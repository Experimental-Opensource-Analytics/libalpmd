module libalpmd.util_common;
// @nogc nothrow:
// extern(C): __gshared:
// module_ source.libalpmd. util_common;

/*
 *  util-common.c
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

import core.stdc.errno :
	errno, 
	EINVAL,
	EINTR;
import core.stdc.ctype : 
	isspace;
import core.stdc.stdlib : 
	free,
	realloc,
	malloc;
import core.stdc.string : 
	strrchr,
	strdup,
	strndup,
	strlen,
	memmove;
import core.stdc.stdio : 
	ferror,
	feof,
	clearerr,
	FILE,
	fgets;
import core.sys.posix.sys.stat :
	lstat,
	stat_t;

import std.conv;

/** Parse the basename of a program from a path.
* @param path path to parse basename from
*
* @return everything following the final '/'
*/
const(char)* mbasename(const(char)* path)
{
	const(char)* last = strrchr(path, '/');
	if(last) {
		return last + 1;
	}
	return path;
}

/** Parse the dirname of a program from a path.
* The path returned should be freed.
* @param path path to parse dirname from
*
* @return everything preceding the final '/'
*/
char* mdirname(const(char)* path)
{
	char* ret = void, last = void;

	/* null or empty path */
	if(path == null || *path == '\0') {
		return strdup(".");
	}

	if((ret = strdup(path)) == null) {
		return null;
	}

	last = strrchr(ret, '/');

	if(last != null) {
		/* we found a '/', so terminate our string */
		if(last == ret) {
			/* return "/" for root */
			last++;
		}
		*last = '\0';
		return ret;
	}

	/* no slash found */
	free(ret);
	return strdup(".");
}

/** lstat wrapper that treats /path/dirsymlink/ the same as /path/dirsymlink.
 * Linux lstat follows POSIX semantics and still performs a dereference on
 * the first, and for uses of lstat in libalpm this is not what we want.
 * @param path path to file to lstat
 * @param buf structure to fill with stat information
 * @return the return code from lstat
 */
int llstat(char* path, stat_t* buf)
{
	int ret = void;
	char* c = null;
	size_t len = strlen(path);

	while(len > 1 && path[len - 1] == '/') {
		--len;
		c = path + len;
	}

	if(c) {
		*c = '\0';
		ret = lstat(path, buf);
		*c = '/';
	} else {
		ret = lstat(path, buf);
	}

	return ret;
}

/** Wrapper around fgets() which properly handles EINTR
 * @param s string to read into
 * @param size maximum length to read
 * @param stream stream to read from
 * @return value returned by fgets()
 */
char* safe_fgets(char* s, int size, FILE* stream)
{
	char* ret = void;
	int errno_save = errno, ferror_save = ferror(stream);
	while((ret = fgets(s, size, stream)) == null && !feof(stream)) {
		if(errno == EINTR) {
			/* clear any errors we set and try again */
			errno = errno_save;
			if(!ferror_save) {
				clearerr(stream);
			}
		} else {
			break;
		}
	}
	return ret;
}

/* Trim whitespace and newlines from a string
 */
size_t strtrim(char* str)
{
	char* end = void, pch = str;

	if(str == null || *str == '\0') {
		/* string is empty, so we're done. */
		return 0;
	}

	while(isspace(cast(ubyte)*pch)) {
		pch++;
	}
	if(pch != str) {
		size_t len = strlen(pch);
		/* check if there wasn't anything but whitespace in the string. */
		if(len == 0) {
			*str = '\0';
			return 0;
		}
		memmove(str, pch, len + 1);
		pch = str;
	}

	end = (str + strlen(str) - 1);
	while(isspace(cast(ubyte)*end)) {
		end--;
	}
	*++end = '\0';

	return end - pch;
}

version (HAVE_STRNLEN) {} else {
/* A quick and dirty implementation derived from glibc */
/** Determines the length of a fixed-size string.
 * @param s string to be measured
 * @param max maximum number of characters to search for the string end
 * @return length of s or max, whichever is smaller
 */
private size_t strnlen(const(char)* s, size_t max)
{
	const(char)* p = void;
	for(p = s; *p && max--; ++p){}
	return (p - s);
}
}

version (HAVE_STRDUP) {} else {
/** Copies a string.
 * Returned string needs to be freed
 * @param s string to be copied
 * @param n maximum number of characters to copy
 * @return pointer to the new string on success, NULL on error
 */
// char* strndup(const(char)* s, size_t n)
// {
// 	size_t len = strnlen(s, n);
// 	char* new_ = cast(char*) malloc(len + 1);

// 	if(new_ == null) {
// 		return null;
// 	}

// 	new_[len] = '\0';
// 	return cast(char*)memcpy(new_, s, len);
// }
}

void wordsplit_free(char** ws)
{
	if(ws) {
		char** c = void;
		for(c = ws; *c; c++) {
			free(*c);
		}
		free(ws);
	}
}

char** wordsplit(const(char)* str)
{
	const(char)* c = str, end = void;
	char** out_ = null, outsave = void;
	size_t count = 0;

	if(str == null) {
		errno = EINVAL;
		return null;
	}

	for(c = str; isspace(*c); c++){}
	while(*c) {
		size_t wordlen = 0;

		/* extend our array */
		outsave = out_;
		if((out_ = cast(char**)realloc(out_, (count + 1) * (char).sizeof)) == null) {
			out_ = outsave;
			goto error;
		}

		/* calculate word length and check for unbalanced quotes */
		for(end = c; *end && !isspace(*end); end++) {
			if(*end == '\'' || *end == '"') {
				char quote = *end;
				while(*(++end) && *end != quote) {
					if(*end == '\\' && *(end + 1) == quote) {
						end++;
					}
					wordlen++;
				}
				if(*end != quote) {
					errno = EINVAL;
					goto error;
				}
			} else {
				if(*end == '\\' && (end[1] == '\'' || end[1] == '"')) {
					end++; /* skip the '\\' */
				}
				wordlen++;
			}
		}

		if(wordlen == cast(size_t) (end - c)) {
			/* no internal quotes or escapes, copy it the easy way */
			if((out_[count++] = strndup(c, wordlen)) == null) {
				goto error;
			}
		} else {
			/* manually copy to remove quotes and escapes */
			char* dest = out_[count++] = cast(char*)malloc(wordlen + 1);
			if(dest == null) { goto error; }
			while(c < end) {
				if(*c == '\'' || *c == '"') {
					char quote = *c;
					/* we know there must be a matching end quote,
					 * no need to check for '\0' */
					for(c++; *c != quote; c++) {
						if(*c == '\\' && *(c + 1) == quote) {
							c++;
						}
						*(dest++) = *c;
					}
					c++;
				} else {
					if(*c == '\\' && (c[1] == '\'' || c[1] == '"')) {
						c++; /* skip the '\\' */
					}
					*(dest++) = *(c++);
				}
			}
			*dest = '\0';
		}

		if(*end == '\0') {
			break;
		} else {
			for(c = end + 1; isspace(*c); c++){}
		}
	}

	outsave = out_;
	if((out_ = cast(char**)realloc(out_, (count + 1) * (char).sizeof)) == null) {
		out_ = outsave;
		goto error;
	}

	out_[count++] = null;

	return out_;

error:
	/* can't use wordsplit_free here because NULL has not been appended */
	while(count) {
		free(out_[--count]);
	}
	free(out_);
	return null;
}
