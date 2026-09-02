module delta_net_abstract_machine::node_interaction_test;

import delta_net_abstract_machine;
import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_storage;

fn Polarity opposite(Polarity polarity)
{
	return polarity == PARENT ? CHILD : PARENT;
}

fn void connect(Net* net, NetRef first, NetRef second)
{
	NetRef wire = net.wires.push({ .a = first, .b = second });
	net.ports.get_ref(first).wire_id = wire;
	net.ports.get_ref(second).wire_id = wire;
}

fn NetRef add_external_port(Net* net, Polarity polarity = PARENT)
{
	// Final nets require every live port to have exactly one graph owner.
	// A dormant eraser is a neutral, fully owned boundary for interaction tests.
	NetRef boundary = delta_net_abstract_machine::new_eraser(net, polarity);
	return net.nodes.get_ref(boundary).agent.eraser.principal;
}
fn LayoutHandle register_shared_layout(
	Net* net,
	mitos::TypeId type_id,
	String name,
	mitos::TypeId element_type = mitos::TYPE_ID_I64,
	usz alignment = 8
)
{
	ModuleKey owner = mitos::core_module_key(mem);
	defer owner.deinit(mem);
	LayoutDescriptor descriptor = {
		.kind = LAYOUT_SEQUENCE,
		.copy_policy = COPY_SHARED_IMMUTABLE,
		.sized = false,
		.alignment = alignment,
		.element_type = element_type,
		.stable_key = mitos::symbol_key(
			&owner, SYMBOL_TYPE, name, 0, "", mem
		),
	};
	defer descriptor.deinit(mem);
	LayoutHandleResult registered =
		mitos_storage::register_layout(&net.storage, type_id, &descriptor);
	assert(registered.error == STORAGE_OK);
	return registered.handle;
}

fn StorageHandle allocate_shared_storage(
	Net* net,
	LayoutHandle layout,
	char[] bytes,
	usz stride
)
{
	StorageHandleResult allocated = mitos_storage::allocate_shared_bytes(
		&net.storage, layout, bytes, stride, stride, stride
	);
	assert(allocated.error == STORAGE_OK);
	return allocated.handle;
}

fn bool wire_connects(Net* net, NetRef wire_id, NetRef first, NetRef second)
{
	if (!net.wires.contains_ref(wire_id)) return false;
	Wire* wire = net.wires.get_ref(wire_id);
	return (wire.a == first && wire.b == second)
		|| (wire.a == second && wire.b == first);
}

fn void assert_port_preserved(Net* net, NetRef reference, Port expected)
{
	assert(net.ports.contains_ref(reference));
	Port* current = net.ports.get_ref(reference);
	assert(current.node_id == expected.node_id);
	assert(current.wire_id == expected.wire_id);
	assert(current.slot.type == expected.slot.type);
	assert(current.slot.properties.has_value
		== expected.slot.properties.has_value);
	if (expected.slot.properties.has_value)
	{
		assert(current.slot.properties.value.position
			== expected.slot.properties.value.position);
		assert(current.slot.properties.value.delta_level
			== expected.slot.properties.value.delta_level);
	}
	assert(current.polarity == expected.polarity);
}

fn void assert_wire_preserved(Net* net, NetRef reference, Wire expected)
{
	assert(net.wires.contains_ref(reference));
	Wire* current = net.wires.get_ref(reference);
	assert(current.a == expected.a);
	assert(current.b == expected.b);
}

fn void assert_practical_preserved(
	Net* net,
	NetRef reference,
	AgentType expected_type,
	PracticalAgent expected
)
{
	assert(net.nodes.contains_ref(reference));
	Node* node = net.nodes.get_ref(reference);
	assert(node.type == expected_type);
	PracticalAgent* current = &node.agent.practical;
	assert(current.principal == expected.principal);
	assert(current.auxiliaries.ptr == expected.auxiliaries.ptr);
	assert(current.auxiliaries.len == expected.auxiliaries.len);
	assert(current.semantic_id == expected.semantic_id);
	assert(current.type_id == expected.type_id);
	assert(current.payload == expected.payload);
	assert(current.text == expected.text);
	assert(current.owns_text == expected.owns_text);
	assert(current.storage == expected.storage);
	assert(current.storage_policy == expected.storage_policy);
	assert(current.storage_count == expected.storage_count);
	assert(current.storage_stride == expected.storage_stride);
	assert(current.occurrence_order == expected.occurrence_order);
	assert(current.descriptor == expected.descriptor);
	assert(current.source_order == expected.source_order);
	assert(current.continuation == expected.continuation);
	assert(current.handler_id == expected.handler_id);
	assert(current.effect_id == expected.effect_id);
	assert(current.operation_id == expected.operation_id);
	assert(current.effect_epoch == expected.effect_epoch);
	assert(current.resume_count == expected.resume_count);
	assert(current.resume_state == expected.resume_state);
	assert(current.host_effect == expected.host_effect);
	assert(current.ordered_effect == expected.ordered_effect);
}

fn void set_auxiliary_delta(Net* net, NetRef auxiliary, long delta)
{
	Port* port = net.ports.get_ref(auxiliary);
	usz position = port.slot.properties.has_value
		? port.slot.properties.value.position : 0;
	port.slot.properties = {
		.value = { .position = position, .delta_level = delta },
		.has_value = true
	};
}

fn void assert_split_fan(Net* net, NetRef former_auxiliary,
	NetRef left_copy_auxiliary, NetRef right_copy_auxiliary)
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

fn void assert_replicated_auxiliary_metadata(Net* net,
	NetRef former_auxiliary, PortSlot expected, NetRef left_auxiliary,
	NetRef right_auxiliary)
{
	PortSlot left_slot = net.ports.get_ref(left_auxiliary).slot;
	PortSlot right_slot = net.ports.get_ref(right_auxiliary).slot;
	assert(left_slot.properties.has_value && right_slot.properties.has_value);
	assert(left_slot.properties.value.position == expected.properties.value.position);
	assert(right_slot.properties.value.position == expected.properties.value.position);
	assert(left_slot.properties.value.delta_level
		== expected.properties.value.delta_level);
	assert(right_slot.properties.value.delta_level
		== expected.properties.value.delta_level);

	// The original auxiliary is now a fan principal, so its metadata must have
	// followed the replicated auxiliary role rather than remaining on this port.
	PortSlot former_auxiliary_slot = net.ports.get_ref(former_auxiliary).slot;
	assert(former_auxiliary_slot.type == PRINCIPAL);
	assert(!former_auxiliary_slot.properties.has_value);
}

fn void assert_replicator_fan_result(Net* net, NetRef replicator, NetRef fan,
	NetRef fan_left, NetRef fan_right, NetRef first_auxiliary,
	NetRef second_auxiliary)
{
	assert(!net.nodes.contains_ref(replicator));
	assert(!net.nodes.contains_ref(fan));
	assert(net.nodes.len() == 8);
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
		NetRef right_auxiliary = right_copy.agent.replicator.auxiliaries[idx];
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

fn NetRef add_eraser(Net* net, Polarity principal_polarity = CHILD)
{
	NetRef principal = net.ports.push({
		.node_id = delta_net_abstract_machine::INVALID_NET_REF,
		.wire_id = delta_net_abstract_machine::INVALID_NET_REF,
		.slot = { .type = PRINCIPAL },
		.polarity = principal_polarity
	});
	NetRef node = net.nodes.push({
		.agent = { .eraser = { .principal = principal } },
		.type = ERASER
	});
	net.ports.get_ref(principal).node_id = node;
	return node;
}

fn NetRef add_fan(Net* net, Polarity principal_polarity = PARENT)
{
	NetRef principal = net.ports.push({
		.node_id = delta_net_abstract_machine::INVALID_NET_REF,
		.wire_id = delta_net_abstract_machine::INVALID_NET_REF,
		.slot = { .type = PRINCIPAL },
		.polarity = principal_polarity
	});
	NetRef left = net.ports.push({
		.node_id = delta_net_abstract_machine::INVALID_NET_REF,
		.wire_id = delta_net_abstract_machine::INVALID_NET_REF,
		.slot = { .type = LEFT },
		.polarity = opposite(principal_polarity)
	});
	NetRef right = net.ports.push({
		.node_id = delta_net_abstract_machine::INVALID_NET_REF,
		.wire_id = delta_net_abstract_machine::INVALID_NET_REF,
		.slot = { .type = RIGHT },
		.polarity = principal_polarity
	});
	NetRef node = net.nodes.push({
		.agent = { .fan = { .principal = principal, .left = left, .right = right } },
		.type = FAN
	});
	net.ports.get_ref(principal).node_id = node;
	net.ports.get_ref(left).node_id = node;
	net.ports.get_ref(right).node_id = node;
	return node;
}

fn NetRef add_replicator(Net* net, ulong level, sz arity,
	Polarity principal_polarity = CHILD, ReplicatorStatus status = UNPAIRED)
{
	NetRef principal = net.ports.push({
		.node_id = delta_net_abstract_machine::INVALID_NET_REF,
		.wire_id = delta_net_abstract_machine::INVALID_NET_REF,
		.slot = { .type = PRINCIPAL },
		.polarity = principal_polarity
	});
	NetRef[] auxiliaries = mem::alloc_array(NetRef, arity);
	NetRef node = net.nodes.push({
		.agent = { .replicator = {
			.principal = principal,
			.auxiliaries = auxiliaries,
			.delta_level = level,
			.status = status
		} },
		.type = REPLICATOR
	});
	net.ports.get_ref(principal).node_id = node;
	for (sz idx = 0; idx < arity; idx++)
	{
		NetRef auxiliary = net.ports.push({
			.node_id = node,
			.wire_id = delta_net_abstract_machine::INVALID_NET_REF,
			.slot = { .type = AUXILIARY, .properties = {
				.value = { .position = (usz)idx, .delta_level = 0 },
				.has_value = true
			} },
			.polarity = principal_polarity == PARENT ? CHILD : PARENT
		});
		auxiliaries[idx] = auxiliary;
	}
	return node;
}

fn NetRef principal(Net* net, NetRef node)
{
	Node* value = net.nodes.get_ref(node);
	switch (value.type)
	{
	case ERASER: return value.agent.eraser.principal;
	case FAN: return value.agent.fan.principal;
	case REPLICATOR: return value.agent.replicator.principal;
	default: return delta_net_abstract_machine::INVALID_NET_REF;
	}
}

fn void eraser_eraser_interaction_removes_both_agents() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef first = add_eraser(&net);
	NetRef second = add_eraser(&net, PARENT);
	NetRef first_port = principal(&net, first);
	NetRef second_port = principal(&net, second);
	connect(&net, first_port, second_port);
	NetRef wire = net.ports.get_ref(first_port).wire_id;

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

	NetRef fan = add_fan(&net);
	NetRef eraser = add_eraser(&net);
	NetRef fan_principal = principal(&net, fan);
	NetRef eraser_principal = principal(&net, eraser);
	NetRef left = net.nodes.get_ref(fan).agent.fan.left;
	NetRef right = net.nodes.get_ref(fan).agent.fan.right;
	connect(&net, fan_principal, eraser_principal);
	connect(&net, left, add_external_port(&net, PARENT));
	connect(&net, right, add_external_port(&net, CHILD));
	NetRef wire = net.ports.get_ref(fan_principal).wire_id;

	delta_net_abstract_machine::interact(&net, wire);

	assert(!net.nodes.contains_ref(fan));
	assert(!net.nodes.contains_ref(eraser));
	assert(net.nodes.len() == 4);
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

	NetRef eraser = add_eraser(&net);
	NetRef fan = add_fan(&net);
	NetRef eraser_principal = principal(&net, eraser);
	NetRef fan_principal = principal(&net, fan);
	NetRef left = net.nodes.get_ref(fan).agent.fan.left;
	NetRef right = net.nodes.get_ref(fan).agent.fan.right;
	connect(&net, eraser_principal, fan_principal);
	connect(&net, left, add_external_port(&net, PARENT));
	connect(&net, right, add_external_port(&net, CHILD));

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(eraser_principal).wire_id);

	assert(!net.nodes.contains_ref(eraser));
	assert(!net.nodes.contains_ref(fan));
	assert(net.nodes.len() == 4);
	assert(net.ports.get_ref(left).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(right).slot.type == PRINCIPAL);
	assert(net.nodes.get_ref(net.ports.get_ref(left).node_id).type == ERASER);
	assert(net.nodes.get_ref(net.ports.get_ref(right).node_id).type == ERASER);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void fan_fan_interaction_splices_matching_auxiliary_wires() @test
{
	Net net;
	net.init();
	defer net.free();

	// The fans are facing only in a drawing. These fields remain aux1/aux2 on
	// both agents, so this fixture must reduce left<-->left and right<-->right.
	NetRef first = delta_net_abstract_machine::new_fan(&net, PARENT);
	NetRef second = delta_net_abstract_machine::new_fan(&net, CHILD);
	NetRef first_principal = principal(&net, first);
	NetRef second_principal = principal(&net, second);
	NetRef first_left = net.nodes.get_ref(first).agent.fan.left;
	NetRef first_right = net.nodes.get_ref(first).agent.fan.right;
	NetRef second_left = net.nodes.get_ref(second).agent.fan.left;
	NetRef second_right = net.nodes.get_ref(second).agent.fan.right;
	NetRef first_left_external = add_external_port(&net, PARENT);
	NetRef first_right_external = add_external_port(&net, CHILD);
	NetRef second_left_external = add_external_port(&net, CHILD);
	NetRef second_right_external = add_external_port(&net, PARENT);
	connect(&net, first_principal, second_principal);
	connect(&net, first_left, first_left_external);
	connect(&net, first_right, first_right_external);
	connect(&net, second_left, second_left_external);
	connect(&net, second_right, second_right_external);
	NetRef principal_wire = net.ports.get_ref(first_principal).wire_id;
	NetRef body_wire = net.ports.get_ref(first_left).wire_id;
	NetRef variable_wire = net.ports.get_ref(first_right).wire_id;
	assert(delta_net_abstract_machine::validate_net(&net));

	delta_net_abstract_machine::interact(&net, principal_wire);

	assert(net.nodes.len() == 4);
	assert(!net.wires.contains_ref(principal_wire));
	assert(net.wires.len() == 2);
	assert(wire_connects(&net, body_wire, first_left_external, second_left_external));
	assert(wire_connects(&net, variable_wire, first_right_external, second_right_external));
	assert(net.ports.get_ref(second_left_external).wire_id == body_wire);
	assert(net.ports.get_ref(second_right_external).wire_id == variable_wire);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void fan_fan_interaction_splices_matching_auxiliaries_when_endpoint_order_is_reversed() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef first = delta_net_abstract_machine::new_fan(&net, PARENT);
	NetRef second = delta_net_abstract_machine::new_fan(&net, CHILD);
	NetRef first_principal = principal(&net, first);
	NetRef second_principal = principal(&net, second);
	NetRef first_left = net.nodes.get_ref(first).agent.fan.left;
	NetRef first_right = net.nodes.get_ref(first).agent.fan.right;
	NetRef second_left = net.nodes.get_ref(second).agent.fan.left;
	NetRef second_right = net.nodes.get_ref(second).agent.fan.right;
	NetRef first_left_external = add_external_port(&net, PARENT);
	NetRef first_right_external = add_external_port(&net, CHILD);
	NetRef second_left_external = add_external_port(&net, CHILD);
	NetRef second_right_external = add_external_port(&net, PARENT);
	connect(&net, second_principal, first_principal);
	connect(&net, first_left, first_left_external);
	connect(&net, first_right, first_right_external);
	connect(&net, second_left, second_left_external);
	connect(&net, second_right, second_right_external);
	NetRef principal_wire = net.ports.get_ref(first_principal).wire_id;
	NetRef body_wire = net.ports.get_ref(first_left).wire_id;
	NetRef variable_wire = net.ports.get_ref(first_right).wire_id;
	assert(delta_net_abstract_machine::validate_net(&net));

	delta_net_abstract_machine::interact(&net, principal_wire);

	assert(net.nodes.len() == 4);
	assert(!net.wires.contains_ref(principal_wire));
	assert(net.wires.len() == 2);
	assert(wire_connects(&net, body_wire, first_left_external, second_left_external));
	assert(wire_connects(&net, variable_wire, first_right_external, second_right_external));
	assert(net.ports.get_ref(first_left_external).wire_id == body_wire);
	assert(net.ports.get_ref(first_right_external).wire_id == variable_wire);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void replicator_eraser_interaction_erases_each_auxiliary() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef replicator = add_replicator(&net, 0, 2);
	NetRef eraser = add_eraser(&net, PARENT);
	NetRef replicator_principal = principal(&net, replicator);
	NetRef eraser_principal = principal(&net, eraser);
	NetRef first_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[0];
	NetRef second_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[1];
	connect(&net, replicator_principal, eraser_principal);
	connect(&net, first_auxiliary, add_external_port(&net, CHILD));
	connect(&net, second_auxiliary, add_external_port(&net, CHILD));
	NetRef wire = net.ports.get_ref(replicator_principal).wire_id;

	delta_net_abstract_machine::interact(&net, wire);

	assert(!net.nodes.contains_ref(replicator));
	assert(!net.nodes.contains_ref(eraser));
	assert(net.nodes.len() == 4);
	assert(net.ports.get_ref(first_auxiliary).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(second_auxiliary).slot.type == PRINCIPAL);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void eraser_replicator_interaction_erases_each_auxiliary() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef eraser = add_eraser(&net, PARENT);
	NetRef replicator = add_replicator(&net, 0, 2);
	NetRef eraser_principal = principal(&net, eraser);
	NetRef replicator_principal = principal(&net, replicator);
	NetRef first_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[0];
	NetRef second_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[1];
	connect(&net, eraser_principal, replicator_principal);
	connect(&net, first_auxiliary, add_external_port(&net, CHILD));
	connect(&net, second_auxiliary, add_external_port(&net, CHILD));

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(eraser_principal).wire_id);

	assert(!net.nodes.contains_ref(eraser));
	assert(!net.nodes.contains_ref(replicator));
	assert(net.nodes.len() == 4);
	assert(net.ports.get_ref(first_auxiliary).slot.type == PRINCIPAL);
	assert(net.ports.get_ref(second_auxiliary).slot.type == PRINCIPAL);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void replicator_fan_interaction_copies_replicator_across_fan() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef replicator = add_replicator(&net, 3, 2);
	NetRef fan = add_fan(&net);
	NetRef replicator_principal = principal(&net, replicator);
	NetRef fan_principal = principal(&net, fan);
	NetRef fan_left = net.nodes.get_ref(fan).agent.fan.left;
	NetRef fan_right = net.nodes.get_ref(fan).agent.fan.right;
	NetRef first_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[0];
	NetRef second_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[1];
	connect(&net, first_auxiliary, add_external_port(&net, CHILD));
	connect(&net, second_auxiliary, add_external_port(&net, CHILD));
	connect(&net, fan_left, add_external_port(&net, PARENT));
	connect(&net, fan_right, add_external_port(&net, CHILD));
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

	NetRef fan = add_fan(&net);
	NetRef replicator = add_replicator(&net, 3, 2);
	NetRef fan_principal = principal(&net, fan);
	NetRef replicator_principal = principal(&net, replicator);
	NetRef fan_left = net.nodes.get_ref(fan).agent.fan.left;
	NetRef fan_right = net.nodes.get_ref(fan).agent.fan.right;
	NetRef first_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[0];
	NetRef second_auxiliary = net.nodes.get_ref(replicator).agent.replicator.auxiliaries[1];
	connect(&net, first_auxiliary, add_external_port(&net, CHILD));
	connect(&net, second_auxiliary, add_external_port(&net, CHILD));
	connect(&net, fan_left, add_external_port(&net, PARENT));
	connect(&net, fan_right, add_external_port(&net, CHILD));
	connect(&net, fan_principal, replicator_principal);

	delta_net_abstract_machine::interact(&net, net.ports.get_ref(fan_principal).wire_id);

	assert_replicator_fan_result(&net, replicator, fan, fan_left, fan_right,
		first_auxiliary, second_auxiliary);
}

fn void replicator_fan_interaction_preserves_status_and_auxiliary_metadata() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef replicator = add_replicator(&net, 3, 2, CHILD, UNKNOWN);
	NetRef fan = add_fan(&net);
	NetRef replicator_principal = principal(&net, replicator);
	NetRef fan_principal = principal(&net, fan);
	NetRef fan_left = net.nodes.get_ref(fan).agent.fan.left;
	NetRef fan_right = net.nodes.get_ref(fan).agent.fan.right;
	NetRef first_source_auxiliary = net.nodes.get_ref(replicator)
		.agent.replicator.auxiliaries[0];
	NetRef second_source_auxiliary = net.nodes.get_ref(replicator)
		.agent.replicator.auxiliaries[1];
	set_auxiliary_delta(&net, first_source_auxiliary, -1);
	set_auxiliary_delta(&net, second_source_auxiliary, 2);
	PortSlot first_source_slot = net.ports.get_ref(first_source_auxiliary).slot;
	PortSlot second_source_slot = net.ports.get_ref(second_source_auxiliary).slot;

	connect(&net, first_source_auxiliary, add_external_port(&net, CHILD));
	connect(&net, second_source_auxiliary, add_external_port(&net, CHILD));
	connect(&net, fan_left, add_external_port(&net, PARENT));
	connect(&net, fan_right, add_external_port(&net, CHILD));
	connect(&net, replicator_principal, fan_principal);
	assert(delta_net_abstract_machine::validate_net(&net));

	delta_net_abstract_machine::interact(
		&net, net.ports.get_ref(replicator_principal).wire_id);

	Node* left_copy = net.nodes.get_ref(net.ports.get_ref(fan_left).node_id);
	Node* right_copy = net.nodes.get_ref(net.ports.get_ref(fan_right).node_id);
	assert(left_copy.type == REPLICATOR && right_copy.type == REPLICATOR);
	assert(left_copy.agent.replicator.status == UNKNOWN);
	assert(right_copy.agent.replicator.status == UNKNOWN);
	assert_replicated_auxiliary_metadata(&net, first_source_auxiliary,
		first_source_slot, left_copy.agent.replicator.auxiliaries[0],
		right_copy.agent.replicator.auxiliaries[0]);
	assert_replicated_auxiliary_metadata(&net, second_source_auxiliary,
		second_source_slot, left_copy.agent.replicator.auxiliaries[1],
		right_copy.agent.replicator.auxiliaries[1]);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void run_inactive_wire_guard_case(usz guard, bool mutate_second)
{
	Net net;
	net.init();
	defer net.free();

	NetRef first = delta_net_abstract_machine::new_eraser(&net, PARENT);
	NetRef second = delta_net_abstract_machine::new_eraser(&net, CHILD);
	NetRef first_principal = principal(&net, first);
	NetRef second_principal = principal(&net, second);
	NetRef active_wire = delta_net_abstract_machine::connect(
		&net, first_principal, second_principal
	);
	assert(delta_net_abstract_machine::validate_net(&net));

	NetRef endpoint = mutate_second ? second_principal : first_principal;
	if (guard == 0)
	{
		net.ports.get_ref(endpoint).wire_id =
			delta_net_abstract_machine::INVALID_NET_REF;
	}
	else if (guard == 1)
	{
		net.ports.get_ref(endpoint).slot.type = AUXILIARY;
	}
	else if (guard == 2)
	{
		net.ports.get_ref(endpoint).node_id =
			delta_net_abstract_machine::INVALID_NET_REF;
	}
	else
	{
		assert(guard == 3);
		Node* owner = net.nodes.get_ref(mutate_second ? second : first);
		owner.agent.eraser.principal =
			mutate_second ? first_principal : second_principal;
	}

	Eraser first_before = net.nodes.get_ref(first).agent.eraser;
	Eraser second_before = net.nodes.get_ref(second).agent.eraser;
	Port first_port_before = *net.ports.get_ref(first_principal);
	Port second_port_before = *net.ports.get_ref(second_principal);
	Wire wire_before = *net.wires.get_ref(active_wire);
	usz node_count = net.nodes.len();
	usz port_count = net.ports.len();
	usz wire_count = net.wires.len();
	usz interface_count = net.interfaces.len();
	SlotId node_next = net.nodes.next_id;
	SlotId port_next = net.ports.next_id;
	SlotId wire_next = net.wires.next_id;
	SlotId interface_next = net.interfaces.next_id;
	SlotId continuation_next = net.effects.continuations.next_id;
	usz commit_count = net.effects.commits.len;
	usz committed = net.effects.committed;
	ulong program_epoch = net.effects.program_epoch;
	ulong execution_epoch = net.effects.execution_epoch;

	assert(!delta_net_abstract_machine::interact(&net, active_wire));

	assert(net.nodes.len() == node_count);
	assert(net.ports.len() == port_count);
	assert(net.wires.len() == wire_count);
	assert(net.interfaces.len() == interface_count);
	assert(net.nodes.next_id == node_next);
	assert(net.ports.next_id == port_next);
	assert(net.wires.next_id == wire_next);
	assert(net.interfaces.next_id == interface_next);
	assert(net.effects.continuations.next_id == continuation_next);
	assert(net.effects.commits.len == commit_count);
	assert(net.effects.committed == committed);
	assert(net.effects.program_epoch == program_epoch);
	assert(net.effects.execution_epoch == execution_epoch);
	assert(net.nodes.contains_ref(first));
	assert(net.nodes.contains_ref(second));
	assert(net.nodes.get_ref(first).type == ERASER);
	assert(net.nodes.get_ref(second).type == ERASER);
	assert(net.nodes.get_ref(first).agent.eraser.principal
		== first_before.principal);
	assert(net.nodes.get_ref(second).agent.eraser.principal
		== second_before.principal);
	assert_port_preserved(&net, first_principal, first_port_before);
	assert_port_preserved(&net, second_principal, second_port_before);
	assert_wire_preserved(&net, active_wire, wire_before);
}

fn void inactive_wire_rejects_each_endpoint_back_reference_mismatch() @test
{
	run_inactive_wire_guard_case(0, false);
	run_inactive_wire_guard_case(0, true);
}

fn void inactive_wire_rejects_each_nonprincipal_endpoint() @test
{
	run_inactive_wire_guard_case(1, false);
	run_inactive_wire_guard_case(1, true);
}

fn void inactive_wire_rejects_each_missing_endpoint_owner() @test
{
	run_inactive_wire_guard_case(2, false);
	run_inactive_wire_guard_case(2, true);
}

fn void inactive_wire_rejects_each_unreferenced_node_port() @test
{
	run_inactive_wire_guard_case(3, false);
	run_inactive_wire_guard_case(3, true);
}

fn void run_equal_replicator_case(
	bool reverse_endpoints,
	bool first_principal_is_parent
)
{
	Net net;
	net.init();
	defer net.free();

	Polarity first_polarity =
		first_principal_is_parent ? PARENT : CHILD;
	Polarity second_polarity = opposite(first_polarity);
	NetRef first = add_replicator(&net, 2, 2, first_polarity);
	NetRef second = add_replicator(&net, 2, 2, second_polarity);
	NetRef first_principal = principal(&net, first);
	NetRef second_principal = principal(&net, second);
	NetRef first_left = net.nodes.get_ref(first).agent.replicator.auxiliaries[0];
	NetRef first_right = net.nodes.get_ref(first).agent.replicator.auxiliaries[1];
	NetRef second_left = net.nodes.get_ref(second).agent.replicator.auxiliaries[0];
	NetRef second_right = net.nodes.get_ref(second).agent.replicator.auxiliaries[1];
	NetRef first_left_external = add_external_port(
		&net, opposite(net.ports.get_ref(first_left).polarity)
	);
	NetRef first_right_external = add_external_port(
		&net, opposite(net.ports.get_ref(first_right).polarity)
	);
	NetRef second_left_external = add_external_port(
		&net, opposite(net.ports.get_ref(second_left).polarity)
	);
	NetRef second_right_external = add_external_port(
		&net, opposite(net.ports.get_ref(second_right).polarity)
	);
	connect(&net, first_left, first_left_external);
	connect(&net, first_right, first_right_external);
	connect(&net, second_left, second_left_external);
	connect(&net, second_right, second_right_external);
	NetRef first_left_wire = net.ports.get_ref(first_left).wire_id;
	NetRef first_right_wire = net.ports.get_ref(first_right).wire_id;
	NetRef second_left_wire = net.ports.get_ref(second_left).wire_id;
	NetRef second_right_wire = net.ports.get_ref(second_right).wire_id;
	if (reverse_endpoints)
	{
		connect(&net, second_principal, first_principal);
	}
	else
	{
		connect(&net, first_principal, second_principal);
	}

	delta_net_abstract_machine::interact(
		&net, net.ports.get_ref(first_principal).wire_id
	);

	// Equal-coordinate annihilation retains the auxiliaries belonging to wire.a.
	NetRef surviving_left_wire =
		reverse_endpoints ? second_left_wire : first_left_wire;
	NetRef surviving_right_wire =
		reverse_endpoints ? second_right_wire : first_right_wire;
	assert(net.nodes.len() == 4);
	assert(net.wires.len() == 2);
	assert(wire_connects(
		&net, surviving_left_wire, first_left_external, second_left_external
	));
	assert(wire_connects(
		&net, surviving_right_wire, first_right_external, second_right_external
	));
	assert(net.ports.get_ref(first_left_external).wire_id
		== surviving_left_wire);
	assert(net.ports.get_ref(first_right_external).wire_id
		== surviving_right_wire);
	assert(net.ports.get_ref(second_left_external).wire_id
		== surviving_left_wire);
	assert(net.ports.get_ref(second_right_external).wire_id
		== surviving_right_wire);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void equal_replicators_annihilate_for_each_endpoint_order_and_polarity() @test
{
	run_equal_replicator_case(false, false);
	run_equal_replicator_case(false, true);
	run_equal_replicator_case(true, false);
	run_equal_replicator_case(true, true);
}

fn void run_unequal_replicator_case(bool higher_first)
{
	Net net;
	net.init();
	defer net.free();

	NetRef higher = add_replicator(&net, 4, 2);
	NetRef lower = add_replicator(&net, 1, 2, PARENT);
	NetRef higher_principal = principal(&net, higher);
	NetRef lower_principal = principal(&net, lower);
	NetRef higher_first_auxiliary = net.nodes.get_ref(higher).agent.replicator.auxiliaries[0];
	NetRef higher_second_auxiliary = net.nodes.get_ref(higher).agent.replicator.auxiliaries[1];
	NetRef lower_first_auxiliary = net.nodes.get_ref(lower).agent.replicator.auxiliaries[0];
	NetRef lower_second_auxiliary = net.nodes.get_ref(lower).agent.replicator.auxiliaries[1];
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

	assert(!net.nodes.contains_ref(higher));
	assert(!net.nodes.contains_ref(lower));
	assert(net.nodes.len() == 8);
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


fn void oversized_different_coordinate_replicator_expansion_rejects_atomically() @test
{
	// 1_414² Cartesian cells have a logical footprint of 10_004_050,
	// just beyond DELTA_MAX_EVALUATION_STEPS, while the fixture stays small.
	const sz ARITY = 1_414;
	Net net;
	net.init();
	defer net.free();

	NetRef earlier = add_replicator(&net, 4, ARITY);
	NetRef later = add_replicator(&net, 1, ARITY, PARENT);
	Replicator* earlier_value =
		&net.nodes.get_ref(earlier).agent.replicator;
	Replicator* later_value =
		&net.nodes.get_ref(later).agent.replicator;
	earlier_value.observable = true;
	earlier_value.origin = 101;
	later_value.observable = true;
	later_value.origin = 202;
	NetRef earlier_principal = earlier_value.principal;
	NetRef later_principal = later_value.principal;
	connect(&net, earlier_principal, later_principal);
	NetRef principal_wire = net.ports.get_ref(earlier_principal).wire_id;

	Replicator earlier_snapshot = *earlier_value;
	Replicator later_snapshot = *later_value;
	Port earlier_port = *net.ports.get_ref(earlier_principal);
	Port later_port = *net.ports.get_ref(later_principal);
	Wire wire = *net.wires.get_ref(principal_wire);
	usz node_count = net.nodes.len();
	usz port_count = net.ports.len();
	usz wire_count = net.wires.len();

	assert(!delta_net_abstract_machine::interact(&net, principal_wire));
	assert(net.nodes.len() == node_count);
	assert(net.ports.len() == port_count);
	assert(net.wires.len() == wire_count);
	assert(net.nodes.contains_ref(earlier));
	assert(net.nodes.contains_ref(later));
	Replicator* retained_earlier =
		&net.nodes.get_ref(earlier).agent.replicator;
	Replicator* retained_later =
		&net.nodes.get_ref(later).agent.replicator;
	assert(retained_earlier.principal == earlier_snapshot.principal);
	assert(retained_earlier.auxiliaries.ptr
		== earlier_snapshot.auxiliaries.ptr);
	assert(retained_earlier.auxiliaries.len
		== earlier_snapshot.auxiliaries.len);
	assert(retained_earlier.origin == earlier_snapshot.origin);
	assert(retained_earlier.delta_level == earlier_snapshot.delta_level);
	assert(retained_earlier.status == earlier_snapshot.status);
	assert(retained_earlier.observable == earlier_snapshot.observable);
	assert(retained_later.principal == later_snapshot.principal);
	assert(retained_later.auxiliaries.ptr == later_snapshot.auxiliaries.ptr);
	assert(retained_later.auxiliaries.len
		== later_snapshot.auxiliaries.len);
	assert(retained_later.origin == later_snapshot.origin);
	assert(retained_later.delta_level == later_snapshot.delta_level);
	assert(retained_later.status == later_snapshot.status);
	assert(retained_later.observable == later_snapshot.observable);
	assert_port_preserved(&net, earlier_principal, earlier_port);
	assert_port_preserved(&net, later_principal, later_port);
	assert_wire_preserved(&net, principal_wire, wire);
}

fn void net_validator_accepts_a_fully_wired_fan_and_boundaries() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef fan = add_fan(&net);
	Node* node = net.nodes.get_ref(fan);
	connect(&net, node.agent.fan.principal, add_external_port(&net, CHILD));
	connect(&net, node.agent.fan.left, add_external_port(&net, PARENT));
	connect(&net, node.agent.fan.right, add_external_port(&net, CHILD));

	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void net_validator_rejects_a_dangling_wire_endpoint() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef fan = add_fan(&net);
	Node* node = net.nodes.get_ref(fan);
	NetRef external_principal = add_external_port(&net);
	connect(&net, node.agent.fan.principal, external_principal);
	net.ports.get_ref(external_principal).polarity = CHILD;
	connect(&net, node.agent.fan.left, add_external_port(&net, PARENT));
	connect(&net, node.agent.fan.right, add_external_port(&net, CHILD));
	net.ports.erase(external_principal);

	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void net_validator_rejects_an_invalid_node_port_slot() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef fan = add_fan(&net);
	Node* node = net.nodes.get_ref(fan);
	connect(&net, node.agent.fan.principal, add_external_port(&net, CHILD));
	connect(&net, node.agent.fan.left, add_external_port(&net, PARENT));
	connect(&net, node.agent.fan.right, add_external_port(&net, CHILD));
	node.agent.fan.left = node.agent.fan.principal;

	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void net_validator_rejects_replicator_auxiliary_with_principal_polarity() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef replicator = add_replicator(&net, 0, 2);
	Node* node = net.nodes.get_ref(replicator);
	connect(&net, node.agent.replicator.principal, add_external_port(&net, PARENT));
	NetRef mutated_auxiliary = node.agent.replicator.auxiliaries[0];
	NetRef mutated_boundary = add_external_port(&net, CHILD);
	connect(&net, mutated_auxiliary, mutated_boundary);
	for (usz index = 1; index < node.agent.replicator.auxiliaries.len; index++)
	{
		connect(
			&net,
			node.agent.replicator.auxiliaries[index],
			add_external_port(&net, CHILD)
		);
	}
	assert(delta_net_abstract_machine::validate_net(&net));

	net.ports.get_ref(mutated_auxiliary).polarity = CHILD;
	net.ports.get_ref(mutated_boundary).polarity = PARENT;

	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void graph_constructors_populate_owned_ports_and_metadata() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef fan_id = delta_net_abstract_machine::new_fan(&net);
	NetRef eraser_id = delta_net_abstract_machine::new_eraser(&net);
	long[] deltas = mem::alloc_array(long, 2);
	defer mem::free(deltas);
	deltas[0] = -1;
	deltas[1] = 2;
	NetRef replicator_id = delta_net_abstract_machine::new_replicator(
		&net, 4, deltas, UNKNOWN, PARENT);
	NetRef root_id = delta_net_abstract_machine::new_interface(&net, ROOT, "");
	NetRef free_id = delta_net_abstract_machine::new_interface(
		&net, FREE_VARIABLE, "x");
	assert(net.ports.get_ref(net.interfaces.get_ref(root_id).port).polarity
		== CHILD);
	assert(net.ports.get_ref(net.interfaces.get_ref(free_id).port).polarity
		== PARENT);

	Node* fan = net.nodes.get_ref(fan_id);
	assert(fan.type == FAN);
	assert(net.ports.get_ref(fan.agent.fan.principal).node_id == fan_id);
	assert(net.ports.get_ref(fan.agent.fan.left).slot.type == LEFT);
	assert(net.ports.get_ref(fan.agent.fan.right).slot.type == RIGHT);
	assert(net.ports.get_ref(fan.agent.fan.principal).polarity == PARENT);
	assert(net.ports.get_ref(fan.agent.fan.left).polarity == CHILD);
	assert(net.ports.get_ref(fan.agent.fan.right).polarity == PARENT);

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
		assert(port.slot.properties.value.position == (usz)idx);
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

	NetRef first = delta_net_abstract_machine::new_eraser(&net);
	NetRef second = delta_net_abstract_machine::new_eraser(&net);
	NetRef third = delta_net_abstract_machine::new_eraser(&net);
	NetRef fourth = delta_net_abstract_machine::new_eraser(&net);
	NetRef first_port = principal(&net, first);
	NetRef second_port = principal(&net, second);
	NetRef third_port = principal(&net, third);
	NetRef fourth_port = principal(&net, fourth);
	net.ports.get_ref(second_port).polarity = PARENT;
	net.ports.get_ref(fourth_port).polarity = PARENT;

	NetRef first_wire = delta_net_abstract_machine::connect(
		&net, first_port, second_port);
	NetRef second_wire = delta_net_abstract_machine::connect(
		&net, third_port, fourth_port);
	assert(delta_net_abstract_machine::other_endpoint(
		&net, first_wire, first_port) == second_port);

	NetRef surviving_wire = delta_net_abstract_machine::splice(
		&net, second_port, third_port);
	assert(surviving_wire == first_wire);
	assert(!net.wires.contains_ref(second_wire));
	assert(wire_connects(&net, surviving_wire, first_port, fourth_port));
	assert(net.ports.get_ref(first_port).wire_id == surviving_wire);
	assert(net.ports.get_ref(fourth_port).wire_id == surviving_wire);
	assert(net.ports.get_ref(second_port).wire_id
		== delta_net_abstract_machine::INVALID_NET_REF);
	assert(net.ports.get_ref(third_port).wire_id
		== delta_net_abstract_machine::INVALID_NET_REF);

	delta_net_abstract_machine::disconnect(&net, surviving_wire);
	assert(net.wires.is_empty());
	assert(net.ports.get_ref(first_port).wire_id
		== delta_net_abstract_machine::INVALID_NET_REF);
	assert(net.ports.get_ref(fourth_port).wire_id
		== delta_net_abstract_machine::INVALID_NET_REF);
}

fn void destroy_node_removes_owned_ports_and_incident_wires() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef fan = delta_net_abstract_machine::new_fan(&net);
	NetRef eraser = delta_net_abstract_machine::new_eraser(&net);
	NetRef fan_principal = principal(&net, fan);
	NetRef eraser_principal = principal(&net, eraser);
	delta_net_abstract_machine::connect(&net, fan_principal, eraser_principal);

	delta_net_abstract_machine::destroy_node(&net, fan);

	assert(!net.nodes.contains_ref(fan));
	assert(net.nodes.contains_ref(eraser));
	assert(net.ports.len() == 1);
	assert(net.wires.is_empty());
	assert(net.ports.get_ref(eraser_principal).wire_id
		== delta_net_abstract_machine::INVALID_NET_REF);

	delta_net_abstract_machine::destroy_node(&net, eraser);
	assert(net.nodes.is_empty());
	assert(net.ports.is_empty());
}

fn void net_validator_rejects_equal_endpoint_polarities() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef first = add_external_port(&net, PARENT);
	NetRef second = add_external_port(&net, PARENT);
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
	NetRef source_node = delta_net_abstract_machine::new_replicator(
		&net, 7, deltas, UNKNOWN, PARENT);
	NetRef target_node = delta_net_abstract_machine::new_eraser(&net);
	NetRef interface_id = delta_net_abstract_machine::new_interface(
		&net, FREE_VARIABLE, "clone-source");
	NetRef interface_port = net.interfaces.get_ref(interface_id).port;
	NetRef[] sources =
		net.nodes.get_ref(source_node).agent.replicator.auxiliaries;
	NetRef source_wire = delta_net_abstract_machine::connect(
		&net, sources[0], interface_port);

	NetRef single_clone = delta_net_abstract_machine::clone_port(
		&net, sources[0], target_node);
	Port* source = net.ports.get_ref(sources[0]);
	Port* clone = net.ports.get_ref(single_clone);
	assert(clone.node_id == target_node);
	assert(clone.wire_id == delta_net_abstract_machine::INVALID_NET_REF);
	assert(clone.slot.type == source.slot.type);
	assert(clone.slot.properties.has_value);
	assert(clone.slot.properties.value.position
		== source.slot.properties.value.position);
	assert(clone.slot.properties.value.delta_level
		== source.slot.properties.value.delta_level);
	assert(clone.polarity == source.polarity);
	assert(source.wire_id == source_wire);

	NetRef[] clones = delta_net_abstract_machine::clone_ports(
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
			== delta_net_abstract_machine::INVALID_NET_REF);
		assert(copied.slot.type == original.slot.type);
		assert(copied.slot.properties.has_value
			== original.slot.properties.has_value);
		assert(copied.slot.properties.value.delta_level
			== original.slot.properties.value.delta_level);
		assert(copied.polarity == original.polarity);
	}
}

fn void net_validator_rejects_an_ownerless_connected_port() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef root = delta_net_abstract_machine::new_interface(&net, ROOT, "");
	NetRef free = delta_net_abstract_machine::new_interface(
		&net, FREE_VARIABLE, "ownerless-peer"
	);
	NetRef root_port = net.interfaces.get_ref(root).port;
	NetRef free_port = net.interfaces.get_ref(free).port;
	delta_net_abstract_machine::connect(&net, root_port, free_port);
	assert(delta_net_abstract_machine::validate_net(&net));

	net.interfaces.erase(root);
	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void net_validator_rejects_practical_storage_type_mismatch() @test
{
	Net net;
	net.init();
	defer net.free();

	LayoutHandle backing_layout = register_shared_layout(
		&net, (mitos::TypeId)41, "NodeTestBackingType"
	);
	(void)register_shared_layout(
		&net, (mitos::TypeId)42, "NodeTestAdvertisedType"
	);
	char[16] bytes;
	foreach (index, &byte : bytes) *byte = (char)index;
	StorageHandle storage =
		allocate_shared_storage(&net, backing_layout, bytes[..], 8);
	NetRef value = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 41
	);
	PracticalAgent* practical = &net.nodes.get_ref(value).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, value, &storage, 2, 8
	));
	delta_net_abstract_machine::connect(
		&net, practical.principal, add_external_port(&net, CHILD)
	);
	assert(delta_net_abstract_machine::validate_net(&net));

	practical.type_id = 42;
	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void net_validator_rejects_practical_storage_stride_mismatch() @test
{
	Net net;
	net.init();
	defer net.free();

	LayoutHandle layout = register_shared_layout(
		&net, (mitos::TypeId)43, "NodeTestStride"
	);
	char[16] bytes;
	foreach (index, &byte : bytes) *byte = (char)(index + 1);
	StorageHandle storage =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	NetRef value = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 43
	);
	PracticalAgent* practical = &net.nodes.get_ref(value).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, value, &storage, 2, 8
	));
	delta_net_abstract_machine::connect(
		&net, practical.principal, add_external_port(&net, CHILD)
	);
	assert(delta_net_abstract_machine::validate_net(&net));

	// Preserve the same total byte length while advertising a different layout.
	practical.storage_count = 4;
	practical.storage_stride = 4;
	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void net_validator_rejects_dual_practical_payload_authority() @test
{
	Net net;
	net.init();
	defer net.free();

	LayoutHandle layout = register_shared_layout(
		&net, (mitos::TypeId)44, "NodeTestDualPayload"
	);
	char[8] bytes;
	foreach (index, &byte : bytes) *byte = (char)(index + 3);
	StorageHandle storage =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	NetRef value = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 44
	);
	PracticalAgent* practical = &net.nodes.get_ref(value).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, value, &storage, 1, 8
	));
	delta_net_abstract_machine::connect(
		&net, practical.principal, add_external_port(&net, CHILD)
	);
	assert(delta_net_abstract_machine::validate_net(&net));

	practical.text = "conflicting-payload".copy(mem);
	practical.owns_text = true;
	assert(!delta_net_abstract_machine::validate_net(&net));
}

fn void practical_storage_attachment_consumes_one_owner_lease() @test
{
	Net net;
	net.init();
	defer net.free();

	LayoutHandle layout = register_shared_layout(
		&net, (mitos::TypeId)45, "NodeTestUniqueLease"
	);
	char[8] bytes;
	foreach (index, &byte : bytes) *byte = (char)(index + 5);
	StorageHandle source =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	StorageHandle copied_alias = source;
	NetRef first = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 45
	);
	NetRef second = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 45
	);
	PracticalAgent* first_value = &net.nodes.get_ref(first).agent.practical;
	PracticalAgent* second_value = &net.nodes.get_ref(second).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, first, &source, 1, 8
	));
	assert(source == mitos_storage::INVALID_STORAGE_HANDLE);
	assert(!delta_net_abstract_machine::practical_agent_take_storage(
		&net, second, &copied_alias, 1, 8
	));
	delta_net_abstract_machine::connect(
		&net, first_value.principal, add_external_port(&net, CHILD)
	);
	delta_net_abstract_machine::connect(
		&net, second_value.principal, add_external_port(&net, CHILD)
	);
	assert(delta_net_abstract_machine::validate_net(&net));

	// Deliberately duplicate the still-live attached owner at the validation
	// boundary. Each node is individually well-formed; only owner uniqueness
	// makes the combined net invalid.
	second_value.storage = first_value.storage;
	second_value.storage_policy = first_value.storage_policy;
	second_value.storage_count = first_value.storage_count;
	second_value.storage_stride = first_value.storage_stride;
	assert(!delta_net_abstract_machine::validate_net(&net));

	// Restore single ownership before cleanup so the lease is released once.
	second_value.storage = mitos_storage::INVALID_STORAGE_HANDLE;
	second_value.storage_policy = COPY_TRIVIAL;
	second_value.storage_count = 0;
	second_value.storage_stride = 0;
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void identical_live_storage_owner_alias_pair_is_rejected_atomically() @test
{
	Net net;
	net.init();
	defer net.free();

	mitos::TypeId array_type = (mitos::TypeId)55;
	LayoutHandle layout = register_shared_layout(
		&net, array_type, "NodeTestIdenticalLiveOwnerAliasPair"
	);
	char[16] bytes;
	foreach (index, &byte : bytes) *byte = (char)(index + 61);
	StorageHandle source =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	NetRef first = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, (uint)array_type
	);
	NetRef second = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, (uint)array_type
	);
	PracticalAgent* first_value = &net.nodes.get_ref(first).agent.practical;
	PracticalAgent* second_value = &net.nodes.get_ref(second).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, first, &source, 2, 8
	));
	assert(source == mitos_storage::INVALID_STORAGE_HANDLE);
	second_value.storage = first_value.storage;
	second_value.storage_policy = first_value.storage_policy;
	second_value.storage_count = first_value.storage_count;
	second_value.storage_stride = first_value.storage_stride;
	net.ports.get_ref(second_value.principal).polarity = CHILD;
	NetRef active_wire = delta_net_abstract_machine::connect(
		&net, first_value.principal, second_value.principal
	);
	assert(!delta_net_abstract_machine::validate_net(&net));

	PracticalAgent first_before = *first_value;
	PracticalAgent second_before = *second_value;
	Port first_port_before = *net.ports.get_ref(first_before.principal);
	Port second_port_before = *net.ports.get_ref(second_before.principal);
	Wire wire_before = *net.wires.get_ref(active_wire);
	usz node_count = net.nodes.len();
	usz port_count = net.ports.len();
	usz wire_count = net.wires.len();
	usz interface_count = net.interfaces.len();
	SlotId node_next = net.nodes.next_id;
	SlotId port_next = net.ports.next_id;
	SlotId wire_next = net.wires.next_id;
	SlotId interface_next = net.interfaces.next_id;
	SlotId continuation_next = net.effects.continuations.next_id;
	usz commit_count = net.effects.commits.len;
	usz committed = net.effects.committed;
	ulong program_epoch = net.effects.program_epoch;
	ulong execution_epoch = net.effects.execution_epoch;
	mitos_storage::StorageMetadata metadata;
	assert(mitos_storage::storage_metadata(
		&net.storage, first_before.storage, &metadata
	) == STORAGE_OK);
	assert(metadata.owner_count == 1);

	assert(!delta_net_abstract_machine::interact(&net, active_wire));

	assert(net.nodes.len() == node_count);
	assert(net.ports.len() == port_count);
	assert(net.wires.len() == wire_count);
	assert(net.interfaces.len() == interface_count);
	assert(net.nodes.next_id == node_next);
	assert(net.ports.next_id == port_next);
	assert(net.wires.next_id == wire_next);
	assert(net.interfaces.next_id == interface_next);
	assert(net.effects.continuations.next_id == continuation_next);
	assert(net.effects.commits.len == commit_count);
	assert(net.effects.committed == committed);
	assert(net.effects.program_epoch == program_epoch);
	assert(net.effects.execution_epoch == execution_epoch);
	assert_practical_preserved(&net, first, ARRAY_AGENT, first_before);
	assert_practical_preserved(&net, second, ARRAY_AGENT, second_before);
	assert_port_preserved(&net, first_before.principal, first_port_before);
	assert_port_preserved(&net, second_before.principal, second_port_before);
	assert_wire_preserved(&net, active_wire, wire_before);
	assert(mitos_storage::storage_metadata(
		&net.storage, first_before.storage, &metadata
	) == STORAGE_OK);
	assert(metadata.owner_count == 1);

	// Restore the deliberately forged alias before the single real owner frees.
	second_value.storage = mitos_storage::INVALID_STORAGE_HANDLE;
	second_value.storage_policy = COPY_TRIVIAL;
	second_value.storage_count = 0;
	second_value.storage_stride = 0;
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void unequal_stored_array_payloads_preserve_the_active_pair() @test
{
	Net net;
	net.init();
	defer net.free();

	LayoutHandle layout = register_shared_layout(
		&net, (mitos::TypeId)46, "NodeTestUnequalArrayPair"
	);
	char[16] left_bytes;
	char[16] right_bytes;
	foreach (index, &byte : left_bytes) *byte = (char)(index + 11);
	foreach (index, &byte : right_bytes) *byte = (char)(index + 11);
	right_bytes[15] = (char)99;
	StorageHandle left_storage =
		allocate_shared_storage(&net, layout, left_bytes[..], 8);
	StorageHandle right_storage =
		allocate_shared_storage(&net, layout, right_bytes[..], 8);
	NetRef left = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 46
	);
	NetRef right = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 46
	);
	PracticalAgent* left_value = &net.nodes.get_ref(left).agent.practical;
	PracticalAgent* right_value = &net.nodes.get_ref(right).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, left, &left_storage, 2, 8
	));
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, right, &right_storage, 2, 8
	));
	net.ports.get_ref(right_value.principal).polarity = CHILD;
	NetRef active_wire = delta_net_abstract_machine::connect(
		&net, left_value.principal, right_value.principal
	);
	assert(delta_net_abstract_machine::validate_net(&net));

	assert(!delta_net_abstract_machine::interact(&net, active_wire));
	assert(net.nodes.contains_ref(left));
	assert(net.nodes.contains_ref(right));
	assert(net.wires.contains_ref(active_wire));
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void equal_stored_array_payloads_consume_the_pair_and_release_leases() @test
{
	Net net;
	net.init();
	defer net.free();

	LayoutHandle layout = register_shared_layout(
		&net, (mitos::TypeId)47, "NodeTestEqualArrayPair"
	);
	char[16] bytes;
	foreach (index, &byte : bytes) *byte = (char)(index + 19);
	StorageHandle left_storage =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	StorageHandle right_storage =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	NetRef left = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 47
	);
	NetRef right = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 47
	);
	PracticalAgent* left_value = &net.nodes.get_ref(left).agent.practical;
	PracticalAgent* right_value = &net.nodes.get_ref(right).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, left, &left_storage, 2, 8
	));
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, right, &right_storage, 2, 8
	));
	StorageHandle retired_left = left_value.storage;
	StorageHandle retired_right = right_value.storage;
	net.ports.get_ref(right_value.principal).polarity = CHILD;
	NetRef active_wire = delta_net_abstract_machine::connect(
		&net, left_value.principal, right_value.principal
	);
	assert(delta_net_abstract_machine::validate_net(&net));

	assert(delta_net_abstract_machine::interact(&net, active_wire));
	assert(!net.nodes.contains_ref(left));
	assert(!net.nodes.contains_ref(right));
	assert(!net.wires.contains_ref(active_wire));
	mitos_storage::StorageMetadata metadata;
	assert(mitos_storage::storage_metadata(
		&net.storage, retired_left, &metadata
	) == STORAGE_INVALID_HANDLE);
	assert(mitos_storage::storage_metadata(
		&net.storage, retired_right, &metadata
	) == STORAGE_INVALID_HANDLE);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void destroying_a_stored_array_releases_its_lease_immediately() @test
{
	Net net;
	net.init();
	defer net.free();

	LayoutHandle layout = register_shared_layout(
		&net, (mitos::TypeId)48, "NodeTestDestroyArray"
	);
	char[8] bytes;
	foreach (index, &byte : bytes) *byte = (char)(index + 23);
	StorageHandle storage =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	NetRef value = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 48
	);
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, value, &storage, 1, 8
	));
	StorageHandle retired =
		net.nodes.get_ref(value).agent.practical.storage;

	delta_net_abstract_machine::destroy_node(&net, value);

	assert(!net.nodes.contains_ref(value));
	mitos_storage::StorageMetadata metadata;
	assert(mitos_storage::storage_metadata(
		&net.storage, retired, &metadata
	) == STORAGE_INVALID_HANDLE);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void storage_attachment_rejects_scalar_and_foreign_refs_without_consuming_source() @test
{
	Net net;
	net.init();
	defer net.free();
	Net foreign_net;
	foreign_net.init();
	defer foreign_net.free();

	LayoutHandle layout = register_shared_layout(
		&net, (mitos::TypeId)49, "NodeTestRejectedAttachment"
	);
	char[8] bytes;
	foreach (index, &byte : bytes) *byte = (char)(index + 29);
	StorageHandle source =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	StorageHandle source_lease = source;
	NetRef scalar = delta_net_abstract_machine::new_practical_agent(
		&net, I64_AGENT, 0, 0, 49
	);
	NetRef foreign = delta_net_abstract_machine::new_practical_agent(
		&foreign_net, ARRAY_AGENT, 0, 0, 49
	);
	delta_net_abstract_machine::destroy_node(&foreign_net, foreign);
	foreign = delta_net_abstract_machine::new_practical_agent(
		&foreign_net, ARRAY_AGENT, 0, 0, 49
	);
	assert(foreign.id == scalar.id);
	assert(foreign != scalar);
	assert(!net.nodes.contains_ref(foreign));

	assert(!delta_net_abstract_machine::practical_agent_take_storage(
		&net, scalar, &source, 1, 8
	));
	assert(source == source_lease);
	mitos_storage::StorageMetadata metadata;
	assert(mitos_storage::storage_metadata(
		&net.storage, source, &metadata
	) == STORAGE_OK);
	assert(!delta_net_abstract_machine::practical_agent_take_storage(
		&net, foreign, &source, 1, 8
	));
	assert(source == source_lease);
	assert(mitos_storage::storage_metadata(
		&net.storage, source, &metadata
	) == STORAGE_OK);
}

fn void string_and_array_storage_kinds_reject_cross_attachment_and_validation() @test
{
	Net net;
	net.init();
	defer net.free();

	LayoutHandle string_layout = register_shared_layout(
		&net,
		mitos::TYPE_ID_STRING,
		"NodeTestCanonicalString",
		mitos::TYPE_ID_INVALID,
		1
	);
	mitos::TypeId array_type = (mitos::TypeId)52;
	LayoutHandle array_layout = register_shared_layout(
		&net, array_type, "NodeTestCanonicalI64Array"
	);
	char[4] string_bytes = { 'm', 'i', 't', 'o' };
	char[8] array_bytes;
	foreach (index, &byte : array_bytes) *byte = (char)(index + 37);
	StorageHandle string_source = allocate_shared_storage(
		&net, string_layout, string_bytes[..], 1
	);
	StorageHandle array_source = allocate_shared_storage(
		&net, array_layout, array_bytes[..], 8
	);
	StorageHandle original_string_source = string_source;
	StorageHandle original_array_source = array_source;
	NetRef string_node = delta_net_abstract_machine::new_practical_agent(
		&net, STRING_AGENT, 0, 0, (uint)mitos::TYPE_ID_STRING
	);
	NetRef array_node = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, (uint)array_type
	);

	assert(!delta_net_abstract_machine::practical_agent_take_storage(
		&net, string_node, &array_source, 1, 8
	));
	assert(array_source == original_array_source);
	mitos_storage::StorageMetadata metadata;
	assert(mitos_storage::storage_metadata(
		&net.storage, array_source, &metadata
	) == STORAGE_OK);
	assert(metadata.owner_count == 1);
	assert(metadata.kind == LAYOUT_SEQUENCE);
	assert(metadata.element_type == mitos::TYPE_ID_I64);
	assert(!delta_net_abstract_machine::practical_agent_take_storage(
		&net, array_node, &string_source, string_bytes.len, 1
	));
	assert(string_source == original_string_source);
	assert(mitos_storage::storage_metadata(
		&net.storage, string_source, &metadata
	) == STORAGE_OK);
	assert(metadata.owner_count == 1);
	assert(metadata.type_id == mitos::TYPE_ID_STRING);
	assert(metadata.kind == LAYOUT_SEQUENCE);
	assert(metadata.element_type == mitos::TYPE_ID_INVALID);

	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, string_node, &string_source, string_bytes.len, 1
	));
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, array_node, &array_source, 1, 8
	));
	assert(string_source == mitos_storage::INVALID_STORAGE_HANDLE);
	assert(array_source == mitos_storage::INVALID_STORAGE_HANDLE);
	PracticalAgent* string_value =
		&net.nodes.get_ref(string_node).agent.practical;
	PracticalAgent* array_value =
		&net.nodes.get_ref(array_node).agent.practical;
	delta_net_abstract_machine::connect(
		&net, string_value.principal, add_external_port(&net, CHILD)
	);
	delta_net_abstract_machine::connect(
		&net, array_value.principal, add_external_port(&net, CHILD)
	);
	assert(delta_net_abstract_machine::validate_net(&net));

	net.nodes.get_ref(string_node).type = ARRAY_AGENT;
	assert(!delta_net_abstract_machine::validate_net(&net));
	net.nodes.get_ref(string_node).type = STRING_AGENT;
	assert(delta_net_abstract_machine::validate_net(&net));
	net.nodes.get_ref(array_node).type = STRING_AGENT;
	assert(!delta_net_abstract_machine::validate_net(&net));
	net.nodes.get_ref(array_node).type = ARRAY_AGENT;
	assert(delta_net_abstract_machine::validate_net(&net));
}


fn void inline_and_stored_strings_compare_by_immutable_bytes() @test
{
	Net equal_net;
	equal_net.init();
	defer equal_net.free();
	LayoutHandle equal_layout = register_shared_layout(
		&equal_net,
		mitos::TYPE_ID_STRING,
		"NodeTestMixedEqualString",
		mitos::TYPE_ID_INVALID,
		1
	);
	char[5] equal_bytes = { 'm', 'i', 't', 'o', 's' };
	StorageHandle equal_source = allocate_shared_storage(
		&equal_net, equal_layout, equal_bytes[..], 1
	);
	NetRef inline_equal = delta_net_abstract_machine::new_practical_agent(
		&equal_net, STRING_AGENT, 0, 0, (uint)mitos::TYPE_ID_STRING
	);
	NetRef stored_equal = delta_net_abstract_machine::new_practical_agent(
		&equal_net, STRING_AGENT, 0, 0, (uint)mitos::TYPE_ID_STRING
	);
	PracticalAgent* inline_value =
		&equal_net.nodes.get_ref(inline_equal).agent.practical;
	PracticalAgent* stored_value =
		&equal_net.nodes.get_ref(stored_equal).agent.practical;
	inline_value.text = "mitos".copy(mem);
	inline_value.owns_text = true;
	assert(inline_value.storage_policy == COPY_TRIVIAL);
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&equal_net, stored_equal, &equal_source, equal_bytes.len, 1
	));
	StorageHandle retired = stored_value.storage;
	equal_net.ports.get_ref(stored_value.principal).polarity = CHILD;
	NetRef equal_wire = delta_net_abstract_machine::connect(
		&equal_net, inline_value.principal, stored_value.principal
	);
	assert(delta_net_abstract_machine::validate_net(&equal_net));
	equal_net.nodes.get_ref(inline_equal).type = ARRAY_AGENT;
	equal_net.nodes.get_ref(stored_equal).type = ARRAY_AGENT;
	assert(!delta_net_abstract_machine::validate_net(&equal_net));
	assert(!delta_net_abstract_machine::interact(&equal_net, equal_wire));
	assert(equal_net.nodes.contains_ref(inline_equal));
	assert(equal_net.nodes.contains_ref(stored_equal));
	assert(equal_net.wires.contains_ref(equal_wire));
	equal_net.nodes.get_ref(inline_equal).type = STRING_AGENT;
	equal_net.nodes.get_ref(stored_equal).type = STRING_AGENT;
	assert(delta_net_abstract_machine::validate_net(&equal_net));
	assert(delta_net_abstract_machine::interact(&equal_net, equal_wire));
	assert(!equal_net.nodes.contains_ref(inline_equal));
	assert(!equal_net.nodes.contains_ref(stored_equal));
	assert(!equal_net.wires.contains_ref(equal_wire));
	assert(mitos_storage::storage_metadata(
		&equal_net.storage, retired, null
	) == STORAGE_INVALID_HANDLE);
	assert(delta_net_abstract_machine::validate_net(&equal_net));

	Net unequal_net;
	unequal_net.init();
	defer unequal_net.free();
	LayoutHandle unequal_layout = register_shared_layout(
		&unequal_net,
		mitos::TYPE_ID_STRING,
		"NodeTestMixedUnequalString",
		mitos::TYPE_ID_INVALID,
		1
	);
	char[5] unequal_bytes = { 'm', 'i', 't', 'o', 's' };
	StorageHandle unequal_source = allocate_shared_storage(
		&unequal_net, unequal_layout, unequal_bytes[..], 1
	);
	NetRef inline_unequal = delta_net_abstract_machine::new_practical_agent(
		&unequal_net, STRING_AGENT, 0, 0, (uint)mitos::TYPE_ID_STRING
	);
	NetRef stored_unequal = delta_net_abstract_machine::new_practical_agent(
		&unequal_net, STRING_AGENT, 0, 0, (uint)mitos::TYPE_ID_STRING
	);
	PracticalAgent* unequal_inline =
		&unequal_net.nodes.get_ref(inline_unequal).agent.practical;
	PracticalAgent* unequal_stored =
		&unequal_net.nodes.get_ref(stored_unequal).agent.practical;
	unequal_inline.text = "sitos".copy(mem);
	unequal_inline.owns_text = true;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&unequal_net, stored_unequal, &unequal_source, unequal_bytes.len, 1
	));
	unequal_net.ports.get_ref(unequal_stored.principal).polarity = CHILD;
	NetRef unequal_wire = delta_net_abstract_machine::connect(
		&unequal_net, unequal_inline.principal, unequal_stored.principal
	);
	assert(delta_net_abstract_machine::validate_net(&unequal_net));
	assert(!delta_net_abstract_machine::interact(&unequal_net, unequal_wire));
	assert(unequal_net.nodes.contains_ref(inline_unequal));
	assert(unequal_net.nodes.contains_ref(stored_unequal));
	assert(unequal_net.wires.contains_ref(unequal_wire));
	assert(delta_net_abstract_machine::validate_net(&unequal_net));
}

fn void stale_stored_practical_eraser_preserves_the_complete_redex() @test
{
	Net net;
	net.init();
	defer net.free();

	mitos::TypeId array_type = (mitos::TypeId)53;
	LayoutHandle layout = register_shared_layout(
		&net, array_type, "NodeTestStalePracticalEraser"
	);
	char[8] bytes;
	foreach (index, &byte : bytes) *byte = (char)(index + 41);
	StorageHandle source =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	NetRef practical = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, (uint)array_type
	);
	PracticalAgent* practical_value =
		&net.nodes.get_ref(practical).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, practical, &source, 1, 8
	));
	NetRef eraser = delta_net_abstract_machine::new_eraser(&net, CHILD);
	NetRef eraser_principal = principal(&net, eraser);
	NetRef active_wire = delta_net_abstract_machine::connect(
		&net, practical_value.principal, eraser_principal
	);
	assert(delta_net_abstract_machine::validate_net(&net));
	StorageHandle stale = practical_value.storage;
	assert(mitos_storage::release(&net.storage, stale) == STORAGE_OK);

	PracticalAgent practical_before = *practical_value;
	Eraser eraser_before = net.nodes.get_ref(eraser).agent.eraser;
	Port practical_port_before =
		*net.ports.get_ref(practical_before.principal);
	Port eraser_port_before = *net.ports.get_ref(eraser_principal);
	Wire wire_before = *net.wires.get_ref(active_wire);
	usz node_count = net.nodes.len();
	usz port_count = net.ports.len();
	usz wire_count = net.wires.len();
	usz interface_count = net.interfaces.len();
	SlotId node_next = net.nodes.next_id;
	SlotId port_next = net.ports.next_id;
	SlotId wire_next = net.wires.next_id;
	SlotId interface_next = net.interfaces.next_id;
	SlotId continuation_next = net.effects.continuations.next_id;
	usz commit_count = net.effects.commits.len;
	usz committed = net.effects.committed;
	ulong program_epoch = net.effects.program_epoch;
	ulong execution_epoch = net.effects.execution_epoch;

	assert(!delta_net_abstract_machine::interact(&net, active_wire));
	assert(net.nodes.len() == node_count);
	assert(net.ports.len() == port_count);
	assert(net.wires.len() == wire_count);
	assert(net.interfaces.len() == interface_count);
	assert(net.nodes.next_id == node_next);
	assert(net.ports.next_id == port_next);
	assert(net.wires.next_id == wire_next);
	assert(net.interfaces.next_id == interface_next);
	assert(net.effects.continuations.next_id == continuation_next);
	assert(net.effects.commits.len == commit_count);
	assert(net.effects.committed == committed);
	assert(net.effects.program_epoch == program_epoch);
	assert(net.effects.execution_epoch == execution_epoch);
	assert_practical_preserved(
		&net, practical, ARRAY_AGENT, practical_before
	);
	assert(net.nodes.contains_ref(eraser));
	assert(net.nodes.get_ref(eraser).type == ERASER);
	assert(net.nodes.get_ref(eraser).agent.eraser.principal
		== eraser_before.principal);
	assert_port_preserved(
		&net, practical_before.principal, practical_port_before
	);
	assert_port_preserved(&net, eraser_principal, eraser_port_before);
	assert_wire_preserved(&net, active_wire, wire_before);
	assert(wire_connects(
		&net, active_wire, practical_before.principal, eraser_principal
	));
	assert(mitos_storage::storage_metadata(
		&net.storage, stale, null
	) == STORAGE_INVALID_HANDLE);
}

fn void stale_owner_with_busy_view_practical_pair_preserves_both_complete_nodes() @test
{
	Net net;
	net.init();
	defer net.free();

	mitos::TypeId array_type = (mitos::TypeId)54;
	LayoutHandle layout = register_shared_layout(
		&net, array_type, "NodeTestStalePracticalPair"
	);
	char[8] bytes;
	foreach (index, &byte : bytes) *byte = (char)(index + 47);
	StorageHandle first_source =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	StorageHandle second_source =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	NetRef first = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, (uint)array_type
	);
	NetRef second = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, (uint)array_type
	);
	PracticalAgent* first_value = &net.nodes.get_ref(first).agent.practical;
	PracticalAgent* second_value = &net.nodes.get_ref(second).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, first, &first_source, 1, 8
	));
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, second, &second_source, 1, 8
	));
	net.ports.get_ref(second_value.principal).polarity = CHILD;
	NetRef active_wire = delta_net_abstract_machine::connect(
		&net, first_value.principal, second_value.principal
	);
	assert(delta_net_abstract_machine::validate_net(&net));
	StorageHandle stale = first_value.storage;
	StorageHandle live = second_value.storage;
	StorageViewResult busy_view = mitos_storage::view(
		&net.storage, stale, 0, 1, 8, 8
	);
	assert(busy_view.error == STORAGE_OK);
	assert(mitos_storage::release(&net.storage, stale) == STORAGE_OK);

	PracticalAgent first_before = *first_value;
	PracticalAgent second_before = *second_value;
	Port first_port_before = *net.ports.get_ref(first_before.principal);
	Port second_port_before = *net.ports.get_ref(second_before.principal);
	Wire wire_before = *net.wires.get_ref(active_wire);
	usz node_count = net.nodes.len();
	usz port_count = net.ports.len();
	usz wire_count = net.wires.len();
	usz interface_count = net.interfaces.len();
	SlotId node_next = net.nodes.next_id;
	SlotId port_next = net.ports.next_id;
	SlotId wire_next = net.wires.next_id;
	SlotId interface_next = net.interfaces.next_id;
	SlotId continuation_next = net.effects.continuations.next_id;
	usz commit_count = net.effects.commits.len;
	usz committed = net.effects.committed;
	ulong program_epoch = net.effects.program_epoch;
	ulong execution_epoch = net.effects.execution_epoch;

	assert(!delta_net_abstract_machine::interact(&net, active_wire));
	assert(net.nodes.len() == node_count);
	assert(net.ports.len() == port_count);
	assert(net.wires.len() == wire_count);
	assert(net.interfaces.len() == interface_count);
	assert(net.nodes.next_id == node_next);
	assert(net.ports.next_id == port_next);
	assert(net.wires.next_id == wire_next);
	assert(net.interfaces.next_id == interface_next);
	assert(net.effects.continuations.next_id == continuation_next);
	assert(net.effects.commits.len == commit_count);
	assert(net.effects.committed == committed);
	assert(net.effects.program_epoch == program_epoch);
	assert(net.effects.execution_epoch == execution_epoch);
	assert_practical_preserved(&net, first, ARRAY_AGENT, first_before);
	assert_practical_preserved(&net, second, ARRAY_AGENT, second_before);
	assert_port_preserved(&net, first_before.principal, first_port_before);
	assert_port_preserved(&net, second_before.principal, second_port_before);
	assert_wire_preserved(&net, active_wire, wire_before);
	assert(wire_connects(
		&net, active_wire, first_before.principal, second_before.principal
	));
	assert(mitos_storage::storage_metadata(
		&net.storage, stale, null
	) == STORAGE_INVALID_HANDLE);
	mitos_storage::StorageMetadata metadata;
	assert(mitos_storage::storage_metadata(
		&net.storage, live, &metadata
	) == STORAGE_OK);
	assert(metadata.owner_count == 1);
	char[8] loaded;
	assert(mitos_storage::load(
		&net.storage, &busy_view.view, 0, loaded[..]
	) == STORAGE_OK);
	foreach (index, byte : bytes) assert(loaded[index] == byte);
	assert(mitos_storage::close_view(
		&net.storage, &busy_view.view
	) == STORAGE_OK);
}

fn void dense_stored_array_readback_preserves_bytes_count_and_stride() @test
{
	Net net;
	net.init();
	defer net.free();

	LayoutHandle layout = register_shared_layout(
		&net, (mitos::TypeId)50, "NodeTestDenseArrayReadback"
	);
	char[16] bytes;
	foreach (index, &byte : bytes) *byte = (char)(index * 3 + 1);
	StorageHandle storage =
		allocate_shared_storage(&net, layout, bytes[..], 8);
	NetRef value = delta_net_abstract_machine::new_practical_agent(
		&net, ARRAY_AGENT, 0, 0, 50
	);
	PracticalAgent* practical = &net.nodes.get_ref(value).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, value, &storage, 2, 8
	));
	NetRef root = delta_net_abstract_machine::new_interface(&net, ROOT, "");
	delta_net_abstract_machine::connect(
		&net, practical.principal, net.interfaces.get_ref(root).port
	);
	assert(delta_net_abstract_machine::validate_net(&net));

	DeltaPracticalReadbackResult readback =
		delta_net_abstract_machine::readback_practical_root(&net, root);
	defer readback.deinit();
	assert(readback.ok());
	assert(readback.agent_type == ARRAY_AGENT);
	assert(readback.storage_count == 2);
	assert(readback.storage_stride == 8);
	assert(readback.storage_bytes.len == bytes.len);
	foreach (index, byte : bytes)
		assert(readback.storage_bytes[index] == byte);
}

fn void stale_stored_string_readback_fails_and_drop_preserves_the_handle() @test
{
	Net net;
	net.init();
	defer net.free();

	LayoutHandle layout = register_shared_layout(
		&net,
		mitos::TYPE_ID_STRING,
		"NodeTestStaleStringReadback",
		mitos::TYPE_ID_INVALID,
		1
	);
	char[8] bytes = { 's', 't', 'a', 'l', 'e', '!', '!', '!' };
	StorageHandle storage =
		allocate_shared_storage(&net, layout, bytes[..], 1);
	NetRef value = delta_net_abstract_machine::new_practical_agent(
		&net, STRING_AGENT, 0, 0, (uint)mitos::TYPE_ID_STRING
	);
	PracticalAgent* practical = &net.nodes.get_ref(value).agent.practical;
	assert(delta_net_abstract_machine::practical_agent_take_storage(
		&net, value, &storage, bytes.len, 1
	));
	StorageHandle stale = practical.storage;
	assert(mitos_storage::release(&net.storage, stale) == STORAGE_OK);
	assert(!delta_net_abstract_machine::practical_agent_drop(&net, value));
	assert(practical.storage == stale);
	NetRef root = delta_net_abstract_machine::new_interface(&net, ROOT, "");
	delta_net_abstract_machine::connect(
		&net, practical.principal, net.interfaces.get_ref(root).port
	);

	DeltaPracticalReadbackResult readback =
		delta_net_abstract_machine::readback_practical_root(&net, root);
	defer readback.deinit();
	assert(!readback.ok());
}

fn void handler_eraser_retires_live_continuation_resources() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef handler = delta_net_abstract_machine::new_practical_agent(
		&net, HANDLER_AGENT, 2
	);
	PracticalAgent* practical = &net.nodes.get_ref(handler).agent.practical;
	practical.handler_id = 7;
	practical.effect_epoch = 11;
	NetRef eraser = delta_net_abstract_machine::new_eraser(&net, CHILD);
	delta_net_abstract_machine::connect(
		&net, practical.principal, principal(&net, eraser)
	);
	foreach (auxiliary : practical.auxiliaries)
	{
		delta_net_abstract_machine::connect(
			&net, auxiliary, add_external_port(&net, PARENT)
		);
	}
	NetRef continuation = delta_net_abstract_machine::new_effect_continuation(
		&net,
		practical.auxiliaries[0],
		practical.auxiliaries[1],
		handler,
		7,
		13,
		17,
		11,
		2,
		3,
		5,
		true,
		HOST_EFFECT_PURE,
		false
	);
	practical.continuation = continuation;
	EffectContinuation* captured =
		net.effects.continuations.get_ref(continuation);
	NetRef first_resource = captured.first_replicator;
	NetRef second_resource = captured.second_replicator;
	assert(delta_net_abstract_machine::validate_net(&net));

	delta_net_abstract_machine::interact(
		&net, net.ports.get_ref(practical.principal).wire_id
	);

	assert(!net.nodes.contains_ref(handler));
	assert(!net.nodes.contains_ref(eraser));
	assert(!net.nodes.contains_ref(first_resource));
	assert(!net.nodes.contains_ref(second_resource));
	assert(!net.effects.continuations.contains_ref(continuation));
	assert(net.effects.commits.len == 0);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void later_continuation_retirement_preserves_ordered_commit_prefix() @test
{
	Net net;
	net.init();
	defer net.free();

	NetRef[3] handlers;
	NetRef[3] continuations;
	foreach (index, &handler : handlers)
	{
		*handler = delta_net_abstract_machine::new_practical_agent(
			&net, HANDLER_AGENT, 2
		);
		PracticalAgent* practical =
			&net.nodes.get_ref(*handler).agent.practical;
		practical.handler_id = (uint)(71 + index);
		practical.effect_epoch = 31;
		uint handler_id = practical.handler_id;
		NetRef handler_principal = practical.principal;
		NetRef root = practical.auxiliaries[0];
		NetRef hole = practical.auxiliaries[1];
		NetRef eraser =
			delta_net_abstract_machine::new_eraser(&net, CHILD);
		delta_net_abstract_machine::connect(
			&net, handler_principal, principal(&net, eraser)
		);
		delta_net_abstract_machine::connect(
			&net, root, add_external_port(&net, PARENT)
		);
		delta_net_abstract_machine::connect(
			&net, hole, add_external_port(&net, PARENT)
		);
		continuations[index] =
			delta_net_abstract_machine::new_effect_continuation(
				&net,
				root,
				hole,
				*handler,
				handler_id,
				73,
				(uint)(79 + index),
				31,
				1,
				(usz)index,
				0,
				false,
				HOST_EFFECT_PURE,
				true
			);
		net.nodes.get_ref(*handler).agent.practical.continuation =
			continuations[index];
	}
	net.effects.execution_epoch = 31;
	delta_net_abstract_machine::delta_build_effect_commit_queue(&net);
	assert(net.effects.commits.len == 3);
	foreach (index, continuation : continuations)
	{
		assert(net.effects.commits[index].continuation == continuation);
		assert(!net.effects.commits[index].committed);
	}
	assert(delta_net_abstract_machine::validate_net(&net));

	assert(delta_net_abstract_machine::resume_effect_continuation(
		&net, continuations[0]
	));
	assert(net.effects.committed == 1);
	assert(net.effects.commits[0].committed);
	assert(!net.effects.commits[1].committed);

	NetRef later_principal =
		net.nodes.get_ref(handlers[2]).agent.practical.principal;
	NetRef later_wire = net.ports.get_ref(later_principal).wire_id;
	assert(delta_net_abstract_machine::interact(&net, later_wire));

	assert(!net.nodes.contains_ref(handlers[2]));
	assert(!net.effects.continuations.contains_ref(continuations[2]));
	assert(net.effects.commits.len == 2);
	assert(net.effects.committed == 1);
	assert(net.effects.commits[0].continuation == continuations[0]);
	assert(net.effects.commits[0].committed);
	assert(net.effects.commits[1].continuation == continuations[1]);
	assert(!net.effects.commits[1].committed);
	assert(delta_net_abstract_machine::resume_effect_continuation(
		&net, continuations[1]
	));
	assert(net.effects.committed == 2);
	assert(net.effects.commits[1].committed);
	assert(delta_net_abstract_machine::validate_net(&net));
}

fn void large_ordered_commit_queue_is_sorted_stably() @test
{
	Net net;
	net.init();
	defer net.free();

	const usz COMMIT_COUNT = 8192;
	const usz TIE_WIDTH = 4;
	for (usz index = 0; index < COMMIT_COUNT; index++)
	{
		usz reverse_group = (COMMIT_COUNT - 1 - index) / TIE_WIDTH;
		(void)net.effects.continuations.push({
			.source_order = reverse_group,
			.occurrence_order = 9,
			.ordered = true,
		});
	}

	delta_net_abstract_machine::delta_build_effect_commit_queue(&net);

	assert(net.effects.commits.len == COMMIT_COUNT);
	assert(net.effects.committed == 0);
	for (usz index = 1; index < COMMIT_COUNT; index++)
	{
		OrderedEffectCommit* previous = &net.effects.commits[index - 1];
		OrderedEffectCommit* current = &net.effects.commits[index];
		assert(previous.source_root_order <= current.source_root_order);
		if (previous.source_root_order == current.source_root_order)
		{
			assert(previous.operation_order == current.operation_order);
			assert(previous.continuation.id < current.continuation.id);
		}
	}
}

fn void readback_rejects_malformed_nested_observable_replicator() @test
{
	long[2] deltas = { 0, 1 };
	for (usz corruption = 0; corruption < 2; corruption++)
	{
		Net net;
		net.init();
		NetRef root =
			delta_net_abstract_machine::new_interface(&net, ROOT, "");
		NetRef outer = delta_net_abstract_machine::new_replicator(
			&net, 0, deltas[..], UNKNOWN, PARENT, true, 101
		);
		NetRef nested = delta_net_abstract_machine::new_replicator(
			&net, 0, deltas[..], UNKNOWN, PARENT, true, 202
		);
		NetRef first = delta_net_abstract_machine::new_practical_agent(
			&net, I64_AGENT, 0, 1, (uint)mitos::TYPE_ID_I64, 40
		);
		NetRef second = delta_net_abstract_machine::new_practical_agent(
			&net, I64_AGENT, 0, 1, (uint)mitos::TYPE_ID_I64, 41
		);
		NetRef third = delta_net_abstract_machine::new_practical_agent(
			&net, I64_AGENT, 0, 1, (uint)mitos::TYPE_ID_I64, 42
		);
		Replicator* outer_value =
			&net.nodes.get_ref(outer).agent.replicator;
		Replicator* nested_value =
			&net.nodes.get_ref(nested).agent.replicator;
		connect(
			&net, net.interfaces.get_ref(root).port, outer_value.principal
		);
		connect(
			&net, outer_value.auxiliaries[0], nested_value.principal
		);
		connect(
			&net, outer_value.auxiliaries[1],
			net.nodes.get_ref(third).agent.practical.principal
		);
		connect(
			&net, nested_value.auxiliaries[0],
			net.nodes.get_ref(first).agent.practical.principal
		);
		connect(
			&net, nested_value.auxiliaries[1],
			net.nodes.get_ref(second).agent.practical.principal
		);
		assert(delta_net_abstract_machine::validate_net(&net));
		DeltaPracticalReadbackResult canonical =
			delta_net_abstract_machine::readback_practical_root(
				&net, root
			);
		assert(canonical.ok());
		assert(canonical.observable);
		assert(canonical.input_semantics.len == 3);
		canonical.deinit();

		Port* malformed =
			net.ports.get_ref(nested_value.auxiliaries[1]);
		if (!corruption)
		{
			malformed.slot.properties.value.position = 0;
		}
		else
		{
			malformed.polarity = PARENT;
		}
		DeltaPracticalReadbackResult rejected =
			delta_net_abstract_machine::readback_practical_root(
				&net, root
			);
		assert(!rejected.ok());
		assert(rejected.diagnostics.len == 1);
		assert(rejected.diagnostics[0].message
			== "practical readback found malformed or heterogeneous observable branches");
		rejected.deinit();
		net.free();
	}
}

fn void deeply_nested_observable_readback_preserves_depth_first_order() @test
{
	const usz CHAIN_DEPTH = 4096;
	const uint ANCHOR_SEMANTIC = 500_000;
	const ulong ORIGIN_BASE = 20_000;
	long[2] deltas = { 0, 1 };
	Net net;
	net.init();
	defer net.free();

	NetRef anchor = delta_net_abstract_machine::new_practical_agent(
		&net,
		I64_AGENT,
		0,
		ANCHOR_SEMANTIC,
		(uint)mitos::TYPE_ID_I64
	);
	NetRef producer_principal =
		net.nodes.get_ref(anchor).agent.practical.principal;
	for (usz index = 0; index < CHAIN_DEPTH; index++)
	{
		NetRef sibling = delta_net_abstract_machine::new_practical_agent(
			&net,
			I64_AGENT,
			0,
			(uint)(index + 1),
			(uint)mitos::TYPE_ID_I64
		);
		NetRef sibling_principal =
			net.nodes.get_ref(sibling).agent.practical.principal;
		NetRef branch = delta_net_abstract_machine::new_replicator(
			&net,
			0,
			deltas[..],
			UNKNOWN,
			PARENT,
			true,
			ORIGIN_BASE + (ulong)index
		);
		NetRef first_branch =
			net.nodes.get_ref(branch).agent.replicator.auxiliaries[0];
		NetRef second_branch =
			net.nodes.get_ref(branch).agent.replicator.auxiliaries[1];
		NetRef branch_principal =
			net.nodes.get_ref(branch).agent.replicator.principal;
		connect(&net, first_branch, producer_principal);
		connect(&net, second_branch, sibling_principal);
		producer_principal = branch_principal;
	}
	NetRef root = delta_net_abstract_machine::new_interface(&net, ROOT, "");
	NetRef root_port = net.interfaces.get_ref(root).port;
	connect(&net, root_port, producer_principal);

	DeltaPracticalReadbackResult first =
		delta_net_abstract_machine::readback_practical_root(&net, root);
	defer first.deinit();
	DeltaPracticalReadbackResult second =
		delta_net_abstract_machine::readback_practical_root(&net, root);
	defer second.deinit();

	assert(first.ok());
	assert(second.ok());
	assert(first.agent_type == REPLICATOR);
	assert(first.observable);
	assert(first.type_id == (uint)mitos::TYPE_ID_I64);
	assert(first.origin == ORIGIN_BASE + (ulong)CHAIN_DEPTH - 1);
	assert(first.input_semantics.len == CHAIN_DEPTH + 1);
	assert(first.input_origins.len == CHAIN_DEPTH + 1);
	assert(first.input_positions.len == CHAIN_DEPTH + 1);
	assert(second.input_semantics.len == first.input_semantics.len);
	assert(second.input_origins.len == first.input_origins.len);
	assert(second.input_positions.len == first.input_positions.len);
	assert(first.input_semantics[0] == ANCHOR_SEMANTIC);
	assert(first.input_origins[0] == ORIGIN_BASE);
	assert(first.input_positions[0] == 0);
	foreach (index, semantic : first.input_semantics)
	{
		assert(second.input_semantics[index] == semantic);
		assert(second.input_origins[index] == first.input_origins[index]);
		assert(second.input_positions[index] == first.input_positions[index]);
		if (!index) continue;
		assert(semantic == (uint)index);
		assert(first.input_origins[index]
			== ORIGIN_BASE + (ulong)index - 1);
		assert(first.input_positions[index] == 1);
	}
}

fn void retained_ordered_commit_tombstones_validate_and_compact_without_reordering_live_prefix() @test
{
	const usz CONTINUATION_COUNT = 8;
	const ulong EFFECT_EPOCH = 47;
	Net net;
	net.init();
	defer net.free();

	NetRef[CONTINUATION_COUNT] handlers;
	NetRef[CONTINUATION_COUNT] continuations;
	NetRef[CONTINUATION_COUNT] first_resources;
	NetRef[CONTINUATION_COUNT] second_resources;
	foreach (index, &handler : handlers)
	{
		*handler = delta_net_abstract_machine::new_practical_agent(
			&net, HANDLER_AGENT, 2
		);
		PracticalAgent* practical =
			&net.nodes.get_ref(*handler).agent.practical;
		practical.handler_id = (uint)(300 + index);
		practical.effect_epoch = EFFECT_EPOCH;
		uint handler_id = practical.handler_id;
		NetRef handler_principal = practical.principal;
		NetRef root = practical.auxiliaries[0];
		NetRef hole = practical.auxiliaries[1];
		delta_net_abstract_machine::connect(
			&net,
			handler_principal,
			principal(
				&net,
				delta_net_abstract_machine::new_eraser(&net, CHILD)
			)
		);
		delta_net_abstract_machine::connect(
			&net, root, add_external_port(&net, PARENT)
		);
		delta_net_abstract_machine::connect(
			&net, hole, add_external_port(&net, PARENT)
		);
		continuations[index] =
			delta_net_abstract_machine::new_effect_continuation(
				&net,
				root,
				hole,
				*handler,
				handler_id,
				401,
				(uint)(500 + index),
				EFFECT_EPOCH,
				2,
				(usz)index,
				0,
				true,
				HOST_EFFECT_PURE,
				true
			);
		net.nodes.get_ref(*handler).agent.practical.continuation =
			continuations[index];
		EffectContinuation* continuation =
			net.effects.continuations.get_ref(continuations[index]);
		first_resources[index] = continuation.first_replicator;
		second_resources[index] = continuation.second_replicator;
	}
	net.effects.execution_epoch = EFFECT_EPOCH;
	delta_net_abstract_machine::delta_build_effect_commit_queue(&net);
	assert(net.effects.commits.len == CONTINUATION_COUNT);
	assert(delta_net_abstract_machine::resume_effect_continuation(
		&net, continuations[0]
	));
	assert(delta_net_abstract_machine::resume_effect_continuation(
		&net, continuations[1]
	));
	assert(net.effects.committed == 2);

	NetRef first_retired_wire = net.ports.get_ref(
		net.nodes.get_ref(handlers[0]).agent.practical.principal
	).wire_id;
	assert(delta_net_abstract_machine::interact(&net, first_retired_wire));
	assert(!net.effects.continuations.contains_ref(continuations[0]));
	assert(!net.nodes.contains_ref(first_resources[0]));
	assert(!net.nodes.contains_ref(second_resources[0]));
	assert(net.effects.commits.len == CONTINUATION_COUNT);
	assert(net.effects.committed == 2);
	assert(delta_net_abstract_machine::validate_net(&net));

	NetRef second_retired_wire = net.ports.get_ref(
		net.nodes.get_ref(handlers[3]).agent.practical.principal
	).wire_id;
	assert(delta_net_abstract_machine::interact(&net, second_retired_wire));
	assert(!net.effects.continuations.contains_ref(continuations[3]));
	assert(!net.nodes.contains_ref(first_resources[3]));
	assert(!net.nodes.contains_ref(second_resources[3]));

	usz[6] retained = { 1, 2, 4, 5, 6, 7 };
	assert(net.effects.commits.len == retained.len);
	assert(net.effects.committed == 1);
	foreach (queue_index, continuation_index : retained)
	{
		assert(net.effects.commits[queue_index].continuation
			== continuations[continuation_index]);
		assert(net.effects.commits[queue_index].committed
			== (queue_index == 0));
		assert(net.effects.continuations.contains_ref(
			continuations[continuation_index]
		));
		assert(net.nodes.contains_ref(first_resources[continuation_index]));
		assert(net.nodes.contains_ref(second_resources[continuation_index]));
	}
	assert(delta_net_abstract_machine::resume_effect_continuation(
		&net, continuations[2]
	));
	assert(net.effects.committed == 2);
	assert(net.effects.commits[0].committed);
	assert(net.effects.commits[1].committed);
	assert(delta_net_abstract_machine::validate_net(&net));
}
