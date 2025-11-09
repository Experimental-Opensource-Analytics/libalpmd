module libalpmd.pkg.xdata;

struct AlpmPkgXData {
	string name;
	string value;
}

alias AlpmXDataList = libalpmd.alpm_list.alpm_list_old.AlpmList!AlpmPkgXData;