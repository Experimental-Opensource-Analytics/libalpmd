module libalpmd.trans;
   
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

import core.stdc.stdlib :
	free;
import core.sys.posix.stdio : 
	snprintf, 
	sprintf, 
	fprintf, 
	fflush, 
	stderr, 
	FILE,
	feof,
	fgets,
	fclose,
	fopen;
import core.stdc.string :
	strcmp,
	strlen,
	strchr,
	strstr,
	strcpy,
	strerror;
import core.sys.posix.unistd :
	rmdir,
	unlink,
	access,
	F_OK,
	R_OK;
import core.sys.posix.stdlib :
	mkdtemp;
import core.stdc.errno :
	errno;
import core.stdc.limits :
	PATH_MAX;

import std.conv;

/* libalpm */
import libalpmd.trans;
import libalpmd.consts;

import libalpmd.handle;
import libalpmd.alpm_list;
import libalpmd.pkg;
import libalpmd.util;
import libalpmd.log;
import libalpmd.handle;
import libalpmd.remove;
import libalpmd.sync;
import libalpmd.alpm;
import libalpmd.deps;
import libalpmd.hook;
import libalpmd.event;
import libalpmd.file.fileconflicts;
import libalpmd.conflict;

enum AlpmTransState {
	Idle = 0,
	Initialized,
	Prepared,
	Downloading,
	Commiting,
	Commited,
	Interrupted
}

/* Transaction */
class AlpmTrans {
private:
	/* bitfield of alpm_transflag_t flags */
	int flags;
	AlpmHandle handle;
	AlpmTransState state;
	AlpmPkgs unresolvable;  /* list of (AlpmPkg) */
	AlpmPkgs add;           /* list of (AlpmPkg) */
	AlpmPkgs remove;        /* list of (AlpmPkg) */
	AlpmStrings skip_remove;   /* list of (char *) */
public:

	this(AlpmHandle handle, int flags) {
		this.flags = flags;
		this.state = AlpmTransState.Initialized;
		this.handle = handle;
	}

	AlpmStrings checkArch() {
		AlpmStrings invalid;

		if(handle.architectures.empty) {
			logger.tracef("skipping architecture checks\n");
			return AlpmStrings();
		}
		foreach(pkg; add[]) {
			int found = 0;
			string pkgarch = pkg.getArch();

			/* always allow non-architecture packages and those marked "any" */
			if(!pkgarch || pkgarch == "any") {
				continue;
			}

			foreach(arch; handle.architectures[]) {
				if(pkgarch == arch) {
					found = 1;
					break;
				}
			}

			if(!found) {
				string string_;
				string pkgname = pkg.getName();
				string pkgver = pkg.getVersion();

				string_ = pkgname ~ "-" ~ pkgver ~ "-" ~ pkgarch;
				invalid.insertBack(string_);
			}
		}
		return invalid;
	}

	bool isRemoveEmpty() {
		return remove.empty();
	}

	auto getFlags() {
		return flags;
	}

	ref auto getAdded() {
		return add;
	}

	ref auto getRemoved() {
		return remove;
	}

	ref auto getUnresolvable() {
		return unresolvable;
	}

	ref auto getState() {
		return state;
	}

	ref auto getSkippedRemoved() {
		return skip_remove;
	}

	int  prepare(ref RefTransData data) {
		/* If there's nothing to do, return without complaining */
		if(this.add.empty() && this.remove.empty()) {
			return 0;
		}

		AlpmStrings invalid = this.checkArch();
		if(!invalid.empty()) {
			data.strings = invalid;
			RET_ERR(handle, ALPM_ERR_PKG_INVALID_ARCH, -1);
		}

		if(this.add.empty()) {
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

		if(!(this.flags & ALPM_TRANS_FLAG_NODEPS)) {
			logger.tracef("sorting by dependencies\n");
			if(!this.add.empty()) {
				auto add_orig = this.add.dup();
				this.add = _alpm_sortbydeps(handle, add_orig, this.remove, 0);
			}
			if(!this.remove.empty()) {
				auto rem_orig = this.remove.dup();

				this.remove = _alpm_sortbydeps(handle, rem_orig, this.remove, 0);
			}
		}

		this.state = AlpmTransState.Prepared;

		return 0;
	}
}

// int  alpm_trans_init(AlpmHandle handle, int flags)
// {
// 	AlpmTrans trans = void;

// 	/* Sanity checks */
// 	//ASSERT(handle.trans == null);

// 	/* lock db */
// 	if(!(flags & ALPM_TRANS_FLAG_NOLOCK)) {
// 		if(handle.lock()) {
// 			RET_ERR(handle, ALPM_ERR_HANDLE_LOCK, -1);
// 		}
// 	}

// 	trans = new AlpmTrans;
// 	trans.getFlags = flags;
// 	trans.getState = AlpmTransState.Initialized;

// 	handle.trans = trans;

// 	return 0;
// }

union RefTransData {
	AlpmDepMissings 	missings;
	AlpmConflicts		conflicts;
	AlpmStrings			strings; 
	AlpmFileConflicts	fileConflicts;
}

int  alpm_trans_commit(AlpmHandle handle, ref RefTransData data)
{
	AlpmTrans trans = void;
	AlpmEvent event;

	/* Sanity checks */

	trans = handle.trans;

	//ASSERT(trans != null);
	ASSERT(trans.getState == AlpmTransState.Prepared);

	//ASSERT(!(trans.getFlags & ALPM_TRANS_FLAG_NOLOCK));

	/* If there's nothing to do, return without complaining */
	if(trans.getAdded.empty() && trans.getRemoved.empty()) {
		return 0;
	}

	if(!trans.getAdded.empty()) {
		if(_alpm_sync_load(handle, data) != 0) {
			/* pm_errno is set by _alpm_sync_load() */
			return -1;
		}
		if(trans.getFlags & ALPM_TRANS_FLAG_DOWNLOADONLY) {
			return 0;
		}
		// auto x = (*data).oldToNewList!AlpmFileConflict;
		if(_alpm_sync_check(handle, data) != 0) {
			/* pm_errno is set by _alpm_sync_check() */
			return -1;
		}
	}

	if(!(trans.getFlags & ALPM_TRANS_FLAG_NOHOOKS) &&
			_alpm_hook_run(handle, AlpmHookWhen.PreTransaction) != 0) {
		RET_ERR(handle, ALPM_ERR_TRANS_HOOK_FAILED, -1);
	}

	trans.getState = AlpmTransState.Commiting;

	//alpm_logaction(handle, ALPM_CALLER_PREFIX, "transaction started\n");
	event = new AlpmEventTransaction(AlpmEventDefStatus.Start);
	EVENT(handle, event);

	if(trans.getAdded.empty()) {
		if(_alpm_remove_packages(handle, 1) == -1) {
			/* pm_errno is set by _alpm_remove_packages() */
			alpm_errno_t save = handle.pm_errno;
			//alpm_logaction(handle, ALPM_CALLER_PREFIX, "transaction failed\n");
			handle.pm_errno = save;
			return -1;
		}
	} else {
		if(_alpm_sync_commit(handle) == -1) {
			/* pm_errno is set by _alpm_sync_commit() */
			alpm_errno_t save = handle.pm_errno;
			//alpm_logaction(handle, ALPM_CALLER_PREFIX, "transaction failed\n");
			handle.pm_errno = save;
			return -1;
		}
	}

	if(trans.getState == AlpmTransState.Interrupted) {
		//alpm_logaction(handle, ALPM_CALLER_PREFIX, "transaction interrupted\n");
	} else {
		event = new AlpmEventTransaction(AlpmEventDefStatus.Done);
		EVENT(handle, event);
		//alpm_logaction(handle, ALPM_CALLER_PREFIX, "transaction completed\n");

		if(!(trans.getFlags & ALPM_TRANS_FLAG_NOHOOKS)) {
			_alpm_hook_run(handle, AlpmHookWhen.PostTransaction);
		}
	}

	trans.getState = AlpmTransState.Commited;

	return 0;
}

int  alpm_trans_interrupt(AlpmHandle handle)
{
	AlpmTrans trans = void;

	/* Sanity checks */
	trans = handle.trans;
	//ASSERT(trans != null);
	ASSERT(trans.getState == AlpmTransState.Commiting || trans.getState == AlpmTransState.Interrupted);

	trans.getState = AlpmTransState.Interrupted;

	return 0;
}

int  alpm_trans_release(AlpmHandle handle)
{
	AlpmTrans trans = void;

	/* Sanity checks */
	trans = handle.trans;
	//ASSERT(trans != null);
	ASSERT(trans.getState != AlpmTransState.Idle);

	int nolock_flag = trans.getFlags & ALPM_TRANS_FLAG_NOLOCK;

	_alpm_trans_free(trans);
	handle.trans = null;

	/* unlock db */
	if(!nolock_flag) {
		handle.unlockDBs();
	}

	return 0;
}

void _alpm_trans_free(AlpmTrans trans)
{
	if(trans is null) {
		return;
	}

	trans.getUnresolvable.clear();
	trans.getAdded.clear();
	trans.getRemoved.clear();

	// FREELIST(trans.getSkippedRemoved);

	// FREE(trans);
}

/* A cheap grep for text files, returns 1 if a substring
 * was found in the text file fn, 0 if it wasn't
 */
private int grep(  char*fn,   char*needle)
{
	FILE* fp = void;
	char* ptr = void;

	if((fp = fopen(fn, "r")) == null) {
		return 0;
	}
	while(!feof(fp)) {
		char[1024] line = void;
		if( fgets(line.ptr, line.sizeof, fp) == null) {
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

int _alpm_runscriptlet(AlpmHandle handle,   char*filepath,   char*script,   char*ver,   char*oldver, int is_archive)
{
	char[PATH_MAX] arg0 = void; char[3] arg1 = void; char[PATH_MAX] cmdline = void;
	char*[4] argv = cast(char*[4])[ arg0, arg1, cmdline, null ];
	char* tmpdir = void, scriptfn = null, scriptpath = void;
	int retval = 0;
	size_t len = void;

	if(alpmAccess(handle, null, filepath.to!string, R_OK) != 0) {
		logger.tracef("scriptlet '%s' not found\n", filepath);
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
	len = handle.root.length + strlen("tmp/alpm_XXXXXX") + 1;
	MALLOC(tmpdir, len);
	snprintf(tmpdir, len, "%stmp/", handle.root.ptr);
	if(access(tmpdir, F_OK) != 0) {
		alpmMakePathMode(tmpdir.to!string, octal!"01777");
	}
	snprintf(tmpdir, len, "%stmp/alpm_XXXXXX", handle.root.ptr);
	if(mkdtemp(tmpdir) == null) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not create temp directory\n"));
		free(tmpdir);
		return 1;
	}

	/* either extract or copy the scriptlet */
	len += strlen("/.INSTALL");
	MALLOC(scriptfn, len);
	snprintf(scriptfn, len, "%s/.INSTALL", tmpdir);
	if(is_archive) {
		if(_alpm_unpack_single(handle, filepath, tmpdir, cast(char*)".INSTALL")) {
			retval = 1;
		}
	} else {
		if(_alpm_copyfile(filepath, scriptfn)) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("could not copy tempfile to %s (%s)\n"), scriptfn, strerror(errno));
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
	scriptpath = scriptfn + handle.root.length - 1;

	if(oldver) {
		snprintf(cmdline.ptr, PATH_MAX, ". %s; %s %s %s",
				scriptpath, script, ver, oldver);
	} else {
		snprintf(cmdline.ptr, PATH_MAX, ". %s; %s %s",
				scriptpath, script, ver);
	}

	logger.tracef("executing \"%s\"\n", cmdline.ptr);


	retval = _alpm_run_chroot(handle, cast(char*)SCRIPTLET_SHELL, argv.ptr, null, null);

cleanup:
	if(scriptfn && unlink(scriptfn)) {
		_alpm_log(handle, ALPM_LOG_WARNING,
				("could not remove %s\n"), scriptfn);
	}
	if(rmdir(tmpdir)) {
		_alpm_log(handle, ALPM_LOG_WARNING,
				("could not remove tmpdir %s\n"), tmpdir);
	}

	free(scriptfn);
	free(tmpdir);
	return retval;
}

int  alpm_trans_get_flags(AlpmHandle handle)
{
	return handle.trans.getFlags;
}

AlpmPkgs alpm_trans_get_add(AlpmHandle handle)
{
	return handle.trans.getAdded;
}

AlpmPkgs alpm_trans_get_remove(AlpmHandle handle)
{
	return handle.trans.getRemoved;
}
