module libalpmd.pkg.backend;
@nogc  
   
/*
 *  be_package.c : backend for packages
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
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
import core.stdc.string;
import libalpmd.signing;
import core.sys.posix.unistd;
import core.stdc.errno;
import core.sys.posix.sys.types;
import core.sys.posix.sys.stat;
import core.sys.posix.fcntl;
import core.stdc.limits;
import core.stdc.stdio;;
import std.conv;
import libalpmd.alpm_list;



/* libarchive */
import derelict.libarchive;
// import archive;
// import archive_entry;

/* libalpm */
import libalpmd.alpm_list;
import libalpmd.alpm;
import libalpmd.libarchive_compat;
import libalpmd.util;
import libalpmd.log;
import libalpmd.handle;
import libalpmd.pkg;
import libalpmd.deps;
import libalpmd.filelist;
import libalpmd.util;
import derelict.libarchive;
import libalpmd.db;
import libalpmd.backup;

/**
 * Read data from an open changelog 'file stream'. Similar to fread in
 * functionality, this function takes a buffer and amount of data to read.
 * @param ptr a buffer to fill with raw changelog data
 * @param size the size of the buffer
 * @param pkg the package that the changelog is being read from
 * @param fp a 'file stream' to the package changelog
 * @return the number of characters read, or 0 if there is no more data
 */
private size_t _package_changelog_read(void* ptr, size_t size,  AlpmPkg pkg, void* fp)
{
	AlpmPkgChangelog changelog = cast(AlpmPkgChangelog)fp;
	ssize_t sret = archive_read_data(changelog._archive, ptr, size);
	/* Report error (negative values) */
	if(sret < 0) {
		RET_ERR(cast(AlpmHandle)pkg.handle, ALPM_ERR_LIBARCHIVE, 0);
	} else {
		return cast(size_t)sret;
	}
}

/**
 * Close a package changelog for reading. Similar to fclose in functionality,
 * except that the 'file stream' is from an archive.
 * @param pkg the package (file) that the changelog was read from
 * @param fp a 'file stream' to the package changelog
 * @return whether closing the package changelog stream was successful
 */
private int _package_changelog_close( AlpmPkg pkg, void* fp)
{
	int ret = void;
	AlpmPkgChangelog changelog = cast(AlpmPkgChangelog)fp;
	ret = _alpm_archive_read_free(changelog._archive);
	close(changelog.fd);
	destroy(changelog);
	return ret;
}

// /** Package file operations struct accessor. We implement this as a method
//  * because we want to reuse the majority of the default_pkg_ops struct and
//  * add only a few operations of our own on top.
//  */
// private const (pkg_operations)* get_file_pkg_ops()
// {
// 	static pkg_operations file_pkg_ops;
// 	static int file_pkg_ops_initialized = 0;
// 	if(!file_pkg_ops_initialized) {
// 		file_pkg_ops = default_pkg_ops;
// 		// file_pkg_ops.changelog_open  = &_package_changelog_open;
// 		file_pkg_ops.changelog_read  = &_package_changelog_read;
// 		file_pkg_ops.changelog_close = &_package_changelog_close;
// 		file_pkg_ops_initialized = 1;
// 	}
// 	return &file_pkg_ops;
// }

/**
 * Parses the package description file for a package into a alpm_pkg_t struct.
 * @param archive the archive to read from, pointed at the .PKGINFO entry
 * @param newpkg an empty alpm_pkg_t struct to fill with package info
 *
 * @return 0 on success, -1 on error
 */
private int parse_descfile(AlpmHandle handle, archive* a, AlpmPkg newpkg)
{
	char* ptr = null;
	char* key = null;
	int ret = void, linenum = 0;
	archive_read_buffer buf;

	/* 512K for a line length seems reasonable */
	buf.max_line_size = 512 * 1024;

	/* loop until we reach EOF or other error */
	while((ret = _alpm_archive_fgets(a, &buf)) == ARCHIVE_OK) {
		size_t len = _alpm_strip_newline(buf.line, buf.real_line_size);

		linenum++;
		key = buf.line;
		if(len == 0 || key[0] == '#') {
			continue;
		}
		/* line is always in this format: "key = value"
		 * we can be sure the " = " exists, so look for that */
		ptr = cast(char*)memchr(key, ' ', len);
		if(!ptr || cast(size_t)(ptr - key + 2) > len || memcmp(cast(void*)ptr, " = ".ptr, 3) != 0) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"%s: syntax error in description file line %d\n",
					newpkg.name ? newpkg.name : "error", linenum);
		} else {
			/* NULL the end of the key portion, move ptr to start of value */
			*ptr = '\0';
			ptr += 3;
			char* tmp = null;
			if(strcmp(key, "pkgname") == 0) {
				STRDUP(tmp, ptr);
				newpkg.name = tmp.to!string;
				newpkg.name_hash = alpmSDBMHash(newpkg.name);
			} else if(strcmp(key, "pkgbase") == 0) {
				newpkg.base = ptr.to!string;
			} else if(strcmp(key, "pkgver") == 0) {
				STRDUP(tmp, ptr);
				newpkg.version_ = tmp.to!string;
			} else if(strcmp(key, "basever") == 0) {
				/* not used atm */
			} else if(strcmp(key, "pkgdesc") == 0) {
				STRDUP(tmp, ptr);
				newpkg.desc = tmp.to!string;
			} else if(strcmp(key, "group") == 0) {
				STRDUP(tmp, ptr);
				newpkg.groups.insertFront(tmp.to!string);
			} else if(strcmp(key, "url") == 0) {
				STRDUP(tmp, ptr);
				newpkg.url = tmp.to!string;
			} else if(strcmp(key, "license") == 0) {
				STRDUP(tmp, ptr);
				newpkg.licenses.insertFront(tmp.to!string);
			} else if(strcmp(key, "builddate") == 0) {
				newpkg.builddate = alpmParseDate(ptr.to!string);
			} else if(strcmp(key, "packager") == 0) {
				STRDUP(tmp, ptr);
				newpkg.packager = tmp.to!string;
			} else if(strcmp(key, "arch") == 0) {
				newpkg.arch = ptr.to!string;
			} else if(strcmp(key, "size") == 0) {
				/* size in the raw package is uncompressed (installed) size */
				newpkg.isize = alpmStrToOfft(ptr.to!string);
			} else if(strcmp(key, "depend") == 0) {
				AlpmDepend dep = alpm_dep_from_string(ptr);
				newpkg.depends.insertFront(dep);
			} else if(strcmp(key, "optdepend") == 0) {
				AlpmDepend optdep = alpm_dep_from_string(ptr);
				newpkg.optdepends.insertFront(optdep);
			} else if(strcmp(key, "makedepend") == 0) {
				AlpmDepend makedep = alpm_dep_from_string(ptr);
				newpkg.makedepends.insertFront(makedep);
			} else if(strcmp(key, "checkdepend") == 0) {
				AlpmDepend checkdep = alpm_dep_from_string(ptr);
				newpkg.checkdepends.insertFront(checkdep);
			} else if(strcmp(key, "conflict") == 0) {
				AlpmDepend conflict = alpm_dep_from_string(ptr);
				newpkg.conflicts.insertFront(conflict);
			} else if(strcmp(key, "replaces") == 0) {
				AlpmDepend replace = alpm_dep_from_string(ptr);
				newpkg.replaces.insertFront(replace);
			} else if(strcmp(key, "provides") == 0) {
				AlpmDepend provide = alpm_dep_from_string(ptr);
				newpkg.provides.insertFront(provide);
			} else if(strcmp(key, "backup") == 0) {
				AlpmBackup backup = new AlpmBackup(ptr.to!string);
				newpkg.backup.insertFront(backup);
			} else if(strcmp(key, "xdata") == 0) {
				AlpmPkgXData pd = AlpmPkgXData.parseFrom(ptr.to!string);
				if(!alpm_new_list_append(&newpkg.xdata, pd)) {
					return -1;
				}
			} else {
				  char*pkgname = cast(char*)(newpkg.name ? newpkg.name : "error") ;
				_alpm_log(handle, ALPM_LOG_WARNING, ("%s: unknown key '%s' in package description\n"), pkgname, key);
				logger.tracef("%s: unknown key '%s' in description file line %d\n",
									pkgname, key, linenum);
			}
		}
	}
	if(ret != ARCHIVE_EOF) {
		logger.tracef("error parsing package descfile\n");
		return -1;
	}

	return 0;
}

/**
 * Validate a package.
 * @param handle the context handle
 * @param pkgfile path to the package file
 * @param syncpkg package object to load verification data from (md5sum,
 * sha256sum, and/or base64 signature)
 * @param level the required level of signature verification
 * @param sigdata signature data from the package to pass back
 * @param validation successful validations performed on the package file
 * @return 0 if package is fully valid, -1 and pm_errno otherwise
 */
int _alpm_pkg_validate_internal(AlpmHandle handle,   char*pkgfile, AlpmPkg syncpkg, int level, alpm_siglist_t** sigdata, int* validation)
{
	int has_sig = void;
	handle.pm_errno = ALPM_ERR_OK;

	if(pkgfile == null || strlen(pkgfile) == 0) {
		RET_ERR(handle, ALPM_ERR_WRONG_ARGS, -1);
	}

	/* attempt to access the package file, ensure it exists */
	if(alpmAccess(handle, null, pkgfile.to!string, R_OK) != 0) {
		if(errno == ENOENT) {
			handle.pm_errno = ALPM_ERR_PKG_NOT_FOUND;
		} else if(errno == EACCES) {
			handle.pm_errno = ALPM_ERR_BADPERMS;
		} else {
			handle.pm_errno = ALPM_ERR_PKG_OPEN;
		}
		return -1;
	}

	/* can we get away with skipping checksums? */
	has_sig = 0;
	if(level & AlpmSigLevel.Package) {
		if(syncpkg && syncpkg.base64_sig) {
			has_sig = 1;
		} else {
			char* sigpath = _alpm_sigpath(handle, pkgfile);
			if(sigpath && !alpmAccess(handle, null, sigpath.to!string, R_OK)) {
				has_sig = 1;
			}
			free(sigpath);
		}
	}

	if(syncpkg && (!has_sig || !syncpkg.base64_sig)) {
		if(syncpkg.md5sum && !syncpkg.sha256sum) {
			logger.tracef("md5sum: %s\n", syncpkg.md5sum);
			logger.tracef("checking md5sum for %s\n", pkgfile);
			if(_alpm_test_checksum(pkgfile, cast(char*)syncpkg.md5sum, AlpmPkgValidation.MD5) != 0) {
				RET_ERR(handle, ALPM_ERR_PKG_INVALID_CHECKSUM, -1);
			}
			if(validation) {
				*validation |= AlpmPkgValidation.MD5;
			}
		}

		if(syncpkg.sha256sum) {
			logger.tracef("sha256sum: %s\n", syncpkg.sha256sum);
			logger.tracef("checking sha256sum for %s\n", pkgfile);
			if(_alpm_test_checksum(cast(char*)pkgfile, cast(char*)syncpkg.sha256sum, AlpmPkgValidation.SHA256) != 0) {
				RET_ERR(handle, ALPM_ERR_PKG_INVALID_CHECKSUM, -1);
			}
			if(validation) {
				*validation |= AlpmPkgValidation.SHA256;
			}
		}
	}

	/* even if we don't have a sig, run the check code if level tells us to */
	if(level & AlpmSigLevel.Package) {
		  char*sig = syncpkg ? cast(char*)syncpkg.base64_sig : null;
		logger.tracef("sig data: %s\n", sig ? sig : "<from .sig>");
		if(!has_sig && !(level & AlpmSigLevel.PackageOptional)) {
			handle.pm_errno = ALPM_ERR_PKG_MISSING_SIG;
			return -1;
		}
		if(_alpm_check_pgp_helper(handle, pkgfile, sig,
					level & AlpmSigLevel.PackageOptional, level & AlpmSigLevel.PackageMarginalOk,
					level & AlpmSigLevel.PackageUnknowOk, sigdata)) {
			handle.pm_errno = ALPM_ERR_PKG_INVALID_SIG;
			return -1;
		}
		if(validation && has_sig) {
			*validation |= AlpmPkgValidation.Signature;
		}
	}

	if(validation && !*validation) {
		*validation = AlpmPkgValidation.None;
	}

	return 0;
}

/**
 * Handle the existence of simple paths for _alpm_load_pkg_internal()
 * @param pkg package to change
 * @param path path to examine
 * @return 0 if path doesn't match any rule, 1 if it has been handled
 */
private int handle_simple_path(AlpmPkg pkg,   char*path)
{
	if(strcmp(path, ".INSTALL") == 0) {
		pkg.scriptlet = 1;
		return 1;
	} else if(*path == '.') {
		/* for now, ignore all files starting with '.' that haven't
		 * already been handled (for future possibilities) */
		return 1;
	}

	return 0;
}

/**
 * Add a file to the files list for pkg.
 *
 * @param pkg package to add the file to
 * @param files_size size of pkg->files.files
 * @param entry archive entry of the file to add to the list
 * @param path path of the file to be added
 * @return <0 on error, 0 on success
 */
private int add_entry_to_files_list(AlpmFileList filelist, size_t* files_size, archive_entry* entry,   char*path)
{
	size_t files_count = filelist.length;
	AlpmFile* current_file = void;
	mode_t type = void;
	size_t pathlen = void;

	filelist.length++;

	type = archive_entry_filetype(entry);

	pathlen = strlen(path);

	current_file = filelist.ptr + files_count;

	/* mtree paths don't contain a tailing slash, those we get from
	 * the archive directly do (expensive way)
	 * Other code relies on it to detect directories so add it here.*/
	if(type == AE_IFDIR && path[pathlen - 1] != '/') {
		/* 2 = 1 for / + 1 for \0 */
		char* newpath = void;
		MALLOC(newpath, pathlen + 2);
		strcpy(newpath, path);
		newpath[pathlen] = '/';
		newpath[pathlen + 1] = '\0';
		current_file.name = newpath.to!string;
	} else {
		current_file.name = path.to!string;
	}
	current_file.size = archive_entry_size(entry);
	current_file.mode = archive_entry_mode(entry);
	filelist.length++;
	return 0;
}

/**
 * Generate a new file list from an mtree file and add it to the package.
 * An existing file list will be free()d first.
 *
 * archive should point to an archive struct which is already at the
 * position of the mtree's header.
 *
 * @param handle
 * @param pkg package to add the file list to
 * @param archive archive containing the mtree
 * @return 0 on success, <0 on error
 */
private int build_filelist_from_mtree(AlpmHandle handle, AlpmPkg pkg, archive* _archive)
{
	int ret = 0;
	size_t i = void;
	size_t mtree_maxsize = 0;
	size_t mtree_cursize = 0;
	size_t files_size = 0; /* we clean up the existing array so this is fine */
	ubyte[] mtree_data;
	archive* mtree = void;
	archive_entry* mtree_entry = null;
	AlpmFileList filelist = [];

	_alpm_log(handle, ALPM_LOG_DEBUG,
			"found mtree for package %s, getting file list\n", pkg.filename);

	/* create a new archive to parse the mtree and load it from archive into memory */
	/* TODO: split this into a function */
	if((mtree = archive_read_new()) == null) {
		GOTO_ERR(handle, ALPM_ERR_LIBARCHIVE, "error");
	}

	_alpm_archive_read_support_filter_all(mtree);
	archive_read_support_format_mtree(mtree);

	/* TODO: split this into a function */
	while(1) {
		ssize_t size = void;

		mtree_data.length = mtree_cursize + ALPM_BUFFER_SIZE;

		size = archive_read_data(_archive, mtree_data.ptr + mtree_cursize, ALPM_BUFFER_SIZE);

		if(size < 0) {
			logger.tracef(("error while reading package %s: %s\n"),
					pkg.filename, archive_error_string(_archive));
			GOTO_ERR(handle, ALPM_ERR_LIBARCHIVE, "error");
		}
		if(size == 0) {
			break;
		}

		mtree_cursize += size;
	}

	if(archive_read_open_memory(mtree, mtree_data.ptr, mtree_cursize)) {
		_alpm_log(handle, ALPM_LOG_DEBUG,
				("error while reading mtree of package %s: %s\n"),
				pkg.filename, archive_error_string(mtree));
		GOTO_ERR(handle, ALPM_ERR_LIBARCHIVE, "error");
	}

	while((ret = archive_read_next_header(mtree, &mtree_entry)) == ARCHIVE_OK) {
		  char*path = cast(char*)archive_entry_pathname(mtree_entry);

		/* strip leading "./" from path entries */
		if(path[0] == '.' && path[1] == '/') {
			path += 2;
		}

		if(handle_simple_path(pkg, path)) {
			continue;
		}

		if(add_entry_to_files_list(filelist, &files_size, mtree_entry, path) < 0) {
			goto error;
		}
	}

	if(ret != ARCHIVE_EOF && ret != ARCHIVE_OK) { /* An error occurred */
		logger.tracef(("error while reading mtree of package %s: %s\n"),
				pkg.filename, archive_error_string(mtree));
		GOTO_ERR(handle, ALPM_ERR_LIBARCHIVE, "error");
	}

	/* throw away any files we loaded directly from the archive */
	for(i = 0; i < pkg.files.length; i++) {
		free(cast(char*)pkg.files[i].name);
	}
	free(pkg.files.ptr);

	/* copy over new filelist */
	memcpy(&pkg.files, &filelist, AlpmFileList.sizeof);

	free(mtree_data.ptr);
	_alpm_archive_read_free(mtree);
	logger.tracef("finished mtree reading for %s\n", pkg.filename);
	return 0;
error:
	/* throw away any files we loaded from the mtree */
	for(i = 0; i < filelist.length; i++) {
		free(cast(char*)filelist.ptr[i].name);
	}
	free(filelist.ptr);

	free(mtree_data.ptr);
	_alpm_archive_read_free(mtree);
	return -1;
}

/**
 * Load a package and create the corresponding alpm_pkg_t struct.
 * @param handle the context handle
 * @param pkgfile path to the package file
 * @param full whether to stop the load after metadata is read or continue
 * through the full archive
 */
AlpmPkg _alpm_pkg_load_internal(AlpmHandle handle,   char*pkgfile, int full)
{
	int ret = void, fd = void;
	int config = 0;
	int hit_mtree = 0;
	archive* archive = void;
	archive_entry* entry = void;
	AlpmPkg newpkg = void;
	stat_t st = void;
	size_t files_size = 0;

	if(pkgfile == null || strlen(pkgfile) == 0) {
		RET_ERR(handle, ALPM_ERR_WRONG_ARGS, 0);
	}

	fd = _alpm_open_archive(handle, pkgfile, &st, &archive, ALPM_ERR_PKG_OPEN);
	if(fd < 0) {
		if(errno == ENOENT) {
			handle.pm_errno = ALPM_ERR_PKG_NOT_FOUND;
		} else if(errno == EACCES) {
			handle.pm_errno = ALPM_ERR_BADPERMS;
		} else {
			handle.pm_errno = ALPM_ERR_PKG_OPEN;
		}
		return null;
	}

	newpkg = new AlpmPkg();
	if(newpkg is null) {
		GOTO_ERR(handle, ALPM_ERR_MEMORY, "error");
	}
	newpkg.filename = pkgfile.to!string;
	newpkg.size = st.st_size;

	logger.tracef("starting package load for %s\n", pkgfile);

	/* If full is false, only read through the archive until we find our needed
	 * metadata. If it is true, read through the entire archive, which serves
	 * as a verification of integrity and allows us to create the filelist. */
	while((ret = archive_read_next_header(archive, &entry)) == ARCHIVE_OK) {
		  char*entry_name = cast(char*)archive_entry_pathname(entry);;

		if(strcmp(entry_name, cast(char*)".PKGINFO") == 0) {
			/* parse the info file */
			if(parse_descfile(handle, archive, newpkg) != 0) {
				_alpm_log(handle, ALPM_LOG_ERROR, ("could not parse package description file in %s\n"),
						pkgfile);
				goto pkg_invalid;
			}
			if(newpkg.name == "") {
				_alpm_log(handle, ALPM_LOG_ERROR, ("missing package name in %s\n"), pkgfile);
				goto pkg_invalid;
			}
			if(newpkg.version_ == null || newpkg.version_.length == 0) {
				_alpm_log(handle, ALPM_LOG_ERROR, ("missing package version in %s\n"), pkgfile);
				goto pkg_invalid;
			}
			if(strchr(cast(char*)newpkg.version_, '-') == null) {
				_alpm_log(handle, ALPM_LOG_ERROR, ("invalid package version in %s\n"), pkgfile);
				goto pkg_invalid;
			}
			config = 1;
			continue;
		} else if(full && strcmp(entry_name, ".MTREE") == 0) {
			/* building the file list: cheap way
			 * get the filelist from the mtree file rather than scanning
			 * the whole archive  */
			hit_mtree = build_filelist_from_mtree(handle, newpkg, archive) == 0;
			continue;
		} else if(handle_simple_path(newpkg, entry_name)) {
			continue;
		} else if(full && !hit_mtree) {
			/* building the file list: expensive way */
			if(add_entry_to_files_list(newpkg.files, &files_size, entry, entry_name) < 0) {
				goto error;
			}
		}

		if(archive_read_data_skip(archive)) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("error while reading package %s: %s\n"),
					pkgfile, archive_error_string(archive));
			GOTO_ERR(handle, ALPM_ERR_LIBARCHIVE, "error");
		}

		/* if we are not doing a full read, see if we have all we need */
		if((!full || hit_mtree) && config) {
			break;
		}
	}

	if(ret != ARCHIVE_EOF && ret != ARCHIVE_OK) { /* An error occurred */
		_alpm_log(handle, ALPM_LOG_ERROR, ("error while reading package %s: %s\n"),
				pkgfile, archive_error_string(archive));
		GOTO_ERR(handle, ALPM_ERR_LIBARCHIVE, "error");
	}

	if(!config) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("missing package metadata in %s\n"), pkgfile);
		goto pkg_invalid;
	}

	/* internal fields for package struct */
	newpkg.origin = ALPM_PKG_FROM_FILE;
	newpkg.origin_data.file = pkgfile.to!string;
	// newpkg.ops = get_file_pkg_ops();
	newpkg.handle = handle;
	newpkg.infolevel =AlpmDBInfRq.Base | AlpmDBInfRq.Desc | AlpmDBInfRq.Scriptlet;
	newpkg.validation = AlpmPkgValidation.None;

	if(full) {
		if(newpkg.files.length > 0) {
			/* attempt to hand back any memory we don't need */
			/* "checking for conflicts" requires a sorted list, ensure that here */
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"sorting package filelist for %s\n", pkgfile);

			_alpm_filelist_sort(newpkg.files);
		}
		newpkg.infolevel |= AlpmDBInfRq.Files;
	}

	if(newpkg.checkMeta() != 0) {
		goto pkg_invalid;
	}

	_alpm_archive_read_free(archive);
	close(fd);
	return newpkg;

pkg_invalid:
	handle.pm_errno = ALPM_ERR_PKG_INVALID;
error:
	destroy!false(newpkg);
	_alpm_archive_read_free(archive);
	close(fd);

	return null;
}

/* adopted limit from repo-add */
enum MAX_SIGFILE_SIZE = 16384;

private int read_sigfile(  char*sigpath, ubyte** sig)
{
	stat_t st = void;
	FILE* fp = void;

	if((fp = fopen(sigpath, "rb")) == null) {
		return -1;
	}

	if(fstat(fileno(fp), &st) != 0 || st.st_size > MAX_SIGFILE_SIZE) {
		fclose(fp);
		return -1;
	}

	MALLOC(*sig, st.st_size);

	if(fread(*sig, st.st_size, 1, fp) != 1) {
		free(*sig);
		fclose(fp);
		return -1;
	}

	fclose(fp);
	return cast(int)st.st_size;
}

int  alpm_pkg_load(AlpmHandle handle,   char*filename, int full, int level, AlpmPkg* pkg)
{
	int validation = 0;
	char* sigpath = void;
	AlpmPkg pkg_temp = void;

	//ASSERT(pkg != null);

	sigpath = _alpm_sigpath(handle, filename);
	if(sigpath && !alpmAccess(handle, null, sigpath.to!string, R_OK)) {
		if(level & AlpmSigLevel.Package) {
			alpm_list_t* keys = null;
			int fail = 0;
			ubyte* sig = null;
			int len = read_sigfile(sigpath, &sig);

			if(len == -1) {
				_alpm_log(handle, ALPM_LOG_ERROR,
					("failed to read signature file: %s\n"), sigpath);
				free(sigpath);
				return -1;
			}

			if(alpm_extract_keyid(handle, filename, sig, len, &keys) == 0) {
				alpm_list_t* k = void;
				for(k = keys; k; k = k.next) {
					char* key = cast(char*)k.data;
					if(_alpm_key_in_keychain(handle, key) == 0) {
						pkg_temp = _alpm_pkg_load_internal(handle, filename, full);
						if(_alpm_key_import(handle, null, key) == -1) {
							fail = 1;
						}
						destroy!false(pkg_temp);
					}
				}
				FREELIST(keys);
			}

			free(sig);

			if(fail) {
				_alpm_log(handle, ALPM_LOG_ERROR, ("required key missing from keyring\n"));
				free(sigpath);
				return -1;
			}
		}
	}
	free(sigpath);

	if(_alpm_pkg_validate_internal(handle, filename, null, level, null,
				&validation) == -1) {
		/* pm_errno is set by pkg_validate */
		return -1;
	}
	*pkg = _alpm_pkg_load_internal(handle, filename, full);
	if(*pkg is null) {
		/* pm_errno is set by pkg_load */
		return -1;
	}
	(*pkg).validation = validation;

	return 0;
}
