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
	NetRef practical_ref = new_practical_agent(
		net,
		type,
		source.inputs.len + source.branches.len + metadata_ports,
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

fn void delta_build_effect_commit_queue(Net* net)
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
 mem::free(net.effects.commits);
 net.effects.commits = { };
 net.effects.committed = 0;
	net.effects.commits = mem::alloc_array(OrderedEffectCommit, (sz)count);
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
}


/** Materialize one immutable DeltaProgram root into generation-bearing slots. */
fn DeltaTranslationResult translate_delta_program(
	mitos::DeltaProgram* program,
	mitos::DeltaNodeId root,
	Allocator allocator = mem
)
{
	DeltaTranslationResult result = { .allocator = allocator, .root = INVALID_NET_REF, .owns_net = true };
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
	result.root = new_interface(&result.net, ROOT, "");
	NetRef destination = result.net.interfaces.get_ref(result.root).port;
 usz root_source_order = 0;
 foreach (&boundary : program.image.interfaces)
 {
  if (boundary.root == root) { root_source_order = boundary.source_order; break; }
 }
 usz occurrence_counter = 0;
 usz materialization_work = 0;
 DeltaDiagnostic diagnostic;
 if (!delta_materialize_node(
  program,
  &result.net,
  root,
  destination,
  root_source_order,
  &occurrence_counter,
  &materialization_work,
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
	delta_build_effect_commit_queue(&result.net);
	if (!validate_net(&result.net))
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "materialized DeltaProgram failed stable-slot validation");
	}
	return result;
}
