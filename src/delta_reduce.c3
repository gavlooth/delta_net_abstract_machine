module delta_net_abstract_machine;

import std::collections::list;

const usz DELTA_MAX_INTERACTIONS = 10_000_000;
const usz DELTA_MAX_TRAVERSAL_DEPTH = 1_000_000;

struct DeltaReductionResult
{
	Allocator allocator;
	usz reductions;
	usz canonical_rewrites;
	DeltaDiagnostic[] diagnostics;
}

fn bool DeltaReductionResult.ok(&self) => self.diagnostics.len == 0;

fn void DeltaReductionResult.deinit(&self)
{
	if (!self.allocator) return;
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

struct DeltaReduceState
{
	Allocator allocator;
	Net* net;
	NetRef root;
	bool failed;
	DeltaDiagnostic diagnostic;
}

fn void delta_reduce_fail(DeltaReduceState* state, String message) @private
{
	if (state.failed) return;
	state.failed = true;
	state.diagnostic.init(state.allocator, message);
}

fn bool delta_port_is_eraser(Net* net, NetRef port_ref, NetRef* node_ref) @private
{
	if (!net.ports.contains_ref(port_ref)) return false;
	Port* port = net.ports.get_ref(port_ref);
	if (port.slot.type != PRINCIPAL || !net.nodes.contains_ref(port.node_id)) return false;
	Node* node = net.nodes.get_ref(port.node_id);
	if (node.type != ERASER || node.agent.eraser.principal != port_ref) return false;
	*node_ref = port.node_id;
	return true;
}

fn bool delta_decay_replicator(DeltaReduceState* state, NetRef node_ref) @private
{
	Net* net = state.net;
	if (!net.nodes.contains_ref(node_ref)) return false;
	Node* node = net.nodes.get_ref(node_ref);
	if (node.type != REPLICATOR || node.agent.replicator.status != UNPAIRED
		|| node.agent.replicator.observable) return false;
	NetRef principal = node.agent.replicator.principal;
	NetRef[] old_auxiliaries = node.agent.replicator.auxiliaries;
	List{NetRef} kept;
	kept.init(state.allocator, (sz)old_auxiliaries.len);
	bool dropped = false;

	foreach (auxiliary : old_auxiliaries)
	{
		if (!net.ports.contains_ref(auxiliary))
		{
			kept.free();
			delta_reduce_fail(state, "unpaired replicator contains a stale auxiliary");
			return false;
		}
		Port* auxiliary_port = net.ports.get_ref(auxiliary);
		if (!net.wires.contains_ref(auxiliary_port.wire_id))
		{
			kept.free();
			delta_reduce_fail(state, "unpaired replicator contains a disconnected auxiliary");
			return false;
		}
		NetRef other = other_endpoint(net, auxiliary_port.wire_id, auxiliary);
		NetRef eraser_node;
		if (!delta_port_is_eraser(net, other, &eraser_node))
		{
			kept.push(auxiliary);
			continue;
		}
		dropped = true;
		NetRef wire = auxiliary_port.wire_id;
		destroy_node_record(net, eraser_node);
		net.ports.erase(other);
		net.wires.erase(wire);
		net.ports.erase(auxiliary);
	}

	NetRef[] current_auxiliaries;
	if (dropped)
	{
		current_auxiliaries = kept.to_array(mem);
		node = net.nodes.get_ref(node_ref);
		mem::free(node.agent.replicator.auxiliaries);
		node.agent.replicator.auxiliaries = current_auxiliaries;
	}
	else
	{
		current_auxiliaries = old_auxiliaries;
	}
	kept.free();

	if (!current_auxiliaries.len)
	{
		if (!net.ports.contains_ref(principal) || net.ports.get_ref(principal).polarity != CHILD)
		{
			delta_reduce_fail(state, "zero-exit unpaired fan-in replicator cannot be reified by the local eraser kernel");
			return false;
		}
		destroy_node_record(net, node_ref);
		NetRef eraser_node = net.nodes.push({
			.agent = { .eraser = { .principal = principal } },
			.type = ERASER,
		});
		Port* principal_port = net.ports.get_ref(principal);
		principal_port.node_id = eraser_node;
		principal_port.slot = { .type = PRINCIPAL };
		return true;
	}

	if (current_auxiliaries.len == 1)
	{
		NetRef auxiliary = current_auxiliaries[0];
		Port* auxiliary_port = net.ports.get_ref(auxiliary);
		if (!auxiliary_port.slot.properties.has_value)
		{
			delta_reduce_fail(state, "replicator auxiliary is missing delta metadata");
			return false;
		}
		if (auxiliary_port.slot.properties.value.delta_level == 0)
		{
			if (!net.wires.contains_ref(net.ports.get_ref(principal).wire_id)
				|| !net.wires.contains_ref(auxiliary_port.wire_id)
				|| net.ports.get_ref(principal).wire_id == auxiliary_port.wire_id)
			{
				delta_reduce_fail(state, "direct replicator decay found malformed wiring");
				return false;
			}
			(void)splice(net, principal, auxiliary);
			destroy_node_record(net, node_ref);
			net.ports.erase(principal);
			net.ports.erase(auxiliary);
			return true;
		}
	}
	return dropped;
}

fn bool delta_try_decay(DeltaReduceState* state) @private
{
	for (SlotId id = 0; id < state.net.nodes.next_id; id++)
	{
		if (!state.net.nodes.contains_id(id)) continue;
		NetRef node_ref = state.net.nodes.generation_ref(id);
		if (delta_decay_replicator(state, node_ref)) return true;
		if (state.failed) return false;
	}
	return false;
}

fn bool delta_merge_replicators(
	DeltaReduceState* state,
	NetRef outer_ref,
	usz exit_index,
	NetRef inner_ref
) @private
{
	Net* net = state.net;
	Node* outer_node = net.nodes.get_ref(outer_ref);
	Node* inner_node = net.nodes.get_ref(inner_ref);
	Replicator* outer = &outer_node.agent.replicator;
	Replicator* inner = &inner_node.agent.replicator;
	NetRef replaced_auxiliary = outer.auxiliaries[(sz)exit_index];
	NetRef inner_principal = inner.principal;
	NetRef connecting_wire = net.ports.get_ref(replaced_auxiliary).wire_id;
	long outer_delta = net.ports.get_ref(replaced_auxiliary).slot.properties.value.delta_level;
	usz new_count = outer.auxiliaries.len - 1 + inner.auxiliaries.len;
	NetRef[] composed = mem::alloc_array(NetRef, (sz)new_count);
	usz cursor = 0;
	foreach (index, auxiliary : outer.auxiliaries)
	{
		if ((usz)index == exit_index)
		{
			foreach (inner_auxiliary : inner.auxiliaries)
			{
				Port* port = net.ports.get_ref(inner_auxiliary);
				if (!port.slot.properties.has_value)
				{
					mem::free(composed);
					delta_reduce_fail(state, "stacked replicator merge found missing delta metadata");
					return false;
				}
				int128 shifted = (int128)outer_delta + (int128)port.slot.properties.value.delta_level;
				if (shifted < (int128)long::min || shifted > (int128)long::max)
				{
					mem::free(composed);
					delta_reduce_fail(state, "stacked replicator merge delta overflow");
					return false;
				}
				port.node_id = outer_ref;
				port.slot.properties.value.position = cursor;
				port.slot.properties.value.delta_level = (long)shifted;
				composed[cursor++] = inner_auxiliary;
			}
			continue;
		}
		Port* port = net.ports.get_ref(auxiliary);
		port.slot.properties.value.position = cursor;
		composed[cursor++] = auxiliary;
	}

	NetRef[] old_outer = outer.auxiliaries;
	outer.auxiliaries = composed;
	mem::free(old_outer);
	destroy_node_record(net, inner_ref);
	net.wires.erase(connecting_wire);
	net.ports.erase(replaced_auxiliary);
	net.ports.erase(inner_principal);
	return true;
}

fn bool delta_try_merge(DeltaReduceState* state) @private
{
	Net* net = state.net;
	for (SlotId id = 0; id < net.nodes.next_id; id++)
	{
		if (!net.nodes.contains_id(id)) continue;
		NetRef outer_ref = net.nodes.generation_ref(id);
		Node* outer_node = net.nodes.get_ref(outer_ref);
		if (outer_node.type != REPLICATOR
			|| outer_node.agent.replicator.status != UNPAIRED
			|| outer_node.agent.replicator.observable) continue;
		Replicator* outer = &outer_node.agent.replicator;
		foreach (index, auxiliary : outer.auxiliaries)
		{
			Port* auxiliary_port = net.ports.get_ref(auxiliary);
			if (!auxiliary_port.slot.properties.has_value || !net.wires.contains_ref(auxiliary_port.wire_id)) continue;
			NetRef other = other_endpoint(net, auxiliary_port.wire_id, auxiliary);
			if (!net.ports.contains_ref(other)) continue;
			Port* other_port = net.ports.get_ref(other);
			if (other_port.slot.type != PRINCIPAL || !net.nodes.contains_ref(other_port.node_id)) continue;
			NetRef inner_ref = other_port.node_id;
			if (inner_ref == outer_ref) continue;
			Node* inner_node = net.nodes.get_ref(inner_ref);
			if (inner_node.type != REPLICATOR
				|| inner_node.agent.replicator.status != UNPAIRED
				|| inner_node.agent.replicator.observable
				|| inner_node.agent.replicator.principal != other) continue;
			long delta = auxiliary_port.slot.properties.value.delta_level;
			int128 level_difference = (int128)inner_node.agent.replicator.delta_level
				- (int128)outer.delta_level;
			if (level_difference < 0 || level_difference > (int128)delta) continue;
			return delta_merge_replicators(state, outer_ref, (usz)index, inner_ref);
		}
	}
	return false;
}
fn bool delta_reduce_is_interface_port(Net* net, NetRef port_ref) @private
{
	for (SlotId id = 0; id < net.interfaces.next_id; id++)
	{
		if (!net.interfaces.contains_id(id)) continue;
		if (net.interfaces.get_ref(net.interfaces.generation_ref(id)).port == port_ref) return true;
	}
	return false;
}

fn bool delta_reduce_is_replicator_auxiliary(Replicator* replicator, NetRef port_ref) @private
{
	foreach (auxiliary : replicator.auxiliaries) if (auxiliary == port_ref) return true;
	return false;
}


fn NetRef delta_find_active_from_child(
	DeltaReduceState* state,
	NetRef child,
	char[] path,
	usz depth
) @private
{
	Net* net = state.net;
	if (depth >= DELTA_MAX_TRAVERSAL_DEPTH)
	{
		delta_reduce_fail(state, "root-directed reduction traversal depth limit exceeded");
		return INVALID_NET_REF;
	}
	if (!net.ports.contains_ref(child) || (usz)child.id >= path.len)
	{
		delta_reduce_fail(state, "root-directed traversal reached a stale port");
		return INVALID_NET_REF;
	}
	Port* child_port = net.ports.get_ref(child);
	if (child_port.polarity != CHILD || !net.wires.contains_ref(child_port.wire_id))
	{
		delta_reduce_fail(state, "root-directed traversal reached malformed CHILD wiring");
		return INVALID_NET_REF;
	}
	if (path[(usz)child.id]) return INVALID_NET_REF;
	path[(usz)child.id] = 1;
	defer path[(usz)child.id] = 0;
	NetRef wire_ref = child_port.wire_id;
	if (is_active(net, wire_ref)) return wire_ref;
	NetRef parent = other_endpoint(net, wire_ref, child);
	if (!net.ports.contains_ref(parent) || net.ports.get_ref(parent).polarity != PARENT)
	{
		delta_reduce_fail(state, "root-directed traversal wire does not lead to a PARENT port");
		return INVALID_NET_REF;
	}
	if (delta_reduce_is_interface_port(net, parent)) return INVALID_NET_REF;
	Port* parent_port = net.ports.get_ref(parent);
	if (!net.nodes.contains_ref(parent_port.node_id))
	{
		delta_reduce_fail(state, "root-directed traversal reached an unowned port");
		return INVALID_NET_REF;
	}
	Node* node = net.nodes.get_ref(parent_port.node_id);
	switch (node.type)
	{
		case FAN:
			Fan* fan = &node.agent.fan;
			Polarity principal_polarity = net.ports.get_ref(fan.principal).polarity;
			if (parent == fan.principal && principal_polarity == PARENT)
			{
				return delta_find_active_from_child(state, fan.left, path, depth + 1);
			}
			if (parent == fan.left && principal_polarity == CHILD)
			{
				NetRef found = delta_find_active_from_child(state, fan.principal, path, depth + 1);
				if (found != INVALID_NET_REF || state.failed) return found;
				return delta_find_active_from_child(state, fan.right, path, depth + 1);
			}
			if (parent == fan.right) return INVALID_NET_REF;
			delta_reduce_fail(state, "root traversal entered a fan through a non-canonical port");
			return INVALID_NET_REF;
		case REPLICATOR:
			Replicator* replicator = &node.agent.replicator;
			Polarity principal_polarity = net.ports.get_ref(replicator.principal).polarity;
			if (principal_polarity == CHILD && delta_reduce_is_replicator_auxiliary(replicator, parent))
			{
				return delta_find_active_from_child(state, replicator.principal, path, depth + 1);
			}
			if (parent == replicator.principal && principal_polarity == PARENT)
			{
				foreach (auxiliary : replicator.auxiliaries)
				{
					NetRef found = delta_find_active_from_child(state, auxiliary, path, depth + 1);
					if (found != INVALID_NET_REF || state.failed) return found;
				}
				return INVALID_NET_REF;
			}
			delta_reduce_fail(state, "root traversal found unsupported replicator orientation");
			return INVALID_NET_REF;
		case ERASER:
			delta_reduce_fail(state, "root traversal demanded an erased term");
			return INVALID_NET_REF;
		default:
			delta_reduce_fail(state, "root traversal reached an unknown agent");
			return INVALID_NET_REF;
	}
}

fn NetRef delta_find_leftmost_outermost(DeltaReduceState* state) @private
{
	if (!state.net.interfaces.contains_ref(state.root))
	{
		delta_reduce_fail(state, "reduction root interface is stale");
		return INVALID_NET_REF;
	}
	InterfacePort* root = state.net.interfaces.get_ref(state.root);
	if (root.type != ROOT || !state.net.ports.contains_ref(root.port))
	{
		delta_reduce_fail(state, "reduction reference does not name a live ROOT interface");
		return INVALID_NET_REF;
	}
	char[] path = alloc::new_array(state.allocator, char, (sz)state.net.ports.next_id);
	foreach (&flag : path) *flag = 0;
	NetRef found = delta_find_active_from_child(state, root.port, path, 0);
	alloc::free(state.allocator, path);
	return found;
}

fn void delta_mark_component(Net* net, NetRef start, char[] port_marks, char[] node_marks, char[] wire_marks) @private
{
	List{NetRef} pending;
	pending.init(mem);
	pending.push(start);
	while (pending.len())
	{
		NetRef port_ref = pending.pop()!!;
		if (!net.ports.contains_ref(port_ref) || (usz)port_ref.id >= port_marks.len) continue;
		if (port_marks[(usz)port_ref.id]) continue;
		port_marks[(usz)port_ref.id] = 1;
		Port* port = net.ports.get_ref(port_ref);
		if (net.wires.contains_ref(port.wire_id))
		{
			wire_marks[(usz)port.wire_id.id] = 1;
			pending.push(other_endpoint(net, port.wire_id, port_ref));
		}
		if (!net.nodes.contains_ref(port.node_id)) continue;
		if (node_marks[(usz)port.node_id.id]) continue;
		node_marks[(usz)port.node_id.id] = 1;
		Node* node = net.nodes.get_ref(port.node_id);
		switch (node.type)
		{
			case FAN:
				pending.push(node.agent.fan.principal);
				pending.push(node.agent.fan.left);
				pending.push(node.agent.fan.right);
			case ERASER:
				pending.push(node.agent.eraser.principal);
			case REPLICATOR:
				pending.push(node.agent.replicator.principal);
				foreach (auxiliary : node.agent.replicator.auxiliaries) pending.push(auxiliary);
			default:
		}
	}
	pending.free();
}

fn bool delta_cleanup_unreachable(DeltaReduceState* state) @private
{
	Net* net = state.net;
	InterfacePort* root = net.interfaces.get_ref(state.root);
	char[] port_marks = alloc::new_array(state.allocator, char, (sz)net.ports.next_id);
	char[] node_marks = alloc::new_array(state.allocator, char, (sz)net.nodes.next_id);
	char[] wire_marks = alloc::new_array(state.allocator, char, (sz)net.wires.next_id);
	foreach (&value : port_marks) *value = 0;
	foreach (&value : node_marks) *value = 0;
	foreach (&value : wire_marks) *value = 0;
	delta_mark_component(net, root.port, port_marks, node_marks, wire_marks);

	char[] checked_nodes = alloc::new_array(state.allocator, char, (sz)net.nodes.next_id);
	foreach (&value : checked_nodes) *value = 0;
	for (SlotId id = 0; id < net.nodes.next_id; id++)
	{
		if (!net.nodes.contains_id(id) || node_marks[(usz)id] || checked_nodes[(usz)id]) continue;
		char[] component_ports = alloc::new_array(state.allocator, char, (sz)net.ports.next_id);
		char[] component_nodes = alloc::new_array(state.allocator, char, (sz)net.nodes.next_id);
		char[] component_wires = alloc::new_array(state.allocator, char, (sz)net.wires.next_id);
		foreach (&value : component_ports) *value = 0;
		foreach (&value : component_nodes) *value = 0;
		foreach (&value : component_wires) *value = 0;
		NetRef component_root = net.nodes.generation_ref(id);
		Node* first = net.nodes.get_ref(component_root);
		NetRef start_port;
		switch (first.type)
		{
			case FAN: start_port = first.agent.fan.principal;
			case ERASER: start_port = first.agent.eraser.principal;
			case REPLICATOR: start_port = first.agent.replicator.principal;
			default: start_port = INVALID_NET_REF;
		}
		delta_mark_component(net, start_port, component_ports, component_nodes, component_wires);
		bool has_eraser = false;
		for (SlotId component_id = 0; component_id < net.nodes.next_id; component_id++)
		{
			if (!component_nodes[(usz)component_id]) continue;
			checked_nodes[(usz)component_id] = 1;
			if (net.nodes.contains_id(component_id)
				&& net.nodes.get_ref(net.nodes.generation_ref(component_id)).type == ERASER) has_eraser = true;
		}
		alloc::free(state.allocator, component_ports);
		alloc::free(state.allocator, component_nodes);
		alloc::free(state.allocator, component_wires);
		if (!has_eraser)
		{
			alloc::free(state.allocator, checked_nodes);
			alloc::free(state.allocator, port_marks);
			alloc::free(state.allocator, node_marks);
			alloc::free(state.allocator, wire_marks);
			delta_reduce_fail(state, "root cleanup refused to drop a component that had not received an eraser");
			return false;
		}
	}
	alloc::free(state.allocator, checked_nodes);

	bool removed = false;
	for (SlotId id = 0; id < net.nodes.next_id; id++)
	{
		if (!net.nodes.contains_id(id) || node_marks[(usz)id]) continue;
		destroy_node_record(net, net.nodes.generation_ref(id));
		removed = true;
	}
	for (SlotId id = 0; id < net.wires.next_id; id++)
	{
		if (!net.wires.contains_id(id) || wire_marks[(usz)id]) continue;
		net.wires.erase(net.wires.generation_ref(id));
	}
	for (SlotId id = 0; id < net.ports.next_id; id++)
	{
		if (!net.ports.contains_id(id) || port_marks[(usz)id]) continue;
		net.ports.erase(net.ports.generation_ref(id));
	}
	for (SlotId id = 0; id < net.interfaces.next_id; id++)
	{
		if (!net.interfaces.contains_id(id)) continue;
		NetRef interface_ref = net.interfaces.generation_ref(id);
		InterfacePort* interface_port = net.interfaces.get_ref(interface_ref);
		if ((usz)interface_port.port.id >= port_marks.len || !port_marks[(usz)interface_port.port.id])
		{
			net.interfaces.erase(interface_ref);
		}
	}
	alloc::free(state.allocator, port_marks);
	alloc::free(state.allocator, node_marks);
	alloc::free(state.allocator, wire_marks);
	return removed;
}

fn bool delta_rotate_phase_two_fans(DeltaReduceState* state) @private
{
	bool changed = false;
	for (SlotId id = 0; id < state.net.nodes.next_id; id++)
	{
		if (!state.net.nodes.contains_id(id)) continue;
		Node* node = state.net.nodes.get_ref(state.net.nodes.generation_ref(id));
		if (node.type != FAN || node.agent.fan.phase_two_rotated) continue;
		Fan* fan = &node.agent.fan;
		if (!state.net.ports.contains_ref(fan.principal)
			|| !state.net.ports.contains_ref(fan.left))
		{
			delta_reduce_fail(state, "phase two found a fan with stale ports");
			return false;
		}
		NetRef old_principal = fan.principal;
		fan.principal = fan.left;
		fan.left = old_principal;
		state.net.ports.get_ref(fan.principal).slot = { .type = PRINCIPAL };
		state.net.ports.get_ref(fan.left).slot = { .type = LEFT };
		fan.phase_two_rotated = true;
		changed = true;
	}
	return changed;
}

fn void delta_restore_phase_two_fans(DeltaReduceState* state) @private
{
	for (SlotId id = 0; id < state.net.nodes.next_id; id++)
	{
		if (!state.net.nodes.contains_id(id)) continue;
		Node* node = state.net.nodes.get_ref(state.net.nodes.generation_ref(id));
		if (node.type != FAN || !node.agent.fan.phase_two_rotated) continue;
		Fan* fan = &node.agent.fan;
		NetRef phase_two_principal = fan.principal;
		fan.principal = fan.left;
		fan.left = phase_two_principal;
		if (state.net.ports.contains_ref(fan.principal))
		{
			state.net.ports.get_ref(fan.principal).slot = { .type = PRINCIPAL };
		}
		if (state.net.ports.contains_ref(fan.left))
		{
			state.net.ports.get_ref(fan.left).slot = { .type = LEFT };
		}
		fan.phase_two_rotated = false;
	}
}

fn NetRef delta_find_any_active(Net* net) @private
{
	for (SlotId id = 0; id < net.wires.next_id; id++)
	{
		if (!net.wires.contains_id(id)) continue;
		NetRef wire = net.wires.generation_ref(id);
		if (is_active(net, wire)) return wire;
	}
	return INVALID_NET_REF;
}

fn bool delta_run_phase_two(
	DeltaReduceState* state,
	DeltaReductionResult* result
) @private
{
	while (!state.failed)
	{
		(void)delta_rotate_phase_two_fans(state);
		if (state.failed) break;
		if (delta_try_decay(state))
		{
			result.canonical_rewrites++;
			continue;
		}
		if (state.failed) break;
		if (delta_try_merge(state))
		{
			result.canonical_rewrites++;
			continue;
		}
		if (state.failed) break;
		NetRef active = delta_find_any_active(state.net);
		if (active == INVALID_NET_REF) break;
		if (result.reductions >= DELTA_MAX_INTERACTIONS)
		{
			delta_reduce_fail(state, "Delta phase-two interaction limit exceeded");
			break;
		}
		if (!interact(state.net, active))
		{
			delta_reduce_fail(state, "phase-two active wire became stale before interaction");
			break;
		}
		result.reductions++;
	}
	delta_restore_phase_two_fans(state);
	if (state.failed) return false;

	for (SlotId id = 0; id < state.net.nodes.next_id; id++)
	{
		if (!state.net.nodes.contains_id(id)) continue;
		Node* node = state.net.nodes.get_ref(state.net.nodes.generation_ref(id));
		if (node.type != REPLICATOR) continue;
		Replicator* replicator = &node.agent.replicator;
		if (!state.net.ports.contains_ref(replicator.principal))
		{
			delta_reduce_fail(state, "phase two left a stale replicator principal");
			return false;
		}
		bool fan_out =
			state.net.ports.get_ref(replicator.principal).polarity == PARENT;
		if (fan_out && !replicator.observable)
		{
			delta_reduce_fail(state, "phase two could not eliminate an unmarked fan-out replicator");
			return false;
		}
		if (replicator.status == UNKNOWN) replicator.status = UNPAIRED;
	}
	return true;
}

fn bool delta_check_phase_two_residue(DeltaReduceState* state) @private
{
	for (SlotId id = 0; id < state.net.nodes.next_id; id++)
	{
		if (!state.net.nodes.contains_id(id)) continue;
		Node* node = state.net.nodes.get_ref(state.net.nodes.generation_ref(id));
		if (node.type != REPLICATOR) continue;
		Replicator* replicator = &node.agent.replicator;
		if (!state.net.ports.contains_ref(replicator.principal))
		{
			delta_reduce_fail(state, "phase barrier found a stale replicator principal");
			return false;
		}
		bool fan_out =
			state.net.ports.get_ref(replicator.principal).polarity == PARENT;
		if ((fan_out && !replicator.observable)
			|| (!fan_out && replicator.observable)
			|| replicator.status == UNKNOWN)
		{
			delta_reduce_fail(state, "phase-two residue is not a valid observable boundary");
			return false;
		}
	}
	return true;
}

fn DeltaReductionResult reduce_delta_root(Net* net, NetRef root, Allocator allocator = mem)
{
	DeltaReductionResult result = { .allocator = allocator };
	DeltaReduceState state = { .allocator = allocator, .net = net, .root = root };
	if (!net)
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "cannot reduce a missing net");
		return result;
	}

	while (!state.failed)
	{
		if (delta_try_decay(&state))
		{
			result.canonical_rewrites++;
			continue;
		}
		if (state.failed) break;
		if (delta_try_merge(&state))
		{
			result.canonical_rewrites++;
			continue;
		}
		if (state.failed) break;
		NetRef active = delta_find_leftmost_outermost(&state);
		if (state.failed || active == INVALID_NET_REF) break;
		if (result.reductions >= DELTA_MAX_INTERACTIONS)
		{
			delta_reduce_fail(&state, "Delta reduction interaction limit exceeded");
			break;
		}
		if (!interact(net, active))
		{
			delta_reduce_fail(&state, "selected leftmost-outermost wire became stale before interaction");
			break;
		}
		result.reductions++;
	}

	if (!state.failed)
	{
		// Explicit phase-one/canonicalization barrier.
		for (;;)
		{
			bool changed = delta_try_decay(&state);
			if (state.failed) break;
			if (!changed) changed = delta_try_merge(&state);
			if (state.failed || !changed) break;
			result.canonical_rewrites++;
		}
	}
	if (!state.failed)
	{
		// Erased phase-one components must not participate in phase two.
		if (delta_cleanup_unreachable(&state)) result.canonical_rewrites++;
	}
	if (!state.failed)
	{
		(void)delta_run_phase_two(&state, &result);
	}
	if (!state.failed)
	{
		// Phase two may expose new erased components and merge opportunities.
		if (delta_cleanup_unreachable(&state)) result.canonical_rewrites++;
		for (;;)
		{
			bool changed = delta_try_decay(&state);
			if (state.failed) break;
			if (!changed) changed = delta_try_merge(&state);
			if (state.failed || !changed) break;
			result.canonical_rewrites++;
		}
	}
	if (!state.failed) (void)delta_check_phase_two_residue(&state);

	if (state.failed)
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0] = state.diagnostic;
	}
	return result;
}
