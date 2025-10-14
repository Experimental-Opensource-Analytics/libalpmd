module sandbox_fs.c;
@nogc nothrow:
extern(C): __gshared:
/*
 *  sandbox_fs.c
 *
 *  Copyright (c) 2021-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
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
import core.sys.posix.fcntl;
import core.stdc.stddef;
import core.sys.posix.unistd;

import config;
import log;
import sandbox_fs;
import util;

version (HAVE_LINUX_LANDLOCK_H) {
	import core.sys.linux.sys.landlock;
	import core.sys.linux.sys.prctl;
	import core.sys.linux.sys;
} /* HAVE_LINUX_LANDLOCK_H */

version (HAVE_LINUX_LANDLOCK_H) {
version (landlock_create_ruleset) {} else {
pragma(inline, true) private int landlock_create_ruleset(const(landlock_ruleset_attr*) attr, const(size_t) size, const(uint) flags)
{
	return syscall(__NR_landlock_create_ruleset, attr, size, flags);
}
} /* landlock_create_ruleset */

version (landlock_add_rule) {} else {
pragma(inline, true) private int landlock_add_rule(const(int) ruleset_fd, const(landlock_rule_type) rule_type, const(void*) rule_attr, const(uint) flags)
{
	return syscall(__NR_landlock_add_rule, ruleset_fd, rule_type, rule_attr, flags);
}
} /* landlock_add_rule */

version (landlock_restrict_self) {} else {
pragma(inline, true) private int landlock_restrict_self(const(int) ruleset_fd, const(uint) flags)
{
	return syscall(__NR_landlock_restrict_self, ruleset_fd, flags);
}
} /* landlock_restrict_self */

enum _LANDLOCK_ACCESS_FS_WRITE = ( \
  LANDLOCK_ACCESS_FS_WRITE_FILE | \
  LANDLOCK_ACCESS_FS_REMOVE_DIR | \
  LANDLOCK_ACCESS_FS_REMOVE_FILE | \
  LANDLOCK_ACCESS_FS_MAKE_CHAR | \
  LANDLOCK_ACCESS_FS_MAKE_DIR | \
  LANDLOCK_ACCESS_FS_MAKE_REG | \
  LANDLOCK_ACCESS_FS_MAKE_SOCK | \
  LANDLOCK_ACCESS_FS_MAKE_FIFO | \
  LANDLOCK_ACCESS_FS_MAKE_BLOCK | \
  LANDLOCK_ACCESS_FS_MAKE_SYM);

enum _LANDLOCK_ACCESS_FS_READ = ( \
  LANDLOCK_ACCESS_FS_READ_FILE | \
  LANDLOCK_ACCESS_FS_READ_DIR);

version (LANDLOCK_ACCESS_FS_REFER) {
enum _LANDLOCK_ACCESS_FS_REFER = LANDLOCK_ACCESS_FS_REFER;
} else {
enum _LANDLOCK_ACCESS_FS_REFER = 0;
} /* LANDLOCK_ACCESS_FS_REFER */

version (LANDLOCK_ACCESS_FS_TRUNCATE) {
enum _LANDLOCK_ACCESS_FS_TRUNCATE = LANDLOCK_ACCESS_FS_TRUNCATE;
} else {
enum _LANDLOCK_ACCESS_FS_TRUNCATE = 0;
} /* LANDLOCK_ACCESS_FS_TRUNCATE */

} /* HAVE_LINUX_LANDLOCK_H */

bool _alpm_sandbox_fs_restrict_writes_to(alpm_handle_t* handle, const(char)* path)
{
	ASSERT(handle != null);
	ASSERT(path != null);

version (HAVE_LINUX_LANDLOCK_H) {
	landlock_ruleset_attr ruleset_attr = {
		handled_access_fs: 
			_LANDLOCK_ACCESS_FS_READ | 
			_LANDLOCK_ACCESS_FS_WRITE | 
			_LANDLOCK_ACCESS_FS_REFER | 
			_LANDLOCK_ACCESS_FS_TRUNCATE | 
			LANDLOCK_ACCESS_FS_EXECUTE,
	};
	landlock_path_beneath_attr path_beneath = {
		allowed_access: _LANDLOCK_ACCESS_FS_READ,
	};
	int abi = 0;
	int result = 0;
	int ruleset_fd = void;

	abi = landlock_create_ruleset(null, 0, LANDLOCK_CREATE_RULESET_VERSION);
	if(abi < 0) {
		/* landlock is not supported/enabled in the kernel */
		_alpm_log(handle, ALPM_LOG_ERROR, _("restricting filesystem access failed because landlock is not supported by the kernel!\n"));
		return true;
	}
version (LANDLOCK_ACCESS_FS_REFER) {
	if(abi < 2) {
		_alpm_log(handle, ALPM_LOG_DEBUG, _("landlock ABI < 2, LANDLOCK_ACCESS_FS_REFER is not supported\n"));
		ruleset_attr.handled_access_fs &= ~LANDLOCK_ACCESS_FS_REFER;
	}
} /* LANDLOCK_ACCESS_FS_REFER */
version (LANDLOCK_ACCESS_FS_TRUNCATE) {
	if(abi < 3) {
		_alpm_log(handle, ALPM_LOG_DEBUG, _("landlock ABI < 3, LANDLOCK_ACCESS_FS_TRUNCATE is not supported\n"));
		ruleset_attr.handled_access_fs &= ~LANDLOCK_ACCESS_FS_TRUNCATE;
	}
} /* LANDLOCK_ACCESS_FS_TRUNCATE */

	ruleset_fd = landlock_create_ruleset(&ruleset_attr, ruleset_attr.sizeof, 0);
	if(ruleset_fd < 0) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("restricting filesystem access failed because the landlock ruleset could not be created!\n"));
		return false;
	}

	/* allow / as read-only */
	path_beneath.parent_fd = open("/", O_PATH | O_CLOEXEC | O_DIRECTORY);
	path_beneath.allowed_access = _LANDLOCK_ACCESS_FS_READ;

	if(landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &path_beneath, 0) != 0) {
		_alpm_log(handle, ALPM_LOG_ERROR, _("restricting filesystem access failed because the landlock rule for / could not be added!\n"));
		close(path_beneath.parent_fd);
		close(ruleset_fd);
		return false;
	}

	close(path_beneath.parent_fd);

	/* allow read-write access to the directory passed as parameter */
	path_beneath.parent_fd = open(path, O_PATH | O_CLOEXEC | O_DIRECTORY);
	path_beneath.allowed_access = _LANDLOCK_ACCESS_FS_READ | _LANDLOCK_ACCESS_FS_WRITE | _LANDLOCK_ACCESS_FS_TRUNCATE;

	/* make sure allowed_access is a subset of handled_access_fs, which may change for older landlock ABI */
	path_beneath.allowed_access &= ruleset_attr.handled_access_fs;

	if(landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &path_beneath, 0) == 0) {
		if(landlock_restrict_self(ruleset_fd, 0)) {
			_alpm_log(handle, ALPM_LOG_ERROR, _("restricting filesystem access failed because the landlock ruleset could not be applied!\n"));
			result = errno;
		}
	} else {
		result = errno;
		_alpm_log(handle, ALPM_LOG_ERROR, _("restricting filesystem access failed because the landlock rule for the temporary download directory could not be added!\n"));
	}

	close(path_beneath.parent_fd);
	close(ruleset_fd);
	if(result == 0) {
		_alpm_log(handle, ALPM_LOG_DEBUG, _("filesystem access has been restricted to %s, landlock ABI is %d\n"), path, abi);
		return true;
        }
	return false;
} else { /* HAVE_LINUX_LANDLOCK_H */
	return true;
} /* HAVE_LINUX_LANDLOCK_H */
}
