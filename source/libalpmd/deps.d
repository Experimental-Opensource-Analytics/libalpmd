module libalpmd.deps;
@nogc  
   
/*
 *  deps.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
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
import core.stdc.string;
import core.stdc.config;

import std.conv;
import std.algorithm;
import std.string;
import std.range;

import libalpmd.alpm_list;
import libalpmd.alpm_list.alpm_list_new : oldToNewList;
import libalpmd.util;
import libalpmd.log;
import libalpmd.graph;
import libalpmd.pkg;
import libalpmd.db;
import libalpmd.handle;
import libalpmd.trans;
import libalpmd.alpm;
import libalpmd.question;
import libalpmd.pkg;

/** Missing dependency. */
class AlpmDepMissing {
	/** Name of the package that has the dependency */
	char* target;
	/** The dependency that was wanted */
	AlpmDepend depend;
	/** If the depmissing was caused by a conflict, the name of the package
	 * that would be installed, causing the satisfying package to be removed */
	char* causingpkg;

	this(  char*target, AlpmDepend dep,   char*causingpkg)
	{
		// AlpmDepMissing miss = new AlpmDepMissing;

		// CALLOC(miss, 1, alpm_depmissing_t.sizeof);

		STRNDUP(this.target, target, strlen(target));
		this.depend = dep.dup();
		STRNDUP(this.causingpkg, causingpkg, strlen(causingpkg));

	// 	return miss;

	// error:
	// 	alpm_depmissing_free(miss);
	// 	return null;
	}
}

alias AlpmDepMissings = AlpmList!AlpmDepMissing;

/** The basic dependency type.
 *
 * This type is used throughout libalpm, not just for dependencies
 * but also conflicts and providers. */
class AlpmDepend {
	/**  Name of the provider to satisfy this dependency */
	string name;
	/**  Version of the provider to match against (optional) */
	string version_;
	/** A description of why this dependency is needed (optional) */
	string desc;
	/** A hash of name (used internally to speed up conflict checks) */
	c_ulong name_hash;
	/** How the version should match against the provider */
	alpm_depmod_t mod;

	this(string name, string version_, string desc, c_ulong name_hash, alpm_depmod_t mod) {
		this.name = name,
		this.version_ = version_,
		this.desc = desc,
		this.name_hash = name_hash,
		this.mod = mod;
	}

	this() {}

	auto dup() {
		return new AlpmDepend(
			this.name.idup,
			this.version_.idup,
			this.desc.idup,
			this.name_hash,
			this.mod
		);
	}

	~this() {}
}

alias AlpmDeps = libalpmd.alpm_list.alpm_list_new.AlpmList!AlpmDepend;

void  alpm_dep_free(void* _dep) {
	destroy(_dep);
}

void  alpm_depmissing_free(AlpmDepMissing miss)
{
	//ASSERT(miss != null);
	// alpm_dep_free(cast(void*)miss.depend);
	// miss.depend = null;
	// FREE(miss.target);
	// FREE(miss.causingpkg);
	// FREE(miss);
}

private AlpmPkg find_dep_satisfier(AlpmPkgs pkgs, AlpmDepend dep)
{
	foreach(pkg; pkgs[]) {
		if(_alpm_depcmp(pkg, dep)) {
			return pkg;
		}
	}
	return null;
}

/* Convert a list of AlpmPkg to a graph structure,
 * with a edge for each dependency.
 * Returns a list of vertices (one vertex = one package)
 * (used by alpm_sortbydeps)
 */
private AlpmGraphs dep_graph_init(AlpmHandle handle, AlpmPkgs targets, AlpmPkgs ignore)
{
	AlpmGraphs vertices;
	AlpmPkgs localpkgs = alpmListDiff(
			handle.getDBLocal().getPkgCacheList(), targets);

	if(!ignore.empty()) {
		AlpmPkgs oldlocal = localpkgs;
		localpkgs = alpmListDiff(oldlocal, ignore);
		// alpm_list_free(oldlocal);
	}

	/* We create the vertices */
	foreach(pkg; targets[]) {
		AlpmGraphPkg vertex = new AlpmGraphPkg();
		vertex.data = pkg;
		vertices.insertBack(vertex);
	}

	/* We compute the edges */
	auto verRange = vertices[];

	foreach(vertex_i; verRange) {
		// AlpmGraphPkg vertex_i = cast(AlpmGraphPkg)i.data;
		AlpmPkg p_i = cast(AlpmPkg)vertex_i.data;
		/* TODO this should be somehow combined with alpm_checkdeps */
		foreach(vertex_j; verRange) {
			// AlpmGraphPkg vertex_j = cast(AlpmGraphPkg)j.data;
			AlpmPkg p_j = cast(AlpmPkg)vertex_j.data;
			if(p_i.dependsOn(p_j)) {
				vertex_i.children.insertBack(vertex_j);
			}
		}

		/* lazily add local packages to the dep graph so they don't
		 * get resolved unnecessarily */
		auto j = localpkgs[];
		foreach(pkg; j) {
			// auto subrange = j.popFront();
			// auto next.front();
			// auto next = j.;
			if(p_i.dependsOn(pkg)) {
				AlpmGraphPkg vertex_j = new AlpmGraphPkg();
				vertex_j.data = pkg;
				vertices.insertBack(vertex_j);
				vertex_i.children.insertBack(vertex_j);
				localpkgs.linearRemoveElement(pkg);
				// free(j);
			}
			// j = next;
		}
	}
	// alpm_list_free(localpkgs);

	return vertices;
}

private void _alpm_warn_dep_cycle(AlpmHandle handle, AlpmPkgs targets, AlpmGraphPkg ancestor, AlpmGraphPkg vertex, int reverse)
{
	/* vertex depends on and is required by ancestor */
	// if(!alpm_list_find_ptr(targets, cast(void*)vertex.data)) {
	if(!targets[].canFind(vertex.data)) {
		/* child is not part of the transaction, not a problem */
		return;
	}

	/* find the nearest ancestor that's part of the transaction */
	while(ancestor) {
		// if(alpm_list_find_ptr(targets, cast(void*)ancestor.data)) {
		if(!targets[].canFind(ancestor.data)) {
			break;
		}
		ancestor = ancestor.parent;
	}

	if(!ancestor || ancestor == vertex) {
		/* no transaction package in our ancestry or the package has
		 * a circular dependency with itself, not a problem */
	} else {
		AlpmPkg ancestorpkg = cast(AlpmPkg)ancestor.data;
		AlpmPkg childpkg = cast(AlpmPkg)vertex.data;
		logger.tracef(("dependency cycle detected:\n"));
		if(reverse) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					("%s will be removed after its %s dependency\n"),
					ancestorpkg.getName(), childpkg.getName());
		} else {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					("%s will be installed before its %s dependency\n"),
					ancestorpkg.getName(), childpkg.getName());
		}
	}
}

/* Re-order a list of target packages with respect to their dependencies.
 *
 * Example (reverse == 0):
 *   A depends on C
 *   B depends on A
 *   Target order is A,B,C,D
 *
 *   Should be re-ordered to C,A,B,D
 *
 * packages listed in ignore will not be used to detect indirect dependencies
 *
 * if reverse is > 0, the dependency order will be reversed.
 *
 * This function returns the new alpm_list_t* target list.
 *
 */
AlpmPkgs _alpm_sortbydeps(AlpmHandle handle, AlpmPkgs targets, AlpmPkgs ignore, int reverse)
{
	AlpmPkgs newtargs;
	AlpmGraphs vertices;
	AlpmGraphPkg vertex = void;

	// if(targets == null) {
	// 	return null;
	// }

	logger.tracef("started sorting dependencies\n");

	vertices = dep_graph_init(handle, targets, ignore);

	auto i = vertices[];
	// vertex = cast(AlpmGraphPkg)vertices.data;
	while(!i.empty()) {
		/* mark that we touched the vertex */
		vertex.state = ALPM_GRAPH_STATE_PROCESSING;
		int switched_to_child = 0;
		auto iterator = vertex.children[];
		while(!iterator.empty() && !switched_to_child) {
			AlpmGraphPkg nextchild = cast(AlpmGraphPkg)iterator.front();
			// vertex.iterator = vertex.iterator.next;
			iterator.popFront();
			if(nextchild.state == ALPM_GRAPH_STATE_UNPROCESSED) {
				switched_to_child = 1;
				nextchild.parent = vertex.children.front();;
				vertex = nextchild;
			} else if(nextchild.state == ALPM_GRAPH_STATE_PROCESSING) {
				_alpm_warn_dep_cycle(handle, targets, vertex, nextchild, reverse);
			}
		}
		if(!switched_to_child) {
			if(targets[].canFind(vertex.data)) {
				newtargs.insertBack(vertex.data);
			}
			/* mark that we've left this vertex */
			vertex.state = ALPM_GRAPH_STATE_PROCESSED;
			vertex = vertex.parent;
			if(!vertex) {
				vertex = i.front();
				while(!vertex.state == ALPM_GRAPH_STATE_UNPROCESSED)
					i.popFront();
				/* top level vertex reached, move to the next unprocessed vertex */
				// for(i = i.next; i; i = i.next) {
				// 	vertex = cast(AlpmGraphPkg)i.data;
				// 	if(vertex.state == ALPM_GRAPH_STATE_UNPROCESSED) {
				// 		break;
				// 	}
				// }
			}
		}
	}

	logger.tracef("sorting dependencies finished\n");

	if(reverse) {
		/* reverse the order */
		/* free the old one */
		// alpm_list_free(newtargs);
		newtargs = AlpmPkgs(newtargs[].reverse());
	}

	// alpm_list_free(vertices);

	return newtargs;
}

private int no_dep_version(AlpmHandle handle)
{
	if(!handle.trans) {
		return 0;
	}
	return (handle.trans.flags & ALPM_TRANS_FLAG_NODEPVERSION);
}

AlpmPkg alpm_find_satisfier(AlpmPkgs pkgs,   char*depstring)
{
	AlpmDepend dep = alpm_dep_from_string(depstring);
	if(!dep) {
		return null;
	}
	AlpmPkg pkg = find_dep_satisfier(pkgs, dep);
	// alpm_dep_free(cast(void*)dep);
	dep = null;
	return pkg;
}

AlpmDepMissings alpm_checkdeps(AlpmHandle handle, AlpmPkgs pkglist, AlpmPkgs rem, AlpmPkgs upgrade, int reversedeps)
{
	AlpmPkgs dblist;
	AlpmPkgs modified;
	AlpmDepMissings baddeps;
	int nodepversion = void;

	foreach(pkg; pkglist[]) {
		if(alpm_pkg_find_n(rem, pkg.getName()) || alpm_pkg_find_n(upgrade, pkg.getName())) {
			modified.insertBack(pkg);
		} else {
			dblist.insertBack(pkg);
		}
	}

	nodepversion = no_dep_version(handle);

	/* look for unsatisfied dependencies of the upgrade list */
	foreach(tp; upgrade[]) {
		logger.tracef("checkdeps: package %s-%s\n",
				tp.getName(), tp.version_);

		foreach(depend; tp.getDepends()[]) {
			alpm_depmod_t orig_mod = depend.mod;
			if(nodepversion) {
				depend.mod = ALPM_DEP_MOD_ANY;
			}
			/* 1. we check the upgrade list */
			/* 2. we check database for untouched satisfying packages */
			/* 3. we check the dependency ignore list */
			if(!find_dep_satisfier(upgrade, depend) &&
					!find_dep_satisfier(dblist, depend) &&
					!_alpm_depcmp_provides(depend, handle.assumeinstalled)) {
				/* Unsatisfied dependency in the upgrade list */
				AlpmDepMissing miss = void;
				char* missdepstring = alpm_dep_compute_string(depend);
				logger.tracef("checkdeps: missing dependency '%s' for package '%s'\n",
						missdepstring, tp.getName());
				free(missdepstring);
				miss = new AlpmDepMissing(cast(char*)tp.getName(), depend, null);
				baddeps.insertBack(miss);
			}
			depend.mod = orig_mod;
		}
	}

	if(reversedeps) {
		/* reversedeps handles the backwards dependencies, ie,
		 * the packages listed in the requiredby field. */
		foreach(lp; dblist[]) {
			foreach(depend; lp.getDepends()[]) {
				// AlpmDepend depend = cast(AlpmDepend )j.data;
				alpm_depmod_t orig_mod = depend.mod;
				if(nodepversion) {
					depend.mod = ALPM_DEP_MOD_ANY;
				}
				AlpmPkg causingpkg = find_dep_satisfier(modified, depend);
				/* we won't break this depend, if it is already broken, we ignore it */
				/* 1. check upgrade list for satisfiers */
				/* 2. check dblist for satisfiers */
				/* 3. we check the dependency ignore list */
				if(causingpkg &&
						!find_dep_satisfier(upgrade, depend) &&
						!find_dep_satisfier(dblist, depend) &&
						!_alpm_depcmp_provides(depend, handle.assumeinstalled)) {
					AlpmDepMissing miss = void;
					char* missdepstring = alpm_dep_compute_string(depend);
					logger.tracef("checkdeps: transaction would break '%s' dependency of '%s'\n",
							missdepstring, lp.getName());
					free(missdepstring);
					miss = new AlpmDepMissing(cast(char*)lp.getName(), depend, cast(char*)causingpkg.getName());
					baddeps.insertBack(miss);
				}
				depend.mod = orig_mod;
			}
		}
	}

	modified.clear();
	dblist.clear();

	return baddeps;
}

private int dep_vercmp(  char*version1, alpm_depmod_t mod,   char*version2)
{
	int equal = 0;

	if(mod == ALPM_DEP_MOD_ANY) {
		equal = 1;
	} else {
		int cmp = alpm_pkg_vercmp(version1, version2);
		switch(mod) {
			case ALPM_DEP_MOD_EQ: equal = (cmp == 0); break;
			case ALPM_DEP_MOD_GE: equal = (cmp >= 0); break;
			case ALPM_DEP_MOD_LE: equal = (cmp <= 0); break;
			case ALPM_DEP_MOD_LT: equal = (cmp < 0); break;
			case ALPM_DEP_MOD_GT: equal = (cmp > 0); break;
			default: equal = 1; break;
		}
	}
	return equal;
}

int _alpm_depcmp_literal(AlpmPkg pkg, AlpmDepend dep)
{
	if(pkg.name_hash != dep.name_hash
			|| cmp(pkg.getName(), dep.name) != 0) {
		/* skip more expensive checks */
		return 0;
	}
	return dep_vercmp(cast(char*)pkg.version_.toStringz, dep.mod, cast(char*)dep.version_.toStringz);
}

/**
 * @param dep dependency to check against the provision list
 * @param provisions provision list
 * @return 1 if provider is found, 0 otherwise
 */
int _alpm_depcmp_provides(AlpmDepend dep, AlpmDeps provisions)
{
	int satisfy = 0;
	AlpmDepend provision;
	auto provisionsRange = provisions[];

	/* check provisions, name and version if available */
	for(provision = provisionsRange.front; !provisionsRange.empty && !satisfy; provisionsRange.popFront) {

		if(dep.mod == ALPM_DEP_MOD_ANY) {
			/* any version will satisfy the requirement */
			satisfy = (provision.name_hash == dep.name_hash
					&& cmp(provision.name, dep.name) == 0);
		} else if(provision.mod == ALPM_DEP_MOD_EQ) {
			/* provision specifies a version, so try it out */
			satisfy = (provision.name_hash == dep.name_hash
					&& cmp(provision.name, dep.name) == 0
					&& dep_vercmp(cast(char*)provision.version_.toStringz, dep.mod, cast(char*)dep.version_.toStringz));
		}
	}

	return satisfy;
}

int _alpm_depcmp(AlpmPkg pkg, AlpmDepend dep)
{
	return _alpm_depcmp_literal(pkg, dep)
		|| _alpm_depcmp_provides(dep, pkg.getProvides());
}

AlpmDepend alpm_dep_from_string(  char*depstring)
{
	AlpmDepend depend = void;
	  char*ptr = void, version_ = void, desc = void;
	size_t deplen = void;

	if(depstring == null) {
		return null;
	}

	depend = new AlpmDepend;

	/* Note the extra space in ": " to avoid matching the epoch */
	if((desc = strstr(depstring, ": ")) != null) {
		depend.desc = desc[2..strlen(desc) + 2].idup;
		deplen = desc - depstring;
	} else {
		/* no description- point desc at NULL at end of string for later use */
		depend.desc = null;
		deplen = strlen(depstring);
		desc = depstring + deplen;
	}

	/* Find a version comparator if one exists. If it does, set the type and
	 * increment the ptr accordingly so we can copy the right strings. */
	if(cast(bool)(ptr = cast(char*)memchr(depstring, '<', deplen))) {
		if(ptr[1] == '=') {
			depend.mod = ALPM_DEP_MOD_LE;
			version_ = ptr + 2;
		} else {
			depend.mod = ALPM_DEP_MOD_LT;
			version_ = ptr + 1;
		}
	}
	if(cast(bool)(ptr = cast(char*)memchr(depstring, '>', deplen))) {
		if(ptr[1] == '=') {
			depend.mod = ALPM_DEP_MOD_GE;
			version_ = ptr + 2;
		} else {
			depend.mod = ALPM_DEP_MOD_GT;
			version_ = ptr + 1;
		}
	}
	if(cast(bool)(ptr =  cast(char*)memchr(depstring, '=', deplen))) {
		/* Note: we must do =,<,> checks after <=, >= checks */
		depend.mod = ALPM_DEP_MOD_EQ;
		version_ = ptr + 1;
	} else {
		/* no version specified, set ptr to end of string and version to NULL */
		ptr = depstring + deplen;
		depend.mod = ALPM_DEP_MOD_ANY;
		depend.version_ = null;
		version_ = null;
	}

	/* copy the right parts to the right places */
	import std.conv;
	
	depend.name = depstring[0..ptr - depstring].idup;
	depend.name_hash = alpmSDBMHash((depend.name).to!string);
	if(version_) {
		depend.version_ = version_[0..desc - version_].idup;
	}

	return depend;

error:
	depend = null;
	return null;
}

/** Move package dependencies from one list to another
 * @param from list to scan for dependencies
 * @param to list to add dependencies to
 * @param pkg package whose dependencies are moved
 * @param explicit if 0, explicitly installed packages are not moved
 */
private void _alpm_select_depends(ref AlpmPkgs from, ref AlpmPkgs to, AlpmPkg pkg, int explicit)
{
	if(pkg.getDepends().empty) {
		return;
	}
	foreach(deppkg; from[]) {
		// AlpmPkg deppkg = cast(AlpmPkg)i.data;
		// next = i.next;
		if((explicit || deppkg.getReason() == ALPM_PKG_REASON_DEPEND)
				&& pkg.dependsOn(deppkg)) {
			to.insertBack(deppkg);
			from.linearRemoveElement(deppkg);
			// free(i);
		}
	}
}

void free_deplist(AlpmDeps deps)
{
	// alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_dep_free);
	// alpm_list_free(deps);
}

/**
 * @brief Adds unneeded dependencies to an existing list of packages.
 * By unneeded, we mean dependencies that are only required by packages in the
 * target list, so they can be safely removed.
 * If the input list was topo sorted, the output list will be topo sorted too.
 *
 * @param db package database to do dependency tracing in
 * @param *targs pointer to a list of packages
 * @param include_explicit if 0, explicitly installed packages are not included
 * @return 0 on success, -1 on errors
 */
int _alpm_recursedeps(AlpmDB db, ref AlpmPkgs targs, int include_explicit)
{
	AlpmPkgs rem;
	AlpmPkgs keep;

	// if(db is null || targs is null) {
	// 	return -1;
	// }

	// keep = alpm_list_copy(db.getPkgCacheList());
	keep = db.getPkgCacheList().dup;
	foreach(pkg; targs[]) {
	// for(i = *targs; i; i = i.next) {
		keep.linearRemoveElement(pkg);
	}

	/* recursively select all dependencies for removal */
	foreach(pkg; targs[]) {
		_alpm_select_depends(keep, rem, pkg, include_explicit);
	}
	// for(i = rem; i; i = i.next) {
	foreach(pkg; rem[]) {
		_alpm_select_depends(keep, rem, pkg, include_explicit);
	}

	/* recursively select any still needed packages to keep */
	// for(i = keep; i && rem; i = i.next) {
	foreach(pkg; keep[]) {
		_alpm_select_depends(rem, keep, pkg, 1);
		if(rem.empty())
			break;
	}
	// alpm_list_free(keep);

	/* copy selected packages into the target list */
	// for(i = rem; i; i = i.next) {
	foreach(pkg; rem[]) {

		// AlpmPkg pkg = cast(AlpmPkg)i.data, copy = null;
		AlpmPkg copy;
		_alpm_log(db.handle, ALPM_LOG_DEBUG,
				"adding '%s' to the targets\n", pkg.getName());
		if((copy = pkg.dup) !is null) {
			/* we return memory on "non-fatal" error in _alpm_pkg_dup */
			destroy!false(copy);
			// alpm_list_free(rem);
			return -1;
		}
		targs.insertBack(copy);
	}
	// alpm_list_free(rem);

	return 0;
}

/**
 * helper function for resolvedeps: search for dep satisfier in dbs
 *
 * @param handle the context handle
 * @param dep is the dependency to search for
 * @param dbs are the databases to search
 * @param excluding are the packages to exclude from the search
 * @param prompt if true, ask an alpm_question_install_ignorepkg_t to decide
 *        if ignored packages should be installed; if false, skip ignored
 *        packages.
 * @return the resolved package
 **/
private AlpmPkg resolvedep(AlpmHandle handle, AlpmDepend dep, AlpmDBs dbs, AlpmPkgs excluding, int prompt)
{
	int ignored = 0;

	AlpmPkgs providers;
	int count = void;

	foreach(i; dbs[]) {
		AlpmPkg pkg = void;
		AlpmDB db = i;

		if(!(db.usage & (AlpmDBUsage.Install | AlpmDBUsage.Upgrade))) {
			continue;
		}

		pkg = db.getPkgFromCache(cast(char*)dep.name);
		if(pkg && _alpm_depcmp_literal(pkg, dep)
				&& !alpm_pkg_find_n(excluding, pkg.getName())) {
			if(alpm_pkg_should_ignore(handle, pkg)) {
				auto question = new AlpmQuestionInstallIgnorePkg(pkg);
				if(prompt) {
					QUESTION(handle, question);
				} else {
					_alpm_log(handle, ALPM_LOG_WARNING, ("ignoring package %s-%s\n"),
							pkg.getName(), pkg.version_);
				}
				if(!question.getAnswer()) {
					ignored = 1;
					continue;
				}
			}
			return pkg;
		}
	}
	/* 2. satisfiers (skip literals here) */
	foreach(i; dbs[]) {
		AlpmDB db = cast(AlpmDB)i;
		if(!(db.usage & (AlpmDBUsage.Install | AlpmDBUsage.Upgrade))) {
			continue;
		}
		foreach(pkg; (db.getPkgCacheList())[]) {
			// AlpmPkg pkg = cast(AlpmPkg)j.data;
			if((pkg.name_hash != dep.name_hash || cmp(pkg.getName(), dep.name) != 0)
					&& _alpm_depcmp_provides(dep, pkg.getProvides())
					&& !alpm_pkg_find_n(excluding, pkg.getName())) {
				if(alpm_pkg_should_ignore(handle, pkg)) {
					auto question = new AlpmQuestionInstallIgnorePkg(pkg);
					if(prompt) {
						QUESTION(handle, question);
					} else {
						_alpm_log(handle, ALPM_LOG_WARNING, ("ignoring package %s-%s\n"),
								pkg.getName(), pkg.version_);
					}
					if(!question.getAnswer()) {
						ignored = 1;
						continue;
					}
				}
				logger.tracef("provider found (%s provides %s)\n",
						pkg.getName(), dep.name);

				/* provide is already installed so return early instead of prompting later */
				if(handle.getDBLocal().getPkgFromCache(cast(char*)pkg.getName())) {
					return pkg;
				}

				providers.insertBack(pkg);
				/* keep looking for other providers in the all dbs */
			}
		}
	}

	count = cast(int)providers[].walkLength();
	if(count >= 1) {
		auto question = new AlpmQuestionSelectProvider(providers, dep);
		if(count > 1) {
			/* if there is more than one provider, we ask the user */
			QUESTION(handle, question);
		}
		auto answer = question.getAnswer();
		if(answer >= 0 && answer < count) {
			// (providers, answer);
			providers.removeFront(answer);
			auto pkg = providers.front();
			return pkg;
		}
		providers.clear();
	}

	if(ignored) { /* resolvedeps will override these */
		handle.pm_errno = ALPM_ERR_PKG_IGNORED;
	} else {
		handle.pm_errno = ALPM_ERR_PKG_NOT_FOUND;
	}
	return null;
}

AlpmPkg alpm_find_dbs_satisfier(AlpmHandle handle, AlpmDBs dbs,   char*depstring)
{
	AlpmDepend dep = void;
	AlpmPkg pkg = void;
	
	//ASSERT(dbs !is null);

	dep = alpm_dep_from_string(depstring);
	//ASSERT(dep !is null);
	pkg = resolvedep(handle, dep, dbs, AlpmPkgs(), 1);
	alpm_dep_free(cast(void*)dep);
	dep = null;
	return pkg;
}

/**
 * Computes resolvable dependencies for a given package and adds that package
 * and those resolvable dependencies to a list.
 *
 * @param handle the context handle
 * @param localpkgs is the list of local packages
 * @param pkg is the package to resolve
 * @param preferred packages to prefer when resolving
 * @param packages is a pointer to a list of packages which will be
 *        searched first for any dependency packages needed to complete the
 *        resolve, and to which will be added any [pkg] and all of its
 *        dependencies not already on the list
 * @param remove is the set of packages which will be removed in this
 *        transaction
 * @param data returns the dependency which could not be satisfied in the
 *        event of an error
 * @return 0 on success, with [pkg] and all of its dependencies not already on
 *         the [*packages] list added to that list, or -1 on failure due to an
 *         unresolvable dependency, in which case the [*packages] list will be
 *         unmodified by this function
 */
int _alpm_resolvedeps(AlpmHandle handle, AlpmPkgs localpkgs, AlpmPkg pkg, AlpmPkgs preferred, ref AlpmPkgs packages, AlpmPkgs rem, ref AlpmDepMissings data)
{
	int ret = 0;
	AlpmPkgs targ;
	AlpmDBs dbs = void;
	AlpmDepMissings deps;

	if(alpm_pkg_find_n(packages, pkg.getName()) !is null) {
		return 0;
	}

	/* Create a copy of the packages list, so that it can be restored
	   on error */
	auto packages_copy = packages.dup();
	/* [pkg] has not already been resolved into the packages list, so put it
	   on that list */
	packages.insertBack(pkg);

	logger.tracef("started resolving dependencies\n");
	targ.insertBack(pkg);
	deps = alpm_checkdeps(handle, localpkgs, rem, targ, 0);
	targ.clear();

	foreach(miss; deps[]) {
		AlpmDepend missdep = miss.depend;
		/* check if one of the packages in the [*packages] list already satisfies
		 * this dependency */
		if(find_dep_satisfier(packages, missdep)) {
			alpm_depmissing_free(miss);
			continue;
		}
		/* check if one of the packages in the [preferred] list already satisfies
		 * this dependency */
		AlpmPkg spkg = find_dep_satisfier(preferred, missdep);
		if(!spkg) {
			/* find a satisfier package in the given repositories */
			spkg = resolvedep(handle, missdep, handle.getDBsSync, packages, 0);
		}
		if(spkg && _alpm_resolvedeps(handle, localpkgs, spkg, preferred, packages, rem, data) == 0) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"pulling dependency %s (needed by %s)\n",
					spkg.getName(), pkg.getName());
			alpm_depmissing_free(miss);
		} else if(resolvedep(handle, missdep, (dbs = alpm_new_list_add(AlpmDBs(), handle.getDBLocal)), rem, 0)) {
			alpm_depmissing_free(miss);
		} else {
			handle.pm_errno = ALPM_ERR_UNSATISFIED_DEPS;
			char* missdepstring = alpm_dep_compute_string(missdep);
			_alpm_log(handle, ALPM_LOG_WARNING,
					("cannot resolve \"%s\", a dependency of \"%s\"\n"),
					missdepstring, pkg.getName());
			free(missdepstring);
			// if(data) {
				data.insertBack(miss);
			// }
			ret = -1;
		}
		targ.clear();
	}
	deps.clear();

	if(ret != 0) {
		packages.clear();
		packages = packages_copy;
	} else {
		packages_copy.clear();
	}
	logger.tracef("finished resolving dependencies\n");
	return ret;
}

char * alpm_dep_compute_string( AlpmDepend dep)
{
	  char*name = void, opr = void, ver = void, desc_delim = void, desc = void;
	char* str = void;
	size_t len = void;

	//ASSERT(dep != null);

	if(dep.name) {
		name = cast(char*)dep.name;
	} else {
		name = cast(char*)"";
	}

	switch(dep.mod) {
		case ALPM_DEP_MOD_ANY:
			opr = cast(char*)"";
			break;
		case ALPM_DEP_MOD_GE:
			opr = cast(char*)">=";
			break;
		case ALPM_DEP_MOD_LE:
			opr = cast(char*)"<=";
			break;
		case ALPM_DEP_MOD_EQ:
			opr = cast(char*)"=";
			break;
		case ALPM_DEP_MOD_LT:
			opr = cast(char*)"<";
			break;
		case ALPM_DEP_MOD_GT:
			opr = cast(char*)">";
			break;
		default:
			opr = cast(char*)"";
			break;
	}

	if(dep.mod != ALPM_DEP_MOD_ANY && dep.version_) {
		ver = cast(char*)dep.version_;
	} else {
		ver = cast(char*)"";
	}

	if(dep.desc) {
		desc_delim = cast(char*)": ";
		desc = cast(char*)dep.desc;
	} else {
		desc_delim = cast(char*)"";
		desc = cast(char*)"";
	}

	/* we can always compute len and print the string like this because opr
	 * and ver will be empty when ALPM_DEP_MOD_ANY is the depend type. the
	 * reassignments above also ensure we do not do a strlen(NULL). */
	len = strlen(name) + strlen(opr) + strlen(ver)
		+ strlen(desc_delim) + strlen(desc) + 1;
	MALLOC(str, len);
	snprintf(str, len, "%s%s%s%s%s", name, opr, ver, desc_delim, desc);

	return str;
}
