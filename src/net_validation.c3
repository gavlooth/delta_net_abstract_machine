module delta_net_abstract_machine;

// Boundaries are represented by ports that no live node references. Wire
// validation still enforces parent/child polarity for those boundary ports.
fn bool node_references_port(Node* node, StableId port_id)
{
	switch (node.type)
	{
	case ERASER:
		return node.agent.eraser.principal == port_id;
	case FAN:
		return node.agent.fan.principal == port_id
			|| node.agent.fan.left == port_id
			|| node.agent.fan.right == port_id;
	case REPLICATOR:
		if (node.agent.replicator.principal == port_id) return true;
		foreach (auxiliary : node.agent.replicator.auxiliaries)
		{
			if (auxiliary == port_id) return true;
		}
		return false;
	default:
		return false;
	}
}

fn bool node_port_is_valid(Net* net, StableId node_id, StableId port_id,
	PortType expected_type)
{
	if (!net.ports.contains(port_id)) return false;
	Port* port = net.ports.get_ref(port_id);
	return port.node_id == node_id && port.slot.type == expected_type;
}

fn bool node_is_valid(Net* net, StableId node_id, Node* node)
{
	switch (node.type)
	{
	case ERASER:
		return node_port_is_valid(net, node_id, node.agent.eraser.principal,
			PRINCIPAL);
	case FAN:
		if (node.agent.fan.principal == node.agent.fan.left
			|| node.agent.fan.principal == node.agent.fan.right
			|| node.agent.fan.left == node.agent.fan.right) return false;
		// LEFT and RIGHT are stable auxiliary identities, not global geometry:
		// LEFT is auxiliary 1 and RIGHT is auxiliary 2. Mirroring a fan changes
		// their polarities relative to the principal, but never swaps the slots.
		// In particular, do not replace this relation with "left is PARENT and
		// right is CHILD": that accepts a wrongly-oriented abstraction and
		// forces the incorrect crossed fan--fan rewrite.
		if (!node_port_is_valid(net, node_id, node.agent.fan.principal, PRINCIPAL)
			|| !node_port_is_valid(net, node_id, node.agent.fan.left, LEFT)
			|| !node_port_is_valid(net, node_id, node.agent.fan.right, RIGHT)) return false;
		Polarity principal_polarity =
			net.ports.get_ref(node.agent.fan.principal).polarity;
		return net.ports.get_ref(node.agent.fan.left).polarity
				== opposite_polarity(principal_polarity)
			&& net.ports.get_ref(node.agent.fan.right).polarity
				== principal_polarity;
	case REPLICATOR:
		StableId principal = node.agent.replicator.principal;
		if (!node_port_is_valid(net, node_id, principal, PRINCIPAL)) return false;
		Polarity auxiliary_polarity =
			opposite_polarity(net.ports.get_ref(principal).polarity);
		foreach (idx, auxiliary : node.agent.replicator.auxiliaries)
		{
			if (auxiliary == principal
				|| !node_port_is_valid(net, node_id, auxiliary, AUXILIARY)
				|| net.ports.get_ref(auxiliary).polarity != auxiliary_polarity) return false;
			foreach (other_idx, other : node.agent.replicator.auxiliaries)
			{
				if (idx != other_idx && auxiliary == other) return false;
			}
		}
		return true;
	default:
		return false;
	}
}

fn bool nodes_are_valid(Net* net)
{
	for (sz index = 0; index < net.nodes.len(); index++)
	{
		StableId node_id = net.nodes.create_handle_at(index).get_id();
		if (!node_is_valid(net, node_id, net.nodes.get_ref(node_id))) return false;
	}
	return true;
}

fn bool ports_have_at_most_one_owner(Net* net)
{
	for (sz port_index = 0; port_index < net.ports.len(); port_index++)
	{
		StableId port_id = net.ports.create_handle_at(port_index).get_id();
		sz owners = 0;
		for (sz node_index = 0; node_index < net.nodes.len(); node_index++)
		{
			StableId node_id = net.nodes.create_handle_at(node_index).get_id();
			if (node_references_port(net.nodes.get_ref(node_id), port_id)) owners++;
		}
		if (owners > 1) return false;
	}
	return true;
}

fn bool replicator_slices_are_unique(Net* net)
{
	for (sz first_index = 0; first_index < net.nodes.len(); first_index++)
	{
		StableId first_id = net.nodes.create_handle_at(first_index).get_id();
		Node* first = net.nodes.get_ref(first_id);
		if (first.type != REPLICATOR) continue;
		StableId[] first_auxiliaries = first.agent.replicator.auxiliaries;
		if (first_auxiliaries.len == 0) continue;

		for (sz second_index = first_index + 1; second_index < net.nodes.len(); second_index++)
		{
			StableId second_id = net.nodes.create_handle_at(second_index).get_id();
			Node* second = net.nodes.get_ref(second_id);
			if (second.type != REPLICATOR) continue;
			StableId[] second_auxiliaries = second.agent.replicator.auxiliaries;
			if (second_auxiliaries.len > 0
				&& first_auxiliaries.ptr == second_auxiliaries.ptr) return false;
		}
	}
	return true;
}

fn bool wires_are_valid(Net* net)
{
	for (sz index = 0; index < net.wires.len(); index++)
	{
		StableId wire_id = net.wires.create_handle_at(index).get_id();
		Wire* wire = net.wires.get_ref(wire_id);
		if (wire.a == wire.b || !net.ports.contains(wire.a)
			|| !net.ports.contains(wire.b)) return false;
		Port* a = net.ports.get_ref(wire.a);
		Port* b = net.ports.get_ref(wire.b);
		if (a.wire_id != wire_id || b.wire_id != wire_id
			|| a.polarity == b.polarity) return false;
	}
	return true;
}

fn bool ports_have_live_wires(Net* net)
{
	for (sz index = 0; index < net.ports.len(); index++)
	{
		StableId port_id = net.ports.create_handle_at(index).get_id();
		Port* port = net.ports.get_ref(port_id);
		if (!net.wires.contains(port.wire_id)) return false;
		Wire* wire = net.wires.get_ref(port.wire_id);
		if (wire.a != port_id && wire.b != port_id) return false;
	}
	return true;
}

fn bool validate_net(Net* net)
{
	return nodes_are_valid(net)
		&& ports_have_at_most_one_owner(net)
		&& replicator_slices_are_unique(net)
		&& wires_are_valid(net)
		&& ports_have_live_wires(net);
}
