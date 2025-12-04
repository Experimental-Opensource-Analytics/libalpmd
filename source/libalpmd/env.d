module libalpmd.env;

import core.stdc.stdlib;
import core.sys.posix.sys.stat;

import std.conv;
import derelict.libarchive.type;

static struct Environment {
    static mode_t  mode;
    static void  saveMask() {
        mode = umask(octal!"022");
    }

    static void restoreMask () {
        umask(mode);
    }

    static string getUserName() {
        return getenv("USER").to!string;
    }
}