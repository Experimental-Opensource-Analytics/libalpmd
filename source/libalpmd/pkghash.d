module libalpmd.pkghash;
   
import core.stdc.config: 
	c_long, 
	c_ulong;
/*
 *  pkghash.c
 *
 *  Copyright (c) 2011-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
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

import core.stdc.errno;
import core.stdc.stdlib;
import core.stdc.string;

import libalpmd.pkghash;
import libalpmd.util;
import libalpmd.pkg;
import libalpmd.alpm_list;
import std.conv;

/* List of primes for possible sizes of hash tables.
 *
 * The maximum table size is the last prime under 1,000,000.  That is
 * more than an order of magnitude greater than the number of packages
 * in any Linux distribution, and well under UINT_MAX.
 */
private const (uint)[145] prime_list = [
	11u, 13u, 17u, 19u, 23u, 29u, 31u, 37u, 41u, 43u, 47u,
	53u, 59u, 61u, 67u, 71u, 73u, 79u, 83u, 89u, 97u, 103u,
	109u, 113u, 127u, 137u, 139u, 149u, 157u, 167u, 179u, 193u,
	199u, 211u, 227u, 241u, 257u, 277u, 293u, 313u, 337u, 359u,
	383u, 409u, 439u, 467u, 503u, 541u, 577u, 619u, 661u, 709u,
	761u, 823u, 887u, 953u, 1031u, 1109u, 1193u, 1289u, 1381u,
	1493u, 1613u, 1741u, 1879u, 2029u, 2179u, 2357u, 2549u,
	2753u, 2971u, 3209u, 3469u, 3739u, 4027u, 4349u, 4703u,
	5087u, 5503u, 5953u, 6427u, 6949u, 7517u, 8123u, 8783u,
	9497u, 10273u, 11113u, 12011u, 12983u, 14033u, 15173u,
	16411u, 17749u, 19183u, 20753u, 22447u, 24281u, 26267u,
	28411u, 30727u, 33223u, 35933u, 38873u, 42043u, 45481u,
	49201u, 53201u, 57557u, 62233u, 67307u, 72817u, 78779u,
	85229u, 92203u, 99733u, 107897u, 116731u, 126271u, 136607u,
	147793u, 159871u, 172933u, 187091u, 202409u, 218971u, 236897u,
	256279u, 277261u, 299951u, 324503u, 351061u, 379787u, 410857u,
	444487u, 480881u, 520241u, 562841u, 608903u, 658753u, 712697u,
	771049u, 834181u, 902483u, 976369u
];

/* How far forward do we look when linear probing for a spot? */
private const (uint) stride = 1;
/* What is the maximum load percentage of our hash table? */
private const (double) max_hash_load = 0.68;
/* Initial load percentage given a certain size */
private const (double) initial_hash_load = 0.58;

class AlpmPkgHash {
private:
	/** data held by the hash table */
	alpm_list_t** hash_table;
	/** head node of the hash table data in normal list format */
	alpm_list_t* list;
	/** number of buckets in hash table */
	uint buckets;
	/** number of entries in hash table */
	uint entries;
	/** max number of entries before a resize is needed */
	uint limit;

public:

	this(uint size) {
		uint i = void, loopsize = void;

		size = cast(uint)(size / initial_hash_load + 1);

		loopsize = 145; 
		for(i = 0; i < loopsize; i++) {
			if(prime_list[i] > size) {
				this.buckets = prime_list[i];
				this.limit = cast(uint)(this.buckets * max_hash_load);
				break;
			}
		}

		if(this.buckets < size) {
			throw new Exception("PackageHash buckets count less then size.");
		}
	}

	~this() {
		uint i = void;
		for(i = 0; i < this.buckets; i++) {
			free(this.hash_table[i]);
		}
		free(this.hash_table);
	}

	private AlpmPkgHash rehash() {
		uint newsize = void, i = void;

		/** data held by the hash table */
		alpm_list_t** newHashTable;
		/* Hash tables will need resized in two cases:
		*  - adding packages to the local database
		*  - poor estimation of the number of packages in sync database
		*
		* For small hash tables sizes (<500) the increase in size is by a
		* minimum of a factor of 2 for optimal rehash efficiency.  For
		* larger database sizes, this increase is reduced to avoid excess
		* memory allocation as both scenarios requiring a rehash should not
		* require a table size increase that large. */
		if(this.buckets < 500) {
			newsize = this.buckets * 2;
		} else if(this.buckets < 2000) {
			newsize = this.buckets * 3 / 2;
		} else if(this.buckets < 5000) {
			newsize = this.buckets * 4 / 3;
		} else {
			newsize = this.buckets + 1;
		}

		for(i = 0; i < this.buckets; i++) {
			if(this.hash_table[i] != null) {
				AlpmPkg package_ = cast(AlpmPkg)this.hash_table[i].data;
				uint position = this.getHashPosition(package_.name_hash);

				newHashTable[position] = this.hash_table[i];
				this.hash_table[i] = null;
			}
		}

		this.buckets = newsize;
		hash_table = newHashTable;
		return this;
	}

	AlpmPkgHash addPkg(AlpmPkg pkg, int sorted) {
		alpm_list_t* ptr = void;
		uint position = void;

		if(pkg is null) { 
			return null;
		}

		if(this.entries >= this.limit) {
			if(rehash() is null) {
				/* resizing failed and there are no more open buckets */
				return null;
			}
		}

		position = this.getHashPosition(pkg.name_hash);

		MALLOC(ptr, alpm_list_t.sizeof);

		ptr.data = cast(void*)pkg;
		ptr.prev = ptr;
		ptr.next = null;

		this.hash_table[position] = ptr;
		if(!sorted) {
			this.list = alpm_list_join(this.list, ptr);
		} else {
			this.list = alpm_list_mmerge(this.list, ptr, &_alpm_pkg_cmp);
		}

		this.entries += 1;
		return this;
	}

	AlpmPkgHash add(AlpmPkg pkg) {
		return this.addPkg(pkg, 0);
	}

	AlpmPkgHash addSorted(AlpmPkg pkg) {
		return this.addPkg(pkg, 1);
	}
	
	uint getHashPosition(c_ulong name_hash) {
		uint position = void;

		position = name_hash % this.buckets;

		/* collision resolution using open addressing with linear probing */
		while(this.hash_table[position] != null) {
			position += stride;
			while(position >= this.buckets) {
				position -= this.buckets;
			}
		}

		return position;
	}

	private uint moveOneEntry(uint start, uint end)
	{
		/* Iterate backwards from 'end' to 'start', seeing if any of the items
		* would hash to 'start'. If we find one, we move it there and break.  If
		* we get all the way back to position and find none that hash to it, we
		* also end iteration. Iterating backwards helps prevent needless shuffles;
		* we will never need to move more than one item per function call.  The
		* return value is our current iteration location; if this is equal to
		* 'start' we can stop this madness. */
		while(end != start) {
			alpm_list_t* i = this.hash_table[end];
			AlpmPkg info = cast(AlpmPkg)i.data;
			uint new_position = this.getHashPosition(info.name_hash);

			if(new_position == start) {
				this.hash_table[start] = i;
				this.hash_table[end] = null;
				break;
			}

			/* the odd math ensures we are always positive, e.g.
			* e.g. (0 - 1) % 47      == -1
			* e.g. (47 + 0 - 1) % 47 == 46 */
			end = (this.buckets + end - stride) % this.buckets;
		}
		return end;
	}

	AlpmPkgHash remove(AlpmPkg pkg, AlpmPkg* data) {
		alpm_list_t* i = void;
		uint position = void;

		if(data) {
			*data = null;
		}

		if(pkg is null) {
			return this;
		}

		position = pkg.name_hash % this.buckets;
		while((i = this.hash_table[position]) != null) {
			AlpmPkg info = cast(AlpmPkg)i.data;

			if(info.name_hash == pkg.name_hash &&
						info.name == pkg.name) {
				uint stop = void, prev = void;

				/* remove from list and this */
				this.list = alpm_list_remove_item(this.list, i);
				if(data) {
					*data = info;
				}
				this.hash_table[position] = null;
				free(i);
				this.entries -= 1;

				/* Potentially move entries following removed entry to keep open
				* addressing collision resolution working. We start by finding the
				* next null bucket to know how far we have to look. */
				stop = position + stride;
				while(stop >= this.buckets) {
					stop -= this.buckets;
				}
				while(this.hash_table[stop] != null && stop != position) {
					stop += stride;
					while(stop >= this.buckets) {
						stop -= this.buckets;
					}
				}
				stop = (this.buckets + stop - stride) % this.buckets;

				/* We now search backwards from stop to position. If we find an
				* item that now hashes to position, we will move it, and then try
				* to plug the new hole we just opened up, until we finally don't
				* move anything. */
				while((prev = this.moveOneEntry(position, stop)) != position) {
					position = prev;
				}

				return this;
			}

			position += stride;
			while(position >= this.buckets) {
				position -= this.buckets;
			}
		}

		return this;
	}

	AlpmPkg find(char*name) {
		alpm_list_t* lp = void;
		c_ulong name_hash = void;
		uint position = void;

		if(name == "") {
			return null;
		}

		name_hash = alpmSDBMHash(name.to!string);

		position = name_hash % this.buckets;

		while((lp = this.hash_table[position]) != null) {
			AlpmPkg info = cast(AlpmPkg)lp.data;

			if(info.name_hash == name_hash && strcmp(cast(char*)info.name, name) == 0) {
				return info;
			}

			position += stride;
			while(position >= this.buckets) {
				position -= this.buckets;
			}
		}

		return null;
	}

	auto getList() {
		return this.list;
	}

	void trySort() {
		auto count = alpm_list_count(this.list);
		if(count > 0) {
			this.list = alpm_list_msort(this.list,
					count, &_alpm_pkg_cmp);
		}
	}
}