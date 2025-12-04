module libalpmd.log;
@nogc  
 
/*
 *  log.c
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

import core.stdc.stdio;
import core.stdc.stdarg;
import core.stdc.errno;
import core.sys.posix.syslog;
// import core.sys.posix.stdc.stdarg;

import core.stdc.time;
import core.sys.posix.dirent;

import core.sys.posix.stdio;

import core.stdc.errno;
import core.stdc.limits;
import core.stdc.string;
import core.stdc.stdlib;
import libalpmd.handle;
import libalpmd.ini;
import libalpmd.log;
import libalpmd.trans;
import libalpmd.util;
import libalpmd.alpm_list;
import libalpmd.alpm;
import libalpmd.util_common;
import libalpmd.pkg;
import libalpmd.consts;
import libalpmd.db;


import core.stdc.stdio;
import core.stdc.errno;
import core.sys.posix.unistd;
import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.errno;
import core.stdc.string;
import core.stdc.stdint; /* intmax_t */
// import core.sys.posix.dirent;
import core.sys.posix.dirent;
import core.sys.posix.sys.stat;
import core.sys.posix.fcntl;
import ae.sys.file;

import std.string;
import std.conv;
import std.stdio;



/* libalpm */
import libalpmd.log;
import libalpmd.handle;
import libalpmd.util;
import libalpmd.alpm;
import hlogger;

static this() {
	logger = new HLogger;
}

HLogger logger;

enum char* ALPM_CALLER_PREFIX = cast(char*)"ALPM";

private int _alpm_log_leader(FILE* f,   char*prefix)
{
	time_t t = time(null);
	tm* tm = localtime(&t);
	immutable int length = 32;
	char[length] timestamp = void;

	/* Use ISO-8601 date format */
	strftime(timestamp.ptr,length,"%FT%T%z", tm);
	return fprintf(f, "[%s] [%s] ", timestamp.ptr, prefix);
}

int  alpm_logaction(AlpmHandle handle,   char*prefix,   char*fmt, ...)
{
	int ret = 0;
	va_list args = void;

	//ASSERT(handle != null);

	if(!(prefix && *prefix)) {
		prefix = cast(char*)"UNKNOWN".ptr;
	}

	/* check if the logstream is open already, opening it if needed */
	if(!(handle.logstream.isOpen) && handle.logfile != null) {
		int fd = void;
		do {
			fd = open(cast(char*)handle.logfile.ptr, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC,
					octal!"0644");
		} while(fd == -1 && errno == EINTR);
		/* if we couldn't open it, we have an issue */
		handle.logstream.fdopen(fd, "a");
		if(fd < 0) {
			if(errno == EACCES) {
				handle.pm_errno = ALPM_ERR_BADPERMS;
			} else if(errno == ENOENT) {
				handle.pm_errno = ALPM_ERR_NOT_A_DIR;
			} else {
				handle.pm_errno = ALPM_ERR_SYSTEM;
			}
			ret = -1;
		}
	}

	va_start(args, fmt);

	if(handle.usesyslog) {
		/* we can't use a va_list more than once, so we need to copy it
		 * so we can use the original when calling vfprintf below. */
		va_list args_syslog = void;
		va_copy(args_syslog, args);
		syslog(LOG_WARNING, fmt, args_syslog);
		va_end(args_syslog);
	}

	if(handle.logstream.isOpen()) {
		if(_alpm_log_leader(handle.logstream.getFP, prefix) < 0
				|| vfprintf(handle.logstream.getFP, fmt, args) < 0) {
			ret = -1;
			handle.pm_errno = ALPM_ERR_SYSTEM;
		}
		handle.logstream.flush();
	}

	va_end(args);
	return ret;
}

void _alpm_log(AlpmHandle handle, alpm_loglevel_t flag, string fmt, ...)
{
	va_list args = void;

	// if(handle is null || handle.logcb == null) {
	// 	return;
	// }

	va_start(args, fmt);
	output_cb(handle.getLogCallback.ptr, flag, fmt.ptr, args);
	va_end(args);
}
