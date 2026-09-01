module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_storage;
import std::collections::list;
import std::core::mem;
import std::os;
import std::thread;
import std::io;

enum TypedDeltaValueKind : char
{
 TYPED_VALUE_I64,
 TYPED_VALUE_BOOL,
 TYPED_VALUE_UNIT,
 TYPED_VALUE_STRING,
 TYPED_VALUE_CONSTRUCTOR,
 TYPED_VALUE_CLOSURE,
 TYPED_VALUE_TYPE,
 TYPED_VALUE_ARRAY,
 TYPED_VALUE_SUPERPOSITION,
 TYPED_VALUE_EFFECT_REQUEST,
}

struct TypedDeltaAssignment
{
	ulong origin;
	usz branch;
}

struct TypedDeltaAlternative
{
	TypedDeltaValue* value;
	TypedDeltaAssignment[] assignments;
}

struct TypedDeltaBinding
{
	String name;
	TypedDeltaValue* value;
}
struct TypedDeltaEnvironment
{
	TypedDeltaBinding[] bindings;
}
struct TypedDeltaClosure
{
	mitos::DeltaNodeId body;
	String[] parameters;
	mitos::TypeId[] parameter_types;
	TypedDeltaEnvironment environment;
	mitos::TypeId result_type;
	mitos::ResolvedEffectRow* effect_row;
	mitos::TypeId signature_type;
}
struct TypedDeltaSubstitution
{
 TypedDeltaSubstitution* parent;
 mitos::DeltaNodeId hole;
 TypedDeltaValue* value;
 usz source_order;
 usz occurrence_order;
}

struct TypedDeltaExternalResult
{
 usz occurrence_order;
 mitos::DeltaNodeId hole;
 TypedDeltaValue* value;
 bool ready;
}
struct TypedDeltaExternalLane
{
 usz source_order;
 List{TypedDeltaExternalResult} results;
}

struct TypedDeltaHandlerScope
{
 TypedDeltaHandlerScope* parent;
 mitos::DeltaHandlerDescriptor* handler;
}

struct TypedDeltaHandlerActivation
{
	TypedDeltaHandlerActivation* parent;
	usz handler_index;
	mitos::DeltaHandlerDescriptor* handler;
	TypedDeltaEnvironment environment;
	mitos::DeltaNodeId handler_node;
	mitos::DeltaNodeId handled_root;
	mitos::DeltaNodeId hole;
	usz resumes_used;
	ulong generation;
 usz resume_limit;
 mitos::TypeId operation_result_type;
 usz effect_source_order;
 usz effect_occurrence_order;
	bool multi;
	bool aborted;
}

struct TypedDeltaValue
{
	TypedDeltaValueKind kind;
	mitos::TypeId type_id;
	long integer;
	bool boolean;
 mitos_storage::StorageHandle storage;
 usz storage_count;
 usz storage_stride;
	usz constructor;
	TypedDeltaValue*[] fields;
	TypedDeltaClosure closure;
	TypedDeltaValue*[] elements;
	TypedDeltaAlternative[] alternatives;
	ulong origin;
	mitos::TypeId represented_type;
	usz effect_operation;
	mitos::DeltaNodeId effect_node;
	TypedDeltaValue*[] effect_arguments;
 mitos::EffectId effect_instance;
 usz effect_source_order;
 usz effect_occurrence_order;
 mitos::TypeId effect_result_type;
 bool effect_host_suspended;
}
struct TypedDeltaExecutionStats
{
	usz phase_one_roots;
	usz phase_two_reifications;
	usz evaluations;
	usz dispatches;
	usz parallel_bindings;
	usz effects_handled;
	usz continuations_resumed;
	usz continuations_erased;
	usz replicator_branches;
	usz ordered_effect_commits;
	ulong effect_epoch;
}
enum TypedDeltaExecutionStatus : char
{
 TYPED_DELTA_COMPLETE,
 TYPED_DELTA_SUSPENDED,
 TYPED_DELTA_FAILED,
}

struct TypedDeltaRequestView
{
 Allocator allocator;
 mitos::EffectId effect;
 mitos::OperationId operation;
 mitos::TypeId result_type;
 usz source_order;
 usz occurrence_order;
 TypedDeltaHostValue[] arguments;
}

fn void TypedDeltaRequestView.deinit(&self)
{
 if (!self.allocator) return;
 foreach (&argument : self.arguments)
 {
  if (argument.kind == HOST_VALUE_STRING)
  {
   alloc::free(self.allocator, argument.string);
  }
 }
 alloc::free(self.allocator, self.arguments);
 *self = { };
}

struct TypedDeltaExecutionResult
{
 Allocator allocator;
 TypedDeltaExecutionStatus status;
 String formatted;
 mitos::TypeId type_id;
 TypedDeltaExecutionStats stats;
 DeltaDiagnostic[] diagnostics;
 TypedDeltaRequestView request;
 DeltaResumptionToken token;
}
fn bool TypedDeltaExecutionResult.ok(&self) => self.status == TYPED_DELTA_COMPLETE;
fn void TypedDeltaExecutionResult.deinit(&self)
{
 if (!self.allocator) return;
 alloc::free(self.allocator, self.formatted);
 foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
 alloc::free(self.allocator, self.diagnostics);
 self.request.deinit();
 *self = { };
}

fn TypedDeltaExecutionResult typed_delta_failure(
 String message,
 Allocator allocator = mem
)
{
 TypedDeltaExecutionResult result = {
  .allocator = allocator,
  .status = TYPED_DELTA_FAILED,
 };
 result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
 result.diagnostics[0].init(allocator, message);
 return result;
}

const usz TYPED_DELTA_MAX_NATIVE_DEPTH = 512;
const usz TYPED_DELTA_MAX_VALUES = 1_000_000;
const usz TYPED_DELTA_MAX_ALTERNATIVES = 65_536;
const usz TYPED_DELTA_MAX_ASSIGNMENTS = 1_024;
const usz TYPED_DELTA_MAX_PARALLEL_ROOTS = 256;
const usz TYPED_DELTA_MAX_ENVIRONMENTS = 1_000_000;
const usz TYPED_DELTA_MAX_OWNED_BYTES = 64 * 1024 * 1024;
const usz TYPED_DELTA_MAX_FORMAT_BYTES = 1024 * 1024;

struct TypedDeltaRetainedAllocation @private
{
	void* base;
	usz allocation_bytes;
	usz payload_bytes;
}

/** Counts the complete backing allocations retained by the program clone. */
struct TypedDeltaRetainedAllocator (Allocator) @private
{
	Allocator backing;
	usz live_bytes;
	bool overflowed;
}

fn void TypedDeltaRetainedAllocator.init(&self, Allocator backing)
{
	*self = { .backing = backing };
}

fn void*? TypedDeltaRetainedAllocator.acquire(
	&self,
	sz size,
	AllocInitType init_type,
	sz requested_alignment
) @dynamic
{
	usz alignment = requested_alignment > 0
		? (usz)requested_alignment : (usz)mem::DEFAULT_MEM_ALIGNMENT;
	if (alignment < (usz)TypedDeltaRetainedAllocation::alignment)
	{
		alignment = (usz)TypedDeltaRetainedAllocation::alignment;
	}
	usz payload_bytes = (usz)size;
	usz overhead = (usz)TypedDeltaRetainedAllocation::size + alignment - 1;
	if (payload_bytes > usz::max - overhead)
	{
		self.overflowed = true;
		return mem::INVALID_ALLOC_SIZE~;
	}
	usz allocation_bytes = payload_bytes + overhead;
	if (self.live_bytes > usz::max - allocation_bytes)
	{
		self.overflowed = true;
		return mem::INVALID_ALLOC_SIZE~;
	}
	void* base = self.backing.acquire((sz)allocation_bytes, NO_ZERO)!;
	void* payload = mem::aligned_pointer(
		base + TypedDeltaRetainedAllocation::size,
		(sz)alignment
	);
	TypedDeltaRetainedAllocation* header =
		payload - TypedDeltaRetainedAllocation::size;
	*header = {
		.base = base,
		.allocation_bytes = allocation_bytes,
		.payload_bytes = payload_bytes,
	};
	if (init_type == ZERO)
	{
		mem::clear(payload, size, mem::DEFAULT_MEM_ALIGNMENT);
	}
	self.live_bytes += allocation_bytes;
	return payload;
}

fn void*? TypedDeltaRetainedAllocator.resize(
	&self,
	void* old_pointer,
	sz new_size,
	sz alignment
) @dynamic
{
	TypedDeltaRetainedAllocation* old_header =
		old_pointer - TypedDeltaRetainedAllocation::size;
	void* replacement = self.acquire(new_size, NO_ZERO, alignment)!;
	usz copied = old_header.payload_bytes < (usz)new_size
		? old_header.payload_bytes : (usz)new_size;
	mem::copy(
		replacement,
		old_pointer,
		(sz)copied,
		mem::DEFAULT_MEM_ALIGNMENT,
		mem::DEFAULT_MEM_ALIGNMENT
	);
	self.release(old_pointer, false);
	return replacement;
}

fn void TypedDeltaRetainedAllocator.release(
	&self,
	void* old_pointer,
	bool
) @dynamic
{
	TypedDeltaRetainedAllocation* header =
		old_pointer - TypedDeltaRetainedAllocation::size;
	assert(
		self.live_bytes >= header.allocation_bytes,
		"typed Delta retained allocator byte accounting underflow"
	);
	self.live_bytes -= header.allocation_bytes;
	self.backing.release(header.base, false);
}

struct TypedDeltaCloneBudget @private
{
 usz bytes;
 usz limit;
 bool failed;
}

fn void typed_delta_clone_budget_add(
 TypedDeltaCloneBudget* budget,
 usz payload
) @private
{
 if (budget.failed || !payload) return;
 usz overhead = (usz)TypedDeltaRetainedAllocation::size
  + (usz)mem::DEFAULT_MEM_ALIGNMENT - 1;
 if (payload > budget.limit
  || overhead > budget.limit - payload
  || budget.bytes > budget.limit - payload - overhead)
 {
  budget.failed = true;
  return;
 }
 budget.bytes += payload + overhead;
}

fn void typed_delta_clone_budget_array(
 TypedDeltaCloneBudget* budget,
 usz count,
 usz element_size
) @private
{
 if (budget.failed || !count) return;
 if (count > budget.limit / element_size)
 {
  budget.failed = true;
  return;
 }
 typed_delta_clone_budget_add(budget, count * element_size);
}

fn void typed_delta_clone_budget_string(
 TypedDeltaCloneBudget* budget,
 String value
) @private
{
 if (value.len == usz::max)
 {
  budget.failed = true;
  return;
 }
 typed_delta_clone_budget_add(budget, value.len + 1);
}

fn void typed_delta_clone_budget_strings(
 TypedDeltaCloneBudget* budget,
 String[] values
) @private
{
 typed_delta_clone_budget_array(budget, values.len, (usz)String::size);
 foreach (value : values) typed_delta_clone_budget_string(budget, value);
}

fn void typed_delta_clone_budget_module(
 TypedDeltaCloneBudget* budget,
 mitos::ModuleKey* key
) @private
{
 if (key) typed_delta_clone_budget_string(budget, key.canonical);
}

fn void typed_delta_clone_budget_symbol(
 TypedDeltaCloneBudget* budget,
 mitos::SymbolKey* key
) @private
{
 if (!key) return;
 typed_delta_clone_budget_module(budget, &key.owner);
 typed_delta_clone_budget_string(budget, key.name);
 typed_delta_clone_budget_string(budget, key.canonical_signature);
}

fn void typed_delta_clone_budget_effect_row(
 TypedDeltaCloneBudget* budget,
 mitos::ResolvedEffectRow* row
) @private
{
 if (!row) return;
 typed_delta_clone_budget_array(
  budget, row.required.len, (usz)mitos::EffectId::size
 );
 if (row.has_tail) typed_delta_clone_budget_symbol(budget, &row.tail);
}

fn void typed_delta_clone_budget_type_pattern(
 TypedDeltaCloneBudget* budget,
 mitos::TypePattern* pattern
) @private
{
 typed_delta_clone_budget_string(budget, pattern.variable);
 typed_delta_clone_budget_array(
  budget, pattern.arguments.len, (usz)mitos::TypePattern::size
 );
 foreach (&argument : pattern.arguments)
  typed_delta_clone_budget_type_pattern(budget, argument);
}

fn void typed_delta_clone_budget_method_pattern(
 TypedDeltaCloneBudget* budget,
 mitos::MethodTypePattern* pattern
) @private
{
 typed_delta_clone_budget_string(budget, pattern.name);
 typed_delta_clone_budget_array(
  budget, pattern.arguments.len, (usz)mitos::MethodTypePattern::size
 );
 foreach (&argument : pattern.arguments)
  typed_delta_clone_budget_method_pattern(budget, argument);
}

fn void typed_delta_clone_budget_type_descriptor(
 TypedDeltaCloneBudget* budget,
 mitos::TypeDescriptor* descriptor
) @private
{
 typed_delta_clone_budget_symbol(budget, &descriptor.key);
 typed_delta_clone_budget_symbol(budget, &descriptor.layout.stable_key);
 typed_delta_clone_budget_string(budget, descriptor.name);
 typed_delta_clone_budget_strings(budget, descriptor.parameters);
 typed_delta_clone_budget_array(
  budget, descriptor.arguments.len, (usz)mitos::TypeId::size
 );
 typed_delta_clone_budget_array(
  budget, descriptor.function_parameters.len, (usz)mitos::TypeId::size
 );
 typed_delta_clone_budget_effect_row(budget, &descriptor.function_effects);
 typed_delta_clone_budget_array(
  budget, descriptor.fields.len, (usz)mitos::TypeFieldDescriptor::size
 );
 foreach (&field : descriptor.fields)
 {
  typed_delta_clone_budget_string(budget, field.name);
  typed_delta_clone_budget_string(budget, field.type_pattern);
  typed_delta_clone_budget_type_pattern(budget, &field.pattern);
 }
}

fn void typed_delta_clone_budget_method(
 TypedDeltaCloneBudget* budget,
 mitos::MethodDescriptor* method
) @private
{
 typed_delta_clone_budget_symbol(budget, &method.key);
 typed_delta_clone_budget_symbol(budget, &method.generic_key);
 typed_delta_clone_budget_module(budget, &method.owner);
 typed_delta_clone_budget_method_pattern(budget, &method.result);
 typed_delta_clone_budget_strings(budget, method.type_variables);
 typed_delta_clone_budget_array(
  budget, method.parameters.len, (usz)mitos::MethodTypePattern::size
 );
 foreach (&pattern : method.parameters)
  typed_delta_clone_budget_method_pattern(budget, pattern);
}

fn void typed_delta_clone_budget_node(
 TypedDeltaCloneBudget* budget,
 mitos::DeltaNode* node
) @private
{
 typed_delta_clone_budget_symbol(budget, &node.key);
 typed_delta_clone_budget_string(budget, node.string_value);
 typed_delta_clone_budget_string(budget, node.name);
 typed_delta_clone_budget_strings(budget, node.names);
 typed_delta_clone_budget_array(
  budget, node.types.len, (usz)mitos::TypeId::size
 );
 typed_delta_clone_budget_effect_row(budget, &node.effect_row);
 typed_delta_clone_budget_array(
  budget, node.inputs.len, (usz)mitos::DeltaNodeId::size
 );
 typed_delta_clone_budget_array(
  budget, node.branches.len, (usz)mitos::DeltaMatchBranch::size
 );
 foreach (&branch : node.branches)
  typed_delta_clone_budget_strings(budget, branch.bindings);
}

fn void typed_delta_clone_budget_method_root(
 TypedDeltaCloneBudget* budget,
 mitos::DeltaMethodRoot* root
) @private
{
 typed_delta_clone_budget_symbol(budget, &root.key);
 typed_delta_clone_budget_symbol(budget, &root.generic_key);
 typed_delta_clone_budget_strings(budget, root.parameters);
 typed_delta_clone_budget_array(
  budget, root.parameter_types.len, (usz)mitos::TypeId::size
 );
 typed_delta_clone_budget_method_pattern(budget, &root.result_pattern);
 typed_delta_clone_budget_effect_row(budget, &root.effect_row);
 typed_delta_clone_budget_array(
  budget, root.parameter_patterns.len, (usz)mitos::MethodTypePattern::size
 );
 foreach (&pattern : root.parameter_patterns)
  typed_delta_clone_budget_method_pattern(budget, pattern);
}

fn void typed_delta_clone_budget_effects(
 TypedDeltaCloneBudget* budget,
 mitos::DeltaEffectSection* section
) @private
{
 typed_delta_clone_budget_array(
  budget, section.effects.len, (usz)mitos::DeltaEffectDescriptor::size
 );
 foreach (&effect : section.effects)
 {
  typed_delta_clone_budget_symbol(budget, &effect.key);
  typed_delta_clone_budget_string(budget, effect.name);
  typed_delta_clone_budget_strings(budget, effect.parameters);
  typed_delta_clone_budget_array(
   budget, effect.operations.len, (usz)mitos::OperationId::size
  );
 }
 typed_delta_clone_budget_array(
  budget, section.operations.len, (usz)mitos::DeltaOperationDescriptor::size
 );
 foreach (&operation : section.operations)
 {
  typed_delta_clone_budget_symbol(budget, &operation.key);
  typed_delta_clone_budget_string(budget, operation.name);
  typed_delta_clone_budget_strings(budget, operation.parameter_patterns);
  typed_delta_clone_budget_string(budget, operation.result_pattern);
  typed_delta_clone_budget_type_pattern(budget, &operation.result_type);
  typed_delta_clone_budget_array(
   budget, operation.parameter_types.len, (usz)mitos::TypePattern::size
  );
  foreach (&pattern : operation.parameter_types)
   typed_delta_clone_budget_type_pattern(budget, pattern);
 }
 typed_delta_clone_budget_array(
  budget, section.instances.len, (usz)mitos::DeltaEffectInstanceDescriptor::size
 );
 foreach (&instance : section.instances)
 {
  typed_delta_clone_budget_symbol(budget, &instance.key);
  typed_delta_clone_budget_array(
   budget, instance.arguments.len, (usz)mitos::TypeId::size
  );
 }
 typed_delta_clone_budget_array(
  budget, section.rows.len, (usz)mitos::DeltaEffectRowDescriptor::size
 );
 foreach (&row : section.rows)
 {
  typed_delta_clone_budget_symbol(budget, &row.key);
  typed_delta_clone_budget_effect_row(budget, &row.inferred);
  typed_delta_clone_budget_effect_row(budget, &row.asserted);
 }
 typed_delta_clone_budget_array(
  budget, section.handlers.len, (usz)mitos::DeltaHandlerDescriptor::size
 );
 foreach (&handler : section.handlers)
 {
  typed_delta_clone_budget_string(budget, handler.return_parameter);
  typed_delta_clone_budget_array(
   budget, handler.clauses.len, (usz)mitos::DeltaHandlerClauseDescriptor::size
  );
  foreach (&clause : handler.clauses)
  {
   typed_delta_clone_budget_symbol(budget, &clause.key);
   typed_delta_clone_budget_strings(budget, clause.parameters);
   typed_delta_clone_budget_array(
    budget, clause.parameter_types.len, (usz)mitos::TypeId::size
   );
  }
 }
}

fn bool typed_delta_clone_program_fits(
 mitos::DeltaProgram* program,
 usz limit
) @private
{
 TypedDeltaCloneBudget budget = { .limit = limit };
 typed_delta_clone_budget_add(&budget, (usz)mitos::DeltaProgram::size);
 typed_delta_clone_budget_module(&budget, &program.module_key);
 typed_delta_clone_budget_array(
  &budget, (usz)program.types.descriptors.len(),
  (usz)mitos::TypeDescriptor::size
 );
 typed_delta_clone_budget_module(&budget, &program.types.module_key);
 foreach (&descriptor : program.types.descriptors)
  typed_delta_clone_budget_type_descriptor(&budget, descriptor);
 typed_delta_clone_budget_array(
  &budget, (usz)program.methods.generics.len(),
  (usz)mitos::GenericFunction::size
 );
 typed_delta_clone_budget_module(&budget, &program.methods.module_key);
 foreach (&generic : program.methods.generics)
 {
  typed_delta_clone_budget_symbol(&budget, &generic.key);
  typed_delta_clone_budget_module(&budget, &generic.owner);
  typed_delta_clone_budget_string(&budget, generic.name);
  typed_delta_clone_budget_array(
   &budget, (usz)generic.methods.len(),
   (usz)mitos::MethodDescriptor::size
  );
  foreach (&method : generic.methods)
   typed_delta_clone_budget_method(&budget, method);
 }
 typed_delta_clone_budget_array(
  &budget, program.constructors.len, (usz)mitos::DeltaConstructorDescriptor::size
 );
 foreach (&constructor : program.constructors)
 {
  typed_delta_clone_budget_symbol(&budget, &constructor.key);
  typed_delta_clone_budget_string(&budget, constructor.name);
  typed_delta_clone_budget_strings(&budget, constructor.parameters);
  typed_delta_clone_budget_strings(&budget, constructor.fields);
  typed_delta_clone_budget_array(
   &budget, constructor.field_types.len, (usz)mitos::TypeId::size
  );
  typed_delta_clone_budget_array(
   &budget, constructor.field_patterns.len, (usz)mitos::TypePattern::size
  );
  foreach (&pattern : constructor.field_patterns)
   typed_delta_clone_budget_type_pattern(&budget, pattern);
 }
 typed_delta_clone_budget_array(
  &budget, program.primitives.len, (usz)mitos::DeltaPrimitiveDescriptor::size
 );
 foreach (&primitive : program.primitives)
 {
  typed_delta_clone_budget_symbol(&budget, &primitive.key);
  typed_delta_clone_budget_string(&budget, primitive.name);
  typed_delta_clone_budget_array(
   &budget, primitive.parameters.len, (usz)mitos::TypeId::size
  );
 }
 typed_delta_clone_budget_array(
  &budget, program.image.nodes.len, (usz)mitos::DeltaNode::size
 );
 foreach (&node : program.image.nodes)
  typed_delta_clone_budget_node(&budget, node);
 typed_delta_clone_budget_array(
  &budget, program.image.edges.len, (usz)mitos::DeltaEdge::size
 );
 typed_delta_clone_budget_array(
  &budget, program.image.interfaces.len, (usz)mitos::DeltaInterface::size
 );
 foreach (&boundary : program.image.interfaces)
 {
  typed_delta_clone_budget_symbol(&budget, &boundary.key);
  typed_delta_clone_budget_string(&budget, boundary.name);
 }
 typed_delta_clone_budget_array(
  &budget, program.image.parallel_regions.len,
  (usz)mitos::DeltaParallelRegion::size
 );
 foreach (&region : program.image.parallel_regions)
  typed_delta_clone_budget_array(
   &budget, region.roots.len, (usz)mitos::DeltaNodeId::size
  );
 typed_delta_clone_budget_array(
  &budget, program.method_roots.len, (usz)mitos::DeltaMethodRoot::size
 );
 foreach (&root : program.method_roots)
  typed_delta_clone_budget_method_root(&budget, root);
 typed_delta_clone_budget_array(
  &budget, program.spans.len, (usz)mitos::MitosSpan::size
 );
 typed_delta_clone_budget_effects(&budget, &program.effects);
 return !budget.failed;
}

fn String[] typed_delta_clone_strings(String[] source, Allocator allocator) @private
{
 String[] clone = alloc::new_array(allocator, String, source.len);
 foreach (index, value : source) clone[index] = value.copy(allocator);
 return clone;
}

fn mitos::TypeDescriptor typed_delta_clone_type_descriptor(
 mitos::TypeDescriptor* source,
 Allocator allocator
) @private
{
 mitos::TypeDescriptor clone = {
  .key = mitos::clone_symbol_key(&source.key, allocator),
  .layout = mitos::clone_layout_descriptor(&source.layout, allocator),
  .id = source.id,
  .kind = source.kind,
  .name = source.name.copy(allocator),
  .parameters = typed_delta_clone_strings(source.parameters, allocator),
  .nominal_parent = source.nominal_parent,
  .constructor = source.constructor,
  .arguments = alloc::clone_slice(allocator, source.arguments),
  .arity = source.arity,
  .function_parameters = alloc::clone_slice(
   allocator, source.function_parameters
  ),
  .function_result = source.function_result,
  .function_effects = mitos::clone_resolved_effect_row(
   &source.function_effects, allocator
  ),
  .span = source.span,
 };
 clone.fields = alloc::new_array(
  allocator, mitos::TypeFieldDescriptor, source.fields.len
 );
 foreach (index, &field : source.fields)
 {
  clone.fields[index] = {
   .name = field.name.copy(allocator),
   .type_pattern = field.type_pattern.copy(allocator),
   .declared_type = field.declared_type,
   .pattern = mitos::clone_type_pattern(&field.pattern, allocator),
   .span = field.span,
  };
 }
 return clone;
}

fn void typed_delta_clone_type_registry(
 mitos::TypeRegistry* destination,
 mitos::TypeRegistry* source,
 Allocator allocator
) @private
{
 *destination = {
  .allocator = allocator,
  .module_key = mitos::clone_module_key(&source.module_key, allocator),
  .max_types = source.max_types,
  .epoch = source.epoch,
 };
 mitos::TypeDescriptor[] descriptors = alloc::new_array(
  allocator, mitos::TypeDescriptor, source.descriptors.len()
 );
 destination.descriptors.init_wrapping_array(allocator, descriptors);
 foreach (index, &descriptor : source.descriptors)
  destination.descriptors[index] =
   typed_delta_clone_type_descriptor(descriptor, allocator);
}

fn mitos::MethodDescriptor typed_delta_clone_method(
 mitos::MethodDescriptor* source,
 Allocator allocator
) @private
{
 mitos::MethodDescriptor clone = {
  .key = mitos::clone_symbol_key(&source.key, allocator),
  .generic_key = mitos::clone_symbol_key(&source.generic_key, allocator),
  .owner = mitos::clone_module_key(&source.owner, allocator),
  .function_index = source.function_index,
  .result = mitos::clone_method_pattern(&source.result, allocator),
  .type_variables = typed_delta_clone_strings(
   source.type_variables, allocator
  ),
  .source_order = source.source_order,
  .span = source.span,
 };
 clone.parameters = alloc::new_array(
  allocator, mitos::MethodTypePattern, source.parameters.len
 );
 foreach (index, &pattern : source.parameters)
  clone.parameters[index] = mitos::clone_method_pattern(pattern, allocator);
 return clone;
}

fn void typed_delta_clone_methods(
 mitos::GenericFunctionTable* destination,
 mitos::GenericFunctionTable* source,
 Allocator allocator
) @private
{
 *destination = {
  .allocator = allocator,
  .module_key = mitos::clone_module_key(&source.module_key, allocator),
  .max_generics = source.max_generics,
  .max_methods = source.max_methods,
  .method_count = source.method_count,
 };
 mitos::GenericFunction[] generics = alloc::new_array(
  allocator, mitos::GenericFunction, source.generics.len()
 );
 destination.generics.init_wrapping_array(allocator, generics);
 foreach (generic_index, &generic : source.generics)
 {
  mitos::GenericFunction clone = {
   .key = mitos::clone_symbol_key(&generic.key, allocator),
   .owner = mitos::clone_module_key(&generic.owner, allocator),
   .name = generic.name.copy(allocator),
   .arity = generic.arity,
   .epoch = generic.epoch,
  };
  mitos::MethodDescriptor[] methods = alloc::new_array(
   allocator, mitos::MethodDescriptor, generic.methods.len()
  );
  clone.methods.init_wrapping_array(allocator, methods);
  foreach (method_index, &method : generic.methods)
   clone.methods[method_index] = typed_delta_clone_method(method, allocator);
  destination.generics[generic_index] = clone;
 }
}

fn mitos::DeltaNode typed_delta_clone_node(
 mitos::DeltaNode* source,
 Allocator allocator
) @private
{
 mitos::DeltaNode clone = {
  .key = mitos::clone_symbol_key(&source.key, allocator),
  .stable_id = source.stable_id,
  .kind = source.kind,
  .static_type = source.static_type,
  .span = source.span,
  .integer = source.integer,
  .string_value = source.string_value.copy(allocator),
  .descriptor = source.descriptor,
  .name = source.name.copy(allocator),
  .names = typed_delta_clone_strings(source.names, allocator),
  .types = alloc::clone_slice(allocator, source.types),
  .runtime_type = source.runtime_type,
  .result_type = source.result_type,
  .effect_row = mitos::clone_resolved_effect_row(
   &source.effect_row, allocator
  ),
  .inputs = alloc::clone_slice(allocator, source.inputs),
 };
 clone.branches = alloc::new_array(
  allocator, mitos::DeltaMatchBranch, source.branches.len
 );
 foreach (index, &branch : source.branches)
 {
  clone.branches[index] = {
   .wildcard = branch.wildcard,
   .constructor = branch.constructor,
   .bindings = typed_delta_clone_strings(branch.bindings, allocator),
   .body = branch.body,
   .span = branch.span,
  };
 }
 return clone;
}

fn mitos::DeltaMethodRoot typed_delta_clone_method_root(
 mitos::DeltaMethodRoot* source,
 Allocator allocator
) @private
{
 mitos::DeltaMethodRoot clone = {
  .key = mitos::clone_symbol_key(&source.key, allocator),
  .generic_key = mitos::clone_symbol_key(&source.generic_key, allocator),
  .function_index = source.function_index,
  .generic_index = source.generic_index,
  .method_index = source.method_index,
  .root = source.root,
  .parameters = typed_delta_clone_strings(source.parameters, allocator),
  .parameter_types = alloc::clone_slice(allocator, source.parameter_types),
  .result_type = source.result_type,
  .result_pattern = mitos::clone_method_pattern(
   &source.result_pattern, allocator
  ),
  .effect_row = mitos::clone_resolved_effect_row(
   &source.effect_row, allocator
  ),
  .source_order = source.source_order,
 };
 clone.parameter_patterns = alloc::new_array(
  allocator, mitos::MethodTypePattern, source.parameter_patterns.len
 );
 foreach (index, &pattern : source.parameter_patterns)
  clone.parameter_patterns[index] = mitos::clone_method_pattern(
   pattern, allocator
  );
 return clone;
}

fn void typed_delta_clone_effects(
 mitos::DeltaEffectSection* destination,
 mitos::DeltaEffectSection* source,
 Allocator allocator
) @private
{
 destination.next_effect_id = source.next_effect_id;
 destination.next_operation_id = source.next_operation_id;
 destination.epoch = source.epoch;
 destination.effects = alloc::new_array(
  allocator, mitos::DeltaEffectDescriptor, source.effects.len
 );
 foreach (index, &effect : source.effects)
 {
  destination.effects[index] = {
   .key = mitos::clone_symbol_key(&effect.key, allocator),
   .id = effect.id,
   .name = effect.name.copy(allocator),
   .multi = effect.multi,
   .parameters = typed_delta_clone_strings(effect.parameters, allocator),
   .operations = alloc::clone_slice(allocator, effect.operations),
   .span = effect.span,
  };
 }
 destination.operations = alloc::new_array(
  allocator, mitos::DeltaOperationDescriptor, source.operations.len
 );
 foreach (index, &operation : source.operations)
 {
  mitos::DeltaOperationDescriptor clone = {
   .key = mitos::clone_symbol_key(&operation.key, allocator),
   .id = operation.id,
   .effect = operation.effect,
   .name = operation.name.copy(allocator),
   .parameter_patterns = typed_delta_clone_strings(
    operation.parameter_patterns, allocator
   ),
   .result_pattern = operation.result_pattern.copy(allocator),
   .result_type = mitos::clone_type_pattern(
    &operation.result_type, allocator
   ),
   .span = operation.span,
   .host_kind = operation.host_kind,
   .ordered = operation.ordered,
  };
  clone.parameter_types = alloc::new_array(
   allocator, mitos::TypePattern, operation.parameter_types.len
  );
  foreach (parameter_index, &pattern : operation.parameter_types)
   clone.parameter_types[parameter_index] = mitos::clone_type_pattern(
    pattern, allocator
   );
  destination.operations[index] = clone;
 }
 destination.instances = alloc::new_array(
  allocator, mitos::DeltaEffectInstanceDescriptor, source.instances.len
 );
 foreach (index, &instance : source.instances)
 {
  destination.instances[index] = {
   .key = mitos::clone_symbol_key(&instance.key, allocator),
   .id = instance.id,
   .constructor = instance.constructor,
   .arguments = alloc::clone_slice(allocator, instance.arguments),
  };
 }
 destination.rows = alloc::new_array(
  allocator, mitos::DeltaEffectRowDescriptor, source.rows.len
 );
 foreach (index, &row : source.rows)
 {
  destination.rows[index] = {
   .key = mitos::clone_symbol_key(&row.key, allocator),
   .function_index = row.function_index,
   .inferred = mitos::clone_resolved_effect_row(&row.inferred, allocator),
   .asserted = mitos::clone_resolved_effect_row(&row.asserted, allocator),
   .has_assertion = row.has_assertion,
   .effect_epoch = row.effect_epoch,
  };
 }
 destination.handlers = alloc::new_array(
  allocator, mitos::DeltaHandlerDescriptor, source.handlers.len
 );
 foreach (index, &handler : source.handlers)
 {
  mitos::DeltaHandlerDescriptor clone = {
   .stable_id = handler.stable_id,
   .handled = handler.handled,
   .return_parameter = handler.return_parameter.copy(allocator),
   .return_type = handler.return_type,
   .return_body = handler.return_body,
   .span = handler.span,
   .source_order = handler.source_order,
  };
  clone.clauses = alloc::new_array(
   allocator, mitos::DeltaHandlerClauseDescriptor, handler.clauses.len
  );
  foreach (clause_index, &clause : handler.clauses)
  {
   clone.clauses[clause_index] = {
    .key = mitos::clone_symbol_key(&clause.key, allocator),
    .stable_id = clause.stable_id,
    .effect = clause.effect,
    .operation = clause.operation,
    .parameters = typed_delta_clone_strings(
     clause.parameters, allocator
    ),
    .parameter_types = alloc::clone_slice(
     allocator, clause.parameter_types
    ),
    .result_type = clause.result_type,
    .body = clause.body,
    .span = clause.span,
    .resume_count = clause.resume_count,
    .multi = clause.multi,
   };
  }
  destination.handlers[index] = clone;
 }
}

fn mitos::DeltaProgram* typed_delta_clone_program(
 mitos::DeltaProgram* source,
 Allocator allocator
) @private
{
 mitos::DeltaProgram* clone = alloc::new(
  allocator,
  mitos::DeltaProgram,
  {
   .allocator = allocator,
   .runtime_identity = source.runtime_identity,
   .module_key = mitos::clone_module_key(&source.module_key, allocator),
   .schema = source.schema,
   .feature_manifest = source.feature_manifest,
   .entry = source.entry,
   .helper_abi = source.helper_abi,
  }
 );
 typed_delta_clone_type_registry(&clone.types, &source.types, allocator);
 typed_delta_clone_methods(&clone.methods, &source.methods, allocator);
 clone.constructors = alloc::new_array(
  allocator, mitos::DeltaConstructorDescriptor, source.constructors.len
 );
 foreach (index, &constructor : source.constructors)
 {
  mitos::DeltaConstructorDescriptor copy = {
   .key = mitos::clone_symbol_key(&constructor.key, allocator),
   .id = constructor.id,
   .name = constructor.name.copy(allocator),
   .runtime_type = constructor.runtime_type,
   .type_constructor = constructor.type_constructor,
   .parameters = typed_delta_clone_strings(
    constructor.parameters, allocator
   ),
   .fields = typed_delta_clone_strings(constructor.fields, allocator),
   .field_types = alloc::clone_slice(allocator, constructor.field_types),
   .span = constructor.span,
  };
  copy.field_patterns = alloc::new_array(
   allocator, mitos::TypePattern, constructor.field_patterns.len
  );
  foreach (pattern_index, &pattern : constructor.field_patterns)
   copy.field_patterns[pattern_index] = mitos::clone_type_pattern(
    pattern, allocator
   );
  clone.constructors[index] = copy;
 }
 clone.primitives = alloc::new_array(
  allocator, mitos::DeltaPrimitiveDescriptor, source.primitives.len
 );
 foreach (index, &primitive : source.primitives)
 {
  clone.primitives[index] = {
   .key = mitos::clone_symbol_key(&primitive.key, allocator),
   .id = primitive.id,
   .operation = primitive.operation,
   .name = primitive.name.copy(allocator),
   .arity = primitive.arity,
   .parameters = alloc::clone_slice(allocator, primitive.parameters),
   .result = primitive.result,
  };
 }
 clone.image.nodes = alloc::new_array(
  allocator, mitos::DeltaNode, source.image.nodes.len
 );
 foreach (index, &node : source.image.nodes)
  clone.image.nodes[index] = typed_delta_clone_node(node, allocator);
 clone.image.edges = alloc::clone_slice(allocator, source.image.edges);
 clone.image.interfaces = alloc::new_array(
  allocator, mitos::DeltaInterface, source.image.interfaces.len
 );
 foreach (index, &boundary : source.image.interfaces)
 {
  clone.image.interfaces[index] = {
   .key = mitos::clone_symbol_key(&boundary.key, allocator),
   .kind = boundary.kind,
   .name = boundary.name.copy(allocator),
   .root = boundary.root,
   .source_order = boundary.source_order,
  };
 }
 clone.image.parallel_regions = alloc::new_array(
  allocator, mitos::DeltaParallelRegion, source.image.parallel_regions.len
 );
 foreach (index, &region : source.image.parallel_regions)
 {
  clone.image.parallel_regions[index] = {
   .roots = alloc::clone_slice(allocator, region.roots),
   .join = region.join,
   .source_order = region.source_order,
  };
 }
 clone.method_roots = alloc::new_array(
  allocator, mitos::DeltaMethodRoot, source.method_roots.len
 );
 foreach (index, &root : source.method_roots)
  clone.method_roots[index] = typed_delta_clone_method_root(root, allocator);
 clone.spans = alloc::clone_slice(allocator, source.spans);
 typed_delta_clone_effects(&clone.effects, &source.effects, allocator);
 return clone;
}

struct TypedDeltaContext
{
 Allocator allocator;
 mitos::DeltaProgram* program;
 List{TypedDeltaValue*} values;
 mitos::DeltaProgram* owned_program;
 TypedDeltaRetainedAllocator program_allocator;
 List{TypedDeltaBinding[]} environments;
 List{TypedDeltaExternalLane} external_lanes;
 TypedDeltaExecutionStats stats;
 usz steps;
 usz owned_bytes;
 usz accounted_program_bytes;
 usz accounted_storage_bytes;
 usz storage_payload_bytes;
 usz accounted_storage_payload_bytes;
 usz value_count;
 usz environment_count;
 usz max_owned_bytes;
 usz max_values;
 usz max_environments;
 Mutex* shared_budget_mutex;
 usz* shared_owned_bytes;
 usz* shared_value_count;
 usz* shared_environment_count;
 usz* shared_steps;
 bool shared_budget_exhausted;
 bool failed;
 DeltaDiagnostic diagnostic;
 uint active_span;
 TypedDeltaHandlerActivation* activation;
 usz parallel_source_order;
 usz current_occurrence_order;
 TypedDeltaSubstitution* substitution;
 TypedDeltaContext* external_owner;
 TypedDeltaHandlerScope* handler_scope;
 usz external_lane_index;
 bool external_lane_cached;
 TypedDeltaPool* pool;
 TypedDeltaHostSnapshotEntry[] host_entries;
 bool owns_host_entries;
 mitos_storage::StorageRuntime local_storage;
 mitos_storage::StorageRuntime* storage;
 bool owns_storage;
 bool worker_active;
}

struct TypedDeltaJob
{
 TypedDeltaContext context;
 mitos::DeltaNodeId node;
 TypedDeltaEnvironment environment;
 usz source_order;
 usz output_index;
 TypedDeltaValue* value;
}
struct TypedDeltaBatch
{
 TypedDeltaJob[] jobs;
 usz next_index;
 usz completed;
}
struct TypedDeltaPool
{
 Mutex mutex;
 Mutex budget_mutex;
 ConditionVariable work_available;
 ConditionVariable batch_completed;
 Thread[] threads;
 usz created_threads;
 TypedDeltaBatch* batch;
 bool stopping;
}

struct TypedDeltaSuspension @private
{
 TypedDeltaContext* context;
 TypedDeltaValue* request;
 mitos::TypeId result_type;
 ulong effect_epoch;
 bool live;
}
fn mitos::MitosSpan typed_delta_active_span(TypedDeltaContext* context) @private
{
 if (context.active_span && context.active_span <= context.program.spans.len)
 {
  return context.program.spans[context.active_span - 1];
 }
 return { };
}
fn void typed_delta_fail(TypedDeltaContext* context, String message) @private
{
 if (context.failed) return;
 context.failed = true;
 context.diagnostic.init(
  context.allocator, message, typed_delta_active_span(context)
 );
}
fn void typed_delta_fail_storage(
 TypedDeltaContext* context,
 mitos_storage::StorageError error
) @private
{
 if (context.shared_budget_mutex
  && error == mitos_storage::StorageError.STORAGE_LIMIT)
 {
  context.shared_budget_exhausted = true;
 }
 typed_delta_fail(context, mitos_storage::storage_error_message(error));
}
fn bool typed_delta_assert_type(
 TypedDeltaContext* context,
 mitos::TypeId actual,
 mitos::TypeId expected
) @private
{
 if (expected == mitos::TYPE_ID_ANY) return true;
 mitos::MitosDiagnostic diagnostic;
 typed_delta_lock_registry(context);
 bool valid = mitos::validate_runtime_annotation(
  &context.program.types,
  actual,
  expected,
  &diagnostic,
  typed_delta_active_span(context)
 );
 typed_delta_unlock_registry(context);
 if (valid) return true;
 typed_delta_fail(context, diagnostic.message);
 diagnostic.deinit();
 return false;
}
fn bool typed_delta_charge(
 TypedDeltaContext* context,
 usz bytes,
 bool value = false,
 bool environment = false
) @private
{
 usz byte_limit = context.max_owned_bytes
  ? context.max_owned_bytes : TYPED_DELTA_MAX_OWNED_BYTES;
 usz value_limit = context.max_values
  ? context.max_values : TYPED_DELTA_MAX_VALUES;
 usz environment_limit = context.max_environments
  ? context.max_environments : TYPED_DELTA_MAX_ENVIRONMENTS;
 bool accepted;
 if (context.shared_budget_mutex)
 {
  context.shared_budget_mutex.lock();
  accepted = *context.shared_owned_bytes <= byte_limit
   && bytes <= byte_limit - *context.shared_owned_bytes
   && *context.shared_value_count <= value_limit
   && *context.shared_environment_count <= environment_limit
   && (!value || *context.shared_value_count < value_limit)
   && (!environment || *context.shared_environment_count < environment_limit);
  if (accepted)
  {
   *context.shared_owned_bytes += bytes;
   if (value) (*context.shared_value_count)++;
   if (environment) (*context.shared_environment_count)++;
  }
  context.shared_budget_mutex.unlock();
  if (!accepted) context.shared_budget_exhausted = true;
 }
 else
 {
  accepted = context.owned_bytes <= byte_limit
   && bytes <= byte_limit - context.owned_bytes
   && context.value_count <= value_limit
   && context.environment_count <= environment_limit
   && (!value || context.value_count < value_limit)
   && (!environment || context.environment_count < environment_limit);
 }
 if (!accepted)
 {
  typed_delta_fail(context, "typed Delta value/environment resource budget exceeded");
  return false;
 }
 context.owned_bytes += bytes;
 if (value) context.value_count++;
 if (environment) context.environment_count++;
 return true;
}

fn bool typed_delta_take_step(
 TypedDeltaContext* context,
 String failure
) @private
{
 bool accepted;
 if (context.shared_budget_mutex)
 {
  context.shared_budget_mutex.lock();
  accepted = *context.shared_steps < mitos::DELTA_MAX_EVALUATION_STEPS;
  if (accepted) (*context.shared_steps)++;
  context.shared_budget_mutex.unlock();
  if (!accepted) context.shared_budget_exhausted = true;
  if (accepted) context.steps++;
 }
 else
 {
  accepted = context.steps < mitos::DELTA_MAX_EVALUATION_STEPS;
  if (accepted) context.steps++;
 }
 if (accepted) return true;
 typed_delta_fail(context, failure);
 return false;
}
fn TypedDeltaValue* typed_delta_value(
 TypedDeltaContext* context,
 TypedDeltaValue value
) @private
{
 if (!typed_delta_charge(
  context,
  (usz)TypedDeltaValue::size + (usz)usz::size,
  true
 )) return null;
 TypedDeltaValue* owned = alloc::new(
  context.allocator, TypedDeltaValue, value
 );
 context.values.push(owned);
 return owned;
}
fn bool typed_delta_is_effect(TypedDeltaValue* value) @private
{
	return value && value.kind == TYPED_VALUE_EFFECT_REQUEST;
}

fn void typed_delta_lock_registry(TypedDeltaContext* context) @private
{
 if (context.pool) context.pool.mutex.lock();
}
fn void typed_delta_unlock_registry(TypedDeltaContext* context) @private
{
 if (context.pool) context.pool.mutex.unlock();
}
fn bool typed_delta_layout(
 TypedDeltaContext* context,
 mitos::TypeId type_id,
 mitos::LayoutDescriptor* layout
) @private
{
 typed_delta_lock_registry(context);
 mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
  &context.program.types, type_id
 );
 if (descriptor) *layout = descriptor.layout;
 typed_delta_unlock_registry(context);
 return descriptor != null;
}

fn bool typed_delta_concrete_type(
 TypedDeltaContext* context,
 mitos::TypeId type_id
) @private
{
 typed_delta_lock_registry(context);
 mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
  &context.program.types, type_id
 );
 bool concrete = descriptor
  && descriptor.kind != mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_ABSTRACT;
 typed_delta_unlock_registry(context);
 return concrete;
}
fn mitos::DeltaOperationDescriptor* typed_delta_operation(
 TypedDeltaContext* context,
 usz index
) @private
{
 if (index >= context.program.effects.operations.len) return null;
 return &context.program.effects.operations[index];
}

fn TypedDeltaValue* typed_delta_effect_request(
 TypedDeltaContext* context,
 usz operation,
 mitos::DeltaNodeId effect_node,
 TypedDeltaValue*[] arguments,
 mitos::EffectId effect_instance,
 usz occurrence_order,
 mitos::TypeId result_type
) @private
{
 return typed_delta_value(context, {
  .kind = TYPED_VALUE_EFFECT_REQUEST,
  .type_id = result_type,
  .effect_operation = operation,
  .effect_node = effect_node,
  .effect_arguments = arguments,
  .effect_instance = effect_instance,
  .effect_source_order = context.parallel_source_order,
  .effect_occurrence_order = occurrence_order,
  .effect_result_type = result_type,
 });
}
fn TypedDeltaValue* typed_delta_i64(TypedDeltaContext* context, long value) @private
{
 return typed_delta_value(context, { .kind = TYPED_VALUE_I64, .type_id = mitos::TYPE_ID_I64, .integer = value });
}
fn TypedDeltaValue* typed_delta_bool(TypedDeltaContext* context, bool value) @private
{
 return typed_delta_value(context, { .kind = TYPED_VALUE_BOOL, .type_id = mitos::TYPE_ID_BOOL, .boolean = value });
}
fn TypedDeltaValue* typed_delta_unit(TypedDeltaContext* context) @private
{
 return typed_delta_value(context, { .kind = TYPED_VALUE_UNIT, .type_id = mitos::TYPE_ID_UNIT });
}
fn TypedDeltaValue* typed_delta_string(TypedDeltaContext* context, String source) @private
{
 if (!typed_delta_charge(context, source.len)) return null;
 mitos::LayoutDescriptor descriptor;
 if (!typed_delta_layout(context, mitos::TYPE_ID_STRING, &descriptor))
 {
  typed_delta_fail(context, "String has no runtime layout");
  return null;
 }
 mitos_storage::LayoutHandleResult layout = mitos_storage::register_layout(
  context.storage, mitos::TYPE_ID_STRING, &descriptor
 );
 if (layout.error != mitos_storage::StorageError.STORAGE_OK)
 {
  typed_delta_fail_storage(context, layout.error);
  return null;
 }
 mitos_storage::StorageHandleResult stored = mitos_storage::allocate_shared_bytes(
  context.storage, layout.handle, source, 1, 1, 1
 );
 if (stored.error != mitos_storage::StorageError.STORAGE_OK)
 {
  typed_delta_fail_storage(context, stored.error);
  return null;
 }
 context.storage_payload_bytes += source.len;
 TypedDeltaValue* value = typed_delta_value(context, {
  .kind = TYPED_VALUE_STRING,
  .type_id = mitos::TYPE_ID_STRING,
  .storage = stored.handle,
  .storage_count = source.len,
  .storage_stride = 1,
 });
 if (!value) (void)mitos_storage::release(context.storage, stored.handle);
 return value;
}
fn TypedDeltaValue* typed_delta_type(TypedDeltaContext* context, mitos::TypeId represented) @private
{
 mitos::TypeId runtime_type;
 mitos::MitosDiagnostic diagnostic;
 typed_delta_lock_registry(context);
 bool interned = mitos::intern_type_value_type(
  &context.program.types,
  represented,
  &runtime_type,
  &diagnostic,
  typed_delta_active_span(context)
 );
 typed_delta_unlock_registry(context);
 if (!interned)
 {
  typed_delta_fail(context, diagnostic.message);
  diagnostic.deinit();
  return null;
 }
 return typed_delta_value(context, {
  .kind = TYPED_VALUE_TYPE,
  .type_id = runtime_type,
  .represented_type = represented,
 });
}

fn mitos::TypeId typed_delta_aggregate_type(
	TypedDeltaContext* context,
	mitos::TypeId constructor,
	mitos::TypeId element_type
) @private
{
	mitos::TypeId[1] arguments = { element_type };
	mitos::TypeId aggregate_type;
	mitos::MitosDiagnostic diagnostic;
	typed_delta_lock_registry(context);
	bool interned = mitos::intern_type(
		&context.program.types,
		constructor,
		arguments[..],
		&aggregate_type,
		&diagnostic,
		typed_delta_active_span(context)
	);
	typed_delta_unlock_registry(context);
	if (!interned)
	{
		typed_delta_fail(context, diagnostic.message);
		diagnostic.deinit();
		return mitos::TYPE_ID_INVALID;
	}
	return aggregate_type;
}

fn bool typed_delta_assignments_equal(
	TypedDeltaAssignment[] left,
	TypedDeltaAssignment[] right
) @private
{
	if (left.len != right.len) return false;
	foreach (index, assignment : left)
	{
		if (assignment.origin != right[index].origin
			|| assignment.branch != right[index].branch) return false;
	}
	return true;
}

fn void typed_delta_free_alternatives(
	TypedDeltaContext* context,
	TypedDeltaAlternative[] alternatives
) @private
{
	foreach (&alternative : alternatives)
		alloc::free(context.allocator, alternative.assignments);
	alloc::free(context.allocator, alternatives);
}

fn TypedDeltaValue* typed_delta_superposition_owned(
	TypedDeltaContext* context,
	TypedDeltaAlternative[] alternatives,
	ulong origin
) @private
{
	if (!origin || !alternatives.len || alternatives.len > TYPED_DELTA_MAX_ALTERNATIVES)
	{
		typed_delta_fail(
			context,
			"superposition must contain a stable origin and at least one compatible alternative"
		);
		typed_delta_free_alternatives(context, alternatives);
		return null;
	}
	mitos::TypeId element_type = mitos::TYPE_ID_INVALID;
	foreach (&alternative : alternatives)
	{
		if (!alternative.value
			|| alternative.value.kind == TYPED_VALUE_SUPERPOSITION
			|| (element_type && alternative.value.type_id != element_type))
		{
			typed_delta_fail(context, "superposition alternatives must have one concrete runtime TypeId");
			typed_delta_free_alternatives(context, alternatives);
			return null;
		}
		if (!element_type) element_type = alternative.value.type_id;
	}
	if (!typed_delta_concrete_type(context, element_type))
	{
		typed_delta_fail(
			context,
			"superposition alternatives require a concrete runtime TypeId"
		);
		typed_delta_free_alternatives(context, alternatives);
		return null;
	}
	mitos::TypeId aggregate_type = typed_delta_aggregate_type(
		context, mitos::TYPE_ID_SUPERPOSITION, element_type
	);
	if (!aggregate_type)
	{
		typed_delta_free_alternatives(context, alternatives);
		return null;
	}
	TypedDeltaValue* value = typed_delta_value(context, {
		.kind = TYPED_VALUE_SUPERPOSITION,
		.type_id = aggregate_type,
		.alternatives = alternatives,
		.origin = origin,
	});
	if (!value) typed_delta_free_alternatives(context, alternatives);
	return value;
}

fn bool typed_delta_dense_array_storage(
 TypedDeltaContext* context,
 TypedDeltaValue*[] elements,
 mitos::TypeId element_type,
 mitos::TypeId aggregate_type,
 mitos_storage::StorageHandle* storage,
 usz* stride
) @private
{
 usz element_stride;
 if (element_type == mitos::TYPE_ID_I64)
 {
  element_stride = 8;
 }
 else if (element_type == mitos::TYPE_ID_BOOL || element_type == mitos::TYPE_ID_UNIT)
 {
  element_stride = 1;
 }
 else
 {
  if (!elements.len || elements[0].kind != TYPED_VALUE_TYPE) return false;
  element_stride = 4;
 }
 if (elements.len > usz::max / element_stride)
 {
  typed_delta_fail(context, "dense Array storage size overflow");
  return false;
 }
 usz byte_count = elements.len * element_stride;
 if (!typed_delta_charge(context, byte_count)) return false;
 char[] bytes = alloc::new_array(context.allocator, char, (sz)byte_count);
 foreach (&byte : bytes) *byte = 0;
 foreach (index, element : elements)
 {
  if (!element || element.type_id != element_type)
  {
   alloc::free(context.allocator, bytes);
   return false;
  }
  ulong bits;
  if (element_stride == 8 && element.kind == TYPED_VALUE_I64)
  {
   bits = (ulong)element.integer;
  }
  else if (element_stride == 1 && element.kind == TYPED_VALUE_BOOL)
  {
   bits = element.boolean ? 1 : 0;
  }
  else if (element_stride == 1 && element.kind == TYPED_VALUE_UNIT)
  {
   bits = 0;
  }
  else if (element_stride == 4 && element.kind == TYPED_VALUE_TYPE)
  {
   bits = (ulong)element.represented_type;
  }
  else
  {
   alloc::free(context.allocator, bytes);
   return false;
  }
  for (usz byte = 0; byte < element_stride; byte++)
  {
   bytes[(usz)index * element_stride + byte] = (char)(bits >> (byte * 8));
  }
 }
 mitos::LayoutDescriptor aggregate;
 mitos::LayoutDescriptor element;
 if (!typed_delta_layout(context, aggregate_type, &aggregate)
  || !typed_delta_layout(context, element_type, &element))
 {
  alloc::free(context.allocator, bytes);
  return false;
 }
 mitos_storage::LayoutHandleResult layout = mitos_storage::register_layout(
  context.storage, aggregate_type, &aggregate
 );
 if (layout.error != mitos_storage::StorageError.STORAGE_OK)
 {
  alloc::free(context.allocator, bytes);
  typed_delta_fail_storage(context, layout.error);
  return false;
 }
 usz alignment = (usz)element.alignment;
 if (!typed_delta_charge(context, byte_count))
 {
  alloc::free(context.allocator, bytes);
  return false;
 }
 mitos_storage::StorageHandleResult allocated = mitos_storage::allocate_shared_bytes(
  context.storage, layout.handle, bytes, alignment, element_stride, element_stride
 );
 alloc::free(context.allocator, bytes);
 if (allocated.error != mitos_storage::StorageError.STORAGE_OK)
 {
  typed_delta_fail_storage(context, allocated.error);
  return false;
 }
 context.storage_payload_bytes += byte_count;
 *storage = allocated.handle;
 *stride = element_stride;
 return true;
}

fn TypedDeltaValue* typed_delta_array_owned(
 TypedDeltaContext* context,
 TypedDeltaValue*[] elements,
 mitos::TypeId element_type
) @private
{
 mitos::TypeId aggregate_type = typed_delta_aggregate_type(
  context, mitos::TYPE_ID_ARRAY, element_type
 );
 if (!aggregate_type)
 {
  alloc::free(context.allocator, elements);
  return null;
 }
 mitos_storage::StorageHandle storage = { };
 usz storage_stride = 0;
 bool dense = typed_delta_dense_array_storage(
  context, elements, element_type, aggregate_type, &storage, &storage_stride
 );
 if (context.failed)
 {
  alloc::free(context.allocator, elements);
  return null;
 }
 TypedDeltaValue* value = typed_delta_value(context, {
  .kind = TYPED_VALUE_ARRAY,
  .type_id = aggregate_type,
  .elements = elements,
  .storage = storage,
  .storage_count = dense ? elements.len : 0,
  .storage_stride = dense ? storage_stride : 0,
 });
 if (!value)
 {
  if (dense) (void)mitos_storage::release(context.storage, storage);
  alloc::free(context.allocator, elements);
 }
 return value;
}
fn TypedDeltaBinding[] typed_delta_environment(
 TypedDeltaContext* context,
 TypedDeltaEnvironment base,
 usz additions
) @private
{
 if (additions > usz::max - base.bindings.len)
 {
  typed_delta_fail(context, "typed Delta environment size overflow");
  return { };
 }
 usz count = base.bindings.len + additions;
 if (count > (usz::max - (usz)usz::size) / (usz)TypedDeltaBinding::size)
 {
  typed_delta_fail(context, "typed Delta environment size overflow");
  return { };
 }
 usz bytes = count * (usz)TypedDeltaBinding::size + (usz)usz::size;
 if (!typed_delta_charge(context, bytes, false, true)) return { };
 TypedDeltaBinding[] bindings = alloc::new_array(
  context.allocator, TypedDeltaBinding, (sz)count
 );
 foreach (index, binding : base.bindings) bindings[index] = binding;
 context.environments.push(bindings);
 return bindings;
}
fn TypedDeltaValue* typed_delta_lookup(
 TypedDeltaContext* context,
 TypedDeltaEnvironment environment,
 String name
) @private
{
	for (sz index = environment.bindings.len - 1; index >= 0; index--)
	{
		if (environment.bindings[index].name == name) return environment.bindings[index].value;
	}
	typed_delta_fail(context, "Delta local is absent from its instantiated environment");
	return null;
}

fn TypedDeltaValue* typed_delta_apply_values(
	TypedDeltaContext* context,
	TypedDeltaValue* function,
	mitos::DeltaNode* application,
	TypedDeltaValue*[] arguments,
	usz depth
) @private
{
	if (!function || function.kind != TYPED_VALUE_CLOSURE)
	{
		typed_delta_fail(context, "attempted to apply a non-function Delta value");
		return null;
	}
	usz argument_count = application.inputs.len - 1;
	if (argument_count != function.closure.parameters.len
		|| arguments.len != argument_count)
	{
		typed_delta_fail(context, "lambda application arity mismatch");
		return null;
	}
	foreach (index, argument : arguments)
	{
		if (!typed_delta_assert_type(
			context,
			argument.type_id,
			function.closure.parameter_types[index]
		)) return null;
	}
	TypedDeltaBinding[] bindings = typed_delta_environment(
		context, function.closure.environment, argument_count
	);
	if (context.failed
		|| bindings.len != function.closure.environment.bindings.len
			+ argument_count) return null;
	usz offset = function.closure.environment.bindings.len;
	foreach (index, parameter : function.closure.parameters)
		bindings[offset + (usz)index] = {
			.name = parameter,
			.value = arguments[index],
		};
	TypedDeltaValue* result = typed_delta_evaluate(
		context, function.closure.body, { .bindings = bindings }, depth + 1
	);
	if (context.failed) return null;
	if (typed_delta_is_effect(result))
	{
		if (!mitos::resolved_effect_row_allows(
			function.closure.effect_row, result.effect_instance
		))
		{
			typed_delta_fail(context, "effect escaped a lambda's resolved effect row");
			return null;
		}
		return result;
	}
	if (!typed_delta_assert_type(
		context, result.type_id, function.closure.result_type
	)) return null;
	return result;
}

fn String typed_delta_method_binding_name(
 mitos::MethodDescriptor* method,
 String dispatched
) @private
{
 foreach (variable : method.type_variables)
  if (variable == dispatched) return variable;
 return "";
}

fn TypedDeltaValue* typed_delta_dispatch_values(
	TypedDeltaContext* context,
	mitos::DeltaNode* call,
	TypedDeltaValue*[] arguments,
	usz depth
) @private
{
	usz arity = call.inputs.len;
	if (arguments.len != arity)
	{
		typed_delta_fail(context, "generic call argument layout is inconsistent");
		return null;
	}
	if (!typed_delta_charge(
		context, arity * (usz)mitos::TypeId::size
	)) return null;
	mitos::TypeId[] actual = alloc::new_array(
		context.allocator, mitos::TypeId, (sz)arity
	);
	defer alloc::free(context.allocator, actual);
	foreach (index, argument : arguments) actual[index] = argument.type_id;
	mitos::MitosSpan span = { };
	if (call.span && call.span <= context.program.spans.len)
	{
		span = context.program.spans[call.span - 1];
	}
	if (call.descriptor >= (usz)context.program.methods.generics.len())
	{
		typed_delta_fail(context, "generic call carries an invalid dense handle");
		return null;
	}
	mitos::GenericFunction* called_generic =
		&context.program.methods.generics[(sz)call.descriptor];
	if (!mitos::symbol_key_equal(&call.key, &called_generic.key))
	{
		typed_delta_fail(context, "generic call key disagrees with its dense handle");
		return null;
	}
 typed_delta_lock_registry(context);
 // Canonical key equality above validates the compact local dispatch handle.
 mitos::DispatchResult dispatch = mitos::dispatch_method(
  &context.program.methods,
  &context.program.types,
  called_generic.name,
  actual,
  context.allocator,
  span,
  &call.key
 );
 typed_delta_unlock_registry(context);
 defer dispatch.deinit();
	if (!dispatch.matched)
	{
		typed_delta_fail(context, dispatch.diagnostic.message);
		return null;
	}
	context.stats.dispatches++;
	mitos::GenericFunction* generic = &context.program.methods.generics[(sz)dispatch.generic_index];
	mitos::MethodDescriptor* method = &generic.methods[(sz)dispatch.method_index];
	mitos::DeltaMethodRoot* root = method.function_index < context.program.method_roots.len
		? &context.program.method_roots[(sz)method.function_index] : null;
	if (!root
		|| root.function_index != method.function_index
		|| !mitos::symbol_key_equal(&root.key, &method.key)
		|| root.parameters.len != arity)
	{
		typed_delta_fail(context, "selected method has no consistent Delta body root");
		return null;
	}
 if (dispatch.bindings.len > usz::max - arity)
 {
  typed_delta_fail(context, "selected method type bindings exceed their resource bound");
  return null;
 }
 usz binding_count = arity + dispatch.bindings.len;
	TypedDeltaBinding[] bindings = typed_delta_environment(
  context, { }, binding_count
 );
 if (context.failed || bindings.len != binding_count) return null;
	foreach (index, parameter : root.parameters)
		bindings[index] = { .name = parameter, .value = arguments[index] };
	foreach (index, &binding : dispatch.bindings)
	{
  String stable_name = typed_delta_method_binding_name(
   method, binding.variable
  );
  if (!stable_name.len)
  {
   typed_delta_fail(
    context, "selected method returned a non-canonical type-variable binding"
   );
   return null;
  }
  TypedDeltaValue* type_value = typed_delta_type(context, binding.type_id);
  if (!type_value) return null;
		bindings[arity + (usz)index] = {
			.name = stable_name,
			.value = type_value,
		};
	}
	TypedDeltaValue* selected_value = typed_delta_evaluate(
		context,
		root.root,
		{ .bindings = bindings },
		depth + 1
	);
	if (context.failed) return null;
	if (typed_delta_is_effect(selected_value))
	{
		if (!mitos::resolved_effect_row_allows(
			&root.effect_row, selected_value.effect_instance
		))
		{
			typed_delta_fail(context, "effect escaped a method's resolved effect row");
			return null;
		}
  return selected_value;
	}
	mitos::TypeId expected_result;
	typed_delta_lock_registry(context);
	bool resolved_result = mitos::resolve_method_result_type(
		&context.program.types,
		method,
		dispatch.bindings,
		&expected_result
	);
	typed_delta_unlock_registry(context);
	if (!resolved_result)
	{
		typed_delta_fail(context, "selected method result type could not be instantiated");

		return null;
	}
 if (!typed_delta_assert_type(
  context, selected_value.type_id, expected_result
 )) return null;
	return selected_value;
}
fn bool typed_delta_equal(
 TypedDeltaContext* context,
 TypedDeltaValue* left,
 TypedDeltaValue* right,
 usz depth = 0
) @private
{
 if (left == right) return true;
 if (!left || !right || left.kind != right.kind
  || depth >= TYPED_DELTA_MAX_NATIVE_DEPTH) return false;
 switch (left.kind)
 {
  case TYPED_VALUE_I64: return left.integer == right.integer;
  case TYPED_VALUE_BOOL: return left.boolean == right.boolean;
  case TYPED_VALUE_UNIT: return true;
  case TYPED_VALUE_STRING:
   bool equal;
   mitos_storage::StorageError compared = mitos_storage::bytes_equal(
    context.storage, left.storage, right.storage, &equal
   );
   if (compared != mitos_storage::StorageError.STORAGE_OK)
   {
    typed_delta_fail_storage(context, compared);
    return false;
   }
   return equal;
  case TYPED_VALUE_TYPE: return left.represented_type == right.represented_type;
  case TYPED_VALUE_CONSTRUCTOR:
   if (left.constructor != right.constructor
    || left.type_id != right.type_id
    || left.fields.len != right.fields.len) return false;
   foreach (index, field : left.fields)
    if (!typed_delta_equal(
     context, field, right.fields[index], depth + 1
    )) return false;
   return true;
  case TYPED_VALUE_ARRAY:
   if (left.type_id != right.type_id
    || left.elements.len != right.elements.len) return false;
   foreach (index, element : left.elements)
    if (!typed_delta_equal(
     context, element, right.elements[index], depth + 1
    )) return false;
   return true;
  case TYPED_VALUE_SUPERPOSITION:
   if (left.type_id != right.type_id
    || left.origin != right.origin
    || left.alternatives.len != right.alternatives.len) return false;
   foreach (index, &alternative : left.alternatives)
   {
    if (!typed_delta_assignments_equal(
     alternative.assignments,
     right.alternatives[index].assignments
    ) || !typed_delta_equal(
     context,
     alternative.value,
     right.alternatives[index].value,
     depth + 1
    )) return false;
   }
   return true;
  default: return false;
 }
}

fn bool typed_delta_request_charge(
 TypedDeltaContext* context,
 usz* bytes,
 usz addition
) @private
{
 if (*bytes > TYPED_DELTA_MAX_OWNED_BYTES
  || addition > TYPED_DELTA_MAX_OWNED_BYTES - *bytes)
 {
  typed_delta_fail(context, "external effect request view exceeds its resource bound");
  return false;
 }
 *bytes += addition;
 return true;
}

fn bool typed_delta_copy_storage_string(
 TypedDeltaContext* context,
 TypedDeltaValue* value,
 String* copied,
 usz* request_bytes = null,
 usz maximum_bytes = usz::max
) @private
{
 usz length;
 mitos_storage::StorageError measured = mitos_storage::byte_length(
  context.storage, value.storage, &length
 );
 if (measured != mitos_storage::StorageError.STORAGE_OK)
 {
  typed_delta_fail_storage(context, measured);
  return false;
 }
 if (length > maximum_bytes)
 {
  typed_delta_fail(context, "formatted result exceeds the byte limit");
  return false;
 }
 if (request_bytes)
 {
  if (!typed_delta_request_charge(context, request_bytes, length)) return false;
 }
 else if (!typed_delta_charge(context, length)) return false;
 char[] bytes = alloc::new_array(context.allocator, char, (sz)length);
 mitos_storage::StorageError read = mitos_storage::copy_all(
  context.storage, value.storage, bytes
 );
 if (read != mitos_storage::StorageError.STORAGE_OK)
 {
  alloc::free(context.allocator, bytes);
  typed_delta_fail_storage(context, read);
  return false;
 }
 *copied = (String)bytes;
 return true;
}

fn bool typed_delta_host_view(
 TypedDeltaContext* context,
 TypedDeltaValue* value,
 TypedDeltaHostValue* view,
 usz* request_bytes = null
) @private
{
 *view = {
  .type_id = value ? value.type_id : mitos::TYPE_ID_INVALID,
 };
 if (!value) return true;
 switch (value.kind)
 {
  case TYPED_VALUE_I64:
   view.kind = HOST_VALUE_I64;
   view.integer = value.integer;
  case TYPED_VALUE_BOOL:
   view.kind = HOST_VALUE_BOOL;
   view.boolean = value.boolean;
  case TYPED_VALUE_UNIT:
   view.kind = HOST_VALUE_UNIT;
  case TYPED_VALUE_STRING:
   view.kind = HOST_VALUE_STRING;
   return typed_delta_copy_storage_string(
    context, value, &view.string, request_bytes
   );
  case TYPED_VALUE_CONSTRUCTOR:
   typed_delta_fail(
    context,
    "external effect host ABI 2.0 cannot represent constructor arguments"
   );
   return false;
  case TYPED_VALUE_CLOSURE:
   view.kind = HOST_VALUE_FUNCTION;
  case TYPED_VALUE_TYPE:
   view.kind = HOST_VALUE_TYPE;
   view.represented_type = value.represented_type;
  default: ;
 }
 return true;
}

fn bool typed_delta_host_value_is_valid(
 TypedDeltaContext* context,
 TypedDeltaHostValue value
) @private
{
 switch (value.kind)
 {
  case HOST_VALUE_I64:
   return value.type_id == mitos::TYPE_ID_I64;
  case HOST_VALUE_BOOL:
   return value.type_id == mitos::TYPE_ID_BOOL;
  case HOST_VALUE_UNIT:
   return value.type_id == mitos::TYPE_ID_UNIT;
  case HOST_VALUE_STRING:
   return value.type_id == mitos::TYPE_ID_STRING
    && (!value.string.len || value.string.ptr);
  case HOST_VALUE_TYPE:
   if (!value.type_id || !value.represented_type) return false;
   typed_delta_lock_registry(context);
   mitos::TypeDescriptor* runtime_descriptor = mitos::type_descriptor(
    &context.program.types, value.type_id
   );
   mitos::TypeDescriptor* represented_descriptor = mitos::type_descriptor(
    &context.program.types, value.represented_type
   );
   bool valid = runtime_descriptor && represented_descriptor
    && runtime_descriptor.kind
     == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
    && runtime_descriptor.constructor == mitos::TYPE_ID_TYPE
    && runtime_descriptor.arguments.len == 1
    && runtime_descriptor.arguments[0] == value.represented_type;
   typed_delta_unlock_registry(context);
   return valid;
  default: return false;
 }
}

fn TypedDeltaValue* typed_delta_from_host(
 TypedDeltaContext* context,
 TypedDeltaHostValue value
) @private
{
 if (!typed_delta_host_value_is_valid(context, value))
 {
  typed_delta_fail(
   context, "external effect helper returned an invalid host ABI 2.0 value"
  );
  return null;
 }
 switch (value.kind)
 {
  case HOST_VALUE_I64: return typed_delta_i64(context, value.integer);
  case HOST_VALUE_BOOL: return typed_delta_bool(context, value.boolean);
  case HOST_VALUE_UNIT: return typed_delta_unit(context);
  case HOST_VALUE_STRING: return typed_delta_string(context, value.string);
  case HOST_VALUE_TYPE:
   return typed_delta_type(context, value.represented_type);
  default: unreachable("validated host value kind became unreachable");
 }
}
fn bool typed_delta_host_resume_type(
 TypedDeltaContext* context,
 mitos::TypeId type_id
) @private
{
 if (type_id == mitos::TYPE_ID_I64 || type_id == mitos::TYPE_ID_BOOL
  || type_id == mitos::TYPE_ID_UNIT || type_id == mitos::TYPE_ID_STRING)
 {
  return true;
 }
 typed_delta_lock_registry(context);
 mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
  &context.program.types, type_id
 );
 bool representable = descriptor
  && descriptor.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
  && descriptor.constructor == mitos::TYPE_ID_TYPE
  && descriptor.arguments.len == 1
  && mitos::type_descriptor(
   &context.program.types, descriptor.arguments[0]
  ) != null;
 typed_delta_unlock_registry(context);
 return representable;
}

fn TypedDeltaHostHandlerEntry* typed_delta_host_handler(
 TypedDeltaContext* context,
 usz dense_handle
) @private
{
 usz low = 0;
 usz high = context.host_entries.len;
 while (low < high)
 {
  usz middle = low + (high - low) / 2;
  TypedDeltaHostSnapshotEntry* candidate = &context.host_entries[middle];
  if (candidate.dense_handle < dense_handle)
  {
   low = middle + 1;
  }
  else
  {
   high = middle;
  }
 }
 if (low >= context.host_entries.len
  || context.host_entries[low].dense_handle != dense_handle) return null;
 return &context.host_entries[low].handler;
}


fn void typed_delta_free_host_arguments(
 Allocator allocator,
 TypedDeltaHostValue[] arguments
) @private
{
 foreach (&argument : arguments)
 {
  if (argument.kind == HOST_VALUE_STRING)
  {
   alloc::free(allocator, argument.string);
  }
 }
 alloc::free(allocator, arguments);
}

fn TypedDeltaHostDisposition typed_delta_invoke_external(
 TypedDeltaContext* context,
 TypedDeltaValue* request,
 TypedDeltaValue** ready_result
) @private
{
 *ready_result = null;
 mitos::DeltaOperationDescriptor* operation = typed_delta_operation(
  context, request.effect_operation
 );
 if (!operation || operation.host_kind != DELTA_EFFECT_EXTERNAL)
 {
  typed_delta_fail(context, "escaped effect is not an external host operation");
  return HOST_FAIL;
 }
 foreach (argument : request.effect_arguments)
 {
  if (argument.kind == TYPED_VALUE_ARRAY
   || argument.kind == TYPED_VALUE_SUPERPOSITION)
  {
   typed_delta_fail(context, "external effect host helpers do not accept aggregate values");
   return HOST_FAIL;
  }
 }
 TypedDeltaHostHandlerEntry* matched = typed_delta_host_handler(
  context, request.effect_operation
 );
 if (!matched || !matched.handler)
 {
  typed_delta_fail(context, "external effect has no compatible registered host ABI 2.0 handler");
  return HOST_FAIL;
 }
 TypedDeltaHostHandlerEntry entry = *matched;
 if (entry.arity != request.effect_arguments.len)
 {
  typed_delta_fail(context, "external effect helper registration arity does not match the operation");
  return HOST_FAIL;
 }
 usz argument_bytes =
  request.effect_arguments.len * (usz)TypedDeltaHostValue::size;
 if (!typed_delta_charge(context, argument_bytes)) return HOST_FAIL;
 TypedDeltaHostValue[] arguments = alloc::new_array(
  context.allocator, TypedDeltaHostValue, (sz)request.effect_arguments.len
 );
 foreach (&argument : arguments) *argument = { };
 defer typed_delta_free_host_arguments(context.allocator, arguments);
 foreach (index, argument : request.effect_arguments)
 {
  if (!typed_delta_host_view(context, argument, &arguments[index]))
  {
   return HOST_FAIL;
  }
 }
 TypedDeltaHostCall call = {
  .abi_major = TYPED_DELTA_HOST_ABI_MAJOR,
  .abi_minor = TYPED_DELTA_HOST_ABI_MINOR,
  .effect = request.effect_instance,
  .operation = operation.id,
  .source_order = request.effect_source_order,
  .occurrence_order = request.effect_occurrence_order,
  .arguments = arguments,
 };
 TypedDeltaHostDisposition disposition = entry.handler(&call, entry.context);
 if (disposition == HOST_SUSPEND) return HOST_SUSPEND;
 if (disposition != HOST_READY)
 {
  typed_delta_fail(
   context,
   call.diagnostic.len
    ? call.diagnostic : "external effect host handler failed the operation"
  );
  return HOST_FAIL;
 }
 TypedDeltaValue* result = typed_delta_from_host(context, call.result);
 if (!result || !typed_delta_assert_type(
  context, result.type_id, request.effect_result_type
 )) return HOST_FAIL;
 context.stats.ordered_effect_commits++;
 *ready_result = result;
 return HOST_READY;
}

fn TypedDeltaHostDisposition typed_delta_console_host(
 TypedDeltaHostCall* call,
 void* ignored
) @private
{
 (void)ignored;
 if (call.arguments.len != 1 || call.arguments[0].kind != HOST_VALUE_STRING)
 {
  call.diagnostic = "Console.print requires one String argument";
  return HOST_FAIL;
 }
 io::printn(call.arguments[0].string);
 call.result = { .kind = HOST_VALUE_UNIT, .type_id = mitos::TYPE_ID_UNIT };
 return HOST_READY;
}
fn bool typed_delta_exact_host_type(
 mitos::TypePattern* pattern,
 mitos::TypeId type_id
) @private
{
 return pattern.kind == mitos::TypePatternKind.TYPE_PATTERN_EXACT
  && pattern.constructor == type_id
  && !pattern.variable.len
  && !pattern.arguments.len;
}

fn bool typed_delta_is_standard_console_print(
 mitos::DeltaProgram* program,
 mitos::DeltaEffectDescriptor* effect,
 mitos::DeltaOperationDescriptor* operation
) @private
{
 return effect.name == "Console" && !effect.parameters.len
  && mitos::symbol_key_is_canonical(&effect.key)
  && effect.key.kind == mitos::SymbolKind.SYMBOL_EFFECT
  && effect.key.name == effect.name && !effect.key.arity
  && mitos::module_key_equal(&effect.key.owner, &program.module_key)
  && operation.effect == effect.id && operation.name == "print"
  && operation.host_kind == DELTA_EFFECT_EXTERNAL
  && operation.parameter_patterns.len == 1
  && operation.parameter_types.len == 1
  && typed_delta_exact_host_type(
   &operation.parameter_types[0], mitos::TYPE_ID_STRING
  )
  && typed_delta_exact_host_type(
   &operation.result_type, mitos::TYPE_ID_UNIT
  )
  && mitos::symbol_key_is_canonical(&operation.key)
  && operation.key.kind == mitos::SymbolKind.SYMBOL_EFFECT_OPERATION
  && operation.key.name == operation.name && operation.key.arity == 1
  && mitos::module_key_equal(&operation.key.owner, &effect.key.owner);
}


fn bool DeltaRuntime.register_standard_host_handlers(
 &self,
 mitos::DeltaProgram* program
)
{
 if (!program) return false;
 bool registered = true;
 foreach (&effect : program.effects.effects)
 {
  foreach (operation_id : effect.operations)
  {
   if (!operation_id
    || (usz)operation_id > program.effects.operations.len) continue;
   usz operation_index = (usz)operation_id - 1;
   mitos::DeltaOperationDescriptor* operation =
    &program.effects.operations[operation_index];
   if (!typed_delta_is_standard_console_print(
    program, effect, operation
   )) continue;
   registered = self.register_host_handler(
    program, operation_index, &typed_delta_console_host
   ) && registered;
  }
 }
 return registered;
}

fn TypedDeltaValue* typed_delta_primitive_values(
	TypedDeltaContext* context,
	mitos::DeltaNode* node,
	TypedDeltaValue*[] arguments
) @private
{
	if (node.descriptor >= context.program.primitives.len
		|| node.inputs.len != 2 || arguments.len != 2)
	{
		typed_delta_fail(context, "invalid primitive descriptor in DeltaProgram");
		return null;
	}
	TypedDeltaValue* left = arguments[0];
	TypedDeltaValue* right = arguments[1];
	mitos::DeltaPrimitiveOp operation =
		context.program.primitives[node.descriptor].operation;
	if (operation == DELTA_PRIMITIVE_EQUAL)
	{
		return typed_delta_bool(
			context, typed_delta_equal(context, left, right)
		);
	}
	if (left.kind != TYPED_VALUE_I64 || right.kind != TYPED_VALUE_I64)
	{
		typed_delta_fail(context, "integer primitive received a non-I64 value");
		return null;
	}
	long lhs = left.integer;
	long rhs = right.integer;
	switch (operation)
	{
		case DELTA_PRIMITIVE_ADD: return typed_delta_i64(context, (long)((ulong)lhs + (ulong)rhs));
		case DELTA_PRIMITIVE_SUBTRACT: return typed_delta_i64(context, (long)((ulong)lhs - (ulong)rhs));
		case DELTA_PRIMITIVE_MULTIPLY: return typed_delta_i64(context, (long)((ulong)lhs * (ulong)rhs));
		case DELTA_PRIMITIVE_DIVIDE:
			if (!rhs) { typed_delta_fail(context, "division by zero"); return null; }
			if (lhs == long::min && rhs == -1) { typed_delta_fail(context, "integer overflow in division"); return null; }
			return typed_delta_i64(context, lhs / rhs);
		case DELTA_PRIMITIVE_REMAINDER:
			if (!rhs) { typed_delta_fail(context, "remainder by zero"); return null; }
			return typed_delta_i64(context, lhs == long::min && rhs == -1 ? 0 : lhs % rhs);
		case DELTA_PRIMITIVE_LESS: return typed_delta_bool(context, lhs < rhs);
		case DELTA_PRIMITIVE_LESS_EQUAL: return typed_delta_bool(context, lhs <= rhs);
		case DELTA_PRIMITIVE_GREATER: return typed_delta_bool(context, lhs > rhs);
		case DELTA_PRIMITIVE_GREATER_EQUAL: return typed_delta_bool(context, lhs >= rhs);
		default: typed_delta_fail(context, "unknown primitive operation in DeltaProgram"); return null;
	}
}

fn TypedDeltaValue* typed_delta_constructor_values(
	TypedDeltaContext* context,
	mitos::DeltaNode* node,
	TypedDeltaValue*[] arguments
) @private
{
	if (node.descriptor >= context.program.constructors.len)
	{
		typed_delta_fail(context, "invalid constructor descriptor in DeltaProgram");
		return null;
	}
	mitos::DeltaConstructorDescriptor* constructor =
		&context.program.constructors[node.descriptor];
	if (constructor.fields.len != arguments.len)
	{
		typed_delta_fail(context, "constructor node disagrees with its field layout");
		return null;
	}
	usz field_bytes = arguments.len * (usz)usz::size;
	usz type_bytes = arguments.len * (usz)mitos::TypeId::size;
	if (!typed_delta_charge(context, field_bytes + type_bytes)) return null;
	TypedDeltaValue*[] fields = alloc::clone_slice(context.allocator, arguments);
	mitos::TypeId[] actual_fields = alloc::new_array(
		context.allocator, mitos::TypeId, (sz)arguments.len
	);
	defer alloc::free(context.allocator, actual_fields);
	foreach (index, argument : arguments) actual_fields[index] = argument.type_id;
	mitos::TypeId runtime_type = constructor.runtime_type;
	if (constructor.parameters.len)
	{
		mitos::MitosDiagnostic diagnostic;
		typed_delta_lock_registry(context);
		bool inferred = mitos::infer_constructor_instance(
			&context.program.types,
			constructor.type_constructor,
			constructor.parameters,
			constructor.field_patterns,
			actual_fields,
			&runtime_type,
			&diagnostic,
			typed_delta_active_span(context)
		);
		typed_delta_unlock_registry(context);
		if (!inferred)
		{
			alloc::free(context.allocator, fields);
			typed_delta_fail(context, diagnostic.message);
			diagnostic.deinit();
			return null;
		}
	}
	else
	{
		foreach (index, actual : actual_fields)
		{
			if (!typed_delta_assert_type(
				context, actual, constructor.field_types[index]
			))
			{
				alloc::free(context.allocator, fields);
				return null;
			}
		}
	}
	TypedDeltaValue* constructed = typed_delta_value(context, {
		.kind = TYPED_VALUE_CONSTRUCTOR,
		.type_id = runtime_type,
		.constructor = node.descriptor,
		.fields = fields,
	});
	if (!constructed) alloc::free(context.allocator, fields);
	return constructed;
}

fn TypedDeltaValue* typed_delta_match_value(
	TypedDeltaContext* context,
	mitos::DeltaNode* node,
	TypedDeltaEnvironment environment,
	TypedDeltaValue* scrutinee,
	usz depth
) @private
{
	if (!scrutinee || scrutinee.kind != TYPED_VALUE_CONSTRUCTOR)
	{
		typed_delta_fail(context, "match scrutinee is not a constructor value");
		return null;
	}
	mitos::DeltaMatchBranch* selected = null;
	foreach (&branch : node.branches)
	{
		if (!branch.wildcard
			&& branch.constructor == (uint)scrutinee.constructor)
		{
			selected = branch;
			break;
		}
		if (branch.wildcard && !selected) selected = branch;
	}
	if (!selected)
	{
		typed_delta_fail(context, "non-exhaustive constructor match");
		return null;
	}
 if (selected.wildcard && selected.bindings.len)
 {
  typed_delta_fail(context, "wildcard match arm cannot bind constructor fields");
  return null;
 }
 if (!selected.wildcard)
 {
  if (selected.constructor >= context.program.constructors.len
   || selected.bindings.len != scrutinee.fields.len
   || selected.bindings.len
    != context.program.constructors[selected.constructor].fields.len)
  {
   typed_delta_fail(context, "match pattern arity disagrees with constructor layout");
   return null;
  }
 }
 usz additions = selected.wildcard ? 0 : selected.bindings.len;
 TypedDeltaBinding[] arm_environment = typed_delta_environment(
  context, environment, additions
 );
 if (context.failed
  || arm_environment.len != environment.bindings.len + additions) return null;
 foreach (index, binding : selected.bindings)
  arm_environment[environment.bindings.len + index] = {
   .name = binding,
   .value = scrutinee.fields[index],
  };
	return typed_delta_evaluate(
		context, selected.body, { .bindings = arm_environment }, depth + 1
	);
}

fn TypedDeltaExternalLane* typed_delta_external_lane(
 TypedDeltaContext* context,
 usz source_order,
 bool create
) @private
{
 TypedDeltaContext* owner = context.external_owner
  ? context.external_owner : context;
 if (context.external_lane_cached
  && context.external_lane_index < (usz)owner.external_lanes.len())
 {
  TypedDeltaExternalLane* cached =
   &owner.external_lanes[(sz)context.external_lane_index];
  if (cached.source_order == source_order) return cached;
 }
 foreach (index, &lane : owner.external_lanes)
 {
  if (lane.source_order != source_order) continue;
  context.external_lane_index = (usz)index;
  context.external_lane_cached = true;
  return lane;
 }
 if (!create) return null;
 if (!typed_delta_charge(
  owner, (usz)TypedDeltaExternalLane::size + (usz)usz::size
 )) return null;
 TypedDeltaExternalLane lane = { .source_order = source_order };
 Allocator control_allocator = owner.owned_program
  ? (Allocator)&owner.program_allocator : owner.allocator;
 lane.results.init(control_allocator);
 owner.external_lanes.push(lane);
 context.external_lane_index = (usz)owner.external_lanes.len() - 1;
 context.external_lane_cached = true;
 return &owner.external_lanes[(sz)context.external_lane_index];
}

fn TypedDeltaExternalResult* typed_delta_external_slot(
 TypedDeltaContext* context,
 usz source_order,
 mitos::DeltaNodeId hole,
 usz occurrence_order,
 bool create,
 bool* created = null
) @private
{
 if (created) *created = false;
 TypedDeltaExternalLane* lane = typed_delta_external_lane(
  context, source_order, create
 );
 if (!lane) return null;
 usz low = 0;
 usz high = (usz)lane.results.len();
 while (low < high)
 {
  usz middle = low + (high - low) / 2;
  if (lane.results[(sz)middle].occurrence_order < occurrence_order)
  {
   low = middle + 1;
  }
  else
  {
   high = middle;
  }
 }
 usz count = (usz)lane.results.len();
 if (low < count
  && lane.results[(sz)low].occurrence_order == occurrence_order)
 {
  TypedDeltaExternalResult* result = &lane.results[(sz)low];
  if (result.hole != hole)
  {
   typed_delta_fail(
    context, "external effect replay disagrees with its resumable work state"
   );
   return null;
  }
  return result;
 }
 if (!create) return null;
 if (low != count)
 {
  typed_delta_fail(
   context, "external effect replay is not sequential within its source root"
  );
  return null;
 }
 TypedDeltaContext* owner = context.external_owner
  ? context.external_owner : context;
 if (!typed_delta_charge(
  owner, (usz)TypedDeltaExternalResult::size + (usz)usz::size
 )) return null;
 lane.results.push({
  .occurrence_order = occurrence_order,
  .hole = hole,
 });
 if (created) *created = true;
 return &lane.results[(sz)count];
}

fn bool typed_delta_handler_scope_handles(
 TypedDeltaContext* context,
 mitos::EffectId effect
) @private
{
 for (TypedDeltaHandlerScope* scope = context.handler_scope;
  scope; scope = scope.parent)
 {
  foreach (&clause : scope.handler.clauses)
   if (clause.effect == effect) return true;
 }
 return false;
}

fn TypedDeltaValue* typed_delta_effect_values(
	TypedDeltaContext* context,
	mitos::DeltaNodeId node_id,
	mitos::DeltaNode* node,
	TypedDeltaValue*[] arguments
) @private
{
	if (node.descriptor >= context.program.effects.operations.len
		|| node.types.len != arguments.len + 1
		|| !node.result_type
		|| node.integer <= 0)
	{
		typed_delta_fail(context, "effect node has incomplete resolved operation metadata");
		return null;
	}
	foreach (index, argument : arguments)
	{
		if (!typed_delta_assert_type(
			context, argument.type_id, node.types[index]
		)) return null;
	}
	usz occurrence_order = context.current_occurrence_order++;
	for (TypedDeltaSubstitution* substitution = context.substitution;
		substitution; substitution = substitution.parent)
	{
		if (substitution.hole == node_id
			&& substitution.source_order == context.parallel_source_order
			&& substitution.occurrence_order == occurrence_order)
		{
			return substitution.value;
		}
	}
 mitos::DeltaOperationDescriptor* operation = typed_delta_operation(
  context, node.descriptor
 );
 bool external_work = operation
  && operation.host_kind == DELTA_EFFECT_EXTERNAL
  && !typed_delta_handler_scope_handles(
   context, (mitos::EffectId)node.integer
  );
 if (external_work)
 {
  TypedDeltaExternalResult* replay = typed_delta_external_slot(
   context, context.parallel_source_order, node_id, occurrence_order, false
  );
  if (context.failed) return null;
  if (replay)
  {
   if (!replay.ready)
   {
    typed_delta_fail(context, "external effect work state resumed before completion");
    return null;
   }
   return replay.value;
  }
 }
	usz bytes = arguments.len * (usz)usz::size;
	if (!typed_delta_charge(context, bytes)) return null;
	TypedDeltaValue*[] owned = alloc::clone_slice(context.allocator, arguments);
	TypedDeltaValue* request = typed_delta_effect_request(
		context,
		node.descriptor,
		node_id,
		owned,
		(mitos::EffectId)node.integer,
		occurrence_order,
		node.result_type
	);
	if (!request)
 {
  alloc::free(context.allocator, owned);
  return null;
 }
 if (context.worker_active || !external_work) return request;
 bool created;
 TypedDeltaExternalResult* slot = typed_delta_external_slot(
  context, context.parallel_source_order, node_id, occurrence_order,
  true, &created
 );
 if (!slot || !created) return null;
 TypedDeltaValue* ready_result;
 TypedDeltaHostDisposition disposition = typed_delta_invoke_external(
  context, request, &ready_result
 );
 if (disposition == HOST_READY)
 {
  slot.value = ready_result;
  slot.ready = true;
  return ready_result;
 }
 if (disposition == HOST_SUSPEND)
 {
  request.effect_host_suspended = true;
  return request;
 }
 return null;
}

enum TypedDeltaLiftOperation : char
{
	TYPED_LIFT_PRIMITIVE,
	TYPED_LIFT_CONSTRUCTOR,
	TYPED_LIFT_GENERIC_CALL,
	TYPED_LIFT_APPLICATION,
	TYPED_LIFT_MATCH,
	TYPED_LIFT_EFFECT,
}

struct TypedDeltaSelection
{
	TypedDeltaAssignment[] assignments;
}

fn bool typed_delta_assignment_slices_compatible(
	TypedDeltaAssignment[] left,
	TypedDeltaAssignment[] right
) @private
{
	usz left_index = 0;
	usz right_index = 0;
	while (left_index < left.len && right_index < right.len)
	{
		TypedDeltaAssignment left_assignment = left[left_index];
		TypedDeltaAssignment right_assignment = right[right_index];
		if (left_assignment.origin < right_assignment.origin)
		{
			left_index++;
			continue;
		}
		if (right_assignment.origin < left_assignment.origin)
		{
			right_index++;
			continue;
		}
		if (left_assignment.branch != right_assignment.branch) return false;
		left_index++;
		right_index++;
	}
	return true;
}

fn bool typed_delta_selection_compatible(
	TypedDeltaSelection[] selections,
	usz selected_count,
	TypedDeltaAssignment[] candidate
) @private
{
	foreach (selection : selections[:(sz)selected_count])
		if (!typed_delta_assignment_slices_compatible(
			selection.assignments, candidate
		)) return false;
	return true;
}

fn usz typed_delta_assignment_bucket(ulong origin, ulong lower_bound) @private
{
	ulong different = origin ^ lower_bound;
	return different ? 64 - (usz)different.clz() : 0;
}

fn bool typed_delta_collect_assignments(
	TypedDeltaContext* context,
	TypedDeltaSelection[] selections,
	TypedDeltaAssignment[]* result
) @private
{
	*result = { };
	if (selections.len > TYPED_DELTA_MAX_NATIVE_DEPTH)
	{
		typed_delta_fail(context, "superposition assignment merge exceeds its cursor bound");
		return false;
	}
	usz capacity = 0;
	foreach (selection : selections)
	{
		ulong previous_origin = 0;
		foreach (assignment : selection.assignments)
		{
			if (!assignment.origin || assignment.origin <= previous_origin)
			{
				typed_delta_fail(
					context,
					"superposition assignment metadata is not canonical"
				);
				return false;
			}
			previous_origin = assignment.origin;
		}
		if (selection.assignments.len > usz::max - capacity)
		{
			typed_delta_fail(context, "superposition assignment metadata exceeds resource bounds");
			return false;
		}
		capacity += selection.assignments.len;
	}
	usz byte_limit = context.max_owned_bytes
		? context.max_owned_bytes : TYPED_DELTA_MAX_OWNED_BYTES;
	if (capacity > TYPED_DELTA_MAX_ASSIGNMENTS
		|| capacity > byte_limit / (usz)TypedDeltaAssignment::size)
	{
		typed_delta_fail(context, "superposition assignment metadata exceeds resource bounds");
		return false;
	}
	if (!capacity) return true;
	usz bytes = capacity * (usz)TypedDeltaAssignment::size;
	if (!typed_delta_charge(context, bytes)) return false;
	TypedDeltaAssignment[] merged = alloc::new_array(
		context.allocator, TypedDeltaAssignment, (sz)capacity
	);

	// A monotone radix heap merges every sorted slice directly into the owned
	// output. Each cursor is redistributed at most once per origin bit.
	usz[512] cursors;
	usz[512] next;
	usz[65] bucket_heads;
	foreach (&cursor : cursors) *cursor = 0;
	foreach (&link : next) *link = usz::max;
	foreach (&head : bucket_heads) *head = usz::max;
	usz active = 0;
	foreach (selection_index, selection : selections)
	{
		if (!selection.assignments.len) continue;
		usz index = (usz)selection_index;
		usz bucket = typed_delta_assignment_bucket(
			selection.assignments[0].origin, 0
		);
		next[index] = bucket_heads[bucket];
		bucket_heads[bucket] = index;
		active++;
	}

	ulong lower_bound = 0;
	usz count = 0;
	while (active)
	{
		usz bucket = 0;
		while (bucket < 65 && bucket_heads[bucket] == usz::max) bucket++;
		assert(bucket < 65, "typed Delta assignment radix heap lost an active cursor");
		if (bucket)
		{
			ulong new_lower_bound = ulong::max;
			for (
				usz selection_index = bucket_heads[bucket];
				selection_index != usz::max;
				selection_index = next[selection_index]
			)
			{
				TypedDeltaSelection selection = selections[selection_index];
				ulong origin = selection.assignments[
					cursors[selection_index]
				].origin;
				if (origin < new_lower_bound) new_lower_bound = origin;
			}
			lower_bound = new_lower_bound;
			usz selection_index = bucket_heads[bucket];
			bucket_heads[bucket] = usz::max;
			while (selection_index != usz::max)
			{
				usz following = next[selection_index];
				TypedDeltaSelection selection = selections[selection_index];
				ulong origin = selection.assignments[
					cursors[selection_index]
				].origin;
				usz replacement_bucket = typed_delta_assignment_bucket(
					origin, lower_bound
				);
				next[selection_index] = bucket_heads[replacement_bucket];
				bucket_heads[replacement_bucket] = selection_index;
				selection_index = following;
			}
		}

		usz selection_index = bucket_heads[0];
		bucket_heads[0] = next[selection_index];
		TypedDeltaSelection selection = selections[selection_index];
		TypedDeltaAssignment assignment =
			selection.assignments[cursors[selection_index]];
		if (count && merged[count - 1].origin == assignment.origin)
		{
			if (merged[count - 1].branch != assignment.branch)
			{
				alloc::free(context.allocator, merged);
				return false;
			}
		}
		else
		{
			merged[count++] = assignment;
		}

		cursors[selection_index]++;
		if (cursors[selection_index] >= selection.assignments.len)
		{
			active--;
			continue;
		}
		ulong next_origin =
			selection.assignments[cursors[selection_index]].origin;
		assert(
			next_origin >= lower_bound,
			"canonical assignment cursor moved behind the radix lower bound"
		);
		usz next_bucket = typed_delta_assignment_bucket(
			next_origin, lower_bound
		);
		next[selection_index] = bucket_heads[next_bucket];
		bucket_heads[next_bucket] = selection_index;
	}
	*result = merged[:(sz)count];
	return true;
}

fn bool typed_delta_merge_assignments(
	TypedDeltaContext* context,
	TypedDeltaAssignment[] left,
	TypedDeltaAssignment[] right,
	TypedDeltaAssignment[]* result
) @private
{
	TypedDeltaSelection[2] selections = {
		{ .assignments = left },
		{ .assignments = right },
	};
	return typed_delta_collect_assignments(context, selections[..], result);
}

fn void typed_delta_free_alternative_list(
	TypedDeltaContext* context,
	List{TypedDeltaAlternative}* alternatives
) @private
{
	foreach (&alternative : *alternatives)
		alloc::free(context.allocator, alternative.assignments);
	alternatives.free();
}

fn bool typed_delta_push_alternative(
	TypedDeltaContext* context,
	List{TypedDeltaAlternative}* alternatives,
	TypedDeltaValue* value,
	TypedDeltaAssignment[] assignments,
	mitos::TypeId* element_type
) @private
{
	if (!value || value.kind == TYPED_VALUE_SUPERPOSITION)
	{
		typed_delta_fail(context, "nested superposition was not flattened");
		alloc::free(context.allocator, assignments);
		return false;
	}
	if (!*element_type) *element_type = value.type_id;
	if (value.type_id != *element_type)
	{
		typed_delta_fail(context, "lifted alternatives must have one concrete runtime TypeId");
		alloc::free(context.allocator, assignments);
		return false;
	}
	usz byte_limit = context.max_owned_bytes
		? context.max_owned_bytes : TYPED_DELTA_MAX_OWNED_BYTES;
	usz alternative_count = (usz)alternatives.len();
	if (alternative_count >= TYPED_DELTA_MAX_ALTERNATIVES
		|| context.owned_bytes > byte_limit
		|| alternative_count + 1 > (
			byte_limit - context.owned_bytes
		) / (usz)TypedDeltaAlternative::size)
	{
		typed_delta_fail(context, "superposition Cartesian product exceeds its resource bound");
		alloc::free(context.allocator, assignments);
		return false;
	}
	alternatives.push({ .value = value, .assignments = assignments });
	return true;
}

fn bool typed_delta_append_flattened(
	TypedDeltaContext* context,
	List{TypedDeltaAlternative}* alternatives,
	TypedDeltaValue* value,
	TypedDeltaAssignment[] base_assignments,
	mitos::TypeId* element_type
) @private
{
	if (typed_delta_is_effect(value))
	{
		alloc::free(context.allocator, base_assignments);
		return false;
	}
	if (value.kind != TYPED_VALUE_SUPERPOSITION)
	{
		return typed_delta_push_alternative(
			context, alternatives, value, base_assignments, element_type
		);
	}
	foreach (&inner : value.alternatives)
	{
		TypedDeltaAssignment[] merged;
		bool compatible = typed_delta_merge_assignments(
			context, base_assignments, inner.assignments, &merged
		);
		if (context.failed)
		{
			alloc::free(context.allocator, base_assignments);
			return false;
		}
		if (!compatible) continue;
		if (!typed_delta_push_alternative(
			context, alternatives, inner.value, merged, element_type
		))
		{
			alloc::free(context.allocator, base_assignments);
			return false;
		}
	}
	alloc::free(context.allocator, base_assignments);
	return true;
}

fn TypedDeltaValue* typed_delta_scalar_lift_operation(
	TypedDeltaContext* context,
	mitos::DeltaNode* node,
	TypedDeltaEnvironment environment,
	TypedDeltaValue*[] values,
	TypedDeltaLiftOperation operation,
	usz depth
) @private
{
	switch (operation)
	{
		case TYPED_LIFT_PRIMITIVE:
			return typed_delta_primitive_values(context, node, values);
		case TYPED_LIFT_CONSTRUCTOR:
			return typed_delta_constructor_values(context, node, values);
		case TYPED_LIFT_GENERIC_CALL:
			return typed_delta_dispatch_values(context, node, values, depth);
		case TYPED_LIFT_APPLICATION:
			return typed_delta_apply_values(
				context, values[0], node, values[1..], depth
			);
		case TYPED_LIFT_MATCH:
			return typed_delta_match_value(
				context, node, environment, values[0], depth
			);
		case TYPED_LIFT_EFFECT:
			return typed_delta_effect_values(
				context, (mitos::DeltaNodeId)node.stable_id, node, values
			);
		default: unreachable("unknown typed Delta lift operation");
	}
}

fn bool typed_delta_lift_recurse(
	TypedDeltaContext* context,
	mitos::DeltaNode* node,
	TypedDeltaEnvironment environment,
	TypedDeltaValue*[] inputs,
	TypedDeltaSelection[] selections,
	TypedDeltaValue*[] selected_values,
	usz input_index,
	TypedDeltaLiftOperation operation,
	usz depth,
	List{TypedDeltaAlternative}* alternatives,
	mitos::TypeId* element_type,
	TypedDeltaValue** escaped_effect
) @private
{
	if (input_index < inputs.len)
	{
		TypedDeltaValue* input = inputs[input_index];
		if (input.kind == TYPED_VALUE_SUPERPOSITION)
		{
			foreach (&alternative : input.alternatives)
			{
				if (!typed_delta_take_step(
					context,
					"superposition Cartesian lifting exceeded its evaluation-step bound"
				)) return false;
				if (!typed_delta_selection_compatible(
					selections, input_index, alternative.assignments
				)) continue;
				selections[input_index] = {
					.assignments = alternative.assignments,
				};
				selected_values[input_index] = alternative.value;
				if (!typed_delta_lift_recurse(
					context, node, environment, inputs, selections,
					selected_values, input_index + 1, operation, depth,
					alternatives, element_type, escaped_effect
				)) return false;
			}
			return true;
		}
		selections[input_index] = { };
		selected_values[input_index] = input;
		return typed_delta_lift_recurse(
			context, node, environment, inputs, selections,
			selected_values, input_index + 1, operation, depth,
			alternatives, element_type, escaped_effect
		);
	}
	TypedDeltaAssignment[] assignments;
	bool compatible = typed_delta_collect_assignments(
		context, selections, &assignments
	);
	if (!compatible) return !context.failed;
	TypedDeltaValue* result = typed_delta_scalar_lift_operation(
		context, node, environment, selected_values, operation, depth
	);
	if (context.failed)
	{
		alloc::free(context.allocator, assignments);
		return false;
	}
	if (typed_delta_is_effect(result))
	{
		alloc::free(context.allocator, assignments);
		*escaped_effect = result;
		return false;
	}
	return typed_delta_append_flattened(
		context, alternatives, result, assignments, element_type
	);
}

fn TypedDeltaValue* typed_delta_lift_values(
	TypedDeltaContext* context,
	mitos::DeltaNode* node,
	TypedDeltaEnvironment environment,
	TypedDeltaValue*[] inputs,
	TypedDeltaLiftOperation operation,
	usz depth
) @private
{
	bool lifted = false;
	ulong primary_origin = 0;
	foreach (input : inputs)
	{
		if (input.kind != TYPED_VALUE_SUPERPOSITION) continue;
		lifted = true;
		if (!primary_origin) primary_origin = input.origin;
	}
	if (!lifted) return typed_delta_scalar_lift_operation(
		context, node, environment, inputs, operation, depth
	);
	if (inputs.len > usz::max / (
		(usz)TypedDeltaSelection::size + (usz)usz::size
	) || !typed_delta_charge(
		context,
		inputs.len * (
			(usz)TypedDeltaSelection::size + (usz)usz::size
		)
	)) return null;
	if (depth >= TYPED_DELTA_MAX_NATIVE_DEPTH
		|| inputs.len > TYPED_DELTA_MAX_NATIVE_DEPTH - depth)
	{
		typed_delta_fail(
			context,
			"superposition Cartesian lifting exceeds its native recursion bound"
		);
		return null;
	}
	TypedDeltaSelection[] selections = alloc::new_array(
		context.allocator, TypedDeltaSelection, (sz)inputs.len
	);
	defer alloc::free(context.allocator, selections);
	TypedDeltaValue*[] selected_values = alloc::new_array(
		context.allocator, TypedDeltaValue*, (sz)inputs.len
	);
	defer alloc::free(context.allocator, selected_values);
	List{TypedDeltaAlternative} alternatives;
	alternatives.init(context.allocator);
	mitos::TypeId element_type = mitos::TYPE_ID_INVALID;
	TypedDeltaValue* escaped_effect = null;
	bool completed = typed_delta_lift_recurse(
		context, node, environment, inputs, selections, selected_values,
		0, operation, depth, &alternatives, &element_type, &escaped_effect
	);
	if (!completed)
	{
		typed_delta_free_alternative_list(context, &alternatives);
		if (escaped_effect) return escaped_effect;
		return null;
	}
	if (!alternatives.len())
	{
		typed_delta_fail(context, "superposition correlation left no compatible alternatives");
		alternatives.free();
		return null;
	}
	usz bytes = (usz)alternatives.len() * (usz)TypedDeltaAlternative::size;
	if (!typed_delta_charge(context, bytes))
	{
		typed_delta_free_alternative_list(context, &alternatives);
		return null;
	}
	TypedDeltaAlternative[] owned = alternatives.to_array(context.allocator);
	alternatives.free();
	TypedDeltaValue* lifted_value = typed_delta_superposition_owned(
		context, owned, primary_origin
	);
	return lifted_value;
}

fn TypedDeltaValue* typed_delta_superpose(
	TypedDeltaContext* context,
	mitos::DeltaNode* node,
	TypedDeltaEnvironment environment,
	usz depth
) @private
{
	if (!node.descriptor || !node.inputs.len
		|| node.inputs.len > TYPED_DELTA_MAX_ALTERNATIVES)
	{
		typed_delta_fail(context, "superpose requires a stable origin and at least one alternative");
		return null;
	}
	List{TypedDeltaAlternative} alternatives;
	alternatives.init(context.allocator);
	mitos::TypeId element_type = mitos::TYPE_ID_INVALID;
	foreach (branch, input : node.inputs)
	{
		TypedDeltaValue* value = typed_delta_evaluate(
			context, input, environment, depth + 1
		);
		if (context.failed || typed_delta_is_effect(value))
		{
			typed_delta_free_alternative_list(context, &alternatives);
			return context.failed ? null : value;
		}
		if (!typed_delta_charge(context, (usz)TypedDeltaAssignment::size))
		{
			typed_delta_free_alternative_list(context, &alternatives);
			return null;
		}
		TypedDeltaAssignment[] assignment = alloc::new_array(
			context.allocator, TypedDeltaAssignment, 1
		);
		assignment[0] = {
			.origin = (ulong)node.descriptor,
			.branch = (usz)branch,
		};
		if (!typed_delta_append_flattened(
			context, &alternatives, value, assignment, &element_type
		))
		{
			typed_delta_free_alternative_list(context, &alternatives);
			return null;
		}
	}
	if (!alternatives.len())
	{
		typed_delta_fail(context, "superpose contains no compatible flattened alternatives");
		alternatives.free();
		return null;
	}
	usz bytes = (usz)alternatives.len() * (usz)TypedDeltaAlternative::size;
	if (!typed_delta_charge(context, bytes))
	{
		typed_delta_free_alternative_list(context, &alternatives);
		return null;
	}
	TypedDeltaAlternative[] owned = alternatives.to_array(context.allocator);
	alternatives.free();
	TypedDeltaValue* superposed_value = typed_delta_superposition_owned(
		context, owned, (ulong)node.descriptor
	);
	if (superposed_value && node.result_type != mitos::TYPE_ID_ANY
		&& node.static_type && !typed_delta_assert_type(
			context, superposed_value.type_id, node.static_type
		)) return null;
	return superposed_value;
}

fn TypedDeltaValue* typed_delta_collapse(
	TypedDeltaContext* context,
	TypedDeltaValue* value
) @private
{
	if (!value || value.kind != TYPED_VALUE_SUPERPOSITION)
	{
		typed_delta_fail(context, "collapse strictly requires a superposition");
		return null;
	}
	usz bytes = value.alternatives.len * (usz)usz::size;
	if (!typed_delta_charge(context, bytes)) return null;
	TypedDeltaValue*[] elements = alloc::new_array(
		context.allocator, TypedDeltaValue*, (sz)value.alternatives.len
	);
	foreach (index, &alternative : value.alternatives)
		elements[index] = alternative.value;
	return typed_delta_array_owned(
		context, elements, value.alternatives[0].value.type_id
	);
}
fn TypedDeltaValue* typed_delta_handler_return(
	TypedDeltaContext* context,
	TypedDeltaHandlerActivation* activation,
	TypedDeltaValue* value,
	usz depth
) @private
{
	mitos::DeltaHandlerDescriptor* handler = activation.handler;
 if (!typed_delta_assert_type(context, value.type_id, handler.return_type))
 {
  return null;
 }
	TypedDeltaBinding[] bindings = typed_delta_environment(context, activation.environment, 1);
 if (context.failed
  || bindings.len != activation.environment.bindings.len + 1) return null;
	bindings[activation.environment.bindings.len] = {
		.name = handler.return_parameter,
		.value = value,
	};
	return typed_delta_evaluate(context, handler.return_body, { .bindings = bindings }, depth + 1);
}

fn TypedDeltaValue* typed_delta_handle_request(
	TypedDeltaContext* context,
	mitos::DeltaNode* node,
	TypedDeltaEnvironment environment,
	TypedDeltaValue* request,
	usz depth
) @private
{
	if (node.descriptor >= context.program.effects.handlers.len)
	{
		typed_delta_fail(context, "handler boundary has invalid Delta metadata");
		return null;
	}
	mitos::DeltaHandlerDescriptor* handler = &context.program.effects.handlers[node.descriptor];
	mitos::DeltaOperationDescriptor* operation = typed_delta_operation(context, request.effect_operation);
	if (!operation)
	{
		typed_delta_fail(context, "effect request has an invalid operation descriptor");
		return null;
	}
	mitos::DeltaHandlerClauseDescriptor* selected = null;
	bool handles_effect = false;
	foreach (&clause : handler.clauses)
	{
		if (clause.effect == request.effect_instance) handles_effect = true;
		if (clause.effect == request.effect_instance
			&& clause.operation == operation.id) { selected = clause; break; }
	}
	if (!selected)
	{
		if (handles_effect) typed_delta_fail(context, "handler is missing a clause for the performed operation");
		return handles_effect ? null : request;
	}
	if (selected.parameters.len != request.effect_arguments.len)
	{
		typed_delta_fail(context, "effect request arguments disagree with the handler clause");
		return null;
	}
	TypedDeltaBinding[] clause_environment = typed_delta_environment(
		context, environment, selected.parameters.len
	);
 if (context.failed
  || clause_environment.len
   != environment.bindings.len + selected.parameters.len) return null;
	foreach (index, parameter : selected.parameters)
	{
		TypedDeltaValue* argument = request.effect_arguments[index];
		mitos::TypeId expected = selected.parameter_types[index];
  if (!typed_delta_assert_type(context, argument.type_id, expected))
  {
   return null;
  }
		clause_environment[environment.bindings.len + index] = { .name = parameter, .value = argument };
	}
	TypedDeltaHandlerActivation activation = {
		.parent = context.activation,
		.handler_index = node.descriptor,
		.handler = handler,
		.environment = environment,
		.handler_node = (mitos::DeltaNodeId)node.stable_id,
		.handled_root = handler.handled,
		.hole = request.effect_node,
		.generation = context.program.effects.epoch,
		.operation_result_type = selected.result_type,
		.resume_limit = delta_resume_occurrences(
			context.program, selected.body, node.descriptor, 0
		),
		.effect_source_order = request.effect_source_order,
		.effect_occurrence_order = request.effect_occurrence_order,
		.multi = selected.multi,
	};
	context.activation = &activation;
	context.stats.effects_handled++;
	if (operation.ordered) context.stats.ordered_effect_commits++;
	TypedDeltaValue* result = typed_delta_evaluate(
		context, selected.body, { .bindings = clause_environment }, depth + 1
	);
	context.activation = activation.parent;
	if (!context.failed && !activation.resumes_used && !activation.aborted)
	{
		activation.aborted = true;
		context.stats.continuations_erased++;
	}
	return result;
}

fn TypedDeltaValue* typed_delta_handler(
	TypedDeltaContext* context,
	mitos::DeltaNode* node,
	TypedDeltaEnvironment environment,
	usz depth
) @private
{
	if (node.descriptor >= context.program.effects.handlers.len)
	{
		typed_delta_fail(context, "handler boundary has invalid Delta metadata");
		return null;
	}
 mitos::DeltaHandlerDescriptor* handler =
  &context.program.effects.handlers[node.descriptor];
 TypedDeltaHandlerScope scope = {
  .parent = context.handler_scope,
  .handler = handler,
 };
 context.handler_scope = &scope;
	TypedDeltaValue* handled = typed_delta_evaluate(
  context, node.inputs[0], environment, depth + 1
 );
 context.handler_scope = scope.parent;
	if (context.failed) return null;
	if (typed_delta_is_effect(handled))
	{
		return typed_delta_handle_request(
   context, node, environment, handled, depth + 1
  );
	}
	TypedDeltaHandlerActivation activation = {
		.handler_index = node.descriptor,
		.handler = handler,
		.environment = environment,
		.handler_node = (mitos::DeltaNodeId)node.stable_id,
		.handled_root = node.inputs[0],
		.generation = context.program.effects.epoch,
	};
	return typed_delta_handler_return(context, &activation, handled, depth + 1);
}


fn TypedDeltaValue* typed_delta_resume_graph(
	TypedDeltaContext* context,
	TypedDeltaHandlerActivation* activation,
	TypedDeltaValue* resumed,
	usz depth
) @private
{
	TypedDeltaSubstitution substitution = {
		.parent = context.substitution,
		.hole = activation.hole,
		.value = resumed,
		.source_order = activation.effect_source_order,
		.occurrence_order = activation.effect_occurrence_order,
	};
 usz previous_occurrence = context.current_occurrence_order;
 usz previous_source_order = context.parallel_source_order;
 context.current_occurrence_order = 0;
 context.parallel_source_order = activation.effect_source_order;
	context.substitution = &substitution;
	TypedDeltaValue* continued = typed_delta_evaluate(
		context, activation.handled_root, activation.environment, depth + 1
	);
	if (context.failed)
	{
		context.substitution = substitution.parent;
  context.current_occurrence_order = previous_occurrence;
  context.parallel_source_order = previous_source_order;
		return null;
	}
	TypedDeltaValue* result;
	if (typed_delta_is_effect(continued))
	{
		mitos::DeltaNode* handler_node = mitos::delta_node(context.program, activation.handler_node);
		if (!handler_node)
		{
			typed_delta_fail(context, "captured continuation lost its lexical handler boundary");
			context.substitution = substitution.parent;
   context.current_occurrence_order = previous_occurrence;
   context.parallel_source_order = previous_source_order;
			return null;
		}
		result = typed_delta_handle_request(
			context, handler_node, activation.environment, continued, depth + 1
		);
	}
	else
	{
		result = typed_delta_handler_return(context, activation, continued, depth + 1);
	}
 context.current_occurrence_order = previous_occurrence;
 context.parallel_source_order = previous_source_order;
	context.substitution = substitution.parent;
	return result;
}

fn usz typed_delta_entry_source_order(mitos::DeltaProgram* program) @private
{
 foreach (&boundary : program.image.interfaces)
  if (boundary.kind == DELTA_INTERFACE_ENTRY
   && boundary.root == program.entry) return boundary.source_order;
 return program.method_roots.len;
}

fn void typed_delta_context_init(
 TypedDeltaContext* context,
 mitos::DeltaProgram* program,
 Allocator allocator,
 TypedDeltaPool* pool,
 TypedDeltaHostSnapshotEntry[] host_entries,
 mitos_storage::StorageRuntime* shared_storage = null,
 bool worker_active = false,
 bool retain_control = false
) @private
{
 *context = {
  .allocator = allocator,
  .program = program,
  .pool = pool,
  .host_entries = host_entries,
  .worker_active = worker_active,
  .max_owned_bytes = TYPED_DELTA_MAX_OWNED_BYTES,
  .max_values = TYPED_DELTA_MAX_VALUES,
  .max_environments = TYPED_DELTA_MAX_ENVIRONMENTS,
  .external_owner = context,
 };
 Allocator control_allocator = allocator;
 if (retain_control)
 {
  context.program_allocator.init(allocator);
  control_allocator = (Allocator)&context.program_allocator;
 }
 context.values.init(control_allocator);
 context.environments.init(control_allocator);
 context.external_lanes.init(control_allocator);
 context.stats.effect_epoch = program.effects.epoch;
 if (shared_storage)
 {
  context.storage = shared_storage;
 }
 else
 {
  context.local_storage.init(
   allocator, mitos::MITOS_DEFAULT_MAX_TYPES,
   TYPED_DELTA_MAX_VALUES, TYPED_DELTA_MAX_OWNED_BYTES
  );
  context.storage = &context.local_storage;
  context.owns_storage = true;
  mitos_storage::StorageError layouts = mitos_storage::register_type_registry(
   context.storage, &program.types
  );
  if (layouts != mitos_storage::StorageError.STORAGE_OK)
  {
   typed_delta_fail_storage(context, layouts);
  }
 }
}

fn int typed_delta_worker_main(void* argument) @private
{
 TypedDeltaPool* pool = (TypedDeltaPool*)argument;
 for (;;)
 {
  pool.mutex.lock();
  while (!pool.stopping
   && (!pool.batch || pool.batch.next_index >= pool.batch.jobs.len))
  {
   pool.work_available.wait(&pool.mutex);
  }
  if (pool.stopping)
  {
   pool.mutex.unlock();
   return 0;
  }
  TypedDeltaBatch* batch = pool.batch;
  usz index = batch.next_index++;
  pool.mutex.unlock();
  TypedDeltaJob* job = &batch.jobs[index];
  job.context.parallel_source_order = job.source_order;
  job.context.current_occurrence_order = 0;
  job.value = typed_delta_evaluate(
   &job.context, job.node, job.environment, 0
  );
  pool.mutex.lock();
  batch.completed++;
  if (batch.completed == batch.jobs.len) pool.batch_completed.signal();
  pool.mutex.unlock();
 }
}

fn bool typed_delta_pool_start(
 TypedDeltaPool* pool,
 int worker_count,
 Allocator allocator,
 DeltaDiagnostic* diagnostic
) @private
{
 if (worker_count <= 1) return true;
 if (catch pool.mutex.init())
 {
  diagnostic.init(allocator, "failed to initialize typed Delta worker-pool mutex");
  return false;
 }
 if (catch pool.budget_mutex.init())
 {
  pool.mutex.destroy();
  diagnostic.init(allocator, "failed to initialize typed Delta budget mutex");
  return false;
 }
 if (catch pool.work_available.init())
 {
  pool.budget_mutex.destroy();
  pool.mutex.destroy();
  diagnostic.init(allocator, "failed to initialize typed Delta worker-pool condition");
  return false;
 }
 if (catch pool.batch_completed.init())
 {
  pool.work_available.destroy();
  pool.budget_mutex.destroy();
  pool.mutex.destroy();
  diagnostic.init(allocator, "failed to initialize typed Delta join barrier");
  return false;
 }
 pool.threads = alloc::new_array(allocator, Thread, (sz)worker_count);
 for (int index = 0; index < worker_count; index++)
 {
  if (catch pool.threads[index].create(&typed_delta_worker_main, pool))
  {
   pool.mutex.lock();
   pool.stopping = true;
   pool.work_available.broadcast();
   pool.mutex.unlock();
   for (usz joined = 0; joined < pool.created_threads; joined++)
   {
    (void)pool.threads[joined].join();
   }
   alloc::free(allocator, pool.threads);
   pool.batch_completed.destroy();
   pool.work_available.destroy();
   pool.budget_mutex.destroy();
   pool.mutex.destroy();
   *pool = { };
   diagnostic.init(allocator, "failed to create bounded typed Delta worker pool");
   return false;
  }
  pool.created_threads++;
 }
 return true;
}

fn void typed_delta_pool_stop(TypedDeltaPool* pool, Allocator allocator) @private
{
 if (!pool.threads.len) return;
 pool.mutex.lock();
 pool.stopping = true;
 pool.work_available.broadcast();
 pool.mutex.unlock();
 foreach (&thread : pool.threads) (void)thread.join();
 alloc::free(allocator, pool.threads);
 pool.batch_completed.destroy();
 pool.work_available.destroy();
 pool.budget_mutex.destroy();
 pool.mutex.destroy();
 *pool = { };
}

fn void typed_delta_add_stats(
 TypedDeltaExecutionStats* destination,
 TypedDeltaExecutionStats source
) @private
{
 destination.phase_one_roots += source.phase_one_roots;
 destination.phase_two_reifications += source.phase_two_reifications;
 destination.evaluations += source.evaluations;
 destination.dispatches += source.dispatches;
 destination.parallel_bindings += source.parallel_bindings;
 destination.effects_handled += source.effects_handled;
 destination.continuations_resumed += source.continuations_resumed;
 destination.continuations_erased += source.continuations_erased;
 destination.replicator_branches += source.replicator_branches;
 destination.ordered_effect_commits += source.ordered_effect_commits;
}

fn void typed_delta_adopt_child(
 TypedDeltaContext* parent,
 TypedDeltaContext* child
) @private
{
 foreach (value : child.values) parent.values.push(value);
 child.values.free();
 foreach (environment : child.environments) parent.environments.push(environment);
 child.environments.free();
 child.external_lanes.free();
 parent.owned_bytes += child.owned_bytes;
 parent.value_count += child.value_count;
 parent.environment_count += child.environment_count;
 parent.storage_payload_bytes += child.storage_payload_bytes;
 parent.steps += child.steps;
 typed_delta_add_stats(&parent.stats, child.stats);
}

fn bool typed_delta_order_parallel_roots(
 TypedDeltaContext* context,
 mitos::DeltaNodeId[] nodes,
 usz[] ordered_indices
) @private
{
 if (nodes.len > ordered_indices.len)
 {
  typed_delta_fail(context, "parallel root count exceeds its runtime bound");
  return false;
 }
 foreach (index, node_id : nodes)
 {
  mitos::DeltaNode* root = mitos::delta_node(context.program, node_id);
  if (!root || root.kind != DELTA_PARALLEL_ROOT || !root.descriptor)
  {
   typed_delta_fail(
    context, "parallel root has no unique source-order identity"
   );
   return false;
  }
  for (usz previous = 0; previous < (usz)index; previous++)
  {
   mitos::DeltaNode* other = mitos::delta_node(
    context.program, nodes[previous]
   );
   if (other.descriptor == root.descriptor)
   {
    typed_delta_fail(
     context, "parallel root has no unique source-order identity"
    );
    return false;
   }
  }
  usz insertion = (usz)index;
  while (insertion)
  {
   usz other_index = ordered_indices[insertion - 1];
   mitos::DeltaNode* other = mitos::delta_node(
    context.program, nodes[other_index]
   );
   if (other.descriptor < root.descriptor) break;
   ordered_indices[insertion] = other_index;
   insertion--;
  }
  ordered_indices[insertion] = (usz)index;
 }
 return true;
}

fn bool typed_delta_evaluate_parallel(
 TypedDeltaContext* context,
 mitos::DeltaNodeId[] nodes,
 TypedDeltaEnvironment environment,
 TypedDeltaValue*[] values,
 bool declared_roots
) @private
{
 foreach (&value : values) *value = null;
 if (!nodes.len) return true;
 usz[TYPED_DELTA_MAX_PARALLEL_ROOTS] ordered_indices;
 if (declared_roots && !typed_delta_order_parallel_roots(
  context, nodes, ordered_indices[..]
 )) return false;
 if (!declared_roots || !context.pool || !context.pool.threads.len
  || context.worker_active || context.activation)
 {
  for (usz iteration = 0; iteration < nodes.len; iteration++)
  {
   usz output_index = declared_roots
    ? ordered_indices[iteration] : iteration;
   mitos::DeltaNodeId node_id = nodes[output_index];
   usz previous_order = context.parallel_source_order;
   usz previous_occurrence = context.current_occurrence_order;
   if (declared_roots)
   {
    mitos::DeltaNode* root = mitos::delta_node(context.program, node_id);
    context.parallel_source_order = root.descriptor;
    context.current_occurrence_order = 0;
   }
   values[output_index] = typed_delta_evaluate(
    context, node_id, environment, 1
   );
   context.parallel_source_order = previous_order;
   context.current_occurrence_order = previous_occurrence;
   if (context.failed || typed_delta_is_effect(values[output_index]))
   {
    return false;
   }
  }
  return true;
 }
 usz job_bytes = nodes.len * (usz)TypedDeltaJob::size;
 if (!typed_delta_charge(context, job_bytes)) return false;
 TypedDeltaJob[] jobs = alloc::new_array(
  context.allocator, TypedDeltaJob, (sz)nodes.len
 );
 usz shared_owned_bytes = context.owned_bytes;
 usz shared_value_count = context.value_count;
 usz shared_environment_count = context.environment_count;
 usz shared_steps = context.steps;
 for (usz job_index = 0; job_index < nodes.len; job_index++)
 {
  usz output_index = ordered_indices[job_index];
  mitos::DeltaNodeId node_id = nodes[output_index];
  mitos::DeltaNode* root = mitos::delta_node(context.program, node_id);
  TypedDeltaJob* job = &jobs[job_index];
  TypedDeltaContext* child = &job.context;
  typed_delta_context_init(
   child,
   context.program,
   context.allocator,
   context.pool,
   context.host_entries,
   context.storage,
   true
  );
  child.shared_budget_mutex = &context.pool.budget_mutex;
  child.shared_owned_bytes = &shared_owned_bytes;
  child.shared_value_count = &shared_value_count;
  child.shared_environment_count = &shared_environment_count;
  child.shared_steps = &shared_steps;
  child.substitution = context.substitution;
  child.external_owner = context.external_owner;
  job.node = node_id;
  job.environment = environment;
  job.source_order = root.descriptor;
  job.output_index = output_index;
 }
 TypedDeltaBatch batch = { .jobs = jobs };
 TypedDeltaPool* pool = context.pool;
 pool.mutex.lock();
 if (pool.batch)
 {
  pool.mutex.unlock();
  typed_delta_fail(
   context, "nested typed Delta worker-pool submission is forbidden"
  );
  foreach (&job : jobs) typed_delta_adopt_child(context, &job.context);
  alloc::free(context.allocator, jobs);
  return false;
 }
 pool.batch = &batch;
 pool.work_available.broadcast();
 while (batch.completed < batch.jobs.len)
 {
  pool.batch_completed.wait(&pool.mutex);
 }
 pool.batch = null;
 pool.mutex.unlock();

 bool replay_in_source_order = false;
 foreach (&job : jobs)
 {
  mitos::DeltaOperationDescriptor* operation =
   typed_delta_is_effect(job.value)
    ? typed_delta_operation(&job.context, job.value.effect_operation)
    : null;
  replay_in_source_order = replay_in_source_order
   || job.context.shared_budget_exhausted
   || (operation && operation.host_kind == DELTA_EFFECT_EXTERNAL);
 }
 if (replay_in_source_order)
 {
  foreach (&job : jobs)
  {
   if (job.context.failed) job.context.diagnostic.deinit();
   typed_delta_context_free(&job.context);
  }
  bool replay_ok = true;
  foreach (&job : jobs)
  {
   usz previous_order = context.parallel_source_order;
   usz previous_occurrence = context.current_occurrence_order;
   context.parallel_source_order = job.source_order;
   context.current_occurrence_order = 0;
   values[job.output_index] = typed_delta_evaluate(
    context, job.node, job.environment, 1
   );
   context.parallel_source_order = previous_order;
   context.current_occurrence_order = previous_occurrence;
   if (context.failed || typed_delta_is_effect(values[job.output_index]))
   {
    replay_ok = false;
    break;
   }
  }
  alloc::free(context.allocator, jobs);
  return replay_ok;
 }

 bool ok = true;
 bool terminal_seen = false;
 foreach (&job : jobs)
 {
  typed_delta_adopt_child(context, &job.context);
  values[job.output_index] = job.value;
  if (terminal_seen)
  {
   if (job.context.failed) job.context.diagnostic.deinit();
   continue;
  }
  if (job.context.failed)
  {
   context.failed = true;
   context.diagnostic = job.context.diagnostic;
   job.context.diagnostic = { };
   terminal_seen = true;
   ok = false;
  }
  else if (typed_delta_is_effect(job.value))
  {
   terminal_seen = true;
   ok = false;
  }
 }
 alloc::free(context.allocator, jobs);
 return ok;
}

fn TypedDeltaValue* typed_delta_evaluate(
 TypedDeltaContext* context,
 mitos::DeltaNodeId node_id,
 TypedDeltaEnvironment environment,
 usz depth
) @private
{
 if (context.failed) return null;
 if (depth >= TYPED_DELTA_MAX_NATIVE_DEPTH)
 {
  typed_delta_fail(context, "typed Delta evaluation resource limit exceeded");
  return null;
 }
 if (!typed_delta_take_step(
  context, "typed Delta evaluation resource limit exceeded"
 )) return null;
	mitos::DeltaNode* node = mitos::delta_node(context.program, node_id);
	if (!node)
	{
		typed_delta_fail(
			context,
			"typed Delta evaluation reached an invalid node identity"
		);
		return null;
	}
	if (node.kind != DELTA_EFFECT)
	{
		for (TypedDeltaSubstitution* substitution = context.substitution;
			substitution; substitution = substitution.parent)
		{
			if (substitution.hole == node_id
				&& substitution.source_order == context.parallel_source_order
				&& substitution.occurrence_order == context.current_occurrence_order)
			{
				context.current_occurrence_order++;
				return substitution.value;
			}
		}
	}
 uint previous_span = context.active_span;
 context.active_span = node.span;
 defer context.active_span = previous_span;
	context.stats.evaluations++;
	switch (node.kind)
	{
		case DELTA_LOCAL: return typed_delta_lookup(context, environment, node.name);
		case DELTA_I64: return typed_delta_i64(context, node.integer);
		case DELTA_STRING: return typed_delta_string(context, node.string_value);
		case DELTA_LAMBDA:
			TypedDeltaBinding[] capture = typed_delta_environment(context, environment, 0);
			if (context.failed || capture.len != environment.bindings.len) return null;
			if (!node.runtime_type || !node.result_type)
			{
				typed_delta_fail(context, "lambda is missing its concrete Function signature metadata");
				return null;
			}
			return typed_delta_value(context, {
				.kind = TYPED_VALUE_CLOSURE,
				.type_id = node.runtime_type,
				.closure = {
					.body = node.inputs[0],
					.parameters = node.names,
					.parameter_types = node.types,
					.environment = { .bindings = capture },
					.result_type = node.result_type,
					.effect_row = &node.effect_row,
					.signature_type = node.runtime_type,
				},
			});
		case DELTA_APPLY:
			if (!node.inputs.len)
			{
				typed_delta_fail(context, "application node has no callee");
				return null;
			}
			if (!typed_delta_charge(
				context, node.inputs.len * (usz)usz::size
			)) return null;
			TypedDeltaValue*[] application_inputs = alloc::new_array(
				context.allocator, TypedDeltaValue*, (sz)node.inputs.len
			);
			defer alloc::free(context.allocator, application_inputs);
			foreach (index, input : node.inputs)
			{
				application_inputs[index] = typed_delta_evaluate(
					context, input, environment, depth + 1
				);
				if (context.failed
					|| typed_delta_is_effect(application_inputs[index]))
				{
					return context.failed ? null : application_inputs[index];
				}
			}
			return typed_delta_lift_values(
				context, node, environment, application_inputs,
				TYPED_LIFT_APPLICATION, depth
			);
		case DELTA_LET:
			TypedDeltaValue* bound = typed_delta_evaluate(context, node.inputs[0], environment, depth + 1);
			if (context.failed) return null;
			if (typed_delta_is_effect(bound)) return bound;
			TypedDeltaBinding[] let_environment = typed_delta_environment(context, environment, 1);
			if (context.failed
				|| let_environment.len != environment.bindings.len + 1) return null;
			let_environment[environment.bindings.len] = { .name = node.names[0], .value = bound };
			return typed_delta_evaluate(context, node.inputs[1], { .bindings = let_environment }, depth + 1);
		case DELTA_CONSTRUCTOR:
			if (!typed_delta_charge(
				context, node.inputs.len * (usz)usz::size
			)) return null;
			TypedDeltaValue*[] constructor_inputs = alloc::new_array(
				context.allocator, TypedDeltaValue*, (sz)node.inputs.len
			);
			defer alloc::free(context.allocator, constructor_inputs);
			foreach (index, input : node.inputs)
			{
				constructor_inputs[index] = typed_delta_evaluate(
					context, input, environment, depth + 1
				);
				if (context.failed
					|| typed_delta_is_effect(constructor_inputs[index]))
				{
					return context.failed ? null : constructor_inputs[index];
				}
			}
			return typed_delta_lift_values(
				context, node, environment, constructor_inputs,
				TYPED_LIFT_CONSTRUCTOR, depth
			);
		case DELTA_MATCH:
			if (node.inputs.len != 1)
			{
				typed_delta_fail(context, "match node has an invalid scrutinee layout");
				return null;
			}
			TypedDeltaValue* match_scrutinee = typed_delta_evaluate(
				context, node.inputs[0], environment, depth + 1
			);
			if (context.failed || typed_delta_is_effect(match_scrutinee))
			{
				return match_scrutinee;
			}
			TypedDeltaValue*[1] match_inputs = { match_scrutinee };
			return typed_delta_lift_values(
				context, node, environment, match_inputs[..],
				TYPED_LIFT_MATCH, depth
			);
		case DELTA_GENERIC_CALL:
			if (!typed_delta_charge(
				context, node.inputs.len * (usz)usz::size
			)) return null;
			TypedDeltaValue*[] dispatch_inputs = alloc::new_array(
				context.allocator, TypedDeltaValue*, (sz)node.inputs.len
			);
			defer alloc::free(context.allocator, dispatch_inputs);
			bool dispatch_inputs_ok = typed_delta_evaluate_parallel(
				context, node.inputs, environment, dispatch_inputs, false
			);
			if (context.failed) return null;
			if (!dispatch_inputs_ok)
			{
				foreach (argument : dispatch_inputs)
				{
					if (typed_delta_is_effect(argument)) return argument;
				}
				typed_delta_fail(context, "parallel dispatch demand failed without a value");
				return null;
			}
			return typed_delta_lift_values(
				context, node, environment, dispatch_inputs,
				TYPED_LIFT_GENERIC_CALL, depth
			);
		case DELTA_TYPE_VALUE:
			return typed_delta_type(context, (mitos::TypeId)node.descriptor);
		case DELTA_TYPE_ASSERT:
			TypedDeltaValue* asserted = typed_delta_evaluate(
				context, node.inputs[0], environment, depth + 1
			);
			if (context.failed || typed_delta_is_effect(asserted)) return asserted;
			if (!typed_delta_assert_type(
				context, asserted.type_id, (mitos::TypeId)node.descriptor
			)) return null;
			return asserted;
		case DELTA_TYPE_OF:
			TypedDeltaValue* inspected = typed_delta_evaluate(
				context, node.inputs[0], environment, depth + 1
			);
			if (context.failed || typed_delta_is_effect(inspected)) return inspected;
			return typed_delta_type(context, inspected.type_id);
		case DELTA_PRIMITIVE:
			if (node.inputs.len != 2)
			{
				typed_delta_fail(context, "primitive node has an invalid argument layout");
				return null;
			}
			TypedDeltaValue*[2] primitive_inputs;
			foreach (index, input : node.inputs)
			{
				primitive_inputs[index] = typed_delta_evaluate(
					context, input, environment, depth + 1
				);
				if (context.failed
					|| typed_delta_is_effect(primitive_inputs[index]))
				{
					return context.failed ? null : primitive_inputs[index];
				}
			}
			return typed_delta_lift_values(
				context, node, environment, primitive_inputs[..],
				TYPED_LIFT_PRIMITIVE, depth
			);
		case DELTA_SUPERPOSE:
			return typed_delta_superpose(context, node, environment, depth);
		case DELTA_COLLAPSE:
			if (node.inputs.len != 1)
			{
				typed_delta_fail(context, "collapse requires exactly one input");
				return null;
			}
			TypedDeltaValue* collapsed_input = typed_delta_evaluate(
				context, node.inputs[0], environment, depth + 1
			);
			if (context.failed || typed_delta_is_effect(collapsed_input))
			{
				return collapsed_input;
			}
			TypedDeltaValue* collapsed_value = typed_delta_collapse(
				context, collapsed_input
			);
			if (collapsed_value && node.result_type != mitos::TYPE_ID_ANY
				&& node.static_type && !typed_delta_assert_type(
					context, collapsed_value.type_id, node.static_type
				)) return null;
			return collapsed_value;
		case DELTA_PARALLEL_ROOT: return typed_delta_evaluate(context, node.inputs[0], environment, depth + 1);
		case DELTA_PARALLEL_JOIN:
			usz binding_count = node.names.len;
			if (node.inputs.len != binding_count + 1)
			{
				typed_delta_fail(context, "parallel join has inconsistent root metadata");
				return null;
			}
			if (!typed_delta_charge(
				context, binding_count * (usz)usz::size
			)) return null;
			TypedDeltaValue*[] values = alloc::new_array(
				context.allocator, TypedDeltaValue*, (sz)binding_count
			);
			defer alloc::free(context.allocator, values);
			bool roots_ok = typed_delta_evaluate_parallel(
				context, node.inputs[:(sz)binding_count], environment, values, true
			);
			if (context.failed) return null;
			if (!roots_ok)
			{
				foreach (value : values)
				{
					if (typed_delta_is_effect(value)) return value;
				}
				typed_delta_fail(context, "parallel roots failed without a source-ordered diagnostic");
				return null;
			}
			TypedDeltaBinding[] parallel_environment = typed_delta_environment(
				context, environment, binding_count
			);
			if (context.failed
				|| parallel_environment.len
					!= environment.bindings.len + binding_count) return null;
			foreach (index, name : node.names)
			{
				parallel_environment[environment.bindings.len + index] = {
					.name = name,
					.value = values[index],
				};
				context.stats.parallel_bindings++;
			}
			return typed_delta_evaluate(
				context,
				node.inputs[binding_count],
				{ .bindings = parallel_environment },
				depth + 1
			);
		case DELTA_EFFECT:
			if (!typed_delta_charge(
				context, node.inputs.len * (usz)usz::size
			)) return null;
			TypedDeltaValue*[] effect_inputs = alloc::new_array(
				context.allocator, TypedDeltaValue*, (sz)node.inputs.len
			);
			defer alloc::free(context.allocator, effect_inputs);
			foreach (index, input : node.inputs)
			{
				effect_inputs[index] = typed_delta_evaluate(
					context, input, environment, depth + 1
				);
				if (context.failed
					|| typed_delta_is_effect(effect_inputs[index]))
				{
					return context.failed ? null : effect_inputs[index];
				}
			}
			foreach (effect_input : effect_inputs)
			{
				if (effect_input.kind != TYPED_VALUE_SUPERPOSITION) continue;
				typed_delta_fail(
					context,
					"effect operation arguments cannot be superpositions; superpose the effect calls explicitly"
				);
				return null;
			}
			return typed_delta_effect_values(
				context, (mitos::DeltaNodeId)node.stable_id, node, effect_inputs
			);
		case DELTA_HANDLER:
			return typed_delta_handler(context, node, environment, depth);
		case DELTA_RESUME:
			TypedDeltaHandlerActivation* activation = context.activation;
			if (!activation || activation.handler_index != node.descriptor
				|| activation.generation != context.program.effects.epoch)
			{
				typed_delta_fail(context, "invalid resume has no live matching continuation");
				return null;
			}
			if ((!activation.multi && activation.resumes_used >= 1)
				|| (activation.resume_limit
					&& activation.resumes_used >= activation.resume_limit)
				|| activation.resumes_used >= TYPED_DELTA_MAX_VALUES)
			{
				typed_delta_fail(
					context,
					activation.multi
						? "multi-shot continuation exceeded its bounded resume budget"
						: "one-shot continuation cannot be resumed more than once"
				);
				return null;
			}
			TypedDeltaValue* resumed = typed_delta_evaluate(
				context, node.inputs[0], environment, depth + 1
			);
			if (context.failed || typed_delta_is_effect(resumed)) return resumed;
			mitos::TypeId resumed_expected = node.types.len
				? node.types[0] : activation.operation_result_type;
			if (!typed_delta_assert_type(
				context, resumed.type_id, resumed_expected
			) || !typed_delta_assert_type(
				context, resumed.type_id, activation.operation_result_type
			)) return null;
			activation.resumes_used++;
			context.stats.continuations_resumed++;
			if (activation.multi) context.stats.replicator_branches++;
			return typed_delta_resume_graph(
				context, activation, resumed, depth + 1
			);
		case DELTA_ABORT:
			TypedDeltaValue* aborted = typed_delta_evaluate(context, node.inputs[0], environment, depth + 1);
			if (context.failed || typed_delta_is_effect(aborted)) return aborted;
			if (context.activation && context.activation.handler_index == node.descriptor)
			{
				context.activation.aborted = true;
				context.stats.continuations_erased++;
			}
			return aborted;
		default: typed_delta_fail(context, "unknown typed Delta node kind"); return null;
	}
}

fn bool typed_delta_format_append(
 TypedDeltaContext* context,
 DString* output,
 String value
) @private
{
 if (context.failed) return false;
 usz length = output.str_view().len;
 if (length > TYPED_DELTA_MAX_FORMAT_BYTES
  || value.len > TYPED_DELTA_MAX_FORMAT_BYTES - length)
 {
  typed_delta_fail(context, "formatted result exceeds the byte limit");
  return false;
 }
 output.append_string(value);
 return true;
}

fn bool typed_delta_format_append_char(
 TypedDeltaContext* context,
 DString* output,
 char value
) @private
{
 if (context.failed) return false;
 if (output.str_view().len >= TYPED_DELTA_MAX_FORMAT_BYTES)
 {
  typed_delta_fail(context, "formatted result exceeds the byte limit");
  return false;
 }
 output.append_char(value);
 return true;
}

fn bool typed_delta_append_string(
 TypedDeltaContext* context,
 DString* output,
 String value
) @private
{
 if (!typed_delta_format_append_char(context, output, '"')) return false;
 String hexadecimal = "0123456789abcdef";
 foreach (character : value)
 {
  switch (character)
  {
   case '"':
    if (!typed_delta_format_append(context, output, "\\\"")) return false;
   case '\\':
    if (!typed_delta_format_append(context, output, "\\\\")) return false;
   case '\n':
    if (!typed_delta_format_append(context, output, "\\n")) return false;
   case '\r':
    if (!typed_delta_format_append(context, output, "\\r")) return false;
   case '\t':
    if (!typed_delta_format_append(context, output, "\\t")) return false;
   default:
    if ((usz)character < 0x20 || (usz)character == 0x7f)
    {
     usz byte = (usz)character;
     if (!typed_delta_format_append(context, output, "\\x")
      || !typed_delta_format_append_char(
       context, output, hexadecimal[byte >> 4]
      )
      || !typed_delta_format_append_char(
       context, output, hexadecimal[byte & 0x0f]
      )) return false;
    }
    else if (!typed_delta_format_append_char(
     context, output, character
    )) return false;
  }
 }
 return typed_delta_format_append_char(context, output, '"');
}

fn bool typed_delta_append_escaped_metadata_byte(
 TypedDeltaContext* context,
 DString* output,
 char value
) @private
{
 String hexadecimal = "0123456789abcdef";
 usz byte = (usz)value & 0xff;
 return typed_delta_format_append(context, output, "\\x")
  && typed_delta_format_append_char(context, output, hexadecimal[byte >> 4])
  && typed_delta_format_append_char(context, output, hexadecimal[byte & 0x0f]);
}

fn bool typed_delta_append_metadata_identifier(
 TypedDeltaContext* context,
 DString* output,
 String identifier
) @private
{
 foreach (index, character : identifier)
 {
  bool source_byte = character >= 'A' && character <= 'Z'
   || character >= 'a' && character <= 'z'
   || character == '_'
   || index && character >= '0' && character <= '9';
  if (source_byte)
  {
   if (!typed_delta_format_append_char(context, output, character)) return false;
  }
  else if (!typed_delta_append_escaped_metadata_byte(
   context, output, character
  )) return false;
 }
 return true;
}

fn bool typed_delta_append_type_metadata_locked(
 TypedDeltaContext* context,
 DString* output,
 mitos::TypeId type_id,
 usz depth
) @private
{
 if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH)
 {
  typed_delta_fail(context, "type metadata exceeds its formatting depth");
  return false;
 }
 mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
  &context.program.types, type_id
 );
 if (!descriptor)
 {
  typed_delta_fail(context, "type value has invalid runtime metadata");
  return false;
 }
 if (!typed_delta_append_metadata_identifier(
  context, output, descriptor.name
 )) return false;
 if (descriptor.kind
  == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
 {
  if (!typed_delta_format_append(context, output, " of (")) return false;
  foreach (index, parameter : descriptor.function_parameters)
  {
   if (index && !typed_delta_format_append(context, output, ", ")) return false;
   if (!typed_delta_append_type_metadata_locked(
    context, output, parameter, depth + 1
   )) return false;
  }
  return typed_delta_format_append(context, output, ") -> ")
   && typed_delta_append_type_metadata_locked(
    context, output, descriptor.function_result, depth + 1
   );
 }
 if (descriptor.kind
  != mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE) return true;
 if (!typed_delta_format_append(context, output, " of ")) return false;
 if (descriptor.arguments.len > 1
  && !typed_delta_format_append_char(context, output, '(')) return false;
 foreach (index, argument : descriptor.arguments)
 {
  if (index && !typed_delta_format_append(context, output, ", ")) return false;
  if (!typed_delta_append_type_metadata_locked(
   context, output, argument, depth + 1
  )) return false;
 }
 return descriptor.arguments.len <= 1
  || typed_delta_format_append_char(context, output, ')');
}

fn void typed_delta_append_value(
 TypedDeltaContext* context,
 DString* output,
 TypedDeltaValue* value,
 usz depth
) @private
{
 if (context.failed) return;
 if (!value || depth >= TYPED_DELTA_MAX_NATIVE_DEPTH)
 {
  typed_delta_fail(context, "typed Delta value exceeds formatting limits");
  return;
 }
 switch (value.kind)
 {
  case TYPED_VALUE_I64:
   char[32] buffer;
   (void)typed_delta_format_append(
    context, output, (String)io::bprintf(&buffer, "%d", value.integer)!!
   );
  case TYPED_VALUE_BOOL:
   (void)typed_delta_format_append(
    context, output, value.boolean ? "True" : "False"
   );
  case TYPED_VALUE_UNIT:
   (void)typed_delta_format_append(context, output, "()");
  case TYPED_VALUE_STRING:
   usz formatted_length = output.str_view().len;
   if (formatted_length > TYPED_DELTA_MAX_FORMAT_BYTES
    || TYPED_DELTA_MAX_FORMAT_BYTES - formatted_length < 2)
   {
    typed_delta_fail(context, "formatted result exceeds the byte limit");
    return;
   }
   usz copy_limit =
    TYPED_DELTA_MAX_FORMAT_BYTES - formatted_length - 2;
   String text;
   if (!typed_delta_copy_storage_string(
    context, value, &text, null, copy_limit
   )) return;
   (void)typed_delta_append_string(context, output, text);
   alloc::free(context.allocator, text);
  case TYPED_VALUE_TYPE:
   typed_delta_lock_registry(context);
   (void)typed_delta_append_type_metadata_locked(
    context, output, value.type_id, 0
   );
   typed_delta_unlock_registry(context);
  case TYPED_VALUE_CLOSURE:
   (void)typed_delta_format_append(context, output, "<lambda>");
  case TYPED_VALUE_CONSTRUCTOR:
   if (value.constructor >= context.program.constructors.len)
   {
    typed_delta_fail(context, "constructor value has an invalid descriptor");
    return;
   }
   if (!typed_delta_append_metadata_identifier(
    context, output, context.program.constructors[value.constructor].name
   )) return;
   if (value.fields.len)
   {
    if (!typed_delta_format_append(context, output, "(")) return;
    foreach (index, field : value.fields)
    {
     if (index && !typed_delta_format_append(context, output, ", ")) return;
     typed_delta_append_value(context, output, field, depth + 1);
     if (context.failed) return;
    }
    (void)typed_delta_format_append(context, output, ")");
   }
  case TYPED_VALUE_ARRAY:
   if (!typed_delta_format_append(context, output, "[")) return;
   foreach (index, element : value.elements)
   {
    if (index && !typed_delta_format_append(context, output, ", ")) return;
    typed_delta_append_value(context, output, element, depth + 1);
    if (context.failed) return;
   }
   (void)typed_delta_format_append(context, output, "]");
  case TYPED_VALUE_SUPERPOSITION:
   if (!typed_delta_format_append(context, output, "superpose(")) return;
   foreach (index, &alternative : value.alternatives)
   {
    if (index && !typed_delta_format_append(context, output, ", ")) return;
    typed_delta_append_value(
     context, output, alternative.value, depth + 1
    );
    if (context.failed) return;
   }
   (void)typed_delta_format_append(context, output, ")");
  case TYPED_VALUE_EFFECT_REQUEST:
   typed_delta_fail(
    context, "unhandled effect reached typed Delta formatting"
   );
  default:
 }
}
fn AgentType typed_delta_value_agent(TypedDeltaValue* value) @private
{
	switch (value.kind)
	{
		case TYPED_VALUE_I64: return I64_AGENT;
		case TYPED_VALUE_STRING: return STRING_AGENT;
		case TYPED_VALUE_TYPE: return TYPE_VALUE_AGENT;
		case TYPED_VALUE_CLOSURE: return LAMBDA_AGENT;
		case TYPED_VALUE_ARRAY: return ARRAY_AGENT;
		default: return CONSTRUCTOR_AGENT;
	}
}
fn bool typed_delta_reify_storage(
 TypedDeltaContext* context,
 Net* net,
 TypedDeltaValue* value,
 NetRef practical
) @private
{
 if (!value.storage.generation) return true;
 mitos::LayoutDescriptor descriptor;
 if (!typed_delta_layout(context, value.type_id, &descriptor))
 {
  typed_delta_fail(context, "stored practical value has no runtime layout");
  return false;
 }
 mitos_storage::LayoutHandleResult layout = mitos_storage::register_layout(
  &net.storage, value.type_id, &descriptor
 );
 if (layout.error != mitos_storage::StorageError.STORAGE_OK)
 {
  typed_delta_fail_storage(context, layout.error);
  return false;
 }
 usz length;
 mitos_storage::StorageError measured = mitos_storage::byte_length(
  context.storage, value.storage, &length
 );
 if (measured != mitos_storage::StorageError.STORAGE_OK)
 {
  typed_delta_fail_storage(context, measured);
  return false;
 }
 if (!typed_delta_charge(context, length)) return false;
 char[] bytes = alloc::new_array(context.allocator, char, (sz)length);
 defer alloc::free(context.allocator, bytes);
 mitos_storage::StorageError copied = mitos_storage::copy_all(
  context.storage, value.storage, bytes
 );
 if (copied != mitos_storage::StorageError.STORAGE_OK)
 {
  typed_delta_fail_storage(context, copied);
  return false;
 }
 usz alignment = 1;
 if (descriptor.element_type)
 {
  mitos::LayoutDescriptor element;
  if (typed_delta_layout(context, descriptor.element_type, &element))
  {
   alignment = (usz)element.alignment;
  }
 }
 if (!typed_delta_charge(context, length)) return false;
 mitos_storage::StorageHandleResult stored = mitos_storage::allocate_shared_bytes(
  &net.storage, layout.handle, bytes, alignment,
  value.storage_stride, value.storage_stride
 );
 if (stored.error != mitos_storage::StorageError.STORAGE_OK)
 {
  typed_delta_fail_storage(context, stored.error);
  return false;
 }
 if (!practical_agent_take_storage(
  net, practical, &stored.handle, value.storage_count, value.storage_stride
 ))
 {
  if (stored.handle != mitos_storage::INVALID_STORAGE_HANDLE)
  {
   (void)mitos_storage::release(&net.storage, stored.handle);
  }
  typed_delta_fail(context, "practical storage ownership transfer failed");
  return false;
 }
 return true;
}

fn bool typed_delta_reify_value(
	TypedDeltaContext* context,
	Net* net,
	TypedDeltaValue* value,
	NetRef destination,
	usz depth
) @private
{
	if (!value || depth >= TYPED_DELTA_MAX_NATIVE_DEPTH)
	{
		typed_delta_fail(context, "typed value exceeds practical reification depth");
		return false;
	}
	if (value.kind == TYPED_VALUE_SUPERPOSITION)
	{
		usz scratch_bytes;
		if (value.alternatives.len > usz::max / (usz)long::size)
		{
			typed_delta_fail(
				context,
				"superposition reification exceeds its resource bound"
			);
			return false;
		}
		scratch_bytes = value.alternatives.len * (usz)long::size;
		if (!typed_delta_charge(context, scratch_bytes)) return false;
		context.stats.replicator_branches += value.alternatives.len;
		long[] ordered_deltas = alloc::new_array(
			context.allocator, long, (sz)value.alternatives.len
		);
		foreach (&delta : ordered_deltas) *delta = 0;
		NetRef node_ref = new_replicator(
			net,
			value.origin,
			ordered_deltas,
			UNKNOWN,
			PARENT,
			true,
			value.origin
		);
		alloc::free(context.allocator, ordered_deltas);
		Node* node = net.nodes.get_ref(node_ref);
		(void)connect(net, destination, node.agent.replicator.principal);
		foreach (index, &alternative : value.alternatives)
		{
			if (!typed_delta_reify_value(
				context,
				net,
				alternative.value,
				node.agent.replicator.auxiliaries[index],
				depth + 1
			)) return false;
		}
		return true;
	}
	usz arity = value.kind == TYPED_VALUE_CONSTRUCTOR
		? value.fields.len
		: value.kind == TYPED_VALUE_ARRAY && !value.storage.generation
			? value.elements.len : 0;
	NetRef node_ref = new_practical_agent(
		net,
		typed_delta_value_agent(value),
		arity,
		0,
		(uint)value.type_id,
		value.kind == TYPED_VALUE_I64 ? value.integer : 0,
		value.kind == TYPED_VALUE_CONSTRUCTOR
			? value.constructor : (usz)value.represented_type
	);
	Node* node = net.nodes.get_ref(node_ref);
	mitos::LayoutDescriptor value_layout;
	if (!typed_delta_layout(context, value.type_id, &value_layout))
	{
		typed_delta_fail(context, "practical value has no runtime layout");
		return false;
	}
	if (!typed_delta_reify_storage(context, net, value, node_ref))
	{
		return false;
	}
	(void)connect(net, destination, node.agent.practical.principal);
	if (value.kind == TYPED_VALUE_CONSTRUCTOR)
	{
		foreach (index, field : value.fields)
		{
			if (!typed_delta_reify_value(
				context, net, field,
				node.agent.practical.auxiliaries[index], depth + 1
			)) return false;
		}
	}
	if (value.kind == TYPED_VALUE_ARRAY && !value.storage.generation)
	{
		foreach (index, element : value.elements)
		{
			if (!typed_delta_reify_value(
				context, net, element,
				node.agent.practical.auxiliaries[index], depth + 1
			)) return false;
		}
	}
	return true;
}
fn void typed_delta_context_free(TypedDeltaContext* context) @private
{
	foreach (environment : context.environments) alloc::free(context.allocator, environment);
	context.environments.free();
	foreach (value : context.values)
	{
		if (value.storage.generation)
		{
			(void)mitos_storage::release(context.storage, value.storage);
		}
		alloc::free(context.allocator, value.fields);
		alloc::free(context.allocator, value.elements);
		foreach (&alternative : value.alternatives)
		{
			alloc::free(context.allocator, alternative.assignments);
		}
		alloc::free(context.allocator, value.alternatives);
		alloc::free(context.allocator, value.effect_arguments);
		alloc::free(context.allocator, value);
	}
	context.values.free();
 if (context.external_owner == context)
 {
  foreach (&lane : context.external_lanes) lane.results.free();
 }
 context.external_lanes.free();
	if (context.owns_storage) context.local_storage.free();
	if (context.owns_host_entries)
	{
		alloc::free(context.allocator, context.host_entries);
		context.host_entries = { };
		context.owns_host_entries = false;
	}
	if (context.owned_program)
	{
		context.owned_program.deinit();
		alloc::free((Allocator)&context.program_allocator, context.owned_program);
		assert(
			!context.program_allocator.live_bytes,
			"typed Delta program clone retained allocations after deinit"
		);
		context.owned_program = null;
		context.program = null;
	}
}

fn bool typed_delta_materialize_root(
	mitos::DeltaProgram* program,
	mitos::DeltaNodeId root,
	Allocator allocator,
	DeltaDiagnostic* diagnostic
) @private
{
	DeltaTranslationResult materialized = translate_delta_program(program, root, allocator);
	if (!materialized.ok())
	{
		diagnostic.init(
			allocator,
			materialized.diagnostics[0].message,
			materialized.diagnostics[0].span
		);
		materialized.deinit();
		return false;
	}
	DeltaPracticalReadbackResult image_root = readback_practical_root(
		&materialized.net,
		materialized.root,
		allocator
	);
	if (!image_root.ok())
	{
		diagnostic.init(allocator, image_root.diagnostics[0].message);
		image_root.deinit();
		materialized.deinit();
		return false;
	}
	image_root.deinit();
	materialized.deinit();
	return true;
}

fn bool typed_delta_copy_request(
 TypedDeltaContext* context,
 TypedDeltaValue* request,
 TypedDeltaRequestView* view
) @private
{
 mitos::DeltaOperationDescriptor* operation = typed_delta_operation(
  context, request.effect_operation
 );
 if (!operation) return false;
 *view = {
  .allocator = context.allocator,
  .effect = request.effect_instance,
  .operation = operation.id,
  .result_type = request.effect_result_type,
  .source_order = request.effect_source_order,
  .occurrence_order = request.effect_occurrence_order,
 };
 usz request_bytes = 0;
 if (request.effect_arguments.len
  > TYPED_DELTA_MAX_OWNED_BYTES / (usz)TypedDeltaHostValue::size)
 {
  typed_delta_fail(context, "external effect request view exceeds its resource bound");
  return false;
 }
 usz argument_bytes =
  request.effect_arguments.len * (usz)TypedDeltaHostValue::size;
 if (!typed_delta_request_charge(context, &request_bytes, argument_bytes))
 {
  return false;
 }
 view.arguments = alloc::new_array(
  context.allocator, TypedDeltaHostValue, (sz)request.effect_arguments.len
 );
 foreach (&argument : view.arguments) *argument = { };
 foreach (index, argument : request.effect_arguments)
 {
  if (!typed_delta_host_view(
   context, argument, &view.arguments[index], &request_bytes
  ))
  {
   typed_delta_free_host_arguments(context.allocator, view.arguments);
   view.arguments = { };
   return false;
  }
 }
 return true;
}


fn bool typed_delta_complete_external(
 TypedDeltaContext* context,
 TypedDeltaValue* request,
 TypedDeltaValue* value
) @private
{
 TypedDeltaExternalResult* slot = typed_delta_external_slot(
  context,
  request.effect_source_order,
  request.effect_node,
  request.effect_occurrence_order,
  false
 );
 if (!slot || slot.ready)
 {
  if (!context.failed)
  {
   typed_delta_fail(
    context, "external resumption has no matching pending work state"
   );
  }
  return false;
 }
 slot.value = value;
 slot.ready = true;
 context.current_occurrence_order = 0;
 context.parallel_source_order = typed_delta_entry_source_order(context.program);
 return true;
}

fn void typed_delta_finish_result(
 TypedDeltaContext* context,
 TypedDeltaValue* value,
 TypedDeltaExecutionResult* result
) @private
{
 if (!context.failed)
 {
  Net result_net;
  result_net.init();
  NetRef root = new_interface(&result_net, ROOT, "");
  if (typed_delta_reify_value(
   context, &result_net, value, result_net.interfaces.get_ref(root).port, 0
  ) && validate_net(&result_net))
  {
   DeltaPracticalReadbackResult reified = readback_practical_root(
    &result_net, root, context.allocator
   );
   if (!reified.ok())
   {
    typed_delta_fail(context, reified.diagnostics[0].message);
   }
   else
   {
    context.stats.phase_two_reifications++;
   }
   reified.deinit();
  }
  else if (!context.failed)
  {
   typed_delta_fail(context, "phase-two practical value failed stable-slot validation");
  }
  result_net.free();
 }
 if (!context.failed)
 {
  DString formatted;
  formatted.init(context.allocator);
  typed_delta_append_value(context, &formatted, value, 0);
  if (!context.failed) result.formatted = formatted.copy_str(context.allocator);
  formatted.free();
 }
 result.stats = context.stats;
 result.type_id = value ? value.type_id : mitos::TYPE_ID_INVALID;
 if (context.failed)
 {
  result.status = TYPED_DELTA_FAILED;
  result.diagnostics = alloc::new_array(context.allocator, DeltaDiagnostic, 1);
  result.diagnostics[0] = context.diagnostic;
  context.diagnostic = { };
 }
 else
 {
  result.status = TYPED_DELTA_COMPLETE;
 }
 typed_delta_context_free(context);
}

fn bool typed_delta_charge_retained_state(
	TypedDeltaContext* context
) @private
{
	if (context.program_allocator.overflowed
		|| context.program_allocator.live_bytes < context.accounted_program_bytes)
	{
		typed_delta_fail(context, "typed Delta program-clone byte accounting failed");
		return false;
	}
	usz program_delta =
		context.program_allocator.live_bytes - context.accounted_program_bytes;
	if (program_delta && !typed_delta_charge(context, program_delta)) return false;
	context.accounted_program_bytes = context.program_allocator.live_bytes;

	usz storage_bytes = 0;
	mitos_storage::StorageError measured = mitos_storage::retained_bytes(
		context.storage, &storage_bytes
	);
	if (measured != mitos_storage::StorageError.STORAGE_OK)
	{
		typed_delta_fail_storage(context, measured);
		return false;
	}
 usz storage_growth = storage_bytes > context.accounted_storage_bytes
  ? storage_bytes - context.accounted_storage_bytes : 0;
 usz payload_growth =
  context.storage_payload_bytes > context.accounted_storage_payload_bytes
  ? context.storage_payload_bytes - context.accounted_storage_payload_bytes : 0;
 if (storage_growth > payload_growth
  && !typed_delta_charge(context, storage_growth - payload_growth)) return false;
 context.accounted_storage_bytes = storage_bytes;
 context.accounted_storage_payload_bytes = context.storage_payload_bytes;
	return true;
}

fn bool typed_delta_escape(
 TypedDeltaContext* context,
 TypedDeltaValue* request,
 TypedDeltaExecutionResult* result,
 TypedDeltaSuspension** escaped
) @private
{
 if (!(context.program.feature_manifest.required
  & mitos::DELTA_FEATURE_SUSPENSION))
 {
  typed_delta_fail(
   context,
   "host handler suspended without the program SUSPENSION capability"
  );
  typed_delta_finish_result(context, null, result);
  return false;
 }
 if (!typed_delta_host_resume_type(context, request.effect_result_type))
 {
  typed_delta_fail(
   context,
   "host ABI 2.0 cannot resume the suspended operation result type"
  );
  typed_delta_finish_result(context, null, result);
  return false;
 }
 if (!typed_delta_charge_retained_state(context))
 {
  typed_delta_finish_result(context, null, result);
  return false;
 }
 if (!typed_delta_charge(context, (usz)TypedDeltaSuspension::size))
 {
  typed_delta_finish_result(context, null, result);
  return false;
 }
 TypedDeltaSuspension* suspension = alloc::new(
  context.allocator,
  TypedDeltaSuspension,
  {
   .context = context,
   .request = request,
   .result_type = request.effect_result_type,
   .effect_epoch = context.program.effects.epoch,
   .live = true,
  }
 );
 context.pool = null;
 if (!typed_delta_copy_request(context, request, &result.request))
 {
  typed_delta_finish_result(context, null, result);
  suspension.context = null;
  suspension.live = false;
  alloc::free(result.allocator, suspension);
  return false;
 }
 result.status = TYPED_DELTA_SUSPENDED;
 result.stats = context.stats;
 result.type_id = request.effect_result_type;
 *escaped = suspension;
 return true;
}

fn void typed_delta_drive(
 TypedDeltaContext* context,
 TypedDeltaValue* value,
 TypedDeltaExecutionResult* result,
 TypedDeltaSuspension** escaped
) @private
{
 while (!context.failed && typed_delta_is_effect(value))
 {
  mitos::DeltaOperationDescriptor* operation = typed_delta_operation(
   context, value.effect_operation
  );
  mitos::DeltaNode* occurrence = mitos::delta_node(
   context.program, value.effect_node
  );
  if (occurrence) context.active_span = occurrence.span;
  if (!operation || operation.host_kind != DELTA_EFFECT_EXTERNAL)
  {
   typed_delta_fail(
    context,
    operation
     ? "unhandled effect operation escaped every lexical handler"
     : "unhandled effect has invalid operation metadata"
   );
   break;
  }
  if (!value.effect_host_suspended)
  {
   typed_delta_fail(
    context, "external effect escaped its resumable evaluation work state"
   );
   break;
  }
  (void)typed_delta_escape(context, value, result, escaped);
  return;
 }
 typed_delta_finish_result(context, value, result);
}

fn bool typed_delta_suspension_accepts(
 TypedDeltaSuspension* suspension,
 mitos::TypeId result_type
) @private
{
 if (!suspension || !suspension.live || !suspension.context
  || !result_type) return false;
 TypedDeltaContext* context = suspension.context;
 typed_delta_lock_registry(context);
 bool accepted = mitos::type_is_subtype(
  &context.program.types, result_type, suspension.result_type
 );
 typed_delta_unlock_registry(context);
 return accepted;
}

fn bool typed_delta_suspension_accepts_host(
 TypedDeltaSuspension* suspension,
 TypedDeltaHostValue value
) @private
{
 if (!suspension || !suspension.live || !suspension.context) return false;
 return typed_delta_host_value_is_valid(suspension.context, value);
}

fn void destroy_typed_delta_suspension(TypedDeltaSuspension* suspension) @private
{
 if (!suspension) return;
 TypedDeltaContext* context = suspension.context;
 Allocator allocator = context ? context.allocator : mem;
 if (suspension.live && context)
 {
  suspension.live = false;
  typed_delta_context_free(context);
  alloc::free(allocator, context);
  suspension.context = null;
 }
 alloc::free(allocator, suspension);
}

fn TypedDeltaExecutionResult resume_typed_delta_suspension(
 TypedDeltaSuspension* suspension,
 TypedDeltaHostValue result_value,
 int max_workers,
 TypedDeltaSuspension** escaped
) @private
{
 Allocator allocator = suspension.context.allocator;
 TypedDeltaExecutionResult result = { .allocator = allocator };
 *escaped = null;
 if (!typed_delta_host_value_is_valid(suspension.context, result_value))
 {
  return typed_delta_failure(
   "resumption result is not a structurally valid host ABI 2.0 value",
   allocator
  );
 }
 if (!typed_delta_suspension_accepts(suspension, result_value.type_id))
 {
  return typed_delta_failure(
   "resumption result TypeId does not match the suspended operation", allocator
  );
 }
 TypedDeltaContext* context = suspension.context;
 TypedDeltaValue* request = suspension.request;
 TypedDeltaValue* resumed_value = typed_delta_from_host(context, result_value);
 if (!resumed_value || !typed_delta_assert_type(
  context, resumed_value.type_id, suspension.result_type
 ))
 {
  typed_delta_finish_result(context, null, &result);
  alloc::free(allocator, context);
  suspension.context = null;
  suspension.live = false;
  alloc::free(allocator, suspension);
  return result;
 }
 context.stats.ordered_effect_commits++;
 if (!typed_delta_complete_external(context, request, resumed_value))
 {
  typed_delta_finish_result(context, null, &result);
  alloc::free(allocator, context);
  suspension.context = null;
  suspension.live = false;
  alloc::free(allocator, suspension);
  return result;
 }
 int worker_count = max_workers;
 if (worker_count <= 0)
 {
  worker_count = os::num_cpu();
  if (worker_count <= 0) worker_count = 1;
 }
 if (worker_count > DELTA_MAX_WORKERS) worker_count = DELTA_MAX_WORKERS;
 TypedDeltaPool pool = { };
 DeltaDiagnostic pool_error;
 if (!typed_delta_pool_start(&pool, worker_count, allocator, &pool_error))
 {
  typed_delta_fail(context, pool_error.message);
  pool_error.deinit();
 }
 context.pool = pool.threads.len ? &pool : null;
 TypedDeltaValue* value = context.failed ? null : typed_delta_evaluate(
  context, context.program.entry, { }, 0
 );
 typed_delta_drive(context, value, &result, escaped);
 typed_delta_pool_stop(&pool, allocator);
 if (!*escaped) alloc::free(allocator, context);
 suspension.context = null;
 suspension.live = false;
 alloc::free(allocator, suspension);
 return result;
}

/** Execute the immutable image in two explicit Delta phases. */
fn TypedDeltaExecutionResult run_typed_delta_program(
 mitos::DeltaProgram* program,
 int max_workers,
 TypedDeltaHostRegistry* host_handlers,
 Allocator allocator,
 TypedDeltaSuspension** escaped
) @private
{
 TypedDeltaExecutionResult result = { .allocator = allocator };
 *escaped = null;
 if (!mitos::delta_program_is_compatible(program)
  || !program.methods.generics.len()
  || !mitos::symbol_key_is_canonical(&program.methods.generics[0].key)
  || !program.entry)
 {
  return typed_delta_failure(
   "typed runtime requires a compatible, complete DeltaProgram entry image",
   allocator
  );
 }
 DeltaDiagnostic materialization_error;
 if (!typed_delta_materialize_root(
  program, program.entry, allocator, &materialization_error
 ))
 {
  result.status = TYPED_DELTA_FAILED;
  result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
  result.diagnostics[0] = materialization_error;
  return result;
 }
 foreach (&method : program.method_roots)
 {
  if (!typed_delta_materialize_root(
   program, method.root, allocator, &materialization_error
  ))
  {
   result.status = TYPED_DELTA_FAILED;
   result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
   result.diagnostics[0] = materialization_error;
   return result;
  }
 }
 TypedDeltaHostSnapshotEntry[] host_entries;
 usz missing_host_operation;
 if (!typed_delta_registry_snapshot(
  host_handlers, program, allocator, &host_entries, &missing_host_operation
 ))
 {
  result.status = TYPED_DELTA_FAILED;
  result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
  mitos::MitosSpan span = { };
  if (missing_host_operation < program.effects.operations.len)
  {
   mitos::DeltaOperationDescriptor* missing =
    &program.effects.operations[missing_host_operation];
   if (missing.span && missing.span <= program.spans.len)
   {
    span = program.spans[missing.span - 1];
   }
  }
  result.diagnostics[0].init(
   allocator,
   "external effect has no compatible registered host ABI 2.0 handler",
   span
  );
  return result;
 }
 int worker_count = max_workers;
 if (worker_count <= 0)
 {
  worker_count = os::num_cpu();
  if (worker_count <= 0) worker_count = 1;
 }
 if (worker_count > DELTA_MAX_WORKERS) worker_count = DELTA_MAX_WORKERS;
 TypedDeltaPool pool = { };
 DeltaDiagnostic pool_error;
 if (!typed_delta_pool_start(&pool, worker_count, allocator, &pool_error))
 {
  result.status = TYPED_DELTA_FAILED;
  result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
  result.diagnostics[0] = pool_error;
  if (host_entries.len) alloc::free(allocator, host_entries);
  return result;
 }
 TypedDeltaPool* active_pool = pool.threads.len ? &pool : null;
 TypedDeltaContext* context = alloc::new(
  allocator, TypedDeltaContext, { }
 );
 typed_delta_context_init(
  context, program, allocator, active_pool, host_entries, null, false, true
 );
 context.owns_host_entries = true;
 usz host_entry_bytes = 0;
 bool clone_budget_valid =
  host_entries.len <= usz::max / (usz)TypedDeltaHostSnapshotEntry::size;
 if (clone_budget_valid)
 {
  host_entry_bytes =
   host_entries.len * (usz)TypedDeltaHostSnapshotEntry::size;
 }
 usz fixed_bytes = context.program_allocator.live_bytes;
 if (!clone_budget_valid
  || fixed_bytes > TYPED_DELTA_MAX_OWNED_BYTES
  || (usz)TypedDeltaContext::size
   > TYPED_DELTA_MAX_OWNED_BYTES - fixed_bytes)
 {
  clone_budget_valid = false;
 }
 else
 {
  fixed_bytes += (usz)TypedDeltaContext::size;
  if (host_entry_bytes > TYPED_DELTA_MAX_OWNED_BYTES - fixed_bytes)
  {
   clone_budget_valid = false;
  }
  else
  {
   fixed_bytes += host_entry_bytes;
  }
 }
 if (!clone_budget_valid
  || !typed_delta_clone_program_fits(
   program, TYPED_DELTA_MAX_OWNED_BYTES - fixed_bytes
  ))
 {
  typed_delta_fail(
   context, "typed Delta retained program clone exceeds its resource bound"
  );
 }
 if (!context.failed)
 {
  mitos::DeltaProgram* owned_program = typed_delta_clone_program(
   program, (Allocator)&context.program_allocator
  );
  context.program = owned_program;
  context.owned_program = owned_program;
  context.accounted_program_bytes = context.program_allocator.live_bytes;
  if (context.program_allocator.overflowed
   || !typed_delta_charge(context, (usz)TypedDeltaContext::size)
   || !typed_delta_charge(context, context.accounted_program_bytes)
   || !typed_delta_charge(context, host_entry_bytes))
  {
   if (!context.failed)
   {
    typed_delta_fail(context, "typed Delta retained control size overflow");
   }
  }
 }
 if (!context.failed)
 {
  context.parallel_source_order = typed_delta_entry_source_order(context.program);
  context.stats.phase_one_roots = 1 + context.program.method_roots.len;
 }
 TypedDeltaValue* value = context.failed ? null : typed_delta_evaluate(
  context, context.program.entry, { }, 0
 );
 typed_delta_drive(context, value, &result, escaped);
 typed_delta_pool_stop(&pool, allocator);
 if (!*escaped) alloc::free(allocator, context);
 return result;
}
