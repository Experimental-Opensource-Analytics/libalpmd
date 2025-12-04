module libalpmd.event;

import core.sys.posix.sys.types;

class AlpmEvent {

}

class AlpmEventPkgRetriev : AlpmEvent {
    /** Number of packages to download */
    size_t num;
	/** Total size of packages to download */
	off_t total_size;
}