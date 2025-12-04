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
import libalpmd.consts;
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

import std.algorithm;
import std.string;
import std.conv;
import std.string;
import std.algorithm;
import std.array;

enum AlpmHookOp {
	Install = (1 << 0),
	Upgrade = (1 << 1),
	Remove = (1 << 2),
}

enum AlpmHookTriggerType {
	Package = 1,
	Path
}

struct AlpmTrigger {
	AlpmHookOp 			op;
	AlpmHookTriggerType type;
	AlpmStrings 		targets;

	~this() {
		targets.clear();
	}

	bool isNotValid(char* file) {
		bool ret = false;

		if(this.targets.empty) {
			ret = true;
			logger.errorf(
					("Missing trigger targets in hook: %s\n"), file);
		}

		if(this.type == 0) {
			ret = true;
			logger.errorf(
					("Missing trigger type in hook: %s\n"), file);
		}

		if(this.op == 0) {
			ret = true;
			logger.errorf(
					("Missing trigger operation in hook: %s\n"), file);
		}

		return ret;
	}
}

alias AlpmTriggers = AlpmList!AlpmTrigger;

/** Kind of hook. */
enum AlpmHookWhen {
	/* Pre transaction hook */
	PreTransaction = 1,
	/* Post transaction hook */
	PostTransaction
}

struct AlpmHook {
	string name;
	string desc;
	AlpmTriggers 	triggers;
	AlpmStrings 	depends;
	string[] 		cmd;
	AlpmStrings 	matches;
	AlpmHookWhen 	when;
	bool abort_on_fail;
	bool needs_targets;

	~this() {
		destroy(this.name);
		destroy(this.desc);
		cmd.length = 0;
		// alpm_list_free_inner(this.triggers, cast(alpm_list_fn_free) &_alpm_trigger_free);
		this.triggers.clear();
		this.matches.clear();
		this.depends.clear();
	}

	bool isNotValid(char* file) {
		bool ret = false;

		if(this.triggers.empty) {
			/* special case: allow triggerless hooks as a way of creating dummy
			* hooks that can be used to mask lower priority hooks */
			return 0;
		}

		foreach(trigger; this.triggers[]) {
			if(trigger.isNotValid(file)) {
				ret = true;
			}
		}

		if(this.cmd == null) {
			ret = true;
			logger.errorf(
					"Missing Exec option in hook: %s\n", file);
		}

		if(this.when == 0) {
			ret = true;
			logger.errorf(
					"Missing When option in hook: %s\n", file);
		} else if(this.when != AlpmHookWhen.PreTransaction && this.abort_on_fail) {
			logger.warningf(
				"AbortOnFail set for PostTransaction hook: %s\n", file);
		}

		return ret;
	}
}

struct _alpm_hook_cb_ctx {
	AlpmHandle handle;
	AlpmHook* hook;
}

private int _alpm_hook_parse_cb(  char*file, int line,   char*section, char* key, char* value, void* data)
{
	_alpm_hook_cb_ctx* ctx = cast(_alpm_hook_cb_ctx*)data;
	AlpmHandle handle = ctx.handle;
	AlpmHook* hook = ctx.hook;

	
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
			AlpmTrigger* t;
			CALLOC(t, AlpmTrigger.sizeof, 1);
			hook.triggers.insertBack(*t);
		} else if(strcmp(section, "Action") == 0) {
			/* no special processing required */
		} else {
			return error(cast(char*)"hook %s line %d: invalid section %s\n", file, line, section);
		}
	} else if(strcmp(section, "Trigger") == 0) {
		AlpmTrigger* t = &hook.triggers.back(); //??
		if(strcmp(key, "Operation") == 0) {
			if(strcmp(value, "Install") == 0) {
				t.op |= AlpmHookOp.Install;
			} else if(strcmp(value, "Upgrade") == 0) {
				t.op |= AlpmHookOp.Upgrade;
			} else if(strcmp(value, "Remove") == 0) {
				t.op |= AlpmHookOp.Remove;
			} else {
				return error(cast(char*)"hook %s line %d: invalid value %s\n", file, line, value);
			}
		} else if(strcmp(key, "Type") == 0) {
			if(t.type != 0) {
				warning(cast(char*)"hook %s line %d: overwriting previous definition of %s\n", file, line, cast(char*)"Type");
			}
			if(strcmp(value, "Package") == 0) {
				t.type = AlpmHookTriggerType.Package;
			} else if(strcmp(value, "File") == 0) {
				_alpm_log(handle, ALPM_LOG_DEBUG,
						"File targets are deprecated, use Path instead\n");
				t.type = AlpmHookTriggerType.Path;
			} else if(strcmp(value, "Path") == 0) {
				t.type = AlpmHookTriggerType.Path;
			} else {
				return error(cast(char*)"hook %s line %d: invalid value %s\n", file, line, value);
			}
		} else if(strcmp(key, "Target") == 0) {
			char* val;
			STRDUP(val, value);
			t.targets.insertBack(val.to!string);
		} else {
			return error(cast(char*)"hook %s line %d: invalid option %s\n", file, line, key);
		}
	} else if(strcmp(section, "Action") == 0) {
		if(strcmp(key, "When") == 0) {
			if(hook.when != 0) {
				warning(cast(char*)"hook %s line %d: overwriting previous definition of %s\n", file, line, cast(char*)"When");
			}
			if(strcmp(value, "PreTransaction") == 0) {
				hook.when = AlpmHookWhen.PreTransaction;
			} else if(strcmp(value, "PostTransaction") == 0) {
				hook.when = AlpmHookWhen.PostTransaction;
			} else {
				return error(cast(char*)"hook %s line %d: invalid value %s\n", file, line, value);
			}
		} else if(strcmp(key, "Description") == 0) {
			if(hook.desc != null) {
				warning(cast(char*)"hook %s line %d: overwriting previous definition of %s\n", file, line, cast(char*)"Description");
				FREE(hook.desc);
			}
			hook.desc = value.to!string;
		} else if(strcmp(key, "Depends") == 0) {
			char* val;
			STRDUP(val, value);
			hook.depends.insertBack(val.to!string);
		} else if(strcmp(key, "AbortOnFail") == 0) {
			hook.abort_on_fail = 1;
		} else if(strcmp(key, "NeedsTargets") == 0) {
			hook.needs_targets = 1;
		} else if(strcmp(key, "Exec") == 0) {
			if(hook.cmd != null) {
				warning(cast(char*)"hook %s line %d: overwriting previous definition of %s\n", file, line, cast(char*)"Exec");
				hook.cmd.length = 0;
			}
			if((hook.cmd = wordsplit(value).toStringArr) == null) {
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

private int _alpm_hook_trigger_match_file(AlpmHandle handle, AlpmHook* hook, AlpmTrigger* t)
{
	alpm_list_t* i = void, j = void;
	AlpmStrings install;
	AlpmStrings upgrade;
	AlpmStrings remove_;

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
			if(alpmFnmatchPatternsNew(t.targets, filelist[f].name) == 0) {
				install.insertBack(filelist[f].name);
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
				if(alpmFnmatchPatternsNew(t.targets, filelist.ptr[f].name) == 0) {
					remove_.insertBack(filelist.ptr[f].name);
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
			if(alpmFnmatchPatternsNew(t.targets, filelist.ptr[f].name) == 0) {
				remove_.insertBack(filelist.ptr[f].name);
				rsize++;
			}
		}
	}

	// i = install = alpm_list_msort(install, isize, cast(alpm_list_fn_cmp)&strcmp);
	install = AlpmStrings(install.lazySort());
	// j = remove_ = alpm_list_msort(remove_, rsize, cast(alpm_list_fn_cmp)&strcmp);
	remove_ = AlpmStrings(remove_.lazySort());
	while(i) {
		while(j && strcmp(cast(char*)i.data, cast(char*)j.data) > 0) {
			j = j.next;
		}
		if(j == null) {
			break;
		}
		if(strcmp(cast(char*)i.data, cast(char*)j.data) == 0) {
			char* path = cast(char*)i.data;
			upgrade.insertBack(path.to!string);
			while(i && strcmp(cast(char*)i.data, path) == 0) {
				alpm_list_t* next = i.next;
				install.linearRemoveElement(i.data.to!string);
				free(i);
				i = next;
			}
			while(j && strcmp(cast(char*)j.data, cast(char*)path) == 0) {
				alpm_list_t* next = j.next;
				remove_.linearRemoveElement(j.data.to!string);
				free(j);
				j = next;
			}
		} else {
			i = i.next;
		}
	}

	ret = (t.op & AlpmHookOp.Install && !install.empty)
			|| (t.op & AlpmHookOp.Upgrade && !upgrade.empty)
			|| (t.op & AlpmHookOp.Remove && !remove_.empty);

	if(hook.needs_targets) {

enum string _save_matches(string _op, string _matches) = `
	if(t.op & ` ~ _op ~ ` && !` ~ _matches ~ `.empty) { 
		hook.matches.insertBack(` ~ _matches ~ `[]); 
	} else { 
		destroy(` ~ _matches ~ `); 
	}`;

		mixin(_save_matches!(`AlpmHookOp.Install`, `install`));
		mixin(_save_matches!(`AlpmHookOp.Upgrade`, `upgrade`));
		mixin(_save_matches!(`AlpmHookOp.Remove`, `remove_`));
	} else {
		install.clear();
		upgrade.clear();
		remove_.clear();
		// alpm_list_free(install);
		// alpm_list_free(upgrade);
		// alpm_list_free(remove_);
	}

	return ret;
}

private int _alpm_hook_trigger_match_pkg(AlpmHandle handle, AlpmHook* hook, AlpmTrigger* t)
{
	AlpmStrings install;
	AlpmStrings upgrade;
	AlpmStrings remove;

	if(t.op & AlpmHookOp.Install || t.op & AlpmHookOp.Upgrade) {
		alpm_list_t* i = void;
		for(i = handle.trans.add; i; i = i.next) {
			AlpmPkg pkg = cast(AlpmPkg)i.data;
			if(alpmFnmatchPatternsNew(t.targets, pkg.name) == 0) {
				if(pkg.oldpkg) {
					if(t.op & AlpmHookOp.Upgrade) {
						if(hook.needs_targets) {
							upgrade.insertBack(pkg.name);
						} else {
							return 1;
						}
					}
				} else {
					if(t.op & AlpmHookOp.Install) {
						if(hook.needs_targets) {
							install.insertBack(pkg.name);
						} else {
							return 1;
						}
					}
				}
			}
		}
	}

	if(t.op & AlpmHookOp.Remove) {
		alpm_list_t* i = void;
		for(i = handle.trans.remove; i; i = i.next) {
			AlpmPkg pkg = cast(AlpmPkg)i.data;
			if(pkg && alpmFnmatchPatternsNew(t.targets, pkg.name) == 0) {
				if(!alpm_list_find(handle.trans.add, cast(void*)pkg, &_alpm_pkg_cmp)) {
					if(hook.needs_targets) {
						remove.insertBack(pkg.name);
					} else {
						return 1;
					}
				}
			}
		}
	}

	/* if we reached this point we either need the target lists or we didn't
	 * match anything and the following calls will all be no-ops */
	hook.matches.insertBack(install[]);
	hook.matches.insertBack(upgrade[]);
	hook.matches.insertBack(remove[]);

	return !install.empty || !upgrade.empty || !remove.empty;
}

private int _alpm_hook_trigger_match(AlpmHandle handle, AlpmHook* hook, AlpmTrigger* t)
{
	return t.type == AlpmHookTriggerType.Package
		? _alpm_hook_trigger_match_pkg(handle, hook, t)
		: _alpm_hook_trigger_match_file(handle, hook, t);
}

private int _alpm_hook_triggered(AlpmHandle handle, AlpmHook* hook)
{
	alpm_list_t* i = void;
	int ret = 0;
	foreach(trigger; hook.triggers[]) {
		if(_alpm_hook_trigger_match(handle, hook, &trigger)) {
			if(!hook.needs_targets) {
				return 1;
			} else {
				ret = 1;
			}
		}
	}
	return ret;
}

private int _alpm_hook_cmp(AlpmHook* h1, AlpmHook* h2)
{
	size_t suflen = strlen(ALPM_HOOK_SUFFIX), l1 = void, l2 = void;
	int ret = void;
	l1 = h1.name.length - suflen;
	l2 = h2.name.length - suflen;
	/* exclude the suffixes from comparison */
	ret = cmp(h1.name, h2.name);
	if(ret == 0 && l1 != l2) {
		return l1 < l2 ? -1 : 1;
	}
	return ret;
}

private alpm_list_t* find_hook(alpm_list_t* haystack,  void* needle)
{
	while(haystack) {
		AlpmHook* h = cast(AlpmHook*)haystack.data;
		if(h && cmp(h.name, needle.to!string) == 0) {
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

private int _alpm_hook_run_hook(AlpmHandle handle, AlpmHook* hook)
{
	alpm_list_t* i = void, pkgs = _alpm_db_get_pkgcache(handle.getDBLocal);

	foreach(depend; hook.depends[]) {
		if(!alpm_find_satisfier(pkgs, cast(char*)depend.toStringz)) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("unable to run hook %s: %s\n"),
					hook.name, ("could not satisfy dependencies"));
			return -1;
		}
	}

	if(hook.needs_targets) {
		AlpmStrings ctx = void;
		hook.matches = AlpmStrings(hook.matches.lazySort());
		/* hooks with multiple triggers could have duplicate matches */
		ctx = hook.matches = AlpmStrings(hook.matches[].uniq!((a, b) => cmp(a, b) == 0));
		return _alpm_run_chroot(handle, cast(char*)hook.cmd[0].toStringz, cast(char**)hook.cmd.map!(s => s.toStringz).array.ptr,
				cast(_alpm_cb_io) &_alpm_hook_feed_targets, &ctx);
	} else {
		return _alpm_run_chroot(handle, cast(char*)hook.cmd[0].toStringz, cast(char**)hook.cmd.map!(s => s.toStringz).array.ptr, null, null);
	}
}

int _alpm_hook_run(AlpmHandle handle, AlpmHookWhen when)
{
	alpm_event_hook_t event = { when: when };
	alpm_event_hook_run_t hook_event = void;
	alpm_list_t* i = void, hooks = null, hooks_triggered = null;
	size_t suflen = strlen(ALPM_HOOK_SUFFIX), triggered = 0;
	int ret = 0;

	foreach_reverse(string hookdir; handle.getHookDirs[].reverse) {
	// for(i = alpm_list_last(handle.hookdirs); i; i = alpm_list_previous(i)) {
		char[PATH_MAX] path = void;
		size_t dirlen = void;
		dirent* entry = void;
		DIR* d = void;

		if((dirlen = strlen(cast(char*)hookdir.toStringz)) >= PATH_MAX) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("could not open directory: %s: %s\n"),
					cast(char*)hookdir.toStringz, strerror(ENAMETOOLONG));
			ret = -1;
			continue;
		}
		memcpy(path.ptr, hookdir.toStringz, dirlen + 1);

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

			CALLOC(ctx.hook, AlpmHook.sizeof, 1);

			_alpm_log(handle, ALPM_LOG_DEBUG, "parsing hook file %s\n", path.ptr);
			if(parse_ini(path.ptr, &_alpm_hook_parse_cb, &ctx) != 0
					|| ctx.hook.isNotValid(path.ptr)) {
				_alpm_log(handle, ALPM_LOG_DEBUG, "parsing hook file %s failed\n", path.ptr);
				destroy(ctx.hook);
				ret = -1;
				continue;
			}

			ctx.hook.name = entry.d_name.dup;
			// STRDUP(ctx.hook.name, entry.d_name.ptr);
			hooks = alpm_list_add(hooks, ctx.hook);
		}
		if(errno != 0) {
			_alpm_log(handle, ALPM_LOG_ERROR, ("could not read directory: %s: %s\n"),
					cast(char*) i.data, strerror(errno));
			ret = -1;
		}

		closedir(d);
	}

	if(ret != 0 && when == AlpmHookWhen.PreTransaction) {
		goto cleanup;
	}

	hooks = alpm_list_msort(hooks, alpm_list_count(hooks),
			cast(alpm_list_fn_cmp)&_alpm_hook_cmp);

	for(i = hooks; i; i = i.next) {
		AlpmHook* hook = cast(AlpmHook*)i.data;
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
			AlpmHook* hook = cast(AlpmHook*)i.data;
			//alpm_logaction(handle, ALPM_CALLER_PREFIX, "running '%s'...\n", hook.name);

			hook_event.type = ALPM_EVENT_HOOK_RUN_START;
			hook_event.name = cast(char*)hook.name.toStringz;
			hook_event.desc = cast(char*)hook.desc.toStringz;
			EVENT(handle, &hook_event);

			if(_alpm_hook_run_hook(handle, hook) != 0 && hook.abort_on_fail) {
				ret = -1;
			}

			hook_event.type = ALPM_EVENT_HOOK_RUN_DONE;
			EVENT(handle, &hook_event);

			if(ret != 0 && when == AlpmHookWhen.PreTransaction) {
				break;
			}
		}

		alpm_list_free(hooks_triggered);

		event.type = ALPM_EVENT_HOOK_DONE;
		EVENT(handle, cast(void*)&event);
	}

cleanup:
	// alpm_list_free_inner(hooks, cast(alpm_list_fn_free) &_alpm_hook_free);
	alpm_list_free(hooks);

	return ret;
}
