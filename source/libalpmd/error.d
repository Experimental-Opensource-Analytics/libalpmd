module libalpmd.error;
@nogc  
   
/*
 *  error.c
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

version (HAVE_LIBCURL) {
import etc.c.curl;
}

/* libalpm */
import libalpmd.util;
import libalpmd.alpm;
import libalpmd.handle;

alpm_errno_t  alpm_errno(alpm_handle_t* handle)
{
	return handle.pm_errno;
}

const(char)* alpm_strerror(alpm_errno_t err)
{
	switch(err) {
		/* System */
		case ALPM_ERR_MEMORY:
			return ("out of memory!");
		case ALPM_ERR_SYSTEM:
			return ("unexpected system error");
		case ALPM_ERR_BADPERMS:
			return ("permission denied");
		case ALPM_ERR_NOT_A_FILE:
			return ("could not find or read file");
		case ALPM_ERR_NOT_A_DIR:
			return ("could not find or read directory");
		case ALPM_ERR_WRONG_ARGS:
			return ("wrong or NULL argument passed");
		case ALPM_ERR_DISK_SPACE:
			return ("not enough free disk space");
		/* Interface */
		case ALPM_ERR_HANDLE_NULL:
			return ("library not initialized");
		case ALPM_ERR_HANDLE_NOT_NULL:
			return ("library already initialized");
		case ALPM_ERR_HANDLE_LOCK:
			return ("unable to lock database");
		/* Databases */
		case ALPM_ERR_DB_OPEN:
			return ("could not open database");
		case ALPM_ERR_DB_CREATE:
			return ("could not create database");
		case ALPM_ERR_DB_NULL:
			return ("database not initialized");
		case ALPM_ERR_DB_NOT_NULL:
			return ("database already registered");
		case ALPM_ERR_DB_NOT_FOUND:
			return ("could not find database");
		case ALPM_ERR_DB_INVALID:
			return ("invalid or corrupted database");
		case ALPM_ERR_DB_INVALID_SIG:
			return ("invalid or corrupted database (PGP signature)");
		case ALPM_ERR_DB_VERSION:
			return ("database is incorrect version");
		case ALPM_ERR_DB_WRITE:
			return ("could not update database");
		case ALPM_ERR_DB_REMOVE:
			return ("could not remove database entry");
		/* Servers */
		case ALPM_ERR_SERVER_BAD_URL:
			return ("invalid url for server");
		case ALPM_ERR_SERVER_NONE:
			return ("no servers configured for repository");
		/* Transactions */
		case ALPM_ERR_TRANS_NOT_NULL:
			return ("transaction already initialized");
		case ALPM_ERR_TRANS_NULL:
			return ("transaction not initialized");
		case ALPM_ERR_TRANS_DUP_TARGET:
			return ("duplicate target");
		case ALPM_ERR_TRANS_DUP_FILENAME:
			return ("duplicate filename");
		case ALPM_ERR_TRANS_NOT_INITIALIZED:
			return ("transaction not initialized");
		case ALPM_ERR_TRANS_NOT_PREPARED:
			return ("transaction not prepared");
		case ALPM_ERR_TRANS_ABORT:
			return ("transaction aborted");
		case ALPM_ERR_TRANS_TYPE:
			return ("operation not compatible with the transaction type");
		case ALPM_ERR_TRANS_NOT_LOCKED:
			return ("transaction commit attempt when database is not locked");
		case ALPM_ERR_TRANS_HOOK_FAILED:
			return ("failed to run transaction hooks");
		/* Packages */
		case ALPM_ERR_PKG_NOT_FOUND:
			return ("could not find or read package");
		case ALPM_ERR_PKG_IGNORED:
			return ("operation cancelled due to ignorepkg");
		case ALPM_ERR_PKG_INVALID:
			return ("invalid or corrupted package");
		case ALPM_ERR_PKG_INVALID_CHECKSUM:
			return ("invalid or corrupted package (checksum)");
		case ALPM_ERR_PKG_INVALID_SIG:
			return ("invalid or corrupted package (PGP signature)");
		case ALPM_ERR_PKG_MISSING_SIG:
			return ("package missing required signature");
		case ALPM_ERR_PKG_OPEN:
			return ("cannot open package file");
		case ALPM_ERR_PKG_CANT_REMOVE:
			return ("cannot remove all files for package");
		case ALPM_ERR_PKG_INVALID_NAME:
			return ("package filename is not valid");
		case ALPM_ERR_PKG_INVALID_ARCH:
			return ("package architecture is not valid");
		/* Signatures */
		case ALPM_ERR_SIG_MISSING:
			return ("missing PGP signature");
		case ALPM_ERR_SIG_INVALID:
			return ("invalid PGP signature");
		/* Dependencies */
		case ALPM_ERR_UNSATISFIED_DEPS:
			return ("could not satisfy dependencies");
		case ALPM_ERR_CONFLICTING_DEPS:
			return ("conflicting dependencies");
		case ALPM_ERR_FILE_CONFLICTS:
			return ("conflicting files");
		/* Miscellaneous */
		case ALPM_ERR_RETRIEVE:
			return ("failed to retrieve some files");
		case ALPM_ERR_INVALID_REGEX:
			return ("invalid regular expression");
		/* Errors from external libraries- our own wrapper error */
		case ALPM_ERR_LIBARCHIVE:
			/* it would be nice to use archive_error_string() here, but that
			 * requires the archive struct, so we can't. Just use a generic
			 * error string instead. */
			return ("libarchive error");
		case ALPM_ERR_LIBCURL:
			return ("download library error");
		case ALPM_ERR_GPGME:
			return ("gpgme error");
		case ALPM_ERR_EXTERNAL_DOWNLOAD:
			return ("error invoking external downloader");
		/* Missing compile-time features */
		case ALPM_ERR_MISSING_CAPABILITY_SIGNATURES:
				return ("compiled without signature support");
		/* Unknown error! */
		default:
			return ("unexpected error");
	}
}
