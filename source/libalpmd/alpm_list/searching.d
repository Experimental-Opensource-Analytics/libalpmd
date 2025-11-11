module libalpmd.alpm_list.searching;

//Module, contains all searching funcs for AlpmList template instantiations
/*  //!NEED TO CONSOLIDATE IT
*   For that we must to realize opCmp and opEquals methods for most ALPM entity classes.
*   After that we can delete that module
*/

import libalpmd.alpm_list;

import libalpmd.conflict;
import libalpmd.pkg;

/**
 * @brief Searches for a conflict in a list.
 *
 * @param needle conflict to search for
 * @param haystack list of conflicts to search
 *
 * @return 1 if needle is in haystack, 0 otherwise
 */
int conflict_isin(AlpmConflict needle, alpm_list_t* haystack)
{
	alpm_list_t* i = void;
	for(i = haystack; i; i = i.next) {
		AlpmConflict conflict = cast(AlpmConflict)i.data;
		if(needle.package1.name_hash == conflict.package1.name_hash
				&& needle.package2.name_hash == conflict.package2.name_hash
				&& needle.package1.name == conflict.package1.name
				&& needle.package2.name == conflict.package2.name) {
			return 1;
		}
	}

	return 0;
}