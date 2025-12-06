module libalpmd.pkg.ops;

import ae.sys.install.common;

/** An enum over the kind of package operations. */
enum AlpmPackageOperationType {
	/** Package (to be) installed. (No oldpkg) */
	Install = 1,
	/** Package (to be) upgraded */
	Upgrade,
	/** Package (to be) re-installed */
	Reinstall,
	/** Package (to be) downgraded */
	Downgrade,
	/** Package (to be) removed (No newpkg) */
	Remove
}