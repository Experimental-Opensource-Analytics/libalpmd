module libalpmd.sync;
@nogc  
   
/*
 *  sync.c
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

import core.sys.posix.sys.types; /* off_t */
// import stdbool;
import core.stdc.stdlib;
import core.stdc.stdio;
import core.stdc.string;
import core.stdc.stdint; /* intmax_t */
import core.sys.posix.unistd;
import core.stdc.limits;
import core.sys.posix.sys.stat;


/* libalpm */
import libalpmd.sync;
import libalpmd.alpm_list;
import libalpmd.log;
import libalpmd._package;
import libalpmd.db;
import libalpmd.deps;
import libalpmd.conflict;
import libalpmd.trans;
import libalpmd.add;
import libalpmd.util;
import libalpmd.handle;
import libalpmd.alpm;
import libalpmd.dload;
import libalpmd.remove;
import libalpmd.diskspace;
import libalpmd.signing;
import libalpmd.be_package;
import libalpmd.group;
import libalpmd.deps;
import libalpmd.error;




struct keyinfo_t {
       char* uid;
       char* keyid;
}

AlpmPkg alpm_sync_get_new_version(AlpmPkg pkg, alpm_list_t* dbs_sync)
{
	alpm_list_t* i = void;
	AlpmPkg spkg = null;

	//ASSERT(pkg != null);
	pkg.handle.pm_errno = ALPM_ERR_OK;

	for(i = dbs_sync; !spkg && i; i = i.next) {
		AlpmDB db = cast(AlpmDB)i.data;
		spkg = _alpm_db_get_pkgfromcache(db, cast(char*)pkg.name);
	}

	if(spkg is null) {
		_alpm_log(pkg.handle, ALPM_LOG_DEBUG, "'%s' not found in sync db => no upgrade\n",
				pkg.name);
		return null;
	}

	/* compare versions and see if spkg is an upgrade */
	if(_alpm_pkg_compare_versions(spkg, pkg) > 0) {
		_alpm_log(pkg.handle, ALPM_LOG_DEBUG, "new version of '%s' found (%s => %s)\n",
					pkg.name, pkg.version_, spkg.version_);
		return spkg;
	}
	/* spkg is not an upgrade */
	return null;
}

private int check_literal(AlpmHandle handle, AlpmPkg lpkg, AlpmPkg spkg, int enable_downgrade)
{
	/* 1. literal was found in sdb */
	int cmp = _alpm_pkg_compare_versions(spkg, lpkg);
	if(cmp > 0) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "new version of '%s' found (%s => %s)\n",
				lpkg.name, lpkg.version_, spkg.version_);
		/* check IgnorePkg/IgnoreGroup */
		if(alpm_pkg_should_ignore(handle, spkg)
				|| alpm_pkg_should_ignore(handle, lpkg)) {
			_alpm_log(handle, ALPM_LOG_WARNING, "%s: ignoring package upgrade (%s => %s)\n",
					lpkg.name, lpkg.version_, spkg.version_);
		} else {
			_alpm_log(handle, ALPM_LOG_DEBUG, "adding package %s-%s to the transaction targets\n",
					spkg.name, spkg.version_);
			return 1;
		}
	} else if(cmp < 0) {
		if(enable_downgrade) {
			/* check IgnorePkg/IgnoreGroup */
			if(alpm_pkg_should_ignore(handle, spkg)
					|| alpm_pkg_should_ignore(handle, lpkg)) {
				_alpm_log(handle, ALPM_LOG_WARNING, "%s: ignoring package downgrade (%s => %s)\n",
						lpkg.name, lpkg.version_, spkg.version_);
			} else {
				_alpm_log(handle, ALPM_LOG_WARNING, "%s: downgrading from version %s to version %s\n",
						lpkg.name, lpkg.version_, spkg.version_);
				return 1;
			}
		} else {
			AlpmDB sdb = spkg.getDB();
			_alpm_log(handle, ALPM_LOG_WARNING, "%s: local (%s) is newer than %s (%s)\n",
					lpkg.name, lpkg.version_, sdb.treename, spkg.version_);
		}
	}
	return 0;
}

private alpm_list_t* check_replacers(AlpmHandle handle, AlpmPkg lpkg, AlpmDB sdb)
{
	/* 2. search for replacers in sdb */
	alpm_list_t* replacers = null;
	alpm_list_t* k = void;
	_alpm_log(handle, ALPM_LOG_DEBUG,
			"searching for replacements for %s in %s\n",
			lpkg.name, sdb.treename);
	for(k = _alpm_db_get_pkgcache(sdb); k; k = k.next) {
		int found = 0;
		AlpmPkg spkg = cast(AlpmPkg)k.data;
		foreach(l; spkg.getReplaces()[]) {
			/* we only want to consider literal matches at this point. */
			if(_alpm_depcmp_literal(lpkg, l)) {
				found = 1;
				break;
			}
		}
		if(found) {
			alpm_question_replace_t question = {
				type: ALPM_QUESTION_REPLACE_PKG,
				replace: 0,
				oldpkg: lpkg,
				newpkg: spkg,
				newdb: sdb
			};
			AlpmPkg tpkg = void;
			/* check IgnorePkg/IgnoreGroup */
			if(alpm_pkg_should_ignore(handle, spkg)
					|| alpm_pkg_should_ignore(handle, lpkg)) {
				_alpm_log(handle, ALPM_LOG_WARNING,
						("ignoring package replacement (%s-%s => %s-%s)\n"),
						lpkg.name, lpkg.version_, spkg.name, spkg.version_);
				continue;
			}

			QUESTION(handle, &question);
			if(!question.replace) {
				continue;
			}

			/* If spkg is already in the target list, we append lpkg to spkg's
			 * removes list */
			tpkg = alpm_pkg_find(handle.trans.add, cast(char*)spkg.name);
			if(tpkg) {
				/* sanity check, multiple repos can contain spkg->name */
				if(tpkg.origin_data.db != sdb) {
					_alpm_log(handle, ALPM_LOG_WARNING, "cannot replace %s by %s\n",
							lpkg.name, spkg.name);
					continue;
				}
				_alpm_log(handle, ALPM_LOG_DEBUG, "appending %s to the removes list of %s\n",
						lpkg.name, tpkg.name);
				tpkg.removes.insertFront(lpkg);
				/* check the to-be-replaced package's reason field */
				if(lpkg.getReason() == ALPM_PKG_REASON_EXPLICIT) {
					tpkg.reason = ALPM_PKG_REASON_EXPLICIT;
				}
			} else {
				/* add spkg to the target list */
				/* copy over reason */
				spkg.reason = lpkg.getReason();
				spkg.removes.insertFront(lpkg);
				_alpm_log(handle, ALPM_LOG_DEBUG,
						"adding package %s-%s to the transaction targets\n",
						spkg.name, spkg.version_);
				replacers = alpm_list_add(replacers, cast(void*)spkg);
			}
		}
	}
	return replacers;
}

int  alpm_sync_sysupgrade(AlpmHandle handle, int enable_downgrade)
{
	AlpmTrans trans = void;

	CHECK_HANDLE(handle);
	trans = handle.trans;
	//ASSERT(trans != null);
	//ASSERT(trans.state == STATE_INITIALIZED);

	_alpm_log(handle, ALPM_LOG_DEBUG, "checking for package upgrades\n");
	for(auto i = _alpm_db_get_pkgcache(handle.db_local); i; i = i.next) {
		AlpmPkg lpkg = cast(AlpmPkg)i.data;

		if(alpm_pkg_find(trans.remove, cast(char*)lpkg.name)) {
			_alpm_log(handle, ALPM_LOG_DEBUG, "%s is marked for removal -- skipping\n", lpkg.name);
			continue;
		}

		if(alpm_pkg_find(trans.add, cast(char*)lpkg.name)) {
			_alpm_log(handle, ALPM_LOG_DEBUG, "%s is already in the target list -- skipping\n", lpkg.name);
			continue;
		}

		/* Search for replacers then literal (if no replacer) in each sync database. */
		for(auto j = handle.dbs_sync; j; j = j.next) {
			AlpmDB sdb = cast(AlpmDB)j.data;
			alpm_list_t* replacers = void;

			if(!(sdb.usage & ALPM_DB_USAGE_UPGRADE)) {
				continue;
			}

			/* Check sdb */
			replacers = check_replacers(handle, lpkg, sdb);
			if(replacers) {
				trans.add = alpm_list_join(trans.add, replacers);
				/* jump to next local package */
				break;
			} else {
				AlpmPkg spkg = _alpm_db_get_pkgfromcache(sdb, cast(char*)lpkg.name);
				if(spkg) {
					if(check_literal(handle, lpkg, spkg, enable_downgrade)) {
						trans.add = alpm_list_add(trans.add, cast(void*)spkg);
					}
					/* jump to next local package */
					break;
				}
			}
		}
	}

	return 0;
}

alpm_list_t * alpm_find_group_pkgs(alpm_list_t* dbs,   char*name)
{
	alpm_list_t* i = void, j = void, pkgs = null, ignorelist = null;

	for(i = dbs; i; i = i.next) {
		AlpmDB db = cast(AlpmDB)i.data;
		AlpmGroup grp = alpm_db_get_group(db, name);

		if(!grp) {
			continue;
		}

		for(j = grp.packages; j; j = j.next) {
			AlpmPkg pkg = cast(AlpmPkg)j.data;
			AlpmTrans trans = db.handle.trans;

			if(alpm_pkg_find(ignorelist, cast(char*)pkg.name)) {
				continue;
			}
			if(trans !is null && trans.flags & ALPM_TRANS_FLAG_NEEDED) {
				AlpmPkg local = _alpm_db_get_pkgfromcache(db.handle.db_local, cast(char*)pkg.name);
				if(local && _alpm_pkg_compare_versions(pkg, local) == 0) {
					/* with the NEEDED flag, packages up to date are not reinstalled */
					_alpm_log(db.handle, ALPM_LOG_WARNING, "%s-%s is up to date -- skipping\n",
							local.name, local.version_);
					ignorelist = alpm_list_add(ignorelist, cast(void*)pkg);
					continue;
				}
			}
			if(alpm_pkg_should_ignore(db.handle, pkg)) {
				alpm_question_install_ignorepkg_t question = {
					type: ALPM_QUESTION_INSTALL_IGNOREPKG,
					install: 0,
					pkg: pkg
				};
				ignorelist = alpm_list_add(ignorelist, cast(void*)pkg);
				QUESTION(db.handle, &question);
				if(!question.install) {
					continue;
				}
			}
			if(!alpm_pkg_find(pkgs, cast(char*)pkg.name)) {
				pkgs = alpm_list_add(pkgs, cast(void*)pkg);
			}
		}
	}
	alpm_list_free(ignorelist);
	return pkgs;
}

/** Compute the size of the files that will be downloaded to install a
 * package.
 * @param newpkg the new package to upgrade to
 */
private int compute_download_size(AlpmPkg newpkg)
{
	  char*fname = void;
	char* fpath = void, fnamepart = null;
	off_t size = 0;
	AlpmHandle handle = newpkg.handle;
	int ret = 0;
	size_t fnamepartlen = 0;

	if(newpkg.origin != ALPM_PKG_FROM_SYNCDB) {
		newpkg.infolevel |= INFRQ_DSIZE;
		newpkg.download_size = 0;
		return 0;
	}

	//ASSERT(newpkg.filename != null);
	fname = cast(char*)newpkg.filename;
	fpath = _alpm_filecache_find(handle, fname);

	/* downloaded file exists, so there's nothing to grab */
	if(fpath) {
		size = 0;
		goto finish;
	}

	fnamepartlen = strlen(fname) + 6;
	CALLOC(fnamepart, fnamepartlen, char.sizeof);
	snprintf(fnamepart, fnamepartlen, "%s.part", fname);
	fpath = _alpm_filecache_find(handle, fnamepart);
	if(fpath) {
		stat_t st = void;
		if(stat(fpath, &st) == 0) {
			/* subtract the size of the .part file */
			_alpm_log(handle, ALPM_LOG_DEBUG, "using (package - .part) size\n");
			size = newpkg.size - st.st_size;
			size = size < 0 ? 0 : size;
		}

		/* tell the caller that we have a partial */
		ret = 1;
	} else {
		size = newpkg.size;
	}

finish:
	_alpm_log(handle, ALPM_LOG_DEBUG, "setting download size %jd for pkg %s\n",
			cast(intmax_t)size, newpkg.name);

	newpkg.infolevel |= INFRQ_DSIZE;
	newpkg.download_size = size;

	FREE(fpath);
	FREE(fnamepart);

	return ret;
}

int _alpm_sync_prepare(AlpmHandle handle, alpm_list_t** data)
{
	alpm_list_t* j = void;
	alpm_list_t* deps = null;
	alpm_list_t* unresolvable = null;
	int from_sync = 0;
	int ret = 0;
	AlpmTrans trans = handle.trans;
	alpm_event_t event = void;

	if(data) {
		*data = null;
	}

	for(auto i = trans.add; i; i = i.next) {
		AlpmPkg spkg = cast(AlpmPkg)i.data;
		if (spkg.origin == ALPM_PKG_FROM_SYNCDB){
			from_sync = 1;
			break;
		}
	}

	/* ensure all sync database are valid if we will be using them */
	for(auto i = handle.dbs_sync; i; i = i.next) {
		  AlpmDB db = cast(AlpmDB)i.data;
		if(db.status & DB_STATUS_INVALID) {
			RET_ERR(handle, ALPM_ERR_DB_INVALID, -1);
		}
		/* missing databases are not allowed if we have sync targets */
		if(from_sync && db.status & DB_STATUS_MISSING) {
			RET_ERR(handle, ALPM_ERR_DB_NOT_FOUND, -1);
		}
	}

	if(!(trans.flags & ALPM_TRANS_FLAG_NODEPS)) {
		alpm_list_t* resolved = null;
		auto remove = trans.remove;
		alpm_list_t* localpkgs = void;

		/* Build up list by repeatedly resolving each transaction package */
		/* Resolve targets dependencies */
		event.type = ALPM_EVENT_RESOLVEDEPS_START;
		EVENT(handle, &event);
		_alpm_log(handle, ALPM_LOG_DEBUG, "resolving target's dependencies\n");

		/* build remove list for resolvedeps */
		for(auto i = trans.add; i; i = i.next) {
			AlpmPkg spkg = cast(AlpmPkg)i.data;
			auto range = spkg.removes[];
			for(auto pkg = range.front; !range.empty; range.popFront) {
				remove = alpm_list_add(remove, cast(void*)pkg);
			}
		}

		/* Compute the fake local database for resolvedeps (partial fix for the
		 * phonon/qt issue) */
		localpkgs = alpm_list_diff(_alpm_db_get_pkgcache(handle.db_local),
				trans.add, &_alpm_pkg_cmp);

		/* Resolve packages in the transaction one at a time, in addition
		   building up a list of packages which could not be resolved. */
		for(auto i = trans.add; i; i = i.next) {
			AlpmPkg pkg = cast(AlpmPkg)i.data;
			if(_alpm_resolvedeps(handle, localpkgs, pkg, trans.add,
						&resolved, remove, data) == -1) {
				unresolvable = alpm_list_add(unresolvable, cast(void*)pkg);
			}
			/* Else, [resolved] now additionally contains [pkg] and all of its
			   dependencies not already on the list */
		}
		alpm_list_free(localpkgs);
		alpm_list_free(remove);

		/* If there were unresolvable top-level packages, prompt the user to
		   see if they'd like to ignore them rather than failing the sync */
		if(unresolvable != null) {
			alpm_question_remove_pkgs_t question = {
				type: ALPM_QUESTION_REMOVE_PKGS,
				skip: 0,
				packages: unresolvable
			};
			QUESTION(handle, &question);
			if(question.skip) {
				/* User wants to remove the unresolvable packages from the
				   transaction. The packages will be removed from the actual
				   transaction when the transaction packages are replaced with a
				   dependency-reordered list below */
				(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_OK;
				if(data) {
					alpm_list_free_inner(*data,
							cast(alpm_list_fn_free)&alpm_depmissing_free);
					alpm_list_free(*data);
					*data = null;
				}
			} else {
				/* pm_errno was set by resolvedeps, callback may have overwrote it */
				alpm_list_free(resolved);
				alpm_list_free(unresolvable);
				ret = -1;
				GOTO_ERR(handle, ALPM_ERR_UNSATISFIED_DEPS, "cleanup");
			}
		}

		/* Ensure two packages don't have the same filename */
		for(auto i = resolved; i; i = i.next) {
			AlpmPkg pkg1 = cast(AlpmPkg)i.data;
			for(j = i.next; j; j = j.next) {
				AlpmPkg pkg2 = cast(AlpmPkg)j.data;
				if(pkg1.filename == pkg2.filename) {
					ret = -1;
					(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_TRANS_DUP_FILENAME;
					_alpm_log(handle, ALPM_LOG_ERROR, "packages %s and %s have the same filename: %s\n",
						pkg1.name, pkg2.name, pkg1.filename);
				}
			}
		}

		if(ret != 0) {
			alpm_list_free(resolved);
			goto cleanup;
		}

		/* Set DEPEND reason for pulled packages */
		for(auto i = resolved; i; i = i.next) {
			AlpmPkg pkg = cast(AlpmPkg)i.data;
			if(!alpm_pkg_find(trans.add, cast(char*)pkg.name)) {
				pkg.reason = ALPM_PKG_REASON_DEPEND;
			}
		}

		/* Unresolvable packages will be removed from the target list; set these
		 * aside in the transaction as a list we won't operate on. If we free them
		 * before the end of the transaction, we may kill pointers the frontend
		 * holds to package objects. */
		trans.unresolvable = unresolvable;

		alpm_list_free(trans.add);
		trans.add = resolved;

		event.type = ALPM_EVENT_RESOLVEDEPS_DONE;
		EVENT(handle, &event);
	}

	if(!(trans.flags & ALPM_TRANS_FLAG_NOCONFLICTS)) {
		/* check for inter-conflicts and whatnot */
		event.type = ALPM_EVENT_INTERCONFLICTS_START;
		EVENT(handle, &event);

		_alpm_log(handle, ALPM_LOG_DEBUG, "looking for conflicts\n");

		/* 1. check for conflicts in the target list */
		_alpm_log(handle, ALPM_LOG_DEBUG, "check targets vs targets\n");
		deps = _alpm_innerconflicts(handle, trans.add);

		for(auto i = deps; i; i = i.next) {
			alpm_conflict_t* conflict = cast(alpm_conflict_t*)i.data;
			string name1 = conflict.package1.name;
			string name2 = conflict.package2.name;
			AlpmPkg rsync = void, sync = void, sync1 = void, sync2 = void;

			/* have we already removed one of the conflicting targets? */
			sync1 = alpm_pkg_find(trans.add, cast(char*)name1);
			sync2 = alpm_pkg_find(trans.add, cast(char*)name2);
			if(!sync1 || !sync2) {
				continue;
			}

			_alpm_log(handle, ALPM_LOG_DEBUG, "conflicting packages in the sync list: '%s' <-> '%s'\n",
					name1, name2);

			/* if sync1 provides sync2, we remove sync2 from the targets, and vice versa */
			AlpmDepend dep1 = alpm_dep_from_string(cast(char*)name1);
			AlpmDepend dep2 = alpm_dep_from_string(cast(char*)name2);
			if(_alpm_depcmp(sync1, dep2)) {
				rsync = sync2;
				sync = sync1;
			} else if(_alpm_depcmp(sync2, dep1)) {
				rsync = sync1;
				sync = sync2;
			} else {
				_alpm_log(handle, ALPM_LOG_ERROR, "unresolvable package conflicts detected\n");
				(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_CONFLICTING_DEPS;
				ret = -1;
				if(data) {
					alpm_conflict_t* newconflict = _alpm_conflict_dup(conflict);
					if(newconflict) {
						*data = alpm_list_add(*data, newconflict);
					}
				}
				alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_conflict_free);
				alpm_list_free(deps);
				alpm_dep_free(cast(void*)dep1);
				alpm_dep_free(cast(void*)dep2);
				goto cleanup;
			}
			alpm_dep_free(cast(void*)dep1);
			alpm_dep_free(cast(void*)dep2);

			/* Prints warning */
			_alpm_log(handle, ALPM_LOG_WARNING,
					("removing '%s-%s' from target list because it conflicts with '%s-%s'\n"),
					rsync.name, rsync.version_, sync.name, sync.version_);
			trans.add = alpm_list_remove(trans.add, cast(void*)rsync, &_alpm_pkg_cmp, null);
			/* rsync is not a transaction target anymore */
			trans.unresolvable = alpm_list_add(trans.unresolvable, cast(void*)rsync);
		}

		alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_conflict_free);
		alpm_list_free(deps);
		deps = null;

		/* 2. we check for target vs db conflicts (and resolve)*/
		_alpm_log(handle, ALPM_LOG_DEBUG, "check targets vs db and db vs targets\n");
		deps = _alpm_outerconflicts(handle.db_local, trans.add);

		for(auto i = deps; i; i = i.next) {
			alpm_question_conflict_t question = {
				type: ALPM_QUESTION_CONFLICT_PKG,
				remove: 0,
				conflict: cast(alpm_conflict_t*)i.data
			};
			alpm_conflict_t* conflict = cast(alpm_conflict_t*)i.data;
			string name1 = conflict.package1.name;
			string name2 = conflict.package2.name;
			int found = 0;

			/* if name2 (the local package) is not elected for removal,
			   we ask the user */
			if(alpm_pkg_find(trans.remove, cast(char*)name2)) {
				found = 1;
			}
			for(j = trans.add; j && !found; j = j.next) {
				AlpmPkg spkg = cast(AlpmPkg)j.data;
				if(alpm_pkg_find_n(spkg.removes, cast(char*)name2)) {
				// if(spkg.removes[].canFind)
					found = 1;
				}
			}
			if(found) {
				continue;
			}

			_alpm_log(handle, ALPM_LOG_DEBUG, "package '%s-%s' conflicts with '%s-%s'\n",
					name1, conflict.package1.version_, name2,conflict.package2.version_);

			QUESTION(handle, &question);
			if(question.remove) {
				/* append to the removes list */
				AlpmPkg sync = alpm_pkg_find(trans.add, cast(char*)name1);
				AlpmPkg local = _alpm_db_get_pkgfromcache(handle.db_local, cast(char*)name2);
				_alpm_log(handle, ALPM_LOG_DEBUG, "electing '%s' for removal\n", name2);
				sync.removes.insertFront(local);
			} else { /* abort */
				_alpm_log(handle, ALPM_LOG_ERROR, "unresolvable package conflicts detected\n");
				(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_CONFLICTING_DEPS;
				ret = -1;
				if(data) {
					alpm_conflict_t* newconflict = _alpm_conflict_dup(conflict);
					if(newconflict) {
						*data = alpm_list_add(*data, newconflict);
					}
				}
				alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_conflict_free);
				alpm_list_free(deps);
				goto cleanup;
			}
		}
		event.type = ALPM_EVENT_INTERCONFLICTS_DONE;
		EVENT(handle, &event);
		alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_conflict_free);
		alpm_list_free(deps);
	}

	/* Build trans->remove list */
	for(auto i = trans.add; i; i = i.next) {
		AlpmPkg spkg = cast(AlpmPkg)i.data;
		foreach(rpkg; spkg.removes[]) {
			// AlpmPkg rpkg = cast(AlpmPkg)j.data;
			if(!alpm_pkg_find(trans.remove, cast(char*)rpkg.name)) {
				AlpmPkg copy = void;
				_alpm_log(handle, ALPM_LOG_DEBUG, "adding '%s' to remove list\n", rpkg.name);
				if(_alpm_pkg_dup(rpkg, &copy) == -1) {
					return -1;
				}
				trans.remove = alpm_list_add(trans.remove, cast(void*)copy);
			}
		}
	}

	if(!(trans.flags & ALPM_TRANS_FLAG_NODEPS)) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "checking dependencies\n");
		deps = alpm_checkdeps(handle, _alpm_db_get_pkgcache(handle.db_local),
				trans.remove, trans.add, 1);
		if(deps) {
			(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_UNSATISFIED_DEPS;
			ret = -1;
			if(data) {
				*data = deps;
			} else {
				alpm_list_free_inner(deps,
						cast(alpm_list_fn_free)&alpm_depmissing_free);
				alpm_list_free(deps);
			}
			goto cleanup;
		}
	}
	for(auto i = trans.add; i; i = i.next) {
		/* update download size field */
		AlpmPkg spkg = cast(AlpmPkg)i.data;
		AlpmPkg lpkg = alpm_db_get_pkg(handle.db_local, cast(char*)spkg.name);
		if(compute_download_size(spkg) < 0) {
			ret = -1;
			goto cleanup;
		}
		if(lpkg && _alpm_pkg_dup(lpkg, &spkg.oldpkg) != 0) {
			ret = -1;
			goto cleanup;
		}
	}

cleanup:
	return ret;
}

off_t  alpm_pkg_download_size(AlpmPkg newpkg)
{
	if(!(newpkg.infolevel & INFRQ_DSIZE)) {
		compute_download_size(newpkg);
	}
	return newpkg.download_size;
}

/**
 * Prompts to delete the file now that we know it is invalid.
 * @param handle the context handle
 * @param filename the absolute path of the file to test
 * @param reason an error code indicating the reason for package invalidity
 *
 * @return 1 if file was removed, 0 otherwise
 */
private int prompt_to_delete(AlpmHandle handle,   char*filepath, alpm_errno_t reason)
{
	alpm_question_corrupted_t question = {
		type: ALPM_QUESTION_CORRUPTED_PKG,
		remove: 0,
		filepath: filepath,
		reason: reason
	};
	QUESTION(handle, &question);
	if(question.remove) {
		char* sig_filepath = void;

		unlink(filepath);

		sig_filepath = _alpm_sigpath(handle, filepath);
		unlink(sig_filepath);
		FREE(sig_filepath);
	}
	return question.remove;
}

private int find_dl_candidates(AlpmHandle handle, alpm_list_t** files)
{
	for(alpm_list_t* i = handle.trans.add; i; i = i.next) {
		AlpmPkg spkg = cast(AlpmPkg)i.data;

		if(spkg.origin != ALPM_PKG_FROM_FILE) {
			AlpmDB repo = spkg.origin_data.db;
			bool need_download = void;
			int siglevel = alpm_db_get_siglevel(spkg.getDB());

			if(!repo.servers) {
				(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_SERVER_NONE;
				_alpm_log(handle, ALPM_LOG_ERROR, "%s: %s\n",
						alpm_strerror(handle.pm_errno), repo.treename);
				return -1;
			}

			//ASSERT(spkg.filename != null);

			need_download = spkg.download_size != 0 || !_alpm_filecache_exists(handle, cast(char*)spkg.filename);
			/* even if the package file in the cache we need to check for
			 * accompanion *.sig file as well.
			 * If *.sig is not cached then force download the package + its signature file.
			 */
			if(!need_download && (siglevel & ALPM_SIG_PACKAGE)) {
				char* sig_filename = null;
				int len = cast(int)spkg.filename.length + 5;

				MALLOC(sig_filename, len);
				snprintf(sig_filename, len, "%s.sig", cast(char*)spkg.filename);

				need_download = !_alpm_filecache_exists(handle, sig_filename);

				FREE(sig_filename);
			}

			if(need_download) {
				*files = alpm_list_add(*files, cast(void*)spkg);
			}
		}
	}

	return 0;
}


private int download_files(AlpmHandle handle)
{
	  char*cachedir = void;
	char* temporary_cachedir = null;
	alpm_list_t* i = void, files = null;
	int ret = 0;
	alpm_event_t event = void;
	alpm_list_t* payloads = null;

	cachedir = _alpm_filecache_setup(handle);
	temporary_cachedir = _alpm_temporary_download_dir_setup(cachedir, cast(char*)handle.sandboxuser);
	if(temporary_cachedir == null) {
		ret = -1;
		goto finish;
	}alpm_pkg_get_db
alpm_pkg_get_db
alpm_pkg_get_db
	handle.trans.state = STATE_DOWNLOADING;

	ret = find_dl_candidates(handle, &files);
	if(ret != 0) {
		goto finish;
	}

	if(files) {
		/* check for necessary disk space for download */
		if(handle.checkspace) {
			off_t* file_sizes = void;
			size_t idx = void, num_files = void;

			_alpm_log(handle, ALPM_LOG_DEBUG, "checking available disk space for download\n");

			num_files = alpm_list_count(files);
			CALLOC(file_sizes, num_files, off_t.sizeof);

			for(i = files, idx = 0; i; i = i.next, idx++) {
				 AlpmPkg pkg = cast(AlpmPkg)i.data;
				file_sizes[idx] = pkg.download_size;
			}

			ret = _alpm_check_downloadspace(handle, temporary_cachedir, num_files, file_sizes);
			free(file_sizes);

			if(ret != 0) {
				goto finish;
			}
		}

		event.type = ALPM_EVENT_PKG_RETRIEVE_START;
		event.pkg_retrieve.total_size = 0;
		event.pkg_retrieve.num = 0;

		/* sum up the number of packages to download and its total size */
		for(i = files; i; i = i.next) {
			AlpmPkg spkg = cast(AlpmPkg)i.data;
			event.pkg_retrieve.total_size += spkg.download_size;
			event.pkg_retrieve.num++;
		}

		EVENT(handle, &event);
		for(i = files; i; i = i.next) {
			AlpmPkg pkg = cast(AlpmPkg)i.data;
			int siglevel = alpm_db_get_siglevel(pkg.getDB());
			dload_payload* payload = null;

			CALLOC(payload, 1, typeof(*payload).sizeof);
			STRDUP(payload.remote_name, cast(char*)pkg.filename);
			STRDUP(payload.filepath, cast(char*)pkg.filename);
			payload.destfile_name = _alpm_get_fullpath(temporary_cachedir, payload.remote_name, cast(char*)"");
			payload.tempfile_name = _alpm_get_fullpath(temporary_cachedir, payload.remote_name, cast(char*)".part");
			if(!payload.destfile_name || !payload.tempfile_name) {
				_alpm_dload_payload_reset(payload);
				FREE(payload);
				GOTO_ERR(handle, ALPM_ERR_MEMORY, "finish");
			}
			payload.max_size = pkg.size;
			payload.cache_servers = pkg.origin_data.db.cache_servers;
			payload.servers = pkg.origin_data.db.servers;
			payload.handle = handle;
			payload.allow_resume = 1;
			payload.download_signature = (siglevel & ALPM_SIG_PACKAGE);
			payload.signature_optional = (siglevel & ALPM_SIG_PACKAGE_OPTIONAL);

			payloads = alpm_list_add(payloads, payload);
		}

		ret = _alpm_download(handle, payloads, cachedir, temporary_cachedir);
		if(ret == -1) {
			event.type = ALPM_EVENT_PKG_RETRIEVE_FAILED;
			EVENT(handle, &event);
			_alpm_log(handle, ALPM_LOG_WARNING, "failed to retrieve some files\n");
			goto finish;
		}
		event.type = ALPM_EVENT_PKG_RETRIEVE_DONE;
		EVENT(handle, &event);
	}

finish:
	if(payloads) {
		alpm_list_free_inner(payloads, cast(alpm_list_fn_free)&_alpm_dload_payload_reset);
		FREELIST(payloads);
	}

	if(files) {
		alpm_list_free(files);
	}

	for(i = handle.trans.add; i; i = i.next) {
		AlpmPkg pkg = cast(AlpmPkg)i.data;
		pkg.infolevel &= ~INFRQ_DSIZE;
		pkg.download_size = 0;
	}
	FREE(temporary_cachedir);

	return ret;
}

version (HAVE_LIBGPGME) {

private int key_cmp( void*k1,  void*k2) {
	 keyinfo_t* key1 = k1;
	  char*key2 = k2;

	return strcmp(key1.keyid, key2);
}

private int check_keyring(AlpmHandle handle)
{
	size_t current = 0, numtargs = void;
	alpm_list_t* i = void, errors = null;
	alpm_event_t event = void;
	keyinfo_t* keyinfo = void;

	event.type = ALPM_EVENT_KEYRING_START;
	EVENT(handle, &event);

	numtargs = alpm_list_count(handle.trans.add);

	for(i = handle.trans.add; i; i = i.next, current++) {
		AlpmPkg pkg = i.data;
		int level = void;

		int percent = (current * 100) / numtargs;
		PROGRESS(handle, ALPM_PROGRESS_KEYRING_START, "", percent,
				numtargs, current);

		if(pkg.origin == ALPM_PKG_FROM_FILE) {
			continue; /* pkg_load() has been already called, this package is valid */
		}

		level = alpm_db_get_siglevel(pkg.getDB());
		if((level & ALPM_SIG_PACKAGE)) {
			ubyte* sig = null;
			size_t sig_len = void;
			int ret = alpm_pkg_get_sig(pkg, &sig, &sig_len);
			if(ret == 0) {
				alpm_list_t* keys = null;
				if(alpm_extract_keyid(handle, pkg.name, sig,
							sig_len, &keys) == 0) {
					alpm_list_t* k = void;
					for(k = keys; k; k = k.next) {
						char* key = k.data;
						_alpm_log(handle, ALPM_LOG_DEBUG, "found signature key: %s\n", key);
						if(!alpm_list_find(errors, key, &key_cmp) &&
								_alpm_key_in_keychain(handle, key) == 0) {
							keyinfo = cast(keyinfo_t*) malloc(keyinfo_t.sizeof);
							if(!keyinfo) {
								break;
							}
							keyinfo.uid = strdup(pkg.packager);
							keyinfo.keyid = strdup(key);
							errors = alpm_list_add(errors, keyinfo);
						}
					}
					FREELIST(keys);
				}
			}
			free(sig);
		}
	}

	PROGRESS(handle, ALPM_PROGRESS_KEYRING_START, "", 100,
			numtargs, current);
	event.type = ALPM_EVENT_KEYRING_DONE;
	EVENT(handle, &event);

	if(errors) {
		event.type = ALPM_EVENT_KEY_DOWNLOAD_START;
		EVENT(handle, &event);
		int fail = 0;
		alpm_list_t* k = void;
		for(k = errors; k; k = k.next) {
			keyinfo = k.data;
			if(_alpm_key_import(handle, keyinfo.uid, keyinfo.keyid) == -1) {
				fail = 1;
			}
			free(keyinfo.uid);
			free(keyinfo.keyid);
			free(keyinfo);
		}
		alpm_list_free(errors);
		event.type = ALPM_EVENT_KEY_DOWNLOAD_DONE;
		EVENT(handle, &event);
		if(fail) {
			_alpm_log(handle, ALPM_LOG_ERROR, "required key missing from keyring\n");
			return -1;
		}
	}

	return 0;
}
} /* HAVE_LIBGPGME */

private int check_validity(AlpmHandle handle, size_t total, ulong total_bytes)
{
	struct validity {
		AlpmPkg pkg = void;
		char* path = void;
		alpm_siglist_t* siglist = void;
		int siglevel = void;
		int validation = void;
		alpm_errno_t error = void;
	};
	size_t current = 0;
	ulong current_bytes = 0;
	alpm_list_t* i = void, errors = null;
	alpm_event_t event = void;

	/* Check integrity of packages */
	event.type = ALPM_EVENT_INTEGRITY_START;
	EVENT(handle, &event);

	for(i = handle.trans.add; i; i = i.next, current++) {
		validity v = { cast(AlpmPkg)i.data, null, null, 0, 0, cast(alpm_errno_t)0 };
		int percent = cast(int)((cast(double)current_bytes / total_bytes) * 100);

		PROGRESS(handle, ALPM_PROGRESS_INTEGRITY_START, "", percent,
				total, current);
		if(v.pkg.origin == ALPM_PKG_FROM_FILE) {
			continue; /* pkg_load() has been already called, this package is valid */
		}

		current_bytes += v.pkg.size;
		v.path = _alpm_filecache_find(handle, cast(char*)v.pkg.filename);

		if(!v.path) {
			_alpm_log(handle, ALPM_LOG_ERROR,
					("%s: could not find package in cache\n"), v.pkg.name);
			RET_ERR(handle, ALPM_ERR_PKG_NOT_FOUND, -1);
		}

		v.siglevel = alpm_db_get_siglevel(v.pkg.getDB());

		if(_alpm_pkg_validate_internal(handle, v.path, v.pkg,
					v.siglevel, &v.siglist, &v.validation) == -1) {
			validity* invalid = void;
			v.error = handle.pm_errno;
			MALLOC(invalid, validity.sizeof);
			memcpy(invalid, &v, validity.sizeof);
			errors = alpm_list_add(errors, invalid);
		} else {
			libalpmd.signing.alpm_siglist_cleanup(v.siglist);
			free(v.siglist);
			free(v.path);
			v.pkg.validation = v.validation;
		}
	}

	PROGRESS(handle, ALPM_PROGRESS_INTEGRITY_START, "", 100,
			total, current);
	event.type = ALPM_EVENT_INTEGRITY_DONE;
	EVENT(handle, &event);

	if(errors) {
		for(i = errors; i; i = i.next) {
			validity* v = cast(validity*)i.data;
			switch(v.error) {
				case ALPM_ERR_PKG_MISSING_SIG:
					_alpm_log(handle, ALPM_LOG_ERROR,
							("%s: missing required signature\n"), v.pkg.name);
					break;
				case ALPM_ERR_PKG_INVALID_SIG:
					_alpm_process_siglist(handle, cast(char*)v.pkg.name, v.siglist,
							v.siglevel & ALPM_SIG_PACKAGE_OPTIONAL,
							v.siglevel & ALPM_SIG_PACKAGE_MARGINAL_OK,
							v.siglevel & ALPM_SIG_PACKAGE_UNKNOWN_OK);
					// __attribute_((fallthrough)){}
					goto case;
				case ALPM_ERR_PKG_INVALID_CHECKSUM:
					prompt_to_delete(handle, v.path, v.error);
					break;
				case ALPM_ERR_PKG_NOT_FOUND:
				case ALPM_ERR_BADPERMS:
				case ALPM_ERR_PKG_OPEN:
					_alpm_log(handle, ALPM_LOG_ERROR, "failed to read file %s: %s\n", v.path, alpm_strerror(v.error));
					break;
				default:
					/* ignore */
					break;
			}
			libalpmd.signing.alpm_siglist_cleanup(v.siglist);
			free(v.siglist);
			free(v.path);
			free(v);
		}
		alpm_list_free(errors);

		if((cast(AlpmHandle)handle).pm_errno == ALPM_ERR_OK) {
			RET_ERR(handle, ALPM_ERR_PKG_INVALID, -1);
		}
		return -1;
	}

	return 0;
}

private int dep_not_equal( AlpmDepend left,  AlpmDepend right)
{
	return left.name_hash != right.name_hash
		|| strcmp(left.name, right.name) != 0
		|| left.mod != right.mod
		|| (left.version_ == null) != (right.version_ == null)
		|| ((left.version_ && right.version_) && strcmp(left.version_, right.version_) != 0);
}

private int check_pkg_field_matches_db(AlpmHandle handle,   char*field, alpm_list_t* left, alpm_list_t* right, alpm_list_fn_cmp cmp)
{
	switch(alpm_list_cmp_unsorted(left, right, cmp)) {
		case 0:
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"internal package %s mismatch\n", field);
			return 1;
		case 1:
			return 0;
		default:
			RET_ERR(handle, ALPM_ERR_MEMORY, -1);
	}
}

private int check_pkg_field_matches_db_n(List)(AlpmHandle handle,   char*field, List left, List right, alpm_list_fn_cmp cmp)
{
	switch(alpmListCmpUnsorted(left, right, cmp)) {
		case 0:
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"internal package %s mismatch\n", field);
			return 1;
		case 1:
			return 0;
		default:
			RET_ERR(handle, ALPM_ERR_MEMORY, -1);
	}
}

private int check_pkg_matches_db(AlpmPkg spkg, AlpmPkg pkgfile)
{
	AlpmHandle handle = spkg.handle;
	int error = 0;

enum string CHECK_FIELD_N(string STR, string FIELD, string CMP) = `do { 
	int ok = check_pkg_field_matches_db_n(handle, cast(char*)` ~ STR ~ `, spkg.` ~ FIELD ~ `, pkgfile.` ~ FIELD ~ `, cast(alpm_list_fn_cmp)&` ~ CMP ~ `); 
	if(ok == -1) { 
		return 1; 
	} else if(ok != 0) { 
		error = 1; 
	} 
} while(0);`;

enum string CHECK_FIELD(string STR, string FIELD, string CMP) = `do { 
	int ok = check_pkg_field_matches_db(handle, cast(char*)` ~ STR ~ `, spkg.` ~ FIELD ~ `, pkgfile.` ~ FIELD ~ `, cast(alpm_list_fn_cmp)&` ~ CMP ~ `); 
	if(ok == -1) { 
		return 1; 
	} else if(ok != 0) { 
		error = 1; 
	} 
} while(0);`;

	if(spkg.name != pkgfile.name) {
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"internal package name mismatch, expected: '%s', actual: '%s'\n",
				spkg.name, pkgfile.name);
		error = 1;
	}
	if(strcmp(cast(char*)spkg.version_, cast(char*)pkgfile.version_) != 0) {
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"internal package version mismatch, expected: '%s', actual: '%s'\n",
				spkg.version_, pkgfile.version_);
		error = 1;
	}
	if(spkg.isize != pkgfile.isize) {
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"internal package install size mismatch, expected: '%ld', actual: '%ld'\n",
				spkg.isize, pkgfile.isize);
		error = 1;
	}

	mixin(CHECK_FIELD_N!(`"depends"`, `depends`, `dep_not_equal`));
	mixin(CHECK_FIELD_N!(`"conflicts"`, `conflicts`, `dep_not_equal`));
	mixin(CHECK_FIELD_N!(`"replaces"`, `replaces`, `dep_not_equal`));
	mixin(CHECK_FIELD_N!(`"provides"`, `provides`, `dep_not_equal`));
	mixin(CHECK_FIELD_N!(`"groups"`, `groups`, `strcmp`));

	return error;
}


private int load_packages(AlpmHandle handle, alpm_list_t** data, size_t total, size_t total_bytes)
{
	size_t current = 0, current_bytes = 0;
	int errors = 0;
	alpm_list_t* i = void, delete_list = null;
	alpm_event_t event = void;

	/* load packages from disk now that they are known-valid */
	event.type = ALPM_EVENT_LOAD_START;
	EVENT(handle, &event);

	for(i = handle.trans.add; i; i = i.next, current++) {
		int error = 0;
		AlpmPkg spkg = cast(AlpmPkg)i.data;
		char* filepath = void;
		int percent = cast(int)((cast(double)current_bytes / total_bytes) * 100);

		PROGRESS(handle, ALPM_PROGRESS_LOAD_START, "", percent,
				total, current);
		if(spkg.origin == ALPM_PKG_FROM_FILE) {
			continue; /* pkg_load() has been already called, this package is valid */
		}

		current_bytes += spkg.size;
		filepath = _alpm_filecache_find(handle, cast(char*)spkg.filename);

		if(!filepath) {
			FREELIST(delete_list);
			_alpm_log(handle, ALPM_LOG_ERROR,
					("%s: could not find package in cache\n"), spkg.name);
			RET_ERR(handle, ALPM_ERR_PKG_NOT_FOUND, -1);
		}

		/* load the package file and replace pkgcache entry with it in the target list */
		/* TODO: alpm_pkg_get_db() will not work on this target anymore */
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"replacing pkgcache entry with package file for target %s\n",
				spkg.name);
		AlpmPkg pkgfile = _alpm_pkg_load_internal(handle, filepath, 1);
		if(!pkgfile) {
			_alpm_log(handle, ALPM_LOG_DEBUG, "failed to load pkgfile internal\n");
			error = 1;
		} else {
			error |= check_pkg_matches_db(spkg, pkgfile);
		}
		if(error != 0) {
			errors++;
			*data = alpm_list_add(*data, cast(char*)spkg.filename.dup);
			delete_list = alpm_list_add(delete_list, filepath);
			_alpm_pkg_free(pkgfile);
			continue;
		}
		free(filepath);
		/* copy over the install reason */
		pkgfile.reason = spkg.reason;
		/* copy over validation method */
		pkgfile.validation = spkg.validation;
		/* transfer oldpkg */
		pkgfile.oldpkg = spkg.oldpkg;
		spkg.oldpkg = null;
		i.data = cast(void*)pkgfile;
		/* spkg has been removed from the target list, so we can free the
		 * sync-specific fields */
		_alpm_pkg_free_trans(spkg);
	}

	PROGRESS(handle, ALPM_PROGRESS_LOAD_START, "", 100,
			total, current);
	event.type = ALPM_EVENT_LOAD_DONE;
	EVENT(handle, &event);

	if(errors) {
		for(i = delete_list; i; i = i.next) {
			prompt_to_delete(handle, cast(char*)i.data, ALPM_ERR_PKG_INVALID);
		}
		FREELIST(delete_list);

		if((cast(AlpmHandle)handle).pm_errno == ALPM_ERR_OK) {
			RET_ERR(handle, ALPM_ERR_PKG_INVALID, -1);
		}
		return -1;
	}

	return 0;
}

int _alpm_sync_load(AlpmHandle handle, alpm_list_t** data)
{
	alpm_list_t* i = void;
	size_t total = 0;
	ulong total_bytes = 0;
	AlpmTrans trans = handle.trans;

	if(download_files(handle) == -1) {
		return -1;
	}

version (HAVE_LIBGPGME) {
	/* make sure all required signatures are in keyring */
	if(check_keyring(handle)) {
		return -1;
	}
}

	/* get the total size of all packages so we can adjust the progress bar more
	 * realistically if there are small and huge packages involved */
	for(i = trans.add; i; i = i.next) {
		AlpmPkg spkg = cast(AlpmPkg)i.data;
		if(spkg.origin != ALPM_PKG_FROM_FILE) {
			total_bytes += spkg.size;
		}
		total++;
	}
	/* this can only happen maliciously */
	total_bytes = total_bytes ? total_bytes : 1;

	if(check_validity(handle, total, total_bytes) != 0) {
		return -1;
	}

	if(trans.flags & ALPM_TRANS_FLAG_DOWNLOADONLY) {
		return 0;
	}

	if(load_packages(handle, data, total, total_bytes)) {
		return -1;
	}

	return 0;
}

int _alpm_sync_check(AlpmHandle handle, alpm_list_t** data)
{
	AlpmTrans trans = handle.trans;
	alpm_event_t event = void;

	/* fileconflict check */
	if(!(trans.flags & ALPM_TRANS_FLAG_DBONLY)) {
		event.type = ALPM_EVENT_FILECONFLICTS_START;
		EVENT(handle, &event);

		_alpm_log(handle, ALPM_LOG_DEBUG, "looking for file conflicts\n");
		alpm_list_t* conflict = _alpm_db_find_fileconflicts(handle,
				trans.add, trans.remove);
		if(conflict) {
			if(data) {
				*data = conflict;
			} else {
				alpm_list_free_inner(conflict,
						cast(alpm_list_fn_free)&alpm_fileconflict_free);
				alpm_list_free(conflict);
			}
			RET_ERR(handle, ALPM_ERR_FILE_CONFLICTS, -1);
		}

		event.type = ALPM_EVENT_FILECONFLICTS_DONE;
		EVENT(handle, &event);
	}

	/* check available disk space */
	if(handle.checkspace && !(trans.flags & ALPM_TRANS_FLAG_DBONLY)) {
		event.type = ALPM_EVENT_DISKSPACE_START;
		EVENT(handle, &event);

		_alpm_log(handle, ALPM_LOG_DEBUG, "checking available disk space\n");
		if(_alpm_check_diskspace(handle) == -1) {
			_alpm_log(handle, ALPM_LOG_ERROR, "not enough free disk space\n");
			return -1;
		}

		event.type = ALPM_EVENT_DISKSPACE_DONE;
		EVENT(handle, &event);
	}

	return 0;
}

int _alpm_sync_commit(AlpmHandle handle)
{
	AlpmTrans trans = handle.trans;

	/* remove conflicting and to-be-replaced packages */
	if(trans.remove) {
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"removing conflicting and to-be-replaced packages\n");
		/* we want the frontend to be aware of commit details */
		if(_alpm_remove_packages(handle, 0) == -1) {
			_alpm_log(handle, ALPM_LOG_ERROR,
					("could not commit removal transaction\n"));
			return -1;
		}
	}

	/* install targets */
	_alpm_log(handle, ALPM_LOG_DEBUG, "installing packages\n");
	if(_alpm_upgrade_packages(handle) == -1) {
		_alpm_log(handle, ALPM_LOG_ERROR, "could not commit transaction\n");
		return -1;
	}

	return 0;
}
