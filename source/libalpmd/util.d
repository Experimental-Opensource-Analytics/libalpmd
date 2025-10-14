module util.c;
@nogc nothrow:
extern(C): __gshared:

private template HasVersion(string versionId) {
	mixin("version("~versionId~") {enum HasVersion = true;} else {enum HasVersion = false;}");
}
import core.stdc.config: c_long, c_ulong;
/*
 *  util.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
 *  Copyright (c) 2005 by Christian Hamar <krics@linuxforum.hu>
 *  Copyright (c) 2006 by David Kimpe <dnaku@frugalware.org>
 *  Copyright (c) 2005, 2006 by Miklos Vajna <vmiklos@frugalware.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import core.stdc.stdlib;
import core.sys.posix.unistd;
import core.stdc.ctype;
import core.sys.posix.dirent;
import core.stdc.time;
import core.stdc.errno;
import core.stdc.limits;
import core.sys.posix.sys.wait;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.types;
import core.sys.posix.fcntl;
import fnmatch;
import core.sys.posix.poll;
import core.sys.posix.pwd;
import core.stdc.signal;

/* libarchive */
import archive;
import archive_entry;

version (HAVE_LIBSSL) {
import openssl/evp;
}

version (HAVE_LIBNETTLE) {
import nettle/md5;
import nettle/sha2;
}

/* libalpm */
import util;
import log;
import libarchive-compat;
import alpm;
import alpm_list;
import handle;
import trans;

void MALLOC(T)(T* ptr, size_t size) {
	*ptr = malloc(size);
}

void STRDUP(ref char* str, char* _str) {
	str = strndup(_str);
} 

void CHECK_HANDLE(T) (T t) {
	assert(t !is null);
}

version (HAVE_STRSEP) {} else {
/** Extracts tokens from a string.
 * Replaces strset which is not portable (missing on Solaris).
 * Copyright (c) 2001 by François Gouget <fgouget_at_codeweavers.com>
 * Modifies str to point to the first character after the token if one is
 * found, or NULL if one is not.
 * @param str string containing delimited tokens to parse
 * @param delim character delimiting tokens in str
 * @return pointer to the first token in str if str is not NULL, NULL if
 * str is NULL
 */
char* strsep(char** str, const(char)* delims)
{
	char* token = void;

	if(*str == null) {
		/* No more tokens */
		return null;
	}

	token = *str;
	while(**str != '\0') {
		if(strchr(delims, **str) != null) {
			**str = '\0';
			(*str)++;
			return token;
		}
		(*str)++;
	}
	/* There is no other token */
	*str = null;
	return token;
}
}

int _alpm_makepath(const(char)* path)
{
	return _alpm_makepath_mode(path, 0755);
}

/** Creates a directory, including parents if needed, similar to 'mkdir -p'.
 * @param path directory path to create
 * @param mode permission mode for created directories
 * @return 0 on success, 1 on error
 */
int _alpm_makepath_mode(const(char)* path, mode_t mode)
{
	char* ptr = void, str = void;
	mode_t oldmask = void;
	int ret = 0;

	STRDUP(str, path, return 1);

	oldmask = umask(0000);

	for(ptr = str; *ptr; ptr++) {
		/* detect mid-path condition and zero length paths */
		if(*ptr != '/' || ptr == str || ptr[-1] == '/') {
			continue;
		}

		/* temporarily mask the end of the path */
		*ptr = '\0';

		if(mkdir(str, mode) < 0 && errno != EEXIST) {
			ret = 1;
			goto done;
		}

		/* restore path separator */
		*ptr = '/';
	}

	/* end of the string. add the full path. It will already exist when the path
	 * passed in has a trailing slash. */
	if(mkdir(str, mode) < 0 && errno != EEXIST) {
		ret = 1;
	}

done:
	umask(oldmask);
	free(str);
	return ret;
}

/** Copies a file.
 * @param src file path to copy from
 * @param dest file path to copy to
 * @return 0 on success, 1 on error
 */
int _alpm_copyfile(const(char)* src, const(char)* dest)
{
	char* buf = void;
	int in_ = void, out_ = void, ret = 1;
	ssize_t nread = void;
	stat st = void;

	MALLOC(buf, cast(size_t)ALPM_BUFFER_SIZE);

	OPEN(in_, src, O_RDONLY | O_CLOEXEC);
	do {
		out_ = open(dest, O_WRONLY | O_CREAT | O_BINARY | O_CLOEXEC, 0000);
	} while(out_ == -1 && errno == EINTR);
	if(in_ < 0 || out_ < 0) {
		goto cleanup;
	}

	if(fstat(in_, &st) || fchmod(out_, st.st_mode)) {
		goto cleanup;
	}

	/* do the actual file copy */
	while((nread = read(in_, buf, ALPM_BUFFER_SIZE)) > 0 || errno == EINTR) {
		ssize_t nwrite = 0;
		if(nread < 0) {
			continue;
		}
		do {
			nwrite = write(out_, buf + nwrite, nread);
			if(nwrite >= 0) {
				nread -= nwrite;
			} else if(errno != EINTR) {
				goto cleanup;
			}
		} while(nread > 0);
	}
	ret = 0;

cleanup:
	free(buf);
	if(in_ >= 0) {
		close(in_);
	}
	if(out_ >= 0) {
		close(out_);
	}
	return ret;
}

/** Combines a directory, filename and suffix to provide full path of a file
 * @param path directory path
 * @param filename file name
 * @param suffix suffix
 * @return file path
*/
char* _alpm_get_fullpath(const(char)* path, const(char)* filename, const(char)* suffix)
{
	char* filepath = void;
	/* len = localpath len + filename len + suffix len + null */
	size_t len = strlen(path) + strlen(filename) + strlen(suffix) + 1;
	MALLOC(filepath, len);
	snprintf(filepath, len, "%s%s%s", path, filename, suffix);

	return filepath;
}

/** Trim trailing newlines from a string (if any exist).
 * @param str a single line of text
 * @param len size of str, if known, else 0
 * @return the length of the trimmed string
 */
size_t _alpm_strip_newline(char* str, size_t len)
{
	if(*str == '\0') {
		return 0;
	}
	if(len == 0) {
		len = strlen(str);
	}
	while(len > 0 && str[len - 1] == '\n') {
		len--;
	}
	str[len] = '\0';

	return len;
}

/* Compression functions */

/** Open an archive for reading and perform the necessary boilerplate.
 * This takes care of creating the libarchive 'archive' struct, setting up
 * compression and format options, opening a file descriptor, setting up the
 * buffer size, and performing a stat on the path once opened.
 * On error, no file descriptor is opened, and the archive pointer returned
 * will be set to NULL.
 * @param handle the context handle
 * @param path the path of the archive to open
 * @param buf space for a stat buffer for the given path
 * @param archive pointer to place the created archive object
 * @param error error code to set on failure to open archive
 * @return -1 on failure, >=0 file descriptor on success
 */
int _alpm_open_archive(alpm_handle_t* handle, const(char)* path, stat* buf, archive** archive, alpm_errno_t error)
{
	int fd = void;
	size_t bufsize = ALPM_BUFFER_SIZE;
	errno = 0;

	if((*archive = archive_read_new()) == null) {
		RET_ERR(handle, ALPM_ERR_LIBARCHIVE, -1);
	}

	_alpm_archive_read_support_filter_all(*archive);
	archive_read_support_format_all(*archive);

	_alpm_log(handle, ALPM_LOG_DEBUG, "opening archive %s\n", path);
	OPEN(fd, path, O_RDONLY | O_CLOEXEC);
	if(fd < 0) {
		_alpm_log(handle, ALPM_LOG_ERROR,
				_("could not open file %s: %s\n"), path, strerror(errno));
		goto error;
	}

	if(fstat(fd, buf) != 0) {
		_alpm_log(handle, ALPM_LOG_ERROR,
				_("could not stat file %s: %s\n"), path, strerror(errno));
		goto error;
	}
version (HAVE_STRUCT_STAT_ST_BLKSIZE) {
	if(buf.st_blksize > ALPM_BUFFER_SIZE) {
		bufsize = buf.st_blksize;
	}
}

	if(archive_read_open_fd(*archive, fd, bufsize) != ARCHIVE_OK) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("could not open file %s: %s\n"),
				path, archive_error_string(*archive));
		goto error;
	}

	return fd;

error:
	_alpm_archive_read_free(*archive);
	*archive = null;
	if(fd >= 0) {, fclose(fp); return ALPM_ERR_MEMORY
		close(fd);
	}
	RET_ERR(handle, error, -1);
}

/** Unpack a specific file in an archive.
 * @param handle the context handle
 * @param archive the archive to unpack
 * @param prefix where to extract the files
 * @param filename a file within the archive to unpack
 * @return 0 on success, 1 on failure
 */
int _alpm_unpack_single(alpm_handle_t* handle, const(char)* archive, const(char)* prefix, const(char)* filename)
{
	alpm_list_t* list = null;
	int ret = 0;
	if(filename == null) {
		return 1;
	}
	list = alpm_list_add(list, cast(void*)filename);
	ret = _alpm_unpack(handle, archive, prefix, list, 1);
	alpm_list_free(list);
	return ret;
}

/** Unpack a list of files in an archive.
 * @param handle the context handle
 * @param path the archive to unpack
 * @param prefix where to extract the files
 * @param list a list of files within the archive to unpack or NULL for all
 * @param breakfirst break after the first entry found
 * @return 0 on success, 1 on failure
 */
int _alpm_unpack(alpm_handle_t* handle, const(char)* path, const(char)* prefix, alpm_list_t* list, int breakfirst)
{
	int ret = 0;
	mode_t oldmask = void;
	archive* archive = void;
	archive_entry* entry = void;
	stat buf = void;
	int fd = void, cwdfd = void;

	fd = _alpm_open_archive(handle, path, &buf, &archive, ALPM_ERR_PKG_OPEN);
	if(fd < 0) {
		return 1;
	}

	oldmask = umask(0022);

	/* save the cwd so we can restore it later */
	OPEN(cwdfd, ".", O_RDONLY | O_CLOEXEC);
	if(cwdfd < 0) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("could not get current working directory\n"));
	}

	/* just in case our cwd was removed in the upgrade operation */
	if(chdir(prefix) != 0) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("could not change directory to %s (%s)\n"),
				prefix, strerror(errno));
		ret = 1;
		goto cleanup;
	}

	while(archive_read_next_header(archive, &entry) == ARCHIVE_OK) {
		const(char)* entryname = void;
		mode_t mode = void;

		entryname = archive_entry_pathname(entry);

		if(entryname == null) {
			ret = 1;
			goto cleanup;
		}

		/* If specific files were requested, skip entries that don't match. */
		if(list) {
			char* entry_prefix = null;
			STRDUP(entry_prefix, entryname);
			char* p = strstr(entry_prefix,"/");
			if(p) {
				*(p + 1) = '\0';
			}
			char* found = alpm_list_find_str(list, entry_prefix);
			free(entry_prefix);
			if(!found) {
				if(archive_read_data_skip(archive) != ARCHIVE_OK) {
					ret = 1;
					goto cleanup;
				}
				continue;
			} else {
				_alpm_log(handle, ALPM_LOG_DEBUG, "extracting: %s\n", entryname);
			}
		}

		mode = archive_entry_mode(entry);
		if(S_ISREG(mode)) {
			archive_entry_set_perm(entry, 0644);
		} else if(S_ISDIR(mode)) {
			archive_entry_set_perm(entry, 0755);
		}

		/* Extract the archive entry. */
		int readret = archive_read_extract(archive, entry, 0);
		if(readret == ARCHIVE_WARN) {
			/* operation succeeded but a non-critical error was encountered */
			_alpm_log(handle, ALPM_LOG_WARNING, _("warning given when extracting %s (%s)\n"),
					entryname, archive_error_string(archive));
		} else if(readret != ARCHIVE_OK) {
			_alpm_log(handle, ALPM_LOG_ERROR, _("could not extract %s (%s)\n"),
					entryname, archive_error_string(archive));
			ret = 1;
			goto cleanup;
		}

		if(breakfirst) {
			break;
		}
	}

cleanup:
	umask(oldmask);
	_alpm_archive_read_free(archive);
	close(fd);
	if(cwdfd >= 0) {
		if(fchdir(cwdfd) != 0) {
			_alpm_log(handle, ALPM_LOG_ERROR,
					_("could not restore working directory (%s)\n"), strerror(errno));
		}
		close(cwdfd);
	}

	return ret;
}

/** Determine if there are files in a directory.
 * @param handle the context handle
 * @param path the full absolute directory path
 * @param full_count whether to return an exact count of files
 * @return a file count if full_count is != 0, else >0 if directory has
 * contents, 0 if no contents, and -1 on error
 */
ssize_t _alpm_files_in_directory(alpm_handle_t* handle, const(char)* path, int full_count)
{
	ssize_t files = 0;
	dirent* ent = void;
	DIR* dir = opendir(path);

	if(!dir) {
		if(errno == ENOTDIR) {
			_alpm_log(handle, ALPM_LOG_DEBUG, "%s was not a directory\n", path);
		} else {
			_alpm_log(handle, ALPM_LOG_DEBUG, "could not read directory %s\n",
					path);
		}
		return -1;
	}
	while((ent = readdir(dir)) != null) {
		const(char)* name = ent.d_name;

		if(strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
			continue;
		}

		files++;

		if(!full_count) {
			break;
		}
	}

	closedir(dir);
	return files;
}

private int should_retry(int errnum)
{
	return errnum == EAGAIN
/* EAGAIN may be the same value as EWOULDBLOCK (POSIX.1) - prevent GCC warning */
static if (EAGAIN != EWOULDBLOCK
	|| errnum == EWOULDBLOCK) {
}
	|| errnum == EINTR;
}

private int _alpm_chroot_write_to_child(alpm_handle_t* handle, int fd, char* buf, ssize_t* buf_size, ssize_t buf_limit, _alpm_cb_io out_cb, void* cb_ctx)
{
	ssize_t nwrite = void;

	if(*buf_size == 0) {
		/* empty buffer, ask the callback for more */
		if((*buf_size = out_cb(buf, buf_limit, cb_ctx)) == 0) {
			/* no more to write, close the pipe */
			return -1;
		}
	}

	nwrite = send(fd, buf, *buf_size, MSG_NOSIGNAL);

	if(nwrite != -1) {
		/* write was successful, remove the written data from the buffer */
		*buf_size -= nwrite;
		memmove(buf, buf + nwrite, *buf_size);
	} else if(should_retry(errno)) {
		/* nothing written, try again later */
	} else {
		_alpm_log(handle, ALPM_LOG_ERROR,
				_("unable to write to pipe (%s)\n"), strerror(errno));
		return -1;
	}

	return 0;
}

private void _alpm_chroot_process_output(alpm_handle_t* handle, const(char)* line)
{
	alpm_event_scriptlet_info_t event = {
		type: ALPM_EVENT_SCRIPTLET_INFO,
		line: line
	};
	alpm_logaction(handle, "ALPM-SCRIPTLET", "%s", line);
	EVENT(handle, &event);
}

private int _alpm_chroot_read_from_child(alpm_handle_t* handle, int fd, char* buf, ssize_t* buf_size, ssize_t buf_limit)
{
	ssize_t space = buf_limit - *buf_size - 2; /* reserve 2 for "\n\0" */
	ssize_t nread = read(fd, buf + *buf_size, space);
	if(nread > 0) {
		char* newline = memchr(buf + *buf_size, '\n', nread);
		*buf_size += nread;
		if(newline) {
			while(newline) {
				size_t linelen = newline - buf + 1;
				char old = buf[linelen];
				buf[linelen] = '\0';
				_alpm_chroot_process_output(handle, buf);
				buf[linelen] = old;

				*buf_size -= linelen;
				memmove(buf, buf + linelen, *buf_size);
				newline = memchr(buf, '\n', *buf_size);
			}
		} else if(nread == space) {
			/* we didn't read a full line, but we're out of space */
			strcpy(buf + *buf_size, "\n");
			_alpm_chroot_process_output(handle, buf);
			*buf_size = 0;
		}
	} else if(nread == 0) {
		/* end-of-file */
		if(*buf_size) {
			strcpy(buf + *buf_size, "\n");
			_alpm_chroot_process_output(handle, buf);
		}
		return -1;
	} else if(should_retry(errno)) {
		/* nothing read, try again */
	} else {
		/* read error */
		if(*buf_size) {
			strcpy(buf + *buf_size, "\n");
			_alpm_chroot_process_output(handle, buf);
		}
		_alpm_log(handle, ALPM_LOG_ERROR,
				_("unable to read from pipe (%s)\n"), strerror(errno));
		return -1;
	}
	return 0;
}

void _alpm_reset_signals()
{
	/* reset POSIX defined signals (see signal.h) */
	/* there are likely more but there is no easy way
	 * to get the full list of valid signals */
	int* i = void; int[29] signals = [
		SIGABRT, SIGALRM, SIGBUS, SIGCHLD, SIGCONT, SIGFPE, SIGHUP, SIGILL,
		SIGINT, SIGKILL, SIGPIPE, SIGQUIT, SIGSEGV, SIGSTOP, SIGTERM, SIGTSTP,
		SIGTTIN, SIGTTOU, SIGUSR1, SIGUSR2, SIGPROF, SIGSYS, SIGTRAP, SIGURG,
		SIGVTALRM, SIGXCPU, SIGXFSZ,
#if defined(SIGPOLL)
		/* Not available on FreeBSD et al. */
		SIGPOLL,
#endif
		0
	];
	sigaction def = { sa_handler: SIG_DFL };
	sigemptyset(&def.sa_mask);
	for(i = signals; *i; i++) {
		sigaction(*i, &def, null);
	}
}

/** Execute a command with arguments in a chroot.
 * @param handle the context handle
 * @param cmd command to execute
 * @param argv arguments to pass to cmd
 * @param stdin_cb callback to provide input to the chroot on stdin
 * @param stdin_ctx context to be passed to @a stdin_cb
 * @return 0 on success, 1 on error
 */
int _alpm_run_chroot(alpm_handle_t* handle, const(char)* cmd, char** argv, _alpm_cb_io stdin_cb, void* stdin_ctx)
{
	pid_t pid = void;
	int[2] child2parent_pipefd = void, parent2child_pipefd = void;
	int cwdfd = void;
	int retval = 0;

enum HEAD = 1;
enum TAIL = 0;

	/* save the cwd so we can restore it later */
	OPEN(cwdfd, ".", O_RDONLY | O_CLOEXEC);
	if(cwdfd < 0) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("could not get current working directory\n"));
	}

	/* just in case our cwd was removed in the upgrade operation */
	if(chdir(handle.root) != 0) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("could not change directory to %s (%s)\n"),
				handle.root, strerror(errno));
		goto cleanup;
	}

	_alpm_log(handle, ALPM_LOG_DEBUG, "executing \"%s\" under chroot \"%s\"\n",
			cmd, handle.root);

	/* Flush open fds before fork() to avoid cloning buffers */
	fflush(null);

	if(socketpair(AF_UNIX, SOCK_STREAM, 0, child2parent_pipefd.ptr) == -1) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("could not create pipe (%s)\n"), strerror(errno));
		retval = 1;
		goto cleanup;
	}

	if(socketpair(AF_UNIX, SOCK_STREAM, 0, parent2child_pipefd.ptr) == -1) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("could not create pipe (%s)\n"), strerror(errno));
		retval = 1;
		goto cleanup;
	}

	/* fork- parent and child each have separate code blocks below */
	pid = fork();
	if(pid == -1) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("could not fork a new process (%s)\n"), strerror(errno));
		retval = 1;
		goto cleanup;
	}

	if(pid == 0) {
		/* this code runs for the child only (the actual chroot/exec) */
		close(0);
		close(1);
		close(2);
		while(dup2(child2parent_pipefd[HEAD], 1) == -1 && errno == EINTR){}
		while(dup2(child2parent_pipefd[HEAD], 2) == -1 && errno == EINTR){}
		while(dup2(parent2child_pipefd[TAIL], 0) == -1 && errno == EINTR){}
		close(parent2child_pipefd[TAIL]);
		close(parent2child_pipefd[HEAD]);
		close(child2parent_pipefd[TAIL]);
		close(child2parent_pipefd[HEAD]);
		if(cwdfd >= 0) {
			close(cwdfd);
		}

		/* use fprintf instead of _alpm_log to send output through the parent */
		/* don't chroot() to "/": this allows running with less caps when the
		 * caller puts us in the right root */
		if(strcmp(handle.root, "/") != 0 && chroot(handle.root) != 0) {
			fprintf(stderr, _("could not change the root directory (%s)\n"), strerror(errno));
			exit(1);
		}
		if(chdir("/") != 0) {
			fprintf(stderr, _("could not change directory to %s (%s)\n"),
					"/", strerror(errno));
			exit(1);
		}
		/* bash assumes it's being run under rsh/ssh if stdin is a socket and
		 * sources ~/.bashrc if it thinks it's the top-level shell.
		 * set SHLVL before running to indicate that it's a child shell and
		 * disable this behavior */
		setenv("SHLVL", "1", 0);
		/* bash sources $BASH_ENV when run non-interactively */
		unsetenv("BASH_ENV");
		umask(0022);
		_alpm_reset_signals();
		_alpm_handle_free(handle);
		execv(cmd, argv);
		/* execv only returns if there was an error */
		fprintf(stderr, _("call to execv failed (%s)\n"), strerror(errno));
		exit(1);
	} else {
		/* this code runs for the parent only (wait on the child) */
		int status = void;
		char[PIPE_BUF] obuf = void; /* writes <= PIPE_BUF are guaranteed atomic */
		char[LINE_MAX] ibuf = void;
		ssize_t olen = 0, ilen = 0;
		nfds_t nfds = 2;
		pollfd[2] fds = void; pollfd* child2parent = &(fds[0]), parent2child = &(fds[1]);
		int poll_ret = void;

		child2parent.fd = child2parent_pipefd[TAIL];
		child2parent.events = POLLIN;
		fcntl(child2parent.fd, F_SETFL, O_NONBLOCK);
		close(child2parent_pipefd[HEAD]);
		close(parent2child_pipefd[TAIL]);

		if(stdin_cb) {
			parent2child.fd = parent2child_pipefd[HEAD];
			parent2child.events = POLLOUT;
			fcntl(parent2child.fd, F_SETFL, O_NONBLOCK);
		} else {
			parent2child.fd = -1;
			parent2child.events = 0;
			close(parent2child_pipefd[HEAD]);
		}

enum string STOP_POLLING(string p) = `do { close(` ~ p ~ `.fd); ` ~ p ~ `.fd = -1; } while(0)`;

		while((child2parent.fd != -1 || parent2child.fd != -1)
				&& (poll_ret = poll(fds, nfds, -1)) != 0) {
			if(poll_ret == -1) {
				if(errno == EINTR) {
					continue;
				} else {
					break;
				}
			}
			if(child2parent.revents & POLLIN) {
				if(_alpm_chroot_read_from_child(handle, child2parent.fd,
							ibuf, &ilen, ibuf.sizeof) != 0) {
					/* we encountered end-of-file or an error */
					mixin(STOP_POLLING!(`child2parent`));
				}
			} else if(child2parent.revents) {
				/* anything but POLLIN indicates an error */
				mixin(STOP_POLLING!(`child2parent`));
			}
			if(parent2child.revents & POLLOUT) {
				if(_alpm_chroot_write_to_child(handle, parent2child.fd, obuf, &olen,
							obuf.sizeof, stdin_cb, stdin_ctx) != 0) {
					mixin(STOP_POLLING!(`parent2child`));
				}
			} else if(parent2child.revents) {
				/* anything but POLLOUT indicates an error */
				mixin(STOP_POLLING!(`parent2child`));
			}
		}
		/* process anything left in the input buffer */
		if(ilen) {
			/* buffer would have already been flushed if it had a newline */
			strcpy(ibuf + ilen, "\n");
			_alpm_chroot_process_output(handle, ibuf);
		}

		if(parent2child.fd != -1) {
			close(parent2child.fd);
		}
		if(child2parent.fd != -1) {
			close(child2parent.fd);
		}

		while(waitpid(pid, &status, 0) == -1) {
			if(errno != EINTR) {
				_alpm_log(handle, ALPM_LOG_ERROR, _("call to waitpid failed (%s)\n"), strerror(errno));
				retval = 1;
				goto cleanup;
			}
		}

		/* check the return status, make sure it is 0 (success) */
		if(WIFEXITED(status)) {
			_alpm_log(handle, ALPM_LOG_DEBUG, "call to waitpid succeeded\n");
			if(WEXITSTATUS(status) != 0) {
				_alpm_log(handle, ALPM_LOG_ERROR, _("command failed to execute correctly\n"));
				retval = 1;
			}
		} else if(WIFSIGNALED(status) != 0) {
			char* signal_description = strsignal(WTERMSIG(status));
			/* strsignal can return NULL on some (non-Linux) platforms */
			if(signal_description == null) {
				signal_description = _("Unknown signal");
			}
			_alpm_log(handle, ALPM_LOG_ERROR, _("command terminated by signal %d: %s\n"),
						WTERMSIG(status), signal_description);
			retval = 1;
		}
	}

cleanup:
	if(cwdfd >= 0) {
		if(fchdir(cwdfd) != 0) {
			_alpm_log(handle, ALPM_LOG_ERROR,
					_("could not restore working directory (%s)\n"), strerror(errno));
		}
		close(cwdfd);
	}

	return retval;
}

/** Run ldconfig in a chroot.
 * @param handle the context handle
 * @return 0 on success, 1 on error
 */
int _alpm_ldconfig(alpm_handle_t* handle)
{
	char[PATH_MAX] line = void;

	_alpm_log(handle, ALPM_LOG_DEBUG, "running ldconfig\n");

	snprintf(line.ptr, PATH_MAX, "%setc/ld.so.conf", handle.root);
	if(access(line.ptr, F_OK) == 0) {
		snprintf(line.ptr, PATH_MAX, "%s%s", handle.root, LDCONFIG);
		if(access(line.ptr, X_OK) == 0) {
			char[32] arg0 = void;
			char*[2] argv = [ arg0, null ];
			strcpy(arg0.ptr, "ldconfig");
			return _alpm_run_chroot(handle, LDCONFIG, argv.ptr, null, null);
		}
	}

	return 0;
}

/** Helper function for comparing strings using the alpm "compare func"
 * signature.
 * @param s1 first string to be compared
 * @param s2 second string to be compared
 * @return 0 if strings are equal, positive int if first unequal character
 * has a greater value in s1, negative if it has a greater value in s2
 */
int _alpm_str_cmp(const(void)* s1, const(void)* s2)
{
	return strcmp(s1, s2);
}

/** Find a filename in a registered alpm cachedir.
 * @param handle the context handle
 * @param filename name of file to find
 * @return malloced path of file, NULL if not found
 */
char* _alpm_filecache_find(alpm_handle_t* handle, const(char)* filename)
{
	char[PATH_MAX] path = void;
	char* retpath = void;
	alpm_list_t* i = void;
	stat buf = void;

	/* Loop through the cache dirs until we find a matching file */
	for(i = handle.cachedirs; i; i = i.next) {
		snprintf(path.ptr, PATH_MAX, "%s%s", cast(char*)i.data,
				filename);
		if(stat(path.ptr, &buf) == 0) {
			if(S_ISREG(buf.st_mode)) {
				retpath = strdup(path.ptr);
				_alpm_log(handle, ALPM_LOG_DEBUG, "found cached pkg: %s\n", retpath);
				return retpath;
			} else {
				_alpm_log(handle, ALPM_LOG_WARNING,
						"cached pkg '%s' is not a regular file: mode=%i\n", path.ptr, buf.st_mode);
			}
		} else if(errno != ENOENT) {
			_alpm_log(handle, ALPM_LOG_WARNING, "could not open '%s'\n: %s", path.ptr, strerror(errno));
		}
	}
	/* package wasn't found in any cachedir */
	return null;
}

/** Check whether a filename exists in a registered alpm cachedir.
 * @param handle the context handle
 * @param filename name of file to find
 * @return 0 if the filename was not found, 1 otherwise
 */
int _alpm_filecache_exists(alpm_handle_t* handle, const(char)* filename)
{
	int res = void;
	char* fpath = _alpm_filecache_find(handle, filename);
	res = (fpath != null);
	FREE(fpath);
	return res;
}

/** Check the alpm cachedirs for existence and find a writable one.
 * If no valid cache directory can be found, use /tmp.
 * @param handle the context handle
 * @return pointer to a writable cache directory.
 */
const(char)* _alpm_filecache_setup(alpm_handle_t* handle)
{
	stat buf = void;
	alpm_list_t* i = void;
	char* cachedir = void;
	const(char)* tmpdir = void;

	/* Loop through the cache dirs until we find a usable directory */
	for(i = handle.cachedirs; i; i = i.next) {
		cachedir = i.data;
		if(stat(cachedir, &buf) != 0) {
			/* cache directory does not exist.... try creating it */
			_alpm_log(handle, ALPM_LOG_WARNING, _("no %s cache exists, creating...\n"),
					cachedir);
			if(_alpm_makepath(cachedir) == 0) {
				_alpm_log(handle, ALPM_LOG_DEBUG, "using cachedir: %s\n", cachedir);
				return cachedir;
			}
		} else if(!S_ISDIR(buf.st_mode)) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"skipping cachedir, not a directory: %s\n", cachedir);
		} else if(_alpm_access(handle, null, cachedir, W_OK) != 0) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"skipping cachedir, not writable: %s\n", cachedir);
		} else if(!(buf.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH))) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"skipping cachedir, no write bits set: %s\n", cachedir);
		} else {
			_alpm_log(handle, ALPM_LOG_DEBUG, "using cachedir: %s\n", cachedir);
			return cachedir;
		}
	}

	/* we didn't find a valid cache directory. use TMPDIR or /tmp. */
	if((tmpdir = getenv("TMPDIR")) && stat(tmpdir, &buf) && S_ISDIR(buf.st_mode)) {
		/* TMPDIR was good, we can use it */
	} else {
		tmpdir = "/tmp";
	}
	alpm_option_add_cachedir(handle, tmpdir);
	cachedir = handle.cachedirs.prev.data;
	_alpm_log(handle, ALPM_LOG_DEBUG, "using cachedir: %s\n", cachedir);
	_alpm_log(handle, ALPM_LOG_WARNING,
			_("couldn't find or create package cache, using %s instead\n"), cachedir);
	return cachedir;
}

/** Create a temporary directory under the supplied directory.
 * The new directory is writable by the download user, and will be
 * removed after the download operation has completed.
 * @param dir existing sync or cache directory
 * @param user download user name
 * @return pointer to a sub-directory writable by the download user inside the existing directory.
 */
char* _alpm_temporary_download_dir_setup(const(char)* dir, const(char)* user)
{
	const(passwd)* pw = null;

	ASSERT(dir != null, return NULL);
	if(user != null) {
		ASSERT((pw = getpwnam(user)) != null, return NULL);
	}

	const(char)[16] template_ = "download-XXXXXX";
	size_t newdirlen = strlen(dir) + ((template_) + 1).sizeof;
	char* newdir = null;
	MALLOC(newdir, newdirlen);
	snprintf(newdir, newdirlen - 1, "%s%s", dir, template_);
	if(mkdtemp(newdir) == null) {
		free(newdir);
		return null;
	}
	if(pw != null) {
		if(chown(newdir, pw.pw_uid, pw.pw_gid) == -1) {
			free(newdir);
			return null;
		}
	}
	newdir[newdirlen-2] = '/';
	newdir[newdirlen-1] = 0;
	return newdir;
}

/** Remove a temporary directory.
 * The temporary download directory is removed after deleting any
 * leftover files.
 * @param dir directory to be removed
 */
void _alpm_remove_temporary_download_dir(const(char)* dir)
{
	ASSERT(dir != null, return);
	size_t dirlen = strlen(dir);
	dirent* dp = null;
	DIR* dirp = opendir(dir);
	if(!dirp) {
		return;
	}
	for(dp = readdir(dirp); dp != null; dp = readdir(dirp)) {
		if(strcmp(dp.d_name, "..") != 0 && strcmp(dp.d_name, ".") != 0) {
			char[PATH_MAX] name = void;
			if(dirlen + strlen(dp.d_name) + 2 > PATH_MAX) {
				/* file path is too long to remove, hmm. */
				continue;
			} else {
				sprintf(name.ptr, "%s/%s", dir, dp.d_name);
				if(unlink(name.ptr)) {
					continue;
				}
			}
		}
	}
	closedir(dirp);
	rmdir(dir);
}


static if (HasVersion!"HAVE_LIBSSL" || HasVersion!"HAVE_LIBNETTLE") {
/** Compute the MD5 message digest of a file.
 * @param path file path of file to compute  MD5 digest of
 * @param output string to hold computed MD5 digest
 * @return 0 on success, 1 on file open error, 2 on file read error
 */
private int md5_file(const(char)* path, ubyte* output)
{
static if (HAVE_LIBSSL) {
	EVP_MD_CTX* ctx = void;
	const(EVP_MD)* md = EVP_get_digestbyname("MD5");
} else { /* HAVE_LIBNETTLE */
	md5_ctx ctx = void;
}
	ubyte* buf = void;
	ssize_t n = void;
	int fd = void;

	MALLOC(buf, cast(size_t)ALPM_BUFFER_SIZE);

	OPEN(fd, path, O_RDONLY | O_CLOEXEC);
	if(fd < 0) {
		free(buf);
		return 1;
	}

static if (HAVE_LIBSSL) {
	ctx = EVP_MD_CTX_create();
	EVP_DigestInit_ex(ctx, md, null);
} else { /* HAVE_LIBNETTLE */
	md5_init(&ctx);
}

	while((n = read(fd, buf, ALPM_BUFFER_SIZE)) > 0 || errno == EINTR) {
		if(n < 0) {
			continue;
		}
static if (HAVE_LIBSSL) {
		EVP_DigestUpdate(ctx, buf, n);
} else { /* HAVE_LIBNETTLE */
		md5_update(&ctx, n, buf);
}
	}

	close(fd);
	free(buf);

	if(n < 0) {
		return 2;
	}

static if (HAVE_LIBSSL) {
	EVP_DigestFinal_ex(ctx, output, null);
	EVP_MD_CTX_destroy(ctx);
} else { /* HAVE_LIBNETTLE */
	md5_digest(&ctx, MD5_DIGEST_SIZE, output);
}
	return 0;
}

/** Compute the SHA-256 message digest of a file.
 * @param path file path of file to compute SHA256 digest of
 * @param output string to hold computed SHA256 digest
 * @return 0 on success, 1 on file open error, 2 on file read error
 */
private int sha256_file(const(char)* path, ubyte* output)
{
static if (HAVE_LIBSSL) {
	EVP_MD_CTX* ctx = void;
	const(EVP_MD)* md = EVP_get_digestbyname("SHA256");
} else { /* HAVE_LIBNETTLE */
	sha256_ctx ctx = void;
}
	ubyte* buf = void;
	ssize_t n = void;
	int fd = void;

	MALLOC(buf, cast(size_t)ALPM_BUFFER_SIZE);

	OPEN(fd, path, O_RDONLY | O_CLOEXEC);
	if(fd < 0) {
		free(buf);
		return 1;
	}

static if (HAVE_LIBSSL) {
	ctx = EVP_MD_CTX_create();
	EVP_DigestInit_ex(ctx, md, null);
} else { /* HAVE_LIBNETTLE */
	sha256_init(&ctx);
}

	while((n = read(fd, buf, ALPM_BUFFER_SIZE)) > 0 || errno == EINTR) {
		if(n < 0) {
			continue;
		}
static if (HAVE_LIBSSL) {
		EVP_DigestUpdate(ctx, buf, n);
} else { /* HAVE_LIBNETTLE */
		sha256_update(&ctx, n, buf);
}
	}

	close(fd);
	free(buf);

	if(n < 0) {
		return 2;
	}

static if (HAVE_LIBSSL) {
	EVP_DigestFinal_ex(ctx, output, null);
	EVP_MD_CTX_destroy(ctx);
} else { /* HAVE_LIBNETTLE */
	sha256_digest(&ctx, SHA256_DIGEST_SIZE, output);
}
	return 0;
}
} /* HAVE_LIBSSL || HAVE_LIBNETTLE */

char * alpm_compute_md5sum(const(char)* filename)
{
	ubyte[16] output = void;

	ASSERT(filename != null, return NULL);

	if(md5_file(filename, output.ptr) > 0) {
		return null;
	}

	return hex_representation(output.ptr, 16);
}

char * alpm_compute_sha256sum(const(char)* filename)
{
	ubyte[32] output = void;

	ASSERT(filename != null, return NULL);

	if(sha256_file(filename, output.ptr) > 0) {
		return null;
	}

	return hex_representation(output.ptr, 32);
}

/** Calculates a file's MD5 or SHA-2 digest and compares it to an expected value.
 * @param filepath path of the file to check
 * @param expected hash value to compare against
 * @param type digest type to use
 * @return 0 if file matches the expected hash, 1 if they do not match, -1 on
 * error
 */
int _alpm_test_checksum(const(char)* filepath, const(char)* expected, alpm_pkgvalidation_t type)
{
	char* computed = void;
	int ret = void;

	if(type == ALPM_PKG_VALIDATION_MD5SUM) {
		computed = alpm_compute_md5sum(filepath);
	} else if(type == ALPM_PKG_VALIDATION_SHA256SUM) {
		computed = alpm_compute_sha256sum(filepath);
	} else {
		return -1;
	}

	if(expected == null || computed == null) {
		ret = -1;
	} else if(strcmp(expected, computed) != 0) {
		ret = 1;
	} else {
		ret = 0;
	}

	FREE(computed);
	return ret;
}

/* Note: does NOT handle sparse files on purpose for speed. */
/** TODO.
 * Does not handle sparse files on purpose for speed.
 * @param a
 * @param b
 * @return
 */
int _alpm_archive_fgets(archive* a, archive_read_buffer* b)
{
	/* ensure we start populating our line buffer at the beginning */
	b.line_offset = b.line;

	while(1) {
		size_t block_remaining = void;
		char* eol = void;

		/* have we processed this entire block? */
		if(b.block + b.block_size == b.block_offset) {
			long offset = void;
			if(b.ret == ARCHIVE_EOF) {
				/* reached end of archive on the last read, now we are out of data */
				goto cleanup;
			}

			/* zero-copy - this is the entire next block of data. */
			b.ret = archive_read_data_block(a, cast(void*)&b.block,
					&b.block_size, &offset);
			b.block_offset = b.block;
			block_remaining = b.block_size;

			/* error, cleanup */
			if(b.ret < ARCHIVE_OK) {
				goto cleanup;
			}
		} else {
			block_remaining = b.block + b.block_size - b.block_offset;
		}

		/* look through the block looking for EOL characters */
		eol = memchr(b.block_offset, '\n', block_remaining);
		if(!eol) {
			eol = memchr(b.block_offset, '\0', block_remaining);
		}

		/* allocate our buffer, or ensure our existing one is big enough */
		if(!b.line) {
			/* set the initial buffer to the read block_size */
			CALLOC(b.line, b.block_size + 1, char.sizeof, b.ret = -ENOMEM; goto cleanup);
			b.line_size = b.block_size + 1;
			b.line_offset = b.line;
		} else {
			/* note: we know eol > b->block_offset and b->line_offset > b->line,
			 * so we know the result is unsigned and can fit in size_t */
			size_t new_ = eol ? cast(size_t)(eol - b.block_offset) : block_remaining;
			size_t needed = cast(size_t)((b.line_offset - b.line) + new_ + 1);
			if(needed > b.max_line_size) {
				b.ret = -ERANGE;
				goto cleanup;
			}
			if(needed > b.line_size) {
				/* need to realloc + copy data to fit total length */
				char* new_line = void;
				CALLOC(new_line, needed, char.sizeof, b.ret = -ENOMEM; goto cleanup);
				memcpy(new_line, b.line, b.line_size);
				b.line_size = needed;
				b.line_offset = new_line + (b.line_offset - b.line);
				free(b.line);
				b.line = new_line;
			}
		}

		if(eol) {
			size_t len = cast(size_t)(eol - b.block_offset);
			memcpy(b.line_offset, b.block_offset, len);
			b.line_offset[len] = '\0';
			b.block_offset = eol + 1;
			b.real_line_size = b.line_offset + len - b.line;
			/* this is the main return point; from here you can read b->line */
			return ARCHIVE_OK;
		} else {
			/* we've looked through the whole block but no newline, copy it */
			size_t len = cast(size_t)(b.block + b.block_size - b.block_offset);
			memcpy(b.line_offset, b.block_offset, len);
			b.line_offset += len;
			b.block_offset = b.block + b.block_size;
			/* there was no new data, return what is left; saved ARCHIVE_EOF will be
			 * returned on next call */
			if(len == 0) {
				b.line_offset[0] = '\0';
				b.real_line_size = b.line_offset - b.line;
				return ARCHIVE_OK;
			}
		}
	}

cleanup:
	{
		int ret = b.ret;
		FREE(b.line);
		*b = struct archive_read_buffer(0);
		return ret;
	}
}

/** Parse a full package specifier.
 * @param target package specifier to parse, such as: "pacman-4.0.1-2",
 * "pacman-4.01-2/", or "pacman-4.0.1-2/desc"
 * @param name to hold package name
 * @param version to hold package version
 * @param name_hash to hold package name hash
 * @return 0 on success, -1 on error
 */
int _alpm_splitname(const(char)* target, char** name, char** version_, c_ulong* name_hash)
{
	/* the format of a db entry is as follows:
	 *    package-version-rel/
	 *    package-version-rel/desc (we ignore the filename portion)
	 * package name can contain hyphens, so parse from the back- go back
	 * two hyphens and we have split the version from the name.
	 */
	const(char)* pkgver = void, end = void;

	if(target == null) {
		return -1;
	}

	/* remove anything trailing a '/' */
	end = strchr(target, '/');
	if(!end) {
		end = target + strlen(target);
	}

	/* do the magic parsing- find the beginning of the version string
	 * by doing two iterations of same loop to lop off two hyphens */
	for(pkgver = end - 1; *pkgver && *pkgver != '-'; pkgver--){}
	for(pkgver = pkgver - 1; *pkgver && *pkgver != '-'; pkgver--){}
	if(*pkgver != '-' || pkgver == target) {
		return -1;
	}

	/* copy into fields and return */
	if(version_) {
		if(*version_) {
			FREE(*version_);
		}
		/* version actually points to the dash, so need to increment 1 and account
		 * for potential end character */
		STRNDUP(*version_, pkgver + 1, end - pkgver - 1, return -1);
	}

	if(name) {
		if(*name) {
			FREE(*name);
		}
		STRNDUP(*name, target, pkgver - target, return -1);
		if(name_hash) {
			*name_hash = _alpm_hash_sdbm(*name);
		}
	}

	return 0;
}

/** Hash the given string to an unsigned long value.
 * This is the standard sdbm hashing algorithm.
 * @param str string to hash
 * @return the hash value of the given string
 */
c_ulong _alpm_hash_sdbm(const(char)* str)
{
	c_ulong hash = 0;
	int c = void;

	if(!str) {
		return hash;
	}
	while((c = *str++)) {
		hash = c + hash * 65599;
	}

	return hash;
}

/** Convert a string to a file offset.
 * This parses bare positive integers only.
 * @param line string to convert
 * @return off_t on success, -1 on error
 */
off_t _alpm_strtoofft(const(char)* line)
{
	char* end = void;
	ulong result = void;
	errno = 0;

	/* we are trying to parse bare numbers only, no leading anything */
	if(!isdigit(cast(ubyte)line[0])) {
		return (off_t)-1;
	}
	result = strtoull(line, &end, 10);
	if(result == 0 && end == line) {
		/* line was not a number */
		return (off_t)-1;
	} else if(result == ULLONG_MAX && errno == ERANGE) {
		/* line does not fit in unsigned long long */
		return (off_t)-1;
	} else if(*end) {
		/* line began with a number but has junk left over at the end */
		return (off_t)-1;
	}

	return cast(off_t)result;
}

/** Parses a date into an alpm_time_t struct.
 * @param line date to parse
 * @return time struct on success, 0 on error
 */
alpm_time_t _alpm_parsedate(const(char)* line)
{
	char* end = void;
	long result = void;
	errno = 0;

	result = strtoll(line, &end, 10);
	if(result == 0 && end == line) {
		/* line was not a number */
		errno = EINVAL;
		return 0;
	} else if(errno == ERANGE) {
		/* line does not fit in long long */
		return 0;
	} else if(*end) {
		/* line began with a number but has junk left over at the end */
		errno = EINVAL;
		return 0;
	}

	return cast(alpm_time_t)result;
}

/** Wrapper around access() which takes a dir and file argument
 * separately and generates an appropriate error message.
 * If dir is NULL file will be treated as the whole path.
 * @param handle an alpm handle
 * @param dir directory path ending with and slash
 * @param file filename
 * @param amode access mode as described in access()
 * @return int value returned by access()
 */
int _alpm_access(alpm_handle_t* handle, const(char)* dir, const(char)* file, int amode)
{
	size_t len = 0;
	int ret = 0;

	int flag = 0;
version (AT_SYMLINK_NOFOLLOW) {
	flag |= AT_SYMLINK_NOFOLLOW;
}

	if(dir) {
		char* check_path = void;

		len = strlen(dir) + strlen(file) + 1;
		CALLOC(check_path, len, char.sizeof, RET_ERR(handle, ALPM_ERR_MEMORY, -1));
		snprintf(check_path, len, "%s%s", dir, file);

		ret = faccessat(AT_FDCWD, check_path, amode, flag);
		free(check_path);
	} else {
		dir = "";
		ret = faccessat(AT_FDCWD, file, amode, flag);
	}

	if(ret != 0) {
		if(amode & R_OK) {
			_alpm_log(handle, ALPM_LOG_DEBUG, "\"%s%s\" is not readable: %s\n",
					dir, file, strerror(errno));
		}
		if(amode & W_OK) {
			_alpm_log(handle, ALPM_LOG_DEBUG, "\"%s%s\" is not writable: %s\n",
					dir, file, strerror(errno));
		}
		if(amode & X_OK) {
			_alpm_log(handle, ALPM_LOG_DEBUG, "\"%s%s\" is not executable: %s\n",
					dir, file, strerror(errno));
		}
		if(amode == F_OK) {
			_alpm_log(handle, ALPM_LOG_DEBUG, "\"%s%s\" does not exist: %s\n",
					dir, file, strerror(errno));
		}
	}
	return ret;
}

/** Checks whether a string matches at least one shell wildcard pattern.
 * Checks for matches with fnmatch. Matches are inverted by prepending
 * patterns with an exclamation mark. Preceding exclamation marks may be
 * escaped. Subsequent matches override previous ones.
 * @param patterns patterns to match against
 * @param string string to check against pattern
 * @return 0 if string matches pattern, negative if they don't match and
 * positive if the last match was inverted
 */
int _alpm_fnmatch_patterns(alpm_list_t* patterns, const(char)* string)
{
	alpm_list_t* i = void;
	char* pattern = void;
	short inverted = void;

	for(i = alpm_list_last(patterns); i; i = alpm_list_previous(i)) {
		pattern = i.data;

		inverted = pattern[0] == '!';
		if(inverted || pattern[0] == '\\') {
			pattern++;
		}

		if(_alpm_fnmatch(pattern, string) == 0) {
			return inverted;
		}
	}

	return -1;
}

/** Checks whether a string matches a shell wildcard pattern.
 * Wrapper around fnmatch.
 * @param pattern pattern to match against
 * @param string string to check against pattern
 * @return 0 if string matches pattern, non-zero if they don't match and on
 * error
 */
int _alpm_fnmatch(const(void)* pattern, const(void)* string)
{
	return fnmatch(pattern, string, 0);
}

/** Think of this as realloc with error handling. If realloc fails NULL will be
 * returned and data will not be changed.
 *
 * Newly created memory will be zeroed.
 *
 * @param data source memory space
 * @param current size of the space pointed to by data
 * @param required size you want
 * @return new memory; NULL on error
 */
void* _alpm_realloc(void** data, size_t* current, const(size_t) required)
{
	REALLOC(*data, required, return NULL);

	if (*current < required) {
		/* ensure all new memory is zeroed out, in both the initial
		 * allocation and later reallocs */
		memset(cast(char*)*data + *current, 0, required - *current);
	}
	*current = required;
	return *data;
}

/** This automatically grows data based on current/required.
 *
 * The memory space will be initialised to required bytes and doubled in size when required.
 *
 * Newly created memory will be zeroed.
 * @param data source memory space
 * @param current size of the space pointed to by data
 * @param required size you want
 * @return new memory if grown; old memory otherwise; NULL on error
 */
void* _alpm_greedy_grow(void** data, size_t* current, const(size_t) required)
{
	size_t newsize = 0;

	if(*current >= required) {
		return data;
	}

	if(*current == 0) {
		newsize = required;
	} else {
		newsize = *current * 2;
	}

	/* check for overflows */
	if (newsize < required) {
		return null;
	}

	return _alpm_realloc(data, current, newsize);
}

void _alpm_alloc_fail(size_t size)
{
	fprintf(stderr, "alloc failure: could not allocate %zu bytes\n", size);
}

/** This functions reads file content.
 *
 * Memory buffer is allocated by the callee function. It is responsibility
 * of the caller to free the buffer.
 *
 * @param filepath filepath to read
 * @param data pointer to output buffer
 * @param data_len size of the output buffer
 * @return error code for the operation
 */
alpm_errno_t _alpm_read_file(const(char)* filepath, ubyte** data, size_t* data_len)
{
	stat st = void;
	FILE* fp = void;

	if((fp = fopen(filepath, "rb")) == null) {
		return ALPM_ERR_NOT_A_FILE;
	}

	if(fstat(fileno(fp), &st) != 0) {
		fclose(fp);
		return ALPM_ERR_NOT_A_FILE;
	}
	*data_len = st.st_size;

	MALLOC(*data, *data_len);

	if(fread(*data, *data_len, 1, fp) != 1) {
		FREE(*data);
		fclose(fp);
		return ALPM_ERR_SYSTEM;
	}

	fclose(fp);
	return ALPM_ERR_OK;
}
