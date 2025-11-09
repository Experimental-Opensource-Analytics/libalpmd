module libalpmd.consts;

import core.stdc.limits;

alias NAME_MAX = core.stdc.limits.NAME_MAX;
enum SYSHOOKDIR = "./hook/";
enum ALPM_HOOK_SUFFIX = "ALPM_HOOK";
enum SCRIPTLET_SHELL = "/bin/sh";
enum LDCONFIG = "/sbin/ldconfig";
