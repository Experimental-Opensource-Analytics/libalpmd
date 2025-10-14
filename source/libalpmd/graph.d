module graph.c;
@nogc nothrow:
extern(C): __gshared:
/*
 *  graph.c - helpful graph structure and setup/teardown methods
 *
 *  Copyright (c) 2007-2025 Pacman Development Team <pacman-dev@lists.archlinux.org>
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

import graph;
import util;
import log;

alpm_graph_t* _alpm_graph_new()
{
	alpm_graph_t* graph = null;

	CALLOC(graph, 1, alpm_graph_t.sizeof, return NULL);
	return graph;
}

void _alpm_graph_free(void* data)
{
	ASSERT(data != null, return);
	alpm_graph_t* graph = data;
	alpm_list_free(graph.children);
	free(graph);
}
