module handle.c;
@nogc nothrow:
extern(C): __gshared:
/*
 *  handle.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
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

import core.stdc.errno;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.limits;
import core.sys.posix.sys.types;
import core.sys.posix.syslog;
import core.sys.posix.sys.stat;
import core.sys.posix.fcntl;

/* libalpm */
import handle;
import alpm_list;
import util;
import log;
import trans;
import alpm;
import deps;

alpm_handle_t* _alpm_handle_new()
{
	alpm_handle_t* handle = void;

	CALLOC(handle, 1, alpm_handle_t.sizeof, return NULL);
	handle.lockfd = -1;

	return handle;
}

/* free all in-memory resources */
void _alpm_handle_free(alpm_handle_t* handle)
{
	alpm_list_t* i = void;
	alpm_db_t* db = void;

	if(handle == null) {
		return;
	}

	/* close local database */
	if((db = handle.db_local)) {
		db.ops.unregister(db);
	}

	/* unregister all sync dbs */
	for(i = handle.dbs_sync; i; i = i.next) {
		db = i.data;
		db.ops.unregister(db);
	}
	alpm_list_free(handle.dbs_sync);

	/* close logfile */
	if(handle.logstream) {
		fclose(handle.logstream);
		handle.logstream = null;
	}
	if(handle.usesyslog) {
		handle.usesyslog = 0;
		closelog();
	}

version (HAVE_LIBGPGME) {
	FREELIST(handle.known_keys);
}

version (HAVE_LIBCURL) {
	curl_multi_cleanup(handle.curlm);
	curl_global_cleanup();
	FREELIST(handle.server_errors);
}

	/* free memory */
	_alpm_trans_free(handle.trans);
	FREE(handle.root);
	FREE(handle.dbpath);
	FREE(handle.dbext);
	FREELIST(handle.cachedirs);
	FREELIST(handle.hookdirs);
	FREE(handle.logfile);
	FREE(handle.lockfile);
	FREELIST(handle.architectures);
	FREE(handle.gpgdir);
	FREE(handle.sandboxuser);
	FREELIST(handle.noupgrade);
	FREELIST(handle.noextract);
	FREELIST(handle.ignorepkg);
	FREELIST(handle.ignoregroup);
	FREELIST(handle.overwrite_files);

	alpm_list_free_inner(handle.assumeinstalled, cast(alpm_list_fn_free)alpm_dep_free);
	alpm_list_free(handle.assumeinstalled);

	FREE(handle);
}

/** Lock the database */
int _alpm_handle_lock(alpm_handle_t* handle)
{
	char* dir = void, ptr = void;

	ASSERT(handle.lockfile != null);
	ASSERT(handle.lockfd < 0);

	/* create the dir of the lockfile first */
	STRDUP(dir, handle.lockfile);
	ptr = strrchr(dir, '/');
	if(ptr) {
		*ptr = '\0';
	}
	if(_alpm_makepath(dir)) {
		FREE(dir);
		return -1;
	}
	FREE(dir);

	do {
		handle.lockfd = open(handle.lockfile, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0000);
	} while(handle.lockfd == -1 && errno == EINTR);

	return (handle.lockfd >= 0 ? 0 : -1);
}

int  alpm_unlock(alpm_handle_t* handle)
{
	ASSERT(handle != null);
	ASSERT(handle.lockfile != null);
	ASSERT(handle.lockfd >= 0);

	close(handle.lockfd);
	handle.lockfd = -1;

	if(unlink(handle.lockfile) != 0) {
		RET_ERR_ASYNC_SAFE(handle, ALPM_ERR_SYSTEM, -1);
	} else {
		return 0;
	}
}

int _alpm_handle_unlock(alpm_handle_t* handle)
{
	if(alpm_unlock(handle) != 0) {
		if(errno == ENOENT) {
			_alpm_log(handle, ALPM_LOG_WARNING,
					_("lock file missing %s\n"), handle.lockfile);
			alpm_logaction(handle, ALPM_CALLER_PREFIX,
					"warning: lock file missing %s\n", handle.lockfile);
			return 0;
		} else {
			_alpm_log(handle, ALPM_LOG_WARNING,
					_("could not remove lock file %s\n"), handle.lockfile);
			alpm_logaction(handle, ALPM_CALLER_PREFIX,
					"warning: could not remove lock file %s\n", handle.lockfile);
			return -1;
		}
	}

	return 0;
}


alpm_cb_log  alpm_option_get_logcb(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.logcb;
}

void * alpm_option_get_logcb_ctx(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.logcb_ctx;
}

alpm_cb_download  alpm_option_get_dlcb(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.dlcb;
}

void * alpm_option_get_dlcb_ctx(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.dlcb_ctx;
}

alpm_cb_fetch  alpm_option_get_fetchcb(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.fetchcb;
}

void * alpm_option_get_fetchcb_ctx(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.fetchcb_ctx;
}

alpm_cb_event  alpm_option_get_eventcb(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.eventcb;
}

void * alpm_option_get_eventcb_ctx(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.eventcb_ctx;
}

alpm_cb_question  alpm_option_get_questioncb(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.questioncb;
}

void * alpm_option_get_questioncb_ctx(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.questioncb_ctx;
}

alpm_cb_progress  alpm_option_get_progresscb(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.progresscb;
}

void * alpm_option_get_progresscb_ctx(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.progresscb_ctx;
}

const(char)* alpm_option_get_root(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.root;
}

const(char)* alpm_option_get_dbpath(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.dbpath;
}

alpm_list_t * alpm_option_get_hookdirs(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.hookdirs;
}

alpm_list_t * alpm_option_get_cachedirs(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.cachedirs;
}

const(char)* alpm_option_get_logfile(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.logfile;
}

const(char)* alpm_option_get_lockfile(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.lockfile;
}

const(char)* alpm_option_get_gpgdir(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.gpgdir;
}

const(char)* alpm_option_get_sandboxuser(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.sandboxuser;
}

int  alpm_option_get_usesyslog(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return -1);
	return handle.usesyslog;
}

alpm_list_t * alpm_option_get_noupgrades(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.noupgrade;
}

alpm_list_t * alpm_option_get_noextracts(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.noextract;
}

alpm_list_t * alpm_option_get_ignorepkgs(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.ignorepkg;
}

alpm_list_t * alpm_option_get_ignoregroups(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.ignoregroup;
}

alpm_list_t * alpm_option_get_overwrite_files(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.overwrite_files;
}

alpm_list_t * alpm_option_get_assumeinstalled(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.assumeinstalled;
}

alpm_list_t * alpm_option_get_architectures(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.architectures;
}

int  alpm_option_get_checkspace(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return -1);
	return handle.checkspace;
}

const(char)* alpm_option_get_dbext(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.dbext;
}

int  alpm_option_get_parallel_downloads(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return -1);
	return handle.parallel_downloads;
}

int  alpm_option_set_logcb(alpm_handle_t* handle, alpm_cb_log cb, void* ctx)
{
	CHECK_HANDLE(handle, return -1);
	handle.logcb = cb;
	handle.logcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_dlcb(alpm_handle_t* handle, alpm_cb_download cb, void* ctx)
{
	CHECK_HANDLE(handle, return -1);
	handle.dlcb = cb;
	handle.dlcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_fetchcb(alpm_handle_t* handle, alpm_cb_fetch cb, void* ctx)
{
	CHECK_HANDLE(handle, return -1);
	handle.fetchcb = cb;
	handle.fetchcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_eventcb(alpm_handle_t* handle, alpm_cb_event cb, void* ctx)
{
	CHECK_HANDLE(handle, return -1);
	handle.eventcb = cb;
	handle.eventcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_questioncb(alpm_handle_t* handle, alpm_cb_question cb, void* ctx)
{
	CHECK_HANDLE(handle, return -1);
	handle.questioncb = cb;
	handle.questioncb_ctx = ctx;
	return 0;
}

int  alpm_option_set_progresscb(alpm_handle_t* handle, alpm_cb_progress cb, void* ctx)
{
	CHECK_HANDLE(handle, return -1);
	handle.progresscb = cb;
	handle.progresscb_ctx = ctx;
	return 0;
}

private char* canonicalize_path(const(char)* path)
{
	char* new_path = void;
	size_t len = void;

	/* verify path ends in a '/' */
	len = strlen(path);
	if(path[len - 1] != '/') {
		len += 1;
	}
	CALLOC(new_path, len + 1, char.sizeof, return NULL);
	strcpy(new_path, path);
	new_path[len - 1] = '/';
	return new_path;
}

alpm_errno_t _alpm_set_directory_option(const(char)* value, char** storage, int must_exist)
{
	stat st = void;
	char[PATH_MAX] real_ = void;
	const(char)* path = void;

	path = value;
	if(!path) {
		return ALPM_ERR_WRONG_ARGS;
	}
	if(must_exist) {
		if(stat(path, &st) == -1 || !S_ISDIR(st.st_mode)) {
			return ALPM_ERR_NOT_A_DIR;
		}
		if(!realpath(path, real_)) {
			return ALPM_ERR_NOT_A_DIR;
		}
		path = real_;
	}

	if(*storage) {
		FREE(*storage);
	}
	*storage = canonicalize_path(path);
	if(!*storage) {
		return ALPM_ERR_MEMORY;
	}
	return 0;
}

int  alpm_option_add_hookdir(alpm_handle_t* handle, const(char)* hookdir)
{
	char* newhookdir = void;

	CHECK_HANDLE(handle, return -1);
	ASSERT(hookdir != null);

	newhookdir = canonicalize_path(hookdir);
	if(!newhookdir) {
		RET_ERR(handle, ALPM_ERR_MEMORY, -1);
	}
	handle.hookdirs = alpm_list_add(handle.hookdirs, newhookdir);
	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'hookdir' = %s\n", newhookdir);
	return 0;
}

int  alpm_option_set_hookdirs(alpm_handle_t* handle, alpm_list_t* hookdirs)
{
	alpm_list_t* i = void;
	CHECK_HANDLE(handle, return -1);
	if(handle.hookdirs) {
		FREELIST(handle.hookdirs);
	}
	for(i = hookdirs; i; i = i.next) {
		int ret = alpm_option_add_hookdir(handle, i.data);
		if(ret) {
			return ret;
		}
	}
	return 0;
}

int  alpm_option_remove_hookdir(alpm_handle_t* handle, const(char)* hookdir)
{
	char* vdata = null;
	char* newhookdir = void;
	CHECK_HANDLE(handle, return -1);
	ASSERT(hookdir != null);

	newhookdir = canonicalize_path(hookdir);
	if(!newhookdir) {
		RET_ERR(handle, ALPM_ERR_MEMORY, -1);
	}
	handle.hookdirs = alpm_list_remove_str(handle.hookdirs, newhookdir, &vdata);
	FREE(newhookdir);
	if(vdata != null) {
		FREE(vdata);
		return 1;
	}
	return 0;
}

int  alpm_option_add_cachedir(alpm_handle_t* handle, const(char)* cachedir)
{
	char* newcachedir = void;

	CHECK_HANDLE(handle, return -1);
	ASSERT(cachedir != null);
	/* don't stat the cachedir yet, as it may not even be needed. we can
	 * fail later if it is needed and the path is invalid. */

	newcachedir = canonicalize_path(cachedir);
	if(!newcachedir) {
		RET_ERR(handle, ALPM_ERR_MEMORY, -1);
	}
	handle.cachedirs = alpm_list_add(handle.cachedirs, newcachedir);
	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'cachedir' = %s\n", newcachedir);
	return 0;
}

int  alpm_option_set_cachedirs(alpm_handle_t* handle, alpm_list_t* cachedirs)
{
	alpm_list_t* i = void;
	CHECK_HANDLE(handle, return -1);
	if(handle.cachedirs) {
		FREELIST(handle.cachedirs);
	}
	for(i = cachedirs; i; i = i.next) {
		int ret = alpm_option_add_cachedir(handle, i.data);
		if(ret) {
			return ret;
		}
	}
	return 0;
}

int  alpm_option_remove_cachedir(alpm_handle_t* handle, const(char)* cachedir)
{
	char* vdata = null;
	char* newcachedir = void;
	CHECK_HANDLE(handle, return -1);
	ASSERT(cachedir != null);

	newcachedir = canonicalize_path(cachedir);
	if(!newcachedir) {
		RET_ERR(handle, ALPM_ERR_MEMORY, -1);
	}
	handle.cachedirs = alpm_list_remove_str(handle.cachedirs, newcachedir, &vdata);
	FREE(newcachedir);
	if(vdata != null) {
		FREE(vdata);
		return 1;
	}
	return 0;
}

int  alpm_option_set_logfile(alpm_handle_t* handle, const(char)* logfile)
{
	char* oldlogfile = handle.logfile;

	CHECK_HANDLE(handle, return -1);
	if(!logfile) {
		handle.pm_errno = ALPM_ERR_WRONG_ARGS;
		return -1;
	}

	STRDUP(handle.logfile, logfile);

	/* free the old logfile path string, and close the stream so logaction
	 * will reopen a new stream on the new logfile */
	if(oldlogfile) {
		FREE(oldlogfile);
	}
	if(handle.logstream) {
		fclose(handle.logstream);
		handle.logstream = null;
	}
	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'logfile' = %s\n", handle.logfile);
	return 0;
}

int  alpm_option_set_gpgdir(alpm_handle_t* handle, const(char)* gpgdir)
{
	int err = void;
	CHECK_HANDLE(handle, return -1);
	if((err = _alpm_set_directory_option(gpgdir, &(handle.gpgdir), 0))) {
		RET_ERR(handle, err, -1);
	}
	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'gpgdir' = %s\n", handle.gpgdir);
	return 0;
}

int  alpm_option_set_sandboxuser(alpm_handle_t* handle, const(char)* sandboxuser)
{
	CHECK_HANDLE(handle, return -1);
	if(handle.sandboxuser) {
		FREE(handle.sandboxuser);
	}

	STRDUP(handle.sandboxuser, sandboxuser);

	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'sandboxuser' = %s\n", handle.sandboxuser);
	return 0;
}

int  alpm_option_set_usesyslog(alpm_handle_t* handle, int usesyslog)
{
	CHECK_HANDLE(handle, return -1);
	handle.usesyslog = usesyslog;
	return 0;
}

private int _alpm_option_strlist_add(alpm_handle_t* handle, alpm_list_t** list, const(char)* str)
{
	char* dup = void;
	CHECK_HANDLE(handle, return -1);
	STRDUP(dup, str);
	*list = alpm_list_add(*list, dup);
	return 0;
}

private int _alpm_option_strlist_set(alpm_handle_t* handle, alpm_list_t** list, alpm_list_t* newlist)
{
	CHECK_HANDLE(handle, return -1);
	FREELIST(*list);
	*list = alpm_list_strdup(newlist);
	return 0;
}

private int _alpm_option_strlist_rem(alpm_handle_t* handle, alpm_list_t** list, const(char)* str)
{
	char* vdata = null;
	CHECK_HANDLE(handle, return -1);
	*list = alpm_list_remove_str(*list, str, &vdata);
	if(vdata != null) {
		FREE(vdata);
		return 1;
	}
	return 0;
}

int  alpm_option_add_noupgrade(alpm_handle_t* handle, const(char)* pkg)
{
	return _alpm_option_strlist_add(handle, &(handle.noupgrade), pkg);
}

int  alpm_option_set_noupgrades(alpm_handle_t* handle, alpm_list_t* noupgrade)
{
	return _alpm_option_strlist_set(handle, &(handle.noupgrade), noupgrade);
}

int  alpm_option_remove_noupgrade(alpm_handle_t* handle, const(char)* pkg)
{
	return _alpm_option_strlist_rem(handle, &(handle.noupgrade), pkg);
}

int  alpm_option_match_noupgrade(alpm_handle_t* handle, const(char)* path)
{
	return _alpm_fnmatch_patterns(handle.noupgrade, path);
}

int  alpm_option_add_noextract(alpm_handle_t* handle, const(char)* path)
{
	return _alpm_option_strlist_add(handle, &(handle.noextract), path);
}

int  alpm_option_set_noextracts(alpm_handle_t* handle, alpm_list_t* noextract)
{
	return _alpm_option_strlist_set(handle, &(handle.noextract), noextract);
}

int  alpm_option_remove_noextract(alpm_handle_t* handle, const(char)* path)
{
	return _alpm_option_strlist_rem(handle, &(handle.noextract), path);
}

int  alpm_option_match_noextract(alpm_handle_t* handle, const(char)* path)
{
	return _alpm_fnmatch_patterns(handle.noextract, path);
}

int  alpm_option_add_ignorepkg(alpm_handle_t* handle, const(char)* pkg)
{
	return _alpm_option_strlist_add(handle, &(handle.ignorepkg), pkg);
}

int  alpm_option_set_ignorepkgs(alpm_handle_t* handle, alpm_list_t* ignorepkgs)
{
	return _alpm_option_strlist_set(handle, &(handle.ignorepkg), ignorepkgs);
}

int  alpm_option_remove_ignorepkg(alpm_handle_t* handle, const(char)* pkg)
{
	return _alpm_option_strlist_rem(handle, &(handle.ignorepkg), pkg);
}

int  alpm_option_add_ignoregroup(alpm_handle_t* handle, const(char)* grp)
{
	return _alpm_option_strlist_add(handle, &(handle.ignoregroup), grp);
}

int  alpm_option_set_ignoregroups(alpm_handle_t* handle, alpm_list_t* ignoregrps)
{
	return _alpm_option_strlist_set(handle, &(handle.ignoregroup), ignoregrps);
}

int  alpm_option_remove_ignoregroup(alpm_handle_t* handle, const(char)* grp)
{
	return _alpm_option_strlist_rem(handle, &(handle.ignoregroup), grp);
}

int  alpm_option_add_overwrite_file(alpm_handle_t* handle, const(char)* glob)
{
	return _alpm_option_strlist_add(handle, &(handle.overwrite_files), glob);
}

int  alpm_option_set_overwrite_files(alpm_handle_t* handle, alpm_list_t* globs)
{
	return _alpm_option_strlist_set(handle, &(handle.overwrite_files), globs);
}

int  alpm_option_remove_overwrite_file(alpm_handle_t* handle, const(char)* glob)
{
	return _alpm_option_strlist_rem(handle, &(handle.overwrite_files), glob);
}

int  alpm_option_add_assumeinstalled(alpm_handle_t* handle, const(alpm_depend_t)* dep)
{
	alpm_depend_t* depcpy = void;
	CHECK_HANDLE(handle, return -1);
	ASSERT(dep.mod == ALPM_DEP_MOD_EQ || dep.mod == ALPM_DEP_MOD_ANY);
	ASSERT((depcpy = _alpm_dep_dup(dep)));

	/* fill in name_hash in case dep was built by hand */
	depcpy.name_hash = _alpm_hash_sdbm(dep.name);
	handle.assumeinstalled = alpm_list_add(handle.assumeinstalled, depcpy);
	return 0;
}

int  alpm_option_set_assumeinstalled(alpm_handle_t* handle, alpm_list_t* deps)
{
	CHECK_HANDLE(handle, return -1);
	if(handle.assumeinstalled) {
		alpm_list_free_inner(handle.assumeinstalled, cast(alpm_list_fn_free)alpm_dep_free);
		alpm_list_free(handle.assumeinstalled);
		handle.assumeinstalled = null;
	}
	while(deps) {
		if(alpm_option_add_assumeinstalled(handle, deps.data) != 0) {
			return -1;
		}
		deps = deps.next;
	}
	return 0;
}

private int assumeinstalled_cmp(const(void)* d1, const(void)* d2)
{
	const(alpm_depend_t)* dep1 = d1;
	const(alpm_depend_t)* dep2 = d2;

	if(dep1.name_hash != dep2.name_hash
			|| strcmp(dep1.name, dep2.name) != 0) {
		return -1;
	}

	if(dep1.version_ && dep2.version_
			&& strcmp(dep1.version_, dep2.version_) == 0) {
		return 0;
	}

	if(dep1.version_ == null && dep2.version_ == null) {
		return 0;
	}


	return -1;
}

int  alpm_option_remove_assumeinstalled(alpm_handle_t* handle, const(alpm_depend_t)* dep)
{
	alpm_depend_t* vdata = null;
	CHECK_HANDLE(handle, return -1);

	handle.assumeinstalled = alpm_list_remove(handle.assumeinstalled, dep, &assumeinstalled_cmp, cast(void**)&vdata);
	if(vdata != null) {
		alpm_dep_free(vdata);
		return 1;
	}

	return 0;
}

int  alpm_option_add_architecture(alpm_handle_t* handle, const(char)* arch)
{
	handle.architectures = alpm_list_add(handle.architectures, strdup(arch));
	return 0;
}

int  alpm_option_set_architectures(alpm_handle_t* handle, alpm_list_t* arches)
{
	CHECK_HANDLE(handle, return -1);
	if(handle.architectures) FREELIST(handle.architectures);
	handle.architectures = alpm_list_strdup(arches);
	return 0;
}

int  alpm_option_remove_architecture(alpm_handle_t* handle, const(char)* arch)
{
	char* vdata = null;
	CHECK_HANDLE(handle, return -1);
	handle.architectures = alpm_list_remove_str(handle.architectures, arch, &vdata);
	if(vdata != null) {
		FREE(vdata);
		return 1;
	}
	return 0;
}

alpm_db_t * alpm_get_localdb(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.db_local;
}

alpm_list_t * alpm_get_syncdbs(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return NULL);
	return handle.dbs_sync;
}

int  alpm_option_set_checkspace(alpm_handle_t* handle, int checkspace)
{
	CHECK_HANDLE(handle, return -1);
	handle.checkspace = checkspace;
	return 0;
}

int  alpm_option_set_dbext(alpm_handle_t* handle, const(char)* dbext)
{
	CHECK_HANDLE(handle, return -1);
	ASSERT(dbext);

	if(handle.dbext) {
		FREE(handle.dbext);
	}

	STRDUP(handle.dbext, dbext);

	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'dbext' = %s\n", handle.dbext);
	return 0;
}

int  alpm_option_set_default_siglevel(alpm_handle_t* handle, int level)
{
	CHECK_HANDLE(handle, return -1);
	if(level == ALPM_SIG_USE_DEFAULT) {
		RET_ERR(handle, ALPM_ERR_WRONG_ARGS, -1);
	}
version (HAVE_LIBGPGME) {
	handle.siglevel = level;
} else {
	if(level != 0) {
		RET_ERR(handle, ALPM_ERR_MISSING_CAPABILITY_SIGNATURES, -1);
	}
}
	return 0;
}

int  alpm_option_get_default_siglevel(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return -1);
	return handle.siglevel;
}

int  alpm_option_set_local_file_siglevel(alpm_handle_t* handle, int level)
{
	CHECK_HANDLE(handle, return -1);
version (HAVE_LIBGPGME) {
	handle.localfilesiglevel = level;
} else {
	if(level != 0 && level != ALPM_SIG_USE_DEFAULT) {
		RET_ERR(handle, ALPM_ERR_MISSING_CAPABILITY_SIGNATURES, -1);
	}
}
	return 0;
}

int  alpm_option_get_local_file_siglevel(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return -1);
	if(handle.localfilesiglevel & ALPM_SIG_USE_DEFAULT) {
		return handle.siglevel;
	} else {
		return handle.localfilesiglevel;
	}
}

int  alpm_option_set_remote_file_siglevel(alpm_handle_t* handle, int level)
{
	CHECK_HANDLE(handle, return -1);
version (HAVE_LIBGPGME) {
	handle.remotefilesiglevel = level;
} else {
	if(level != 0 && level != ALPM_SIG_USE_DEFAULT) {
		RET_ERR(handle, ALPM_ERR_MISSING_CAPABILITY_SIGNATURES, -1);
	}
}
	return 0;
}

int  alpm_option_get_remote_file_siglevel(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return -1);
	if(handle.remotefilesiglevel & ALPM_SIG_USE_DEFAULT) {
		return handle.siglevel;
	} else {
		return handle.remotefilesiglevel;
	}
}

int  alpm_option_get_disable_dl_timeout(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return -1);
	return handle.disable_dl_timeout;
}

int  alpm_option_set_disable_dl_timeout(alpm_handle_t* handle, ushort disable_dl_timeout)
{
	CHECK_HANDLE(handle, return -1);
	handle.disable_dl_timeout = disable_dl_timeout;
	return 0;
}

int  alpm_option_set_parallel_downloads(alpm_handle_t* handle, uint num_streams)
{
	CHECK_HANDLE(handle, return -1);
	ASSERT(num_streams >= 1);
	handle.parallel_downloads = num_streams;
	return 0;
}

int  alpm_option_get_disable_sandbox(alpm_handle_t* handle)
{
	CHECK_HANDLE(handle, return -1);
	return handle.disable_sandbox;
}

int  alpm_option_set_disable_sandbox(alpm_handle_t* handle, ushort disable_sandbox)
{
	CHECK_HANDLE(handle, return -1);
	handle.disable_sandbox = disable_sandbox;
	return 0;
}
