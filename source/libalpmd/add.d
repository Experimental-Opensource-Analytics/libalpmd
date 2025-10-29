module libalpmd.add;

import core.stdc.stdlib;
import core.stdc.stdio;
import core.stdc.errno;
import core.stdc.string;
import std.conv;
import core.stdc.limits;
import core.sys.posix.fcntl;
import core.sys.posix.sys.types;
import core.sys.posix.time;
import core.sys.posix.sys.stat;
import core.sys.posix.unistd;
import core.stdc.stdint; /* int64_t */
import derelict.libarchive;
import std.string;
import libalpmd.add;
import libalpmd.alpm;
import libalpmd.alpm_list;
import libalpmd.handle;
import libalpmd.libarchive_compat;
import libalpmd.trans;
import libalpmd.util;
import libalpmd.log;
import libalpmd.backup;
import libalpmd._package;
import libalpmd.db;
import libalpmd.remove;
import libalpmd.handle;

import libalpmd.be_local;

int  alpm_add_pkg(AlpmHandle handle, AlpmPkg pkg)
{
	  char*pkgname = void, pkgver = void;
	alpm_trans_t* trans = void;
	AlpmPkg local = void;
	AlpmPkg dup = void;

	/* Sanity checks */
	CHECK_HANDLE(handle);
	//ASSERT(pkg != null);
	//ASSERT(pkg.origin != ALPM_PKG_FROM_LOCALDB);
	//ASSERT(handle == pkg.handle);
	trans = handle.trans;
	//ASSERT(trans != null);
	//ASSERT(trans.state == STATE_INITIALIZED);

	pkgname = pkg.name;
	pkgver = pkg.version_;

	_alpm_log(handle, ALPM_LOG_DEBUG, "adding package '%s'\n", pkgname);

	if((dup = alpm_pkg_find(trans.add, pkgname)) !is null ) {
		if(dup == pkg) {
			_alpm_log(handle, ALPM_LOG_DEBUG, "skipping duplicate target: %s\n", pkgname);
			return 0;
		}
		/* error for separate packages with the same name */
		RET_ERR(handle, ALPM_ERR_TRANS_DUP_TARGET, -1);
	}

	if((local = _alpm_db_get_pkgfromcache(handle.db_local, pkgname)) !is null) {
		  char*localpkgname = local.name;
		  char*localpkgver = local.version_;
		int cmp = _alpm_pkg_compare_versions(pkg, local);

		if(cmp == 0) {
			if(trans.flags & ALPM_TRANS_FLAG_NEEDED) {
				/* with the NEEDED flag, packages up to date are not reinstalled */
				_alpm_log(handle, ALPM_LOG_WARNING, ("%s-%s is up to date -- skipping\n"),
						localpkgname, localpkgver);
				return 0;
			} else if(!(trans.flags & ALPM_TRANS_FLAG_DOWNLOADONLY)) {
				_alpm_log(handle, ALPM_LOG_WARNING, ("%s-%s is up to date -- reinstalling\n"),
						localpkgname, localpkgver);
			}
		} else if(cmp < 0 && !(trans.flags & ALPM_TRANS_FLAG_DOWNLOADONLY)) {
			/* local version is newer */
			_alpm_log(handle, ALPM_LOG_WARNING, ("downgrading package %s (%s => %s)\n"),
					localpkgname, localpkgver, pkgver);
		}
	}

	/* add the package to the transaction */
	pkg.reason = ALPM_PKG_REASON_EXPLICIT;
	_alpm_log(handle, ALPM_LOG_DEBUG, "adding package %s-%s to the transaction add list\n",
						pkgname, pkgver);
	trans.add = alpm_list_add(trans.add, cast(void*)pkg);

	return 0;
}

private int perform_extraction(AlpmHandle handle, archive* _archive, archive_entry* entry,  char* filename)
{
	int ret = void;
	archive* archive_writer = void;
	 const (int) archive_flags = ARCHIVE_EXTRACT_OWNER |
	                          ARCHIVE_EXTRACT_PERM |
	                          ARCHIVE_EXTRACT_TIME |
	                          ARCHIVE_EXTRACT_UNLINK |
	                          ARCHIVE_EXTRACT_XATTR |
	                          ARCHIVE_EXTRACT_SECURE_SYMLINKS;

	archive_entry_set_pathname(entry, filename);

	archive_writer = archive_write_disk_new();
	if (archive_writer == null) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("cannot allocate disk archive object"));
		//alpm_logaction(handle, ALPM_CALLER_PREFIX,
				// "error: cannot allocate disk archive object");
		return 1;
	}

	archive_write_disk_set_options(archive_writer, archive_flags);

	ret = archive_read_extract2(_archive, entry, archive_writer);

	archive_write_free(archive_writer);

	if(ret == ARCHIVE_WARN && archive_errno(_archive) != ENOSPC) {
		/* operation succeeded but a "non-critical" error was encountered */
		_alpm_log(handle, ALPM_LOG_WARNING, ("warning given when extracting %s (%s)\n"),
				filename, archive_error_string(_archive));
	} else if(ret != ARCHIVE_OK) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not extract %s (%s)\n"),
				filename, archive_error_string(_archive));
		//alpm_logaction(handle, ALPM_CALLER_PREFIX,
				// "error: could not extract %s (%s)\n" ,
				// filename, archive_error_string(_archive));
		return 1;
	}
	return 0;
}

private int try_rename(AlpmHandle handle,   char*src,   char*dest)
{
	if(rename(src, dest)) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not rename %s to %s (%s)\n"),
				src, dest, strerror(errno));
		//alpm_logaction(handle, ALPM_CALLER_PREFIX,
		//		"error: could not rename %s to %s (%s)\n" , src, dest, strerror(errno));
		return 1;
	}
	return 0;
}

private int extract_db_file(AlpmHandle handle, archive* archive, archive_entry* entry, AlpmPkg newpkg,   char*entryname)
{
	char[PATH_MAX] filename = void; /* the actual file we're extracting */
	  char*dbfile = null;
	if(strcmp(entryname, ".INSTALL") == 0) {
		dbfile = cast(char*)"install";
	} else if(strcmp(entryname, ".CHANGELOG") == 0) {
		dbfile = cast(char*)"changelog";
	} else if(strcmp(entryname, ".MTREE") == 0) {
		dbfile = cast(char*)"mtree";
	} else if(*entryname == '.') {
		/* reserve all files starting with '.' for future possibilities */
		_alpm_log(handle, ALPM_LOG_DEBUG, "skipping extraction of '%s'\n", entryname);
		archive_read_data_skip(archive);
		return 0;
	}
	archive_entry_set_perm(entry, octal!"0644");
	snprintf(filename.ptr, PATH_MAX, "%s%s-%s/%s",
			cast(char*)_alpm_db_path(handle.db_local), newpkg.name, newpkg.version_, dbfile);
	return perform_extraction(handle, archive, entry, filename.ptr);
}

int extract_single_file(AlpmHandle handle, archive* archive, archive_entry* entry, AlpmPkg newpkg, AlpmPkg oldpkg)
{
	char*entryname = cast(char*)archive_entry_pathname(entry);
	mode_t entrymode = archive_entry_mode(entry);
	alpm_backup_t* backup = _alpm_needbackup(entryname, newpkg);
	char[PATH_MAX] filename = void; /* the actual file we're extracting */
	int needbackup = 0, notouch = 0;
	  char*hash_orig = null;
	int isnewfile = 0, errors = 0;
	stat_t lsbuf = void;
	size_t filename_len = void;

// 	if(*entryname == '.') {
// 		return extract_db_file(handle, archive, entry, newpkg, entryname);
// 	}

// 	if (!alpm_filelist_contains(&newpkg.files, entryname)) {
// 		_alpm_log(handle, ALPM_LOG_WARNING,
// 				("file not found in file list for package %s. skipping extraction of %s\n"),
// 				newpkg.name, entryname);
// 		return 0;
// 	}

// 	/* build the new entryname relative to handle->root */
// 	filename_len = snprintf(filename.ptr, PATH_MAX, "%s%s", handle.root, entryname);
// 	if(filename_len >= PATH_MAX) {
// 		_alpm_log(handle, ALPM_LOG_ERROR,
// 				("unable to extract %s%s: path too long"), handle.root, entryname);
// 		return 1;
// 	}

// 	/* if a file is in NoExtract then we never extract it */
// 	if(_alpm_fnmatch_patterns(handle.noextract, entryname) == 0) {
// 		_alpm_log(handle, ALPM_LOG_DEBUG, "%s is in NoExtract,"
// 				~ " skipping extraction of %s\n",
// 				entryname, filename.ptr);
// 		archive_read_data_skip(archive);
// 		return 0;
// 	}

// 	/* Check for file existence. This is one of the more crucial parts
// 	 * to get 'right'. Here are the possibilities, with the filesystem
// 	 * on the left and the package on the top:
// 	 * (F=file, N=node, S=symlink, D=dir)
// 	 *               |  F/N  |   D
// 	 *  non-existent |   1   |   2
// 	 *  F/N          |   3   |   4
// 	 *  D            |   5   |   6
// 	 *
// 	 *  1,2- extract, no magic necessary. lstat (llstat) will fail here.
// 	 *  3,4- conflict checks should have caught this. either overwrite
// 	 *      or backup the file.
// 	 *  5- file replacing directory- don't allow it.
// 	 *  6- skip extraction, dir already exists.
// 	 */

// 	isnewfile = lstat(filename.ptr, &lsbuf) != 0;
// 	if(isnewfile) {
// 		/* cases 1,2: file doesn't exist, skip all backup checks */
// 	} else if(S_ISDIR(lsbuf.st_mode) && S_ISDIR(entrymode)) {
// version (none) {
// 		uid_t entryuid = archive_entry_uid(entry);
// 		gid_t entrygid = archive_entry_gid(entry);
// }

// 		/* case 6: existing dir, ignore it */
// 		if(lsbuf.st_mode != entrymode) {
// 			/* if filesystem perms are different than pkg perms, warn user */
// 			mode_t mask = octal!"07777";
// 			_alpm_log(handle, ALPM_LOG_WARNING, ("directory permissions differ on %s\n"
// 					~ "filesystem: %o  package: %o\n"), filename.ptr, lsbuf.st_mode & mask,
// 					entrymode & mask);
// 			//alpm_logaction(handle, ALPM_CALLER_PREFIX,
// 					"warning: directory permissions differ on %s, "
// 					~ "filesystem: %o  package: %o\n", filename.ptr, lsbuf.st_mode & mask,
// 					entrymode & mask);
// 		}

// version (none) {
// 		/* Disable this warning until our user management in packages has improved.
// 		   Currently many packages have to create users in post_install and chown the
// 		   directories. These all resulted in "false-positive" warnings. */

// 		if((entryuid != lsbuf.st_uid) || (entrygid != lsbuf.st_gid)) {
// 			_alpm_log(handle, ALPM_LOG_WARNING, ("directory ownership differs on %s\n"
// 					~ "filesystem: %u:%u  package: %u:%u\n"), filename.ptr,
// 					lsbuf.st_uid, lsbuf.st_gid, entryuid, entrygid);
// 			//alpm_logaction(handle, ALPM_CALLER_PREFIX,
// 					"warning: directory ownership differs on %s, "
// 					~ "filesystem: %u:%u  package: %u:%u\n", filename.ptr,
// 					lsbuf.st_uid, lsbuf.st_gid, entryuid, entrygid);
// 		}
// }

// 		_alpm_log(handle, ALPM_LOG_DEBUG, "extract: skipping dir extraction of %s\n",
// 				filename.ptr);
// 		archive_read_data_skip(archive);
// 		return 0;
// 	} else if(S_ISDIR(lsbuf.st_mode)) {
// 		/* case 5: trying to overwrite dir with file, don't allow it */
// 		_alpm_log(handle, ALPM_LOG_ERROR, ("extract: not overwriting dir with file %s\n"),
// 				filename.ptr);
// 		archive_read_data_skip(archive);
// 		return 1;
// 	} else if(S_ISDIR(entrymode)) {
// 		/* case 4: trying to overwrite file with dir */
// 		_alpm_log(handle, ALPM_LOG_DEBUG, "extract: overwriting file with dir %s\n",
// 				filename.ptr);
// 	} else {
// 		/* case 3: trying to overwrite file with file */
// 		/* if file is in NoUpgrade, don't touch it */
// 		if(_alpm_fnmatch_patterns(handle.noupgrade, entryname) == 0) {
// 			notouch = 1;
// 		} else {
// 			alpm_backup_t* oldbackup = void;
// 			if(oldpkg && cast(bool)(oldbackup = _alpm_needbackup(entryname, oldpkg))) {
// 				hash_orig = oldbackup.hash;
// 				needbackup = 1;
// 			} else if(backup) {
// 				/* allow adding backup files retroactively */
// 				needbackup = 1;
// 			}
// 		}
// 	}

// 	if(notouch || needbackup) {
// 		if(filename_len + strlen(".pacnew") >= PATH_MAX) {
// 			_alpm_log(handle, ALPM_LOG_ERROR,
// 					("unable to extract %s.pacnew: path too long"), filename.ptr);
// 			return 1;
// 		}
// 		strcpy(filename.ptr + filename_len, ".pacnew");
// 		isnewfile = (lstat(filename.ptr, &lsbuf) != 0 && errno == ENOENT);
// 	}

// 	_alpm_log(handle, ALPM_LOG_DEBUG, "extracting %s\n", filename.ptr);
// 	if(perform_extraction(handle, archive, entry, filename.ptr)) {
// 		errors++;
// 		return errors;
// 	}

// 	if(backup) {
// 		FREE(backup.hash);
// 		backup.hash = alpm_compute_md5sum(filename.ptr);
// 	}

// 	if(notouch) {
// 		alpm_event_pacnew_created_t event = {
// 			type: ALPM_EVENT_PACNEW_CREATED,
// 			from_noupgrade: 1,
// 			oldpkg: oldpkg,
// 			newpkg: newpkg,
// 			file: cast(  char*)filename.
// 		};
// 		/* "remove" the .pacnew suffix */
// 		filename[filename_len] = '\0';
// 		EVENT(handle, &event);
// 		//alpm_logaction(handle, ALPM_CALLER_PREFIX,
// 				"warning: %s installed as %s.pacnew\n", filename.ptr, filename.ptr);
// 	} 
// 	if (needbackup) {
// 		char* hash_local = null, hash_pkg = null;
// 		char[PATH_MAX] origfile = "";

// 		strncat(origfile.ptr, filename.ptr, filename_len);

// 		hash_local = alpm_compute_md5sum(origfile.ptr);
// 		hash_pkg = cast(char*) backup ? backup.hash : alpm_compute_md5sum(filename.ptr);

// 		_alpm_log(handle, ALPM_LOG_DEBUG, "checking hashes for %s\n", origfile.ptr);
// 		_alpm_log(handle, ALPM_LOG_DEBUG, "current:  %s\n", hash_local);
// 		_alpm_log(handle, ALPM_LOG_DEBUG, "new:      %s\n", hash_pkg);
// 		_alpm_log(handle, ALPM_LOG_DEBUG, "original: %s\n", hash_orig);

// 		if(hash_local && hash_pkg && strcmp(hash_local, hash_pkg) == 0) {
// 			/* local and new files are the same, updating anyway to get
// 			 * correct timestamps */
// 			_alpm_log(handle, ALPM_LOG_DEBUG, "action: installing new file: %s\n",
// 					origfile.ptr);
// 			if(try_rename(handle, filename.ptr, origfile.ptr)) {
// 				errors++;
// 			}
// 		} else if(hash_orig && hash_pkg && strcmp(hash_orig, hash_pkg) == 0) {
// 			/* original and new files are the same, leave the local version alone,
// 			 * including any user changes */
// 			_alpm_log(handle, ALPM_LOG_DEBUG,
// 					"action: leaving existing file in place\n");
// 			if(isnewfile) {
// 				unlink(filename.ptr);
// 			}
// 		} else if(hash_orig && hash_local && strcmp(hash_orig, hash_local) == 0) {
// 			/* installed file has NOT been changed by user,
// 			 * update to the new version */
// 			_alpm_log(handle, ALPM_LOG_DEBUG, "action: installing new file: %s\n",
// 					origfile.ptr);
// 			if(try_rename(handle, filename.ptr, origfile.ptr)) {
// 				errors++;
// 			}
// 		} else {
// 			/* none of the three files matched another,  leave the unpacked
// 			 * file alongside the local file */
// 			alpm_event_pacnew_created_t event = {
// 				type: ALPM_EVENT_PACNEW_CREATED,
// 				from_noupgrade: 0,
// 				oldpkg: oldpkg,
// 				newpkg: newpkg,
// 				file: origfile
// 			};
// 			_alpm_log(handle, ALPM_LOG_DEBUG,
// 					"action: keeping current file and installing"
// 					~ " new one with .pacnew ending\n");
// 			EVENT(handle, &event);
// 			//alpm_logaction(handle, ALPM_CALLER_PREFIX,
// 					"warning: %s installed as %s\n", origfile.ptr, filename.ptr);
// 		}

// 		free(hash_local);
// 		if(!backup) {
// 			free(hash_pkg);
// 		}
// 	}
	return errors;
}

int commit_single_pkg(AlpmHandle handle, AlpmPkg newpkg, size_t pkg_current, size_t pkg_count)
{
	int ret = 0, errors = 0;
	int is_upgrade = 0;
	AlpmPkg oldpkg = null;
	AlpmDB db = handle.db_local;
	alpm_trans_t* trans = handle.trans;
	alpm_progress_t progress = ALPM_PROGRESS_ADD_START;
	alpm_event_package_operation_t event = void;
	  char*log_msg = cast(char*)"adding";
	  char*pkgfile = void;
	archive* archive = void;
	archive_entry* entry = void;
	int fd = void, cwdfd = void;
	stat_t buf = void;

	//ASSERT(trans != null);

	/* see if this is an upgrade. if so, remove the old package first */
	if(_alpm_db_get_pkgfromcache(db, newpkg.name) && (oldpkg = newpkg.oldpkg) !is null) {
		int cmp = _alpm_pkg_compare_versions(newpkg, oldpkg);
		if(cmp < 0) {
			log_msg = cast(char*)"downgrading";
			progress = ALPM_PROGRESS_DOWNGRADE_START;
			event.operation = ALPM_PACKAGE_DOWNGRADE;
		} else if(cmp == 0) {
			log_msg = cast(char*)"reinstalling";
			progress = ALPM_PROGRESS_REINSTALL_START;
			event.operation = ALPM_PACKAGE_REINSTALL;
		} else {
			log_msg = cast(char*)"upgrading";
			progress = ALPM_PROGRESS_UPGRADE_START;
			event.operation = ALPM_PACKAGE_UPGRADE;
		}
		is_upgrade = 1;

		/* copy over the install reason */
		newpkg.reason = alpm_pkg_get_reason(oldpkg);
	} else {
		event.operation = ALPM_PACKAGE_INSTALL;
	}

	event.type = ALPM_EVENT_PACKAGE_OPERATION_START;
	event.oldpkg = oldpkg;
	event.newpkg = newpkg;
	EVENT(handle, &event);

	pkgfile = newpkg.origin_data.file;

	_alpm_log(handle, ALPM_LOG_DEBUG, "%s package %s-%s\n",
			log_msg, newpkg.name, newpkg.version_);
		/* pre_install/pre_upgrade scriptlet */
	if(alpm_pkg_has_scriptlet(newpkg) &&
			!(trans.flags & ALPM_TRANS_FLAG_NOSCRIPTLET)) {
		  char*scriptlet_name = cast(char*)(is_upgrade ? "pre_upgrade" : "pre_install");

		_alpm_runscriptlet(handle, pkgfile, scriptlet_name,
				newpkg.version_, oldpkg ? oldpkg.version_ : null, 1);
	}

	/* we override any pre-set reason if we have alldeps or allexplicit set */
	if(trans.flags & ALPM_TRANS_FLAG_ALLDEPS) {
		newpkg.reason = ALPM_PKG_REASON_DEPEND;
	} else if(trans.flags & ALPM_TRANS_FLAG_ALLEXPLICIT) {
		newpkg.reason = ALPM_PKG_REASON_EXPLICIT;
	}

	if(oldpkg) {
		/* set up fake remove transaction */
		if(_alpm_remove_single_package(handle, oldpkg, newpkg, 0, 0) == -1) {
			handle.pm_errno = ALPM_ERR_TRANS_ABORT;
			return -1;
		}
	}

	/* prepare directory for database entries so permissions are correct after
	   changelog/install script installation */
	if(_alpm_local_db_prepare(db, newpkg)) {
		//alpm_logaction(handle, ALPM_CALLER_PREFIX,
				// "error: could not create database entry %s-%s\n",
				// newpkg.name, newpkg.version_);
		handle.pm_errno = ALPM_ERR_DB_WRITE;
		return -1;
	}

	fd = _alpm_open_archive(db.handle, pkgfile, &buf,
			&archive, ALPM_ERR_PKG_OPEN);
	if(fd < 0) {
		return -1;
	}

	/* save the cwd so we can restore it later */
	OPEN(cwdfd, cast(char*)".", O_RDONLY | O_CLOEXEC);
	if(cwdfd < 0) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not get current working directory\n"));
	}

	/* libarchive requires this for extracting hard links */
	if(chdir(handle.root) != 0) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not change directory to %s (%s)\n"),
				handle.root, strerror(errno));
		_alpm_archive_read_free(archive);
		if(cwdfd >= 0) {
			close(cwdfd);
		}
		close(fd);
		return -1;
	}

	if(trans.flags & ALPM_TRANS_FLAG_DBONLY) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "extracting db files\n");
		while(archive_read_next_header(archive, &entry) == ARCHIVE_OK) {
			  char*entryname = cast(char*)archive_entry_pathname(entry);
			if(entryname[0] == '.') {
				errors += extract_db_file(handle, archive, entry, newpkg, entryname);
			} else {
				archive_read_data_skip(archive);
			}
		}
	} else {
		_alpm_log(handle, ALPM_LOG_DEBUG, "extracting files\n");

		/* call PROGRESS once with 0 percent, as we sort-of skip that here */
		PROGRESS(handle, progress, newpkg.name, 0, pkg_count, pkg_current);

		while(archive_read_next_header(archive, &entry) == ARCHIVE_OK) {
			int percent = void;

			if(newpkg.size != 0) {
				/* Using compressed size for calculations here, as newpkg->isize is not
				 * exact when it comes to comparing to the ACTUAL uncompressed size
				 * (missing metadata sizes) */
				long pos = _alpm_archive_compressed_ftell(archive);
				percent = cast(int)((pos * 100) / newpkg.size);
				if(percent >= 100) {
					percent = 100;
				}
			} else {
				percent = 0;
			}

			PROGRESS(handle, progress, newpkg.name, percent, pkg_count, pkg_current);

			/* extract the next file from the archive */
			errors += extract_single_file(handle, archive, entry, newpkg, oldpkg);
		}
	}

	_alpm_archive_read_free(archive);
	close(fd);

	/* restore the old cwd if we have it */
	if(cwdfd >= 0) {
		if(fchdir(cwdfd) != 0) {
			_alpm_log(handle, ALPM_LOG_ERROR,
					("could not restore working directory (%s)\n"), strerror(errno));
		}
		close(cwdfd);
	}

	if(errors) {
		ret = -1;
		if(is_upgrade) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("problem occurred while upgrading %s\n"),
					newpkg.name);
			//alpm_logaction(handle, ALPM_CALLER_PREFIX,
					// "error: problem occurred while upgrading %s\n",
					// newpkg.name);
		} else {
			_alpm_log(handle, ALPM_LOG_ERROR, ("problem occurred while installing %s\n"),
					newpkg.name);
			//alpm_logaction(handle, ALPM_CALLER_PREFIX,
					// "error: problem occurred while installing %s\n",
					// newpkg.name);
		}
	}

	/* make an install date (in UTC) */
	newpkg.installdate = time(null);

	_alpm_log(handle, ALPM_LOG_DEBUG, "updating database\n");
	_alpm_log(handle, ALPM_LOG_DEBUG, "adding database entry '%s'\n", newpkg.name);

	if(_alpm_local_db_write(db, newpkg, INFRQ_ALL)) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not update database entry %s-%s\n"),
				newpkg.name, newpkg.version_);
		//alpm_logaction(handle, ALPM_CALLER_PREFIX,
				// "error: could not update database entry %s-%s\n",
				// newpkg.name, newpkg.version_);
		handle.pm_errno = ALPM_ERR_DB_WRITE;
		return -1;
	}

	if(_alpm_db_add_pkgincache(db, newpkg) == -1) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not add entry '%s' in cache\n"),
				newpkg.name);
	}

	PROGRESS(handle, progress, newpkg.name, 100, pkg_count, pkg_current);

	switch(event.operation) {
		case ALPM_PACKAGE_INSTALL:
			//alpm_logaction(handle, ALPM_CALLER_PREFIX, "installed %s (%s)\n",
					// newpkg.name, newpkg.version_);
			break;
		case ALPM_PACKAGE_DOWNGRADE:
			//alpm_logaction(handle, ALPM_CALLER_PREFIX, "downgraded %s (%s -> %s)\n",
					// newpkg.name, oldpkg.version_, newpkg.version_);
			break;
		case ALPM_PACKAGE_REINSTALL:
			//alpm_logaction(handle, ALPM_CALLER_PREFIX, "reinstalled %s (%s)\n",
					// newpkg.name, newpkg.version_);
			break;
		case ALPM_PACKAGE_UPGRADE:
			//alpm_logaction(handle, ALPM_CALLER_PREFIX, "upgraded %s (%s -> %s)\n",
					// newpkg.name, oldpkg.version_, newpkg.version_);
			break;
		default:
			/* we should never reach here */
			break;
	}

	/* run the post-install script if it exists */
	if(alpm_pkg_has_scriptlet(newpkg)
			&& !(trans.flags & ALPM_TRANS_FLAG_NOSCRIPTLET)) {
		char* scriptlet = _alpm_local_db_pkgpath(db, newpkg, cast(char*)"install");
		  char*scriptlet_name = cast(char*)(is_upgrade ? "post_upgrade" : "post_install");

		_alpm_runscriptlet(handle, scriptlet, scriptlet_name,
				newpkg.version_, oldpkg ? oldpkg.version_ : null, 0);
		free(scriptlet);
	}

	event.type = ALPM_EVENT_PACKAGE_OPERATION_DONE;
	 EVENT(handle, &event);

	return ret;
}

int _alpm_upgrade_packages(AlpmHandle handle)
{
	size_t pkg_count = void, pkg_current = void;
	int skip_ldconfig = 0, ret = 0;
	alpm_list_t* targ = void;
	alpm_trans_t* trans = handle.trans;

	if(trans.add == null) {
		return 0;
	}

	pkg_count = alpm_list_count(trans.add);
	pkg_current = 1;

	/* loop through our package list adding/upgrading one at a time */
	for(targ = trans.add; targ; targ = targ.next) {
		AlpmPkg newpkg = cast(AlpmPkg)targ.data;

		if(handle.trans.state == STATE_INTERRUPTED) {
			return ret;
		}

		if(commit_single_pkg(handle, newpkg, pkg_current, pkg_count)) {
			/* something screwed up on the commit, abort the trans */
			trans.state = STATE_INTERRUPTED;
			handle.pm_errno = ALPM_ERR_TRANS_ABORT;
			/* running ldconfig at this point could possibly screw system */
			skip_ldconfig = 1;
			ret = -1;
		}

		pkg_current++;
	}

	if(!skip_ldconfig) {
		/* run ldconfig if it exists */
		_alpm_ldconfig(handle);
	}

	return ret;
}
