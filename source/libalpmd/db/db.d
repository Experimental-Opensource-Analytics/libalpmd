module libalpmd.db.db;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.stddef;
import std.regex;
import std.algorithm;

/* libalpm */
// import libalpmd.db;
import libalpmd.alpm_list;
import libalpmd.alpm_list.alpm_list_new;

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
protected import libalpmd.signing;

import std.string;
import std.bigint;

/** The usage level of a database. */
enum AlpmDBUsage {
	/** Enable refreshes for this database */
	Sync = 1,
	/** Enable search for this database */
	Search = (1 << 1),
	/** Enable installing packages from this database */
	Install = (1 << 2),
	/** Enable sysupgrades with this database */
	Upgrade = (1 << 3),
	/** Enable all usage levels */
	All = (1 << 4) - 1,
}

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

/* Database */
class AlpmDB {
	AlpmHandle 		handle;
	string 			treename;
	/* do not access directly, use _alpm_db_path(db) for lazy access */
	string _path;
	AlpmPkgHash 	pkgcache;
	AlpmGroups	 	grpcache;
	AlpmStrings		cache_servers;
	AlpmStrings		servers;

	/* bitfields for validity, local, loaded caches, etc. */
	/* AlpmSigLevel */
	int siglevel;
	/* alpm_db_usage_t */
	int usage;
	/* From _alpm_dbstatus_t */
	int status;
	// const (db_operations)* ops;
	abstract int validate();
	abstract int populate();
	abstract void unregister();
	abstract string genPath();

	this(string treename) {
		this.treename = treename.to!string;
		this.usage = AlpmDBUsage.All;
	}

	~this() {
		this.freePkgCache();
		this.cache_servers.clear();
		this.servers.clear();
	}

	AlpmHandle getHandle() => this.handle;
	string getName() => this.treename;

	string calcPath() {
		if(this._path == "") {
			string dbpath = handle.dbpath;
			if(!dbpath) {
				throw new Exception("Database path is undefined");
			}

			this.genPath();

			logger.tracef("Database path for tree %s set to %s\n",
					this.treename, this._path);
		}
		
		return this._path;
	}

	AlpmStrings getChacheServers() => this.cache_servers;

	void  addServer(string url) {
		url = sanitizeUrl(url);

		this.servers.insertBack(url);

		logger.tracef("adding new server URL to database '%s': %s",
				treename, url);
	}

	void  setServers(AlpmStrings servers) {
		this.servers = servers.dup();
	}

	void  removeServer(scope string url) {
		url = sanitizeUrl(url);

		if(this.servers.linearRemoveElement(url)) {
			logger.tracef("removed server URL from database '%s': %s\n", this.treename, url);
		}
	}

	void  setCacheServer(AlpmStrings cache_servers) {
		this.cache_servers.clear();

		this.cache_servers = cache_servers.dup;
	}

	void  addCacheServer(string url) {
		url = sanitizeUrl(url);

		this.cache_servers.insertBack(url);

		logger.tracef("adding new cache server URL to database '%s': %s\n",
				this.treename, url);
	}

	void  removeCacheServer(string url) {
		url = sanitizeUrl(url);

		if(this.cache_servers.linearRemoveElement(url)) {
			logger.tracef("Removed cache server URL from database '%s': %s\n",
					this.treename, url);
		}
	}

	int getSigLevel() {
		if(this.siglevel & AlpmSigLevel.UseDefault) {
			return this.handle.siglevel;
		} else {
			return this.siglevel;
		}
	}

	AlpmPkg getPkg(string name) {
		auto pkg = this.getPkgFromCache(cast(char*)name.toStringz);

		if(!pkg) {
			throw new Exception("Package %s not found");
		}

		return pkg;
	}

	/**
	* @brief Returns a list of conflicts between a db and a list of packages.
	*/
	AlpmConflicts outerConflicts(AlpmPkgs packages)
	{
		AlpmConflicts baddeps;

		AlpmPkgs dblist = alpmListDiff(this.getPkgCacheList(), packages);

		/* two checks to be done here for conflicts */
		_alpm_log(this.handle, ALPM_LOG_DEBUG, "check targets vs db\n");
		check_conflict(this.handle, packages, dblist, baddeps, 1);
		_alpm_log(this.handle, ALPM_LOG_DEBUG, "check db vs targets\n");
		check_conflict(this.handle, dblist, packages, baddeps, -1);

		return baddeps;
	}

	void freePkgCache() {
		if(this.pkgcache is null) {
			return;
		}

		logger.tracef("freeing package cache for repository '%s'\n", this.treename);

		this.pkgcache = null;
		this.status &= ~AlpmDBStatus.PkgCache;

		this.freeGroupCache();
	}

	AlpmPkgHash getPkgCacheHash() {
		if(!(this.status & AlpmDBStatus.Valid)) {
			RET_ERR(this.handle, ALPM_ERR_DB_INVALID, null);
		}

		if(!(this.status & AlpmDBStatus.PkgCache)) {
			if(this.loadPkgCache()) {
				/* handle->error set in local/sync-db-populate */
				return null;
			}
		}

		return this.pkgcache;
	}

	AlpmPkgs getPkgCacheList() {
		// AlpmPkgHash hash = getPkgCacheHash();

		if(this.pkgcache is null) {
			// return null;
			return AlpmPkgs();
		}

		return this.pkgcache.getList();
	}

	AlpmGroups getGroupsCache() {
		if(!(this.status & AlpmDBStatus.Valid)) {
			throw new Exception("Can't get groups cache: Database is invalid");
		}

		if(!(this.status & AlpmDBStatus.GrpCache)) {
			this.loadGroupCache();
		}

		return this.grpcache;
	}

	AlpmGroup getGroupFromCache(char*target) {
		if(target == null || strlen(target) == 0) {
			return null;
		}

		foreach(info; grpcache[]) {
			if(strcmp(cast(char*)info.getName(), target) == 0) {
				return info;
			}
		}

		return null;
	}

	//For compatible
	alias getGroup = getGroupFromCache;

	/*
	* Returns a new group cache from db.
	*/
	int loadGroupCache() {
		// if(db is null) {
		// 	return -1;
		// }

		logger.tracef("loading group cache for repository '%s'\n", this.treename);

		foreach(pkg; (this.getPkgCacheList())[]) {
			// AlpmPkg pkg = cast(AlpmPkg)lp.data;

			foreach(grpname; pkg.getGroups()[]) {
				int found = 0;

				/* first look through the group cache for a group with this name */
				foreach(grp; this.grpcache[]) {
					if(strcmp(cast(char*)grp.getName, cast(char*)grpname) == 0
							&& !grp.isPkgIn(pkg)) {
						grp.addPkg(pkg);
						found = 1;
						break;
					}
				}
				if(found) {
					continue;
				}
				/* we didn't find the group, so create a new one with this name */
				auto grp = new AlpmGroup(grpname.to!string);
				if(!grp) {
					this.freeGroupCache();
					return -1;
				}
				grp.addPkg(pkg);
				this.grpcache.insertBack(grp);
			}
		}

		this.status |= AlpmDBStatus.GrpCache;
		return 0;
	}

	void  setUsage(int usage) {
		this.usage = usage;
	}

	int  getUsage() {
		return this.usage;
	}

	AlpmPkgs search(AlpmStrings needles) {

		AlpmPkgs ret;

		if(!(this.usage & AlpmDBUsage.Search)) {
			return AlpmPkgs();
		}

		/* copy the pkgcache- we will free the list var after each needle */
		// AlpmPkgs list = alpm_list_copy(this.getPkgCacheList()).oldToNewList!AlpmPkg;
		AlpmPkgs list = this.getPkgCacheList().dup;


		foreach(targ_; needles[]) {
			char* targ = void;

			// if(i.data == null) {
			// 	continue;
			// }
			ret = AlpmPkgs();
			targ = cast(char*)targ_.toStringz();
			_alpm_log(this.handle, ALPM_LOG_DEBUG, "searching for target '%s'\n", targ);

			foreach(pkg; list[]) {
				// AlpmPkg pkg = cast(AlpmPkg)j.data;
				char* matched = null;
				string name = pkg.getName();
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
					_alpm_log(this.handle, ALPM_LOG_DEBUG,
							"search target '%s' matched '%s' on package '%s'\n",
							targ, matched, name);
					ret.insertBack(pkg);
				}
			}

			/* Free the existing search list, and use the returned list for the
			* next needle. This allows for AND-based package searching. */
			// alpm_list_free(list);
			list = ret;
		}

		return ret;
	}

	override int opCmp(Object other) const {
		return cmp(this.treename, (cast(AlpmDB)other).treename);
	}

	/* Returns a new package cache from db.
	* It frees the cache if it already exists.
	*/
	private int loadPkgCache()
	{
		// _alpm_db_free_pkgcache(db);
		this.freePkgCache();

		_alpm_log(this.handle, ALPM_LOG_DEBUG, "loading package cache for repository '%s'\n",
				this.treename);
		if(this.populate() == -1) {
			_alpm_log(this.handle, ALPM_LOG_DEBUG,
					"failed to load package cache for repository '%s'\n", this.treename);
			return -1;
		}

		this.status |= AlpmDBStatus.PkgCache;
		return 0;
	}

	AlpmStrings findRequiredBy(AlpmPkg pkg, int optional) {
		AlpmStrings res;
		AlpmDeps deps;
		foreach(cachepkg; this.pkgcache.getList[]) { 

			if(optional == 0) {
				deps = cachepkg.getDepends();
			} else {
				deps = cachepkg.getOptDepends();
			}

			foreach(dep; deps[]) {
				if(_alpm_depcmp(pkg, dep)) {
					string cachepkgname = cachepkg.getName();
					if(res[].canFind(cachepkgname)) 
						res.insertBack(cachepkgname);
				}
			}
		}
		return res;
	}

	private void freeGroupCache()
	{
		if(!(this.status & AlpmDBStatus.GrpCache)) {
			return;
		}

		_alpm_log(this.handle, ALPM_LOG_DEBUG,
				"freeing group cache for repository '%s'\n", this.treename);

		this.grpcache.clear();
		this.status &= ~AlpmDBStatus.GrpCache;
	}

	/* "duplicate" pkg then add it to pkgcache */
	int addPkgInCache(AlpmPkg pkg)
	{
		AlpmPkg newpkg = null;

		if(pkg is null || !(this.status & AlpmDBStatus.PkgCache)) {
			return -1;
		}

		if((newpkg = pkg.dup) !is null) {
			/* we return memory on "non-fatal" error in _alpm_pkg_dup */
			destroy!false(newpkg);
			return -1;
		}

		_alpm_log(this.handle, ALPM_LOG_DEBUG, "adding entry '%s' in '%s' cache\n",
							pkg.getName(), this.treename);
		if(newpkg.origin == AlpmPkgFrom.File) {
			free(cast(void*)newpkg.getOriginFile());
		}

		// auto origin = (this.status & AlpmDBStatus.Local)
		auto origin = (this.status & AlpmDBStatus.Local)
			? AlpmPkgFrom.LocalDB
			: AlpmPkgFrom.SyncDB;
		newpkg.setOriginDB(this, origin);
		
		if(this.pkgcache.addSorted(newpkg) is null) {
			destroy!false(newpkg);
			RET_ERR(this.handle, ALPM_ERR_MEMORY, -1);
		}

		this.freeGroupCache();

		return 0;
	}

	int removePkgFromCache(AlpmPkg pkg)
	{
		AlpmPkg data = null;

		if(pkg is null || !(this.status & AlpmDBStatus.PkgCache)) {
			return -1;
		}

		_alpm_log(this.handle, ALPM_LOG_DEBUG, "removing entry '%s' from '%s' cache\n",
							pkg.getName(), this.treename);

		this.pkgcache = this.pkgcache.remove(pkg, &data);
		if(data is null) {
			/* package not found */
			_alpm_log(this.handle, ALPM_LOG_DEBUG, "cannot remove entry '%s' from '%s' cache: not found\n",
								pkg.getName(), this.treename);
			return -1;
		}

		destroy!false(data);

		this.freeGroupCache();

		return 0;
	}

	AlpmPkg getPkgFromCache(char*target)
	{
		AlpmPkgHash pkgcache = this.getPkgCacheHash();
		if(!pkgcache) {
			return null;
		}

		return pkgcache.find(target);
	}
}

alias AlpmDBs = AlpmList!AlpmDB;

int _alpm_db_cmp( void* d1,  void* d2)
{
	  AlpmDB db1 = cast(AlpmDB)d1;
	  AlpmDB db2 = cast(AlpmDB)d2;
	return db1.treename == db2.treename;
}
