module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import std::collections::list;

const usz DELTA_READBACK_MAX_DEPTH = 100_000;

const usz DELTA_READBACK_MAX_WORK = 1_000_000;

/** Explicit traversal frame; the cursor preserves left-to-right DFS order. */
struct DeltaPracticalReadbackFrame @private
{
	NetRef producer_ref;
	ulong origin;
	usz position;
	usz depth;
	usz next_auxiliary;
	bool expanded;
}

struct DeltaPracticalReadbackResult
{
	Allocator allocator;
	AgentType agent_type;
	uint semantic_id;
	uint type_id;
	long payload;
 String text;
 char[] storage_bytes;
 usz storage_count;
 usz storage_stride;
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


fn bool DeltaPracticalReadbackResult.ok(&self) => self.diagnostics.len == 0;

fn void DeltaPracticalReadbackResult.deinit(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.input_semantics);
	alloc::free(self.allocator, self.input_origins);
	alloc::free(self.allocator, self.input_positions);
 alloc::free(self.allocator, self.text);
 alloc::free(self.allocator, self.storage_bytes);
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

fn bool delta_wire_contains(Net* net, NetRef wire_ref, NetRef port_ref) @private
{
	if (!net.wires.contains_ref(wire_ref)) return false;
	Wire* wire = net.wires.get_ref(wire_ref);
	return wire.a == port_ref || wire.b == port_ref;
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
	Allocator allocator,
	usz* visited
) @private
{
	List{DeltaPracticalReadbackFrame} work;
	work.init(allocator);
	defer work.free();
	work.push({
		.producer_ref = producer_ref,
		.origin = origin,
		.position = position
	});
	while (work.len())
	{
		DeltaPracticalReadbackFrame* frame = &work[work.len() - 1];
		if (!frame.expanded)
		{
			if (*visited >= DELTA_READBACK_MAX_WORK
				|| frame.depth >= DELTA_READBACK_MAX_DEPTH
				|| !net.ports.contains_ref(frame.producer_ref))
			{
				return false;
			}
			(*visited)++;
			Port* producer = net.ports.get_ref(frame.producer_ref);
			if (producer.polarity != PARENT
				|| !net.nodes.contains_ref(producer.node_id))
			{
				return false;
			}
			Node* producer_node = net.nodes.get_ref(producer.node_id);
			if (!node_is_valid(net, producer.node_id, producer_node)) return false;
			if (is_practical_agent_type(producer_node.type))
			{
				if (frame.producer_ref
					!= producer_node.agent.practical.principal) return false;
				semantics.push(producer_node.agent.practical.semantic_id);
				types.push(producer_node.agent.practical.type_id);
				origins.push(frame.origin);
				positions.push(frame.position);
				(void)work.pop()!!;
				continue;
			}
			if (producer_node.type != REPLICATOR) return false;
			Replicator* replicator = &producer_node.agent.replicator;
			if (!replicator.observable || !replicator.origin
				|| frame.producer_ref != replicator.principal
				|| !replicator.auxiliaries.len) return false;
			frame.expanded = true;
		}

		Port* producer = net.ports.get_ref(frame.producer_ref);
		Replicator* replicator =
			&net.nodes.get_ref(producer.node_id).agent.replicator;
		if (frame.next_auxiliary >= replicator.auxiliaries.len)
		{
			(void)work.pop()!!;
			continue;
		}
		usz index = frame.next_auxiliary++;
		NetRef auxiliary = replicator.auxiliaries[index];
		if (!net.ports.contains_ref(auxiliary)) return false;
		Port* input = net.ports.get_ref(auxiliary);
		if (input.polarity != CHILD
			|| input.node_id != producer.node_id
			|| !delta_wire_contains(net, input.wire_id, auxiliary))
		{
			return false;
		}
		if (frame.depth >= DELTA_READBACK_MAX_DEPTH - 1) return false;
		NetRef nested = other_endpoint(net, input.wire_id, auxiliary);
		ulong child_origin = replicator.origin;
		usz child_depth = frame.depth + 1;
		work.push({
			.producer_ref = nested,
			.origin = child_origin,
			.position = index,
			.depth = child_depth
		});
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
	if (destination.polarity != CHILD
		|| !delta_wire_contains(net, destination.wire_id, interface_port.port))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "practical readback root is disconnected or malformed");
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
	if (!node_is_valid(net, source.node_id, node))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(
			allocator, "practical readback reached malformed agent metadata"
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
	usz traversal_work = 0;
	if (observable_root)
	{
		collected = delta_collect_practical_inputs(
			net, source_ref, &semantics, &types, &origins, &positions, 0, 0,
			allocator, &traversal_work
		);
	}
	else
	{
		foreach (index, auxiliary : node.agent.practical.auxiliaries)
		{
			if (!net.ports.contains_ref(auxiliary))
			{
				collected = false;
				break;
			}
			Port* input = net.ports.get_ref(auxiliary);
			if (input.polarity != CHILD
				|| input.node_id != source.node_id
				|| !delta_wire_contains(net, input.wire_id, auxiliary))
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
				allocator,
				&traversal_work
			))
			{
				collected = false;
				break;
			}
		}
	}
	uint concrete_type = (uint)mitos::TYPE_ID_INVALID;
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
				if (type == (uint)mitos::TYPE_ID_INVALID
					|| type == (uint)mitos::TYPE_ID_ANY) continue;
				if (concrete_type == (uint)mitos::TYPE_ID_INVALID)
				{
					concrete_type = type;
				}
				else if (type != concrete_type)
				{
					collected = false;
					break;
				}
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
		result.type_id = concrete_type == (uint)mitos::TYPE_ID_INVALID
			? (uint)mitos::TYPE_ID_ANY
			: concrete_type;
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
		bool stored =
			practical.storage != mitos_storage::INVALID_STORAGE_HANDLE;
		if (node.type == STRING_AGENT)
		{
			if (!stored)
			{
				result.text = practical.text.copy(allocator);
			}
			else
			{
				char[] bytes;
				if (!practical_agent_storage_copy(
					net, source.node_id, &bytes, allocator
				))
				{
					semantics.free();
					types.free();
					origins.free();
					positions.free();
					result.diagnostics = alloc::new_array(
						allocator, DeltaDiagnostic, 1
					);
					result.diagnostics[0].init(
						allocator, "stored string payload could not be read"
					);
					return result;
				}
				result.text = (String)bytes;
			}
		}
		else if (node.type == ARRAY_AGENT && stored)
		{
			if (!practical_agent_storage_copy(
				net, source.node_id, &result.storage_bytes, allocator
			))
			{
				semantics.free();
				types.free();
				origins.free();
				positions.free();
				result.diagnostics = alloc::new_array(
					allocator, DeltaDiagnostic, 1
				);
				result.diagnostics[0].init(
					allocator, "stored array payload could not be read"
				);
				return result;
			}
			result.storage_count = practical.storage_count;
			result.storage_stride = practical.storage_stride;
		}
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
