module libalpmd.db.db;
/*
 *  db.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
 *  Copyright (c) 2005 by Christian Hamar <krics@linuxforum.hu>
 *  Copyright (c) 2006 by David Kimpe <dnaku@frugalware.org>
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

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.stddef;
import std.regex;

/* libalpm */
// import libalpmd.db;
import libalpmd.alpm_list;
import std.conv;
import libalpmd.log;
import libalpmd.util;
import libalpmd.handle;
import libalpmd.alpm;
import libalpmd.pkg;
import libalpmd.group;
import libalpmd.pkghash;
// import libalpmd.be_sync;
import libalpmd.deps;
import libalpmd.util;
import libalpmd.conflict;

import std.string;
import std.bigint;

enum AlpmDBInfRq {
	Base = (1 << 0),
	Desc = (1 << 1),
	Files = (1 << 2),
	Scriptlet = (1 << 3),
	DSize = (1 << 4),
	/* ALL should be info stored in the package or database */
	All = Base | Desc | Files |
		Scriptlet | DSize,
	Error = (1 << 30)
}

/** Database status. Bitflags. */
enum AlpmDBStatus {
	Valid = (1 << 0),
	Invalid = (1 << 1),
	Exists = (1 << 2),
	Missing = (1 << 3),

	Local = (1 << 10),
	PkgCache = (1 << 11),
	GrpCache = (1 << 12)
}

struct db_operations {
	int function(AlpmDB) validate;
	int function(AlpmDB) populate;
	void function(AlpmDB) unregister;
}

/* Database */
class AlpmDB {
	AlpmHandle handle;
	string treename;
	/* do not access directly, use _alpm_db_path(db) for lazy access */
	string _path;
	AlpmPkgHash pkgcache;
	alpm_list_t* grpcache;
	alpm_list_t* cache_servers;
	alpm_list_t* servers;
	const (db_operations)* ops;
	// abstract int validate() {
	// 	return 0;
	// }

	// abstract int populate() {
	// 	return 0;
	// }

	// abstract void unregister() {

	// }

	/* bitfields for validity, local, loaded caches, etc. */
	/* From _alpm_dbstatus_t */
	int status;
	/* alpm_siglevel_t */
	int siglevel;
	/* alpm_db_usage_t */
	int usage;

	AlpmHandle getHandle() => this.handle;
	string getName() => this.treename;

	int  unregisterDB() {
		int found = 0;
		// AlpmHandle handle = void;

		/* Sanity checks */
		//ASSERT(db != null);
		/* Do not unregister a database if a transaction is on-going */
		// handle = db.handle;
		handle.pm_errno = ALPM_ERR_OK;
		//ASSERT(handle.trans == null);

		if(this is handle.getDBLocal) {
			handle.getDBLocal = null;
			found = 1;
		} else {
			/* Warning : this function shouldn't be used to unregister all sync
			* databases by walking through the list returned by
			* alpm_get_syncdbs, because the db is removed from that list here.
			*/
			void* data = void;
			handle.getDBsSync = alpm_new_list_remove(handle.getDBsSync,
					this, &_alpm_db_cmp, &data);
			if(data) {
				found = 1;
			}
		}

		if(!found) {
			RET_ERR(handle, ALPM_ERR_DB_NOT_FOUND, -1);
		}

		this.ops.unregister(this);
		return 0;
	}

	alpm_list_t* getChacheServers() => this.cache_servers;

	int  addServer(char*url)
	{
		auto db = this;

		/* Sanity checks */
		//ASSERT(db != null);
		// (cast(AlpmHandle)db.handle).pm_errno = ALPM_ERR_OK;
		//ASSERT(url != null && strlen(url) != 0);

		string newurl = sanitizeUrl(url.to!string);
		//ASSERT(newurl != null);

		db.servers = alpm_list_add(db.servers, cast(char*)newurl.toStringz());
		// _alpm_log(db.handle, ALPM_LOG_DEBUG, "adding new server URL to database '%s': %s",
				// db.treename, newurl);

		return 0;
	}

	int  setServers(alpm_list_t* servers)
	{
		alpm_list_t* i = void;
		//ASSERT(db != null);
		FREELIST(this.servers);
		for(i = servers; i; i = i.next) {
			char* url = cast(char*)i.data;
			if(this.addServer(url) != 0) {
				return -1;
			}
		}
		
		
		return 0;
	}

	int  removeServer(char*url)
	{
		char* vdata = null;
		int ret = 1;

		/* Sanity checks */
		//ASSERT(db != null);
		(cast(AlpmHandle)this.handle).pm_errno = ALPM_ERR_OK;
		//ASSERT(url != null && strlen(url) != 0);

		string newurl = sanitizeUrl(url.to!string);
		//ASSERT(newurl != null);

		this.servers = alpm_list_remove_str(this.servers, cast(char*)newurl.toStringz, &vdata);

		if(vdata) {
			_alpm_log(this.handle, ALPM_LOG_DEBUG, "removed server URL from database '%s': %s\n",
					this.treename, cast(char*)newurl.toStringz);
			free(vdata);
			ret = 0;
		}

		return ret;
	}

	int  setCacheServer(alpm_list_t* cache_servers)
	{
		alpm_list_t* i = void;
		//ASSERT(db != null);
		FREELIST(this.cache_servers);
		for(i = cache_servers; i; i = i.next) {
			char* url = cast(char*)i.data;
			if(this.addCacheServer(url) != 0) {
				return -1;
			}
		}
		return 0;
	}

	int  addCacheServer( char*url)
	{
		/* Sanity checks */
		//ASSERT(this != null);
		(cast(AlpmHandle)this.handle).pm_errno = ALPM_ERR_OK;
		//ASSERT(url != null && strlen(url) != 0);

		string newurl = sanitizeUrl(url.to!string);
		//ASSERT(newurl != null);

		this.cache_servers = alpm_list_add(this.cache_servers, cast(char*)newurl.toStringz);
		// _alpm_log(this.handle, ALPM_LOG_DEBUG, "adding new cache server URL to database '%s': %s\n",
				// this.treename, newurl);

		return 0;
	}

	int  removeCacheServer( char*url)
	{
		alias db = this;
		import libalpmd.util;
		char* vdata = null;
		int ret = 1;

		/* Sanity checks */
		//ASSERT(db != null);
		(cast(AlpmHandle)db.handle).pm_errno = ALPM_ERR_OK;
		//ASSERT(url != null && strlen(url) != 0);

		string newurl = sanitizeUrl(url.to!string);
		//ASSERT(newurl != null);

		db.cache_servers = alpm_list_remove_str(db.cache_servers, cast(char*)newurl.toStringz(), &vdata);

		if(vdata) {
			_alpm_log(db.handle, ALPM_LOG_DEBUG, "removed cache server URL from database '%s': %s\n",
					db.treename, newurl);
			free(vdata);
			ret = 0;
		}

		return ret;
	}

	int getSigLevel() {
		if(this.siglevel & ALPM_SIG_USE_DEFAULT) {
			return this.handle.siglevel;
		} else {
			return this.siglevel;
		}
	}

	int  getValid()
	{
		//ASSERT(db != null);
		(cast(AlpmHandle)this.handle).pm_errno = ALPM_ERR_OK;
		return this.ops.validate(this);
	}

	AlpmPkg getPkg(char*name)
	{
		AlpmPkg pkg = void;
		//ASSERT(this != null);
		(cast(AlpmHandle)this.handle).pm_errno = ALPM_ERR_OK;
		//ASSERT(name != null && strlen(name) != 0);

		pkg = _alpm_db_get_pkgfromcache(this, name);
		if(!pkg) {
			RET_ERR(this.handle, ALPM_ERR_PKG_NOT_FOUND, null);
		}
		return pkg;
	}

	AlpmGroup getGroup(char*name)
	{
		//ASSERT(db != null);
		(cast(AlpmHandle)this.handle).pm_errno = ALPM_ERR_OK;
		//ASSERT(name != null && strlen(name) != 0);

		return _alpm_db_get_groupfromcache(this, name);
	}

	/**
	* @brief Returns a list of conflicts between a db and a list of packages.
	*/
	alpm_list_t* outerConflicts(alpm_list_t* packages)
	{
		alpm_list_t* baddeps = null;

		alpm_list_t* dblist = alpm_list_diff(this.getPkgCacheList(),
				packages, &_alpm_pkg_cmp);

		/* two checks to be done here for conflicts */
		_alpm_log(this.handle, ALPM_LOG_DEBUG, "check targets vs db\n");
		check_conflict(this.handle, packages, dblist, &baddeps, 1);
		_alpm_log(this.handle, ALPM_LOG_DEBUG, "check db vs targets\n");
		check_conflict(this.handle, dblist, packages, &baddeps, -1);

		alpm_list_free(dblist);
		return baddeps;
	}

	void freePkgCache() {
		if(this.pkgcache is null) {
			return;
		}

		logger.tracef("freeing package cache for repository '%s'\n", this.treename);

		this.pkgcache = null;
		this.status &= ~AlpmDBStatus.PkgCache;

		free_groupcache(this);
	}

	AlpmPkgHash getPkgCacheHash() {
		if(!(this.status & AlpmDBStatus.Valid)) {
			RET_ERR(this.handle, ALPM_ERR_DB_INVALID, null);
		}

		if(!(this.status & AlpmDBStatus.PkgCache)) {
			if(load_pkgcache(this)) {
				/* handle->error set in local/sync-db-populate */
				return null;
			}
		}

		return this.pkgcache;
	}

	alpm_list_t* getPkgCacheList() {
		// AlpmPkgHash hash = getPkgCacheHash();

		if(this.pkgcache is null) {
			return null;
		}

		return this.pkgcache.getList();
	}
}

alias AlpmDBs = AlpmList!AlpmDB;
/* Helper function for alpm_db_unregister{_all} */
void _alpm_db_unregister(AlpmDB db)
{
	if(db is null) {
		return;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG, "unregistering database '%s'\n", db.treename);
	_alpm_db_free(db);
}

alpm_list_t * alpm_db_get_groupcache(AlpmDB db)
{
	//ASSERT(db != null);
	(cast(AlpmHandle)db.handle).pm_errno = ALPM_ERR_OK;

	return _alpm_db_get_groupcache(db);
}

int  alpm_db_search(AlpmDB db,  alpm_list_t* needles, alpm_list_t** ret)
{
	//ASSERT(db != null && ret != null && *ret == null);
	(cast(AlpmHandle)db.handle).pm_errno = ALPM_ERR_OK;

	return _alpm_db_search(db, needles, ret);
}

int  alpm_db_set_usage(AlpmDB db, int usage)
{
	//ASSERT(db != null);
	db.usage = usage;
	return 0;
}

int  alpm_db_get_usage(AlpmDB db, int* usage)
{
	//ASSERT(db != null);
	//ASSERT(usage != null);
	*usage = db.usage;
	return 0;
}

AlpmDB _alpm_db_new(  char*treename, int is_local)
{
	AlpmDB db = new AlpmDB();
	db.treename = treename.to!string;
	if(is_local) {
		db.status |= AlpmDBStatus.Local;
	} else {
		db.status &= ~AlpmDBStatus.Local;
	}
	db.usage = AlpmDBUsage.All;

	return db;
}

void _alpm_db_free(AlpmDB db)
{
	//ASSERT(db != null);
	/* cleanup pkgcache */
	// _alpm_db_free_pkgcache(db);
	db.freePkgCache();
	/* cleanup server list */
	FREELIST(db.cache_servers);
	FREELIST(db.servers);
	FREE(db._path);
	FREE(db.treename);
	FREE(db);

	return;
}

string _alpm_db_path(AlpmDB db)
{
	if(db is null) {
		return null;
	}
	if(db._path is null) {
		string dbpath = void;
		size_t pathsize = void;

		dbpath = db.handle.dbpath;
		if(!dbpath) {
			// _alpm_log(db.handle, ALPM_LOG_ERROR, ("database path is undefined\n"));
			// RET_ERR(db.handle, ALPM_ERR_DB_OPEN, null);
		}

		if(db.status & AlpmDBStatus.Local) {
			db._path = dbpath ~ db.treename;
		} else {
			db._path = dbpath ~ db.treename ~ db.handle.dbext;
		}
		// _alpm_log(db.handle, ALPM_LOG_DEBUG, "database path for tree %s set to %s\n",
				// db.treename, db._path);
	}
	return db._path;
}

int _alpm_db_cmp( void* d1,  void* d2)
{
	  AlpmDB db1 = cast(AlpmDB)d1;
	  AlpmDB db2 = cast(AlpmDB)d2;
	return db1.treename == db2.treename;
}

int _alpm_db_search(AlpmDB db,  alpm_list_t* needles, alpm_list_t** ret)
{
	alpm_list_t* i = void, j = void, k = void;

	if(!(db.usage & AlpmDBUsage.Search)) {
		return 0;
	}

	/* copy the pkgcache- we will free the list var after each needle */
	alpm_list_t* list = alpm_list_copy(db.getPkgCacheList());

	for(i = needles; i; i = i.next) {
		char* targ = void;

		if(i.data == null) {
			continue;
		}
		*ret = null;
		targ = cast(char*)i.data;
		_alpm_log(db.handle, ALPM_LOG_DEBUG, "searching for target '%s'\n", targ);

		for(j = cast( alpm_list_t*) list; j; j = j.next) {
			AlpmPkg pkg = cast(AlpmPkg)j.data;
			char* matched = null;
			string name = pkg.name;
			char*desc = cast(char*)pkg.getDesc();

			/* check name as plain text */
			if(name && strstr(cast(char*)name, targ)) {
				matched = cast(char*)name;
			}
			/* check desc */
			else if(desc && strstr(desc, targ)) {
				matched = desc;
			}
			/* TODO: should we be doing this, and should we print something
			 * differently when we do match it since it isn't currently printed? */
			if(!matched) {
				/* check provides */
				foreach(provide; pkg.getProvides()[]) {
					// AlpmDepend provide = cast(AlpmDepend )k.data;
					if(strstr(cast(char*)provide.name.toStringz, targ)) {
						matched = cast(char*)provide.name.toStringz;
						break;
					}
				}
			}
			if(!matched) {
				/* check groups */
				foreach(group; pkg.getGroups()[]) {
					//   char*group =  cast(char*)k.data;
					if(strstr(cast(char*)group, targ)) {
						matched = cast(char*)group;
						break;
					}
				}
			}

			if(matched != null) {
				_alpm_log(db.handle, ALPM_LOG_DEBUG,
						"search target '%s' matched '%s' on package '%s'\n",
						targ, matched, name);
				*ret = alpm_list_add(*ret, cast(void*)pkg);
			}
		}

		/* Free the existing search list, and use the returned list for the
		 * next needle. This allows for AND-based package searching. */
		alpm_list_free(list);
		list = *ret;
	}

	return 0;
}

/* Returns a new package cache from db.
 * It frees the cache if it already exists.
 */
private int load_pkgcache(AlpmDB db)
{
	// _alpm_db_free_pkgcache(db);
	db.freePkgCache();

	_alpm_log(db.handle, ALPM_LOG_DEBUG, "loading package cache for repository '%s'\n",
			db.treename);
	if(db.ops.populate(db) == -1) {
		_alpm_log(db.handle, ALPM_LOG_DEBUG,
				"failed to load package cache for repository '%s'\n", db.treename);
		return -1;
	}

	db.status |= AlpmDBStatus.PkgCache;
	return 0;
}

private void free_groupcache(AlpmDB db)
{
	alpm_list_t* lg = void;

	if(db is null || !(db.status & AlpmDBStatus.GrpCache)) {
		return;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG,
			"freeing group cache for repository '%s'\n", db.treename);

	for(lg = db.grpcache; lg; lg = lg.next) {
		destroy(cast(AlpmGroup)lg.data);
		lg.data = null;
	}
	FREELIST(db.grpcache);
	db.status &= ~AlpmDBStatus.GrpCache;
}

/* "duplicate" pkg then add it to pkgcache */
int _alpm_db_add_pkgincache(AlpmDB db, AlpmPkg pkg)
{
	AlpmPkg newpkg = null;

	if(db is null || pkg is null || !(db.status & AlpmDBStatus.PkgCache)) {
		return -1;
	}

	if((newpkg = pkg.dup) !is null) {
		/* we return memory on "non-fatal" error in _alpm_pkg_dup */
		destroy!false(newpkg);
		return -1;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG, "adding entry '%s' in '%s' cache\n",
						newpkg.name, db.treename);
	if(newpkg.origin == ALPM_PKG_FROM_FILE) {
		free(cast(void*)newpkg.origin_data.file);
	}
	newpkg.origin = (db.status & AlpmDBStatus.Local)
		? ALPM_PKG_FROM_LOCALDB
		: ALPM_PKG_FROM_SYNCDB;
	newpkg.origin_data.db = db;
	if(db.pkgcache.addSorted(newpkg) is null) {
		destroy!false(newpkg);
		RET_ERR(db.handle, ALPM_ERR_MEMORY, -1);
	}

	free_groupcache(db);

	return 0;
}

int _alpm_db_remove_pkgfromcache(AlpmDB db, AlpmPkg pkg)
{
	AlpmPkg data = null;

	if(db is null || pkg is null || !(db.status & AlpmDBStatus.PkgCache)) {
		return -1;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG, "removing entry '%s' from '%s' cache\n",
						pkg.name, db.treename);

	db.pkgcache = db.pkgcache.remove(pkg, &data);
	if(data is null) {
		/* package not found */
		_alpm_log(db.handle, ALPM_LOG_DEBUG, "cannot remove entry '%s' from '%s' cache: not found\n",
							pkg.name, db.treename);
		return -1;
	}

	destroy!false(data);

	free_groupcache(db);

	return 0;
}

AlpmPkg _alpm_db_get_pkgfromcache(AlpmDB db,   char*target)
{
	if(db is null) {
		return null;
	}

	AlpmPkgHash pkgcache = db.getPkgCacheHash();
	if(!pkgcache) {
		return null;
	}

	return pkgcache.find(target);
}

/* Returns a new group cache from db.
 */
int load_grpcache(AlpmDB db)
{
	alpm_list_t* lp = void;

	if(db is null) {
		return -1;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG, "loading group cache for repository '%s'\n",
			db.treename);

	for(lp = db.getPkgCacheList(); lp; lp = lp.next) {
		AlpmPkg pkg = cast(AlpmPkg)lp.data;

		foreach(grpname; pkg.getGroups()[]) {
			alpm_list_t* j = void;
			AlpmGroup grp = null;
			int found = 0;

			/* first look through the group cache for a group with this name */
			for(j = db.grpcache; j; j = j.next) {
				grp = cast(AlpmGroup)j.data;

				if(strcmp(cast(char*)grp.name, cast(char*)grpname) == 0
						&& !alpm_new_list_find_ptr(grp.packages, cast(void*)pkg)) {
					grp.packages.insertFront(pkg);
					found = 1;
					break;
				}
			}
			if(found) {
				continue;
			}
			/* we didn't find the group, so create a new one with this name */
			grp = new AlpmGroup(grpname.to!string);
			if(!grp) {
				free_groupcache(db);
				return -1;
			}
			grp.packages.insertFront(pkg);
			db.grpcache = alpm_list_add(db.grpcache, cast(void*)grp);
		}
	}

	db.status |= AlpmDBStatus.GrpCache;
	return 0;
}

alpm_list_t* _alpm_db_get_groupcache(AlpmDB db)
{
	if(db is null) {
		return null;
	}

	if(!(db.status & AlpmDBStatus.Valid)) {
		RET_ERR(db.handle, ALPM_ERR_DB_INVALID, null);
	}

	if(!(db.status & AlpmDBStatus.GrpCache)) {
		load_grpcache(db);
	}

	return db.grpcache;
}

AlpmGroup _alpm_db_get_groupfromcache(AlpmDB db,   char*target)
{
	alpm_list_t* i = void;

	if(db is null || target == null || strlen(target) == 0) {
		return null;
	}

	for(i = _alpm_db_get_groupcache(db); i; i = i.next) {
		AlpmGroup info = cast(AlpmGroup)i.data;

		if(strcmp(cast(char*)info.name, target) == 0) {
			return info;
		}
	}

	return null;
}
