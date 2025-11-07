module libalpmd._package;

import core.stdc.config: c_long, c_ulong;

import core.stdc.limits;
import core.stdc.stdlib;
import core.stdc.string;
import core.sys.posix.unistd;

import libalpmd.deps;

import core.sys.posix.sys.types;
/* libalpm */
import libalpmd._package;
import libalpmd.alpm_list;
import libalpmd.log;
import libalpmd.util;
import libalpmd.db;
import libalpmd.handle;
import libalpmd.alpm;
import libalpmd.group;
import derelict.libarchive;
import libalpmd.signing;
import libalpmd.backup;
import std.conv;
import std.string;
import std.array;
import core.stdc.errno;

import libalpmd.filelist;
import libalpmd.be_package;
import libalpmd.libarchive_compat;
import libalpmd._version;




struct pkg_operations {
	  char*function(AlpmPkg) get_base;
	  char*function(AlpmPkg) get_desc;
	string function(AlpmPkg) get_url;
	AlpmTime function(AlpmPkg) get_builddate;
	AlpmTime function(AlpmPkg) get_installdate;
	string function(AlpmPkg) get_packager;
	  char*function(AlpmPkg) get_arch;
	off_t function(AlpmPkg) get_isize;
	AlpmPkgReason function(AlpmPkg) get_reason;
	int function(AlpmPkg) get_validation;
	int function(AlpmPkg) has_scriptlet;

	AlpmStrings function(AlpmPkg) get_groups;
	AlpmStrings function(AlpmPkg) get_licenses;
	AlpmDeps function(AlpmPkg) get_depends;
	AlpmDeps function(AlpmPkg) get_optdepends;
	AlpmDeps function(AlpmPkg) get_checkdepends;
	AlpmDeps function(AlpmPkg) get_makedepends;
	AlpmDeps function(AlpmPkg) get_conflicts;
	AlpmDeps function(AlpmPkg) get_provides;
	AlpmDeps function(AlpmPkg) get_replaces;
	AlpmFileList function(AlpmPkg) get_files;
	AlpmBackups function(AlpmPkg) get_backup;

	AlpmXDataList function(AlpmPkg) get_xdata;

	void* function(AlpmPkg) changelog_open;
	size_t function(void*, size_t, AlpmPkg, void*) changelog_read;
	int function(AlpmPkg, void*) changelog_close;

	archive* function(AlpmPkg) mtree_open;
	int function(AlpmPkg, archive*, archive_entry**) mtree_next;
	int function(AlpmPkg, archive*) mtree_close;

	int function(AlpmPkg) force_load;
}

/** The standard package operations struct. get fields directly from the
 * struct itself with no abstraction layer or any type of lazy loading.
 * The actual definition is in package.c so it can have access to the
 * default accessor functions which are defined there.
 */
const(pkg_operations) default_pkg_ops;

struct AlpmPkgXData {
	string name;
	string value;
}

alias AlpmXDataList = AlpmList!AlpmPkgXData;

class AlpmPkg {
	c_ulong name_hash;
	string filename;
	string base;
	string name;
	string version_;
	string desc;
	string url;
	string packager;
	string md5sum;
	string sha256sum;
	string base64_sig;
	string arch;

	AlpmTime builddate;
	AlpmTime installdate;

	off_t size;
	off_t isize;
	off_t download_size;

	AlpmHandle handle;

	AlpmStrings licenses;
	AlpmDeps replaces;
	AlpmStrings groups;
	AlpmBackups backup;
	AlpmDeps depends;
	AlpmDeps optdepends;
	AlpmDeps checkdepends;
	AlpmDeps makedepends;
	AlpmDeps conflicts;
	AlpmDeps provides;
	AlpmPkgs removes; /* in transaction targets only */
	AlpmPkg oldpkg; /* in transaction targets only */

	const (pkg_operations)* ops;

	AlpmFileList files;

	/* origin == PKG_FROM_FILE, use pkg->origin_data.file
	 * origin == PKG_FROM_*DB, use pkg->origin_data.db */
	union _Origin_data {
		AlpmDB db;
		string file;
	}_Origin_data origin_data;

	AlpmPkgFrom origin;
	AlpmPkgReason reason;
	int scriptlet;

	AlpmXDataList xdata;

	/* Bitfield from alpm_dbinfrq_t */
	int infolevel;
	/* Bitfield from alpm_pkgvalidation_t */
	int validation;

	this() {}
	auto getHandle() => this.handle;

	auto getFilename() => this.filename;
	auto getName() => this.name; 
	auto getBase() => this.base;
	auto getVersion() => this.version_;
	auto getDesc() => this.desc;
	auto getUrl() => this.url;
	auto getPackager() => this.packager;
	auto getMD5Sum() => this.md5sum;
	auto getSHA256Sum() => this.sha256sum;
	auto getBase64Sig() => this.base64_sig;
	auto getArch() => this.arch;

	auto getBuildDate() => this.builddate;
	auto getInstallDate() => this.installdate;
	auto getSize() => this.size;
	auto getInstallSize() => this.isize;
	auto getDownloadSize() => this.download_size;

	auto getLicenses() => this.licenses;
	auto getReplaces() => this.replaces;
	auto getGroups() => this.groups;
	auto getBackups() => this.backup;
	auto getDepends() => this.depends;
	auto getOptDepends() => this.optdepends;
	auto getCheckDepends() => this.checkdepends;
	auto getMakeDepends() => this.makedepends;
	auto getConflicts() => this.conflicts;
	auto getProvides() => this.provides;
	auto getRemoves() => this.removes;
	auto getOldPkg() => this.oldpkg;

	auto getOrigin() => this.origin;
	auto getDB() => this.origin_data.db;
	auto getReason() => this.reason;
	auto getValidation() => this.validation;
	auto getFiles() => this.files;



	auto getXData() => this.xdata;


	AlpmPkgChangelog openChangelog() {
		AlpmPkgChangelog changelog;
		archive* _archive;
		archive_entry* entry;
		stat_t buf = void;
		int fd = void;

		fd = _alpm_open_archive(this.handle, cast(char*)origin_data.file, &buf,
				&_archive, ALPM_ERR_PKG_OPEN);
		if(fd < 0) {
			return null;
		}

		while(archive_read_next_header(_archive, &entry) == ARCHIVE_OK) {
			string entry_name = archive_entry_pathname(entry).to!string;

			if(entry_name == ".CHANGELOG") {
				changelog = new AlpmPkgChangelog;
				changelog._archive = _archive;
				changelog.fd = fd;
				return changelog;
			}
		}
		/* we didn't find a changelog */
		_alpm_archive_read_free(_archive);
		close(fd);
		errno = ENOENT;

		return null;
	}

	int  checkMD5Sum() {
		char* fpath = void;
		int retval = void;

		handle.pm_errno = ALPM_ERR_OK;
		if(this.origin != ALPM_PKG_FROM_SYNCDB) {
			handle.pm_errno = ALPM_ERR_WRONG_ARGS;
			return -1;
		}

		fpath = _alpm_filecache_find(this.handle, cast(char*)this.filename);

		retval = _alpm_test_checksum(fpath, cast(char*)this.md5sum, ALPM_PKG_VALIDATION_MD5SUM);

		FREE(fpath);

		if(retval == 1) {
			this.handle.pm_errno = ALPM_ERR_PKG_INVALID;
			retval = -1;
		}

		return retval;
	}
}

alias AlpmPkgs = DList!AlpmPkg;

int  alpm_pkg_free(AlpmPkg pkg)
{
	/* Only free packages loaded in user space */
	if(pkg.origin == ALPM_PKG_FROM_FILE) {
		_alpm_pkg_free(pkg);
	}

	return 0;
}

/* Default package accessor functions. These will get overridden by any
 * backend logic that needs lazy access, such as the local database through
 * a lazy-load cache. However, the defaults will work just fine for fully-
 * populated package structures. */
string _pkg_get_base(AlpmPkg pkg)        { return pkg.base; }
string _pkg_get_desc(AlpmPkg pkg)        { return pkg.desc; }
string _pkg_get_url(AlpmPkg pkg)         { return pkg.url; }
AlpmTime _pkg_get_builddate(AlpmPkg pkg)   { return pkg.builddate; }
AlpmTime _pkg_get_installdate(AlpmPkg pkg) { return pkg.installdate; }
string _pkg_get_packager(AlpmPkg pkg)    { return pkg.packager; }
string _pkg_get_arch(AlpmPkg pkg)        { return pkg.arch; }
off_t _pkg_get_isize(AlpmPkg pkg)             { return pkg.isize; }
AlpmPkgReason _pkg_get_reason(AlpmPkg pkg) { return pkg.reason; }
int _pkg_get_validation(AlpmPkg pkg) { return pkg.validation; }
int _pkg_has_scriptlet(AlpmPkg pkg)           { return pkg.scriptlet; }

auto _pkg_get_depends(AlpmPkg pkg)    { return pkg.depends; }
auto _pkg_get_optdepends(AlpmPkg pkg) { return pkg.optdepends; }
auto _pkg_get_checkdepends(AlpmPkg pkg) { return pkg.checkdepends; }
auto _pkg_get_makedepends(AlpmPkg pkg) { return pkg.makedepends; }
auto _pkg_get_conflicts(AlpmPkg pkg)  { return pkg.conflicts; }
auto _pkg_get_provides(AlpmPkg pkg)   { return pkg.provides; }
// auto _pkg_get_replaces(AlpmPkg pkg)   { return pkg.replaces; }
AlpmFileList _pkg_get_files(AlpmPkg pkg)  { return pkg.files; }
auto _pkg_get_backup(AlpmPkg pkg)     { return pkg.backup; }
auto _pkg_get_xdata(AlpmPkg pkg)      { return pkg.xdata; }

void* _pkg_changelog_open(AlpmPkg pkg)
{
	return null;
}

alias UNUSED = void;

size_t _pkg_changelog_read(void* ptr, size_t UNUSED, AlpmPkg pkg, UNUSED* fp)
{
	return 0;
}

int _pkg_changelog_close(AlpmPkg pkg, void* fp)
{
	return 0;
}

archive* _pkg_mtree_open(AlpmPkg pkg)
{
	return null;
}

int _pkg_mtree_next(AlpmPkg pkg, archive* archive, archive_entry** entry)
{
	return -1;
}

int _pkg_mtree_close(AlpmPkg pkg, archive* archive)
{
	return -1;
}

int _pkg_force_load(AlpmPkg pkg) { return 0; }

int  alpm_pkg_get_sig(AlpmPkg pkg, ubyte** sig, size_t* sig_len)
{
	//ASSERT(pkg != null);

	if(pkg.base64_sig) {
		int ret = alpm_decode_signature(cast(char*)pkg.base64_sig, sig, sig_len);
		if(ret != 0) {
			RET_ERR(pkg.handle, ALPM_ERR_SIG_INVALID, -1);
		}
		return 0;
	} else {
		char* pkgpath = null, sigpath = null;
		alpm_errno_t err = void;
		int ret = -1;

		pkgpath = _alpm_filecache_find(pkg.handle, cast(char*)pkg.filename);
		if(!pkgpath) {
			GOTO_ERR(pkg.handle, ALPM_ERR_PKG_NOT_FOUND, "cleanup");
		}
		sigpath = _alpm_sigpath(pkg.handle, pkgpath);
		if(!sigpath || _alpm_access(pkg.handle, null, sigpath, R_OK)) {
			GOTO_ERR(pkg.handle, ALPM_ERR_SIG_MISSING, "cleanup");
		}
		err = _alpm_read_file(sigpath, sig, sig_len);
		if(err == ALPM_ERR_OK) {
			_alpm_log(pkg.handle, ALPM_LOG_DEBUG, "found detached signature %s with size %ld\n",
				sigpath, *sig_len);
		} else {
			GOTO_ERR(pkg.handle, err, "cleanup");
		}
		ret = 0;
cleanup:
		FREE(pkgpath);
		FREE(sigpath);
		return ret;
	} 
}

size_t  alpm_pkg_changelog_read(void* ptr, size_t size, AlpmPkg pkg, void* fp)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.changelog_read(ptr, size, pkg, fp);
}

int  alpm_pkg_changelog_close(AlpmPkg pkg, void* fp)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.changelog_close(pkg, fp);
}

archive * alpm_pkg_mtree_open(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.mtree_open(pkg);
}

int  alpm_pkg_mtree_next(AlpmPkg pkg, archive* archive, archive_entry** entry)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.mtree_next(pkg, archive, entry);
}

int  alpm_pkg_mtree_close(AlpmPkg pkg, archive* archive)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.mtree_close(pkg, archive);
}

int  alpm_pkg_has_scriptlet(AlpmPkg pkg)
{
	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
	return pkg.ops.has_scriptlet(pkg);
}

// alpm_list_t * alpm_pkg_get_xdata(AlpmPkg pkg)
// {
// 	//ASSERT(pkg != null);
// 	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;
// 	return pkg.ops.get_xdata(pkg);
// }

/* Wrapper function for _alpm_fnmatch to match alpm_list_fn_cmp signature */
private int fnmatch_wrapper( void* pattern,  void* _string)
{
	return _alpm_fnmatch(cast(char*)pattern, cast(char*)_string);
}

void find_requiredby(AlpmPkg pkg, AlpmDB db, alpm_list_t** reqs, int optional)
{
	 alpm_list_t* i = void;
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;

	for(i = _alpm_db_get_pkgcache(db); i; i = i.next) {
		AlpmPkg cachepkg = cast(AlpmPkg)i.data;
		AlpmDeps j;

		if(optional == 0) {
			j = cachepkg.getDepends();
		} else {
			j = cachepkg.getOptDepends();
		}

		foreach(dep; j[]) {
			if(_alpm_depcmp(pkg, dep)) {
				string cachepkgname = cachepkg.name;
				if(alpm_list_find_str(*reqs, cast(char*)cachepkgname) == null) {
					*reqs = alpm_list_add(*reqs, cast(char*)cachepkgname.dup);
				}
			}
		}
	}
}

alpm_list_t* compute_requiredby(AlpmPkg pkg, int optional)
{
	alpm_list_t* reqs = null;
	AlpmDB db = void;

	//ASSERT(pkg != null);
	(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_OK;

	if(pkg.origin == ALPM_PKG_FROM_FILE) {
		/* The sane option; search locally for things that require this. */
		find_requiredby(pkg, pkg.handle.db_local, &reqs, optional);
	} else {
		/* We have a DB package. if it is a local package, then we should
		 * only search the local DB; else search all known sync databases. */
		db = pkg.origin_data.db;
		if(db.status & DB_STATUS_LOCAL) {
			find_requiredby(pkg, db, &reqs, optional);
		} else {
			for(auto i = pkg.handle.dbs_sync; i; i = i.next) {
				db = cast(AlpmDB)i.data;
				find_requiredby(pkg, db, &reqs, optional);
			}
			reqs = alpm_list_msort(reqs, alpm_list_count(reqs), &_alpm_str_cmp);
		}
	}
	return reqs;
}

alpm_list_t * alpm_pkg_compute_requiredby(AlpmPkg pkg)
{
	return compute_requiredby(pkg, 0);
}

alpm_list_t * alpm_pkg_compute_optionalfor(AlpmPkg pkg)
{
	return compute_requiredby(pkg, 1);
}

AlpmFile* _alpm_file_copy(AlpmFile* dest, AlpmFile* src)
{
	dest.name = src.name;
	dest.size = src.size;
	dest.mode = src.mode;

	return dest;
}

alpm_list_t* list_depdup(alpm_list_t* old)
{
	alpm_list_t* i = void, new_ = null;
	for(i = old; i; i = i.next) {
		new_ = alpm_list_add(new_, cast(void*)_alpm_dep_dup(cast(AlpmDepend )i.data));
	}
	return new_;
}

/**
 * Duplicate a package data struct.
 * @param pkg the package to duplicate
 * @param new_ptr location to store duplicated package pointer
 * @return 0 on success, -1 on fatal error, 1 on non-fatal error
 */
int _alpm_pkg_dup(AlpmPkg pkg, AlpmPkg* new_ptr)
{
	AlpmPkg newpkg = void;
	alpm_list_t* i = void;
	int ret = 0;

	if(!pkg || !pkg.handle) {
		return -1;
	}

	if(!new_ptr) {
		RET_ERR(pkg.handle, ALPM_ERR_WRONG_ARGS, -1);
	}

	if(pkg.ops.force_load(pkg)) {
		_alpm_log(pkg.handle, ALPM_LOG_WARNING,
				("could not fully load metadata for package %s-%s\n"),
				pkg.name, pkg.version_);
		ret = 1;
		(cast(AlpmHandle)pkg.handle).pm_errno = ALPM_ERR_PKG_INVALID;
	}

	CALLOC(newpkg, 1, AlpmPkg.sizeof);

	newpkg.name_hash = pkg.name_hash;
	newpkg.filename = pkg.filename.dup;
	newpkg.base = pkg.base.dup;
	newpkg.name = pkg.name.dup;
	newpkg.version_ = pkg.version_.dup;
	newpkg.desc = pkg.desc.dup;
	newpkg.url = pkg.url.dup;
	newpkg.builddate = pkg.builddate;
	newpkg.installdate = pkg.installdate;
	newpkg.packager = pkg.packager.dup;
	newpkg.md5sum = pkg.md5sum.dup;
	newpkg.sha256sum = pkg.sha256sum.dup;
	newpkg.arch = pkg.arch.dup;
	newpkg.size = pkg.size;
	newpkg.isize = pkg.isize;
	newpkg.scriptlet = pkg.scriptlet;
	newpkg.reason = pkg.reason;
	newpkg.validation = pkg.validation;

	// newpkg.licenses   = alpm_list_strdup(pkg.licenses);
	newpkg.licenses = alpmStringsDup(pkg.licenses);
	newpkg.replaces   = alpmDepsDup(pkg.replaces);
	newpkg.groups     = alpmStringsDup(pkg.groups);
	// for(i = pkg.backup; i; i = i.next) {
	// 	newpkg.backup = alpm_list_add(newpkg.backup, cast(void*)(cast(AlpmBackup)i.data).dup);
	// }
	foreach(_i; pkg.backup[]) {
		newpkg.backup.insertFront(_i.dup);
	}
	newpkg.depends    = alpmDepsDup(pkg.depends);
	newpkg.optdepends = alpmDepsDup(pkg.optdepends);
	newpkg.conflicts  = alpmDepsDup(pkg.conflicts);
	newpkg.provides   = alpmDepsDup(pkg.provides);

	newpkg.files = pkg.files.dup;
	/* internal */
	newpkg.infolevel = pkg.infolevel;
	newpkg.origin = pkg.origin;
	if(newpkg.origin == ALPM_PKG_FROM_FILE) {
		newpkg.origin_data.file = pkg.origin_data.file.idup;
	} else {
		newpkg.origin_data.db = pkg.origin_data.db;
	}
	newpkg.ops = pkg.ops;
	newpkg.handle = pkg.handle;

	*new_ptr = newpkg;
	return ret;

cleanup:
	_alpm_pkg_free(newpkg);
	RET_ERR(pkg.handle, ALPM_ERR_MEMORY, -1);
}

void free_deplist(alpm_list_t* deps)
{
	alpm_list_free_inner(deps, cast(alpm_list_fn_free)&alpm_dep_free);
	alpm_list_free(deps);
}

AlpmPkgXData* _alpm_pkg_parse_xdata(string data)
{
	AlpmPkgXData* pd = void;
	string[] splited;
	if(data == "" || (splited = data.split('=')).length == 0) {
		return null;
	}

	pd = new AlpmPkgXData;
	pd.name = splited[0];
	pd.value = splited[1];

	return pd;
}

void _alpm_pkg_xdata_free(AlpmPkgXData* pd)
{
	if(pd) {
		free(pd);
	}
}

void _alpm_pkg_free(AlpmPkg pkg)
{
	if(pkg is null) {
		return;
	}

	FREE(pkg.filename);
	FREE(pkg.base);
	FREE(pkg.name);
	FREE(pkg.version_);
	FREE(pkg.desc);
	FREE(pkg.url);
	FREE(pkg.packager);
	FREE(pkg.md5sum);
	FREE(pkg.sha256sum);
	FREE(pkg.base64_sig);
	FREE(pkg.arch);

	// FREELIST(pkg.licenses);
	// free_deplist(pkg.replaces);
	// FREELIST(pkg.groups);
	if(pkg.files.count) {
		size_t i = void;
		for(i = 0; i < pkg.files.count; i++) {
			FREE(pkg.files.ptr[i].name);
		}
		free(pkg.files.ptr);
	}
	// alpm_list_free_inner(pkg.backup, cast(alpm_list_fn_free)&_alpm_backup_free);
	// alpm_list_free(pkg.backup);
	// alpm_list_free_inner(pkg.xdata, cast(alpm_list_fn_free)&_alpm_pkg_xdata_free);
	// alpm_list_free(pkg.xdata);
	// free_deplist(pkg.depends);
	// free_deplist(pkg.optdepends);
	// free_deplist(pkg.checkdepends);
	// free_deplist(pkg.makedepends);
	// free_deplist(pkg.conflicts);
	// free_deplist(pkg.provides);
	// alpm_list_free(pkg.removes);
	// _alpm_pkg_free(pkg.oldpkg);

	if(pkg.origin == ALPM_PKG_FROM_FILE) {
		FREE(pkg.origin_data.file);
	}
	FREE(pkg);
}

/* This function should be used when removing a target from upgrade/sync target list
 * Case 1: If pkg is a loaded package file (ALPM_PKG_FROM_FILE), it will be freed.
 * Case 2: If pkg is a pkgcache entry (ALPM_PKG_FROM_CACHE), it won't be freed,
 *         only the transaction specific fields of pkg will be freed.
 */
void _alpm_pkg_free_trans(AlpmPkg pkg)
{
	if(pkg is null) {
		return;
	}

	if(pkg.origin == ALPM_PKG_FROM_FILE) {
		_alpm_pkg_free(pkg);
		return;
	}

	// alpm_list_free(pkg.removes);
	// pkg.removes = null;
	_alpm_pkg_free(pkg.oldpkg);
	pkg.oldpkg = null;
}

/* Is spkg an upgrade for localpkg? */
int _alpm_pkg_compare_versions(AlpmPkg spkg, AlpmPkg localpkg)
{
	return alpm_pkg_vercmp(cast(char*)spkg.version_.toStringz, cast(char*)localpkg.version_.toStringz);
}

/* Helper function for comparing packages
 */
int _alpm_pkg_cmp( void* p1,  void* p2)
{
	AlpmPkg pkg1 = cast( AlpmPkg)p1;
	AlpmPkg pkg2 = cast( AlpmPkg)p2;
	return pkg1.name == pkg2.name;
}

AlpmPkg alpm_pkg_find_n(AlpmPkgs haystack,   char*needle)
{
	// alpm_list_t* lp = void;
	c_ulong needle_hash = void;

	if(needle is null || !haystack.empty) {
		return null;
	}

	needle_hash = _alpm_hash_sdbm(needle);

	foreach(info; haystack[]) {
		// AlpmPkg info = cast(AlpmPkg)lp.data;

		if(info) {
			if(info.name_hash != needle_hash) {
				continue;
			}

			/* finally: we had hash match, verify string match */
			if(strcmp(cast(char*)info.name, needle) == 0) {
				return info;
			}
		}
	}
	return null;
}

/* Test for existence of a package in a alpm_list_t*
 * of AlpmPkg
 */
AlpmPkg alpm_pkg_find(alpm_list_t* haystack,   char*needle)
{
	alpm_list_t* lp = void;
	c_ulong needle_hash = void;

	if(needle == null || haystack == null) {
		return null;
	}

	needle_hash = _alpm_hash_sdbm(needle);

	for(lp = haystack; lp; lp = lp.next) {
		AlpmPkg info = cast(AlpmPkg)lp.data;

		if(info) {
			if(info.name_hash != needle_hash) {
				continue;
			}

			/* finally: we had hash match, verify string match */
			if(strcmp(cast(char*)info.name, needle) == 0) {
				return info;
			}
		}
	}
	return null;
}

int  alpm_pkg_should_ignore(AlpmHandle handle, AlpmPkg pkg)
{
	/* first see if the package is ignored */
	if(alpm_list_find(handle.ignorepkg, cast(char*)pkg.name, &fnmatch_wrapper)) {
		return 1;
	}

	/* next see if the package is in a group that is ignored */
	foreach(groups; pkg.getGroups()[]) {
		char* grp = cast(char*)groups;
		if(alpm_list_find(handle.ignoregroup, grp, &fnmatch_wrapper)) {
			return 1;
		}
	}

	return 0;
}

/* check that package metadata meets our requirements */
int _alpm_pkg_check_meta(AlpmPkg pkg)
{
	char* c = void;
	int error_found = 0;

enum string EPKGMETA(string error) = `do { 
	error_found = -1; 
	_alpm_log(pkg.handle, ALPM_LOG_ERROR, ` ~ error ~ `, pkg.name, pkg.version_); 
} while(0);`;

	/* sanity check */
	if(pkg.handle is null) {
		return -1;
	}

	/* immediate bail if package doesn't have name or version */
	if(pkg.name == null || pkg.name[0] == '\0'
			|| pkg.version_ == null || pkg.version_[0] == '\0') {
		_alpm_log(pkg.handle, ALPM_LOG_ERROR,
				("invalid package metadata (name or version missing)"));
		return -1;
	}

	if(pkg.name[0] == '-' || pkg.name[0] == '.') {
		mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
					~ "(package name cannot start with '.' or '-')\n")`));
	}
	if(_alpm_fnmatch(cast(char*)pkg.name, cast(char*)"[![:alnum:]+_.@-]") == 0) {
		mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
					~ "(package name contains invalid characters)\n")`));
	}

	/* multiple '-' in pkgver can cause local db entries for different packages
	 * to overlap (e.g. foo-1=2-3 and foo=1-2-3 both give foo-1-2-3) */
	if((c = strchr(cast(char*)pkg.version_, '-')) !is null && (strchr(c + 1, '-'))) {
		mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
					~ "(package version contains invalid characters)\n")`));
	}
	if(strchr(cast(char*)pkg.version_, '/')) {
		mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
					~ "(package version contains invalid characters)\n")`));
	}

	/* local db entry is <pkgname>-<pkgver> */
	if(pkg.name.length + pkg.version_.length + 1 > NAME_MAX) {
		mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
					~ "(package name and version too long)\n")`));
	}

	return error_found;
}
