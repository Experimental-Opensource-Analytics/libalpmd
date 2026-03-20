module libalpmd.alpm_list.alpm_list_new;

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

///Lazy sorting function for AlpmList
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

int alpmListCmpUnsorted(R1, R2)(R1 left, R2 right) {
    auto rightElems = right.array;
    auto matched = new bool[rightElems.length];

    foreach (l; left) {
        bool found = false;
        foreach (i, ref r; rightElems) {
            if (!matched[i] && l == r) {
                matched[i] = true;
                found = true;
                break;
            }
        }
        if (!found)
            return 0; 
    }
    return 1;
}