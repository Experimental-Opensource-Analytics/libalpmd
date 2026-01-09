module libalpmd.alpm_list.searching;

//Module, contains all searching funcs for AlpmList template instantiations
/*  //!NEED TO CONSOLIDATE IT
*   For that we must to realize opCmp and opEquals methods for most ALPM entity classes.
*   After that we can delete that module
*/
import std.algorithm;

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
bool isInConflicts(AlpmConflicts haystack, AlpmConflict needle) {
	return haystack[].canFind(needle);
}

/* trivial helper function for alpm_list_find_ptr */
private int ptr_cmp_n(void* p, void* q)
{
	return (p != q);
}

alias alpm_list_fn_cmp = int function( void*,  void*);

// void * alpmList_find_ptr_n(PL, Item = typeof(PL.front))(PL haystack, void* needle)
// {
// 	return alpmList_find_n(haystack, cast(Item)needle, &ptr_cmp_n);
// }