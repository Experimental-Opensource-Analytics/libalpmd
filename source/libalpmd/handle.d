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
import std.conv;
import std.file;

import libalpmd.alpm_list;
import libalpmd.util;
import libalpmd.log;
import libalpmd.trans;
import libalpmd.alpm;
import libalpmd.deps;
import core.stdc.stdio;
import libalpmd.db;
// import libalpmd.be_sync;
import std.exception;
import std.stdio;
import std.string;
import libalpmd.deps;
import libalpmd.pkg;
import libalpmd.dload;
import libalpmd.env;
import std.algorithm;

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

alias AlpmCallbackLog = void delegate(string fmt, ...);

class AlpmHandle {
private:
	AlpmDB 	dbLocal;    /* local db pointer */
	AlpmDBs dbsSync;  /* List of (AlpmDB) */
	File 	lckFile;

	AlpmStrings 	cachedirs;  /* Paths to pacman cache directories */
	AlpmStrings 	hookdirs;   /* Paths to hook directories */

	bool disableSandboxFilesystem;
	bool disableSandboxSyscalls;
	bool disableDltimeout;

public:
	/* internal usage */
	File 	logstream;        /* log file stream pointer */
	AlpmTrans trans;
	uid_t 	user;

	version (HAVE_LIBCURL) {
		/* libcurl handle */
		CURLM* curlm;
		alpm_list_t* server_errors;
	}

	uint parallel_downloads; /* number of download streams */

	version (HAVE_LIBGPGME) {
		alpm_list_t* known_keys;  /* keys verified to be in our keychain */
	}

	/* callback functions */
	// alpm_cb_log logcb;          /* Log callback function */
	// void* logcb_ctx;

	AlpmCallbackLog		cbLog; 

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
	alpm_list_t* 	overwrite_files; /* Paths that may be overwritten */

	/* package lists */
	alpm_list_t* noupgrade;   /* List of packages NOT to be upgraded */
	alpm_list_t* noextract;   /* List of files NOT to extract */
	alpm_list_t* ignorepkg;   /* List of packages to ignore */
	alpm_list_t* ignoregroup; /* List of groups to ignore */
	AlpmDeps assumeinstalled;   /* List of virtual packages used to satisfy dependencies */

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

	~this() {
		lckFile.close();
		trans = null;
	}

	auto ref getDBsSync()  @property => this.dbsSync;
	auto ref getDBLocal() @property => this.dbLocal;

	string getRoot() => this.root;
	string getDBPath() => this.dbpath;
	string getLogfile() => this.logfile;

	/** Lock the database */
	void lockDBs() {
		scope string dir = "./";

		assert(this.lockfile != null);

		dir = "./";
		if(exists(dir ~ lockfile))
			throw new Exception("Is Locked");

		mkdirRecurse(dir);
		lckFile = File(dir ~ lockfile, "w+");
	}

	void  unlockDBs() {
		if(lckFile.isOpen) {
			lckFile.close();
		}
		if(exists(lckFile.name))
			lckFile.name.remove();
	}

	AlpmDB register_syncdb(string treename, int siglevel) {
		import std.string;
		assert(treename.length != 0);
		/* Do not register a database if a transaction is on-going */
		enforce(this.trans is null, "Can't register db, the thansaction is on-going,");

		/* ensure database name is unique */
		if(treename == "local") {
			RET_ERR(this, ALPM_ERR_DB_NOT_NULL, null);
		}
		foreach(i; getDBsSync[]) {
			if(treename == i.treename)
				continue;
				// RET_ERR(this, ALPM_ERR_DB_NOT_NULL, null);
		}

		return _alpm_db_register_sync(this, cast(char*)treename.toStringz, siglevel);
	}

	void unregisterAllSyncDBs() {
		enforce(this.trans !is null, "The transaction is going-on");

		/* unregister all sync dbs */
		foreach(i; this.getDBsSync[]) {
			auto db = i;
			db.ops.unregister(db);
			i = null;
		}
		this.getDBsSync.clear;
	}

	string getSyncDir() {
		string syncpath = this.dbpath ~ "sync/";
		stat_t buf = void;

		if(stat(syncpath.toStringz, &buf) != 0) {
			// _alpm_log(handle, ALPM_LOG_DEBUG, "database dir '%s' does not exist, creating it\n",
			// 		syncpath);

			mkdirRecurse(syncpath);
		} else if(!S_ISDIR(buf.st_mode)) {
			// _alpm_log(handle, ALPM_LOG_WARNING, ("removing invalid file: %s\n"), syncpath);
			if(unlink(syncpath.toStringz) != 0 ) {
				throw new FileException("Can't unlink syncpath" ~ syncpath);
			}

			mkdirRecurse(syncpath);
		}

		return syncpath;
	}

	void updateDBs(bool force = true) {
		scope string syncpath = this.getSyncDir();
		scope string temporary_syncpath = "./tmp/";
		int ret = -1;
		/* make sure we have a sane umask */
		Environment.saveMask();
		scope alpm_list_t* payloads = null;
		alpm_event_t event = void;

		this.sandboxuser = Environment.getUserName();

		this.lockDBs();

		foreach(AlpmDB db; this.getDBsSync) {
			bool dbforce = force;

			if(!(db.usage & AlpmDBUsage.Sync)) {
				continue;
			}

			/* force update of invalid databases to fix potential mismatched database/signature */
			if(db.status & AlpmDBStatus.Invalid) {
				dbforce = true;
			}

			DLoadPayload* payload = new DLoadPayload(this, db, temporary_syncpath, dbforce);			
			payloads = alpm_list_add(payloads, payload);
		}
		if(payloads == null) {
			// ret = 0;
			goto cleanup;
		}

		// event.type = ALPM_EVENT_DB_RETRIEVE_START;
		// EVENT(this, &event);
		ret = _alpm_download(this, payloads, cast(char*)syncpath.toStringz, cast(char*)temporary_syncpath.toStringz);
		// if(ret < 0) {
		// 	event.type = ALPM_EVENT_DB_RETRIEVE_FAILED;
		// 	EVENT(this, &event);
		// 	goto cleanup;
		// }
		// event.type = ALPM_EVENT_DB_RETRIEVE_DONE;
		// EVENT(this, &event);

		foreach(db; getDBsSync) {
			// AlpmDB db = cast(AlpmDB)i;
			if(!(db.usage & AlpmDBUsage.Sync)) {
				continue;
			}

			/* Cache needs to be rebuilt */
			_alpm_db_free_pkgcache(db);

			/* clear all status flags regarding validity/existence */
			db.status &= ~AlpmDBStatus.Valid;
			db.status &= ~AlpmDBStatus.Invalid;
			db.status &= ~AlpmDBStatus.Exists;
			db.status &= ~AlpmDBStatus.Missing;

			/* if the download failed skip validation to preserve the download error */
			if(sync_db_validate(db) != 0) {
				logger.trace("failed to validate db: ", db.treename);
				/* pm_errno should be set */
				// ret = -1;
			}
		}

	cleanup:
		// if(ret == -1) {
		// 	/* pm_errno was set by the download code */
		// 	_alpm_log(this, ALPM_LOG_DEBUG, "failed to sync dbs: %s\n",
		// 			alpm_strerror(this.pm_errno));
		// } else {
		// 	this.pm_errno = ALPM_ERR_OK;
		// }

		// if(payloads) {
		// 	alpm_list_free_inner(payloads, cast(alpm_list_fn_free)&_alpm_DLoadPayload_reset);
		// 	FREELIST(payloads);
		// }
		// FREE(temporary_syncpath);
		// FREE(syncpath);
		this.unlockDBs();
		Environment.restoreMask();
		// return ret;
	}

	bool useSandbox() {
		if(this.user == 0 && 
		this.sandboxuser !is null && 
		(!this.disableSandboxFilesystem || !this.disableSandboxSyscalls)){
			return true;
		}

		return false;
	}

	int  getDisableSandbox(){
		if(this.disableSandboxFilesystem && this.disableSandboxSyscalls) {
			return 2;
		} else if (this.disableSandboxFilesystem || this.disableSandboxSyscalls) {
			return 1;
		}

		return 0;
	}

	void setDisableSandbox(bool disable_sandbox) {
		this.disableSandboxFilesystem = disable_sandbox;
		this.disableSandboxSyscalls= disable_sandbox;
	}

	void addCacheDir(string dir) {
		string newcachedir = canonicalizePath(dir);
		this.cachedirs.insert(newcachedir);

		logger.tracef("option 'cachedir' = %s\n", cast(char*)newcachedir.toStringz);
	}

	AlpmStrings getCacheDirs() => this.cachedirs;

	void  setCacheDirs(AlpmStrings cachedirs) {
		this.cachedirs.clear();

		//DList[] don't works with st.algoithm.each
		foreach(cachedir; cachedirs[]) {
			addCacheDir(cachedir);
		}
	}

	void  addHookDir(string hookdir) {
		string newhookdir = canonicalizePath(hookdir);
		this.hookdirs.insertBack(newhookdir);
		logger.tracef("option 'hookdir' = %s\n", newhookdir);
	}

	AlpmStrings getHookDirs() => this.hookdirs;

	void setHookDirs(AlpmStrings hookdirs) {
		this.hookdirs.clear();

		//DList[] don't works with st.algoithm.each
		foreach(hookdir; hookdirs[]) {
			addHookDir(hookdir);
		}
	}

	void  removeHookDir(string hookdir) {
		string newhookdir = canonicalizePath(hookdir);
		this.hookdirs.linearRemoveElement(newhookdir);
	}

	bool  isDlTimeoutDisabled() => this.disableDltimeout;

	void  setDlTimeoutDisables(bool disableDltimeout) {
		this.disableDltimeout = disableDltimeout;
	}

	auto  getLogCallback() => this.cbLog;

	void setLogCallback(AlpmCallbackLog cbLog) {
		this.cbLog = cbLog;
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
	if((db = handle.getDBLocal) !is null) {
		db.ops.unregister(db);
	}

	/* unregister all sync dbs */
	foreach(i; handle.getDBsSync[]) {
		db = cast(AlpmDB)i;
		db.ops.unregister(db);
	}
	handle.getDBsSync.clear;

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
	// FREELIST(handle.cachedirs);
	handle.cachedirs.clear();
	handle.hookdirs.clear();
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

	// alpm_list_free_inner(handle.assumeinstalled, cast(alpm_list_fn_free)&alpm_dep_free);
	// alpm_list_free(handle.assumeinstalled);

	FREE(handle);
}


alpm_cb_download  alpm_option_get_dlcb(AlpmHandle handle)
{
	return handle.dlcb;
}

void * alpm_option_get_dlcb_ctx(AlpmHandle handle)
{
	return handle.dlcb_ctx;
}

alpm_cb_fetch  alpm_option_get_fetchcb(AlpmHandle handle)
{
	return handle.fetchcb;
}

void * alpm_option_get_fetchcb_ctx(AlpmHandle handle)
{
	return handle.fetchcb_ctx;
}

alpm_cb_event  alpm_option_get_eventcb(AlpmHandle handle)
{
	return handle.eventcb;
}

void * alpm_option_get_eventcb_ctx(AlpmHandle handle)
{
	return handle.eventcb_ctx;
}

alpm_cb_question  alpm_option_get_questioncb(AlpmHandle handle)
{
	return handle.questioncb;
}

void * alpm_option_get_questioncb_ctx(AlpmHandle handle)
{
	return handle.questioncb_ctx;
}

alpm_cb_progress  alpm_option_get_progresscb(AlpmHandle handle)
{
	return handle.progresscb;
}

void * alpm_option_get_progresscb_ctx(AlpmHandle handle)
{
	return handle.progresscb_ctx;
}

string alpm_option_get_lockfile(AlpmHandle handle)
{
	return handle.lockfile;
}

string alpm_option_get_gpgdir(AlpmHandle handle)
{
	return handle.gpgdir;
}

string alpm_option_get_sandboxuser(AlpmHandle handle)
{
	return handle.sandboxuser;
}

int  alpm_option_get_usesyslog(AlpmHandle handle)
{
	return handle.usesyslog;
}

alpm_list_t * alpm_option_get_noupgrades(AlpmHandle handle)
{
	return handle.noupgrade;
}

alpm_list_t * alpm_option_get_noextracts(AlpmHandle handle)
{
	return handle.noextract;
}

alpm_list_t * alpm_option_get_ignorepkgs(AlpmHandle handle)
{
	return handle.ignorepkg;
}

alpm_list_t * alpm_option_get_ignoregroups(AlpmHandle handle)
{
	return handle.ignoregroup;
}

alpm_list_t * alpm_option_get_overwrite_files(AlpmHandle handle)
{
	return handle.overwrite_files;
}

auto alpm_option_get_assumeinstalled(AlpmHandle handle)
{
	return handle.assumeinstalled;
}

alpm_list_t * alpm_option_get_architectures(AlpmHandle handle)
{
	return handle.architectures;
}

int  alpm_option_get_checkspace(AlpmHandle handle)
{
	return handle.checkspace;
}

string alpm_option_get_dbext(AlpmHandle handle)
{
	return handle.dbext;
}

int  alpm_option_get_parallel_downloads(AlpmHandle handle)
{
	return handle.parallel_downloads;
}

int  alpm_option_set_dlcb(AlpmHandle handle, alpm_cb_download cb, void* ctx)
{
	handle.dlcb = cb;
	handle.dlcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_fetchcb(AlpmHandle handle, alpm_cb_fetch cb, void* ctx)
{
	handle.fetchcb = cb;
	handle.fetchcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_eventcb(AlpmHandle handle, alpm_cb_event cb, void* ctx)
{
	handle.eventcb = cb;
	handle.eventcb_ctx = ctx;
	return 0;
}

int  alpm_option_set_questioncb(AlpmHandle handle, alpm_cb_question cb, void* ctx)
{
	handle.questioncb = cb;
	handle.questioncb_ctx = ctx;
	return 0;
}

int  alpm_option_set_progresscb(AlpmHandle handle, alpm_cb_progress cb, void* ctx)
{
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

alpm_errno_t setDirectoryOption(string value, out string storage, bool mustExist)
{
	stat_t st = void;
	char[PATH_MAX] real_ = "";
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

	storage = canonicalizePath(canonicalPath);

	return cast(alpm_errno_t)0;
}

int  alpm_option_remove_cachedir(AlpmHandle handle,   char*cachedir)
{
	char* vdata = null;
	char* newcachedir = void;
	//ASSERT(cachedir != null);

		newcachedir = cast(char*)canonicalizePath(cachedir.to!string).ptr;
	if(!newcachedir) {
		RET_ERR(handle, ALPM_ERR_MEMORY, -1);
	}
	handle.cachedirs.linearRemoveElement(newcachedir.to!string);
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

	if(cast(bool)(err = setDirectoryOption(gpgdir.to!string, handle.gpgdir, 0))) {
		RET_ERR(handle, err, -1);
	}
	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'gpgdir' = %s\n", handle.gpgdir);
	return 0;
}

int  alpm_option_set_sandboxuser(AlpmHandle handle,   char*sandboxuser)
{
	if(handle.sandboxuser) {
		FREE(handle.sandboxuser);
	}

	STRDUP(cast(char**)handle.sandboxuser.ptr, sandboxuser);

	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'sandboxuser' = %s\n", handle.sandboxuser);
	return 0;
}

int  alpm_option_set_usesyslog(AlpmHandle handle, int usesyslog)
{
	handle.usesyslog = usesyslog;
	return 0;
}

int _alpm_option_strlist_add(AlpmHandle handle, alpm_list_t** list,   char*str)
{
	char* dup = void;
	STRDUP(dup, str);
	*list = alpm_list_add(*list, dup);
	return 0;
}

int _alpm_option_strlist_set(AlpmHandle handle, alpm_list_t** list, alpm_list_t* newlist)
{
	FREELIST(*list);
	*list = alpm_list_strdup(newlist);
	return 0;
}

int _alpm_option_strlist_rem(AlpmHandle handle, alpm_list_t** list, char* str)
{
	char* vdata = null;

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
	return alpmFnmatchPatterns(handle.noupgrade, path.to!string);
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
	return alpmFnmatchPatterns(handle.noextract, path.to!string);
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

int  alpm_option_add_assumeinstalled(AlpmHandle handle, AlpmDepend dep)
{
	AlpmDepend depcpy = void;
	//ASSERT(dep.mod == ALPM_DEP_MOD_EQ || dep.mod == ALPM_DEP_MOD_ANY);
	// //ASSERT((depcpy = _alpm_dep_dup(dep)));

	/* fill in name_hash in case dep was built by hand */
	depcpy.name_hash = alpmSDBMHash(dep.name.to!string);
	handle.assumeinstalled.insertFront(depcpy);
	return 0;
}

int  alpm_option_set_assumeinstalled(AlpmHandle handle, alpm_list_t* deps)
{
	if(!handle.assumeinstalled.empty) {
		// alpm_list_free_inner(handle.assumeinstalled, cast(alpm_list_fn_free)&alpm_dep_free);
		// alpm_list_free(handle.assumeinstalled);
		// handle.assumeinstalled = null;
	}
	while(deps) {
		if(alpm_option_add_assumeinstalled(handle, cast(AlpmDepend )deps.data) != 0) {
			return -1;
		}
		deps = deps.next;
	}
	return 0;
}

int assumeinstalled_cmp( void* d1,  void* d2)
{
	 AlpmDepend dep1 = cast(AlpmDepend )d1;
	 AlpmDepend dep2 = cast(AlpmDepend )d2;

	if(dep1.name_hash != dep2.name_hash
			|| cmp(dep1.name, dep2.name) != 0) {
		return -1;
	}

	if(dep1.version_ && dep2.version_
			&& cmp(dep1.version_, dep2.version_) == 0) {
		return 0;
	}

	if(dep1.version_ == null && dep2.version_ == null) {
		return 0;
	}


	return -1;
}

int  alpm_option_remove_assumeinstalled(AlpmHandle handle, AlpmDepend dep)
{
	AlpmDepend vdata = null;

	// handle.assumeinstalled = alpm_list_remove(handle.assumeinstalled, cast(void*)dep, &assumeinstalled_cmp, cast(void**)&vdata);
	// vdata = handle.assumeinstalled.linearRemoveElement(dep);
	// if(vdata !is null) {
		// alpm_dep_free(cast(void*)vdata);
		// return 1;
	// }
	if(handle.assumeinstalled.linearRemoveElement(dep)) {
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
	if(handle.architectures) FREELIST(handle.architectures);
	handle.architectures = alpm_list_strdup(arches);
	return 0;
}

int  alpm_option_remove_architecture(AlpmHandle handle, char* arch)
{
	char* vdata = null;

	handle.architectures = alpm_list_remove_str(handle.architectures, arch, &vdata);
	if(vdata != null) {
		FREE(vdata);
		return 1;
	}
	return 0;
}

AlpmDB alpm_get_localdb(AlpmHandle handle)
{
	return handle.getDBLocal;
}

int  alpm_option_set_checkspace(AlpmHandle handle, int checkspace)
{
	handle.checkspace = checkspace;
	return 0;
}

int  alpm_option_set_dbext(AlpmHandle handle, char* dbext)
{
	if(handle.dbext) {
		FREE(handle.dbext);
	}

	STRDUP(cast(char**)handle.dbext.ptr, dbext);

	_alpm_log(handle, ALPM_LOG_DEBUG, "option 'dbext' = %s\n", handle.dbext);
	return 0;
}

int  alpm_option_set_default_siglevel(AlpmHandle handle, int level)
{
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
	return handle.siglevel;
}

int  alpm_option_set_local_file_siglevel(AlpmHandle handle, int level)
{
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
	if(handle.localfilesiglevel & ALPM_SIG_USE_DEFAULT) {
		return handle.siglevel;
	} else {
		return handle.localfilesiglevel;
	}
}

int  alpm_option_set_remote_file_siglevel(AlpmHandle handle, int level)
{
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
	if(handle.remotefilesiglevel & ALPM_SIG_USE_DEFAULT) {
		return handle.siglevel;
	} else {
		return handle.remotefilesiglevel;
	}
}

int  alpm_option_set_parallel_downloads(AlpmHandle handle, uint num_streams)
{
	//ASSERT(num_streams >= 1);
	handle.parallel_downloads = num_streams;
	return 0;
}
