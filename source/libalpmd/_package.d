module libalpmd._package;

//  
import core.stdc.config: c_long, c_ulong;
/*
 *  package.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
 *  Copyright (c) 2005, 2006 by Christian Hamar <krics@linuxforum.hu>
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

import core.stdc.limits;
import core.stdc.stdlib;
import core.stdc.string;
import core.sys.posix.unistd;

import libalpmd.deps;

import core.sys.posix.sys.types;
/* libalpm */
import libalpmd._package;
import libalpmd.alpm_list;
import libalpmd.log;
import libalpmd.util;
import libalpmd.db;
import libalpmd.handle;
import libalpmd.alpm;
import derelict.libarchive;
import libalpmd.signing;
import libalpmd.backup;
import std.conv;
import std.string;
import libalpmd.filelist;




struct pkg_operations {
	  char*function(AlpmPkg) get_base;
	  char*function(AlpmPkg) get_desc;
	  char*function(AlpmPkg) get_url;
	alpm_time_t function(AlpmPkg) get_builddate;
	alpm_time_t function(AlpmPkg) get_installdate;
	  char*function(AlpmPkg) get_packager;
	  char*function(AlpmPkg) get_arch;
	off_t function(AlpmPkg) get_isize;
	alpm_pkgreason_t function(AlpmPkg) get_reason;
	int function(AlpmPkg) get_validation;
	int function(AlpmPkg) has_scriptlet;

	alpm_list_t* function(AlpmPkg) get_licenses;
	alpm_list_t* function(AlpmPkg) get_groups;
	alpm_list_t* function(AlpmPkg) get_depends;
	alpm_list_t* function(AlpmPkg) get_optdepends;
	alpm_list_t* function(AlpmPkg) get_checkdepends;
	alpm_list_t* function(AlpmPkg) get_makedepends;
	alpm_list_t* function(AlpmPkg) get_conflicts;
	alpm_list_t* function(AlpmPkg) get_provides;
	alpm_list_t* function(AlpmPkg) get_replaces;
	AlpmFileList function(AlpmPkg) get_files;
	alpm_list_t* function(AlpmPkg) get_backup;

	alpm_list_t* function(AlpmPkg) get_xdata;

	void* function(AlpmPkg) changelog_open;
	size_t function(void*, size_t, AlpmPkg, void*) changelog_read;
	int function(AlpmPkg, void*) changelog_close;

	archive* function(AlpmPkg) mtree_open;
	int function(AlpmPkg, archive*, archive_entry**) mtree_next;
	int function(AlpmPkg, archive*) mtree_close;

	int function(AlpmPkg) force_load;
}

/** The standard package operations struct. get fields directly from the
 * struct itself with no abstraction layer or any type of lazy loading.
 * The actual definition is in package.c so it can have access to the
 * default accessor functions which are defined there.
 */
extern const(pkg_operations) default_pkg_ops;

class AlpmPkg {
	c_ulong name_hash;
	string filename;
	char* base;
	string name;
	char* version_;
	char* desc;
	char* url;
	char* packager;
	char* md5sum;
	char* sha256sum;
	char* base64_sig;
	char* arch;

	alpm_time_t builddate;
	alpm_time_t installdate;

	off_t size;
	off_t isize;
	off_t download_size;

	AlpmHandle handle;

	alpm_list_t* licenses;
	alpm_list_t* replaces;
	alpm_list_t* groups;
	alpm_list_t* backup;
	alpm_list_t* depends;
	alpm_list_t* optdepends;
	alpm_list_t* checkdepends;
	alpm_list_t* makedepends;
	alpm_list_t* conflicts;
	alpm_list_t* provides;
	alpm_list_t* removes; /* in transaction targets only */
	AlpmPkg oldpkg; /* in transaction targets only */

	const (pkg_operations)* ops;

	AlpmFileList files;

	/* origin == PKG_FROM_FILE, use pkg->origin_data.file
	 * origin == PKG_FROM_*DB, use pkg->origin_data.db */
	union _Origin_data {
		AlpmDB db;
		char* file;
	}_Origin_data origin_data;

	alpm_pkgfrom_t origin;
	alpm_pkgreason_t reason;
	int scriptlet;

	alpm_list_t* xdata;

	/* Bitfield from alpm_dbinfrq_t */
	int infolevel;
	/* Bitfield from alpm_pkgvalidation_t */
	int validation;
}

// alias AlpmPkgList = AlpmList!AlpmPkg;

int  alpm_pkg_free(AlpmPkg pkg)
{
	//ASSERT(pkg != null);

	/* Only free packages loaded in user space */
	if(pkg.origin == ALPM_PKG_FROM_FILE) {
		_alpm_pkg_free(pkg);
	}

	return 0;
}

int  alpm_pkg_checkmd5sum(AlpmPkg pkg)
{
	char* fpath = void;
	int retval = void;

	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	/* We only inspect packages from sync repositories */
	//ASSERT(pkg.origin == ALPM_PKG_FROM_SYNCDB,
			// RET_ERR(cast(AlpmHandle)pkg.handle, ALPM_ERR_WRONG_ARGS, -1));

	fpath = _alpm_filecache_find(pkg.handle, cast(char*)pkg.filename);

	retval = _alpm_test_checksum(fpath, pkg.md5sum, ALPM_PKG_VALIDATION_MD5SUM);

	FREE(fpath);

	if(retval == 1) {
		pkg.handle.pm_errno = ALPM_ERR_PKG_INVALID;
		retval = -1;
	}

	return retval;
}

/* Default package accessor functions. These will get overridden by any
 * backend logic that needs lazy access, such as the local database through
 * a lazy-load cache. However, the defaults will work just fine for fully-
 * populated package structures. */
  char*_pkg_get_base(AlpmPkg pkg)        { return pkg.base; }
  char*_pkg_get_desc(AlpmPkg pkg)        { return pkg.desc; }
  char*_pkg_get_url(AlpmPkg pkg)         { return pkg.url; }
alpm_time_t _pkg_get_builddate(AlpmPkg pkg)   { return pkg.builddate; }
alpm_time_t _pkg_get_installdate(AlpmPkg pkg) { return pkg.installdate; }
  char*_pkg_get_packager(AlpmPkg pkg)    { return pkg.packager; }
  char*_pkg_get_arch(AlpmPkg pkg)        { return pkg.arch; }
off_t _pkg_get_isize(AlpmPkg pkg)             { return pkg.isize; }
alpm_pkgreason_t _pkg_get_reason(AlpmPkg pkg) { return pkg.reason; }
int _pkg_get_validation(AlpmPkg pkg) { return pkg.validation; }
int _pkg_has_scriptlet(AlpmPkg pkg)           { return pkg.scriptlet; }

alpm_list_t* _pkg_get_licenses(AlpmPkg pkg)   { return pkg.licenses; }
alpm_list_t* _pkg_get_groups(AlpmPkg pkg)     { return pkg.groups; }
alpm_list_t* _pkg_get_depends(AlpmPkg pkg)    { return pkg.depends; }
alpm_list_t* _pkg_get_optdepends(AlpmPkg pkg) { return pkg.optdepends; }
alpm_list_t* _pkg_get_checkdepends(AlpmPkg pkg) { return pkg.checkdepends; }
alpm_list_t* _pkg_get_makedepends(AlpmPkg pkg) { return pkg.makedepends; }
alpm_list_t* _pkg_get_conflicts(AlpmPkg pkg)  { return pkg.conflicts; }
alpm_list_t* _pkg_get_provides(AlpmPkg pkg)   { return pkg.provides; }
alpm_list_t* _pkg_get_replaces(AlpmPkg pkg)   { return pkg.replaces; }
AlpmFileList _pkg_get_files(AlpmPkg pkg)  { return pkg.files; }
alpm_list_t* _pkg_get_backup(AlpmPkg pkg)     { return pkg.backup; }
alpm_list_t* _pkg_get_xdata(AlpmPkg pkg)      { return pkg.xdata; }

void* _pkg_changelog_open(AlpmPkg pkg)
{
	return null;
}

alias UNUSED = void;

size_t _pkg_changelog_read(void* ptr, size_t UNUSED, AlpmPkg pkg, UNUSED* fp)
{
	return 0;
}

int _pkg_changelog_close(AlpmPkg pkg, void* fp)
{
	return 0;
}

archive* _pkg_mtree_open(AlpmPkg pkg)
{
	return null;
}

int _pkg_mtree_next(AlpmPkg pkg, archive* archive, archive_entry** entry)
{
	return -1;
}

int _pkg_mtree_close(AlpmPkg pkg, archive* archive)
{
	return -1;
}

int _pkg_force_load(AlpmPkg pkg) { return 0; }

/** The standard package operations struct. Get fields directly from the
 * struct itself with no abstraction layer or any type of lazy loading.
 */

/* Public functions for getting package information. These functions
 * delegate the hard work to the function callbacks attached to each
 * package, which depend on where the package was loaded from. */
string alpm_pkg_get_filename(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.filename;
}

  char*alpm_pkg_get_base(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_base(pkg);
}

AlpmHandle alpm_pkg_get_handle(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	return pkg.handle;
}

string alpm_pkg_get_name(AlpmPkg pkg) {
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.name;
}

  char*alpm_pkg_get_version(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.version_;
}

alpm_pkgfrom_t  alpm_pkg_get_origin(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.origin;
}

  char*alpm_pkg_get_desc(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_desc(pkg);
}

  char*alpm_pkg_get_url(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_url(pkg);
}

alpm_time_t  alpm_pkg_get_builddate(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_builddate(pkg);
}

alpm_time_t  alpm_pkg_get_installdate(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_installdate(pkg);
}

  char*alpm_pkg_get_packager(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_packager(pkg);
}

  char*alpm_pkg_get_md5sum(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.md5sum;
}

  char*alpm_pkg_get_sha256sum(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.sha256sum;
}

  char*alpm_pkg_get_base64_sig(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.base64_sig;
}

int  alpm_pkg_get_sig(AlpmPkg pkg, ubyte** sig, size_t* sig_len)
{
	//ASSERT(pkg != null);

	if(pkg.base64_sig) {
		int ret = alpm_decode_signature(pkg.base64_sig, sig, sig_len);
		if(ret != 0) {
			RET_ERR(pkg.handle, ALPM_ERR_SIG_INVALID, -1);
		}
		return 0;
	} else {
		char* pkgpath = null, sigpath = null;
		alpm_errno_t err = void;
		int ret = -1;

		pkgpath = _alpm_filecache_find(pkg.handle, cast(char*)pkg.filename);
		if(!pkgpath) {
			GOTO_ERR(pkg.handle, ALPM_ERR_PKG_NOT_FOUND, "cleanup");
		}
		sigpath = _alpm_sigpath(pkg.handle, pkgpath);
		if(!sigpath || _alpm_access(pkg.handle, null, sigpath, R_OK)) {
			GOTO_ERR(pkg.handle, ALPM_ERR_SIG_MISSING, "cleanup");
		}
		err = _alpm_read_file(sigpath, sig, sig_len);
		if(err == ALPM_ERR_OK) {
			_alpm_log(pkg.handle, ALPM_LOG_DEBUG, "found detached signature %s with size %ld\n",
				sigpath, *sig_len);
		} else {
			GOTO_ERR(pkg.handle, err, "cleanup");
		}
		ret = 0;
cleanup:
		FREE(pkgpath);
		FREE(sigpath);
		return ret;
	} 
}

  char*alpm_pkg_get_arch(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_arch(pkg);
}

off_t  alpm_pkg_get_size(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.size;
}

off_t  alpm_pkg_get_isize(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_isize(pkg);
}

alpm_pkgreason_t  alpm_pkg_get_reason(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_reason(pkg);
}

int  alpm_pkg_get_validation(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_validation(pkg);
}

alpm_list_t * alpm_pkg_get_licenses(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_licenses(pkg);
}

alpm_list_t * alpm_pkg_get_groups(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_groups(pkg);
}

alpm_list_t * alpm_pkg_get_depends(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_depends(pkg);
}

alpm_list_t * alpm_pkg_get_optdepends(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_optdepends(pkg);
}

alpm_list_t * alpm_pkg_get_checkdepends(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_checkdepends(pkg);
}

alpm_list_t * alpm_pkg_get_makedepends(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_makedepends(pkg);
}

alpm_list_t * alpm_pkg_get_conflicts(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_conflicts(pkg);
}

alpm_list_t * alpm_pkg_get_provides(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_provides(pkg);
}

alpm_list_t * alpm_pkg_get_replaces(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_replaces(pkg);
}

AlpmFileList alpm_pkg_get_files(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_files(pkg);
}

alpm_list_t * alpm_pkg_get_backup(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_backup(pkg);
}

AlpmDB alpm_pkg_get_db(AlpmPkg pkg)
{
	/* Sanity checks */
	//ASSERT(pkg != null);
	//ASSERT(pkg.origin != ALPM_PKG_FROM_FILE);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;

	return pkg.origin_data.db;
}

void * alpm_pkg_changelog_open(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.changelog_open(pkg);
}

size_t  alpm_pkg_changelog_read(void* ptr, size_t size, AlpmPkg pkg, void* fp)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.changelog_read(ptr, size, pkg, fp);
}

int  alpm_pkg_changelog_close(AlpmPkg pkg, void* fp)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.changelog_close(pkg, fp);
}

archive * alpm_pkg_mtree_open(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.mtree_open(pkg);
}

int  alpm_pkg_mtree_next(AlpmPkg pkg, archive* archive, archive_entry** entry)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.mtree_next(pkg, archive, entry);
}

int  alpm_pkg_mtree_close(AlpmPkg pkg, archive* archive)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.mtree_close(pkg, archive);
}

int  alpm_pkg_has_scriptlet(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.has_scriptlet(pkg);
}

alpm_list_t * alpm_pkg_get_xdata(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.get_xdata(pkg);
}

/* Wrapper function for _alpm_fnmatch to match alpm_list_fn_cmp signature */
private int fnmatch_wrapper( void* pattern,  void* _string)
{
	return _alpm_fnmatch(cast(char*)pattern, cast(char*)_string);
}

void find_requiredby(AlpmPkg pkg, AlpmDB db, alpm_list_t** reqs, int optional)
{
	 alpm_list_t* i = void;
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;

	for(i = _alpm_db_get_pkgcache(db); i; i = i.next) {
		AlpmPkg cachepkg = cast(AlpmPkg)i.data;
		alpm_list_t* j = void;

		if(optional == 0) {
			j = alpm_pkg_get_depends(cachepkg);
		} else {
			j = alpm_pkg_get_optdepends(cachepkg);
		}

		for(; j; j = j.next) {
			if(_alpm_depcmp(pkg, cast(alpm_depend_t*)j.data)) {
				string cachepkgname = cachepkg.name;
				if(alpm_list_find_str(*reqs, cast(char*)cachepkgname) == null) {
					*reqs = alpm_list_add(*reqs, cast(char*)cachepkgname.dup);
				}
			}
		}
	}
}

alpm_list_t* compute_requiredby(AlpmPkg pkg, int optional)
{
	alpm_list_t* reqs = null;
	AlpmDB db = void;

	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;

	if(pkg.origin == ALPM_PKG_FROM_FILE) {
		/* The sane option; search locally for things that require this. */
		find_requiredby(pkg, pkg.handle.db_local, &reqs, optional);
	} else {
		/* We have a DB package. if it is a local package, then we should
		 * only search the local DB; else search all known sync databases. */
		db = pkg.origin_data.db;
		if(db.status & DB_STATUS_LOCAL) {
			find_requiredby(pkg, db, &reqs, optional);
		} else {
			for(auto i = pkg.handle.dbs_sync; i; i = i.next) {
				db = cast(AlpmDB)i.data;
				find_requiredby(pkg, db, &reqs, optional);
			}
			reqs = alpm_list_msort(reqs, alpm_list_count(reqs), &_alpm_str_cmp);
		}
	}
	return reqs;
}

alpm_list_t * alpm_pkg_compute_requiredby(AlpmPkg pkg)
{
	return compute_requiredby(pkg, 0);
}

alpm_list_t * alpm_pkg_compute_optionalfor(AlpmPkg pkg)
{
	return compute_requiredby(pkg, 1);
}

AlpmFile* _alpm_file_copy(AlpmFile* dest, AlpmFile* src)
{
	dest.name = src.name;
	dest.size = src.size;
	dest.mode = src.mode;

	return dest;
}

AlpmPkg _alpm_pkg_new()
{
	AlpmPkg pkg = void;

	CALLOC(pkg, 1, AlpmPkg.sizeof);

	return pkg;
}

alpm_list_t* list_depdup(alpm_list_t* old)
{
	alpm_list_t* i = void, new_ = null;
	for(i = old; i; i = i.next) {
		new_ = alpm_list_add(new_, _alpm_dep_dup(cast(alpm_depend_t*)i.data));
	}
	return new_;
}

/**
 * Duplicate a package data struct.
 * @param pkg the package to duplicate
 * @param new_ptr location to store duplicated package pointer
 * @return 0 on success, -1 on fatal error, 1 on non-fatal error
 */
int _alpm_pkg_dup(AlpmPkg pkg, AlpmPkg* new_ptr)
{
	AlpmPkg newpkg = void;
	alpm_list_t* i = void;
	int ret = 0;

	if(!pkg || !pkg.handle) {
		return -1;
	}

	if(!new_ptr) {
		RET_ERR(pkg.handle, ALPM_ERR_WRONG_ARGS, -1);
	}

	if(pkg.ops.force_load(pkg)) {
		_alpm_log(pkg.handle, ALPM_LOG_WARNING,
				("could not fully load metadata for package %s-%s\n"),
				pkg.name, pkg.version_);
		ret = 1;
		(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_PKG_INVALID;
	}

	CALLOC(newpkg, 1, AlpmPkg.sizeof);

	newpkg.name_hash = pkg.name_hash;
	newpkg.filename = pkg.filename.dup;
	STRDUP(newpkg.base, pkg.base);
	newpkg.name = pkg.name.dup;
	STRDUP(newpkg.version_, pkg.version_);
	STRDUP(newpkg.desc, pkg.desc);
	STRDUP(newpkg.url, pkg.url);
	newpkg.builddate = pkg.builddate;
	newpkg.installdate = pkg.installdate;
	STRDUP(newpkg.packager, pkg.packager);
	STRDUP(newpkg.md5sum, pkg.md5sum);
	STRDUP(newpkg.sha256sum, pkg.sha256sum);
	STRDUP(newpkg.arch, pkg.arch);
	newpkg.size = pkg.size;
	newpkg.isize = pkg.isize;
	newpkg.scriptlet = pkg.scriptlet;
	newpkg.reason = pkg.reason;
	newpkg.validation = pkg.validation;

	newpkg.licenses   = alpm_list_strdup(pkg.licenses);
	newpkg.replaces   = list_depdup(pkg.replaces);
	newpkg.groups     = alpm_list_strdup(pkg.groups);
	for(i = pkg.backup; i; i = i.next) {
		newpkg.backup = alpm_list_add(newpkg.backup, cast(void*)_alpm_backup_dup(cast(AlpmBackup)i.data));
	}
	newpkg.depends    = list_depdup(pkg.depends);
	newpkg.optdepends = list_depdup(pkg.optdepends);
	newpkg.conflicts  = list_depdup(pkg.conflicts);
	newpkg.provides   = list_depdup(pkg.provides);

	newpkg.files = pkg.files.dup;
	/* internal */
	newpkg.infolevel = pkg.infolevel;
	newpkg.origin = pkg.origin;
	if(newpkg.origin == ALPM_PKG_FROM_FILE) {
		STRDUP(newpkg.origin_data.file, pkg.origin_data.file);
	} else {
		newpkg.origin_data.db = pkg.origin_data.db;
	}
	newpkg.ops = pkg.ops;
	newpkg.handle = pkg.handle;

	*new_ptr = newpkg;
	return ret;

cleanup:
	_alpm_pkg_free(newpkg);
	RET_ERR(pkg.handle, ALPM_ERR_MEMORY, -1);
}

void free_deplist(alpm_list_t* deps)
{
	alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_dep_free);
	alpm_list_free(deps);
}

alpm_pkg_xdata_t* _alpm_pkg_parse_xdata(char* _string)
{
	alpm_pkg_xdata_t* pd = void;
	char* sep = void;
	if(_string == null || (sep = strchr(_string, '=')) == null) {
		return null;
	}

	CALLOC(pd, 1, alpm_pkg_xdata_t.sizeof);
	STRNDUP(pd.name, _string, sep - _string);
	STRDUP(pd.value, sep + 1);

	return pd;
}

void _alpm_pkg_xdata_free(alpm_pkg_xdata_t* pd)
{
	if(pd) {
		free(pd.name);
		free(pd.value);
		free(pd);
	}
}

void _alpm_pkg_free(AlpmPkg pkg)
{
	if(pkg is null) {
		return;
	}

	FREE(pkg.filename);
	FREE(pkg.base);
	FREE(pkg.name);
	FREE(pkg.version_);
	FREE(pkg.desc);
	FREE(pkg.url);
	FREE(pkg.packager);
	FREE(pkg.md5sum);
	FREE(pkg.sha256sum);
	FREE(pkg.base64_sig);
	FREE(pkg.arch);

	FREELIST(pkg.licenses);
	free_deplist(pkg.replaces);
	FREELIST(pkg.groups);
	if(pkg.files.count) {
		size_t i = void;
		for(i = 0; i < pkg.files.count; i++) {
			FREE(pkg.files.ptr[i].name);
		}
		free(pkg.files.ptr);
	}
	alpm_list_free_inner(pkg.backup, cast(alpm_list_fn_free)&_alpm_backup_free);
	alpm_list_free(pkg.backup);
	alpm_list_free_inner(pkg.xdata, cast(alpm_list_fn_free)&_alpm_pkg_xdata_free);
	alpm_list_free(pkg.xdata);
	free_deplist(pkg.depends);
	free_deplist(pkg.optdepends);
	free_deplist(pkg.checkdepends);
	free_deplist(pkg.makedepends);
	free_deplist(pkg.conflicts);
	free_deplist(pkg.provides);
	alpm_list_free(pkg.removes);
	_alpm_pkg_free(pkg.oldpkg);

	if(pkg.origin == ALPM_PKG_FROM_FILE) {
		FREE(pkg.origin_data.file);
	}
	FREE(pkg);
}

/* This function should be used when removing a target from upgrade/sync target list
 * Case 1: If pkg is a loaded package file (ALPM_PKG_FROM_FILE), it will be freed.
 * Case 2: If pkg is a pkgcache entry (ALPM_PKG_FROM_CACHE), it won't be freed,
 *         only the transaction specific fields of pkg will be freed.
 */
void _alpm_pkg_free_trans(AlpmPkg pkg)
{
	if(pkg is null) {
		return;
	}

	if(pkg.origin == ALPM_PKG_FROM_FILE) {
		_alpm_pkg_free(pkg);
		return;
	}

	alpm_list_free(pkg.removes);
	pkg.removes = null;
	_alpm_pkg_free(pkg.oldpkg);
	pkg.oldpkg = null;
}

/* Is spkg an upgrade for localpkg? */
int _alpm_pkg_compare_versions(AlpmPkg spkg, AlpmPkg localpkg)
{
	return alpm_pkg_vercmp(spkg.version_, localpkg.version_);
}

/* Helper function for comparing packages
 */
int _alpm_pkg_cmp( void* p1,  void* p2)
{
	 AlpmPkg pkg1 = cast( AlpmPkg)p1;
	 AlpmPkg pkg2 = cast( AlpmPkg)p2;
	return pkg1.name == pkg2.name;
}

/* Test for existence of a package in a alpm_list_t*
 * of AlpmPkg
 */
AlpmPkg alpm_pkg_find(alpm_list_t* haystack,   char*needle)
{
	alpm_list_t* lp = void;
	c_ulong needle_hash = void;

	if(needle == null || haystack == null) {
		return null;
	}

	needle_hash = _alpm_hash_sdbm(needle);

	for(lp = haystack; lp; lp = lp.next) {
		AlpmPkg info = cast(AlpmPkg)lp.data;

		if(info) {
			if(info.name_hash != needle_hash) {
				continue;
			}

			/* finally: we had hash match, verify string match */
			if(strcmp(cast(char*)info.name, needle) == 0) {
				return info;
			}
		}
	}
	return null;
}

int  alpm_pkg_should_ignore(AlpmHandle handle, AlpmPkg pkg)
{
	alpm_list_t* groups = null;

	/* first see if the package is ignored */
	if(alpm_list_find(handle.ignorepkg, cast(char*)pkg.name, &fnmatch_wrapper)) {
		return 1;
	}

	/* next see if the package is in a group that is ignored */
	for(groups = alpm_pkg_get_groups(pkg); groups; groups = groups.next) {
		char* grp = cast(char*)groups.data;
		if(alpm_list_find(handle.ignoregroup, grp, &fnmatch_wrapper)) {
			return 1;
		}
	}

	return 0;
}

/* check that package metadata meets our requirements */
int _alpm_pkg_check_meta(AlpmPkg pkg)
{
	char* c = void;
	int error_found = 0;

enum string EPKGMETA(string error) = `do { 
	error_found = -1; 
	_alpm_log(pkg.handle, ALPM_LOG_ERROR, ` ~ error ~ `, pkg.name, pkg.version_); 
} while(0);`;

	/* sanity check */
	if(pkg.handle is null) {
		return -1;
	}

	/* immediate bail if package doesn't have name or version */
	if(pkg.name == null || pkg.name[0] == '\0'
			|| pkg.version_ == null || pkg.version_[0] == '\0') {
		_alpm_log(pkg.handle, ALPM_LOG_ERROR,
				("invalid package metadata (name or version missing)"));
		return -1;
	}

	if(pkg.name[0] == '-' || pkg.name[0] == '.') {
		mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
					~ "(package name cannot start with '.' or '-')\n")`));
	}
	if(_alpm_fnmatch(cast(char*)pkg.name, cast(char*)"[![:alnum:]+_.@-]") == 0) {
		mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
					~ "(package name contains invalid characters)\n")`));
	}

	/* multiple '-' in pkgver can cause local db entries for different packages
	 * to overlap (e.g. foo-1=2-3 and foo=1-2-3 both give foo-1-2-3) */
	if((c = strchr(pkg.version_, '-')) !is null && (strchr(c + 1, '-'))) {
		mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
					~ "(package version contains invalid characters)\n")`));
	}
	if(strchr(pkg.version_, '/')) {
		mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
					~ "(package version contains invalid characters)\n")`));
	}

	/* local db entry is <pkgname>-<pkgver> */
	if(pkg.name.length + strlen(pkg.version_) + 1 > NAME_MAX) {
		mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
					~ "(package name and version too long)\n")`));
	}

	return error_found;
}
