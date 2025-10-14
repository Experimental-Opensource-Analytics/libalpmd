module libalpmd.db;
@nogc nothrow:
extern(C): __gshared:
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

/* libalpm */
// import libalpmd.db;
import libalpmd.alpm_list;
import libalpmd.log;
import libalpmd.util;
import libalpmd.handle;
import libalpmd.alpm;
import libalpmd._package;
import libalpmd.group;
import libalpmd.pkghash;

enum alpm_dbinfrq_t {
	INFRQ_BASE = (1 << 0),
	INFRQ_DESC = (1 << 1),
	INFRQ_FILES = (1 << 2),
	INFRQ_SCRIPTLET = (1 << 3),
	INFRQ_DSIZE = (1 << 4),
	/* ALL should be info stored in the package or database */
	INFRQ_ALL = INFRQ_BASE | INFRQ_DESC | INFRQ_FILES |
		INFRQ_SCRIPTLET | INFRQ_DSIZE,
	INFRQ_ERROR = (1 << 30)
}
alias INFRQ_BASE = alpm_dbinfrq_t.INFRQ_BASE;
alias INFRQ_DESC = alpm_dbinfrq_t.INFRQ_DESC;
alias INFRQ_FILES = alpm_dbinfrq_t.INFRQ_FILES;
alias INFRQ_SCRIPTLET = alpm_dbinfrq_t.INFRQ_SCRIPTLET;
alias INFRQ_DSIZE = alpm_dbinfrq_t.INFRQ_DSIZE;
alias INFRQ_ALL = alpm_dbinfrq_t.INFRQ_ALL;
alias INFRQ_ERROR = alpm_dbinfrq_t.INFRQ_ERROR;


/** Database status. Bitflags. */
enum _alpm_dbstatus_t {
	DB_STATUS_VALID = (1 << 0),
	DB_STATUS_INVALID = (1 << 1),
	DB_STATUS_EXISTS = (1 << 2),
	DB_STATUS_MISSING = (1 << 3),

	DB_STATUS_LOCAL = (1 << 10),
	DB_STATUS_PKGCACHE = (1 << 11),
	DB_STATUS_GRPCACHE = (1 << 12)
}
alias DB_STATUS_VALID = _alpm_dbstatus_t.DB_STATUS_VALID;
alias DB_STATUS_INVALID = _alpm_dbstatus_t.DB_STATUS_INVALID;
alias DB_STATUS_EXISTS = _alpm_dbstatus_t.DB_STATUS_EXISTS;
alias DB_STATUS_MISSING = _alpm_dbstatus_t.DB_STATUS_MISSING;
alias DB_STATUS_LOCAL = _alpm_dbstatus_t.DB_STATUS_LOCAL;
alias DB_STATUS_PKGCACHE = _alpm_dbstatus_t.DB_STATUS_PKGCACHE;
alias DB_STATUS_GRPCACHE = _alpm_dbstatus_t.DB_STATUS_GRPCACHE;



struct db_operations {
	int function(alpm_db_t*) validate;
	int function(alpm_db_t*) populate;
	void function(alpm_db_t*) unregister;
}

/* Database */
struct _alpm_db_t {
	alpm_handle_t* handle;
	char* treename;
	/* do not access directly, use _alpm_db_path(db) for lazy access */
	char* _path;
	alpm_pkghash_t* pkgcache;
	alpm_list_t* grpcache;
	alpm_list_t* cache_servers;
	alpm_list_t* servers;
	const(db_operations)* ops;

	/* bitfields for validity, local, loaded caches, etc. */
	/* From _alpm_dbstatus_t */
	int status;
	/* alpm_siglevel_t */
	int siglevel;
	/* alpm_db_usage_t */
	int usage;
}

alias alpm_db_t = _alpm_db_t;

alpm_db_t * alpm_register_syncdb(alpm_handle_t* handle, const(char)* treename, int siglevel)
{
	alpm_list_t* i = void;

	/* Sanity checks */
	CHECK_HANDLE(handle);
	ASSERT(treename != null && strlen(treename) != 0);
	ASSERT(!strchr(treename, '/'));
	/* Do not register a database if a transaction is on-going */
	ASSERT(handle.trans == null);

	/* ensure database name is unique */
	if(strcmp(treename, "local") == 0) {
		RET_ERR(handle, ALPM_ERR_DB_NOT_NULL, null);
	}
	for(i = handle.dbs_sync; i; i = i.next) {
		alpm_db_t* d = i.data;
		if(strcmp(treename, d.treename) == 0) {
			RET_ERR(handle, ALPM_ERR_DB_NOT_NULL, null);
		}
	}

	return _alpm_db_register_sync(handle, treename, siglevel);
}

/* Helper function for alpm_db_unregister{_all} */
void _alpm_db_unregister(alpm_db_t* db)
{
	if(db == null) {
		return;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG, "unregistering database '%s'\n", db.treename);
	_alpm_db_free(db);
}

int  alpm_unregister_all_syncdbs(alpm_handle_t* handle)
{
	alpm_list_t* i = void;
	alpm_db_t* db = void;

	/* Sanity checks */
	CHECK_HANDLE(handle);
	/* Do not unregister a database if a transaction is on-going */
	ASSERT(handle.trans == null);

	/* unregister all sync dbs */
	for(i = handle.dbs_sync; i; i = i.next) {
		db = i.data;
		db.ops.unregister(db);
		i.data = null;
	}
	FREELIST(handle.dbs_sync);
	return 0;
}

int  alpm_db_unregister(alpm_db_t* db)
{
	int found = 0;
	alpm_handle_t* handle = void;

	/* Sanity checks */
	ASSERT(db != null);
	/* Do not unregister a database if a transaction is on-going */
	handle = db.handle;
	handle.pm_errno = ALPM_ERR_OK;
	ASSERT(handle.trans == null);

	if(db == handle.db_local) {
		handle.db_local = null;
		found = 1;
	} else {
		/* Warning : this function shouldn't be used to unregister all sync
		 * databases by walking through the list returned by
		 * alpm_get_syncdbs, because the db is removed from that list here.
		 */
		void* data = void;
		handle.dbs_sync = alpm_list_remove(handle.dbs_sync,
				db, _alpm_db_cmp, &data);
		if(data) {
			found = 1;
		}
	}

	if(!found) {
		RET_ERR(handle, ALPM_ERR_DB_NOT_FOUND, -1);
	}

	db.ops.unregister(db);
	return 0;
}

alpm_list_t * alpm_db_get_cache_servers(const(alpm_db_t)* db)
{
	ASSERT(db != null);
	return db.cache_servers;
}

int  alpm_db_set_cache_servers(alpm_db_t* db, alpm_list_t* cache_servers)
{
	alpm_list_t* i = void;
	ASSERT(db != null);
	FREELIST(db.cache_servers);
	for(i = cache_servers; i; i = i.next) {
		char* url = i.data;
		if(alpm_db_add_cache_server(db, url) != 0) {
			return -1;
		}
	}
	return 0;
}

alpm_list_t * alpm_db_get_servers(const(alpm_db_t)* db)
{
	ASSERT(db != null);
	return db.servers;
}

int  alpm_db_set_servers(alpm_db_t* db, alpm_list_t* servers)
{
	alpm_list_t* i = void;
	ASSERT(db != null);
	FREELIST(db.servers);
	for(i = servers; i; i = i.next) {
		char* url = i.data;
		if(alpm_db_add_server(db, url) != 0) {
			return -1;
		}
	}
	return 0;
}

private char* sanitize_url(const(char)* url)
{
	char* newurl = void;
	size_t len = strlen(url);

	STRDUP(newurl, url);
	/* strip the trailing slash if one exists */
	if(newurl[len - 1] == '/') {
		newurl[len - 1] = '\0';
	}
	return newurl;
}

int  alpm_db_add_cache_server(alpm_db_t* db, const(char)* url)
{
	char* newurl = void;

	/* Sanity checks */
	ASSERT(db != null);
	db.handle.pm_errno = ALPM_ERR_OK;
	ASSERT(url != null && strlen(url) != 0);

	newurl = sanitize_url(url);
	ASSERT(newurl != null);

	db.cache_servers = alpm_list_add(db.cache_servers, newurl);
	_alpm_log(db.handle, ALPM_LOG_DEBUG, "adding new cache server URL to database '%s': %s\n",
			db.treename, newurl);

	return 0;
}

int  alpm_db_add_server(alpm_db_t* db, const(char)* url)
{
	char* newurl = void;

	/* Sanity checks */
	ASSERT(db != null);
	db.handle.pm_errno = ALPM_ERR_OK;
	ASSERT(url != null && strlen(url) != 0);

	newurl = sanitize_url(url);
	ASSERT(newurl != null);

	db.servers = alpm_list_add(db.servers, newurl);
	_alpm_log(db.handle, ALPM_LOG_DEBUG, "adding new server URL to database '%s': %s\n",
			db.treename, newurl);

	return 0;
}

int  alpm_db_remove_cache_server(alpm_db_t* db, const(char)* url)
{
	char* newurl = void, vdata = null;
	int ret = 1;

	/* Sanity checks */
	ASSERT(db != null);
	db.handle.pm_errno = ALPM_ERR_OK;
	ASSERT(url != null && strlen(url) != 0);

	newurl = sanitize_url(url);
	ASSERT(newurl != null);

	db.cache_servers = alpm_list_remove_str(db.cache_servers, newurl, &vdata);

	if(vdata) {
		_alpm_log(db.handle, ALPM_LOG_DEBUG, "removed cache server URL from database '%s': %s\n",
				db.treename, newurl);
		free(vdata);
		ret = 0;
	}

	free(newurl);
	return ret;
}

int  alpm_db_remove_server(alpm_db_t* db, const(char)* url)
{
	char* newurl = void, vdata = null;
	int ret = 1;

	/* Sanity checks */
	ASSERT(db != null);
	db.handle.pm_errno = ALPM_ERR_OK;
	ASSERT(url != null && strlen(url) != 0);

	newurl = sanitize_url(url);
	ASSERT(newurl != null);

	db.servers = alpm_list_remove_str(db.servers, newurl, &vdata);

	if(vdata) {
		_alpm_log(db.handle, ALPM_LOG_DEBUG, "removed server URL from database '%s': %s\n",
				db.treename, newurl);
		free(vdata);
		ret = 0;
	}

	free(newurl);
	return ret;
}

alpm_handle_t * alpm_db_get_handle(alpm_db_t* db)
{
	ASSERT(db != null);
	return db.handle;
}

const(char)* alpm_db_get_name(const(alpm_db_t)* db)
{
	ASSERT(db != null);
	return db.treename;
}

int  alpm_db_get_siglevel(alpm_db_t* db)
{
	ASSERT(db != null);
	if(db.siglevel & ALPM_SIG_USE_DEFAULT) {
		return db.handle.siglevel;
	} else {
		return db.siglevel;
	}
}

int  alpm_db_get_valid(alpm_db_t* db)
{
	ASSERT(db != null);
	db.handle.pm_errno = ALPM_ERR_OK;
	return db.ops.validate(db);
}

alpm_pkg_t * alpm_db_get_pkg(alpm_db_t* db, const(char)* name)
{
	alpm_pkg_t* pkg = void;
	ASSERT(db != null);
	db.handle.pm_errno = ALPM_ERR_OK;
	ASSERT(name != null && strlen(name) != 0);

	pkg = _alpm_db_get_pkgfromcache(db, name);
	if(!pkg) {
		RET_ERR(db.handle, ALPM_ERR_PKG_NOT_FOUND, null);
	}
	return pkg;
}

alpm_list_t * alpm_db_get_pkgcache(alpm_db_t* db)
{
	ASSERT(db != null);
	db.handle.pm_errno = ALPM_ERR_OK;
	return _alpm_db_get_pkgcache(db);
}

alpm_group_t * alpm_db_get_group(alpm_db_t* db, const(char)* name)
{
	ASSERT(db != null);
	db.handle.pm_errno = 0;
	ASSERT(name != null && strlen(name) != 0);

	return _alpm_db_get_groupfromcache(db, name);
}

alpm_list_t * alpm_db_get_groupcache(alpm_db_t* db)
{
	ASSERT(db != null);
	db.handle.pm_errno = ALPM_ERR_OK;

	return _alpm_db_get_groupcache(db);
}

int  alpm_db_search(alpm_db_t* db, const(alpm_list_t)* needles, alpm_list_t** ret)
{
	ASSERT(db != null && ret != null && *ret == null);
	db.handle.pm_errno = ALPM_ERR_OK;

	return _alpm_db_search(db, needles, ret);
}

int  alpm_db_set_usage(alpm_db_t* db, int usage)
{
	ASSERT(db != null);
	db.usage = usage;
	return 0;
}

int  alpm_db_get_usage(alpm_db_t* db, int* usage)
{
	ASSERT(db != null);
	ASSERT(usage != null);
	*usage = db.usage;
	return 0;
}

alpm_db_t* _alpm_db_new(const(char)* treename, int is_local)
{
	alpm_db_t* db = void;

	CALLOC(db, 1, alpm_db_t.sizeof);
	STRDUP(db.treename, treename);
	if(is_local) {
		db.status |= DB_STATUS_LOCAL;
	} else {
		db.status &= ~DB_STATUS_LOCAL;
	}
	db.usage = ALPM_DB_USAGE_ALL;

	return db;
}

void _alpm_db_free(alpm_db_t* db)
{
	ASSERT(db != null);
	/* cleanup pkgcache */
	_alpm_db_free_pkgcache(db);
	/* cleanup server list */
	FREELIST(db.cache_servers);
	FREELIST(db.servers);
	FREE(db._path);
	FREE(db.treename);
	FREE(db);

	return;
}

const(char)* _alpm_db_path(alpm_db_t* db)
{
	if(!db) {
		return null;
	}
	if(!db._path) {
		const(char)* dbpath = void;
		size_t pathsize = void;

		dbpath = db.handle.dbpath;
		if(!dbpath) {
			_alpm_log(db.handle, ALPM_LOG_ERROR, _("database path is undefined\n"));
			RET_ERR(db.handle, ALPM_ERR_DB_OPEN, null);
		}

		if(db.status & DB_STATUS_LOCAL) {
			pathsize = strlen(dbpath) + strlen(db.treename) + 2;
			CALLOC(db._path, 1, pathsize);
			snprintf(db._path, pathsize, "%s%s/", dbpath, db.treename);
		} else {
			const(char)* dbext = db.handle.dbext;

			pathsize = strlen(dbpath) + 5 + strlen(db.treename) + strlen(dbext) + 1;
			CALLOC(db._path, 1, pathsize);
			/* all sync DBs now reside in the sync/ subdir of the dbpath */
			snprintf(db._path, pathsize, "%ssync/%s%s", dbpath, db.treename, dbext);
		}
		_alpm_log(db.handle, ALPM_LOG_DEBUG, "database path for tree %s set to %s\n",
				db.treename, db._path);
	}
	return db._path;
}

int _alpm_db_cmp(const(void)* d1, const(void)* d2)
{
	const(alpm_db_t)* db1 = d1;
	const(alpm_db_t)* db2 = d2;
	return strcmp(db1.treename, db2.treename);
}

int _alpm_db_search(alpm_db_t* db, const(alpm_list_t)* needles, alpm_list_t** ret)
{
	const(alpm_list_t)* i = void, j = void, k = void;

	if(!(db.usage & ALPM_DB_USAGE_SEARCH)) {
		return 0;
	}

	/* copy the pkgcache- we will free the list var after each needle */
	alpm_list_t* list = alpm_list_copy(_alpm_db_get_pkgcache(db));

	for(i = needles; i; i = i.next) {
		char* targ = void;
		regex_t reg = void;

		if(i.data == null) {
			continue;
		}
		*ret = null;
		targ = i.data;
		_alpm_log(db.handle, ALPM_LOG_DEBUG, "searching for target '%s'\n", targ);

		if(regcomp(&reg, targ, REG_EXTENDED | REG_NOSUB | REG_ICASE | REG_NEWLINE) != 0) {
			db.handle.pm_errno = ALPM_ERR_INVALID_REGEX;
			alpm_list_free(list);
			alpm_list_free(*ret);
			return -1;
		}

		for(j = cast(const(alpm_list_t)*) list; j; j = j.next) {
			alpm_pkg_t* pkg = j.data;
			const(char)* matched = null;
			const(char)* name = pkg.name;
			const(char)* desc = alpm_pkg_get_desc(pkg);

			/* check name as regex AND as plain text */
			if(name && (regexec(&reg, name, 0, 0, 0) == 0 || strstr(name, targ))) {
				matched = name;
			}
			/* check desc */
			else if(desc && regexec(&reg, desc, 0, 0, 0) == 0) {
				matched = desc;
			}
			/* TODO: should we be doing this, and should we print something
			 * differently when we do match it since it isn't currently printed? */
			if(!matched) {
				/* check provides */
				for(k = alpm_pkg_get_provides(pkg); k; k = k.next) {
					alpm_depend_t* provide = k.data;
					if(regexec(&reg, provide.name, 0, 0, 0) == 0) {
						matched = provide.name;
						break;
					}
				}
			}
			if(!matched) {
				/* check groups */
				for(k = alpm_pkg_get_groups(pkg); k; k = k.next) {
					if(regexec(&reg, k.data, 0, 0, 0) == 0) {
						matched = k.data;
						break;
					}
				}
			}

			if(matched != null) {
				_alpm_log(db.handle, ALPM_LOG_DEBUG,
						"search target '%s' matched '%s' on package '%s'\n",
						targ, matched, name);
				*ret = alpm_list_add(*ret, pkg);
			}
		}

		/* Free the existing search list, and use the returned list for the
		 * next needle. This allows for AND-based package searching. */
		alpm_list_free(list);
		list = *ret;
		regfree(&reg);
	}

	return 0;
}

/* Returns a new package cache from db.
 * It frees the cache if it already exists.
 */
private int load_pkgcache(alpm_db_t* db)
{
	_alpm_db_free_pkgcache(db);

	_alpm_log(db.handle, ALPM_LOG_DEBUG, "loading package cache for repository '%s'\n",
			db.treename);
	if(db.ops.populate(db) == -1) {
		_alpm_log(db.handle, ALPM_LOG_DEBUG,
				"failed to load package cache for repository '%s'\n", db.treename);
		return -1;
	}

	db.status |= DB_STATUS_PKGCACHE;
	return 0;
}

private void free_groupcache(alpm_db_t* db)
{
	alpm_list_t* lg = void;

	if(db == null || !(db.status & DB_STATUS_GRPCACHE)) {
		return;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG,
			"freeing group cache for repository '%s'\n", db.treename);

	for(lg = db.grpcache; lg; lg = lg.next) {
		_alpm_group_free(lg.data);
		lg.data = null;
	}
	FREELIST(db.grpcache);
	db.status &= ~DB_STATUS_GRPCACHE;
}

void _alpm_db_free_pkgcache(alpm_db_t* db)
{
	if(db == null || db.pkgcache == null) {
		return;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG,
			"freeing package cache for repository '%s'\n", db.treename);

	alpm_list_free_inner(db.pkgcache.list,
			cast(alpm_list_fn_free)_alpm_pkg_free);
	_alpm_pkghash_free(db.pkgcache);
	db.pkgcache = null;
	db.status &= ~DB_STATUS_PKGCACHE;

	free_groupcache(db);
}

alpm_pkghash_t* _alpm_db_get_pkgcache_hash(alpm_db_t* db)
{
	if(db == null) {
		return null;
	}

	if(!(db.status & DB_STATUS_VALID)) {
		RET_ERR(db.handle, ALPM_ERR_DB_INVALID, null);
	}

	if(!(db.status & DB_STATUS_PKGCACHE)) {
		if(load_pkgcache(db)) {
			/* handle->error set in local/sync-db-populate */
			return null;
		}
	}

	return db.pkgcache;
}

alpm_list_t* _alpm_db_get_pkgcache(alpm_db_t* db)
{
	alpm_pkghash_t* hash = _alpm_db_get_pkgcache_hash(db);

	if(hash == null) {
		return null;
	}

	return hash.list;
}

/* "duplicate" pkg then add it to pkgcache */
int _alpm_db_add_pkgincache(alpm_db_t* db, alpm_pkg_t* pkg)
{
	alpm_pkg_t* newpkg = null;

	if(db == null || pkg == null || !(db.status & DB_STATUS_PKGCACHE)) {
		return -1;
	}

	if(_alpm_pkg_dup(pkg, &newpkg)) {
		/* we return memory on "non-fatal" error in _alpm_pkg_dup */
		_alpm_pkg_free(newpkg);
		return -1;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG, "adding entry '%s' in '%s' cache\n",
						newpkg.name, db.treename);
	if(newpkg.origin == ALPM_PKG_FROM_FILE) {
		free(newpkg.origin_data.file);
	}
	newpkg.origin = (db.status & DB_STATUS_LOCAL)
		? ALPM_PKG_FROM_LOCALDB
		: ALPM_PKG_FROM_SYNCDB;
	newpkg.origin_data.db = db;
	if(_alpm_pkghash_add_sorted(&db.pkgcache, newpkg) == null) {
		_alpm_pkg_free(newpkg);
		RET_ERR(db.handle, ALPM_ERR_MEMORY, -1);
	}

	free_groupcache(db);

	return 0;
}

int _alpm_db_remove_pkgfromcache(alpm_db_t* db, alpm_pkg_t* pkg)
{
	alpm_pkg_t* data = null;

	if(db == null || pkg == null || !(db.status & DB_STATUS_PKGCACHE)) {
		return -1;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG, "removing entry '%s' from '%s' cache\n",
						pkg.name, db.treename);

	db.pkgcache = _alpm_pkghash_remove(db.pkgcache, pkg, &data);
	if(data == null) {
		/* package not found */
		_alpm_log(db.handle, ALPM_LOG_DEBUG, "cannot remove entry '%s' from '%s' cache: not found\n",
							pkg.name, db.treename);
		return -1;
	}

	_alpm_pkg_free(data);

	free_groupcache(db);

	return 0;
}

alpm_pkg_t* _alpm_db_get_pkgfromcache(alpm_db_t* db, const(char)* target)
{
	if(db == null) {
		return null;
	}

	alpm_pkghash_t* pkgcache = _alpm_db_get_pkgcache_hash(db);
	if(!pkgcache) {
		return null;
	}

	return _alpm_pkghash_find(pkgcache, target);
}

/* Returns a new group cache from db.
 */
private int load_grpcache(alpm_db_t* db)
{
	alpm_list_t* lp = void;

	if(db == null) {
		return -1;
	}

	_alpm_log(db.handle, ALPM_LOG_DEBUG, "loading group cache for repository '%s'\n",
			db.treename);

	for(lp = _alpm_db_get_pkgcache(db); lp; lp = lp.next) {
		const(alpm_list_t)* i = void;
		alpm_pkg_t* pkg = lp.data;

		for(i = alpm_pkg_get_groups(pkg); i; i = i.next) {
			const(char)* grpname = i.data;
			alpm_list_t* j = void;
			alpm_group_t* grp = null;
			int found = 0;

			/* first look through the group cache for a group with this name */
			for(j = db.grpcache; j; j = j.next) {
				grp = j.data;

				if(strcmp(grp.name, grpname) == 0
						&& !alpm_list_find_ptr(grp.packages, pkg)) {
					grp.packages = alpm_list_add(grp.packages, pkg);
					found = 1;
					break;
				}
			}
			if(found) {
				continue;
			}
			/* we didn't find the group, so create a new one with this name */
			grp = _alpm_group_new(grpname);
			if(!grp) {
				free_groupcache(db);
				return -1;
			}
			grp.packages = alpm_list_add(grp.packages, pkg);
			db.grpcache = alpm_list_add(db.grpcache, grp);
		}
	}

	db.status |= DB_STATUS_GRPCACHE;
	return 0;
}

alpm_list_t* _alpm_db_get_groupcache(alpm_db_t* db)
{
	if(db == null) {
		return null;
	}

	if(!(db.status & DB_STATUS_VALID)) {
		RET_ERR(db.handle, ALPM_ERR_DB_INVALID, null);
	}

	if(!(db.status & DB_STATUS_GRPCACHE)) {
		load_grpcache(db);
	}

	return db.grpcache;
}

alpm_group_t* _alpm_db_get_groupfromcache(alpm_db_t* db, const(char)* target)
{
	alpm_list_t* i = void;

	if(db == null || target == null || strlen(target) == 0) {
		return null;
	}

	for(i = _alpm_db_get_groupcache(db); i; i = i.next) {
		alpm_group_t* info = i.data;

		if(strcmp(info.name, target) == 0) {
			return info;
		}
	}

	return null;
}
