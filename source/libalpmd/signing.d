module libalpmd.signing;
@nogc  
   
/*
 *  signing.c
 *
 *  Copyright (c) 2008-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
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

version (HAVE_LIBGPGME) {
import core.stdc.locale; /* setlocale() */
import gpgme;
}

/* libalpm */
import libalpmd.signing;
import libalpmd.pkg;
import libalpmd.base64;
import libalpmd.util;
import libalpmd.log;
import libalpmd.alpm;
import libalpmd.handle;
import libalpmd.alpm_list;
import libalpmd.db;



int  alpm_decode_signature(  char*base64_data, ubyte** data, size_t* data_len)
{
	size_t len = strlen(base64_data);
	ubyte* usline = cast(ubyte*)base64_data;
	/* reasonable allocation of expected length is 3/4 of encoded length */
	size_t destlen = len * 3 / 4;
	MALLOC(*data, destlen);
	if(base64_decode(*data, &destlen, usline, len)) {
		free(*data);
		goto error;
	}
	*data_len = destlen;
	return 0;

error:
	*data = null;
	*data_len = 0;
	return -1;
}

version (HAVE_LIBGPGME) {
void CHECK_ERR(E)(E gpg_err) { 
	if(gpg_err_code(gpg_err) != GPG_ERR_NO_ERROR) {
		assert(false);
	} 
} 

/**
 * Return a statically allocated validity string based on the GPGME validity
 * code. This is mainly for debug purposes and is not translated.
 * @param validity a validity code returned by GPGME
 * @return a string such as "marginal"
 */
private   char*string_validity(gpgme_validity_t validity)
{
	switch(validity) {
		case GPGME_VALIDITY_UNKNOWN:
			return "unknown";
		case GPGME_VALIDITY_UNDEFINED:
			return "undefined";
		case GPGME_VALIDITY_NEVER:
			return "never";
		case GPGME_VALIDITY_MARGINAL:
			return "marginal";
		case GPGME_VALIDITY_FULL:
			return "full";
		case GPGME_VALIDITY_ULTIMATE:
			return "ultimate";
	default: break;}
	return "???";
}

private void sigsum_test_bit(gpgme_sigsum_t sigsum, alpm_list_t** summary, gpgme_sigsum_t bit,   char*value)
{
	if(sigsum & bit) {
		*summary = alpm_list_add(*summary, cast(void*)value);
	}
}

/**
 * Calculate a set of strings to represent the given GPGME signature summary
 * value. This is a bitmask so you may get any number of strings back.
 * @param sigsum a GPGME signature summary bitmask
 * @return the list of signature summary strings
 */
private alpm_list_t* list_sigsum(gpgme_sigsum_t sigsum)
{
	alpm_list_t* summary = null;
	/* The docs say this can be a bitmask...not sure I believe it, but we'll code
	 * for it anyway and show all possible flags in the returned string. */

	/* The signature is fully valid. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_VALID, "valid");
	/* The signature is good. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_GREEN, "green");
	/* The signature is bad. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_RED, "red");
	/* One key has been revoked. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_KEY_REVOKED, "key revoked");
	/* One key has expired. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_KEY_EXPIRED, "key expired");
	/* The signature has expired. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_SIG_EXPIRED, "sig expired");
	/* Can't verify: key missing. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_KEY_MISSING, "key missing");
	/* CRL not available. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_CRL_MISSING, "crl missing");
	/* Available CRL is too old. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_CRL_TOO_OLD, "crl too old");
	/* A policy was not met. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_BAD_POLICY, "bad policy");
	/* A system error occurred. */
	sigsum_test_bit(sigsum, &summary, GPGME_SIGSUM_SYS_ERROR, "sys error");
	/* Fallback case */
	if(!sigsum) {
		summary = alpm_list_add(summary, cast(void*)"(empty)");
	}
	return summary;
}

/**
 * Initialize the GPGME library.
 * This can be safely called multiple times; however it is not thread-safe.
 * @param handle the context handle
 * @return 0 on success, -1 on error
 */
private int init_gpgme(AlpmHandle handle)
{
	static int init = 0;
	  char*version_ = void, sigdir = void;
	gpgme_error_t gpg_err = void;
	gpgme_engine_info_t enginfo = void;

	if(init) {
		/* we already successfully initialized the library */
		return 0;
	}

	sigdir = handle.gpgdir;

	if(alpmAccess(handle, sigdir, "pubring.gpg", R_OK)
			|| alpmAccess(handle, sigdir, "trustdb.gpg", R_OK)) {
		handle.pm_errno = ALPM_ERR_NOT_A_FILE;
		logger.tracef("Signature verification will fail!\n");
		_alpm_log(handle, ALPM_LOG_WARNING,
				("Public keyring not found; have you run '%s'?\n"),
				"pacman-key --init");
	}

	/* calling gpgme_check_version() returns the current version and runs
	 * some internal library setup code */
	version_ = gpgme_check_version(null);
	logger.tracef("GPGME version: %s\n", version_);
	gpgme_set_locale(null, LC_CTYPE, setlocale(LC_CTYPE, null));
version (LC_MESSAGES) {
	gpgme_set_locale(null, LC_MESSAGES, setlocale(LC_MESSAGES, null));
}
	/* NOTE:
	 * The GPGME library installs a SIGPIPE signal handler automatically if
	 * the default signal handler is in use. The only time we set a handler
	 * for SIGPIPE is in dload.c, and we reset it when we are done. Given that
	 * we do this, we can let GPGME do its automagic. However, if we install
	 * a library-wide SIGPIPE handler, we will have to be careful.
	 */

	/* check for OpenPGP support (should be a no-brainer, but be safe) */
	gpg_err = gpgme_engine_check_version(GPGME_PROTOCOL_OpenPGP);
	mixin(CHECK_ERR!());

	/* set and check engine information */
	gpg_err = gpgme_set_engine_info(GPGME_PROTOCOL_OpenPGP, null, sigdir);
	mixin(CHECK_ERR!());
	gpg_err = gpgme_get_engine_info(&enginfo);
	mixin(CHECK_ERR!());
	logger.tracef("GPGME engine info: file=%s, home=%s\n",
			enginfo.file_name, enginfo.home_dir);

	init = 1;
	return 0;

gpg_error:
	_alpm_log(handle, ALPM_LOG_ERROR, ("GPGME error: %s\n"), gpgme_strerror(gpg_err));
	RET_ERR(handle, ALPM_ERR_GPGME, -1);
}

/**
 * Determine if we have a key is known in our local keyring.
 * @param handle the context handle
 * @param fpr the fingerprint key ID to look up
 * @return 1 if key is known, 0 if key is unknown, -1 on error
 */
int _alpm_key_in_keychain(AlpmHandle handle,   char*fpr)
{
	gpgme_error_t gpg_err = void;
	gpgme_ctx_t ctx = {0};
	gpgme_key_t key = void;
	int ret = -1;

	if(alpm_list_find_str(handle.known_keys, fpr)) {
		logger.tracef("key %s found in cache\n", fpr);
		return 1;
	}

	if(init_gpgme(handle)) {
		/* pm_errno was set in gpgme_init() */
		goto error;
	}

	gpg_err = gpgme_new(&ctx);
	mixin(CHECK_ERR!());

	logger.tracef("looking up key %s locally\n", fpr);

	gpg_err = gpgme_get_key(ctx, fpr, &key, 0);
	if(gpg_err_code(gpg_err) == GPG_ERR_EOF) {
		logger.tracef("key lookup failed, unknown key\n");
		ret = 0;
	} else if(gpg_err_code(gpg_err) == GPG_ERR_NO_ERROR) {
		if(key.expired) {
			logger.tracef("key lookup success, but key is expired\n");
			ret = 0;
		} else {
			logger.tracef("key lookup success, key exists\n");
			handle.known_keys = alpm_list_add(handle.known_keys, strdup(fpr));
			ret = 1;
		}
	} else {
		logger.tracef("gpg error: %s\n", gpgme_strerror(gpg_err));
	}
	gpgme_key_unref(key);

gpg_error:
	gpgme_release(ctx);

error:
	return ret;
}

/**
 * Import a key from a Web Key Directory (WKD) into the local keyring using.
 * This requires GPGME to call the gpg binary.
 * @param handle the context handle
 * @param email the email address of the key to import
 * @param fpr the fingerprint key ID to look up (or NULL)
 * @return 0 on success, -1 on error
 */
private int key_import_wkd(AlpmHandle handle,   char*email,   char*fpr)
{
	gpgme_error_t gpg_err = void;
	gpgme_ctx_t ctx = {0};
	gpgme_keylist_mode_t mode = void;
	gpgme_key_t key = void;
	int ret = -1;

	gpg_err = gpgme_new(&ctx);
	mixin(CHECK_ERR!());

	mode = gpgme_get_keylist_mode(ctx);
	mode |= GPGME_KEYLIST_MODE_LOCATE_EXTERNAL;
	gpg_err = gpgme_set_keylist_mode(ctx, mode);
	mixin(CHECK_ERR!());

	logger.tracef(("looking up key %s using WKD\n"), email);
	gpg_err = gpgme_get_key(ctx, email, &key, 0);
	if(gpg_err_code(gpg_err) == GPG_ERR_NO_ERROR) {
		/* check if correct key was imported via WKD */
		if(fpr && _alpm_key_in_keychain(handle, fpr)) {
			ret = 0;
		} else {
			logger.tracef("key lookup failed: WKD imported wrong fingerprint or key expired\n");
		}
	}
	gpgme_key_unref(key);

gpg_error:
	if(ret != 0) {
		logger.tracef(("gpg error: %s\n"), gpgme_strerror(gpg_err));
	}
	gpgme_release(ctx);
	return ret;
}

/**
 * Search for a GPG key on a keyserver.
 * This requires GPGME to call the gpg binary and have a keyserver previously
 * defined in a gpg.conf configuration file.
 * @param handle the context handle
 * @param fpr the fingerprint key ID to look up
 * @param pgpkey storage location for the given key if found
 * @return 1 on success, 0 on key not found, -1 on error
 */
private int key_search_keyserver(AlpmHandle handle,   char*fpr, alpm_pgpkey_t* pgpkey)
{
	gpgme_error_t gpg_err = void;
	gpgme_ctx_t ctx = {0};
	gpgme_keylist_mode_t mode = void;
	gpgme_key_t key = void;
	int ret = -1;
	size_t fpr_len = void;
	char* full_fpr = void;

	/* gpg2 goes full retard here. For key searches ONLY, we need to prefix the
	 * key fingerprint with 0x, or the lookup will fail. */
	fpr_len = strlen(fpr);
	MALLOC(full_fpr, fpr_len + 3);
	snprintf(full_fpr, fpr_len + 3, "0x%s", fpr);

	gpg_err = gpgme_new(&ctx);
	mixin(CHECK_ERR!());

	mode = gpgme_get_keylist_mode(ctx);
	/* using LOCAL and EXTERN together doesn't work for GPG 1.X. Ugh. */
	mode &= ~GPGME_KEYLIST_MODE_LOCAL;
	mode |= GPGME_KEYLIST_MODE_EXTERN;
	gpg_err = gpgme_set_keylist_mode(ctx, mode);
	mixin(CHECK_ERR!());

	logger.tracef("looking up key %s remotely\n", fpr);

	gpg_err = gpgme_get_key(ctx, full_fpr, &key, 0);
	if(gpg_err_code(gpg_err) == GPG_ERR_EOF) {
		logger.tracef("key lookup failed, unknown key\n");
		/* Try an alternate lookup using the 8 character fingerprint value, since
		 * busted-ass keyservers can't support lookups using subkeys with the full
		 * value as of now. This is why 2012 is not the year of PGP encryption. */
		if(fpr_len > 8) {
			  char*short_fpr = memcpy(&full_fpr[fpr_len - 8], "0x", 2);
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"looking up key %s remotely\n", short_fpr);
			gpg_err = gpgme_get_key(ctx, short_fpr, &key, 0);
			if(gpg_err_code(gpg_err) == GPG_ERR_EOF) {
				logger.tracef("key lookup failed, unknown key\n");
				ret = 0;
			}
		} else {
			ret = 0;
		}
	}

	mixin(CHECK_ERR!());

	/* should only get here if key actually exists */
	pgpkey.data = key;
	if(key.subkeys.fpr) {
		pgpkey.fingerprint = key.subkeys.fpr;
	} else {
		pgpkey.fingerprint = key.subkeys.keyid;
	}

	/* we are probably going to fail importing, but continue anyway... */
	if(key.uids != null) {
		pgpkey.uid = key.uids.uid;
		pgpkey.name = key.uids.name;
		pgpkey.email = key.uids.email;
	}

	pgpkey.created = key.subkeys.timestamp;
	pgpkey.expires = key.subkeys.expires;
	pgpkey.length = key.subkeys.length;
	pgpkey.revoked = key.subkeys.revoked;
	ret = 1;

gpg_error:
	if(ret != 1) {
		logger.tracef("gpg error: %s\n", gpgme_strerror(gpg_err));
	}
	free(full_fpr);
	gpgme_release(ctx);
	return ret;
}

/**
 * Import a key into the local keyring.
 * @param handle the context handle
 * @param key the key to import, likely retrieved from #key_search_keyserver
 * @return 0 on success, -1 on error
 */
private int key_import_keyserver(AlpmHandle handle, alpm_pgpkey_t* key)
{
	gpgme_error_t gpg_err = void;
	gpgme_ctx_t ctx = {0};
	gpgme_key_t[2] keys = void;
	gpgme_import_result_t result = void;
	int ret = -1;

	if(alpmAccess(handle, handle.gpgdir, "pubring.gpg", W_OK)) {
		/* no chance of import succeeding if pubring isn't writable */
		_alpm_log(handle, ALPM_LOG_ERROR, ("keyring is not writable\n"));
		return -1;
	}

	gpg_err = gpgme_new(&ctx);
	mixin(CHECK_ERR!());

	logger.tracef("importing key\n");

	keys[0] = key.data;
	keys[1] = null;
	gpg_err = gpgme_op_import_keys(ctx, keys.ptr);
	mixin(CHECK_ERR!());
	result = gpgme_op_import_result(ctx);
	/* we know we tried to import exactly one key, so check for this */
	if(result.considered != 1 || !result.imports) {
		logger.tracef("could not import key, 0 results\n");
		ret = -1;
	} else if(result.imports.result != GPG_ERR_NO_ERROR) {
		logger.tracef("gpg error: %s\n", gpgme_strerror(gpg_err));
		ret = -1;
	} else {
		ret = 0;
	}

gpg_error:
	gpgme_release(ctx);
	return ret;
}

/** Extract the email address from a user ID
 * @param uid the user ID to parse in the form "Example Name <email@address.invalid>"
 * @param email to hold email address
 * @return 0 on success, -1 on error
 */
private int email_from_uid(  char*uid, char** email)
{
       char* start = void, end = void;

       if (uid == null) {
               *email = null;
               return -1;
       }

       start = strrchr(uid, '<');
       if(start) {
               end = strrchr(start, '>');
       }

       if(start && end) {
               STRDUP(*email, start+1, end-start-1);
               return 0;
       } else {
               *email = null;
               return -1;
       }
}

/**
 * Import a key defined by a fingerprint into the local keyring.
 * @param handle the context handle
 * @param uid a user ID of the key to import
 * @param fpr the fingerprint key ID to import
 * @return 0 on success, -1 on error
 */
int _alpm_key_import(AlpmHandle handle,   char*uid,   char*fpr)
{
	int ret = -1;
	alpm_pgpkey_t fetch_key = {0};
	char* email = void;

	if(alpmAccess(handle, handle.gpgdir, "pubring.gpg", W_OK)) {
		/* no chance of import succeeding if pubring isn't writable */
		_alpm_log(handle, ALPM_LOG_ERROR, ("keyring is not writable\n"));
		return -1;
	}


	alpm_question_import_key_t question = {
				type: ALPM_QUESTION_IMPORT_KEY,
				_import: 0,
				uid: uid,
				fingerprint: fpr
			};
	QUESTION(handle, &question);

	if(question.import_) {
		/* Try to import the key from a WKD first */
		if(email_from_uid(uid, &email) == 0) {
			ret = key_import_wkd(handle, email, fpr);
			free(email);
		}

		/* If importing from the WKD fails, fall back to keyserver lookup */
		if(ret != 0) {
			if(key_search_keyserver(handle, fpr, &fetch_key) == 1) {
				_alpm_log(handle, ALPM_LOG_DEBUG,
						("key \"%s\" on keyserver\n"), fetch_key.uid);
				if(key_import_keyserver(handle, &fetch_key) == 0) {
					ret = 0;
				} else {
					_alpm_log(handle, ALPM_LOG_ERROR,
							("key \"%s\" could not be imported\n"), fpr);
				}
			} else {
				_alpm_log(handle, ALPM_LOG_ERROR,
						("key \"%s\" could not be looked up remotely\n"), fpr);
			}
		}
	}
	gpgme_key_unref(fetch_key.data);
	return ret;
}

/**
 * Check the PGP signature for the given file path.
 * If base64_sig is provided, it will be used as the signature data after
 * decoding. If base64_sig is NULL, expect a signature file next to path
 * (e.g. "%s.sig").
 *
 * The return value will be 0 if nothing abnormal happened during the signature
 * check, and -1 if an error occurred while checking signatures or if a
 * signature could not be found; pm_errno will be set. Note that "abnormal"
 * does not include a failed signature; the value in siglist should be checked
 * to determine if the signature(s) are good.
 * @param handle the context handle
 * @param path the full path to a file
 * @param base64_sig optional PGP signature data in base64 encoding
 * @param siglist a pointer to storage for signature results
 * @return 0 in normal cases, -1 if the something failed in the check process
 */
int _alpm_gpgme_checksig(AlpmHandle handle,   char*path,   char*base64_sig, alpm_siglist_t* siglist)
{
	int ret = -1, sigcount = void;
	gpgme_error_t gpg_err = 0;
	gpgme_ctx_t ctx = {0};
	gpgme_data_t filedata = {0}, sigdata = {0};
	gpgme_verify_result_t verify_result = void;
	gpgme_signature_t gpgsig = void;
	char* sigpath = null;
	ubyte* decoded_sigdata = null;
	FILE* file = null, sigfile = null;

	if(!path || alpmAccess(handle, null, path, R_OK) != 0) {
		RET_ERR(handle, ALPM_ERR_NOT_A_FILE, -1);
	}

	if(!siglist) {
		RET_ERR(handle, ALPM_ERR_WRONG_ARGS, -1);
	}
	siglist.count = 0;

	if(!base64_sig) {
		sigpath = _alpm_sigpath(handle, path);
		if(alpmAccess(handle, null, sigpath, R_OK) != 0
				|| (sigfile = fopen(sigpath, "rb")) == null) {
			logger.tracef("sig path %s could not be opened\n",
					sigpath);
			GOTO_ERR(handle, ALPM_ERR_SIG_MISSING, error);
		}
	}

	/* does the file we are verifying exist? */
	file = fopen(path, "rb");
	if(file == null) {
		GOTO_ERR(handle, ALPM_ERR_NOT_A_FILE, error);
	}

	if(init_gpgme(handle)) {
		/* pm_errno was set in gpgme_init() */
		goto error;
	}

	logger.tracef("checking signature for %s\n", path);

	gpg_err = gpgme_new(&ctx);
	mixin(CHECK_ERR!());

	/* create our necessary data objects to verify the signature */
	gpg_err = gpgme_data_new_from_stream(&filedata, file);
	mixin(CHECK_ERR!());

	/* next create data object for the signature */
	if(base64_sig) {
		/* memory-based, we loaded it from a sync DB */
		size_t data_len = void;
		int decode_ret = alpm_decode_signature(base64_sig,
				&decoded_sigdata, &data_len);
		if(decode_ret) {
			GOTO_ERR(handle, ALPM_ERR_SIG_INVALID, error);
		}
		gpg_err = gpgme_data_new_from_mem(&sigdata,
				cast(char*)decoded_sigdata, data_len, 0);
	} else {
		/* file-based, it is on disk */
		gpg_err = gpgme_data_new_from_stream(&sigdata, sigfile);
	}
	mixin(CHECK_ERR!());

	/* here's where the magic happens */
	gpg_err = gpgme_op_verify(ctx, sigdata, filedata, null);
	mixin(CHECK_ERR!());
	verify_result = gpgme_op_verify_result(ctx);
	mixin(CHECK_ERR!());
	if(!verify_result || !verify_result.signatures) {
		logger.tracef("no signatures returned\n");
		GOTO_ERR(handle, ALPM_ERR_SIG_MISSING, gpg_error);
	}
	for(gpgsig = verify_result.signatures, sigcount = 0;
			gpgsig; gpgsig = gpgsig.next, sigcount++){}
	logger.tracef("%d signatures returned\n", sigcount);

	CALLOC(siglist.results, sigcount, alpm_sigresult_t.sizeof);
	siglist.count = sigcount;

	for(gpgsig = verify_result.signatures, sigcount = 0; gpgsig;
			gpgsig = gpgsig.next, sigcount++) {
		alpm_list_t* summary_list = void, summary = void;
		alpm_sigstatus_t status = void;
		alpm_sigvalidity_t validity = void;
		gpgme_key_t key = void;
		alpm_sigresult_t* result = void;

		logger.tracef("fingerprint: %s\n", gpgsig.fpr);
		summary_list = list_sigsum(gpgsig.summary);
		for(summary = summary_list; summary; summary = summary.next) {
			logger.tracef("summary: %s\n", cast( char*)summary.data);
		}
		alpm_list_free(summary_list);
		logger.tracef("status: %s\n", gpgme_strerror(gpgsig.status));
		logger.tracef("timestamp: %lu\n", gpgsig.timestamp);

		if(cast(time_t)gpgsig.timestamp > time(null)) {
			_alpm_log(handle, ALPM_LOG_DEBUG,
					"signature timestamp is greater than system time.\n");
		}

		logger.tracef("exp_timestamp: %lu\n", gpgsig.exp_timestamp);
		logger.tracef("validity: %s; reason: %s\n",
				string_validity(gpgsig.validity),
				gpgme_strerror(gpgsig.validity_reason));

		result = siglist.results + sigcount;
		gpg_err = gpgme_get_key(ctx, gpgsig.fpr, &key, 0);
		if(gpg_err_code(gpg_err) == GPG_ERR_EOF) {
			logger.tracef("key lookup failed, unknown key\n");
			gpg_err = GPG_ERR_NO_ERROR;
			/* we dupe the fpr in this case since we have no key to point at */
			STRDUP(result.key.fingerprint, gpgsig.fpr);
		} else {
			mixin(CHECK_ERR!());
			if(key.uids) {
				result.key.data = key;
				result.key.fingerprint = key.subkeys.fpr;
				result.key.uid = key.uids.uid;
				result.key.name = key.uids.name;
				result.key.email = key.uids.email;
				result.key.created = key.subkeys.timestamp;
				result.key.expires = key.subkeys.expires;
				_alpm_log(handle, ALPM_LOG_DEBUG,
						"key: %s, %s, owner_trust %s, disabled %d\n",
						key.subkeys.fpr, key.uids.uid,
						string_validity(key.owner_trust), key.disabled);
			}
		}

		switch(gpg_err_code(gpgsig.status)) {
			/* good cases */
			case GPG_ERR_NO_ERROR:
				status = ALPM_SIGSTATUS_VALID;
				break;
			case GPG_ERR_KEY_EXPIRED:
				status = ALPM_SIGSTATUS_KEY_EXPIRED;
				break;
			/* bad cases */
			case GPG_ERR_SIG_EXPIRED:
				status = ALPM_SIGSTATUS_SIG_EXPIRED;
				break;
			case GPG_ERR_NO_PUBKEY:
				status = ALPM_SIGSTATUS_KEY_UNKNOWN;
				break;
			case GPG_ERR_BAD_SIGNATURE:
			default:
				status = ALPM_SIGSTATUS_INVALID;
				break;
		}
		/* special case: key disabled is not returned in above status code */
		if(result.key.data && key.disabled) {
			status = ALPM_SIGSTATUS_KEY_DISABLED;
		}

		switch(gpgsig.validity) {
			case GPGME_VALIDITY_ULTIMATE:
			case GPGME_VALIDITY_FULL:
				validity = ALPM_SIGVALIDITY_FULL;
				break;
			case GPGME_VALIDITY_MARGINAL:
				validity = ALPM_SIGVALIDITY_MARGINAL;
				break;
			case GPGME_VALIDITY_NEVER:
				validity = ALPM_SIGVALIDITY_NEVER;
				break;
			case GPGME_VALIDITY_UNKNOWN:
			case GPGME_VALIDITY_UNDEFINED:
			default:
				validity = ALPM_SIGVALIDITY_UNKNOWN;
				break;
		}

		result.status = status;
		result.validity = validity;
	}

	ret = 0;

gpg_error:
	gpgme_data_release(sigdata);
	gpgme_data_release(filedata);
	gpgme_release(ctx);

error:
	if(sigfile) {
		fclose(sigfile);
	}
	if(file) {
		fclose(file);
	}
	FREE(sigpath);
	FREE(decoded_sigdata);
	if(gpg_err_code(gpg_err) != GPG_ERR_NO_ERROR) {
		_alpm_log(handle, ALPM_LOG_ERROR, ("GPGME error: %s\n"), gpgme_strerror(gpg_err));
		RET_ERR(handle, ALPM_ERR_GPGME, -1);
	}
	return ret;
}

} else { /* HAVE_LIBGPGME */
int _alpm_key_in_keychain(AlpmHandle handle,   char*fpr)
{
	handle.pm_errno = ALPM_ERR_MISSING_CAPABILITY_SIGNATURES;
	return -1;
}

int _alpm_key_import(AlpmHandle handle,   char*uid,   char*fpr)
{
	handle.pm_errno = ALPM_ERR_MISSING_CAPABILITY_SIGNATURES;
	return -1;
}

int _alpm_gpgme_checksig(AlpmHandle handle,   char*path,   char*base64_sig, alpm_siglist_t* siglist)
{
	siglist.count = 0;
	handle.pm_errno = ALPM_ERR_MISSING_CAPABILITY_SIGNATURES;
	return -1;
}
} /* HAVE_LIBGPGME */

/**
 * Form a signature path given a file path.
 * Caller must free the result.
 * @param handle the context handle
 * @param path the full path to a file
 * @return the path with '.sig' appended, NULL on errors
 */
char* _alpm_sigpath(AlpmHandle handle,   char*path)
{
	char* sigpath = void;
	size_t len = void;

	if(!path) {
		return null;
	}
	len = strlen(path) + 5;
	CALLOC(sigpath, len, char.sizeof);
	snprintf(sigpath, len, "%s.sig", path);
	return sigpath;
}

/**
 * Helper for checking the PGP signature for the given file path.
 * This wraps #_alpm_gpgme_checksig in a slightly friendlier manner to simplify
 * handling of optional signatures and marginal/unknown trust levels and
 * handling the correct error code return values.
 * @param handle the context handle
 * @param path the full path to a file
 * @param base64_sig optional PGP signature data in base64 encoding
 * @param optional whether signatures are optional (e.g., missing OK)
 * @param marginal whether signatures with marginal trust are acceptable
 * @param unknown whether signatures with unknown trust are acceptable
 * @param sigdata a pointer to storage for signature results
 * @return 0 on success, -1 on error (consult pm_errno or sigdata)
 */
int _alpm_check_pgp_helper(AlpmHandle handle,   char*path,   char*base64_sig, int optional, int marginal, int unknown, alpm_siglist_t** sigdata)
{
	alpm_siglist_t* siglist = void;
	int ret = void;

	CALLOC(siglist, 1, alpm_siglist_t.sizeof);

	ret = _alpm_gpgme_checksig(handle, path, base64_sig, siglist);
	if(ret && handle.pm_errno == ALPM_ERR_SIG_MISSING) {
		if(optional) {
			logger.tracef("missing optional signature\n");
			handle.pm_errno = ALPM_ERR_OK;
			ret = 0;
		} else {
			logger.tracef("missing required signature\n");
			/* ret will already be -1 */
		}
	} else if(ret) {
		logger.tracef("signature check failed\n");
		/* ret will already be -1 */
	} else {
		size_t num = void;
		for(num = 0; !ret && num < siglist.count; num++) {
			switch(siglist.results[num].status) {
				case ALPM_SIGSTATUS_VALID:
				case ALPM_SIGSTATUS_KEY_EXPIRED:
					logger.tracef("signature is valid\n");
					switch(siglist.results[num].validity) {
						case ALPM_SIGVALIDITY_FULL:
							logger.tracef("signature is fully trusted\n");
							break;
						case ALPM_SIGVALIDITY_MARGINAL:
							logger.tracef("signature is marginal trust\n");
							if(!marginal) {
								ret = -1;
							}
							break;
						case ALPM_SIGVALIDITY_UNKNOWN:
							logger.tracef("signature is unknown trust\n");
							if(!unknown) {
								ret = -1;
							}
							break;
						case ALPM_SIGVALIDITY_NEVER:
							logger.tracef("signature should never be trusted\n");
							ret = -1;
							break;
					default: break;}
					break;
				case ALPM_SIGSTATUS_SIG_EXPIRED:
				case ALPM_SIGSTATUS_KEY_UNKNOWN:
				case ALPM_SIGSTATUS_KEY_DISABLED:
				case ALPM_SIGSTATUS_INVALID:
					logger.tracef("signature is not valid\n");
					ret = -1;
					break;
			default: break;}
		}
	}

	if(sigdata) {
		*sigdata = siglist;
	} else {
		alpm_siglist_cleanup(siglist);
		free(siglist);
	}

	return ret;
}

/**
 * Examine a signature result list and take any appropriate or necessary
 * actions. This may include asking the user to import a key or simply printing
 * helpful failure messages so the user can take action out of band.
 * @param handle the context handle
 * @param identifier a friendly name for the signed resource; usually a
 * database or package name
 * @param siglist a pointer to storage for signature results
 * @param optional whether signatures are optional (e.g., missing OK)
 * @param marginal whether signatures with marginal trust are acceptable
 * @param unknown whether signatures with unknown trust are acceptable
 * @return 0 if all signatures are OK, -1 on errors, 1 if we should retry the
 * validation process
 */
int _alpm_process_siglist(AlpmHandle handle,   char*identifier, alpm_siglist_t* siglist, int optional, int marginal, int unknown)
{
	size_t i = void;
	int retry = 0;

	if(!optional && siglist.count == 0) {
		_alpm_log(handle, ALPM_LOG_ERROR,
				("%s: missing required signature\n"), identifier);
	}

	for(i = 0; i < siglist.count; i++) {
		alpm_sigresult_t* result = siglist.results + i;
		  char*name = result.key.uid ? result.key.uid : result.key.fingerprint;
		switch(result.status) {
			case ALPM_SIGSTATUS_VALID:
				switch(result.validity) {
					case ALPM_SIGVALIDITY_FULL:
						break;
					case ALPM_SIGVALIDITY_MARGINAL:
						if(!marginal) {
							_alpm_log(handle, ALPM_LOG_ERROR,
									("%s: signature from \"%s\" is marginal trust\n"),
									identifier, name);
							/* QUESTION(handle, ALPM_QUESTION_EDIT_KEY_TRUST, &result->key, NULL, NULL, &answer); */
						}
						break;
					case ALPM_SIGVALIDITY_UNKNOWN:
						if(!unknown) {
							_alpm_log(handle, ALPM_LOG_ERROR,
									("%s: signature from \"%s\" is unknown trust\n"),
									identifier, name);
							/* QUESTION(handle, ALPM_QUESTION_EDIT_KEY_TRUST, &result->key, NULL, NULL, &answer); */
						}
						break;
					case ALPM_SIGVALIDITY_NEVER:
						_alpm_log(handle, ALPM_LOG_ERROR,
								("%s: signature from \"%s\" should never be trusted\n"),
								identifier, name);
						break;
				default: break;}
				break;
			case ALPM_SIGSTATUS_KEY_EXPIRED:
				_alpm_log(handle, ALPM_LOG_ERROR,
						("%s: signature from \"%s\" is expired\n"),
						identifier, name);

				if(_alpm_key_import(handle, result.key.uid, result.key.fingerprint) == 0) {
					retry = 1;
				}

				break;
			case ALPM_SIGSTATUS_KEY_UNKNOWN:
				/* ensure this key is still actually unknown; we may have imported it
				 * on an earlier call to this function. */
				if(_alpm_key_in_keychain(handle, result.key.fingerprint) == 1) {
					break;
				}
				_alpm_log(handle, ALPM_LOG_ERROR,
						("%s: key \"%s\" is unknown\n"), identifier, name);

				if(_alpm_key_import(handle, result.key.uid, result.key.fingerprint) == 0) {
					retry = 1;
				}

				break;
			case ALPM_SIGSTATUS_KEY_DISABLED:
				_alpm_log(handle, ALPM_LOG_ERROR,
						("%s: key \"%s\" is disabled\n"), identifier, name);
				break;
			case ALPM_SIGSTATUS_SIG_EXPIRED:
				_alpm_log(handle, ALPM_LOG_ERROR,
						("%s: signature from \"%s\" is expired\n"), identifier, name);
				break;
			case ALPM_SIGSTATUS_INVALID:
				_alpm_log(handle, ALPM_LOG_ERROR,
						("%s: signature from \"%s\" is invalid\n"),
						identifier, name);
				break;
		default: break;}
	}

	return retry;
}

int  alpm_pkg_check_pgp_signature(AlpmPkg pkg, alpm_siglist_t* siglist)
{
	//ASSERT(pkg != null);
	//ASSERT(siglist != null);
	AlpmHandle handle = cast(AlpmHandle)pkg.handle;
	handle.pm_errno = ALPM_ERR_OK;

	return _alpm_gpgme_checksig(pkg.handle, cast(char*)pkg.filename,
			cast(char*)pkg.base64_sig, siglist);
}

int  alpm_db_check_pgp_signature(AlpmDB db, alpm_siglist_t* siglist)
{
	//ASSERT(db != null);
	//ASSERT(siglist != null);
	db.handle.pm_errno = ALPM_ERR_OK;

	return _alpm_gpgme_checksig(db.handle, cast(char*)_alpm_db_path(db), null, siglist);
}

int  alpm_siglist_cleanup(alpm_siglist_t* siglist)
{
	//ASSERT(siglist != null);
	size_t num = void;
	for(num = 0; num < siglist.count; num++) {
		alpm_sigresult_t* result = siglist.results + num;
		if(result.key.data) {
version (HAVE_LIBGPGME) {
			gpgme_key_unref(result.key.data);
}
		} else {
			free(result.key.fingerprint);
		}
	}
	if(siglist.count) {
		free(siglist.results);
	}
	siglist.results = null;
	siglist.count = 0;
	return 0;
}

/* Check to avoid out of boundary reads */
private size_t length_check(size_t length, size_t position, size_t a, AlpmHandle handle,   char*identifier)
{
	if( a == 0 || position > length || length - position <= a) {
		_alpm_log(handle, ALPM_LOG_ERROR,
				("%s: signature format error\n"), identifier);
		return -1;
	} else {
		return 0;
	}
}

private int parse_subpacket(AlpmHandle handle,   char*identifier,  ubyte* sig,  size_t len,  size_t pos,  size_t plen, alpm_list_t** keys)
{
		size_t slen = void;
		size_t spos = pos;

		while(spos < pos + plen) {
			if(sig[spos] < 192) {
				slen = sig[spos];
				spos = spos + 1;
			} else if(sig[spos] < 255) {
				if(length_check(len, spos, 2, handle, identifier) != 0){
					return -1;
				}
				slen = ((sig[spos] - 192) << 8) + sig[spos + 1] + 192;
				spos = spos + 2;
			} else {
				if(length_check(len, spos, 5, handle, identifier) != 0) {
					return -1;
				}
				slen = (sig[spos + 1] << 24) | (sig[spos + 2] << 16) | (sig[spos + 3] << 8) | sig[spos + 4];
				spos = spos + 5;
			}
			if(sig[spos] == 16) {
				/* issuer key ID */
				char[17] key = void;
				size_t i = void;
				if(length_check(len, spos, 8, handle, identifier) != 0) {
					return -1;
				}
				for (i = 0; i < 8; i++) {
					snprintf(&key[i * 2], 3, "%02X", sig[spos + i + 1]);
				}
				*keys = alpm_list_add(*keys, strdup(key.ptr));
				break;
			}
			if(length_check(len, spos, slen, handle, identifier) != 0) {
				return -1;
			}
			spos = spos + slen;
		}
		return 0;
}

int  alpm_extract_keyid(AlpmHandle handle,   char*identifier,  ubyte* sig,  size_t len, alpm_list_t** keys)
{
	size_t pos = void, blen = void, hlen = void, ulen = void;
	pos = 0;

	while(pos < len) {
		if(!(sig[pos] & 0x80)) {
			_alpm_log(handle, ALPM_LOG_ERROR,
					("%s: signature format error\n"), identifier);
			return -1;
		}

		if(sig[pos] & 0x40) {
			/* new packet format */
			if(length_check(len, pos, 1, handle, identifier) != 0) {
				return -1;
			}
			pos = pos + 1;

			if(sig[pos] < 192) {
				if(length_check(len, pos, 1, handle, identifier) != 0) {
					return -1;
				}
				blen = sig[pos];
				pos = pos + 1;
			} else if (sig[pos] < 224) {
				if(length_check(len, pos, 2, handle, identifier) != 0) {
					return -1;
				}
				blen = ((sig[pos] - 192) << 8) + sig[pos + 1] + 192;
				pos = pos + 2;
			} else if (sig[pos] == 255) {
				if(length_check(len, pos, 5, handle, identifier)) {
					return -1;
				}
				blen = (sig[pos + 1] << 24) | (sig[pos + 2] << 16) | (sig[pos + 3] << 8) | sig[pos + 4];
				pos = pos + 5;
			} else {
				/* partial body length not supported */
				_alpm_log(handle, ALPM_LOG_ERROR,
					("%s: unsupported signature format\n"), identifier);
				return -1;
			}
		} else {
			/* old package format */
			switch(sig[pos] & 0x03) {
				case 0:
					if(length_check(len, pos, 2, handle, identifier) != 0) {
						return -1;
					}
					blen = sig[pos + 1];
					pos = pos + 2;
					break;

				case 1:
					if(length_check(len, pos, 3, handle, identifier) != 0) {
						return -1;
					}
					blen = (sig[pos + 1] << 8) | sig[pos + 2];
					pos = pos + 3;
					break;

				case 2:
					if(length_check(len, pos, 5, handle, identifier) != 0) {
						return -1;
					}
					blen = (sig[pos + 1] << 24) | (sig[pos + 2] << 16) | (sig[pos + 3] << 8) | sig[pos + 4];
					pos = pos + 5;
					break;

				case 3:
					/* partial body length not supported */
					_alpm_log(handle, ALPM_LOG_ERROR,
						("%s: unsupported signature format\n"), identifier);
					return -1;
			default: break;}
		}

		if(length_check(len, pos, 2, handle, identifier)) {
			return -1;
		}
		if(sig[pos] != 4) {
			/* only support version 4 signature packet format */
			_alpm_log(handle, ALPM_LOG_ERROR,
					("%s: unsupported signature format\n"), identifier);
			return -1;
		}
		if(sig[pos + 1] != 0x00) {
			/* not a signature of a binary document */
			_alpm_log(handle, ALPM_LOG_ERROR,
					("%s: signature format error\n"), identifier);
			return -1;
		}
		pos = pos + 4;

		/* pos got changed above, so an explicit check is necessary
		 * check for 2 as that catches another some lines down */
		if(length_check(len, pos, 2, handle, identifier)) {
			return -1;
		}
		hlen = (sig[pos] << 8) | sig[pos + 1];
		if(length_check(len, pos, hlen + 2, handle, identifier) != 0) {
			return -1;
		}
		pos = pos + 2;

		if(parse_subpacket(handle, identifier, sig, len, pos, hlen, keys) == -1) {
			return -1;
		}
		pos = pos + hlen;

		ulen = (sig[pos] << 8) | sig[pos + 1];
		if(length_check(len, pos, ulen + 2, handle, identifier) != 0) {
			return -1;
		}
		pos = pos + 2;

		if(parse_subpacket(handle, identifier, sig, len, pos, ulen, keys) == -1) {
			return -1;
		}
		pos = pos + (blen - hlen - 8);
	}

	return 0;
}
