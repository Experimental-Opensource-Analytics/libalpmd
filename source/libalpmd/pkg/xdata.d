module libalpmd.pkg.xdata;

import std.array;

struct AlpmPkgXData {
	string name;
	string value;

	void parse(string data) {
		string[] splited;
		if(data == "" || (splited = data.split('=')).length == 0) {
			return;
		}
		this.name = splited[0];
		this.value = splited[1];
	}

	static AlpmPkgXData parseTo(string data) {
		auto xdata = AlpmPkgXData();
		string[] splited;
		if(data == "" || (splited = data.split('=')).length == 0) {
			return AlpmPkgXData();
		}
		xdata.name = splited[0];
		xdata.value = splited[1];
		return xdata;
	}
}

alias AlpmXDataList = libalpmd.alpm_list.alpm_list_old.AlpmList!AlpmPkgXData;