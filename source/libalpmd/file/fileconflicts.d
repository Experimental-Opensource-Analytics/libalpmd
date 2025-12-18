module libalpmd.file.fileconflicts;

import libalpmd.file.filelist;

import core.stdc.stdlib;
import core.stdc.stdio;
import core.stdc.string;
import core.stdc.limits;
import core.sys.posix.sys.stat;
import core.sys.posix.dirent;

import std.conv;
import std.string;
import std.range;
/* libalpm */
import libalpmd.file;
import libalpmd.util;
import libalpmd.alpm_list;
import libalpmd.alpm;
import libalpmd.handle;
import libalpmd.db;
import libalpmd.pkg;
import libalpmd.log;
import libalpmd.conflict;


/**
 * File conflict type.
 * Whether the conflict results from a file existing on the filesystem, or with
 * another target in the transaction.
 */
enum AlpmFileConflictType {
	/** The conflict results with a another target in the transaction */
	Target = 1,
	/** The conflict results from a file existing on the filesystem */
	Filesystem
}

/** File conflict.
 *
 * A conflict that has happened due to a two packages containing the same file,
 * or a package contains a file that is already on the filesystem and not owned
 * by that package. */


class AlpmFileConflict {
	/** The name of the package that caused the conflict */
	string target;
	/** The type of conflict */
	AlpmFileConflictType type;
	/** The name of the file that the package conflicts with */
	string file;
	/** The name of the package that also owns the file if there is one*/
	string ctarget;
}

alias AlpmFileConflicts = AlpmList!AlpmFileConflict;

/**
 * @brief Creates and adds a file conflict to a conflict list.
 *
 * @param handle the context handle
 * @param conflicts the list of conflicts to append to
 * @param filestr the conflicting file path
 * @param pkg1 package that wishes to install the file
 * @param pkg2 package that currently owns the file, or NULL if unowned
 *
 * @return the updated conflict list
 */
private AlpmFileConflicts add_fileconflict(AlpmHandle handle, ref AlpmFileConflicts conflicts,   char*filestr, AlpmPkg pkg1, AlpmPkg pkg2)
{
	AlpmFileConflict conflict = new AlpmFileConflict();

	conflict.target = pkg1.getName();
	conflict.file = filestr.to!string;
	if(!pkg2) {
		conflict.type = AlpmFileConflictType.Filesystem;
		conflict.ctarget = "";
	} else if(pkg2.origin == AlpmPkgFrom.LocalDB) {
		conflict.type = AlpmFileConflictType.Filesystem;
		conflict.ctarget = pkg2.getName();
	} else {
		conflict.type = AlpmFileConflictType.Target;
		conflict.ctarget = pkg2.getName();
	}

	conflicts.insertBack(conflict);
	logger.tracef("found file conflict %s, packages %s and %s\n",
	          filestr, pkg1.getName(), pkg2 ? cast(char*)pkg2.getName() : "(filesystem)");

	return conflicts;

error:			
	alpm_fileconflict_free(conflict);
	RET_ERR(handle, ALPM_ERR_MEMORY, conflicts);
}

void  alpm_fileconflict_free(AlpmFileConflict conflict)
{
	FREE(conflict.ctarget);
	FREE(conflict.file);
	FREE(conflict.target);
	FREE(conflict);
}

/**
 * @brief Recursively checks if a set of packages own all subdirectories and
 * files in a directory.
 *
 * @param handle the context handle
 * @param dirpath path of the directory to check
 * @param pkgs packages being checked against
 *
 * @return 1 if a package owns all subdirectories and files, 0 otherwise
 */
private int dir_belongsto_pkgs(AlpmHandle handle,   char*dirpath, AlpmPkgs pkgs)
{
	char[PATH_MAX] path = void, full_path = void;
	DIR* dir = void;
	dirent* ent = null;

	snprintf(full_path.ptr, PATH_MAX, "%s%s", handle.root.ptr, dirpath);
	dir = opendir(full_path.ptr);
	if(dir == null) {
		return 0;
	}

	while((ent = readdir(dir)) != null) {
		  char*name = ent.d_name.ptr;
		int owned = 0, is_dir = 0;
		stat_t sbuf = void;

		if(strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
			continue;
		}

		snprintf(full_path.ptr, PATH_MAX, "%s%s%s", handle.root.ptr, dirpath, name);

		if(lstat(full_path.ptr, &sbuf) != 0) {
			logger.tracef("could not stat %s\n", full_path.ptr);
			closedir(dir);
			return 0;
		}
		is_dir = S_ISDIR(sbuf.st_mode);

		snprintf(path.ptr, PATH_MAX, "%s%s%s", dirpath, name, is_dir ? "/".ptr : "".ptr);

		foreach(pkg; pkgs[]) {
			if(alpm_filelist_contains(pkg.getFiles(), path.to!string)) {
				owned = 1;
			}

			if(owned)
				break;
		}

		if(owned && is_dir) {
			owned = dir_belongsto_pkgs(handle, path.ptr, pkgs);
		}

		if(!owned) {
			closedir(dir);
			// _alpm_log(handle, ALPM_LOG_DEBUG,
			// 		"unowned file %s found in directory\n", path.ptr);
			return 0;
		}
	}
	closedir(dir);
	return 1;
}

private AlpmPkgs alpm_db_find_file_owners(AlpmDB db,   char*path)
{
	AlpmPkgs owners;
	foreach(pkg; (db.getPkgCacheList())[]) {
		if(alpm_filelist_contains(pkg.getFiles(), path.to!string)) {
			owners.insertBack(pkg);
		}
	}
	return owners;
}

private AlpmPkg _alpm_find_file_owner(AlpmHandle handle,   char*path)
{
	foreach(pkg; (handle.getDBLocal().getPkgCacheList())[]) {
		if(alpm_filelist_contains(pkg.getFiles(), path.to!string)) {
			return pkg;
		}
	}
	return null;
}

private int _alpm_can_overwrite_file(AlpmHandle handle,   char*path,   char*rootedpath)
{
	return alpmFnmatchPatterns(handle.overwrite_files, path.to!string) == 0
		|| alpmFnmatchPatterns(handle.overwrite_files, rootedpath.to!string) == 0;
}

/**
 * @brief Find file conflicts that may occur during the transaction.
 *
 * @details Performs two checks:
 *   1. check every target against every target
 *   2. check every target against the filesystem
 *
 * @param handle the context handle
 * @param upgrade list of packages being installed
 * @param rem list of packages being removed
 *
 * @return list of file conflicts
 */
AlpmFileConflicts _alpm_db_find_fileconflicts(AlpmHandle handle, AlpmPkgs upgrade, AlpmPkgs rem)
{
	AlpmFileConflicts conflicts;
	size_t numtargs = upgrade[].walkLength();

	size_t current = void;
	size_t rootlen = void;

	if(upgrade.empty()) {
		return AlpmFileConflicts();
	}

	rootlen = handle.root.length;

	/* TODO this whole function needs a huge change, which hopefully will
	 * be possible with real transactions. Right now we only do half as much
	 * here as we do when we actually extract files in add.c with our 12
	 * different cases. */
	auto range = upgrade[];
	foreach(p1; range) {
		AlpmStrings newfiles;
		AlpmPkg dbpkg = void;

		int percent = cast(int)((current * 100) / numtargs);
		PROGRESS(handle, ALPM_PROGRESS_CONFLICTS_START, cast(char*)"", percent,
		         numtargs, current);

		/* CHECK 1: check every target against every target */
		logger.tracef("searching for file conflicts: %s\n",
				p1.getName());
		foreach(p2; range) {
			AlpmStrings common_files = void;
			AlpmFileList p1_files = p1.getFiles();
			AlpmFileList p2_files = p2.getFiles();

			common_files = _alpm_filelist_intersection(p1_files, p2_files);

			if(!common_files.empty()) {
				char[PATH_MAX] path = void;
				foreach(filename_; common_files[]) {
					char* filename = cast(char*)filename_.toStringz;
					snprintf(path.ptr, PATH_MAX, "%s%s", handle.root.ptr, filename);

					/* can skip file-file conflicts when forced *
					 * checking presence in p2_files detects dir-file or file-dir
					 * conflicts as the path from p1 is returned */
					if(_alpm_can_overwrite_file(handle, filename, path.ptr)
							&& alpm_filelist_contains(p2_files, filename.to!string)) {
						_alpm_log(handle, ALPM_LOG_DEBUG,
							"%s exists in both '%s' and '%s'\n", filename,
							p1.getName(), p2.getName());
						_alpm_log(handle, ALPM_LOG_DEBUG,
							"file-file conflict being forced\n");
						continue;
					}

					conflicts = add_fileconflict(handle, conflicts, path.ptr, p1, p2);
					if(handle.pm_errno == ALPM_ERR_MEMORY) {
						conflicts.clear();
						common_files.clear();
						return AlpmFileConflicts();
					}
				}
				common_files.clear();
			}
		}

		/* CHECK 2: check every target against the filesystem */
		logger.tracef("searching for filesystem conflicts: %s\n",
				p1.getName());
		dbpkg = handle.getDBLocal().getPkgFromCache(cast(char*)p1.getName());

		/* Do two different checks here. If the package is currently installed,
		 * then only check files that are new in the new package. If the package
		 * is not currently installed, then simply stat the whole filelist. Note
		 * that the former list needs to be freed while the latter list should NOT
		 * be freed. */
		if(dbpkg) {
			/* older ver of package currently installed */
			newfiles = _alpm_filelist_difference(p1.getFiles(),
					dbpkg.getFiles());
		} else {
			/* no version of package currently installed */
			AlpmFileList fl = p1.getFiles();
			size_t filenum = void;
			for(filenum = 0; filenum < fl.length; filenum++) {
				newfiles.insertBack(fl[filenum].name);
			}
		}

		foreach(filestr_; newfiles[]) {
			  char*filestr = cast(char*)filestr_.toStringz;
			  char*relative_path = void;
			/* have we acted on this conflict? */
			int resolved_conflict = 0;
			stat_t lsbuf = void;
			char[PATH_MAX] path = void;
			size_t pathlen = void;
			int pfile_isdir = void;

			pathlen = snprintf(path.ptr, PATH_MAX, "%s%s", handle.root.ptr, filestr);
			relative_path = path.ptr + rootlen;

			/* stat the file - if it exists, do some checks */
			if(lstat(path.ptr, &lsbuf) != 0) {
				continue;
			}

			logger.tracef("checking possible conflict: %s\n", path.ptr);

			pfile_isdir = path[pathlen - 1] == '/';
			if(pfile_isdir) {
				if(S_ISDIR(lsbuf.st_mode)) {
					logger.tracef("file is a directory, not a conflict\n");
					continue;
				}
				/* if we made it to here, we want all subsequent path comparisons to
				 * not include the trailing slash. This allows things like file ->
				 * directory replacements. */
				path[pathlen - 1] = '\0';

				/* Check if the directory was a file in dbpkg */
				if(alpm_filelist_contains(dbpkg.getFiles(), relative_path.to!string)) {
					size_t fslen = strlen(filestr);
					_alpm_log(handle, ALPM_LOG_DEBUG,
							"replacing package file with a directory, not a conflict\n");
					resolved_conflict = 1;

					/* go ahead and skip any files inside filestr as they will
					 * necessarily be resolved by replacing the file with a dir
					 * NOTE: afterward, j will point to the last file inside filestr */
					 auto range2 = range;
					foreach(str_; range2) {
						  char*filestr2 = cast(char*)str_.getName().toStringz;
						if(strncmp(filestr, filestr2, fslen) != 0) {
							break;
						}
					}
				}
			}

			/* Check remove list (will we remove the conflicting local file?) */
			foreach(rempkg; rem[]) {
				if(rempkg && alpm_filelist_contains(rempkg.getFiles(), relative_path.to!string)) {
					_alpm_log(handle, ALPM_LOG_DEBUG,
							"local file will be removed, not a conflict\n");
					resolved_conflict = 1;
					if(pfile_isdir) {
						/* go ahead and skip any files inside filestr as they will
						 * necessarily be resolved by replacing the file with a dir
						 * NOTE: afterward, j will point to the last file inside filestr */
						size_t fslen = strlen(filestr);

						auto range2 = range;
						foreach(j; range2) {
							  char*filestr2 = cast(char*)j.getName().toStringz();
							if(strncmp(filestr, filestr2, fslen) != 0) {
								break;
							}
						}
						// for( ; j.next; j = j.next) {
						// 	  char*filestr2 = cast(char*)j.next.data;
						// 	if(strncmp(filestr, filestr2, fslen) != 0) {
						// 		break;
						// 	}
						// }
					}
				}

				if(resolved_conflict)
					break;
			}

			/* Look at all the targets to see if file has changed hands */
			foreach(p2; upgrade[]) {
				AlpmPkg localp2 = void;
				localp2 = null;
				if(!p2 || p1 == p2) {
					/* skip p1; both p1 and p2 come directly from the upgrade list
					 * so they can be compared directly */
					continue;
				}
				localp2 = handle.getDBLocal().getPkgFromCache(cast(char*)p2.getName());

				/* localp2->files will be removed (target conflicts are handled by CHECK 1) */
				if(localp2 && alpm_filelist_contains(localp2.getFiles(), relative_path.to!string)) {
					size_t fslen = strlen(filestr);

					/* skip removal of file, but not add. this will prevent a second
					 * package from removing the file when it was already installed
					 * by its new owner (whether the file is in backup array or not */
					handle.trans.skip_remove.insertBack(strdup(relative_path).to!string);
					_alpm_log(handle, ALPM_LOG_DEBUG,
							"file changed packages, adding to remove skiplist\n");
					resolved_conflict = 1;

					if(filestr[fslen - 1] == '/') {
						/* replacing a file with a directory:
						 * go ahead and skip any files inside filestr as they will
						 * necessarily be resolved by replacing the file with a dir
						 * NOTE: afterward, j will point to the last file inside filestr */
						auto range2 = range;
						foreach(j; range2) {
							  char*filestr2 = cast(char*)j.getName().toStringz();
							if(strncmp(filestr, filestr2, fslen) != 0) {
								break;
							}
						}
					}
				}

				if(resolved_conflict)
					break;
			}

			/* check if all files of the dir belong to the installed pkg */
			if(!resolved_conflict && S_ISDIR(lsbuf.st_mode)) {
				AlpmPkgs owners;
				size_t dir_len = strlen(relative_path) + 2;
				char* dir = cast(char*) malloc(dir_len);
				snprintf(dir, dir_len, "%s/", relative_path);

				owners = alpm_db_find_file_owners(handle.getDBLocal, dir);
				if(!owners.empty) {
					AlpmPkgs diffs = AlpmPkgs();
					AlpmPkgs pkgs;

					if(dbpkg !is null) {
						pkgs.insertBack(dbpkg);
					}
					pkgs.insertFront(rem[]);
					diffs = alpmListDiff(owners, pkgs);
					if(!diffs.empty()) {
						/* dir is owned by files we aren't removing */
						/* TODO: with better commit ordering, we may be able to check
						 * against upgrades as well */
						diffs.clear();
					} else {
						_alpm_log(handle, ALPM_LOG_DEBUG,
								"checking if all files in %s belong to removed packages\n",
								dir);
						resolved_conflict = dir_belongsto_pkgs(handle, dir, owners);
					}
					pkgs.clear();
					owners.clear();
				}
				free(dir);
			}

			/* is the file unowned and in the backup list of the new package? */
			// if(!resolved_conflict && _alpm_needbackup(relative_path, p1)) {
			if(!resolved_conflict && p1.needBackup(relative_path.to!string)) {

				auto local_pkgs = handle.getDBLocal().getPkgCacheList();
				int found = 0;
				foreach(pkg; local_pkgs) {
					if(alpm_filelist_contains(pkg.getFiles(), relative_path.to!string)) {
							found = 1;
					}

					if(found)
						break;
				}
				if(!found) {
					_alpm_log(handle, ALPM_LOG_DEBUG,
							"file was unowned but in new backup list\n");
					resolved_conflict = 1;
				}
			}

			/* skip file-file conflicts when being forced */
			if(!S_ISDIR(lsbuf.st_mode)
					&& _alpm_can_overwrite_file(handle, filestr, path.ptr)) {
				_alpm_log(handle, ALPM_LOG_DEBUG,
							"conflict with file on filesystem being forced\n");
				resolved_conflict = 1;
			}

			if(!resolved_conflict) {
				conflicts = add_fileconflict(handle, conflicts, path.ptr, p1,
						_alpm_find_file_owner(handle, relative_path));
				if(handle.pm_errno == ALPM_ERR_MEMORY) {
					conflicts.clear();
					newfiles.clear();
					return AlpmFileConflicts();
				}
			}
		}
		newfiles.clear();
		current++;
	}
	PROGRESS(handle, ALPM_PROGRESS_CONFLICTS_START, "", 100,
			numtargs, current);

	return conflicts;
}
