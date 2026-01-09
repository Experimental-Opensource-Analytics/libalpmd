module libalpmd.group;
@nogc  
   
/*
 *  group.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
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
import core.stdc.string;

import std.algorithm;

/* libalpm */
import libalpmd.group;
import libalpmd.alpm_list;
import libalpmd.pkg;
import libalpmd.util;
import libalpmd.log;
import libalpmd.alpm;

/** Package group */
class AlpmGroup {
private:
	/** group name */
	string name;
	/** list of alpm_pkg_t packages */
	AlpmPkgs packages;

public:
	this(string name) {
		this.name = name;
	}

	string getName() {
		return name;
	}

	bool isPkgIn(AlpmPkg pkg) {
		return packages[].canFind!(a => a is pkg);
	}

	void addPkg(AlpmPkg pkg) {
		packages.insertBack(pkg);
	}

	auto getPackagesRange() {
		return packages[];
	}

	~this() {
		destroy(packages);
	}
}

alias AlpmGroups = AlpmList!AlpmGroup;