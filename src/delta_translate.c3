module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import std::collections::list;

struct DeltaDiagnostic
{
 Allocator allocator;
 String message;
 mitos::MitosSpan span;
}

fn DeltaDiagnostic* DeltaDiagnostic.init(
 &self,
 Allocator allocator,
 String message,
 mitos::MitosSpan span = {}
)
{
 *self = {
  .allocator = allocator,
  .message = message.copy(allocator),
  .span = span,
 };
 return self;
}

fn void DeltaDiagnostic.deinit(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.message);
	*self = { };
}

struct DeltaTranslationResult
{
	Allocator allocator;
	Net net;
	NetRef root;
	DeltaDiagnostic[] diagnostics;
	bool owns_net;
}

fn bool DeltaTranslationResult.ok(&self) => self.diagnostics.len == 0;

fn void DeltaTranslationResult.deinit(&self)
{
	if (!self.allocator) return;
	if (self.owns_net) self.net.free();
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}


fn AgentType delta_practical_agent_type(mitos::DeltaNodeKind kind)
{
	switch (kind)
	{
		case DELTA_LOCAL: return LOCAL_AGENT;
		case DELTA_I64: return I64_AGENT;
		case DELTA_STRING: return STRING_AGENT;
		case DELTA_LAMBDA: return LAMBDA_AGENT;
		case DELTA_APPLY: return APPLY_AGENT;
		case DELTA_LET: return LET_AGENT;
		case DELTA_CONSTRUCTOR: return CONSTRUCTOR_AGENT;
		case DELTA_MATCH: return MATCH_AGENT;
		case DELTA_GENERIC_CALL: return GENERIC_CALL_AGENT;
		case DELTA_TYPE_VALUE: return TYPE_VALUE_AGENT;
		case DELTA_TYPE_ASSERT: return TYPE_ASSERTION_AGENT;
		case DELTA_TYPE_OF: return GENERIC_DISPATCH_AGENT;
		case DELTA_PRIMITIVE: return PRIMITIVE_OP_AGENT;
		case DELTA_PARALLEL_ROOT: return PARALLEL_ROOT_AGENT;
		case DELTA_PARALLEL_JOIN: return PARALLEL_JOIN_AGENT;
		case DELTA_EFFECT: return EFFECT_AGENT;
		case DELTA_HANDLER: return HANDLER_AGENT;
		case DELTA_RESUME: return RESUME_AGENT;
		case DELTA_ABORT: return ABORT_AGENT;
		case DELTA_COLLAPSE: return COLLAPSE_AGENT;
		default: return ABORT_AGENT;
	}
}

fn HostEffectKind delta_net_host_kind(mitos::DeltaEffectHostKind kind)
{
	switch (kind)
	{
		case DELTA_EFFECT_ORDERED: return HOST_EFFECT_ORDERED;
		case DELTA_EFFECT_EXTERNAL: return HOST_EFFECT_EXTERNAL;
		default: return HOST_EFFECT_PURE;
	}
}

fn mitos::DeltaOperationDescriptor* delta_net_operation(
	mitos::DeltaProgram* program,
	mitos::OperationId id
)
{
	foreach (&operation : program.effects.operations) if (operation.id == id) return operation;
	return null;
}
struct DeltaMaterializedEffect
{
	NetRef hole;
	uint effect_id;
	uint operation_id;
	usz source_order;
	usz occurrence_order;
}

fn bool delta_charge_materialization(
	usz* work,
	usz units,
	DeltaDiagnostic* diagnostic,
	Allocator allocator
) @private
{
	if (units > mitos::DELTA_MAX_EVALUATION_STEPS
		|| *work > mitos::DELTA_MAX_EVALUATION_STEPS - units)
	{
		diagnostic.init(
			allocator,
			"DeltaProgram graph exceeds the total materialization work limit"
		);
		return false;
	}
	*work += units;
	return true;
}

const usz DELTA_MAX_MATERIALIZATION_BYTES = 64 * 1024 * 1024;

fn bool delta_charge_materialization_bytes(
	usz* bytes,
	usz amount,
	DeltaDiagnostic* diagnostic,
	Allocator allocator
) @private
{
	if (amount > DELTA_MAX_MATERIALIZATION_BYTES
		|| *bytes > DELTA_MAX_MATERIALIZATION_BYTES - amount)
	{
		diagnostic.init(
			allocator,
			"DeltaProgram graph exceeds the total materialization byte limit"
		);
		return false;
	}
	*bytes += amount;
	return true;
}

fn bool delta_charge_materialization_items(
	usz* bytes,
	usz count,
	usz item_size,
	DeltaDiagnostic* diagnostic,
	Allocator allocator
) @private
{
	if (count && item_size > DELTA_MAX_MATERIALIZATION_BYTES / count)
	{
		diagnostic.init(
			allocator,
			"DeltaProgram graph exceeds the total materialization byte limit"
		);
		return false;
	}
	return delta_charge_materialization_bytes(
		bytes, count * item_size, diagnostic, allocator
	);
}

fn bool delta_materialization_arena_growth(
	SlotId next_id,
	SlotId free_head,
	sz pages_size,
	sz pages_capacity,
	usz page_capacity,
	usz page_size,
	usz count,
	usz* growth
) @private
{
	*growth = 0;
	if (!count) return true;
	// Materialization only appends to fresh Nets. Refuse a reused arena rather
	// than guess how many free-list pushes avoid page allocation.
	if (free_head != stable_slot_arena::INVALID_SLOT_ID
		|| next_id > (SlotId)usz::max
		|| pages_size < 0
		|| pages_capacity < pages_size
		|| !page_capacity
		|| !page_size
		|| count > usz::max - (usz)next_id) return false;
	usz final_next_id = (usz)next_id + count;
	usz required_pages = final_next_id / page_capacity;
	if (final_next_id % page_capacity) required_pages++;
	usz existing_pages = (usz)pages_size;
	if (required_pages < existing_pages) return false;
	usz new_pages = required_pages - existing_pages;
	if (new_pages > DELTA_MAX_MATERIALIZATION_BYTES / page_size) return false;
	usz page_bytes = new_pages * page_size;

	usz old_capacity = (usz)pages_capacity;
	usz new_capacity = old_capacity;
	while (new_capacity < required_pages)
	{
		if (!new_capacity)
		{
			new_capacity = 16;
		}
		else
		{
			if (new_capacity > (usz)sz::max / 2) return false;
			new_capacity *= 2;
		}
	}
	usz added_pointers = new_capacity - old_capacity;
	if (added_pointers > DELTA_MAX_MATERIALIZATION_BYTES / (usz)void*::size)
	{
		return false;
	}
	usz pointer_bytes = added_pointers * (usz)void*::size;
	if (pointer_bytes > DELTA_MAX_MATERIALIZATION_BYTES - page_bytes) return false;
	*growth = page_bytes + pointer_bytes;
	return true;
}

fn bool delta_charge_materialization_arena(
	usz* bytes,
	SlotId next_id,
	SlotId free_head,
	sz pages_size,
	sz pages_capacity,
	usz page_capacity,
	usz page_size,
	usz count,
	DeltaDiagnostic* diagnostic,
	Allocator allocator
) @private
{
	usz growth;
	if (!delta_materialization_arena_growth(
		next_id,
		free_head,
		pages_size,
		pages_capacity,
		page_capacity,
		page_size,
		count,
		&growth
	))
	{
		diagnostic.init(
			allocator,
			"DeltaProgram graph exceeds the total materialization byte limit"
		);
		return false;
	}
	return delta_charge_materialization_bytes(
		bytes, growth, diagnostic, allocator
	);
}

// Match the persistent allocations made by Net constructors: StableSlotArena
// page growth (including page-pointer List capacity) and owned auxiliary refs.
fn bool delta_charge_materialized_agents(
	Net* net,
	usz* bytes,
	usz arity,
	usz agent_count,
	usz wire_count,
	DeltaDiagnostic* diagnostic,
	Allocator allocator
) @private
{
	if (arity == usz::max
		|| agent_count > usz::max / (arity + 1)
		|| (arity && agent_count > usz::max / arity))
	{
		diagnostic.init(
			allocator,
			"DeltaProgram graph exceeds the total materialization byte limit"
		);
		return false;
	}
	usz port_count = agent_count * (arity + 1);
	usz auxiliary_count = agent_count * arity;
	return delta_charge_materialization_arena(
			bytes,
			net.nodes.next_id,
			net.nodes.free_head,
			net.nodes.pages.size,
			net.nodes.pages.capacity,
			stable_slot_arena::STABLE_SLOT_PAGE_CAPACITY{Node},
			(usz)stable_slot_arena::StableSlotPage{Node}::size,
			agent_count,
			diagnostic,
			allocator
		)
		&& delta_charge_materialization_arena(
			bytes,
			net.ports.next_id,
			net.ports.free_head,
			net.ports.pages.size,
			net.ports.pages.capacity,
			stable_slot_arena::STABLE_SLOT_PAGE_CAPACITY{Port},
			(usz)stable_slot_arena::StableSlotPage{Port}::size,
			port_count,
			diagnostic,
			allocator
		)
		&& delta_charge_materialization_items(
			bytes, auxiliary_count, (usz)NetRef::size, diagnostic, allocator
		)
		&& delta_charge_materialization_arena(
			bytes,
			net.wires.next_id,
			net.wires.free_head,
			net.wires.pages.size,
			net.wires.pages.capacity,
			stable_slot_arena::STABLE_SLOT_PAGE_CAPACITY{Wire},
			(usz)stable_slot_arena::StableSlotPage{Wire}::size,
			wire_count,
			diagnostic,
			allocator
		);
}

fn bool delta_charge_continuation(
	usz* work,
	bool multi,
	usz resume_count,
	DeltaDiagnostic* diagnostic,
	Allocator allocator
) @private
{
	if (!delta_charge_materialization(work, 1, diagnostic, allocator)) return false;
	if (!multi || resume_count <= 1) return true;
	return delta_charge_materialization(work, 4, diagnostic, allocator)
		&& delta_charge_materialization(work, resume_count, diagnostic, allocator)
		&& delta_charge_materialization(work, resume_count, diagnostic, allocator);
}
fn usz delta_resume_occurrences(
 mitos::DeltaProgram* program,
 mitos::DeltaNodeId node_id,
 usz handler_index,
 usz depth
) @private
{
 if (depth >= mitos::DELTA_MAX_EVALUATION_DEPTH) return 0;
 mitos::DeltaNode* node = mitos::delta_node(program, node_id);
 if (!node) return 0;
 if (node.kind == DELTA_LAMBDA) return 0;
 usz count = 0;
 if (node.kind == DELTA_HANDLER)
 {
  if (node.inputs.len < 2) return 0;
  usz handled = delta_resume_occurrences(
   program, node.inputs[0], handler_index, depth + 1
  );
  usz returned = delta_resume_occurrences(
   program, node.inputs[node.inputs.len - 1], handler_index, depth + 1
  );
  if (returned > mitos::DELTA_MAX_EVALUATION_STEPS - handled)
  {
   return mitos::DELTA_MAX_EVALUATION_STEPS;
  }
  return handled + returned;
 }

 foreach (input : node.inputs)
 {
  usz nested = delta_resume_occurrences(
   program, input, handler_index, depth + 1
  );
  if (nested > mitos::DELTA_MAX_EVALUATION_STEPS - count)
  {
   return mitos::DELTA_MAX_EVALUATION_STEPS;
  }
  count += nested;
 }
 foreach (&branch : node.branches)
 {
  usz nested = delta_resume_occurrences(
   program, branch.body, handler_index, depth + 1
  );
  if (nested > mitos::DELTA_MAX_EVALUATION_STEPS - count)
  {
   return mitos::DELTA_MAX_EVALUATION_STEPS;
  }
  count += nested;
 }
 if (node.kind == DELTA_RESUME && node.descriptor == handler_index
  && count < mitos::DELTA_MAX_EVALUATION_STEPS) count++;
 return count;
}

fn bool delta_superposition_leaf_type(
 mitos::DeltaProgram* program,
 mitos::DeltaNodeId node_id,
 uint* concrete_type,
 usz* materialization_work,
 usz depth,
 DeltaDiagnostic* diagnostic,
 Allocator allocator
) @private
{
 if (depth >= mitos::DELTA_MAX_EVALUATION_DEPTH)
 {
  diagnostic.init(
   allocator, "superposition leaf validation exceeds the materialization depth limit"
  );
  return false;
 }
 mitos::DeltaNode* node = mitos::delta_node(program, node_id);
 if (!node)
 {
  diagnostic.init(allocator, "superposition contains an invalid branch identity");
  return false;
 }
 if (!delta_charge_materialization(
   materialization_work, 1, diagnostic, allocator
  )) return false;
 if (node.kind == DELTA_SUPERPOSE)
 {
  if (!node.inputs.len || !node.descriptor || node.branches.len)
  {
   diagnostic.init(allocator, "nested superposition has an invalid ordered layout");
   return false;
  }
  foreach (input : node.inputs)
  {
   if (!delta_superposition_leaf_type(
     program,
     input,
     concrete_type,
     materialization_work,
     depth + 1,
     diagnostic,
     allocator
    )) return false;
  }
  return true;
 }
 uint leaf_type = (uint)node.static_type;
 if (leaf_type == (uint)mitos::TYPE_ID_INVALID
  || leaf_type == (uint)mitos::TYPE_ID_ANY) return true;
 if (!*concrete_type)
 {
  *concrete_type = leaf_type;
  return true;
 }
 if (*concrete_type == leaf_type) return true;
 diagnostic.init(
  allocator, "superposition branches do not share one concrete runtime type"
 );
 return false;
}

fn bool delta_materialize_node(
	mitos::DeltaProgram* program,
	Net* net,
	mitos::DeltaNodeId node_id,
	NetRef destination,
	usz root_source_order,
	usz* occurrence_counter,
	usz* materialization_work,
	usz* materialization_bytes,
	List{DeltaMaterializedEffect}* effect_occurrences,
	usz depth,
	DeltaDiagnostic* diagnostic,
	Allocator allocator
) @private
{
	if (depth >= mitos::DELTA_MAX_EVALUATION_DEPTH)
	{
		diagnostic.init(allocator, "DeltaProgram graph exceeds the materialization depth limit");
		return false;
	}
	mitos::DeltaNode* source = mitos::delta_node(program, node_id);
	if (!source)
	{
		diagnostic.init(allocator, "DeltaProgram contains an invalid node identity");
		return false;
	}
	if (!delta_charge_materialization(materialization_work, 2, diagnostic, allocator)
		|| !delta_charge_materialization(
			materialization_work, source.inputs.len, diagnostic, allocator
		)
		|| !delta_charge_materialization(
			materialization_work, source.branches.len, diagnostic, allocator
		)
		|| (source.kind == DELTA_ABORT
			&& (!delta_charge_materialization(materialization_work, 1, diagnostic, allocator)
				|| !delta_charge_materialization(
					materialization_work, 2, diagnostic, allocator
				))))
	{
		return false;
	}
	if (source.kind == DELTA_HANDLER)
	{
		if (source.descriptor >= program.effects.handlers.len)
		{
			diagnostic.init(allocator, "handler node has an invalid metadata descriptor");
			return false;
		}
		mitos::DeltaHandlerDescriptor* handler =
			&program.effects.handlers[source.descriptor];
		if (source.inputs.len != handler.clauses.len + 2
			|| source.inputs[0] != handler.handled
			|| source.inputs[source.inputs.len - 1] != handler.return_body)
		{
			diagnostic.init(allocator, "handler node input layout does not match its metadata");
			return false;
		}
		foreach (clause_index, &clause : handler.clauses)
		{
			if (source.inputs[(usz)clause_index + 1] != clause.body)
			{
				diagnostic.init(
					allocator, "handler clause input does not match its metadata body"
				);
				return false;
			}
		}
	}
	List{DeltaMaterializedEffect} handled_effects;
	if (source.kind == DELTA_HANDLER) handled_effects.init(allocator);
	defer if (source.kind == DELTA_HANDLER) handled_effects.free();
	if (source.kind == DELTA_SUPERPOSE)
	{
		if (!source.inputs.len)
		{
			diagnostic.init(allocator, "superposition node must contain at least one ordered branch");
			return false;
		}
		if (!source.descriptor)
		{
			diagnostic.init(allocator, "superposition node is missing its stable origin");
			return false;
		}
		if (source.branches.len)
		{
			diagnostic.init(allocator, "superposition node stores branches outside its ordered input list");
			return false;
		}
		uint concrete_type = 0;
		foreach (input : source.inputs)
		{
			if (!delta_superposition_leaf_type(
				program,
				input,
				&concrete_type,
				materialization_work,
				depth + 1,
				diagnostic,
				allocator
			)) return false;
		}
		if (!delta_charge_materialized_agents(
			net,
			materialization_bytes,
			source.inputs.len,
			1,
			1,
			diagnostic,
			allocator
		)) return false;
		long[] deltas = mem::alloc_array(long, (sz)source.inputs.len);
		foreach (&delta : deltas) *delta = 0;
		NetRef replicator_ref = new_replicator(
			net,
			(ulong)source.descriptor,
			deltas,
			UNPAIRED,
			PARENT,
			true,
			(ulong)source.descriptor
		);
		mem::free(deltas);
		Node* replicator_node = net.nodes.get_ref(replicator_ref);
		NetRef principal = replicator_node.agent.replicator.principal;
		NetRef[] auxiliaries = replicator_node.agent.replicator.auxiliaries;
		(void)connect(net, destination, principal);
		foreach (index, input : source.inputs)
		{
			if (!delta_materialize_node(
				program,
				net,
				input,
				auxiliaries[index],
				root_source_order,
				occurrence_counter,
				materialization_work,
				materialization_bytes,
				effect_occurrences,
				depth + 1,
				diagnostic,
				allocator
			)) return false;
		}
		return true;
	}
	AgentType type = delta_practical_agent_type(source.kind);
 usz source_order = source.kind == DELTA_PARALLEL_ROOT
  ? source.descriptor : root_source_order;
	usz metadata_ports = source.kind == DELTA_ABORT ? 1 : 0;
	if (source.inputs.len > usz::max - source.branches.len
		|| source.inputs.len + source.branches.len > usz::max - metadata_ports)
	{
		diagnostic.init(
			allocator,
			"DeltaProgram graph exceeds the total materialization byte limit"
		);
		return false;
	}
	usz arity = source.inputs.len + source.branches.len + metadata_ports;
	if (!delta_charge_materialized_agents(
		net, materialization_bytes, arity, 1, 1, diagnostic, allocator
	)) return false;
	if (source.kind == DELTA_STRING
		&& !delta_charge_materialization_bytes(
			materialization_bytes, source.string_value.len, diagnostic, allocator
		)) return false;
	NetRef practical_ref = new_practical_agent(
		net,
		type,
		arity,
		(uint)node_id,
		(uint)source.static_type,
		source.integer,
		source.descriptor,
		source_order
	);
	Node* practical = net.nodes.get_ref(practical_ref);
	NetRef practical_principal = practical.agent.practical.principal;
	NetRef[] practical_auxiliaries = practical.agent.practical.auxiliaries;
	(void)connect(net, destination, practical_principal);
	if (source.kind == DELTA_STRING)
	{
		practical = net.nodes.get_ref(practical_ref);
		practical.agent.practical.text = source.string_value.copy(mem);
		practical.agent.practical.owns_text = true;
		net_account_node_payload_allocate(
			net, practical, source.string_value.len
		);
	}
	if (source.kind == DELTA_EFFECT)
	{
		if (source.descriptor >= program.effects.operations.len)
		{
			diagnostic.init(allocator, "effect node has an invalid operation descriptor");
			return false;
		}
		mitos::DeltaOperationDescriptor* operation = &program.effects.operations[source.descriptor];
		practical.agent.practical.effect_id = (uint)source.integer;
		practical.agent.practical.operation_id = (uint)operation.id;
		practical.agent.practical.effect_epoch = program.effects.epoch;
		practical.agent.practical.host_effect = delta_net_host_kind(operation.host_kind);
		practical.agent.practical.ordered_effect = operation.ordered;
  practical.agent.practical.source_order = source_order;
	}
	else if (source.kind == DELTA_RESUME)
	{
		if (source.descriptor >= program.effects.handlers.len)
		{
			diagnostic.init(allocator, "resume node has an invalid handler descriptor");
			return false;
		}
		practical.agent.practical.handler_id =
			program.effects.handlers[source.descriptor].stable_id;
		practical.agent.practical.effect_epoch = program.effects.epoch;
		practical.agent.practical.resume_count = 1;
		practical.agent.practical.resume_state = CONTINUATION_CAPTURED;
	}
	foreach (index, input : source.inputs)
	{
		if (!delta_materialize_node(
			program,
			net,
			input,
			practical_auxiliaries[index],
			source_order,
			occurrence_counter,
			materialization_work,
			materialization_bytes,
			source.kind == DELTA_HANDLER
				? (index == 0 ? &handled_effects : effect_occurrences)
				: effect_occurrences,
			depth + 1,
			diagnostic,
			allocator
		)) return false;
	}
	if (source.kind == DELTA_EFFECT)
	{
		practical = net.nodes.get_ref(practical_ref);
		practical.agent.practical.occurrence_order = (*occurrence_counter)++;
		if (effect_occurrences)
		{
			effect_occurrences.push({
				.hole = practical_principal,
				.effect_id = practical.agent.practical.effect_id,
				.operation_id = practical.agent.practical.operation_id,
				.source_order = practical.agent.practical.source_order,
				.occurrence_order = practical.agent.practical.occurrence_order,
			});
		}
	}
	foreach (branch_index, &branch : source.branches)
	{
		if (!delta_materialize_node(
			program,
			net,
			branch.body,
			practical_auxiliaries[source.inputs.len + (usz)branch_index],
			source_order,
			occurrence_counter,
			materialization_work,
			materialization_bytes,
			source.kind == DELTA_HANDLER ? null : effect_occurrences,
			depth + 1,
			diagnostic,
			allocator
		)) return false;
	}
	if (source.kind == DELTA_ABORT)
	{
		if (source.descriptor >= program.effects.handlers.len)
		{
			diagnostic.init(allocator, "abort node has an invalid handler descriptor");
			return false;
		}
		if (!delta_charge_materialized_agents(
			net, materialization_bytes, 0, 1, 1, diagnostic, allocator
		)) return false;
		NetRef eraser_ref = new_eraser(net, PARENT);
		Node* eraser = net.nodes.get_ref(eraser_ref);
		(void)connect(net, practical_auxiliaries[source.inputs.len], eraser.agent.eraser.principal);
		Node* refreshed = net.nodes.get_ref(practical_ref);
		refreshed.agent.practical.resume_state = CONTINUATION_ERASED;
		refreshed.agent.practical.operation_id = (uint)source.integer;
		refreshed.agent.practical.handler_id =
			program.effects.handlers[source.descriptor].stable_id;
		refreshed.agent.practical.effect_epoch = program.effects.epoch;
	}
	if (source.kind == DELTA_HANDLER)
	{
		mitos::DeltaHandlerDescriptor* handler = &program.effects.handlers[source.descriptor];
		Node* refreshed = net.nodes.get_ref(practical_ref);
		refreshed.agent.practical.handler_id = handler.stable_id;
		refreshed.agent.practical.effect_epoch = program.effects.epoch;
		char[] shadowed = alloc::new_array(
			allocator, char, (sz)handled_effects.len()
		);
		defer alloc::free(allocator, shadowed);
		foreach (&entry : shadowed) *entry = 0;
		foreach (clause_index, &clause : handler.clauses)
		{
			if (!delta_charge_materialization(
				materialization_work,
				program.effects.operations.len,
				diagnostic,
				allocator
			)) return false;
			mitos::DeltaOperationDescriptor* operation =
				delta_net_operation(program, clause.operation);
			if (!operation)
			{
				diagnostic.init(allocator, "handler clause operation metadata is missing");
				return false;
			}
			mitos::DeltaNode* clause_body = mitos::delta_node(program, clause.body);
			if (!clause_body)
			{
				diagnostic.init(allocator, "handler clause body metadata is missing");
				return false;
			}
			bool aborts = clause_body.kind == DELTA_ABORT;
			usz resume_count = aborts ? 0 : delta_resume_occurrences(
				program, clause.body, source.descriptor, 0
			);
			NetRef eraser_ref = INVALID_NET_REF;
			if (aborts)
			{
				NetRef body_port = practical_auxiliaries[(usz)clause_index + 1];
				NetRef body_principal = other_endpoint(
					net, net.ports.get_ref(body_port).wire_id, body_port
				);
				Node* body = net.nodes.get_ref(net.ports.get_ref(body_principal).node_id);
				NetRef cleanup =
					body.agent.practical.auxiliaries[body.agent.practical.auxiliaries.len - 1];
				NetRef eraser_port =
					other_endpoint(net, net.ports.get_ref(cleanup).wire_id, cleanup);
				eraser_ref = net.ports.get_ref(eraser_port).node_id;
			}
			foreach (effect_index, &effect : handled_effects)
			{
				if (!delta_charge_materialization(
					materialization_work, 1, diagnostic, allocator
				)) return false;
				if (effect.effect_id == (uint)clause.effect)
				{
					shadowed[(usz)effect_index] = 1;
				}
				if (effect.operation_id != (uint)clause.operation
					|| effect.effect_id != (uint)clause.effect) continue;
				if (!delta_charge_continuation(
					materialization_work,
					clause.multi,
					resume_count,
					diagnostic,
					allocator
				)) return false;
				if (!delta_charge_materialization_arena(
					materialization_bytes,
					net.effects.continuations.next_id,
					net.effects.continuations.free_head,
					net.effects.continuations.pages.size,
					net.effects.continuations.pages.capacity,
					stable_slot_arena::STABLE_SLOT_PAGE_CAPACITY{EffectContinuation},
					(usz)stable_slot_arena::StableSlotPage{EffectContinuation}::size,
					1,
					diagnostic,
					allocator
				)) return false;
				if (clause.multi && resume_count > 1
					&& !delta_charge_materialized_agents(
						net,
						materialization_bytes,
						resume_count,
						2,
						resume_count + 1,
						diagnostic,
						allocator
					)) return false;
				NetRef continuation = new_effect_continuation(
					net,
					practical_principal,
					effect.hole,
					practical_ref,
					handler.stable_id,
					effect.effect_id,
					effect.operation_id,
					program.effects.epoch,
					resume_count,
					effect.source_order,
					effect.occurrence_order,
					clause.multi,
					delta_net_host_kind(operation.host_kind),
					operation.ordered,
					eraser_ref
				);
				refreshed = net.nodes.get_ref(practical_ref);
				if (refreshed.agent.practical.continuation == INVALID_NET_REF)
				{
					refreshed.agent.practical.continuation = continuation;
				}
				refreshed.agent.practical.resume_count += resume_count;
			}
		}
		if (effect_occurrences)
		{
			foreach (effect_index, &effect : handled_effects)
			{
				if (!delta_charge_materialization(
					materialization_work, 1, diagnostic, allocator
				)) return false;
				if (!shadowed[(usz)effect_index]) effect_occurrences.push(*effect);
			}
		}
	}
	return true;
}
fn bool delta_effect_commit_precedes_or_ties(
	OrderedEffectCommit* left,
	OrderedEffectCommit* right
) @private
{
	return left.source_root_order < right.source_root_order
		|| (left.source_root_order == right.source_root_order
			&& left.operation_order <= right.operation_order);
}

// Bottom-up merge sort keeps equal-key continuations in stable slot order and
// bounds queue construction to O(n log n) comparisons.
fn void delta_stable_sort_effect_commits(OrderedEffectCommit[] commits) @private
{
	usz count = commits.len;
	if (count < 2) return;
	OrderedEffectCommit[] scratch =
		mem::alloc_array(OrderedEffectCommit, (sz)count);
	defer mem::free(scratch);
	usz width = 1;
	while (width < count)
	{
		usz start = 0;
		while (start < count)
		{
			usz left = start;
			usz middle = start + (width < count - start ? width : count - start);
			usz right = middle;
			usz end = middle + (width < count - middle ? width : count - middle);
			usz output = start;
			while (left < middle && right < end)
			{
				if (delta_effect_commit_precedes_or_ties(
					&commits[left], &commits[right]
				))
				{
					scratch[output++] = commits[left++];
				}
				else
				{
					scratch[output++] = commits[right++];
				}
			}
			while (left < middle) scratch[output++] = commits[left++];
			while (right < end) scratch[output++] = commits[right++];
			start = end;
		}
		foreach (index, &commit : commits) *commit = scratch[(usz)index];
		if (width > count / 2) break;
		width *= 2;
	}
}

fn bool delta_build_effect_commit_queue(
	Net* net,
	usz* materialization_bytes = null,
	DeltaDiagnostic* diagnostic = null,
	Allocator allocator = mem
)
{
	usz count = 0;
	for (SlotId id = 0; id < net.effects.continuations.next_id; id++)
	{
		if (!net.effects.continuations.contains_id(id)) continue;
		EffectContinuation* continuation = net.effects.continuations.get_ref(
			net.effects.continuations.generation_ref(id)
		);
		if (continuation.ordered) count++;
	}
	if (materialization_bytes && !delta_charge_materialization_items(
		materialization_bytes,
		count,
		(usz)OrderedEffectCommit::size,
		diagnostic,
		allocator
	)) return false;
	mem::free(net.effects.commits);
	net.effects.commits = { };
	net.effects.committed = 0;
	net.effects.commit_allocation_count = 0;
	net.effects.commits = mem::alloc_array(OrderedEffectCommit, (sz)count);
	net.effects.commit_allocation_count = count;
	usz cursor = 0;
	for (SlotId id = 0; id < net.effects.continuations.next_id; id++)
	{
		if (!net.effects.continuations.contains_id(id)) continue;
		NetRef continuation_ref = net.effects.continuations.generation_ref(id);
		EffectContinuation* continuation = net.effects.continuations.get_ref(continuation_ref);
		if (!continuation.ordered) continue;
		net.effects.commits[cursor++] = {
			.continuation = continuation_ref,
			.source_root_order = continuation.source_order,
			.operation_order = continuation.occurrence_order,
		};
	}
	delta_stable_sort_effect_commits(net.effects.commits);
	return true;
}


/** Materialize one immutable DeltaProgram root into generation-bearing slots. */
fn DeltaTranslationResult translate_delta_program_with_budget(
	mitos::DeltaProgram* program,
	mitos::DeltaNodeId root,
	usz* materialization_work,
	usz* materialization_bytes,
	Allocator allocator = mem
)
{
	DeltaTranslationResult result = {
		.allocator = allocator,
		.root = INVALID_NET_REF,
		.owns_net = true
	};
	result.net.init();
	if (!mitos::delta_program_is_compatible(program))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(
			allocator, "unsupported or incoherent DeltaProgram capability manifest"
		);
		return result;
	}
	result.net.effects.program_epoch = program.effects.epoch;
	result.net.effects.execution_epoch = program.effects.epoch;
	DeltaDiagnostic diagnostic;
	if (!delta_charge_materialization_arena(
		materialization_bytes,
		result.net.ports.next_id,
		result.net.ports.free_head,
		result.net.ports.pages.size,
		result.net.ports.pages.capacity,
		stable_slot_arena::STABLE_SLOT_PAGE_CAPACITY{Port},
		(usz)stable_slot_arena::StableSlotPage{Port}::size,
		1,
		&diagnostic,
		allocator
	) || !delta_charge_materialization_arena(
		materialization_bytes,
		result.net.interfaces.next_id,
		result.net.interfaces.free_head,
		result.net.interfaces.pages.size,
		result.net.interfaces.pages.capacity,
		stable_slot_arena::STABLE_SLOT_PAGE_CAPACITY{InterfacePort},
		(usz)stable_slot_arena::StableSlotPage{InterfacePort}::size,
		1,
		&diagnostic,
		allocator
	))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0] = diagnostic;
		return result;
	}
	result.root = new_interface(&result.net, ROOT, "");
	NetRef destination = result.net.interfaces.get_ref(result.root).port;
	usz root_source_order = 0;
	foreach (&boundary : program.image.interfaces)
	{
		if (boundary.root == root)
		{
			root_source_order = boundary.source_order;
			break;
		}
	}
	usz occurrence_counter = 0;
	if (!delta_materialize_node(
		program,
		&result.net,
		root,
		destination,
		root_source_order,
		&occurrence_counter,
		materialization_work,
		materialization_bytes,
		null,
		0,
		&diagnostic,
		allocator
	))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0] = diagnostic;
		return result;
	}
	if (!delta_build_effect_commit_queue(
		&result.net, materialization_bytes, &diagnostic, allocator
	))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0] = diagnostic;
		return result;
	}
	if (!validate_net(&result.net))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(
			allocator, "materialized DeltaProgram failed stable-slot validation"
		);
	}
	return result;
}

fn DeltaTranslationResult translate_delta_program(
	mitos::DeltaProgram* program,
	mitos::DeltaNodeId root,
	Allocator allocator = mem
)
{
	usz materialization_work = 0;
	usz materialization_bytes = 0;
	return translate_delta_program_with_budget(
		program, root, &materialization_work, &materialization_bytes, allocator
	);
}
