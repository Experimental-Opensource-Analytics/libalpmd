///Alpm package class module
module libalpmd.pkg.pkg;

import core.sys.posix.sys.types : off_t;
import core.sys.posix.unistd;
import core.stdc.errno;

import std.conv;
import std.string;
import std.array;
import std.algorithm;
import std.base64;

import derelict.libarchive;

import libalpmd.pkg;
import libalpmd.alpm;
import libalpmd.alpm_list;
import libalpmd.handle;
import libalpmd.deps ;
import libalpmd.backup;
import libalpmd.file;
import libalpmd.db;
import libalpmd.util;
import libalpmd.log;
import libalpmd.consts;

/** Package install reasons. */
enum AlpmPkgReason {
	/** Explicitly requested by the user. */
	Explicit = 0,
	/** Installed as a dependency for another package. */
	Depend = 1,
	/** Failed parsing of local database */
	Unknow = 2
}

/** Method used to validate a package. */
enum AlpmPkgValidation {
	/** The package's validation type is unknown */
	Unknow = 0,
	/** The package does not have any validation */
	None = (1 << 0),
	/** The package is validated with md5 */
	MD5 = (1 << 1),
	/** The package is validated with sha256 */
	SHA256 = (1 << 2),
	/** The package is validated with a PGP signature */
	Signature = (1 << 3)
}

///Enum type for determine from package getted from
enum AlpmPkgFrom {
	/// Loaded from a file
	File = 1,
	/// From the local database
	LocalDB,
	/// From a sync database
	SyncDB
}

///Alpm package class
class AlpmPkg {
private:
	ulong name_hash;
	string filename;
	string base;
	string name;
	string version_;
	string desc;
	string url;
	string packager;
public:
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

	/* origin == PKG_FROM_FILE, use pkg->getOriginFile()
	 * origin == PKG_FROM_*DB, use pkg->getOriginDB() */
	union OriginData {
		AlpmDB db;
		string filename;
	}
	private OriginData originData;

	AlpmPkgFrom origin;
	AlpmPkgReason reason;
	int scriptlet;

	AlpmXDataList xdata;

	/* Bitfield from AlpmDBInfRq */
	int infolevel;
	/* Bitfield from AlpmPkgValidation */
	int validation;

public:
	this() {}

	///
	auto getHandle() => this.handle;
	///
	void setHandle(AlpmHandle handle) {
		this.handle = handle;
	}

	///
	string 	getFilename() => this.filename;
	///
	void 	setFilename(string filename) {
		this.filename = filename;
	}

	///
	string getName() => this.name; 
	//
	void 	setName(string name) {
		this.name = name;
	}

	///
	ulong getNameHash() => this.name_hash; 
	///
	void 	setNameHash(ulong name_hash) {
		this.name_hash = name_hash;
	}

	///
	string getBase() => this.base; 
	///
	void 	setBase(string base) {
		this.base = base;
	}

	///
	string getVersion() => this.version_; 
	///
	void 	setVersion(string version_) {
		this.version_ = version_;
	}

	///
	string getDesc() => this.desc; 
	///
	void 	setDesc(string desc) {
		this.desc = desc;
	}

	///
	string getUrl() => this.url; 
	///
	void 	setUrl(string url) {
		this.url = url;
	}

	///
	AlpmTime getBuildDate() => this.builddate; 
	///
	void 	setBuildDate(AlpmTime builddate) {
		this.builddate = builddate;
	}

	///
	auto getSize() => this.size; 
	///
	void 	setSize(off_t size) {
		this.size = size;
	}

	///
	AlpmPkg getOldPkg() => this.oldpkg; 
	///
	void 	setOldPkg(AlpmPkg oldpkg) {
		this.oldpkg = oldpkg;
	}	
	///
	int getValidation() => this.validation; 
	///
	void 	setValidation(int validation) {
		this.validation = validation;
	}

	///
	AlpmPkgReason getReason() => this.reason; 
	///
	void 	setReason(AlpmPkgReason reason) {
		this.reason = reason;
	}

	///
	string getPackager() => this.packager; 
	///
	void 	setPackager(string packager) {
		this.packager = packager;
	}
	// string getVersion() => this.version_;
	// string getPackager() => this.packager;
	string getMD5Sum() => this.md5sum;
	string getSHA256Sum() => this.sha256sum;
	string getBase64Sig() => this.base64_sig;
	string getArch() => this.arch;

	// AlpmTime getBuildDate() => this.builddate;
	AlpmTime getInstallDate() => this.installdate;
	// off_t getSize() => this.size;
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
	// AlpmPkg getOldPkg() => this.oldpkg;

	/** 
	* Getting AlpmPkgFrom origin type
	*
	* Returns: origin type
	*/
	AlpmPkgFrom getOrigin() => this.origin;
	
	/** 
	* Getting AlmmDB origin database
	*
	* Returns: origin database
	*/
	AlpmDB getOriginDB() => this.originData.db;

	/** 
	* Getting origin file name
	*
	* Returns: origin file name
	*/
	string getOriginFile() => this.originData.filename;

	/**
	* Setting origin database and it's type
	* 
	* Params:  
	* 	db = origin database 
	* 	origin = origin type
	*/
	void setOriginDB(AlpmDB db, AlpmPkgFrom origin = this.origin) {
		this.origin = origin;
		this.originData.db = db;
	}

	/**
	* Setting origin file name
	*
	* Params:  
	* 	file = origin file name
	*/
	void setOriginFile(string file) {
		this.origin = AlpmPkgFrom.File;
		this.originData.filename = filename;
	}

	// AlpmPkgReason getReason() => this.reason;
	// int getValidation() => this.validation;
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

	ubyte[] getSig() {
		if(!this.base64_sig.isEmpty()) {
			return Base64.decode(base64_sig);
		} else {
			try{
				string pkgpath = _alpm_filecache_find(this.handle, cast(char*)this.filename).to!string;
				if(pkgpath.isEmpty) {
					throw new Exception("ALPM Error: package not found");
				}

				string sigpath = _alpm_sigpath(this.handle, cast(char*)pkgpath).to!string;
				if(sigpath.isEmpty || alpmAccess(this.handle, null, sigpath, R_OK)) {
					throw new Exception("ALPM Error: signing not found");
				}

				ubyte[] sig = alpmReadFile(sigpath);
				
				logger.tracef("found detached signature %s with size %ld\n", sigpath, sig.length);
				return sig;
			}
			catch(Exception e) {
				return [];
			}
		}
	}

	AlpmStrings computeRequiredBy() {
		return handle.computeRequiredBy(this, 0);
	}

	AlpmStrings computeOptionalFor() {
		return handle.computeRequiredBy(this, 1);
	}
	/**
	* Clearing trans specific fields or if origin is File, return true for deleting outside
	* 
	* Return: need to be destroed outside? 
	*/
	bool freeTrans() {
		if(this.origin == AlpmPkgFrom.File)
			return true;
		this.removes.clear();
		this.oldpkg = null;
		return false;
	}

	/**
	* Duplicate a package data struct.
	* 
	* Return: new copy of package
	*/
	AlpmPkg dup() {
		AlpmPkg newPkg = new AlpmPkg;

		newPkg.tupleof = this.tupleof;

		return newPkg;
	}

	/** 
	 * Checks metadata (name ind version) of pkg 
	 *
	 * Throws: Exception, if name or/and version isn't valid
	 */
	void checkMeta() {
		string c;

		/* immediate bail if package doesn't have name or version */
		if(this.name.isEmpty() || this.version_ == null) {
			throw new Exception("invalid package metadata (name or version missing)");
		}
		if(this.name[0] == '-' || this.name[0] == '.') {
			throw new Exception("invalid metadata for package "~this.name~"-"~this.version_~", (package name cannot start with '.' or '-')");
		}
		if(alpmFnMatch(this.name, "[![:alnum:]+_.@-]") == 0) {
			throw new Exception("invalid metadata for package "~this.name~"-"~this.version_~", (package name contains invalid characters)");
		}

		/* multiple '-' in pkgver can cause local db entries for different packages
		* to overlap (e.g. foo-1=2-3 and foo=1-2-3 both give foo-1-2-3) */
		if((c = this.getVersion().find('-')) != [] && c[1..$-1].find('-')) {
			throw new Exception("invalid metadata for package "~this.name~"-"~this.version_~", (package version contains invalid characters)");
		}
		if(this.getVersion().find('-') != []) {
			throw new Exception("invalid metadata for package "~this.name~"-"~this.version_~", (package version contains invalid characters)");
		}

		/* local db entry is <pkgname>-<pkgver> */
		if(this.name.length + this.version_.length + 1 > NAME_MAX) {
			throw new Exception("invalid metadata for package "~this.name~"-"~this.version_~", (package name and version too long)");
		}
	}

	~this() {}

	/** 
	 * Compare packages's versions 
	 *
	 * Params:
	 *   localpkg = package to compare
	 * Returns: 
	 * 	 0 if version is equal
	 * 	 1 if this package is newer
	 *   -1 if this package is older	
	 */
	int compareVersions(AlpmPkg localpkg) {
		return compareStringVersions(this.version_, localpkg.version_);
	}


	/**
	*  Look for a filename in a AlpmPkg.backup list. If we find it,
	*  then we return the full backup entry.
	*
	* Params:
	*   file = filenames
	*
	* Return:
	* 	Backup entry
	*/
	AlpmBackup needBackup(string file) {
		if(file.isEmpty) {
			return null;
		}

		return backup[].find!(a => a.isBackup(file)).front();
	}

	/**
	*  Checks package depends on other package
	*
	* Params:
	*   pkg = other package
	*
	* Return:
	* 	true if depends
	*/
	bool dependsOn(AlpmPkg pkg) {
		return this.depends[]
			.canFind!(
				(dep) => _alpm_depcmp(pkg, dep)); 
	}
}

/// alias for AlpmList!AlpmPkg
alias AlpmPkgs = AlpmList!AlpmPkg;

/** 
 *	Find package int list by hash
 * 
 * Params:
 *   haystack = Package list
 *   needle = package name
 * Returns: 
 * 		Package object from list 
 */
AlpmPkg alpmFindPkgByHash(AlpmPkgs haystack, string needle) {
	return haystack[].find!((a) => (a.getNameHash == needle.alpmSDBMHash())).front();
}