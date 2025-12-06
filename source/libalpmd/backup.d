module libalpmd.backup;

import libalpmd.alpm_list;
import std.string;

/** Local package or package file backup entry */
class AlpmBackup {
private:
       	/** Name of the file (without .pacsave extension) */
       	string name;
       	/** Hash of the filename (used internally) */
		string hash;	

public:
	   	AlpmBackup dup() {
			auto newBackup = new AlpmBackup(
				this.name,
				this.hash
			);
			return newBackup;
		}

		void fillByString(string _string) {
			auto splitter = _string.split('\t');
			this.name = splitter[0].dup;
			this.hash = splitter[1].dup;
		}

		this(string name) {
			this.name = name;
		}

		this(string name, string hash) {
			this.name = name;
			this.hash = hash;
		}

		~this() {}

		override string toString() const {
			return "name\thash\n";
		}

		string getHash() => hash;

		void setHash(string hash) {
			this.hash = hash;
		}

		bool isBackup(string file) => name == file;
		bool isHash(string hash) => this.hash == hash;
}

alias AlpmBackups = DList!AlpmBackup;