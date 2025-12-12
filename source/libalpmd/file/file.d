module libalpmd.file.file;

import core.stdc.stdlib;
import core.stdc.stdio;
import core.stdc.string;
import core.stdc.limits;
import core.sys.posix.sys.stat;
import core.sys.posix.dirent;

/** File in a package */
struct AlpmFile {
		/** Name of the file */
		string name;
		/** Size of the file */
		off_t size;
		/** The file's permissions */
		mode_t mode;

	   	AlpmFile dup(){
			auto dest = AlpmFile();
			dest.name = this.name.idup;
			dest.size = this.size;
			dest.mode = this.mode;

			return dest;
		}
}
