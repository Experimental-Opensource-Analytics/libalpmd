module libalpmd.be_local;
/*
 *  be_local.c : backend for the local database
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

import core.sys.posix.unistd;
import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.errno;
import core.stdc.string;
import core.stdc.stdint; /* intmax_t */
// import core.sys.posix.dirent;
import core.sys.posix.dirent;
import core.sys.posix.sys.stat;
import ae.sys.file;


import core.stdc.limits; /* PATH_MAX */


/* libarchive */
import derelict.libarchive;
// import archive;
// import archive_entry;

/* libalpm */
import libalpmd.db;
import libalpmd.alpm_list;
import libalpmd.libarchive_compat;
import libalpmd.log;
import libalpmd.util;
import libalpmd.alpm;
import libalpmd.handle;
import libalpmd._package;
import libalpmd.deps;
import libalpmd.filelist;
import libalpmd.libarchive_compat;
import std.conv;
import std.string;

import libalpmd.pkghash;
import libalpmd.backup;

pragma(mangle, "dirfd") extern(C) nothrow @nogc int dirfd(DIR* dir);

/* local database format version */
size_t ALPM_LOCAL_DB_VERSION = 9;

enum string LAZY_LOAD(string info) = `
	if(!(this.infolevel & ` ~ info ~ `)) { 
		local_db_read(this, ` ~ info ~ `); 
	}`;

/* Cache-specific accessor functions. These implementations allow for lazy
 * loading by the files backend when a data member is actually needed
 * rather than loading all pieces of information when the package is first
 * initialized.
 */

 class AlpmPkgLocal : AlpmPkg {
	override string getBase() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.base;
	}

	override string getDesc() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.desc;
	}

	override string getUrl() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.url;
	}

	override AlpmTime getBuildDate() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.builddate;
	}

	override AlpmTime getInstallDate() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.installdate;
	}

	override string getPackager() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.packager;
	}

	override string getArch() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.arch;
	}

	override off_t getInstallSize() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.isize;
	}

	override AlpmPkgReason getReason() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.reason;
	}

	override int getValidation() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.validation;
	}

	override AlpmStrings getLicenses() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.licenses;
	}

	override AlpmStrings getGroups() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.groups;
	}

	override int hasScriptlet() {
		mixin(LAZY_LOAD!(`INFRQ_SCRIPTLET`));
		return this.scriptlet;
	}

	override AlpmDeps getDepends() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.depends;
	}

	override AlpmDeps getOptDepends() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.optdepends;
	}

	override AlpmDeps getMakeDepends() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.makedepends;
	}

	override AlpmDeps getCheckDepends() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.checkdepends;
	}

	override AlpmDeps getConflicts() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.conflicts;
	}

	override AlpmDeps getProvides() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.provides;
	}

	override AlpmFileList getFiles() {
		mixin(LAZY_LOAD!(`INFRQ_FILES`));
		return this.files;
	}

	override AlpmBackups getBackups() {
		mixin(LAZY_LOAD!(`INFRQ_FILES`));
		return this.backup;
	}

	override AlpmXDataList getXData() {
		mixin(LAZY_LOAD!(`INFRQ_DESC`));
		return this.xdata;
	}

	override void* changelogOpen() {
		// AlpmDB db = pkg.getDB();
		char* clfile = _alpm_local_db_pkgpath(origin_data.db, this, cast(char*)"changelog");
		FILE* f = fopen(clfile, "r");
		free(clfile);
		return cast(void*)f;
	}

	/**
	* Read data from an open changelog 'file stream'. Similar to fread in
	* functionality, this function takes a buffer and amount of data to read.
	* @param ptr a buffer to fill with raw changelog data
	* @param size the size of the buffer
	* @param pkg the package that the changelog is being read from
	* @param fp a 'file stream' to the package changelog
	* @return the number of characters read, or 0 if there is no more data
	*/
	override size_t changelogRead(void* ptr, size_t size, void* fp) {
		return fread(ptr, 1, size, cast(FILE*)fp);
	}

	/**
	* Close a package changelog for reading. Similar to fclose in functionality,
	* except that the 'file stream' is from the database.
	* @param pkg the package that the changelog was read from
	* @param fp a 'file stream' to the package changelog
	* @return whether closing the package changelog stream was successful
	*/
	override int changelogClose(void* fp) {
		return fclose(cast(FILE*)fp);
	}

	/**
	* Open a package mtree file for reading.
	* @param pkg the local package to read the changelog of
	* @return a archive structure for the package mtree file
	*/
	override archive* mtreeOpen() {
		archive* mtree = void;

		// AlpmDB db = pkg.getDB();
		char* mtfile = _alpm_local_db_pkgpath(origin_data.db, this, cast(char*)"mtree");

		if(access(mtfile, F_OK) != 0) {
			/* there is no mtree file for this package */
			goto error;
		}

		if((mtree = archive_read_new()) == null) {
			GOTO_ERR(this.handle, ALPM_ERR_LIBARCHIVE, "error");
		}

		_alpm_archive_read_support_filter_all(mtree);
		archive_read_support_format_mtree(mtree);

		if(_alpm_archive_read_open_file(mtree, mtfile, ALPM_BUFFER_SIZE)) {
			_alpm_log(this.handle, ALPM_LOG_ERROR, "error while reading file %s: %s\n",
						mtfile, archive_error_string(mtree));
			_alpm_archive_read_free(mtree);
			GOTO_ERR(this.handle, ALPM_ERR_LIBARCHIVE, "error");
		}

		free(mtfile);
		return mtree;

	error:
		free(mtfile);
		return null;
	}

	/**
	* Read next entry from a package mtree file.
	* @param pkg the package that the mtree file is being read from
	* @param archive the archive structure reading from the mtree file
	* @param entry an archive_entry to store the entry header information
	* @return 0 on success, 1 if end of archive is reached, -1 otherwise.
	*/
	override int mtreeNext(archive* mtree, archive_entry** entry) {
		int ret = void;
		ret = archive_read_next_header(mtree, entry);

		switch(ret) {
			case ARCHIVE_OK:
				return 0;
				break;
			case ARCHIVE_EOF:
				return 1;
				break;
			default:
				break;
		}

		return -1;
	}

	/**
	* Close a package mtree file for reading.
	* @param pkg the package that the mtree file was read from
	* @param mtree the archive structure use for reading from the mtree file
	* @return whether closing the package changelog stream was successful
	*/
	override int mtreeClose(archive* mtree) {
		return _alpm_archive_read_free(mtree);
	}

	override int forceLoad() {
		return local_db_read(this, INFRQ_ALL);
	}
 }

private int checkdbdir(AlpmDB db)
{
	stat_t buf = void;
	  char*path = cast(char*)_alpm_db_path(db);

	if(stat(path, &buf) != 0) {
		_alpm_log(db.handle, ALPM_LOG_DEBUG, "database dir '%s' does not exist, creating it\n",
				path);
		if(_alpm_makepath(path) != 0) {
			RET_ERR(db.handle, ALPM_ERR_SYSTEM, -1);
		}
	} else if(!S_ISDIR(buf.st_mode)) {
		_alpm_log(db.handle, ALPM_LOG_WARNING, ("removing invalid database: %s\n"), path);
		if(unlink(path) != 0 || _alpm_makepath(path) != 0) {
			RET_ERR(db.handle, ALPM_ERR_SYSTEM, -1);
		}
	}
	return 0;
}

private int is_dir(  char*path, dirent* entry)
{
version (HAVE_STRUCT_DIRENT_D_TYPE) {
	if(entry.d_type != DT_UNKNOWN) {
		return (entry.d_type == DT_DIR);
	}
}
	{
		char[PATH_MAX] buffer = void;
		stat_t sbuf = void;

		snprintf(buffer.ptr, PATH_MAX, "%s/%s", path, entry.d_name.ptr);

		if(!stat(buffer.ptr, &sbuf)) {
			return S_ISDIR(sbuf.st_mode);
		}
	}

	return 0;
}

private int local_db_add_version(AlpmDB db,   char*dbpath)
{
	char[PATH_MAX] dbverpath = void;
	FILE* dbverfile = void;

	snprintf(dbverpath.ptr, PATH_MAX, "%sALPM_DB_VERSION", dbpath);

	dbverfile = fopen(dbverpath.ptr, "w");

	if(dbverfile == null) {
		return 1;
	}

	fprintf(dbverfile, "%zu\n", ALPM_LOCAL_DB_VERSION);
	fclose(dbverfile);

	return 0;
}

private int local_db_create(AlpmDB db,   char*dbpath)
{
	if(mkdir(dbpath, octal!"0755") != 0) {
		_alpm_log(db.handle, ALPM_LOG_ERROR, ("could not create directory %s: %s\n"),
				dbpath, strerror(errno));
		RET_ERR(db.handle, ALPM_ERR_DB_CREATE, -1);
	}
	if(local_db_add_version(db, dbpath) != 0) {
		return 1;
	}

	return 0;
}

private int local_db_validate(AlpmDB db)
{
	dirent* ent = null;
	  char*dbpath = void;
	DIR* dbdir = void;
	char[PATH_MAX] dbverpath = void;
	FILE* dbverfile = void;
	int t = void;
	size_t version_ = void;

	if(db.status & DB_STATUS_VALID) {
		return 0;
	}
	if(db.status & DB_STATUS_INVALID) {
		return -1;
	}

	dbpath = cast(char*)_alpm_db_path(db);
	if(dbpath == null) {
		RET_ERR(db.handle, ALPM_ERR_DB_OPEN, -1);
	}

	dbdir = opendir(dbpath);
	if(dbdir == null) {
		if(errno == ENOENT) {
			/* local database dir doesn't exist yet - create it */
			if(local_db_create(db, dbpath) == 0) {
				db.status |= DB_STATUS_VALID;
				db.status &= ~DB_STATUS_INVALID;
				db.status |= DB_STATUS_EXISTS;
				db.status &= ~DB_STATUS_MISSING;
				return 0;
			} else {
				db.status &= ~DB_STATUS_EXISTS;
				db.status |= DB_STATUS_MISSING;
				/* pm_errno is set by local_db_create */
				return -1;
			}
		} else {
			RET_ERR(db.handle, ALPM_ERR_DB_OPEN, -1);
		}
	}
	db.status |= DB_STATUS_EXISTS;
	db.status &= ~DB_STATUS_MISSING;

	snprintf(dbverpath.ptr, PATH_MAX, "%sALPM_DB_VERSION", dbpath);

	if((dbverfile = fopen(dbverpath.ptr, "r")) == null) {
		/* create dbverfile if local database is empty - otherwise version error */
		while((ent = readdir(dbdir)) != null) {
			  char*name = ent.d_name.ptr;
			if(strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
				continue;
			} else {
				goto version_error;
			}
		}

		if(local_db_add_version(db, dbpath) != 0) {
			goto version_error;
		}
		goto version_latest;
	}

	t = fscanf(dbverfile, "%zu", &version_);
	fclose(dbverfile);

	if(t != 1) {
		goto version_error;
	}

	if(version_ != ALPM_LOCAL_DB_VERSION) {
		goto version_error;
	}

version_latest:
	closedir(dbdir);
	db.status |= DB_STATUS_VALID;
	db.status &= ~DB_STATUS_INVALID;
	return 0;

version_error:
	closedir(dbdir);
	db.status &= ~DB_STATUS_VALID;
	db.status |= DB_STATUS_INVALID;
	db.handle.pm_errno = ALPM_ERR_DB_VERSION;
	return -1;
}

private int local_db_populate(AlpmDB db)
{
	size_t est_count = void;
	size_t count = 0;
	stat_t buf = void;
	dirent* ent = null;
	  char*dbpath = void;
	DIR* dbdir = void;

	if(db.status & DB_STATUS_INVALID) {
		RET_ERR(db.handle, ALPM_ERR_DB_INVALID, -1);
	}
	if(db.status & DB_STATUS_MISSING) {
		RET_ERR(db.handle, ALPM_ERR_DB_NOT_FOUND, -1);
	}

	dbpath = cast(char*)_alpm_db_path(db);
	if(dbpath == null) {
		/* pm_errno set in _alpm_db_path() */
		return -1;
	}

	dbdir = opendir(dbpath);
	if(dbdir == null) {
		RET_ERR(db.handle, ALPM_ERR_DB_OPEN, -1);
	}
	if(fstat(dirfd(dbdir), &buf) != 0) {
		RET_ERR(db.handle, ALPM_ERR_DB_OPEN, -1);
	}
	db.status |= DB_STATUS_EXISTS;
	db.status &= ~DB_STATUS_MISSING;
	if(buf.st_nlink >= 2) {
		est_count = buf.st_nlink;
	} else {
		/* Some filesystems don't subscribe to the two-implicit links school of
		 * thought, e.g. BTRFS, HFS+. See
		 * http://kerneltrap.org/mailarchive/linux-btrfs/2010/1/23/6723483/thread
		 */
		est_count = 0;
		while(readdir(dbdir) != null) {
			est_count++;
		}
		rewinddir(dbdir);
	}
	if(est_count >= 2) {
		/* subtract the '.' and '..' pointers to get # of children */
		est_count -= 2;
	}

	db.pkgcache = _alpm_pkghash_create(cast(uint)est_count);
	if(db.pkgcache == null){
		closedir(dbdir);
		RET_ERR(db.handle, ALPM_ERR_MEMORY, -1);
	}

	while((ent = readdir(dbdir)) != null) {
		  char*name = ent.d_name.ptr;

		AlpmPkg pkg = void;

		if(strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
			continue;
		}
		if(!is_dir(dbpath, ent)) {
			continue;
		}

		pkg = new AlpmPkg();
		if(pkg is null) {
			closedir(dbdir);
			RET_ERR(db.handle, ALPM_ERR_MEMORY, -1);
		}
		/* split the db entry name */
		if(_alpm_splitname(name, cast(char**)&(pkg.name), cast(char**)&(pkg.version_),
					&(pkg.name_hash)) != 0) {
			_alpm_log(db.handle, ALPM_LOG_ERROR, ("invalid name for database entry '%s'\n"),
					name);
			_alpm_pkg_free(pkg);
			continue;
		}

		/* duplicated database entries are not allowed */
		if(_alpm_pkghash_find(db.pkgcache, cast(char*)pkg.name)) {
			_alpm_log(db.handle, ALPM_LOG_ERROR, ("duplicated database entry '%s'\n"), pkg.name);
			_alpm_pkg_free(pkg);
			continue;
		}

		pkg.origin = ALPM_PKG_FROM_LOCALDB;
		pkg.origin_data.db = db;
		// pkg.ops = &local_pkg_ops;
		pkg.handle = db.handle;

		/* explicitly read with only 'BASE' data, accessors will handle the rest */
		if(local_db_read(pkg, INFRQ_BASE) == -1) {
			_alpm_log(db.handle, ALPM_LOG_ERROR, ("corrupted database entry '%s'\n"), name);
			_alpm_pkg_free(pkg);
			continue;
		}

		/* treat local metadata errors as warning-only,
		 * they are already installed and otherwise they can't be operated on */
		_alpm_pkg_check_meta(pkg);

		/* add to the collection */
		_alpm_log(db.handle, ALPM_LOG_FUNCTION, "adding '%s' to package cache for db '%s'\n",
				pkg.name, db.treename);
		if(_alpm_pkghash_add(&db.pkgcache, pkg) == null) {
			_alpm_pkg_free(pkg);
			RET_ERR(db.handle, ALPM_ERR_MEMORY, -1);
		}
		count++;
	}

	closedir(dbdir);
	if(count > 0) {
		db.pkgcache.list = alpm_list_msort(db.pkgcache.list, count, cast(alpm_list_fn_cmp)&_alpm_pkg_cmp);
	}
	_alpm_log(db.handle, ALPM_LOG_DEBUG, "added %zu packages to package cache for db '%s'\n",
			count, db.treename);

	return 0;
}

private AlpmPkgReason _read_pkgreason(AlpmHandle handle,   char*pkgname,   char*line) {
	if(strcmp(line, "0") == 0) {
		return ALPM_PKG_REASON_EXPLICIT;
	} else if(strcmp(line, "1") == 0) {
		return ALPM_PKG_REASON_DEPEND;
	} else {
		_alpm_log(handle, ALPM_LOG_ERROR, ("unknown install reason for package %s: %s\n"), pkgname, line);
		return ALPM_PKG_REASON_UNKNOWN;
	}
}

/* Note: the return value must be freed by the caller */
char* _alpm_local_db_pkgpath(AlpmDB db, AlpmPkg info,   char*filename)
{
	size_t len = void;
	char* pkgpath = void;
	  char*dbpath = void;

	dbpath = cast(char*)_alpm_db_path(db);
	len = strlen(dbpath) + info.name.length + info.version_.length + 3;
	len += filename ? strlen(filename) : 0;
	MALLOC(pkgpath, len);
	snprintf(pkgpath, len, "%s%s-%s/%s", dbpath, cast(char*)info.name.ptr, cast(char*)info.version_,
			filename ? filename : "");
	return pkgpath;
}

enum string READ_NEXT() = `do { 
	if(fgets(line.ptr, line.sizeof, fp) == null && !feof(fp)) goto error; 
	_alpm_strip_newline(line.ptr, 0); 
} while(0);`;

enum string READ_AND_STORE(string f) = `do { 
	` ~ READ_NEXT!() ~ `; 
	char* tmp = null;
	STRDUP(tmp, line.ptr);
	`~f~` = tmp.to!(typeof(`~f~`));
} while(0);`;

enum string READ_AND_STORE_ALL_L(string f) = `do { 
	char* linedup = void; 
	if(fgets(line.ptr, line.sizeof, fp) == null) {
		if(!feof(fp)) goto error; else break; 
	} 
	if(_alpm_strip_newline(line.ptr, 0) == 0) break; 
	STRDUP(linedup, line.ptr); 
	` ~ f ~ `.insertFront(linedup.to!string); 
} while(1); /* note the while(1) and not (0) */`;

enum string READ_AND_STORE_ALL(string f) = `do { 
	char* linedup = void; 
	if(fgets(line.ptr, line.sizeof, fp) == null) {
		if(!feof(fp)) goto error; else break; 
	} 
	if(_alpm_strip_newline(line.ptr, 0) == 0) break; 
	STRDUP(linedup, line.ptr); 
	` ~ f ~ ` = alpm_list_add(` ~ f ~ `, linedup); 
} while(1); /* note the while(1) and not (0) */`;

enum string READ_AND_SPLITDEP(string f) = `do { 
	if(fgets(line.ptr, line.sizeof, fp) == null) {
		if(!feof(fp)) goto error; else break; 
	} 
	if(_alpm_strip_newline(line.ptr, 0) == 0) break; 
	` ~ f ~ ` = alpm_list_add(` ~ f ~ `, cast(void*)alpm_dep_from_string(line.ptr)); 
} while(1); /* note the while(1) and not (0) */`;

enum string READ_AND_SPLITDEP_N(string f) = `do { 
	if(fgets(line.ptr, line.sizeof, fp) == null) {
		if(!feof(fp)) goto error; else break; 
	} 
	if(_alpm_strip_newline(line.ptr, 0) == 0) break; 
	` ~ f ~ `.insertFront(alpm_dep_from_string(line.ptr)); 
} while(1); /* note the while(1) and not (0) */`;

private int local_db_read(AlpmPkg info, int inforeq)
{
	FILE* fp = null;
	char[1024] line = 0;
	AlpmDB db = info.origin_data.db;

	/* bitmask logic here:
	 * infolevel: 00001111
	 * inforeq:   00010100
	 * & result:  00000100
	 * == to inforeq? nope, we need to load more info. */
	if((info.infolevel & inforeq) == inforeq) {
		/* already loaded all of this info, do nothing */
		return 0;
	}

	if(info.infolevel & INFRQ_ERROR) {
		/* We've encountered an error loading this package before. Don't attempt
		 * repeated reloads, just give up. */
		return -1;
	}

	_alpm_log(db.handle, ALPM_LOG_FUNCTION,
			"loading package data for %s : level=0x%x\n",
			info.name, inforeq);

	/* DESC */
	if(inforeq & INFRQ_DESC && !(info.infolevel & INFRQ_DESC)) {
		char* path = _alpm_local_db_pkgpath(db, info, cast(char*)"desc");
		if(!path || (fp = fopen(path, "r")) == null) {
			_alpm_log(db.handle, ALPM_LOG_ERROR, ("could not open file %s: %s\n"), path, strerror(errno));
			free(path);
			goto error;
		}
		free(path);
		while(!feof(fp)) {
			if(fgets(line.ptr, line.sizeof, fp) == null && !feof(fp)) {
				goto error;
			}
			if(_alpm_strip_newline(line.ptr, 0) == 0) {
				/* length of stripped line was zero */
				continue;
			}
			if(strcmp(line.ptr, "%NAME%") == 0) {
				mixin(READ_NEXT!());
				if(strcmp(line.ptr, cast(char*)info.name) != 0) {
					_alpm_log(db.handle, ALPM_LOG_ERROR, ("%s database is inconsistent: name "
								~ "mismatch on package %s\n"), db.treename, info.name);
				}
			} else if(strcmp(line.ptr, "%VERSION%") == 0) {
				mixin(READ_NEXT!());
				if(strcmp(line.ptr, cast(char*)info.version_) != 0) {
					_alpm_log(db.handle, ALPM_LOG_ERROR, ("%s database is inconsistent: version "
								~ "mismatch on package %s\n"), db.treename, info.name);
				}
			} else if(strcmp(line.ptr, "%BASE%") == 0) {
				mixin(READ_AND_STORE!(`info.base`));
			} else if(strcmp(line.ptr, "%DESC%") == 0) {
				mixin(READ_AND_STORE!(`info.desc`));
			} else if(strcmp(line.ptr, "%GROUPS%") == 0) {
				mixin(READ_AND_STORE_ALL_L!(`info.groups`));
			} else if(strcmp(line.ptr, "%URL%") == 0) {
				mixin(READ_AND_STORE!(`info.url`));
			} else if(strcmp(line.ptr, "%LICENSE%") == 0) {
				mixin(READ_AND_STORE_ALL_L!(`info.licenses`));
			} else if(strcmp(line.ptr, "%ARCH%") == 0) {
				mixin(READ_AND_STORE!(`info.arch`));
			} else if(strcmp(line.ptr, "%BUILDDATE%") == 0) {
				mixin(READ_NEXT!());
				info.builddate = _alpm_parsedate(line.ptr);
			} else if(strcmp(line.ptr, "%INSTALLDATE%") == 0) {
				mixin(READ_NEXT!());
				info.installdate = _alpm_parsedate(line.ptr);
			} else if(strcmp(line.ptr, "%PACKAGER%") == 0) {
				mixin(READ_AND_STORE!(`info.packager`));
			} else if(strcmp(line.ptr, "%REASON%") == 0) {
				mixin(READ_NEXT!());
				info.reason = _read_pkgreason(db.handle, cast(char*)info.name, line.ptr);
			} else if(strcmp(line.ptr, "%VALIDATION%") == 0) {
				alpm_list_t* i = void, v = null;
				mixin(READ_AND_STORE_ALL!(`v`));
				for(i = v; i; i = alpm_list_next(i))
				{
					if(strcmp(cast(  char*)i.data, "none") == 0) {
						info.validation |= ALPM_PKG_VALIDATION_NONE;
					} else if(strcmp(cast(  char*)i.data, "md5") == 0) {
						info.validation |= ALPM_PKG_VALIDATION_MD5SUM;
					} else if(strcmp(cast(  char*)i.data, "sha256") == 0) {
						info.validation |= ALPM_PKG_VALIDATION_SHA256SUM;
					} else if(strcmp(cast(  char*)i.data, "pgp") == 0) {
						info.validation |= ALPM_PKG_VALIDATION_SIGNATURE;
					} else {
						_alpm_log(db.handle, ALPM_LOG_WARNING,
								("unknown validation type for package %s: %s\n"),
								info.name, cast(char*)i.data);
					}
				}
				FREELIST(v);
			} else if(strcmp(line.ptr, "%SIZE%") == 0) {
				mixin(READ_NEXT!());
				info.isize = _alpm_strtoofft(line.ptr);
			} else if(strcmp(line.ptr, "%REPLACES%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`info.replaces`));
			} else if(strcmp(line.ptr, "%DEPENDS%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`info.depends`));
			} else if(strcmp(line.ptr, "%OPTDEPENDS%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`info.optdepends`));
			} else if(strcmp(line.ptr, "%MAKEDEPENDS%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`info.makedepends`));
			} else if(strcmp(line.ptr, "%CHECKDEPENDS%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`info.checkdepends`));
			} else if(strcmp(line.ptr, "%CONFLICTS%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`info.conflicts`));
			} else if(strcmp(line.ptr, "%PROVIDES%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`info.provides`));
			} else if(strcmp(line.ptr, "%XDATA%") == 0) {
				alpm_list_t* i = void, lines = null;
				mixin(READ_AND_STORE_ALL!(`lines`));
				for(i = lines; i; i = i.next) {
					AlpmPkgXData* pd = _alpm_pkg_parse_xdata(i.data.to!string);
					if(pd == null || !alpmList_append(&info.xdata, *pd)) {
						pd = null;
						FREELIST(lines);
						goto error;
					}
				}
				FREELIST(lines);
			} else {
				_alpm_log(db.handle, ALPM_LOG_WARNING, ("%s: unknown key '%s' in local database\n"), info.name, line.ptr);
				alpm_list_t* lines = null;
				mixin(READ_AND_STORE_ALL!(`lines`));
				FREELIST(lines);
			}
		}
		fclose(fp);
		fp = null;
		info.infolevel |= INFRQ_DESC;
	}

	/* FILES */
	if(inforeq & INFRQ_FILES && !(info.infolevel & INFRQ_FILES)) {
		char* path = _alpm_local_db_pkgpath(db, info, cast(char*)"files");
		if(!path || (fp = fopen(path, "r")) == null) {
			_alpm_log(db.handle, ALPM_LOG_ERROR, ("could not open file %s: %s\n"), path, strerror(errno));
			free(path);
			goto error;
		}
		free(path);
		while( fgets(line.ptr, line.sizeof, fp)) {
			_alpm_strip_newline(line.ptr, 0);
			if(strcmp(line.ptr, "%FILES%") == 0) {
				size_t files_count = 0, files_size = 0, len = void;
				AlpmFile* files = null;

				while( fgets(line.ptr, line.sizeof, fp) &&
						(cast(bool)(len = _alpm_strip_newline(line.ptr, 0)))) {
					if(!_alpm_greedy_grow(cast(void**)&files, &files_size,
								(files_count ? (files_count + 1) * AlpmFile.sizeof : 8 * AlpmFile.sizeof))) {
						goto nomem;
					}
					/* since we know the length of the file string already,
					 * we can do malloc + memcpy rather than strdup */
					len += 1;
					MALLOC(cast(char*)files[files_count].name, len);
					memcpy(cast(char*)files[files_count].name, line.ptr, len);
					files_count++;
				}
				/* attempt to hand back any memory we don't need */
				if(files_count > 0) {
					REALLOC(files, ((AlpmFile).sizeof * files_count));
				} else {
					FREE(files);
				}
				// info.files.count = files_count;
				info.files = files[0..files_count];
				_alpm_filelist_sort(info.files[]);
				continue;
nomem:
				while(files_count > 0) {
					FREE(files[--files_count].name);
				}
				FREE(files);
				goto error;
			} else if(strcmp(line.ptr, "%BACKUP%") == 0) {
				while( fgets(line.ptr, line.sizeof, fp) && _alpm_strip_newline(line.ptr, 0)) {
					AlpmBackup backup = void;
					CALLOC(backup, 1, AlpmBackup.sizeof);
					if(backup.splitString(line.to!string)) {
						FREE(backup);
						goto error;
					}
					info.backup.insertFront(backup);
				}
			}
		}
		fclose(fp);
		fp = null;
		info.infolevel |= INFRQ_FILES;
	}

	/* INSTALL */
	if(inforeq & INFRQ_SCRIPTLET && !(info.infolevel & INFRQ_SCRIPTLET)) {
		char* path = _alpm_local_db_pkgpath(db, info, cast(char*)"install");
		if(access(path, F_OK) == 0) {
			info.scriptlet = 1;
		}
		free(path);
		info.infolevel |= INFRQ_SCRIPTLET;
	}

	return 0;

error:
	info.infolevel |= INFRQ_ERROR;
	if(fp) {
		fclose(fp);
	}
	return -1;
}

int _alpm_local_db_prepare(AlpmDB db, AlpmPkg info)
{
	mode_t oldmask = void;
	int retval = 0;
	char* pkgpath = void;

	if(checkdbdir(db) != 0) {
		return -1;
	}

	oldmask = umask(0000);
	pkgpath = _alpm_local_db_pkgpath(db, info, null);

	if((retval = mkdir(pkgpath, octal!"0755")) != 0) {
		_alpm_log(db.handle, ALPM_LOG_ERROR, ("could not create directory %s: %s\n"),
				pkgpath, strerror(errno));
	}

	free(pkgpath);
	umask(oldmask);

	return retval;
}

private void write_deps(FILE* fp,   char*header, alpm_list_t* deplist)
{
	alpm_list_t* lp = void;
	if(!deplist) {
		return;
	}
	fputs(header, fp);
	fputc('\n', fp);
	for(lp = deplist; lp; lp = lp.next) {
		char* depstring = alpm_dep_compute_string(cast(AlpmDepend )lp.data);
		fputs(depstring, fp);
		fputc('\n', fp);
		free(depstring);
	}
	fputc('\n', fp);
}

private void write_deps_n(FILE* fp,   char*header, AlpmDeps deplist)
{
	// alpm_list_t* lp = void;
	if(!deplist.empty) {
		return;
	}
	fputs(header, fp);
	fputc('\n', fp);
	foreach(lp; deplist[]) {
		char* depstring = alpm_dep_compute_string(cast(AlpmDepend )lp);
		fputs(depstring, fp);
		fputc('\n', fp);
		free(depstring);
	}
	fputc('\n', fp);
}

int _alpm_local_db_write(AlpmDB db, AlpmPkg info, int inforeq)
{
	FILE* fp = null;
	mode_t oldmask = void;
	alpm_list_t* lp = void;
	int retval = 0;

	if(db is null || info is null || !(db.status & DB_STATUS_LOCAL)) {
		return -1;
	}

	/* make sure we have a sane umask */
	oldmask = umask(octal!"0022");

	/* DESC */
	if(inforeq & INFRQ_DESC) {
		char* path = void;
		_alpm_log(db.handle, ALPM_LOG_DEBUG,
				"writing %s-%s DESC information back to db\n",
				info.name, info.version_);
		path = _alpm_local_db_pkgpath(db, info, cast(char*)"desc");
		if(!path || (fp = fopen(path, "w")) == null) {
			_alpm_log(db.handle, ALPM_LOG_ERROR, ("could not open file %s: %s\n"),
					path, strerror(errno));
			retval = -1;
			free(path);
			goto cleanup;
		}
		free(path);
		fprintf(fp, "%%NAME%%\n%s\n\n"
						~ "%%VERSION%%\n%s\n\n", cast(char*)info.name.ptr, cast(char*)info.version_);
		if(info.base) {
			fprintf(fp, "%%BASE%%\n"
							~ "%s\n\n", info.base.ptr);
		}
		if(info.desc) {
			fprintf(fp, "%%DESC%%\n"
							~ "%s\n\n", cast(char*)info.desc);
		}
		if(info.url) {
			fprintf(fp, "%%URL%%\n"
							~ "%s\n\n", cast(char*)info.url);
		}
		if(info.arch) {
			fprintf(fp, "%%ARCH%%\n"
							~ "%s\n\n", cast(char*)info.arch);
		}
		if(info.builddate) {
			fprintf(fp, "%%BUILDDATE%%\n"
							~ "%jd\n\n", cast(intmax_t)info.builddate);
		}
		if(info.installdate) {
			fprintf(fp, "%%INSTALLDATE%%\n"
							~ "%jd\n\n", cast(intmax_t)info.installdate);
		}
		if(info.packager) {
			fprintf(fp, "%%PACKAGER%%\n"
							~ "%s\n\n", cast(char*)info.packager);
		}
		if(info.isize) {
			/* only write installed size, csize is irrelevant once installed */
			fprintf(fp, "%%SIZE%%\n"
							~ "%jd\n\n", cast(intmax_t)info.isize);
		}
		if(info.reason) {
			fprintf(fp, "%%REASON%%\n"
							~ "%u\n\n", info.reason);
		}
		if(!info.groups.empty) {
			fputs("%GROUPS%\n", fp);
			foreach(_lp; info.groups) {
				fputs(cast(  char*)lp, fp);
				fputc('\n', fp);
			}
			fputc('\n', fp);
		}
		if(!info.licenses.empty) {
			fputs("%LICENSE%\n", fp);
			foreach(_lp; info.licenses[]) {
				fputs(cast(  char*)_lp, fp);
				fputc('\n', fp);
			}
			fputc('\n', fp);
		}
		if(info.validation) {
			fputs("%VALIDATION%\n", fp);
			if(info.validation & ALPM_PKG_VALIDATION_NONE) {
				fputs("none\n", fp);
			}
			if(info.validation & ALPM_PKG_VALIDATION_MD5SUM) {
				fputs("md5\n", fp);
			}
			if(info.validation & ALPM_PKG_VALIDATION_SHA256SUM) {
				fputs("sha256\n", fp);
			}
			if(info.validation & ALPM_PKG_VALIDATION_SIGNATURE) {
				fputs("pgp\n", fp);
			}
			fputc('\n', fp);
		}

		write_deps_n(fp, cast(char*)"%REPLACES%", info.replaces);
		write_deps_n(fp, cast(char*)"%DEPENDS%", info.depends);
		write_deps_n(fp, cast(char*)"%OPTDEPENDS%", info.optdepends);
		write_deps_n(fp, cast(char*)"%CONFLICTS%", info.conflicts);
		write_deps_n(fp, cast(char*)"%PROVIDES%", info.provides);

		if(info.xdata) {
			fputs("%XDATA%\n", fp);
			for(auto _lp = info.xdata; _lp; _lp = _lp.next) {
				AlpmPkgXData* pd = cast(AlpmPkgXData*)&_lp.data;
				fprintf(fp, "%s=%s\n", cast(char*)pd.name, cast(char*)pd.value.ptr);
			}
			fputc('\n', fp);
		}

		fclose(fp);
		fp = null;
	}

	/* FILES */
	if(inforeq & INFRQ_FILES) {
		char* path = void;
		_alpm_log(db.handle, ALPM_LOG_DEBUG,
				"writing %s-%s FILES information back to db\n",
				info.name, info.version_);
		path = _alpm_local_db_pkgpath(db, info, cast(char*)"files");
		if(!path || (fp = fopen(path, "w")) == null) {
			_alpm_log(db.handle, ALPM_LOG_ERROR, ("could not open file %s: %s\n"),
					path, strerror(errno));
			retval = -1;
			free(path);
			goto cleanup;
		}
		free(path);
		if(info.files.count) {
			size_t i = void;
			fputs("%FILES%\n", fp);
			for(i = 0; i < info.files.count; i++) {
				AlpmFile* file = info.files.ptr + i;
				fputs(cast(char*)file.name, fp);
				fputc('\n', fp);
			}
			fputc('\n', fp);
		}
		if(!info.backup.empty) {
			fputs("%BACKUP%\n", fp);
			foreach(backup; info.backup) {
				//  AlpmBackup backup = lpa;
				fprintf(fp, "%s\t%s\n", cast(char*)backup.name, cast(char*)backup.hash);
			}
			fputc('\n', fp);
		}
		fclose(fp);
		fp = null;
	}

	/* INSTALL and MTREE */
	/* nothing needed here (automatically extracted) */

cleanup:
	umask(oldmask);
	return retval;
}

int _alpm_local_db_remove(AlpmDB db, AlpmPkg info)
{
	int ret = 0;
	DIR* dirp = void;
	dirent* dp = void;
	char* pkgpath = void;
	size_t pkgpath_len = void;

	pkgpath = _alpm_local_db_pkgpath(db, info, null);
	if(!pkgpath) {
		return -1;
	}
	pkgpath_len = strlen(pkgpath);

	dirp = opendir(pkgpath);
	if(!dirp) {
		free(pkgpath);
		return -1;
	}
	/* go through the local DB entry, removing the files within, which we know
	 * are not nested directories of any kind. */
	for(dp = readdir(dirp); dp != null; dp = readdir(dirp)) {
		if(strcmp(dp.d_name.ptr, "..") != 0 && strcmp(dp.d_name.ptr, ".") != 0) {
			char[PATH_MAX] name = void;
			if(pkgpath_len + strlen(dp.d_name.ptr) + 2 > PATH_MAX) {
				/* file path is too long to remove, hmm. */
				ret = -1;
			} else {
				snprintf(name.ptr, PATH_MAX, "%s/%s", pkgpath, dp.d_name.ptr);
				if(unlink(name.ptr)) {
					ret = -1;
				}
			}
		}
	}
	closedir(dirp);

	/* after removing all enclosed files, we can remove the directory itself. */
	if(rmdir(pkgpath)) {
		ret = -1;
	}
	free(pkgpath);
	return ret;
}

int  alpm_pkg_set_reason(AlpmPkg pkg, AlpmPkgReason reason)
{
	//ASSERT(pkg != null);
	//ASSERT(pkg.origin == ALPM_PKG_FROM_LOCALDB);
	//ASSERT(pkg.origin_data.db == pkg.handle.db_local);

	_alpm_log(pkg.handle, ALPM_LOG_DEBUG,
			"setting install reason %u for %s\n", reason, pkg.name);
	if(pkg.getReason() == reason) {
		/* we are done */
		return 0;
	}
	/* set reason (in pkgcache) */
	pkg.reason = reason;
	/* write DESC */
	if(_alpm_local_db_write(pkg.handle.db_local, pkg, INFRQ_DESC)) {
		RET_ERR(pkg.handle, ALPM_ERR_DB_WRITE, -1);
	}

	return 0;
}

private  const(db_operations) local_db_ops = {
	validate: &local_db_validate,
	populate: &local_db_populate,
	unregister: &_alpm_db_unregister,
};

AlpmDB _alpm_db_register_local(AlpmHandle handle)
{
	AlpmDB db = void;

	_alpm_log(handle, ALPM_LOG_DEBUG, "registering local database\n");

	db = _alpm_db_new(cast(char*)"local", 1);
	if(db is null) {
		handle.pm_errno = ALPM_ERR_DB_CREATE;
		return null;
	}
	db.ops = &local_db_ops;
	db.handle = handle;
	db.usage = ALPM_DB_USAGE_ALL;

	if(local_db_validate(db)) {
		/* pm_errno set in local_db_validate() */
		_alpm_db_free(db);
		return null;
	}

	handle.db_local = db;
	return db;
}

AlpmPkgChangelog openChangelog(AlpmPkg pkg) {
	AlpmPkgChangelog changelog;
	archive* _archive;
	archive_entry* entry;
	stat_t buf = void;
	int fd = void;

	fd = _alpm_open_archive(pkg.handle, cast(char*)pkg.origin_data.file, &buf,
			&_archive, ALPM_ERR_PKG_OPEN);
	if(fd < 0) {
		return null;
	}

	while(archive_read_next_header(_archive, &entry) == ARCHIVE_OK) {
		string entry_name = archive_entry_pathname(entry).to!string;

		if(entry_name == ".CHANGELOG") {
			changelog = new AlpmPkgChangelog;
			changelog._archive = _archive;
			changelog.fd = fd;
			return changelog;
		}
	}
	/* we didn't find a changelog */
	_alpm_archive_read_free(_archive);
	close(fd);
	errno = ENOENT;

	return null;
}
