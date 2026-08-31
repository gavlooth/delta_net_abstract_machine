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

struct DeltaOccurrence
{
	NetRef destination;
	long level;
}

struct DeltaBinder
{
	String name;
	NetRef variable_port;
	long base_level;
	List{DeltaOccurrence} occurrences;
}

struct DeltaFreeInterface
{
	String name;
	NetRef interface_ref;
	List{DeltaOccurrence} occurrences;
}

struct DeltaTranslationResult
{
	Allocator allocator;
	Net net;
	NetRef root;
	String[] owned_interface_names;
	DeltaDiagnostic[] diagnostics;
	bool owns_net;
}

fn bool DeltaTranslationResult.ok(&self) => self.diagnostics.len == 0;

fn void DeltaTranslationResult.deinit(&self)
{
	if (!self.allocator) return;
	if (self.owns_net) self.net.free();
	foreach (name : self.owned_interface_names) alloc::free(self.allocator, name);
	alloc::free(self.allocator, self.owned_interface_names);
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

struct DeltaTranslator
{
	Allocator allocator;
	Net* net;
	List{DeltaBinder} binders;
	List{DeltaFreeInterface} frees;
	List{String} owned_interface_names;
	List{DeltaDiagnostic} diagnostics;
}

fn void delta_translation_error(DeltaTranslator* translator, String message) @private
{
	if (translator.diagnostics.len()) return;
	DeltaDiagnostic diagnostic;
	diagnostic.init(translator.allocator, message);
	translator.diagnostics.push(diagnostic);
}

fn sz delta_find_binder(DeltaTranslator* translator, String name) @private
{
	for (sz index = translator.binders.len() - 1; index >= 0; index--)
	{
		if (translator.binders[index].name == name) return index;
	}
	return -1;
}

fn sz delta_find_free(DeltaTranslator* translator, String name) @private
{
	foreach (index, &entry : translator.frees)
	{
		if (entry.name == name) return (sz)index;
	}
	return -1;
}


fn void delta_finalize_occurrences(
	DeltaTranslator* translator,
	NetRef source_parent,
	long base_level,
	DeltaOccurrence[] occurrences
) @private
{
	if (translator.diagnostics.len()) return;
	if (!occurrences.len)
	{
		NetRef eraser = new_eraser(translator.net);
		(void)connect(translator.net, source_parent, translator.net.nodes.get_ref(eraser).agent.eraser.principal);
		return;
	}
	if (occurrences.len == 1 && occurrences[0].level == base_level)
	{
		(void)connect(translator.net, source_parent, occurrences[0].destination);
		return;
	}

	long[] deltas = alloc::new_array(translator.allocator, long, (sz)occurrences.len);
	foreach (index, occurrence : occurrences)
	{
		int128 delta = (int128)occurrence.level - (int128)base_level;
		if (delta < (int128)long::min || delta > (int128)long::max)
		{
			alloc::free(translator.allocator, deltas);
			delta_translation_error(translator, "replicator occurrence delta is outside the signed 64-bit range");
			return;
		}
		deltas[index] = (long)delta;
	}
	if (base_level < 0)
	{
		alloc::free(translator.allocator, deltas);
		delta_translation_error(translator, "replicator level is negative");
		return;
	}
	NetRef replicator = new_replicator(
		translator.net,
		(ulong)base_level,
		deltas,
		UNPAIRED,
		CHILD
	);
	alloc::free(translator.allocator, deltas);
	Node* node = translator.net.nodes.get_ref(replicator);
	(void)connect(translator.net, source_parent, node.agent.replicator.principal);
	foreach (index, occurrence : occurrences)
	{
		(void)connect(translator.net, node.agent.replicator.auxiliaries[index], occurrence.destination);
	}
}

fn void delta_emit_variable(DeltaTranslator* translator, String name, NetRef destination, long level) @private
{
	sz binder_index = delta_find_binder(translator, name);
	if (binder_index >= 0)
	{
		translator.binders[binder_index].occurrences.push({ .destination = destination, .level = level });
		return;
	}

	sz free_index = delta_find_free(translator, name);
	if (free_index < 0)
	{
		String owned_name = name.copy(translator.allocator);
		translator.owned_interface_names.push(owned_name);
		NetRef interface_ref = new_interface(translator.net, FREE_VARIABLE, owned_name);
		DeltaFreeInterface entry = { .name = owned_name, .interface_ref = interface_ref };
		entry.occurrences.init(translator.allocator);
		translator.frees.push(entry);
		free_index = translator.frees.len() - 1;
	}
	translator.frees[free_index].occurrences.push({ .destination = destination, .level = level });
}

fn void delta_emit_abstraction(
	DeltaTranslator* translator,
	mitos::CoreExpr* expression,
	NetRef destination,
	long level
) @private
{
	NetRef fan_ref = new_fan(translator.net, PARENT);
	Node* fan = translator.net.nodes.get_ref(fan_ref);
	NetRef principal = fan.agent.fan.principal;
	NetRef body = fan.agent.fan.left;
	NetRef variable = fan.agent.fan.right;
	(void)connect(translator.net, destination, principal);

	DeltaBinder binder = {
		.name = expression.data.abstraction.parameter,
		.variable_port = variable,
		.base_level = level + 1,
	};
	binder.occurrences.init(translator.allocator);
	translator.binders.push(binder);
	delta_emit_core(translator, expression.data.abstraction.body, body, level);
	DeltaBinder completed = translator.binders.pop()!!;
	if (!translator.diagnostics.len())
	{
		DeltaOccurrence[] occurrences = completed.occurrences.to_array(translator.allocator);
		delta_finalize_occurrences(
			translator,
			completed.variable_port,
			completed.base_level,
			occurrences
		);
		alloc::free(translator.allocator, occurrences);
	}
	completed.occurrences.free();
}

fn void delta_emit_application(
	DeltaTranslator* translator,
	mitos::CoreExpr* expression,
	NetRef destination,
	long level
) @private
{
	NetRef fan_ref = new_fan(translator.net, CHILD);
	Node* fan = translator.net.nodes.get_ref(fan_ref);
	NetRef function = fan.agent.fan.principal;
	NetRef result = fan.agent.fan.left;
	NetRef argument = fan.agent.fan.right;
	(void)connect(translator.net, destination, result);
	delta_emit_core(translator, expression.data.application.function, function, level);
	if (!translator.diagnostics.len())
	{
		if (level == long::max)
		{
			delta_translation_error(translator, "translation level overflow");
			return;
		}
		delta_emit_core(translator, expression.data.application.argument, argument, level + 1);
	}
}

fn void delta_emit_core(DeltaTranslator* translator, mitos::CoreExpr* expression, NetRef destination, long level) @private
{
	if (translator.diagnostics.len()) return;
	if (!expression)
	{
		delta_translation_error(translator, "cannot translate a missing core expression");
		return;
	}
	if (!translator.net.ports.contains_ref(destination)
		|| translator.net.ports.get_ref(destination).polarity != CHILD)
	{
		delta_translation_error(translator, "translation destination is not a live CHILD port");
		return;
	}
	switch (expression.kind)
	{
		case CORE_VARIABLE:
			delta_emit_variable(translator, expression.data.variable.name, destination, level);
		case CORE_ABSTRACTION:
			if (level == long::max)
			{
				delta_translation_error(translator, "translation level overflow");
				return;
			}
			delta_emit_abstraction(translator, expression, destination, level);
		case CORE_APPLICATION:
			delta_emit_application(translator, expression, destination, level);
		case CORE_PARALLEL:
			delta_translation_error(translator, "CORE_PARALLEL must be expanded by DeltaRuntime before net translation");
		default:
			delta_translation_error(translator, "unknown core expression kind");
	}
}

fn DeltaTranslationResult translate_core(mitos::CoreExpr* expression, Allocator allocator = mem)
{
	DeltaTranslationResult result = { .allocator = allocator, .root = INVALID_NET_REF, .owns_net = true };
	result.net.init();
	DeltaTranslator translator = { .allocator = allocator, .net = &result.net };
	translator.binders.init(allocator);
	translator.frees.init(allocator);
	translator.owned_interface_names.init(allocator);
	translator.diagnostics.init(allocator);

	result.root = new_interface(&result.net, ROOT, "");
	NetRef root_port = result.net.interfaces.get_ref(result.root).port;
	delta_emit_core(&translator, expression, root_port, 0);

	if (!translator.diagnostics.len())
	{
		foreach (&entry : translator.frees)
		{
			NetRef free_port = result.net.interfaces.get_ref(entry.interface_ref).port;
			DeltaOccurrence[] occurrences = entry.occurrences.to_array(allocator);
			delta_finalize_occurrences(&translator, free_port, 0, occurrences);
			alloc::free(allocator, occurrences);
			if (translator.diagnostics.len()) break;
		}
	}

	foreach (&binder : translator.binders) binder.occurrences.free();
	foreach (&entry : translator.frees) entry.occurrences.free();
	translator.binders.free();
	translator.frees.free();
	result.owned_interface_names = translator.owned_interface_names.to_array(allocator);
	translator.owned_interface_names.free();
	result.diagnostics = translator.diagnostics.to_array(allocator);
	translator.diagnostics.free();
	return result;
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
fn NetRef delta_effect_hole(Net* net, mitos::DeltaNodeId occurrence)
{
 for (SlotId id = 0; id < net.nodes.next_id; id++)
 {
  if (!net.nodes.contains_id(id)) continue;
  NetRef node_ref = net.nodes.generation_ref(id);
  Node* node = net.nodes.get_ref(node_ref);
  if (node.type == EFFECT_AGENT
   && node.agent.practical.semantic_id == (uint)occurrence)
  {
   return node.agent.practical.principal;
  }
 }
 return INVALID_NET_REF;
}

fn void delta_effect_occurrences(
 mitos::DeltaProgram* program,
 mitos::DeltaNodeId node_id,
 mitos::OperationId operation,
 mitos::EffectId effect,
 List{mitos::DeltaNodeId}* occurrences,
 usz depth
) @private
{
 if (depth >= mitos::DELTA_MAX_EVALUATION_DEPTH) return;
 mitos::DeltaNode* node = mitos::delta_node(program, node_id);
 if (!node) return;
 if (node.kind == DELTA_HANDLER) return;
 if (node.kind == DELTA_EFFECT)
 {
  if (node.descriptor < program.effects.operations.len
   && program.effects.operations[node.descriptor].id == operation
   && (mitos::EffectId)node.integer == effect)
  {
   occurrences.push(node_id);
  }
  return;
 }
 foreach (input : node.inputs)
 {
  delta_effect_occurrences(
   program, input, operation, effect, occurrences, depth + 1
  );
 }
 foreach (&branch : node.branches)
 {
  delta_effect_occurrences(
   program, branch.body, operation, effect, occurrences, depth + 1
  );
 }
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
 if (node.kind == DELTA_LAMBDA || node.kind == DELTA_HANDLER) return 0;
 if (node.kind == DELTA_RESUME && node.descriptor == handler_index) return 1;
 usz count = 0;
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
 return count;
}

fn bool delta_materialize_node(
 mitos::DeltaProgram* program,
 Net* net,
 mitos::DeltaNodeId node_id,
 NetRef destination,
 usz root_source_order,
 usz* occurrence_counter,
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
			mitos::DeltaNode* branch = mitos::delta_node(program, input);
			if (!branch)
			{
				diagnostic.init(allocator, "superposition contains an invalid branch identity");
				return false;
			}
			uint branch_type = (uint)(branch.kind == DELTA_SUPERPOSE
				? branch.result_type : branch.static_type);
			if (branch_type == (uint)mitos::TYPE_ID_INVALID
				|| branch_type == (uint)mitos::TYPE_ID_ANY) continue;
			if (!concrete_type)
			{
				concrete_type = branch_type;
			}
			else if (concrete_type != branch_type)
			{
				diagnostic.init(
					allocator,
					"superposition branches do not share one concrete runtime type"
				);
				return false;
			}
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
  practical.agent.practical.occurrence_order = (*occurrence_counter)++;
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
			depth + 1,
			diagnostic,
			allocator
		)) return false;
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
		if (source.descriptor >= program.effects.handlers.len)
		{
			diagnostic.init(allocator, "handler node has an invalid metadata descriptor");
			return false;
		}
		mitos::DeltaHandlerDescriptor* handler = &program.effects.handlers[source.descriptor];
		Node* refreshed = net.nodes.get_ref(practical_ref);
		refreshed.agent.practical.handler_id = handler.stable_id;
		refreshed.agent.practical.effect_epoch = program.effects.epoch;
		foreach (clause_index, &clause : handler.clauses)
		{
			mitos::DeltaOperationDescriptor* operation = delta_net_operation(program, clause.operation);
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
   List{mitos::DeltaNodeId} occurrences;
   occurrences.init(allocator);
   delta_effect_occurrences(
    program, handler.handled, clause.operation, clause.effect, &occurrences, 0
   );
   foreach (occurrence : occurrences)
   {
    NetRef hole = delta_effect_hole(net, occurrence);
    if (hole == INVALID_NET_REF)
    {
     occurrences.free();
     diagnostic.init(allocator, "effect continuation occurrence is absent from its lexical handler graph");
     return false;
    }
    PracticalAgent* effect =
     &net.nodes.get_ref(net.ports.get_ref(hole).node_id).agent.practical;
    NetRef continuation = new_effect_continuation(
     net,
     practical_principal,
     hole,
     practical_ref,
     handler.stable_id,
     (uint)clause.effect,
     (uint)clause.operation,
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
   occurrences.free();
		}
	}
	return true;
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
	for (usz index = 1; index < count; index++)
	{
		OrderedEffectCommit current = net.effects.commits[index];
		usz insertion = index;
		while (insertion > 0)
		{
			OrderedEffectCommit previous = net.effects.commits[insertion - 1];
			if (previous.source_root_order < current.source_root_order
				|| (previous.source_root_order == current.source_root_order
					&& previous.operation_order <= current.operation_order)) break;
			net.effects.commits[insertion] = previous;
			insertion--;
		}
		net.effects.commits[insertion] = current;
	}
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
	if (!program || program.format_version != mitos::DELTA_PROGRAM_FORMAT_VERSION)
	{
		result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
		result.diagnostics[0].init(allocator, "unsupported or missing DeltaProgram image");
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
 DeltaDiagnostic diagnostic;
 if (!delta_materialize_node(
  program,
  &result.net,
  root,
  destination,
  root_source_order,
  &occurrence_counter,
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
