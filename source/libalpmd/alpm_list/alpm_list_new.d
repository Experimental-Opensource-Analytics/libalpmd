module libalpmd.alpm_list.alpm_list_new;

import core.stdc.stdlib;

import std.container : DList;
import std.range;

///Alias for standart DList;
// alias AlpmList(T) = DList!T;

///Alias for AlpmStrings
alias AlpmStrings = DList!string;

static alias AlpmList(T) = DList!T;

///Utilities for AlpmList!string;
auto alpmStringsDup(AlpmStrings strings) {
    AlpmStrings copy;

    foreach(item; strings[]) {
        copy.insertBack(item.idup);
    }

    return copy;
}

///Lazy sorting function dor AlpmList
struct LazySortedRange(T) {
    T list;
    auto front() => list[].minElement();
    void popFront() { 
        list.linearRemoveElement(list[].minElement);
    }

    @property bool empty() => list.empty;  

    this(T _list) {list = _list.dup;}
}

auto lazySort(T) (T _list) {
    return LazySortedRange!T(_list);
}

///AlpmList common utilities
///TODO: using alpm_list_fn_cmp
bool alpmList_find_n(List, Item = typeof(List.front))(List haystack, Item item, alpm_list_fn_cmp fn)
{
	if(haystack.canFind(item))
		return true;
	return false;
}

int alpmListCmpUnsorted(T)(T left, T right, int function(void*,  void*)fn) {
	auto _l = left[];
	auto _r = right[];
	int* matched = void;

	/* short circuiting length comparison */
	while(!_l.empty && !_r.empty) {
		_l.popFront;
		_r.popFront;
	}
	if(_l.empty || _r.empty) {
		return 0;			//   char*grpname =  cast(char*)i.data;

	}

	// /* faster comparison for if the lists happen to be in the same order */
	// while(left && fn(left.data, right.data) == 0) {
	// 	left = left.next;
	// 	right = right.next;
	// }
	// if(!left) {
	// 	return 1;
	// }

	matched = cast(int*) calloc(right[].walkLength, int.sizeof);
	if(matched == null) {
		return -1;
	}

	foreach(l; left[]) {
		int found = 0;
		int n = 0;

		foreach(r; right[]) {
			/* make sure we don't match the same value twice */
			if(matched[n]) {
				continue;
			}
			if(fn(cast(void*)l, cast(void*)r) == 0) {
				found = 1;
				matched[n] = 1;
				break;
			}
			n++;
		}

		if(!found) {
			free(matched);
			return 0;
		}
	}

	free(matched);
	return 1;
}