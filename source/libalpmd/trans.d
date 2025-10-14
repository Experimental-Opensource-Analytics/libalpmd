module libalpmd.trans;
@nogc nothrow:
extern(C): __gshared:
/*
 *  trans.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
 *  Copyright (c) 2005 by Christian Hamar <krics@linuxforum.hu>
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
import core.stdc.stdio;
import core.stdc.string;
import core.sys.posix.unistd;
import core.sys.posix.sys.types;
import core.stdc.errno;
import core.stdc.limits;

/* libalpm */
import libalpmd.trans;
import libalpmd.alpm_list;
import libalpmd._package;
import libalpmd.util;
import libalpmd.log;
import libalpmd.handle;
import libalpmd.remove;
import libalpmd.sync;
import libalpmd.alpm;
import libalpmd.deps;
import libalpmd.hook;

int  alpm_trans_init(alpm_handle_t* handle, int flags)
{
	alpm_trans_t* trans = void;

	/* Sanity checks */
	CHECK_HANDLE(handle);
	ASSERT(handle.trans == null);

	/* lock db */
	if(!(flags & ALPM_TRANS_FLAG_NOLOCK)) {
		if(_alpm_handle_lock(handle)) {
			RET_ERR(handle, ALPM_ERR_HANDLE_LOCK, -1);
		}
	}

	CALLOC(trans, 1, alpm_trans_t.sizeof);
	trans.flags = flags;
	trans.state = STATE_INITIALIZED;

	handle.trans = trans;

	return 0;
}

private alpm_list_t* check_arch(alpm_handle_t* handle, alpm_list_t* pkgs)
{
	alpm_list_t* i = void;
	alpm_list_t* invalid = null;

	if(!handle.architectures) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "skipping architecture checks\n");
		return null;
	}
	for(i = pkgs; i; i = i.next) {
		alpm_pkg_t* pkg = i.data;
		alpm_list_t* j = void;
		int found = 0;
		const(char)* pkgarch = alpm_pkg_get_arch(pkg);

		/* always allow non-architecture packages and those marked "any" */
		if(!pkgarch || strcmp(pkgarch, "any") == 0) {
			continue;
		}

		for(j = handle.architectures; j; j = j.next) {
			if(strcmp(pkgarch, j.data) == 0) {
				found = 1;
				break;
			}
		}

		if(!found) {
			char* string = void;
			const(char)* pkgname = pkg.name;
			const(char)* pkgver = pkg.version_;
			size_t len = strlen(pkgname) + strlen(pkgver) + strlen(pkgarch) + 3;
			MALLOC(string, len);
			snprintf(string, len, "%s-%s-%s", pkgname, pkgver, pkgarch);
			invalid = alpm_list_add(invalid, string);
		}
	}
	return invalid;
}

int  alpm_trans_prepare(alpm_handle_t* handle, alpm_list_t** data)
{
	alpm_trans_t* trans = void;

	/* Sanity checks */
	CHECK_HANDLE(handle);
	ASSERT(data != null);

	trans = handle.trans;

	ASSERT(trans != null);
	ASSERT(trans.state == STATE_INITIALIZED);

	/* If there's nothing to do, return without complaining */
	if(trans.add == null && trans.remove == null) {
		return 0;
	}

	alpm_list_t* invalid = check_arch(handle, trans.add);
	if(invalid) {
		if(data) {
			*data = invalid;
		}
		RET_ERR(handle, ALPM_ERR_PKG_INVALID_ARCH, -1);
	}

	if(trans.add == null) {
		if(_alpm_remove_prepare(handle, data) == -1) {
			/* pm_errno is set by _alpm_remove_prepare() */
			return -1;
		}
	} else {
		if(_alpm_sync_prepare(handle, data) == -1) {
			/* pm_errno is set by _alpm_sync_prepare() */
			return -1;
		}
	}


	if(!(trans.flags & ALPM_TRANS_FLAG_NODEPS)) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "sorting by dependencies\n");
		if(trans.add) {
			alpm_list_t* add_orig = trans.add;
			trans.add = _alpm_sortbydeps(handle, add_orig, trans.remove, 0);
			alpm_list_free(add_orig);
		}
		if(trans.remove) {
			alpm_list_t* rem_orig = trans.remove;
			trans.remove = _alpm_sortbydeps(handle, rem_orig, null, 1);
			alpm_list_free(rem_orig);
		}
	}

	trans.state = STATE_PREPARED;

	return 0;
}

int  alpm_trans_commit(alpm_handle_t* handle, alpm_list_t** data)
{
	alpm_trans_t* trans = void;
	alpm_event_any_t event = void;

	/* Sanity checks */
	CHECK_HANDLE(handle);

	trans = handle.trans;

	ASSERT(trans != null);
	ASSERT(trans.state == STATE_PREPARED);

	ASSERT(!(trans.flags & ALPM_TRANS_FLAG_NOLOCK));

	/* If there's nothing to do, return without complaining */
	if(trans.add == null && trans.remove == null) {
		return 0;
	}

	if(trans.add) {
		if(_alpm_sync_load(handle, data) != 0) {
			/* pm_errno is set by _alpm_sync_load() */
			return -1;
		}
		if(trans.flags & ALPM_TRANS_FLAG_DOWNLOADONLY) {
			return 0;
		}
		if(_alpm_sync_check(handle, data) != 0) {
			/* pm_errno is set by _alpm_sync_check() */
			return -1;
		}
	}

	if(!(trans.flags & ALPM_TRANS_FLAG_NOHOOKS) &&
			_alpm_hook_run(handle, ALPM_HOOK_PRE_TRANSACTION) != 0) {
		RET_ERR(handle, ALPM_ERR_TRANS_HOOK_FAILED, -1);
	}

	trans.state = STATE_COMMITTING;

	alpm_logaction(handle, ALPM_CALLER_PREFIX, "transaction started\n");
	event.type = ALPM_EVENT_TRANSACTION_START;
	EVENT(handle, cast(void*)&event);

	if(trans.add == null) {
		if(_alpm_remove_packages(handle, 1) == -1) {
			/* pm_errno is set by _alpm_remove_packages() */
			alpm_errno_t save = handle.pm_errno;
			alpm_logaction(handle, ALPM_CALLER_PREFIX, "transaction failed\n");
			handle.pm_errno = save;
			return -1;
		}
	} else {
		if(_alpm_sync_commit(handle) == -1) {
			/* pm_errno is set by _alpm_sync_commit() */
			alpm_errno_t save = handle.pm_errno;
			alpm_logaction(handle, ALPM_CALLER_PREFIX, "transaction failed\n");
			handle.pm_errno = save;
			return -1;
		}
	}

	if(trans.state == STATE_INTERRUPTED) {
		alpm_logaction(handle, ALPM_CALLER_PREFIX, "transaction interrupted\n");
	} else {
		event.type = ALPM_EVENT_TRANSACTION_DONE;
		EVENT(handle, cast(void*)&event);
		alpm_logaction(handle, ALPM_CALLER_PREFIX, "transaction completed\n");

		if(!(trans.flags & ALPM_TRANS_FLAG_NOHOOKS)) {
			_alpm_hook_run(handle, ALPM_HOOK_POST_TRANSACTION);
		}
	}

	trans.state = STATE_COMMITTED;

	return 0;
}

int  alpm_trans_interrupt(alpm_handle_t* handle)
{
	alpm_trans_t* trans = void;

	/* Sanity checks */
	CHECK_HANDLE(handle);

	trans = handle.trans;
	ASSERT(trans != null);
	ASSERT(trans.state == STATE_COMMITTING || trans.state == STATE_INTERRUPTED);

	trans.state = STATE_INTERRUPTED;

	return 0;
}

int  alpm_trans_release(alpm_handle_t* handle)
{
	alpm_trans_t* trans = void;

	/* Sanity checks */
	CHECK_HANDLE(handle);

	trans = handle.trans;
	ASSERT(trans != null);
	ASSERT(trans.state != STATE_IDLE);

	int nolock_flag = trans.flags & ALPM_TRANS_FLAG_NOLOCK;

	_alpm_trans_free(trans);
	handle.trans = null;

	/* unlock db */
	if(!nolock_flag) {
		_alpm_handle_unlock(handle);
	}

	return 0;
}

void _alpm_trans_free(alpm_trans_t* trans)
{
	if(trans == null) {
		return;
	}

	alpm_list_free_inner(trans.unresolvable,
			cast(alpm_list_fn_free)_alpm_pkg_free_trans);
	alpm_list_free(trans.unresolvable);
	alpm_list_free_inner(trans.add, cast(alpm_list_fn_free)_alpm_pkg_free_trans);
	alpm_list_free(trans.add);
	alpm_list_free_inner(trans.remove, cast(alpm_list_fn_free)_alpm_pkg_free);
	alpm_list_free(trans.remove);

	FREELIST(trans.skip_remove);

	FREE(trans);
}

/* A cheap grep for text files, returns 1 if a substring
 * was found in the text file fn, 0 if it wasn't
 */
private int grep(const(char)* fn, const(char)* needle)
{
	FILE* fp = void;
	char* ptr = void;

	if((fp = fopen(fn, "r")) == null) {
		return 0;
	}
	while(!feof(fp)) {
		char[1024] line = void;
		if(safe_fgets(line.ptr, line.sizeof, fp) == null) {
			continue;
		}
		if((ptr = strchr(line.ptr, '#')) != null) {
			*ptr = '\0';
		}
		/* TODO: this will not work if the search string
		 * ends up being split across line reads */
		if(strstr(line.ptr, needle)) {
			fclose(fp);
			return 1;
		}
	}
	fclose(fp);
	return 0;
}

int _alpm_runscriptlet(alpm_handle_t* handle, const(char)* filepath, const(char)* script, const(char)* ver, const(char)* oldver, int is_archive)
{
	char[PATH_MAX] arg0 = void; char[3] arg1 = void; char[PATH_MAX] cmdline = void;
	char*[4] argv = [ arg0, arg1, cmdline, null ];
	char* tmpdir = void, scriptfn = null, scriptpath = void;
	int retval = 0;
	size_t len = void;

	if(_alpm_access(handle, null, filepath, R_OK) != 0) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "scriptlet '%s' not found\n", filepath);
		return 0;
	}

	if(!is_archive && !grep(filepath, script)) {
		/* script not found in scriptlet file; we can only short-circuit this early
		 * if it is an actual scriptlet file and not an archive. */
		return 0;
	}

	strcpy(arg0.ptr, SCRIPTLET_SHELL);
	strcpy(arg1.ptr, "-c");

	/* create a directory in $root/tmp/ for copying/extracting the scriptlet */
	len = strlen(handle.root) + strlen("tmp/alpm_XXXXXX") + 1;
	MALLOC(tmpdir, len);
	snprintf(tmpdir, len, "%stmp/", handle.root);
	if(access(tmpdir, F_OK) != 0) {
		_alpm_makepath_mode(tmpdir, octal!"01777");
	}
	snprintf(tmpdir, len, "%stmp/alpm_XXXXXX", handle.root);
	if(mkdtemp(tmpdir) == null) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("could not create temp directory\n"));
		free(tmpdir);
		return 1;
	}

	/* either extract or copy the scriptlet */
	len += strlen("/.INSTALL");
	MALLOC(scriptfn, len);
	snprintf(scriptfn, len, "%s/.INSTALL", tmpdir);
	if(is_archive) {
		if(_alpm_unpack_single(handle, filepath, tmpdir, ".INSTALL")) {
			retval = 1;
		}
	} else {
		if(_alpm_copyfile(filepath, scriptfn)) {
			_alpm_log(handle, ALPM_LOG_ERROR, _("could not copy tempfile to %s (%s)\n"), scriptfn, strerror(errno));
			retval = 1;
		}
	}
	if(retval == 1) {
		goto cleanup;
	}

	if(is_archive && !grep(scriptfn, script)) {
		/* script not found in extracted scriptlet file */
		goto cleanup;
	}

	/* chop off the root so we can find the tmpdir in the chroot */
	scriptpath = scriptfn + strlen(handle.root) - 1;

	if(oldver) {
		snprintf(cmdline.ptr, PATH_MAX, ". %s; %s %s %s",
				scriptpath, script, ver, oldver);
	} else {
		snprintf(cmdline.ptr, PATH_MAX, ". %s; %s %s",
				scriptpath, script, ver);
	}

	_alpm_log(handle, ALPM_LOG_DEBUG, "executing \"%s\"\n", cmdline.ptr);

	retval = _alpm_run_chroot(handle, SCRIPTLET_SHELL, argv.ptr, null, null);

cleanup:
	if(scriptfn && unlink(scriptfn)) {
		_alpm_log(handle, ALPM_LOG_WARNING,
				_("could not remove %s\n"), scriptfn);
	}
	if(rmdir(tmpdir)) {
		_alpm_log(handle, ALPM_LOG_WARNING,
				_("could not remove tmpdir %s\n"), tmpdir);
	}

	free(scriptfn);
	free(tmpdir);
	return retval;
}

int  alpm_trans_get_flags(alpm_handle_t* handle)
{
	/* Sanity checks */
	CHECK_HANDLE(handle);
	ASSERT(handle.trans != null);

	return handle.trans.flags;
}

alpm_list_t * alpm_trans_get_add(alpm_handle_t* handle)
{
	/* Sanity checks */
	CHECK_HANDLE(handle);
	ASSERT(handle.trans != null);

	return handle.trans.add;
}

alpm_list_t * alpm_trans_get_remove(alpm_handle_t* handle)
{
	/* Sanity checks */
	CHECK_HANDLE(handle);
	ASSERT(handle.trans != null);

	return handle.trans.remove;
}
