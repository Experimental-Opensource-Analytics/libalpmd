module alpm.c;
@nogc nothrow:
extern(C): __gshared:

import libalpmd.conf;
/*
 *  alpm.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *  Copyright (c) 2005 by Aurelien Foret <orelien@chez.com>
 *  Copyright (c) 2005 by Christian Hamar <krics@linuxforum.hu>
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

version (HAVE_LIBCURL) {
import curl/curl;
}

import core.stdc.errno;
import core.sys.posix.pwd;

/* libalpm */
import alpm;
import alpm_list;
import handle;
import log;
import util;

alpm_handle_t * alpm_initialize(const(char)* root, const(char)* dbpath, alpm_errno_t* err)
{
	alpm_errno_t myerr = void;
	const(char)* lf = "db.lck";
	char* hookdir = void;
	size_t hookdirlen = void, lockfilelen = void;
	const(passwd)* pw = null;
	alpm_handle_t* myhandle = _alpm_handle_new();

	if(myhandle == null) {
		goto nomem;
	}
	if((myerr = _alpm_set_directory_option(root, &(myhandle.root), 1))) {
		goto cleanup;
	}
	if((myerr = _alpm_set_directory_option(dbpath, &(myhandle.dbpath), 1))) {
		goto cleanup;
	}

	/* to concatenate myhandle->root (ends with a slash) with SYSHOOKDIR (starts
	 * with a slash) correctly, we skip SYSHOOKDIR[0]; the regular +1 therefore
	 * disappears from the allocation */
	hookdirlen = strlen(myhandle.root) + strlen(SYSHOOKDIR);
	MALLOC(hookdir, hookdirlen);
	snprintf(hookdir, hookdirlen, "%s%s", myhandle.root, &SYSHOOKDIR[1]);
	myhandle.hookdirs = alpm_list_add(null, hookdir);

	/* set default database extension */
	STRDUP(myhandle.dbext, ".db", goto nomem);

	lockfilelen = strlen(myhandle.dbpath) + strlen(lf) + 1;
	MALLOC(myhandle.lockfile, lockfilelen);
	snprintf(myhandle.lockfile, lockfilelen, "%s%s", myhandle.dbpath, lf);

	if(_alpm_db_register_local(myhandle) == null) {
		myerr = myhandle.pm_errno;
		goto cleanup;
	}

version (HAVE_LIBCURL) {
	curl_global_init(CURL_GLOBAL_ALL);
	myhandle.curlm = curl_multi_init();
}

	myhandle.parallel_downloads = 1;

	/* set default sandboxuser */
	ASSERT((pw = getpwuid(0)) != null, myerr = errno; goto cleanup);
	STRDUP(myhandle.sandboxuser, pw.pw_name);
	
version (ENABLE_NLS) {
	bindtextdomain("libalpm", LOCALEDIR);
}

	return myhandle;

nomem:
	myerr = ALPM_ERR_MEMORY;
cleanup:
	_alpm_handle_free(myhandle);
	if(err) {
		*err = myerr;
	}
	return null;
}

/* check current state and free all resources including storage locks */
int  alpm_release(alpm_handle_t* myhandle)
{
	CHECK_HANDLE(myhandle, return -1);
	ASSERT(myhandle.trans == null, RET_ERR(myhandle, ALPM_ERR_TRANS_NOT_NULL, -1));

	_alpm_handle_unlock(myhandle);
	_alpm_handle_free(myhandle);

	return 0;
}

const(char)* alpm_version()
{
	return LIB_VERSION;
}

int  alpm_capabilities()
{
	int capabilities = 0;
version(ENABLE_NLS) {
		capabilities |= ALPM_CAPABILITY_NLS;
}
//! #endif
version (HAVE_LIBCURL) {
		capabilities |= ALPM_CAPABILITY_DOWNLOADER;
}
version (HAVE_LIBGPGME) {
		capabilities |= ALPM_CAPABILITY_SIGNATURES;
}
		return capabilities;
}
