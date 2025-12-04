module libalpmd.alpm_list.alpm_list_new;

import core.stdc.stdlib;

import std.container : DList;
import std.range;
import std.algorithm;

import libalpmd.alpm_list.searching;

///Alias for standart DList;
// alias AlpmList(T) = DList!T;

alias AlpmStrings = DList!string;

auto alpmStringsDup(AlpmStrings strings) {
	AlpmStrings copy;

	foreach(item; strings[]) {
		copy.insertBack(item.idup);
	}

	return copy;
}

alias AlpmList(Item) = DList!Item;


// 	///Lazy sorting function dor AlpmList
// 	struct LazySortedRange(T) {
// 		T list;
// 		auto front() => list[].minElement();
// 		void popFront() { 
// 			list.linearRemoveElement(list[].minElement);
// 		}

// 		@property bool empty() => list.empty;  

// 		this(T _list) {list = _list.dup;}
// 	}

// 	auto lazySort(T) (T _list) {
// 		return LazySortedRange!T(_list);
// 	}

// 	void  alpm_new_list_free(List, T = typeof(List.front))(List list)
// 	{
// 		List it = list;

// 		while(it) {
// 			List tmp = it.next;
// 			free(it);
// 			it = tmp;
// 		}
// 	}

// 	void  alpm_new_list_free_inner(List list, alpm_new_list_fn_free fn)
// 	{
// 		List it = list;

// 		if(fn) {
// 			while(it) {
// 				if(it.data) {
// 					fn(it.data);
// 				}
// 				it = it.next;
// 			}
// 		}
// 	}


// 	/* Mutators */

List alpm_new_list_add(List, Item = typeof(List.front))(List list, Item data)
{
	alpm_new_list_append(list, cast(Item)data);
	return list;
}

auto alpm_new_list_append(List, Item = typeof(List.front))(List list, Item item) {
	list.insertFront(item);
	return list;
}

// 	List alpm_new_list_append_strdup(List list,   char*data)
// 	{
// 		List ret = void;
// 		char* dup = void;
// 		if(cast(bool)(dup = strdup(data)) && cast(bool)(ret = alpm_new_list_append(list, dup))) {
// 			return ret;
// 		} else {
// 			free(dup);
// 			return null;
// 		}
// 	}

// 	List alpm_new_list_add_sorted(List list, void* data, alpm_new_list_fn_cmp fn)
// 	{
// 		if(!fn || !list) {
// 			return alpm_new_list_add(list, data);
// 		} else {
// 			List add = null, prev = null, next = list;

// 			add = cast(alpm_new_list_t*) malloc(alpm_new_list_t.sizeof);
// 			if(add == null) {
// 				return list;
// 			}
// 			add.data = data;

// 			/* Find insertion point. */
// 			while(next) {
// 				if(fn(add.data, next.data) <= 0) break;
// 				prev = next;
// 				next = next.next;
// 			}

// 			/* Insert the add node to the list */
// 			if(prev == null) { /* special case: we insert add as the first element */
// 				add.prev = list.prev; /* list != NULL */
// 				add.next = list;
// 				list.prev = add;
// 				return add;
// 			} else if(next == null) { /* another special case: add last element */
// 				add.prev = prev;
// 				add.next = null;
// 				prev.next = add;
// 				list.prev = add;
// 				return list;
// 			} else {
// 				add.prev = prev;
// 				add.next = next;
// 				next.prev = add;
// 				prev.next = add;
// 				return list;
// 			}
// 		}
// 	}

// 	List alpm_new_list_join(List first, List second)
// 	{
// 		List tmp = void;

// 		if(first == null) {
// 			return second;
// 		}
// 		if(second == null) {
// 			return first;
// 		}
// 		/* tmp is the last element of the first list */
// 		tmp = first.prev;
// 		/* link the first list to the second */
// 		tmp.next = second;
// 		/* link the second list to the first */
// 		first.prev = second.prev;
// 		/* set the back reference to the tail */
// 		second.prev = tmp;

// 		return first;
// 	}

// 	List alpm_new_list_mmerge(List left, List right, alpm_new_list_fn_cmp fn)
// 	{
// 		List newlist = void, lp = void, tail_ptr = void, left_tail_ptr = void, right_tail_ptr = void;

// 		if(left == null) {
// 			return right;
// 		}
// 		if(right == null) {
// 			return left;
// 		}

// 		/* Save tail node pointers for future use */
// 		left_tail_ptr = left.prev;
// 		right_tail_ptr = right.prev;

// 		if(fn(left.data, right.data) <= 0) {
// 			newlist = left;
// 			left = left.next;
// 		}
// 		else {
// 			newlist = right;
// 			right = right.next;
// 		}
// 		newlist.prev = null;
// 		newlist.next = null;
// 		lp = newlist;

// 		while((left != null) && (right != null)) {
// 			if(fn(left.data, right.data) <= 0) {
// 				lp.next = left;
// 				left.prev = lp;
// 				left = left.next;
// 			}
// 			else {
// 				lp.next = right;
// 				right.prev = lp;
// 				right = right.next;
// 			}
// 			lp = lp.next;
// 			lp.next = null;
// 		}
// 		if(left != null) {
// 			lp.next = left;
// 			left.prev = lp;
// 			tail_ptr = left_tail_ptr;
// 		}
// 		else if(right != null) {
// 			lp.next = right;
// 			right.prev = lp;
// 			tail_ptr = right_tail_ptr;
// 		}
// 		else {
// 			tail_ptr = lp;
// 		}

// 		newlist.prev = tail_ptr;

// 		return newlist;
// 	}

// 	List alpm_new_list_msort(List list, size_t n, alpm_new_list_fn_cmp fn)
// 	{
// 		if(n > 1) {
// 			size_t half = n / 2;
// 			size_t i = half - 1;
// 			List left = list, lastleft = list, right = void;

// 			while(i--) {
// 				lastleft = lastleft.next;
// 			}
// 			right = lastleft.next;

// 			/* tidy new lists */
// 			lastleft.next = null;
// 			right.prev = left.prev;
// 			left.prev = lastleft;

// 			left = alpm_new_list_msort(left, half, fn);
// 			right = alpm_new_list_msort(right, n - half, fn);
// 			list = alpm_new_list_mmerge(left, right, fn);
// 		}
// 		return list;
// 	}

List alpm_new_list_remove_item(List)(List haystack, int n)
{
	haystack[].remove(n);
	return haystack;
}
/** item comparison callback */
// alias alpm_Item_fn_cmp = int function( void*,  void*);
List alpm_new_list_remove(List, Item = typeof(List.front))(List haystack, Item needle, alpm_list_fn_cmp fn, void** data)
{
	// List i = haystack;

	if(data) {
		*data = null;
	}

	if(needle is null) {
		return haystack;
	}
	int i = 0;
	foreach(stick; haystack[]) {

		// if(i.data == null) {
		// 	i = i.next;
		// 	continue;
		// }
		if(fn(cast(void*)stick, cast(void*)needle) == 0) {
			haystack = alpm_new_list_remove_item(haystack, i);

			if(data) {
				*data = &stick;
			}
			// free(i);
			break;
		}
		i++;
	}
	return haystack;	

}

	// List alpm_new_list_remove_str(List haystack, char* needle, char** data)
	// {
	// 	return alpm_new_list_remove(haystack, cast(void*)needle,
	// 			cast(alpm_new_list_fn_cmp)&strcmp, cast(void**)data);
	// }

// 	List alpm_new_list_remove_dupes(List list)
// 	{
// 		List lp = list;
// 		List newlist = null;
// 		while(lp) {
// 			if(!alpm_new_list_find_ptr(newlist, lp.data)) {
// 				if(alpm_new_list_append(&newlist, lp.data) == null) {
// 					alpm_new_list_free(newlist);
// 					return null;
// 				}
// 			}
// 			lp = lp.next;
// 		}
// 		return newlist;
// 	}

// 	List alpm_new_list_strdup(List list)
// 	{
// 		List lp = list;
// 		List newlist = null;
// 		while(lp) {
// 			if(alpm_new_list_append_strdup(&newlist, cast(  char*)lp.data) == null) {
// 				FREELIST(newlist);
// 				return null;
// 			}
// 			lp = lp.next;
// 		}
// 		return newlist;
// 	}

// 	List alpm_new_list_copy( List list)
// 	{
// 		List lp = list;
// 		List newlist = null;
// 		while(lp) {
// 			if(alpm_new_list_append(&newlist, lp.data) == null) {
// 				alpm_new_list_free(newlist);
// 				return null;
// 			}
// 			lp = lp.next;
// 		}
// 		return newlist;
// 	}

// 	List alpm_new_list_copy_data( List list, size_t size)
// 	{
// 		List lp = list;
// 		List newlist = null;
// 		while(lp) {
// 			void* newdata = malloc(size);
// 			if(newdata) {
// 				memcpy(newdata, lp.data, size);
// 				if(alpm_new_list_append(&newlist, newdata) == null) {
// 					free(newdata);
// 					FREELIST(newlist);
// 					return null;
// 				}
// 				lp = lp.next;
// 			} else {
// 				FREELIST(newlist);
// 				return null;
// 			}
// 		}
// 		return newlist;
// 	}

// 	List alpm_new_list_reverse(List list)
// 	{
// 		List lp = void;
// 		List newlist = null, backup = void;

// 		if(list == null) {
// 			return null;
// 		}

// 		lp = alpm_new_list_last(list);
// 		/* break our reverse circular list */
// 		backup = list.prev;
// 		list.prev = null;

// 		while(lp) {
// 			if(alpm_new_list_append(&newlist, lp.data) == null) {
// 				alpm_new_list_free(newlist);
// 				list.prev = backup;
// 				return null;
// 			}
// 			lp = lp.prev;
// 		}
// 		list.prev = backup; /* restore tail pointer */
// 		return newlist;
// 	}

// 	/* Accessors */

// 	List alpm_new_list_nth( List list, size_t n)
// 	{
// 		List i = list;
// 		while(n--) {
// 			i = i.next;
// 		}
// 		return cast(alpm_new_list_t*)i;
// 	}

// 	pragma(inline, true) List alpm_new_list_next(List node)
// 	{
// 		if(node) {
// 			return node.next;
// 		} else {
// 			return null;
// 		}
// 	}

// 	pragma(inline, true) List alpm_new_list_previous(List list)
// 	{
// 		if(list && list.prev.next) {
// 			return list.prev;
// 		} else {
// 			return null;
// 		}
// 	}

// 	List alpm_new_list_last(List list)
// 	{
// 		if(list) {
// 			return list.prev;
// 		} else {
// 			return null;
// 		}
// 	}

// 	/* Misc */

// 	size_t  alpm_new_list_count( List list)
// 	{
// 		size_t i = 0;
// 		List lp = list;
// 		while(lp) {
// 			++i;
// 			lp = lp.next;
// 		}
// 		return i;
// 	}

void * alpm_new_list_find(List)(List haystack, void* needle, alpm_list_fn_cmp fn)
{
	// List lp = haystack;
	foreach(stick; haystack[]){
		if(fn(cast(void*)stick, needle) == 0) {
			return cast(void*)stick;
		}
		// lp = lp.next;
	}

	return null;
}

	/* trivial helper function for alpm_new_list_find_ptr */
	private int ptr_cmp(void* p, void* q)
	{
		return (p != q);
	}

	void * alpm_new_list_find_ptr(List)(List haystack, void* needle)
	{
		return alpm_new_list_find(haystack, needle, &ptr_cmp);
	}

// 	char * alpm_new_list_find_str(List haystack, char* needle)
// 	{
// 		return cast(char*)alpm_new_list_find(haystack, cast(void*)needle,
// 				cast(alpm_new_list_fn_cmp)&strcmp);
// 	}

// 	int  alpm_new_list_cmp_unsorted( List left,  List right, alpm_new_list_fn_cmp fn)
// 	{
// 		List l = left;
// 		List r = right;
// 		int* matched = void;

// 		/* short circuiting length comparison */
// 		while(l && r) {
// 			l = l.next;
// 			r = r.next;
// 		}
// 		if(l || r) {
// 			return 0;
// 		}

// 		/* faster comparison for if the lists happen to be in the same order */
// 		while(left && fn(left.data, right.data) == 0) {
// 			left = left.next;
// 			right = right.next;
// 		}
// 		if(!left) {
// 			return 1;
// 		}

// 		matched = cast(int*) calloc(alpm_new_list_count(right), int.sizeof);
// 		if(matched == null) {
// 			return -1;
// 		}

// 		for(l = left; l; l = l.next) {
// 			int found = 0;
// 			int n = 0;

// 			for(r = right; r; r = r.next, n++) {
// 				/* make sure we don't match the same value twice */
// 				if(matched[n]) {
// 					continue;
// 				}
// 				if(fn(l.data, r.data) == 0) {
// 					found = 1;
// 					matched[n] = 1;
// 					break;
// 				}

// 			}

// 			if(!found) {
// 				free(matched);
// 				return 0;
// 			}
// 		}

// 		free(matched);
// 		return 1;
// 	}

// 	void  alpm_new_list_diff_sorted(List left, List right, alpm_new_list_fn_cmp fn, List onlyleft, List onlyright)
// 	{
// 		List l = left;
// 		List r = right;

// 		if(!onlyleft && !onlyright) {
// 			return;
// 		}

// 		while(l != null && r != null) {
// 			int cmp = fn(l.data, r.data);
// 			if(cmp < 0) {
// 				if(onlyleft) {
// 					*onlyleft = alpm_new_list_add(*onlyleft, l.data);
// 				}
// 				l = l.next;
// 			}
// 			else if(cmp > 0) {
// 				if(onlyright) {
// 					*onlyright = alpm_new_list_add(*onlyright, r.data);
// 				}
// 				r = r.next;
// 			} else {
// 				l = l.next;
// 				r = r.next;
// 			}
// 		}
// 		while(l != null) {
// 			if(onlyleft) {
// 				*onlyleft = alpm_new_list_add(*onlyleft, l.data);
// 			}
// 			l = l.next;
// 		}
// 		while(r != null) {
// 			if(onlyright) {
// 				*onlyright = alpm_new_list_add(*onlyright, r.data);
// 			}
// 			r = r.next;
// 		}
// 	}


// 	List alpm_new_list_diff(List lhs, List rhs, alpm_new_list_fn_cmp fn)
// 	{
// 		List left = void, right = void;
// 		List ret = null;

// 		left = alpm_new_list_copy(lhs);
// 		left = alpm_new_list_msort(left, alpm_new_list_count(left), fn);
// 		right = alpm_new_list_copy(rhs);
// 		right = alpm_new_list_msort(right, alpm_new_list_count(right), fn);

// 		alpm_new_list_diff_sorted(left, right, fn, &ret, null);

// 		alpm_new_list_free(left);
// 		alpm_new_list_free(right);
// 		return ret;
// 	}

// 	void * alpm_new_list_to_array( List list, size_t n, size_t size)
// 	{
// 		size_t i = void;
// 		List item = void;
// 		char* array = void;

// 		if(n == 0) {
// 			return null;
// 		}

// 		array = cast(char*) malloc(n * size);
// 		if(array == null) {
// 			return null;
// 		}
// 		for(i = 0, item = list; i < n && item; i++, item = item.next) {
// 			memcpy(array + i * size, item.data, size);
// 		}
// 		return array;
// 	}
// }
// }

// unittest {
// 	class A {
// 		int b;
// 	}
// }

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