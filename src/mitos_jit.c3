module delta_net_abstract_machine::mitos_jit;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_mir;

import std::collections::list;
import std::io;

const uint JIT_MAX_REGISTERS    = 65_536;
const uint JIT_MAX_INSTRUCTIONS = 1_000_000;
const uint JIT_MAX_OPERANDS     = 4_000_000;
const uint JIT_MAX_DEPTH        = 1_024;
const usz JIT_MAX_SUPERPOSE_BRANCHES = 65_536;

const mitos::DeltaFeatureBits MIR_SUPPORTED_DELTA_FEATURES =
	mitos::DELTA_FEATURE_ALL_KNOWN
		& ~mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES
		& ~mitos::DELTA_FEATURE_SUSPENSION;

fn bool mir_supports_required_features(mitos::DeltaProgram* program)
{
	return program
		&& !(program.feature_manifest.required & ~MIR_SUPPORTED_DELTA_FEATURES);
}


struct MirScope
{
	MirScope* parent;
	String[] names;
	mitos::TypeId[] types;
	uint[] registers;
	mitos::DeltaNodeId[] closure_nodes;
	MirScope*[] closure_environments;
	LoweredValue[][] fields;
	LoweredValue[] values;
}

struct MirSubstitution
{
	MirSubstitution* parent;
	mitos::DeltaNodeId hole;
	LoweredValue value;
}

struct MirHandlerActivation
{
	MirHandlerActivation* parent;
	usz handler_index;
	mitos::DeltaHandlerDescriptor* handler;
	MirScope* environment;
	mitos::DeltaNodeId handler_node;
	mitos::DeltaNodeId handled_root;
	mitos::DeltaNodeId hole;
	usz resumes_used;
	ulong effect_epoch;
	bool multi;
	bool aborted;
}
struct MirResumeBranchState
{
	MirHandlerActivation* activation;
	usz baseline;
	usz merged;
	bool baseline_aborted;
	bool merged_aborted;
}


struct LoweredValue
{
	uint register;
	mitos::TypeId type_id;
	mitos::DeltaNodeId closure_node;
	MirScope* closure_environment;
	bool pending_effect;
	usz effect_operation;
	mitos::DeltaNodeId effect_node;
	ulong effect_epoch;
	usz effect_source_order;
	LoweredValue[] effect_arguments;
	LoweredValue[] fields;
	LoweredValue[] alternatives;
	mitos::DeltaNodeId alternatives_node;
	uint alternative_scrutinee;
	mitos::DeltaNodeId constructor_node;
	bool provenance_only;
	LazyMaterialization* lazy;
}

struct LazyMaterialization
{
	bool materializing;
	ulong scope_id;
	usz scope_depth;
	uint register;
	mitos::TypeId type_id;
}
struct MirMethodInstance
{
	mitos::DeltaNodeId root;
	String[] parameters;
	usz generic_index;
	usz method_index;
	mitos::TypeId[] concrete_types;
	String[] type_variables;
	mitos::TypeId[] type_bindings;
	uint function_index;
	mitos::TypeId result_type;
	usz source_order;
	bool parallel_source;
}

struct MirMethodActivation
{
	MirMethodActivation* parent;
	usz generic_index;
	usz method_index;
	mitos::TypeId[] concrete_types;
	uint function_index;
}

struct DeltaMirLowerer
{
	Allocator allocator;
	mitos::DeltaProgram* source;

	usz current_source_order;
	bool current_parallel_source;
	List{mitos_mir::MirFunction} functions;
	mitos_mir::MirConstructor[] constructors;
	mitos_mir::MirType[] types;
	mitos_mir::MirLayout[] layouts;
	List{mitos_mir::MirInstruction} instructions;
	List{uint} operands;
	uint next_register;
	uint next_label;
	bool failed;
	String diagnostic;
	MirSubstitution* substitution;
	MirHandlerActivation* activation;
	MirMethodActivation* method_activation;
	List{LoweredValue[]} effect_argument_sets;
	List{LoweredValue[]} provenance_field_sets;
	List{MirScope*} provenance_scopes;
	List{mitos_mir::MirString} strings;
	mitos_mir::MirEffectOperation[] effect_operations;
	List{MirMethodInstance} instances;
	List{String} type_names;
	List{mitos_mir::MirMatchArm} match_arms;
	List{LazyMaterialization*} lazy_materializations;
	List{ulong} materialization_path;
	ulong next_materialization_scope_id;
	char[] effect_scan;
	char[] closure_type_scan;
	char[] effectful_lambda_scan;
	uint[] instance_slots;
	usz instance_slot_count;
}

struct OwnedMirProgram
{
	Allocator allocator;
	ulong program_identity;
	mitos_mir::MirFunction[] functions;
	mitos_mir::MirInstruction[] instructions;
	uint[] operands;
	mitos_mir::MirConstructor[] constructors;
	mitos_mir::MirType[] types;
	mitos_mir::MirLayout[] layouts;
	String[] type_names;
	uint main_function;
	uint phase_one_root_count;
	mitos_mir::MirString[] strings;
	uint max_source_order;
	mitos_mir::MirEffectOperation[] effect_operations;
	mitos_mir::MirMatchArm[] match_arms;
	mitos_mir::MirSpan[] spans;
}

struct MitosMirLowerResult
{
	Allocator allocator;
	OwnedMirProgram program;
	String diagnostic;
}

struct MitosJitResult
{
	mitos_mir::MirStatus status;
	String result;
	String diagnostic;
	mitos::MitosSpan diagnostic_span;
	uint native_instruction_count;

	Allocator allocator;
}

fn void MitosJitResult.free(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.result);
	alloc::free(self.allocator, self.diagnostic);
	*self = { };
}

fn void OwnedMirProgram.free(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.functions);
	alloc::free(self.allocator, self.instructions);
	alloc::free(self.allocator, self.operands);
	alloc::free(self.allocator, self.constructors);
	foreach (name : self.type_names) alloc::free(self.allocator, name);
	alloc::free(self.allocator, self.type_names);
	alloc::free(self.allocator, self.types);
	alloc::free(self.allocator, self.layouts);
	alloc::free(self.allocator, self.strings);
	alloc::free(self.allocator, self.effect_operations);
	alloc::free(self.allocator, self.match_arms);
	alloc::free(self.allocator, self.spans);
	*self = { };
}

fn mitos_mir::MirProgram OwnedMirProgram.view(&self)
{
	return {
		.program_identity = self.program_identity,
		.functions = self.functions.ptr,
		.instructions = self.instructions.ptr,
		.operands = self.operands.ptr,
		.constructors = self.constructors.ptr,
		.types = self.types.ptr,
		.layouts = self.layouts.ptr,
		.strings = self.strings.ptr,
		.effect_operations = self.effect_operations.ptr,
		.match_arms = self.match_arms.ptr,
		.spans = self.spans.ptr,
		.function_count = (uint)self.functions.len,
		.instruction_count = (uint)self.instructions.len,
		.operand_count = (uint)self.operands.len,
		.constructor_count = (uint)self.constructors.len,
		.type_count = (uint)self.types.len,
		.layout_count = (uint)self.layouts.len,
		.string_count = (uint)self.strings.len,
		.effect_operation_count = (uint)self.effect_operations.len,
		.match_arm_count = (uint)self.match_arms.len,
		.span_count = (uint)self.spans.len,
		.max_source_order = self.max_source_order,
		.main_function = self.main_function,
		.true_tag = 1,
		.false_tag = 0,
		.i64_type = (uint)mitos::TYPE_ID_I64,
		.bool_type = (uint)mitos::TYPE_ID_BOOL,
		.string_type = (uint)mitos::TYPE_ID_STRING,
		.type_type = (uint)mitos::TYPE_ID_TYPE,
		.function_type = (uint)mitos::TYPE_ID_FUNCTION,
		.phase_one_root_count = self.phase_one_root_count,
		.max_workers = 4,
	};
}

fn bool MitosMirLowerResult.ok(&self) => self.diagnostic.len == 0;

fn void MitosMirLowerResult.free(&self)
{
	if (!self.allocator) return;
	self.program.free();
	alloc::free(self.allocator, self.diagnostic);
	*self = { };
}

fn void DeltaMirLowerer.fail(&self, String message)
{
	if (self.failed) return;
	self.failed = true;
	self.diagnostic = message.copy(self.allocator);
}

fn uint new_register(DeltaMirLowerer* lowerer)
{
	if (lowerer.next_register >= JIT_MAX_REGISTERS)
	{
		lowerer.fail("MIR JIT virtual-register limit exceeded");
		return 0;
	}
	return lowerer.next_register++;
}

fn uint new_label(DeltaMirLowerer* lowerer)
{
	if (lowerer.next_label >= JIT_MAX_INSTRUCTIONS)
	{
		lowerer.fail("MIR JIT label limit exceeded");
		return 0;
	}
	return lowerer.next_label++;
}

fn void emit(DeltaMirLowerer* lowerer, mitos_mir::MirInstruction instruction)
{
	if (lowerer.failed) return;
	if (lowerer.instructions.size >= (sz)JIT_MAX_INSTRUCTIONS)
	{
		lowerer.fail("MIR JIT instruction limit exceeded");
		return;
	}
	lowerer.instructions.push(instruction);
}

fn uint append_operands(DeltaMirLowerer* lowerer, uint[] registers)
{
	if (lowerer.failed) return 0;
	if (registers.len > (usz)JIT_MAX_OPERANDS
		|| lowerer.operands.size > (sz)JIT_MAX_OPERANDS - (sz)registers.len)
	{
		lowerer.fail("MIR JIT operand-pool limit exceeded");
		return 0;
	}
	uint start = (uint)lowerer.operands.size;
	foreach (register : registers) lowerer.operands.push(register);
	return start;
}

fn LoweredValue scope_binding_value(MirScope* scope, usz index)
{
	if (index < scope.values.len)
	{
		LoweredValue result = scope.values[index];
		result.register = scope.registers[index];
		result.type_id = scope.types[index];
		return result;
	}
	return {
		.register = scope.registers[index],
		.type_id = scope.types[index],
		.closure_node = index < scope.closure_nodes.len
			? scope.closure_nodes[index] : mitos::DELTA_NODE_INVALID,
		.fields = index < scope.fields.len ? scope.fields[index] : { },
		.closure_environment = index < scope.closure_environments.len
			? scope.closure_environments[index] : null,
	};
}

fn bool find_binding(MirScope* scope, String name, LoweredValue* result)
{
	for (MirScope* current = scope; current; current = current.parent)
	{
		foreach (index, candidate : current.names)
		{
			if (candidate != name) continue;
			*result = scope_binding_value(current, (usz)index);
			return true;
		}
	}
	return false;
}

struct GraphNameIndex
{
	Allocator allocator;
	String[] slots;
	usz[] counts;
	usz[] ordinals;
	bool[] occupied;
	usz entry_count;
}

struct GraphBindings
{
	GraphNameIndex index;
	List{String} stack;
}

struct OrderedGraphNames
{
	GraphNameIndex index;
	List{String} order;
}

fn ulong graph_name_hash(String name)
{
	ulong hash = 1469598103934665603UL;
	foreach (byte : name)
	{
		hash ^= (ulong)byte;
		hash *= 1099511628211UL;
	}
	return hash;
}

fn void GraphNameIndex.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.slots = alloc::new_array(allocator, String, 16);
	self.counts = alloc::new_array(allocator, usz, 16);
	self.ordinals = alloc::new_array(allocator, usz, 16);
	self.occupied = alloc::new_array(allocator, bool, 16);
	foreach (&occupied : self.occupied) *occupied = false;
}

fn void GraphNameIndex.deinit(&self)
{
	alloc::free(self.allocator, self.slots);
	alloc::free(self.allocator, self.counts);
	alloc::free(self.allocator, self.ordinals);
	alloc::free(self.allocator, self.occupied);
	*self = { };
}

fn void GraphNameIndex.grow(&self)
{
	usz capacity = self.slots.len * 2;
	String[] slots = alloc::new_array(self.allocator, String, (sz)capacity);
	usz[] counts = alloc::new_array(self.allocator, usz, (sz)capacity);
	usz[] ordinals = alloc::new_array(self.allocator, usz, (sz)capacity);
	bool[] occupied = alloc::new_array(self.allocator, bool, (sz)capacity);
	foreach (&entry : occupied) *entry = false;
	foreach (index, name : self.slots)
	{
		if (!self.occupied[index]) continue;
		usz slot = (usz)graph_name_hash(name) & (capacity - 1);
		while (occupied[slot]) slot = (slot + 1) & (capacity - 1);
		slots[slot] = name;
		counts[slot] = self.counts[index];
		ordinals[slot] = self.ordinals[index];
		occupied[slot] = true;
	}
	alloc::free(self.allocator, self.slots);
	alloc::free(self.allocator, self.counts);
	alloc::free(self.allocator, self.ordinals);
	alloc::free(self.allocator, self.occupied);
	self.slots = slots;
	self.counts = counts;
	self.ordinals = ordinals;
	self.occupied = occupied;
}

fn usz GraphNameIndex.find_slot(&self, String name)
{
	usz slot = (usz)graph_name_hash(name) & (self.slots.len - 1);
	while (self.occupied[slot] && self.slots[slot] != name)
	{
		slot = (slot + 1) & (self.slots.len - 1);
	}
	return slot;
}

fn bool GraphNameIndex.contains(&self, String name)
{
	usz slot = self.find_slot(name);
	return self.occupied[slot] && self.counts[slot] != 0;
}

fn void GraphNameIndex.increment(&self, String name)
{
	usz slot = self.find_slot(name);
	if (self.occupied[slot])
	{
		self.counts[slot]++;
		return;
	}
	if (self.entry_count * 2 >= self.slots.len)
	{
		self.grow();
		slot = self.find_slot(name);
	}
	self.occupied[slot] = true;
	self.slots[slot] = name;
	self.counts[slot] = 1;
	self.entry_count++;
}

fn void GraphNameIndex.decrement(&self, String name)
{
	usz slot = self.find_slot(name);
	if (self.occupied[slot] && self.counts[slot]) self.counts[slot]--;
}

fn void GraphBindings.init(&self, Allocator allocator)
{
	self.index.init(allocator);
	self.stack.init(allocator);
}

fn void GraphBindings.deinit(&self)
{
	self.index.deinit();
	self.stack.free();
	*self = { };
}

fn void GraphBindings.push(&self, String name)
{
	self.index.increment(name);
	self.stack.push(name);
}

fn void GraphBindings.pop(&self, usz count)
{
	while (count)
	{
		String name = self.stack.pop()!!;
		self.index.decrement(name);
		count--;
	}
}

fn bool GraphBindings.contains(&self, String name)
{
	return self.index.contains(name);
}

fn void OrderedGraphNames.init(&self, Allocator allocator)
{
	self.index.init(allocator);
	self.order.init(allocator);
}

fn void OrderedGraphNames.deinit(&self)
{
	self.index.deinit();
	self.order.free();
	*self = { };
}

fn void OrderedGraphNames.add(&self, String name)
{
	if (self.index.contains(name)) return;
	self.index.increment(name);
	usz slot = self.index.find_slot(name);
	self.index.ordinals[slot] = (usz)self.order.size + 1;
	self.order.push(name);
}

fn sz OrderedGraphNames.position(&self, String name)
{
	usz slot = self.index.find_slot(name);
	if (!self.index.occupied[slot] || !self.index.counts[slot]) return -1;
	return (sz)self.index.ordinals[slot] - 1;
}

fn bool resolve_graph_captures(
	DeltaMirLowerer* lowerer,
	MirScope* scope,
	OrderedGraphNames* names,
	LoweredValue[] captures
)
{
	if (captures.len != (usz)names.order.size) return false;
	bool[] resolved = alloc::new_array(
		lowerer.allocator, bool, (sz)captures.len
	);
	defer alloc::free(lowerer.allocator, resolved);
	foreach (&entry : resolved) *entry = false;
	usz remaining = captures.len;
	for (MirScope* current = scope; current && remaining; current = current.parent)
	{
		foreach (index, candidate : current.names)
		{
			sz position = names.position(candidate);
			if (position < 0 || resolved[(usz)position]) continue;
			captures[(usz)position] = scope_binding_value(current, (usz)index);
			resolved[(usz)position] = true;
			remaining--;
		}
	}
	return remaining == 0;
}

fn bool collect_graph_free_names(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNodeId node_id,
	GraphBindings* bindings,
	OrderedGraphNames* free_names,
	uint depth
)
{
	if (depth >= JIT_MAX_DEPTH || !node_id)
	{
		lowerer.fail("MIR closure capture analysis exceeded the graph depth limit");
		return false;
	}
	mitos::DeltaNode* node = mitos::delta_node(lowerer.source, node_id);
	if (!node)
	{
		lowerer.fail("MIR closure capture analysis reached an invalid Delta node");
		return false;
	}
	switch (node.kind)
	{
		case DELTA_LOCAL:
			if (!bindings.contains(node.name)) free_names.add(node.name);
			return true;
		case DELTA_LET:
			if (node.inputs.len != 2 || node.names.len != 1)
			{
				lowerer.fail("MIR closure capture analysis found an invalid let node");
				return false;
			}
			if (!collect_graph_free_names(
				lowerer, node.inputs[0], bindings, free_names, depth + 1
			)) return false;
			bindings.push(node.names[0]);
			bool let_ok = collect_graph_free_names(
				lowerer, node.inputs[1], bindings, free_names, depth + 1
			);
			bindings.pop(1);
			return let_ok;
		case DELTA_LAMBDA:
			if (node.inputs.len != 1)
			{
				lowerer.fail("MIR closure capture analysis found an invalid lambda node");
				return false;
			}
			foreach (name : node.names) bindings.push(name);
			bool lambda_ok = collect_graph_free_names(
				lowerer, node.inputs[0], bindings, free_names, depth + 1
			);
			bindings.pop(node.names.len);
			return lambda_ok;
		case DELTA_MATCH:
			foreach (input : node.inputs)
			{
				if (!collect_graph_free_names(
					lowerer, input, bindings, free_names, depth + 1
				)) return false;
			}
			foreach (&branch : node.branches)
			{
				foreach (name : branch.bindings) bindings.push(name);
				bool branch_ok = collect_graph_free_names(
					lowerer, branch.body, bindings, free_names, depth + 1
				);
				bindings.pop(branch.bindings.len);
				if (!branch_ok) return false;
			}
			return true;
		case DELTA_PARALLEL_JOIN:
			if (node.inputs.len != node.names.len + 1)
			{
				lowerer.fail("MIR closure capture analysis found an invalid parallel join");
				return false;
			}
			for (usz index = 0; index < node.names.len; index++)
			{
				if (!collect_graph_free_names(
					lowerer, node.inputs[index], bindings, free_names, depth + 1
				)) return false;
			}
			foreach (name : node.names) bindings.push(name);
			bool join_ok = collect_graph_free_names(
				lowerer,
				node.inputs[node.names.len],
				bindings,
				free_names,
				depth + 1
			);
			bindings.pop(node.names.len);
			return join_ok;
		case DELTA_HANDLER:
			if (!node.inputs.len
				|| node.descriptor >= lowerer.source.effects.handlers.len)
			{
				lowerer.fail("MIR closure capture analysis found invalid handler metadata");
				return false;
			}
			if (!collect_graph_free_names(
				lowerer, node.inputs[0], bindings, free_names, depth + 1
			)) return false;
			mitos::DeltaHandlerDescriptor* handler =
				&lowerer.source.effects.handlers[node.descriptor];
			foreach (&clause : handler.clauses)
			{
				foreach (name : clause.parameters) bindings.push(name);
				bool clause_ok = collect_graph_free_names(
					lowerer, clause.body, bindings, free_names, depth + 1
				);
				bindings.pop(clause.parameters.len);
				if (!clause_ok) return false;
			}
			bindings.push(handler.return_parameter);
			bool return_ok = collect_graph_free_names(
				lowerer, handler.return_body, bindings, free_names, depth + 1
			);
			bindings.pop(1);
			return return_ok;
		default:
			foreach (input : node.inputs)
			{
				if (!collect_graph_free_names(
					lowerer, input, bindings, free_names, depth + 1
				)) return false;
			}
			foreach (&branch : node.branches)
			{
				foreach (name : branch.bindings) bindings.push(name);
				bool branch_ok = collect_graph_free_names(
					lowerer, branch.body, bindings, free_names, depth + 1
				);
				bindings.pop(branch.bindings.len);
				if (!branch_ok) return false;
			}
			return true;
	}
}

fn MirScope* snapshot_scope(
	DeltaMirLowerer* lowerer,
	MirScope* scope,
	mitos::DeltaNodeId root,
	String[] parameter_names
)
{
	GraphBindings bindings;
	bindings.init(lowerer.allocator);
	defer bindings.deinit();
	foreach (name : parameter_names) bindings.push(name);
	OrderedGraphNames free_names;
	free_names.init(lowerer.allocator);
	defer free_names.deinit();
	if (!collect_graph_free_names(lowerer, root, &bindings, &free_names, 0))
	{
		return null;
	}
	LoweredValue[] captured_values = alloc::new_array(
		lowerer.allocator, LoweredValue, (sz)free_names.order.size
	);
	defer alloc::free(lowerer.allocator, captured_values);
	if (!resolve_graph_captures(lowerer, scope, &free_names, captured_values))
	{
		lowerer.fail("MIR closure capture references an absent lexical binding");
		return null;
	}
	List{String} names; names.init(lowerer.allocator); defer names.free();
	List{mitos::TypeId} types; types.init(lowerer.allocator); defer types.free();
	List{uint} registers; registers.init(lowerer.allocator); defer registers.free();
	List{mitos::DeltaNodeId} closure_nodes;
	closure_nodes.init(lowerer.allocator);
	defer closure_nodes.free();
	List{MirScope*} closure_environments;
	List{LoweredValue[]} fields;
	fields.init(lowerer.allocator);
	defer fields.free();
	List{LoweredValue} values;
	values.init(lowerer.allocator);
	defer values.free();
	closure_environments.init(lowerer.allocator);
	defer closure_environments.free();
	foreach (index, name : free_names.order)
	{
		LoweredValue value = captured_values[index];
		names.push(name);
		types.push(value.type_id);
		registers.push(value.register);
		closure_nodes.push(value.closure_node);
		closure_environments.push(value.closure_environment);
		fields.push(value.fields);
		values.push(value);
	}
	MirScope* snapshot = alloc::new(lowerer.allocator, MirScope, {
		.names = names.to_array(lowerer.allocator),
		.types = types.to_array(lowerer.allocator),
		.registers = registers.to_array(lowerer.allocator),
		.fields = fields.to_array(lowerer.allocator),
		.closure_nodes = closure_nodes.to_array(lowerer.allocator),
		.closure_environments = closure_environments.to_array(lowerer.allocator),
		.values = values.to_array(lowerer.allocator),
	});
	lowerer.provenance_scopes.push(snapshot);
	return snapshot;
}

fn uint constructor_index(usz delta_index) => (uint)delta_index + 3;

fn mitos_mir::MirOpcode primitive_opcode(DeltaMirLowerer* lowerer, mitos::DeltaPrimitiveOp operation)
{
	switch (operation)
	{
		case DELTA_PRIMITIVE_ADD: return ADD;
		case DELTA_PRIMITIVE_SUBTRACT: return SUBTRACT;
		case DELTA_PRIMITIVE_MULTIPLY: return MULTIPLY;
		case DELTA_PRIMITIVE_DIVIDE: return DIVIDE;
		case DELTA_PRIMITIVE_REMAINDER: return REMAINDER;
		case DELTA_PRIMITIVE_EQUAL: return EQUAL;
		case DELTA_PRIMITIVE_LESS: return LESS;
		case DELTA_PRIMITIVE_LESS_EQUAL: return LESS_EQUAL;
		case DELTA_PRIMITIVE_GREATER: return GREATER;
		case DELTA_PRIMITIVE_GREATER_EQUAL: return GREATER_EQUAL;
		default:
			lowerer.fail("MIR JIT encountered an unknown Delta primitive descriptor");
			return CONST;
	}
}
fn bool superposition_element_type(
	DeltaMirLowerer* lowerer,
	mitos::TypeId type_id,
	mitos::TypeId* element
)
{
	mitos::TypeDescriptor* descriptor = mitos::type_descriptor(&lowerer.source.types, type_id);
	if (!descriptor || descriptor.constructor != mitos::TYPE_ID_SUPERPOSITION
		|| descriptor.arguments.len != 1) return false;
	if (element) *element = descriptor.arguments[0];
	return true;
}

fn mitos::TypeId branch_runtime_type(
	DeltaMirLowerer* lowerer,
	mitos::TypeId type_id,
	bool* lifted = null
)
{
	mitos::TypeId element;
	if (superposition_element_type(lowerer, type_id, &element))
	{
		if (lifted) *lifted = true;
		return element;
	}
	if (lifted) *lifted = false;
	return type_id;
}

fn bool type_is_abstract(DeltaMirLowerer* lowerer, mitos::TypeId type_id)
{
	mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
		&lowerer.source.types, type_id
	);
	return descriptor && descriptor.kind
		== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_ABSTRACT;
}

fn mitos::TypeId intern_superposition_type(
	DeltaMirLowerer* lowerer,
	mitos::TypeId element
)
{
	if (!mitos::type_id_is_valid(&lowerer.source.types, element)
		|| element == mitos::TYPE_ID_INVALID)
	{
		return mitos::TYPE_ID_ANY;
	}
	mitos::TypeId[1] arguments = { element };
	mitos::TypeId result;
	mitos::MitosDiagnostic diagnostic;
	if (!mitos::intern_type(
		&lowerer.source.types,
		mitos::TYPE_ID_SUPERPOSITION,
		arguments[..],
		&result,
		&diagnostic
	))
	{
		lowerer.fail(diagnostic.message);
		diagnostic.deinit();
		return mitos::TYPE_ID_INVALID;
	}
	return result;
}
fn mitos::TypeId static_lambda_result_type(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNode* lambda,
	mitos::TypeId fallback
)
{
	if (!lambda || lambda.inputs.len != 1) return fallback;
	mitos::DeltaNode* body = mitos::delta_node(lowerer.source, lambda.inputs[0]);
	if (!body) return fallback;
	if (body.kind == mitos::DeltaNodeKind.DELTA_TYPE_OF && body.inputs.len == 1)
	{
		mitos::DeltaNode* inspected = mitos::delta_node(lowerer.source, body.inputs[0]);
		if (inspected && inspected.kind == mitos::DeltaNodeKind.DELTA_LOCAL)
		{
			foreach (index, parameter : lambda.names)
			{
				if (parameter != inspected.name) continue;
				mitos::TypeId reflected;
				mitos::MitosDiagnostic diagnostic;
				if (!mitos::intern_type_value_type(
					&lowerer.source.types,
					lambda.types[index],
					&reflected,
					&diagnostic
				))
				{
					lowerer.fail(diagnostic.message);
					diagnostic.deinit();
					return mitos::TYPE_ID_INVALID;
				}
				return reflected;
			}
		}
	}
	if (mitos::type_id_is_valid(&lowerer.source.types, body.runtime_type)
		&& body.runtime_type != mitos::TYPE_ID_ANY) return body.runtime_type;
	return fallback;
}

fn LoweredValue assert_runtime_type(
	DeltaMirLowerer* lowerer,
	LoweredValue value,
	mitos::TypeId expected,
	uint source_span,
	uint depth
)
{
	if (lowerer.failed || value.pending_effect || expected == mitos::TYPE_ID_ANY)
	{
		return value;
	}
	if (!mitos::type_id_is_valid(&lowerer.source.types, expected))
	{
		lowerer.fail("MIR runtime assertion references an invalid TypeId");
		return { };
	}
	value = materialize_runtime_value(lowerer, value, depth + 1);
	if (lowerer.failed || value.pending_effect) return value;
	uint checked = new_register(lowerer);
	emit(lowerer, {
		.opcode = TYPE_ASSERT,
		.destination = checked,
		.a = value.register,
		.b = (uint)expected,
		.operand_start = source_span,
	});
	value.register = checked;
	if (!mitos::type_is_subtype(&lowerer.source.types, value.type_id, expected))
	{
		value.type_id = expected;
	}
	return value;
}

fn mitos::TypeId intern_array_type(
	DeltaMirLowerer* lowerer,
	mitos::TypeId element
)
{
	if (!mitos::type_id_is_valid(&lowerer.source.types, element)
		|| element == mitos::TYPE_ID_INVALID)
	{
		return mitos::TYPE_ID_ANY;
	}
	mitos::TypeId[1] arguments = { element };
	mitos::TypeId result;
	mitos::MitosDiagnostic diagnostic;
	if (!mitos::intern_type(
		&lowerer.source.types,
		mitos::TYPE_ID_ARRAY,
		arguments[..],
		&result,
		&diagnostic
	))
	{
		lowerer.fail(diagnostic.message);
		diagnostic.deinit();
		return mitos::TYPE_ID_INVALID;
	}
	return result;
}



fn mitos::DeltaMethodRoot* method_root(
	DeltaMirLowerer* lowerer,
	usz function_index,
	mitos::SymbolKey* method_key
)
{
	if (function_index >= lowerer.source.method_roots.len) return null;
	mitos::DeltaMethodRoot* root = &lowerer.source.method_roots[function_index];
	return mitos::symbol_key_equal(&root.key, method_key) ? root : null;
}

fn ulong instance_hash(usz generic_index, usz method_index, mitos::TypeId[] types)
{
	ulong hash = 1469598103934665603UL;
	hash = (hash ^ (ulong)generic_index) * 1099511628211UL;
	hash = (hash ^ (ulong)method_index) * 1099511628211UL;
	foreach (type_id : types)
	{
		hash = (hash ^ (ulong)type_id) * 1099511628211UL;
	}
	return hash ? hash : 1;
}

fn bool instance_key_equal(
	MirMethodInstance* instance,
	usz generic_index,
	usz method_index,
	mitos::TypeId[] concrete_types
)
{
	if (instance.generic_index != generic_index
		|| instance.method_index != method_index
		|| instance.concrete_types.len != concrete_types.len) return false;
	foreach (index, type_id : concrete_types)
	{
		if (instance.concrete_types[index] != type_id) return false;
	}
	return true;
}

fn MirMethodActivation* active_method_instance(
	DeltaMirLowerer* lowerer,
	usz generic_index,
	usz method_index,
	mitos::TypeId[] concrete_types
)
{
	for (MirMethodActivation* activation = lowerer.method_activation;
		activation; activation = activation.parent)
	{
		if (activation.generic_index != generic_index
			|| activation.method_index != method_index
			|| activation.concrete_types.len != concrete_types.len) continue;
		bool equal = true;
		foreach (index, type_id : concrete_types)
		{
			if (activation.concrete_types[index] == type_id) continue;
			equal = false;
			break;
		}
		if (equal) return activation;
	}
	return null;
}

fn bool grow_instance_index(DeltaMirLowerer* lowerer)
{
	usz new_count = lowerer.instance_slot_count
		? lowerer.instance_slot_count * 2 : 16;
	if (new_count < lowerer.instance_slot_count
		|| new_count > (usz)JIT_MAX_INSTRUCTIONS * 2)
	{
		lowerer.fail("MIR method-instance index exceeds the production limit");
		return false;
	}
	uint[] slots = alloc::new_array(lowerer.allocator, uint, (sz)new_count);
	foreach (slot_index : lowerer.instance_slots)
	{
		if (!slot_index) continue;
		MirMethodInstance* instance = &lowerer.instances[(sz)slot_index - 1];
		ulong hash = instance_hash(
			instance.generic_index, instance.method_index, instance.concrete_types
		);
		usz slot = (usz)hash & (new_count - 1);
		while (slots[slot]) slot = (slot + 1) & (new_count - 1);
		slots[slot] = slot_index;
	}
	alloc::free(lowerer.allocator, lowerer.instance_slots);
	lowerer.instance_slots = slots;
	lowerer.instance_slot_count = new_count;
	return true;
}

fn uint reserve_method_instance(
	DeltaMirLowerer* lowerer,
	usz generic_index,
	usz method_index,
	mitos::DeltaMethodRoot* root,
	mitos::TypeId[] concrete_types,
	String[] type_variables,
	mitos::TypeId[] type_bindings
)
{
	if (!root)
	{
		lowerer.fail("MIR JIT selected method has no Delta method root");
		return 0;
	}
	if (!lowerer.instance_slot_count
		|| (usz)lowerer.instances.size * 2 >= lowerer.instance_slot_count)
	{
		if (!grow_instance_index(lowerer)) return 0;
	}
	ulong hash = instance_hash(generic_index, method_index, concrete_types);
	usz slot = (usz)hash & (lowerer.instance_slot_count - 1);
	while (lowerer.instance_slots[slot])
	{
		MirMethodInstance* instance =
			&lowerer.instances[(sz)lowerer.instance_slots[slot] - 1];
		if (instance_key_equal(
			instance, generic_index, method_index, concrete_types
		)) return instance.function_index;
		slot = (slot + 1) & (lowerer.instance_slot_count - 1);
	}
	if (lowerer.functions.size >= (sz)JIT_MAX_INSTRUCTIONS)
	{
		lowerer.fail("MIR method-instance table exceeds the production limit");
		return 0;
	}
	uint function_index = (uint)lowerer.functions.size;
	lowerer.functions.push({ });
	lowerer.instances.push({
		.root = root.root,
		.parameters = root.parameters,
		.generic_index = generic_index,
		.method_index = method_index,
		.concrete_types = alloc::clone_slice(lowerer.allocator, concrete_types),
		.type_variables = type_variables,
		.type_bindings = alloc::clone_slice(lowerer.allocator, type_bindings),
		.function_index = function_index,
		.result_type = mitos::TYPE_ID_ANY,
		.source_order = root.source_order,
	});
	lowerer.instance_slots[slot] = (uint)lowerer.instances.size;
	return function_index;
}

fn bool delta_graph_has_effect(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNodeId node_id,
	uint depth
)
{
	if (depth >= JIT_MAX_DEPTH || !node_id
		|| (usz)node_id > lowerer.effect_scan.len) return true;
	char* state = &lowerer.effect_scan[(sz)node_id - 1];
	if (*state == 3) return true;
	if (*state == 2 || *state == 1) return false;
	*state = 1;
	mitos::DeltaNode* node = mitos::delta_node(lowerer.source, node_id);
	bool found = !node || node.kind == mitos::DeltaNodeKind.DELTA_EFFECT
		|| node.effect_row.required.len || node.effect_row.has_tail;
	if (node && !found
		&& node.kind == mitos::DeltaNodeKind.DELTA_GENERIC_CALL)
	{
		if (node.descriptor >= (usz)lowerer.source.methods.generics.len())
		{
			found = true;
		}
		else
		{
			mitos::GenericFunction* generic =
				&lowerer.source.methods.generics[(sz)node.descriptor];
			foreach (&method : generic.methods)
			{
				if (method.function_index >= lowerer.source.method_roots.len)
				{
					found = true;
					break;
				}
				mitos::DeltaMethodRoot* root =
					&lowerer.source.method_roots[method.function_index];
				if (root.function_index != method.function_index
					|| root.generic_index != node.descriptor
					|| root.effect_row.required.len || root.effect_row.has_tail
					|| delta_graph_has_effect(lowerer, root.root, depth + 1))
				{
					found = true;
					break;
				}
			}
		}
	}
	if (node && !found) foreach (input : node.inputs)
	{
		if (delta_graph_has_effect(lowerer, input, depth + 1))
		{
			found = true;
			break;
		}
	}
	if (node && !found) foreach (&branch : node.branches)
	{
		if (delta_graph_has_effect(lowerer, branch.body, depth + 1))
		{
			found = true;
			break;
		}
	}
	*state = found ? 3 : 2;
	return found;
}

fn bool delta_graph_has_effectful_lambda(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNodeId node_id,
	uint depth
)
{
	if (depth >= JIT_MAX_DEPTH || !node_id
		|| (usz)node_id > lowerer.effectful_lambda_scan.len) return true;
	char* state = &lowerer.effectful_lambda_scan[(sz)node_id - 1];
	if (*state == 3) return true;
	if (*state == 2 || *state == 1) return false;
	*state = 1;
	mitos::DeltaNode* node = mitos::delta_node(lowerer.source, node_id);
	bool found = !node || (node.kind == mitos::DeltaNodeKind.DELTA_LAMBDA
		&& (node.effect_row.required.len || node.effect_row.has_tail));
	if (node && !found) foreach (input : node.inputs)
	{
		if (delta_graph_has_effectful_lambda(lowerer, input, depth + 1))
		{
			found = true;
			break;
		}
	}
	if (node && !found) foreach (&branch : node.branches)
	{
		if (delta_graph_has_effectful_lambda(lowerer, branch.body, depth + 1))
		{
			found = true;
			break;
		}
	}
	*state = found ? 3 : 2;
	return found;
}

fn bool type_may_contain_closure(
	DeltaMirLowerer* lowerer,
	mitos::TypeId type_id,
	uint depth
)
{
	if (depth >= JIT_MAX_DEPTH || type_id == mitos::TYPE_ID_ANY
		|| !type_id || (usz)type_id > lowerer.closure_type_scan.len) return true;
	char* state = &lowerer.closure_type_scan[(sz)type_id - 1];
	if (*state == 3) return true;
	if (*state == 2 || *state == 1) return false;
	*state = 1;
	mitos::TypeDescriptor* descriptor =
		mitos::type_descriptor(&lowerer.source.types, type_id);
	bool found = !descriptor || (descriptor.kind
		== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE);
	if (descriptor && !found) foreach (argument : descriptor.arguments)
	{
		if (type_may_contain_closure(lowerer, argument, depth + 1))
		{
			found = true;
			break;
		}
	}
	if (descriptor && !found) foreach (&constructor : lowerer.source.constructors)
	{
		if (constructor.runtime_type != type_id
			&& constructor.type_constructor != descriptor.constructor) continue;
		foreach (field_type : constructor.field_types)
		{
			if (type_may_contain_closure(
				lowerer, field_type, depth + 1
			))
			{
				found = true;
				break;
			}
		}
		if (found) break;
	}
	*state = found ? 3 : 2;
	return found;
}

fn bool value_is_closure_sensitive(LoweredValue value, uint depth)
{
	if (depth >= JIT_MAX_DEPTH || value.provenance_only || value.closure_node)
	{
		return true;
	}
	foreach (field : value.fields)
	{
		if (value_is_closure_sensitive(field, depth + 1)) return true;
	}
	foreach (alternative : value.alternatives)
	{
		if (value_is_closure_sensitive(alternative, depth + 1)) return true;
	}
	return false;
}

fn bool captured_value_has_effectful_closure(
	DeltaMirLowerer* lowerer,
	LoweredValue value,
	uint depth
)
{
	if (depth >= JIT_MAX_DEPTH || value.pending_effect) return true;
	if (value.closure_node
		&& delta_graph_has_effect(lowerer, value.closure_node, depth + 1))
	{
		return true;
	}
	mitos::TypeDescriptor* descriptor =
		mitos::type_descriptor(&lowerer.source.types, value.type_id);
	if (descriptor
		&& descriptor.kind
			== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
		&& (descriptor.function_effects.required.len
			|| descriptor.function_effects.has_tail))
	{
		return true;
	}
	foreach (field : value.fields)
	{
		if (captured_value_has_effectful_closure(lowerer, field, depth + 1))
		{
			return true;
		}
	}
	foreach (alternative : value.alternatives)
	{
		if (captured_value_has_effectful_closure(
			lowerer, alternative, depth + 1
		))
		{
			return true;
		}
	}
	return false;
}

fn LazyMaterialization* new_lazy_materialization(DeltaMirLowerer* lowerer)
{
	LazyMaterialization* lazy = alloc::new(
		lowerer.allocator, LazyMaterialization, { }
	);
	lowerer.lazy_materializations.push(lazy);
	return lazy;
}
fn void enter_materialization_scope(DeltaMirLowerer* lowerer)
{
	lowerer.next_materialization_scope_id += 1;
	lowerer.materialization_path.push(lowerer.next_materialization_scope_id);
}

fn void leave_materialization_scope(DeltaMirLowerer* lowerer)
{
	(void)lowerer.materialization_path.pop()!!;
}

fn void reset_materialization_scope(DeltaMirLowerer* lowerer)
{
	lowerer.materialization_path.clear();
	enter_materialization_scope(lowerer);
}

fn bool materialization_scope_dominates(
	DeltaMirLowerer* lowerer,
	ulong definition_id,
	usz definition_depth
)
{
	return definition_id
		&& definition_depth < (usz)lowerer.materialization_path.size
		&& lowerer.materialization_path[(sz)definition_depth] == definition_id;
}


fn LoweredValue materialize_runtime_value(
	DeltaMirLowerer* lowerer,
	LoweredValue value,
	uint depth
)
{
	if (lowerer.failed || value.pending_effect || !value.provenance_only) return value;
	if (depth >= JIT_MAX_DEPTH || !value.lazy)
	{
		lowerer.fail("MIR lazy value has invalid or recursive provenance");
		return { };
	}
	if (materialization_scope_dominates(
		lowerer, value.lazy.scope_id, value.lazy.scope_depth
	))
	{
		value.register = value.lazy.register;
		value.type_id = value.lazy.type_id;
		value.provenance_only = false;
		return value;
	}
	if (value.lazy.materializing)
	{
		lowerer.fail("MIR lazy closure capture is recursively materialized");
		return { };
	}
	value.lazy.materializing = true;
	if (value.closure_node)
	{
		mitos::DeltaNode* lambda = mitos::delta_node(
			lowerer.source, value.closure_node
		);
		if (!lambda || lambda.kind != mitos::DeltaNodeKind.DELTA_LAMBDA
			|| !value.closure_environment)
		{
			lowerer.fail("MIR lazy closure provenance is invalid");
			return { };
		}
		uint[] captures;
		mitos::TypeId[] capture_types;
		uint target = reserve_closure_instance(
			lowerer, lambda, value.closure_environment, &captures, &capture_types
		);
		if (lowerer.failed)
		{
			alloc::free(lowerer.allocator, captures);
			alloc::free(lowerer.allocator, capture_types);
			return { };
		}
		bool lifted = false;
		foreach (capture_type : capture_types)
		{
			if (superposition_element_type(lowerer, capture_type, null))
			{
				lifted = true;
				break;
			}
		}
		mitos::TypeId closure_type = lifted
			? intern_superposition_type(lowerer, lambda.runtime_type)
			: lambda.runtime_type;
		uint closure = new_register(lowerer);
		emit(lowerer, {
			.opcode = lifted ? LIFT_MAKE_FUNCTION : MAKE_FUNCTION,
			.destination = closure,
			.a = target,
			.b = (uint)lambda.runtime_type,
			.operand_start = append_operands(lowerer, captures),
			.operand_count = (uint)captures.len,
			.immediate = (long)lambda.names.len,
		});
		alloc::free(lowerer.allocator, captures);
		alloc::free(lowerer.allocator, capture_types);
		value.register = closure;
		value.type_id = closure_type;
	}
	else if (value.constructor_node)
	{
		mitos::DeltaNode* constructor_node = mitos::delta_node(
			lowerer.source, value.constructor_node
		);
		if (!constructor_node
			|| constructor_node.kind != mitos::DeltaNodeKind.DELTA_CONSTRUCTOR
			|| constructor_node.descriptor >= lowerer.source.constructors.len
			|| constructor_node.inputs.len != value.fields.len)
		{
			lowerer.fail("MIR lazy constructor provenance is invalid");
			return { };
		}
		uint[] fields = alloc::new_array(
			lowerer.allocator, uint, (sz)value.fields.len
		);
		defer alloc::free(lowerer.allocator, fields);
		bool lifted = false;
		foreach (index, field : value.fields)
		{
			field = materialize_runtime_value(lowerer, field, depth + 1);
			if (lowerer.failed || field.pending_effect) return { };
			value.fields[index] = field;
			fields[index] = field.register;
			lifted = lifted || superposition_element_type(
				lowerer, field.type_id, null
			);
		}
		mitos::TypeId constructed_type = branch_runtime_type(
			lowerer, value.type_id
		);
		uint constructed = new_register(lowerer);
		emit(lowerer, {
			.opcode = lifted ? LIFT_CONSTRUCTOR : MAKE_CONSTRUCTOR,
			.destination = constructed,
			.a = constructor_index(constructor_node.descriptor),
			.b = (uint)constructed_type,
			.operand_start = append_operands(lowerer, fields),
			.operand_count = (uint)fields.len,
		});
		value.register = constructed;
	}
	else if (value.alternatives.len)
	{
		mitos::DeltaNode* source = mitos::delta_node(
			lowerer.source, value.alternatives_node
		);
		if (!source)
		{
			lowerer.fail("MIR lazy alternatives provenance is invalid");
			return { };
		}
		if (source.kind == mitos::DeltaNodeKind.DELTA_MATCH)
		{
			if (source.branches.len != value.alternatives.len)
			{
				lowerer.fail("MIR lazy match provenance has inconsistent branches");
				return { };
			}
			uint matched = new_register(lowerer);
			emit(lowerer, { .opcode = CONST, .destination = matched });
			bool exhaustive = false;
			uint join = new_label(lowerer);
			foreach (branch_index, &branch : source.branches)
			{
				(void)branch_index;
				uint next = 0;
				if (!branch.wildcard)
				{
					if (branch.constructor >= lowerer.source.constructors.len)
					{
						lowerer.fail("MIR lazy match references an invalid constructor");
						return { };
					}
					next = new_label(lowerer);
					uint condition = new_register(lowerer);
					emit(lowerer, {
						.opcode = TAG_EQUAL,
						.destination = condition,
						.a = value.alternative_scrutinee,
						.b = constructor_index(branch.constructor),
					});
					emit(lowerer, {
						.opcode = BRANCH_FALSE, .a = condition, .b = next,
					});
				}
				enter_materialization_scope(lowerer);
				LoweredValue alternative = materialize_runtime_value(
					lowerer, value.alternatives[branch_index], depth + 1
				);
				leave_materialization_scope(lowerer);
				if (lowerer.failed || alternative.pending_effect) return { };
				value.alternatives[branch_index] = alternative;
				emit(lowerer, {
					.opcode = MOVE,
					.destination = matched,
					.a = alternative.register,
				});
				emit(lowerer, { .opcode = JUMP, .a = join });
				if (!branch.wildcard) emit(lowerer, {
					.opcode = LABEL, .a = next,
				});
				if (branch.wildcard)
				{
					exhaustive = true;
					break;
				}
			}
			if (!exhaustive)
			{
				uint zero = new_register(lowerer);
				emit(lowerer, { .opcode = CONST, .destination = zero });
				uint trap = new_register(lowerer);
				emit(lowerer, {
					.opcode = DIVIDE, .destination = trap, .a = zero, .b = zero,
				});
				emit(lowerer, {
					.opcode = MOVE, .destination = matched, .a = trap,
				});
			}
			emit(lowerer, { .opcode = LABEL, .a = join });
			value.register = matched;
		}
		else if (source.kind == mitos::DeltaNodeKind.DELTA_SUPERPOSE
			&& source.inputs.len == value.alternatives.len)
		{
			uint[] alternatives = alloc::new_array(
				lowerer.allocator, uint, (sz)value.alternatives.len
			);
			defer alloc::free(lowerer.allocator, alternatives);
			foreach (index, alternative : value.alternatives)
			{
				alternative = materialize_runtime_value(
					lowerer, alternative, depth + 1
				);
				if (lowerer.failed || alternative.pending_effect) return { };
				value.alternatives[index] = alternative;
				alternatives[index] = alternative.register;
			}
			uint superposition = new_register(lowerer);
			emit(lowerer, {
				.opcode = SUPERPOSE,
				.destination = superposition,
				.b = (uint)value.type_id,
				.operand_start = append_operands(lowerer, alternatives),
				.operand_count = (uint)alternatives.len,
				.immediate = (long)source.descriptor,
			});
			value.register = superposition;
		}
		else
		{
			lowerer.fail("MIR lazy alternatives provenance has an unsupported source");
			return { };
		}
	}
	else
	{
		lowerer.fail("MIR lazy value has no materializable provenance");
		return { };
	}
	if (lowerer.failed) return { };
	if (!lowerer.materialization_path.size)
	{
		lowerer.fail("MIR lazy value has no active materialization scope");
		return { };
	}
	value.provenance_only = false;
	value.lazy.scope_id = lowerer.materialization_path[
		lowerer.materialization_path.size - 1
	];
	value.lazy.scope_depth = (usz)lowerer.materialization_path.size - 1;
	value.lazy.materializing = false;
	value.lazy.register = value.register;
	value.lazy.type_id = value.type_id;
	return value;
}


fn uint reserve_parallel_instance(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNodeId root,
	usz source_order,
	MirScope* scope,
	uint[]* captured_registers,
	mitos::TypeId[]* captured_types,
	bool* requires_inline
)
{
	*captured_registers = { };
	*captured_types = { };
	*requires_inline = false;
	GraphBindings bindings;
	bindings.init(lowerer.allocator);
	defer bindings.deinit();
	OrderedGraphNames free_names;
	free_names.init(lowerer.allocator);
	defer free_names.deinit();
	if (!collect_graph_free_names(lowerer, root, &bindings, &free_names, 0))
	{
		return 0;
	}
	LoweredValue[] captured_values = alloc::new_array(
		lowerer.allocator, LoweredValue, (sz)free_names.order.size
	);
	defer alloc::free(lowerer.allocator, captured_values);
	if (!resolve_graph_captures(lowerer, scope, &free_names, captured_values))
	{
		lowerer.fail("MIR parallel thunk references an absent lexical binding");
		return 0;
	}
	foreach (index, name : free_names.order)
	{
		(void)name;
		LoweredValue captured = captured_values[index];
		if (captured_value_has_effectful_closure(lowerer, captured, 0))
		{
			*requires_inline = true;
			return 0;
		}
	}
	List{String} names; names.init(lowerer.allocator); defer names.free();
	List{mitos::TypeId} types; types.init(lowerer.allocator); defer types.free();
	List{uint} registers; registers.init(lowerer.allocator); defer registers.free();
	foreach (index, name : free_names.order)
	{
		LoweredValue captured = captured_values[index];
		captured = materialize_runtime_value(lowerer, captured, 0);
		if (lowerer.failed) return 0;
		names.push(name);
		types.push(captured.type_id);
		registers.push(captured.register);
	}
	if (lowerer.functions.size >= (sz)JIT_MAX_INSTRUCTIONS)
	{
		lowerer.fail("MIR parallel thunk table exceeds the production limit");
		return 0;
	}
	uint function_index = (uint)lowerer.functions.size;
	lowerer.functions.push({ });
	lowerer.instances.push({
		.method_index = usz::max,
		.root = root,
		.parameters = names.to_array(lowerer.allocator),
		.concrete_types = types.to_array(lowerer.allocator),
		.function_index = function_index,
		.result_type = mitos::TYPE_ID_ANY,
		.source_order = source_order,
		.parallel_source = true,
	});
	*captured_registers = registers.to_array(lowerer.allocator);
	*captured_types = types.to_array(lowerer.allocator);
	return function_index;
}

fn uint reserve_graph_closure_instance(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNodeId root,
	String[] parameter_names,
	mitos::TypeId[] parameter_types,
	mitos::TypeId result_type,
	MirScope* scope,
	uint[]* captured_registers,
	mitos::TypeId[]* captured_types
)
{
	GraphBindings bindings;
	bindings.init(lowerer.allocator);
	defer bindings.deinit();
	OrderedGraphNames free_names;
	free_names.init(lowerer.allocator);
	defer free_names.deinit();
	List{String} names; names.init(lowerer.allocator); defer names.free();
	List{mitos::TypeId} types; types.init(lowerer.allocator); defer types.free();
	List{uint} captures; captures.init(lowerer.allocator); defer captures.free();
	List{mitos::TypeId} capture_types; capture_types.init(lowerer.allocator); defer capture_types.free();
	foreach (index, name : parameter_names)
	{
		bindings.push(name);
		names.push(name);
		types.push(parameter_types[index]);
	}
	if (!collect_graph_free_names(lowerer, root, &bindings, &free_names, 0))
	{
		return 0;
	}
	LoweredValue[] captured_values = alloc::new_array(
		lowerer.allocator, LoweredValue, (sz)free_names.order.size
	);
	defer alloc::free(lowerer.allocator, captured_values);
	if (!resolve_graph_captures(lowerer, scope, &free_names, captured_values))
	{
		lowerer.fail("MIR closure instance references an absent lexical binding");
		return 0;
	}
	foreach (index, name : free_names.order)
	{
		LoweredValue captured = captured_values[index];
		captured = materialize_runtime_value(lowerer, captured, 0);
		if (lowerer.failed) return 0;
		names.push(name);
		types.push(captured.type_id);
		captures.push(captured.register);
		capture_types.push(captured.type_id);
	}
	if (lowerer.functions.size >= (sz)JIT_MAX_INSTRUCTIONS)
	{
		lowerer.fail("MIR closure-instance table exceeds the production limit");
		return 0;
	}
	uint function_index = (uint)lowerer.functions.size;
	lowerer.functions.push({ });
	lowerer.instances.push({
		.method_index = usz::max,
		.root = root,
		.parameters = names.to_array(lowerer.allocator),
		.concrete_types = types.to_array(lowerer.allocator),
		.function_index = function_index,
		.result_type = result_type,
		.source_order = lowerer.current_source_order,
		.parallel_source = lowerer.current_parallel_source,
	});
	*captured_registers = captures.to_array(lowerer.allocator);
	*captured_types = capture_types.to_array(lowerer.allocator);
	return function_index;
}

fn uint reserve_closure_instance(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNode* lambda,
	MirScope* scope,
	uint[]* captured_registers,
	mitos::TypeId[]* captured_types
)
{
	return reserve_graph_closure_instance(
		lowerer,
		lambda.inputs[0],
		lambda.names,
		lambda.types,
		lambda.result_type ? lambda.result_type : mitos::TYPE_ID_ANY,
		scope,
		captured_registers,
		captured_types
	);
}


fn bool resolve_concrete_type_bindings(
	DeltaMirLowerer* lowerer,
	mitos::MethodDescriptor* method,
	mitos::TypeBinding[] dispatch_bindings,
	mitos::TypeId[] concrete_bindings
)
{
	foreach (index, variable : method.type_variables)
	{
		bool found = false;
		foreach (&binding : dispatch_bindings)
		{
			if (binding.variable != variable) continue;
			concrete_bindings[index] = binding.type_id;
			found = true;
			break;
		}
		if (found) continue;
		lowerer.fail("MIR JIT selected method has an unresolved type variable");
		return false;
	}
	return true;
}

fn bool materialize_type_binding_locals(
	DeltaMirLowerer* lowerer,
	mitos::TypeId[] concrete_bindings,
	uint[] registers,
	mitos::TypeId[] runtime_types
)
{
	foreach (index, represented : concrete_bindings)
	{
		if (!mitos::type_id_is_valid(&lowerer.source.types, represented))
		{
			lowerer.fail("MIR JIT selected method has an invalid concrete type binding");
			return false;
		}
		mitos::MitosDiagnostic diagnostic;
		if (!mitos::intern_type_value_type(
			&lowerer.source.types,
			represented,
			&runtime_types[index],
			&diagnostic
		))
		{
			lowerer.fail(diagnostic.message);
			diagnostic.deinit();
			return false;
		}
		registers[index] = new_register(lowerer);
		emit(lowerer, {
			.opcode = TYPE_VALUE,
			.destination = registers[index],
			.a = (uint)represented,
		});
		if (lowerer.failed) return false;
	}
	return true;
}


fn LoweredValue lower_generic_call(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNode* node,
	MirScope* scope,
	uint depth
)
{
	if (node.descriptor >= (usz)lowerer.source.methods.generics.len())
	{
		lowerer.fail("MIR JIT generic call references an invalid generic descriptor");
		return { };
	}
	usz arity = node.inputs.len;
	uint[] registers = alloc::new_array(lowerer.allocator, uint, (sz)arity);
	mitos::TypeId[] actual = alloc::new_array(lowerer.allocator, mitos::TypeId, (sz)arity);
	mitos::TypeId[] argument_types = alloc::new_array(lowerer.allocator, mitos::TypeId, (sz)arity);
	mitos::DeltaNodeId[] argument_closures = alloc::new_array(
		lowerer.allocator, mitos::DeltaNodeId, (sz)arity
	);
	MirScope*[] argument_closure_environments = alloc::new_array(
		lowerer.allocator, MirScope*, (sz)arity
	);
	LoweredValue[][] argument_fields = alloc::new_array(
		lowerer.allocator, LoweredValue[], (sz)arity
	);
	LoweredValue[] argument_values = alloc::new_array(
		lowerer.allocator, LoweredValue, (sz)arity
	);
	bool lifted = false;
	defer alloc::free(lowerer.allocator, registers);
	defer alloc::free(lowerer.allocator, actual);
	defer alloc::free(lowerer.allocator, argument_types);
	defer alloc::free(lowerer.allocator, argument_closures);
	defer alloc::free(lowerer.allocator, argument_closure_environments);
	defer alloc::free(lowerer.allocator, argument_fields);
	defer alloc::free(lowerer.allocator, argument_values);
	foreach (index, input : node.inputs)
	{
		LoweredValue argument = lower_node(lowerer, input, scope, depth + 1);
		if (lowerer.failed) return { };
		if (argument.pending_effect) return argument;
		registers[index] = argument.register;
		argument_types[index] = argument.type_id;
		argument_closures[index] = argument.closure_node;
		argument_closure_environments[index] = argument.closure_environment;
		argument_fields[index] = argument.fields;
		argument_values[index] = argument;
		bool argument_lifted;
		actual[index] = branch_runtime_type(lowerer, argument.type_id, &argument_lifted);
		lifted = lifted || argument_lifted;
	}
	foreach (type_id : actual)
	{
		if (type_id == mitos::TYPE_ID_ANY || type_id == mitos::TYPE_ID_INVALID
			|| (usz)type_id > (usz)lowerer.source.types.descriptors.len()
			|| lowerer.source.types.descriptors[(sz)type_id - 1].kind
				== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_ABSTRACT)
		{
			lowerer.fail("MIR dynamic dispatch requires a runtime TypeId tuple");
			return { };
		}
	}
	mitos::GenericFunction* generic =
		&lowerer.source.methods.generics[(sz)node.descriptor];
	if (!mitos::symbol_key_equal(&node.key, &generic.key))
	{
		lowerer.fail("MIR generic call key disagrees with its dense handle");
		return { };
	}
	mitos::MitosSpan span;
	if (node.span && node.span <= lowerer.source.spans.len) span = lowerer.source.spans[node.span - 1];
	mitos::DispatchResult dispatch = mitos::dispatch_method(
		&lowerer.source.methods,
		&lowerer.source.types,
		generic.name,
		actual,
		lowerer.allocator,
		span,
		&node.key
	);
	defer dispatch.deinit();
	if (!dispatch.matched)
	{
		lowerer.fail(dispatch.diagnostic.message);
		return { };
	}
	usz method_index = dispatch.method_index;
	mitos::MethodDescriptor* method = &generic.methods[(sz)method_index];
	mitos::TypeId[] concrete_bindings = alloc::new_array(
		lowerer.allocator, mitos::TypeId, (sz)method.type_variables.len
	);
	defer alloc::free(lowerer.allocator, concrete_bindings);
	if (!resolve_concrete_type_bindings(
		lowerer, method, dispatch.bindings, concrete_bindings
	)) return { };
	mitos::TypeId result_type = mitos::TYPE_ID_ANY;
	if (!mitos::resolve_method_result_type(
		&lowerer.source.types,
		method,
		dispatch.bindings,
		&result_type
	))
	{

		lowerer.fail("MIR JIT could not instantiate the selected method result type");
		return { };
	}
	mitos::TypeId lowered_result_type = lifted
		? intern_superposition_type(lowerer, result_type) : result_type;
	if (lowerer.failed) return { };
	mitos::DeltaMethodRoot* root = method_root(
		lowerer, method.function_index, &method.key
	);
	if (!root)
	{
		lowerer.fail("MIR JIT selected method has no Delta method root");
		return { };
	}
	bool closure_sensitive = type_may_contain_closure(
		lowerer, result_type, 0
	) || delta_graph_has_effectful_lambda(lowerer, root.root, 0);
	if (!closure_sensitive)
	{
		foreach (argument : argument_values)
		{
			if (value_is_closure_sensitive(argument, 0))
			{
				closure_sensitive = true;
				break;
			}
		}
	}
	bool effectful_root = root.effect_row.required.len || root.effect_row.has_tail;
	bool abstract_result = type_is_abstract(lowerer, result_type);
	uint reserved_target = 0;
	MirMethodActivation* reentry = !effectful_root
		? active_method_instance(
			lowerer, node.descriptor, method_index, actual
		) : null;
	if (reentry && !reentry.function_index)
	{
		reserved_target = reserve_method_instance(
			lowerer,
			node.descriptor,
			method_index,
			root,
			actual,
			method.type_variables,
			concrete_bindings
		);
		if (lowerer.failed) return { };
		reentry.function_index = reserved_target;
	}
	if ((effectful_root || closure_sensitive || abstract_result) && !reentry)
	{
		MirScope effect_scope = {
			.parent = scope,
			.names = root.parameters,
			.types = argument_types,
			.registers = registers,
			.closure_nodes = argument_closures,
			.closure_environments = argument_closure_environments,
			.fields = argument_fields,
			.values = argument_values,
		};
		uint[] type_registers = alloc::new_array(
			lowerer.allocator, uint, (sz)concrete_bindings.len
		);
		defer alloc::free(lowerer.allocator, type_registers);
		mitos::TypeId[] type_runtime_types = alloc::new_array(
			lowerer.allocator, mitos::TypeId, (sz)concrete_bindings.len
		);
		defer alloc::free(lowerer.allocator, type_runtime_types);
		if (!materialize_type_binding_locals(
			lowerer, concrete_bindings, type_registers, type_runtime_types
		)) return { };
		MirScope type_scope = {
			.parent = &effect_scope,
			.names = method.type_variables,
			.types = type_runtime_types,
			.registers = type_registers,
		};
		usz enclosing_source_order = lowerer.current_source_order;
		bool enclosing_parallel_source = lowerer.current_parallel_source;
		MirMethodActivation activation = {
			.parent = lowerer.method_activation,
			.generic_index = node.descriptor,
			.method_index = method_index,
			.concrete_types = actual,
			.function_index = reserved_target,
		};
		MirMethodActivation* enclosing_activation = lowerer.method_activation;
		if (!effectful_root) lowerer.method_activation = &activation;
		LoweredValue effectful = lower_node(
			lowerer, root.root, &type_scope, depth + 1
		);
		lowerer.method_activation = enclosing_activation;
		lowerer.current_source_order = enclosing_source_order;
		lowerer.current_parallel_source = enclosing_parallel_source;
		if (!effectful.pending_effect && !abstract_result
			&& lowered_result_type != mitos::TYPE_ID_ANY)
		{
			effectful.type_id = lowered_result_type;
		}
		return effectful;
	}
	foreach (index, argument : argument_values)
	{
		argument = materialize_runtime_value(lowerer, argument, depth + 1);
		if (lowerer.failed || argument.pending_effect) return { };
		argument_values[index] = argument;
		registers[index] = argument.register;
		argument_types[index] = argument.type_id;
		argument_closures[index] = argument.closure_node;
		argument_closure_environments[index] = argument.closure_environment;
		argument_fields[index] = argument.fields;
	}
	uint destination = new_register(lowerer);
	uint operand_start = append_operands(lowerer, registers);
	uint target = reentry ? reentry.function_index
		: reserved_target ? reserved_target
		: reserve_method_instance(
			lowerer,
			node.descriptor,
			method_index,
			root,
			actual,
			method.type_variables,
			concrete_bindings
		);
	if (lowerer.failed) return { };
	emit(lowerer, {
		.opcode = lifted ? LIFT_CALL : CALL,
		.destination = destination,
		.a = target,
		.b = lifted ? (uint)lowered_result_type : 0,
		.operand_start = operand_start,
		.operand_count = (uint)arity,
	});
	return { .register = destination, .type_id = lowered_result_type };
}

fn mitos::DeltaEffectDescriptor* lower_effect_descriptor(
	DeltaMirLowerer* lowerer,
	mitos::EffectId effect
)
{
	foreach (&descriptor : lowerer.source.effects.effects)
	{
		if (descriptor.id == effect) return descriptor;
	}
	return null;
}

fn LoweredValue lower_handler_return(
	DeltaMirLowerer* lowerer,
	MirHandlerActivation* activation,
	LoweredValue value,
	uint depth
)
{
	if (value.pending_effect || lowerer.failed) return value;
	mitos::DeltaHandlerDescriptor* handler = activation.handler;
	if (handler.return_type != mitos::TYPE_ID_ANY
		&& !mitos::type_is_subtype(&lowerer.source.types, value.type_id, handler.return_type))
	{
		lowerer.fail("TypeError: MIR handler return value failed its declared type");
		return { };
	}
	String[1] names = { handler.return_parameter };
	mitos::TypeId[1] types = { value.type_id };
	uint[1] registers = { value.register };
	mitos::DeltaNodeId[1] closure_nodes = { value.closure_node };
	MirScope*[1] closure_environments = { value.closure_environment };
	LoweredValue[][1] fields = { value.fields };
	LoweredValue[1] values = { value };
	MirScope return_scope = {
		.parent = activation.environment,
		.names = names[..],
		.types = types[..],
		.registers = registers[..],
		.closure_nodes = closure_nodes[..],
		.closure_environments = closure_environments[..],
		.fields = fields[..],
		.values = values[..],
	};
	return lower_node(lowerer, handler.return_body, &return_scope, depth + 1);
}

fn LoweredValue lower_handle_request(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNodeId handler_node_id,
	mitos::DeltaNode* handler_node,
	MirScope* environment,
	LoweredValue request,
	uint depth
)
{
	if (!request.pending_effect) return request;
	if (request.effect_epoch != lowerer.source.effects.epoch)
	{
		lowerer.fail("MIR JIT rejected a stale effect request epoch");
		return { };
	}
	if (handler_node.descriptor >= lowerer.source.effects.handlers.len
		|| request.effect_operation >= lowerer.source.effects.operations.len)
	{
		lowerer.fail("MIR JIT handler or effect request has invalid Delta metadata");
		return { };
	}
	mitos::DeltaHandlerDescriptor* handler =
		&lowerer.source.effects.handlers[handler_node.descriptor];
	mitos::DeltaOperationDescriptor* operation =
		&lowerer.source.effects.operations[request.effect_operation];
	mitos::DeltaHandlerClauseDescriptor* selected = null;
	bool handles_effect = false;
	foreach (&clause : handler.clauses)
	{
		if (clause.effect == operation.effect) handles_effect = true;
		if (clause.effect == operation.effect && clause.operation == operation.id)
		{
			selected = clause;
			break;
		}
	}
	if (!selected)
	{
		if (handles_effect)
		{
			lowerer.fail("MIR handler is missing a clause for the performed operation");
			return { };
		}
		return request;
	}
	if (selected.parameters.len != request.effect_arguments.len
		|| selected.parameter_types.len != selected.parameters.len)
	{
		lowerer.fail("MIR effect request arguments disagree with the handler clause");
		return { };
	}
	mitos::DeltaEffectDescriptor* effect = lower_effect_descriptor(lowerer, operation.effect);
	if (!effect || selected.multi != effect.multi)
	{
		lowerer.fail("MIR handler continuation mode disagrees with its effect epoch metadata");
		return { };
	}
	uint[] registers = alloc::new_array(lowerer.allocator, uint, (sz)selected.parameters.len);
	mitos::TypeId[] types = alloc::new_array(
		lowerer.allocator, mitos::TypeId, (sz)selected.parameters.len
	);
	mitos::DeltaNodeId[] closure_nodes = alloc::new_array(
		lowerer.allocator, mitos::DeltaNodeId, (sz)selected.parameters.len
	);
	MirScope*[] closure_environments = alloc::new_array(
		lowerer.allocator, MirScope*, (sz)selected.parameters.len
	);
	LoweredValue[][] fields = alloc::new_array(
		lowerer.allocator, LoweredValue[], (sz)selected.parameters.len
	);
	defer alloc::free(lowerer.allocator, registers);
	defer alloc::free(lowerer.allocator, types);
	defer alloc::free(lowerer.allocator, closure_nodes);
	defer alloc::free(lowerer.allocator, closure_environments);
	defer alloc::free(lowerer.allocator, fields);
	foreach (index, argument : request.effect_arguments)
	{
		mitos::TypeId expected = selected.parameter_types[index];
		if (expected != mitos::TYPE_ID_ANY
			&& !mitos::type_is_subtype(&lowerer.source.types, argument.type_id, expected))
		{
			lowerer.fail("TypeError: MIR effect argument failed its handler clause type");
			return { };
		}
		registers[index] = argument.register;
		types[index] = argument.type_id;
		closure_nodes[index] = argument.closure_node;
		closure_environments[index] = argument.closure_environment;
		fields[index] = argument.fields;
	}
	MirScope clause_scope = {
		.parent = environment,
		.names = selected.parameters,
		.types = types,
		.registers = registers,
		.closure_nodes = closure_nodes,
		.closure_environments = closure_environments,
		.fields = fields,
		.values = request.effect_arguments,
	};
	MirHandlerActivation activation = {
		.parent = lowerer.activation,
		.handler_index = handler_node.descriptor,
		.handler = handler,
		.environment = environment,
		.handler_node = handler_node_id,
		.handled_root = handler.handled,
		.hole = request.effect_node,
		.effect_epoch = request.effect_epoch,
		.multi = selected.multi,
	};
	lowerer.activation = &activation;
	LoweredValue result = lower_node(lowerer, selected.body, &clause_scope, depth + 1);
	lowerer.activation = activation.parent;
	if (!lowerer.failed && !activation.resumes_used) activation.aborted = true;
	return result;
}

fn LoweredValue lower_resume_graph(
	DeltaMirLowerer* lowerer,
	MirHandlerActivation* activation,
	LoweredValue resumed,
	uint depth
)
{
	MirSubstitution substitution = {
		.parent = lowerer.substitution,
		.hole = activation.hole,
		.value = resumed,
	};
	lowerer.substitution = &substitution;
	LoweredValue continued = lower_node(
		lowerer, activation.handled_root, activation.environment, depth + 1
	);
	if (lowerer.failed)
	{
		lowerer.substitution = substitution.parent;
		return { };
	}
	LoweredValue result;
	if (continued.pending_effect)
	{
		mitos::DeltaNode* handler_node = mitos::delta_node(
			lowerer.source, activation.handler_node
		);
		if (!handler_node)
		{
			lowerer.fail("MIR captured continuation lost its lexical handler boundary");
			lowerer.substitution = substitution.parent;
			return { };
		}
		result = lower_handle_request(
			lowerer, activation.handler_node, handler_node,
			activation.environment, continued, depth + 1
		);
	}
	else
	{
		result = lower_handler_return(lowerer, activation, continued, depth + 1);
	}
	lowerer.substitution = substitution.parent;
	return result;
}

fn MirResumeBranchState[] snapshot_resume_branch_state(
	DeltaMirLowerer* lowerer
)
{
	usz count = 0;
	for (MirHandlerActivation* activation = lowerer.activation;
		activation; activation = activation.parent) count++;
	MirResumeBranchState[] states = alloc::new_array(
		lowerer.allocator, MirResumeBranchState, (sz)count
	);
	usz index = 0;
	for (MirHandlerActivation* activation = lowerer.activation;
		activation; activation = activation.parent)
	{
		states[index] = {
			.activation = activation,
			.baseline = activation.resumes_used,
			.merged = activation.resumes_used,
			.baseline_aborted = activation.aborted,
			.merged_aborted = activation.aborted,
		};
		index++;
	}
	return states;
}

fn void restore_resume_branch_state(MirResumeBranchState[] states)
{
	foreach (&state : states)
	{
		state.activation.resumes_used = state.baseline;
		state.activation.aborted = state.baseline_aborted;
	}
}

fn void merge_resume_branch_state(MirResumeBranchState[] states)
{
	foreach (&state : states)
	{
		if (state.activation.resumes_used > state.merged)
		{
			state.merged = state.activation.resumes_used;
		}
		state.merged_aborted = state.merged_aborted || state.activation.aborted;
	}
}

fn void apply_resume_branch_state(MirResumeBranchState[] states)
{
	foreach (&state : states)
	{
		state.activation.resumes_used = state.merged;
		state.activation.aborted = state.merged_aborted;
	}
}


fn LoweredValue lower_match(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNodeId node_id,
	mitos::DeltaNode* node,
	MirScope* scope,
	uint depth
)
{
	if (node.inputs.len != 1 || !node.branches.len)
	{
		lowerer.fail("MIR JIT match node has no scrutinee or branches");
		return { };
	}
	LoweredValue scrutinee = lower_node(lowerer, node.inputs[0], scope, depth + 1);
	if (scrutinee.provenance_only && scrutinee.constructor_node)
	{
		mitos::DeltaNode* constructor_node = mitos::delta_node(
			lowerer.source, scrutinee.constructor_node
		);
		if (!constructor_node
			|| constructor_node.kind != mitos::DeltaNodeKind.DELTA_CONSTRUCTOR
			|| constructor_node.descriptor >= lowerer.source.constructors.len)
		{
			lowerer.fail("MIR constructor provenance is invalid");
			return { };
		}
		foreach (&branch : node.branches)
		{
			if (!branch.wildcard
				&& branch.constructor != constructor_node.descriptor) continue;
			if (branch.wildcard)
			{
				return lower_node(lowerer, branch.body, scope, depth + 1);
			}
			mitos::DeltaConstructorDescriptor* constructor =
				&lowerer.source.constructors[constructor_node.descriptor];
			if (branch.bindings.len != constructor.fields.len
				|| scrutinee.fields.len != branch.bindings.len)
			{
				lowerer.fail("MIR constructor provenance disagrees with match bindings");
				return { };
			}
			uint[] registers = alloc::new_array(
				lowerer.allocator, uint, (sz)branch.bindings.len
			);
			mitos::TypeId[] types = alloc::new_array(
				lowerer.allocator, mitos::TypeId, (sz)branch.bindings.len
			);
			mitos::DeltaNodeId[] closure_nodes = alloc::new_array(
				lowerer.allocator, mitos::DeltaNodeId, (sz)branch.bindings.len
			);
			MirScope*[] closure_environments = alloc::new_array(
				lowerer.allocator, MirScope*, (sz)branch.bindings.len
			);
			LoweredValue[][] fields = alloc::new_array(
				lowerer.allocator, LoweredValue[], (sz)branch.bindings.len
			);
			LoweredValue[] values = alloc::new_array(
				lowerer.allocator, LoweredValue, (sz)branch.bindings.len
			);
			foreach (index, field : scrutinee.fields)
			{
				registers[index] = field.register;
				types[index] = field.type_id;
				closure_nodes[index] = field.closure_node;
				closure_environments[index] = field.closure_environment;
				fields[index] = field.fields;
				values[index] = field;
			}
			MirScope branch_scope = {
				.parent = scope,
				.names = branch.bindings,
				.types = types,
				.registers = registers,
				.closure_nodes = closure_nodes,
				.closure_environments = closure_environments,
				.fields = fields,
				.values = values,
			};
			LoweredValue result = lower_node(
				lowerer, branch.body, &branch_scope, depth + 1
			);
			alloc::free(lowerer.allocator, registers);
			alloc::free(lowerer.allocator, types);
			alloc::free(lowerer.allocator, closure_nodes);
			alloc::free(lowerer.allocator, closure_environments);
			alloc::free(lowerer.allocator, fields);
			alloc::free(lowerer.allocator, values);
			return result;
		}
		lowerer.fail("MIR constructor provenance has no matching branch");
		return { };
	}
	if (lowerer.failed) return { };
	if (scrutinee.pending_effect) return scrutinee;
	if (scrutinee.alternatives.len
		&& superposition_element_type(lowerer, scrutinee.type_id, null))
	{
		mitos::DeltaNode* alternatives_source = mitos::delta_node(
			lowerer.source, scrutinee.alternatives_node
		);
		if (!alternatives_source
			|| alternatives_source.kind != mitos::DeltaNodeKind.DELTA_SUPERPOSE
			|| alternatives_source.inputs.len != scrutinee.alternatives.len)
		{
			lowerer.fail("MIR lifted match lost its superposition provenance");
			return { };
		}
		LoweredValue[] matched_alternatives = alloc::new_array(
			lowerer.allocator, LoweredValue, (sz)scrutinee.alternatives.len
		);
		lowerer.provenance_field_sets.push(matched_alternatives);
		uint[] registers = alloc::new_array(
			lowerer.allocator, uint, (sz)scrutinee.alternatives.len
		);
		defer alloc::free(lowerer.allocator, registers);
		mitos::TypeId element_type = mitos::TYPE_ID_INVALID;
		MirSubstitution* base_substitution = lowerer.substitution;
		foreach (index, alternative : scrutinee.alternatives)
		{
			MirSubstitution alternative_substitution = {
				.parent = base_substitution,
				.hole = node.inputs[0],
				.value = alternative,
			};
			lowerer.substitution = &alternative_substitution;
			LoweredValue matched = lower_node(
				lowerer, node_id, scope, depth + 1
			);
			lowerer.substitution = base_substitution;
			if (lowerer.failed || matched.pending_effect) return matched;
			matched = materialize_runtime_value(lowerer, matched, depth + 1);
			if (lowerer.failed) return { };
			matched_alternatives[index] = matched;
			registers[index] = matched.register;
			mitos::TypeId matched_type = branch_runtime_type(
				lowerer, matched.type_id
			);
			if (element_type == mitos::TYPE_ID_INVALID)
			{
				element_type = matched_type;
			}
			else if (element_type != matched_type)
			{
				element_type = mitos::TYPE_ID_ANY;
			}
		}
		if (element_type == mitos::TYPE_ID_INVALID)
		{
			element_type = mitos::TYPE_ID_ANY;
		}
		mitos::TypeId matched_type = intern_superposition_type(
			lowerer, element_type
		);
		if (lowerer.failed) return { };
		uint matched = new_register(lowerer);
		emit(lowerer, {
			.opcode = SUPERPOSE,
			.destination = matched,
			.b = (uint)matched_type,
			.operand_start = append_operands(lowerer, registers),
			.operand_count = (uint)registers.len,
			.immediate = (long)alternatives_source.descriptor,
		});
		return {
			.register = matched,
			.type_id = matched_type,
			.alternatives = matched_alternatives,
			.alternatives_node = scrutinee.alternatives_node,
		};
	}
	scrutinee = materialize_runtime_value(lowerer, scrutinee, depth + 1);
	if (lowerer.failed) return { };
	if (superposition_element_type(lowerer, scrutinee.type_id, null))
	{
		uint[] closures = alloc::new_array(lowerer.allocator, uint, (sz)node.branches.len);
		defer alloc::free(lowerer.allocator, closures);
		uint arm_start = (uint)lowerer.match_arms.size;
		mitos::TypeId result_element = mitos::TYPE_ID_INVALID;
		foreach (branch_index, &branch : node.branches)
		{
			String[] parameters;
			mitos::TypeId[] parameter_types;
			if (branch.wildcard)
			{
				parameters = { };
				parameter_types = { };
			}
			else
			{
				if (branch.constructor >= lowerer.source.constructors.len)
				{
					lowerer.fail("MIR JIT match branch references an invalid constructor");
					return { };
				}
				mitos::DeltaConstructorDescriptor* constructor =
					&lowerer.source.constructors[branch.constructor];
				if (branch.bindings.len != constructor.fields.len)
				{
					lowerer.fail("MIR JIT match binding count disagrees with constructor layout");
					return { };
				}
				parameters = branch.bindings;
				parameter_types = constructor.field_types;
			}
			uint[] captures;
			mitos::TypeId[] capture_types;
			uint target = reserve_graph_closure_instance(
				lowerer,
				branch.body,
				parameters,
				parameter_types,
				mitos::TYPE_ID_ANY,
				scope,
				&captures,
				&capture_types
			);
			if (lowerer.failed)
			{
				alloc::free(lowerer.allocator, captures);
				alloc::free(lowerer.allocator, capture_types);
				return { };
			}
			bool lifted_closure = false;
			foreach (capture_type : capture_types)
			{
				if (superposition_element_type(lowerer, capture_type, null))
				{
					lifted_closure = true;
					break;
				}
			}
			closures[branch_index] = new_register(lowerer);
			emit(lowerer, {
				.opcode = lifted_closure ? LIFT_MAKE_FUNCTION : MAKE_FUNCTION,
				.destination = closures[branch_index],
				.a = target,
				.b = (uint)mitos::TYPE_ID_FUNCTION,
				.operand_start = append_operands(lowerer, captures),
				.operand_count = (uint)captures.len,
				.immediate = (long)parameters.len,
			});
			mitos::DeltaNode* body = mitos::delta_node(lowerer.source, branch.body);
			mitos::TypeId body_type = body
				? (body.runtime_type ? body.runtime_type : body.static_type)
				: mitos::TYPE_ID_ANY;
			if (body && body.kind == mitos::DeltaNodeKind.DELTA_LOCAL
				&& (body_type == mitos::TYPE_ID_ANY || body_type == mitos::TYPE_ID_INVALID))
			{
				foreach (parameter_index, parameter : parameters)
				{
					if (parameter == body.name)
					{
						body_type = parameter_types[parameter_index];
						break;
					}
				}
			}
			body_type = branch_runtime_type(lowerer, body_type);
			if (body_type == mitos::TYPE_ID_ANY || body_type == mitos::TYPE_ID_INVALID)
			{
				result_element = mitos::TYPE_ID_ANY;
			}
			else if (result_element == mitos::TYPE_ID_INVALID)
			{
				result_element = body_type;
			}
			else if (result_element != mitos::TYPE_ID_ANY && result_element != body_type)
			{
				result_element = mitos::TYPE_ID_ANY;
			}
			lowerer.match_arms.push({
				.constructor = branch.wildcard ? uint::max : constructor_index(branch.constructor),
				.flags = branch.wildcard ? 1u : 0u,
			});
			alloc::free(lowerer.allocator, captures);
			alloc::free(lowerer.allocator, capture_types);
		}
		mitos::TypeId result_element_type = result_element == mitos::TYPE_ID_INVALID
			? mitos::TYPE_ID_ANY : result_element;
		mitos::TypeId result_type = intern_superposition_type(
			lowerer, result_element_type
		);
		if (lowerer.failed) return { };
		uint result = new_register(lowerer);
		emit(lowerer, {
			.opcode = LIFT_MATCH,
			.destination = result,
			.a = scrutinee.register,
			.b = (uint)result_type,
			.operand_start = append_operands(lowerer, closures),
			.operand_count = (uint)closures.len,
			.immediate = (long)arm_start,
		});
		return { .register = result, .type_id = result_type };
	}
	uint result = new_register(lowerer);
	// The shared phi register is explicitly initialized so nested forward
	// joins remain definitely assigned; every reachable match arm overwrites it.
	emit(lowerer, { .opcode = CONST, .destination = result });
	uint join = new_label(lowerer);
	mitos::TypeId result_type = mitos::TYPE_ID_ANY;
	mitos::DeltaNodeId result_closure = mitos::DELTA_NODE_INVALID;
	MirScope* result_closure_environment = null;
	LoweredValue[] result_fields;
	LoweredValue[] branch_values = alloc::new_array(
		lowerer.allocator, LoweredValue, (sz)node.branches.len
	);
	lowerer.provenance_field_sets.push(branch_values);
	bool result_provenance_only = false;
	bool exhaustive = false;
	foreach (&branch : node.branches)
	{
		if (branch.wildcard)
		{
			exhaustive = true;
			break;
		}
	}
	// Runtime match arms are exclusive: lower each from the same continuation
	// state, then retain the greatest use count at the control-flow join.
	MirResumeBranchState[] resume_states = snapshot_resume_branch_state(lowerer);
	defer alloc::free(lowerer.allocator, resume_states);
	foreach (branch_index, &branch : node.branches)
	{
		restore_resume_branch_state(resume_states);
		uint next = 0;
		if (!branch.wildcard && branch.constructor >= lowerer.source.constructors.len)
		{
			lowerer.fail("MIR JIT match branch references an invalid constructor");
			return { };
		}
		if (!branch.wildcard)
		{
			next = new_label(lowerer);
			uint condition = new_register(lowerer);
			emit(lowerer, {
				.opcode = TAG_EQUAL,
				.destination = condition,
				.a = scrutinee.register,
				.b = constructor_index(branch.constructor),
			});
			emit(lowerer, { .opcode = BRANCH_FALSE, .a = condition, .b = next });
		}
		MirScope branch_scope = { .parent = scope };
		uint[] registers;
		mitos::TypeId[] types;
		mitos::DeltaNodeId[] closure_nodes;
		MirScope*[] closure_environments;
		LoweredValue[][] fields;
		LoweredValue[] values;
		if (!branch.wildcard)
		{
			mitos::DeltaConstructorDescriptor* constructor = &lowerer.source.constructors[branch.constructor];
			if (branch.bindings.len != constructor.fields.len)
			{
				lowerer.fail("MIR JIT match binding count disagrees with constructor layout");
				return { };
			}
			registers = alloc::new_array(lowerer.allocator, uint, (sz)branch.bindings.len);
			types = alloc::clone_slice(lowerer.allocator, constructor.field_types);
			closure_nodes = alloc::new_array(
				lowerer.allocator, mitos::DeltaNodeId, (sz)branch.bindings.len
			);
			closure_environments = alloc::new_array(
				lowerer.allocator, MirScope*, (sz)branch.bindings.len
			);
			fields = alloc::new_array(
				lowerer.allocator, LoweredValue[], (sz)branch.bindings.len
			);
			values = alloc::new_array(
				lowerer.allocator, LoweredValue, (sz)branch.bindings.len
			);
			foreach (field_index, binding : branch.bindings)
			{
				(void)binding;
				registers[field_index] = new_register(lowerer);
				emit(lowerer, {
					.opcode = GET_FIELD,
					.destination = registers[field_index],
					.a = scrutinee.register,
					.b = (uint)field_index,
				});
				if (scrutinee.fields.len == branch.bindings.len)
				{
					closure_nodes[field_index] =
						scrutinee.fields[field_index].closure_node;
					closure_environments[field_index] =
						scrutinee.fields[field_index].closure_environment;
					fields[field_index] = scrutinee.fields[field_index].fields;
				}
				if (scrutinee.fields.len == branch.bindings.len)
				{
					values[field_index] = scrutinee.fields[field_index];
				}
				else if (scrutinee.alternatives.len)
				{
					bool complete = true;
					foreach (alternative : scrutinee.alternatives)
					{
						if (alternative.fields.len != branch.bindings.len)
						{
							complete = false;
							break;
						}
					}
					if (complete)
					{
						LoweredValue[] field_alternatives = alloc::new_array(
							lowerer.allocator,
							LoweredValue,
							(sz)scrutinee.alternatives.len
						);
						lowerer.provenance_field_sets.push(field_alternatives);
						foreach (alternative_index, alternative : scrutinee.alternatives)
						{
							field_alternatives[alternative_index] =
								alternative.fields[field_index];
						}
						values[field_index] = {
							.alternatives = field_alternatives,
							.alternatives_node = scrutinee.alternatives_node,
							.alternative_scrutinee = scrutinee.alternative_scrutinee,
						};
					}
				}
				values[field_index].register = registers[field_index];
				values[field_index].type_id = types[field_index];
			}
			branch_scope.names = branch.bindings;
			branch_scope.types = types;
			branch_scope.registers = registers;
			branch_scope.closure_nodes = closure_nodes;
			branch_scope.closure_environments = closure_environments;
			branch_scope.fields = fields;
			branch_scope.values = values;
		}
		enter_materialization_scope(lowerer);
		LoweredValue body = lower_node(lowerer, branch.body, &branch_scope, depth + 1);
		if (!lowerer.failed && !body.pending_effect)
		{
			if (body.provenance_only)
			{
				result_provenance_only = true;
			}
			else
			{
				body = materialize_runtime_value(lowerer, body, depth + 1);
			}
		}
		merge_resume_branch_state(resume_states);
		leave_materialization_scope(lowerer);
		alloc::free(lowerer.allocator, registers);
		alloc::free(lowerer.allocator, types);
		alloc::free(lowerer.allocator, closure_nodes);
		alloc::free(lowerer.allocator, closure_environments);
		alloc::free(lowerer.allocator, fields);
		alloc::free(lowerer.allocator, values);
		if (lowerer.failed) return { };
		if (body.pending_effect) return body;
		branch_values[branch_index] = body;
		if (branch_index == 0)
		{
			result_type = body.type_id;
			result_closure = body.closure_node;
			result_closure_environment = body.closure_environment;
			result_fields = body.fields;
		}
		else
		{
			if (result_type != body.type_id) result_type = mitos::TYPE_ID_ANY;
			if (result_closure != body.closure_node
				|| result_closure_environment != body.closure_environment)
			{
				result_closure = mitos::DELTA_NODE_INVALID;
				result_closure_environment = null;
			}
			if (result_fields.ptr != body.fields.ptr) result_fields = { };
		}
		if (!body.provenance_only) emit(lowerer, {
			.opcode = MOVE, .destination = result, .a = body.register,
		});
		emit(lowerer, { .opcode = JUMP, .a = join });
		if (!branch.wildcard) emit(lowerer, { .opcode = LABEL, .a = next });
		if (branch.wildcard) break;
	}
	apply_resume_branch_state(resume_states);
	if (!exhaustive)
	{
		// The MIR ABI has no trap opcode. A guaranteed division by zero gives
		// dynamically typed, non-exhaustive matches an explicit fail-closed path.
		uint zero = new_register(lowerer);
		emit(lowerer, { .opcode = CONST, .destination = zero });
		uint trap = new_register(lowerer);
		emit(lowerer, {
			.opcode = DIVIDE, .destination = trap, .a = zero, .b = zero,
		});
		emit(lowerer, {
			.opcode = MOVE, .destination = result, .a = trap,
		});
	}
	emit(lowerer, { .opcode = LABEL, .a = join });
	return {
		.register = result,
		.type_id = result_type,
		.closure_node = result_closure,
		.closure_environment = result_closure_environment,
		.fields = result_fields,
		.alternatives = branch_values,
		.alternatives_node = node_id,
		.alternative_scrutinee = scrutinee.register,
		.provenance_only = result_provenance_only,
		.lazy = result_provenance_only ? new_lazy_materialization(lowerer) : null,
	};
}

fn LoweredValue lower_effectful_lifted_lambda(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNode* lambda,
	MirScope* environment,
	uint[] registers,
	mitos::TypeId[] types,
	mitos::DeltaNodeId[] closure_nodes,
	MirScope*[] closure_environments,
	LoweredValue[][] fields,
	LoweredValue[] values,
	usz first_argument,
	uint source_span,
	uint depth
)
{
	usz lifted_argument = values.len;
	for (usz index = first_argument; index < values.len; index++)
	{
		if (superposition_element_type(lowerer, values[index].type_id, null))
		{
			lifted_argument = index;
			break;
		}
	}
	if (lifted_argument == values.len)
	{
		MirScope direct_scope = {
			.parent = environment,
			.names = lambda.names,
			.types = types,
			.registers = registers,
			.closure_nodes = closure_nodes,
			.closure_environments = closure_environments,
			.fields = fields,
			.values = values,
		};
		LoweredValue direct = lower_node(
			lowerer, lambda.inputs[0], &direct_scope, depth + 1
		);
		return assert_runtime_type(
			lowerer,
			direct,
			lambda.result_type ? lambda.result_type : mitos::TYPE_ID_ANY,
			source_span,
			depth + 1
		);
	}
	LoweredValue lifted = values[lifted_argument];
	mitos::DeltaNode* alternatives_source = mitos::delta_node(
		lowerer.source, lifted.alternatives_node
	);
	if (!lifted.alternatives.len || !alternatives_source
		|| alternatives_source.kind != mitos::DeltaNodeKind.DELTA_SUPERPOSE
		|| alternatives_source.inputs.len != lifted.alternatives.len)
	{
		lowerer.fail(
			"effect-capable MIR lifted closure application has unresolved branch provenance"
		);
		return { };
	}
	uint[] branch_registers = alloc::new_array(
		lowerer.allocator, uint, (sz)lifted.alternatives.len
	);
	defer alloc::free(lowerer.allocator, branch_registers);
	LoweredValue[] branch_values = alloc::new_array(
		lowerer.allocator, LoweredValue, (sz)lifted.alternatives.len
	);
	lowerer.provenance_field_sets.push(branch_values);
	mitos::TypeId element_type = mitos::TYPE_ID_INVALID;
	foreach (branch_index, alternative : lifted.alternatives)
	{
		values[lifted_argument] = alternative;
		registers[lifted_argument] = alternative.register;
		types[lifted_argument] = alternative.type_id;
		closure_nodes[lifted_argument] = alternative.closure_node;
		closure_environments[lifted_argument] = alternative.closure_environment;
		fields[lifted_argument] = alternative.fields;
		LoweredValue branch = lower_effectful_lifted_lambda(
			lowerer,
			lambda,
			environment,
			registers,
			types,
			closure_nodes,
			closure_environments,
			fields,
			values,
			lifted_argument + 1,
			source_span,
			depth + 1
		);
		if (lowerer.failed || branch.pending_effect)
		{
			values[lifted_argument] = lifted;
			registers[lifted_argument] = lifted.register;
			types[lifted_argument] = lifted.type_id;
			closure_nodes[lifted_argument] = lifted.closure_node;
			closure_environments[lifted_argument] = lifted.closure_environment;
			fields[lifted_argument] = lifted.fields;
			return branch;
		}
		branch = materialize_runtime_value(lowerer, branch, depth + 1);
		if (lowerer.failed) return { };
		branch_values[branch_index] = branch;
		branch_registers[branch_index] = branch.register;
		mitos::TypeId branch_type = branch_runtime_type(
			lowerer, branch.type_id
		);
		if (element_type == mitos::TYPE_ID_INVALID)
		{
			element_type = branch_type;
		}
		else if (element_type != branch_type)
		{
			element_type = mitos::TYPE_ID_ANY;
		}
	}
	values[lifted_argument] = lifted;
	registers[lifted_argument] = lifted.register;
	types[lifted_argument] = lifted.type_id;
	closure_nodes[lifted_argument] = lifted.closure_node;
	closure_environments[lifted_argument] = lifted.closure_environment;
	fields[lifted_argument] = lifted.fields;
	mitos::TypeId result_type = intern_superposition_type(lowerer, element_type);
	if (lowerer.failed) return { };
	uint result = new_register(lowerer);
	emit(lowerer, {
		.opcode = SUPERPOSE,
		.destination = result,
		.b = (uint)result_type,
		.operand_start = append_operands(lowerer, branch_registers),
		.operand_count = (uint)branch_registers.len,
		.immediate = (long)alternatives_source.descriptor,
	});
	return {
		.register = result,
		.type_id = result_type,
		.alternatives = branch_values,
		.alternatives_node = lifted.alternatives_node,
	};
}

fn LoweredValue lower_node(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNodeId node_id,
	MirScope* scope,
	uint depth
)
{
	if (lowerer.failed) return { };
	if (depth >= JIT_MAX_DEPTH)
	{
		lowerer.fail("MIR JIT Delta lowering depth limit exceeded");
		return { };
	}
	for (MirSubstitution* substitution = lowerer.substitution;
		substitution; substitution = substitution.parent)
	{
		if (substitution.hole == node_id) return substitution.value;
	}
	mitos::DeltaNode* node = mitos::delta_node(lowerer.source, node_id);
	if (!node)
	{
		lowerer.fail("MIR JIT reached an invalid Delta node identity");
		return { };
	}
	switch (node.kind)
	{
		case DELTA_LOCAL:
			LoweredValue local;
			if (!find_binding(scope, node.name, &local))
			{
				lowerer.fail("MIR JIT Delta local is absent from its method instance");
				return { };
			}
			return local;
		case DELTA_I64:
			uint integer = new_register(lowerer);
			emit(lowerer, { .opcode = CONST, .destination = integer, .immediate = node.integer });
			return { .register = integer, .type_id = mitos::TYPE_ID_I64 };
		case DELTA_STRING:
			mitos::TypeId string_type = node.runtime_type
				? node.runtime_type : mitos::TYPE_ID_STRING;
			uint string_index = (uint)lowerer.strings.size;
			lowerer.strings.push({
				.bytes = node.string_value.ptr,
				.length = node.string_value.len,
				.runtime_type = (uint)string_type,
			});
			uint string_value = new_register(lowerer);
			emit(lowerer, {
				.opcode = STRING_CONST,
				.destination = string_value,
				.a = string_index,
			});
			return { .register = string_value, .type_id = string_type };
		case DELTA_SUPERPOSE:
			if (!node.inputs.len || node.inputs.len > JIT_MAX_SUPERPOSE_BRANCHES
				|| !node.descriptor
				|| !mitos::type_id_is_valid(&lowerer.source.types, node.runtime_type)
				|| !mitos::type_id_is_valid(&lowerer.source.types, node.result_type))
			{
				lowerer.fail("MIR superpose node has invalid origin, alternatives, or TypeIds");
				return { };
			}
			mitos::TypeId declared_element;
			if (!superposition_element_type(lowerer, node.runtime_type, &declared_element)
				|| declared_element != node.result_type)
			{
				lowerer.fail("MIR superpose metadata is not Superposition of its element TypeId");
				return { };
			}
			uint[] alternatives = alloc::new_array(lowerer.allocator, uint, (sz)node.inputs.len);
			defer alloc::free(lowerer.allocator, alternatives);
			LoweredValue[] alternative_values = alloc::new_array(
				lowerer.allocator, LoweredValue, (sz)node.inputs.len
			);
			lowerer.provenance_field_sets.push(alternative_values);
			mitos::TypeId actual_element = mitos::TYPE_ID_INVALID;
			bool provenance_only = false;
			foreach (index, input : node.inputs)
			{
				LoweredValue alternative = lower_node(lowerer, input, scope, depth + 1);
				if (lowerer.failed || alternative.pending_effect) return alternative;
				alternative_values[index] = alternative;
				provenance_only = provenance_only || alternative.provenance_only;
				mitos::TypeId alternative_type = branch_runtime_type(
					lowerer, alternative.type_id
				);
				if ((alternative_type == mitos::TYPE_ID_ANY
						&& declared_element != mitos::TYPE_ID_ANY)
					|| alternative_type == mitos::TYPE_ID_INVALID
					|| (declared_element != mitos::TYPE_ID_ANY
						&& alternative_type != declared_element)
					|| (actual_element != mitos::TYPE_ID_INVALID
						&& actual_element != mitos::TYPE_ID_ANY
						&& alternative_type != mitos::TYPE_ID_ANY
						&& alternative_type != actual_element))
				{
					lowerer.fail("MIR superpose alternatives must have one concrete runtime TypeId");
					return { };
				}
				if (actual_element == mitos::TYPE_ID_INVALID)
				{
					actual_element = alternative_type;
				}
				else if (alternative_type == mitos::TYPE_ID_ANY)
				{
					actual_element = mitos::TYPE_ID_ANY;
				}
				alternatives[index] = alternative.register;
			}
			mitos::TypeId superposition_type = declared_element == mitos::TYPE_ID_ANY
				&& actual_element != mitos::TYPE_ID_ANY
				? intern_superposition_type(lowerer, actual_element) : node.runtime_type;
			if (lowerer.failed || superposition_type == mitos::TYPE_ID_INVALID)
			{
				lowerer.fail("MIR superpose could not intern its runtime TypeId");
				return { };
			}
			if (provenance_only)
			{
				return {
					.type_id = superposition_type,
					.alternatives = alternative_values,
					.alternatives_node = node_id,
					.provenance_only = true,
					.lazy = new_lazy_materialization(lowerer),
				};
			}
			uint superposition = new_register(lowerer);
			emit(lowerer, {
				.opcode = SUPERPOSE,
				.destination = superposition,
				.b = (uint)superposition_type,
				.operand_start = append_operands(lowerer, alternatives),
				.operand_count = (uint)alternatives.len,
				.immediate = (long)node.descriptor,
			});
			return {
				.register = superposition,
				.type_id = superposition_type,
				.alternatives = alternative_values,
				.alternatives_node = node_id,
			};
		case DELTA_COLLAPSE:
			if (node.inputs.len != 1
				|| !mitos::type_id_is_valid(&lowerer.source.types, node.runtime_type)
				|| !mitos::type_id_is_valid(&lowerer.source.types, node.result_type))
			{
				lowerer.fail("MIR collapse node has invalid arity or TypeIds");
				return { };
			}
			LoweredValue collapsed_input = lower_node(
				lowerer, node.inputs[0], scope, depth + 1
			);
			if (lowerer.failed || collapsed_input.pending_effect) return collapsed_input;
			collapsed_input = materialize_runtime_value(
				lowerer, collapsed_input, depth + 1
			);
			if (lowerer.failed) return { };
			mitos::TypeId collapsed_element;
			if (!superposition_element_type(lowerer, collapsed_input.type_id, &collapsed_element)
				|| (node.result_type != mitos::TYPE_ID_ANY
					&& collapsed_element != node.result_type))
			{
				lowerer.fail("collapse strictly requires a superposition");
				return { };
			}
			mitos::TypeId array_type = node.result_type == mitos::TYPE_ID_ANY
				&& collapsed_element != mitos::TYPE_ID_ANY
				? intern_array_type(lowerer, collapsed_element) : node.runtime_type;
			if (lowerer.failed || array_type == mitos::TYPE_ID_INVALID)
			{
				lowerer.fail("collapse could not intern its Array result TypeId");
				return { };
			}
			uint collapsed = new_register(lowerer);
			emit(lowerer, {
				.opcode = COLLAPSE,
				.destination = collapsed,
				.a = collapsed_input.register,
				.b = (uint)array_type,
				.immediate = (long)collapsed_element,
			});
			return { .register = collapsed, .type_id = array_type };
		case DELTA_PRIMITIVE:
			if (node.descriptor >= lowerer.source.primitives.len || node.inputs.len != 2)
			{
				lowerer.fail("MIR JIT primitive node has invalid descriptor or arity");
				return { };
			}
			LoweredValue left = lower_node(lowerer, node.inputs[0], scope, depth + 1);
			if (lowerer.failed || left.pending_effect) return left;
			LoweredValue right = lower_node(lowerer, node.inputs[1], scope, depth + 1);
			if (lowerer.failed || right.pending_effect) return right;
			left = materialize_runtime_value(lowerer, left, depth + 1);
			right = materialize_runtime_value(lowerer, right, depth + 1);
			if (lowerer.failed) return { };
			mitos::DeltaPrimitiveDescriptor* descriptor = &lowerer.source.primitives[node.descriptor];
			bool left_lifted;
			bool right_lifted;
			mitos::TypeId left_type = branch_runtime_type(lowerer, left.type_id, &left_lifted);
			mitos::TypeId right_type = branch_runtime_type(lowerer, right.type_id, &right_lifted);
			bool lifted = left_lifted || right_lifted;
			if (descriptor.operation != mitos::DeltaPrimitiveOp.DELTA_PRIMITIVE_EQUAL
				&& (left_type != mitos::TYPE_ID_I64 || right_type != mitos::TYPE_ID_I64))
			{
				lowerer.fail("TypeError: MIR integer primitive requires two concrete I64 operands");
				return { };
			}
			mitos::TypeId primitive_type = lifted
				? intern_superposition_type(lowerer, descriptor.result) : descriptor.result;
			if (lowerer.failed) return { };
			uint primitive = new_register(lowerer);
			emit(lowerer, {
				.opcode = primitive_opcode(lowerer, descriptor.operation),
				.destination = primitive,
				.a = left.register,
				.b = right.register,
				.immediate = lifted ? (long)primitive_type : 0,
			});
			return { .register = primitive, .type_id = primitive_type };
		case DELTA_CONSTRUCTOR:
			if (node.descriptor >= lowerer.source.constructors.len)
			{
				lowerer.fail("MIR JIT constructor node references an invalid descriptor");
				return { };
			}
			mitos::DeltaConstructorDescriptor* constructor = &lowerer.source.constructors[node.descriptor];
			if (node.inputs.len != constructor.fields.len)
			{
				lowerer.fail("MIR JIT constructor node disagrees with its typed field layout");
				return { };
			}
			uint[] fields = alloc::new_array(lowerer.allocator, uint, (sz)node.inputs.len);
			defer alloc::free(lowerer.allocator, fields);
			mitos::TypeId[] field_types = alloc::new_array(
				lowerer.allocator, mitos::TypeId, (sz)node.inputs.len
			);
			defer alloc::free(lowerer.allocator, field_types);
			LoweredValue[] field_values = alloc::new_array(
				lowerer.allocator, LoweredValue, (sz)node.inputs.len
			);
			lowerer.provenance_field_sets.push(field_values);
			bool lifted = false;
			bool provenance_only = false;
			foreach (index, input : node.inputs)
			{
				LoweredValue field = lower_node(lowerer, input, scope, depth + 1);
				if (lowerer.failed) return { };
				if (field.pending_effect) return field;
				field_values[index] = field;
				mitos::TypeId expected = node.types.len == node.inputs.len
					? node.types[index] : constructor.field_types[index];
				bool field_lifted;
				mitos::TypeId field_type = branch_runtime_type(lowerer, field.type_id, &field_lifted);
				lifted = lifted || field_lifted;
				provenance_only = provenance_only || field.provenance_only;
				field_types[index] = field_type;
				if (expected != mitos::TYPE_ID_ANY
					&& !mitos::type_is_subtype(&lowerer.source.types, field_type, expected))
				{
					lowerer.fail("TypeError: MIR constructor field does not satisfy its declared type");
					return { };
				}
				fields[index] = field.register;
			}
			mitos::TypeId constructed_type = node.runtime_type
				? node.runtime_type : constructor.runtime_type;
			if (constructor.parameters.len)
			{
				mitos::MitosDiagnostic diagnostic;
				if (!mitos::infer_constructor_instance(
					&lowerer.source.types,
					constructor.type_constructor,
					constructor.parameters,
					constructor.field_patterns,
					field_types,
					&constructed_type,
					&diagnostic
				))
				{
					lowerer.fail(diagnostic.message);
					diagnostic.deinit();
					return { };
				}
			}
			if (!mitos::type_id_is_valid(&lowerer.source.types, constructed_type)
				|| constructed_type == mitos::TYPE_ID_ANY)
			{
				lowerer.fail("MIR constructor has no concrete interned runtime TypeId");
				return { };
			}
			mitos::TypeId lowered_type = lifted
				? intern_superposition_type(lowerer, constructed_type) : constructed_type;
			if (lowerer.failed) return { };
			if (provenance_only)
			{
				return {
					.type_id = lowered_type,
					.fields = field_values,
					.constructor_node = node_id,
					.provenance_only = true,
					.lazy = new_lazy_materialization(lowerer),
				};
			}
			uint constructed = new_register(lowerer);
			emit(lowerer, {
				.opcode = lifted ? LIFT_CONSTRUCTOR : MAKE_CONSTRUCTOR,
				.destination = constructed,
				.a = constructor_index(node.descriptor),
				.b = (uint)constructed_type,
				.operand_start = append_operands(lowerer, fields),
				.operand_count = (uint)fields.len,
			});
			return {
				.register = constructed,
				.type_id = lowered_type,
				.fields = field_values,
			};
		case DELTA_MATCH:
			return lower_match(lowerer, node_id, node, scope, depth);
		case DELTA_GENERIC_CALL: return lower_generic_call(lowerer, node, scope, depth);
		case DELTA_TYPE_VALUE:
			if (!mitos::type_id_is_valid(&lowerer.source.types, (mitos::TypeId)node.descriptor))
			{
				lowerer.fail("TypeError: MIR Type value references an unknown TypeId");
				return { };
			}
			uint type_value = new_register(lowerer);
			emit(lowerer, { .opcode = TYPE_VALUE, .destination = type_value, .a = (uint)node.descriptor });
			return {
				.register = type_value,
				.type_id = node.runtime_type ? node.runtime_type : mitos::TYPE_ID_TYPE,
			};
		case DELTA_TYPE_OF:
			if (node.inputs.len != 1) { lowerer.fail("MIR typeOf node has invalid arity"); return { }; }
			LoweredValue inspected = lower_node(lowerer, node.inputs[0], scope, depth + 1);
			if (lowerer.failed) return { };
			if (inspected.pending_effect) return inspected;
			mitos::TypeId reflected_type = node.runtime_type;
			if (!reflected_type)
			{
				mitos::MitosDiagnostic diagnostic;
				if (!mitos::intern_type_value_type(
					&lowerer.source.types,
					inspected.type_id,
					&reflected_type,
					&diagnostic
				))
				{
					lowerer.fail(diagnostic.message);
					diagnostic.deinit();
					return { };
				}
			}
			uint type_of = new_register(lowerer);
			if (inspected.provenance_only)
			{
				emit(lowerer, {
					.opcode = TYPE_VALUE,
					.destination = type_of,
					.a = (uint)inspected.type_id,
				});
			}
			else
			{
				emit(lowerer, {
					.opcode = TYPE_OF,
					.destination = type_of,
					.a = inspected.register,
				});
			}
			return { .register = type_of, .type_id = reflected_type };
		case DELTA_TYPE_ASSERT:
			if (node.inputs.len != 1 || !mitos::type_id_is_valid(&lowerer.source.types, (mitos::TypeId)node.descriptor))
			{ lowerer.fail("MIR type assertion has invalid metadata"); return { }; }
			LoweredValue asserted = lower_node(
				lowerer, node.inputs[0], scope, depth + 1
			);
			return assert_runtime_type(
				lowerer, asserted, (mitos::TypeId)node.descriptor, node.span,
				depth + 1
			);
		case DELTA_LET:
			if (node.inputs.len != 2 || node.names.len != 1) { lowerer.fail("MIR let node has invalid metadata"); return { }; }
			LoweredValue bound = lower_node(lowerer, node.inputs[0], scope, depth + 1);
			if (lowerer.failed) return { };
			if (bound.pending_effect) return bound;
			String[1] names = { node.names[0] };
			mitos::TypeId[1] types = { bound.type_id };
			uint[1] registers = { bound.register };
			mitos::DeltaNodeId[1] closure_nodes = { bound.closure_node };
			MirScope*[1] closure_environments = { bound.closure_environment };
			LoweredValue[][1] fields = { bound.fields };
			LoweredValue[1] values = { bound };
			MirScope let_scope = {
				.parent = scope,
				.names = names[..],
				.types = types[..],
				.registers = registers[..],
				.closure_nodes = closure_nodes[..],
				.closure_environments = closure_environments[..],
				.fields = fields[..],
				.values = values[..],
			};
			return lower_node(lowerer, node.inputs[1], &let_scope, depth + 1);
		case DELTA_PARALLEL_ROOT:
			if (node.inputs.len != 1) { lowerer.fail("MIR practical root has invalid arity"); return { }; }
			return lower_node(lowerer, node.inputs[0], scope, depth + 1);
		case DELTA_PARALLEL_JOIN:
			if (node.inputs.len != node.names.len + 1 || node.types.len != node.names.len)
			{ lowerer.fail("MIR practical join has inconsistent phase-one roots"); return { }; }
			uint[] root_registers = alloc::new_array(lowerer.allocator, uint, (sz)node.names.len);
			uint[] futures = alloc::new_array(lowerer.allocator, uint, (sz)node.names.len);
			mitos::TypeId[] root_types = alloc::new_array(lowerer.allocator, mitos::TypeId, (sz)node.names.len);
			mitos::DeltaNodeId[] root_closures = alloc::new_array(
				lowerer.allocator, mitos::DeltaNodeId, (sz)node.names.len
			);
			MirScope*[] root_closure_environments = alloc::new_array(
				lowerer.allocator, MirScope*, (sz)node.names.len
			);
			LoweredValue[][] root_fields = alloc::new_array(
				lowerer.allocator, LoweredValue[], (sz)node.names.len
			);
			LoweredValue[] root_values = alloc::new_array(
				lowerer.allocator, LoweredValue, (sz)node.names.len
			);
			defer alloc::free(lowerer.allocator, root_registers);
			defer alloc::free(lowerer.allocator, futures);
			defer alloc::free(lowerer.allocator, root_types);
			defer alloc::free(lowerer.allocator, root_closures);
			defer alloc::free(lowerer.allocator, root_closure_environments);
			defer alloc::free(lowerer.allocator, root_fields);
			defer alloc::free(lowerer.allocator, root_values);
			for (usz batch = 0; batch < node.names.len; batch += 4)
			{
				usz batch_end = batch + 4 < node.names.len ? batch + 4 : node.names.len;
				for (usz index = batch; index < batch_end; index++)
				{
					mitos::DeltaNode* root = mitos::delta_node(lowerer.source, node.inputs[index]);
					if (!root || root.kind != mitos::DeltaNodeKind.DELTA_PARALLEL_ROOT
						|| root.inputs.len != 1)
					{
						lowerer.fail("MIR parallel join references an invalid practical root");
						return { };
					}
					mitos::DeltaNode* root_body = mitos::delta_node(
						lowerer.source, root.inputs[0]
					);
					mitos::TypeId body_result_type = root_body
						? (root_body.result_type
							? root_body.result_type
							: root_body.runtime_type
								? root_body.runtime_type
								: root_body.static_type)
						: mitos::TYPE_ID_INVALID;
					mitos::TypeId root_result_type =
						body_result_type != mitos::TYPE_ID_INVALID
							&& body_result_type != mitos::TYPE_ID_ANY
						? body_result_type
						: root.result_type
							? root.result_type
							: node.types[index];
					bool closure_result = type_may_contain_closure(
						lowerer, root_result_type, 0
					);
					bool inline_required =
						delta_graph_has_effect(lowerer, root.inputs[0], 0)
							|| closure_result;
					uint[] captured = { };
					mitos::TypeId[] captured_types = { };
					uint target = 0;
					if (!inline_required)
					{
						bool captured_effects;
						target = reserve_parallel_instance(
							lowerer, root.inputs[0], root.descriptor,
							scope, &captured, &captured_types, &captured_effects
						);
						alloc::free(lowerer.allocator, captured_types);
						if (lowerer.failed)
						{
							alloc::free(lowerer.allocator, captured);
							return { };
						}
						inline_required = captured_effects;
					}
					if (inline_required)
					{
						alloc::free(lowerer.allocator, captured);
						usz enclosing_source_order = lowerer.current_source_order;
						bool enclosing_parallel_source = lowerer.current_parallel_source;
						lowerer.current_source_order = root.descriptor;
						lowerer.current_parallel_source = true;
						LoweredValue inline_root = lower_node(
							lowerer, root.inputs[0], scope, depth + 1
						);
						lowerer.current_source_order = enclosing_source_order;
						lowerer.current_parallel_source = enclosing_parallel_source;
						if (lowerer.failed || inline_root.pending_effect) return inline_root;
						root_registers[index] = inline_root.register;
						root_types[index] = inline_root.type_id;
						root_closures[index] = inline_root.closure_node;
						root_closure_environments[index] = inline_root.closure_environment;
						root_fields[index] = inline_root.fields;
						root_values[index] = inline_root;
						futures[index] = uint::max;
						continue;
					}
					uint future = new_register(lowerer);
					emit(lowerer, {
						.opcode = PARALLEL_CALL,
						.destination = future,
						.a = target,
						.b = (uint)root.descriptor,
						.immediate = (long)lowerer.instructions.size,
						.operand_start = append_operands(lowerer, captured),
						.operand_count = (uint)captured.len,
					});
					alloc::free(lowerer.allocator, captured);
					futures[index] = future;
					root_types[index] = root.result_type ? root.result_type
						: root.runtime_type ? root.runtime_type : root.static_type;
				}
				for (usz index = batch; index < batch_end; index++)
				{
					if (futures[index] == uint::max) continue;
					uint joined = new_register(lowerer);
					emit(lowerer, {
						.opcode = PARALLEL_JOIN,
						.destination = joined,
						.a = futures[index],
					});
					root_registers[index] = joined;
					root_values[index].register = joined;
					root_values[index].type_id = root_types[index];
				}
			}
			MirScope phase_two_scope = {
				.parent = scope,
				.names = node.names,
				.types = root_types,
				.registers = root_registers,
				.closure_nodes = root_closures,
				.closure_environments = root_closure_environments,
				.fields = root_fields,
				.values = root_values,
			};
			return lower_node(lowerer, node.inputs[node.names.len], &phase_two_scope, depth + 1);
		case DELTA_EFFECT:
			if (node.descriptor >= lowerer.source.effects.operations.len)
			{
				lowerer.fail("MIR effect node has an invalid operation descriptor");
				return { };
			}
			mitos::DeltaOperationDescriptor* operation =
				&lowerer.source.effects.operations[node.descriptor];
			if (operation.parameter_types.len != node.inputs.len
				|| node.types.len != node.inputs.len + 1)
			{
				lowerer.fail("MIR effect node disagrees with its resolved operation signature");
				return { };
			}
			LoweredValue[] effect_arguments = alloc::new_array(
				lowerer.allocator, LoweredValue, (sz)node.inputs.len
			);
			lowerer.effect_argument_sets.push(effect_arguments);
			foreach (index, input : node.inputs)
			{
				effect_arguments[index] = lower_node(lowerer, input, scope, depth + 1);
				if (lowerer.failed) return { };
				if (effect_arguments[index].pending_effect) return effect_arguments[index];
				mitos::TypeId expected_argument = node.types[index];
				if (superposition_element_type(
					lowerer, effect_arguments[index].type_id, null
				))
				{
					lowerer.fail(
						"effect operation arguments cannot be superpositions; superpose the effect calls explicitly"
					);
					return { };
				}
				if (expected_argument != mitos::TYPE_ID_ANY
					&& !mitos::type_is_subtype(
						&lowerer.source.types,
						effect_arguments[index].type_id,
						expected_argument
					))
				{
					lowerer.fail("TypeError: MIR effect argument violates its operation type");
					return { };
				}
			}
			return {
				.type_id = node.result_type ? node.result_type : node.types[node.inputs.len],
				.pending_effect = true,
				.effect_operation = node.descriptor,
				.effect_node = node_id,
				.effect_epoch = lowerer.source.effects.epoch,
				.effect_source_order = lowerer.current_source_order,
				.effect_arguments = effect_arguments,
			};
		case DELTA_HANDLER:
			if (node.inputs.len < 1 || node.descriptor >= lowerer.source.effects.handlers.len)
			{
				lowerer.fail("MIR handler node has invalid Delta metadata");
				return { };
			}
			LoweredValue handled = lower_node(lowerer, node.inputs[0], scope, depth + 1);
			if (lowerer.failed) return { };
			if (handled.pending_effect)
			{
				return lower_handle_request(lowerer, node_id, node, scope, handled, depth + 1);
			}
			MirHandlerActivation return_activation = {
				.handler_index = node.descriptor,
				.handler = &lowerer.source.effects.handlers[node.descriptor],
				.environment = scope,
				.handler_node = node_id,
				.handled_root = node.inputs[0],
				.effect_epoch = lowerer.source.effects.epoch,
			};
			return lower_handler_return(lowerer, &return_activation, handled, depth + 1);
		case DELTA_RESUME:
			if (node.inputs.len != 1)
			{
				lowerer.fail("MIR resume node has invalid arity");
				return { };
			}
			MirHandlerActivation* activation = lowerer.activation;
			if (!activation || activation.handler_index != node.descriptor
				|| activation.effect_epoch != lowerer.source.effects.epoch
				|| activation.aborted)
			{
				lowerer.fail("invalid MIR resume has no live matching continuation");
				return { };
			}
			if (!activation.multi && activation.resumes_used)
			{
				lowerer.fail("one-shot MIR continuation cannot be resumed more than once");
				return { };
			}
			LoweredValue resumed = lower_node(lowerer, node.inputs[0], scope, depth + 1);
			if (lowerer.failed || resumed.pending_effect) return resumed;
			mitos::TypeId expected_resume = node.result_type
				? node.result_type : node.types.len ? node.types[0] : mitos::TYPE_ID_ANY;
			mitos::TypeId resumed_type = branch_runtime_type(
				lowerer, resumed.type_id
			);
			if (expected_resume != mitos::TYPE_ID_ANY
				&& !mitos::type_is_subtype(
					&lowerer.source.types,
					resumed_type,
					expected_resume
				))
			{
				lowerer.fail("TypeError: MIR resumed value violates the operation result type");
				return { };
			}
			activation.resumes_used++;
			return lower_resume_graph(lowerer, activation, resumed, depth + 1);
		case DELTA_ABORT:
			if (node.inputs.len != 1)
			{
				lowerer.fail("MIR abort node has invalid arity");
				return { };
			}
			LoweredValue aborted = lower_node(lowerer, node.inputs[0], scope, depth + 1);
			if (lowerer.failed || aborted.pending_effect) return aborted;
			if (lowerer.activation && lowerer.activation.handler_index == node.descriptor)
			{
				lowerer.activation.aborted = true;
			}
			return aborted;
		case DELTA_LAMBDA:
			if (node.inputs.len != 1 || node.names.len != node.types.len
				|| !mitos::type_id_is_valid(&lowerer.source.types, node.runtime_type))
			{
				lowerer.fail("MIR lambda has invalid concrete Function metadata");
				return { };
			}
			return {
				.type_id = node.runtime_type,
				.closure_node = node_id,
				.closure_environment = snapshot_scope(
					lowerer, scope, node.inputs[0], node.names
				),
				.provenance_only = true,
				.lazy = new_lazy_materialization(lowerer),
			};
		case DELTA_APPLY:
			if (!node.inputs.len)
			{
				lowerer.fail("MIR function application has no callee");
				return { };
			}
			mitos::DeltaNode* static_callee = mitos::delta_node(
				lowerer.source, node.inputs[0]
			);
			MirScope* static_environment = scope;
			LoweredValue callee = { };
			if (!static_callee
				|| static_callee.kind != mitos::DeltaNodeKind.DELTA_LAMBDA)
			{
				callee = lower_node(lowerer, node.inputs[0], scope, depth + 1);
				if (lowerer.failed || callee.pending_effect) return callee;
				if (callee.closure_node)
				{
					static_callee = mitos::delta_node(
						lowerer.source, callee.closure_node
					);
				}
				if (callee.closure_environment)
				{
					static_environment = callee.closure_environment;
				}
			}
			if (callee.alternatives.len)
			{
				mitos::DeltaNode* alternatives_source = mitos::delta_node(
					lowerer.source, callee.alternatives_node
				);
				if (!alternatives_source
					|| (alternatives_source.inputs.len != callee.alternatives.len
						&& alternatives_source.branches.len != callee.alternatives.len))
				{
					lowerer.fail("MIR closure alternatives lost their Delta provenance");
					return { };
				}
				MirSubstitution* base_substitution = lowerer.substitution;
				MirSubstitution[] argument_substitutions = alloc::new_array(
					lowerer.allocator, MirSubstitution, (sz)node.inputs.len - 1
				);
				defer alloc::free(lowerer.allocator, argument_substitutions);
				MirSubstitution* argument_scope = base_substitution;
				for (usz argument_index = 1; argument_index < node.inputs.len;
					argument_index++)
				{
					LoweredValue argument = lower_node(
						lowerer, node.inputs[argument_index], scope, depth + 1
					);
					if (lowerer.failed || argument.pending_effect) return argument;
					argument_substitutions[argument_index - 1] = {
						.parent = argument_scope,
						.hole = node.inputs[argument_index],
						.value = argument,
					};
					argument_scope = &argument_substitutions[argument_index - 1];
				}
				LoweredValue[] applied_alternatives = alloc::new_array(
					lowerer.allocator, LoweredValue, (sz)callee.alternatives.len
				);
				lowerer.provenance_field_sets.push(applied_alternatives);
				if (alternatives_source.kind
					== mitos::DeltaNodeKind.DELTA_SUPERPOSE)
				{
					uint[] registers = alloc::new_array(
						lowerer.allocator, uint, (sz)callee.alternatives.len
					);
					defer alloc::free(lowerer.allocator, registers);
					mitos::TypeId element_type = mitos::TYPE_ID_INVALID;
					foreach (index, alternative : callee.alternatives)
					{
						MirSubstitution alternative_substitution = {
							.parent = argument_scope,
							.hole = node.inputs[0],
							.value = alternative,
						};
						lowerer.substitution = &alternative_substitution;
						LoweredValue applied = lower_node(
							lowerer, node_id, scope, depth + 1
						);
						lowerer.substitution = base_substitution;
						if (lowerer.failed || applied.pending_effect) return applied;
						applied = materialize_runtime_value(
							lowerer, applied, depth + 1
						);
						if (lowerer.failed) return { };
						applied_alternatives[index] = applied;
						registers[index] = applied.register;
						mitos::TypeId applied_type = branch_runtime_type(
							lowerer, applied.type_id
						);
						if (element_type == mitos::TYPE_ID_INVALID)
						{
							element_type = applied_type;
						}
						else if (element_type != applied_type)
						{
							element_type = mitos::TYPE_ID_ANY;
						}
					}
					if (element_type == mitos::TYPE_ID_INVALID)
					{
						element_type = mitos::TYPE_ID_ANY;
					}
					mitos::TypeId distributed_type = intern_superposition_type(
						lowerer, element_type
					);
					if (lowerer.failed) return { };
					uint distributed = new_register(lowerer);
					emit(lowerer, {
						.opcode = SUPERPOSE,
						.destination = distributed,
						.b = (uint)distributed_type,
						.operand_start = append_operands(lowerer, registers),
						.operand_count = (uint)registers.len,
						.immediate = (long)alternatives_source.descriptor,
					});
					return {
						.register = distributed,
						.type_id = distributed_type,
						.alternatives = applied_alternatives,
						.alternatives_node = callee.alternatives_node,
					};
				}
				if (alternatives_source.kind
					!= mitos::DeltaNodeKind.DELTA_MATCH)
				{
					lowerer.fail("MIR closure alternatives have an unsupported source");
					return { };
				}
				uint distributed = new_register(lowerer);
				emit(lowerer, { .opcode = CONST, .destination = distributed });
				bool exhaustive = false;
				uint join = new_label(lowerer);
				mitos::TypeId distributed_type = mitos::TYPE_ID_ANY;
				foreach (branch_index, &branch : alternatives_source.branches)
				{
					(void)branch_index;
					uint next = 0;
					if (!branch.wildcard)
					{
						next = new_label(lowerer);
						uint condition = new_register(lowerer);
						emit(lowerer, {
							.opcode = TAG_EQUAL,
							.destination = condition,
							.a = callee.alternative_scrutinee,
							.b = constructor_index(branch.constructor),
						});
						emit(lowerer, {
							.opcode = BRANCH_FALSE, .a = condition, .b = next,
						});
					}
					MirSubstitution alternative_substitution = {
						.parent = argument_scope,
						.hole = node.inputs[0],
						.value = callee.alternatives[branch_index],
					};
					lowerer.substitution = &alternative_substitution;
					enter_materialization_scope(lowerer);
					LoweredValue applied = lower_node(
						lowerer, node_id, scope, depth + 1
					);
					if (!lowerer.failed && !applied.pending_effect)
					{
						applied = materialize_runtime_value(
							lowerer, applied, depth + 1
						);
					}
					leave_materialization_scope(lowerer);
					lowerer.substitution = base_substitution;
					if (lowerer.failed) return { };
					if (applied.pending_effect)
					{
						if (!branch.wildcard) emit(lowerer, {
							.opcode = LABEL, .a = next,
						});
						emit(lowerer, { .opcode = LABEL, .a = join });
						return applied;
					}
					applied_alternatives[branch_index] = applied;
					if (!branch_index)
					{
						distributed_type = applied.type_id;
					}
					else if (distributed_type != applied.type_id)
					{
						distributed_type = mitos::TYPE_ID_ANY;
					}
					emit(lowerer, {
						.opcode = MOVE,
						.destination = distributed,
						.a = applied.register,
					});
					emit(lowerer, { .opcode = JUMP, .a = join });
					if (!branch.wildcard) emit(lowerer, {
						.opcode = LABEL, .a = next,
					});
					if (branch.wildcard)
					{
						exhaustive = true;
						break;
					}
				}
				if (!exhaustive)
				{
					uint zero = new_register(lowerer);
					emit(lowerer, { .opcode = CONST, .destination = zero });
					uint trap = new_register(lowerer);
					emit(lowerer, {
						.opcode = DIVIDE, .destination = trap, .a = zero, .b = zero,
					});
					emit(lowerer, {
						.opcode = MOVE, .destination = distributed, .a = trap,
					});
				}
				emit(lowerer, { .opcode = LABEL, .a = join });
				return {
					.register = distributed,
					.type_id = distributed_type,
					.alternatives = applied_alternatives,
					.alternatives_node = callee.alternatives_node,
					.alternative_scrutinee = callee.alternative_scrutinee,
				};
			}
			if (static_callee
				&& static_callee.kind == mitos::DeltaNodeKind.DELTA_LAMBDA)
			{
				if (static_callee.names.len + 1 != node.inputs.len)
				{
					lowerer.fail("proven MIR closure application arity mismatch");
					return { };
				}
				uint[] direct_registers = alloc::new_array(
					lowerer.allocator, uint, (sz)static_callee.names.len
				);
				mitos::TypeId[] direct_types = alloc::new_array(
					lowerer.allocator, mitos::TypeId, (sz)static_callee.names.len
				);
				mitos::DeltaNodeId[] direct_closures = alloc::new_array(
					lowerer.allocator, mitos::DeltaNodeId, (sz)static_callee.names.len
				);
				MirScope*[] direct_closure_environments = alloc::new_array(
					lowerer.allocator, MirScope*, (sz)static_callee.names.len
				);
				LoweredValue[][] direct_fields = alloc::new_array(
					lowerer.allocator, LoweredValue[], (sz)static_callee.names.len
				);
				LoweredValue[] direct_values = alloc::new_array(
					lowerer.allocator, LoweredValue, (sz)static_callee.names.len
				);
				defer alloc::free(lowerer.allocator, direct_registers);
				defer alloc::free(lowerer.allocator, direct_types);
				defer alloc::free(lowerer.allocator, direct_closures);
				defer alloc::free(lowerer.allocator, direct_closure_environments);
				defer alloc::free(lowerer.allocator, direct_fields);
				defer alloc::free(lowerer.allocator, direct_values);
				bool direct_lifted = false;
				foreach (index, parameter : static_callee.names)
				{
					(void)parameter;
					LoweredValue argument = lower_node(
						lowerer, node.inputs[index + 1], scope, depth + 1
					);
					if (lowerer.failed || argument.pending_effect) return argument;
					mitos::TypeId expected = static_callee.types[index];
					mitos::TypeId actual_type = branch_runtime_type(
						lowerer, argument.type_id
					);
					direct_lifted = direct_lifted
						|| superposition_element_type(lowerer, argument.type_id, null);
					if (expected != mitos::TYPE_ID_ANY
						&& !mitos::type_is_subtype(
							&lowerer.source.types, actual_type, expected
						))
					{
						lowerer.fail(
							"TypeError: MIR closure argument violates its parameter type"
						);
						return { };
					}
					direct_registers[index] = argument.register;
					direct_types[index] = argument.type_id;
					direct_closures[index] = argument.closure_node;
					direct_closure_environments[index] = argument.closure_environment;
					direct_fields[index] = argument.fields;
					direct_values[index] = argument;
				}
				if (direct_lifted)
				{
					if (static_callee.effect_row.required.len
						|| static_callee.effect_row.has_tail)
					{
						return lower_effectful_lifted_lambda(
							lowerer,
							static_callee,
							static_environment,
							direct_registers,
							direct_types,
							direct_closures,
							direct_closure_environments,
							direct_fields,
							direct_values,
							0,
							node.span,
							depth + 1
						);
					}
					if (!callee.closure_node)
					{
						callee = lower_node(
							lowerer, node.inputs[0], scope, depth + 1
						);
						if (lowerer.failed || callee.pending_effect) return callee;
					}
					callee = materialize_runtime_value(
						lowerer, callee, depth + 1
					);
					if (lowerer.failed) return { };
					foreach (index, argument : direct_values)
					{
						argument = materialize_runtime_value(
							lowerer, argument, depth + 1
						);
						if (lowerer.failed) return { };
						direct_values[index] = argument;
						direct_registers[index] = argument.register;
					}
					mitos::TypeId concrete_result = node.result_type
						? node.result_type : static_callee.result_type;
					if (!concrete_result) concrete_result = mitos::TYPE_ID_ANY;
					concrete_result = static_lambda_result_type(
						lowerer, static_callee, concrete_result
					);
					mitos::TypeId lifted_result = intern_superposition_type(
						lowerer, concrete_result
					);
					if (lowerer.failed) return { };
					uint applied = new_register(lowerer);
					emit(lowerer, {
						.opcode = APPLY_FUNCTION,
						.destination = applied,
						.a = callee.register,
						.b = (uint)lifted_result,
						.operand_start = append_operands(lowerer, direct_registers),
						.operand_count = (uint)direct_registers.len,
					});
					return { .register = applied, .type_id = lifted_result };
				}
				MirScope direct_scope = {
					.parent = static_environment,
					.names = static_callee.names,
					.types = direct_types,
					.registers = direct_registers,
					.closure_nodes = direct_closures,
					.closure_environments = direct_closure_environments,
					.fields = direct_fields,
					.values = direct_values,
				};
				LoweredValue direct = lower_node(
					lowerer, static_callee.inputs[0], &direct_scope, depth + 1
				);
				return assert_runtime_type(
					lowerer,
					direct,
					static_callee.result_type
						? static_callee.result_type : mitos::TYPE_ID_ANY,
					node.span,
					depth + 1
				);
			}
			bool lifted = superposition_element_type(lowerer, callee.type_id, null);
			mitos::TypeId callee_type = branch_runtime_type(lowerer, callee.type_id);
			mitos::TypeDescriptor* callee_descriptor = mitos::type_descriptor(
				&lowerer.source.types, callee_type
			);
			if (!callee_descriptor
				|| callee_descriptor.kind
					!= mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
			{
				lowerer.fail(
					"MIR closure application has unresolved dynamic provenance or a non-function callee"
				);
				return { };
			}
			if (callee_descriptor.function_effects.required.len
				|| callee_descriptor.function_effects.has_tail)
			{
				lowerer.fail(
					"effect-capable MIR closure application has unresolved lexical provenance"
				);
				return { };
			}
			callee = materialize_runtime_value(lowerer, callee, depth + 1);
			if (lowerer.failed) return { };
			uint[] arguments = alloc::new_array(
				lowerer.allocator, uint, (sz)node.inputs.len - 1
			);
			defer alloc::free(lowerer.allocator, arguments);
			for (usz index = 1; index < node.inputs.len; index++)
			{
				LoweredValue argument = lower_node(
					lowerer, node.inputs[index], scope, depth + 1
				);
				if (lowerer.failed || argument.pending_effect) return argument;
				argument = materialize_runtime_value(
					lowerer, argument, depth + 1
				);
				if (lowerer.failed) return { };
				arguments[index - 1] = argument.register;
				lifted = lifted || superposition_element_type(
					lowerer, argument.type_id, null
				);
			}
			mitos::TypeId concrete_result = node.result_type
				? node.result_type : mitos::TYPE_ID_ANY;
			if (concrete_result == mitos::TYPE_ID_ANY
				&& callee_descriptor && callee_descriptor.function_result)
			{
				concrete_result = callee_descriptor.function_result;
			}
			mitos::TypeId application_type = lifted
				? intern_superposition_type(lowerer, concrete_result) : concrete_result;
			if (lowerer.failed) return { };
			uint applied = new_register(lowerer);
			emit(lowerer, {
				.opcode = APPLY_FUNCTION,
				.destination = applied,
				.a = callee.register,
				.b = lifted ? (uint)application_type : 0,
				.operand_start = append_operands(lowerer, arguments),
				.operand_count = (uint)arguments.len,
			});
			return { .register = applied, .type_id = application_type };
		default:
			lowerer.fail("MIR JIT encountered an unsupported Delta node kind");
			return { };
	}
}
fn bool initialize_type_metadata(DeltaMirLowerer* lowerer)
{
	usz type_count = (usz)lowerer.source.types.descriptors.len();
	lowerer.types = alloc::new_array(lowerer.allocator, mitos_mir::MirType, (sz)type_count);
	lowerer.layouts = alloc::new_array(
		lowerer.allocator, mitos_mir::MirLayout, (sz)type_count
	);
	mitos::TypeId[] reflected_types = alloc::new_array(
		lowerer.allocator, mitos::TypeId, (sz)type_count
	);
	defer alloc::free(lowerer.allocator, reflected_types);
	foreach (&descriptor : lowerer.source.types.descriptors)
	{
		if (descriptor.constructor != mitos::TYPE_ID_TYPE
			|| descriptor.arguments.len != 1) continue;
		mitos::TypeId represented = descriptor.arguments[0];
		if (!represented || (usz)represented > type_count
			|| reflected_types[(sz)represented - 1]) continue;
		reflected_types[(sz)represented - 1] = descriptor.id;
	}
	foreach (index, &descriptor : lowerer.source.types.descriptors)
	{
		mitos::TypeId type_value_runtime = reflected_types[index]
			? reflected_types[index] : mitos::TYPE_ID_TYPE;
		String canonical_name = mitos::format_type(
			&lowerer.source.types, descriptor.id, lowerer.allocator
		);
		lowerer.type_names.push(canonical_name);
		lowerer.types[index] = {
			.id = (uint)descriptor.id,
			.parent = (uint)descriptor.nominal_parent,
			.type_value_runtime = (uint)type_value_runtime,
			.kind = (uint)descriptor.kind,
			.name = canonical_name.ptr,
			.name_length = canonical_name.len,
			.constructor = (uint)descriptor.constructor,
			.argument = descriptor.arguments.len ? (uint)descriptor.arguments[0] : 0,
		};
		lowerer.layouts[index] = {
			.type_id = (uint)descriptor.id,
			.kind = (uint)descriptor.layout.kind,
			.copy_policy = (uint)descriptor.layout.copy_policy,
			.flags = descriptor.layout.sized ? 1u : 0u,
			.size = descriptor.layout.size,
			.alignment = descriptor.layout.alignment,
			.stride = descriptor.layout.stride,
			.element_type = (uint)descriptor.layout.element_type,
		};
	}
	return true;
}

fn bool initialize_metadata(DeltaMirLowerer* lowerer)
{
	usz constructor_count = lowerer.source.constructors.len + 3;
	if (constructor_count > (usz)uint::max)
	{
		lowerer.fail("MIR constructor table exceeds the ABI limit");
		return false;
	}
	lowerer.constructors = alloc::new_array(
		lowerer.allocator, mitos_mir::MirConstructor, (sz)constructor_count
	);
	lowerer.constructors[0] = {
		.tag = 0, .arity = 0, .runtime_type = (uint)mitos::TYPE_ID_BOOL,
		.name = "False".ptr, .name_length = "False".len,
	};
	lowerer.constructors[1] = {
		.tag = 1, .arity = 0, .runtime_type = (uint)mitos::TYPE_ID_BOOL,
		.name = "True".ptr, .name_length = "True".len,
	};
	lowerer.constructors[2] = {
		.tag = 2, .arity = 0, .runtime_type = (uint)mitos::TYPE_ID_UNIT,
		.name = "()".ptr, .name_length = "()".len,
	};
	foreach (index, &constructor : lowerer.source.constructors)
	{
		if (constructor.fields.len > (usz)uint::max)
		{
			lowerer.fail("MIR constructor arity exceeds the ABI limit");
			return false;
		}
		mitos::TypeId constructor_type = constructor.runtime_type
			? constructor.runtime_type : constructor.type_constructor;
		lowerer.constructors[(sz)index + 3] = {
			.tag = (uint)index + 3,
			.arity = (uint)constructor.fields.len,
			.runtime_type = (uint)constructor_type,
			.name = constructor.name.ptr,
			.name_length = constructor.name.len,
		};
	}
	lowerer.effect_operations = alloc::new_array(
		lowerer.allocator,
		mitos_mir::MirEffectOperation,
		(sz)lowerer.source.effects.operations.len
	);
	foreach (index, &operation : lowerer.source.effects.operations)
	{
		lowerer.effect_operations[index] = {
			.dense_handle = (uint)index,
			.effect = (uint)operation.effect,
			.operation = (uint)operation.id,
			.arity = (uint)operation.parameter_types.len,
			.result_type = (uint)mitos::TYPE_ID_ANY,
			.abi_major = lowerer.source.helper_abi.major,
			.abi_minor = lowerer.source.helper_abi.minor,
			.flags = (operation.ordered ? 1u : 0u)
				| (operation.host_kind
					== mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL ? 2u : 0u),
		};
	}
	return true;
}

fn bool reject_pending_effect(DeltaMirLowerer* lowerer, LoweredValue value)
{
	if (!value.pending_effect) return false;
	lowerer.fail("unhandled effect request reached MIR JIT");
	return true;
}


fn LoweredValue materialize_external_effect(
	DeltaMirLowerer* lowerer,
	LoweredValue request
)
{
	if (!request.pending_effect || request.effect_operation >= lowerer.source.effects.operations.len)
	{
		return request;
	}
	mitos::DeltaOperationDescriptor* operation =
		&lowerer.source.effects.operations[request.effect_operation];
	if (operation.host_kind != mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL)
	{
		return request;
	}
	uint[] arguments = alloc::new_array(
		lowerer.allocator,
		uint,
		(sz)request.effect_arguments.len
	);
	defer alloc::free(lowerer.allocator, arguments);
	bool lifted = false;
	foreach (index, argument : request.effect_arguments)
	{
		argument = materialize_runtime_value(lowerer, argument, 0);
		if (lowerer.failed) return { };
		arguments[index] = argument.register;
		lifted = lifted || superposition_element_type(
			lowerer, argument.type_id, null
		);
	}
	mitos::DeltaNode* effect_node = mitos::delta_node(lowerer.source, request.effect_node);
	mitos::TypeId result_type = effect_node && effect_node.result_type
		? effect_node.result_type : mitos::TYPE_ID_ANY;
	mitos::TypeId lowered_result_type = lifted
		? intern_superposition_type(lowerer, result_type) : result_type;
	if (lowerer.failed) return { };
	mitos::EffectId effect = effect_node ? (mitos::EffectId)effect_node.integer : operation.effect;
	ulong packed = ((ulong)effect << 32) | (ulong)(uint)result_type;
	uint destination = new_register(lowerer);
	emit(lowerer, {
		.opcode = EXTERNAL_EFFECT,
		.destination = destination,
		.a = (uint)request.effect_operation,
		.b = (uint)request.effect_source_order,
		.operand_start = append_operands(lowerer, arguments),
		.operand_count = (uint)arguments.len,
		.immediate = (long)packed,
	});
	return { .register = destination, .type_id = lowered_result_type };
}

fn void free_method_instances(DeltaMirLowerer* lowerer)
{
	foreach (&instance : lowerer.instances)
	{
		alloc::free(lowerer.allocator, instance.concrete_types);
		alloc::free(lowerer.allocator, instance.type_bindings);
		if (instance.method_index == usz::max)
		{
			alloc::free(lowerer.allocator, instance.parameters);
		}
	}
	lowerer.instances.free();
}

fn void free_lowerer_analysis(DeltaMirLowerer* lowerer)
{
	foreach (lazy : lowerer.lazy_materializations)
	{
		alloc::free(lowerer.allocator, lazy);
	}
	lowerer.lazy_materializations.free();
	lowerer.materialization_path.free();
	alloc::free(lowerer.allocator, lowerer.effect_scan);
	alloc::free(lowerer.allocator, lowerer.closure_type_scan);
	alloc::free(lowerer.allocator, lowerer.effectful_lambda_scan);
	alloc::free(lowerer.allocator, lowerer.instance_slots);
}

fn void free_effect_argument_sets(DeltaMirLowerer* lowerer)
{
	foreach (arguments : lowerer.effect_argument_sets)
	{
		alloc::free(lowerer.allocator, arguments);
	}
	lowerer.effect_argument_sets.free();
}

fn void free_provenance_field_sets(DeltaMirLowerer* lowerer)
{
	foreach (fields : lowerer.provenance_field_sets)
		alloc::free(lowerer.allocator, fields);
	lowerer.provenance_field_sets.free();
}

fn void free_provenance_scopes(DeltaMirLowerer* lowerer)
{
	foreach (scope : lowerer.provenance_scopes)
	{
		alloc::free(lowerer.allocator, scope.names);
		alloc::free(lowerer.allocator, scope.types);
		alloc::free(lowerer.allocator, scope.registers);
		alloc::free(lowerer.allocator, scope.closure_nodes);
		alloc::free(lowerer.allocator, scope.closure_environments);
		alloc::free(lowerer.allocator, scope.fields);
		alloc::free(lowerer.allocator, scope.values);
		alloc::free(lowerer.allocator, scope);
	}
	lowerer.provenance_scopes.free();
}

fn usz entry_source_order(mitos::DeltaProgram* program)
{
	foreach (&root_interface : program.image.interfaces)
	{
		if (root_interface.root == program.entry) return root_interface.source_order;
	}
	return 0;
}

fn uint declared_root_count(mitos::DeltaProgram* program)
{
	usz count = program.image.interfaces.len;
	foreach (&region : program.image.parallel_regions) count += region.roots.len;
	return (uint)count;
}
fn uint declared_max_source_order(mitos::DeltaProgram* program)
{
	usz maximum = 0;
	foreach (&root_interface : program.image.interfaces)
	{
		if (root_interface.source_order > maximum)
		{
			maximum = root_interface.source_order;
		}
	}
	foreach (&method_root : program.method_roots)
	{
		if (method_root.source_order > maximum) maximum = method_root.source_order;
	}
	foreach (&region : program.image.parallel_regions)
	{
		foreach (root_id : region.roots)
		{
			mitos::DeltaNode* root = mitos::delta_node(program, root_id);
			if (root && root.descriptor > maximum) maximum = root.descriptor;
		}
	}
	return maximum > (usz)uint::max ? uint::max : (uint)maximum;
}


fn bool lower_functions(DeltaMirLowerer* lowerer, uint* main_function)
{
	lowerer.functions.push({ });
	*main_function = 0;
	lowerer.next_register = 0;
	lowerer.next_label = 0;
	lowerer.substitution = null;
	lowerer.activation = null;
	lowerer.method_activation = null;
	lowerer.current_source_order = entry_source_order(lowerer.source);
	lowerer.current_parallel_source = false;
	reset_materialization_scope(lowerer);
	uint instruction_start = (uint)lowerer.instructions.size;
	LoweredValue entry = lower_node(lowerer, lowerer.source.entry, null, 0);
	if (lowerer.failed) return false;
	if (entry.pending_effect) entry = materialize_external_effect(lowerer, entry);
	if (lowerer.failed || reject_pending_effect(lowerer, entry)) return false;
	entry = materialize_runtime_value(lowerer, entry, 0);
	if (lowerer.failed) return false;
	emit(lowerer, { .opcode = RETURN, .a = entry.register });
	lowerer.functions[0] = {
		.register_count = lowerer.next_register,
		.instruction_start = instruction_start,
		.instruction_count = (uint)lowerer.instructions.size - instruction_start,
	};
	for (usz instance_index = 0; instance_index < (usz)lowerer.instances.size; instance_index++)
	{
		MirMethodInstance* instance = &lowerer.instances[(sz)instance_index];
		uint function_index = instance.function_index;
		usz source_order = instance.source_order;
		bool parallel_source = instance.parallel_source;
		String[] parameters = instance.parameters;
		mitos::TypeId[] concrete_types = instance.concrete_types;
		String[] type_variables = instance.type_variables;
		mitos::TypeId[] type_bindings = instance.type_bindings;
		mitos::TypeId result_type = instance.result_type;
		usz generic_index = instance.generic_index;
		usz method_index = instance.method_index;
		mitos::DeltaNodeId body = instance.root;
		if (parameters.len > (usz)JIT_MAX_REGISTERS
			|| parameters.len != concrete_types.len
			|| type_variables.len != type_bindings.len)
		{
			lowerer.fail("MIR function instance has inconsistent parameter metadata");
			return false;
		}
		lowerer.substitution = null;
		lowerer.activation = null;
		MirMethodActivation method_activation = {
			.generic_index = generic_index,
			.method_index = method_index,
			.concrete_types = concrete_types,
			.function_index = function_index,
		};
		lowerer.method_activation = method_index == usz::max
			? null : &method_activation;
		lowerer.current_source_order = source_order;
		lowerer.current_parallel_source = parallel_source;
		reset_materialization_scope(lowerer);
		lowerer.next_register = (uint)parameters.len;
		lowerer.next_label = 0;
		instruction_start = (uint)lowerer.instructions.size;
		uint[] registers = alloc::new_array(lowerer.allocator, uint, (sz)parameters.len);
		foreach (index, parameter : parameters)
		{
			(void)parameter;
			registers[index] = (uint)index;
		}
		MirScope parameter_scope = {
			.names = parameters,
			.types = concrete_types,
			.registers = registers,
		};
		uint[] type_registers = alloc::new_array(
			lowerer.allocator, uint, (sz)type_bindings.len
		);
		mitos::TypeId[] type_runtime_types = alloc::new_array(
			lowerer.allocator, mitos::TypeId, (sz)type_bindings.len
		);
		if (!materialize_type_binding_locals(
			lowerer, type_bindings, type_registers, type_runtime_types
		))
		{
			alloc::free(lowerer.allocator, registers);
			alloc::free(lowerer.allocator, type_registers);
			alloc::free(lowerer.allocator, type_runtime_types);
			return false;
		}
		MirScope type_scope = {
			.parent = &parameter_scope,
			.names = type_variables,
			.types = type_runtime_types,
			.registers = type_registers,
		};
		LoweredValue result = lower_node(lowerer, body, &type_scope, 0);
		alloc::free(lowerer.allocator, type_registers);
		alloc::free(lowerer.allocator, type_runtime_types);
		alloc::free(lowerer.allocator, registers);
		if (lowerer.failed) return false;
		if (result.pending_effect) result = materialize_external_effect(lowerer, result);
		if (lowerer.failed) return false;
		if (result.pending_effect)
		{
			lowerer.fail("effectful MIR method instance escaped its effect-capable call site");
			return false;
		}
		if (result_type != mitos::TYPE_ID_ANY)
		{
			result = assert_runtime_type(lowerer, result, result_type, 0, 0);
			if (lowerer.failed) return false;
		}
		result = materialize_runtime_value(lowerer, result, 0);
		if (lowerer.failed) return false;
		emit(lowerer, { .opcode = RETURN, .a = result.register });
		lowerer.functions[(sz)function_index] = {
			.parameter_count = (uint)parameters.len,
			.register_count = lowerer.next_register,
			.instruction_start = instruction_start,
			.instruction_count = (uint)lowerer.instructions.size - instruction_start,
		};
	}
	return true;
}

fn MitosMirLowerResult lower_delta_program_to_mir(
	mitos::DeltaProgram* program,
	Allocator allocator = mem
)
{
	if (!program)
	{
		return {
			.allocator = allocator,
			.diagnostic = "MIR lowering requires a DeltaProgram".copy(allocator),
		};
	}
	if (program.feature_manifest.required & mitos::DELTA_FEATURE_SUSPENSION)
	{
		return {
			.allocator = allocator,
			.diagnostic = "MIR backend does not support resumable host suspension; use generic Delta execution".copy(allocator),
		};
	}
	if (program.feature_manifest.required
		& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES)
	{
		return {
			.allocator = allocator,
			.diagnostic = "MIR backend does not support dynamic effectful closures; use generic Delta execution".copy(allocator),
		};
	}
	if (!mir_supports_required_features(program)
		|| !mitos::delta_program_is_compatible(
			program,
			MIR_SUPPORTED_DELTA_FEATURES
		) || !program.entry)
	{
		return {
			.allocator = allocator,
			.diagnostic = "MIR lowering requires a compatible, complete DeltaProgram".copy(allocator),
		};
	}
	if (!program.effects.epoch)
	{
		return {
			.allocator = allocator,
			.diagnostic = "MIR lowering requires a current effect metadata epoch".copy(allocator),
		};
	}
	foreach (&row : program.effects.rows)
	{
		if (row.effect_epoch != program.effects.epoch)
		{
			return {
				.allocator = allocator,
				.diagnostic = "MIR lowering rejected a stale method effect epoch".copy(allocator),
			};
		}
	}
	DeltaMirLowerer lowerer = {
		.allocator = allocator,
		.source = program,
	};
	lowerer.functions.init(allocator);
	lowerer.instances.init(allocator);
	lowerer.instructions.init(allocator);
	lowerer.operands.init(allocator);
	lowerer.effect_argument_sets.init(allocator);
	lowerer.provenance_field_sets.init(allocator);
	lowerer.provenance_scopes.init(allocator);
	lowerer.strings.init(allocator);
	lowerer.type_names.init(allocator);
	lowerer.match_arms.init(allocator);
	lowerer.lazy_materializations.init(allocator);
	lowerer.materialization_path.init(allocator);
	lowerer.effect_scan = alloc::new_array(
		allocator, char, (sz)program.image.nodes.len
	);
	lowerer.closure_type_scan = alloc::new_array(
		allocator, char, (sz)program.types.descriptors.len()
	);
	lowerer.effectful_lambda_scan = alloc::new_array(
		allocator, char, (sz)program.image.nodes.len
	);
	foreach (&state : lowerer.effect_scan) *state = 0;
	foreach (&state : lowerer.closure_type_scan) *state = 0;
	foreach (&state : lowerer.effectful_lambda_scan) *state = 0;
	uint main_function;
	if (!initialize_metadata(&lowerer) || !lower_functions(&lowerer, &main_function)
		|| !initialize_type_metadata(&lowerer))
	{
		String message = lowerer.diagnostic.len
			? lowerer.diagnostic : "MIR Delta lowering failed".copy(allocator);
		foreach (name : lowerer.type_names) alloc::free(allocator, name);
		lowerer.type_names.free();
		lowerer.instructions.free();
		lowerer.operands.free();
		lowerer.strings.free();
		lowerer.match_arms.free();
		free_effect_argument_sets(&lowerer);
		free_provenance_field_sets(&lowerer);
		free_provenance_scopes(&lowerer);
		lowerer.functions.free();
		free_method_instances(&lowerer);
		free_lowerer_analysis(&lowerer);
		alloc::free(allocator, lowerer.constructors);
		alloc::free(allocator, lowerer.types);
		alloc::free(allocator, lowerer.layouts);
		alloc::free(allocator, lowerer.effect_operations);
		return { .allocator = allocator, .diagnostic = message };
	}
	mitos_mir::MirSpan[] spans = alloc::new_array(
		allocator, mitos_mir::MirSpan, (sz)program.spans.len
	);
	foreach (index, span : program.spans)
	{
		spans[index] = {
			.start_offset = (ulong)span.start.offset,
			.start_row = (ulong)span.start.row,
			.start_column = (ulong)span.start.column,
			.end_offset = (ulong)span.end.offset,
			.end_row = (ulong)span.end.row,
			.end_column = (ulong)span.end.column,
		};
	}
	OwnedMirProgram owned = {
		.allocator = allocator,
		.program_identity = program.runtime_identity,
		.functions = lowerer.functions.to_array(allocator),
		.instructions = lowerer.instructions.to_array(allocator),
		.operands = lowerer.operands.to_array(allocator),
		.constructors = lowerer.constructors,
		.types = lowerer.types,
		.layouts = lowerer.layouts,
		.type_names = lowerer.type_names.to_array(allocator),
		.strings = lowerer.strings.to_array(allocator),
		.effect_operations = lowerer.effect_operations,
		.match_arms = lowerer.match_arms.to_array(allocator),
		.spans = spans,
		.main_function = main_function,
		.phase_one_root_count = declared_root_count(program),
		.max_source_order = declared_max_source_order(program),
	};
	lowerer.instructions.free();
	lowerer.functions.free();
	lowerer.operands.free();
	lowerer.strings.free();
	lowerer.type_names.free();
	lowerer.match_arms.free();
	free_method_instances(&lowerer);
	free_effect_argument_sets(&lowerer);
	free_provenance_field_sets(&lowerer);
	free_provenance_scopes(&lowerer);
	free_lowerer_analysis(&lowerer);
	return { .allocator = allocator, .program = owned };
}

fn mitos_mir::MirHostDisposition mir_console_host(
	mitos_mir::MirHostCall* call,
	void* ignored
)
{
	(void)ignored;
	if (!call || call.abi_major != 2 || call.abi_minor != 0
		|| call.argument_count != 1 || !call.arguments
		|| call.arguments[0].kind != 3
		|| (!call.arguments[0].string && call.arguments[0].string_length))
	{
		if (call)
		{
			call.diagnostic = "Console.print requires one String argument".ptr;
			call.diagnostic_length =
				"Console.print requires one String argument".len;
		}
		return mitos_mir::MirHostDisposition.HOST_FAIL;
	}
	String text = (String)call.arguments[0].string[
		0..call.arguments[0].string_length
	];
	io::printn(text);
	call.result = {
		.kind = 2,
		.type_id = (uint)mitos::TYPE_ID_UNIT,
	};
	return mitos_mir::MirHostDisposition.HOST_READY;
}

fn bool exact_standard_type_pattern(
	mitos::TypePattern* pattern,
	mitos::TypeId expected
)
{
	return pattern && pattern.kind == mitos::TypePatternKind.TYPE_PATTERN_EXACT
		&& pattern.constructor == expected && !pattern.variable.len
		&& !pattern.arguments.len;
}

fn bool standard_mir_helpers_enroll(
	mitos_mir::MirRuntime* runtime,
	mitos_mir::MirProgram* bridge_program,
	mitos::DeltaProgram* source,
	uint[] enrolled_handles,
	usz* enrolled_count
)
{
	if (!runtime || !bridge_program || !source || !enrolled_count
		|| enrolled_handles.len < source.effects.operations.len) return false;
	foreach (operation_index, &operation : source.effects.operations)
	{
		if (operation.host_kind
			!= mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL) continue;
		if (operation.name != "print"
			|| operation.parameter_types.len != 1
			|| !exact_standard_type_pattern(
				&operation.parameter_types[0], mitos::TYPE_ID_STRING
			)
			|| !exact_standard_type_pattern(
				&operation.result_type, mitos::TYPE_ID_UNIT
			)
			|| !mitos::symbol_key_is_canonical(&operation.key)
			|| operation.key.kind
				!= mitos::SymbolKind.SYMBOL_EFFECT_OPERATION
			|| operation.key.name != "print" || operation.key.arity != 1)
		{
			return false;
		}
		bool console = false;
		foreach (&effect : source.effects.effects)
		{
			if (effect.id == operation.effect && effect.name == "Console"
				&& !effect.parameters.len
				&& mitos::symbol_key_is_canonical(&effect.key)
				&& effect.key.kind == mitos::SymbolKind.SYMBOL_EFFECT
				&& effect.key.name == "Console" && !effect.key.arity
				&& mitos::module_key_equal(
					&effect.key.owner, &operation.key.owner
				))
			{
				console = true;
				break;
			}
		}
		if (!console) return false;
		if (!runtime.register_host_helper(
			bridge_program, (uint)operation_index, &mir_console_host
		)) return false;
		enrolled_handles[*enrolled_count] = (uint)operation_index;
		*enrolled_count += 1;
	}
	return true;
}

fn void standard_mir_helpers_withdraw(
	mitos_mir::MirRuntime* runtime,
	mitos_mir::MirProgram* bridge_program,
	uint[] enrolled_handles,
	usz enrolled_count
)
{
	if (!runtime || !bridge_program) return;
	foreach (dense_handle : enrolled_handles[:(sz)enrolled_count])
	{
		(void)runtime.unregister_host_helper(bridge_program, dense_handle);
	}
}
fn MitosJitResult jit_delta_program(
	mitos::DeltaProgram* program,
	Allocator allocator = mem,
	mitos_mir::MirRuntime* mir_runtime = null
)
{
	MitosMirLowerResult lowered = lower_delta_program_to_mir(
		program, allocator
	);
	defer lowered.free();
	if (!lowered.ok()) return {
		.status = ERROR, .diagnostic = lowered.diagnostic.copy(allocator), .allocator = allocator,
	};
	mitos_mir::MirRuntime local_mir_runtime;
	bool owns_mir_runtime = mir_runtime == null;
	if (owns_mir_runtime)
	{
		local_mir_runtime.init();
		mir_runtime = &local_mir_runtime;
	}
	defer if (owns_mir_runtime) (void)local_mir_runtime.free();
	if (!mir_runtime.ready()) return {
		.status = ERROR,
		.diagnostic = "MIR runtime initialization failed".copy(allocator),
		.allocator = allocator,
	};
	mitos_mir::MirProgram bridge_program = lowered.program.view();
	uint[] console_handles = alloc::new_array(
		allocator, uint, (sz)program.effects.operations.len
	);
	defer alloc::free(allocator, console_handles);
	usz console_handle_count = 0;
	defer standard_mir_helpers_withdraw(
		mir_runtime, &bridge_program, console_handles, console_handle_count
	);
	if (!standard_mir_helpers_enroll(
		mir_runtime,
		&bridge_program,
		program,
		console_handles,
		&console_handle_count
	))
	{
		return {
			.status = ERROR,
			.diagnostic =
				"standard MIR helpers require every external operation to be canonical Console.print".copy(allocator),
			.allocator = allocator,
		};
	}
	mitos_mir::MirExecutionResult native = mitos_mir::execute(
		mir_runtime, &bridge_program, allocator
	);
	MitosJitResult result = {
		.status = native.status,
		.result = native.result,
		.diagnostic = native.diagnostic,
		.diagnostic_span = native.diagnostic_span,
		.native_instruction_count = bridge_program.instruction_count,
		.allocator = allocator,
	};
	native.result = { };
	native.diagnostic = { };
	native.allocator = { };
	return result;
}
