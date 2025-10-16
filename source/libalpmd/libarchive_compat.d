module libalpmd.libarchive_compat;
@nogc  
   
 
/*
 * libarchive-compat.h
 *
 *  Copyright (c) 2013-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
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

public import core.stdc.stdint;
import derelict.libarchive;

pragma(inline, true) int _alpm_archive_read_free(archive* archive)
{
	return archive_read_free(archive);
}

pragma(inline, true) long _alpm_archive_compressed_ftell(archive* archive)
{
	return archive_filter_bytes(archive, -1);
}

pragma(inline, true) int _alpm_archive_read_open_file(archive* archive, const(char)* filename, size_t block_size)
{
	return archive_read_open_filename(archive, filename, block_size);
}

pragma(inline, true) int _alpm_archive_filter_code(archive* archive)
{
	return archive_filter_code(archive, 0);
}

pragma(inline, true) int _alpm_archive_read_support_filter_all(archive* archive)
{
	return archive_read_support_filter_all(archive);
}

 /* LIBARCHIVE_COMPAT_H */
