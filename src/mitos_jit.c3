module delta_net_abstract_machine::mitos_jit;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_mir;
import delta_net_abstract_machine::mitos_specialization;
import std::collections::list;

const uint JIT_MAX_REGISTERS    = 65_536;
const uint JIT_MAX_INSTRUCTIONS = 1_000_000;
const uint JIT_MAX_OPERANDS     = 4_000_000;
const uint JIT_MAX_DEPTH        = 1_024;
const usz JIT_MAX_SUPERPOSE_BRANCHES = 65_536;

struct MirScope
{
	MirScope* parent;
	String[] names;
	mitos::TypeId[] types;
	uint[] registers;
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

struct LoweredValue
{
	uint register;
	mitos::TypeId type_id;
	bool pending_effect;
	usz effect_operation;
	mitos::DeltaNodeId effect_node;
	ulong effect_epoch;
	LoweredValue[] effect_arguments;
}

struct MirMethodInstance
{
	mitos::DeltaNodeId root;
	String[] parameters;
	usz generic_index;
	usz method_index;
	mitos::TypeId[] concrete_types;
	uint function_index;
	bool lowered;
}

struct DeltaMirLowerer
{
	Allocator allocator;
	mitos::DeltaProgram* source;
	mitos_specialization::SpecializationCache* cache;
	List{mitos_mir::MirFunction} functions;
	mitos_mir::MirConstructor[] constructors;
	mitos_mir::MirType[] types;
	List{mitos_mir::MirInstruction} instructions;
	List{uint} operands;
	uint next_register;
	uint next_label;
	bool failed;
	String diagnostic;
	MirSubstitution* substitution;
	MirHandlerActivation* activation;
	List{LoweredValue[]} effect_argument_sets;
	List{mitos_mir::MirString} strings;
	List{void*} native_methods;
	mitos_mir::MirEffectOperation[] effect_operations;
	List{MirMethodInstance} instances;
	List{String} type_names;
	List{mitos_mir::MirMatchArm} match_arms;
}

struct OwnedMirProgram
{
	Allocator allocator;
	mitos_mir::MirFunction[] functions;
	mitos_mir::MirInstruction[] instructions;
	uint[] operands;
	mitos_mir::MirConstructor[] constructors;
	mitos_mir::MirType[] types;
	String[] type_names;
	uint main_function;
	uint phase_one_root_count;
	mitos_mir::MirString[] strings;
	void*[] native_methods;
	mitos_mir::MirEffectOperation[] effect_operations;
	mitos_mir::MirMatchArm[] match_arms;
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
	uint native_instruction_count;
	uint specialized_method_count;
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
	alloc::free(self.allocator, self.strings);
	alloc::free(self.allocator, self.native_methods);
	alloc::free(self.allocator, self.effect_operations);
	alloc::free(self.allocator, self.match_arms);
	*self = { };
}

fn mitos_mir::MirProgram OwnedMirProgram.view(&self)
{
	return {
		.functions = self.functions.ptr,
		.instructions = self.instructions.ptr,
		.operands = self.operands.ptr,
		.constructors = self.constructors.ptr,
		.types = self.types.ptr,
		.strings = self.strings.ptr,
		.effect_operations = self.effect_operations.ptr,
		.native_methods = self.native_methods.ptr,
		.match_arms = self.match_arms.ptr,
		.function_count = (uint)self.functions.len,
		.instruction_count = (uint)self.instructions.len,
		.operand_count = (uint)self.operands.len,
		.constructor_count = (uint)self.constructors.len,
		.type_count = (uint)self.types.len,
		.string_count = (uint)self.strings.len,
		.effect_operation_count = (uint)self.effect_operations.len,
		.native_method_count = (uint)self.native_methods.len,
		.match_arm_count = (uint)self.match_arms.len,
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

fn bool find_binding(MirScope* scope, String name, LoweredValue* result)
{
	for (MirScope* current = scope; current; current = current.parent)
	{
		foreach (index, candidate : current.names)
		{
			if (candidate != name) continue;
			*result = { .register = current.registers[index], .type_id = current.types[index] };
			return true;
		}
	}
	return false;
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
	usz generic_index,
	usz method_index
)
{
	foreach (&root : lowerer.source.method_roots)
	{
		if (root.generic_index == generic_index && root.method_index == method_index) return root;
	}
	return null;
}

fn uint reserve_method_instance(
	DeltaMirLowerer* lowerer,
	usz generic_index,
	usz method_index,
	mitos::TypeId[] concrete_types
)
{
	foreach (&instance : lowerer.instances)
	{
		if (instance.generic_index != generic_index || instance.method_index != method_index
			|| instance.concrete_types.len != concrete_types.len) continue;
		bool matches = true;
		foreach (index, type_id : concrete_types)
		{
			if (instance.concrete_types[index] == type_id) continue;
			matches = false;
			break;
		}
		if (matches) return instance.function_index;
	}
	if (lowerer.functions.size >= (sz)JIT_MAX_INSTRUCTIONS)
	{
		lowerer.fail("MIR method-instance table exceeds the production limit");
		return 0;
	}
	uint function_index = (uint)lowerer.functions.size;
	lowerer.functions.push({ });
	lowerer.instances.push({
		.generic_index = generic_index,
		.method_index = method_index,
		.concrete_types = alloc::clone_slice(lowerer.allocator, concrete_types),
		.function_index = function_index,
	});
	return function_index;
}

fn bool method_has_effects(DeltaMirLowerer* lowerer, usz function_index)
{
	foreach (&row : lowerer.source.effects.rows)
	{
		if (row.function_index == function_index) return row.inferred.len != 0;
	}
	return false;
}
fn bool delta_graph_has_effect(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNodeId node_id,
	uint depth
)
{
	if (depth >= JIT_MAX_DEPTH) return true;
	mitos::DeltaNode* node = mitos::delta_node(lowerer.source, node_id);
	if (!node) return true;
	if (node.kind == mitos::DeltaNodeKind.DELTA_EFFECT) return true;
	foreach (input : node.inputs)
	{
		if (delta_graph_has_effect(lowerer, input, depth + 1)) return true;
	}
	foreach (&branch : node.branches)
	{
		if (delta_graph_has_effect(lowerer, branch.body, depth + 1)) return true;
	}
	return false;
}


fn uint reserve_parallel_instance(
	DeltaMirLowerer* lowerer,
	mitos::DeltaNodeId root,
	MirScope* scope,
	uint[]* captured_registers,
	mitos::TypeId[]* captured_types
)
{
	List{String} names; names.init(lowerer.allocator); defer names.free();
	List{mitos::TypeId} types; types.init(lowerer.allocator); defer types.free();
	List{uint} registers; registers.init(lowerer.allocator); defer registers.free();
	for (MirScope* current = scope; current; current = current.parent)
	{
		foreach (index, name : current.names)
		{
			bool shadowed = false;
			foreach (existing : names)
			{
				if (existing == name) { shadowed = true; break; }
			}
			if (shadowed) continue;
			names.push(name);
			types.push(current.types[index]);
			registers.push(current.registers[index]);
		}
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
	MirScope* scope,
	uint[]* captured_registers,
	mitos::TypeId[]* captured_types
)
{
	List{String} names; names.init(lowerer.allocator); defer names.free();
	List{mitos::TypeId} types; types.init(lowerer.allocator); defer types.free();
	List{uint} captures; captures.init(lowerer.allocator); defer captures.free();
	List{mitos::TypeId} capture_types; capture_types.init(lowerer.allocator); defer capture_types.free();
	foreach (index, name : parameter_names)
	{
		names.push(name);
		types.push(parameter_types[index]);
	}
	for (MirScope* current = scope; current; current = current.parent)
	{
		foreach (index, name : current.names)
		{
			bool shadowed = false;
			foreach (existing : names)
			{
				if (existing == name) { shadowed = true; break; }
			}
			if (shadowed) continue;
			names.push(name);
			types.push(current.types[index]);
			captures.push(current.registers[index]);
			capture_types.push(current.types[index]);
		}
	}
	uint function_index = (uint)lowerer.functions.size;
	lowerer.functions.push({ });
	lowerer.instances.push({
		.method_index = usz::max,
		.root = root,
		.parameters = names.to_array(lowerer.allocator),
		.concrete_types = types.to_array(lowerer.allocator),
		.function_index = function_index,
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
		scope,
		captured_registers,
		captured_types
	);
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
	bool lifted = false;
	defer alloc::free(lowerer.allocator, registers);
	defer alloc::free(lowerer.allocator, actual);
	defer alloc::free(lowerer.allocator, argument_types);
	foreach (index, input : node.inputs)
	{
		LoweredValue argument = lower_node(lowerer, input, scope, depth + 1);
		if (lowerer.failed) return { };
		if (argument.pending_effect) return argument;
		registers[index] = argument.register;
		argument_types[index] = argument.type_id;
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
	mitos::GenericFunction* generic = &lowerer.source.methods.generics[(sz)node.descriptor];
	mitos::MitosSpan span;
	if (node.span && node.span <= lowerer.source.spans.len) span = lowerer.source.spans[node.span - 1];
	mitos::DispatchResult dispatch = mitos::dispatch_method(
		&lowerer.source.methods,
		&lowerer.source.types,
		generic.name,
		actual,
		lowerer.allocator,
		span
	);
	if (!dispatch.matched)
	{
		lowerer.fail(dispatch.diagnostic.message);
		dispatch.deinit();
		return { };
	}
	usz method_index = dispatch.method_index;
	mitos::MethodDescriptor* method = &generic.methods[(sz)method_index];
	mitos::TypeId result_type = mitos::TYPE_ID_ANY;
	if (!mitos::resolve_method_result_type(
		&lowerer.source.types,
		method,
		dispatch.bindings,
		&result_type
	))
	{
		dispatch.deinit();
		lowerer.fail("MIR JIT could not instantiate the selected method result type");
		return { };
	}
	dispatch.deinit();
	mitos::TypeId lowered_result_type = lifted
		? intern_superposition_type(lowerer, result_type) : result_type;
	if (lowerer.failed) return { };
	mitos::DeltaMethodRoot* root = method_root(lowerer, node.descriptor, method_index);
	if (!root)
	{
		lowerer.fail("MIR JIT selected method has no Delta method root");
		return { };
	}
	if (method_has_effects(lowerer, root.function_index))
	{
		MirScope effect_scope = {
			.parent = scope,
			.names = root.parameters,
			.types = argument_types,
			.registers = registers,
		};
		LoweredValue effectful = lower_node(lowerer, root.root, &effect_scope, depth + 1);
		if (!effectful.pending_effect && lowered_result_type != mitos::TYPE_ID_ANY)
		{
			effectful.type_id = lowered_result_type;
		}
		return effectful;
	}
	mitos_specialization::MethodSpecialization* cached = lowerer.cache
		? lowerer.cache.lookup(
			node.descriptor,
			actual,
			generic.epoch,
			lowerer.source.effects.epoch
		) : null;
	uint destination = new_register(lowerer);
	uint operand_start = append_operands(lowerer, registers);
	if (cached && cached.native_result)
	{
		uint native_index = (uint)lowerer.native_methods.size;
		lowerer.native_methods.push(cached.native_result);
		emit(lowerer, {
			.opcode = CACHED_CALL,
			.destination = destination,
			.a = native_index,
			.operand_start = operand_start,
			.operand_count = (uint)arity,
			.b = lifted ? (uint)lowered_result_type : 0,
		});
		return { .register = destination, .type_id = lowered_result_type };
	}
	uint target = reserve_method_instance(lowerer, node.descriptor, method_index, actual);
	if (lowerer.failed) return { };
	if (lowerer.cache) (void)lowerer.cache.record(
		node.descriptor,
		method_index,
		actual,
		generic.epoch,
		lowerer.source.effects.epoch,
		null,
		target
	);
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
		if (descriptor.id == effect) return descriptor;
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
	MirScope return_scope = {
		.parent = activation.environment,
		.names = names[..],
		.types = types[..],
		.registers = registers[..],
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
	defer alloc::free(lowerer.allocator, registers);
	defer alloc::free(lowerer.allocator, types);
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
	}
	MirScope clause_scope = {
		.parent = environment,
		.names = selected.parameters,
		.types = types,
		.registers = registers,
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

fn LoweredValue lower_match(
	DeltaMirLowerer* lowerer,
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
	if (lowerer.failed) return { };
	if (scrutinee.pending_effect) return scrutinee;
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
	uint join = new_label(lowerer);
	mitos::TypeId result_type = mitos::TYPE_ID_ANY;
	foreach (branch_index, &branch : node.branches)
	{
		bool final_branch = branch_index + 1 == node.branches.len;
		uint next = 0;
		if (!branch.wildcard && branch.constructor >= lowerer.source.constructors.len)
		{
			lowerer.fail("MIR JIT match branch references an invalid constructor");
			return { };
		}
		if (!final_branch && !branch.wildcard)
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
			}
			branch_scope.names = branch.bindings;
			branch_scope.types = types;
			branch_scope.registers = registers;
		}
		LoweredValue body = lower_node(lowerer, branch.body, &branch_scope, depth + 1);
		alloc::free(lowerer.allocator, registers);
		alloc::free(lowerer.allocator, types);
		if (lowerer.failed) return { };
		if (body.pending_effect) return body;
		if (branch_index == 0) { result_type = body.type_id; }
		else if (result_type != body.type_id) { result_type = mitos::TYPE_ID_ANY; }
		emit(lowerer, { .opcode = MOVE, .destination = result, .a = body.register });
		if (!final_branch) emit(lowerer, { .opcode = JUMP, .a = join });
		if (!final_branch && !branch.wildcard) emit(lowerer, { .opcode = LABEL, .a = next });
	}
	emit(lowerer, { .opcode = LABEL, .a = join });
	return { .register = result, .type_id = result_type };
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
			mitos::TypeId actual_element = mitos::TYPE_ID_INVALID;
			foreach (index, input : node.inputs)
			{
				LoweredValue alternative = lower_node(lowerer, input, scope, depth + 1);
				if (lowerer.failed || alternative.pending_effect) return alternative;
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
			uint superposition = new_register(lowerer);
			emit(lowerer, {
				.opcode = SUPERPOSE,
				.destination = superposition,
				.b = (uint)superposition_type,
				.operand_start = append_operands(lowerer, alternatives),
				.operand_count = (uint)alternatives.len,
				.immediate = (long)node.descriptor,
			});
			return { .register = superposition, .type_id = superposition_type };
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
			bool lifted = false;
			foreach (index, input : node.inputs)
			{
				LoweredValue field = lower_node(lowerer, input, scope, depth + 1);
				if (lowerer.failed) return { };
				if (field.pending_effect) return field;
				mitos::TypeId expected = node.types.len == node.inputs.len
					? node.types[index] : constructor.field_types[index];
				bool field_lifted;
				mitos::TypeId field_type = branch_runtime_type(lowerer, field.type_id, &field_lifted);
				lifted = lifted || field_lifted;
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
			uint constructed = new_register(lowerer);
			mitos::TypeId lowered_type = lifted
				? intern_superposition_type(lowerer, constructed_type) : constructed_type;
			if (lowerer.failed) return { };
			emit(lowerer, {
				.opcode = lifted ? LIFT_CONSTRUCTOR : MAKE_CONSTRUCTOR,
				.destination = constructed,
				.a = constructor_index(node.descriptor),
				.b = (uint)constructed_type,
				.operand_start = append_operands(lowerer, fields),
				.operand_count = (uint)fields.len,
			});
			return { .register = constructed, .type_id = lowered_type };
		case DELTA_MATCH: return lower_match(lowerer, node, scope, depth);
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
			emit(lowerer, { .opcode = TYPE_OF, .destination = type_of, .a = inspected.register });
			return { .register = type_of, .type_id = reflected_type };
		case DELTA_TYPE_ASSERT:
			if (node.inputs.len != 1 || !mitos::type_id_is_valid(&lowerer.source.types, (mitos::TypeId)node.descriptor))
			{ lowerer.fail("MIR type assertion has invalid metadata"); return { }; }
			LoweredValue asserted = lower_node(lowerer, node.inputs[0], scope, depth + 1);
			if (lowerer.failed) return { };
			if (asserted.pending_effect) return asserted;
			bool lifted = superposition_element_type(lowerer, asserted.type_id, null);
			mitos::TypeId assertion_type = lifted
				? intern_superposition_type(lowerer, (mitos::TypeId)node.descriptor)
				: (mitos::TypeId)node.descriptor;
			if (lowerer.failed) return { };
			uint checked = new_register(lowerer);
			emit(lowerer, {
				.opcode = TYPE_ASSERT,
				.destination = checked,
				.a = asserted.register,
				.b = (uint)node.descriptor,
				.immediate = lifted ? (long)assertion_type : 0,
			});
			return { .register = checked, .type_id = assertion_type };
		case DELTA_LET:
			if (node.inputs.len != 2 || node.names.len != 1) { lowerer.fail("MIR let node has invalid metadata"); return { }; }
			LoweredValue bound = lower_node(lowerer, node.inputs[0], scope, depth + 1);
			if (lowerer.failed) return { };
			if (bound.pending_effect) return bound;
			String[1] names = { node.names[0] };
			mitos::TypeId[1] types = { bound.type_id };
			uint[1] registers = { bound.register };
			MirScope let_scope = { .parent = scope, .names = names[..], .types = types[..], .registers = registers[..] };
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
			defer alloc::free(lowerer.allocator, root_registers);
			defer alloc::free(lowerer.allocator, futures);
			defer alloc::free(lowerer.allocator, root_types);
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
					if (delta_graph_has_effect(lowerer, root.inputs[0], 0))
					{
						LoweredValue inline_root = lower_node(
							lowerer, root.inputs[0], scope, depth + 1
						);
						if (lowerer.failed || inline_root.pending_effect) return inline_root;
						root_registers[index] = inline_root.register;
						root_types[index] = inline_root.type_id;
						futures[index] = uint::max;
						continue;
					}
					uint[] captured;
					mitos::TypeId[] captured_types;
					uint target = reserve_parallel_instance(
						lowerer, root.inputs[0], scope, &captured, &captured_types
					);
					alloc::free(lowerer.allocator, captured_types);
					if (lowerer.failed) { alloc::free(lowerer.allocator, captured); return { }; }
					uint future = new_register(lowerer);
					emit(lowerer, {
						.opcode = PARALLEL_CALL,
						.destination = future,
						.a = target,
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
				}
			}
			MirScope phase_two_scope = {
				.parent = scope, .names = node.names, .types = root_types, .registers = root_registers,
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
			if (operation.parameter_patterns.len != node.inputs.len
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
			if (node.effect_row.len)
			{
				lowerer.fail("effectful MIR closures require a handler-capable application boundary");
				return { };
			}
			uint[] captures;
			mitos::TypeId[] capture_types;
			uint function_target = reserve_closure_instance(
				lowerer, node, scope, &captures, &capture_types
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
				? intern_superposition_type(lowerer, node.runtime_type) : node.runtime_type;
			if (lowerer.failed)
			{
				alloc::free(lowerer.allocator, captures);
				alloc::free(lowerer.allocator, capture_types);
				return { };
			}
			uint closure = new_register(lowerer);
			emit(lowerer, {
				.opcode = lifted ? LIFT_MAKE_FUNCTION : MAKE_FUNCTION,
				.destination = closure,
				.a = function_target,
				.b = (uint)node.runtime_type,
				.operand_start = append_operands(lowerer, captures),
				.operand_count = (uint)captures.len,
				.immediate = (long)node.names.len,
			});
			alloc::free(lowerer.allocator, captures);
			alloc::free(lowerer.allocator, capture_types);
			return { .register = closure, .type_id = closure_type };
		case DELTA_APPLY:
			if (!node.inputs.len)
			{
				lowerer.fail("MIR function application has no callee");
				return { };
			}
			LoweredValue callee = lower_node(lowerer, node.inputs[0], scope, depth + 1);
			if (lowerer.failed || callee.pending_effect) return callee;
			bool lifted = superposition_element_type(lowerer, callee.type_id, null);
			uint[] arguments = alloc::new_array(
				lowerer.allocator, uint, (sz)node.inputs.len - 1
			);
			defer alloc::free(lowerer.allocator, arguments);
			for (usz index = 1; index < node.inputs.len; index++)
			{
				LoweredValue argument = lower_node(lowerer, node.inputs[index], scope, depth + 1);
				if (lowerer.failed || argument.pending_effect) return argument;
				arguments[index - 1] = argument.register;
				lifted = lifted || superposition_element_type(lowerer, argument.type_id, null);
			}
			mitos::TypeId concrete_result = node.result_type
				? node.result_type : mitos::TYPE_ID_ANY;
			if (concrete_result == mitos::TYPE_ID_ANY)
			{
				mitos::TypeId callee_type = branch_runtime_type(lowerer, callee.type_id);
				mitos::TypeDescriptor* callee_descriptor = mitos::type_descriptor(
					&lowerer.source.types, callee_type
				);
				if (callee_descriptor && callee_descriptor.function_result)
				{
					concrete_result = callee_descriptor.function_result;
				}
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
			return {
				.register = applied,
				.type_id = application_type,
			};
		default:
			lowerer.fail("MIR JIT encountered an unsupported Delta node kind");
			return { };
	}
}
fn bool initialize_type_metadata(DeltaMirLowerer* lowerer)
{
	usz type_count = (usz)lowerer.source.types.descriptors.len();
	lowerer.types = alloc::new_array(lowerer.allocator, mitos_mir::MirType, (sz)type_count);
	foreach (index, &descriptor : lowerer.source.types.descriptors)
	{
		mitos::TypeId type_value_runtime = mitos::TYPE_ID_TYPE;
		foreach (&candidate : lowerer.source.types.descriptors)
		{
			if (candidate.constructor == mitos::TYPE_ID_TYPE
				&& candidate.arguments.len == 1
				&& candidate.arguments[0] == descriptor.id)
			{
				type_value_runtime = candidate.id;
				break;
			}
		}
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
	}
	return true;
}

fn bool initialize_metadata(DeltaMirLowerer* lowerer)
{
	usz constructor_count = lowerer.source.constructors.len + 3;
	if (constructor_count > (usz)uint::max) { lowerer.fail("MIR constructor table exceeds the ABI limit"); return false; }
	lowerer.constructors = alloc::new_array(lowerer.allocator, mitos_mir::MirConstructor, (sz)constructor_count);
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
		if (constructor.fields.len > (usz)uint::max) { lowerer.fail("MIR constructor arity exceeds the ABI limit"); return false; }
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
		bool standard_console = false;
		foreach (&effect : lowerer.source.effects.effects)
		{
			if (effect.id == operation.effect && effect.name == "Console"
				&& operation.name == "print")
			{
				standard_console = true;
				break;
			}
		}
		lowerer.effect_operations[index] = {
			.effect = (uint)operation.effect,
			.operation = (uint)operation.id,
			.result_type = (uint)mitos::TYPE_ID_ANY,
			.abi_major = lowerer.source.helper_abi.major,
			.abi_minor = lowerer.source.helper_abi.minor,
			.flags = (operation.ordered ? 1u : 0u)
				| (operation.host_kind == mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL ? 2u : 0u)
				| (standard_console ? 4u : 0u),
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
		arguments[index] = argument.register;
		lifted = lifted || superposition_element_type(lowerer, argument.type_id, null);
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
		alloc::free(lowerer.allocator, instance.parameters);
	}
	lowerer.instances.free();
}

fn void free_effect_argument_sets(DeltaMirLowerer* lowerer)
{
	foreach (arguments : lowerer.effect_argument_sets)
	{
		alloc::free(lowerer.allocator, arguments);
	}
	lowerer.effect_argument_sets.free();
}

fn bool lower_functions(DeltaMirLowerer* lowerer, uint* main_function)
{
	lowerer.functions.push({ });
	*main_function = 0;
	lowerer.next_register = 0;
	lowerer.next_label = 0;
	lowerer.substitution = null;
	lowerer.activation = null;
	uint instruction_start = (uint)lowerer.instructions.size;
	LoweredValue entry = lower_node(lowerer, lowerer.source.entry, null, 0);
	if (lowerer.failed) return false;
	if (entry.pending_effect) entry = materialize_external_effect(lowerer, entry);
	if (lowerer.failed || reject_pending_effect(lowerer, entry)) return false;
	emit(lowerer, { .opcode = RETURN, .a = entry.register });
	lowerer.functions[0] = {
		.register_count = lowerer.next_register,
		.instruction_start = instruction_start,
		.instruction_count = (uint)lowerer.instructions.size - instruction_start,
	};
	for (usz instance_index = 0; instance_index < (usz)lowerer.instances.size; instance_index++)
	{
		MirMethodInstance* instance = &lowerer.instances[(sz)instance_index];
		String[] parameters;
		mitos::DeltaNodeId body;
		if (instance.method_index == usz::max)
		{
			parameters = instance.parameters;
			body = instance.root;
		}
		else
		{
			mitos::DeltaMethodRoot* root = method_root(
				lowerer,
				instance.generic_index,
				instance.method_index
			);
			if (!root)
			{
				lowerer.fail("MIR method instance lost its Delta root metadata");
				return false;
			}
			parameters = root.parameters;
			body = root.root;
		}
		if (parameters.len > (usz)JIT_MAX_REGISTERS
			|| parameters.len != instance.concrete_types.len)
		{
			lowerer.fail("MIR function instance has inconsistent parameter metadata");
			return false;
		}
		lowerer.substitution = null;
		lowerer.activation = null;
		lowerer.next_register = (uint)parameters.len;
		lowerer.next_label = 0;
		instruction_start = (uint)lowerer.instructions.size;
		uint[] registers = alloc::new_array(lowerer.allocator, uint, (sz)parameters.len);
		foreach (index, parameter : parameters)
		{
			(void)parameter;
			registers[index] = (uint)index;
		}
		MirScope scope = {
			.names = parameters,
			.types = instance.concrete_types,
			.registers = registers,
		};
		LoweredValue result = lower_node(lowerer, body, &scope, 0);
		alloc::free(lowerer.allocator, registers);
		if (lowerer.failed) return false;
		if (result.pending_effect) result = materialize_external_effect(lowerer, result);
		if (lowerer.failed) return false;
		if (result.pending_effect)
		{
			lowerer.fail("effectful MIR method instance escaped its effect-capable call site");
			return false;
		}
		emit(lowerer, { .opcode = RETURN, .a = result.register });
		lowerer.functions[(sz)instance.function_index] = {
			.parameter_count = (uint)parameters.len,
			.register_count = lowerer.next_register,
			.instruction_start = instruction_start,
			.instruction_count = (uint)lowerer.instructions.size - instruction_start,
		};
		instance.lowered = true;
	}
	return true;
}

fn MitosMirLowerResult lower_delta_program_to_mir(
	mitos::DeltaProgram* program,
	mitos_specialization::SpecializationCache* cache = null,
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
	if (program.format_version != mitos::DELTA_PROGRAM_FORMAT_VERSION || !program.entry)
	{
		return {
			.allocator = allocator,
			.diagnostic = "MIR lowering requires a complete current-version DeltaProgram".copy(allocator),
		};
	}
	if (program.helper_abi.major != mitos::DELTA_HELPER_ABI_MAJOR
		|| program.helper_abi.minor > mitos::DELTA_HELPER_ABI_MINOR
		|| (program.helper_abi.feature_bits & (ulong)0x1f) != program.helper_abi.feature_bits)
	{
		return {
			.allocator = allocator,
			.diagnostic = "MIR lowering rejected an incompatible Delta helper ABI".copy(allocator),
		};
	}
	foreach (&node : program.image.nodes)
	{
		if (node.kind != mitos::DeltaNodeKind.DELTA_SUPERPOSE
			&& node.kind != mitos::DeltaNodeKind.DELTA_COLLAPSE) continue;
		if (program.helper_abi.minor < 2
			|| (program.helper_abi.feature_bits & (ulong)0x10) == 0)
		{
			return {
				.allocator = allocator,
				.diagnostic = "MIR superposition requires Delta helper ABI 1.2 feature 0x10".copy(allocator),
			};
		}
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
	DeltaMirLowerer lowerer = { .allocator = allocator, .source = program, .cache = cache };
	lowerer.functions.init(allocator);
	lowerer.instances.init(allocator);
	lowerer.instructions.init(allocator);
	lowerer.operands.init(allocator);
	lowerer.effect_argument_sets.init(allocator);
	lowerer.strings.init(allocator);
	lowerer.native_methods.init(allocator);
	lowerer.type_names.init(allocator);
	lowerer.match_arms.init(allocator);
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
		lowerer.native_methods.free();
		lowerer.match_arms.free();
		free_effect_argument_sets(&lowerer);
		lowerer.functions.free();
		free_method_instances(&lowerer);
		alloc::free(allocator, lowerer.constructors);
		alloc::free(allocator, lowerer.types);
		alloc::free(allocator, lowerer.effect_operations);
		return { .allocator = allocator, .diagnostic = message };
	}
	OwnedMirProgram owned = {
		.allocator = allocator,
		.functions = lowerer.functions.to_array(allocator),
		.instructions = lowerer.instructions.to_array(allocator),
		.operands = lowerer.operands.to_array(allocator),
		.constructors = lowerer.constructors,
		.types = lowerer.types,
		.type_names = lowerer.type_names.to_array(allocator),
		.strings = lowerer.strings.to_array(allocator),
		.native_methods = lowerer.native_methods.to_array(allocator),
		.effect_operations = lowerer.effect_operations,
		.match_arms = lowerer.match_arms.to_array(allocator),
		.main_function = main_function,
		.phase_one_root_count = (uint)(
			1 + program.method_roots.len + program.image.parallel_regions.len
		),
	};
	lowerer.instructions.free();
	lowerer.functions.free();
	lowerer.operands.free();
	lowerer.strings.free();
	lowerer.native_methods.free();
	lowerer.type_names.free();
	lowerer.match_arms.free();
	free_method_instances(&lowerer);
	free_effect_argument_sets(&lowerer);
	return { .allocator = allocator, .program = owned };
}

fn MitosJitResult jit_delta_program(
	mitos::DeltaProgram* program,
	mitos_specialization::SpecializationCache* cache = null,
	Allocator allocator = mem
)
{
	mitos_specialization::SpecializationCache local_cache;
	bool owns_cache = cache == null;
	if (owns_cache)
	{
		local_cache.init(allocator);
		cache = &local_cache;
	}
	defer if (owns_cache) local_cache.deinit();
	MitosMirLowerResult lowered = lower_delta_program_to_mir(program, cache, allocator);
	defer lowered.free();
	if (!lowered.ok()) return {
		.status = ERROR, .diagnostic = lowered.diagnostic.copy(allocator), .allocator = allocator,
	};
	mitos_mir::MirProgram bridge_program = lowered.program.view();
	foreach (&entry : cache.entries[:(sz)cache.count])
	{
		if (entry.native_result || entry.function_index == uint::max
			|| entry.function_index >= bridge_program.function_count) continue;
		String compile_diagnostic;
		void* native_method = mitos_mir::compile_method(
			&bridge_program,
			entry.function_index,
			&compile_diagnostic,
			allocator
		);
		if (!native_method)
		{
			String message = compile_diagnostic.len
				? compile_diagnostic : "MIR method-instance compilation failed".copy(allocator);
			return { .status = ERROR, .diagnostic = message, .allocator = allocator };
		}
		alloc::free(allocator, compile_diagnostic);
		entry.native_result = native_method;
	}
	mitos_mir::MirExecutionResult native = mitos_mir::execute(&bridge_program, allocator);
	MitosJitResult result = {
		.status = native.status,
		.result = native.result,
		.diagnostic = native.diagnostic,
		.native_instruction_count = bridge_program.instruction_count,
		.specialized_method_count = (uint)cache.count,
		.allocator = allocator,
	};
	native.result = { };
	native.diagnostic = { };
	native.allocator = { };
	return result;
}
