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

import std.array;
import std.algorithm;
import std.range;
import std.conv;
import std.string;
/* libalpm */
import libalpmd.sync;
import libalpmd.alpm_list;
import libalpmd.alpm_list.alpm_list_new;
import libalpmd.log;
import libalpmd.pkg;
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
// import libalpmd.be_package;
import libalpmd.group;
import libalpmd.deps;
import libalpmd.error;
import libalpmd.question;
import libalpmd.event;
import libalpmd.file;




struct KeyInfo {
       char* uid;
       char* keyid;
}

alias KeysInfo = AlpmList!(KeyInfo*); 

AlpmPkg alpm_sync_get_new_version(AlpmPkg pkg, AlpmDBs dbs_sync)
{
	AlpmPkg spkg = null;

	//ASSERT(pkg != null);
	pkg.getHandle().pm_errno = ALPM_ERR_OK;

	foreach(db; dbs_sync[]) {
		// AlpmDB db = cast(AlpmDB)i.data;
		spkg = db.getPkgFromCache(cast(char*)pkg.getName());

		if(spkg is null)
			break;
	}

	if(spkg is null) {
		_alpm_log(pkg.getHandle(), ALPM_LOG_DEBUG, "'%s' not found in sync db => no upgrade\n",
				pkg.getName());
		return null;
	}

	/* compare versions and see if spkg is an upgrade */
	if(spkg.compareVersions(pkg) > 0) {
		_alpm_log(pkg.getHandle(), ALPM_LOG_DEBUG, "new version of '%s' found (%s => %s)\n",
					pkg.getName(), pkg.getVersion(), spkg.getVersion());
		return spkg;
	}
	/* spkg is not an upgrade */
	return null;
}

private int check_literal(AlpmHandle handle, AlpmPkg lpkg, AlpmPkg spkg, int enable_downgrade)
{
	/* 1. literal was found in sdb */
	int cmp = spkg.compareVersions(lpkg);
	if(cmp > 0) {
		logger.tracef("new version of '%s' found (%s => %s)\n",
				lpkg.getName(), lpkg.getVersion(), spkg.getVersion());
		/* check IgnorePkg/IgnoreGroup */
		if(alpm_pkg_should_ignore(handle, spkg)
				|| alpm_pkg_should_ignore(handle, lpkg)) {
			_alpm_log(handle, ALPM_LOG_WARNING, "%s: ignoring package upgrade (%s => %s)\n",
					lpkg.getName(), lpkg.getVersion(), spkg.getVersion());
		} else {
			logger.tracef("adding package %s-%s to the transaction targets\n",
					spkg.getName(), spkg.getVersion());
			return 1;
		}
	} else if(cmp < 0) {
		if(enable_downgrade) {
			/* check IgnorePkg/IgnoreGroup */
			if(alpm_pkg_should_ignore(handle, spkg)
					|| alpm_pkg_should_ignore(handle, lpkg)) {
				_alpm_log(handle, ALPM_LOG_WARNING, "%s: ignoring package downgrade (%s => %s)\n",
						lpkg.getName(), lpkg.getVersion(), spkg.getVersion());
			} else {
				_alpm_log(handle, ALPM_LOG_WARNING, "%s: downgrading from version %s to version %s\n",
						lpkg.getName(), lpkg.getVersion(), spkg.getVersion());
				return 1;
			}
		} else {
			AlpmDB sdb = spkg.getOriginDB();
			_alpm_log(handle, ALPM_LOG_WARNING, "%s: local (%s) is newer than %s (%s)\n",
					lpkg.getName(), lpkg.getVersion(), sdb.treename, spkg.getVersion());
		}
	}
	return 0;
}

private AlpmPkgs check_replacers(AlpmHandle handle, AlpmPkg lpkg, AlpmDB sdb)
{
	/* 2. search for replacers in sdb */
	AlpmPkgs replacers;
	_alpm_log(handle, ALPM_LOG_DEBUG,
			"searching for replacements for %s in %s\n",
			lpkg.getName(), sdb.treename);
	foreach(spkg; (sdb.getPkgCacheList())[]) {
		int found = 0;
		foreach(l; spkg.getReplaces()[]) {
			/* we only want to consider literal matches at this point. */
			if(_alpm_depcmp_literal(lpkg, l)) {
				found = 1;
				break;
			}
		}
		if(found) {
			auto question = new AlpmQuestionReplace(lpkg, spkg, sdb);
			AlpmPkg tpkg = void;
			/* check IgnorePkg/IgnoreGroup */
			if(alpm_pkg_should_ignore(handle, spkg)
					|| alpm_pkg_should_ignore(handle, lpkg)) {
				_alpm_log(handle, ALPM_LOG_WARNING,
						("ignoring package replacement (%s-%s => %s-%s)\n"),
						lpkg.getName(), lpkg.getVersion(), spkg.getName(), spkg.getVersion());
				continue;
			}

			QUESTION(handle, question);
			if(!question.getAnswer()) {
				continue;
			}

			/* If spkg is already in the target list, we append lpkg to spkg's
			 * removes list */
			tpkg = alpm_pkg_find_n(handle.trans.add, spkg.getName());
			if(tpkg) {
				/* sanity check, multiple repos can contain spkg->getName() */
				if(tpkg.getOriginDB() != sdb) {
					_alpm_log(handle, ALPM_LOG_WARNING, "cannot replace %s by %s\n",
							lpkg.getName(), spkg.getName());
					continue;
				}
				logger.tracef("appending %s to the removes list of %s\n",
						lpkg.getName(), tpkg.getName());
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
						spkg.getName(), spkg.getVersion());
				replacers.insertBack(spkg);
			}
		}
	}
	return replacers;
}

int  alpm_sync_sysupgrade(AlpmHandle handle, int enable_downgrade)
{
	AlpmTrans trans = void;

	trans = handle.trans;
	//ASSERT(trans != null);
	ASSERT(trans.state == AlpmTransState.Initialized);

	logger.tracef("checking for package upgrades\n");
	foreach(lpkg; (handle.getDBLocal().getPkgCacheList())[]) {
		// AlpmPkg lpkg = cast(AlpmPkg)i.data;

		if(alpm_pkg_find_n(trans.remove, lpkg.getName())) {
			logger.tracef("%s is marked for removal -- skipping\n", lpkg.getName());
			continue;
		}

		if(alpm_pkg_find_n(trans.add, lpkg.getName())) {
			logger.tracef("%s is already in the target list -- skipping\n", lpkg.getName());
			continue;
		}

		/* Search for replacers then literal (if no replacer) in each sync database. */
		foreach(j; handle.getDBsSync[]) {
			AlpmDB sdb = cast(AlpmDB)j;

			if(!(sdb.usage & AlpmDBUsage.Upgrade)) {
				continue;
			}

			/* Check sdb */
			AlpmPkgs replacers = check_replacers(handle, lpkg, sdb);
			if(!replacers.empty()) {
				trans.add.insertBack(replacers[]);
				/* jump to next local package */
				break;
			} else {
				AlpmPkg spkg = sdb.getPkgFromCache(cast(char*)lpkg.getName());
				if(spkg) {
					if(check_literal(handle, lpkg, spkg, enable_downgrade)) {
						trans.add.insertBack(spkg);
					}
					/* jump to next local package */
					break;
				}
			}
		}
	}

	return 0;
}

AlpmPkgs findPkgInGroupAcrossDB(AlpmDBs dbs, char*name) {
	AlpmPkgs pkgs = AlpmPkgs();
	AlpmPkgs ignorelist = AlpmPkgs();

	foreach(db; dbs[]) {
		AlpmGroup grp = db.getGroup(name);

		if(!grp) {
			continue;
		}

		foreach(pkg; grp.packages[]) {
			AlpmTrans trans = db.handle.trans;

			if(alpm_pkg_find_n(ignorelist, pkg.getName())) {
				continue;
			}
			if(trans !is null && trans.flags & ALPM_TRANS_FLAG_NEEDED) {
				AlpmPkg local = db.handle.getDBLocal().getPkgFromCache(cast(char*)pkg.getName());
				if(local && pkg.compareVersions(local) == 0) {
					/* with the NEEDED flag, packages up to date are not reinstalled */
					_alpm_log(db.handle, ALPM_LOG_WARNING, "%s-%s is up to date -- skipping\n",
							local.getName(), local.getVersion());
					ignorelist.insertBack(pkg);
					continue;
				}
			}
			if(alpm_pkg_should_ignore(db.handle, pkg)) {
				auto question = new AlpmQuestionInstallIgnorePkg(pkg);
				ignorelist.insertBack(pkg);
				QUESTION(db.handle, question);
				if(!question.getAnswer()) {
					continue;
				}
			}
			if(!alpm_pkg_find_n(pkgs, pkg.getName())) {
				pkgs.insertBack(pkg);
			}
		}
	}
	ignorelist.clear();
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
	AlpmHandle handle = newpkg.getHandle();
	int ret = 0;
	size_t fnamepartlen = 0;

	if(newpkg.origin != AlpmPkgFrom.SyncDB) {
		newpkg.infolevel |= AlpmDBInfRq.DSize;
		newpkg.download_size = 0;
		return 0;
	}

	//ASSERT(newpkg.filename != null);
	fname = cast(char*)newpkg.getFilename();
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
			logger.tracef("using (package - .part) size\n");
			size = newpkg.size - st.st_size;
			size = size < 0 ? 0 : size;
		}

		/* tell the caller that we have a partial */
		ret = 1;
	} else {
		size = newpkg.size;
	}

finish:
	logger.tracef("setting download size %jd for pkg %s\n",
			cast(intmax_t)size, newpkg.getName());

	newpkg.infolevel |= AlpmDBInfRq.DSize;
	newpkg.download_size = size;

	FREE(fpath);
	FREE(fnamepart);

	return ret;
}

int _alpm_sync_prepare(AlpmHandle handle, ref RefTransData data)
{
	AlpmConflicts conflicts;
	AlpmDepMissings missings;
	AlpmPkgs unresolvable;
	int from_sync = 0;
	int ret = 0;
	AlpmTrans trans = handle.trans;
	AlpmEvent event = void;

	// if(data) {
		// *data = null;
	// }

	foreach(spkg; trans.add[]) {
		if (spkg.origin == AlpmPkgFrom.SyncDB){
			from_sync = 1;
			break;
		}
	}

	/* ensure all sync database are valid if we will be using them */
	foreach(db; handle.getDBsSync()[]) {
		if(db.status & AlpmDBStatus.Invalid) {
			RET_ERR(handle, ALPM_ERR_DB_INVALID, -1);
		}
		/* missing databases are not allowed if we have sync targets */
		if(from_sync && db.status & AlpmDBStatus.Missing) {
			RET_ERR(handle, ALPM_ERR_DB_NOT_FOUND, -1);
		}
	}

	if(!(trans.flags & ALPM_TRANS_FLAG_NODEPS)) {
		AlpmPkgs resolved;
		auto remove = trans.remove;
		AlpmPkgs localpkgs;

		/* Build up list by repeatedly resolving each transaction package */
		/* Resolve targets dependencies */
		event = new AlpmEventResolveDeps(AlpmEventDefStatus.Start);
		EVENT(handle, event);
		logger.tracef("resolving target's dependencies\n");

		/* build remove list for resolvedeps */
		foreach(spkg; trans.add[]) {
			auto range = spkg.removes[];
			for(auto pkg = range.front; !range.empty; range.popFront) {
				remove.insertBack(pkg);
			}
		}

		/* Compute the fake local database for resolvedeps (partial fix for the
		 * phonon/qt issue) */
		localpkgs = alpmListDiff(handle.getDBLocal().getPkgCacheList(),
				trans.add);

		/* Resolve packages in the transaction one at a time, in addition
		   building up a list of packages which could not be resolved. */
		foreach(pkg; trans.add[]) {
			if(_alpm_resolvedeps(handle, localpkgs, pkg, trans.add,
						resolved, remove, data.missings) == -1) {
				unresolvable.insertBack(pkg);
			}
			/* Else, [resolved] now additionally contains [pkg] and all of its
			   dependencies not already on the list */
		}
		localpkgs.clear();

		/* If there were unresolvable top-level packages, prompt the user to
		   see if they'd like to ignore them rather than failing the sync */
		if(unresolvable[].count) {
			auto question = new AlpmQuestionRemovePkg(unresolvable);
			QUESTION(handle, question);

			if(question.getAnswer()) {
				/* User wants to remove the unresolvable packages from the
				   transaction. The packages will be removed from the actual
				   transaction when the transaction packages are replaced with a
				   dependency-reordered list below */
				(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_OK;
				// if(data) {
					// alpm_list_free_inner(*data,
							// cast(alpm_list_fn_free)&alpm_depmissing_free);
					// alpm_list_free(*data);
					// *data = null;
					data.missings.clear();
				// }
			} else {
				/* pm_errno was set by resolvedeps, callback may have overwrote it */
				// alpm_list_free(resolved);
				resolved.clear();
				unresolvable.clear();
				ret = -1;
				GOTO_ERR(handle, ALPM_ERR_UNSATISFIED_DEPS, "cleanup");
			}
		}

		auto resRange = resolved[];

		/* Ensure two packages don't have the same filename */
		foreach(pkg1; resRange) {
			foreach(pkg2; resRange) {
				if(pkg1.getFilename() == pkg2.getFilename()) {
					ret = -1;
					(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_TRANS_DUP_FILENAME;
					_alpm_log(handle, ALPM_LOG_ERROR, "packages %s and %s have the same filename: %s\n",
						pkg1.getName(), pkg2.getName(), pkg1.getFilename());
				}
			}
		}

		if(ret != 0) {
			// alpm_list_free(resolved);
			resolved.clear();
			goto cleanup;
		}

		/* Set DEPEND reason for pulled packages */
		foreach(pkg; resolved[]) {
			if(!alpm_pkg_find_n(trans.add, pkg.getName())) {
				pkg.reason = ALPM_PKG_REASON_DEPEND;
			}
		}

		/* Unresolvable packages will be removed from the target list; set these
		 * aside in the transaction as a list we won't operate on. If we free them
		 * before the end of the transaction, we may kill pointers the frontend
		 * holds to package objects. */
		trans.unresolvable = unresolvable;

		trans.add = resolved.dup();

		event = new AlpmEventResolveDeps(AlpmEventDefStatus.Done);
		EVENT(handle, event);
	}

	if(!(trans.flags & ALPM_TRANS_FLAG_NOCONFLICTS)) {
		/* check for inter-conflicts and whatnot */
		event = new AlpmEventInterConflicts(AlpmEventDefStatus.Start);
		EVENT(handle, event);

		logger.tracef("looking for conflicts\n");

		/* 1. check for conflicts in the target list */
		logger.tracef("check targets vs targets\n");
		conflicts = _alpm_innerconflicts(handle, trans.add);

		foreach(conflict; conflicts[]) {
			string name1 = conflict.package1.getName();
			string name2 = conflict.package2.getName();
			AlpmPkg rsync = void, sync = void, sync1 = void, sync2 = void;

			/* have we already removed one of the conflicting targets? */
			sync1 = alpm_pkg_find_n(trans.add, name1);
			sync2 = alpm_pkg_find_n(trans.add, name2);
			if(!sync1 || !sync2) {
				continue;
			}

			logger.tracef("conflicting packages in the sync list: '%s' <-> '%s'\n",
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
				// if(data) {
					AlpmConflict newconflict = conflict.dup();
					if(newconflict) {
						data.conflicts.insertBack(newconflict);
					}
				// }
				// alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_conflict_free);
				// alpm_list_free(deps);
				// alpm_dep_free(cast(void*)dep1);
				// alpm_dep_free(cast(void*)dep2);
				dep1 = null;
				dep2 = null;
				goto cleanup;
			}
			// alpm_dep_free(cast(void*)dep1);
			// alpm_dep_free(cast(void*)dep2);
			dep1 = null;
			dep2 = null;
// c = 

			/* Prints warning */
			_alpm_log(handle, ALPM_LOG_WARNING,
					("removing '%s-%s' from target list because it conflicts with '%s-%s'\n"),
					rsync.getName(), rsync.getVersion(), sync.getName(), sync.getVersion());
			trans.add.linearRemoveElement(rsync);
			/* rsync is not a transaction target anymore */
			trans.unresolvable.insertBack(rsync);
		}

		// alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_conflict_free);
		// alpm_list_free(deps);
		// deps = null;
		conflicts.clear();

		/* 2. we check for target vs db conflicts (and resolve)*/
		logger.tracef("check targets vs db and db vs targets\n");
		conflicts = handle.getDBLocal.outerConflicts(trans.add);

		// for(auto i = deps; i; i = i.next) {
		foreach(conflict; conflicts[]) {
			// AlpmConflict conflict = cast(AlpmConflict)i.data;
			string name1 = conflict.package1.getName();
			string name2 = conflict.package2.getName();
			auto question = new AlpmQuestionConflict(conflict);
			int found = 0;

			/* if name2 (the local package) is not elected for removal,
			   we ask the user */
			if(alpm_pkg_find_n(trans.remove, name2)) {
				found = 1;
			}
			foreach(spkg; trans.add[]) {
				if(alpm_pkg_find_n(spkg.removes, name2)) {
				// if(spkg.removes[].canFind)
					found = 1;
				}
			}
			if(found) {
				continue;
			}

			logger.tracef("package '%s-%s' conflicts with '%s-%s'\n",
					name1, conflict.package1.getVersion(), name2,conflict.package2.getVersion());

			QUESTION(handle, question);
			if(question.getAnswer()) {
				/* append to the removes list */
				AlpmPkg sync = alpm_pkg_find_n(trans.add, name1);
				AlpmPkg local = handle.getDBLocal().getPkgFromCache(cast(char*)name2);
				logger.tracef("electing '%s' for removal\n", name2);
				sync.removes.insertFront(local);
			} else { /* abort */
				_alpm_log(handle, ALPM_LOG_ERROR, "unresolvable package conflicts detected\n");
				(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_CONFLICTING_DEPS;
				ret = -1;
				// if(data) {
					AlpmConflict newconflict = conflict.dup();
					// if(newconflict) {
						data.conflicts.insertBack(newconflict);
					// }
				// }
				// alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_conflict_free);
				// alpm_list_free(deps);
				goto cleanup;
			}
		}
		event = new AlpmEventInterConflicts(AlpmEventDefStatus.Done);
		EVENT(handle, event);
		// alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_conflict_free);
		// alpm_list_free(deps);
	}

	/* Build trans->remove list */
	foreach(spkg; trans.add[]) {
		foreach(rpkg; spkg.removes[]) {
			// AlpmPkg rpkg = cast(AlpmPkg)j.data;
			if(!alpm_pkg_find_n(trans.remove, rpkg.getName())) {
				AlpmPkg copy = void;
				logger.tracef("adding '%s' to remove list\n", rpkg.getName());
				if((copy = rpkg.dup) !is null) {
					return -1;
				}
				trans.remove.insertBack(copy);
			}
		}
	}

	if(!(trans.flags & ALPM_TRANS_FLAG_NODEPS)) {
		logger.tracef("checking dependencies\n");
		missings = alpm_checkdeps(handle, handle.getDBLocal().getPkgCacheList(),
				trans.remove, trans.add, 1);
		if(!missings.empty()) {
			(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_UNSATISFIED_DEPS;
			ret = -1;
			// if(data) {
				data.missings = missings;
			// } else {
				// alpm_list_free_inner(deps,
						// cast(alpm_list_fn_free)&alpm_depmissing_free);
				// alpm_list_free(deps);
			// }
			goto cleanup;
		}
	}
	foreach(spkg; trans.add) {
		/* update download size field */
		AlpmPkg lpkg = handle.getDBLocal.getPkg(spkg.getName());
		if(compute_download_size(spkg) < 0) {
			ret = -1;
			goto cleanup;
		}
		if(lpkg && (spkg.oldpkg = lpkg.dup) !is null) {
			// (spkg.oldpkg = lpkg.dup) !is null
			ret = -1;
			goto cleanup;
		}
	}

cleanup:
	return ret;
}

off_t  alpm_pkg_download_size(AlpmPkg newpkg)
{
	if(!(newpkg.infolevel & AlpmDBInfRq.DSize)) {
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
	auto question = new AlpmQuestionCorrupted(filepath.to!string, reason);
	QUESTION(handle, question);
	if(question.getAnswer()) {
		char* sig_filepath = void;

		unlink(filepath);

		sig_filepath = _alpm_sigpath(handle, filepath);
		unlink(sig_filepath);
		FREE(sig_filepath);
	}
	return question.getAnswer();
}

private int find_dl_candidates(AlpmHandle handle, ref AlpmPkgs files)
{
	foreach(spkg; handle.trans.add) {
		if(spkg.origin != AlpmPkgFrom.File) {
			AlpmDB repo = spkg.getOriginDB();
			bool need_download = void;
			int siglevel = spkg.getOriginDB().getSigLevel();

			if(!repo.servers.empty()) {
				(cast(AlpmHandle)handle).pm_errno = ALPM_ERR_SERVER_NONE;
				_alpm_log(handle, ALPM_LOG_ERROR, "%s: %s\n",
						alpm_strerror(handle.pm_errno), repo.treename);
				return -1;
			}

			//ASSERT(spkg.filename != null);

			need_download = spkg.download_size != 0 || !_alpm_filecache_exists(handle, cast(char*)spkg.getFilename());
			/* even if the package file in the cache we need to check for
			 * accompanion *.sig file as well.
			 * If *.sig is not cached then force download the package + its signature file.
			 */
			if(!need_download && (siglevel & AlpmSigLevel.Package)) {
				char* sig_filename = null;
				int len = cast(int)spkg.getFilename().length + 5;

				MALLOC(sig_filename, len);
				snprintf(sig_filename, len, "%s.sig", cast(char*)spkg.getFilename());

				need_download = !_alpm_filecache_exists(handle, sig_filename);

				FREE(sig_filename);
			}

			if(need_download) {
				files.insertBack(spkg);
			}
		}
	}

	return 0;
}

unittest {
	
}

private int download_files(AlpmHandle handle)
{
	  char*cachedir = void;
	char* temporary_cachedir = null;
	AlpmPkgs files;
	int ret = 0;
	AlpmEventPkgRetriev event = void;
	AlpmPayloads payloads;

	cachedir = _alpm_filecache_setup(handle);
	temporary_cachedir = _alpm_temporary_download_dir_setup(cachedir, cast(char*)handle.sandboxuser);
	if(temporary_cachedir == null) {
		ret = -1;
		goto finish;
	}
	handle.trans.state = AlpmTransState.Downloading;

	ret = find_dl_candidates(handle, files);
	if(ret != 0) {
		goto finish;
	}

	if(!files.empty()) {
		/* check for necessary disk space for download */
		if(handle.checkspace) {
			off_t* file_sizes = void;
			size_t idx = 0, num_files = void;

			logger.tracef("checking available disk space for download\n");

			num_files = files[].walkLength();
			// CALLOC(file_sizes, num_files, off_t.sizeof);

			foreach(pkg; files[]) {
				//  AlpmPkg pkg = cast(AlpmPkg)i.data;
				file_sizes[idx] = pkg.download_size;
				idx++;
			}

			ret = _alpm_check_downloadspace(handle, temporary_cachedir, num_files, file_sizes);
			free(file_sizes);

			if(ret != 0) {
				goto finish;
			}
		}

		event = new AlpmEventPkgRetriev(AlpmEventPkgRetrievStatus.Start);
		event.total_size = 0;
		event.num = 0;

		/* sum up the number of packages to download and its total size */
		// for(i = files; i; i = i.next) {
		foreach(spkg; files[]) {
			// AlpmPkg spkg = cast(AlpmPkg)i.data;
			event.total_size += spkg.download_size;
			event.num++;
		}

		EVENT(handle, event);
		// for(i = files; i; i = i.next) {
		foreach(pkg; files[]) {
			// AlpmPkg pkg = cast(AlpmPkg)i.data;
			int siglevel = pkg.getOriginDB().getSigLevel();
			DLoadPayload* payload = null;

			CALLOC(payload, 1, typeof(*payload).sizeof);
			STRDUP(payload.remote_name, cast(char*)pkg.getFilename());
			// STRDUP(payload.filepath, cast(char*)pkg.getFilename());
			payload.filepath = pkg.getFilename().dup;
			// payload.destfile_name = temporary_syncpath ~ payload.remote_name ~ "";
			// payload.tempfile_name = temporary_syncpath ~ payload.remote_name ~ ".part";
			payload.destfile_name = temporary_cachedir.to!string ~ payload.remote_name.to!string ~ "";
			payload.tempfile_name = temporary_cachedir.to!string ~ payload.remote_name.to!string ~".part";
			if(!payload.destfile_name || !payload.tempfile_name) {
				_alpm_dload_payload_reset(payload);
				FREE(payload);
				GOTO_ERR(handle, ALPM_ERR_MEMORY, "finish");
			}
			payload.max_size = pkg.size;
			payload.cache_servers = pkg.getOriginDB().cache_servers;
			payload.servers = pkg.getOriginDB().servers;
			payload.handle = handle;
			payload.allow_resume = 1;
			payload.download_signature = (siglevel & AlpmSigLevel.Package);
			payload.signature_optional = (siglevel & AlpmSigLevel.PackageOptional);

			payloads.insertBack(*payload);
		}

		ret = _alpm_download(handle, payloads, cachedir, temporary_cachedir);
		if(ret == -1) {
			event = new AlpmEventPkgRetriev(AlpmEventPkgRetrievStatus.Failed);
			EVENT(handle, event);
			_alpm_log(handle, ALPM_LOG_WARNING, "failed to retrieve some files\n");
			goto finish;
		}
		event = new AlpmEventPkgRetriev(AlpmEventPkgRetrievStatus.Done);
		EVENT(handle, event);
	}

finish:
	if(!payloads.empty()) {
		// alpm_list_free_inner(payloads, cast(alpm_list_fn_free)&_alpm_dload_payload_reset);
		// FREELIST(payloads);
	}

	if(!files.empty()) {
		// alpm_list_free(files);
		files.clear();
	}

	foreach(pkg; handle.trans.add) {
		pkg.infolevel &= ~AlpmDBInfRq.DSize;
		pkg.download_size = 0;
	}
	FREE(temporary_cachedir);

	return ret;
}

version (HAVE_LIBGPGME) {

private int key_cmp( void*k1,  void*k2) {
	 KeyInfo* key1 = k1;
	  char*key2 = k2;

	return strcmp(key1.keyid, key2);
}

private int check_keyring(AlpmHandle handle)
{
	size_t current = 0, numtargs = void;
	alpm_event_t event = void;

	KeyInfo* keyinfo = void;

	event.type = ALPM_EVENT_KEYRING_START;
	EVENT(handle, event);

	numtargs = alpm_list_count(handle.trans.add);

	foreach(pkg; handle.trans.add[]) {
		// AlpmPkg pkg = i.data;
		int level = void;

		int percent = (current * 100) / numtargs;
		PROGRESS(handle, ALPM_PROGRESS_KEYRING_START, "", percent,
				numtargs, current);

		if(pkg.origin == AlpmPkgFrom.File) {
			continue; /* pkg_load() has been already called, this package is valid */
		}

		level = alpm_db_get_siglevel(pkg.getDB());
		if((level & AlpmSigLevel.Package)) {
			ubyte* sig = null;
			size_t sig_len = void;
			int ret = alpm_pkg_get_sig(pkg, &sig, &sig_len);
			if(ret == 0) {
				AlpmStrings keys = null;
				if(alpm_extract_keyid(handle, pkg.name, sig,
							sig_len, keys) == 0) {
					foreach(key; keys[]) {
						logger.tracef("found signature key: %s\n", key);
						if(!errors.canFind(key) &&
								_alpm_key_in_keychain(handle, key) == 0) {
							keyinfo = new KeyInfo();
							if(!keyinfo) {
								break;
							}
							keyinfo.uid = strdup(pkg.packager);
							keyinfo.keyid = strdup(key);
							errors.insertBack(keyinfo);
						}
					}
					// FREELIST(keys);
				}
			}
			free(sig);
		}
		current++;
	}

	PROGRESS(handle, ALPM_PROGRESS_KEYRING_START, "", 100,
			numtargs, current);
	event.type = ALPM_EVENT_KEYRING_DONE;
	EVENT(handle, event);

	if(errors) {
		event.type = ALPM_EVENT_KEY_DOWNLOAD_START;
		EVENT(handle, event);
		int fail = 0;
		foreach(keyinfo; errors[]) {
			if(_alpm_key_import(handle, keyinfo.uid, keyinfo.keyid) == -1) {
				fail = 1;
			}
			free(keyinfo.uid);
			free(keyinfo.keyid);
			free(keyinfo);
		}
		alpm_list_free(errors);
		event.type = ALPM_EVENT_KEY_DOWNLOAD_DONE;
		EVENT(handle, event);
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
	alias AlpmValidities = AlpmList!validity;
	AlpmValidities errors;
	size_t current = 0;
	ulong current_bytes = 0;

	AlpmEvent event = void;

	/* Check integrity of packages */
	event = new AlpmEventIntegrity(AlpmEventDefStatus.Start);
	EVENT(handle, event);

	foreach(pkg; handle.trans.add) {
		validity v = { pkg, null, null, 0, 0, cast(alpm_errno_t)0 };
		int percent = cast(int)((cast(double)current_bytes / total_bytes) * 100);

		PROGRESS(handle, ALPM_PROGRESS_INTEGRITY_START, "", percent,
				total, current);
		if(v.pkg.origin == AlpmPkgFrom.File) {
			continue; /* pkg_load() has been already called, this package is valid */
		}

		current_bytes += v.pkg.size;
		v.path = _alpm_filecache_find(handle, cast(char*)v.pkg.getFilename());

		if(!v.path) {
			_alpm_log(handle, ALPM_LOG_ERROR,
					("%s: could not find package in cache\n"), v.pkg.getName());
			RET_ERR(handle, ALPM_ERR_PKG_NOT_FOUND, -1);
		}

		v.siglevel = v.pkg.getOriginDB().getSigLevel();

		if(_alpm_pkg_validate_internal(handle, v.path, v.pkg,
					v.siglevel, &v.siglist, &v.validation) == -1) {
			validity* invalid = void;
			v.error = handle.pm_errno;
			// MALLOC(invalid, validity.sizeof);
			invalid = new validity;

			memcpy(invalid, &v, validity.sizeof);
			errors.insertBack(*invalid);
		} else {
			libalpmd.signing.alpm_siglist_cleanup(v.siglist);
			free(v.siglist);
			free(v.path);
			v.pkg.validation = v.validation;
		}

		current++;
	}

	PROGRESS(handle, ALPM_PROGRESS_INTEGRITY_START, "", 100,
			total, current);
	event = new AlpmEventIntegrity(AlpmEventDefStatus.Done);
	EVENT(handle, event);

	if(!errors.empty) {
		foreach(v; errors[]) {
			// validity* v = cast(validity*)i.data;
			switch(v.error) {
				case ALPM_ERR_PKG_MISSING_SIG:
					_alpm_log(handle, ALPM_LOG_ERROR,
							("%s: missing required signature\n"), v.pkg.getName());
					break;
				case ALPM_ERR_PKG_INVALID_SIG:
					_alpm_process_siglist(handle, cast(char*)v.pkg.getName(), v.siglist,
							v.siglevel & AlpmSigLevel.PackageOptional,
							v.siglevel & AlpmSigLevel.PackageMarginalOk,
							v.siglevel & AlpmSigLevel.PackageUnknowOk);
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
			// free(v);
		}
		// alpm_list_free(errors);

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
		|| cmp(left.name, right.name) != 0
		|| left.mod != right.mod
		|| (left.version_ == null) != (right.version_ == null)
		|| ((left.version_ && right.version_) && cmp(left.version_, right.version_) != 0);
}

private int check_pkg_field_matches_db(AlpmHandle handle,   char*field, AlpmPkgs left, AlpmPkgs right)
{
	switch(alpmListCmpUnsorted(left, right)) {
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
	switch(alpmListCmpUnsorted(left, right)) {
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
	AlpmHandle handle = spkg.getHandle();
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

	if(spkg.getName() != pkgfile.getName()) {
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"internal package name mismatch, expected: '%s', actual: '%s'\n",
				spkg.getName(), pkgfile.getName());
		error = 1;
	}
	if(strcmp(cast(char*)spkg.getVersion(), cast(char*)pkgfile.getVersion()) != 0) {
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"internal package version mismatch, expected: '%s', actual: '%s'\n",
				spkg.getVersion(), pkgfile.getVersion());
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


private int load_packages(AlpmHandle handle, ref AlpmStrings data, size_t total, size_t total_bytes)
{
	size_t current = 0, current_bytes = 0;
	int errors = 0;
	AlpmStrings delete_list;
	AlpmEvent event;

	/* load packages from disk now that they are known-valid */
	event = new AlpmEventLoad(AlpmEventDefStatus.Start);

	EVENT(handle, event);

	foreach(ref spkg; handle.trans.add) {
		int error = 0;
		char* filepath = void;
		int percent = cast(int)((cast(double)current_bytes / total_bytes) * 100);

		PROGRESS(handle, ALPM_PROGRESS_LOAD_START, "", percent,
				total, current);
		if(spkg.origin == AlpmPkgFrom.File) {
			continue; /* pkg_load() has been already called, this package is valid */
		}

		current_bytes += spkg.getSize();
		filepath = _alpm_filecache_find(handle, cast(char*)spkg.getFilename());

		if(!filepath) {
			// FREELIST(delete_list);
			_alpm_log(handle, ALPM_LOG_ERROR,
					("%s: could not find package in cache\n"), spkg.getName());
			RET_ERR(handle, ALPM_ERR_PKG_NOT_FOUND, -1);
		}

		/* load the package file and replace pkgcache entry with it in the target list */
		/* TODO: alpm_pkg_get_db() will not work on this target anymore */
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"replacing pkgcache entry with package file for target %s\n",
				spkg.getName());
		AlpmPkg pkgfile = _alpm_pkg_load_internal(handle, filepath, 1);
		if(!pkgfile) {
			logger.tracef("failed to load pkgfile internal\n");
			error = 1;
		} else {
			error |= check_pkg_matches_db(spkg, pkgfile);
		}
		if(error != 0) {
			errors++;
			data.insertBack(spkg.getFilename());
			delete_list.insertBack(filepath.to!string);
			destroy!false(pkgfile);
			continue;
		}
		free(filepath);
		/* copy over the install reason */
		pkgfile.setReason(spkg.getReason());
		/* copy over validation method */
		pkgfile.setValidation(spkg.getValidation);
		/* transfer oldpkg */
		pkgfile.setOldPkg(spkg.getOldPkg());
		spkg.setOldPkg(null);
		spkg = pkgfile;
		/* spkg has been removed from the target list, so we can free the
		 * sync-specific fields */
		// _alpm_pkg_free_trans(spkg);
		spkg.freeTrans();

		current++;
	}

	PROGRESS(handle, ALPM_PROGRESS_LOAD_START, "", 100,
			total, current);
	event = new AlpmEventLoad(AlpmEventDefStatus.Done);
	EVENT(handle, event);

	if(errors) {
		foreach(str; delete_list[]) {
			prompt_to_delete(handle, cast(char*)str.toStringz, ALPM_ERR_PKG_INVALID);
		}
		// FREELIST(delete_list);

		if((cast(AlpmHandle)handle).pm_errno == ALPM_ERR_OK) {
			RET_ERR(handle, ALPM_ERR_PKG_INVALID, -1);
		}
		return -1;
	}

	return 0;
}

int _alpm_sync_load(AlpmHandle handle, ref RefTransData data)
{
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
	foreach(spkg; trans.add) {
		if(spkg.getOrigin() != AlpmPkgFrom.File) {
			total_bytes += spkg.getSize();
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

	if(load_packages(handle, data.strings, total, total_bytes)) {
		return -1;
	}

	return 0;
}

int _alpm_sync_check(AlpmHandle handle, ref RefTransData data)
{
	AlpmTrans trans = handle.trans;
	AlpmEventWithDefStatus event;

	/* fileconflict check */
	if(!(trans.flags & ALPM_TRANS_FLAG_DBONLY)) {
		event = new AlpmEventFileConflicts(AlpmEventDefStatus.Start);
		EVENT(handle, event);

		logger.tracef("looking for file conflicts\n");
		AlpmFileConflicts conflict = _alpm_db_find_fileconflicts(handle,
				trans.add, trans.remove);
		if(!conflict.empty) {
			// if(data) {
				data.fileConflicts = conflict;
			// } else {
				// alpm_list_free_inner(conflict,
						// cast(alpm_list_fn_free)&alpm_fileconflict_free);
				// alpm_list_free(conflict);
			// }
			RET_ERR(handle, ALPM_ERR_FILE_CONFLICTS, -1);
		}

		event = new AlpmEventFileConflicts(AlpmEventDefStatus.Done);
		EVENT(handle, event);
	}

	/* check available disk space */
	if(handle.checkspace && !(trans.flags & ALPM_TRANS_FLAG_DBONLY)) {
		event = new AlpmEventDiskSpace(AlpmEventDefStatus.Start);
		EVENT(handle, event);

		logger.tracef("checking available disk space\n");
		if(_alpm_check_diskspace(handle) == -1) {
			_alpm_log(handle, ALPM_LOG_ERROR, "not enough free disk space\n");
			return -1;
		}

		event = new AlpmEventDiskSpace(AlpmEventDefStatus.Done);
		EVENT(handle, event);
	}

	return 0;
}

int _alpm_sync_commit(AlpmHandle handle)
{
	AlpmTrans trans = handle.trans;

	/* remove conflicting and to-be-replaced packages */
	if(!trans.remove.empty()) {
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
	logger.tracef("installing packages\n");
	if(handle.upgradePackages() == -1) {
		_alpm_log(handle, ALPM_LOG_ERROR, "could not commit transaction\n");
		return -1;
	}

	return 0;
}
