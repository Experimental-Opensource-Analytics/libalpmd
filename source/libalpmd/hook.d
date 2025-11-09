module libalpmd.hook;
@nogc  
   
/*
 *  hook.c
 *
 *  Copyright (c) 2015-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
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

import core.sys.posix.dirent;
import core.stdc.errno;
import core.stdc.limits;
import core.stdc.string;
import core.stdc.stdlib;
import libalpmd.handle;
import libalpmd.ini;
import libalpmd.log;
import libalpmd.trans;
import libalpmd.util;
import libalpmd.alpm_list;
import libalpmd.alpm;
import libalpmd.util_common;
import libalpmd.pkg;
import libalpmd.conf;
import libalpmd.db;
import libalpmd.filelist;
import libalpmd.deps;



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


enum _alpm_hook_op_t {
	ALPM_HOOK_OP_INSTALL = (1 << 0),
	ALPM_HOOK_OP_UPGRADE = (1 << 1),
	ALPM_HOOK_OP_REMOVE = (1 << 2),
}
alias ALPM_HOOK_OP_INSTALL = _alpm_hook_op_t.ALPM_HOOK_OP_INSTALL;
alias ALPM_HOOK_OP_UPGRADE = _alpm_hook_op_t.ALPM_HOOK_OP_UPGRADE;
alias ALPM_HOOK_OP_REMOVE = _alpm_hook_op_t.ALPM_HOOK_OP_REMOVE;


enum _alpm_trigger_type_t {
	ALPM_HOOK_TYPE_PACKAGE = 1,
	ALPM_HOOK_TYPE_PATH,
}
alias ALPM_HOOK_TYPE_PACKAGE = _alpm_trigger_type_t.ALPM_HOOK_TYPE_PACKAGE;
alias ALPM_HOOK_TYPE_PATH = _alpm_trigger_type_t.ALPM_HOOK_TYPE_PATH;


struct _alpm_trigger_t {
	_alpm_hook_op_t op;
	_alpm_trigger_type_t type;
	alpm_list_t* targets;
}

struct _alpm_hook_t {
	char* name;
	char* desc;
	alpm_list_t* triggers;
	alpm_list_t* depends;
	char** cmd;
	alpm_list_t* matches;
	alpm_hook_when_t when;
	int abort_on_fail, needs_targets;
}

struct _alpm_hook_cb_ctx {
	AlpmHandle handle;
	_alpm_hook_t* hook;
}

private void _alpm_trigger_free(_alpm_trigger_t* trigger)
{
	if(trigger) {
		FREELIST(trigger.targets);
		free(trigger);
	}
}

private void _alpm_hook_free(_alpm_hook_t* hook)
{
	if(hook) {
		free(hook.name);
		free(hook.desc);
		// wordsplit_free(hook.cmd);
		alpm_list_free_inner(hook.triggers, cast(alpm_list_fn_free) &_alpm_trigger_free);
		alpm_list_free(hook.triggers);
		alpm_list_free(hook.matches);
		FREELIST(hook.depends);
		free(hook);
	}
}

private int _alpm_trigger_validate(AlpmHandle handle, _alpm_trigger_t* trigger,   char*file)
{
	int ret = 0;

	if(trigger.targets == null) {
		ret = -1;
		_alpm_log(handle, ALPM_LOG_ERROR,
				("Missing trigger targets in hook: %s\n"), file);
	}

	if(trigger.type == 0) {
		ret = -1;
		_alpm_log(handle, ALPM_LOG_ERROR,
				("Missing trigger type in hook: %s\n"), file);
	}

	if(trigger.op == 0) {
		ret = -1;
		_alpm_log(handle, ALPM_LOG_ERROR,
				("Missing trigger operation in hook: %s\n"), file);
	}

	return ret;
}

private int _alpm_hook_validate(AlpmHandle handle, _alpm_hook_t* hook,   char*file)
{
	alpm_list_t* i = void;
	int ret = 0;

	if(hook.triggers == null) {
		/* special case: allow triggerless hooks as a way of creating dummy
		 * hooks that can be used to mask lower priority hooks */
		return 0;
	}

	for(i = hook.triggers; i; i = i.next) {
		if(_alpm_trigger_validate(handle, cast(_alpm_trigger_t*)i.data, file) != 0) {
			ret = -1;
		}
	}

	if(hook.cmd == null) {
		ret = -1;
		_alpm_log(handle, ALPM_LOG_ERROR,
				("Missing Exec option in hook: %s\n"), file);
	}

	if(hook.when == 0) {
		ret = -1;
		_alpm_log(handle, ALPM_LOG_ERROR,
				("Missing When option in hook: %s\n"), file);
	} else if(hook.when != ALPM_HOOK_PRE_TRANSACTION && hook.abort_on_fail) {
		_alpm_log(handle, ALPM_LOG_WARNING,
				("AbortOnFail set for PostTransaction hook: %s\n"), file);
	}

	return ret;
}

private int _alpm_hook_parse_cb(  char*file, int line,   char*section, char* key, char* value, void* data)
{
	_alpm_hook_cb_ctx* ctx = cast(_alpm_hook_cb_ctx*)data;
	AlpmHandle handle = ctx.handle;
	_alpm_hook_t* hook = ctx.hook;

	
auto error = (char* fmt, char* arg1, int arg2, char* arg3 = null, char* arg4 = null, char* arg5 = null) {
		if (arg3 !is null && arg4 !is null && arg5 !is null) {
			// _alpm_log(handle, ALPM_LOG_ERROR, fmt, arg1, arg2, arg3, arg4, arg5);
		} else if (arg3 !is null && arg4 !is null) {
			// _alpm_log(handle, ALPM_LOG_ERROR, fmt, arg1, arg2, arg3, arg4);
		} else if (arg3 !is null) {
			// _alpm_log(handle, ALPM_LOG_ERROR, fmt, arg1, arg2, arg3);
		} else {
			// _alpm_log(handle, ALPM_LOG_ERROR, fmt, arg1, arg2);
		}
		return 1;
	};
	
	auto warning = (char*  fmt, char*  arg1, int arg2, char*  arg3 = null, char*  arg4 = null, char*  arg5 = null) {
		if (arg3 !is null && arg4 !is null && arg5 !is null) {
			// _alpm_log(handle, ALPM_LOG_WARNING, fmt, arg1, arg2, arg3, arg4, arg5);
		} else if (arg3 !is null && arg4 !is null) {
			// _alpm_log(handle, ALPM_LOG_WARNING, fmt, arg1, arg2, arg3, arg4);
		} else if (arg3 !is null) {
			// _alpm_log(handle, ALPM_LOG_WARNING, fmt, arg1, arg2, arg3);
		} else {
			// _alpm_log(handle, ALPM_LOG_WARNING, fmt, arg1, arg2);
		}
		return 0;
	};

	if(!section && !key) {
		return error(cast(char*)"error while reading hook %s: %s\n", file, line, strerror(cast(char*)errno));
	} else if(!section) {
		return error(cast(char*)"hook %s line %d: invalid option %s\n", file, line, key);
	} else if(!key) {
		/* beginning a new section */
		if(strcmp(section, "Trigger") == 0) {
			_alpm_trigger_t* t;
			CALLOC(t, _alpm_trigger_t.sizeof, 1);
			hook.triggers = alpm_list_add(hook.triggers, t);
		} else if(strcmp(section, "Action") == 0) {
			/* no special processing required */
		} else {
			return error(cast(char*)"hook %s line %d: invalid section %s\n", file, line, section);
		}
	} else if(strcmp(section, "Trigger") == 0) {
		_alpm_trigger_t* t = cast(_alpm_trigger_t*)hook.triggers.prev.data;
		if(strcmp(key, "Operation") == 0) {
			if(strcmp(value, "Install") == 0) {
				t.op |= ALPM_HOOK_OP_INSTALL;
			} else if(strcmp(value, "Upgrade") == 0) {
				t.op |= ALPM_HOOK_OP_UPGRADE;
			} else if(strcmp(value, "Remove") == 0) {
				t.op |= ALPM_HOOK_OP_REMOVE;
			} else {
				return error(cast(char*)"hook %s line %d: invalid value %s\n", file, line, value);
			}
		} else if(strcmp(key, "Type") == 0) {
			if(t.type != 0) {
				warning(cast(char*)"hook %s line %d: overwriting previous definition of %s\n", file, line, cast(char*)"Type");
			}
			if(strcmp(value, "Package") == 0) {
				t.type = ALPM_HOOK_TYPE_PACKAGE;
			} else if(strcmp(value, "File") == 0) {
				_alpm_log(handle, ALPM_LOG_DEBUG,
						"File targets are deprecated, use Path instead\n");
				t.type = ALPM_HOOK_TYPE_PATH;
			} else if(strcmp(value, "Path") == 0) {
				t.type = ALPM_HOOK_TYPE_PATH;
			} else {
				return error(cast(char*)"hook %s line %d: invalid value %s\n", file, line, value);
			}
		} else if(strcmp(key, "Target") == 0) {
			char* val;
			STRDUP(val, value);
			t.targets = alpm_list_add(t.targets, val);
		} else {
			return error(cast(char*)"hook %s line %d: invalid option %s\n", file, line, key);
		}
	} else if(strcmp(section, "Action") == 0) {
		if(strcmp(key, "When") == 0) {
			if(hook.when != 0) {
				warning(cast(char*)"hook %s line %d: overwriting previous definition of %s\n", file, line, cast(char*)"When");
			}
			if(strcmp(value, "PreTransaction") == 0) {
				hook.when = ALPM_HOOK_PRE_TRANSACTION;
			} else if(strcmp(value, "PostTransaction") == 0) {
				hook.when = ALPM_HOOK_POST_TRANSACTION;
			} else {
				return error(cast(char*)"hook %s line %d: invalid value %s\n", file, line, value);
			}
		} else if(strcmp(key, "Description") == 0) {
			if(hook.desc != null) {
				warning(cast(char*)"hook %s line %d: overwriting previous definition of %s\n", file, line, cast(char*)"Description");
				FREE(hook.desc);
			}
			STRDUP(hook.desc, value);
		} else if(strcmp(key, "Depends") == 0) {
			char* val;
			STRDUP(val, value);
			hook.depends = alpm_list_add(hook.depends, val);
		} else if(strcmp(key, "AbortOnFail") == 0) {
			hook.abort_on_fail = 1;
		} else if(strcmp(key, "NeedsTargets") == 0) {
			hook.needs_targets = 1;
		} else if(strcmp(key, "Exec") == 0) {
			if(hook.cmd != null) {
				warning(cast(char*)"hook %s line %d: overwriting previous definition of %s\n", file, line, cast(char*)"Exec");
				wordsplit_free(hook.cmd);
			}
			if((hook.cmd = wordsplit(value)) == null) {
				if(errno == EINVAL) {
					return error(cast(char*)"hook %s line %d: invalid value %s\n", file, line, value);
				} else {
					return error(cast(char*)"hook %s line %d: unable to set option (%s)\n", file, line, strerror(errno));
				}
			}
		} else {
			return error(cast(char*)"hook %s line %d: invalid option %s\n", file, line, key);
		}
	}

	return 0;
}

private int _alpm_hook_trigger_match_file(AlpmHandle handle, _alpm_hook_t* hook, _alpm_trigger_t* t)
{
	alpm_list_t* i = void, j = void, install = null, upgrade = null, remove = null;
	size_t isize = 0, rsize = 0;
	int ret = 0;

	/* check if file will be installed */
	for(i = handle.trans.add; i; i = i.next) {
		AlpmPkg pkg = cast(AlpmPkg)i.data;
		AlpmFileList filelist = pkg.files;
		size_t f = void;
		for(f = 0; f < filelist.length; f++) {
			if(alpm_option_match_noextract(handle, cast(char*)filelist[f].name) == 0) {
				continue;
			}
			if(_alpm_fnmatch_patterns(t.targets, cast(char*)filelist[f].name) == 0) {
				install = alpm_list_add(install, cast(char*)filelist[f].name);
				isize++;
			}
		}
	}

	/* check if file will be removed due to package upgrade */
	for(i = handle.trans.add; i; i = i.next) {
		AlpmPkg spkg = cast(AlpmPkg)i.data;
		AlpmPkg pkg = spkg.oldpkg;
		if(pkg) {
			AlpmFileList filelist = pkg.files;
			size_t f = void;
			for(f = 0; f < filelist.length; f++) {
				if(_alpm_fnmatch_patterns(t.targets, cast(char*)filelist.ptr[f].name) == 0) {
					remove = alpm_list_add(remove, cast(char*)filelist.ptr[f].name);
					rsize++;
				}
			}
		}
	}

	/* check if file will be removed due to package removal */
	for(i = handle.trans.remove; i; i = i.next) {
		AlpmPkg pkg = cast(AlpmPkg)i.data;
		AlpmFileList filelist = pkg.files;
		size_t f = void;
		for(f = 0; f < filelist.length; f++) {
			if(_alpm_fnmatch_patterns(t.targets, cast(char*)filelist.ptr[f].name) == 0) {
				remove = alpm_list_add(remove, cast(char*)filelist.ptr[f].name);
				rsize++;
			}
		}
	}

	i = install = alpm_list_msort(install, isize, cast(alpm_list_fn_cmp)&strcmp);
	j = remove = alpm_list_msort(remove, rsize, cast(alpm_list_fn_cmp)&strcmp);
	while(i) {
		while(j && strcmp(cast(char*)i.data, cast(char*)j.data) > 0) {
			j = j.next;
		}
		if(j == null) {
			break;
		}
		if(strcmp(cast(char*)i.data, cast(char*)j.data) == 0) {
			char* path = cast(char*)i.data;
			upgrade = alpm_list_add(upgrade, path);
			while(i && strcmp(cast(char*)i.data, path) == 0) {
				alpm_list_t* next = i.next;
				install = alpm_list_remove_item(install, i);
				free(i);
				i = next;
			}
			while(j && strcmp(cast(char*)j.data, cast(char*)path) == 0) {
				alpm_list_t* next = j.next;
				remove = alpm_list_remove_item(remove, j);
				free(j);
				j = next;
			}
		} else {
			i = i.next;
		}
	}

	ret = (t.op & ALPM_HOOK_OP_INSTALL && install)
			|| (t.op & ALPM_HOOK_OP_UPGRADE && upgrade)
			|| (t.op & ALPM_HOOK_OP_REMOVE && remove);

	if(hook.needs_targets) {
enum string _save_matches(string _op, string _matches) = `
	if(t.op & ` ~ _op ~ ` && ` ~ _matches ~ `) { 
		hook.matches = alpm_list_join(hook.matches, ` ~ _matches ~ `); 
	} else { 
		alpm_list_free(` ~ _matches ~ `); 
	}`;
		mixin(_save_matches!(`ALPM_HOOK_OP_INSTALL`, `install`));
		mixin(_save_matches!(`ALPM_HOOK_OP_UPGRADE`, `upgrade`));
		mixin(_save_matches!(`ALPM_HOOK_OP_REMOVE`, `remove`));
	} else {
		alpm_list_free(install);
		alpm_list_free(upgrade);
		alpm_list_free(remove);
	}

	return ret;
}

private int _alpm_hook_trigger_match_pkg(AlpmHandle handle, _alpm_hook_t* hook, _alpm_trigger_t* t)
{
	alpm_list_t* install = null, upgrade = null, remove = null;

	if(t.op & ALPM_HOOK_OP_INSTALL || t.op & ALPM_HOOK_OP_UPGRADE) {
		alpm_list_t* i = void;
		for(i = handle.trans.add; i; i = i.next) {
			AlpmPkg pkg = cast(AlpmPkg)i.data;
			if(_alpm_fnmatch_patterns(t.targets, cast(char*)pkg.name) == 0) {
				if(pkg.oldpkg) {
					if(t.op & ALPM_HOOK_OP_UPGRADE) {
						if(hook.needs_targets) {
							upgrade = alpm_list_add(upgrade, cast(char*)pkg.name);
						} else {
							return 1;
						}
					}
				} else {
					if(t.op & ALPM_HOOK_OP_INSTALL) {
						if(hook.needs_targets) {
							install = alpm_list_add(install, cast(char*)pkg.name);
						} else {
							return 1;
						}
					}
				}
			}
		}
	}

	if(t.op & ALPM_HOOK_OP_REMOVE) {
		alpm_list_t* i = void;
		for(i = handle.trans.remove; i; i = i.next) {
			AlpmPkg pkg = cast(AlpmPkg)i.data;
			if(pkg && _alpm_fnmatch_patterns(t.targets, cast(char*)pkg.name) == 0) {
				if(!alpm_list_find(handle.trans.add, cast(void*)pkg, &_alpm_pkg_cmp)) {
					if(hook.needs_targets) {
						remove = alpm_list_add(remove, cast(char*)pkg.name);
					} else {
						return 1;
					}
				}
			}
		}
	}

	/* if we reached this point we either need the target lists or we didn't
	 * match anything and the following calls will all be no-ops */
	hook.matches = alpm_list_join(hook.matches, install);
	hook.matches = alpm_list_join(hook.matches, upgrade);
	hook.matches = alpm_list_join(hook.matches, remove);

	return install || upgrade || remove;
}

private int _alpm_hook_trigger_match(AlpmHandle handle, _alpm_hook_t* hook, _alpm_trigger_t* t)
{
	return t.type == ALPM_HOOK_TYPE_PACKAGE
		? _alpm_hook_trigger_match_pkg(handle, hook, t)
		: _alpm_hook_trigger_match_file(handle, hook, t);
}

private int _alpm_hook_triggered(AlpmHandle handle, _alpm_hook_t* hook)
{
	alpm_list_t* i = void;
	int ret = 0;
	for(i = hook.triggers; i; i = i.next) {
		if(_alpm_hook_trigger_match(handle, hook, cast(_alpm_trigger_t*)i.data)) {
			if(!hook.needs_targets) {
				return 1;
			} else {
				ret = 1;
			}
		}
	}
	return ret;
}

private int _alpm_hook_cmp(_alpm_hook_t* h1, _alpm_hook_t* h2)
{
	size_t suflen = strlen(ALPM_HOOK_SUFFIX), l1 = void, l2 = void;
	int ret = void;
	l1 = strlen(h1.name) - suflen;
	l2 = strlen(h2.name) - suflen;
	/* exclude the suffixes from comparison */
	ret = strncmp(h1.name, h2.name, l1 <= l2 ? l1 : l2);
	if(ret == 0 && l1 != l2) {
		return l1 < l2 ? -1 : 1;
	}
	return ret;
}

private alpm_list_t* find_hook(alpm_list_t* haystack,  void* needle)
{
	while(haystack) {
		_alpm_hook_t* h = cast(_alpm_hook_t*)haystack.data;
		if(h && strcmp(h.name, cast(char*)needle) == 0) {
			return haystack;
		}
		haystack = haystack.next;
	}
	return null;
}

private ssize_t _alpm_hook_feed_targets(char* buf, ssize_t needed, alpm_list_t** pos)
{
	size_t remaining = needed, written = 0;{}
	size_t len = void;

	while(*pos && (len = strlen( cast(char*)(*pos).data)) + 1 <= remaining) {
		memcpy(buf, (*pos).data, len);
		buf[len++] = '\n';
		*pos = (*pos).next;
		buf += len;
		remaining -= len;
		written += len;
	}

	if(*pos && remaining) {
		memcpy(buf, (*pos).data, remaining);
		(*pos).data = cast(char*) (*pos).data + remaining;
		written += remaining;
	}

	return written;
}

private alpm_list_t* _alpm_strlist_dedup(alpm_list_t* list)
{
	alpm_list_t* i = list;
	while(i) {
		alpm_list_t* next = i.next;
		while(next && strcmp( cast(char*)i.data,  cast(char*)next.data) == 0) {
			list = alpm_list_remove_item(list, next);
			free(next);
			next = i.next;
		}
		i = next;
	}
	return list;
}

private int _alpm_hook_run_hook(AlpmHandle handle, _alpm_hook_t* hook)
{
	alpm_list_t* i = void, pkgs = _alpm_db_get_pkgcache(handle.db_local);

	for(i = hook.depends; i; i = i.next) {
		if(!alpm_find_satisfier(pkgs, cast(char*)i.data)) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("unable to run hook %s: %s\n"),
					hook.name, ("could not satisfy dependencies"));
			return -1;
		}
	}

	if(hook.needs_targets) {
		alpm_list_t* ctx = void;
		hook.matches = alpm_list_msort(hook.matches,
				alpm_list_count(hook.matches), cast(alpm_list_fn_cmp)&strcmp);
		/* hooks with multiple triggers could have duplicate matches */
		ctx = hook.matches = _alpm_strlist_dedup(hook.matches);
		return _alpm_run_chroot(handle, hook.cmd[0], hook.cmd,
				cast(_alpm_cb_io) &_alpm_hook_feed_targets, &ctx);
	} else {
		return _alpm_run_chroot(handle, hook.cmd[0], hook.cmd, null, null);
	}
}

int _alpm_hook_run(AlpmHandle handle, alpm_hook_when_t when)
{
	alpm_event_hook_t event = { when: when };
	alpm_event_hook_run_t hook_event = void;
	alpm_list_t* i = void, hooks = null, hooks_triggered = null;
	size_t suflen = strlen(ALPM_HOOK_SUFFIX), triggered = 0;
	int ret = 0;

	for(i = alpm_list_last(handle.hookdirs); i; i = alpm_list_previous(i)) {
		char[PATH_MAX] path = void;
		size_t dirlen = void;
		dirent* entry = void;
		DIR* d = void;

		if((dirlen = strlen(cast(char*)i.data)) >= PATH_MAX) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("could not open directory: %s: %s\n"),
					cast(char*)i.data, strerror(ENAMETOOLONG));
			ret = -1;
			continue;
		}
		memcpy(path.ptr, i.data, dirlen + 1);

		if(((d = opendir(path.ptr)) is null)) {
			if(errno == ENOENT) {
				continue;
			} else {
				_alpm_log(handle, ALPM_LOG_ERROR,
						("could not open directory: %s: %s\n"), path.ptr, strerror(errno));
				ret = -1;
				continue;
			}
		}

		while((cast(bool)(errno = 0) && cast(bool)(entry = readdir(d)))) {
			_alpm_hook_cb_ctx ctx = { handle, null };
			stat_t buf = void;
			size_t name_len = void;

			if(strcmp(entry.d_name.ptr, ".".ptr) == 0 || strcmp(entry.d_name.ptr, "..".ptr) == 0) {
				continue;
			}

			if((name_len = strlen(entry.d_name.ptr)) >= PATH_MAX - dirlen) {
				_alpm_log(handle, ALPM_LOG_ERROR, ("could not open file: %s%s: %s\n"),
						path.ptr, entry.d_name, strerror(ENAMETOOLONG));
				ret = -1;
				continue;
			}
			memcpy(path.ptr + dirlen, entry.d_name.ptr, name_len + 1);

			if(name_len < suflen
					|| strcmp(entry.d_name.ptr + name_len - suflen, ALPM_HOOK_SUFFIX) != 0) {
				_alpm_log(handle, ALPM_LOG_DEBUG, "skipping non-hook file %s\n", path.ptr);
				continue;
			}

			if(find_hook(hooks, entry.d_name.ptr)) {
				_alpm_log(handle, ALPM_LOG_DEBUG, "skipping overridden hook %s\n", path.ptr);
				continue;
			}

			if(stat(path.ptr, &buf) != 0) {
				_alpm_log(handle, ALPM_LOG_ERROR,
						("could not stat file %s: %s\n"), path.ptr, strerror(errno));
				ret = -1;
				continue;
			}

			if(S_ISDIR(buf.st_mode)) {
				_alpm_log(handle, ALPM_LOG_DEBUG, "skipping directory %s\n", path.ptr);
				continue;
			}

			CALLOC(ctx.hook, _alpm_hook_t.sizeof, 1);

			_alpm_log(handle, ALPM_LOG_DEBUG, "parsing hook file %s\n", path.ptr);
			if(parse_ini(path.ptr, &_alpm_hook_parse_cb, &ctx) != 0
					|| _alpm_hook_validate(handle, ctx.hook, path.ptr)) {
				_alpm_log(handle, ALPM_LOG_DEBUG, "parsing hook file %s failed\n", path.ptr);
				_alpm_hook_free(ctx.hook);
				ret = -1;
				continue;
			}

			STRDUP(ctx.hook.name, entry.d_name.ptr);
			hooks = alpm_list_add(hooks, ctx.hook);
		}
		if(errno != 0) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("could not read directory: %s: %s\n"),
					cast(char*) i.data, strerror(errno));
			ret = -1;
		}

		closedir(d);
	}

	if(ret != 0 && when == ALPM_HOOK_PRE_TRANSACTION) {
		goto cleanup;
	}

	hooks = alpm_list_msort(hooks, alpm_list_count(hooks),
			cast(alpm_list_fn_cmp)&_alpm_hook_cmp);

	for(i = hooks; i; i = i.next) {
		_alpm_hook_t* hook = cast(_alpm_hook_t*)i.data;
		if(hook && hook.when == when && _alpm_hook_triggered(handle, hook)) {
			hooks_triggered = alpm_list_add(hooks_triggered, hook);
			triggered++;
		}
	}

	if(hooks_triggered != null) {
		event.type = ALPM_EVENT_HOOK_START;
		EVENT(handle, cast(void*)&event);

		hook_event.position = 1;
		hook_event.total = triggered;

		for(i = hooks_triggered; i; i = i.next, hook_event.position++) {
			_alpm_hook_t* hook = cast(_alpm_hook_t*)i.data;
			//alpm_logaction(handle, ALPM_CALLER_PREFIX, "running '%s'...\n", hook.name);

			hook_event.type = ALPM_EVENT_HOOK_RUN_START;
			hook_event.name = hook.name;
			hook_event.desc = hook.desc;
			EVENT(handle, &hook_event);

			if(_alpm_hook_run_hook(handle, hook) != 0 && hook.abort_on_fail) {
				ret = -1;
			}

			hook_event.type = ALPM_EVENT_HOOK_RUN_DONE;
			EVENT(handle, &hook_event);

			if(ret != 0 && when == ALPM_HOOK_PRE_TRANSACTION) {
				break;
			}
		}

		alpm_list_free(hooks_triggered);

		event.type = ALPM_EVENT_HOOK_DONE;
		EVENT(handle, cast(void*)&event);
	}

cleanup:
	alpm_list_free_inner(hooks, cast(alpm_list_fn_free) &_alpm_hook_free);
	alpm_list_free(hooks);

	return ret;
}
