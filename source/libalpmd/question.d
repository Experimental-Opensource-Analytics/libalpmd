module libalpmd.question;

import libalpmd.deps;
import libalpmd.pkg;
import libalpmd.alpm;
import libalpmd.alpm_list;
import libalpmd.conflict;
import libalpmd.db;

/**
 * Type of question.
 * Unlike the events or progress enumerations, this enum has bitmask values
 * so a frontend can use a bitmask map to supply preselected answers to the
 * different types of questions.
 */
enum alpm_question_type_t {
	/** Should target in ignorepkg be installed anyway? */
	ALPM_QUESTION_INSTALL_IGNOREPKG = (1 << 0),
	/** Should a package be replaced? */
	ALPM_QUESTION_REPLACE_PKG = (1 << 1),
	/** Should a conflicting package be removed? */
	ALPM_QUESTION_CONFLICT_PKG = (1 << 2),
	/** Should a corrupted package be deleted? */
	ALPM_QUESTION_CORRUPTED_PKG = (1 << 3),
	/** Should unresolvable targets be removed from the transaction? */
	ALPM_QUESTION_REMOVE_PKGS = (1 << 4),
	/** Provider selection */
	ALPM_QUESTION_SELECT_PROVIDER = (1 << 5),
	/** Should a key be imported? */
	ALPM_QUESTION_IMPORT_KEY = (1 << 6)
}
alias ALPM_QUESTION_INSTALL_IGNOREPKG = alpm_question_type_t.ALPM_QUESTION_INSTALL_IGNOREPKG;
alias ALPM_QUESTION_REPLACE_PKG = alpm_question_type_t.ALPM_QUESTION_REPLACE_PKG;
alias ALPM_QUESTION_CONFLICT_PKG = alpm_question_type_t.ALPM_QUESTION_CONFLICT_PKG;
alias ALPM_QUESTION_CORRUPTED_PKG = alpm_question_type_t.ALPM_QUESTION_CORRUPTED_PKG;
alias ALPM_QUESTION_REMOVE_PKGS = alpm_question_type_t.ALPM_QUESTION_REMOVE_PKGS;
alias ALPM_QUESTION_SELECT_PROVIDER = alpm_question_type_t.ALPM_QUESTION_SELECT_PROVIDER;
alias ALPM_QUESTION_IMPORT_KEY = alpm_question_type_t.ALPM_QUESTION_IMPORT_KEY;

/** A question that can represent any other question. */
struct alpm_question_any_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer */
	int answer;
}

/** Should target in ignorepkg be installed anyway? */
struct alpm_question_install_ignorepkg_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to install pkg anyway */
	int install;
	/** The ignored package that we are deciding whether to install */
	AlpmPkg pkg;
}

/** Should a package be replaced? */
struct alpm_question_replace_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to replace oldpkg with newpkg */
	int replace;
	/** Package to be replaced */
	AlpmPkg oldpkg;
	/** Package to replace with.*/
	AlpmPkg newpkg;
	/** DB of newpkg */
	AlpmDB newdb;
}

/** Should a conflicting package be removed? */
struct alpm_question_conflict_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to remove conflict->package2 */
	int remove;
	/** Conflict info */
	AlpmConflict conflict;
}

/** Should a corrupted package be deleted? */
struct alpm_question_corrupted_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to remove filepath */
	int remove;
	/** File to remove */
	const(char)* filepath;
	/** Error code indicating the reason for package invalidity */
	alpm_errno_t reason;
}

/** Should unresolvable targets be removed from the transaction? */
struct alpm_question_remove_pkgs_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to skip packages */
	int skip;
	/** List of AlpmPkg with unresolved dependencies */
	AlpmPkgs packages;
}

/** Provider selection */
struct alpm_question_select_provider_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: which provider to use (index from providers) */
	int use_index;
	/** List of AlpmPkg as possible providers */
	alpm_list_t* providers;
	/** What providers provide for */
	AlpmDepend depend;
}

/** Should a key be imported? */
struct alpm_question_import_key_t {
	/** Type of question */
	alpm_question_type_t type;
	/** Answer: whether or not to import key */
	int import_;
	/** UID of the key to import */
	const(char)* uid;
	/** Fingerprint the key to import */
	const(char)* fingerprint;
}

/**
 * Questions.
 * This is an union passed to the callback that allows the frontend to know
 * which type of question was triggered (via type). It is then possible to
 * typecast the pointer to the right structure, or use the union field, in order
 * to access question-specific data. */
union alpm_question_t {
	/** The type of question. It's always safe to access this. */
	alpm_question_type_t type;
	/** A question that can represent any question.
	 * It's always safe to access this. */
	alpm_question_any_t any;
	/** Should target in ignorepkg be installed anyway? */
	alpm_question_install_ignorepkg_t install_ignorepkg;
	/** Should a package be replaced? */
	alpm_question_replace_t replace;
	/** Should a conflicting package be removed? */
	alpm_question_conflict_t conflict;
	/** Should a corrupted package be deleted? */
	alpm_question_corrupted_t corrupted;
	/** Should unresolvable targets be removed from the transaction? */
	alpm_question_remove_pkgs_t remove_pkgs;
	/** Provider selection */
	alpm_question_select_provider_t select_provider;
	/** Should a key be imported? */
	alpm_question_import_key_t import_key;
}

/** Question callback.
 *
 * This callback allows user to give input and decide what to do during certain events
 * @param ctx user-provided context
 * @param question the question being asked.
 */
alias alpm_cb_question = void function(void* ctx, alpm_question_t* question);

