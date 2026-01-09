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
import libalpmd.log;
import libalpmd.trans;
import libalpmd.util;
import libalpmd.alpm_list;
import libalpmd.alpm;
import libalpmd.util_common;
import libalpmd.pkg;
import libalpmd.consts;
import libalpmd.db;
import libalpmd.file;
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

import std.algorithm;
import std.string;
import std.conv;
import std.string;
import std.algorithm;
import std.array;
import std.range;
import inilike;
import libalpmd.event;

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

	int opCmp(AlpmHook h2) const
	{
		size_t suflen = strlen(ALPM_HOOK_SUFFIX), l1 = void, l2 = void;
		int ret = void;
		l1 = this.name.length - suflen;
		l2 = h2.name.length - suflen;
		/* exclude the suffixes from comparison */
		ret = cmp(this.name, h2.name);
		if(ret == 0 && l1 != l2) {
			return l1 < l2 ? -1 : 1;
		}
		return ret;
	}
}

alias AlpmHooks = AlpmList!AlpmHook;

struct _alpm_hook_cb_ctx {
	AlpmHandle handle;
	AlpmHook* hook;
}

private int _alpm_hook_parse_cb(char*file, void* data)
{
	_alpm_hook_cb_ctx* ctx = cast(_alpm_hook_cb_ctx*)data;
	// AlpmHandle handle = ctx.handle;
	AlpmHook* hook = ctx.hook;

	AlpmTrigger* t = new AlpmTrigger;
	IniLikeFile hookFile = new IniLikeFile(file.to!string);

	auto trigGroup = hookFile.group("Trigger");
	auto actionGroup = hookFile.group("Action");

	void processOperations(string value) {
		switch(value) {
			case "Install": t.op |= AlpmHookOp.Install; break;
			case "Upgrade": t.op |= AlpmHookOp.Upgrade; break;
			case "Remove": t.op |= AlpmHookOp.Remove; break;
			default:
				logger.errorf("hook %s line %d: invalid value %s\n", file, value);
			break;
		}
	}

	void processType(string value) {
		switch(value) {
			case "Package": t.type = AlpmHookTriggerType.Package; break;
			case "File": 
			case "Path": t.type = AlpmHookTriggerType.Path; break;
			default:
				logger.errorf("hook %s line %d: invalid value %s\n", file, value);
			break;
		}
	}

	foreach(Tuple!(string, "key", string, "value") pair; trigGroup.byKeyValue) {
		switch(pair.key) {
			case "Operation": processOperations(pair.value); break;
			case "Type": processType(pair.value); break;
			case "Target": t.targets.insertBack(pair.value); break;
			default: break;
		}
	}

	void processWhen(string value) {
		switch(value) {
			case "PreTransaction": hook.when = AlpmHookWhen.PreTransaction; break;
			case "PostTransaction": hook.when = AlpmHookWhen.PreTransaction; break;
			default:
				logger.errorf("hook %s line %d: invalid value %s\n", file, value);
			break;
		}
	}

	foreach(Tuple!(string, "key", string, "value") pair; actionGroup.byKeyValue) {
		switch(pair.key) {
			case "When": processWhen(pair.value); break;
			case "Description": hook.desc = pair.value; break;
			case "Depends": hook.depends.insertBack(pair.value); break;
			case "AbortOnFail": hook.abort_on_fail = true; break;
			case "NeedsTargets": hook.needs_targets = true; break;
			case "Exec":
				if(hook.cmd.length != 0)
					logger.warningf("hook %s line %d: overwriting previous definition of %s\n", file, cast(char*)"Exec");
				hook.cmd = wordsplit(cast(char*)pair.value.ptr).toStringArr; break;
			default: break;
		}
	}

	return 0;
}

private int _alpm_hook_trigger_match_file(AlpmHandle handle, AlpmHook* hook, AlpmTrigger* t)
{
	AlpmStrings install;
	AlpmStrings upgrade;
	AlpmStrings remove_;

	size_t isize = 0, rsize = 0;
	int ret = 0;

	/* check if file will be installed */
	foreach(pkg; handle.trans.getAdded[]) {
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
	foreach(spkg; handle.trans.getAdded[]) {
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
	foreach(pkg; handle.trans.getRemoved[]) {
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
	auto installRange = install[];
	// j = remove_ = alpm_list_msort(remove_, rsize, cast(alpm_list_fn_cmp)&strcmp);
	remove_ = AlpmStrings(remove_.lazySort());
	auto removeRange = remove_[];
	string jStr, iStr;
	for(iStr = installRange.front(); !installRange.empty();) {

		for(jStr = removeRange.front; !removeRange.empty; removeRange.popFront()) {
			if(cmp(iStr, jStr) > 0)
				break;
		}
		// if(j == null) {
		// 	break;
		// }
		if(cmp(iStr, jStr) == 0) {
			char* path = cast(char*)iStr.toStringz;
			upgrade.insertBack(path.to!string);
			while(!installRange.empty() && cmp(iStr, path.to!string) == 0) {
				install.linearRemoveElement(iStr);
				// free(i);
				// i = next
				installRange.popFront();
			}
			while(!removeRange.empty() && cmp(jStr, path.to!string) == 0) {
				
				remove_.linearRemoveElement(jStr);
				// free(j);
				removeRange.popFront();
			}
		} else {
			installRange.popFront();
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
		foreach(pkg; handle.trans.getAdded[]) {
			if(alpmFnmatchPatternsNew(t.targets, pkg.getName()) == 0) {
				if(pkg.oldpkg) {
					if(t.op & AlpmHookOp.Upgrade) {
						if(hook.needs_targets) {
							upgrade.insertBack(pkg.getName());
						} else {
							return 1;
						}
					}
				} else {
					if(t.op & AlpmHookOp.Install) {
						if(hook.needs_targets) {
							install.insertBack(pkg.getName());
						} else {
							return 1;
						}
					}
				}
			}
		}
	}

	if(t.op & AlpmHookOp.Remove) {
		foreach(pkg; handle.trans.getRemoved[]) {
			if(pkg && alpmFnmatchPatternsNew(t.targets, pkg.getName()) == 0) {
				if(!handle.trans.getAdded[].canFind(pkg)) {
					if(hook.needs_targets) {
						remove.insertBack(pkg.getName());
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

private AlpmHooks find_hook(AlpmHooks haystack,  void* needle)
{
	// while(haystack) {
	// 	AlpmHook* h = cast(AlpmHook*)haystack.data;
	// 	if(h && cmp(h.name, needle.to!string) == 0) {
	// 		return haystack;
	// 	}
	// 	haystack = haystack.next;
	// }
	// return null;

	foreach(hook; haystack) {
		if(hook.name == needle.to!string)
			return haystack;
	}

	return AlpmHooks();
}

private long hookFeedTargets(ref char[] buffer, ref AlpmStrings pos)
{
    long written = 0;
    size_t remaining = buffer.length;
    
    while (!pos.empty && remaining > 0) {
        char* str = cast(char*)pos.front();
        size_t len = strlen(str);
        
        if (len + 1 <= remaining) {
            memcpy(&buffer[written], str, len);
            buffer[written + len] = '\n';
            
            written += len + 1;
            remaining -= len + 1;
            pos.removeFront();
        } else if (remaining > 0) {
            memcpy(&buffer[written], str, remaining);
            pos.front() = str.to!string ~ remaining.to!string;
            written += remaining;
            remaining = 0;
        }
    }
    
    return written;
}

private AlpmStrings _alpm_strlist_dedup(AlpmStrings list)
{
	return AlpmStrings(list[].uniq().array);

}

private int _alpm_hook_run_hook(AlpmHandle handle, AlpmHook* hook)
{
	auto pkgs = handle.getDBLocal().getPkgCacheList();

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
				cast(_alpm_cb_io) &hookFeedTargets, &ctx);
	} else {
		return _alpm_run_chroot(handle, cast(char*)hook.cmd[0].toStringz, cast(char**)hook.cmd.map!(s => s.toStringz).array.ptr, null, null);
	}
}

int _alpm_hook_run(AlpmHandle handle, AlpmHookWhen when)
{
	AlpmEventHook event = new AlpmEventHook(AlpmEventDefStatus.Start, when);
	AlpmEventHookRun hook_event = new AlpmEventHookRun();
	AlpmHooks hooks_triggered;
	AlpmHooks hooks;
	size_t suflen = strlen(ALPM_HOOK_SUFFIX), triggered = 0;
	int ret = 0;

	foreach_reverse(string hookdir; handle.getHookDirs[]) {
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
				logger.tracef("skipping non-hook file %s\n", path.ptr);
				continue;
			}

			if(!find_hook(hooks, entry.d_name.ptr).empty()) {
				logger.tracef("skipping overridden hook %s\n", path.ptr);
				continue;
			}

			if(stat(path.ptr, &buf) != 0) {
				_alpm_log(handle, ALPM_LOG_ERROR,
						("could not stat file %s: %s\n"), path.ptr, strerror(errno));
				ret = -1;
				continue;
			}

			if(S_ISDIR(buf.st_mode)) {
				logger.tracef("skipping directory %s\n", path.ptr);
				continue;
			}

			CALLOC(ctx.hook, AlpmHook.sizeof, 1);

			logger.tracef("parsing hook file %s\n", path.ptr);
			if(_alpm_hook_parse_cb(path.ptr, cast(void*)&ctx) != 0
					|| ctx.hook.isNotValid(path.ptr)) {
				logger.tracef("parsing hook file %s failed\n", path.ptr);
				destroy(ctx.hook);
				ret = -1;
				continue;
			}

			ctx.hook.name = entry.d_name.dup;
			// STRDUP(ctx.hook.name, entry.d_name.ptr);
			hooks.insertBack(*ctx.hook);
		}
		if(errno != 0) {
			// _alpm_log(handle, ALPM_LOG_ERROR, ("could not read directory: %s: %s\n"),
					// cast(char*) i.data, strerror(errno));
			ret = -1;
		}

		closedir(d);
	}

	if(ret != 0 && when == AlpmHookWhen.PreTransaction) {
		goto cleanup;
	}

	// hooks = alpm_list_msort(hooks, alpm_list_count(hooks),
			// cast(alpm_list_fn_cmp)&_alpm_hook_cmp);
	hooks = AlpmHooks(hooks[].array.sort);

	foreach(hook; hooks[]) {
		// AlpmHook* hook = cast(AlpmHook*)i.data;
		if(hook.when == when && _alpm_hook_triggered(handle, &hook)) {
			hooks_triggered.insertBack(hook);
			triggered++;
		}
	}

	if(!hooks_triggered.empty) {
		event.setStatus(AlpmEventDefStatus.Start);
		EVENT(handle, event);

		hook_event.position = 1;
		hook_event.total = triggered;

		foreach(hook; hooks_triggered[]) {
			// AlpmHook* hook = cast(AlpmHook*)i.data;
			//alpm_logaction(handle, ALPM_CALLER_PREFIX, "running '%s'...\n", hook.name);

			hook_event.status = AlpmEventDefStatus.Start;
			hook_event.name = hook.name;
			hook_event.desc = hook.desc;
			EVENT(handle, hook_event);

			if(_alpm_hook_run_hook(handle, &hook) != 0 && hook.abort_on_fail) {
				ret = -1;
			}

			hook_event.status = AlpmEventDefStatus.Done;
			EVENT(handle, hook_event);

			if(ret != 0 && when == AlpmHookWhen.PreTransaction) {
				break;
			}

			hook_event.position++;
		}

		// alpm_list_free(hooks_triggered);

		event.setStatus = AlpmEventDefStatus.Done;
		EVENT(handle, event);
	}

cleanup:
	// alpm_list_free_inner(hooks, cast(alpm_list_fn_free) &_alpm_hook_free);
	// alpm_list_free(hooks);

	return ret;
}
