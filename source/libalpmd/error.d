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

  char*alpm_strerror(alpm_errno_t err)
{
	switch(err) {
		/* System */
		case ALPM_ERR_MEMORY:
			return cast(char*)("out of memory!");
		case ALPM_ERR_SYSTEM:
			return cast(char*)("unexpected system error");
		case ALPM_ERR_BADPERMS:
			return cast(char*)("permission denied");
		case ALPM_ERR_NOT_A_FILE:
			return cast(char*)("could not find or read file");
		case ALPM_ERR_NOT_A_DIR:
			return cast(char*)("could not find or read directory");
		case ALPM_ERR_WRONG_ARGS:
			return cast(char*)("wrong or NULL argument passed");
		case ALPM_ERR_DISK_SPACE:
			return cast(char*)("not enough free disk space");
		/* Interface */
		case ALPM_ERR_HANDLE_NULL:
			return cast(char*)("library not initialized");
		case ALPM_ERR_HANDLE_NOT_NULL:
			return cast(char*)("library already initialized");
		case ALPM_ERR_HANDLE_LOCK:
			return cast(char*)("unable to lock database");
		/* Databases */
		case ALPM_ERR_DB_OPEN:
			return cast(char*)("could not open database");
		case ALPM_ERR_DB_CREATE:
			return cast(char*)("could not create database");
		case ALPM_ERR_DB_NULL:
			return cast(char*)("database not initialized");
		case ALPM_ERR_DB_NOT_NULL:
			return cast(char*)("database already registered");
		case ALPM_ERR_DB_NOT_FOUND:
			return cast(char*)("could not find database");
		case ALPM_ERR_DB_INVALID:
			return cast(char*)("invalid or corrupted database");
		case ALPM_ERR_DB_INVALID_SIG:
			return cast(char*)("invalid or corrupted database (PGP signature)");
		case ALPM_ERR_DB_VERSION:
			return cast(char*)("database is incorrect version");
		case ALPM_ERR_DB_WRITE:
			return cast(char*)("could not update database");
		case ALPM_ERR_DB_REMOVE:
			return cast(char*)("could not remove database entry");
		/* Servers */
		case ALPM_ERR_SERVER_BAD_URL:
			return cast(char*)("invalid url for server");
		case ALPM_ERR_SERVER_NONE:
			return cast(char*)("no servers configured for repository");
		/* Transactions */
		case ALPM_ERR_TRANS_NOT_NULL:
			return cast(char*)("transaction already initialized");
		case ALPM_ERR_TRANS_NULL:
			return cast(char*)("transaction not initialized");
		case ALPM_ERR_TRANS_DUP_TARGET:
			return cast(char*)("duplicate target");
		case ALPM_ERR_TRANS_DUP_FILENAME:
			return cast(char*)("duplicate filename");
		case ALPM_ERR_TRANS_NOT_INITIALIZED:
			return cast(char*)("transaction not initialized");
		case ALPM_ERR_TRANS_NOT_PREPARED:
			return cast(char*)("transaction not prepared");
		case ALPM_ERR_TRANS_ABORT:
			return cast(char*)("transaction aborted");
		case ALPM_ERR_TRANS_TYPE:
			return cast(char*)("operation not compatible with the transaction type");
		case ALPM_ERR_TRANS_NOT_LOCKED:
			return cast(char*)("transaction commit attempt when database is not locked");
		case ALPM_ERR_TRANS_HOOK_FAILED:
			return cast(char*)("failed to run transaction hooks");
		/* Packages */
		case ALPM_ERR_PKG_NOT_FOUND:
			return cast(char*)("could not find or read package");
		case ALPM_ERR_PKG_IGNORED:
			return cast(char*)("operation cancelled due to ignorepkg");
		case ALPM_ERR_PKG_INVALID:
			return cast(char*)("invalid or corrupted package");
		case ALPM_ERR_PKG_INVALID_CHECKSUM:
			return cast(char*)("invalid or corrupted package (checksum)");
		case ALPM_ERR_PKG_INVALID_SIG:
			return cast(char*)("invalid or corrupted package (PGP signature)");
		case ALPM_ERR_PKG_MISSING_SIG:
			return cast(char*)("package missing required signature");
		case ALPM_ERR_PKG_OPEN:
			return cast(char*)("cannot open package file");
		case ALPM_ERR_PKG_CANT_REMOVE:
			return cast(char*)("cannot remove all files for package");
		case ALPM_ERR_PKG_INVALID_NAME:
			return cast(char*)("package filename is not valid");
		case ALPM_ERR_PKG_INVALID_ARCH:
			return cast(char*)("package architecture is not valid");
		/* Signatures */
		case ALPM_ERR_SIG_MISSING:
			return cast(char*)("missing PGP signature");
		case ALPM_ERR_SIG_INVALID:
			return cast(char*)("invalid PGP signature");
		/* Dependencies */
		case ALPM_ERR_UNSATISFIED_DEPS:
			return cast(char*)("could not satisfy dependencies");
		case ALPM_ERR_CONFLICTING_DEPS:
			return cast(char*)("conflicting dependencies");
		case ALPM_ERR_FILE_CONFLICTS:
			return cast(char*)("conflicting files");
		/* Miscellaneous */
		case ALPM_ERR_RETRIEVE:
			return cast(char*)("failed to retrieve some files");
		case ALPM_ERR_INVALID_REGEX:
			return cast(char*)("invalid regular expression");
		/* Errors from external libraries- our own wrapper error */
		case ALPM_ERR_LIBARCHIVE:
			/* it would be nice to use archive_error_string() here, but that
			 * requires the archive struct, so we can't. Just use a generic
			 * error string instead. */
			return cast(char*)("libarchive error");
		case ALPM_ERR_LIBCURL:
			return cast(char*)("download library error");
		case ALPM_ERR_GPGME:
			return cast(char*)("gpgme error");
		case ALPM_ERR_EXTERNAL_DOWNLOAD:
			return cast(char*)("error invoking external downloader");
		/* Missing compile-time features */
		case ALPM_ERR_MISSING_CAPABILITY_SIGNATURES:
				return cast(char*)("compiled without signature support");
		/* Unknown error! */
		default:
			return cast(char*)("unexpected error");
	}
}
