module libalpmd.remove;
@nogc  
   
import core.stdc.config: c_long, c_ulong;
/*
 *  remove.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
 *  Copyright (c) 2005 by Christian Hamar <krics@linuxforum.hu>
 *  Copyright (c) 2006 by David Kimpe <dnaku@frugalware.org>
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

import core.stdc.stdlib;
import core.stdc.stdio;

import core.stdc.errno;
import core.stdc.string;
import core.stdc.limits;
import core.sys.posix.dirent;
import std.regex;
import core.sys.posix.unistd;
import core.sys.posix.sys.stat;
import core.sys.posix.sys.types;

import std.conv;

/* libalpm */
import libalpmd.remove;
import libalpmd.alpm_list;
import libalpmd.alpm;
import libalpmd.trans;
import libalpmd.util;
import libalpmd.log;
import libalpmd.backup;
import libalpmd.pkg;
import libalpmd.db;
import libalpmd.deps;
import libalpmd.handle;
import libalpmd.filelist;
import libalpmd.util_common;
import libalpmd.be_local;



int  alpm_remove_pkg(AlpmHandle handle, AlpmPkg pkg)
{
	auto pkgname = pkg.name;
	// string pkgname = void;
	AlpmTrans trans = void;
	AlpmPkg copy = void;

	/* Sanity checks */
	CHECK_HANDLE(handle);
	//ASSERT(pkg != null);
	//ASSERT(pkg.origin == ALPM_PKG_FROM_LOCALDB,
			// RET_ERR(handle, ALPM_ERR_WRONG_ARGS, -1));
	//ASSERT(handle == pkg.handle);
	trans = handle.trans;
	//ASSERT(trans != null);
	//ASSERT(trans.state == STATE_INITIALIZED);


	if(alpm_pkg_find(trans.remove, cast(char*)pkgname)) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "skipping duplicate target: %s\n", pkgname);
		return 0;
	}

	_alpm_log(handle, ALPM_LOG_DEBUG, "adding package %s to the transaction remove list\n",
			pkgname);
	if(_alpm_pkg_dup(pkg, &copy) == -1) {
		return -1;
	}
	trans.remove = alpm_list_add(trans.remove, cast(void*)copy);
	return 0;
}

/**
 * @brief Add dependencies to the removal transaction for cascading.
 *
 * @param handle the context handle
 * @param lp list of missing dependencies caused by the removal transaction
 *
 * @return 0 on success, -1 on error
 */
private int remove_prepare_cascade(AlpmHandle handle, alpm_list_t* lp)
{
	AlpmTrans trans = handle.trans;

	while(lp) {
		alpm_list_t* i = void;
		for(i = lp; i; i = i.next) {
			alpm_depmissing_t* miss = cast(alpm_depmissing_t*)i.data;
			AlpmPkg info = _alpm_db_get_pkgfromcache(handle.db_local, miss.target);
			if(info) {
				AlpmPkg copy = void;
				if(!alpm_pkg_find(trans.remove, cast(char*)info.name)) {
					_alpm_log(handle, ALPM_LOG_DEBUG, "pulling %s in target list\n",
							info.name);
					if(_alpm_pkg_dup(info, &copy) == -1) {
						return -1;
					}
					trans.remove = alpm_list_add(trans.remove, cast(void*)copy);
				}
			} else {
				_alpm_log(handle, ALPM_LOG_ERROR,
						("could not find %s in database -- skipping\n"), miss.target);
			}
		}
		alpm_list_free_inner(lp, cast(alpm_list_fn_free)&alpm_depmissing_free);
		alpm_list_free(lp);
		lp = alpm_checkdeps(handle, _alpm_db_get_pkgcache(handle.db_local),
				trans.remove, null, 1);
	}
	return 0;
}

/**
 * @brief Remove needed packages from the removal transaction.
 *
 * @param handle the context handle
 * @param lp list of missing dependencies caused by the removal transaction
 */
private void remove_prepare_keep_needed(AlpmHandle handle, alpm_list_t* lp)
{
	AlpmTrans trans = handle.trans;

	/* Remove needed packages (which break dependencies) from target list */
	while(lp != null) {
		alpm_list_t* i = void;
		for(i = lp; i; i = i.next) {
			alpm_depmissing_t* miss = cast(alpm_depmissing_t*)i.data;
			void* vpkg = void;
			AlpmPkg pkg = alpm_pkg_find(trans.remove, miss.causingpkg);
			if(pkg is null) {
				continue;
			}
			trans.remove = alpm_list_remove(trans.remove, cast(void*)pkg, &_alpm_pkg_cmp,
					&vpkg);
			pkg = cast(AlpmPkg) vpkg;
			if(pkg) {
				_alpm_log(handle, ALPM_LOG_WARNING, ("removing %s from target list\n"),
						pkg.name);
				_alpm_pkg_free(pkg);
			}
		}
		alpm_list_free_inner(lp, cast(alpm_list_fn_free)&alpm_depmissing_free);
		alpm_list_free(lp);
		lp = alpm_checkdeps(handle, _alpm_db_get_pkgcache(handle.db_local),
				trans.remove, null, 1);
	}
}

/**
 * @brief Send a callback for any optdepend being removed.
 *
 * @param handle the context handle
 * @param lp list of packages to be removed
 */
private void remove_notify_needed_optdepends(AlpmHandle handle, alpm_list_t* lp)
{
	alpm_list_t* i = void;

	for(i = _alpm_db_get_pkgcache(handle.db_local); i; i = alpm_list_next(i)) {
		AlpmPkg pkg = cast(AlpmPkg)i.data;
		auto optdeps = pkg.getOptDepends();

		if(!optdeps.empty && !alpm_pkg_find(lp, cast(char*)pkg.name)) {
			alpm_list_t* j = void;
			foreach(optdep; optdeps[]) {
				// AlpmDepend optdep = cast(AlpmDepend)j.data;
				char* optstring = alpm_dep_compute_string(optdep);
				if(libalpmd.deps.alpm_find_satisfier(lp, optstring)) {
					alpm_event_optdep_removal_t event = {
						type: ALPM_EVENT_OPTDEP_REMOVAL,
						pkg: pkg,
						optdep: optdep
					};
					EVENT(handle, &event);
				}
				free(optstring);
			}
		}
	}
}

/**
 * @brief Transaction preparation for remove actions.
 *
 * This functions takes a pointer to a alpm_list_t which will be
 * filled with a list of alpm_depmissing_t* objects representing
 * the packages blocking the transaction.
 *
 * @param handle the context handle
 * @param data a pointer to an alpm_list_t* to fill
 *
 * @return 0 on success, -1 on error
 */
int _alpm_remove_prepare(AlpmHandle handle, alpm_list_t** data)
{
	alpm_list_t* lp = void;
	AlpmTrans trans = handle.trans;
	AlpmDB db = handle.db_local;
	alpm_event_t event = void;

	if((trans.flags & ALPM_TRANS_FLAG_RECURSE)
			&& !(trans.flags & ALPM_TRANS_FLAG_CASCADE)) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "finding removable dependencies\n");
		if(_alpm_recursedeps(db, &trans.remove,
				trans.flags & ALPM_TRANS_FLAG_RECURSEALL)) {
			return -1;
		}
	}

	if(!(trans.flags & ALPM_TRANS_FLAG_NODEPS)) {
		event.type = ALPM_EVENT_CHECKDEPS_START;
		EVENT(handle, &event);

		_alpm_log(handle, ALPM_LOG_DEBUG, "looking for unsatisfied dependencies\n");
		lp = alpm_checkdeps(handle, _alpm_db_get_pkgcache(db), trans.remove, null, 1);
		if(lp != null) {

			if(trans.flags & ALPM_TRANS_FLAG_CASCADE) {
				if(remove_prepare_cascade(handle, lp)) {
					return -1;
				}
			} else if(trans.flags & ALPM_TRANS_FLAG_UNNEEDED) {
				/* Remove needed packages (which would break dependencies)
				 * from target list */
				remove_prepare_keep_needed(handle, lp);
			} else {
				if(data) {
					*data = lp;
				} else {
					alpm_list_free_inner(lp,
							cast(alpm_list_fn_free)&alpm_depmissing_free);
					alpm_list_free(lp);
				}
				RET_ERR(handle, ALPM_ERR_UNSATISFIED_DEPS, -1);
			}
		}
	}

	/* -Rcs == -Rc then -Rs */
	if((trans.flags & ALPM_TRANS_FLAG_CASCADE)
			&& (trans.flags & ALPM_TRANS_FLAG_RECURSE)) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "finding removable dependencies\n");
		if(_alpm_recursedeps(db, &trans.remove,
					trans.flags & ALPM_TRANS_FLAG_RECURSEALL)) {
			return -1;
		}
	}

	/* Note packages being removed that are optdepends for installed packages */
	if(!(trans.flags & ALPM_TRANS_FLAG_NODEPS)) {
		remove_notify_needed_optdepends(handle, trans.remove);
	}

	if(!(trans.flags & ALPM_TRANS_FLAG_NODEPS)) {
		event.type = ALPM_EVENT_CHECKDEPS_DONE;
		EVENT(handle, &event);
	}

	return 0;
}

/**
 * @brief Test if a directory is being used as a mountpoint.
 *
 * @param handle context handle
 * @param directory path to test, must be absolute and include trailing '/'
 * @param stbuf stat_t result for @a directory, may be NULL
 *
 * @return 0 if @a directory is not a mountpoint or on error, 1 if @a directory
 * is a mountpoint
 */
private int dir_is_mountpoint(AlpmHandle handle,   char*directory,  stat_t* stbuf)
{
	char[PATH_MAX] parent_dir = void;
	stat_t parent_stbuf = void;
	dev_t dir_st_dev = void;

	if(stbuf == null) {
		stat_t dir_stbuf = void;
		if(stat(directory, &dir_stbuf) < 0) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"failed to stat directory %s: %s\n",
					directory, strerror(errno));
			return 0;
		}
		dir_st_dev = dir_stbuf.st_dev;
	} else {
		dir_st_dev = stbuf.st_dev;
	}

	snprintf(parent_dir.ptr, PATH_MAX, "%s..", directory);
	if(stat(parent_dir.ptr, &parent_stbuf) < 0) {
		_alpm_log(handle, ALPM_LOG_DEBUG,
				"failed to stat parent of %s: %s: %s\n",
				directory, parent_dir.ptr, strerror(errno));
		return 0;
	}

	return dir_st_dev != parent_stbuf.st_dev;
}

/**
 * @brief Check if alpm can delete a file.
 *
 * @param handle the context handle
 * @param file file to be removed
 *
 * @return 1 if the file can be deleted, 0 if it cannot be deleted
 */
private int can_remove_file(AlpmHandle handle,  AlpmFile* file)
{
	char[PATH_MAX] filepath = void;

	snprintf(filepath.ptr, PATH_MAX, "%s%s", handle.root.ptr, cast(char*)file.name);

	if(file.name[$ - 1] == '/' &&
			dir_is_mountpoint(handle, filepath.ptr, null)) {
		/* we do not remove mountpoints */
		return 1;
	}

	/* If we fail write permissions due to a read-only filesystem, abort.
	 * Assume all other possible failures are covered somewhere else */
	if(_alpm_access(handle, null, filepath.ptr, W_OK) == -1) {
		if(errno != EACCES && errno != ETXTBSY && _alpm_access(handle, null, filepath.ptr, F_OK) == 0) {
			/* only return failure if the file ACTUALLY exists and we can't write to
			 * it - ignore "chmod -w" simple permission failures */
			_alpm_log(handle, ALPM_LOG_ERROR, ("cannot remove file '%s': %s\n"),
					filepath.ptr, strerror(errno));
			return 0;
		}
	}

	return 1;
}

private void shift_pacsave(AlpmHandle handle,   char*file)
{
	c_ulong i = void;

	DIR* dir = null;
	dirent* ent = void;
	stat_t st = void;
	// auto reg = void;

	  char*basename = void;
	char* dirname = void;
	char[PATH_MAX] oldfile = void;
	char[PATH_MAX] newfile = void;
	char[PATH_MAX] regstr = void;

	c_ulong log_max = 0;
	size_t basename_len = void;

	dirname = cast(char*)mdirname(cast(char*)file);
	if(!dirname) {
		return;
	}

	basename = cast(char*)mbasename(cast(char*)file);
	basename_len = strlen(basename);

	snprintf(regstr.ptr, PATH_MAX, "^%s\\.pacsave\\.([[:digit:]]+)$", basename);
	auto reg = regex(cast(string)(regstr));

	dir = opendir(dirname);
	if(dir == null) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not open directory: %s: %s\n"),
							dirname, strerror(errno));
		goto cleanup;
	}

	while((ent = readdir(dir)) != null) {
		if(strcmp(ent.d_name.ptr, cast(char*)".") == 0 || strcmp(ent.d_name.ptr, cast(char*)"..") == 0) {
			continue;
		}

		if(match(cast(string)ent.d_name, reg)) {
			c_ulong cur_log = void;
			cur_log = strtoul(ent.d_name.ptr + basename_len + strlen(".pacsave."), null, 10);
			if(cur_log > log_max) {
				log_max = cur_log;
			}
		}
	}

	/* Shift pacsaves */
	for(i = log_max + 1; i > 1; i--) {
		if(snprintf(oldfile.ptr, PATH_MAX, "%s.pacsave.%lu", file, i-1) >= PATH_MAX
				|| snprintf(newfile.ptr, PATH_MAX, "%s.pacsave.%lu", file, i) >= PATH_MAX) {
			_alpm_log(handle, ALPM_LOG_ERROR,
					("could not backup %s due to PATH_MAX overflow\n"), file);
			goto cleanup;
		}
		rename(oldfile.ptr, newfile.ptr);
	}

	if(snprintf(oldfile.ptr, PATH_MAX, "%s.pacsave", file) >= PATH_MAX
			|| snprintf(newfile.ptr, PATH_MAX, "%s.1", oldfile.ptr) >= PATH_MAX) {
		_alpm_log(handle, ALPM_LOG_ERROR,
				("could not backup %s due to PATH_MAX overflow\n"), file);
		goto cleanup;
	}
	if(stat(oldfile.ptr, &st) == 0) {
		rename(oldfile.ptr, newfile.ptr);
	}

cleanup:
	free(dirname);
	if(dir != null) {
		closedir(dir);
	}
}


/**
 * @brief Unlink a package file, backing it up if necessary.
 *
 * @param handle the context handle
 * @param oldpkg the package being removed
 * @param newpkg the package replacing \a oldpkg
 * @param fileobj file to remove
 * @param nosave whether files should be backed up
 *
 * @return 0 on success, -1 if there was an error unlinking the file, 1 if the
 * file was skipped or did not exist
 */
private int unlink_file(AlpmHandle handle, AlpmPkg oldpkg, AlpmPkg newpkg,  AlpmFile* fileobj, int nosave)
{
	stat_t buf = void;
	char[PATH_MAX] file = void;
	int file_len = void;

	file_len = snprintf(file.ptr, PATH_MAX, "%s%s", handle.root.ptr, cast(char*)fileobj.name);
	if(file_len <= 0 || file_len >= PATH_MAX) {
		/* 0 is a valid value from snprintf, but should be impossible here */
		_alpm_log(handle, ALPM_LOG_DEBUG, "path too long to unlink %s%s\n",
				handle.root, fileobj.name);
		return -1;
	} else if(file[file_len - 1] == '/') {
		/* trailing slashes cause errors and confusing messages if the user has
		 * replaced a directory with a symlink */
		file[file_len - 1] = '\0';
		file_len--;
	}

	if(llstat(file.ptr, &buf)) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "file %s does not exist\n", file.ptr);
		return 1;
	}

	if(S_ISDIR(buf.st_mode)) {
		ssize_t files = void;

		/* restore/add trailing slash */
		if(file_len < PATH_MAX - 1) {
			file[file_len] = '/';
			file_len++;
			file[file_len] = '\0';
		} else {
			_alpm_log(handle, ALPM_LOG_DEBUG, "path too long to unlink %s%s\n",
					handle.root, fileobj.name);
			return -1;
		}

		files = _alpm_files_in_directory(handle, file.ptr, 0);
		if(files > 0) {
			/* if we have files, no need to remove the directory */
			_alpm_log(handle, ALPM_LOG_DEBUG, "keeping directory %s (contains files)\n",
					file.ptr);
		} else if(files < 0) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"keeping directory %s (could not count files)\n", file.ptr);
		} else if(newpkg && alpm_filelist_contains(newpkg.getFiles(),
					fileobj.name)) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"keeping directory %s (in new package)\n", file.ptr);
		} else if(dir_is_mountpoint(handle, file.ptr, &buf)) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"keeping directory %s (mountpoint)\n", file.ptr);
		} else {
			/* one last check- does any other package own this file? */
			alpm_list_t* local = void, local_pkgs = void;
			int found = 0;
			local_pkgs = _alpm_db_get_pkgcache(handle.db_local);
			for(local = local_pkgs; local && !found; local = local.next) {
				AlpmPkg local_pkg = cast(AlpmPkg)local.data;
				AlpmFileList filelist;

				/* we duplicated the package when we put it in the removal list, so we
				 * so we can't use direct pointer comparison here. */
				if(oldpkg.name_hash == local_pkg.name_hash
						&& oldpkg.name == local_pkg.name) {
					continue;
				}
				filelist = local_pkg.getFiles();
				if(alpm_filelist_contains(filelist, fileobj.name)) {
					_alpm_log(handle, ALPM_LOG_DEBUG,
							"keeping directory %s (owned by %s)\n", file.ptr, local_pkg.name);
					found = 1;
				}
			}
			if(!found) {
				if(rmdir(file.ptr)) {
					_alpm_log(handle, ALPM_LOG_DEBUG,
							"directory removal of %s failed: %s\n", file.ptr, strerror(errno));
					return -1;
				} else {
					_alpm_log(handle, ALPM_LOG_DEBUG,
							"removed directory %s (no remaining owners)\n", file.ptr);
				}
			}
		}
	} else {
		/* if the file needs backup and has been modified, back it up to .pacsave */
		AlpmBackup backup = _alpm_needbackup(cast(char*)fileobj.name, oldpkg);
		if(backup) {
			if(nosave) {
				_alpm_log(handle, ALPM_LOG_DEBUG, "transaction is set to NOSAVE, not backing up '%s'\n", file.ptr);
			} else {
				char* filehash = alpm_compute_md5sum(file.ptr);
				int cmp = filehash ? strcmp(filehash, cast(char*)backup.hash) : 0;
				FREE(filehash);
				if(cmp != 0) {
					alpm_event_pacsave_created_t event = {
						type: ALPM_EVENT_PACSAVE_CREATED,
						oldpkg: oldpkg,
						file: cast(char*)file
					};
					char* newpath = void;
					size_t len = strlen(file.ptr) + 8 + 1;
					MALLOC(newpath, len);
					shift_pacsave(handle, file.ptr);
					snprintf(newpath, len, "%s.pacsave", file.ptr);
					if(rename(file.ptr, newpath)) {
						_alpm_log(handle, ALPM_LOG_ERROR, ("could not rename %s to %s (%s)\n"),
								file.ptr, newpath, strerror(errno));
						//alpm_logaction(handle, ALPM_CALLER_PREFIX,
								// "error: could not rename %s to %s (%s)\n",
								// file.ptr, newpath, strerror(errno));
						free(newpath);
						return -1;
					}
					EVENT(handle, &event);
					//alpm_logaction(handle, ALPM_CALLER_PREFIX,
							// "warning: %s saved as %s\n", file.ptr, newpath);
					free(newpath);
					return 0;
				}
			}
		}

		_alpm_log(handle, ALPM_LOG_DEBUG, "unlinking %s\n", file.ptr);

		if(unlink(file.ptr) == -1) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("cannot remove %s (%s)\n"),
					file.ptr, strerror(errno));
			//alpm_logaction(handle, ALPM_CALLER_PREFIX,
					// "error: cannot remove %s (%s)\n", file.ptr, strerror(errno));
			return -1;
		}
	}
	return 0;
}

/**
 * @brief Check if a package file should be removed.
 *
 * @param handle the context handle
 * @param newpkg the package replacing the current owner of \a path
 * @param path file to be removed
 *
 * @return 1 if the file should be skipped, 0 if it should be removed
 */
private int should_skip_file(AlpmHandle handle, AlpmPkg newpkg,   char*path)
{
	return _alpm_fnmatch_patterns(handle.noupgrade, path) == 0
		|| alpm_list_find_str(handle.trans.skip_remove, path)
		|| (newpkg && _alpm_needbackup(path, newpkg)
				&& alpm_filelist_contains(newpkg.getFiles(), path.to!string));
}

/**
 * @brief Remove a package's files, optionally skipping its replacement's
 * files.
 *
 * @param handle the context handle
 * @param oldpkg package to remove
 * @param newpkg package to replace \a oldpkg (optional)
 * @param targ_count current index within the transaction (1-based)
 * @param pkg_count the number of packages affected by the transaction
 *
 * @return 0 on success, -1 if alpm lacks permission to delete some of the
 * files, >0 the number of files alpm was unable to delete
 */
private int remove_package_files(AlpmHandle handle, AlpmPkg oldpkg, AlpmPkg newpkg, size_t targ_count, size_t pkg_count)
{
	AlpmFileList filelist;
	size_t i = void;
	int err = 0;
	int nosave = handle.trans.flags & ALPM_TRANS_FLAG_NOSAVE;

	filelist = oldpkg.getFiles();
	for(i = 0; i < filelist.length; i++) {
		AlpmFile* file = filelist.ptr + i;
		if(!should_skip_file(handle, newpkg, cast(char*)file.name)
				&& !can_remove_file(handle, file)) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"not removing package '%s', can't remove all files\n",
					oldpkg.name);
			RET_ERR(handle, ALPM_ERR_PKG_CANT_REMOVE, -1);
		}
	}

	_alpm_log(handle, ALPM_LOG_DEBUG, "removing %zu files\n", filelist.length);

	if(!newpkg) {
		/* init progress bar, but only on true remove transactions */
		PROGRESS(handle, ALPM_PROGRESS_REMOVE_START, oldpkg.name, 0,
				pkg_count, targ_count);
	}

	/* iterate through the list backwards, unlinking files */
	for(i = filelist.length; i > 0; i--) {
		AlpmFile* file = filelist.ptr + i - 1;

		/* check the remove skip list before removing the file.
		 * see the big comment block in db_find_fileconflicts() for an
		 * explanation. */
		if(should_skip_file(handle, newpkg, cast(char*)file.name)) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"%s is in skip_remove, skipping removal\n", file.name);
			continue;
		}

		if(unlink_file(handle, oldpkg, newpkg, file, nosave) < 0) {
			err++;
		}

		if(!newpkg) {
			/* update progress bar after each file */
			int percent = cast(int)(((filelist.length - i) * 100) / filelist.length);
			PROGRESS(handle, ALPM_PROGRESS_REMOVE_START, oldpkg.name,
					percent, pkg_count, targ_count);
		}
	}

	if(!newpkg) {
		/* set progress to 100% after we finish unlinking files */
		PROGRESS(handle, ALPM_PROGRESS_REMOVE_START, oldpkg.name, 100,
				pkg_count, targ_count);
	}

	return err;
}

/**
 * @brief Remove a package from the filesystem.
 *
 * @param handle the context handle
 * @param oldpkg package to remove
 * @param newpkg package to replace \a oldpkg (optional)
 * @param targ_count current index within the transaction (1-based)
 * @param pkg_count the number of packages affected by the transaction
 *
 * @return 0
 */
int _alpm_remove_single_package(AlpmHandle handle, AlpmPkg oldpkg, AlpmPkg newpkg, size_t targ_count, size_t pkg_count)
{
	 string pkgname = oldpkg.name;
	  char*pkgver = cast(char*)oldpkg.version_;
	alpm_event_package_operation_t event = {
		type: ALPM_EVENT_PACKAGE_OPERATION_START,
		operation: ALPM_PACKAGE_REMOVE,
		oldpkg: oldpkg,
		newpkg: null
	};

	if(newpkg) {
		_alpm_log(handle, ALPM_LOG_DEBUG, "removing old package first (%s-%s)\n",
				pkgname, pkgver);
	} else {
		EVENT(handle, &event);
		_alpm_log(handle, ALPM_LOG_DEBUG, "removing package %s-%s\n",
				pkgname, pkgver);

		/* run the pre-remove scriptlet if it exists */
		if(oldpkg.hasScriptlet() &&
				!(handle.trans.flags & ALPM_TRANS_FLAG_NOSCRIPTLET)) {
			char* scriptlet = _alpm_local_db_pkgpath(handle.db_local,
					oldpkg, cast(char*)"install");
			_alpm_runscriptlet(handle, scriptlet, cast(char*)"pre_remove", pkgver, null, 0);
			free(scriptlet);
		}
	}

	if(!(handle.trans.flags & ALPM_TRANS_FLAG_DBONLY)) {
		/* TODO check returned errors if any */
		remove_package_files(handle, oldpkg, newpkg, targ_count, pkg_count);
	}

	if(!newpkg) {
		//alpm_logaction(handle, ALPM_CALLER_PREFIX, "removed %s (%s)\n",
					// oldpkg.name, oldpkg.version_);
	}

	/* run the post-remove script if it exists */
	if(!newpkg && oldpkg.hasScriptlet() &&
			!(handle.trans.flags & ALPM_TRANS_FLAG_NOSCRIPTLET)) {
		char* scriptlet = _alpm_local_db_pkgpath(handle.db_local,
				oldpkg, cast(char*)"install");
		_alpm_runscriptlet(handle, scriptlet, cast(char*)"post_remove", pkgver, null, 0);
		free(scriptlet);
	}

	if(!newpkg) {
		event.type = ALPM_EVENT_PACKAGE_OPERATION_DONE;
		EVENT(handle, &event);
	}

	/* remove the package from the database */
	_alpm_log(handle, ALPM_LOG_DEBUG, "removing database entry '%s'\n", pkgname);
	if(_alpm_local_db_remove(handle.db_local, oldpkg) == -1) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not remove database entry %s-%s\n"),
				pkgname, pkgver);
	}
	/* remove the package from the cache */
	if(_alpm_db_remove_pkgfromcache(handle.db_local, oldpkg) == -1) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not remove entry '%s' from cache\n"),
				pkgname);
	}

	/* TODO: useful return values */
	return 0;
}

/**
 * @brief Remove packages in the current transaction.
 *
 * @param handle the context handle
 * @param run_ldconfig whether to run ld_config after removing the packages
 *
 * @return 0 on success, -1 if errors occurred while removing files
 */
int _alpm_remove_packages(AlpmHandle handle, int run_ldconfig)
{
	alpm_list_t* targ = void;
	size_t pkg_count = void, targ_count = void;
	AlpmTrans trans = handle.trans;
	int ret = 0;

	pkg_count = alpm_list_count(trans.remove);
	targ_count = 1;

	for(targ = trans.remove; targ; targ = targ.next) {
		AlpmPkg pkg = cast(AlpmPkg)targ.data;

		if(trans.state == STATE_INTERRUPTED) {
			return ret;
		}

		if(_alpm_remove_single_package(handle, pkg, null,
					targ_count, pkg_count) == -1) {
			handle.pm_errno = ALPM_ERR_TRANS_ABORT;
			/* running ldconfig at this point could possibly screw system */
			run_ldconfig = 0;
			ret = -1;
		}

		targ_count++;
	}

	if(run_ldconfig) {
		/* run ldconfig if it exists */
		_alpm_ldconfig(handle);
	}

	return ret;
}
