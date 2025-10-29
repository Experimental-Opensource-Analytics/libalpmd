module libalpmd.alpm;
 
   

import libalpmd.conf;
import core.stdc.config: c_long, c_ulong;
import core.stdc.stdarg;
import derelict.libarchive;
import core.stdc.string;
import core.stdc.stdio;
import libalpmd.be_local;

/*
 *  alpm.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
 *  Copyright (c) 2005 by Christian Hamar <krics@linuxforum.hu>
 *  Copyright (c) 2005, 2006 by Miklos Vajna <vmiklos@frugalware.org>
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

import core.stdc.errno;
import core.stdc.stddef;

import core.sys.posix.pwd;

/* libalpm */
import libalpmd.alpm;
import libalpmd.alpm_list;
import libalpmd.handle;
import libalpmd.log;
import libalpmd.util;

struct alpm_pkg_xdata_t {
	char* name;
	char* value;
}

/** The time type used by libalpm. Represents a unix time stamp
 * @ingroup libalpm_misc */
alias alpm_time_t = long;

/** @addtogroup libalpm_files Files
 * @brief Functions for package files
 * @{
 */

/** File in a package */
struct alpm_file_t {
       /** Name of the file */
       char* name;
       /** Size of the file */
       off_t size;
       /** The file's permissions */
       mode_t mode;
}

/** Package filelist container */
struct alpm_filelist_t {
       /** Amount of files in the array */
       size_t count;
       /** An array of files */
       alpm_file_t* files;
}

/** Local package or package file backup entry */
struct alpm_backup_t {
       /** Name of the file (without .pacsave extension) */
       char* name;
       /** Hash of the filename (used internally) */
       char* hash;
}

/** Determines whether a package filelist contains a given path.
 * The provided path should be relative to the install root with no leading
 * slashes, e.g. "etc/localtime". When searching for directories, the path must
 * have a trailing slash.
 * @param filelist a pointer to a package filelist
 * @param path the path to search for in the package
 * @return a pointer to the matching file or NULL if not found
 */
// alpm_file_t* alpm_filelist_contains(const(alpm_filelist_t)* filelist, const(char)* path);

/* End of libalpm_files */
/** @} */


/** @addtogroup libalpm_groups Groups
 * @brief Functions for package groups
 * @{
 */

/** Package group */
struct alpm_group_t {
	/** group name */
	char* name;
	/** list of alpm_pkg_t packages */
	alpm_list_t* packages;
}

/** Find group members across a list of databases.
 * If a member exists in several databases, only the first database is used.
 * IgnorePkg is also handled.
 * @param dbs the list of AlpmDB
 * @param name the name of the group
 * @return the list of AlpmPkg (caller is responsible for alpm_list_free)
 */
alpm_list_t* alpm_find_group_pkgs(alpm_list_t* dbs, const(char)* name);

/* End of libalpm_groups */
/** @} */


/** @addtogroup libalpm_errors Error Codes
 * Error codes returned by libalpm.
 * @{
 */

/** libalpm's error type */
enum alpm_errno_t {
	/** No error */
	ALPM_ERR_OK = 0,
	/** Failed to allocate memory */
	ALPM_ERR_MEMORY,
	/** A system error occurred */
	ALPM_ERR_SYSTEM,
	/** Permmision denied */
	ALPM_ERR_BADPERMS,
	/** Should be a file */
	ALPM_ERR_NOT_A_FILE,
	/** Should be a directory */
	ALPM_ERR_NOT_A_DIR,
	/** Function was called with invalid arguments */
	ALPM_ERR_WRONG_ARGS,
	/** Insufficient disk space */
	ALPM_ERR_DISK_SPACE,
	/* Interface */
	/** Handle should be null */
	ALPM_ERR_HANDLE_NULL,
	/** Handle should not be null */
	ALPM_ERR_HANDLE_NOT_NULL,
	/** Failed to acquire lock */
	ALPM_ERR_HANDLE_LOCK,
	/* Databases */
	/** Failed to open database */
	ALPM_ERR_DB_OPEN,
	/** Failed to create database */
	ALPM_ERR_DB_CREATE,
	/** Database should not be null */
	ALPM_ERR_DB_NULL,
	/** Database should be null */
	ALPM_ERR_DB_NOT_NULL,
	/** The database could not be found */
	ALPM_ERR_DB_NOT_FOUND,
	/** Database is invalid */
	ALPM_ERR_DB_INVALID,
	/** Database has an invalid signature */
	ALPM_ERR_DB_INVALID_SIG,
	/** The localdb is in a newer/older format than libalpm expects */
	ALPM_ERR_DB_VERSION,
	/** Failed to write to the database */
	ALPM_ERR_DB_WRITE,
	/** Failed to remove entry from database */
	ALPM_ERR_DB_REMOVE,
	/* Servers */
	/** Server URL is in an invalid format */
	ALPM_ERR_SERVER_BAD_URL,
	/** The database has no configured servers */
	ALPM_ERR_SERVER_NONE,
	/* Transactions */
	/** A transaction is already initialized */
	ALPM_ERR_TRANS_NOT_NULL,
	/** A transaction has not been initialized */
	ALPM_ERR_TRANS_NULL,
	/** Duplicate target in transaction */
	ALPM_ERR_TRANS_DUP_TARGET,
	/** Duplicate filename in transaction */
	ALPM_ERR_TRANS_DUP_FILENAME,
	/** A transaction has not been initialized */
	ALPM_ERR_TRANS_NOT_INITIALIZED,
	/** Transaction has not been prepared */
	ALPM_ERR_TRANS_NOT_PREPARED,
	/** Transaction was aborted */
	ALPM_ERR_TRANS_ABORT,
	/** Failed to interrupt transaction */
	ALPM_ERR_TRANS_TYPE,
	/** Tried to commit transaction without locking the database */
	ALPM_ERR_TRANS_NOT_LOCKED,
	/** A hook failed to run */
	ALPM_ERR_TRANS_HOOK_FAILED,
	/* Packages */
	/** Package not found */
	ALPM_ERR_PKG_NOT_FOUND,
	/** Package is in ignorepkg */
	ALPM_ERR_PKG_IGNORED,
	/** Package is invalid */
	ALPM_ERR_PKG_INVALID,
	/** Package has an invalid checksum */
	ALPM_ERR_PKG_INVALID_CHECKSUM,
	/** Package has an invalid signature */
	ALPM_ERR_PKG_INVALID_SIG,
	/** Package does not have a signature */
	ALPM_ERR_PKG_MISSING_SIG,
	/** Cannot open the package file */
	ALPM_ERR_PKG_OPEN,
	/** Failed to remove package files */
	ALPM_ERR_PKG_CANT_REMOVE,
	/** Package has an invalid name */
	ALPM_ERR_PKG_INVALID_NAME,
	/** Package has an invalid architecture */
	ALPM_ERR_PKG_INVALID_ARCH,
	/* Signatures */
	/** Signatures are missing */
	ALPM_ERR_SIG_MISSING,
	/** Signatures are invalid */
	ALPM_ERR_SIG_INVALID,
	/* Dependencies */
	/** Dependencies could not be satisfied */
	ALPM_ERR_UNSATISFIED_DEPS,
	/** Conflicting dependencies */
	ALPM_ERR_CONFLICTING_DEPS,
	/** Files conflict */
	ALPM_ERR_FILE_CONFLICTS,
	/* Misc */
	/** Download failed */
	ALPM_ERR_RETRIEVE,
	/** Invalid Regex */
	ALPM_ERR_INVALID_REGEX,
	/* External library errors */
	/** Error in libarchive */
	ALPM_ERR_LIBARCHIVE,
	/** Error in libcurl */
	ALPM_ERR_LIBCURL,
	/** Error in external download program */
	ALPM_ERR_EXTERNAL_DOWNLOAD,
	/** Error in gpgme */
	ALPM_ERR_GPGME,
	/** Missing compile-time features */
	ALPM_ERR_MISSING_CAPABILITY_SIGNATURES
}
alias ALPM_ERR_OK = alpm_errno_t.ALPM_ERR_OK;
alias ALPM_ERR_MEMORY = alpm_errno_t.ALPM_ERR_MEMORY;
alias ALPM_ERR_SYSTEM = alpm_errno_t.ALPM_ERR_SYSTEM;
alias ALPM_ERR_BADPERMS = alpm_errno_t.ALPM_ERR_BADPERMS;
alias ALPM_ERR_NOT_A_FILE = alpm_errno_t.ALPM_ERR_NOT_A_FILE;
alias ALPM_ERR_NOT_A_DIR = alpm_errno_t.ALPM_ERR_NOT_A_DIR;
alias ALPM_ERR_WRONG_ARGS = alpm_errno_t.ALPM_ERR_WRONG_ARGS;
alias ALPM_ERR_DISK_SPACE = alpm_errno_t.ALPM_ERR_DISK_SPACE;
alias ALPM_ERR_HANDLE_NULL = alpm_errno_t.ALPM_ERR_HANDLE_NULL;
alias ALPM_ERR_HANDLE_NOT_NULL = alpm_errno_t.ALPM_ERR_HANDLE_NOT_NULL;
alias ALPM_ERR_HANDLE_LOCK = alpm_errno_t.ALPM_ERR_HANDLE_LOCK;
alias ALPM_ERR_DB_OPEN = alpm_errno_t.ALPM_ERR_DB_OPEN;
alias ALPM_ERR_DB_CREATE = alpm_errno_t.ALPM_ERR_DB_CREATE;
alias ALPM_ERR_DB_NULL = alpm_errno_t.ALPM_ERR_DB_NULL;
alias ALPM_ERR_DB_NOT_NULL = alpm_errno_t.ALPM_ERR_DB_NOT_NULL;
alias ALPM_ERR_DB_NOT_FOUND = alpm_errno_t.ALPM_ERR_DB_NOT_FOUND;
alias ALPM_ERR_DB_INVALID = alpm_errno_t.ALPM_ERR_DB_INVALID;
alias ALPM_ERR_DB_INVALID_SIG = alpm_errno_t.ALPM_ERR_DB_INVALID_SIG;
alias ALPM_ERR_DB_VERSION = alpm_errno_t.ALPM_ERR_DB_VERSION;
alias ALPM_ERR_DB_WRITE = alpm_errno_t.ALPM_ERR_DB_WRITE;
alias ALPM_ERR_DB_REMOVE = alpm_errno_t.ALPM_ERR_DB_REMOVE;
alias ALPM_ERR_SERVER_BAD_URL = alpm_errno_t.ALPM_ERR_SERVER_BAD_URL;
alias ALPM_ERR_SERVER_NONE = alpm_errno_t.ALPM_ERR_SERVER_NONE;
alias ALPM_ERR_TRANS_NOT_NULL = alpm_errno_t.ALPM_ERR_TRANS_NOT_NULL;
alias ALPM_ERR_TRANS_NULL = alpm_errno_t.ALPM_ERR_TRANS_NULL;
alias ALPM_ERR_TRANS_DUP_TARGET = alpm_errno_t.ALPM_ERR_TRANS_DUP_TARGET;
alias ALPM_ERR_TRANS_DUP_FILENAME = alpm_errno_t.ALPM_ERR_TRANS_DUP_FILENAME;
alias ALPM_ERR_TRANS_NOT_INITIALIZED = alpm_errno_t.ALPM_ERR_TRANS_NOT_INITIALIZED;
alias ALPM_ERR_TRANS_NOT_PREPARED = alpm_errno_t.ALPM_ERR_TRANS_NOT_PREPARED;
alias ALPM_ERR_TRANS_ABORT = alpm_errno_t.ALPM_ERR_TRANS_ABORT;
alias ALPM_ERR_TRANS_TYPE = alpm_errno_t.ALPM_ERR_TRANS_TYPE;
alias ALPM_ERR_TRANS_NOT_LOCKED = alpm_errno_t.ALPM_ERR_TRANS_NOT_LOCKED;
alias ALPM_ERR_TRANS_HOOK_FAILED = alpm_errno_t.ALPM_ERR_TRANS_HOOK_FAILED;
alias ALPM_ERR_PKG_NOT_FOUND = alpm_errno_t.ALPM_ERR_PKG_NOT_FOUND;
alias ALPM_ERR_PKG_IGNORED = alpm_errno_t.ALPM_ERR_PKG_IGNORED;
alias ALPM_ERR_PKG_INVALID = alpm_errno_t.ALPM_ERR_PKG_INVALID;
alias ALPM_ERR_PKG_INVALID_CHECKSUM = alpm_errno_t.ALPM_ERR_PKG_INVALID_CHECKSUM;
alias ALPM_ERR_PKG_INVALID_SIG = alpm_errno_t.ALPM_ERR_PKG_INVALID_SIG;
alias ALPM_ERR_PKG_MISSING_SIG = alpm_errno_t.ALPM_ERR_PKG_MISSING_SIG;
alias ALPM_ERR_PKG_OPEN = alpm_errno_t.ALPM_ERR_PKG_OPEN;
alias ALPM_ERR_PKG_CANT_REMOVE = alpm_errno_t.ALPM_ERR_PKG_CANT_REMOVE;
alias ALPM_ERR_PKG_INVALID_NAME = alpm_errno_t.ALPM_ERR_PKG_INVALID_NAME;
alias ALPM_ERR_PKG_INVALID_ARCH = alpm_errno_t.ALPM_ERR_PKG_INVALID_ARCH;
alias ALPM_ERR_SIG_MISSING = alpm_errno_t.ALPM_ERR_SIG_MISSING;
alias ALPM_ERR_SIG_INVALID = alpm_errno_t.ALPM_ERR_SIG_INVALID;
alias ALPM_ERR_UNSATISFIED_DEPS = alpm_errno_t.ALPM_ERR_UNSATISFIED_DEPS;
alias ALPM_ERR_CONFLICTING_DEPS = alpm_errno_t.ALPM_ERR_CONFLICTING_DEPS;
alias ALPM_ERR_FILE_CONFLICTS = alpm_errno_t.ALPM_ERR_FILE_CONFLICTS;
alias ALPM_ERR_RETRIEVE = alpm_errno_t.ALPM_ERR_RETRIEVE;
alias ALPM_ERR_INVALID_REGEX = alpm_errno_t.ALPM_ERR_INVALID_REGEX;
alias ALPM_ERR_LIBARCHIVE = alpm_errno_t.ALPM_ERR_LIBARCHIVE;
alias ALPM_ERR_LIBCURL = alpm_errno_t.ALPM_ERR_LIBCURL;
alias ALPM_ERR_EXTERNAL_DOWNLOAD = alpm_errno_t.ALPM_ERR_EXTERNAL_DOWNLOAD;
alias ALPM_ERR_GPGME = alpm_errno_t.ALPM_ERR_GPGME;
alias ALPM_ERR_MISSING_CAPABILITY_SIGNATURES = alpm_errno_t.ALPM_ERR_MISSING_CAPABILITY_SIGNATURES;

enum alpm_siglevel_t {
	/** Packages require a signature */
	ALPM_SIG_PACKAGE = (1 << 0),
	/** Packages do not require a signature,
	 * but check packages that do have signatures */
	ALPM_SIG_PACKAGE_OPTIONAL = (1 << 1),
	/* Allow packages with signatures that are marginal trust */
	ALPM_SIG_PACKAGE_MARGINAL_OK = (1 << 2),
	/** Allow packages with signatures that are unknown trust */
	ALPM_SIG_PACKAGE_UNKNOWN_OK = (1 << 3),

	/** Databases require a signature */
	ALPM_SIG_DATABASE = (1 << 10),
	/** Databases do not require a signature,
	 * but check databases that do have signatures */
	ALPM_SIG_DATABASE_OPTIONAL = (1 << 11),
	/** Allow databases with signatures that are marginal trust */
	ALPM_SIG_DATABASE_MARGINAL_OK = (1 << 12),
	/** Allow databases with signatures that are unknown trust */
	ALPM_SIG_DATABASE_UNKNOWN_OK = (1 << 13),

	/** The Default siglevel */
	ALPM_SIG_USE_DEFAULT = (1 << 30)
}
alias ALPM_SIG_PACKAGE = alpm_siglevel_t.ALPM_SIG_PACKAGE;
alias ALPM_SIG_PACKAGE_OPTIONAL = alpm_siglevel_t.ALPM_SIG_PACKAGE_OPTIONAL;
alias ALPM_SIG_PACKAGE_MARGINAL_OK = alpm_siglevel_t.ALPM_SIG_PACKAGE_MARGINAL_OK;
alias ALPM_SIG_PACKAGE_UNKNOWN_OK = alpm_siglevel_t.ALPM_SIG_PACKAGE_UNKNOWN_OK;
alias ALPM_SIG_DATABASE = alpm_siglevel_t.ALPM_SIG_DATABASE;
alias ALPM_SIG_DATABASE_OPTIONAL = alpm_siglevel_t.ALPM_SIG_DATABASE_OPTIONAL;
alias ALPM_SIG_DATABASE_MARGINAL_OK = alpm_siglevel_t.ALPM_SIG_DATABASE_MARGINAL_OK;
alias ALPM_SIG_DATABASE_UNKNOWN_OK = alpm_siglevel_t.ALPM_SIG_DATABASE_UNKNOWN_OK;
alias ALPM_SIG_USE_DEFAULT = alpm_siglevel_t.ALPM_SIG_USE_DEFAULT;


/** PGP signature verification status return codes */
enum alpm_sigstatus_t {
	/** Signature is valid */
	ALPM_SIGSTATUS_VALID,
	/** The key has expired */
	ALPM_SIGSTATUS_KEY_EXPIRED,
	/** The signature has expired */
	ALPM_SIGSTATUS_SIG_EXPIRED,
	/** The key is not in the keyring */
	ALPM_SIGSTATUS_KEY_UNKNOWN,
	/** The key has been disabled */
	ALPM_SIGSTATUS_KEY_DISABLED,
	/** The signature is invalid */
	ALPM_SIGSTATUS_INVALID
}
alias ALPM_SIGSTATUS_VALID = alpm_sigstatus_t.ALPM_SIGSTATUS_VALID;
alias ALPM_SIGSTATUS_KEY_EXPIRED = alpm_sigstatus_t.ALPM_SIGSTATUS_KEY_EXPIRED;
alias ALPM_SIGSTATUS_SIG_EXPIRED = alpm_sigstatus_t.ALPM_SIGSTATUS_SIG_EXPIRED;
alias ALPM_SIGSTATUS_KEY_UNKNOWN = alpm_sigstatus_t.ALPM_SIGSTATUS_KEY_UNKNOWN;
alias ALPM_SIGSTATUS_KEY_DISABLED = alpm_sigstatus_t.ALPM_SIGSTATUS_KEY_DISABLED;
alias ALPM_SIGSTATUS_INVALID = alpm_sigstatus_t.ALPM_SIGSTATUS_INVALID;



/** The trust level of a PGP key */
enum alpm_sigvalidity_t {
	/** The signature is fully trusted */
	ALPM_SIGVALIDITY_FULL,
	/** The signature is marginally trusted */
	ALPM_SIGVALIDITY_MARGINAL,
	/** The signature is never trusted */
	ALPM_SIGVALIDITY_NEVER,
	/** The signature has unknown trust */
	ALPM_SIGVALIDITY_UNKNOWN
}
alias ALPM_SIGVALIDITY_FULL = alpm_sigvalidity_t.ALPM_SIGVALIDITY_FULL;
alias ALPM_SIGVALIDITY_MARGINAL = alpm_sigvalidity_t.ALPM_SIGVALIDITY_MARGINAL;
alias ALPM_SIGVALIDITY_NEVER = alpm_sigvalidity_t.ALPM_SIGVALIDITY_NEVER;
alias ALPM_SIGVALIDITY_UNKNOWN = alpm_sigvalidity_t.ALPM_SIGVALIDITY_UNKNOWN;


/** A PGP key */
struct alpm_pgpkey_t {
	/** The actual key data */
	void* data;
	/** The key's fingerprint */
	char* fingerprint;
	/** UID of the key */
	char* uid;
	/** Name of the key's owner */
	char* name;
	/** Email of the key's owner */
	char* email;
	/** When the key was created */
	alpm_time_t created;
	/** When the key expires */
	alpm_time_t expires;
	/** The length of the key */
	uint length;
	/** has the key been revoked */
	uint revoked;
}

/**
 * Signature result. Contains the key, status, and validity of a given
 * signature.
 */
struct alpm_sigresult_t {
	/** The key of the signature */
	alpm_pgpkey_t key;
	/** The status of the signature */
	alpm_sigstatus_t status;
	/** The validity of the signature */
	alpm_sigvalidity_t validity;
}

/**
 * Signature list. Contains the number of signatures found and a pointer to an
 * array of results. The array is of size count.
 */
struct alpm_siglist_t {
	/** The amount of results in the array */
	size_t count;
	/** An array of sigresults */
	alpm_sigresult_t* results;
}

/** Types of version constraints in dependency specs. */
enum alpm_depmod_t {
        /** No version constraint */
        ALPM_DEP_MOD_ANY = 1,
        /** Test version equality (package=x.y.z) */
        ALPM_DEP_MOD_EQ,
        /** Test for at least a version (package>=x.y.z) */
        ALPM_DEP_MOD_GE,
        /** Test for at most a version (package<=x.y.z) */
        ALPM_DEP_MOD_LE,
        /** Test for greater than some version (package>x.y.z) */
        ALPM_DEP_MOD_GT,
        /** Test for less than some version (package<x.y.z) */
        ALPM_DEP_MOD_LT
}
alias ALPM_DEP_MOD_ANY = alpm_depmod_t.ALPM_DEP_MOD_ANY;
alias ALPM_DEP_MOD_EQ = alpm_depmod_t.ALPM_DEP_MOD_EQ;
alias ALPM_DEP_MOD_GE = alpm_depmod_t.ALPM_DEP_MOD_GE;
alias ALPM_DEP_MOD_LE = alpm_depmod_t.ALPM_DEP_MOD_LE;
alias ALPM_DEP_MOD_GT = alpm_depmod_t.ALPM_DEP_MOD_GT;
alias ALPM_DEP_MOD_LT = alpm_depmod_t.ALPM_DEP_MOD_LT;


/**
 * File conflict type.
 * Whether the conflict results from a file existing on the filesystem, or with
 * another target in the transaction.
 */
enum alpm_fileconflicttype_t {
	/** The conflict results with a another target in the transaction */
	ALPM_FILECONFLICT_TARGET = 1,
	/** The conflict results from a file existing on the filesystem */
	ALPM_FILECONFLICT_FILESYSTEM
}
alias ALPM_FILECONFLICT_TARGET = alpm_fileconflicttype_t.ALPM_FILECONFLICT_TARGET;
alias ALPM_FILECONFLICT_FILESYSTEM = alpm_fileconflicttype_t.ALPM_FILECONFLICT_FILESYSTEM;


/** The basic dependency type.
 *
 * This type is used throughout libalpm, not just for dependencies
 * but also conflicts and providers. */
struct alpm_depend_t {
	/**  Name of the provider to satisfy this dependency */
	char* name;
	/**  Version of the provider to match against (optional) */
	char* version_;
	/** A description of why this dependency is needed (optional) */
	char* desc;
	/** A hash of name (used internally to speed up conflict checks) */
	c_ulong name_hash;
	/** How the version should match against the provider */
	alpm_depmod_t mod;
}

/** Missing dependency. */
struct alpm_depmissing_t {
	/** Name of the package that has the dependency */
	char* target;
	/** The dependency that was wanted */
	alpm_depend_t* depend;
	/** If the depmissing was caused by a conflict, the name of the package
	 * that would be installed, causing the satisfying package to be removed */
	char* causingpkg;
}

/** A conflict that has occurred between two packages. */
struct alpm_conflict_t {
	/** The first package */
	AlpmPkg package1;
	/** The second package */
	AlpmPkg package2;
	/** The conflict */
	alpm_depend_t* reason;
}

/** File conflict.
 *
 * A conflict that has happened due to a two packages containing the same file,
 * or a package contains a file that is already on the filesystem and not owned
 * by that package. */
struct alpm_fileconflict_t {
	/** The name of the package that caused the conflict */
	char* target;
	/** The type of conflict */
	alpm_fileconflicttype_t type;
	/** The name of the file that the package conflicts with */
	char* file;
	/** The name of the package that also owns the file if there is one*/
	char* ctarget;
}



/** @addtogroup libalpm The libalpm Public API
 *
 *
 *
 * libalpm is a package management library, primarily used by pacman.
 * For ease of access, the libalpm manual has been split up into several sections.
 *
 * @section see_also See Also
 * \b libalpm_list(3),
 * \b libalpm_cb(3),
 * \b libalpm_databases(3),
 * \b libalpm_depends(3),
 * \b libalpm_errors(3),
 * \b libalpm_files(3),
 * \b libalpm_groups(3),
 * \b libalpm_handle(3),
 * \b libalpm_log(3),
 * \b libalpm_misc(3),
 * \b libalpm_options(3),
 * \b libalpm_packages(3),
 * \b libalpm_sig(3),
 * \b libalpm_trans(3)
 * @{
 */

/*
 * Opaque Structures
 */

/** The libalpm context handle.
 *
 * This struct represents an instance of libalpm.
 * @ingroup libalpm_handle
 */

/** A database.
 *
 * A database is a container that stores metadata about packages.
 *
 * A database can be located on the local filesystem or on a remote server.
 *
 * To use a database, it must first be registered via \link alpm_register_syncdb \endlink.
 * If the database is already present in dbpath then it will be usable. Otherwise,
 * the database needs to be downloaded using \link alpm_db_update \endlink. Even if the
 * source of the database is the local filesystem.
 *
 * After this, the database can be used to query packages and groups. Any packages or groups
 * from the database will continue to be owned by the database and do not need to be freed by
 * the user. They will be freed when the database is unregistered.
 *
 * Databases are automatically unregistered when the \link AlpmHandle \endlink is released.
 * @ingroup libalpm_databases
 */
 import libalpmd.db;

/** A package.
 *
 * A package can be loaded from disk via \link alpm_pkg_load \endlink or retrieved from a database.
 * Packages from databases are automatically freed when the database is unregistered. Packages loaded
 * from a file must be freed manually.
 *
 * Packages can then be queried for metadata or added to a transaction
 * to be added or removed from the system.
 * @ingroup libalpm_packages
 */
import libalpmd._package;

/** The time type used by libalpm. Represents a unix time stamp
 * @ingroup libalpm_misc */
// alias alpm_time_t = long;



/** Determines whether a package filelist contains a given path.
 * The provided path should be relative to the install root with no leading
 * slashes, e.g. "etc/localtime". When searching for directories, the path must
 * have a trailing slash.
 * @param filelist a pointer to a package filelist
 * @param path the path to search for in the package
 * @return a pointer to the matching file or NULL if not found
 */
// alpm_file_t* alpm_filelist_contains(const(alpm_filelist_t)* filelist, const(char)* path);

/* End of libalpm_files */
/** @} */


/** @addtogroup libalpm_groups Groups
 * @brief Functions for package groups
 * @{
 */


/** Find group members across a list of databases.
 * If a member exists in several databases, only the first database is used.
 * IgnorePkg is also handled.
 * @param dbs the list of AlpmDB
 * @param name the name of the group
 * @return the list of AlpmPkg (caller is responsible for alpm_list_free)
 */
alpm_list_t* alpm_find_group_pkgs(alpm_list_t* dbs, const(char)* name);

/* End of libalpm_groups */
/** @} */


/** Returns the current error code from the handle.
 * @param handle the context handle
 * @return the current error code of the handle
 */
alpm_errno_t alpm_errno(AlpmHandle handle);

/** Returns the string corresponding to an error number.
 * @param err the error code to get the string for
 * @return the string relating to the given error code
 */
const(char)* alpm_strerror(alpm_errno_t err);

/* End of libalpm_errors */
/** @} */


/** \addtogroup libalpm_handle Handle
 * @brief Functions to initialize and release libalpm
 * @{
 */

/** Initializes the library.
 * Creates handle, connects to database and creates lockfile.
 * This must be called before any other functions are called.
 * @param root the root path for all filesystem operations
 * @param dbpath the absolute path to the libalpm database
 * @param err an optional variable to hold any error return codes
 * @return a context handle on success, NULL on error, err will be set if provided
 */
AlpmHandle alpm_initialize(const(char)* root, const(char)* dbpath, alpm_errno_t* err);

/** Release the library.
 * Disconnects from the database, removes handle and lockfile
 * This should be the last alpm call you make.
 * After this returns, handle should be considered invalid and cannot be reused
 * in any way.
 * @param handle the context handle
 * @return 0 on success, -1 on error
 */
int alpm_release(AlpmHandle handle);

/* End of libalpm_handle */
/** @} */




/**
 * Check the PGP signature for the given package file.
 * @param pkg the package to check
 * @param siglist a pointer to storage for signature results
 * @return 0 on success, -1 if an error occurred or signature is missing
 */
int alpm_pkg_check_pgp_signature(AlpmPkg pkg, alpm_siglist_t* siglist);

/**
 * Check the PGP signature for the given database.
 * @param db the database to check
 * @param siglist a pointer to storage for signature results
 * @return 0 on success, -1 if an error occurred or signature is missing
 */
int alpm_db_check_pgp_signature(AlpmDB db, alpm_siglist_t* siglist);

/**
 * Clean up and free a signature result list.
 * Note that this does not free the siglist object itself in case that
 * was allocated on the stack; this is the responsibility of the caller.
 * @param siglist a pointer to storage for signature results
 * @return 0 on success, -1 on error
 */
int alpm_siglist_cleanup(alpm_siglist_t* siglist);

/**
 * Extract the Issuer Key ID from a signature
 * @param handle the context handle
 * @param identifier the identifier of the key.
 * This may be the name of the package or the path to the package.
 * @param sig PGP signature
 * @param len length of signature
 * @param keys a pointer to storage for key IDs
 * @return 0 on success, -1 on error
 */
// int alpm_extract_keyid(AlpmHandle handle, const(char)* identifier, const(ubyte)* sig, const(size_t) len, alpm_list_t** keys);

/* End of libalpm_sig */








/** Checks dependencies and returns missing ones in a list.
 * Dependencies can include versions with depmod operators.
 * @param handle the context handle
 * @param pkglist the list of local packages
 * @param remove an alpm_list_t* of packages to be removed
 * @param upgrade an alpm_list_t* of packages to be upgraded (remove-then-upgrade)
 * @param reversedeps handles the backward dependencies
 * @return an alpm_list_t* of alpm_depmissing_t pointers.
 */
// alpm_list_t* alpm_checkdeps(AlpmHandle handle, alpm_list_t* pkglist, alpm_list_t* remove, alpm_list_t* upgrade, int reversedeps);

/** Find a package satisfying a specified dependency.
 * First look for a literal, going through each db one by one. Then look for
 * providers. The first satisfyer that belongs to an installed package is
 * returned. If no providers belong to an installed package then an
 * alpm_question_select_provider_t is created to select the provider.
 * The dependency can include versions with depmod operators.
 *
 * @param handle the context handle
 * @param dbs an alpm_list_t* of alpm_db_t where the satisfyer will be searched
 * @param depstring package or provision name, versioned or not
 * @return a AlpmPkg satisfying depstring
 */
AlpmPkg alpm_find_dbs_satisfier(AlpmHandle handle, alpm_list_t* dbs, const(char)* depstring);

/** Check the package conflicts in a database
 *
 * @param handle the context handle
 * @param pkglist the list of packages to check
 *
 * @return an alpm_list_t of alpm_conflict_t
 */
alpm_list_t* alpm_checkconflicts(AlpmHandle handle, alpm_list_t* pkglist);

/** Returns a newly allocated string representing the dependency information.
 * @param dep a dependency info structure
 * @return a formatted string, e.g. "glibc>=2.12"
 */
// char* alpm_dep_compute_string(alpm_depend_t* dep);

/** Return a newly allocated dependency information parsed from a string
 *\link alpm_dep_free should be used to free the dependency \endlink
 * @param depstring a formatted string, e.g. "glibc=2.12"
 * @return a dependency info structure
 */
// alpm_depend_t* alpm_dep_from_string(const(char)* depstring);

/** Free a dependency info structure
 * @param dep struct to free
 */
// void alpm_dep_free(alpm_depend_t* dep);

/** Free a fileconflict and its members.
 * @param conflict the fileconflict to free
 */
// void alpm_fileconflict_free(alpm_fileconflict_t* conflict);

/** Free a depmissing and its members
 * @param miss the depmissing to free
 * */
// void alpm_depmissing_free(alpm_depmissing_t* miss);

/**
 * Free a conflict and its members.
 * @param conflict the conflict to free
 */
// void alpm_conflict_free(alpm_conflict_t* conflict);


/* End of libalpm_depends */
/** @} */


/** \addtogroup libalpm_cb Callbacks
 * @brief Functions and structures for libalpm's callbacks
 * @{
 */

/**
 * Type of events.
 */
enum alpm_event_type_t {
	/** Dependencies will be computed for a package. */
	ALPM_EVENT_CHECKDEPS_START = 1,
	/** Dependencies were computed for a package. */
	ALPM_EVENT_CHECKDEPS_DONE,
	/** File conflicts will be computed for a package. */
	ALPM_EVENT_FILECONFLICTS_START,
	/** File conflicts were computed for a package. */
	ALPM_EVENT_FILECONFLICTS_DONE,
	/** Dependencies will be resolved for target package. */
	ALPM_EVENT_RESOLVEDEPS_START,
	/** Dependencies were resolved for target package. */
	ALPM_EVENT_RESOLVEDEPS_DONE,
	/** Inter-conflicts will be checked for target package. */
	ALPM_EVENT_INTERCONFLICTS_START,
	/** Inter-conflicts were checked for target package. */
	ALPM_EVENT_INTERCONFLICTS_DONE,
	/** Processing the package transaction is starting. */
	ALPM_EVENT_TRANSACTION_START,
	/** Processing the package transaction is finished. */
	ALPM_EVENT_TRANSACTION_DONE,
	/** Package will be installed/upgraded/downgraded/re-installed/removed; See
	 * alpm_event_package_operation_t for arguments. */
	ALPM_EVENT_PACKAGE_OPERATION_START,
	/** Package was installed/upgraded/downgraded/re-installed/removed; See
	 * alpm_event_package_operation_t for arguments. */
	ALPM_EVENT_PACKAGE_OPERATION_DONE,
	/** Target package's integrity will be checked. */
	ALPM_EVENT_INTEGRITY_START,
	/** Target package's integrity was checked. */
	ALPM_EVENT_INTEGRITY_DONE,
	/** Target package will be loaded. */
	ALPM_EVENT_LOAD_START,
	/** Target package is finished loading. */
	ALPM_EVENT_LOAD_DONE,
	/** Scriptlet has printed information; See alpm_event_scriptlet_info_t for
	 * arguments. */
	ALPM_EVENT_SCRIPTLET_INFO,
	/** Database files will be downloaded from a repository. */
	ALPM_EVENT_DB_RETRIEVE_START,
	/** Database files were downloaded from a repository. */
	ALPM_EVENT_DB_RETRIEVE_DONE,
	/** Not all database files were successfully downloaded from a repository. */
	ALPM_EVENT_DB_RETRIEVE_FAILED,
	/** Package files will be downloaded from a repository. */
	ALPM_EVENT_PKG_RETRIEVE_START,
	/** Package files were downloaded from a repository. */
	ALPM_EVENT_PKG_RETRIEVE_DONE,
	/** Not all package files were successfully downloaded from a repository. */
	ALPM_EVENT_PKG_RETRIEVE_FAILED,
	/** Disk space usage will be computed for a package. */
	ALPM_EVENT_DISKSPACE_START,
	/** Disk space usage was computed for a package. */
	ALPM_EVENT_DISKSPACE_DONE,
	/** An optdepend for another package is being removed; See
	 * alpm_event_optdep_removal_t for arguments. */
	ALPM_EVENT_OPTDEP_REMOVAL,
	/** A configured repository database is missing; See
	 * alpm_event_database_missing_t for arguments. */
	ALPM_EVENT_DATABASE_MISSING,
	/** Checking keys used to create signatures are in keyring. */
	ALPM_EVENT_KEYRING_START,
	/** Keyring checking is finished. */
	ALPM_EVENT_KEYRING_DONE,
	/** Downloading missing keys into keyring. */
	ALPM_EVENT_KEY_DOWNLOAD_START,
	/** Key downloading is finished. */
	ALPM_EVENT_KEY_DOWNLOAD_DONE,
	/** A .pacnew file was created; See alpm_event_pacnew_created_t for arguments. */
	ALPM_EVENT_PACNEW_CREATED,
	/** A .pacsave file was created; See alpm_event_pacsave_created_t for
	 * arguments. */
	ALPM_EVENT_PACSAVE_CREATED,
	/** Processing hooks will be started. */
	ALPM_EVENT_HOOK_START,
	/** Processing hooks is finished. */
	ALPM_EVENT_HOOK_DONE,
	/** A hook is starting */
	ALPM_EVENT_HOOK_RUN_START,
	/** A hook has finished running. */
	ALPM_EVENT_HOOK_RUN_DONE
}
alias ALPM_EVENT_CHECKDEPS_START = alpm_event_type_t.ALPM_EVENT_CHECKDEPS_START;
alias ALPM_EVENT_CHECKDEPS_DONE = alpm_event_type_t.ALPM_EVENT_CHECKDEPS_DONE;
alias ALPM_EVENT_FILECONFLICTS_START = alpm_event_type_t.ALPM_EVENT_FILECONFLICTS_START;
alias ALPM_EVENT_FILECONFLICTS_DONE = alpm_event_type_t.ALPM_EVENT_FILECONFLICTS_DONE;
alias ALPM_EVENT_RESOLVEDEPS_START = alpm_event_type_t.ALPM_EVENT_RESOLVEDEPS_START;
alias ALPM_EVENT_RESOLVEDEPS_DONE = alpm_event_type_t.ALPM_EVENT_RESOLVEDEPS_DONE;
alias ALPM_EVENT_INTERCONFLICTS_START = alpm_event_type_t.ALPM_EVENT_INTERCONFLICTS_START;
alias ALPM_EVENT_INTERCONFLICTS_DONE = alpm_event_type_t.ALPM_EVENT_INTERCONFLICTS_DONE;
alias ALPM_EVENT_TRANSACTION_START = alpm_event_type_t.ALPM_EVENT_TRANSACTION_START;
alias ALPM_EVENT_TRANSACTION_DONE = alpm_event_type_t.ALPM_EVENT_TRANSACTION_DONE;
alias ALPM_EVENT_PACKAGE_OPERATION_START = alpm_event_type_t.ALPM_EVENT_PACKAGE_OPERATION_START;
alias ALPM_EVENT_PACKAGE_OPERATION_DONE = alpm_event_type_t.ALPM_EVENT_PACKAGE_OPERATION_DONE;
alias ALPM_EVENT_INTEGRITY_START = alpm_event_type_t.ALPM_EVENT_INTEGRITY_START;
alias ALPM_EVENT_INTEGRITY_DONE = alpm_event_type_t.ALPM_EVENT_INTEGRITY_DONE;
alias ALPM_EVENT_LOAD_START = alpm_event_type_t.ALPM_EVENT_LOAD_START;
alias ALPM_EVENT_LOAD_DONE = alpm_event_type_t.ALPM_EVENT_LOAD_DONE;
alias ALPM_EVENT_SCRIPTLET_INFO = alpm_event_type_t.ALPM_EVENT_SCRIPTLET_INFO;
alias ALPM_EVENT_DB_RETRIEVE_START = alpm_event_type_t.ALPM_EVENT_DB_RETRIEVE_START;
alias ALPM_EVENT_DB_RETRIEVE_DONE = alpm_event_type_t.ALPM_EVENT_DB_RETRIEVE_DONE;
alias ALPM_EVENT_DB_RETRIEVE_FAILED = alpm_event_type_t.ALPM_EVENT_DB_RETRIEVE_FAILED;
alias ALPM_EVENT_PKG_RETRIEVE_START = alpm_event_type_t.ALPM_EVENT_PKG_RETRIEVE_START;
alias ALPM_EVENT_PKG_RETRIEVE_DONE = alpm_event_type_t.ALPM_EVENT_PKG_RETRIEVE_DONE;
alias ALPM_EVENT_PKG_RETRIEVE_FAILED = alpm_event_type_t.ALPM_EVENT_PKG_RETRIEVE_FAILED;
alias ALPM_EVENT_DISKSPACE_START = alpm_event_type_t.ALPM_EVENT_DISKSPACE_START;
alias ALPM_EVENT_DISKSPACE_DONE = alpm_event_type_t.ALPM_EVENT_DISKSPACE_DONE;
alias ALPM_EVENT_OPTDEP_REMOVAL = alpm_event_type_t.ALPM_EVENT_OPTDEP_REMOVAL;
alias ALPM_EVENT_DATABASE_MISSING = alpm_event_type_t.ALPM_EVENT_DATABASE_MISSING;
alias ALPM_EVENT_KEYRING_START = alpm_event_type_t.ALPM_EVENT_KEYRING_START;
alias ALPM_EVENT_KEYRING_DONE = alpm_event_type_t.ALPM_EVENT_KEYRING_DONE;
alias ALPM_EVENT_KEY_DOWNLOAD_START = alpm_event_type_t.ALPM_EVENT_KEY_DOWNLOAD_START;
alias ALPM_EVENT_KEY_DOWNLOAD_DONE = alpm_event_type_t.ALPM_EVENT_KEY_DOWNLOAD_DONE;
alias ALPM_EVENT_PACNEW_CREATED = alpm_event_type_t.ALPM_EVENT_PACNEW_CREATED;
alias ALPM_EVENT_PACSAVE_CREATED = alpm_event_type_t.ALPM_EVENT_PACSAVE_CREATED;
alias ALPM_EVENT_HOOK_START = alpm_event_type_t.ALPM_EVENT_HOOK_START;
alias ALPM_EVENT_HOOK_DONE = alpm_event_type_t.ALPM_EVENT_HOOK_DONE;
alias ALPM_EVENT_HOOK_RUN_START = alpm_event_type_t.ALPM_EVENT_HOOK_RUN_START;
alias ALPM_EVENT_HOOK_RUN_DONE = alpm_event_type_t.ALPM_EVENT_HOOK_RUN_DONE;


/** An event that may represent any event. */
struct alpm_event_any_t {
	/** Type of event */
	alpm_event_type_t type;
}

/** An enum over the kind of package operations. */
enum alpm_package_operation_t {
	/** Package (to be) installed. (No oldpkg) */
	ALPM_PACKAGE_INSTALL = 1,
	/** Package (to be) upgraded */
	ALPM_PACKAGE_UPGRADE,
	/** Package (to be) re-installed */
	ALPM_PACKAGE_REINSTALL,
	/** Package (to be) downgraded */
	ALPM_PACKAGE_DOWNGRADE,
	/** Package (to be) removed (No newpkg) */
	ALPM_PACKAGE_REMOVE
}
alias ALPM_PACKAGE_INSTALL = alpm_package_operation_t.ALPM_PACKAGE_INSTALL;
alias ALPM_PACKAGE_UPGRADE = alpm_package_operation_t.ALPM_PACKAGE_UPGRADE;
alias ALPM_PACKAGE_REINSTALL = alpm_package_operation_t.ALPM_PACKAGE_REINSTALL;
alias ALPM_PACKAGE_DOWNGRADE = alpm_package_operation_t.ALPM_PACKAGE_DOWNGRADE;
alias ALPM_PACKAGE_REMOVE = alpm_package_operation_t.ALPM_PACKAGE_REMOVE;


/** A package operation event occurred. */
struct alpm_event_package_operation_t {
	/** Type of event */
	alpm_event_type_t type;
	/** Type of operation */
	alpm_package_operation_t operation;
	/** Old package */
	AlpmPkg oldpkg;
	/** New package */
	AlpmPkg newpkg;
}

/** An optional dependency was removed. */
struct alpm_event_optdep_removal_t {
	/** Type of event */
	alpm_event_type_t type;
	/** Package with the optdep */
	AlpmPkg pkg;
	/** Optdep being removed */
	alpm_depend_t* optdep;
}

/** A scriptlet was ran. */
struct alpm_event_scriptlet_info_t {
	/** Type of event */
	alpm_event_type_t type;
	/** Line of scriptlet output */
	const(char)* line;
}


/** A database is missing.
 *
 * The database is registered but has not been downloaded
 */
struct alpm_event_database_missing_t {
	/** Type of event */
	alpm_event_type_t type;
	/** Name of the database */
	const(char)* dbname;
}

/** A package was downloaded. */
struct alpm_event_pkgdownload_t {
	/** Type of event */
	alpm_event_type_t type;
	/** Name of the file */
	const(char)* file;
}

/** A pacnew file was created. */
struct alpm_event_pacnew_created_t {
	/** Type of event */
	alpm_event_type_t type;
	/** Whether the creation was result of a NoUpgrade or not */
	int from_noupgrade;
	/** Old package */
	AlpmPkg oldpkg;
	/** New Package */
	AlpmPkg newpkg;
	/** Filename of the file without the .pacnew suffix */
	const(char)* file;
}

/** A pacsave file was created. */
struct alpm_event_pacsave_created_t {
	/** Type of event */
	alpm_event_type_t type;
	/** Old package */
	AlpmPkg oldpkg;
	/** Filename of the file without the .pacsave suffix */
	const(char)* file;
}

/** Kind of hook. */
enum alpm_hook_when_t {
	/* Pre transaction hook */
	ALPM_HOOK_PRE_TRANSACTION = 1,
	/* Post transaction hook */
	ALPM_HOOK_POST_TRANSACTION
}
alias ALPM_HOOK_PRE_TRANSACTION = alpm_hook_when_t.ALPM_HOOK_PRE_TRANSACTION;
alias ALPM_HOOK_POST_TRANSACTION = alpm_hook_when_t.ALPM_HOOK_POST_TRANSACTION;


/** pre/post transaction hooks are to be ran. */
struct alpm_event_hook_t {
	/** Type of event*/
	alpm_event_type_t type;
	/** Type of hook */
	alpm_hook_when_t when;
}

/** A pre/post transaction hook was ran. */
struct alpm_event_hook_run_t {
	/** Type of event */
	alpm_event_type_t type;
	/** Name of hook */
	const(char)* name;
	/** Description of hook to be outputted */
	const(char)* desc;
	/** position of hook being run */
	size_t position;
	/** total hooks being run */
	size_t total;
}

/** Packages downloading about to start. */
struct alpm_event_pkg_retrieve_t {
	/** Type of event */
	alpm_event_type_t type;
	/** Number of packages to download */
	size_t num;
	/** Total size of packages to download */
	off_t total_size;
}

/** Events.
 * This is a union passed to the callback that allows the frontend to know
 * which type of event was triggered (via type). It is then possible to
 * typecast the pointer to the right structure, or use the union field, in order
 * to access event-specific data. */
union alpm_event_t {
	/** Type of event it's always safe to access this. */
	alpm_event_type_t type;
	/** The any event type. It's always safe to access this. */
	alpm_event_any_t any;
	/** Package operation */
	alpm_event_package_operation_t package_operation;
	/** An optdept was remove */
	alpm_event_optdep_removal_t optdep_removal;
	/** A scriptlet was ran */
	alpm_event_scriptlet_info_t scriptlet_info;
	/** A database is missing */
	alpm_event_database_missing_t database_missing;
	/** A package was downloaded */
	alpm_event_pkgdownload_t pkgdownload;
	/** A pacnew file was created */
	alpm_event_pacnew_created_t pacnew_created;
	/** A pacsave file was created */
	alpm_event_pacsave_created_t pacsave_created;
	/** Pre/post transaction hooks are being ran */
	alpm_event_hook_t hook;
	/** A hook was ran */
	alpm_event_hook_run_t hook_run;
	/** Download packages */
	alpm_event_pkg_retrieve_t pkg_retrieve;
}

/** Event callback.
 *
 * Called when an event occurs
 * @param ctx user-provided context
 * @param event the event that occurred */
alias alpm_cb_event = void function(void* ctx, alpm_event_t* event);

/**
 * Type of question.
 * Unlike the events or progress enumerations, this enum has bitmask values
 * so a frontend can use a bitmask map to supply preselected answers to the
 * different types of questions.
 */
enum alpm_question_type_t {
	/** Should target in ignorepkg be installed anyway? */
	ALPM_QUESTION_INSTALL_IGNOREPKG = (1 << 0),
	/** Should a package be replaced? */
	ALPM_QUESTION_REPLACE_PKG = (1 << 1),
	/** Should a conflicting package be removed? */
	ALPM_QUESTION_CONFLICT_PKG = (1 << 2),
	/** Should a corrupted package be deleted? */
	ALPM_QUESTION_CORRUPTED_PKG = (1 << 3),
	/** Should unresolvable targets be removed from the transaction? */
	ALPM_QUESTION_REMOVE_PKGS = (1 << 4),
	/** Provider selection */
	ALPM_QUESTION_SELECT_PROVIDER = (1 << 5),
	/** Should a key be imported? */
	ALPM_QUESTION_IMPORT_KEY = (1 << 6)
}
alias ALPM_QUESTION_INSTALL_IGNOREPKG = alpm_question_type_t.ALPM_QUESTION_INSTALL_IGNOREPKG;
alias ALPM_QUESTION_REPLACE_PKG = alpm_question_type_t.ALPM_QUESTION_REPLACE_PKG;
alias ALPM_QUESTION_CONFLICT_PKG = alpm_question_type_t.ALPM_QUESTION_CONFLICT_PKG;
alias ALPM_QUESTION_CORRUPTED_PKG = alpm_question_type_t.ALPM_QUESTION_CORRUPTED_PKG;
alias ALPM_QUESTION_REMOVE_PKGS = alpm_question_type_t.ALPM_QUESTION_REMOVE_PKGS;
alias ALPM_QUESTION_SELECT_PROVIDER = alpm_question_type_t.ALPM_QUESTION_SELECT_PROVIDER;
alias ALPM_QUESTION_IMPORT_KEY = alpm_question_type_t.ALPM_QUESTION_IMPORT_KEY;


/** A question that can represent any other question. */
struct alpm_question_any_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer */
	int answer;
}

/** Should target in ignorepkg be installed anyway? */
struct alpm_question_install_ignorepkg_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to install pkg anyway */
	int install;
	/** The ignored package that we are deciding whether to install */
	AlpmPkg pkg;
}

/** Should a package be replaced? */
struct alpm_question_replace_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to replace oldpkg with newpkg */
	int replace;
	/** Package to be replaced */
	AlpmPkg oldpkg;
	/** Package to replace with.*/
	AlpmPkg newpkg;
	/** DB of newpkg */
	AlpmDB newdb;
}

/** Should a conflicting package be removed? */
struct alpm_question_conflict_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to remove conflict->package2 */
	int remove;
	/** Conflict info */
	alpm_conflict_t* conflict;
}

/** Should a corrupted package be deleted? */
struct alpm_question_corrupted_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to remove filepath */
	int remove;
	/** File to remove */
	const(char)* filepath;
	/** Error code indicating the reason for package invalidity */
	alpm_errno_t reason;
}

/** Should unresolvable targets be removed from the transaction? */
struct alpm_question_remove_pkgs_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to skip packages */
	int skip;
	/** List of AlpmPkg with unresolved dependencies */
	alpm_list_t* packages;
}

/** Provider selection */
struct alpm_question_select_provider_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: which provider to use (index from providers) */
	int use_index;
	/** List of AlpmPkg as possible providers */
	alpm_list_t* providers;
	/** What providers provide for */
	alpm_depend_t* depend;
}

/** Should a key be imported? */
struct alpm_question_import_key_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to import key */
	int import_;
	/** UID of the key to import */
	const(char)* uid;
	/** Fingerprint the key to import */
	const(char)* fingerprint;
}

/**
 * Questions.
 * This is an union passed to the callback that allows the frontend to know
 * which type of question was triggered (via type). It is then possible to
 * typecast the pointer to the right structure, or use the union field, in order
 * to access question-specific data. */
union alpm_question_t {
	/** The type of question. It's always safe to access this. */
	alpm_question_type_t type;
	/** A question that can represent any question.
	 * It's always safe to access this. */
	alpm_question_any_t any;
	/** Should target in ignorepkg be installed anyway? */
	alpm_question_install_ignorepkg_t install_ignorepkg;
	/** Should a package be replaced? */
	alpm_question_replace_t replace;
	/** Should a conflicting package be removed? */
	alpm_question_conflict_t conflict;
	/** Should a corrupted package be deleted? */
	alpm_question_corrupted_t corrupted;
	/** Should unresolvable targets be removed from the transaction? */
	alpm_question_remove_pkgs_t remove_pkgs;
	/** Provider selection */
	alpm_question_select_provider_t select_provider;
	/** Should a key be imported? */
	alpm_question_import_key_t import_key;
}

/** Question callback.
 *
 * This callback allows user to give input and decide what to do during certain events
 * @param ctx user-provided context
 * @param question the question being asked.
 */
alias alpm_cb_question = void function(void* ctx, alpm_question_t* question);

/** An enum over different kinds of progress alerts. */
enum alpm_progress_t {
	/** Package install */
	ALPM_PROGRESS_ADD_START,
	/** Package upgrade */
	ALPM_PROGRESS_UPGRADE_START,
	/** Package downgrade */
	ALPM_PROGRESS_DOWNGRADE_START,
	/** Package reinstall */
	ALPM_PROGRESS_REINSTALL_START,
	/** Package removal */
	ALPM_PROGRESS_REMOVE_START,
	/** Conflict checking */
	ALPM_PROGRESS_CONFLICTS_START,
	/** Diskspace checking */
	ALPM_PROGRESS_DISKSPACE_START,
	/** Package Integrity checking */
	ALPM_PROGRESS_INTEGRITY_START,
	/** Loading packages from disk */
	ALPM_PROGRESS_LOAD_START,
	/** Checking signatures of packages */
	ALPM_PROGRESS_KEYRING_START
}
alias ALPM_PROGRESS_ADD_START = alpm_progress_t.ALPM_PROGRESS_ADD_START;
alias ALPM_PROGRESS_UPGRADE_START = alpm_progress_t.ALPM_PROGRESS_UPGRADE_START;
alias ALPM_PROGRESS_DOWNGRADE_START = alpm_progress_t.ALPM_PROGRESS_DOWNGRADE_START;
alias ALPM_PROGRESS_REINSTALL_START = alpm_progress_t.ALPM_PROGRESS_REINSTALL_START;
alias ALPM_PROGRESS_REMOVE_START = alpm_progress_t.ALPM_PROGRESS_REMOVE_START;
alias ALPM_PROGRESS_CONFLICTS_START = alpm_progress_t.ALPM_PROGRESS_CONFLICTS_START;
alias ALPM_PROGRESS_DISKSPACE_START = alpm_progress_t.ALPM_PROGRESS_DISKSPACE_START;
alias ALPM_PROGRESS_INTEGRITY_START = alpm_progress_t.ALPM_PROGRESS_INTEGRITY_START;
alias ALPM_PROGRESS_LOAD_START = alpm_progress_t.ALPM_PROGRESS_LOAD_START;
alias ALPM_PROGRESS_KEYRING_START = alpm_progress_t.ALPM_PROGRESS_KEYRING_START;


/** Progress callback
 *
 * Alert the front end about the progress of certain events.
 * Allows the implementation of loading bars for events that
 * make take a while to complete.
 * @param ctx user-provided context
 * @param progress the kind of event that is progressing
 * @param pkg for package operations, the name of the package being operated on
 * @param percent the percent completion of the action
 * @param howmany the total amount of items in the action
 * @param current the current amount of items completed
 */
/** Progress callback */
alias alpm_cb_progress = void function(void* ctx, alpm_progress_t progress, const(char)* pkg, int percent, size_t howmany, size_t current);

/*
 * Downloading
 */

/** File download events.
 * These events are reported by ALPM via download callback.
 */
enum alpm_download_event_type_t {
	/** A download was started */
	ALPM_DOWNLOAD_INIT,
	/** A download made progress */
	ALPM_DOWNLOAD_PROGRESS,
	/** Download will be retried */
	ALPM_DOWNLOAD_RETRY,
	/** A download completed */
	ALPM_DOWNLOAD_COMPLETED
}
alias ALPM_DOWNLOAD_INIT = alpm_download_event_type_t.ALPM_DOWNLOAD_INIT;
alias ALPM_DOWNLOAD_PROGRESS = alpm_download_event_type_t.ALPM_DOWNLOAD_PROGRESS;
alias ALPM_DOWNLOAD_RETRY = alpm_download_event_type_t.ALPM_DOWNLOAD_RETRY;
alias ALPM_DOWNLOAD_COMPLETED = alpm_download_event_type_t.ALPM_DOWNLOAD_COMPLETED;


/** Context struct for when a download starts. */
struct alpm_download_event_init_t {
	/** whether this file is optional and thus the errors could be ignored */
	int optional;
}

/** Context struct for when a download progresses. */
struct alpm_download_event_progress_t {
	/** Amount of data downloaded */
	off_t downloaded;
	/** Total amount need to be downloaded */
	off_t total;
}

/** Context struct for when a download retries. */
struct alpm_download_event_retry_t {
	/** If the download will resume or start over */
	int resume;
}

/** Context struct for when a download completes. */
struct alpm_download_event_completed_t {
	/** Total bytes in file */
	off_t total;
	/** download result code:
	 *    0 - download completed successfully
	 *    1 - the file is up-to-date
	 *   -1 - error
	 */
	int result;
}

/** Type of download progress callbacks.
 * @param ctx user-provided context
 * @param filename the name of the file being downloaded
 * @param event the event type
 * @param data the event data of type alpm_download_event_*_t
 */
alias alpm_cb_download = void function(void* ctx, const(char)* filename, alpm_download_event_type_t event, void* data);


/** A callback for downloading files
 * @param ctx user-provided context
 * @param url the URL of the file to be downloaded
 * @param localpath the directory to which the file should be downloaded
 * @param force whether to force an update, even if the file is the same
 * @return 0 on success, 1 if the file exists and is identical, -1 on
 * error.
 */
alias alpm_cb_fetch = int function(void* ctx, const(char)* url, const(char)* localpath, int force);

/* End of libalpm_cb */
/** @} */


/** @addtogroup libalpm_databases Database
 * @brief Functions to query and manipulate the database of libalpm.
 * @{
 */

/** Get the database of locally installed packages.
 * The returned pointer points to an internal structure
 * of libalpm which should only be manipulated through
 * libalpm functions.
 * @return a reference to the local database
 */
AlpmDB alpm_get_localdb(AlpmHandle handle);

/** Get the list of sync databases.
 * Returns a list of alpm_db_t structures, one for each registered
 * sync database.
 *
 * @param handle the context handle
 * @return a reference to an internal list of alpm_db_t structures
 */
alpm_list_t* alpm_get_syncdbs(AlpmHandle handle);

/** Register a sync database of packages.
 * Databases can not be registered when there is an active transaction.
 *
 * @param handle the context handle
 * @param treename the name of the sync repository
 * @param level what level of signature checking to perform on the
 * database; note that this must be a '.sig' file type verification
 * @return an AlpmDB on success (the value), NULL on error
 */
AlpmDB alpm_register_syncdb(AlpmHandle handle, const(char)* treename, int level);

/** Unregister all package databases.
 * Databases can not be unregistered while there is an active transaction.
 *
 * @param handle the context handle
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_unregister_all_syncdbs(AlpmHandle handle);

/** Unregister a package database.
 * Databases can not be unregistered when there is an active transaction.
 *
 * @param db pointer to the package database to unregister
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_db_unregister(AlpmDB db);

/** Get the handle of a package database.
 * @param db pointer to the package database
 * @return the alpm handle that the package database belongs to
 */
AlpmHandle alpm_db_get_handle(AlpmDB db);

/** Get the name of a package database.
 * @param db pointer to the package database
 * @return the name of the package database, NULL on error
 */
const(char)* alpm_db_get_name( AlpmDB db);

/** Check the validity of a database.
 * This is most useful for sync databases and verifying signature status.
 * If invalid, the handle error code will be set accordingly.
 * @param db pointer to the package database
 * @return 0 if valid, -1 if invalid (pm_errno is set accordingly)
 */
int alpm_db_get_valid(AlpmDB db);

/** @name Server accessors
 * @{
 */

/** Get the list of servers assigned to this db.
 * @param db pointer to the database to get the servers from
 * @return a char* list of servers
 */
alpm_list_t* alpm_db_get_servers( AlpmDB db);

/** Sets the list of servers for the database to use.
 * @param db the database to set the servers. The list will be duped and
 * the original will still need to be freed by the caller.
 * @param servers a char* list of servers.
 */
int alpm_db_set_servers(AlpmDB db, alpm_list_t* servers);

/** Add a download server to a database.
 * @param db database pointer
 * @param url url of the server
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_db_add_server(AlpmDB db, const(char)* url);

/** Remove a download server from a database.
 * @param db database pointer
 * @param url url of the server
 * @return 0 on success, 1 on server not present,
 * -1 on error (pm_errno is set accordingly)
 */
int alpm_db_remove_server(AlpmDB db, const(char)* url);

/** Get the list of cache servers assigned to this db.
 * @param db pointer to the database to get the servers from
 * @return a char* list of servers
 */
alpm_list_t* alpm_db_get_cache_servers( AlpmDB db);

/** Sets the list of cache servers for the database to use.
 * @param db the database to set the servers. The list will be duped and
 * the original will still need to be freed by the caller.
 * @param servers a char* list of servers.
 */
int alpm_db_set_cache_servers(AlpmDB db, alpm_list_t* servers);

/** Add a download cache server to a database.
 * @param db database pointer
 * @param url url of the server
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_db_add_cache_server(AlpmDB db, const(char)* url);

/** Remove a download cache server from a database.
 * @param db database pointer
 * @param url url of the server
 * @return 0 on success, 1 on server not present,
 * -1 on error (pm_errno is set accordingly)
 */
int alpm_db_remove_cache_server(AlpmDB db, const(char)* url);

/* End of server accessors */
/** @} */

/** Update package databases.
 *
 * An update of the package databases in the list \a dbs will be attempted.
 * Unless \a force is true, the update will only be performed if the remote
 * databases were modified since the last update.
 *
 * This operation requires a database lock, and will return an applicable error
 * if the lock could not be obtained.
 *
 * Example:
 * @code
 * alpm_list_t *dbs = alpm_get_syncdbs(config->handle);
 * ret = alpm_db_update(config->handle, dbs, force);
 * if(ret < 0) {
 *     pm_printf(ALPM_LOG_ERROR, ("failed to synchronize all databases (%s)\n"),
 *         alpm_strerror(alpm_errno(config->handle)));
 * }
 * @endcode
 *
 * @note After a successful update, the \link alpm_db_get_pkgcache()
 * package cache \endlink will be invalidated
 * @param handle the context handle
 * @param dbs list of package databases to update
 * @param force if true, then forces the update, otherwise update only in case
 * the databases aren't up to date
 * @return 0 on success, -1 on error (pm_errno is set accordingly),
 * 1 if all databases are up to to date
 */
int alpm_db_update(AlpmHandle handle, alpm_list_t* dbs, int force);

/** Get the group cache of a package database.
 * @param db pointer to the package database to get the group from
 * @return the list of groups on success, NULL on error
 */
alpm_list_t* alpm_db_get_groupcache(AlpmDB db);

/** Searches a database with regular expressions.
 * @param db pointer to the package database to search in
 * @param needles a list of regular expressions to search for
 * @param ret pointer to list for storing packages matching all
 * regular expressions - must point to an empty (NULL) alpm_list_t *.
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_db_search(AlpmDB db, alpm_list_t* needles, alpm_list_t** ret);

/** The usage level of a database. */
enum alpm_db_usage_t {
       /** Enable refreshes for this database */
       ALPM_DB_USAGE_SYNC = 1,
       /** Enable search for this database */
       ALPM_DB_USAGE_SEARCH = (1 << 1),
       /** Enable installing packages from this database */
       ALPM_DB_USAGE_INSTALL = (1 << 2),
       /** Enable sysupgrades with this database */
       ALPM_DB_USAGE_UPGRADE = (1 << 3),
       /** Enable all usage levels */
       ALPM_DB_USAGE_ALL = (1 << 4) - 1,
}
alias ALPM_DB_USAGE_SYNC = alpm_db_usage_t.ALPM_DB_USAGE_SYNC;
alias ALPM_DB_USAGE_SEARCH = alpm_db_usage_t.ALPM_DB_USAGE_SEARCH;
alias ALPM_DB_USAGE_INSTALL = alpm_db_usage_t.ALPM_DB_USAGE_INSTALL;
alias ALPM_DB_USAGE_UPGRADE = alpm_db_usage_t.ALPM_DB_USAGE_UPGRADE;
alias ALPM_DB_USAGE_ALL = alpm_db_usage_t.ALPM_DB_USAGE_ALL;


/** @name Usage accessors
 * @{
 */

/** Sets the usage of a database.
 * @param db pointer to the package database to set the status for
 * @param usage a bitmask of alpm_db_usage_t values
 * @return 0 on success, or -1 on error
 */
int alpm_db_set_usage(AlpmDB db, int usage);

/** Gets the usage of a database.
 * @param db pointer to the package database to get the status of
 * @param usage pointer to an alpm_db_usage_t to store db's status
 * @return 0 on success, or -1 on error
 */
int alpm_db_get_usage(AlpmDB db, int* usage);

/* End of usage accessors */
/** @} */


/* End of libalpm_databases */
/** @} */


/** \addtogroup libalpm_log Logging Functions
 * @brief Functions to log using libalpm
 * @{
 */

/** Logging Levels */
enum alpm_loglevel_t {
       /** Error */
       ALPM_LOG_ERROR    = 1,
       /** Warning */
       ALPM_LOG_WARNING  = (1 << 1),
       /** Debug */
       ALPM_LOG_DEBUG    = (1 << 2),
       /** Function */
       ALPM_LOG_FUNCTION = (1 << 3)
}
alias ALPM_LOG_ERROR = alpm_loglevel_t.ALPM_LOG_ERROR;
alias ALPM_LOG_WARNING = alpm_loglevel_t.ALPM_LOG_WARNING;
alias ALPM_LOG_DEBUG = alpm_loglevel_t.ALPM_LOG_DEBUG;
alias ALPM_LOG_FUNCTION = alpm_loglevel_t.ALPM_LOG_FUNCTION;



/** The callback type for logging.
 *
 * libalpm will call this function whenever something is to be logged.
 * many libalpm will produce log output. Additionally any calls to \link //alpm_logaction
 * \endlink will also call this callback.
 * @param ctx user-provided context
 * @param level the currently set loglevel
 * @param fmt the printf like format string
 * @param args printf like arguments
 */
alias alpm_cb_log = void function(void* ctx, alpm_loglevel_t level, const(char)* fmt, va_list args);

/** A printf-like function for logging.
 * @param handle the context handle
 * @param prefix caller-specific prefix for the log
 * @param fmt output format
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
// int //alpm_logaction(AlpmHandle handle, const(char)* prefix, const(char)* fmt, ...);

/* End of libalpm_log */
/** @} */


/** @addtogroup libalpm_options Options
 * Libalpm option getters and setters
 * @{
 */

/** @name Accessors for callbacks
 * @{
 */

/** Returns the callback used for logging.
 * @param handle the context handle
 * @return the currently set log callback
 */
alpm_cb_log alpm_option_get_logcb(AlpmHandle handle);

/** Returns the callback used for logging.
 * @param handle the context handle
 * @return the currently set log callback context
 */
void* alpm_option_get_logcb_ctx(AlpmHandle handle);

/** Sets the callback used for logging.
 * @param handle the context handle
 * @param cb the cb to use
 * @param ctx user-provided context to pass to cb
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_logcb(AlpmHandle handle, alpm_cb_log cb, void* ctx);

/** Returns the callback used to report download progress.
 * @param handle the context handle
 * @return the currently set download callback
 */
alpm_cb_download alpm_option_get_dlcb(AlpmHandle handle);

/** Returns the callback used to report download progress.
 * @param handle the context handle
 * @return the currently set download callback context
 */
void* alpm_option_get_dlcb_ctx(AlpmHandle handle);

/** Sets the callback used to report download progress.
 * @param handle the context handle
 * @param cb the cb to use
 * @param ctx user-provided context to pass to cb
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_dlcb(AlpmHandle handle, alpm_cb_download cb, void* ctx);

/** Returns the downloading callback.
 * @param handle the context handle
 * @return the currently set fetch callback
 */
alpm_cb_fetch alpm_option_get_fetchcb(AlpmHandle handle);

/** Returns the downloading callback.
 * @param handle the context handle
 * @return the currently set fetch callback context
 */
void* alpm_option_get_fetchcb_ctx(AlpmHandle handle);

/** Sets the downloading callback.
 * @param handle the context handle
 * @param cb the cb to use
 * @param ctx user-provided context to pass to cb
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_fetchcb(AlpmHandle handle, alpm_cb_fetch cb, void* ctx);

/** Returns the callback used for events.
 * @param handle the context handle
 * @return the currently set event callback
 */
alpm_cb_event alpm_option_get_eventcb(AlpmHandle handle);

/** Returns the callback used for events.
 * @param handle the context handle
 * @return the currently set event callback context
 */
void* alpm_option_get_eventcb_ctx(AlpmHandle handle);

/** Sets the callback used for events.
 * @param handle the context handle
 * @param cb the cb to use
 * @param ctx user-provided context to pass to cb
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_eventcb(AlpmHandle handle, alpm_cb_event cb, void* ctx);

/** Returns the callback used for questions.
 * @param handle the context handle
 * @return the currently set question callback
 */
alpm_cb_question alpm_option_get_questioncb(AlpmHandle handle);

/** Returns the callback used for questions.
 * @param handle the context handle
 * @return the currently set question callback context
 */
void* alpm_option_get_questioncb_ctx(AlpmHandle handle);

/** Sets the callback used for questions.
 * @param handle the context handle
 * @param cb the cb to use
 * @param ctx user-provided context to pass to cb
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_questioncb(AlpmHandle handle, alpm_cb_question cb, void* ctx);

/**Returns the callback used for operation progress.
 * @param handle the context handle
 * @return the currently set progress callback
 */
alpm_cb_progress alpm_option_get_progresscb(AlpmHandle handle);

/**Returns the callback used for operation progress.
 * @param handle the context handle
 * @return the currently set progress callback context
 */
void* alpm_option_get_progresscb_ctx(AlpmHandle handle);

/** Sets the callback used for operation progress.
 * @param handle the context handle
 * @param cb the cb to use
 * @param ctx user-provided context to pass to cb
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_progresscb(AlpmHandle handle, alpm_cb_progress cb, void* ctx);
/* End of callback accessors */
/** @} */


/** @name Accessors to the root directory
 *
 * The root directory is the prefix to which libalpm installs packages to.
 * Hooks and scriptlets will also be run in a chroot to ensure they behave correctly
 * in alternative roots.
 * @{
 */

/** Returns the root path. Read-only.
 * @param handle the context handle
 */
const(char)* alpm_option_get_root(AlpmHandle handle);
/* End of root accessors */
/** @} */


/** @name Accessors to the database path
 *
 * The dbpath is where libalpm stores the local db and
 * downloads sync databases.
 * @{
 */

/** Returns the path to the database directory. Read-only.
 * @param handle the context handle
 */
const(char)* alpm_option_get_dbpath(AlpmHandle handle);
/* End of dbpath accessors */
/** @} */


/** @name Accessors to the lockfile
 *
 * The lockfile is used to ensure two instances of libalpm can not write
 * to the database at the same time. The lock file is created when
 * committing a transaction and released when the transaction completes.
 * Or when calling \link alpm_unlock \endlink.
 * @{
 */

/** Get the name of the database lock file. Read-only.
 * This is the name that the lockfile would have. It does not
 * matter if the lockfile actually exists on disk.
 * @param handle the context handle
 */
const(char)* alpm_option_get_lockfile(AlpmHandle handle);
/* End of lockfile accessors */
/** @} */

/** @name Accessors to the list of package cache directories.
 *
 * This is where libalpm will store downloaded packages.
 * @{
 */

/** Gets the currently configured cachedirs,
 * @param handle the context handle
 * @return a char* list of cache directories
 */
alpm_list_t* alpm_option_get_cachedirs(AlpmHandle handle);

/** Sets the cachedirs.
 * @param handle the context handle
 * @param cachedirs a char* list of cachdirs. The list will be duped and
 * the original will still need to be freed by the caller.
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_cachedirs(AlpmHandle handle, alpm_list_t* cachedirs);

/** Append a cachedir to the configured cachedirs.
 * @param handle the context handle
 * @param cachedir the cachedir to add
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
// int alpm_option_add_cachedir(AlpmHandle handle, const(char)* cachedir);

/** Remove a cachedir from the configured cachedirs.
 * @param handle the context handle
 * @param cachedir the cachedir to remove
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_remove_cachedir(AlpmHandle handle, const(char)* cachedir);
/* End of cachedir accessors */
/** @} */


/** @name Accessors to the list of package hook directories.
 *
 * libalpm will search these directories for hooks to run. A hook in
 * a later directory will override previous hooks if they have the same name.
 * @{
 */

/** Gets the currently configured hookdirs,
 * @param handle the context handle
 * @return a char* list of hook directories
 */
alpm_list_t* alpm_option_get_hookdirs(AlpmHandle handle);

/** Sets the hookdirs.
 * @param handle the context handle
 * @param hookdirs a char* list of hookdirs. The list will be duped and
 * the original will still need to be freed by the caller.
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_hookdirs(AlpmHandle handle, alpm_list_t* hookdirs);

/** Append a hookdir to the configured hookdirs.
 * @param handle the context handle
 * @param hookdir the hookdir to add
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_add_hookdir(AlpmHandle handle, const(char)* hookdir);

/** Remove a hookdir from the configured hookdirs.
 * @param handle the context handle
 * @param hookdir the hookdir to remove
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_remove_hookdir(AlpmHandle handle, const(char)* hookdir);
/* End of hookdir accessors */
/** @} */


/** @name Accessors to the list of overwritable files.
 *
 * Normally libalpm will refuse to install a package that owns files that
 * are already on disk and not owned by that package.
 *
 * If a conflicting file matches a glob in the overwrite_files list, then no
 * conflict will be raised and libalpm will simply overwrite the file.
 * @{
 */

/** Gets the currently configured overwritable files,
 * @param handle the context handle
 * @return a char* list of overwritable file globs
 */
alpm_list_t* alpm_option_get_overwrite_files(AlpmHandle handle);

/** Sets the overwritable files.
 * @param handle the context handle
 * @param globs a char* list of overwritable file globs. The list will be duped and
 * the original will still need to be freed by the caller.
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_overwrite_files(AlpmHandle handle, alpm_list_t* globs);

/** Append an overwritable file to the configured overwritable files.
 * @param handle the context handle
 * @param glob the file glob to add
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_add_overwrite_file(AlpmHandle handle, const(char)* glob);

/** Remove a file glob from the configured overwritable files globs.
 * @note The overwritable file list contains a list of globs. The glob to
 * remove must exactly match the entry to remove. There is no glob expansion.
 * @param handle the context handle
 * @param glob the file glob to remove
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_remove_overwrite_file(AlpmHandle handle, const(char)* glob);
/* End of overwrite accessors */
/** @} */


/** @name Accessors to the log file
 *
 * This controls where libalpm will save log output to.
 * @{
 */

/** Gets the filepath to the currently set logfile.
 * @param handle the context handle
 * @return the path to the logfile
 */
const(char)* alpm_option_get_logfile(AlpmHandle handle);

/** Sets the logfile path.
 * @param handle the context handle
 * @param logfile path to the new location of the logfile
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_logfile(AlpmHandle handle, const(char)* logfile);
/* End of logfile accessors */
/** @} */


/** @name Accessors to the GPG directory
 *
 * This controls where libalpm will store GnuPG's files.
 * @{
 */

/** Returns the path to libalpm's GnuPG home directory.
 * @param handle the context handle
 * @return the path to libalpms's GnuPG home directory
 */
const(char)* alpm_option_get_gpgdir(AlpmHandle handle);

/** Sets the path to libalpm's GnuPG home directory.
 * @param handle the context handle
 * @param gpgdir the gpgdir to set
 */
int alpm_option_set_gpgdir(AlpmHandle handle, const(char)* gpgdir);
/* End of gpgdir accessors */
/** @} */


/** @name Accessors for use sandboxuser
 *
 *  This controls the user that libalpm will use for sensitive operations like
 *  downloading files.
 * @{
 */

/** Returns the user to switch to for sensitive operations.
 * @return the user name
 */
const(char)* alpm_option_get_sandboxuser(AlpmHandle handle);

/** Sets the user to switch to for sensitive operations.
 * @param handle the context handle
 * @param sandboxuser the user to set
 */
int alpm_option_set_sandboxuser(AlpmHandle handle, const(char)* sandboxuser);

/* End of sandboxuser accessors */
/** @} */


/** @name Accessors for use syslog
 *
 * This controls whether libalpm will also use the syslog. Even if this option
 * is enabled, libalpm will still try to log to its log file.
 * @{
 */

/** Returns whether to use syslog (0 is FALSE, TRUE otherwise).
 * @param handle the context handle
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_get_usesyslog(AlpmHandle handle);

/** Sets whether to use syslog (0 is FALSE, TRUE otherwise).
 * @param handle the context handle
 * @param usesyslog whether to use the syslog (0 is FALSE, TRUE otherwise)
 */
int alpm_option_set_usesyslog(AlpmHandle handle, int usesyslog);
/* End of usesyslog accessors */
/** @} */


/** @name Accessors to the list of no-upgrade files.
 * These functions modify the list of files which should
 * not be updated by package installation.
 * @{
 */

/** Get the list of no-upgrade files
 * @param handle the context handle
 * @return the char* list of no-upgrade files
 */
alpm_list_t* alpm_option_get_noupgrades(AlpmHandle handle);

/** Add a file to the no-upgrade list
 * @param handle the context handle
 * @param path the path to add
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_add_noupgrade(AlpmHandle handle, const(char)* path);

/** Sets the list of no-upgrade files
 * @param handle the context handle
 * @param noupgrade a char* list of file to not upgrade.
 * The list will be duped and the original will still need to be freed by the caller.
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_noupgrades(AlpmHandle handle, alpm_list_t* noupgrade);

/** Remove an entry from the no-upgrade list
 * @param handle the context handle
 * @param path the path to remove
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_remove_noupgrade(AlpmHandle handle, const(char)* path);

/** Test if a path matches any of the globs in the no-upgrade list
 * @param handle the context handle
 * @param path the path to test
 * @return 0 is the path matches a glob, negative if there is no match and
 * positive is the  match was inverted
 */
int alpm_option_match_noupgrade(AlpmHandle handle, const(char)* path);
/* End of noupgrade accessors */
/** @} */


/** @name Accessors to the list of no-extract files.
 * These functions modify the list of filenames which should
 * be skipped packages which should
 * not be upgraded by a sysupgrade operation.
 * @{
 */

/** Get the list of no-extract files
 * @param handle the context handle
 * @return the char* list of no-extract files
 */
alpm_list_t* alpm_option_get_noextracts(AlpmHandle handle);

/** Add a file to the no-extract list
 * @param handle the context handle
 * @param path the path to add
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_add_noextract(AlpmHandle handle, const(char)* path);

/** Sets the list of no-extract files
 * @param handle the context handle
 * @param noextract a char* list of file to not extract.
 * The list will be duped and the original will still need to be freed by the caller.
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_noextracts(AlpmHandle handle, alpm_list_t* noextract);

/** Remove an entry from the no-extract list
 * @param handle the context handle
 * @param path the path to remove
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_remove_noextract(AlpmHandle handle, const(char)* path);

/** Test if a path matches any of the globs in the no-extract list
 * @param handle the context handle
 * @param path the path to test
 * @return 0 is the path matches a glob, negative if there is no match and
 * positive is the  match was inverted
 */
// int alpm_option_match_noextract(AlpmHandle handle, const(char)* path);
/* End of noextract accessors */
/** @} */


/** @name Accessors to the list of ignored packages.
 * These functions modify the list of packages that
 * should be ignored by a sysupgrade.
 *
 * Entries in this list may be globs and only match the package's
 * name. Providers are not taken into account.
 * @{
 */

/** Get the list of ignored packages
 * @param handle the context handle
 * @return the char* list of ignored packages
 */
alpm_list_t* alpm_option_get_ignorepkgs(AlpmHandle handle);

/** Add a file to the ignored package list
 * @param handle the context handle
 * @param pkg the package to add
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_add_ignorepkg(AlpmHandle handle, const(char)* pkg);

/** Sets the list of packages to ignore
 * @param handle the context handle
 * @param ignorepkgs a char* list of packages to ignore
 * The list will be duped and the original will still need to be freed by the caller.
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_ignorepkgs(AlpmHandle handle, alpm_list_t* ignorepkgs);

/** Remove an entry from the ignorepkg list
 * @param handle the context handle
 * @param pkg the package to remove
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_remove_ignorepkg(AlpmHandle handle, const(char)* pkg);
/* End of ignorepkg accessors */
/** @} */


/** @name Accessors to the list of ignored groups.
 * These functions modify the list of groups whose packages
 * should be ignored by a sysupgrade.
 *
 * Entries in this list may be globs.
 * @{
 */

/** Get the list of ignored groups
 * @param handle the context handle
 * @return the char* list of ignored groups
 */
alpm_list_t* alpm_option_get_ignoregroups(AlpmHandle handle);

/** Add a file to the ignored group list
 * @param handle the context handle
 * @param grp the group to add
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_add_ignoregroup(AlpmHandle handle, const(char)* grp);

/** Sets the list of groups to ignore
 * @param handle the context handle
 * @param ignoregrps a char* list of groups to ignore
 * The list will be duped and the original will still need to be freed by the caller.
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_ignoregroups(AlpmHandle handle, alpm_list_t* ignoregrps);

/** Remove an entry from the ignoregroup list
 * @param handle the context handle
 * @param grp the group to remove
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_remove_ignoregroup(AlpmHandle handle, const(char)* grp);
/* End of ignoregroup accessors */
/** @} */


/** @name Accessors to the list of ignored dependencies.
 * These functions modify the list of dependencies that
 * should be ignored by a sysupgrade.
 *
 * This is effectively a list of virtual providers that
 * packages can use to satisfy their dependencies.
 * @{
 */

/** Gets the list of dependencies that are assumed to be met
 * @param handle the context handle
 * @return a list of alpm_depend_t*
 */
alpm_list_t* alpm_option_get_assumeinstalled(AlpmHandle handle);

/** Add a depend to the assumed installed list
 * @param handle the context handle
 * @param dep the dependency to add
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_add_assumeinstalled(AlpmHandle handle, alpm_depend_t* dep);

/** Sets the list of dependencies that are assumed to be met
 * @param handle the context handle
 * @param deps a list of *alpm_depend_t
 * The list will be duped and the original will still need to be freed by the caller.
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_assumeinstalled(AlpmHandle handle, alpm_list_t* deps);

/** Remove an entry from the assume installed list
 * @param handle the context handle
 * @param dep the dep to remove
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_remove_assumeinstalled(AlpmHandle handle, alpm_depend_t* dep);
/* End of assunmeinstalled accessors */
/** @} */


/** @name Accessors to the list of allowed architectures.
 * libalpm will only install packages that match one of the configured
 * architectures. The architectures do not need to match the physical
   architecture. They can just be treated as a label.
 * @{
 */

/** Returns the allowed package architecture.
 * @param handle the context handle
 * @return the configured package architectures
 */
alpm_list_t* alpm_option_get_architectures(AlpmHandle handle);

/** Adds an allowed package architecture.
 * @param handle the context handle
 * @param arch the architecture to set
 */
int alpm_option_add_architecture(AlpmHandle handle, const(char)* arch);

/** Sets the allowed package architecture.
 * @param handle the context handle
 * @param arches the architecture to set
 */
int alpm_option_set_architectures(AlpmHandle handle, alpm_list_t* arches);

/** Removes an allowed package architecture.
 * @param handle the context handle
 * @param arch the architecture to remove
 */
int alpm_option_remove_architecture(AlpmHandle handle, const(char)* arch);

/* End of arch accessors */
/** @} */


/** @name Accessors for check space.
 *
 * This controls whether libalpm will check if there is sufficient before
 * installing packages.
 * @{
 */

/** Get whether or not checking for free space before installing packages is enabled.
 * @param handle the context handle
 * @return 0 if disabled, 1 if enabled
 */
int alpm_option_get_checkspace(AlpmHandle handle);

/** Enable/disable checking free space before installing packages.
 * @param handle the context handle
 * @param checkspace 0 for disabled, 1 for enabled
 */
int alpm_option_set_checkspace(AlpmHandle handle, int checkspace);
/* End of checkspace accessors */
/** @} */


/** @name Accessors for the database extension
 *
 * This controls the extension used for sync databases. libalpm will use this
 * extension to both lookup remote databases and as the name used when opening
 * reading them.
 *
 * This is useful for file databases. Seems as files can increase the size of
 * a database by quite a lot, a server could hold a database without files under
 * one extension, and another with files under another extension.
 *
 * Which one is downloaded and used then depends on this setting.
 * @{
 */

/** Gets the configured database extension.
 * @param handle the context handle
 * @return the configured database extension
 */
const(char)* alpm_option_get_dbext(AlpmHandle handle);

/** Sets the database extension.
 * @param handle the context handle
 * @param dbext the database extension to use
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_dbext(AlpmHandle handle, const(char)* dbext);
/* End of dbext accessors */
/** @} */


/** @name Accessors for the signature levels
 * @{
 */

/** Get the default siglevel.
 * @param handle the context handle
 * @return a \link alpm_siglevel_t \endlink bitfield of the siglevel
 */
int alpm_option_get_default_siglevel(AlpmHandle handle);

/** Set the default siglevel.
 * @param handle the context handle
 * @param level a \link alpm_siglevel_t \endlink bitfield of the level to set
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_default_siglevel(AlpmHandle handle, int level);

/** Get the configured local file siglevel.
 * @param handle the context handle
 * @return a \link alpm_siglevel_t \endlink bitfield of the siglevel
 */
int alpm_option_get_local_file_siglevel(AlpmHandle handle);

/** Set the local file siglevel.
 * @param handle the context handle
 * @param level a \link alpm_siglevel_t \endlink bitfield of the level to set
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_local_file_siglevel(AlpmHandle handle, int level);

/** Get the configured remote file siglevel.
 * @param handle the context handle
 * @return a \link alpm_siglevel_t \endlink bitfield of the siglevel
 */
// int alpm_option_get_remote_file_siglevel(AlpmHandle handle);

/** Set the remote file siglevel.
 * @param handle the context handle
 * @param level a \link alpm_siglevel_t \endlink bitfield of the level to set
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_remote_file_siglevel(AlpmHandle handle, int level);
/* End of signature accessors */
/** @} */


/** @name Accessors for download timeout
 *
 * By default, libalpm will timeout if a download has been transferring
 * less than 1 byte for 10 seconds.
 * @{
 */

/** Get the download timeout state
 * @param handle the context handle
 * @return 0 for enabled, 1 for disabled
*/
int alpm_option_get_disable_dl_timeout(AlpmHandle handle);

/** Enables/disables the download timeout.
 * @param handle the context handle
 * @param disable_dl_timeout 0 for enabled, 1 for disabled
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_disable_dl_timeout(AlpmHandle handle, ushort disable_dl_timeout);
/* End of disable_dl_timeout accessors */
/** @} */


/** @name Accessors for parallel downloads
 * \link alpm_db_update \endlink, \link alpm_fetch_pkgurl \endlink and
 * \link alpm_trans_commit \endlink can all download packages in parallel.
 * This setting configures how many packages can be downloaded in parallel,
 *
 * By default this value is set to 1, meaning packages are downloading
 * sequentially.
 *
 * @{
 */

/** Gets the number of parallel streams to download database and package files.
 * @param handle the context handle
 * @return the number of parallel streams to download database and package files
 */
int alpm_option_get_parallel_downloads(AlpmHandle handle);

/** Sets number of parallel streams to download database and package files.
 * @param handle the context handle
 * @param num_streams number of parallel download streams
 * @return 0 on success, -1 on error
 */
int alpm_option_set_parallel_downloads(AlpmHandle handle, uint num_streams);
/* End of parallel_downloads accessors */
/** @} */

/** @name Accessors for sandbox
 *
 * By default, libalpm will sandbox the downloader process.
 * @{
 */

/** Get the sandbox state
 * @param handle the context handle
 * @return 0 for enabled, 1 for disabled
 */
int alpm_option_get_disable_sandbox(AlpmHandle handle);

/** Enables/disables the sandbox.
 * @param handle the context handle
 * @param disable_sandbox 0 for enabled, 1 for disabled
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_option_set_disable_sandbox(AlpmHandle handle, ushort disable_sandbox);
/* End of disable_sandbox accessors */
/** @} */

/* End of libalpm_options */
/** @} */


/** @addtogroup libalpm_packages Package Functions
 * Functions to manipulate libalpm packages
 * @{
 */

/** Package install reasons. */
enum alpm_pkgreason_t {
	/** Explicitly requested by the user. */
	ALPM_PKG_REASON_EXPLICIT = 0,
	/** Installed as a dependency for another package. */
	ALPM_PKG_REASON_DEPEND = 1,
	/** Failed parsing of local database */
	ALPM_PKG_REASON_UNKNOWN = 2
}
alias ALPM_PKG_REASON_EXPLICIT = alpm_pkgreason_t.ALPM_PKG_REASON_EXPLICIT;
alias ALPM_PKG_REASON_DEPEND = alpm_pkgreason_t.ALPM_PKG_REASON_DEPEND;
alias ALPM_PKG_REASON_UNKNOWN = alpm_pkgreason_t.ALPM_PKG_REASON_UNKNOWN;


/** Location a package object was loaded from. */
enum alpm_pkgfrom_t {
	/** Loaded from a file via \link alpm_pkg_load \endlink */
	ALPM_PKG_FROM_FILE = 1,
	/** From the local database */
	ALPM_PKG_FROM_LOCALDB,
	/** From a sync database */
	ALPM_PKG_FROM_SYNCDB
}
alias ALPM_PKG_FROM_FILE = alpm_pkgfrom_t.ALPM_PKG_FROM_FILE;
alias ALPM_PKG_FROM_LOCALDB = alpm_pkgfrom_t.ALPM_PKG_FROM_LOCALDB;
alias ALPM_PKG_FROM_SYNCDB = alpm_pkgfrom_t.ALPM_PKG_FROM_SYNCDB;



/** Method used to validate a package. */
enum alpm_pkgvalidation_t {
	/** The package's validation type is unknown */
	ALPM_PKG_VALIDATION_UNKNOWN = 0,
	/** The package does not have any validation */
	ALPM_PKG_VALIDATION_NONE = (1 << 0),
	/** The package is validated with md5 */
	ALPM_PKG_VALIDATION_MD5SUM = (1 << 1),
	/** The package is validated with sha256 */
	ALPM_PKG_VALIDATION_SHA256SUM = (1 << 2),
	/** The package is validated with a PGP signature */
	ALPM_PKG_VALIDATION_SIGNATURE = (1 << 3)
}
alias ALPM_PKG_VALIDATION_UNKNOWN = alpm_pkgvalidation_t.ALPM_PKG_VALIDATION_UNKNOWN;
alias ALPM_PKG_VALIDATION_NONE = alpm_pkgvalidation_t.ALPM_PKG_VALIDATION_NONE;
alias ALPM_PKG_VALIDATION_MD5SUM = alpm_pkgvalidation_t.ALPM_PKG_VALIDATION_MD5SUM;
alias ALPM_PKG_VALIDATION_SHA256SUM = alpm_pkgvalidation_t.ALPM_PKG_VALIDATION_SHA256SUM;
alias ALPM_PKG_VALIDATION_SIGNATURE = alpm_pkgvalidation_t.ALPM_PKG_VALIDATION_SIGNATURE;


/** Create a package from a file.
 * If full is false, the archive is read only until all necessary
 * metadata is found. If it is true, the entire archive is read, which
 * serves as a verification of integrity and the filelist can be created.
 * The allocated structure should be freed using alpm_pkg_free().
 * @param handle the context handle
 * @param filename location of the package tarball
 * @param full whether to stop the load after metadata is read or continue
 * through the full archive
 * @param level what level of package signature checking to perform on the
 * package; note that this must be a '.sig' file type verification
 * @param pkg address of the package pointer
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_pkg_load(AlpmHandle handle, const(char)* filename, int full, int level, AlpmPkg* pkg);

/** Fetch a list of remote packages.
 * @param handle the context handle
 * @param urls list of package URLs to download
 * @param fetched list of filepaths to the fetched packages, each item
 *    corresponds to one in `urls` list. This is an output parameter,
 *    the caller should provide a pointer to an empty list
 *    (*fetched === NULL) and the callee fills the list with data.
 * @return 0 on success or -1 on failure
 */
int alpm_fetch_pkgurl(AlpmHandle handle, alpm_list_t* urls, alpm_list_t** fetched);

/** Free a package.
 * Only packages loaded with \link alpm_pkg_load \endlink can be freed.
 * Packages from databases will be freed by libalpm when they are unregistered.
 * @param pkg package pointer to free
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_pkg_free(AlpmPkg pkg);

/** Check the integrity (with md5) of a package from the sync cache.
 * @param pkg package pointer
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_pkg_checkmd5sum(AlpmPkg pkg);

/** Compare two version strings and determine which one is 'newer'.
 * Returns a value comparable to the way strcmp works. Returns 1
 * if a is newer than b, 0 if a and b are the same version, or -1
 * if b is newer than a.
 *
 * Different epoch values for version strings will override any further
 * comparison. If no epoch is provided, 0 is assumed.
 *
 * Keep in mind that the pkgrel is only compared if it is available
 * on both versions handed to this function. For example, comparing
 * 1.5-1 and 1.5 will yield 0; comparing 1.5-1 and 1.5-2 will yield
 * -1 as expected. This is mainly for supporting versioned dependencies
 * that do not include the pkgrel.
 */
int alpm_pkg_vercmp(const(char)* a, const(char)* b);

/** Computes the list of packages requiring a given package.
 * The return value of this function is a newly allocated
 * list of package names (char*), it should be freed by the caller.
 * @param pkg a package
 * @return the list of packages requiring pkg
 */
alpm_list_t* alpm_pkg_compute_requiredby(AlpmPkg pkg);

/** Computes the list of packages optionally requiring a given package.
 * The return value of this function is a newly allocated
 * list of package names (char*), it should be freed by the caller.
 * @param pkg a package
 * @return the list of packages optionally requiring pkg
 */
alpm_list_t* alpm_pkg_compute_optionalfor(AlpmPkg pkg);

/** @name Package Property Accessors
 * Any pointer returned by these functions points to internal structures
 * allocated by libalpm. They should not be freed nor modified in any
 * way.
 *
 * For loaded packages, they will be freed when \link alpm_pkg_free \endlink is called.
 * For database packages, they will be freed when the database is unregistered.
 * @{
 */

/** Gets the handle of a package
 * @param pkg a pointer to package
 * @return the alpm handle that the package belongs to
 */
AlpmHandle alpm_pkg_get_handle(AlpmPkg pkg);

/** Gets the name of the file from which the package was loaded.
 * @param pkg a pointer to package
 * @return a reference to an internal string
 */
const(char)* alpm_pkg_get_filename(AlpmPkg pkg);

/** Returns the package base name.
 * @param pkg a pointer to package
 * @return a reference to an internal string
 */
const(char)* alpm_pkg_get_base(AlpmPkg pkg);

/** Returns the package name.
 * @param pkg a pointer to package
 * @return a reference to an internal string
 */
const(char)* alpm_pkg_get_name(AlpmPkg pkg);

/** Returns the package version as a string.
 * This includes all available epoch, version, and pkgrel components. Use
 * alpm_pkg_vercmp() to compare version strings if necessary.
 * @param pkg a pointer to package
 * @return a reference to an internal string
 */
const(char)* alpm_pkg_get_version(AlpmPkg pkg);

/** Returns the origin of the package.
 * @return an alpm_pkgfrom_t constant, -1 on error
 */
alpm_pkgfrom_t alpm_pkg_get_origin(AlpmPkg pkg);

/** Returns the package URL.
 * @param pkg a pointer to package
 * @return a reference to an internal string
 */
const(char)* alpm_pkg_get_url(AlpmPkg pkg);

/** Returns the build timestamp of the package.
 * @param pkg a pointer to package
 * @return the timestamp of the build time
 */
alpm_time_t alpm_pkg_get_builddate(AlpmPkg pkg);

/** Returns the install timestamp of the package.
 * @param pkg a pointer to package
 * @return the timestamp of the install time
 */
alpm_time_t alpm_pkg_get_installdate(AlpmPkg pkg);

/** Returns the packager's name.
 * @param pkg a pointer to package
 * @return a reference to an internal string
 */
const(char)* alpm_pkg_get_packager(AlpmPkg pkg);

/** Returns the package's MD5 checksum as a string.
 * The returned string is a sequence of 32 lowercase hexadecimal digits.
 * @param pkg a pointer to package
 * @return a reference to an internal string
 */
const(char)* alpm_pkg_get_md5sum(AlpmPkg pkg);

/** Returns the package's SHA256 checksum as a string.
 * The returned string is a sequence of 64 lowercase hexadecimal digits.
 * @param pkg a pointer to package
 * @return a reference to an internal string
 */
const(char)* alpm_pkg_get_sha256sum(AlpmPkg pkg);

/** Returns the size of the package. This is only available for sync database
 * packages and package files, not those loaded from the local database.
 * @param pkg a pointer to package
 * @return the size of the package in bytes.
 */
off_t alpm_pkg_get_size(AlpmPkg pkg);

/** Returns the installed size of the package.
 * @param pkg a pointer to package
 * @return the total size of files installed by the package.
 */
off_t alpm_pkg_get_isize(AlpmPkg pkg);
/** Returns a list of package check dependencies
 * @param pkg a pointer to package
 * @return a reference to an internal list of alpm_depend_t structures.
 */
alpm_list_t* alpm_pkg_get_checkdepends(AlpmPkg pkg);

/** Returns a list of package make dependencies
 * @param pkg a pointer to package
 * @return a reference to an internal list of alpm_depend_t structures.
 */
alpm_list_t* alpm_pkg_get_makedepends(AlpmPkg pkg);

/** Returns the base64 encoded package signature.
 * @param pkg a pointer to package
 * @return a reference to an internal string
 */
const(char)* alpm_pkg_get_base64_sig(AlpmPkg pkg);

/** Extracts package signature either from embedded package signature
 * or if it is absent then reads data from detached signature file.
 * @param pkg a pointer to package.
 * @param sig output parameter for signature data. Callee function allocates
 * a buffer needed for the signature data. Caller is responsible for
 * freeing this buffer.
 * @param sig_len output parameter for the signature data length.
 * @return 0 on success, negative number on error.
 */
int alpm_pkg_get_sig(AlpmPkg pkg, ubyte** sig, size_t* sig_len);

/** Returns the method used to validate a package during install.
 * @param pkg a pointer to package
 * @return an enum member giving the validation method
 */
int alpm_pkg_get_validation(AlpmPkg pkg);

/** Gets the extended data field of a package.
 * @param pkg a pointer to package
 * @return a reference to a list of alpm_pkg_xdata_t objects
 */
alpm_list_t* alpm_pkg_get_xdata(AlpmPkg pkg);

/** Returns the size of the files that will be downloaded to install a
 * package.
 * @param newpkg the new package to upgrade to
 * @return the size of the download
 */
off_t alpm_pkg_download_size(AlpmPkg newpkg);

/** Set install reason for a package in the local database.
 * The provided package object must be from the local database or this method
 * will fail. The write to the local database is performed immediately.
 * @param pkg the package to update
 * @param reason the new install reason
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_pkg_set_reason(AlpmPkg pkg, alpm_pkgreason_t reason);


/* End of libalpm_pkg_t accessors */
/** @} */


/** @name Changelog functions
 *  Functions for reading the changelog
 * @{
 */

/** Open a package changelog for reading.
 * Similar to fopen in functionality, except that the returned 'file
 * stream' could really be from an archive as well as from the database.
 * @param pkg the package to read the changelog of (either file or db)
 * @return a 'file stream' to the package changelog
 */
void* alpm_pkg_changelog_open(AlpmPkg pkg);

/** Read data from an open changelog 'file stream'.
 * Similar to fread in functionality, this function takes a buffer and
 * amount of data to read. If an error occurs pm_errno will be set.
 * @param ptr a buffer to fill with raw changelog data
 * @param size the size of the buffer
 * @param pkg the package that the changelog is being read from
 * @param fp a 'file stream' to the package changelog
 * @return the number of characters read, or 0 if there is no more data or an
 * error occurred.
 */
size_t alpm_pkg_changelog_read(void* ptr, size_t size, AlpmPkg pkg, void* fp);

/** Close a package changelog for reading.
 * @param pkg the package to close the changelog of (either file or db)
 * @param fp the 'file stream' to the package changelog to close
 * @return 0 on success, -1 on error
 */
int alpm_pkg_changelog_close(AlpmPkg pkg, void* fp);

/* End of changelog accessors */
/** @} */


/** @name Mtree functions
 *  Functions for reading the mtree
 * @{
 */

/** Open a package mtree file for reading.
 * @param pkg the local package to read the mtree of
 * @return an archive structure for the package mtree file
 */
archive* alpm_pkg_mtree_open(AlpmPkg pkg);

/** Read next entry from a package mtree file.
 * @param pkg the package that the mtree file is being read from
 * @param archive the archive structure reading from the mtree file
 * @param entry an archive_entry to store the entry header information
 * @return 0 on success, 1 if end of archive is reached, -1 otherwise.
 */
int alpm_pkg_mtree_next(AlpmPkg pkg, archive* archive, archive_entry** entry);

/** Close a package mtree file.
 * @param pkg the local package to close the mtree of
 * @param archive the archive to close
 */
int alpm_pkg_mtree_close(AlpmPkg pkg, archive* archive);

/* End of mtree accessors */
/** @} */


/* End of libalpm_packages */
/** @} */

/** @addtogroup libalpm_trans Transaction
 * @brief Functions to manipulate libalpm transactions
 *
 * Transactions are the way to add/remove packages to/from the system.
 * Only one transaction can exist at a time.
 *
 * The basic workflow of a transaction is to:
 *
 * - Initialize with \link alpm_trans_init \endlink
 * - Choose which packages to add with \link alpm_add_pkg \endlink and \link alpm_remove_pkg \endlink
 * - Prepare the transaction with \link alpm_trans_prepare \endlink
 * - Commit the transaction with \link alpm_trans_commit \endlink
 * - Release the transaction with \link alpm_trans_release \endlink
 *
 * A transaction can be released at any time. A transaction does not have to be committed.
 * @{
 */

/** Transaction flags */
enum alpm_transflag_t {
	/** Ignore dependency checks. */
	ALPM_TRANS_FLAG_NODEPS = 1,
	/* (1 << 1) flag can go here */
	/** Delete files even if they are tagged as backup. */
	ALPM_TRANS_FLAG_NOSAVE = (1 << 2),
	/** Ignore version numbers when checking dependencies. */
	ALPM_TRANS_FLAG_NODEPVERSION = (1 << 3),
	/** Remove also any packages depending on a package being removed. */
	ALPM_TRANS_FLAG_CASCADE = (1 << 4),
	/** Remove packages and their unneeded deps (not explicitly installed). */
	ALPM_TRANS_FLAG_RECURSE = (1 << 5),
	/** Modify database but do not commit changes to the filesystem. */
	ALPM_TRANS_FLAG_DBONLY = (1 << 6),
	/** Do not run hooks during a transaction */
	ALPM_TRANS_FLAG_NOHOOKS = (1 << 7),
	/** Use ALPM_PKG_REASON_DEPEND when installing packages. */
	ALPM_TRANS_FLAG_ALLDEPS = (1 << 8),
	/** Only download packages and do not actually install. */
	ALPM_TRANS_FLAG_DOWNLOADONLY = (1 << 9),
	/** Do not execute install scriptlets after installing. */
	ALPM_TRANS_FLAG_NOSCRIPTLET = (1 << 10),
	/** Ignore dependency conflicts. */
	ALPM_TRANS_FLAG_NOCONFLICTS = (1 << 11),
	/* (1 << 12) flag can go here */
	/** Do not install a package if it is already installed and up to date. */
	ALPM_TRANS_FLAG_NEEDED = (1 << 13),
	/** Use ALPM_PKG_REASON_EXPLICIT when installing packages. */
	ALPM_TRANS_FLAG_ALLEXPLICIT = (1 << 14),
	/** Do not remove a package if it is needed by another one. */
	ALPM_TRANS_FLAG_UNNEEDED = (1 << 15),
	/** Remove also explicitly installed unneeded deps (use with ALPM_TRANS_FLAG_RECURSE). */
	ALPM_TRANS_FLAG_RECURSEALL = (1 << 16),
	/** Do not lock the database during the operation. */
	ALPM_TRANS_FLAG_NOLOCK = (1 << 17)
}
alias ALPM_TRANS_FLAG_NODEPS = alpm_transflag_t.ALPM_TRANS_FLAG_NODEPS;
alias ALPM_TRANS_FLAG_NOSAVE = alpm_transflag_t.ALPM_TRANS_FLAG_NOSAVE;
alias ALPM_TRANS_FLAG_NODEPVERSION = alpm_transflag_t.ALPM_TRANS_FLAG_NODEPVERSION;
alias ALPM_TRANS_FLAG_CASCADE = alpm_transflag_t.ALPM_TRANS_FLAG_CASCADE;
alias ALPM_TRANS_FLAG_RECURSE = alpm_transflag_t.ALPM_TRANS_FLAG_RECURSE;
alias ALPM_TRANS_FLAG_DBONLY = alpm_transflag_t.ALPM_TRANS_FLAG_DBONLY;
alias ALPM_TRANS_FLAG_NOHOOKS = alpm_transflag_t.ALPM_TRANS_FLAG_NOHOOKS;
alias ALPM_TRANS_FLAG_ALLDEPS = alpm_transflag_t.ALPM_TRANS_FLAG_ALLDEPS;
alias ALPM_TRANS_FLAG_DOWNLOADONLY = alpm_transflag_t.ALPM_TRANS_FLAG_DOWNLOADONLY;
alias ALPM_TRANS_FLAG_NOSCRIPTLET = alpm_transflag_t.ALPM_TRANS_FLAG_NOSCRIPTLET;
alias ALPM_TRANS_FLAG_NOCONFLICTS = alpm_transflag_t.ALPM_TRANS_FLAG_NOCONFLICTS;
alias ALPM_TRANS_FLAG_NEEDED = alpm_transflag_t.ALPM_TRANS_FLAG_NEEDED;
alias ALPM_TRANS_FLAG_ALLEXPLICIT = alpm_transflag_t.ALPM_TRANS_FLAG_ALLEXPLICIT;
alias ALPM_TRANS_FLAG_UNNEEDED = alpm_transflag_t.ALPM_TRANS_FLAG_UNNEEDED;
alias ALPM_TRANS_FLAG_RECURSEALL = alpm_transflag_t.ALPM_TRANS_FLAG_RECURSEALL;
alias ALPM_TRANS_FLAG_NOLOCK = alpm_transflag_t.ALPM_TRANS_FLAG_NOLOCK;


/** Returns the bitfield of flags for the current transaction.
 * @param handle the context handle
 * @return the bitfield of transaction flags
 */
int alpm_trans_get_flags(AlpmHandle handle);

/** Returns a list of packages added by the transaction.
 * @param handle the context handle
 * @return a list of alpm_pkg_t structures
 */
alpm_list_t* alpm_trans_get_add(AlpmHandle handle);

/** Returns the list of packages removed by the transaction.
 * @param handle the context handle
 * @return a list of alpm_pkg_t structures
 */
alpm_list_t* alpm_trans_get_remove(AlpmHandle handle);

/** Initialize the transaction.
 * @param handle the context handle
 * @param flags flags of the transaction (like nodeps, etc; see alpm_transflag_t)
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_trans_init(AlpmHandle handle, int flags);

/** Prepare a transaction.
 * @param handle the context handle
 * @param data the address of an alpm_list where a list
 * of alpm_depmissing_t objects is dumped (conflicting packages)
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_trans_prepare(AlpmHandle handle, alpm_list_t** data);

/** Commit a transaction.
 * @param handle the context handle
 * @param data the address of an alpm_list where detailed description
 * of an error can be dumped (i.e. list of conflicting files)
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_trans_commit(AlpmHandle handle, alpm_list_t** data);

/** Interrupt a transaction.
 * @param handle the context handle
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_trans_interrupt(AlpmHandle handle);

/** Release a transaction.
 * @param handle the context handle
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_trans_release(AlpmHandle handle);

/** @name Add/Remove packages
 * These functions remove/add packages to the transactions
 * @{
 * */

/** Search for packages to upgrade and add them to the transaction.
 * @param handle the context handle
 * @param enable_downgrade allow downgrading of packages if the remote version is lower
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_sync_sysupgrade(AlpmHandle handle, int enable_downgrade);

/** Add a package to the transaction.
 * If the package was loaded by alpm_pkg_load(), it will be freed upon
 * \link alpm_trans_release \endlink invocation.
 * @param handle the context handle
 * @param pkg the package to add
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_add_pkg(AlpmHandle handle, AlpmPkg pkg);

/** Add a package removal to the transaction.
 * @param handle the context handle
 * @param pkg the package to uninstall
 * @return 0 on success, -1 on error (pm_errno is set accordingly)
 */
int alpm_remove_pkg(AlpmHandle handle, AlpmPkg pkg);

/* End of add/remove packages */
/** @} */


/* End of libalpm_trans */
/** @} */


/** \addtogroup libalpm_misc Miscellaneous Functions
 * @brief Various libalpm functions
 * @{
 */

/** Check for new version of pkg in syncdbs.
 *
 * If the same package appears multiple dbs only the first will be checked
 *
 * This only checks the syncdb for a newer version. It does not access the network at all.
 * See \link alpm_db_update \endlink to update a database.
 */
AlpmPkg alpm_sync_get_new_version(AlpmPkg pkg, alpm_list_t* dbs_sync);

/** Get the md5 sum of file.
 * @param filename name of the file
 * @return the checksum on success, NULL on error
 */
// char* alpm_compute_md5sum(const(char)* filename);

/** Get the sha256 sum of file.
 * @param filename name of the file
 * @return the checksum on success, NULL on error
 */
char* alpm_compute_sha256sum(const(char)* filename);

/** Remove the database lock file
 * @param handle the context handle
 * @return 0 on success, -1 on error
 *
 * @note Safe to call from inside signal handlers.
 */
int alpm_unlock(AlpmHandle handle);

/** Enum of possible compile time features */
enum alpm_caps {
        /** localization */
        ALPM_CAPABILITY_NLS = (1 << 0),
        /** Ability to download */
        ALPM_CAPABILITY_DOWNLOADER = (1 << 1),
        /** Signature checking */
        ALPM_CAPABILITY_SIGNATURES = (1 << 2)
}
alias ALPM_CAPABILITY_NLS = alpm_caps.ALPM_CAPABILITY_NLS;
alias ALPM_CAPABILITY_DOWNLOADER = alpm_caps.ALPM_CAPABILITY_DOWNLOADER;
alias ALPM_CAPABILITY_SIGNATURES = alpm_caps.ALPM_CAPABILITY_SIGNATURES;


/** Get the version of library.
 * @return the library version, e.g. "6.0.4"
 * */
const(char)* alpm_version();

/** Get the capabilities of the library.
 * @return a bitmask of the capabilities
 * */
int alpm_capabilities();

/** Drop privileges by switching to a different user.
 * @param handle the context handle
 * @param sandboxuser the user to switch to
 * @param sandbox_path if non-NULL, restrict writes to this filesystem path
 * @param restrict_syscalls whether to deny access to a list of dangerous syscalls
 * @return 0 on success, -1 on failure
 */
int alpm_sandbox_setup_child(AlpmHandle handle, const(char)* sandboxuser, const(char)* sandbox_path, bool restrict_syscalls);

/* End of libalpm_misc */
/** @} */

/* End of libalpm_api */
/** @} */

 /* ALPM_H */

/** Checks dependencies and returns missing ones in a list.
 * Dependencies can include versions with depmod operators.
 * @param handle the context handle
 * @param pkglist the list of local packages
 * @param remove an alpm_list_t* of packages to be removed
 * @param upgrade an alpm_list_t* of packages to be upgraded (remove-then-upgrade)
 * @param reversedeps handles the backward dependencies
 * @return an alpm_list_t* of alpm_depmissing_t pointers.
 */
// alpm_list_t* alpm_checkdeps(AlpmHandle handle, alpm_list_t* pkglist, alpm_list_t* remove, alpm_list_t* upgrade, int reversedeps);

/** Find a package satisfying a specified dependency.
 * The dependency can include versions with depmod operators.
 * @param pkgs an alpm_list_t* of alpm_pkg_t where the satisfyer will be searched
 * @param depstring package or provision name, versioned or not
 * @return a AlpmPkg satisfying depstring
 */
AlpmPkg alpm_find_satisfier(alpm_list_t* pkgs, const(char)* depstring);

/** Find a package satisfying a specified dependency.
 * First look for a literal, going through each db one by one. Then look for
 * providers. The first satisfyer that belongs to an installed package is
 * returned. If no providers belong to an installed package then an
 * alpm_question_select_provider_t is created to select the provider.
 * The dependency can include versions with depmod operators.
 *
 * @param handle the context handle
 * @param dbs an alpm_list_t* of alpm_db_t where the satisfyer will be searched
 * @param depstring package or provision name, versioned or not
 * @return a AlpmPkg satisfying depstring
 */
AlpmPkg alpm_find_dbs_satisfier(AlpmHandle handle, alpm_list_t* dbs, const(char)* depstring);

/** Check the package conflicts in a database
 *
 * @param handle the context handle
 * @param pkglist the list of packages to check
 *
 * @return an alpm_list_t of alpm_conflict_t
 */
alpm_list_t* alpm_checkconflicts(AlpmHandle handle, alpm_list_t* pkglist);

/** Returns a newly allocated string representing the dependency information.
 * @param dep a dependency info structure
 * @return a formatted string, e.g. "glibc>=2.12"
 */
// char* alpm_dep_compute_string(alpm_depend_t* dep);

/** Return a newly allocated dependency information parsed from a string
 *\link alpm_dep_free should be used to free the dependency \endlink
 * @param depstring a formatted string, e.g. "glibc=2.12"
 * @return a dependency info structure
 */
// alpm_depend_t* alpm_dep_from_string(const(char)* depstring);

/** Free a dependency info structure
 * @param dep struct to free
 */
// void alpm_dep_free(alpm_depend_t* dep);

/** Free a fileconflict and its members.
 * @param conflict the fileconflict to free
 */
// void alpm_fileconflict_free(alpm_fileconflict_t* conflict);

/** Free a depmissing and its members
 * @param miss the depmissing to free
 * */
// void alpm_depmissing_free(alpm_depmissing_t* miss);

/**
 * Free a conflict and its members.
 * @param conflict the conflict to free
 */
// void alpm_conflict_free(alpm_conflict_t* conflict);



/** Progress callback
 *
 * Alert the front end about the progress of certain events.
 * Allows the implementation of loading bars for events that
 * make take a while to complete.
 * @param ctx user-provided context
 * @param progress the kind of event that is progressing
 * @param pkg for package operations, the name of the package being operated on
 * @param percent the percent completion of the action
 * @param howmany the total amount of items in the action
 * @param current the current amount of items completed
 */
/** Progress callback */



/** Type of download progress callbacks.
 * @param ctx user-provided context
 * @param filename the name of the file being downloaded
 * @param event the event type
 * @param data the event data of type alpm_download_event_*_t
 */


/** A callback for downloading files
 * @param ctx user-provided context
 * @param url the URL of the file to be downloaded
 * @param localpath the directory to which the file should be downloaded
 * @param force whether to force an update, even if the file is the same
 * @return 0 on success, 1 if the file exists and is identical, -1 on
 * error.
 */

/* End of libalpm_cb */
/** @} */

AlpmHandle alpm_initialize(char* root, char* dbpath, alpm_errno_t* err)
{
	alpm_errno_t myerr = void;
	const(char)* lf = "db.lck";
	char* hookdir = void;
	size_t hookdirlen = void, lockfilelen = void;
	const(passwd)* pw = null;
	AlpmHandle myhandle = new AlpmHandle();
	
	if(cast(bool)(myerr = _alpm_set_directory_option(root, &(myhandle.root), 1))) {
		goto cleanup;
	}
	if(cast(bool)(myerr = _alpm_set_directory_option(dbpath, &(myhandle.dbpath), 1))) {
		goto cleanup;
	}

	/* to concatenate myhandle->root (ends with a slash) with SYSHOOKDIR (starts
	 * with a slash) correctly, we skip SYSHOOKDIR[0]; the regular +1 therefore
	 * disappears from the allocation */
	hookdirlen = strlen(myhandle.root) + strlen(SYSHOOKDIR);
	MALLOC(hookdir, hookdirlen);
	snprintf(hookdir, hookdirlen, "%s%s", myhandle.root, &SYSHOOKDIR[1]);
	myhandle.hookdirs = alpm_list_add(null, hookdir);

	/* set default database extension */
	STRDUP(myhandle.dbext, cast(char*)".db");

	lockfilelen = strlen(myhandle.dbpath) + strlen(lf) + 1;
	MALLOC(myhandle.lockfile, lockfilelen);
	snprintf(myhandle.lockfile, lockfilelen, "%s%s", myhandle.dbpath, lf);

	if(_alpm_db_register_local(myhandle) is null) {
		myerr = myhandle.pm_errno;
		goto cleanup;
	}

version (HAVE_LIBCURL) {
	curl_global_init(CURL_GLOBAL_ALL);
	myhandle.curlm = curl_multi_init();
}

	myhandle.parallel_downloads = 1;

	/* set default sandboxuser */
	//ASSERT((pw = getpwuid(0)) != null);
	STRDUP(myhandle.sandboxuser, cast(char*)pw.pw_name);
	
version (ENABLE_NLS) {
	bindtextdomain("libalpm", LOCALEDIR);
}

	return myhandle;

nomem:
	myerr = ALPM_ERR_MEMORY;
cleanup:
	_alpm_handle_free(myhandle);
	if(err) {
		*err = myerr;
	}
	return null;
}

/* check current state and free all resources including storage locks */
int  alpm_release(AlpmHandle myhandle)
{
	CHECK_HANDLE(myhandle);
	//ASSERT(myhandle.trans == null);

	_alpm_handle_unlock(myhandle);
	_alpm_handle_free(myhandle);

	return 0;
}

const(char)* alpm_version()
{
	return "todo: fix it";
}

int  alpm_capabilities()
{
	int capabilities = 0;
version(ENABLE_NLS) {
		capabilities |= ALPM_CAPABILITY_NLS;
}
//! #endif
version (HAVE_LIBCURL) {
		capabilities |= ALPM_CAPABILITY_DOWNLOADER;
}
version (HAVE_LIBGPGME) {
		capabilities |= ALPM_CAPABILITY_SIGNATURES;
}
		return capabilities;
}
