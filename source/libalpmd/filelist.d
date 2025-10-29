module libalpmd.filelist;
@nogc  
   
/*
 *  filelist.c
 *
 *  Copyright (c) 2012-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
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

import core.stdc.limits;
import core.stdc.string;
import core.sys.posix.sys.stat;
import core.sys.posix.stdlib;

/* libalpm */
import libalpmd.filelist;
import libalpmd.util;
import libalpmd.alpm_list;
import libalpmd.alpm;
import std.conv;

/** File in a package */
struct AlpmFile {
       /** Name of the file */
       string name;
       /** Size of the file */
       off_t size;
       /** The file's permissions */
       mode_t mode;
}

/* Returns the difference of the provided two lists of files.
 * Pre-condition: both lists are sorted!
 * When done, free the list but NOT the contained data.
 */
alpm_list_t* _alpm_filelist_difference(alpm_filelist_t* filesA, alpm_filelist_t* filesB)
{
	alpm_list_t* ret = null;
	size_t ctrA = 0, ctrB = 0;

	while(ctrA < filesA.count && ctrB < filesB.count) {
		string strA = filesA.files[ctrA].name;
		string strB = filesB.files[ctrB].name;

		int cmp = strA == strB;
		if(cmp < 0) {
			/* item only in filesA, qualifies as a difference */
			ret = alpm_list_add(ret, cast(void*)strA);
			ctrA++;
		} else if(cmp > 0) {
			ctrB++;
		} else {
			ctrA++;
			ctrB++;
		}
	}

	/* ensure we have completely emptied pA */
	while(ctrA < filesA.count) {
		ret = alpm_list_add(ret, cast(char*)filesA.files[ctrA].name);
		ctrA++;
	}

	return ret;
}

private int _alpm_filelist_pathcmp(  char*p1,   char*p2)
{
	while(*p1 && *p1 == *p2) {
		p1++;
		p2++;
	}

	/* skip trailing '/' */
	if(*p1 == '\0' && *p2 == '/') {
		p2++;
	} else if(*p2 == '\0' && *p1 == '/') {
		p1++;
	}

	return *p1 - *p2;
}

/* Returns the intersection of the provided two lists of files.
 * Pre-condition: both lists are sorted!
 * When done, free the list but NOT the contained data.
 */
alpm_list_t* _alpm_filelist_intersection(alpm_filelist_t* filesA, alpm_filelist_t* filesB)
{
	alpm_list_t* ret = null;
	size_t ctrA = 0, ctrB = 0;
	AlpmFile* arrA = filesA.files, arrB = filesB.files;

	while(ctrA < filesA.count && ctrB < filesB.count) {
		string strA = arrA[ctrA].name, strB = arrB[ctrB].name;
		int cmp = _alpm_filelist_pathcmp(cast(char*)strA, cast(char*)strB);
		if(cmp < 0) {
			ctrA++;
		} else if(cmp > 0) {
			ctrB++;
		} else {
			/* when not directories, item in both qualifies as an intersect */
			if(strA[$ - 1] != '/' || strB[$ - 1] != '/') {
				ret = alpm_list_add(ret, cast(char*)arrA[ctrA].name);
			}
			ctrA++;
			ctrB++;
		}
	}

	return ret;
}

/* Helper function for comparing files list entries
 */
extern (C) int _alpm_files_cmp(const void* f1, const void* f2)
{
	const(AlpmFile)* file1 = cast(const(AlpmFile)*)f1;
	const(AlpmFile)* file2 = cast(const(AlpmFile)*)f2;
	return strcmp(cast(char*)file1.name, cast(char*)file2.name);
}

AlpmFile * alpm_filelist_contains( alpm_filelist_t* filelist, string path)
{
	AlpmFile key = AlpmFile.init;

	if(!filelist || filelist.count == 0) {
		return null;
	}

	key.name = path.to!string;

	return cast(AlpmFile*)bsearch(cast(const void*)&key, cast(void*)filelist.files, filelist.count,
			AlpmFile.sizeof, &_alpm_files_cmp);
}

void _alpm_filelist_sort(alpm_filelist_t* filelist)
{
	size_t i = 0;
	for(i = 1; i < filelist.count; i++) {
		if(filelist.files[i - 1].name == filelist.files[i].name) {
			/* filelist is not pre-sorted */
			qsort(filelist.files, filelist.count,
					AlpmFile.sizeof, &_alpm_files_cmp);
			return;
		}
	}
}
