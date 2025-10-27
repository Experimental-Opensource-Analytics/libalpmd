module libalpmd.diskspace;
@nogc  
   

private template HasVersion(string versionId) {
	mixin("version("~versionId~") {enum HasVersion = true;} else {enum HasVersion = false;}");
}
/*
 *  diskspace.c
 *
 *  Copyright (c) 2010-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
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

import core.stdc.stdio;
import core.stdc.errno;
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

import core.stdc.string;
// version (HAVE_MNTENT_H) {
// import mntent;
// }
// version (HAVE_SYS_MNTTAB_H) {
// import sys/mnttab;
// }
// version (HAVE_SYS_STATVFS_H) {
// import core.sys.posix.sys.statvfs;
// }
// version (HAVE_SYS_PARAM_H) {
// import sys/param;
// }
// version (HAVE_SYS_MOUNT_H) {
// import sys/mount;
// }
// version (HAVE_SYS_UCRED_H) {
// import sys/ucred;
// import core.sys.freebsd.sys.
// }
enum PATH_MAX = 255;

version (HAVE_SYS_TYPES_H) {
import core.sys.posix.sys.types;
}

/* libalpm */
import libalpmd.diskspace;
import libalpmd.alpm_list;
import libalpmd.util;
import libalpmd.log;
import libalpmd.trans;
import libalpmd.handle;
import libalpmd._package;
import core.sys.posix.sys.statvfs;
import libalpmd.filelist;import core.sys.posix.unistd;
import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.errno;
import core.stdc.string;
import core.stdc.stdint; /* intmax_t */
// import core.sys.posix.dirent;
import core.sys.posix.dirent;
import core.sys.posix.sys.stat;
import core.sys.posix.stdlib;
import ae.sys.file;
import libalpmd.alpm;
import libalpmd.db;


alias FSSTATSTYPE = statvfs_t;


version (HAVE_SYS_MOUNT_H) {
public import core.stdc.stddef;
}
version (HAVE_SYS_STATVFS_H) {
public import core.sys.posix.sys.statvfs;
}
version (HAVE_SYS_TYPES_H) {
public import core.sys.posix.sys.types;
}
public import core.sys.posix.sys.types;

enum mount_used_level {
	USED_REMOVE = 1,
	USED_INSTALL = (1 << 1),
}
alias USED_REMOVE = mount_used_level.USED_REMOVE;
alias USED_INSTALL = mount_used_level.USED_INSTALL;


enum mount_fsinfo {
	MOUNT_FSINFO_UNLOADED = 0,
	MOUNT_FSINFO_LOADED,
	MOUNT_FSINFO_FAIL,
}
alias MOUNT_FSINFO_UNLOADED = mount_fsinfo.MOUNT_FSINFO_UNLOADED;
alias MOUNT_FSINFO_LOADED = mount_fsinfo.MOUNT_FSINFO_LOADED;
alias MOUNT_FSINFO_FAIL = mount_fsinfo.MOUNT_FSINFO_FAIL;


struct alpm_mountpoint_t {
	/* mount point information */
	char* mount_dir;
	size_t mount_dir_len;
	/* storage for additional disk usage calculations */
	blkcnt_t blocks_needed;
	blkcnt_t max_blocks_needed;
	mount_used_level used;
	int read_only;
	mount_fsinfo fsinfo_loaded;
	FSSTATSTYPE fsp;
}

private int mount_point_cmp(void* p1,void* p2)
{
	 alpm_mountpoint_t* mp1 = cast(alpm_mountpoint_t*)p1;
	 alpm_mountpoint_t* mp2 = cast(alpm_mountpoint_t*)p2;
	/* the negation will sort all mountpoints before their parent */
	return -strcmp(mp1.mount_dir, mp2.mount_dir);
}

private void mount_point_list_free(alpm_list_t* mount_points)
{
	alpm_list_t* i = void;

	for(i = mount_points; i; i = i.next) {
		alpm_mountpoint_t* data = cast(alpm_mountpoint_t*)i.data;
		FREE(data.mount_dir);
	}
	FREELIST(mount_points);
}

private int mount_point_load_fsinfo(AlpmHandle handle, alpm_mountpoint_t* mountpoint)
{
version (HAVE_GETMNTENT) {
	/* grab the filesystem usage */
	if(statvfs(mountpoint.mount_dir, &(mountpoint.fsp)) != 0) {
		_alpm_log(handle, ALPM_LOG_WARNING,
				("could not get filesystem information for %s: %s\n"),
				mountpoint.mount_dir, strerror(errno));
		mountpoint.fsinfo_loaded = MOUNT_FSINFO_FAIL;
		return -1;
	}

	_alpm_log(handle, ALPM_LOG_DEBUG, "loading fsinfo for %s\n", mountpoint.mount_dir);
	mountpoint.read_only = mountpoint.fsp.f_flag & ST_RDONLY;
	mountpoint.fsinfo_loaded = MOUNT_FSINFO_LOADED;
} else {
	cast(void)handle;
	cast(void)mountpoint;
}

	return 0;
}

private alpm_list_t* mount_point_list(AlpmHandle handle)
{
	alpm_list_t* mount_points = null, ptr = void;
	alpm_mountpoint_t* mp = void;

static if (HasVersion!"HAVE_GETMNTENT" && HasVersion!"HAVE_MNTENT_H") {
	/* Linux */
	mntent* mnt = void;
	FILE* fp = void;

	fp = setmntent(MOUNTED, "r");

	if(fp == null) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not open file: %s: %s\n"),
				MOUNTED, strerror(errno));
		return null;
	}

	while((mnt = getmntent(fp))) {
		if(mnt.mnt_dir == null) {
			continue;
		}

		CALLOC(mp, 1, alpm_mountpoint_t.sizeof);
		STRDUP(mp.mount_dir, mnt.mnt_dir);
		mp.mount_dir_len = strlen(mp.mount_dir);

		mount_points = alpm_list_add(mount_points, mp);
	}

	endmntent(fp);
} else static if (HasVersion!"HAVE_GETMNTENT" && HasVersion!"HAVE_MNTTAB_H") {
	/* Solaris, Illumos */
	mnttab mnt = void;
	FILE* fp = void;
	int ret = void;

	fp = fopen("/etc/mnttab", "r");

	if(fp == null) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not open file %s: %s\n"),
				"/etc/mnttab", strerror(errno));
		return null;
	}

	while((ret = getmntent(fp, &mnt)) == 0) {
		if(mnt.mnt_mountp == null) {
			continue;
		}

		CALLOC(mp, 1, alpm_mountpoint_t.sizeof);
		STRDUP(mp.mount_dir, mnt.mnt_mountp);
		mp.mount_dir_len = strlen(mp.mount_dir);

		mount_points = alpm_list_add(mount_points, mp);
	}
	/* -1 == EOF */
	if(ret != -1) {
		_alpm_log(handle, ALPM_LOG_WARNING,
				("could not get filesystem information\n"));
	}

	fclose(fp);
} else version (HAVE_GETMNTINFO) {
	/* FreeBSD (statfs), NetBSD (statvfs), OpenBSD (statfs), OS X (statfs) */
	int entries = void;
	FSSTATSTYPE* fsp = void;

	entries = getmntinfo(&fsp, MNT_NOWAIT);

	if(entries < 0) {
		_alpm_log(handle, ALPM_LOG_ERROR,
				("could not get filesystem information\n"));
		return null;
	}

	for(; entries-- > 0; fsp++) {
		if(fsp.f_mntonname == null) {
			continue;
		}

		CALLOC(mp, 1, alpm_mountpoint_t.sizeof);
		STRDUP(mp.mount_dir, fsp.f_mntonname);
		mp.mount_dir_len = strlen(mp.mount_dir);
		memcpy(&(mp.fsp), fsp, FSSTATSTYPE.sizeof);
static if (HasVersion!"HAVE_GETMNTINFO_STATVFS" && HasVersion!"HAVE_STRUCT_STATVFS_F_FLAG") {
		mp.read_only = fsp.f_flag & ST_RDONLY;
} else static if (HasVersion!"HAVE_GETMNTINFO_STATFS" && HasVersion!"HAVE_STRUCT_STATFS_F_FLAGS") {
		mp.read_only = fsp.f_flags & MNT_RDONLY;
}

		/* we don't support lazy loading on this platform */
		mp.fsinfo_loaded = MOUNT_FSINFO_LOADED;

		mount_points = alpm_list_add(mount_points, mp);
	}
}

	mount_points = alpm_list_msort(mount_points, alpm_list_count(mount_points),
			&mount_point_cmp);
	for(ptr = mount_points; ptr != null; ptr = ptr.next) {
		mp = cast(alpm_mountpoint_t*)ptr.data;
		_alpm_log(handle, ALPM_LOG_DEBUG, "discovered mountpoint: %s\n", mp.mount_dir);
	}
	return mount_points;
}

private alpm_mountpoint_t* match_mount_point( alpm_list_t* mount_points,   char*real_path)
{
	 alpm_list_t* mp = void;

	for(mp = mount_points; mp != null; mp = mp.next) {
		alpm_mountpoint_t* data = cast(alpm_mountpoint_t*)mp.data;

		/* first, check if the prefix matches */
		if(strncmp(data.mount_dir, real_path, data.mount_dir_len) == 0) {
			/* now, the hard work- a file like '/etc/myconfig' shouldn't map to a
			 * mountpoint '/e', but only '/etc'. If the mountpoint ends in a trailing
			 * slash, we know we didn't have a mismatch, otherwise we have to do some
			 * more sanity checks. */
			if(data.mount_dir[data.mount_dir_len - 1] == '/') {
				return data;
			} else if(strlen(real_path) >= data.mount_dir_len) {
				 char next = real_path[data.mount_dir_len];
				if(next == '/' || next == '\0') {
					return data;
				}
			}
		}
	}

	/* should not get here... */
	return null;
}

private int calculate_removed_size(AlpmHandle handle,  alpm_list_t* mount_points, alpm_pkg_t* pkg)
{
	size_t i = void;
	alpm_filelist_t* filelist = alpm_pkg_get_files(pkg);

	if(!filelist.count) {
		return 0;
	}

	for(i = 0; i < filelist.count; i++) {
		alpm_file_t* file = filelist.files + i;
		alpm_mountpoint_t* mp = void;
		stat_t st = void;
		char[PATH_MAX] path = void;
		blkcnt_t remove_size = void;
		  char*filename = file.name;

		snprintf(path.ptr, PATH_MAX, "%s%s", handle.root, filename);

		if(lstat(path.ptr, &st) == -1) {
			if(alpm_option_match_noextract(handle, filename)) {
				_alpm_log(handle, ALPM_LOG_WARNING,
						("could not get file information for %s\n"), filename);
			}
			continue;
		}

		/* skip directories and symlinks to be consistent with libarchive that
		 * reports them to be zero size */
		if(S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
			continue;
		}

		mp = match_mount_point(mount_points, path.ptr);
		if(mp == null) {
			_alpm_log(handle, ALPM_LOG_WARNING,
					("could not determine mount point for file %s\n"), filename);
			continue;
		}

		/* don't check a mount that we know we can't stat_t */
		if(mp && mp.fsinfo_loaded == MOUNT_FSINFO_FAIL) {
			continue;
		}

		/* lazy load filesystem info */
		if(mp.fsinfo_loaded == MOUNT_FSINFO_UNLOADED) {
			if(mount_point_load_fsinfo(handle, mp) < 0) {
				continue;
			}
		}

		/* the addition of (divisor - 1) performs ceil() with integer division */
		remove_size = (st.st_size + mp.fsp.f_bsize - 1) / mp.fsp.f_bsize;
		mp.blocks_needed -= remove_size;
		mp.used |= USED_REMOVE;
	}

	return 0;
}

private int calculate_installed_size(AlpmHandle handle,  alpm_list_t* mount_points, alpm_pkg_t* pkg)
{
	size_t i = void;
	alpm_filelist_t* filelist = alpm_pkg_get_files(pkg);

	if(!filelist.count) {
		return 0;
	}

	for(i = 0; i < filelist.count; i++) {
		alpm_file_t* file = filelist.files + i;
		alpm_mountpoint_t* mp = void;
		char[PATH_MAX] path = void;
		blkcnt_t install_size = void;
		  char*filename = file.name;

		/* libarchive reports these as zero size anyways */
		/* NOTE: if we do start accounting for directory size, a dir matching a
		 * mountpoint needs to be attributed to the parent, not the mountpoint. */
		if(S_ISDIR(file.mode) || S_ISLNK(file.mode)) {
			continue;
		}

		/* approximate space requirements for db entries */
		if(filename[0] == '.') {
			filename = handle.dbpath;
		}

		snprintf(path.ptr, PATH_MAX, "%s%s", handle.root, filename);

		mp = match_mount_point(mount_points, path.ptr);
		if(mp == null) {
			_alpm_log(handle, ALPM_LOG_WARNING,
					("could not determine mount point for file %s\n"), filename);
			continue;
		}

		/* don't check a mount that we know we can't stat_t */
		if(mp && mp.fsinfo_loaded == MOUNT_FSINFO_FAIL) {
			continue;
		}

		/* lazy load filesystem info */
		if(mp.fsinfo_loaded == MOUNT_FSINFO_UNLOADED) {
			if(mount_point_load_fsinfo(handle, mp) < 0) {
				continue;
			}
		}

		/* the addition of (divisor - 1) performs ceil() with integer division */
		install_size = (file.size + mp.fsp.f_bsize - 1) / mp.fsp.f_bsize;
		mp.blocks_needed += install_size;
		mp.used |= USED_INSTALL;
	}

	return 0;
}

private int check_mountpoint(AlpmHandle handle, alpm_mountpoint_t* mp)
{
	/* cushion is roughly min(5% capacity, 20MiB) */
	fsblkcnt_t fivepc = (mp.fsp.f_blocks / 20) + 1;
	fsblkcnt_t twentymb = (20 * 1024 * 1024 / mp.fsp.f_bsize) + 1;
	fsblkcnt_t cushion = fivepc < twentymb ? fivepc : twentymb;
	blkcnt_t needed = mp.max_blocks_needed + cushion;

	_alpm_log(handle, ALPM_LOG_DEBUG,
			"partition %s, needed %jd, cushion %ju, free %ju\n",
			mp.mount_dir, cast(intmax_t)mp.max_blocks_needed,
			cast(uintmax_t)cushion, cast(uintmax_t)mp.fsp.f_bavail);
	if(needed >= 0 && cast(fsblkcnt_t)needed > mp.fsp.f_bavail) {
		_alpm_log(handle, ALPM_LOG_ERROR,
				("Partition %s too full: %jd blocks needed, %ju blocks free\n"),
				mp.mount_dir, cast(intmax_t)needed, cast(uintmax_t)mp.fsp.f_bavail);
		return 1;
	}
	return 0;
}

int _alpm_check_downloadspace(AlpmHandle handle,   char*cachedir, size_t num_files,  off_t* file_sizes)
{
	alpm_list_t* mount_points = void;
	alpm_mountpoint_t* cachedir_mp = void;
	char[PATH_MAX] resolved_cachedir = void;
	size_t j = void;
	int error = 0;

	/* resolve the cachedir path to ensure we check the right mountpoint. We
	 * handle failures silently, and continue to use the possibly unresolved
	 * path. */
	if(realpath(cachedir, resolved_cachedir.ptr) != null) {
		cachedir = resolved_cachedir.ptr;
	}

	mount_points = mount_point_list(handle);
	if(mount_points == null) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not determine filesystem mount points\n"));
		return -1;
	}

	cachedir_mp = match_mount_point(mount_points, cachedir);
	if(cachedir_mp == null) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not determine cachedir mount point %s\n"),
				cachedir);
		error = 1;
		goto finish;
	}

	if(cachedir_mp.fsinfo_loaded == MOUNT_FSINFO_UNLOADED) {
		if(mount_point_load_fsinfo(handle, cachedir_mp)) {
			error = 1;
			goto finish;
		}
	}

	/* there's no need to check for a R/O mounted filesystem here, as
	 * _alpm_filecache_setup will never give us a non-writable directory */

	/* round up the size of each file to the nearest block and accumulate */
	for(j = 0; j < num_files; j++) {
		cachedir_mp.max_blocks_needed += (file_sizes[j] + cachedir_mp.fsp.f_bsize + 1) /
			cachedir_mp.fsp.f_bsize;
	}

	if(check_mountpoint(handle, cachedir_mp)) {
		error = 1;
	}

finish:
	mount_point_list_free(mount_points);

	if(error) {
		RET_ERR(handle, ALPM_ERR_DISK_SPACE, -1);
	}

	return 0;
}

int _alpm_check_diskspace(AlpmHandle handle)
{
	alpm_list_t* mount_points = void, i = void;
	alpm_mountpoint_t* root_mp = void;
	size_t replaces = 0, current = 0, numtargs = void;
	int error = 0;
	alpm_list_t* targ = void;
	alpm_trans_t* trans = handle.trans;

	numtargs = alpm_list_count(trans.add);
	mount_points = mount_point_list(handle);
	if(mount_points == null) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not determine filesystem mount points\n"));
		return -1;
	}
	root_mp = match_mount_point(mount_points, handle.root);
	if(root_mp == null) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("could not determine root mount point %s\n"),
				handle.root);
		error = 1;
		goto finish;
	}

	replaces = alpm_list_count(trans.remove);
	if(replaces) {
		numtargs += replaces;
		for(targ = trans.remove; targ; targ = targ.next, current++) {
			alpm_pkg_t* local_pkg = void;
			int percent = cast(int)((current * 100) / numtargs);
			PROGRESS(handle, ALPM_PROGRESS_DISKSPACE_START, "", percent,
					numtargs, current);

			local_pkg = cast(alpm_pkg_t*)targ.data;
			calculate_removed_size(handle, mount_points, local_pkg);
		}
	}

	for(targ = trans.add; targ; targ = targ.next, current++) {
		alpm_pkg_t* pkg = void, local_pkg = void;
		int percent = cast(int)((current * 100) / numtargs);
		PROGRESS(handle, ALPM_PROGRESS_DISKSPACE_START, "", percent,
				numtargs, current);

		pkg = cast(alpm_pkg_t*)targ.data;
		/* is this package already installed? */
		local_pkg = _alpm_db_get_pkgfromcache(handle.db_local, pkg.name);
		if(local_pkg) {
			calculate_removed_size(handle, mount_points, local_pkg);
		}
		calculate_installed_size(handle, mount_points, pkg);

		for(i = mount_points; i; i = i.next) {
			alpm_mountpoint_t* data = cast(alpm_mountpoint_t*)i.data;
			if(data.blocks_needed > data.max_blocks_needed) {
				data.max_blocks_needed = data.blocks_needed;
			}
		}
	}

	PROGRESS(handle, ALPM_PROGRESS_DISKSPACE_START, "", 100,
			numtargs, current);

	for(i = mount_points; i; i = i.next) {
		alpm_mountpoint_t* data = cast(alpm_mountpoint_t*)i.data;
		if(data.used && data.read_only) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("Partition %s is mounted read only\n"),
					data.mount_dir);
			error = 1;
		} else if(data.used & USED_INSTALL && check_mountpoint(handle, data)) {
			error = 1;
		}
	}

finish:
	mount_point_list_free(mount_points);

	if(error) {
		RET_ERR(handle, ALPM_ERR_DISK_SPACE, -1);
	}

	return 0;
}
