module libalpmd.db.be_local;
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
import libalpmd.pkg;
import libalpmd.deps;
import libalpmd.file;
import libalpmd.libarchive_compat;
import std.conv;
import std.string;

import libalpmd.pkghash;
import libalpmd.backup;
import ae.sys.git;

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
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.getBase;
	}

	override string getDesc() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.getDesc;
	}

	override string getUrl() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.getUrl;
	}

	override AlpmTime getBuildDate() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.builddate;
	}

	override AlpmTime getInstallDate() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.installdate;
	}

	override string getPackager() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.getPackager;
	}

	override string getArch() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.arch;
	}

	override off_t getInstallSize() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.isize;
	}

	override AlpmPkgReason getReason() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.reason;
	}

	override int getValidation() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.validation;
	}

	override AlpmStrings getLicenses() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.licenses;
	}

	override AlpmStrings getGroups() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.groups;
	}

	override int hasScriptlet() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Scriptlet`));
		return this.scriptlet;
	}

	override AlpmDeps getDepends() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.depends;
	}

	override AlpmDeps getOptDepends() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.optdepends;
	}

	override AlpmDeps getMakeDepends() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.makedepends;
	}

	override AlpmDeps getCheckDepends() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.checkdepends;
	}

	override AlpmDeps getConflicts() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.conflicts;
	}

	override AlpmDeps getProvides() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.provides;
	}

	override AlpmFileList getFiles() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Files`));
		return this.files;
	}

	override AlpmBackups getBackups() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Files`));
		return this.backup;
	}

	override AlpmXDataList getXData() {
		mixin(LAZY_LOAD!(`AlpmDBInfRq.Desc`));
		return this.xdata;
	}

	override void* changelogOpen() {
		// AlpmDB db = pkg.getDB();
		char* clfile = _alpm_local_db_pkgpath(getOriginDB(), this, cast(char*)"changelog");
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
		char* mtfile = _alpm_local_db_pkgpath(getOriginDB(), this, cast(char*)"mtree");

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
		return local_db_read(this, AlpmDBInfRq.All);
	}

	int  checkMD5Sum() {
		char* fpath = void;
		int retval = void;

		handle.pm_errno = ALPM_ERR_OK;
		if(this.origin != AlpmPkgFrom.SyncDB) {
			handle.pm_errno = ALPM_ERR_WRONG_ARGS;
			return -1;
		}

		fpath = _alpm_filecache_find(this.handle, cast(char*)this.getFilename());

		retval = _alpm_test_checksum(fpath, cast(char*)this.md5sum, AlpmPkgValidation.MD5);

		FREE(fpath);

		if(retval == 1) {
			this.handle.pm_errno = ALPM_ERR_PKG_INVALID;
			retval = -1;
		}

		return retval;
	}
 }

 class AlpmDBLocal : AlpmDB {

	this(string treename) {
		super(treename);
		this.status |= AlpmDBStatus.Local;
	}

	override int validate()
	{
		dirent* ent = null;
		char*dbpath = void;
		DIR* dbdir = void;
		char[PATH_MAX] dbverpath = void;
		FILE* dbverfile = void;
		int t = void;
		size_t version_ = void;

		if(this.status & AlpmDBStatus.Valid) {
			return 0;
		}
		if(this.status & AlpmDBStatus.Invalid) {
			return -1;
		}

		dbpath = cast(char*)this.calcPath();
		if(dbpath == null) {
			throw new Exception("Error to opem dbpath");
			// RET_ERR(this.handle, ALPM_ERR_DB_OPEN, "error to open dbpath %s", dbpath.to!string);
		}

		dbdir = opendir(dbpath);
		if(dbdir == null) {
			if(errno == ENOENT) {
				/* local database dir doesn't exist yet - create it */
				if(local_db_create(this, dbpath) == 0) {
					this.status |= AlpmDBStatus.Valid;
					this.status &= ~AlpmDBStatus.Invalid;
					this.status |= AlpmDBStatus.Exists;
					this.status &= ~AlpmDBStatus.Missing;
					return 0;
				} else {
					this.status &= ~AlpmDBStatus.Exists;
					this.status |= AlpmDBStatus.Missing;
					/* pm_errno is set by local_db_create */
					return -1;
				}
			} else {
				throw new Exception("Error to opem dbpath");
				// RET_ERR(this.handle, ALPM_ERR_DB_OPEN, "error to open dbpath %s", dbdir.to!string);
			}
		}
		this.status |= AlpmDBStatus.Exists;
		this.status &= ~AlpmDBStatus.Missing;

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

			if(local_db_add_version(this, dbpath) != 0) {
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
		this.status |= AlpmDBStatus.Valid;
		this.status &= ~AlpmDBStatus.Invalid;
		return 0;

	version_error:
		closedir(dbdir);
		this.status &= ~AlpmDBStatus.Valid;
		this.status |= AlpmDBStatus.Invalid;
		this.handle.pm_errno = ALPM_ERR_DB_VERSION;
		return -1;
	}

	override int populate()
	{
		size_t est_count = void;
		size_t count = 0;
		stat_t buf = void;
		dirent* ent = null;
		char*dbpath = void;
		DIR* dbdir = void;

		if(this.status & AlpmDBStatus.Invalid) {
			RET_ERR(this.handle, ALPM_ERR_DB_INVALID, -1);
		}
		if(this.status & AlpmDBStatus.Missing) {
			RET_ERR(this.handle, ALPM_ERR_DB_NOT_FOUND, -1);
		}

		dbpath = cast(char*)this.calcPath();
		if(dbpath == null) {
			/* pm_errno set in _alpm_db_path() */
			return -1;
		}

		dbdir = opendir(dbpath);
		if(dbdir == null) {
			RET_ERR(this.handle, ALPM_ERR_DB_OPEN, -1);
		}
		if(fstat(dirfd(dbdir), &buf) != 0) {
			RET_ERR(this.handle, ALPM_ERR_DB_OPEN, -1);
		}
		this.status |= AlpmDBStatus.Exists;
		this.status &= ~AlpmDBStatus.Missing;
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

		this.pkgcache = new AlpmPkgHash(cast(uint)est_count);
		if(this.pkgcache is null){
			closedir(dbdir);
			RET_ERR(this.handle, ALPM_ERR_MEMORY, -1);
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
				RET_ERR(this.handle, ALPM_ERR_MEMORY, -1);
			}
			/* split the db entry name */
			string splitResult;
			string ver;
			ulong hash;
			if(alpmSplitName(name.to!string, splitResult, ver, hash) != 0) {
				_alpm_log(this.handle, ALPM_LOG_ERROR, ("invalid name for database entry '%s'\n"),
						name);
				destroy!false(pkg);
				continue;
			}

			pkg.setName(splitResult);
			pkg.setNameHash(hash);
			pkg.setVersion(ver);


			/* duplicated database entries are not allowed */
			if(this.pkgcache.find(cast(char*)pkg.getName())) {
				_alpm_log(this.handle, ALPM_LOG_ERROR, ("duplicated database entry '%s'\n"), pkg.getName());
				destroy!false(pkg);
				continue;
			}

			pkg.setOriginDB(this, AlpmPkgFrom.LocalDB);
			// pkg.ops = &local_pkg_ops;
			pkg.setHandle(this.handle);

			/* explicitly read with only 'BASE' data, accessors will handle the rest */
			if(local_db_read(pkg,AlpmDBInfRq.Base) == -1) {
				_alpm_log(this.handle, ALPM_LOG_ERROR, ("corrupted database entry '%s'\n"), name);
				destroy!false(pkg);
				continue;
			}

			/* treat local metadata errors as warning-only,
			* they are already installed and otherwise they can't be operated on */
			pkg.checkMeta();

			/* add to the collection */
			_alpm_log(this.handle, ALPM_LOG_FUNCTION, "adding '%s' to package cache for db '%s'\n",
					pkg.getName(), this.treename);
			if(this.pkgcache.add(pkg) is null) {
				destroy!false(pkg);
				RET_ERR(this.handle, ALPM_ERR_MEMORY, -1);
			}
			count++;
		}

		closedir(dbdir);

		this.pkgcache.trySort();
		_alpm_log(this.handle, ALPM_LOG_DEBUG, "added %zu packages to package cache for db '%s'\n",
				count, this.treename);

		return 0;
	}

	override void unregister() {
		int found;
		handle.getDBLocal = null;
		found = 1;

		if(!found) {
			RET_ERR(handle, ALPM_ERR_DB_NOT_FOUND, -1);
		}
	}

	override string genPath() {
		return _path = handle.dbpath ~ this.treename;
	}
 }

private int checkdbdir(AlpmDB db)
{
	stat_t buf = void;
	  char*path = cast(char*)db.calcPath();

	if(stat(path, &buf) != 0) {
		_alpm_log(db.handle, ALPM_LOG_DEBUG, "database dir '%s' does not exist, creating it\n",
				path);
		alpmMakePath(path.to!string);
	} else if(!S_ISDIR(buf.st_mode)) {
		_alpm_log(db.handle, ALPM_LOG_WARNING, ("removing invalid database: %s\n"), path);
		if(unlink(path) != 0) {
			alpmMakePath(path.to!string);
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

private AlpmPkgReason _read_pkgreason(AlpmHandle handle,   char*pkgname,   char*line) {
	if(strcmp(line, "0") == 0) {
		return AlpmPkgReason.Explicit;
	} else if(strcmp(line, "1") == 0) {
		return AlpmPkgReason.Depend;
	} else {
		_alpm_log(handle, ALPM_LOG_ERROR, ("unknown install reason for package %s: %s\n"), pkgname, line);
		return AlpmPkgReason.Unknow;
	}
}

/* Note: the return value must be freed by the caller */
char* _alpm_local_db_pkgpath(AlpmDB db, AlpmPkg info,   char*filename)
{
	size_t len = void;
	char* pkgpath = void;
	  char*dbpath = void;

	dbpath = cast(char*)db.calcPath();
	len = strlen(dbpath) + info.getName().length + info.getVersion().length + 3;
	len += filename ? strlen(filename) : 0;
	MALLOC(pkgpath, len);
	snprintf(pkgpath, len, "%s%s-%s/%s", dbpath, cast(char*)info.getName().ptr, cast(char*)info.getVersion(),
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

enum string READ_AND_STORE_THIS(string f) = `do { 
	` ~ READ_NEXT!() ~ `; 
	char* tmp = null;
	STRDUP(tmp, line.ptr);
	`~f~`(tmp.to!string);
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
	AlpmDB db = info.getOriginDB();

	/* bitmask logic here:
	 * infolevel: 00001111
	 * inforeq:   00010100
	 * & result:  00000100
	 * == to inforeq? nope, we need to load more info. */
	if((info.infolevel & inforeq) == inforeq) {
		/* already loaded all of this info, do nothing */
		return 0;
	}

	if(info.infolevel & AlpmDBInfRq.Error) {
		/* We've encountered an error loading this package before. Don't attempt
		 * repeated reloads, just give up. */
		return -1;
	}

	_alpm_log(db.handle, ALPM_LOG_FUNCTION,
			"loading package data for %s : level=0x%x\n",
			info.getName(), inforeq);

	/* DESC */
	if(inforeq & AlpmDBInfRq.Desc && !(info.infolevel & AlpmDBInfRq.Desc)) {
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
				if(strcmp(line.ptr, cast(char*)info.getName()) != 0) {
					_alpm_log(db.handle, ALPM_LOG_ERROR, ("%s database is inconsistent: name "
								~ "mismatch on package %s\n"), db.treename, info.getName());
				}
			} else if(strcmp(line.ptr, "%VERSION%") == 0) {
				mixin(READ_NEXT!());
				if(strcmp(line.ptr, cast(char*)info.getVersion()) != 0) {
					_alpm_log(db.handle, ALPM_LOG_ERROR, ("%s database is inconsistent: version "
								~ "mismatch on package %s\n"), db.treename, info.getName());
				}
			} else if(strcmp(line.ptr, "%BASE%") == 0) {
				mixin(READ_AND_STORE_THIS!(`info.setBase`));
			} else if(strcmp(line.ptr, "%DESC%") == 0) {
				mixin(READ_AND_STORE_THIS!(`info.setDesc`));
			} else if(strcmp(line.ptr, "%GROUPS%") == 0) {
				mixin(READ_AND_STORE_ALL_L!(`info.groups`));
			} else if(strcmp(line.ptr, "%URL%") == 0) {
				mixin(READ_AND_STORE_THIS!(`info.setUrl`));
			} else if(strcmp(line.ptr, "%LICENSE%") == 0) {
				mixin(READ_AND_STORE_ALL_L!(`info.licenses`));
			} else if(strcmp(line.ptr, "%ARCH%") == 0) {
				mixin(READ_AND_STORE!(`info.arch`));
			} else if(strcmp(line.ptr, "%BUILDDATE%") == 0) {
				mixin(READ_NEXT!());
				info.builddate = alpmParseDate(line.to!string);
			} else if(strcmp(line.ptr, "%INSTALLDATE%") == 0) {
				mixin(READ_NEXT!());
				info.installdate = alpmParseDate(line.to!string);
			} else if(strcmp(line.ptr, "%PACKAGER%") == 0) {
				mixin(READ_AND_STORE_THIS!(`info.setPackager`));
			} else if(strcmp(line.ptr, "%REASON%") == 0) {
				mixin(READ_NEXT!());
				info.reason = _read_pkgreason(db.handle, cast(char*)info.getName(), line.ptr);
			} else if(strcmp(line.ptr, "%VALIDATION%") == 0) {
				AlpmStrings v;
				mixin(READ_AND_STORE_ALL_L!(`v`));
				foreach(str; v[])
				{
					if(strcmp(cast(  char*)str.toStringz, "none") == 0) {
						info.validation |= AlpmPkgValidation.None;
					} else if(strcmp(cast(  char*)str.toStringz, "md5") == 0) {
						info.validation |= AlpmPkgValidation.MD5;
					} else if(strcmp(cast(  char*)str.toStringz, "sha256") == 0) {
						info.validation |= AlpmPkgValidation.SHA256;
					} else if(strcmp(cast(  char*)str.toStringz, "pgp") == 0) {
						info.validation |= AlpmPkgValidation.Signature;
					} else {
						_alpm_log(db.handle, ALPM_LOG_WARNING,
								("unknown validation type for package %s: %s\n"),
								info.getName(), cast(char*)str.toStringz);
					}
				}
				v.clear();
			} else if(strcmp(line.ptr, "%SIZE%") == 0) {
				mixin(READ_NEXT!());
				info.isize = alpmStrToOfft(line.to!string);
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
				AlpmStrings lines;
				mixin(READ_AND_STORE_ALL_L!(`lines`));
				foreach(str; lines[]) {
					AlpmPkgXData pd = AlpmPkgXData.parseFrom(str);
					if(!alpm_new_list_append(&info.xdata, pd)) {
						lines.clear();
						goto error;
					}
				}
				lines.clear();
			} else {
				_alpm_log(db.handle, ALPM_LOG_WARNING, ("%s: unknown key '%s' in local database\n"), info.getName(), line.ptr);
				AlpmStrings lines;
				mixin(READ_AND_STORE_ALL_L!(`lines`));
				// FREELIST(lines);
				lines.clear();
			}
		}
		fclose(fp);
		fp = null;
		info.infolevel |= AlpmDBInfRq.Desc;
	}

	/* FILES */
	if(inforeq & AlpmDBInfRq.Files && !(info.infolevel & AlpmDBInfRq.Files)) {
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
				AlpmFileList files = null;

				while( fgets(line.ptr, line.sizeof, fp) &&
						(cast(bool)(len = _alpm_strip_newline(line.ptr, 0)))) {
					files.length++;
					/* since we know the length of the file string already,
					 * we can do malloc + memcpy rather than strdup */
					files ~= AlpmFile();
					files[$-1].name = line.to!string;
					files_count++;
				}
				/* attempt to hand back any memory we don't need */
				if(files_count == 0)
					FREE(files);
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
					backup.fillByString(line.to!string);
					info.backup.insertFront(backup);
				}
			}
		}
		fclose(fp);
		fp = null;
		info.infolevel |= AlpmDBInfRq.Files;
	}

	/* INSTALL */
	if(inforeq & AlpmDBInfRq.Scriptlet && !(info.infolevel & AlpmDBInfRq.Scriptlet)) {
		char* path = _alpm_local_db_pkgpath(db, info, cast(char*)"install");
		if(access(path, F_OK) == 0) {
			info.scriptlet = 1;
		}
		free(path);
		info.infolevel |= AlpmDBInfRq.Scriptlet;
	}

	return 0;

error:
	info.infolevel |= AlpmDBInfRq.Error;
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

private void write_deps(FILE* fp,   char*header, AlpmDeps deplist)
{
	if(deplist.empty()) {
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

private void write_deps_n(FILE* fp,   char*header, AlpmDeps deplist)
{
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
	int retval = 0;

	if(db is null || info is null || !(db.status & AlpmDBStatus.Local)) {
		return -1;
	}

	/* make sure we have a sane umask */
	oldmask = umask(octal!"0022");

	/* DESC */
	if(inforeq & AlpmDBInfRq.Desc) {
		char* path = void;
		_alpm_log(db.handle, ALPM_LOG_DEBUG,
				"writing %s-%s DESC information back to db\n",
				info.getName(), info.getVersion());
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
						~ "%%VERSION%%\n%s\n\n", cast(char*)info.getName().toStringz, cast(char*)info.getVersion());
		if(info.getBase()) {
			fprintf(fp, "%%BASE%%\n"
							~ "%s\n\n", cast(char*)info.getBase().toStringz);
		}
		if(info.getDesc()) {
			fprintf(fp, "%%DESC%%\n"
							~ "%s\n\n", cast(char*)info.getDesc());
		}
		if(info.getUrl()) {
			fprintf(fp, "%%URL%%\n"
							~ "%s\n\n", cast(char*)info.getUrl());
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
		if(info.getPackager()) {
			fprintf(fp, "%%PACKAGER%%\n"
							~ "%s\n\n", cast(char*)info.getPackager());
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
				fputs(cast(  char*)_lp, fp);
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
			if(info.validation & AlpmPkgValidation.None) {
				fputs("none\n", fp);
			}
			if(info.validation & AlpmPkgValidation.MD5) {
				fputs("md5\n", fp);
			}
			if(info.validation & AlpmPkgValidation.SHA256) {
				fputs("sha256\n", fp);
			}
			if(info.validation & AlpmPkgValidation.Signature) {
				fputs("pgp\n", fp);
			}
			fputc('\n', fp);
		}

		write_deps_n(fp, cast(char*)"%REPLACES%", info.replaces);
		write_deps_n(fp, cast(char*)"%DEPENDS%", info.depends);
		write_deps_n(fp, cast(char*)"%OPTDEPENDS%", info.optdepends);
		write_deps_n(fp, cast(char*)"%CONFLICTS%", info.conflicts);
		write_deps_n(fp, cast(char*)"%PROVIDES%", info.provides);

		if(!info.xdata.empty) {
			fputs("%XDATA%\n", fp);
			foreach(pxd; info.xdata[]) {
				// AlpmPkgXData* pd = cast(AlpmPkgXData*)&_lp.data;
				fprintf(fp, "%s=%s\n", cast(char*)pxd.name, cast(char*)pxd.value.ptr);
			}
			fputc('\n', fp);
		}

		fclose(fp);
		fp = null;
	}

	/* FILES */
	if(inforeq & AlpmDBInfRq.Files) {
		char* path = void;
		_alpm_log(db.handle, ALPM_LOG_DEBUG,
				"writing %s-%s FILES information back to db\n",
				info.getName(), info.getVersion());
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
				fprintf(fp, cast(char*)backup.toString().toStringz);
				
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
	ASSERT(pkg !is null);
	ASSERT(pkg.origin == AlpmPkgFrom.LocalDB);
	ASSERT(pkg.getOriginDB() == pkg.getHandle().getDBLocal);

	_alpm_log(pkg.getHandle(), ALPM_LOG_DEBUG,
			"setting install reason %u for %s\n", reason, pkg.getName());
	if(pkg.getReason() == reason) {
		/* we are done */
		return 0;
	}
	/* set reason (in pkgcache) */
	pkg.reason = reason;
	/* write DESC */
	if(_alpm_local_db_write(pkg.getHandle().getDBLocal, pkg, AlpmDBInfRq.Desc)) {
		RET_ERR(pkg.getHandle(), ALPM_ERR_DB_WRITE, -1);
	}

	return 0;
}

// private  const(db_operations) local_db_ops = {
// 	validate: &local_db_validate,
// 	populate: &local_db_populate,
// 	// unregister: &_alpm_db_unregister,
// };

AlpmDB _alpm_db_register_local(AlpmHandle handle)
{
	AlpmDB db = void;

	logger.tracef("registering local database\n");

	db = new AlpmDBLocal("local");
	if(db is null) {
		handle.pm_errno = ALPM_ERR_DB_CREATE;
		return null;
	}
	// db.ops = &local_db_ops;
	db.handle = handle;
	db.usage = AlpmDBUsage.All;

	if(db.validate()) {
		// throw new Exception("Cant validate");
		/* pm_errno set in local_db_validate() */
		// _alpm_db_free(db);
		db = null;
		return null;
	}

	handle.getDBLocal = db;
	return db;
}

AlpmPkgChangelog openChangelog(AlpmPkg pkg) {
	AlpmPkgChangelog changelog;
	archive* _archive;
	archive_entry* entry;
	stat_t buf = void;
	int fd = void;

	fd = _alpm_open_archive(pkg.getHandle(), cast(char*)pkg.getOriginFile(), &buf,
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
