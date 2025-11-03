module libalpmd.alpm_list;
// @nogc  
//    
/*
 *  alpm_list.c
 *
 *  Copyright (c) 2006-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
 *  Copyright (c) 2002-2006 by Judd Vinet <jvinet@zeroflux.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import core.stdc.stdlib;
import core.stdc.string;

import std.conv; 

alias AlpmStringList = AlpmList!string;

class AlpmList(T) {
	alias IT = T;
	IT data;
	AlpmList!IT prev;
	AlpmList!IT next;
}

auto toInputRange(List)(List list) {
	struct Range {
		List current;

		List front() => current;
		void popFront() { current = current.next;}
		bool empty() => current is null;
	}

	return Range(list);
}

AlpmStringList alpmList_strdup(AlpmStringList list) {
	auto lp = list;
	AlpmStringList newlist = null;
	foreach(line; lp.toInputRange) {
		if(alpmList_append_strdup(&newlist, lp.data) is null) {
			// FREELIST(newlist);
			return null;
		}
		// lp = lp.next;
	}
	return newlist;
}

AlpmStringList alpmList_append_strdup(AlpmStringList* list, string data) {
	AlpmStringList ret = void;
	string dup = void;
	if((dup = data.idup) != "" && (ret = alpmList_append(list, dup)) !is null) {
		return ret;
	} else {
		// free(dup);
		return null;
	}
}

List alpmList_add(List, IT = List.IT)(List list, IT data)
{
	alpmList_append(&list, data);
	return list;
}

List alpmList_append(List, IT = List.IT)(List* list, IT data)
{
	List ptr = new List;

	ptr.data = data;
	ptr.next = null;

	/* Special case: the input list is empty */
	if(*list is null) {
		*list = ptr;
		ptr.prev = ptr;
	} else {
		List lp = alpmList_last(*list);
		lp.next = ptr;
		ptr.prev = lp;
		(*list).prev = ptr;
	}

	return ptr;
}

List alpmList_last(List)(List list)
{
	if(list) {
		return list.prev;
	} else {
		return null;
	}
}

List alpmList_remove(List, IT = List.IT)(List haystack, IT needle, alpm_list_fn_cmp fn, void** data)
{
	List i = haystack;

	if(data) {
		(*data) = null;
	}

	if(needle is null) {
		return haystack;
	}

	while(i) {
		if(i.data is null) {
			i = i.next;
			continue;
		}
		if(fn(cast(void*)i.data, cast(void*)needle) == 0) {
			haystack = alpmList_remove_item(haystack, i);

			if(data) {
				*data = cast(void*)i.data;
			}
			// free(i);
			break;
		} else {
			i = i.next;
		}
	}

	return haystack;
}

List alpmList_remove_item(List, IT = List.IT)(List haystack, List item)
{
	if(item.prev) {
		item.prev.next = item.next;
	} else {
		haystack = item.next;
	}

	if(item.next) {
		item.next.prev = item.prev;
	} else {
		haystack.prev = item.prev;
	}

	return haystack;
}

void * alpmList_find(List, IT = List.IT)(alpm_list_t* haystack, void* needle)
{
	alpm_list_t* lp = haystack;
	while(lp) {
		if(lp.data && lp.data != null && lp.data == needle) {
			return lp.data;
		}
		lp = lp.next;
	}
	return null;
}

struct _alpm_list_t {
	/** data held by the list node */
	void* data;
	/** pointer to the previous node */
	_alpm_list_t* prev;
	/** pointer to the next node */
	_alpm_list_t* next;
}

void FREELIST(T)(T p) {
	 alpm_list_free_inner(p, cast(alpm_list_fn_free)&free);
	 alpm_list_free(p);
	  p = null; 
}

alias alpm_list_t = _alpm_list_t;  

alias alpm_list_fn_free = void function(void* item);

/** item comparison callback */
alias alpm_list_fn_cmp = int function( void*,  void*);

void  alpm_list_free(alpm_list_t* list)
{
	alpm_list_t* it = list;

	while(it) {
		alpm_list_t* tmp = it.next;
		free(it);
		it = tmp;
	}
}

void  alpm_list_free_inner(alpm_list_t* list, alpm_list_fn_free fn)
{
	alpm_list_t* it = list;

	if(fn) {
		while(it) {
			if(it.data) {
				fn(it.data);
			}
			it = it.next;
		}
	}
}


/* Mutators */

alpm_list_t * alpm_list_add(alpm_list_t* list, void* data)
{
	alpm_list_append(&list, data);
	return list;
}

alpm_list_t * alpm_list_append(alpm_list_t** list,   void* data)
{
	alpm_list_t* ptr = void;

	ptr = cast(alpm_list_t*) malloc(alpm_list_t.sizeof);
	if(ptr == null) {
		return null;
	}

	ptr.data = cast(void*)data;
	ptr.next = null;

	/* Special case: the input list is empty */
	if(*list == null) {
		*list = ptr;
		ptr.prev = ptr;
	} else {
		alpm_list_t* lp = alpm_list_last(*list);
		lp.next = ptr;
		ptr.prev = lp;
		(*list).prev = ptr;
	}

	return ptr;
}

alpm_list_t * alpm_list_append_strdup(alpm_list_t** list,   char*data)
{
	alpm_list_t* ret = void;
	char* dup = void;
	if(cast(bool)(dup = strdup(data)) && cast(bool)(ret = alpm_list_append(list, dup))) {
		return ret;
	} else {
		free(dup);
		return null;
	}
}

alpm_list_t * alpm_list_add_sorted(alpm_list_t* list, void* data, alpm_list_fn_cmp fn)
{
	if(!fn || !list) {
		return alpm_list_add(list, data);
	} else {
		alpm_list_t* add = null, prev = null, next = list;

		add = cast(alpm_list_t*) malloc(alpm_list_t.sizeof);
		if(add == null) {
			return list;
		}
		add.data = data;

		/* Find insertion point. */
		while(next) {
			if(fn(add.data, next.data) <= 0) break;
			prev = next;
			next = next.next;
		}

		/* Insert the add node to the list */
		if(prev == null) { /* special case: we insert add as the first element */
			add.prev = list.prev; /* list != NULL */
			add.next = list;
			list.prev = add;
			return add;
		} else if(next == null) { /* another special case: add last element */
			add.prev = prev;
			add.next = null;
			prev.next = add;
			list.prev = add;
			return list;
		} else {
			add.prev = prev;
			add.next = next;
			next.prev = add;
			prev.next = add;
			return list;
		}
	}
}

alpm_list_t * alpm_list_join(alpm_list_t* first, alpm_list_t* second)
{
	alpm_list_t* tmp = void;

	if(first == null) {
		return second;
	}
	if(second == null) {
		return first;
	}
	/* tmp is the last element of the first list */
	tmp = first.prev;
	/* link the first list to the second */
	tmp.next = second;
	/* link the second list to the first */
	first.prev = second.prev;
	/* set the back reference to the tail */
	second.prev = tmp;

	return first;
}

alpm_list_t * alpm_list_mmerge(alpm_list_t* left, alpm_list_t* right, alpm_list_fn_cmp fn)
{
	alpm_list_t* newlist = void, lp = void, tail_ptr = void, left_tail_ptr = void, right_tail_ptr = void;

	if(left == null) {
		return right;
	}
	if(right == null) {
		return left;
	}

	/* Save tail node pointers for future use */
	left_tail_ptr = left.prev;
	right_tail_ptr = right.prev;

	if(fn(left.data, right.data) <= 0) {
		newlist = left;
		left = left.next;
	}
	else {
		newlist = right;
		right = right.next;
	}
	newlist.prev = null;
	newlist.next = null;
	lp = newlist;

	while((left != null) && (right != null)) {
		if(fn(left.data, right.data) <= 0) {
			lp.next = left;
			left.prev = lp;
			left = left.next;
		}
		else {
			lp.next = right;
			right.prev = lp;
			right = right.next;
		}
		lp = lp.next;
		lp.next = null;
	}
	if(left != null) {
		lp.next = left;
		left.prev = lp;
		tail_ptr = left_tail_ptr;
	}
	else if(right != null) {
		lp.next = right;
		right.prev = lp;
		tail_ptr = right_tail_ptr;
	}
	else {
		tail_ptr = lp;
	}

	newlist.prev = tail_ptr;

	return newlist;
}

alpm_list_t * alpm_list_msort(alpm_list_t* list, size_t n, alpm_list_fn_cmp fn)
{
	if(n > 1) {
		size_t half = n / 2;
		size_t i = half - 1;
		alpm_list_t* left = list, lastleft = list, right = void;

		while(i--) {
			lastleft = lastleft.next;
		}
		right = lastleft.next;

		/* tidy new lists */
		lastleft.next = null;
		right.prev = left.prev;
		left.prev = lastleft;

		left = alpm_list_msort(left, half, fn);
		right = alpm_list_msort(right, n - half, fn);
		list = alpm_list_mmerge(left, right, fn);
	}
	return list;
}

alpm_list_t * alpm_list_remove_item(alpm_list_t* haystack, alpm_list_t* item)
{
	if(haystack == null || item == null) {
		return haystack;
	}

	if(item == haystack) {
		/* Special case: removing the head node which has a back reference to
		 * the tail node */
		haystack = item.next;
		if(haystack) {
			haystack.prev = item.prev;
		}
		item.prev = null;
	} else if(item == haystack.prev) {
		/* Special case: removing the tail node, so we need to fix the back
		 * reference on the head node. We also know tail != head. */
		if(item.prev) {
			/* i->next should always be null */
			item.prev.next = item.next;
			haystack.prev = item.prev;
			item.prev = null;
		}
	} else {
		/* Normal case, non-head and non-tail node */
		if(item.next) {
			item.next.prev = item.prev;
		}
		if(item.prev) {
			item.prev.next = item.next;
		}
	}

	return haystack;
}

alpm_list_t * alpm_list_remove(alpm_list_t* haystack, void* needle, alpm_list_fn_cmp fn, void** data)
{
	alpm_list_t* i = haystack;

	if(data) {
		*data = null;
	}

	if(needle == null) {
		return haystack;
	}

	while(i) {
		if(i.data == null) {
			i = i.next;
			continue;
		}
		if(fn(i.data, needle) == 0) {
			haystack = alpm_list_remove_item(haystack, i);

			if(data) {
				*data = i.data;
			}
			free(i);
			break;
		} else {
			i = i.next;
		}
	}

	return haystack;
}

alpm_list_t * alpm_list_remove_str(alpm_list_t* haystack, char* needle, char** data)
{
	return alpm_list_remove(haystack, cast(void*)needle,
			cast(alpm_list_fn_cmp)&strcmp, cast(void**)data);
}

alpm_list_t * alpm_list_remove_dupes(alpm_list_t* list)
{
	alpm_list_t* lp = list;
	alpm_list_t* newlist = null;
	while(lp) {
		if(!alpm_list_find_ptr(newlist, lp.data)) {
			if(alpm_list_append(&newlist, lp.data) == null) {
				alpm_list_free(newlist);
				return null;
			}
		}
		lp = lp.next;
	}
	return newlist;
}

alpm_list_t * alpm_list_strdup(alpm_list_t* list)
{
	 alpm_list_t* lp = list;
	alpm_list_t* newlist = null;
	while(lp) {
		if(alpm_list_append_strdup(&newlist, cast(  char*)lp.data) == null) {
			FREELIST(newlist);
			return null;
		}
		lp = lp.next;
	}
	return newlist;
}

alpm_list_t * alpm_list_copy( alpm_list_t* list)
{
	 alpm_list_t* lp = list;
	alpm_list_t* newlist = null;
	while(lp) {
		if(alpm_list_append(&newlist, lp.data) == null) {
			alpm_list_free(newlist);
			return null;
		}
		lp = lp.next;
	}
	return newlist;
}

alpm_list_t * alpm_list_copy_data( alpm_list_t* list, size_t size)
{
	 alpm_list_t* lp = list;
	alpm_list_t* newlist = null;
	while(lp) {
		void* newdata = malloc(size);
		if(newdata) {
			memcpy(newdata, lp.data, size);
			if(alpm_list_append(&newlist, newdata) == null) {
				free(newdata);
				FREELIST(newlist);
				return null;
			}
			lp = lp.next;
		} else {
			FREELIST(newlist);
			return null;
		}
	}
	return newlist;
}

alpm_list_t * alpm_list_reverse(alpm_list_t* list)
{
	 alpm_list_t* lp = void;
	alpm_list_t* newlist = null, backup = void;

	if(list == null) {
		return null;
	}

	lp = alpm_list_last(list);
	/* break our reverse circular list */
	backup = list.prev;
	list.prev = null;

	while(lp) {
		if(alpm_list_append(&newlist, lp.data) == null) {
			alpm_list_free(newlist);
			list.prev = backup;
			return null;
		}
		lp = lp.prev;
	}
	list.prev = backup; /* restore tail pointer */
	return newlist;
}

/* Accessors */

alpm_list_t * alpm_list_nth( alpm_list_t* list, size_t n)
{
	 alpm_list_t* i = list;
	while(n--) {
		i = i.next;
	}
	return cast(alpm_list_t*)i;
}

pragma(inline, true) alpm_list_t* alpm_list_next(alpm_list_t* node)
{
	if(node) {
		return node.next;
	} else {
		return null;
	}
}

pragma(inline, true) alpm_list_t* alpm_list_previous(alpm_list_t* list)
{
	if(list && list.prev.next) {
		return list.prev;
	} else {
		return null;
	}
}

alpm_list_t * alpm_list_last(alpm_list_t* list)
{
	if(list) {
		return list.prev;
	} else {
		return null;
	}
}

/* Misc */

size_t  alpm_list_count( alpm_list_t* list)
{
	size_t i = 0;
	 alpm_list_t* lp = list;
	while(lp) {
		++i;
		lp = lp.next;
	}
	return i;
}

void * alpm_list_find(alpm_list_t* haystack, void* needle, alpm_list_fn_cmp fn)
{
	alpm_list_t* lp = haystack;
	while(lp) {
		if(lp.data && fn(lp.data, needle) == 0) {
			return lp.data;
		}
		lp = lp.next;
	}
	return null;
}

/* trivial helper function for alpm_list_find_ptr */
private int ptr_cmp(void* p, void* q)
{
	return (p != q);
}

void * alpm_list_find_ptr(alpm_list_t* haystack, void* needle)
{
	return alpm_list_find(haystack, needle, &ptr_cmp);
}

char * alpm_list_find_str(alpm_list_t* haystack, char* needle)
{
	return cast(char*)alpm_list_find(haystack, cast(void*)needle,
			cast(alpm_list_fn_cmp)&strcmp);
}

int  alpm_list_cmp_unsorted( alpm_list_t* left,  alpm_list_t* right, alpm_list_fn_cmp fn)
{
	 alpm_list_t* l = left;
	 alpm_list_t* r = right;
	int* matched = void;

	/* short circuiting length comparison */
	while(l && r) {
		l = l.next;
		r = r.next;
	}
	if(l || r) {
		return 0;
	}

	/* faster comparison for if the lists happen to be in the same order */
	while(left && fn(left.data, right.data) == 0) {
		left = left.next;
		right = right.next;
	}
	if(!left) {
		return 1;
	}

	matched = cast(int*) calloc(alpm_list_count(right), int.sizeof);
	if(matched == null) {
		return -1;
	}

	for(l = left; l; l = l.next) {
		int found = 0;
		int n = 0;

		for(r = right; r; r = r.next, n++) {
			/* make sure we don't match the same value twice */
			if(matched[n]) {
				continue;
			}
			if(fn(l.data, r.data) == 0) {
				found = 1;
				matched[n] = 1;
				break;
			}

		}

		if(!found) {
			free(matched);
			return 0;
		}
	}

	free(matched);
	return 1;
}

void  alpm_list_diff_sorted(alpm_list_t* left, alpm_list_t* right, alpm_list_fn_cmp fn, alpm_list_t** onlyleft, alpm_list_t** onlyright)
{
	alpm_list_t* l = left;
	alpm_list_t* r = right;

	if(!onlyleft && !onlyright) {
		return;
	}

	while(l != null && r != null) {
		int cmp = fn(l.data, r.data);
		if(cmp < 0) {
			if(onlyleft) {
				*onlyleft = alpm_list_add(*onlyleft, l.data);
			}
			l = l.next;
		}
		else if(cmp > 0) {
			if(onlyright) {
				*onlyright = alpm_list_add(*onlyright, r.data);
			}
			r = r.next;
		} else {
			l = l.next;
			r = r.next;
		}
	}
	while(l != null) {
		if(onlyleft) {
			*onlyleft = alpm_list_add(*onlyleft, l.data);
		}
		l = l.next;
	}
	while(r != null) {
		if(onlyright) {
			*onlyright = alpm_list_add(*onlyright, r.data);
		}
		r = r.next;
	}
}


alpm_list_t * alpm_list_diff(alpm_list_t* lhs, alpm_list_t* rhs, alpm_list_fn_cmp fn)
{
	alpm_list_t* left = void, right = void;
	alpm_list_t* ret = null;

	left = alpm_list_copy(lhs);
	left = alpm_list_msort(left, alpm_list_count(left), fn);
	right = alpm_list_copy(rhs);
	right = alpm_list_msort(right, alpm_list_count(right), fn);

	alpm_list_diff_sorted(left, right, fn, &ret, null);

	alpm_list_free(left);
	alpm_list_free(right);
	return ret;
}

void * alpm_list_to_array( alpm_list_t* list, size_t n, size_t size)
{
	size_t i = void;
	 alpm_list_t* item = void;
	char* array = void;

	if(n == 0) {
		return null;
	}

	array = cast(char*) malloc(n * size);
	if(array == null) {
		return null;
	}
	for(i = 0, item = list; i < n && item; i++, item = item.next) {
		memcpy(array + i * size, item.data, size);
	}
	return array;
}
