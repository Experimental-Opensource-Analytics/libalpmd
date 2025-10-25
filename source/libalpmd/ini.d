module libalpmd.ini;
@nogc

/*
 *  ini.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
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
import core.stdc.errno;
import core.stdc.ctype;

import libalpmd.util;
import libalpmd.log;

enum INI_BUFFER_SIZE = 4096;

alias ini_parse_line_fn = int function(  char*file, int line,   char*section, char* key, char* value, void* data);

int parse_ini(  char*file, ini_parse_line_fn fn, void* data)
{
	FILE* fp = void;
	char[INI_BUFFER_SIZE] line = void;
	int linenum = 0;
	char* section = null;
	int ret = 0;

	if((fp = fopen(file, "r")) == null) {
		return -1;
	}

	while(fgets(line.ptr, INI_BUFFER_SIZE, fp)) {
		char* ptr = void;
		linenum++;

		/* strip trailing whitespace/newline */
		ptr = line.ptr + strlen(line.ptr) - 1;
		while(ptr >= line.ptr && isspace(cast(ubyte)*ptr)) {
			*ptr = '\0';
			ptr--;
		}

		/* strip leading whitespace */
		ptr = line.ptr;
		while(*ptr && isspace(cast(ubyte)*ptr)) {
			ptr++;
		}

		/* skip comments and empty lines */
		if(*ptr == '\0' || *ptr == '#') {
			continue;
		}

		if(*ptr == '[') {
			/* section header */
			char* name = ptr + 1;
			char* name_end = strchr(name, ']');
			if(!name_end) {
				ret = -1;
				break;
			}
			*name_end = '\0';
			if(fn(file, linenum, name, null, null, data)) {
				ret = -1;
				break;
			}
			STRNDUP(section, name);
		} else {
			/* key/value pair */
			char* key = ptr;
			char* value = strchr(ptr, '=');
			if(value) {
				*value = '\0';
				value++;

				/* strip trailing whitespace from key */
				char* key_end = key + strlen(key) - 1;
				while(key_end >= key && isspace(cast(ubyte)*key_end)) {
					*key_end = '\0';
					key_end--;
				}

				/* strip leading whitespace from value */
				while(*value && isspace(cast(ubyte)*value)) {
					value++;
				}

				/* strip trailing whitespace from value */
				char* value_end = value + strlen(value) - 1;
				while(value_end >= value && isspace(cast(ubyte)*value_end)) {
					*value_end = '\0';
					value_end--;
				}

				if(fn(file, linenum, section, key, value, data)) {
					ret = -1;
					break;
				}
			} else {
				/* invalid line */
				ret = -1;
				break;
			}
		}
	}

	FREE(section);
	fclose(fp);
	return ret;
}