module libalpmd.conflict;
@nogc  
   
/*
 *  conflict.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
 *  Copyright (c) 2006 by David Kimpe <dnaku@frugalware.org>
 *  Copyright (c) 2006 by Miklos Vajna <vmiklos@frugalware.org>
 *  Copyright (c) 2006 by Christian Hamar <krics@linuxforum.hu>
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

import core.stdc.stdlib;
import core.stdc.stdio;
import core.stdc.string;
import core.stdc.limits;
import core.sys.posix.sys.stat;
import core.sys.posix.dirent;

/* libalpm */
import libalpmd.conflict;
import libalpmd.alpm_list;
import libalpmd.alpm;
import libalpmd.handle;
import libalpmd.trans;
import libalpmd.util;
import libalpmd.log;
import libalpmd.deps;
import libalpmd.file;
import libalpmd.pkg;
import libalpmd.backup;
import libalpmd.alpm_list.searching;

import libalpmd.db;
import libalpmd.deps;
import std.traits;

import std.conv;


/** A conflict that has occurred between two packages. */
class AlpmConflict {
	/** The first package */
	AlpmPkg package1;
	/** The second package */
	AlpmPkg package2;
	/** The conflict */
	AlpmDepend reason;

	this(AlpmPkg pkg1, AlpmPkg pkg2, AlpmDepend reason) {
		this.package1 = pkg1.dup;
		this.package2 = pkg2.dup;

		reason = reason.dup;
	}

	~this() {}

	/**
	* @brief Creates a copy of a conflict.
	*/
	AlpmConflict dup() => new AlpmConflict(
			package1,
			package2,
			reason
		);
}

alias AlpmConflicts = DList!AlpmConflict; 

void  alpm_conflict_free(AlpmConflict conflict) //! For alpm_list_free*
{
	destroy!false(conflict);
}

/**
 * @brief Adds the pkg1/pkg2 conflict to the baddeps list.
 *
 * @param handle the context handle
 * @param baddeps list to add conflict to
 * @param pkg1 first package
 * @param pkg2 package causing conflict
 * @param reason reason for this conflict
 *
 * @return 0 on success, -1 on error
 */
private int add_conflict(AlpmHandle handle, ref AlpmConflicts baddeps, AlpmPkg pkg1, AlpmPkg pkg2, AlpmDepend reason)
{
	AlpmConflict conflict = new AlpmConflict(pkg1, pkg2, reason);
	if(!conflict) {
		return -1;
	}
	if(!conflict_isin(conflict, baddeps)) {
		char* conflict_str = alpm_dep_compute_string(reason);
		baddeps.insertBack(conflict);
		logger.tracef("package %s conflicts with %s (by %s)\n",
				pkg1.getName(), pkg2.getName(), conflict_str);
		free(conflict_str);
	} else {
		alpm_conflict_free(conflict);
	}
	return 0;
}

/**
 * @brief Check if packages from list1 conflict with packages from list2.
 *
 * @details This looks at the conflicts fields of all packages from list1, and
 * sees if they match packages from list2. If a conflict (pkg1, pkg2) is found,
 * it is added to the baddeps list in this order if order >= 0, or reverse
 * order (pkg2,pkg1) otherwise.
 *
 * @param handle the context handle
 * @param list1 first list of packages
 * @param list2 second list of packages
 * @param baddeps list to store conflicts
 * @param order if >= 0 the conflict order is preserved, if < 0 it's reversed
 */
void check_conflict(AlpmHandle handle, AlpmPkgs list1, AlpmPkgs  list2, ref AlpmConflicts baddeps, int order) {
	if(baddeps.empty()) {
		return;
	}
	foreach(pkg1; list1[]) {
		foreach(conflict1; pkg1.getConflicts()[]) {
			foreach(pkg2; list2[]) {

				if(pkg1.getNameHash() == pkg2.getNameHash()
						&& pkg1.getName()== pkg2.getName()) {
					/* skip the package we're currently processing */
					continue;
				}

				if(_alpm_depcmp(pkg2, conflict1)) {
					if(order >= 0) {
						add_conflict(handle, baddeps, pkg1, pkg2, conflict1);
					} else {
						add_conflict(handle, baddeps, pkg2, pkg1, conflict1);
					}
				}
			}
		}
	}
}

/**
 * @brief Check for inter-conflicts in a list of packages.
 *
 * @param handle the context handle
 * @param packages list of packages to check
 *
 * @return list of conflicts
 */
AlpmConflicts _alpm_innerconflicts(AlpmHandle handle, AlpmPkgs packages)
{
	AlpmConflicts baddeps;

	logger.tracef("check targets vs targets\n");
	check_conflict(handle, packages, packages, baddeps, 0);

	return baddeps;
}

AlpmConflicts alpm_checkconflicts(AlpmHandle handle, AlpmPkgs pkglist)
{
	return _alpm_innerconflicts(handle, pkglist);
}
