module libalpmd.handle;
@nogc  
   
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
import core.sys.posix.stdlib;
import core.stdc.string;
import core.stdc.limits;
import core.sys.posix.sys.types;
import core.sys.posix.syslog;
import core.sys.posix.sys.stat;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;;


/* libalpm */
import libalpmd.handle;
import libalpmd.alpm_list;
import libalpmd.util;
import libalpmd.log;
import libalpmd.trans;
import libalpmd.alpm;
import libalpmd.deps;
import core.stdc.stdio;

void EVENT(h, e)(h handle, e event) { 
	if(handle.eventcb) { 
		handle.eventcb(handle.eventcb_ctx, cast(alpm_event_t*) event);
	}
} 

void QUESTION(H, Q)(H h, Q q) {
	if((h).questioncb) {
		(h).questioncb((h).questioncb_ctx, cast(alpm_question_t *) (q));
	}
}
void PROGRESS(H, E, P, PER, N, R)(H h, E e, P p, PER per, N n, R r){
	if((h).progresscb) {
		(h).progresscb((h).progresscb_ctx, e, cast(char*)p, per, n, r);
	}
}

class AlpmHandle {
	/* internal usage */
	alpm_db_t* db_local;    /* local db pointer */
	alpm_list_t* dbs_sync;  /* List of (alpm_db_t *) */
	FILE* logstream;        /* log file stream pointer */
	alpm_trans_t* trans;

version (HAVE_LIBCURL) {
	/* libcurl handle */
	CURLM* curlm;
	alpm_list_t* server_errors;
}

	ushort disable_dl_timeout;
	ushort disable_sandbox;
	uint parallel_downloads; /* number of download streams */

version (HAVE_LIBGPGME) {
	alpm_list_t* known_keys;  /* keys verified to be in our keychain */
}

	/* callback functions */
	alpm_cb_log logcb;          /* Log callback function */
	void* logcb_ctx;
	alpm_cb_download dlcb;      /* Download callback function */
	void* dlcb_ctx;
	alpm_cb_fetch fetchcb;      /* Download file callback function */
	void* fetchcb_ctx;
	alpm_cb_event eventcb;
	void* eventcb_ctx;
	alpm_cb_question questioncb;
	void* questioncb_ctx;
	alpm_cb_progress progresscb;
	void* progresscb_ctx;

	/* filesystem paths */
	char* root;              /* Root path, default '/' */
	char* dbpath;            /* Base path to pacman's DBs */
	char* logfile;           /* Name of the log file */
	char* lockfile;          /* Name of the lock file */
	char* gpgdir;            /* Directory where GnuPG files are stored */
	char* sandboxuser;       /* User to switch to for sensitive operations */
	alpm_list_t* cachedirs;  /* Paths to pacman cache directories */
	alpm_list_t* hookdirs;   /* Paths to hook directories */
	alpm_list_t* overwrite_files; /* Paths that may be overwritten */

	/* package lists */
	alpm_list_t* noupgrade;   /* List of packages NOT to be upgraded */
	alpm_list_t* noextract;   /* List of files NOT to extract */
	alpm_list_t* ignorepkg;   /* List of packages to ignore */
	alpm_list_t* ignoregroup; /* List of groups to ignore */
	alpm_list_t* assumeinstalled;   /* List of virtual packages used to satisfy dependencies */

	/* options */
	alpm_list_t* architectures; /* Architectures of packages we should allow */
	int usesyslog;           /* Use syslog instead of logfile? */ /* TODO move to frontend */
	int checkspace;          /* Check disk space before installing */
	char* dbext;             /* Sync DB extension */
	int siglevel;            /* Default signature verification level */
	int localfilesiglevel;   /* Signature verification level for local file
	                                       upgrade operations */
	int remotefilesiglevel;  /* Signature verification level for remote file
	                                       upgrade operations */

	/* error code */
	alpm_errno_t pm_errno;

	/* lock file descriptor */
	int lockfd;

	this() {
		this.lockfd = -1;
	}

	/** Lock the database */
	int lock()
	{
		char* dir = void, ptr = void;

		assert(this.lockfile != null);
		assert(this.lockfd < 0);

		/* create the dir of the lockfile first */
		STRDUP(dir, this.lockfile);
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
			this.lockfd = open(this.lockfile, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0000);
		} while(this.lockfd == -1 && errno == EINTR);

		return (this.lockfd >= 0 ? 0 : -1);
	}
}

/* free all in-memory resources */
void _alpm_handle_free(AlpmHandle handle)
{
	alpm_list_t* i = void;
	alpm_db_t* db = void;

	if(handle is null) {
		return;
	}

	/* close local database */
	if(cast(bool)(db = handle.db_local)) {
		db.ops.unregister(db);
	}

	/* unregister all sync dbs */
	for(i = handle.dbs_sync; i; i = i.next) {
		db = cast(alpm_db_t*)i.data;
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

	alpm_list_free_inner(handle.assumeinstalled, cast(alpm_list_fn_free)&alpm_dep_free);
	alpm_list_free(handle.assumeinstalled);

	FREE(handle);
}

int  alpm_unlock(AlpmHandle handle)
{
	//ASSERT(handle != null);
	//ASSERT(handle.lockfile != null);
	//ASSERT(handle.lockfd >= 0);

	close(handle.lockfd);
	handle.lockfd = -1;

	if(unlink(handle.lockfile) != 0) {
		RET_ERR_ASYNC_SAFE(handle, ALPM_ERR_SYSTEM, -1);
		assert(0);
	} else {
		return 0;
	}
}

int _alpm_handle_unlock(AlpmHandle handle)
{
	if(alpm_unlock(handle) != 0) {
		if(errno == ENOENT) {
			_alpm_log(handle, ALPM_LOG_WARNING,
					("lock file missing %s\n"), handle.lockfile);
			// alpm_logaction(handle, ALPM_CALLER_PREFIX,
					// "warning: lock file missing %s\n", handle.lockfile);
			return 0;
		} else {
			_alpm_log(handle, ALPM_LOG_WARNING,
					("could not remove lock file %s\n"), handle.lockfile);
			// alpm_logaction(handle, ALPM_CALLER_PREFIX,
			// 		"warning: could not remove lock file %s\n", handle.lockfile);
			return -1;
		}
	}

	return 0;
}


alpm_cb_log  alpm_option_get_logcb(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.logcb;
}

void * alpm_option_get_logcb_ctx(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.logcb_ctx;
}

alpm_cb_download  alpm_option_get_dlcb(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.dlcb;
}

void * alpm_option_get_dlcb_ctx(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.dlcb_ctx;
}

alpm_cb_fetch  alpm_option_get_fetchcb(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.fetchcb;
}

void * alpm_option_get_fetchcb_ctx(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.fetchcb_ctx;
}

alpm_cb_event  alpm_option_get_eventcb(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.eventcb;
}

void * alpm_option_get_eventcb_ctx(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.eventcb_ctx;
}

alpm_cb_question  alpm_option_get_questioncb(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.questioncb;
}

void * alpm_option_get_questioncb_ctx(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.questioncb_ctx;
}

alpm_cb_progress  alpm_option_get_progresscb(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.progresscb;
}

void * alpm_option_get_progresscb_ctx(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.progresscb_ctx;
}

char* alpm_option_get_root(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.root;
}

char* alpm_option_get_dbpath(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.dbpath;
}

alpm_list_t * alpm_option_get_hookdirs(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.hookdirs;
}

alpm_list_t * alpm_option_get_cachedirs(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.cachedirs;
}

char* alpm_option_get_logfile(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.logfile;
}

char* alpm_option_get_lockfile(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.lockfile;
}

char* alpm_option_get_gpgdir(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.gpgdir;
}

char* alpm_option_get_sandboxuser(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.sandboxuser;
}

int  alpm_option_get_usesyslog(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.usesyslog;
}

alpm_list_t * alpm_option_get_noupgrades(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.noupgrade;
}

alpm_list_t * alpm_option_get_noextracts(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.noextract;
}

alpm_list_t * alpm_option_get_ignorepkgs(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.ignorepkg;
}

alpm_list_t * alpm_option_get_ignoregroups(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.ignoregroup;
}

alpm_list_t * alpm_option_get_overwrite_files(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.overwrite_files;
}

alpm_list_t * alpm_option_get_assumeinstalled(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.assumeinstalled;
}

alpm_list_t * alpm_option_get_architectures(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.architectures;
}

int  alpm_option_get_checkspace(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.checkspace;
}

char* alpm_option_get_dbext(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.dbext;
}

int  alpm_option_get_parallel_downloads(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.parallel_downloads;
}

int  alpm_option_set_logcb(AlpmHandle handle, alpm_cb_log cb, void* ctx)
{
	CHECK_HANDLE(handle);
	handle.logcb = cb;
	handle.logcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_dlcb(AlpmHandle handle, alpm_cb_download cb, void* ctx)
{
	CHECK_HANDLE(handle);
	handle.dlcb = cb;
	handle.dlcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_fetchcb(AlpmHandle handle, alpm_cb_fetch cb, void* ctx)
{
	CHECK_HANDLE(handle);
	handle.fetchcb = cb;
	handle.fetchcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_eventcb(AlpmHandle handle, alpm_cb_event cb, void* ctx)
{
	CHECK_HANDLE(handle);
	handle.eventcb = cb;
	handle.eventcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_questioncb(AlpmHandle handle, alpm_cb_question cb, void* ctx)
{
	CHECK_HANDLE(handle);
	handle.questioncb = cb;
	handle.questioncb_ctx = ctx;
	return 0;
}

int  alpm_option_set_progresscb(AlpmHandle handle, alpm_cb_progress cb, void* ctx)
{
	CHECK_HANDLE(handle);
	handle.progresscb = cb;
	handle.progresscb_ctx = ctx;
	return 0;
}

char* canonicalize_path(char* path)
{
	char* new_path = void;
	size_t len = void;

	/* verify path ends in a '/' */
	len = strlen(path);
	if(path[len - 1] != '/') {
		len += 1;
	}
	CALLOC(new_path, len + 1, char.sizeof);
	strcpy(new_path, path);
	new_path[len - 1] = '/';
	return new_path;
}

alpm_errno_t _alpm_set_directory_option(char* value, char** storage, int must_exist)
{
	stat_t st = void;
	char[PATH_MAX] real_ = void;
	char* path = void;

	path = value;
	if(!path) {
		return ALPM_ERR_WRONG_ARGS;
	}
	if(must_exist) {
		if(stat(path, &st) == -1 || !S_ISDIR(st.st_mode)) {
			return ALPM_ERR_NOT_A_DIR;
		}
		if(!realpath(path, real_.ptr)) {
			return ALPM_ERR_NOT_A_DIR;
		}
		path = real_.ptr;
	}

	if(*storage) {
		FREE(*storage);
	}
	*storage = canonicalize_path(path);
	if(!*storage) {
		return ALPM_ERR_MEMORY;
	}
	return cast(alpm_errno_t)0;
}

int  alpm_option_add_hookdir(AlpmHandle handle, char* hookdir)
{
	char* newhookdir = void;

	CHECK_HANDLE(handle);
	//ASSERT(hookdir != null);

	newhookdir = canonicalize_path(hookdir);
	if(!newhookdir) {
		RET_ERR(handle, ALPM_ERR_MEMORY, -1);
	}
	handle.hookdirs = alpm_list_add(handle.hookdirs, newhookdir);
	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'hookdir' = %s\n", newhookdir);
	return 0;
}

int  alpm_option_set_hookdirs(AlpmHandle handle, alpm_list_t* hookdirs)
{
	alpm_list_t* i = void;
	CHECK_HANDLE(handle);
	if(handle.hookdirs) {
		FREELIST(handle.hookdirs);
	}
	for(i = hookdirs; i; i = i.next) {
		int ret = alpm_option_add_hookdir(handle, cast(char*)i.data);
		if(ret) {
			return ret;
		}
	}
	return 0;
}

int  alpm_option_remove_hookdir(AlpmHandle handle, char* hookdir)
{
	char* vdata = null;
	char* newhookdir = void;
	CHECK_HANDLE(handle);
	//ASSERT(hookdir != null);

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

int  alpm_option_add_cachedir(AlpmHandle handle,  char*cachedir)
{
	char* newcachedir = void;

	CHECK_HANDLE(handle);
	//ASSERT(cachedir != null);
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

int  alpm_option_set_cachedirs(AlpmHandle handle, alpm_list_t* cachedirs)
{
	alpm_list_t* i = void;
	CHECK_HANDLE(handle);
	if(handle.cachedirs) {
		FREELIST(handle.cachedirs);
	}
	for(i = cachedirs; i; i = i.next) {
		int ret = alpm_option_add_cachedir(handle, cast(char*)i.data);
		if(ret) {
			return ret;
		}
	}
	return 0;
}

int  alpm_option_remove_cachedir(AlpmHandle handle,   char*cachedir)
{
	char* vdata = null;
	char* newcachedir = void;
	CHECK_HANDLE(handle);
	//ASSERT(cachedir != null);

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

int  alpm_option_set_logfile(AlpmHandle handle,   char*logfile)
{
	char* oldlogfile = handle.logfile;

	CHECK_HANDLE(handle);
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

int  alpm_option_set_gpgdir(AlpmHandle handle,   char*gpgdir)
{
	int err = void;
	CHECK_HANDLE(handle);
	if(cast(bool)(err = _alpm_set_directory_option(gpgdir, &(handle.gpgdir), 0))) {
		RET_ERR(handle, err, -1);
	}
	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'gpgdir' = %s\n", handle.gpgdir);
	return 0;
}

int  alpm_option_set_sandboxuser(AlpmHandle handle,   char*sandboxuser)
{
	CHECK_HANDLE(handle);
	if(handle.sandboxuser) {
		FREE(handle.sandboxuser);
	}

	STRDUP(handle.sandboxuser, sandboxuser);

	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'sandboxuser' = %s\n", handle.sandboxuser);
	return 0;
}

int  alpm_option_set_usesyslog(AlpmHandle handle, int usesyslog)
{
	CHECK_HANDLE(handle);
	handle.usesyslog = usesyslog;
	return 0;
}

int _alpm_option_strlist_add(AlpmHandle handle, alpm_list_t** list,   char*str)
{
	char* dup = void;
	CHECK_HANDLE(handle);
	STRDUP(dup, str);
	*list = alpm_list_add(*list, dup);
	return 0;
}

int _alpm_option_strlist_set(AlpmHandle handle, alpm_list_t** list, alpm_list_t* newlist)
{
	CHECK_HANDLE(handle);
	FREELIST(*list);
	*list = alpm_list_strdup(newlist);
	return 0;
}

int _alpm_option_strlist_rem(AlpmHandle handle, alpm_list_t** list, char* str)
{
	char* vdata = null;
	CHECK_HANDLE(handle);
	*list = alpm_list_remove_str(*list, str, &vdata);
	if(vdata != null) {
		FREE(vdata);
		return 1;
	}
	return 0;
}

int  alpm_option_add_noupgrade(AlpmHandle handle, char* pkg)
{
	return _alpm_option_strlist_add(handle, &(handle.noupgrade), pkg);
}

int  alpm_option_set_noupgrades(AlpmHandle handle, alpm_list_t* noupgrade)
{
	return _alpm_option_strlist_set(handle, &(handle.noupgrade), noupgrade);
}

int  alpm_option_remove_noupgrade(AlpmHandle handle, char* pkg)
{
	return _alpm_option_strlist_rem(handle, &(handle.noupgrade), pkg);
}

int  alpm_option_match_noupgrade(AlpmHandle handle, char* path)
{
	return _alpm_fnmatch_patterns(handle.noupgrade, path);
}

int  alpm_option_add_noextract(AlpmHandle handle, char* path)
{
	return _alpm_option_strlist_add(handle, &(handle.noextract), path);
}

int  alpm_option_set_noextracts(AlpmHandle handle, alpm_list_t* noextract)
{
	return _alpm_option_strlist_set(handle, &(handle.noextract), noextract);
}

int  alpm_option_remove_noextract(AlpmHandle handle, char* path)
{
	return _alpm_option_strlist_rem(handle, &(handle.noextract), path);
}

int  alpm_option_match_noextract(AlpmHandle handle, char* path)
{
	return _alpm_fnmatch_patterns(handle.noextract, path);
}

int  alpm_option_add_ignorepkg(AlpmHandle handle, char* pkg)
{
	return _alpm_option_strlist_add(handle, &(handle.ignorepkg), pkg);
}

int  alpm_option_set_ignorepkgs(AlpmHandle handle, alpm_list_t* ignorepkgs)
{
	return _alpm_option_strlist_set(handle, &(handle.ignorepkg), ignorepkgs);
}

int  alpm_option_remove_ignorepkg(AlpmHandle handle, char* pkg)
{
	return _alpm_option_strlist_rem(handle, &(handle.ignorepkg), pkg);
}

int  alpm_option_add_ignoregroup(AlpmHandle handle, char* grp)
{
	return _alpm_option_strlist_add(handle, &(handle.ignoregroup), grp);
}

int  alpm_option_set_ignoregroups(AlpmHandle handle, alpm_list_t* ignoregrps)
{
	return _alpm_option_strlist_set(handle, &(handle.ignoregroup), ignoregrps);
}

int  alpm_option_remove_ignoregroup(AlpmHandle handle, char* grp)
{
	return _alpm_option_strlist_rem(handle, &(handle.ignoregroup), grp);
}

int  alpm_option_add_overwrite_file(AlpmHandle handle, char* glob)
{
	return _alpm_option_strlist_add(handle, &(handle.overwrite_files), glob);
}

int  alpm_option_set_overwrite_files(AlpmHandle handle, alpm_list_t* globs)
{
	return _alpm_option_strlist_set(handle, &(handle.overwrite_files), globs);
}

int  alpm_option_remove_overwrite_file(AlpmHandle handle, char* glob)
{
	return _alpm_option_strlist_rem(handle, &(handle.overwrite_files), glob);
}

int  alpm_option_add_assumeinstalled(AlpmHandle handle, alpm_depend_t* dep)
{
	alpm_depend_t* depcpy = void;
	CHECK_HANDLE(handle);
	//ASSERT(dep.mod == ALPM_DEP_MOD_EQ || dep.mod == ALPM_DEP_MOD_ANY);
	// //ASSERT((depcpy = _alpm_dep_dup(dep)));

	/* fill in name_hash in case dep was built by hand */
	depcpy.name_hash = _alpm_hash_sdbm(dep.name);
	handle.assumeinstalled = alpm_list_add(handle.assumeinstalled, depcpy);
	return 0;
}

int  alpm_option_set_assumeinstalled(AlpmHandle handle, alpm_list_t* deps)
{
	CHECK_HANDLE(handle);
	if(handle.assumeinstalled) {
		alpm_list_free_inner(handle.assumeinstalled, cast(alpm_list_fn_free)&alpm_dep_free);
		alpm_list_free(handle.assumeinstalled);
		handle.assumeinstalled = null;
	}
	while(deps) {
		if(alpm_option_add_assumeinstalled(handle, cast(alpm_depend_t*)deps.data) != 0) {
			return -1;
		}
		deps = deps.next;
	}
	return 0;
}

int assumeinstalled_cmp( void* d1,  void* d2)
{
	 alpm_depend_t* dep1 = cast(alpm_depend_t*)d1;
	 alpm_depend_t* dep2 = cast(alpm_depend_t*)d2;

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

int  alpm_option_remove_assumeinstalled(AlpmHandle handle, alpm_depend_t* dep)
{
	alpm_depend_t* vdata = null;
	CHECK_HANDLE(handle);

	handle.assumeinstalled = alpm_list_remove(handle.assumeinstalled, dep, &assumeinstalled_cmp, cast(void**)&vdata);
	if(vdata != null) {
		alpm_dep_free(vdata);
		return 1;
	}

	return 0;
}

int  alpm_option_add_architecture(AlpmHandle handle, char* arch)
{
	handle.architectures = alpm_list_add(handle.architectures, strdup(arch));
	return 0;
}

int  alpm_option_set_architectures(AlpmHandle handle, alpm_list_t* arches)
{
	CHECK_HANDLE(handle);
	if(handle.architectures) FREELIST(handle.architectures);
	handle.architectures = alpm_list_strdup(arches);
	return 0;
}

int  alpm_option_remove_architecture(AlpmHandle handle, char* arch)
{
	char* vdata = null;
	CHECK_HANDLE(handle);
	handle.architectures = alpm_list_remove_str(handle.architectures, arch, &vdata);
	if(vdata != null) {
		FREE(vdata);
		return 1;
	}
	return 0;
}

alpm_db_t * alpm_get_localdb(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.db_local;
}

alpm_list_t * alpm_get_syncdbs(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.dbs_sync;
}

int  alpm_option_set_checkspace(AlpmHandle handle, int checkspace)
{
	CHECK_HANDLE(handle);
	handle.checkspace = checkspace;
	return 0;
}

int  alpm_option_set_dbext(AlpmHandle handle, char* dbext)
{
	CHECK_HANDLE(handle);
	// //ASSERT(dbext);

	if(handle.dbext) {
		FREE(handle.dbext);
	}

	STRDUP(handle.dbext, dbext);

	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'dbext' = %s\n", handle.dbext);
	return 0;
}

int  alpm_option_set_default_siglevel(AlpmHandle handle, int level)
{
	CHECK_HANDLE(handle);
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

int  alpm_option_get_default_siglevel(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.siglevel;
}

int  alpm_option_set_local_file_siglevel(AlpmHandle handle, int level)
{
	CHECK_HANDLE(handle);
version (HAVE_LIBGPGME) {
	handle.localfilesiglevel = level;
} else {
	if(level != 0 && level != ALPM_SIG_USE_DEFAULT) {
		RET_ERR(handle, ALPM_ERR_MISSING_CAPABILITY_SIGNATURES, -1);
	}
}
	return 0;
}

int  alpm_option_get_local_file_siglevel(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	if(handle.localfilesiglevel & ALPM_SIG_USE_DEFAULT) {
		return handle.siglevel;
	} else {
		return handle.localfilesiglevel;
	}
}

int  alpm_option_set_remote_file_siglevel(AlpmHandle handle, int level)
{
	CHECK_HANDLE(handle);
version (HAVE_LIBGPGME) {
	handle.remotefilesiglevel = level;
} else {
	if(level != 0 && level != ALPM_SIG_USE_DEFAULT) {
		RET_ERR(handle, ALPM_ERR_MISSING_CAPABILITY_SIGNATURES, -1);
	}
}
	return 0;
}

int  alpm_option_get_remote_file_siglevel(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	if(handle.remotefilesiglevel & ALPM_SIG_USE_DEFAULT) {
		return handle.siglevel;
	} else {
		return handle.remotefilesiglevel;
	}
}

int  alpm_option_get_disable_dl_timeout(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.disable_dl_timeout;
}

int  alpm_option_set_disable_dl_timeout(AlpmHandle handle, ushort disable_dl_timeout)
{
	CHECK_HANDLE(handle);
	handle.disable_dl_timeout = disable_dl_timeout;
	return 0;
}

int  alpm_option_set_parallel_downloads(AlpmHandle handle, uint num_streams)
{
	CHECK_HANDLE(handle);
	//ASSERT(num_streams >= 1);
	handle.parallel_downloads = num_streams;
	return 0;
}

int  alpm_option_get_disable_sandbox(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.disable_sandbox;
}

int  alpm_option_set_disable_sandbox(AlpmHandle handle, ushort disable_sandbox)
{
	CHECK_HANDLE(handle);
	handle.disable_sandbox = disable_sandbox;
	return 0;
}
