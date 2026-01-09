module libalpmd.alpm_list.alpm_list_new;

import core.stdc.stdlib;

import std.container : DList;
import std.range;
import std.algorithm;
import std.functional: binaryFun;
import std.algorithm: sort, setDifference;
import std.conv;

///Alias for standart DList;
alias AlpmList(T) = DList!T;
alias AlpmStrings = DList!string;

auto alpmListDiff(alias fn = "a < b", List)(List lhs, List rhs) {
    auto left = lhs[].array.sort!fn.array;
    auto right = rhs[].array.sort!fn.array;
    
    auto diff = left.setDifference!fn(right).array;
    
    List result;
    foreach(item; diff) {
        result.insertBack(item);
    }
    return result;
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

int alpmListCmpUnsorted(T)(T left, T right) {
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
			static if(is(T : string)) {
				if(cmp(l, r) == 0) {
					found = 1;
					matched[n] = 1;
					break;
				}
			}
			else {
				if(l == r) {
					found = 1;
					matched[n] = 1;
					break;
				}
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