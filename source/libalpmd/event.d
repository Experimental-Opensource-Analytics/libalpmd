module libalpmd.event;

import core.sys.posix.sys.types;

import libalpmd.pkg;
import libalpmd.deps;
import libalpmd.hook;

enum AlpmEventType {
	/** Checking keys used to create signatures are in keyring. */
	ALPM_EVENT_KEYRING_START,
	/** Keyring checking is finished. */
	ALPM_EVENT_KEYRING_DONE,
	/** Downloading missing keys into keyring. */
	ALPM_EVENT_KEY_DOWNLOAD_START,
	/** Key downloading is finished. */
	ALPM_EVENT_KEY_DOWNLOAD_DONE,
}

enum AlpmEventDefStatus {
	Start,
	Done
}

class AlpmEvent {

}

class AlpmEventWithDefStatus : AlpmEvent {
	AlpmEventDefStatus status;

	this() {}

	this(AlpmEventDefStatus status) {
		this.status = status;
	}

	void setStatus(AlpmEventDefStatus status) {
		this.status = status;
	}	

	auto getStatus() => status; 
}

/** A package operation event occurred. */
class AlpmEventPackageOperation : AlpmEventWithDefStatus {
	/** Type of operation */
	AlpmPackageOperationType operation;
	/** Old package */
	AlpmPkg oldpkg;
	/** New package */
	AlpmPkg newpkg;

	this(AlpmEventDefStatus status, AlpmPackageOperationType op, AlpmPkg old, AlpmPkg new_) {
		super(status);
		this.operation = op;
		this.oldpkg = old;
		this.newpkg = new_;
	}
}

class AlpmEventCheckDeps : AlpmEventWithDefStatus {
	this(AlpmEventDefStatus status) {
		super(status);
	}
}

class AlpmEventDownload : AlpmEvent {}

/** Context struct for when a download starts. */
class AlpmEventDownloadInit : AlpmEventDownload {
	/** whether this file is optional and thus the errors could be ignored */
	int optional;
}

/** Context struct for when a download progresses. */
class AlpmEventDownloadProgress : AlpmEventDownload {
	/** Amount of data downloaded */
	off_t downloaded;
	/** Total amount need to be downloaded */
	off_t total;
}

/** Context struct for when a download retries. */
class AlpmEventDownloadRetry : AlpmEventDownload {
	/** If the download will resume or start over */
	int resume;
}

/** Context struct for when a download completes. */
class AlpmEventDownloadCompleted : AlpmEventDownload {
	/** Total bytes in file */
	off_t total;
	/** download result code:
	 *    0 - download completed successfully
	 *    1 - the file is up-to-date
	 *   -1 - error
	 */
	int result;
}

/** An optional dependency was removed. */
class AlpmEventOptDepRemoval : AlpmEvent {
	/** Package with the optdep */
	AlpmPkg pkg;
	/** Optdep being removed */
	AlpmDepend optdep;

	this(AlpmPkg pkg, AlpmDepend dep) {
		this.pkg = pkg;
		this.optdep = dep;
	}
}

/** A scriptlet was ran. */
class AlpmEventScriptletInfo : AlpmEvent {
	/** Line of scriptlet output */
	string line;

	this(string line) {
		this.line = line;
	}
}


/** A database is missing.
 *
 * The database is registered but has not been downloaded
 */
class AlpmEventDbMissing : AlpmEvent {
	/** Name of the database */
	string dbname;

	this(string name) {
		this.dbname = name;
	}
}

/** A package was downloaded. */
class AlpmEventPkgDownloaded : AlpmEvent {
	/** Name of the file */
	string file;
}

class AlpmEventLoad : AlpmEventWithDefStatus {
	this(AlpmEventDefStatus status) {
		super(status);
	}	
}

class AlpmEventInterConflicts : AlpmEventWithDefStatus {
	this(AlpmEventDefStatus status) {
		super(status);
	}	
}

class AlpmEventResolveDeps : AlpmEventWithDefStatus {
	this(AlpmEventDefStatus status) {
		super(status);
	}	
}

class AlpmEventIntegrity : AlpmEventWithDefStatus {
	this(AlpmEventDefStatus status) {
		super(status);
	}	
}


class AlpmEventFileConflicts : AlpmEventWithDefStatus {
	this(AlpmEventDefStatus status) {
		super(status);
	}	
}

class AlpmEventDiskSpace : AlpmEventWithDefStatus {
	this(AlpmEventDefStatus status) {
		super(status);
	}	
}

/** A pacnew file was created. */
class AlpmEventPacnewCreated : AlpmEvent {
	/** Whether the creation was result of a NoUpgrade or not */
	bool from_noupgrade;
	/** Old package */
	AlpmPkg oldpkg;
	/** New Package */
	AlpmPkg newpkg;
	/** Filename of the file without the .pacnew suffix */
	string file;

	this(bool fromNoUpgrade, AlpmPkg old, AlpmPkg new_, string filename) {
		from_noupgrade = fromNoUpgrade;
		this.oldpkg = old;
		this.newpkg = new_;
		this.file = filename;
	}
}

class AlpmEventTransaction : AlpmEventWithDefStatus {
	this(AlpmEventDefStatus status) {
		super(status);
	}
}

/** A pacsave file was created. */
class AlpmEventPacsaveCreated : AlpmEvent {
	/** Old package */
	AlpmPkg oldpkg;
	/** Filename of the file without the .pacsave suffix */
	string file;

	this(AlpmPkg oldPkg, string file) {
		this.oldpkg = oldPkg;
		this.file = file;
	}
}

/** pre/post transaction hooks are to be ran. */
class AlpmEventHook : AlpmEventWithDefStatus {
	// AlpmEventDefStatus status;
	/** Type of hook */
	AlpmHookWhen when;

	this(AlpmEventDefStatus status, AlpmHookWhen when) {
		super(status);
		this.when = when;
	}
}

/** A pre/post transaction hook was ran. */
class AlpmEventHookRun : AlpmEventWithDefStatus {
	// AlpmEventDefStatus status;
	/** Name of hook */
	string name;
	/** Description of hook to be outputted */
	string desc;
	/** position of hook being run */
	size_t position;
	/** total hooks being run */
	size_t total;
}

enum AlpmEventPkgRetrievStatus {
	Start,
	Done,
	Failed
}

/** Packages downloading about to start. */
class AlpmEventPkgRetriev : AlpmEvent {
	/** Type of event */
	AlpmEventPkgRetrievStatus status;

	size_t num;
	/** Total size of packages to download */
	off_t total_size;

	this(AlpmEventPkgRetrievStatus status) {
		this.status = status;
	}
}

alias AlpmEventCallback = void delegate(AlpmEvent event);