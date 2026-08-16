module delta_net_abstract_machine::node_interaction_test;

import delta_net_abstract_machine;

fn Polarity opposite(Polarity polarity)
{
	return polarity == PARENT ? CHILD : PARENT;
}

fn void connect(Net* net, StableId first, StableId second)
{
	StableId wire = net.wires.push({ .a = first, .b = second });
	net.ports.get_ref(first).wire_id = wire;
	net.ports.get_ref(second).wire_id = wire;
}

fn StableId add_external_port(Net* net, Polarity polarity = PARENT)
{
	return net.ports.push({
		.slot = { .type = AUXILIARY },
		.polarity = polarity
	});
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
	assert(net.wires.len() == 8);

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

	foreach (idx, left_auxiliary : left_copy.agent.replicator.auxiliaries)
	{
		StableId right_auxiliary = right_copy.agent.replicator.auxiliaries[idx];
		assert(left_auxiliary != right_auxiliary);
		assert(left_auxiliary != first_auxiliary && left_auxiliary != second_auxiliary);
		assert(right_auxiliary != first_auxiliary && right_auxiliary != second_auxiliary);
		assert(net.ports.get_ref(left_auxiliary).polarity
			== opposite(net.ports.get_ref(fan_left).polarity));
		assert(net.ports.get_ref(right_auxiliary).polarity
			== opposite(net.ports.get_ref(fan_right).polarity));
	}

	assert_split_fan(net, first_auxiliary,
		left_copy.agent.replicator.auxiliaries[0],
		right_copy.agent.replicator.auxiliaries[0]);
	assert_split_fan(net, second_auxiliary,
		left_copy.agent.replicator.auxiliaries[1],
		right_copy.agent.replicator.auxiliaries[1]);
	assert(delta_net_abstract_machine::validate_net(net));
}

fn StableId add_eraser(Net* net, Polarity principal_polarity = CHILD)
{
	StableId principal = net.ports.push({
		.slot = { .type = PRINCIPAL },
		.polarity = principal_polarity
	});
	StableId node = net.nodes.push({
		.agent = { .eraser = { .principal = principal } },
		.type = ERASER
	});
	net.ports.get_ref(principal).node_id = node;
	return node;
}

fn StableId add_fan(Net* net, Polarity principal_polarity = PARENT)
{
	StableId principal = net.ports.push({
		.slot = { .type = PRINCIPAL },
		.polarity = principal_polarity
	});
	StableId left = net.ports.push({
		.slot = { .type = LEFT },
		.polarity = PARENT
	});
	StableId right = net.ports.push({
		.slot = { .type = RIGHT },
		.polarity = CHILD
	});
	StableId node = net.nodes.push({
		.agent = { .fan = { .principal = principal, .left = left, .right = right } },
		.type = FAN
	});
	net.ports.get_ref(principal).node_id = node;
	net.ports.get_ref(left).node_id = node;
	net.ports.get_ref(right).node_id = node;
	return node;
}

fn StableId add_replicator(Net* net, ulong level, sz arity,
	Polarity principal_polarity = CHILD)
{
	StableId principal = net.ports.push({
		.slot = { .type = PRINCIPAL },
		.polarity = principal_polarity
	});
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
			.slot = { .type = AUXILIARY },
			.polarity = principal_polarity == PARENT ? CHILD : PARENT
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
	StableId second = add_eraser(&net, PARENT);
	StableId first_port = principal(&net, first);
	StableId second_port = principal(&net, second);
	connect(&net, first_port, second_port);
	StableId wire = net.ports.get_ref(first_port).wire_id;

	delta_net_abstract_machine::interact(&net, wire);

	assert(net.nodes.is_empty());
	assert(net.ports.is_empty());
	assert(net.wires.is_empty());
	assert(delta_net_abstract_machine::validate_net(&net));
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
	connect(&net, left, add_external_port(&net, CHILD));
	connect(&net, right, add_external_port(&net, PARENT));
	StableId wire = net.ports.get_ref(fan_principal).wire_id;

	delta_net_abstract_machine::interact(&net, wire);

	assert(!net.nodes.contains(fan));
	assert(!net.nodes.contains(eraser));
	assert(net.nodes.len() == 2);
	assert(net.ports.get_ref(left).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(right).slot.type == PRINCIPAL);
	assert(net.nodes.get_ref(net.ports.get_ref(left).node_id).type == ERASER);
	assert(net.nodes.get_ref(net.ports.get_ref(right).node_id).type == ERASER);
	assert(delta_net_abstract_machine::validate_net(&net));
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
	connect(&net, left, add_external_port(&net, CHILD));
	connect(&net, right, add_external_port(&net, PARENT));

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(eraser_principal).wire_id);

	assert(!net.nodes.contains(eraser));
	assert(!net.nodes.contains(fan));
	assert(net.nodes.len() == 2);
	assert(net.ports.get_ref(left).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(right).slot.type == PRINCIPAL);
	assert(net.nodes.get_ref(net.ports.get_ref(left).node_id).type == ERASER);
	assert(net.nodes.get_ref(net.ports.get_ref(right).node_id).type == ERASER);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void fan_fan_interaction_splices_the_branch_wires() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId first = add_fan(&net);
	StableId second = add_fan(&net, CHILD);
	StableId first_principal = principal(&net, first);
	StableId second_principal = principal(&net, second);
	StableId first_left = net.nodes.get_ref(first).agent.fan.left;
	StableId first_right = net.nodes.get_ref(first).agent.fan.right;
	StableId second_left = net.nodes.get_ref(second).agent.fan.left;
	StableId second_right = net.nodes.get_ref(second).agent.fan.right;
	StableId first_left_external = add_external_port(&net, CHILD);
	StableId first_right_external = add_external_port(&net, PARENT);
	StableId second_left_external = add_external_port(&net, CHILD);
	StableId second_right_external = add_external_port(&net, PARENT);
	connect(&net, first_principal, second_principal);
	connect(&net, first_left, first_left_external);
	connect(&net, first_right, first_right_external);
	connect(&net, second_left, second_left_external);
	connect(&net, second_right, second_right_external);
	StableId principal_wire = net.ports.get_ref(first_principal).wire_id;
	StableId variable_wire = net.ports.get_ref(first_left).wire_id;
	StableId body_wire = net.ports.get_ref(first_right).wire_id;

	delta_net_abstract_machine::interact(&net, principal_wire);

	assert(net.nodes.len() == 0);
	assert(!net.wires.contains(principal_wire));
	assert(net.wires.len() == 2);
	assert(wire_connects(&net, body_wire, first_right_external, second_left_external));
	assert(wire_connects(&net, variable_wire, first_left_external, second_right_external));
	assert(net.ports.get_ref(second_left_external).wire_id == body_wire);
	assert(net.ports.get_ref(second_right_external).wire_id == variable_wire);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void fan_fan_interaction_splices_branch_wires_when_endpoint_order_is_reversed() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId first = add_fan(&net);
	StableId second = add_fan(&net, CHILD);
	StableId first_principal = principal(&net, first);
	StableId second_principal = principal(&net, second);
	StableId first_left = net.nodes.get_ref(first).agent.fan.left;
	StableId first_right = net.nodes.get_ref(first).agent.fan.right;
	StableId second_left = net.nodes.get_ref(second).agent.fan.left;
	StableId second_right = net.nodes.get_ref(second).agent.fan.right;
	StableId first_left_external = add_external_port(&net, CHILD);
	StableId first_right_external = add_external_port(&net, PARENT);
	StableId second_left_external = add_external_port(&net, CHILD);
	StableId second_right_external = add_external_port(&net, PARENT);
	connect(&net, second_principal, first_principal);
	connect(&net, first_left, first_left_external);
	connect(&net, first_right, first_right_external);
	connect(&net, second_left, second_left_external);
	connect(&net, second_right, second_right_external);
	StableId principal_wire = net.ports.get_ref(first_principal).wire_id;
	StableId variable_wire = net.ports.get_ref(first_left).wire_id;
	StableId body_wire = net.ports.get_ref(first_right).wire_id;

	delta_net_abstract_machine::interact(&net, principal_wire);

	assert(net.nodes.is_empty());
	assert(!net.wires.contains(principal_wire));
	assert(net.wires.len() == 2);
	assert(wire_connects(&net, body_wire, first_right_external, second_left_external));
	assert(wire_connects(&net, variable_wire, first_left_external, second_right_external));
	assert(net.ports.get_ref(first_right_external).wire_id == body_wire);
	assert(net.ports.get_ref(first_left_external).wire_id == variable_wire);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void replicator_eraser_interaction_erases_each_auxiliary() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId replicator = add_replicator(&net, 0, 2);
	StableId eraser = add_eraser(&net, PARENT);
	StableId replicator_principal = principal(&net, replicator);
	StableId eraser_principal = principal(&net, eraser);
	StableId first_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[0];
	StableId second_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[1];
	connect(&net, replicator_principal, eraser_principal);
	connect(&net, first_auxiliary, add_external_port(&net, CHILD));
	connect(&net, second_auxiliary, add_external_port(&net, CHILD));
	StableId wire = net.ports.get_ref(replicator_principal).wire_id;

	delta_net_abstract_machine::interact(&net, wire);

	assert(!net.nodes.contains(replicator));
	assert(!net.nodes.contains(eraser));
	assert(net.nodes.len() == 2);
	assert(net.ports.get_ref(first_auxiliary).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(second_auxiliary).slot.type == PRINCIPAL);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void eraser_replicator_interaction_erases_each_auxiliary() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId eraser = add_eraser(&net, PARENT);
	StableId replicator = add_replicator(&net, 0, 2);
	StableId eraser_principal = principal(&net, eraser);
	StableId replicator_principal = principal(&net, replicator);
	StableId first_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[0];
	StableId second_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[1];
	connect(&net, eraser_principal, replicator_principal);
	connect(&net, first_auxiliary, add_external_port(&net, CHILD));
	connect(&net, second_auxiliary, add_external_port(&net, CHILD));

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(eraser_principal).wire_id);

	assert(!net.nodes.contains(eraser));
	assert(!net.nodes.contains(replicator));
	assert(net.nodes.len() == 2);
	assert(net.ports.get_ref(first_auxiliary).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(second_auxiliary).slot.type == PRINCIPAL);
	assert(delta_net_abstract_machine::validate_net(&net));
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
	connect(&net, first_auxiliary, add_external_port(&net, CHILD));
	connect(&net, second_auxiliary, add_external_port(&net, CHILD));
	connect(&net, fan_left, add_external_port(&net, CHILD));
	connect(&net, fan_right, add_external_port(&net, PARENT));
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
	connect(&net, first_auxiliary, add_external_port(&net, CHILD));
	connect(&net, second_auxiliary, add_external_port(&net, CHILD));
	connect(&net, fan_left, add_external_port(&net, CHILD));
	connect(&net, fan_right, add_external_port(&net, PARENT));
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
	StableId second = add_replicator(&net, 2, 2, PARENT);
	StableId first_principal = principal(&net, first);
	StableId second_principal = principal(&net, second);
	StableId first_left = net.nodes.get_ref(first).agent.replicator.auxiliaries[0];
	StableId first_right = net.nodes.get_ref(first).agent.replicator.auxiliaries[1];
	StableId second_left = net.nodes.get_ref(second).agent.replicator.auxiliaries[0];
	StableId second_right = net.nodes.get_ref(second).agent.replicator.auxiliaries[1];
	StableId first_left_external = add_external_port(&net, CHILD);
	StableId first_right_external = add_external_port(&net, CHILD);
	StableId second_left_external = add_external_port(&net, PARENT);
	StableId second_right_external = add_external_port(&net, PARENT);
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
	assert(delta_net_abstract_machine::validate_net(&net));
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
	StableId lower = add_replicator(&net, 1, 2, PARENT);
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
	connect(&net, higher_first_auxiliary, add_external_port(&net, CHILD));
	connect(&net, higher_second_auxiliary, add_external_port(&net, CHILD));
	connect(&net, lower_first_auxiliary, add_external_port(&net, PARENT));
	connect(&net, lower_second_auxiliary, add_external_port(&net, PARENT));
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

	assert(delta_net_abstract_machine::validate_net(&net));
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
	connect(&net, node.agent.fan.principal, add_external_port(&net, CHILD));
	connect(&net, node.agent.fan.left, add_external_port(&net, CHILD));
	connect(&net, node.agent.fan.right, add_external_port(&net, PARENT));

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
	net.ports.get_ref(external_principal).polarity = CHILD;
	connect(&net, node.agent.fan.left, add_external_port(&net, CHILD));
	connect(&net, node.agent.fan.right, add_external_port(&net, PARENT));
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
	connect(&net, node.agent.fan.principal, add_external_port(&net, CHILD));
	connect(&net, node.agent.fan.left, add_external_port(&net, CHILD));
	connect(&net, node.agent.fan.right, add_external_port(&net, PARENT));
	node.agent.fan.left = node.agent.fan.principal;

	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void net_validator_rejects_replicator_auxiliary_with_principal_polarity() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId replicator = add_replicator(&net, 0, 2);
	Node* node = net.nodes.get_ref(replicator);
	connect(&net, node.agent.replicator.principal, add_external_port(&net, PARENT));
	foreach (auxiliary : node.agent.replicator.auxiliaries)
	{
		connect(&net, auxiliary, add_external_port(&net, CHILD));
	}
	assert(delta_net_abstract_machine::validate_net(&net));

	net.ports.get_ref(node.agent.replicator.auxiliaries[0]).polarity = CHILD;

	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void graph_constructors_populate_owned_ports_and_metadata() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId fan_id = delta_net_abstract_machine::new_fan(&net);
	StableId eraser_id = delta_net_abstract_machine::new_eraser(&net);
	long[] deltas = mem::alloc_array(long, 2);
	defer mem::free(deltas);
	deltas[0] = -1;
	deltas[1] = 2;
	StableId replicator_id = delta_net_abstract_machine::new_replicator(
		&net, 4, deltas, UNKNOWN, PARENT);
	StableId root_id = delta_net_abstract_machine::new_interface(&net, ROOT, "");
	StableId free_id = delta_net_abstract_machine::new_interface(
		&net, FREE_VARIABLE, "x");
	assert(net.ports.get_ref(net.interfaces.get_ref(root_id).port).polarity
		== PARENT);
	assert(net.ports.get_ref(net.interfaces.get_ref(free_id).port).polarity
		== CHILD);

	Node* fan = net.nodes.get_ref(fan_id);
	assert(fan.type == FAN);
	assert(net.ports.get_ref(fan.agent.fan.principal).node_id == fan_id);
	assert(net.ports.get_ref(fan.agent.fan.left).slot.type == LEFT);
	assert(net.ports.get_ref(fan.agent.fan.right).slot.type == RIGHT);

	Node* eraser = net.nodes.get_ref(eraser_id);
	assert(eraser.type == ERASER);
	assert(net.ports.get_ref(eraser.agent.eraser.principal).node_id == eraser_id);

	Node* replicator = net.nodes.get_ref(replicator_id);
	assert(replicator.type == REPLICATOR);
	assert(replicator.agent.replicator.delta_level == 4);
	assert(replicator.agent.replicator.status == UNKNOWN);
	assert(net.ports.get_ref(replicator.agent.replicator.principal).polarity
		== PARENT);
	assert(replicator.agent.replicator.auxiliaries.len == 2);
	foreach (idx, auxiliary : replicator.agent.replicator.auxiliaries)
	{
		Port* port = net.ports.get_ref(auxiliary);
		assert(port.node_id == replicator_id);
		assert(port.slot.type == AUXILIARY);
		assert(port.slot.properties.has_value);
		assert(port.slot.properties.value.position == (StableId)idx);
		assert(port.slot.properties.value.delta_level == deltas[idx]);
		assert(port.polarity == CHILD);
	}

	assert(!net.interfaces.get_ref(root_id).name.has_value);
	assert(net.interfaces.get_ref(free_id).name.has_value);
	assert(net.interfaces.get_ref(free_id).name.value == "x");
}

fn void wire_mutations_preserve_endpoint_back_references() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId first = delta_net_abstract_machine::new_eraser(&net);
	StableId second = delta_net_abstract_machine::new_eraser(&net);
	StableId third = delta_net_abstract_machine::new_eraser(&net);
	StableId fourth = delta_net_abstract_machine::new_eraser(&net);
	StableId first_port = principal(&net, first);
	StableId second_port = principal(&net, second);
	StableId third_port = principal(&net, third);
	StableId fourth_port = principal(&net, fourth);
	net.ports.get_ref(second_port).polarity = PARENT;
	net.ports.get_ref(fourth_port).polarity = PARENT;

	StableId first_wire = delta_net_abstract_machine::connect(
		&net, first_port, second_port);
	StableId second_wire = delta_net_abstract_machine::connect(
		&net, third_port, fourth_port);
	assert(delta_net_abstract_machine::other_endpoint(
		&net, first_wire, first_port) == second_port);

	StableId surviving_wire = delta_net_abstract_machine::splice(
		&net, second_port, third_port);
	assert(surviving_wire == first_wire);
	assert(!net.wires.contains(second_wire));
	assert(wire_connects(&net, surviving_wire, first_port, fourth_port));
	assert(net.ports.get_ref(first_port).wire_id == surviving_wire);
	assert(net.ports.get_ref(fourth_port).wire_id == surviving_wire);
	assert(net.ports.get_ref(second_port).wire_id
		== delta_net_abstract_machine::INVALID_STABLE_ID);
	assert(net.ports.get_ref(third_port).wire_id
		== delta_net_abstract_machine::INVALID_STABLE_ID);

	delta_net_abstract_machine::disconnect(&net, surviving_wire);
	assert(net.wires.is_empty());
	assert(net.ports.get_ref(first_port).wire_id
		== delta_net_abstract_machine::INVALID_STABLE_ID);
	assert(net.ports.get_ref(fourth_port).wire_id
		== delta_net_abstract_machine::INVALID_STABLE_ID);
}

fn void destroy_node_removes_owned_ports_and_incident_wires() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId fan = delta_net_abstract_machine::new_fan(&net);
	StableId eraser = delta_net_abstract_machine::new_eraser(&net);
	StableId fan_principal = principal(&net, fan);
	StableId eraser_principal = principal(&net, eraser);
	delta_net_abstract_machine::connect(&net, fan_principal, eraser_principal);

	delta_net_abstract_machine::destroy_node(&net, fan);

	assert(!net.nodes.contains(fan));
	assert(net.nodes.contains(eraser));
	assert(net.ports.len() == 1);
	assert(net.wires.is_empty());
	assert(net.ports.get_ref(eraser_principal).wire_id
		== delta_net_abstract_machine::INVALID_STABLE_ID);

	delta_net_abstract_machine::destroy_node(&net, eraser);
	assert(net.nodes.is_empty());
	assert(net.ports.is_empty());
}

fn void net_validator_rejects_equal_endpoint_polarities() @test
{
	Net net;
	net.init();
	defer net.free();

	StableId first = add_external_port(&net, PARENT);
	StableId second = add_external_port(&net, PARENT);
	connect(&net, first, second);

	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void port_clones_copy_semantics_but_not_connections() @test
{
	Net net;
	net.init();
	defer net.free();

	long[] deltas = mem::alloc_array(long, 2);
	defer mem::free(deltas);
	deltas[0] = -3;
	deltas[1] = 5;
	StableId source_node = delta_net_abstract_machine::new_replicator(
		&net, 7, deltas, UNKNOWN, PARENT);
	StableId target_node = delta_net_abstract_machine::new_eraser(&net);
	StableId interface_id = delta_net_abstract_machine::new_interface(
		&net, ROOT, "");
	StableId interface_port = net.interfaces.get_ref(interface_id).port;
	StableId[] sources =
		net.nodes.get_ref(source_node).agent.replicator.auxiliaries;
	StableId source_wire = delta_net_abstract_machine::connect(
		&net, sources[0], interface_port);

	StableId single_clone = delta_net_abstract_machine::clone_port(
		&net, sources[0], target_node);
	Port* source = net.ports.get_ref(sources[0]);
	Port* clone = net.ports.get_ref(single_clone);
	assert(clone.node_id == target_node);
	assert(clone.wire_id == delta_net_abstract_machine::INVALID_STABLE_ID);
	assert(clone.slot.type == source.slot.type);
	assert(clone.slot.properties.has_value);
	assert(clone.slot.properties.value.position
		== source.slot.properties.value.position);
	assert(clone.slot.properties.value.delta_level
		== source.slot.properties.value.delta_level);
	assert(clone.polarity == source.polarity);
	assert(source.wire_id == source_wire);

	StableId[] clones = delta_net_abstract_machine::clone_ports(
		&net, sources, target_node);
	defer mem::free(clones);
	assert(clones.len == sources.len);
	foreach (idx, clone_id : clones)
	{
		Port* original = net.ports.get_ref(sources[idx]);
		Port* copied = net.ports.get_ref(clone_id);
		assert(clone_id != sources[idx]);
		assert(copied.node_id == target_node);
		assert(copied.wire_id
			== delta_net_abstract_machine::INVALID_STABLE_ID);
		assert(copied.slot.type == original.slot.type);
		assert(copied.slot.properties.has_value
			== original.slot.properties.has_value);
		assert(copied.slot.properties.value.delta_level
			== original.slot.properties.value.delta_level);
		assert(copied.polarity == original.polarity);
	}
}
