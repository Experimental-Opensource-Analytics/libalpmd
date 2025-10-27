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

/* libalpm */
import libalpmd.group;
import libalpmd.alpm_list;
import libalpmd.util;
import libalpmd.log;
import libalpmd.alpm;

alpm_group_t* _alpm_group_new(  char*name)
{
	alpm_group_t* grp = void;

	CALLOC(grp, 1, alpm_group_t.sizeof);
	STRDUP(grp.name, name);

	return grp;
}

void _alpm_group_free(alpm_group_t* grp)
{
	if(grp == null) {
		return;
	}

	FREE(grp.name);
	/* do NOT free the contents of the list, just the nodes */
	alpm_list_free(grp.packages);
	FREE(grp);
}
