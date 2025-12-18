module libalpmd.db.be_sync;

import core.stdc.config: c_long, c_ulong;
/*
 *  be_sync.c : backend for sync databases
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

import core.stdc.errno;
import core.sys.posix.sys.types;
import core.sys.posix.sys.stat;
import core.sys.posix.fcntl;
import core.stdc.limits;
import core.sys.posix.unistd;
import core.stdc.string;
import std.conv;
import core.stdc.stdio;
/* libarchive */
import hlogger;
import derelict.libarchive;
// import archive;
// import archive_entry;

/* libalpm */
import libalpmd.util;
import libalpmd.log;
import libalpmd.libarchive_compat;
import libalpmd.alpm;
import libalpmd.alpm_list;
import libalpmd.pkg;
import libalpmd.handle;
import libalpmd.deps;
import libalpmd.dload;
import libalpmd.file;
import libalpmd.db;
import core.stdc.stdlib;
import libalpmd.pkghash;
import libalpmd.error;
import std.string;
import libalpmd.event;

class AlpmDBSync : AlpmDB {

	this(string treename) {
		super(treename);
		this.status &= ~AlpmDBStatus.Local;
	}

	override int validate() {
		int siglevel = void;
		char*dbpath = void;

		AlpmDB db = this;

		if(db.status & AlpmDBStatus.Valid || db.status & AlpmDBStatus.Missing) {
			return 0;
		}
		if(db.status & AlpmDBStatus.Invalid) {
			db.handle.pm_errno = ALPM_ERR_DB_INVALID_SIG;
			return -1;
		}

		dbpath = cast(char*)db.calcPath();
		if(!dbpath) {
			/* pm_errno set in _alpm_db_path() */
			return -1;
		}

		/* we can skip any validation if the database doesn't exist */
		if(alpmAccess(db.handle, null, dbpath.to!string, R_OK) != 0 && errno == ENOENT) {
			auto event = new AlpmEventDbMissing(db.treename); 
			db.status &= ~AlpmDBStatus.Exists;
			db.status |= AlpmDBStatus.Missing;
			EVENT(db.handle, event);
			goto valid;
		}
		db.status |= AlpmDBStatus.Exists;
		db.status &= ~AlpmDBStatus.Missing;

		/* this takes into account the default verification level if UNKNOWN
		* was assigned to this db */
		siglevel = db.getSigLevel();

		if(siglevel & AlpmSigLevel.Database) {
			int retry = void, ret = void;
			do {
				retry = 0;
				alpm_siglist_t* siglist = void;
				import libalpmd.signing;
				ret = _alpm_check_pgp_helper(db.handle, dbpath, null,
						siglevel & AlpmSigLevel.DatabaseOptional, siglevel & AlpmSigLevel.DatabaseMarginalOk,
						siglevel & AlpmSigLevel.DatabaseUnknowOk, &siglist);
				if(ret) {
					retry = _alpm_process_siglist(db.handle, cast(char*)db.treename, siglist,
							siglevel & AlpmSigLevel.DatabaseOptional, siglevel & AlpmSigLevel.DatabaseMarginalOk,
							siglevel & AlpmSigLevel.DatabaseUnknowOk);
				}
				alpm_siglist_cleanup(siglist);
				free(siglist);
			} while(retry);

			if(ret) {
				db.status &= ~AlpmDBStatus.Valid;
				db.status |= AlpmDBStatus.Invalid;
				db.handle.pm_errno = ALPM_ERR_DB_INVALID_SIG;
				return 1;
			}
		}

	valid:
		db.status |= AlpmDBStatus.Valid;
		db.status &= ~AlpmDBStatus.Invalid;
		return 0;
	}	

	override int populate()
	{
		AlpmDB db = this;
		char*dbpath = void;
		size_t est_count = void, count = void;
		int fd = void;
		int ret = 0;
		int archive_ret = void;
		stat_t buf = void;
		archive* archive = void;
		archive_entry* entry = void;
		AlpmPkg pkg = null;

		if(db.status & AlpmDBStatus.Invalid) {
			RET_ERR(db.handle, ALPM_ERR_DB_INVALID, -1);
		}
		if(db.status & AlpmDBStatus.Missing) {
			RET_ERR(db.handle, ALPM_ERR_DB_NOT_FOUND, -1);
		}
		dbpath = cast(char*)db.calcPath();
		if(!dbpath) {
			/* pm_errno set in _alpm_db_path() */
			return -1;
		}

		fd = _alpm_open_archive(db.handle, dbpath, &buf,
				&archive, ALPM_ERR_DB_OPEN);
		if(fd < 0) {
			db.status &= ~AlpmDBStatus.Valid;
			db.status |= AlpmDBStatus.Invalid;
			return -1;
		}
		est_count = estimate_package_count(&buf, archive);

		/* currently only .files dbs contain file lists - make flexible when required*/
		if(strcmp(cast(char*)db.handle.dbext, ".files") == 0) {
			/* files databases are about four times larger on average */
			est_count /= 4;
		}

		db.pkgcache = new AlpmPkgHash(cast(uint)est_count);
		if(db.pkgcache is null) {
			ret = -1;
			GOTO_ERR(db.handle, ALPM_ERR_MEMORY," cleanup");
		}

		while((archive_ret = archive_read_next_header(archive, &entry)) == ARCHIVE_OK) {
			mode_t mode = archive_entry_mode(entry);
			if(!S_ISDIR(mode)) {
				/* we have desc or depends - parse it */
				if(sync_db_read(db, archive, entry, &pkg) != 0) {
					_alpm_log(db.handle, ALPM_LOG_ERROR,
							("could not parse package description file '%s' from db '%s'\n"),
							archive_entry_pathname(entry), db.treename);
					ret = -1;
				}
			}
		}
		/* the db file was successfully read, but contained errors */
		if(ret == -1) {
			db.status &= ~AlpmDBStatus.Valid;
			db.status |= AlpmDBStatus.Invalid;
			db.freePkgCache();
			GOTO_ERR(db.handle, ALPM_ERR_DB_INVALID, "cleanup");
		}
		/* reading the db file failed */
		if(archive_ret != ARCHIVE_EOF) {
			_alpm_log(db.handle, ALPM_LOG_ERROR, ("could not read db '%s' (%s)\n"),
					db.treename, archive_error_string(archive));
			db.freePkgCache();
			ret = -1;
			GOTO_ERR(db.handle, ALPM_ERR_LIBARCHIVE, "cleanup");
		}

		db.pkgcache.trySort();
		_alpm_log(db.handle, ALPM_LOG_DEBUG,
				"added %zu packages to package cache for db '%s'\n",
				count, db.treename);

	cleanup:
		_alpm_archive_read_free(archive);
		if(fd >= 0) {
			close(fd);
		}
		return ret;
	}
	
	override void unregister() {
		int found;
		void* data = void;
		handle.getDBsSync = alpm_new_list_remove(handle.getDBsSync,
				this, &_alpm_db_cmp, &data);
		
		if(data) {
			found = 1;
		}

		if(!found) {
			RET_ERR(handle, ALPM_ERR_DB_NOT_FOUND, -1);
		}
	}

	override string genPath() {
		return _path = handle.dbpath ~ this.treename ~ this.handle.dbext;
	}
}

/* Forward decl so I don't reorganize the whole file right now */


int _sync_get_validation(AlpmPkg pkg)
{
	if(pkg.validation) {
		return pkg.validation;
	}

	if(pkg.md5sum) {
		pkg.validation |= AlpmPkgValidation.MD5;
	}
	if(pkg.sha256sum) {
		pkg.validation |= AlpmPkgValidation.SHA256;
	}
	if(pkg.base64_sig) {
		pkg.validation |= AlpmPkgValidation.Signature;
	}

	if(!pkg.validation) {
		pkg.validation |= AlpmPkgValidation.None;
	}

	return pkg.validation;
}

// /** Package sync operations struct accessor. We implement this as a method
//  * because we want to reuse the majority of the default_pkg_ops struct and
//  * add only a few operations of our own on top.
//  */
//  const (pkg_operations)* get_sync_pkg_ops()
// {
// 	static pkg_operations sync_pkg_ops;
// 	static int sync_pkg_ops_initialized = 0;
// 	if(!sync_pkg_ops_initialized) {
// 		sync_pkg_ops = default_pkg_ops;
// 		sync_pkg_ops.get_validation = &_sync_get_validation;
// 		sync_pkg_ops_initialized = 1;
// 	}
// 	return &sync_pkg_ops;
// }

AlpmPkg load_pkg_for_entry(AlpmDB db,   char*entryname,  char** entry_filename, AlpmPkg likely_pkg)
{
	string pkgname = null;
	string pkgver = null;
	c_ulong pkgname_hash = void;
	AlpmPkg pkg = void;

	/* get package and db file names */
	if(entry_filename) {
		char* fname = cast(char*)strrchr(entryname, '/');
		if(fname) {
			*entry_filename = fname + 1;
		} else {
			*entry_filename = null;
		}
	}
	if(alpmSplitName(entryname.to!string, pkgname, pkgver, pkgname_hash) != 0) {
		_alpm_log(db.handle, ALPM_LOG_ERROR,
				("invalid name for database entry '%s'\n"), entryname);
		return null;
	}

	if(likely_pkg && pkgname_hash == likely_pkg.getNameHash()
			&& likely_pkg.getName() == pkgname) {
		pkg = likely_pkg;
	} else {
		pkg = db.pkgcache.find(cast(char*)pkgname);
	}
	if(pkg is null) {
		pkg = new AlpmPkg();
		if(pkg is null) {
			RET_ERR(db.handle, ALPM_ERR_MEMORY, null);
		}

		pkg.setName(pkgname);
		pkg.setVersion(pkgver.to!string);
		pkg.setNameHash(pkgname_hash);

		pkg.setOriginDB(db, AlpmPkgFrom.SyncDB);
		// pkg.ops = get_sync_pkg_ops();
		pkg.setHandle(db.handle);

		if(pkg.checkMeta() != 0) {
			destroy!false(pkg);
			RET_ERR(db.handle, ALPM_ERR_PKG_INVALID, null);
		}

		/* add to the collection */
		_alpm_log(db.handle, ALPM_LOG_FUNCTION, "adding '%s' to package cache for db '%s'\n",
				pkg.getName(), db.treename);
		if(db.pkgcache.add(pkg) is null) {
			destroy!false(pkg);
			RET_ERR(db.handle, ALPM_ERR_MEMORY, null);
		}
	} else {
		// free(pkgname);
		// free(pkgver);
	}

	return pkg;
}

/* This function doesn't work as well as one might think, as size of database
 * entries varies considerably. Adding signatures nearly doubles the size of a
 * single entry. These  current values are heavily influenced by Arch Linux;
 * databases with a single signature per package. */
size_t estimate_package_count(stat_t* st, archive* archive)
{
	int per_package = void;

	switch(_alpm_archive_filter_code(archive)) {
		case ARCHIVE_COMPRESSION_NONE:
			per_package = 3015;
			break;
		case ARCHIVE_COMPRESSION_GZIP:
		case ARCHIVE_COMPRESSION_COMPRESS:
			per_package = 464;
			break;
		case ARCHIVE_COMPRESSION_BZIP2:
			per_package = 394;
			break;
		case ARCHIVE_COMPRESSION_LZMA:
		case ARCHIVE_COMPRESSION_XZ:
			per_package = 400;
			break;
version (ARCHIVE_COMPRESSION_UU) {
		case ARCHIVE_COMPRESSION_UU:
			per_package = 3015 * 4 / 3;
			break;
}
		default:
			/* assume it is at least somewhat compressed */
			per_package = 500;
	}

	return cast(size_t)((st.st_size / per_package) + 1);
}

/* This function validates %FILENAME%. filename must be between 3 and
 * PATH_MAX characters and cannot be contain a path */
int _alpm_validate_filename(AlpmDB db,   char*pkgname,   char*filename)
{
	size_t len = strlen(filename);

	if(filename[0] == '.') {
		errno = EINVAL;
		_alpm_log(db.handle, ALPM_LOG_ERROR, ("%s database is inconsistent: filename "
					~ "of package %s is illegal\n"), db.treename, pkgname);
		return -1;
	} else if(memchr(filename, '/', len) != null) {
		errno = EINVAL;
		_alpm_log(db.handle, ALPM_LOG_ERROR, ("%s database is inconsistent: filename "
					~ "of package %s is illegal\n"), db.treename, pkgname);
		return -1;
	} else if(len > PATH_MAX) {
		errno = EINVAL;
		_alpm_log(db.handle, ALPM_LOG_ERROR, ("%s database is inconsistent: filename "
					~ "of package %s is too long\n"), db.treename, pkgname);
		return -1;
	}

	return 0;
}

enum string READ_NEXT() = `do { 
	if(_alpm_archive_fgets(archive, &buf) != ARCHIVE_OK) goto error; 
	line = buf.line; 
	_alpm_strip_newline(line, buf.real_line_size); 
} while(0);`;

enum string READ_AND_STORE_THIS(string f) = `do { 
	` ~ READ_NEXT!() ~ `; 
	char* tmp = null;
	STRDUP(tmp, line);
	`~f~`(tmp.to!string);
} while(0);`;


enum string READ_AND_STORE(string f) = `do { 
	` ~ READ_NEXT!() ~ `; 
	char* tmp = null;
	STRDUP(tmp, line);
	`~f~` = tmp.to!(typeof(`~f~`));
} while(0);`;

enum string READ_AND_STORE_N(string f) = `do { 
	` ~ READ_NEXT!() ~ `; 
	char* tmp = null;
	STRDUP(tmp, line);
	`~f~` = tmp.to!(typeof(`~f~`));
} while(0);`;


enum string READ_AND_STORE_ALL_L(string f) = `do { 
	char* linedup = void; 
	if(_alpm_archive_fgets(archive, &buf) != ARCHIVE_OK) goto error; 
	if(_alpm_strip_newline(buf.line, buf.real_line_size) == 0) break; 
	STRDUP(linedup, buf.line); 
	` ~ f ~ `.insertFront(linedup.to!string); 
} while(1); /* note the while(1) and not (0) */`;

enum string READ_AND_STORE_ALL(string f) = `do { 
	char* linedup = void; 
	if(_alpm_archive_fgets(archive, &buf) != ARCHIVE_OK) goto error; 
	if(_alpm_strip_newline(buf.line, buf.real_line_size) == 0) break; 
	STRDUP(linedup, buf.line); 
	` ~ f ~ ` = alpm_list_add(` ~ f ~ `, linedup); 
} while(1); /* note the while(1) and not (0) */`;


enum string READ_AND_SPLITDEP(string f) = `do { 
	if(_alpm_archive_fgets(archive, &buf) != ARCHIVE_OK) goto error; 
	if(_alpm_strip_newline(buf.line, buf.real_line_size) == 0) break; 
	` ~ f ~ ` = alpm_list_add(` ~ f ~ `, cast(void*)alpm_dep_from_string(line)); 
} while(1); /* note the while(1) and not (0) */`;

enum string READ_AND_SPLITDEP_N(string f) = `do { 
	if(_alpm_archive_fgets(archive, &buf) != ARCHIVE_OK) goto error; 
	if(_alpm_strip_newline(buf.line, buf.real_line_size) == 0) break; 
	` ~ f ~ `.insertFront(alpm_dep_from_string(line)); 
} while(1); /* note the while(1) and not (0) */`;


int sync_db_read(AlpmDB db, archive* archive, archive_entry* entry, AlpmPkg* likely_pkg)
{
	import std.string;
	  char*entryname = void, filename = void;
	AlpmPkg pkg = void;
	archive_read_buffer buf;

	entryname = cast(char*)archive_entry_pathname(entry);
	if(entryname == null) {
		_alpm_log(db.handle, ALPM_LOG_DEBUG,
				"invalid archive entry provided to _alpm_sync_db_read, skipping\n");
		return -1;
	}

	_alpm_log(db.handle, ALPM_LOG_FUNCTION, "loading package data from archive entry %s\n",
			entryname);

	/* 512K for a line length seems reasonable */
	buf.max_line_size = 512 * 1024;

	pkg = load_pkg_for_entry(db, entryname, &filename, *likely_pkg);

	if(pkg is null) {
		_alpm_log(db.handle, ALPM_LOG_DEBUG,
				"entry %s could not be loaded into %s sync database\n",
				entryname, db.treename);
		return -1;
	}

	if(filename == null) {
		/* A file exists outside of a subdirectory. This isn't a read error, so return
		 * success and try to continue on. */
		_alpm_log(db.handle, ALPM_LOG_WARNING, ("unknown database file: %s\n"),
				entryname);
		return 0;
	}

	if(strcmp(filename, "desc") == 0 || strcmp(filename, "depends") == 0
			|| strcmp(filename, "files") == 0) {
		int ret = void;
		while((ret = _alpm_archive_fgets(archive, &buf)) == ARCHIVE_OK) {
			char* line = buf.line;
			if(_alpm_strip_newline(line, buf.real_line_size) == 0) {
				/* length of stripped line was zero */
				continue;
			}

			if(strcmp(line, "%NAME%") == 0) {
				mixin(READ_NEXT!());
				if(strcmp(line, cast(char*)pkg.getName()) != 0) {
					_alpm_log(db.handle, ALPM_LOG_ERROR, ("%s database is inconsistent: name "
								~ "mismatch on package %s\n"), db.treename, pkg.getName());
				}
			} else if(strcmp(line, "%VERSION%") == 0) {
				mixin(READ_NEXT!());
				if(strcmp(line, cast(char*)pkg.getVersion()) != 0) {
					_alpm_log(db.handle, ALPM_LOG_ERROR, ("%s database is inconsistent: version "
								~ "mismatch on package %s\n"), db.treename, pkg.getName());
				}
			} else if(strcmp(line, "%FILENAME%") == 0) {
				auto pkgfilename = cast(char*)pkg.getFilename().ptr;
				mixin(READ_AND_STORE!(`pkgfilename`));
				if(_alpm_validate_filename(db, cast(char*)pkg.getName(), cast(char*)pkg.getFilename().toStringz) < 0) {
					return -1;
				}
			} else if(strcmp(line, "%BASE%") == 0) {
				mixin(READ_AND_STORE_THIS!(`pkg.setBase`));
			} else if(strcmp(line, "%DESC%") == 0) {
				mixin(READ_AND_STORE_THIS!(`pkg.setDesc`));
			} else if(strcmp(line, "%GROUPS%") == 0) {
				mixin(READ_AND_STORE_ALL_L!(`pkg.groups`));
			} else if(strcmp(line, "%URL%") == 0) {
				mixin(READ_AND_STORE_THIS!(`pkg.setUrl`));
			} else if(strcmp(line, "%LICENSE%") == 0) {
				mixin(READ_AND_STORE_ALL_L!(`pkg.licenses`));
			} else if(strcmp(line, "%ARCH%") == 0) {
				mixin(READ_AND_STORE!(`pkg.arch`));
			} else if(strcmp(line, "%BUILDDATE%") == 0) {
				mixin(READ_NEXT!());
				pkg.builddate = alpmParseDate(line.to!string);
			} else if(strcmp(line, "%PACKAGER%") == 0) {
				mixin(READ_AND_STORE_THIS!(`pkg.setPackager`));
			} else if(strcmp(line, "%CSIZE%") == 0) {
				mixin(READ_NEXT!());
				pkg.setSize(alpmStrToOfft(line.to!string));
			} else if(strcmp(line, "%ISIZE%") == 0) {
				mixin(READ_NEXT!());
				pkg.isize = alpmStrToOfft(line.to!string);
			} else if(strcmp(line, "%MD5SUM%") == 0) {
				mixin(READ_AND_STORE!(`pkg.md5sum`));
			} else if(strcmp(line, "%SHA256SUM%") == 0) {
				mixin(READ_AND_STORE!(`pkg.sha256sum`));
			} else if(strcmp(line, "%PGPSIG%") == 0) {
				mixin(READ_AND_STORE!(`pkg.base64_sig`));
			} else if(strcmp(line, "%REPLACES%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`pkg.replaces`));
			} else if(strcmp(line, "%DEPENDS%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`pkg.depends`));
			} else if(strcmp(line, "%OPTDEPENDS%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`pkg.optdepends`));
			} else if(strcmp(line, "%MAKEDEPENDS%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`pkg.makedepends`));
			} else if(strcmp(line, "%CHECKDEPENDS%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`pkg.checkdepends`));
			} else if(strcmp(line, "%CONFLICTS%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`pkg.conflicts`));
			} else if(strcmp(line, "%PROVIDES%") == 0) {
				mixin(READ_AND_SPLITDEP_N!(`pkg.provides`));
			} else if(strcmp(line, "%FILES%") == 0) {
				/* TODO: this could lazy load if there is future demand */
				size_t files_count = 0, files_size = 0;
				AlpmFileList files = null;

				while(1) {
					if(_alpm_archive_fgets(archive, &buf) != ARCHIVE_OK) {
						goto error;
					}
					line = buf.line;
					if(_alpm_strip_newline(line, buf.real_line_size) == 0) {
						break;
					}
					files.length++;
					files[files_count].name = line.to!string;
					files_count++;
				}
				/* attempt to hand back any memory we don't need */
				if(files_count == 0)
					FREE(files);
				// pkg.files.length = files_count;
				pkg.files = files[0..files_count].dup;
				_alpm_filelist_sort(pkg.files);
			} else if(strcmp(line, "%DATA%") == 0) {
				AlpmStrings lines;
				mixin(READ_AND_STORE_ALL_L!(`lines`));
				foreach(line_; lines[]) {
					AlpmPkgXData pd = AlpmPkgXData.parseFrom(line_.to!string);
					if(!alpm_new_list_append(&pkg.xdata, pd)) {			
						// _alpm_pkg_xdata_free(pd);
						// FREELIST(lines);
						goto error;
					}
				}
				// FREELIST(lines);
			} else {
				_alpm_log(db.handle, ALPM_LOG_WARNING, ("%s: unknown key '%s' in sync database\n"), pkg.getName(), line);
				AlpmStrings lines;
				mixin(READ_AND_STORE_ALL_L!(`lines`));
				// FREELIST(lines);
			}
		}
		if(ret != ARCHIVE_EOF) {
			goto error;
		}
		*likely_pkg = pkg;
	} else {
		/* unknown database file */
		_alpm_log(db.handle, ALPM_LOG_DEBUG, "unknown database file: %s\n", filename);
	}

	return 0;

error:
	_alpm_log(db.handle, ALPM_LOG_DEBUG, "error parsing database file: %s\n", filename);
	return -1;
}

// db_operations sync_db_ops = {
// 	validate: &sync_db_validate,
// 	populate: &sync_db_populate,
// 	// unregister: &_alpm_db_unregister,
// };

AlpmDB _alpm_db_register_sync(AlpmHandle handle,   char*treename, int level)
{
	AlpmDB db = void;

	logger.trace("registering sync database ", treename.to!string);
	// logger.tracef("registering sync database '%s'\n", treename);

version (HAVE_LIBGPGME) {} else {
	if(level != 0 && level != AlpmSigLevel.UseDefault) {
		RET_ERR(handle, ALPM_ERR_MISSING_CAPABILITY_SIGNATURES, null);
	}
}

	db = new AlpmDBSync(treename.to!string);
	if(db is null) {
		RET_ERR(handle, ALPM_ERR_DB_CREATE, null);
	}
	// db.ops = &sync_db_ops;
	db.handle = handle;
	db.siglevel = level;

	// sync_db_validate(db);

	handle.getDBsSync.insertBack(db);
	return db;
}
