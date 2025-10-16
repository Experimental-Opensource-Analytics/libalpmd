module libalpmd.sandbox;
@nogc  
   

private template HasVersion(string versionId) {
	mixin("version("~versionId~") {enum HasVersion = true;} else {enum HasVersion = false;}");
}
/*
 *  sandbox.c
 *
 *  Copyright (c) 2021-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
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

// import libalpmd.config;

import core.stdc.errno;
import core.sys.posix.grp;
import core.sys.posix.pwd;
version (HAVE_SYS_PRCTL_H) {
import core.sys.linux.sys.prctl;
} /* HAVE_SYS_PRCTL_H */
import core.sys.posix.sys.types;
import core.sys.posix.unistd;
import core.stdc.limits;
import core.stdc.stdarg;

import libalpmd.alpm;
import libalpmd.log;
import libalpmd.sandbox;
import libalpmd.sandbox_fs;
import libalpmd.sandbox_syscalls;
import libalpmd.util;

int  alpm_sandbox_setup_child(alpm_handle_t* handle, const(char)* sandboxuser, const(char)* sandbox_path, bool restrict_syscalls)
{
	const(passwd)* pw = null;

	ASSERT(sandboxuser != null);
	ASSERT(getuid() == 0);
	ASSERT((pw = getpwnam(sandboxuser)));
	if(sandbox_path != null && !handle.disable_sandbox) {
		_alpm_sandbox_fs_restrict_writes_to(handle, sandbox_path);
	}
static if (HasVersion!"HAVE_SYS_PRCTL_H" && HasVersion!"PR_SET_NO_NEW_PRIVS") {
	/* make sure that we cannot gain more privileges later, failure is fine */
	prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
} /* HAVE_SYS_PRCTL && PR_SET_NO_NEW_PRIVS */
	if(restrict_syscalls && !handle.disable_sandbox) {
		_alpm_sandbox_syscalls_filter(handle);
	}
	ASSERT(setgid(pw.pw_gid) == 0);
	ASSERT(setgroups(0, null) == 0);
	ASSERT(setuid(pw.pw_uid) == 0);

	return 0;
}

private int should_retry(int errnum)
{
	return errnum == EINTR;
}

private int read_from_pipe(int fd, void* buf, size_t count)
{
	size_t nread = 0;

	ASSERT(count > 0);

	while(nread < count) {
		ssize_t r = read(fd, cast(char*)buf + nread, count-nread);
		if(r < 0) {
			if(!should_retry(errno)) {
				return -1;
			}
			continue;
		}
		if(r == 0) {
			/* we hit EOF unexpectedly - bail */
			return -1;
		}
		nread += r;
	}

	return 0;
}

private int write_to_pipe(int fd, const(void)* buf, size_t count)
{
	size_t nwrite = 0;

	ASSERT(count > 0);

	while(nwrite < count) {
		ssize_t r = write(fd, cast(char*)buf + nwrite, count-nwrite);
		if(r < 0) {
			if(!should_retry(errno)) {
				return -1;
			}
			continue;
		}
		nwrite += r;
	}

	return 0;
}

void _alpm_sandbox_cb_log(void* ctx, alpm_loglevel_t level, const(char)* fmt, va_list args)
{
	_alpm_sandbox_callback_t type = ALPM_SANDBOX_CB_LOG;
	_alpm_sandbox_callback_context* context = ctx;
	char* string = null;
	int string_size = 0;

	if(!context || context.callback_pipe == -1) {
		return;
	}

	/* compute the required size, as allowed by POSIX.1-2001 and C99 */
	/* first we need to copy the va_list as it will be consumed by the first call */
	va_list copy = void;
	va_copy(copy, args);
	string_size = vsnprintf(null, 0, fmt, copy);
	if(string_size <= 0) {
		va_end(copy);
		return;
	}
	MALLOC(string, string_size + 1);
	string_size = vsnprintf(string, string_size + 1, fmt, args);
	if(string_size > 0) {
		write_to_pipe(context.callback_pipe, &type, type.sizeof);
		write_to_pipe(context.callback_pipe, &level, level.sizeof);
		write_to_pipe(context.callback_pipe, &string_size, string_size.sizeof);
		write_to_pipe(context.callback_pipe, string, string_size);
	}
	va_end(copy);
	FREE(string);
}

void _alpm_sandbox_cb_dl(void* ctx, const(char)* filename, alpm_download_event_type_t event, void* data)
{
	_alpm_sandbox_callback_t type = ALPM_SANDBOX_CB_DOWNLOAD;
	_alpm_sandbox_callback_context* context = ctx;
	size_t filename_len = void;

	if(!context || context.callback_pipe == -1) {
		return;
	}

	ASSERT(filename != null);
	ASSERT(event == ALPM_DOWNLOAD_INIT || event == ALPM_DOWNLOAD_PROGRESS || event == ALPM_DOWNLOAD_RETRY || event == ALPM_DOWNLOAD_COMPLETED);

	filename_len = strlen(filename);

	write_to_pipe(context.callback_pipe, &type, type.sizeof);
	write_to_pipe(context.callback_pipe, &event, event.sizeof);
	switch(event) {
		case ALPM_DOWNLOAD_INIT:
			write_to_pipe(context.callback_pipe, data, alpm_download_event_init_t.sizeof);
			break;
		case ALPM_DOWNLOAD_PROGRESS:
			write_to_pipe(context.callback_pipe, data, alpm_download_event_progress_t.sizeof);
			break;
		case ALPM_DOWNLOAD_RETRY:
			write_to_pipe(context.callback_pipe, data, alpm_download_event_retry_t.sizeof);
			break;
		case ALPM_DOWNLOAD_COMPLETED:
			write_to_pipe(context.callback_pipe, data, alpm_download_event_completed_t.sizeof);
			break;
	default: break;}
	write_to_pipe(context.callback_pipe, &filename_len, filename_len.sizeof);
	write_to_pipe(context.callback_pipe, filename, filename_len);
}


bool _alpm_sandbox_process_cb_log(alpm_handle_t* handle, int callback_pipe) {
	alpm_loglevel_t level = void;
	char* string = null;
	int string_size = 0;

	ASSERT(read_from_pipe(callback_pipe, &level, level.sizeof) != -1);
	ASSERT(read_from_pipe(callback_pipe, &string_size, string_size.sizeof) != -1);
	ASSERT(string_size > 0 && cast(size_t)string_size < SIZE_MAX);

	MALLOC(string, cast(size_t)string_size + 1);

	ASSERT(read_from_pipe(callback_pipe, string, string_size) != -1);
	string[string_size] = '\0';

	_alpm_log(handle, level, "%s", string);
	FREE(string);
	return true;
}

bool _alpm_sandbox_process_cb_download(alpm_handle_t* handle, int callback_pipe) {
	alpm_download_event_type_t type = void;
	char* filename = null;
	size_t filename_size = void, cb_data_size = void;
	union _Cb_data {
		alpm_download_event_init_t init = void;
		alpm_download_event_progress_t progress = void;
		alpm_download_event_retry_t retry = void;
		alpm_download_event_completed_t completed = void;
	}_Cb_data cb_data = void;

	ASSERT(read_from_pipe(callback_pipe, &type, type.sizeof) != -1);

	switch (type) {
		case ALPM_DOWNLOAD_INIT:
			cb_data_size = alpm_download_event_init_t.sizeof;
			ASSERT(read_from_pipe(callback_pipe, &cb_data.init, cb_data_size) != -1);
			break;
		case ALPM_DOWNLOAD_PROGRESS:
			cb_data_size = alpm_download_event_progress_t.sizeof;
			ASSERT(read_from_pipe(callback_pipe, &cb_data.progress, cb_data_size) != -1);
			break;
		case ALPM_DOWNLOAD_RETRY:
			cb_data_size = alpm_download_event_retry_t.sizeof;
			ASSERT(read_from_pipe(callback_pipe, &cb_data.retry, cb_data_size) != -1);
			break;
		case ALPM_DOWNLOAD_COMPLETED:
			cb_data_size = alpm_download_event_completed_t.sizeof;
			ASSERT(read_from_pipe(callback_pipe, &cb_data.completed, cb_data_size) != -1);
			break;
		default:
			return false;
	}

	ASSERT(read_from_pipe(callback_pipe, &filename_size, filename_size.sizeof) != -1);{}
	ASSERT(filename_size < PATH_MAX);

	MALLOC(filename, filename_size + 1);

	ASSERT(read_from_pipe(callback_pipe, filename, filename_size) != -1);
	filename[filename_size] = '\0';

	if(handle.dlcb) {
		handle.dlcb(handle.dlcb_ctx, filename, type, &cb_data);
	}
	FREE(filename);
	return true;
}
