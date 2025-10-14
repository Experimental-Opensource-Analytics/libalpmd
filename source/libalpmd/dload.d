module dload.c;
@nogc nothrow:
extern(C): __gshared:
import core.stdc.config: c_long, c_ulong;
/*
 *  dload.c
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

import stdbool;
import core.stdc.stdlib;
import core.stdc.stdio;
import core.stdc.errno;
import core.stdc.string;
import core.sys.posix.unistd;
import core.sys.posix.sys.socket; /* setsockopt, SO_KEEPALIVE */
import core.sys.posix.sys.time;
import core.sys.posix.sys.types;
import core.sys.posix.sys.stat;
import core.sys.posix.sys.wait;
import core.stdc.signal;
import core.sys.posix.dirent;
import core.sys.posix.pwd;

version (HAVE_NETINET_IN_H) {
import netinet/in; /* IPPROTO_TCP */
}
version (HAVE_NETINET_TCP_H) {
import netinet/tcp; /* TCP_KEEPINTVL, TCP_KEEPIDLE */
}

version (HAVE_LIBCURL) {
import curl/curl;
}

/* libalpm */
import dload;
import alpm_list;
import alpm;
import log;
import util;
import handle;
import sandbox;


private const(char)* get_filename(const(char)* url)
{
	char* filename = strrchr(url, '/');
	if(filename != null) {
		return filename + 1;
	}

	/* no slash found, it's a filename */
	return url;
}

/* prefix to avoid possible future clash with getumask(3) */
private mode_t _getumask()
{
	mode_t mask = umask(0);
	umask(mask);
	return mask;
}

private int finalize_download_file(const(char)* filename)
{
	stat st = void;
	uid_t myuid = getuid();
	ASSERT(filename != null, return -1);
	ASSERT(stat(filename, &st) == 0, return -1);
	if(st.st_size == 0) {
		unlink(filename);
                return 1;
	}
	if(myuid == 0) {
		ASSERT(chown(filename, 0, 0) != -1, return -1);
	}
	ASSERT(chmod(filename, ~cast(_getumask) & 0666) != -1, return -1);
	return 0;
}

private FILE* create_tempfile(dload_payload* payload, const(char)* localpath)
{
	int fd = void;
	FILE* fp = void;
	char* randpath = void;
	size_t len = void;

	/* create a random filename, which is opened with O_EXCL */
	len = strlen(localpath) + 14 + 1;
	MALLOC(randpath, len);
	snprintf(randpath, len, "%salpmtmp.XXXXXX", localpath);
	if((fd = mkstemp(randpath)) == -1 ||
			fchmod(fd, ~cast(_getumask) & 0666) ||
			((fp = fdopen(fd, payload.tempfile_openmode)) == 0)) {
		unlink(randpath);
		close(fd);
		_alpm_log(payload.handle, ALPM_LOG_ERROR,
				_("failed to create temporary file for download\n"));
		free(randpath);
		return null;
	}
	/* fp now points to our alpmtmp.XXXXXX */
	free(payload.tempfile_name);
	payload.tempfile_name = randpath;
	free(payload.remote_name);
	STRDUP(payload.remote_name, strrchr(randpath, '/') + 1,
			fclose(fp); RET_ERR(payload.handle, ALPM_ERR_MEMORY, null));

	return fp;
}


version (HAVE_LIBCURL) {

/* RFC1123 states applications should support this length */
enum HOSTNAME_SIZE = 256;




/* number of "soft" errors required to blacklist a server, set to 0 to disable
 * server blacklisting */
const(int) server_error_limit = 3;

struct server_error_count {
	char[HOSTNAME_SIZE] server = 0;
	int errors;
}

private server_error_count* find_server_errors(alpm_handle_t* handle, const(char)* server)
{
	alpm_list_t* i = void;
	server_error_count* h = void;
	char[HOSTNAME_SIZE] hostname = void;
	/* key off the hostname because a host may serve multiple repos under
	 * different url's and errors are likely to be host-wide */
	if(curl_gethost(server.ptr, hostname.ptr, hostname.sizeof) != 0) {
		return null;
	}
	for(i = handle.server_errors; i; i = i.next) {
		h = i.data;
		if(strcmp(hostname.ptr, h.server) == 0) {
			return h;
		}
	}
	if((h = cast(server_error_count*) calloc(server_error_count.sizeof, 1))
			&& alpm_list_append(&handle.server_errors, h)) {
		strcpy(h.server, hostname.ptr);
		h.errors = 0;
		return h;
	} else {
		free(h);
		return null;
	}
}

/* skip for hard errors or too many soft errors */
private int should_skip_server(alpm_handle_t* handle, const(char)* server)
{
	server_error_count* h = void;
	if(server_error_limit && (h = find_server_errors(handle, server.ptr)) ) {
		return h.errors < 0 || h.errors >= server_error_limit;
	}
	return 0;
}

/* only skip for hard errors */
private int should_skip_cache_server(alpm_handle_t* handle, const(char)* server)
{
	server_error_count* h = void;
	if(server_error_limit && (h = find_server_errors(handle, server.ptr)) ) {
		return h.errors < 0;
	}
	return 0;
}

/* block normal servers after too many errors */
private void server_soft_error(alpm_handle_t* handle, const(char)* server)
{
	server_error_count* h = void;
	if(server_error_limit
			&& (h = find_server_errors(handle, server.ptr))
			&& !should_skip_server(handle, server.ptr) ) {
		h.errors++;

		if(should_skip_server(handle, server.ptr)) {
			_alpm_log(handle, ALPM_LOG_WARNING,
					_("too many errors from %s, skipping for the remainder of this transaction\n"),
					h.server);
		}
	}
}

/* immediate block for both servers and cache servers */
private void server_hard_error(alpm_handle_t* handle, const(char)* server)
{
	server_error_count* h = void;
	if(server_error_limit && (h = find_server_errors(handle, server.ptr))) {
		if(h.errors != -1) {
			/* always set even if already skipped for soft errors
			 * to disable cache servers too */
			h.errors = -1;

			_alpm_log(handle, ALPM_LOG_WARNING,
					_("fatal error from %s, skipping for the remainder of this transaction\n"),
					h.server);
		}
	}
}

private const(char)* payload_next_server(dload_payload* payload)
{
	while(payload.cache_servers
			&& should_skip_cache_server(payload.handle, payload.cache_servers.data)) {
		payload.cache_servers = payload.cache_servers.next;
	}
	if(payload.cache_servers) {
		const(char)* server = payload.cache_servers.data;
		payload.cache_servers = payload.cache_servers.next;
		payload.request_errors_ok = 1;
		return server;
	}
	while(payload.servers
			&& should_skip_server(payload.handle, payload.servers.data)) {
		payload.servers = payload.servers.next;
	}
	if(payload.servers) {
		const(char)* server = payload.servers.data;
		payload.servers = payload.servers.next;
		payload.request_errors_ok = payload.errors_ok;
		return server;
	}
	return null;
}

enum {
	ABORT_OVER_MAXFILESIZE = 1,
}

private int dload_interrupted;

private int dload_progress_cb(void* file, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t UNUSED)
{
	dload_payload* payload = cast(dload_payload*)file;
	off_t current_size = void, total_size = void;
	alpm_download_event_progress_t cb_data = {0};

	/* avoid displaying progress bar for redirects with a body */
	if(payload.respcode >= 300) {
		return 0;
	}

	/* SIGINT sent, abort by alerting curl */
	if(dload_interrupted) {
		return 1;
	}

	if(dlnow < 0 || dltotal <= 0 || dlnow > dltotal) {
		/* bogus values : stop here */
		return 0;
	}

	current_size = payload.initial_size + dlnow;

	/* is our filesize still under any set limit? */
	if(payload.max_size && current_size > payload.max_size) {
		dload_interrupted = ABORT_OVER_MAXFILESIZE;
		return 1;
	}

	/* none of what follows matters if the front end has no callback */
	if(payload.handle.dlcb == null) {
		return 0;
	}

	total_size = payload.initial_size + dltotal;

	if(payload.prevprogress == total_size) {
		return 0;
	}

	/* do NOT include initial_size since it wasn't part of the package's
	 * download_size (nor included in the total download size callback) */
	cb_data.total = dltotal;
	cb_data.downloaded = dlnow;
	payload.handle.dlcb(payload.handle.dlcb_ctx,
			payload.remote_name, ALPM_DOWNLOAD_PROGRESS, &cb_data);
	payload.prevprogress = current_size;

	return 0;
}

private int curl_gethost(const(char)* url, char* buffer, size_t buf_len)
{
	size_t hostlen = void;
	char* p = void, q = void;

	if(strncmp(url, "file://", 7) == 0) {
		p = _("disk");
		hostlen = strlen(p);
	} else {
		p = strstr(url, "//");
		if(!p) {
			return 1;
		}
		p += 2; /* jump over the found // */
		hostlen = strcspn(p, "/");

		/* there might be a user:pass@ on the URL. hide it. avoid using memrchr()
		 * for portability concerns. */
		q = p + hostlen;
		while(--q > p) {
			if(*q == '@') {
				break;
			}
		}
		if(*q == '@' && p != q) {
			hostlen -= q - p + 1;
			p = q + 1;
		}
	}

	if(hostlen > buf_len - 1) {
		/* buffer overflow imminent */
		return 1;
	}
	memcpy(buffer, p, hostlen);
	buffer[hostlen] = '\0';

	return 0;
}

private int utimes_long(const(char)* path, c_long seconds)
{
	if(seconds != -1) {
		timeval[2] tv = [
			{ tv_sec: seconds, },
			{ tv_sec: seconds, },
		];
		return utimes(path, tv.ptr);
	}
	return 0;
}

private size_t dload_parseheader_cb(void* ptr, size_t size, size_t nmemb, void* user)
{
	size_t realsize = size * nmemb;
	dload_payload* payload = cast(dload_payload*)user;
	c_long respcode = void;
	cast(void) ptr;

	curl_easy_getinfo(payload.curl, CURLINFO_RESPONSE_CODE, &respcode);
	if(payload.respcode != respcode) {
		payload.respcode = respcode;
	}

	return realsize;
}

private void curl_set_handle_opts(CURL* curl, dload_payload* payload)
{
	alpm_handle_t* handle = payload.handle;
	const(char)* useragent = getenv("HTTP_USER_AGENT");
	stat st = void;

	/* the curl_easy handle is initialized with the alpm handle, so we only need
	 * to reset the handle's parameters for each time it's used. */
	curl_easy_reset(curl);
	curl_easy_setopt(curl, CURLOPT_URL, payload.fileurl);
	curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, payload.error_buffer);
	curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
	curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 10L);
	curl_easy_setopt(curl, CURLOPT_FILETIME, 1L);
	curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
	curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
	curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, &dload_progress_cb);
	curl_easy_setopt(curl, CURLOPT_XFERINFODATA, cast(void*)payload);
	if(!handle.disable_dl_timeout) {
		curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
		curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 10L);
	}
	curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, &dload_parseheader_cb);
	curl_easy_setopt(curl, CURLOPT_HEADERDATA, cast(void*)payload);
	curl_easy_setopt(curl, CURLOPT_NETRC, CURL_NETRC_OPTIONAL);
	curl_easy_setopt(curl, CURLOPT_TCP_KEEPALIVE, 1L);
	curl_easy_setopt(curl, CURLOPT_TCP_KEEPIDLE, 60L);
	curl_easy_setopt(curl, CURLOPT_TCP_KEEPINTVL, 60L);
	curl_easy_setopt(curl, CURLOPT_HTTPAUTH, CURLAUTH_ANY);
	curl_easy_setopt(curl, CURLOPT_PRIVATE, cast(void*)payload);

	_alpm_log(handle, ALPM_LOG_DEBUG, "%s: url is %s\n",
		payload.remote_name, payload.fileurl);

	if(payload.max_size) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "%s: maxsize %jd\n",
				payload.remote_name, cast(intmax_t)payload.max_size);
		curl_easy_setopt(curl, CURLOPT_MAXFILESIZE_LARGE,
				cast(curl_off_t)payload.max_size);
	}

	if(useragent != null) {
		curl_easy_setopt(curl, CURLOPT_USERAGENT, useragent);
	}

	if(!payload.force && payload.mtime_existing_file) {
		/* start from scratch, but only download if our local is out of date. */
		curl_easy_setopt(curl, CURLOPT_TIMECONDITION, CURL_TIMECOND_IFMODSINCE);
		curl_easy_setopt(curl, CURLOPT_TIMEVALUE, payload.mtime_existing_file);
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"%s: using time condition %ld\n",
				payload.remote_name, cast(c_long)payload.mtime_existing_file);
	} else if(stat(payload.tempfile_name, &st) == 0 && payload.allow_resume) {
		/* a previous partial download exists, resume from end of file. */
		payload.tempfile_openmode = "ab";
		curl_easy_setopt(curl, CURLOPT_RESUME_FROM_LARGE, cast(curl_off_t)st.st_size);
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"%s: tempfile found, attempting continuation from %jd bytes\n",
				payload.remote_name, cast(intmax_t)st.st_size);
		payload.initial_size = st.st_size;
	}
}

/* Return 0 if retry was successful, -1 otherwise */
private int curl_retry_next_server(CURLM* curlm, CURL* curl, dload_payload* payload)
{
	const(char)* server = null;
	size_t len = void;
	stat st = void;
	alpm_handle_t* handle = payload.handle;

	if((server = payload_next_server(payload)) == null) {
		_alpm_log(payload.handle, ALPM_LOG_DEBUG,
				"%s: no more servers to retry\n", payload.remote_name);
		return -1;
	}

	/* regenerate a new fileurl */
	FREE(payload.fileurl);
	len = strlen(server) + strlen(payload.filepath) + 2;
	MALLOC(payload.fileurl, len);
	snprintf(payload.fileurl, len, "%s/%s", server, payload.filepath);
	_alpm_log(handle, ALPM_LOG_DEBUG,
			"%s: retrying from %s\n",
			payload.remote_name, payload.fileurl);

	fflush(payload.localf);

	if(payload.allow_resume && stat(payload.tempfile_name, &st) == 0) {
		/* a previous partial download exists, resume from end of file. */
		payload.tempfile_openmode = "ab";
		curl_easy_setopt(curl, CURLOPT_RESUME_FROM_LARGE, cast(curl_off_t)st.st_size);
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"%s: tempfile found, attempting continuation from %jd bytes\n",
				payload.remote_name, cast(intmax_t)st.st_size);
		payload.initial_size = st.st_size;
	} else {
		/* we keep the file for a new retry but remove its data if any */
		if(ftruncate(fileno(payload.localf), 0)) {
			RET_ERR(handle, ALPM_ERR_SYSTEM, -1);
		}
		fseek(payload.localf, 0, SEEK_SET);
	}

	if(handle.dlcb) {
		alpm_download_event_retry_t cb_data = void;
		cb_data.resume = payload.allow_resume;
		handle.dlcb(handle.dlcb_ctx, payload.remote_name, ALPM_DOWNLOAD_RETRY, &cb_data);
	}

	/* Set curl with the new URL */
	curl_easy_setopt(curl, CURLOPT_URL, payload.fileurl);

	curl_multi_remove_handle(curlm, curl);
	curl_multi_add_handle(curlm, curl);

	return 0;
}

/* Returns 2 if download retry happened
 * Returns 1 if the file is up-to-date
 * Returns 0 if current payload is completed successfully
 * Returns -1 if an error happened for a required file
 * Returns -2 if an error happened for an optional file
 */
private int curl_check_finished_download(alpm_handle_t* handle, CURLM* curlm, CURLMsg* msg, int* active_downloads_num)
{
	dload_payload* payload = null;
	CURL* curl = msg.easy_handle;
	CURLcode curlerr = void;
	char* effective_url = void;
	c_long timecond = void;
	curl_off_t remote_size = void;
	curl_off_t bytes_dl = 0;
	c_long remote_time = -1;
	stat st = void;
	char[HOSTNAME_SIZE] hostname = void;
	int ret = -1;

	curlerr = curl_easy_getinfo(curl, CURLINFO_PRIVATE, &payload);
	ASSERT(curlerr == CURLE_OK, RET_ERR(handle, ALPM_ERR_LIBCURL, -1));

	curl_gethost(payload.fileurl, hostname.ptr, hostname.sizeof);
	curlerr = msg.data.result;
	_alpm_log(handle, ALPM_LOG_DEBUG, "%s: %s returned result %d from transfer\n",
			payload.remote_name, "curl", curlerr);

	/* was it a success? */
	switch(curlerr) {
		case CURLE_OK:
			/* get http/ftp response code */
			_alpm_log(handle, ALPM_LOG_DEBUG, "%s: response code %ld\n",
					payload.remote_name, payload.respcode);
			if(payload.respcode >= 400) {
				if(!payload.request_errors_ok) {
					handle.pm_errno = ALPM_ERR_RETRIEVE;
					/* non-translated message is same as libcurl */
					snprintf(payload.error_buffer, typeof(payload.error_buffer).sizeof,
							"The requested URL returned error: %ld", payload.respcode);
					_alpm_log(handle, ALPM_LOG_ERROR,
							_("failed retrieving file '%s' from %s : %s\n"),
							payload.remote_name, hostname.ptr, payload.error_buffer);
					server_soft_error(handle, payload.fileurl);
				}

				fflush(payload.localf);
				if(fstat(fileno(payload.localf), &st) == 0 && st.st_size != payload.initial_size) {
					/* an html error page was written to the file, reset it */
					if(ftruncate(fileno(payload.localf), payload.initial_size)) {
						RET_ERR(handle, ALPM_ERR_SYSTEM, -1);
					}
					fseek(payload.localf, payload.initial_size, SEEK_SET);
				}

				if(curl_retry_next_server(curlm, curl, payload) == 0) {
					(*active_downloads_num)++;
					return 2;
				} else {
					payload.unlink_on_fail = 1;
					goto cleanup;
				}
			}
			break;
		case CURLE_ABORTED_BY_CALLBACK:
			/* handle the interrupt accordingly */
			if(dload_interrupted == ABORT_OVER_MAXFILESIZE) {
				curlerr = CURLE_FILESIZE_EXCEEDED;
				payload.unlink_on_fail = 1;
				handle.pm_errno = ALPM_ERR_LIBCURL;
				_alpm_log(handle, ALPM_LOG_ERROR,
						_("failed retrieving file '%s' from %s : expected download size exceeded\n"),
						payload.remote_name, hostname.ptr);
				server_soft_error(handle, payload.fileurl);
			}
			goto cleanup;
		case CURLE_COULDNT_RESOLVE_HOST:
			handle.pm_errno = ALPM_ERR_SERVER_BAD_URL;
			_alpm_log(handle, ALPM_LOG_ERROR,
					_("failed retrieving file '%s' from %s : %s\n"),
					payload.remote_name, hostname.ptr, payload.error_buffer);
			server_hard_error(handle, payload.fileurl);
			if(curl_retry_next_server(curlm, curl, payload) == 0) {
				(*active_downloads_num)++;
				return 2;
			} else {
				goto cleanup;
			}
		default:
			if(!payload.request_errors_ok) {
				handle.pm_errno = ALPM_ERR_LIBCURL;
				_alpm_log(handle, ALPM_LOG_ERROR,
						_("failed retrieving file '%s' from %s : %s\n"),
						payload.remote_name, hostname.ptr, payload.error_buffer);
				server_soft_error(handle, payload.fileurl);
			} else {
				_alpm_log(handle, ALPM_LOG_DEBUG,
						"failed retrieving file '%s' from %s : %s\n",
						payload.remote_name, hostname.ptr, payload.error_buffer);
			}
			if(curl_retry_next_server(curlm, curl, payload) == 0) {
				(*active_downloads_num)++;
				return 2;
			} else {
				/* delete zero length downloads */
				if(fstat(fileno(payload.localf), &st) == 0 && st.st_size == 0) {
					payload.unlink_on_fail = 1;
				}
				goto cleanup;
			}
	}

	/* retrieve info about the state of the transfer */
	curl_easy_getinfo(curl, CURLINFO_FILETIME, &remote_time);
	curl_easy_getinfo(curl, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &remote_size);
	curl_easy_getinfo(curl, CURLINFO_SIZE_DOWNLOAD_T, &bytes_dl);
	curl_easy_getinfo(curl, CURLINFO_CONDITION_UNMET, &timecond);
	curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effective_url);

	/* Let's check if client requested downloading accompanion *.sig file */
	if(!payload.signature && payload.download_signature && curlerr == CURLE_OK && payload.respcode < 400) {
		dload_payload* sig = null;
		char* url = payload.fileurl;
		char* _effective_filename = void;
		const(char)* effective_filename = void;
		char* query = void;
		const(char)* dbext = alpm_option_get_dbext(handle);
		const(char)* realname = payload.destfile_name ? payload.destfile_name : payload.tempfile_name;
		int len = void;

		STRDUP(_effective_filename, effective_url, GOTO_ERR(handle, ALPM_ERR_MEMORY, cleanup));
		effective_filename = get_filename(_effective_filename);
		query = strrchr(effective_filename, '?');

		if(query) {
			query[0] = '\0';
		}

		/* Only use the effective url for sig downloads if the effective_url contains .dbext or .pkg */
		if(strstr(effective_filename, dbext) || strstr(effective_filename, ".pkg")) {
			url = effective_url;
		}

		free(_effective_filename);

		len = strlen(url) + 5;
		CALLOC(sig, 1, typeof(*sig).sizeof, GOTO_ERR(handle, ALPM_ERR_MEMORY, cleanup));
		MALLOC(sig.fileurl, len);
		snprintf(sig.fileurl, len, "%s.sig", url);

		int remote_name_len = strlen(payload.remote_name) + 5;
		MALLOC(sig.remote_name, remote_name_len);
		snprintf(sig.remote_name, remote_name_len, "%s.sig", payload.remote_name);

		/* force the filename to be realname + ".sig" */
		int destfile_name_len = strlen(realname) + 5;
		MALLOC(sig.destfile_name, destfile_name_len);
		snprintf(sig.destfile_name, destfile_name_len, "%s.sig", realname);

		int tempfile_name_len = strlen(realname) + 10;
		MALLOC(sig.tempfile_name, tempfile_name_len);
		snprintf(sig.tempfile_name, tempfile_name_len, "%s.sig.part", realname);


		sig.signature = 1;
		sig.handle = handle;
		sig.force = payload.force;
		sig.unlink_on_fail = payload.unlink_on_fail;
		sig.errors_ok = payload.signature_optional;
		/* set hard upper limit of 16KiB */
		sig.max_size = 16 * 1024;

		curl_add_payload(handle, curlm, sig);
		(*active_downloads_num)++;
	}

	/* time condition was met and we didn't download anything. we need to
	 * clean up the 0 byte .part file that's left behind. */
	if(timecond == 1 && bytes_dl == 0) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "%s: file met time condition\n",
			payload.remote_name);
		ret = 1;
		unlink(payload.tempfile_name);
		goto cleanup;
	}

	/* remote_size isn't necessarily the full size of the file, just what the
	 * server reported as remaining to download. compare it to what curl reported
	 * as actually being transferred during curl_easy_perform() */
	if(remote_size != -1 && bytes_dl != -1 &&
			bytes_dl != remote_size) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("%s appears to be truncated: %jd/%jd bytes\n"),
				payload.remote_name, cast(intmax_t)bytes_dl, cast(intmax_t)remote_size);
		GOTO_ERR(handle, ALPM_ERR_RETRIEVE, cleanup);
	}

	ret = 0;

cleanup:
	/* disconnect relationships from the curl handle for things that might go out
	 * of scope, but could still be touched on connection teardown. This really
	 * only applies to FTP transfers. */
	curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 1L);
	curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, cast(char*)null);
	if(payload.localf != null) {
		fclose(payload.localf);
		payload.localf = null;
		utimes_long(payload.tempfile_name, remote_time);
	}

	if(ret == 0) {
		if(payload.destfile_name) {
			if(rename(payload.tempfile_name, payload.destfile_name)) {
				_alpm_log(handle, ALPM_LOG_ERROR, _("could not rename %s to %s (%s)\n"),
						payload.tempfile_name, payload.destfile_name, strerror(errno));
				ret = -1;
			}
		}
	}

	if((ret == -1 || dload_interrupted) && payload.unlink_on_fail &&
			payload.tempfile_name) {
		unlink(payload.tempfile_name);
	}

	if(handle.dlcb) {
		alpm_download_event_completed_t cb_data = {0};
		cb_data.total = bytes_dl;
		cb_data.result = ret;
		handle.dlcb(handle.dlcb_ctx, payload.remote_name, ALPM_DOWNLOAD_COMPLETED, &cb_data);
	}

	curl_multi_remove_handle(curlm, curl);
	curl_easy_cleanup(curl);
	payload.curl = null;

	FREE(payload.fileurl);

	if(ret == -1 && payload.errors_ok) {
		ret = -2;
	}

	if(payload.signature) {
		/* free signature payload memory that was allocated earlier in dload.c */
		_alpm_dload_payload_reset(payload);
		FREE(payload);
	}

	return ret;
}

/* Returns 0 in case if a new download transaction has been successfully started
 * Returns -1 if am error happened while starting a new download
 */
private int curl_add_payload(alpm_handle_t* handle, CURLM* curlm, dload_payload* payload)
{
	size_t len = void;
	CURL* curl = null;
	char[HOSTNAME_SIZE] hostname = void;
	int ret = -1;

	curl = curl_easy_init();
	payload.curl = curl;

	if(payload.fileurl) {
		ASSERT(!payload.servers, GOTO_ERR(handle, ALPM_ERR_WRONG_ARGS, cleanup));
		ASSERT(!payload.filepath, GOTO_ERR(handle, ALPM_ERR_WRONG_ARGS, cleanup));
		payload.request_errors_ok = payload.errors_ok;
	} else {
		const(char)* server = payload_next_server(payload);

		ASSERT(server, GOTO_ERR(handle, ALPM_ERR_SERVER_NONE, cleanup));
		ASSERT(payload.filepath, GOTO_ERR(handle, ALPM_ERR_WRONG_ARGS, cleanup));

		len = strlen(server) + strlen(payload.filepath) + 2;
		MALLOC(payload.fileurl, len, GOTO_ERR(handle, ALPM_ERR_MEMORY, cleanup));
		snprintf(payload.fileurl, len, "%s/%s", server, payload.filepath);
	}

	payload.tempfile_openmode = "wb";
	if(curl_gethost(payload.fileurl, hostname.ptr, hostname.sizeof) != 0) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("url '%s' is invalid\n"), payload.fileurl);
		GOTO_ERR(handle, ALPM_ERR_SERVER_BAD_URL, cleanup);
	}

	curl_set_handle_opts(curl, payload);

	if(payload.max_size == payload.initial_size && payload.max_size != 0) {
		/* .part file is complete */
		ret = 0;
		goto cleanup;
	}

	if(payload.localf == null) {
		payload.localf = fopen(payload.tempfile_name, payload.tempfile_openmode);
		if(payload.localf == null) {
			_alpm_log(handle, ALPM_LOG_ERROR,
					_("could not open file %s: %s\n"),
					payload.tempfile_name, strerror(errno));
			GOTO_ERR(handle, ALPM_ERR_RETRIEVE, cleanup);
		}
	}

	_alpm_log(handle, ALPM_LOG_DEBUG,
			"%s: opened tempfile for download: %s (%s)\n",
			payload.remote_name,
			payload.tempfile_name,
			payload.tempfile_openmode);

	curl_easy_setopt(curl, CURLOPT_WRITEDATA, payload.localf);
	curl_multi_add_handle(curlm, curl);

	if(handle.dlcb) {
		alpm_download_event_init_t cb_data = {optional: payload.errors_ok};
		handle.dlcb(handle.dlcb_ctx, payload.remote_name, ALPM_DOWNLOAD_INIT, &cb_data);
	}

	return 0;

cleanup:
	curl_easy_cleanup(curl);
	return ret;
}

/*
 * Use to sort payloads by max size in descending order (largest -> smallest)
 */
private int compare_dload_payload_sizes(const(void)* left_ptr, const(void)* right_ptr)
{
	dload_payload* left = void, right = void;

	left = cast(dload_payload*) left_ptr;
	right = cast(dload_payload*) right_ptr;

	return right.max_size - left.max_size;
}

/* Returns -1 if an error happened for a required file
 * Returns 0 if a payload was actually downloaded
 * Returns 1 if no files were downloaded and all errors were non-fatal
 */
private int curl_download_internal(alpm_handle_t* handle, alpm_list_t* payloads)
{
	int active_downloads_num = 0;
	int err = 0;
	int max_streams = handle.parallel_downloads;
	int updated = 0; /* was a file actually updated */
	CURLM* curlm = handle.curlm;
	size_t payloads_size = alpm_list_count(payloads);
	alpm_list_t* p = void;

	/* Sort payloads by package size */
	payloads = alpm_list_copy(payloads);
	payloads = alpm_list_msort(payloads, payloads_size, &compare_dload_payload_sizes);
	p = payloads;

	while(active_downloads_num > 0 || p) {
		CURLMcode mc = void;

		for(; active_downloads_num < max_streams && p; active_downloads_num++) {
			dload_payload* payload = p.data;

			if(curl_add_payload(handle, curlm, payload) == 0) {
				p = p.next;
			} else {
				/* The payload failed to start. Do not start any new downloads.
				 * Wait until all active downloads complete.
				 */
				_alpm_log(handle, ALPM_LOG_ERROR, _("failed to setup a download payload for %s\n"), payload.remote_name);
				p = null;
				err = -1;
			}
		}

		mc = curl_multi_perform(curlm, &active_downloads_num);
		if(mc == CURLM_OK) {
			mc = curl_multi_wait(curlm, null, 0, 1000, null);
		}

		if(mc != CURLM_OK) {
			_alpm_log(handle, ALPM_LOG_ERROR, _("curl returned error %d from transfer\n"), mc);
			p = null;
			err = -1;
		}
		while(true) {
			int msgs_left = 0;
			CURLMsg* msg = curl_multi_info_read(curlm, &msgs_left);
			if(!msg) {
				break;
			}
			if(msg.msg == CURLMSG_DONE) {
				int ret = curl_check_finished_download(handle, curlm, msg,
						&active_downloads_num);
				if(ret == -1) {
					/* if current payload failed to download then stop adding new payloads but wait for the
					 * current ones
					 */
					p = null;
					err = -1;
				} else if(ret == 0) {
					updated = 1;
				}
			} else {
				_alpm_log(handle, ALPM_LOG_ERROR, _("curl transfer error: %d\n"), msg.msg);
			}
		}
	}
	int ret = err ? -1 : updated ? 0 : 1;
	_alpm_log(handle, ALPM_LOG_DEBUG, "curl_download_internal return code is %d\n", ret);
	alpm_list_free(payloads);
	return ret;
}

/* Download the requested files by launching a process inside a sandbox.
 * Returns -1 if an error happened for a required file
 * Returns 0 if a payload was actually downloaded
 * Returns 1 if no files were downloaded and all errors were non-fatal
 */
private int curl_download_internal_sandboxed(alpm_handle_t* handle, alpm_list_t* payloads, const(char)* localpath, int* childsig)
{
	int pid = void, err = 0, ret = -1; int[2] callbacks_fd = void;
	sigset_t oldblock = void;
	sigaction sa_ign = { sa_handler: SIG_IGN }, oldint = void, oldquit = void;
	_alpm_sandbox_callback_context callbacks_ctx = void;

	sigemptyset(&sa_ign.sa_mask);

	if(pipe(callbacks_fd.ptr) != 0) {
		return -1;
	}

	sigaction(SIGINT, &sa_ign, &oldint);
	sigaction(SIGQUIT, &sa_ign, &oldquit);
	sigaddset(&sa_ign.sa_mask, SIGCHLD);
	sigprocmask(SIG_BLOCK, &sa_ign.sa_mask, &oldblock);

	pid = fork();
	if(pid == -1) {
		/* fork failed, make sure errno is preserved after cleanup */
		err = errno;
	}

	/* child */
	if(pid == 0) {
		close(callbacks_fd[0]);
		fcntl(callbacks_fd[1], F_SETFD, FD_CLOEXEC);
		callbacks_ctx.callback_pipe = callbacks_fd[1];
		alpm_option_set_logcb(handle, _alpm_sandbox_cb_log, &callbacks_ctx);
		alpm_option_set_dlcb(handle, _alpm_sandbox_cb_dl, &callbacks_ctx);
		alpm_option_set_fetchcb(handle, null, null);
		alpm_option_set_eventcb(handle, null, null);
		alpm_option_set_questioncb(handle, null, null);
		alpm_option_set_progresscb(handle, null, null);

		/* restore default signal handling in the child */
		_alpm_reset_signals();

		/* cwd to the download directory */
		ret = chdir(localpath);
		if(ret != 0) {
			handle.pm_errno = ALPM_ERR_NOT_A_DIR;
			_alpm_log(handle, ALPM_LOG_ERROR, _("could not chdir to download directory %s\n"), localpath);
			ret = -1;
		} else {
			ret = alpm_sandbox_setup_child(handle, handle.sandboxuser, localpath, true);
			if (ret != 0) {
				_alpm_log(handle, ALPM_LOG_ERROR, _("switching to sandbox user '%s' failed!\n"), handle.sandboxuser);
				_Exit(2);
			}

			ret = curl_download_internal(handle, payloads);
		}

		/* pass the result back to the parent */
		if(ret == 0) {
			/* a payload was actually downloaded */
			_Exit(0);
		}
		else if(ret == 1) {
			/* no files were downloaded and all errors were non-fatal */
			_Exit(1);
		}
		else {
			/* an error happened for a required file */
			_Exit(2);
		}
	}

	/* parent */
	close(callbacks_fd[1]);

	if(pid != -1)  {
		bool had_error = false;
		while(true) {
			_alpm_sandbox_callback_t callback_type = void;
			ssize_t got = read(callbacks_fd[0], &callback_type, callback_type.sizeof);
			if(got < 0 || cast(size_t)got != callback_type.sizeof) {
				had_error = true;
				break;
			}

			if(callback_type == ALPM_SANDBOX_CB_DOWNLOAD) {
				if(!_alpm_sandbox_process_cb_download(handle, callbacks_fd[0])) {
					had_error = true;
					break;
				}
			}
			else if(callback_type == ALPM_SANDBOX_CB_LOG) {
				if(!_alpm_sandbox_process_cb_log(handle, callbacks_fd[0])) {
					had_error = true;
					break;
				}
			}
		}


		if(had_error) {
			kill(pid, SIGTERM);
		}

		int wret = void;
		while((wret = waitpid(pid, &ret, 0)) == -1 && errno == EINTR){}
		if(wret > 0) {
			if(WIFSIGNALED(ret)) {
				*childsig = WTERMSIG(ret);
			}
			if(!WIFEXITED(ret)) {
				/* the child did not terminate normally */
				handle.pm_errno = ALPM_ERR_RETRIEVE;
				ret = -1;
			}
			else {
				ret = WEXITSTATUS(ret);
				if(ret != 0) {
					if(ret == 2) {
						/* an error happened for a required file, or unexpected exit status */
						handle.pm_errno = ALPM_ERR_RETRIEVE;
						ret = -1;
					}
					else {
						handle.pm_errno = ALPM_ERR_RETRIEVE;
						ret = 1;
					}
				}
			}
		}
		else {
			/* waitpid failed */
			err = errno;
		}
	}

	close(callbacks_fd[0]);

	sigaction(SIGINT, &oldint, null);
	sigaction(SIGQUIT, &oldquit, null);
	sigprocmask(SIG_SETMASK, &oldblock, null);

	if(err) {
		errno = err;
		ret = -1;
	}
	return ret;
}

}

private int payload_download_fetchcb(dload_payload* payload, const(char)* server, const(char)* localpath)
{
	int ret = void;
	char* fileurl = void;
	alpm_handle_t* handle = payload.handle;

	size_t len = strlen(server.ptr) + strlen(payload.filepath) + 2;
	MALLOC(fileurl, len);
	snprintf(fileurl, len, "%s/%s", server.ptr, payload.filepath);

	ret = handle.fetchcb(handle.fetchcb_ctx, fileurl, localpath, payload.force);
	free(fileurl);

	return ret;
}

private int move_file(const(char)* filepath, const(char)* directory)
{
	ASSERT(filepath != null, return -1);
	ASSERT(directory != null, return -1);
	int ret = finalize_download_file(filepath);
	if(ret != 0) {
		return ret;
	}
	const(char)* filename = mbasename(filepath);
	char* dest = _alpm_get_fullpath(directory, filename, "");
	if(rename(filepath, dest)) {
		FREE(dest);
		return -1;
	}
	FREE(dest);
	return 0;
}

private int finalize_download_locations(alpm_list_t* payloads, const(char)* localpath)
{
	ASSERT(payloads != null, return -1);
	ASSERT(localpath != null, return -1);
	alpm_list_t* p = void;
	stat st = void;
	int returnvalue = 0;
	for(p = payloads; p; p = p.next) {
		dload_payload* payload = p.data;
		const(char)* filename = null;

		if(payload.destfile_name && stat(payload.destfile_name, &st) == 0) {
			filename = payload.destfile_name;
		} else if(stat(payload.tempfile_name, &st) == 0) {
			filename = payload.tempfile_name;
		}

		if(filename) {
			int ret = move_file(filename, localpath);

			if(ret == -1) {
				if(payload.mtime_existing_file == 0) {
					_alpm_log(payload.handle, ALPM_LOG_ERROR, _("could not move %s into %s (%s)\n"),
							filename, localpath, strerror(errno));
					returnvalue = -1;
				}
			}
		}

		if (payload.download_signature) {
			char* sig_filename = void;
			int ret = void;

			filename = payload.destfile_name ? payload.destfile_name : payload.tempfile_name;
			sig_filename = _alpm_get_fullpath("", filename, ".sig");
			ASSERT(sig_filename, RET_ERR(payload.handle, ALPM_ERR_MEMORY, -1));
			ret = move_file(sig_filename, localpath);
			free(sig_filename);

			if(ret == -1) {
				sig_filename = _alpm_get_fullpath("", filename, ".sig.part");
				ASSERT(sig_filename, RET_ERR(payload.handle, ALPM_ERR_MEMORY, -1));
				move_file(sig_filename, localpath);
				free(sig_filename);
			}
		}
	}
	return returnvalue;
}

private void prepare_resumable_downloads(alpm_list_t* payloads, const(char)* localpath, const(char)* user)
{
	const(passwd)* pw = null;
	ASSERT(payloads != null, return);
	ASSERT(localpath != null, return);
	if(user != null) {
		ASSERT((pw = getpwnam(user)) != null, return);
	}
	alpm_list_t* p = void;
	for(p = payloads; p; p = p.next) {
		dload_payload* payload = p.data;
		if(payload.destfile_name) {
			const(char)* destfilename = mbasename(payload.destfile_name);
			char* dest = _alpm_get_fullpath(localpath, destfilename, "");
			stat deststat = void;
			if(stat(dest, &deststat) == 0 && deststat.st_size != 0) {
				payload.mtime_existing_file = deststat.st_mtime;
			}
			FREE(dest);
		}
		if(!payload.tempfile_name) {
			continue;
		}
		const(char)* filename = mbasename(payload.tempfile_name);
		char* src = _alpm_get_fullpath(localpath, filename, "");
		stat st = void;
		if(stat(src, &st) != 0 || st.st_size == 0) {
			FREE(src);
			continue;
		}
		if(rename(src, payload.tempfile_name) != 0) {
			FREE(src);
			continue;
		}
		if(pw != null) {
			ASSERT(chown(payload.tempfile_name, pw.pw_uid, pw.pw_gid), return);
		}
		FREE(src);
	}
}

/* Returns -1 if an error happened for a required file
 * Returns 0 if a payload was actually downloaded
 * Returns 1 if no files were downloaded and all errors were non-fatal
 */
int _alpm_download(alpm_handle_t* handle, alpm_list_t* payloads, const(char)* localpath, const(char)* temporary_localpath)
{
	int ret = void;
	int finalize_ret = void;
	int childsig = 0;
	prepare_resumable_downloads(payloads, localpath, handle.sandboxuser);

	if(handle.fetchcb == null) {
version (HAVE_LIBCURL) {
		if(handle.sandboxuser) {
			ret = curl_download_internal_sandboxed(handle, payloads, temporary_localpath, &childsig);
		} else {
			ret = curl_download_internal(handle, payloads);
		}
} else {
		RET_ERR(handle, ALPM_ERR_EXTERNAL_DOWNLOAD, -1);
}
	} else {
		alpm_list_t* p = void;
		int updated = 0;
		for(p = payloads; p; p = p.next) {
			dload_payload* payload = p.data;
			alpm_list_t* s = void;
			ret = -1;

			if(payload.fileurl) {
				ret = handle.fetchcb(handle.fetchcb_ctx, payload.fileurl, temporary_localpath, payload.force);
				if (ret != -1 && payload.download_signature) {
					/* Download signature if requested */
					char* sig_fileurl = void;
					size_t sig_len = strlen(payload.fileurl) + 5;
					int retsig = -1;

					MALLOC(sig_fileurl, sig_len);
					snprintf(sig_fileurl, sig_len, "%s.sig", payload.fileurl);

					retsig = handle.fetchcb(handle.fetchcb_ctx, sig_fileurl, temporary_localpath,  payload.force);
					free(sig_fileurl);

					if(!payload.signature_optional) {
						ret = retsig;
					}
				}
			} else {
				for(s = payload.cache_servers; s; s = s.next) {
					ret = payload_download_fetchcb(payload, s.data, temporary_localpath);
					if (ret != -1) {
						goto download_signature;
					}
				}
				for(s = payload.servers; s; s = s.next) {
					ret = payload_download_fetchcb(payload, s.data, temporary_localpath);
					if (ret != -1) {
						goto download_signature;
					}
				}

download_signature:
				if (ret != -1 && payload.download_signature) {
					/* Download signature if requested */
					char* sig_fileurl = void;
					size_t sig_len = strlen(s.data) + strlen(payload.filepath) + 6;
					int retsig = -1;

					MALLOC(sig_fileurl, sig_len);
					snprintf(sig_fileurl, sig_len, "%s/%s.sig", cast(const(char)*)(s.data), payload.filepath);

					retsig = handle.fetchcb(handle.fetchcb_ctx, sig_fileurl, temporary_localpath, payload.force);
					free(sig_fileurl);

					if(!payload.signature_optional) {
						ret = retsig;
					}
				}
			}

			if(ret == -1 && !payload.errors_ok) {
				RET_ERR(handle, ALPM_ERR_EXTERNAL_DOWNLOAD, -1);
			} else if(ret == 0) {
				updated = 1;
			}
		}
		ret = updated ? 0 : 1;
	}

	finalize_ret = finalize_download_locations(payloads, localpath);
	_alpm_remove_temporary_download_dir(temporary_localpath);

	/* propagate after finalizing so .part files get copied over */
	if(childsig != 0) {
		kill(getpid(), childsig);
	}
	if(finalize_ret != 0 && ret == 0) {
		RET_ERR(handle, ALPM_ERR_RETRIEVE, -1);
	}

	return ret;
}

private const(char)* url_basename(const(char)* url)
{
	const(char)* filebase = strrchr(url, '/');

	if(filebase == null) {
		return null;
	}

	filebase++;
	if(*filebase == '\0') {
		return null;
	}

	return filebase;
}

int  alpm_fetch_pkgurl(alpm_handle_t* handle, const(alpm_list_t)* urls, alpm_list_t** fetched)
{
	alpm_siglevel_t siglevel = alpm_option_get_remote_file_siglevel(handle);
	const(char)* cachedir = void;
	char* temporary_cachedir = null;
	alpm_list_t* payloads = null;
	const(alpm_list_t)* i = void;
	alpm_event_t event = void;

	CHECK_HANDLE(handle, return -1);
	ASSERT(*fetched == null, RET_ERR(handle, ALPM_ERR_WRONG_ARGS, -1));

	/* find a valid cache dir to download to */
	cachedir = _alpm_filecache_setup(handle);
	temporary_cachedir = _alpm_temporary_download_dir_setup(cachedir, handle.sandboxuser);
	ASSERT(temporary_cachedir != null, return -1);

	for(i = urls; i; i = i.next) {
		char* url = i.data;
		char* filepath = null;
		const(char)* urlbase = url_basename(url);

		if(urlbase) {
			/* attempt to find the file in our pkgcache */
			filepath = _alpm_filecache_find(handle, urlbase);

			if(filepath && (siglevel & ALPM_SIG_PACKAGE)) {
				char* sig_filename = _alpm_get_fullpath("", urlbase, ".sig");

				/* if there's no .sig file then forget about the pkg file and go for download */
				if(!_alpm_filecache_exists(handle, sig_filename)) {
					free(filepath);
					filepath = null;
				}

				free(sig_filename);
			}
		}

		if(filepath) {
			/* the file is locally cached so add it to the output right away */
			alpm_list_append(fetched, filepath);
		} else {
			dload_payload* payload = null;
			char* c = void;

			ASSERT(url, GOTO_ERR(handle, ALPM_ERR_WRONG_ARGS, err));
			CALLOC(payload, 1, typeof(*payload).sizeof, GOTO_ERR(handle, ALPM_ERR_MEMORY, err));
			STRDUP(payload.fileurl, url, FREE(payload); GOTO_ERR(handle, ALPM_ERR_MEMORY, err));

			STRDUP(payload.remote_name, get_filename(payload.fileurl),
				GOTO_ERR(handle, ALPM_ERR_MEMORY, err));

			c = strrchr(url, '/');
			if(c != null &&  strstr(c, ".pkg") && payload.remote_name && strlen(payload.remote_name) > 0) {
				/* we probably have a usable package filename to download to */
				payload.destfile_name = _alpm_get_fullpath(temporary_cachedir, payload.remote_name, "");
				payload.tempfile_name = _alpm_get_fullpath(temporary_cachedir, payload.remote_name, ".part");
				payload.allow_resume = 1;

				if(!payload.destfile_name || !payload.tempfile_name) {
					goto err;
				}

			} else {
				/* The URL does not contain a filename, so download to a temporary location.
				 * We can not support resuming this kind of download; any partial transfers
				 * will be destroyed */
				payload.unlink_on_fail = 1;

				payload.tempfile_openmode = "wb";
				payload.localf = create_tempfile(payload, temporary_cachedir);
				if(payload.localf == null) {
					goto err;
				}
			}

			payload.handle = handle;
			payload.download_signature = (siglevel & ALPM_SIG_PACKAGE);
			payload.signature_optional = (siglevel & ALPM_SIG_PACKAGE_OPTIONAL);
			payloads = alpm_list_add(payloads, payload);
		}
	}

	if(payloads) {
		event.type = ALPM_EVENT_PKG_RETRIEVE_START;
		event.pkg_retrieve.num = alpm_list_count(payloads);
		event.pkg_retrieve.total_size = 0;
		EVENT(handle, &event);
		if(_alpm_download(handle, payloads, cachedir, temporary_cachedir) == -1) {
			_alpm_log(handle, ALPM_LOG_WARNING, _("failed to retrieve some files\n"));
			event.type = ALPM_EVENT_PKG_RETRIEVE_FAILED;
			EVENT(handle, &event);
			GOTO_ERR(handle, ALPM_ERR_RETRIEVE, err);
		} else {
			event.type = ALPM_EVENT_PKG_RETRIEVE_DONE;
			EVENT(handle, &event);
		}

		for(i = cast(const(alpm_list_t)*) payloads; i; i = i.next) {
			dload_payload* payload = i.data;
			char* filepath = void;

			if(payload.destfile_name) {
				const(char)* filename = mbasename(payload.destfile_name);
				filepath = _alpm_filecache_find(handle, filename);
			} else {
				const(char)* filename = mbasename(payload.tempfile_name);
				filepath = _alpm_filecache_find(handle, filename);
			}
			if(filepath) {
				alpm_list_append(fetched, filepath);
			} else {
				_alpm_log(handle, ALPM_LOG_WARNING, _("download completed successfully but no file in the cache\n"));
				GOTO_ERR(handle, ALPM_ERR_RETRIEVE, err);
			}
		}

		alpm_list_free_inner(payloads, cast(alpm_list_fn_free)_alpm_dload_payload_reset);
		FREELIST(payloads);
	}

	FREE(temporary_cachedir);
	return 0;

err:
	alpm_list_free_inner(payloads, cast(alpm_list_fn_free)_alpm_dload_payload_reset);
	FREE(temporary_cachedir);
	FREELIST(payloads);
	FREELIST(*fetched);

	return -1;
}

void _alpm_dload_payload_reset(dload_payload* payload)
{
	ASSERT(payload, return);

	if(payload.localf != null) {
		fclose(payload.localf);
		payload.localf = null;
	}

	FREE(payload.remote_name);
	FREE(payload.tempfile_name);
	FREE(payload.destfile_name);
	FREE(payload.fileurl);
	FREE(payload.filepath);
	*payload = struct dload_payload(0);
}
