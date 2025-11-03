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
import core.sys.posix.unistd;


/* libalpm */
import libalpmd.handle;
import std.conv;

import libalpmd.alpm_list;
import libalpmd.util;
import libalpmd.log;
import libalpmd.trans;
import libalpmd.alpm;
import libalpmd.deps;
import core.stdc.stdio;
import libalpmd.db;
import libalpmd.be_sync;
import std.exception;
import std.stdio;
import std.string;


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
	AlpmDB db_local;    /* local db pointer */
	AlpmDBList dbs_sync;  /* List of (AlpmDB) */
	File logstream;        /* log file stream pointer */
	AlpmTrans trans;

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
	string root;              /* Root path, default '/' */
	string dbpath;            /* Base path to pacman's DBs */
	string logfile;           /* Name of the log file */
	string lockfile;          /* Name of the lock file */
	string gpgdir;            /* Directory where GnuPG files are stored */
	string sandboxuser;       /* User to switch to for sensitive operations */
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
	string dbext;             /* Sync DB extension */
	int siglevel;            /* Default signature verification level */
	int localfilesiglevel;   /* Signature verification level for local file
	                                       upgrade operations */
	int remotefilesiglevel;  /* Signature verification level for remote file
	                                       upgrade operations */

	/* error code */
	alpm_errno_t pm_errno;

	/* lock file descriptor */
	int lockfd;

	string getRoot() => this.root;
	string getDBPath() => this.dbpath;
	string getLogfile() => this.logfile;

	this() {
		this.lockfd = -1;
	}

	/** Lock the database */
	int lock() {
		char* dir = void, ptr = void;

		assert(this.lockfile != null);
		assert(this.lockfd < 0);

		/* create the dir of the lockfile first */
		STRDUP(dir, cast(char*)this.lockfile);
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
			this.lockfd = open(cast(char*)this.lockfile, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0000);
		} while(this.lockfd == -1 && errno == EINTR);

		return (this.lockfd >= 0 ? 0 : -1);
	}

	int  unlock() {
		assert(this.lockfile != null);
		assert(this.lockfd >= 0);

		close(this.lockfd);
		this.lockfd = -1;

		if(unlink(cast(char*)this.lockfile) != 0) {
			RET_ERR_ASYNC_SAFE(this, ALPM_ERR_SYSTEM, -1);
			assert(0);
		} else {
			return 0;
		}
	}

	AlpmDB register_syncdb(string treename, int siglevel) {
		assert(treename.length != 0);
		/* Do not register a database if a transaction is on-going */
		enforce(this.trans !is null, "Can't register db, the thansaction is on-going,");

		/* ensure database name is unique */
		if(treename == "local") {
			RET_ERR(this, ALPM_ERR_DB_NOT_NULL, null);
		}
		foreach(i; dbs_sync.AlpmInputRange) {
			if(treename == i.data.treename)
				RET_ERR(this, ALPM_ERR_DB_NOT_NULL, null);
		}

		return _alpm_db_register_sync(this, cast(char*)treename, siglevel);
	}

	void unregisterAllSyncDBs() {
		enforce(this.trans !is null, "The transaction is going-on");

		/* unregister all sync dbs */
		for(auto i = this.dbs_sync; i; i = i.next) {
			auto db = i.data;
			db.ops.unregister(db);
			i.data = null;
		}
		this.dbs_sync = null;
	}
}

/* free all in-memory resources */
void _alpm_handle_free(AlpmHandle handle)
{
	AlpmDB db = void;

	if(handle is null) {
		return;
	}

	/* close local database */
	if((db = handle.db_local) !is null) {
		db.ops.unregister(db);
	}

	/* unregister all sync dbs */
	for(auto i = handle.dbs_sync; i; i = i.next) {
		db = cast(AlpmDB)i.data;
		db.ops.unregister(db);
	}
	handle.dbs_sync = null;

	/* close logfile */
	if(handle.logstream.isOpen) {
		handle.logstream.close();
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

string alpm_option_get_lockfile(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.lockfile;
}

string alpm_option_get_gpgdir(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.gpgdir;
}

string alpm_option_get_sandboxuser(AlpmHandle handle)
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

string alpm_option_get_dbext(AlpmHandle handle)
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

string canonicalizePath(string path) {	
	if(path[$-1] != '/') {
		return path ~ '/';
	}

	return path;
}

alpm_errno_t setDirectoryOption(string value, string* storage, bool mustExist)
{
	stat_t st = void;
	char[PATH_MAX] real_ = void;
	auto canonicalPath = value.idup;
	if(mustExist) {
		if(stat(canonicalPath.toStringz(), &st) == -1 || !S_ISDIR(st.st_mode)) {
			return ALPM_ERR_NOT_A_DIR;
		}
		if(!realpath(canonicalPath.toStringz(), real_.ptr)) {
			return ALPM_ERR_NOT_A_DIR;
		}
		canonicalPath = real_.to!string;
	}

	*storage = canonicalizePath(canonicalPath);

	return cast(alpm_errno_t)0;
}

int  alpm_option_add_hookdir(AlpmHandle handle, char* hookdir)
{
	char* newhookdir = void;

	CHECK_HANDLE(handle);
	//ASSERT(hookdir != null);

	newhookdir = cast(char*)canonicalizePath(hookdir.to!string).ptr;
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

	newhookdir = cast(char*)canonicalizePath(hookdir.to!string).ptr;
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

		newcachedir = cast(char*)canonicalizePath(cachedir.to!string).ptr;
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

		newcachedir = cast(char*)canonicalizePath(cachedir.to!string).ptr;
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
	char* oldlogfile = cast(char*)handle.logfile;

	CHECK_HANDLE(handle);
	if(!logfile) {
		handle.pm_errno = ALPM_ERR_WRONG_ARGS;
		return -1;
	}

	char* tmp;
	STRDUP(tmp, logfile);
	handle.logfile = tmp.to!string;

	/* free the old logfile path string, and close the stream so logaction
	 * will reopen a new stream on the new logfile */
	if(oldlogfile) {
		FREE(oldlogfile);
	}
	if(handle.logstream.isOpen()) {
		handle.logstream.close();
	}
	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'logfile' = %s\n", handle.logfile);
	return 0;
}

int  alpm_option_set_gpgdir(AlpmHandle handle,   char*gpgdir)
{
	int err = void;
	CHECK_HANDLE(handle);
	if(cast(bool)(err = setDirectoryOption(gpgdir.to!string, &handle.gpgdir, 0))) {
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

	STRDUP(cast(char**)handle.sandboxuser.ptr, sandboxuser);

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

AlpmDB alpm_get_localdb(AlpmHandle handle)
{
	CHECK_HANDLE(handle);
	return handle.db_local;
}

AlpmDBList alpm_get_syncdbs(AlpmHandle handle)
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

	STRDUP(cast(char**)handle.dbext.ptr, dbext);

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
