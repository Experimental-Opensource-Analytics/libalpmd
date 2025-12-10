module libalpmd.graph;
@nogc  
   
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
import core.sys.posix.sys.types;

import libalpmd.graph;
import libalpmd.util;
import libalpmd.log;
import libalpmd.alpm_list;
import libalpmd.pkg;

import core.stdc.stdlib;

enum _alpm_graph_vertex_state {
	ALPM_GRAPH_STATE_UNPROCESSED,
	ALPM_GRAPH_STATE_PROCESSING,
	ALPM_GRAPH_STATE_PROCESSED
}
alias ALPM_GRAPH_STATE_UNPROCESSED = _alpm_graph_vertex_state.ALPM_GRAPH_STATE_UNPROCESSED;
alias ALPM_GRAPH_STATE_PROCESSING = _alpm_graph_vertex_state.ALPM_GRAPH_STATE_PROCESSING;
alias ALPM_GRAPH_STATE_PROCESSED = _alpm_graph_vertex_state.ALPM_GRAPH_STATE_PROCESSED;


class AlpmGraph(T) {
	T data;
	AlpmGraph!T 	parent; /* where did we come from? */
	AlpmGraphs	 	children;
	off_t weight; /* weight of the node */
	_alpm_graph_vertex_state state;
}

// alias _alpm_graph_t = alpm_graph_t;
alias AlpmGraphPkg = AlpmGraph!AlpmPkg;
alias AlpmGraphs = AlpmList!AlpmGraphPkg;

// alpm_graph_t* _alpm_graph_new()
// {
// 	alpm_graph_t* graph = null;

// 	CALLOC(graph, 1, alpm_graph_t.sizeof);
// 	return graph;
// }

// void _alpm_graph_free(void* data)
// {
// 	//ASSERT(data != null);
// 	alpm_graph_t* graph = cast(alpm_graph_t*)data;
// 	alpm_list_free(graph.children);
// 	free(graph);
// }
