module delta_net_abstract_machine::node_interaction_test;

import delta_net_abstract_machine;

fn void connect(Net* net, StableId first, StableId second)
{
	StableId wire = net.wires.push({ .a = first, .b = second });
	net.ports.get_ref(first).wire_id = wire;
	net.ports.get_ref(second).wire_id = wire;
}

fn StableId add_external_port(Net* net)
{
	return net.ports.push({ .slot = { .type = AUXILIARY } });
}

fn bool wire_connects(Net* net, StableId wire_id, StableId first, StableId second)
{
	if (!net.wires.contains(wire_id)) return false;
	Wire* wire = net.wires.get_ref(wire_id);
	return (wire.a == first && wire.b == second)
		|| (wire.a == second && wire.b == first);
}

fn void set_auxiliary_delta(Net* net, StableId auxiliary, long delta)
{
	net.ports.get_ref(auxiliary).slot.properties = {
		.value = { .position = auxiliary, .delta_level = delta },
		.has_value = true
	};
}

fn void assert_split_fan(Net* net, StableId former_auxiliary,
	StableId left_copy_auxiliary, StableId right_copy_auxiliary)
{
	Node* fan = net.nodes.get_ref(net.ports.get_ref(former_auxiliary).node_id);
	assert(net.ports.get_ref(former_auxiliary).slot.type == PRINCIPAL);
	assert(fan.type == FAN);
	assert(wire_connects(net, net.ports.get_ref(fan.agent.fan.left).wire_id,
		fan.agent.fan.left, left_copy_auxiliary));
	assert(wire_connects(net, net.ports.get_ref(fan.agent.fan.right).wire_id,
		fan.agent.fan.right, right_copy_auxiliary));
	assert(net.ports.get_ref(left_copy_auxiliary).wire_id
		== net.ports.get_ref(fan.agent.fan.left).wire_id);
	assert(net.ports.get_ref(right_copy_auxiliary).wire_id
		== net.ports.get_ref(fan.agent.fan.right).wire_id);
}

fn void assert_replicator_fan_result(Net* net, StableId replicator, StableId fan,
	StableId fan_left, StableId fan_right, StableId first_auxiliary,
	StableId second_auxiliary)
{
	assert(!net.nodes.contains(replicator));
	assert(!net.nodes.contains(fan));
	assert(net.nodes.len() == 4);
	assert(net.wires.len() == 6);

	Node* left_copy = net.nodes.get_ref(net.ports.get_ref(fan_left).node_id);
	Node* right_copy = net.nodes.get_ref(net.ports.get_ref(fan_right).node_id);
	assert(net.ports.get_ref(fan_left).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(fan_right).slot.type == PRINCIPAL);
	assert(left_copy.type == REPLICATOR);
	assert(right_copy.type == REPLICATOR);
	assert(left_copy.agent.replicator.delta_level == 3);
	assert(right_copy.agent.replicator.delta_level == 3);
	assert(left_copy.agent.replicator.auxiliaries.len == 2);
	assert(right_copy.agent.replicator.auxiliaries.len == 2);

	assert_split_fan(net, first_auxiliary,
		left_copy.agent.replicator.auxiliaries[0],
		right_copy.agent.replicator.auxiliaries[0]);
	assert_split_fan(net, second_auxiliary,
		left_copy.agent.replicator.auxiliaries[1],
		right_copy.agent.replicator.auxiliaries[1]);
}

fn StableId add_eraser(Net* net)
{
	StableId principal = net.ports.push({ .slot = { .type = PRINCIPAL } });
	StableId node = net.nodes.push({
		.agent = { .eraser = { .principal = principal } },
		.type = ERASER
	});
	net.ports.get_ref(principal).node_id = node;
	return node;
}

fn StableId add_fan(Net* net)
{
	StableId principal = net.ports.push({ .slot = { .type = PRINCIPAL } });
	StableId left = net.ports.push({ .slot = { .type = LEFT } });
	StableId right = net.ports.push({ .slot = { .type = RIGHT } });
	StableId node = net.nodes.push({
		.agent = { .fan = { .principal = principal, .left = left, .right = right } },
		.type = FAN
	});
	net.ports.get_ref(principal).node_id = node;
	net.ports.get_ref(left).node_id = node;
	net.ports.get_ref(right).node_id = node;
	return node;
}

fn StableId add_replicator(Net* net, ulong level, sz arity)
{
	StableId principal = net.ports.push({ .slot = { .type = PRINCIPAL } });
	StableId[] auxiliaries = mem::alloc_array(StableId, arity);
	StableId node = net.nodes.push({
		.agent = { .replicator = {
			.principal = principal,
			.auxiliaries = auxiliaries,
			.delta_level = level,
			.status = UNPAIRED
		} },
		.type = REPLICATOR
	});
	net.ports.get_ref(principal).node_id = node;
	for (sz idx = 0; idx < arity; idx++)
	{
		StableId auxiliary = net.ports.push({
			.node_id = node,
			.slot = { .type = AUXILIARY }
		});
		auxiliaries[idx] = auxiliary;
	}
	return node;
}

fn StableId principal(Net* net, StableId node)
{
	Node* value = net.nodes.get_ref(node);
	switch (value.type)
	{
	case ERASER: return value.agent.eraser.principal;
	case FAN: return value.agent.fan.principal;
	case REPLICATOR: return value.agent.replicator.principal;
	default: return (StableId)0;
	}
}

fn void eraser_eraser_interaction_removes_both_agents() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId first = add_eraser(&net);
	StableId second = add_eraser(&net);
	StableId first_port = principal(&net, first);
	StableId second_port = principal(&net, second);
	connect(&net, first_port, second_port);
	StableId wire = net.ports.get_ref(first_port).wire_id;

	delta_net_abstract_machine::interact(&net, wire);

	assert(net.nodes.is_empty());
	assert(net.ports.is_empty());
	assert(net.wires.is_empty());
}

fn void fan_eraser_interaction_replaces_branches_with_erasers() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId fan = add_fan(&net);
	StableId eraser = add_eraser(&net);
	StableId fan_principal = principal(&net, fan);
	StableId eraser_principal = principal(&net, eraser);
	StableId left = net.nodes.get_ref(fan).agent.fan.left;
	StableId right = net.nodes.get_ref(fan).agent.fan.right;
	connect(&net, fan_principal, eraser_principal);
	StableId wire = net.ports.get_ref(fan_principal).wire_id;

	delta_net_abstract_machine::interact(&net, wire);

	assert(!net.nodes.contains(fan));
	assert(!net.nodes.contains(eraser));
	assert(net.nodes.len() == 2);
	assert(net.ports.get_ref(left).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(right).slot.type == PRINCIPAL);
	assert(net.nodes.get_ref(net.ports.get_ref(left).node_id).type == ERASER);
	assert(net.nodes.get_ref(net.ports.get_ref(right).node_id).type == ERASER);
}

fn void eraser_fan_interaction_replaces_branches_with_erasers() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId eraser = add_eraser(&net);
	StableId fan = add_fan(&net);
	StableId eraser_principal = principal(&net, eraser);
	StableId fan_principal = principal(&net, fan);
	StableId left = net.nodes.get_ref(fan).agent.fan.left;
	StableId right = net.nodes.get_ref(fan).agent.fan.right;
	connect(&net, eraser_principal, fan_principal);

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(eraser_principal).wire_id);

	assert(!net.nodes.contains(eraser));
	assert(!net.nodes.contains(fan));
	assert(net.nodes.len() == 2);
	assert(net.ports.get_ref(left).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(right).slot.type == PRINCIPAL);
	assert(net.nodes.get_ref(net.ports.get_ref(left).node_id).type == ERASER);
	assert(net.nodes.get_ref(net.ports.get_ref(right).node_id).type == ERASER);
}

fn void fan_fan_interaction_splices_the_branch_wires() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId first = add_fan(&net);
	StableId second = add_fan(&net);
	StableId first_principal = principal(&net, first);
	StableId second_principal = principal(&net, second);
	StableId first_left = net.nodes.get_ref(first).agent.fan.left;
	StableId first_right = net.nodes.get_ref(first).agent.fan.right;
	StableId second_left = net.nodes.get_ref(second).agent.fan.left;
	StableId second_right = net.nodes.get_ref(second).agent.fan.right;
	StableId first_left_external = add_external_port(&net);
	StableId first_right_external = add_external_port(&net);
	StableId second_left_external = add_external_port(&net);
	StableId second_right_external = add_external_port(&net);
	connect(&net, first_principal, second_principal);
	connect(&net, first_left, first_left_external);
	connect(&net, first_right, first_right_external);
	connect(&net, second_left, second_left_external);
	connect(&net, second_right, second_right_external);
	StableId principal_wire = net.ports.get_ref(first_principal).wire_id;
	StableId left_wire = net.ports.get_ref(first_left).wire_id;
	StableId right_wire = net.ports.get_ref(first_right).wire_id;

	delta_net_abstract_machine::interact(&net, principal_wire);

	assert(net.nodes.len() == 0);
	assert(!net.wires.contains(principal_wire));
	assert(net.wires.len() == 2);
	assert(wire_connects(&net, left_wire, first_left_external, second_left_external));
	assert(wire_connects(&net, right_wire, first_right_external, second_right_external));
	assert(net.ports.get_ref(second_left_external).wire_id == left_wire);
	assert(net.ports.get_ref(second_right_external).wire_id == right_wire);
}

fn void fan_fan_interaction_splices_branch_wires_when_endpoint_order_is_reversed() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId first = add_fan(&net);
	StableId second = add_fan(&net);
	StableId first_principal = principal(&net, first);
	StableId second_principal = principal(&net, second);
	StableId first_left = net.nodes.get_ref(first).agent.fan.left;
	StableId first_right = net.nodes.get_ref(first).agent.fan.right;
	StableId second_left = net.nodes.get_ref(second).agent.fan.left;
	StableId second_right = net.nodes.get_ref(second).agent.fan.right;
	StableId first_left_external = add_external_port(&net);
	StableId first_right_external = add_external_port(&net);
	StableId second_left_external = add_external_port(&net);
	StableId second_right_external = add_external_port(&net);
	connect(&net, second_principal, first_principal);
	connect(&net, first_left, first_left_external);
	connect(&net, first_right, first_right_external);
	connect(&net, second_left, second_left_external);
	connect(&net, second_right, second_right_external);
	StableId principal_wire = net.ports.get_ref(first_principal).wire_id;
	StableId left_wire = net.ports.get_ref(second_left).wire_id;
	StableId right_wire = net.ports.get_ref(second_right).wire_id;

	delta_net_abstract_machine::interact(&net, principal_wire);

	assert(net.nodes.is_empty());
	assert(!net.wires.contains(principal_wire));
	assert(net.wires.len() == 2);
	assert(wire_connects(&net, left_wire, first_left_external, second_left_external));
	assert(wire_connects(&net, right_wire, first_right_external, second_right_external));
	assert(net.ports.get_ref(first_left_external).wire_id == left_wire);
	assert(net.ports.get_ref(first_right_external).wire_id == right_wire);
}

fn void replicator_eraser_interaction_erases_each_auxiliary() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId replicator = add_replicator(&net, 0, 2);
	StableId eraser = add_eraser(&net);
	StableId replicator_principal = principal(&net, replicator);
	StableId eraser_principal = principal(&net, eraser);
	StableId first_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[0];
	StableId second_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[1];
	connect(&net, replicator_principal, eraser_principal);
	StableId wire = net.ports.get_ref(replicator_principal).wire_id;

	delta_net_abstract_machine::interact(&net, wire);

	assert(!net.nodes.contains(replicator));
	assert(!net.nodes.contains(eraser));
	assert(net.nodes.len() == 2);
	assert(net.ports.get_ref(first_auxiliary).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(second_auxiliary).slot.type == PRINCIPAL);
}

fn void eraser_replicator_interaction_erases_each_auxiliary() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId eraser = add_eraser(&net);
	StableId replicator = add_replicator(&net, 0, 2);
	StableId eraser_principal = principal(&net, eraser);
	StableId replicator_principal = principal(&net, replicator);
	StableId first_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[0];
	StableId second_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[1];
	connect(&net, eraser_principal, replicator_principal);

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(eraser_principal).wire_id);

	assert(!net.nodes.contains(eraser));
	assert(!net.nodes.contains(replicator));
	assert(net.nodes.len() == 2);
	assert(net.ports.get_ref(first_auxiliary).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(second_auxiliary).slot.type == PRINCIPAL);
}

fn void replicator_fan_interaction_copies_replicator_across_fan() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId replicator = add_replicator(&net, 3, 2);
	StableId fan = add_fan(&net);
	StableId replicator_principal = principal(&net, replicator);
	StableId fan_principal = principal(&net, fan);
	StableId fan_left = net.nodes.get_ref(fan).agent.fan.left;
	StableId fan_right = net.nodes.get_ref(fan).agent.fan.right;
	StableId first_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[0];
	StableId second_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[1];
	connect(&net, first_auxiliary, add_external_port(&net));
	connect(&net, second_auxiliary, add_external_port(&net));
	connect(&net, replicator_principal, fan_principal);

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(replicator_principal).wire_id);

	assert_replicator_fan_result(&net, replicator, fan, fan_left, fan_right,
		first_auxiliary, second_auxiliary);
}

fn void fan_replicator_interaction_copies_replicator_across_fan() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId fan = add_fan(&net);
	StableId replicator = add_replicator(&net, 3, 2);
	StableId fan_principal = principal(&net, fan);
	StableId replicator_principal = principal(&net, replicator);
	StableId fan_left = net.nodes.get_ref(fan).agent.fan.left;
	StableId fan_right = net.nodes.get_ref(fan).agent.fan.right;
	StableId first_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[0];
	StableId second_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[1];
	connect(&net, first_auxiliary, add_external_port(&net));
	connect(&net, second_auxiliary, add_external_port(&net));
	connect(&net, fan_principal, replicator_principal);

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(fan_principal).wire_id);

	assert_replicator_fan_result(&net, replicator, fan, fan_left, fan_right,
		first_auxiliary, second_auxiliary);
}

fn void inactive_wire_does_not_reduce_nodes() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId eraser = add_eraser(&net);
	StableId eraser_port = principal(&net, eraser);
	StableId auxiliary = net.ports.push({ .slot = { .type = AUXILIARY } });
	StableId wire = net.wires.push({ .a = eraser_port, .b = auxiliary });

	delta_net_abstract_machine::interact(&net, wire);

	assert(net.nodes.len() == 1);
	assert(net.wires.contains(wire));
}

fn void run_equal_replicator_case(bool reverse_endpoints)
{
	Net net;
	net.init();
	defer net.free();

	StableId first = add_replicator(&net, 2, 2);
	StableId second = add_replicator(&net, 2, 2);
	StableId first_principal = principal(&net, first);
	StableId second_principal = principal(&net, second);
	StableId first_left = net.nodes.get_ref(first).agent.replicator.auxiliaries[0];
	StableId first_right = net.nodes.get_ref(first).agent.replicator.auxiliaries[1];
	StableId second_left = net.nodes.get_ref(second).agent.replicator.auxiliaries[0];
	StableId second_right = net.nodes.get_ref(second).agent.replicator.auxiliaries[1];
	StableId first_left_external = add_external_port(&net);
	StableId first_right_external = add_external_port(&net);
	StableId second_left_external = add_external_port(&net);
	StableId second_right_external = add_external_port(&net);
	connect(&net, first_left, first_left_external);
	connect(&net, first_right, first_right_external);
	connect(&net, second_left, second_left_external);
	connect(&net, second_right, second_right_external);
	StableId first_left_wire = net.ports.get_ref(first_left).wire_id;
	StableId first_right_wire = net.ports.get_ref(first_right).wire_id;
	StableId second_left_wire = net.ports.get_ref(second_left).wire_id;
	StableId second_right_wire = net.ports.get_ref(second_right).wire_id;
	if (reverse_endpoints)
	{
		connect(&net, second_principal, first_principal);
	}
	else
	{
		connect(&net, first_principal, second_principal);
	}

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(first_principal).wire_id);

	StableId surviving_left_wire = reverse_endpoints ? second_left_wire : first_left_wire;
	StableId surviving_right_wire = reverse_endpoints ? second_right_wire : first_right_wire;
	assert(net.nodes.is_empty());
	assert(net.wires.len() == 2);
	assert(wire_connects(&net, surviving_left_wire, first_left_external, second_left_external));
	assert(wire_connects(&net, surviving_right_wire, first_right_external, second_right_external));
	assert(net.ports.get_ref(first_left_external).wire_id == surviving_left_wire);
	assert(net.ports.get_ref(first_right_external).wire_id == surviving_right_wire);
	assert(net.ports.get_ref(second_left_external).wire_id == surviving_left_wire);
	assert(net.ports.get_ref(second_right_external).wire_id == surviving_right_wire);
}

fn void equal_replicators_annihilate() @test
{
	run_equal_replicator_case(false);
}

fn void equal_replicators_annihilate_when_endpoint_order_is_reversed() @test
{
	run_equal_replicator_case(true);
}

fn void run_unequal_replicator_case(bool higher_first)
{
	Net net;
	net.init();
	defer net.free();

	StableId higher = add_replicator(&net, 4, 2);
	StableId lower = add_replicator(&net, 1, 2);
	StableId higher_principal = principal(&net, higher);
	StableId lower_principal = principal(&net, lower);
	StableId higher_first_auxiliary = net.nodes.get_ref(higher).agent.replicator.auxiliaries[0];
	StableId higher_second_auxiliary = net.nodes.get_ref(higher).agent.replicator.auxiliaries[1];
	StableId lower_first_auxiliary = net.nodes.get_ref(lower).agent.replicator.auxiliaries[0];
	StableId lower_second_auxiliary = net.nodes.get_ref(lower).agent.replicator.auxiliaries[1];
	set_auxiliary_delta(&net, higher_first_auxiliary, 0);
	set_auxiliary_delta(&net, higher_second_auxiliary, 1);
	set_auxiliary_delta(&net, lower_first_auxiliary, -1);
	set_auxiliary_delta(&net, lower_second_auxiliary, 2);
	connect(&net, higher_first_auxiliary, add_external_port(&net));
	connect(&net, higher_second_auxiliary, add_external_port(&net));
	connect(&net, lower_first_auxiliary, add_external_port(&net));
	connect(&net, lower_second_auxiliary, add_external_port(&net));
	if (higher_first)
	{
		connect(&net, higher_principal, lower_principal);
	}
	else
	{
		connect(&net, lower_principal, higher_principal);
	}

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(higher_principal).wire_id);

	assert(!net.nodes.contains(higher));
	assert(!net.nodes.contains(lower));
	assert(net.nodes.len() == 4);
	assert(net.wires.len() == 8);

	Node* first_higher_copy = net.nodes.get_ref(net.ports.get_ref(lower_first_auxiliary).node_id);
	Node* second_higher_copy = net.nodes.get_ref(net.ports.get_ref(lower_second_auxiliary).node_id);
	Node* first_lower_copy = net.nodes.get_ref(net.ports.get_ref(higher_first_auxiliary).node_id);
	Node* second_lower_copy = net.nodes.get_ref(net.ports.get_ref(higher_second_auxiliary).node_id);
	assert(first_higher_copy.type == REPLICATOR);
	assert(second_higher_copy.type == REPLICATOR);
	assert(first_lower_copy.type == REPLICATOR);
	assert(second_lower_copy.type == REPLICATOR);
	assert(first_higher_copy.agent.replicator.delta_level == 3);
	assert(second_higher_copy.agent.replicator.delta_level == 6);
	assert(first_lower_copy.agent.replicator.delta_level == 1);
	assert(second_lower_copy.agent.replicator.delta_level == 1);
	assert(first_higher_copy.agent.replicator.auxiliaries.len == 2);
	assert(second_higher_copy.agent.replicator.auxiliaries.len == 2);
	assert(first_lower_copy.agent.replicator.auxiliaries.len == 2);
	assert(second_lower_copy.agent.replicator.auxiliaries.len == 2);

	assert(wire_connects(&net,
		net.ports.get_ref(first_higher_copy.agent.replicator.auxiliaries[0]).wire_id,
		first_higher_copy.agent.replicator.auxiliaries[0],
		first_lower_copy.agent.replicator.auxiliaries[0]));
	assert(wire_connects(&net,
		net.ports.get_ref(first_higher_copy.agent.replicator.auxiliaries[1]).wire_id,
		first_higher_copy.agent.replicator.auxiliaries[1],
		second_lower_copy.agent.replicator.auxiliaries[0]));
	assert(wire_connects(&net,
		net.ports.get_ref(second_higher_copy.agent.replicator.auxiliaries[0]).wire_id,
		second_higher_copy.agent.replicator.auxiliaries[0],
		first_lower_copy.agent.replicator.auxiliaries[1]));
	assert(wire_connects(&net,
		net.ports.get_ref(second_higher_copy.agent.replicator.auxiliaries[1]).wire_id,
		second_higher_copy.agent.replicator.auxiliaries[1],
		second_lower_copy.agent.replicator.auxiliaries[1]));
}

fn void unequal_replicators_commute_as_a_cartesian_product() @test
{
	run_unequal_replicator_case(true);
}

fn void unequal_replicators_commute_when_endpoint_order_is_reversed() @test
{
	run_unequal_replicator_case(false);
}

fn void net_validator_accepts_a_fully_wired_fan_and_boundaries() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId fan = add_fan(&net);
	Node* node = net.nodes.get_ref(fan);
	connect(&net, node.agent.fan.principal, add_external_port(&net));
	connect(&net, node.agent.fan.left, add_external_port(&net));
	connect(&net, node.agent.fan.right, add_external_port(&net));

	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void net_validator_rejects_a_dangling_wire_endpoint() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId fan = add_fan(&net);
	Node* node = net.nodes.get_ref(fan);
	StableId external_principal = add_external_port(&net);
	connect(&net, node.agent.fan.principal, external_principal);
	connect(&net, node.agent.fan.left, add_external_port(&net));
	connect(&net, node.agent.fan.right, add_external_port(&net));
	net.ports.erase(external_principal);

	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void net_validator_rejects_an_invalid_node_port_slot() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId fan = add_fan(&net);
	Node* node = net.nodes.get_ref(fan);
	connect(&net, node.agent.fan.principal, add_external_port(&net));
	connect(&net, node.agent.fan.left, add_external_port(&net));
	connect(&net, node.agent.fan.right, add_external_port(&net));
	node.agent.fan.left = node.agent.fan.principal;

	assert(!delta_net_abstract_machine::validate_net(&net));
}
