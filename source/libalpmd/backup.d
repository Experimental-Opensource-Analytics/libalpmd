module libalpmd.backup;
@nogc  
   
/*
 *  backup.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2005 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
 *  Copyright (c) 2005 by Christian Hamar <krics@linuxforum.hu>
 *  Copyright (c) 2006 by Miklos Vajna <vmiklos@frugalware.org>
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

/* libalpm */
import libalpmd.backup;
import libalpmd.alpm_list;
import libalpmd.log;
import libalpmd.util;
import libalpmd.alpm;
import libalpmd.pkg;
import std.string;

/** Local package or package file backup entry */
class AlpmBackup {
       	/** Name of the file (without .pacsave extension) */
       	string name;
       	/** Hash of the filename (used internally) */
		string hash;	

	   	AlpmBackup dup() {
			auto newBackup = new AlpmBackup;
			newBackup.name = name.dup;
			newBackup.hash = hash.dup;
			return newBackup;
		}

		int splitString(string _string) {
			auto splitter = _string.split('\t');
			this.name = splitter[0].dup;
			this.hash = splitter[1].dup;

			return 0;
		}
}

/* Look for a filename in a alpm_pkg_t.backup list. If we find it,
 * then we return the full backup entry.
 */
AlpmBackup _alpm_needbackup(  char*file, AlpmPkg pkg)
{
	alpm_list_t* lp = void;

	if(file == null || pkg is null) {
		return null;
	}

	foreach(backup; pkg.getBackups()[]) {
		// AlpmBackup backup = cast(AlpmBackup)lp.data;

		if(strcmp(file, cast(char*)backup.name) == 0) {
			return backup;
		}
	}

	return null;
}

void _alpm_backup_free(AlpmBackup backup)
{
	//ASSERT(backup != null);
	FREE(backup.name);
	FREE(backup.hash);
	FREE(backup);
}

alias AlpmBackups = DList!AlpmBackup;