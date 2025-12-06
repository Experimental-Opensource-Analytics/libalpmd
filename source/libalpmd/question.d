module libalpmd.question;

import libalpmd.deps;
import libalpmd.pkg;
import libalpmd.alpm;
import libalpmd.alpm_list;
import libalpmd.conflict;
import libalpmd.db;

/** Question callback.
 *
 * This callback allows user to give input and decide what to do during certain events
 * @param ctx user-provided context
 * @param question the question being asked.
 */
alias AlpmQuestionCallback = void delegate(AlpmQuestion question);

class AlpmQuestion {
    int answer;

	int getAnswer() => answer;
} 

class AlpmQuestionInstallIgnorePkg : AlpmQuestion {
	/** The ignored package that we are deciding whether to install */
	AlpmPkg pkg;

	this(AlpmPkg pkg) {
		this.pkg = pkg;
	}
}

class AlpmQuestionReplace : AlpmQuestion {
	/** Package to be replaced */
	AlpmPkg oldpkg;
	/** Package to replace with.*/
	AlpmPkg newpkg;
	/** DB of newpkg */
	AlpmDB newdb;

	this(AlpmPkg pkg1, AlpmPkg pkg2, AlpmDB db) {
		this.oldpkg = pkg1;
		this.newpkg = pkg2;
		this.newdb = db;
	}
}

/** Should a conflicting package be removed? */
class AlpmQuestionConflict : AlpmQuestion {
	/** Conflict info */
	AlpmConflict conflict;

	this(AlpmConflict conflict) {
		this.conflict = conflict;
	}
}

/** Should a corrupted package be deleted? */
class AlpmQuestionCorrupted : AlpmQuestion {
	/** File to remove */
	string filepath;
	/** Error code indicating the reason for package invalidity */
	alpm_errno_t reason;

	this(string filepath, alpm_errno_t reason) {
		this.filepath = filepath;
		this.reason = reason;
	}
}

/** Should unresolvable targets be removed from the transaction? */
class AlpmQuestionRemovePkg : AlpmQuestion {
	/** List of AlpmPkg with unresolved dependencies */
	AlpmPkgs packages;

	this(AlpmPkgs pkgs) {
		this.packages = pkgs;
	}
}

/** Provider selection */
class AlpmQuestionSelectProvider : AlpmQuestion {
	/** List of AlpmPkg as possible providers */
	alpm_list_t* providers;
	/** What providers provide for */
	AlpmDepend depend;

	this(alpm_list_t* providers, AlpmDepend depend) {
		this.providers = providers;
		this.depend = depend;
	}
}

/** Should a key be imported? */
class AlpmQuestionImportKey : AlpmQuestion {
	/** UID of the key to import */
	string uid;
	/** Fingerprint the key to import */
	string fingerprint;

	this(string uid, string fingerprint) {
		this.uid = uid;
		this.fingerprint = fingerprint;
	}
}