module libalpmd.pkg.pkg;

import core.stdc.config: c_long, c_ulong;

import core.sys.posix.unistd;
import core.sys.posix.sys.types : off_t;

import std.conv;
import std.string;
import std.array;

import libalpmd.pkg;

import libalpmd.deps;
import libalpmd.consts;
/* libalpm */
import libalpmd.alpm_list.alpm_list_new;
import libalpmd.alpm_list.alpm_list_old;
import libalpmd.log;
import libalpmd.util;
import libalpmd.db;
import libalpmd.handle;
import libalpmd.alpm;
import libalpmd.group;
import libalpmd.util_common;
import derelict.libarchive;
import libalpmd.signing;
import libalpmd.backup;
import core.stdc.errno;
import std.algorithm;
import libalpmd.util;

import libalpmd.filelist;
// import libalpmd.be_package;
import libalpmd.libarchive_compat;
import libalpmd.pkg;;
import std.base64;
// import core.sys.darwin.mach.loader;

alias AlpmPkgs = DList!AlpmPkg;

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

	/* Bitfield from AlpmDBInfRq */
	int infolevel;
	/* Bitfield from alpm_pkgvalidation_t */
	int validation;

public:
	this() {}
	auto getHandle() => this.handle;

	string getFilename() => this.filename;
	string getName() => this.name; 
	string getBase() => this.base;
	string getVersion() => this.version_;
	string getDesc() => this.desc;
	string getUrl() => this.url;
	string getPackager() => this.packager;
	string getMD5Sum() => this.md5sum;
	string getSHA256Sum() => this.sha256sum;
	string getBase64Sig() => this.base64_sig;
	string getArch() => this.arch;

	AlpmTime getBuildDate() => this.builddate;
	AlpmTime getInstallDate() => this.installdate;
	off_t getSize() => this.size;
	off_t getInstallSize() => this.isize;
	off_t getDownloadSize() => this.download_size;

	AlpmStrings getLicenses() => this.licenses;
	AlpmDeps getReplaces() => this.replaces;
	AlpmStrings getGroups() => this.groups;
	AlpmBackups getBackups() => this.backup;
	AlpmDeps getDepends() => this.depends;
	AlpmDeps getOptDepends() => this.optdepends;
	AlpmDeps getCheckDepends() => this.checkdepends;
	AlpmDeps getMakeDepends() => this.makedepends;
	AlpmDeps getConflicts() => this.conflicts;
	AlpmDeps getProvides() => this.provides;
	AlpmPkgs getRemoves() => this.removes;
	AlpmPkg getOldPkg() => this.oldpkg;

	AlpmPkgFrom getOrigin() => this.origin;
	AlpmDB getDB() => this.origin_data.db;
	AlpmPkgReason getReason() => this.reason;
	int getValidation() => this.validation;
	AlpmFileList getFiles() => this.files;
	int hasScriptlet() => this.scriptlet;

	AlpmXDataList getXData() => this.xdata;

	alias UNUSED = void;

	void* changelogOpen() => null;
	size_t changelogRead(void* ptr, size_t UNUSED, UNUSED* fp) => 0;
	int changelogClose(void* fp) => 0;

	archive* mtreeOpen() => null;
	int mtreeNext(archive* archive, archive_entry** entry) => -1;
	int mtreeClose(archive* archive) => -1;

	int forceLoad() => 0;

	/* Helper function for comparing packages
	*/
	override int opCmp(Object rhs) {
		return cmp(this.name, (cast(AlpmPkg)rhs).name);
	}

	int  getSig(ref ubyte[] sig, size_t* sig_len) {
		if(this.base64_sig) {
			try{
				Base64.decode(base64_sig);
			}
			catch(Exception e) {
				this.handle.pm_errno = ALPM_ERR_SIG_INVALID;
				return -1;
			}
			*sig_len = sig.length;
		} else {
			string pkgpath, sigpath;
			alpm_errno_t err = void;
			int ret = -1;

			try{
				pkgpath = _alpm_filecache_find(this.handle, cast(char*)this.filename).to!string;
				if(!pkgpath) {
					this.handle.pm_errno = ALPM_ERR_PKG_NOT_FOUND;
					throw new Exception("ALPM Error: package not found");
					return ret;
				}
				sigpath = _alpm_sigpath(this.handle, cast(char*)pkgpath).to!string;
				if(!sigpath || _alpm_access(this.handle, null, cast(char*)sigpath, R_OK)) {
					this.handle.pm_errno = ALPM_ERR_SIG_MISSING;
					throw new Exception("ALPM Error: signing not found");
				}
				err = _alpm_read_file(cast(char*)sigpath, &sig, sig_len);
				if(err == ALPM_ERR_OK) {
					_alpm_log(this.handle, ALPM_LOG_DEBUG, "found detached signature %s with size %ld\n",
						sigpath, *sig_len);
				} else {
					throw new Exception("ALPM Error: cannot read signature file.");
				}
				ret = 0;
			}
			catch(Exception e) {
				FREE(pkgpath);
				FREE(sigpath);
				return ret;
			}

		}
		assert(0);
	}

	void findRequiredBy(AlpmDB db, alpm_list_t** reqs, int optional)
	{
		alpm_list_t* i = void;
		(cast(AlpmHandle)this.handle).pm_errno = ALPM_ERR_OK;

		//[ ] _alpm_db_get_pkgcache
		for(i = _alpm_db_get_pkgcache(db); i; i = i.next) { 
			AlpmPkg cachepkg = cast(AlpmPkg)i.data;
			AlpmDeps j;

			if(optional == 0) {
				j = cachepkg.getDepends();
			} else {
				j = cachepkg.getOptDepends();
			}

			foreach(dep; j[]) {
				if(_alpm_depcmp(this, dep)) {//[ ] _alpm_depcmp
					string cachepkgname = cachepkg.name;
					if(alpm_list_find_str(*reqs, cast(char*)cachepkgname) == null) { //[ ] alpm_list_find_str
						*reqs = alpm_list_add(*reqs, cast(char*)cachepkgname.dup); //[ ] alpm_list_add
					}
				}
			}
		}
	}

	alpm_list_t* computeRequiredBy(int optional)
	{
		alpm_list_t* reqs = null;
		AlpmDB db = void;

		(cast(AlpmHandle)this.handle).pm_errno = ALPM_ERR_OK;

		if(this.origin == ALPM_PKG_FROM_FILE) {
			/* The sane option; search locally for things that require this. */
			this.findRequiredBy(this.handle.db_local, &reqs, optional);
		} else {
			/* We have a DB package. if it is a local package, then we should
			* only search the local DB; else search all known sync databases. */
			db = this.origin_data.db;
			if(db.status & AlpmDBStatus.Local) {
				this.findRequiredBy(db, &reqs, optional);
			} else {
				foreach(i; this.handle.dbs_sync[]) {
					db = cast(AlpmDB)i;
					this.findRequiredBy(db, &reqs, optional);
				}
				reqs = alpm_list_msort(reqs, alpm_list_count(reqs), &_alpm_str_cmp); //[ ] alpm_list_msort
			}
		}
		return reqs;
	}

	alpm_list_t * computeRequiredBy()
	{
		return computeRequiredBy(0);
	}

	alpm_list_t * computeOptionalFor()
	{
		return computeRequiredBy(1);
	}

	/* This function should be used when removing a target from upgrade/sync target list
	* Case 1: If pkg is a loaded package file (ALPM_PKG_FROM_FILE), it will be freed.
	* Case 2: If pkg is a pkgcache entry (ALPM_PKG_FROM_CACHE), it won't be freed,
	*         only the transaction specific fields of pkg will be freed.
	*/
	void freeTrans()
	{
		if(this.origin == ALPM_PKG_FROM_FILE) {
			destroy!false(this);
			return;
		}

		//TODO: recheck alpm_list_free(this.removes)
		// alpm_list_free(this.removes);
		destroy(this.removes);
		destroy!false(this.oldpkg);
		this.oldpkg = null;
	}

	/**
	* Duplicate a package data struct.
	* @param pkg the package to duplicate
	* @param new_ptr location to store duplicated package pointer
	* @return 0 on success, -1 on fatal error, 1 on non-fatal error
	*/
	AlpmPkg dup() {
		if(!this.handle) {
			return null;
		}

		AlpmPkg newPkg = new AlpmPkg;

		newPkg.name_hash = this.name_hash;
		newPkg.filename = this.filename.dup;
		newPkg.base = this.base.dup;
		newPkg.name = this.name.dup;
		newPkg.version_ = this.version_.dup;
		newPkg.desc = this.desc.dup;
		newPkg.url = this.url.dup;
		newPkg.builddate = this.builddate;
		newPkg.installdate = this.installdate;
		newPkg.packager = this.packager.dup;
		newPkg.md5sum = this.md5sum.dup;
		newPkg.sha256sum = this.sha256sum.dup;
		newPkg.arch = this.arch.dup;
		newPkg.size = this.size;
		newPkg.isize = this.isize;
		newPkg.scriptlet = this.scriptlet;
		newPkg.reason = this.reason;
		newPkg.validation = this.validation;
		newPkg.licenses = alpmStringsDup(this.licenses);
		newPkg.replaces   = alpmDepsDup(this.replaces);
		newPkg.groups     = alpmStringsDup(this.groups);
		foreach(_i; this.backup[]) {
			newPkg.backup.insertFront(_i.dup);
		}
		newPkg.depends    = alpmDepsDup(this.depends);
		newPkg.optdepends = alpmDepsDup(this.optdepends);
		newPkg.conflicts  = alpmDepsDup(this.conflicts);
		newPkg.provides   = alpmDepsDup(this.provides);

		newPkg.files = this.files.dup;

		newPkg.infolevel = this.infolevel;
		newPkg.origin = this.origin;
		if(newPkg.origin == ALPM_PKG_FROM_FILE) {
			newPkg.origin_data.file = this.origin_data.file.idup;
		} else {
			newPkg.origin_data.db = this.origin_data.db;
		}
		
		newPkg.handle = this.handle;

		return newPkg;
	}

	/* check that package metadata meets our requirements */
	int checkMeta()
	{
		string c;
		int error_found = 0;

	enum string EPKGMETA(string error) = `do { 
		error_found = -1; 
		_alpm_log(this.handle, ALPM_LOG_ERROR, ` ~ error ~ `, this.name, this.version_); 
	} while(0);`;

		/* sanity check */
		if(this.handle is null) {
			return -1;
		}

		/* immediate bail if package doesn't have name or version */
		if(this.name == null || this.name[0] == '\0'
				|| this.version_ == null || this.version_[0] == '\0') {
			_alpm_log(this.handle, ALPM_LOG_ERROR,
					("invalid package metadata (name or version missing)"));
			return -1;
		}

		if(this.name[0] == '-' || this.name[0] == '.') {
			mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
						~ "(package name cannot start with '.' or '-')\n")`));
		}
		if(_alpm_fnmatch(cast(char*)this.name, cast(char*)"[![:alnum:]+_.@-]") == 0) {
			mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
						~ "(package name contains invalid characters)\n")`));
		}

		/* multiple '-' in pkgver can cause local db entries for different packages
		* to overlap (e.g. foo-1=2-3 and foo=1-2-3 both give foo-1-2-3) */
		// if((c = strchr(cast(char*)pkg.version_, '-')) !is null && (strchr(c + 1, '-'))) {
		if((c = this.getVersion().find('-')) != [] && c[1..$-1].find('-')) {
			mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
						~ "(package version contains invalid characters)\n")`));
		}
		if(this.getVersion().find('-') != []) {
			mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
						~ "(package version contains invalid characters)\n")`));
		}

		/* local db entry is <pkgname>-<pkgver> */
		if(this.name.length + this.version_.length + 1 > NAME_MAX) {
			mixin(EPKGMETA!(`("invalid metadata for package %s-%s "
						~ "(package name and version too long)\n")`));
		}

		return error_found;
	}

	~this() {
		FREE(this.filename);
		FREE(this.base);
		FREE(this.name);
		FREE(this.version_);
		FREE(this.desc);
		FREE(this.url);
		FREE(this.packager);
		FREE(this.md5sum);
		FREE(this.sha256sum);
		FREE(this.base64_sig);
		FREE(this.arch);

		// FREELIST(this.licenses);
		// free_deplist(this.replaces);
		// FREELIST(this.groups);
		if(this.files.count) {
			size_t i = void;
			for(i = 0; i < this.files.count; i++) {
				FREE(this.files.ptr[i].name);
			}
			// free(this.files.ptr);
			this.files = [];
		}
		// alpm_list_free_inner(this.backup, cast(alpm_list_fn_free)&_alpm_backup_free);
		// alpm_list_free(this.backup);
		// alpm_list_free_inner(this.xdata, cast(alpm_list_fn_free)&_alpm_pkg_xdata_free);
		// alpm_list_free(this.xdata);
		// free_deplist(this.depends);
		// free_deplist(this.optdepends);
		// free_deplist(this.checkdepends);
		// free_deplist(this.makedepends);
		// free_deplist(this.conflicts);
		// free_deplist(this.provides);
		// alpm_list_free(this.removes);
		destroy!false(this.oldpkg);

		if(this.origin == ALPM_PKG_FROM_FILE) {
			FREE(this.origin_data.file);
		}
		// FREE(this);
	}

	/* Is spkg an upgrade for localpkg? */
	int compareVersions(AlpmPkg localpkg)
	{
		return alpm_pkg_vercmp(cast(char*)this.version_.toStringz, cast(char*)localpkg.version_.toStringz);
	}

	int  shouldIgnore(AlpmHandle handle)
	{
		/* first see if the package is ignored */
		if(alpm_list_find(handle.ignorepkg, cast(char*)this.name, &fnmatch_wrapper)) {
			return 1;
		}

		/* next see if the package is in a group that is ignored */
		foreach(group; groups[]) {
			char* grp = cast(char*)group;
			if(alpm_list_find(handle.ignoregroup, grp, &fnmatch_wrapper)) {
				return 1;
			}
		}

		return 0;
	}

	/* Look for a filename in a alpm_pkg_t.backup list. If we find it,
	* then we return the full backup entry.
	*/
	AlpmBackup needBackup(string file) {
		if(!file) {
			return null;
		}

		foreach(_backup; backup[]) {
			if(file == _backup.name) {
				return _backup;
			}
		}

		return null;
	}
}

//Left until full refactoring AlpmList
void _alpm_pkg_free(AlpmPkg pkg)
{
	destroy!false(pkg);
}

/* This function should be used when removing a target from upgrade/sync target list
 * Case 1: If pkg is a loaded package file (ALPM_PKG_FROM_FILE), it will be freed.
 * Case 2: If pkg is a pkgcache entry (ALPM_PKG_FROM_CACHE), it won't be freed,
 *         only the transaction specific fields of pkg will be freed.
 */
void _alpm_pkg_free_trans(AlpmPkg pkg)
{
	pkg.freeTrans();
}

/* Helper function for comparing packages
 */
int _alpm_pkg_cmp( void* p1,  void* p2)
{
	return (cast(AlpmPkg)p1).opCmp(cast(Object)p2);
}

AlpmPkg alpm_pkg_find_n(AlpmPkgs haystack, string needle)
{
	if(needle || haystack.empty) {
		return null;
	}

	c_ulong needle_hash = alpmSDBMHash(needle.to!string);

	foreach(info; haystack[]) {
		if(info.name_hash != needle_hash) {
			continue;
		}

		/* finally: we had hash match, verify string match */
		if(info.name == needle) {
			return info;
		}
	}
	return null;
}

AlpmPkg alpm_pkg_find_n(alpm_list_t* haystack, string needle)
{
	import core.stdc.string;
	alpm_list_t* lp = void;
	c_ulong needle_hash = void;

	if(needle == null || haystack == null) {
		return null;
	}

	needle_hash = alpmSDBMHash(needle.to!string);

	for(lp = haystack; lp; lp = lp.next) {
		AlpmPkg info = cast(AlpmPkg)lp.data;

		if(info) {
			if(info.name_hash != needle_hash) {
				continue;
			}

			/* finally: we had hash match, verify string match */
			if(info.name == needle) {
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
	import core.stdc.string;
	alpm_list_t* lp = void;
	c_ulong needle_hash = void;

	if(needle == null || haystack == null) {
		return null;
	}

	needle_hash = alpmSDBMHash(needle.to!string);

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
	return pkg.shouldIgnore(handle);
}