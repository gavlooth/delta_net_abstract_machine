module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import std::collections::list;
import std::io;

const usz DELTA_READBACK_MAX_DEPTH = 100_000;
const usz DELTA_FORMAT_MAX_DEPTH = 10_000;
const usz DELTA_FORMAT_MAX_BYTES = 1_048_576;

struct DeltaReadbackResult
{
	Allocator allocator;
	mitos::CoreProgram program;
	DeltaDiagnostic[] diagnostics;
}

fn bool DeltaReadbackResult.ok(&self) => self.diagnostics.len == 0;

fn void DeltaReadbackResult.deinit(&self)
{
	if (!self.allocator) return;
	self.program.deinit();
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

struct DeltaReadBinder
{
	NetRef variable_port;
	String name;
}

struct DeltaReadContext
{
	Allocator allocator;
	Net* net;
	List{DeltaReadBinder} binders;
	char[] path_ports;
	usz next_binder;
	bool failed;
	DeltaDiagnostic diagnostic;
}


fn void delta_read_fail(DeltaReadContext* context, String message) @private
{
	if (context.failed) return;
	context.failed = true;
	context.diagnostic.init(context.allocator, message);
}

fn mitos::CoreExpr* delta_new_variable(Allocator allocator, String name) @private
{
	return alloc::new(allocator, mitos::CoreExpr, {
		.kind = CORE_VARIABLE,
		.data = { .variable = { .name = name.copy(allocator) } },
	});
}

fn mitos::CoreExpr* delta_new_abstraction(
	Allocator allocator,
	String parameter,
	mitos::CoreExpr* body
) @private
{
	return alloc::new(allocator, mitos::CoreExpr, {
		.kind = CORE_ABSTRACTION,
		.data = { .abstraction = { .parameter = parameter, .body = body } },
	});
}

fn mitos::CoreExpr* delta_new_application(
	Allocator allocator,
	mitos::CoreExpr* function,
	mitos::CoreExpr* argument
) @private
{
	return alloc::new(allocator, mitos::CoreExpr, {
		.kind = CORE_APPLICATION,
		.data = { .application = { .function = function, .argument = argument } },
	});
}

fn void delta_destroy_core(Allocator allocator, mitos::CoreExpr* expression) @private
{
	if (!expression) return;
	expression.deinit(allocator);
	alloc::free(allocator, expression);
}

fn InterfacePort* delta_interface_for_port(Net* net, NetRef port) @private
{
	for (SlotId id = 0; id < net.interfaces.next_id; id++)
	{
		if (!net.interfaces.contains_id(id)) continue;
		NetRef reference = net.interfaces.generation_ref(id);
		InterfacePort* interface_port = net.interfaces.get_ref(reference);
		if (interface_port.port == port) return interface_port;
	}
	return null;
}

fn String delta_fresh_binder_name(DeltaReadContext* context) @private
{
	for (;;)
	{
		char[48] buffer;
		String candidate = (String)io::bprintf(&buffer, "$delta%d", (long)context.next_binder++)!!;
		bool collision = false;
		for (SlotId id = 0; id < context.net.interfaces.next_id; id++)
		{
			if (!context.net.interfaces.contains_id(id)) continue;
			InterfacePort* interface_port = context.net.interfaces.get_ref(
				context.net.interfaces.generation_ref(id)
			);
			if (interface_port.type == FREE_VARIABLE
				&& interface_port.name.has_value
				&& interface_port.name.value == candidate)
			{
				collision = true;
				break;
			}
		}
		if (!collision) return candidate.copy(context.allocator);
	}
}

fn String delta_binder_for_port(DeltaReadContext* context, NetRef port) @private
{
	for (sz index = context.binders.len() - 1; index >= 0; index--)
	{
		if (context.binders[index].variable_port == port) return context.binders[index].name;
	}
	return "";
}

fn bool delta_replicator_has_auxiliary(Replicator* replicator, NetRef port) @private
{
	foreach (auxiliary : replicator.auxiliaries) if (auxiliary == port) return true;
	return false;
}
fn mitos::CoreExpr* delta_read_observable_replicator(
	DeltaReadContext* context,
	Replicator* replicator,
	usz depth
) @private
{
	if (!replicator.origin || !replicator.auxiliaries.len)
	{
		delta_read_fail(context, "observable readback found a malformed superposition boundary");
		return null;
	}
	// CoreExpr has no superposition variant. A reserved readback-only head
	// retains the stable origin while ordered applications retain branch order.
	char[64] marker_buffer;
	String marker_name = (String)io::bprintf(
		&marker_buffer, "$superpose_%d", (long)replicator.origin
	)!!;
	mitos::CoreExpr* expression =
		delta_new_variable(context.allocator, marker_name);
	foreach (auxiliary : replicator.auxiliaries)
	{
		mitos::CoreExpr* branch = delta_read_term(context, auxiliary, depth + 1);
		if (context.failed)
		{
			delta_destroy_core(context.allocator, expression);
			delta_destroy_core(context.allocator, branch);
			return null;
		}
		expression = delta_new_application(context.allocator, expression, branch);
	}
	return expression;
}


fn mitos::CoreExpr* delta_read_from_source(
	DeltaReadContext* context,
	NetRef source,
	usz depth
) @private
{
	String binder_name = delta_binder_for_port(context, source);
	if (binder_name.len) return delta_new_variable(context.allocator, binder_name);

	InterfacePort* interface_port = delta_interface_for_port(context.net, source);
	if (interface_port)
	{
		if (interface_port.type != FREE_VARIABLE || !interface_port.name.has_value)
		{
			delta_read_fail(context, "readback reached a malformed interface");
			return null;
		}
		return delta_new_variable(context.allocator, interface_port.name.value);
	}

	if (!context.net.ports.contains_ref(source))
	{
		delta_read_fail(context, "readback reached a stale port reference");
		return null;
	}
	Port* port = context.net.ports.get_ref(source);
	if (!context.net.nodes.contains_ref(port.node_id))
	{
		delta_read_fail(context, "readback reached an unowned non-interface port");
		return null;
	}
	Node* node = context.net.nodes.get_ref(port.node_id);
	switch (node.type)
	{
		case FAN:
			Fan* fan = &node.agent.fan;
			Port* principal = context.net.ports.get_ref(fan.principal);
			if (source == fan.principal && principal.polarity == PARENT)
			{
				String name = delta_fresh_binder_name(context);
				context.binders.push({ .variable_port = fan.right, .name = name });
				mitos::CoreExpr* body = delta_read_term(context, fan.left, depth + 1);
				(void)context.binders.pop()!!;
				if (context.failed)
				{
					alloc::free(context.allocator, name);
					delta_destroy_core(context.allocator, body);
					return null;
				}
				return delta_new_abstraction(context.allocator, name, body);
			}
			if (source == fan.left && principal.polarity == CHILD)
			{
				mitos::CoreExpr* function = delta_read_term(context, fan.principal, depth + 1);
				if (context.failed) return null;
				mitos::CoreExpr* argument = delta_read_term(context, fan.right, depth + 1);
				if (context.failed)
				{
					delta_destroy_core(context.allocator, function);
					return null;
				}
				return delta_new_application(context.allocator, function, argument);
			}
			delta_read_fail(context, "readback entered a fan through a non-canonical port/orientation");
			return null;
		case REPLICATOR:
			Replicator* replicator = &node.agent.replicator;
			Port* principal_port = context.net.ports.get_ref(replicator.principal);
			if (replicator.observable)
			{
				if (source != replicator.principal || principal_port.polarity != PARENT)
				{
					delta_read_fail(context, "observable readback entered a superposition through a non-principal port");
					return null;
				}
				return delta_read_observable_replicator(context, replicator, depth);
			}
			if (principal_port.polarity != CHILD || !delta_replicator_has_auxiliary(replicator, source))
			{
				delta_read_fail(context, "readback found unsupported phase-two/fan-in replicator residue");
				return null;
			}
			return delta_read_term(context, replicator.principal, depth + 1);
		case ERASER:
			delta_read_fail(context, "readback reached an eraser in a demanded position");
			return null;
		default:
			delta_read_fail(context, "readback reached an unknown agent");
			return null;
	}
}

fn mitos::CoreExpr* delta_read_term(DeltaReadContext* context, NetRef destination, usz depth) @private
{
	if (context.failed) return null;
	if (depth >= DELTA_READBACK_MAX_DEPTH)
	{
		delta_read_fail(context, "readback depth limit exceeded");
		return null;
	}
	if (!context.net.ports.contains_ref(destination))
	{
		delta_read_fail(context, "readback destination is stale");
		return null;
	}
	Port* destination_port = context.net.ports.get_ref(destination);
	if (destination_port.polarity != CHILD)
	{
		delta_read_fail(context, "readback destination is not a CHILD port");
		return null;
	}
	if ((usz)destination.id >= context.path_ports.len || context.path_ports[(usz)destination.id])
	{
		delta_read_fail(context, "readback detected a cycle");
		return null;
	}
	context.path_ports[(usz)destination.id] = 1;
	defer context.path_ports[(usz)destination.id] = 0;
	if (!context.net.wires.contains_ref(destination_port.wire_id))
	{
		delta_read_fail(context, "readback found a disconnected destination");
		return null;
	}
	if (is_active(context.net, destination_port.wire_id))
	{
		delta_read_fail(context, "readback encountered an unreduced active pair");
		return null;
	}
	NetRef source = other_endpoint(context.net, destination_port.wire_id, destination);
	if (!context.net.ports.contains_ref(source)
		|| context.net.ports.get_ref(source).polarity != PARENT)
	{
		delta_read_fail(context, "readback wire does not lead to a live PARENT port");
		return null;
	}
	return delta_read_from_source(context, source, depth);
}

fn DeltaReadbackResult readback_delta_root(Net* net, NetRef root, Allocator allocator = mem)
{
	DeltaReadbackResult result = { .allocator = allocator };
	if (!net || !net.interfaces.contains_ref(root))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "readback root interface is missing or stale");
		return result;
	}
	InterfacePort* root_interface = net.interfaces.get_ref(root);
	if (root_interface.type != ROOT || !net.ports.contains_ref(root_interface.port))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "readback root reference does not name a live ROOT interface");
		return result;
	}

	DeltaReadContext context = { .allocator = allocator, .net = net };
	context.binders.init(allocator);
	context.path_ports = alloc::new_array(allocator, char, (sz)net.ports.next_id);
	foreach (&flag : context.path_ports) *flag = 0;
	mitos::CoreExpr* expression = delta_read_term(&context, root_interface.port, 0);
	context.binders.free();
	alloc::free(allocator, context.path_ports);
	if (context.failed)
	{
		delta_destroy_core(allocator, expression);
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0] = context.diagnostic;
		return result;
	}
	result.program = { .allocator = allocator, .expression = expression };
	return result;
}

fn void delta_append_formatted_core(
	DString* output,
	mitos::CoreExpr* expression,
	int parent_precedence,
	usz depth,
	bool* failed
) @private
{
	if (*failed) return;
	if (!expression || depth >= DELTA_FORMAT_MAX_DEPTH || output.str_view().len >= DELTA_FORMAT_MAX_BYTES)
	{
		*failed = true;
		return;
	}
	int precedence;
	switch (expression.kind)
	{
		case CORE_VARIABLE: precedence = 3;
		case CORE_APPLICATION: precedence = 2;
		case CORE_ABSTRACTION: precedence = 1;
		default:
			*failed = true;
			return;
	}
	bool parentheses = precedence < parent_precedence;
	if (parentheses) output.append_string("(");
	switch (expression.kind)
	{
		case CORE_VARIABLE:
			output.append_string(expression.data.variable.name);
		case CORE_ABSTRACTION:
			output.append_string("\\");
			output.append_string(expression.data.abstraction.parameter);
			output.append_string(". ");
			delta_append_formatted_core(output, expression.data.abstraction.body, 1, depth + 1, failed);
		case CORE_APPLICATION:
			delta_append_formatted_core(output, expression.data.application.function, 2, depth + 1, failed);
			output.append_string(" ");
			delta_append_formatted_core(output, expression.data.application.argument, 3, depth + 1, failed);
		default:
	}
	if (parentheses) output.append_string(")");
	if (output.str_view().len > DELTA_FORMAT_MAX_BYTES) *failed = true;
}

fn String format_delta_core(mitos::CoreExpr* expression, Allocator allocator = mem)
{
	DString output;
	output.init(allocator);
	bool failed = false;
	delta_append_formatted_core(&output, expression, 0, 0, &failed);
	if (failed)
	{
		output.free();
		return "<delta normal form exceeds formatting limit>".copy(allocator);
	}
	String result = output.copy_str(allocator);
	output.free();
	return result;
}

struct DeltaPracticalReadbackResult
{
	Allocator allocator;
	AgentType agent_type;
	uint semantic_id;
	uint type_id;
	long payload;
 String text;
 usz occurrence_order;
	usz descriptor;
	uint[] input_semantics;
	bool observable;
	ulong origin;
	ulong[] input_origins;
	usz[] input_positions;
	usz source_order;
	NetRef continuation;
	uint handler_id;
	uint effect_id;
	uint operation_id;
	ulong effect_epoch;
	usz resume_count;
	EffectContinuationState resume_state;
	HostEffectKind host_effect;
	bool ordered_effect;
	DeltaDiagnostic[] diagnostics;
}
struct DeltaContinuationReadbackResult
{
	Allocator allocator;
	NetRef root;
	NetRef hole;
	NetRef eraser;
	NetRef first_replicator;
	NetRef second_replicator;
	uint handler_id;
	uint effect_id;
	uint operation_id;
	ulong effect_epoch;
	usz resume_count;
	usz resumes_used;
	usz source_order;
 usz occurrence_order;
	EffectContinuationState state;
	HostEffectKind host_effect;
	bool multi;
	bool ordered;
	DeltaDiagnostic[] diagnostics;
}

fn bool DeltaContinuationReadbackResult.ok(&self) => self.diagnostics.len == 0;

fn void DeltaContinuationReadbackResult.deinit(&self)
{
	if (!self.allocator) return;
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

fn DeltaContinuationReadbackResult readback_effect_continuation(
	Net* net,
	NetRef continuation_ref,
	Allocator allocator = mem
)
{
	DeltaContinuationReadbackResult result = { .allocator = allocator };
	if (!net || !net.effects.continuations.contains_ref(continuation_ref))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "effect continuation root is missing or stale");
		return result;
	}
	EffectContinuation* continuation = net.effects.continuations.get_ref(continuation_ref);
	if (!net.ports.contains_ref(continuation.root)
		|| !net.ports.contains_ref(continuation.hole)
		|| !net.nodes.contains_ref(continuation.handler))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "effect continuation graph boundary is invalid");
		return result;
	}
	result.root = continuation.root;
	result.hole = continuation.hole;
	result.eraser = continuation.eraser;
	result.first_replicator = continuation.first_replicator;
	result.second_replicator = continuation.second_replicator;
	result.handler_id = continuation.handler_id;
	result.effect_id = continuation.effect_id;
	result.operation_id = continuation.operation_id;
	result.effect_epoch = continuation.effect_epoch;
	result.resume_count = continuation.resume_count;
	result.resumes_used = continuation.resumes_used;
 result.occurrence_order = continuation.occurrence_order;
	result.source_order = continuation.source_order;
	result.state = continuation.state;
	result.host_effect = continuation.host_effect;
	result.multi = continuation.multi;
	result.ordered = continuation.ordered;
	return result;
}


fn bool DeltaPracticalReadbackResult.ok(&self) => self.diagnostics.len == 0;

fn void DeltaPracticalReadbackResult.deinit(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.input_semantics);
	alloc::free(self.allocator, self.input_origins);
	alloc::free(self.allocator, self.input_positions);
 alloc::free(self.allocator, self.text);
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

fn bool delta_collect_practical_inputs(
	Net* net,
	NetRef producer_ref,
	List{uint}* semantics,
	List{uint}* types,
	List{ulong}* origins,
	List{usz}* positions,
	ulong origin,
	usz position,
	usz depth
) @private
{
	if (depth >= DELTA_READBACK_MAX_DEPTH || !net.ports.contains_ref(producer_ref))
	{
		return false;
	}
	Port* producer = net.ports.get_ref(producer_ref);
	if (producer.polarity != PARENT || !net.nodes.contains_ref(producer.node_id))
	{
		return false;
	}
	Node* producer_node = net.nodes.get_ref(producer.node_id);
	if (is_practical_agent_type(producer_node.type))
	{
		if (producer_ref != producer_node.agent.practical.principal) return false;
		semantics.push(producer_node.agent.practical.semantic_id);
		types.push(producer_node.agent.practical.type_id);
		origins.push(origin);
		positions.push(position);
		return true;
	}
	if (producer_node.type != REPLICATOR) return false;
	Replicator* replicator = &producer_node.agent.replicator;
	if (!replicator.observable || !replicator.origin
		|| producer_ref != replicator.principal
		|| !replicator.auxiliaries.len) return false;
	foreach (index, auxiliary : replicator.auxiliaries)
	{
		if (!net.ports.contains_ref(auxiliary)) return false;
		Port* input = net.ports.get_ref(auxiliary);
		if (input.polarity != CHILD || !net.wires.contains_ref(input.wire_id))
		{
			return false;
		}
		NetRef nested = other_endpoint(net, input.wire_id, auxiliary);
		if (!delta_collect_practical_inputs(
			net,
			nested,
			semantics,
			types,
			origins,
			positions,
			replicator.origin,
			(usz)index,
			depth + 1
		)) return false;
	}
	return true;
}

/** Reify a practical root without consulting source syntax or free names. */
fn DeltaPracticalReadbackResult readback_practical_root(
	Net* net,
	NetRef root,
	Allocator allocator = mem
)
{
	DeltaPracticalReadbackResult result = { .allocator = allocator };
	if (!net || !net.interfaces.contains_ref(root))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "practical readback root is missing or stale");
		return result;
	}
	InterfacePort* interface_port = net.interfaces.get_ref(root);
	if (interface_port.type != ROOT || !net.ports.contains_ref(interface_port.port))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "practical readback requires a live ROOT interface");
		return result;
	}
	Port* destination = net.ports.get_ref(interface_port.port);
	if (!net.wires.contains_ref(destination.wire_id))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "practical readback root is disconnected");
		return result;
	}
	NetRef source_ref = other_endpoint(net, destination.wire_id, interface_port.port);
	if (!net.ports.contains_ref(source_ref))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "practical readback reached a stale producer port");
		return result;
	}
	Port* source = net.ports.get_ref(source_ref);
	if (!net.nodes.contains_ref(source.node_id))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "practical readback reached an unowned port");
		return result;
	}
	Node* node = net.nodes.get_ref(source.node_id);
	bool observable_root = node.type == REPLICATOR
		&& node.agent.replicator.observable
		&& source_ref == node.agent.replicator.principal;
	if (!observable_root && (!is_practical_agent_type(node.type)
		|| source_ref != node.agent.practical.principal))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(
			allocator, "root does not reify to a practical agent or observable superposition"
		);
		return result;
	}
	List{uint} semantics;
	List{uint} types;
	List{ulong} origins;
	List{usz} positions;
	semantics.init(allocator);
	types.init(allocator);
	origins.init(allocator);
	positions.init(allocator);
	bool collected = true;
	if (observable_root)
	{
		collected = delta_collect_practical_inputs(
			net, source_ref, &semantics, &types, &origins, &positions, 0, 0, 0
		);
	}
	else
	{
		foreach (index, auxiliary : node.agent.practical.auxiliaries)
		{
			Port* input = net.ports.get_ref(auxiliary);
			if (!net.wires.contains_ref(input.wire_id))
			{
				collected = false;
				break;
			}
			NetRef producer_ref = other_endpoint(net, input.wire_id, auxiliary);
			if (!delta_collect_practical_inputs(
				net,
				producer_ref,
				&semantics,
				&types,
				&origins,
				&positions,
				0,
				(usz)index,
				0
			))
			{
				collected = false;
				break;
			}
		}
	}
	if (collected && observable_root)
	{
		if (!types.len())
		{
			collected = false;
		}
		else
		{
			foreach (type : types)
			{
				if (type == types[0]) continue;
				collected = false;
				break;
			}
		}
	}
	if (!collected)
	{
		semantics.free();
		types.free();
		origins.free();
		positions.free();
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(
			allocator, "practical readback found malformed or heterogeneous observable branches"
		);
		return result;
	}
	if (observable_root)
	{
		Replicator* replicator = &node.agent.replicator;
		result.agent_type = REPLICATOR;
		result.type_id = types[0];
		result.descriptor = (usz)replicator.origin;
		result.observable = true;
		result.origin = replicator.origin;
	}
	else
	{
		PracticalAgent* practical = &node.agent.practical;
		result.agent_type = node.type;
		result.semantic_id = practical.semantic_id;
		result.type_id = practical.type_id;
		result.payload = practical.payload;
		result.descriptor = practical.descriptor;
		result.text = practical.text.copy(allocator);
		result.occurrence_order = practical.occurrence_order;
		result.source_order = practical.source_order;
		result.continuation = practical.continuation;
		result.handler_id = practical.handler_id;
		result.effect_id = practical.effect_id;
		result.operation_id = practical.operation_id;
		result.effect_epoch = practical.effect_epoch;
		result.resume_count = practical.resume_count;
		result.resume_state = practical.resume_state;
		result.host_effect = practical.host_effect;
		result.ordered_effect = practical.ordered_effect;
	}
	result.input_semantics = semantics.to_array(allocator);
	result.input_origins = origins.to_array(allocator);
	result.input_positions = positions.to_array(allocator);
	semantics.free();
	types.free();
	origins.free();
	positions.free();
	return result;
}
