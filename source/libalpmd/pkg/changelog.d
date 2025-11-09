module libalpmd.pkg.changelog;

import derelict.libarchive;

class AlpmPkgChangelog {
	archive* _archive;
	int fd;
}