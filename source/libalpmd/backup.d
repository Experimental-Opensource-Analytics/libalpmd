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
import libalpmd._package;


/* split a backup string "file\thash" into the relevant components */
int _alpm_split_backup(  char*_string, alpm_backup_t** backup)
{
	char* str = void, ptr = void;

	STRDUP(str, _string);

	/* tab delimiter */
	ptr = str ? strchr(str, '\t') : null;
	if(ptr == null) {
		(*backup).name = str;
		(*backup).hash = null;
		return 0;
	}
	*ptr = '\0';
	ptr++;
	/* now str points to the filename and ptr points to the hash */
	STRDUP((*backup).name, str);
	STRDUP((*backup).hash, ptr);
	FREE(str);
	return 0;
}

/* Look for a filename in a alpm_pkg_t.backup list. If we find it,
 * then we return the full backup entry.
 */
alpm_backup_t* _alpm_needbackup(  char*file, AlpmPkg pkg)
{
	alpm_list_t* lp = void;

	if(file == null || pkg is null) {
		return null;
	}

	for(lp = alpm_pkg_get_backup(pkg); lp; lp = lp.next) {
		alpm_backup_t* backup = cast(alpm_backup_t*)lp.data;

		if(strcmp(file, backup.name) == 0) {
			return backup;
		}
	}

	return null;
}

void _alpm_backup_free(alpm_backup_t* backup)
{
	//ASSERT(backup != null);
	FREE(backup.name);
	FREE(backup.hash);
	FREE(backup);
}

alpm_backup_t* _alpm_backup_dup(alpm_backup_t* backup)
{
	alpm_backup_t* newbackup = void;
	CALLOC(newbackup, 1, alpm_backup_t.sizeof);

	STRDUP(newbackup.name, backup.name);
	STRDUP(newbackup.hash, backup.hash);

	return newbackup;

error:
	free(newbackup.name);
	free(newbackup);
	return null;
}
