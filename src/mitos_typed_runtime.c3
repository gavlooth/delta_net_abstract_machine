module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
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
 mitos::EffectId[] effects;
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
 String string;
 bool owns_string;
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
struct TypedDeltaExecutionResult
{
	Allocator allocator;
	String formatted;
	mitos::TypeId type_id;
	TypedDeltaExecutionStats stats;
	DeltaDiagnostic[] diagnostics;
}
fn bool TypedDeltaExecutionResult.ok(&self) => self.diagnostics.len == 0;
fn void TypedDeltaExecutionResult.deinit(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.formatted);
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

const usz TYPED_DELTA_MAX_NATIVE_DEPTH = 512;
const usz TYPED_DELTA_MAX_VALUES = 1_000_000;
const usz TYPED_DELTA_MAX_ALTERNATIVES = 65_536;
const usz TYPED_DELTA_MAX_ASSIGNMENTS = 1_024;
const usz TYPED_DELTA_MAX_ENVIRONMENTS = 1_000_000;
const usz TYPED_DELTA_MAX_OWNED_BYTES = 64 * 1024 * 1024;

struct TypedDeltaContext
{
 Allocator allocator;
 mitos::DeltaProgram* program;
 List{TypedDeltaValue*} values;
 List{TypedDeltaBinding[]} environments;
 List{TypedDeltaSubstitution*} owned_substitutions;
 TypedDeltaExecutionStats stats;
 usz steps;
 usz owned_bytes;
 usz value_count;
 usz environment_count;
 usz max_owned_bytes;
 usz max_values;
 usz max_environments;
 bool failed;
 DeltaDiagnostic diagnostic;
 uint active_span;
 TypedDeltaHandlerActivation* activation;
 usz parallel_source_order;
 usz current_occurrence_order;
 usz last_committed_root;
 usz last_committed_operation;
 TypedDeltaSubstitution* substitution;
 TypedDeltaPool* pool;
 TypedDeltaHostRegistry* host_handlers;
 bool worker_active;
}

struct TypedDeltaJob
{
 TypedDeltaContext context;
 mitos::DeltaNodeId node;
 TypedDeltaEnvironment environment;
 usz source_order;
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
 ConditionVariable work_available;
 ConditionVariable batch_completed;
 Thread[] threads;
 usz created_threads;
 TypedDeltaBatch* batch;
 bool stopping;
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
fn bool typed_delta_assert_type(
 TypedDeltaContext* context,
 mitos::TypeId actual,
 mitos::TypeId expected
) @private
{
 if (expected == mitos::TYPE_ID_ANY) return true;
 mitos::MitosDiagnostic diagnostic;
 if (mitos::validate_runtime_annotation(
  &context.program.types,
  actual,
  expected,
  &diagnostic,
  typed_delta_active_span(context)
 )) return true;
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
 if (context.owned_bytes > byte_limit
  || bytes > byte_limit - context.owned_bytes
  || context.value_count > value_limit
  || context.environment_count > environment_limit
  || (value && context.value_count >= value_limit)
  || (environment && context.environment_count >= environment_limit))
 {
  typed_delta_fail(context, "typed Delta value/environment resource budget exceeded");
  return false;
 }
 context.owned_bytes += bytes;
 if (value) context.value_count++;
 if (environment) context.environment_count++;
 return true;
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
 String owned = source.copy(context.allocator);
 TypedDeltaValue* value = typed_delta_value(context, {
  .kind = TYPED_VALUE_STRING,
  .type_id = mitos::TYPE_ID_STRING,
  .string = owned,
  .owns_string = true,
 });
 if (!value) alloc::free(context.allocator, owned);
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
	mitos::TypeDescriptor* element_descriptor = mitos::type_descriptor(
		&context.program.types, element_type
	);
	if (!element_descriptor
		|| element_descriptor.kind
			== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_ABSTRACT)
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
	TypedDeltaValue* value = typed_delta_value(context, {
		.kind = TYPED_VALUE_ARRAY,
		.type_id = aggregate_type,
		.elements = elements,
	});
	if (!value) alloc::free(context.allocator, elements);
	return value;
}
fn TypedDeltaBinding[] typed_delta_environment(
 TypedDeltaContext* context,
 TypedDeltaEnvironment base,
 usz additions
) @private
{
 usz count = base.bindings.len + additions;
 usz bytes = count * (usz)TypedDeltaBinding::size
  + (usz)usz::size;
 if (count < base.bindings.len
  || !typed_delta_charge(context, bytes, false, true)) return { };
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
fn mitos::DeltaMethodRoot* typed_delta_method_root(mitos::DeltaProgram* program, usz function_index) @private
{
	foreach (&root : program.method_roots) if (root.function_index == function_index) return root;
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
	if (context.failed) return null;
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
		bool declared = false;
		foreach (effect : function.closure.effects)
		{
			if (effect == result.effect_instance) { declared = true; break; }
		}
		if (!declared)
		{
			typed_delta_fail(context, "effect escaped a lambda's declared effect row");
			return null;
		}
		return result;
	}
	if (!typed_delta_assert_type(
		context, result.type_id, function.closure.result_type
	)) return null;
	return result;
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
 typed_delta_lock_registry(context);
 mitos::DispatchResult dispatch = mitos::dispatch_method(
  &context.program.methods,
  &context.program.types,
  call.name,
  actual,
  context.allocator,
  span
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
	mitos::DeltaMethodRoot* root = typed_delta_method_root(context.program, method.function_index);
	if (!root || root.parameters.len != arity)
	{
		typed_delta_fail(context, "selected method has no consistent Delta body root");
		return null;
	}
	TypedDeltaBinding[] bindings = typed_delta_environment(context, { }, arity + dispatch.bindings.len);
	foreach (index, parameter : root.parameters)
		bindings[index] = { .name = parameter, .value = arguments[index] };
	foreach (index, &binding : dispatch.bindings)
	{
		bindings[arity + (usz)index] = {
			.name = binding.variable,
			.value = typed_delta_type(context, binding.type_id),
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
  bool declared = false;
  foreach (effect : root.effect_row)
  {
   if (effect == selected_value.effect_instance) { declared = true; break; }
  }
  if (!declared)
  {
   typed_delta_fail(context, "effect escaped a method's resolved effect row");
   return null;
  }
  return selected_value;
	}
	mitos::TypeId expected_result;
	if (!mitos::resolve_method_result_type(
		&context.program.types,
		method,
		dispatch.bindings,
		&expected_result
	))
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
  case TYPED_VALUE_STRING: return left.string == right.string;
  case TYPED_VALUE_TYPE: return left.represented_type == right.represented_type;
  case TYPED_VALUE_CONSTRUCTOR:
   if (left.constructor != right.constructor
    || left.type_id != right.type_id
    || left.fields.len != right.fields.len) return false;
   foreach (index, field : left.fields)
    if (!typed_delta_equal(field, right.fields[index], depth + 1)) return false;
   return true;
  case TYPED_VALUE_ARRAY:
   if (left.type_id != right.type_id
    || left.elements.len != right.elements.len) return false;
   foreach (index, element : left.elements)
    if (!typed_delta_equal(element, right.elements[index], depth + 1)) return false;
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
     alternative.value,
     right.alternatives[index].value,
     depth + 1
    )) return false;
   }
   return true;
  default: return false;
 }
}

fn TypedDeltaHostValue typed_delta_host_view(TypedDeltaValue* value) @private
{
 TypedDeltaHostValue view = {
  .type_id = value ? value.type_id : mitos::TYPE_ID_INVALID,
 };
 if (!value) return view;
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
   view.string = value.string;
  case TYPED_VALUE_CONSTRUCTOR:
   view.kind = HOST_VALUE_CONSTRUCTOR;
  case TYPED_VALUE_CLOSURE:
   view.kind = HOST_VALUE_FUNCTION;
  case TYPED_VALUE_TYPE:
   view.kind = HOST_VALUE_TYPE;
   view.represented_type = value.represented_type;
  default: ;
 }
 return view;
}

fn TypedDeltaValue* typed_delta_from_host(
 TypedDeltaContext* context,
 TypedDeltaHostValue value
) @private
{
 switch (value.kind)
 {
  case HOST_VALUE_I64:
   if (value.type_id != mitos::TYPE_ID_I64) break;
   return typed_delta_i64(context, value.integer);
  case HOST_VALUE_BOOL:
   if (value.type_id != mitos::TYPE_ID_BOOL) break;
   return typed_delta_bool(context, value.boolean);
  case HOST_VALUE_UNIT:
   if (value.type_id != mitos::TYPE_ID_UNIT) break;
   return typed_delta_unit(context);
  case HOST_VALUE_STRING:
   if (value.type_id != mitos::TYPE_ID_STRING) break;
   return typed_delta_string(context, value.string);
  case HOST_VALUE_TYPE:
   if (!value.represented_type) break;
   return typed_delta_type(context, value.represented_type);
  default: ;
 }
 typed_delta_fail(context, "external effect helper returned an invalid typed value");
 return null;
}

fn TypedDeltaValue* typed_delta_invoke_external(
 TypedDeltaContext* context,
 TypedDeltaValue* request
) @private
{
 mitos::DeltaOperationDescriptor* operation = typed_delta_operation(
  context, request.effect_operation
 );
 if (!operation || operation.host_kind != DELTA_EFFECT_EXTERNAL)
 {
  typed_delta_fail(context, "escaped effect is not an external host operation");
  return null;
 }
 foreach (argument : request.effect_arguments)
 {
  if (argument.kind == TYPED_VALUE_ARRAY
   || argument.kind == TYPED_VALUE_SUPERPOSITION)
  {
   typed_delta_fail(context, "external effect host helpers do not accept aggregate values");
   return null;
  }
 }
 TypedDeltaHostHandlerEntry* entry = context.host_handlers
  ? context.host_handlers.find(operation.id) : null;
 if (!entry || entry.abi_major != TYPED_DELTA_HOST_ABI_MAJOR
  || entry.abi_minor > TYPED_DELTA_HOST_ABI_MINOR)
 {
  typed_delta_fail(context, "external effect has no compatible registered host handler");
  return null;
 }
 if (request.effect_source_order < context.last_committed_root
  || (request.effect_source_order == context.last_committed_root
   && request.effect_occurrence_order < context.last_committed_operation))
 {
  typed_delta_fail(context, "external effect commit violated source occurrence order");
  return null;
 }
 usz argument_bytes =
  request.effect_arguments.len * (usz)TypedDeltaHostValue::size;
 if (!typed_delta_charge(context, argument_bytes)) return null;
 TypedDeltaHostValue[] arguments = alloc::new_array(
  context.allocator, TypedDeltaHostValue, (sz)request.effect_arguments.len
 );
 defer alloc::free(context.allocator, arguments);
 foreach (index, argument : request.effect_arguments)
  arguments[index] = typed_delta_host_view(argument);
 TypedDeltaHostCall call = {
  .abi_major = TYPED_DELTA_HOST_ABI_MAJOR,
  .abi_minor = TYPED_DELTA_HOST_ABI_MINOR,
  .effect = request.effect_instance,
  .operation = operation.id,
  .source_order = request.effect_source_order,
  .occurrence_order = request.effect_occurrence_order,
  .arguments = arguments,
 };
 if (!entry.handler(&call, entry.context))
 {
  typed_delta_fail(
   context,
   call.diagnostic.len
    ? call.diagnostic : "external effect host handler rejected the operation"
  );
  return null;
 }
 TypedDeltaValue* result = typed_delta_from_host(context, call.result);
 if (!result || !typed_delta_assert_type(
  context, result.type_id, request.effect_result_type
 )) return null;
 context.stats.ordered_effect_commits++;
 context.last_committed_root = request.effect_source_order;
 context.last_committed_operation = request.effect_occurrence_order;
 return result;
}

fn bool typed_delta_console_host(
 TypedDeltaHostCall* call,
 void* ignored
) @private
{
 (void)ignored;
 if (call.arguments.len != 1 || call.arguments[0].kind != HOST_VALUE_STRING)
 {
  call.diagnostic = "Console.print requires one String argument";
  return false;
 }
 io::printn(call.arguments[0].string);
 call.result = { .kind = HOST_VALUE_UNIT, .type_id = mitos::TYPE_ID_UNIT };
 return true;
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
  if (effect.name != "Console") continue;
  foreach (operation_id : effect.operations)
  {
   foreach (&operation : program.effects.operations)
   {
    if (operation.id == operation_id && operation.name == "print"
     && operation.host_kind == DELTA_EFFECT_EXTERNAL)
    {
     registered = self.register_host_handler(
      operation.id, &typed_delta_console_host
     ) && registered;
    }
   }
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
		return typed_delta_bool(context, typed_delta_equal(left, right));
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
	if (!selected.wildcard
		&& selected.bindings.len != scrutinee.fields.len)
	{
		typed_delta_fail(context, "match pattern arity disagrees with constructor layout");
		return null;
	}
	TypedDeltaBinding[] arm_environment = typed_delta_environment(
		context,
		environment,
		selected.wildcard ? 0 : selected.bindings.len
	);
	foreach (index, binding : selected.bindings)
		arm_environment[environment.bindings.len + index] = {
			.name = binding,
			.value = scrutinee.fields[index],
		};
	return typed_delta_evaluate(
		context, selected.body, { .bindings = arm_environment }, depth + 1
	);
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
	if (!request) alloc::free(context.allocator, owned);
	return request;
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

fn bool typed_delta_selection_compatible(
	TypedDeltaSelection[] selections,
	usz selected_count,
	TypedDeltaAssignment[] candidate
) @private
{
	foreach (assignment : candidate)
	{
		foreach (selection : selections[:(sz)selected_count])
		{
			foreach (existing : selection.assignments)
			{
				if (existing.origin == assignment.origin
					&& existing.branch != assignment.branch) return false;
			}
		}
	}
	return true;
}

fn bool typed_delta_collect_assignments(
	TypedDeltaContext* context,
	TypedDeltaSelection[] selections,
	TypedDeltaAssignment[]* result
) @private
{
	usz capacity = 0;
	foreach (selection : selections)
	{
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
	if (!capacity)
	{
		*result = { };
		return true;
	}
	TypedDeltaAssignment[] merged = alloc::new_array(
		context.allocator, TypedDeltaAssignment, (sz)capacity
	);
	usz count = 0;
	foreach (selection : selections)
	{
		foreach (assignment : selection.assignments)
		{
			usz insertion = 0;
			while (insertion < count
				&& merged[insertion].origin < assignment.origin) insertion++;
			if (insertion < count
				&& merged[insertion].origin == assignment.origin)
			{
				if (merged[insertion].branch != assignment.branch)
				{
					alloc::free(context.allocator, merged);
					return false;
				}
				continue;
			}
			for (usz move = count; move > insertion; move--)
			{
				merged[move] = merged[move - 1];
			}
			merged[insertion] = assignment;
			count++;
		}
	}
	usz bytes = count * (usz)TypedDeltaAssignment::size;
	if (!typed_delta_charge(context, bytes))
	{
		alloc::free(context.allocator, merged);
		return false;
	}
	*result = alloc::clone_slice(context.allocator, merged[:(sz)count]);
	alloc::free(context.allocator, merged);
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
				if (context.steps++ >= mitos::DELTA_MAX_EVALUATION_STEPS)
				{
					typed_delta_fail(
						context,
						"superposition Cartesian lifting exceeded its evaluation-step bound"
					);
					return false;
				}
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
	if (operation.ordered)
	{
  if (request.effect_source_order < context.last_committed_root
   || (request.effect_source_order == context.last_committed_root
    && request.effect_occurrence_order < context.last_committed_operation))
  {
   typed_delta_fail(context, "ordered effect commit violated source occurrence order");
   context.activation = activation.parent;
   return null;
  }
  context.last_committed_root = request.effect_source_order;
  context.last_committed_operation = request.effect_occurrence_order;
		context.stats.ordered_effect_commits++;
	}
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
	TypedDeltaValue* handled = typed_delta_evaluate(context, node.inputs[0], environment, depth + 1);
	if (context.failed) return null;
	if (typed_delta_is_effect(handled))
	{
		return typed_delta_handle_request(context, node, environment, handled, depth + 1);
	}
	if (node.descriptor >= context.program.effects.handlers.len)
	{
		typed_delta_fail(context, "handler boundary has invalid Delta metadata");
		return null;
	}
	TypedDeltaHandlerActivation activation = {
		.handler_index = node.descriptor,
		.handler = &context.program.effects.handlers[node.descriptor],
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

fn void typed_delta_context_init(
 TypedDeltaContext* context,
 mitos::DeltaProgram* program,
 Allocator allocator,
 TypedDeltaPool* pool,
 TypedDeltaHostRegistry* host_handlers,
 bool worker_active = false
) @private
{
 *context = {
  .allocator = allocator,
  .program = program,
  .pool = pool,
  .host_handlers = host_handlers,
  .worker_active = worker_active,
  .max_owned_bytes = TYPED_DELTA_MAX_OWNED_BYTES,
  .max_values = TYPED_DELTA_MAX_VALUES,
  .max_environments = TYPED_DELTA_MAX_ENVIRONMENTS,
 };
 context.values.init(allocator);
 context.environments.init(allocator);
 context.owned_substitutions.init(allocator);
 context.stats.effect_epoch = program.effects.epoch;
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
 if (catch pool.work_available.init())
 {
  pool.mutex.destroy();
  diagnostic.init(allocator, "failed to initialize typed Delta worker-pool condition");
  return false;
 }
 if (catch pool.batch_completed.init())
 {
  pool.work_available.destroy();
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
 foreach (substitution : child.owned_substitutions)
  parent.owned_substitutions.push(substitution);
 child.owned_substitutions.free();
 parent.owned_bytes += child.owned_bytes;
 parent.value_count += child.value_count;
 parent.environment_count += child.environment_count;
 parent.steps += child.steps;
 typed_delta_add_stats(&parent.stats, child.stats);
}

fn bool typed_delta_evaluate_parallel(
 TypedDeltaContext* context,
 mitos::DeltaNodeId[] nodes,
 TypedDeltaEnvironment environment,
 TypedDeltaValue*[] values
) @private
{
 if (!nodes.len) return true;
 if (!context.pool || !context.pool.threads.len || context.worker_active
  || context.activation)
 {
  foreach (index, node : nodes)
  {
   usz previous_order = context.parallel_source_order;
   context.parallel_source_order = (usz)index;
   values[index] = typed_delta_evaluate(context, node, environment, 1);
   context.parallel_source_order = previous_order;
   if (context.failed || typed_delta_is_effect(values[index])) return false;
  }
  return true;
 }
 usz job_bytes = nodes.len * (usz)TypedDeltaJob::size;
 if (!typed_delta_charge(context, job_bytes)) return false;
 TypedDeltaJob[] jobs = alloc::new_array(
  context.allocator, TypedDeltaJob, (sz)nodes.len
 );
 usz remaining_bytes = context.max_owned_bytes - context.owned_bytes;
 usz remaining_values = context.max_values - context.value_count;
 usz remaining_environments =
  context.max_environments - context.environment_count;
 usz job_count = (usz)nodes.len;
 foreach (index, node : nodes)
 {
  TypedDeltaContext* child = &jobs[index].context;
  typed_delta_context_init(
   child,
   context.program,
   context.allocator,
   context.pool,
   context.host_handlers,
   true
  );
  usz byte_quota = remaining_bytes / job_count;
  usz value_quota = remaining_values / job_count;
  usz environment_quota = remaining_environments / job_count;
  child.max_owned_bytes = byte_quota ? byte_quota : 1;
  child.max_values = value_quota ? value_quota : 1;
  child.max_environments = environment_quota ? environment_quota : 1;
  child.substitution = context.substitution;
  jobs[index].node = node;
  jobs[index].environment = environment;
  jobs[index].source_order = (usz)index;
 }
 TypedDeltaBatch batch = { .jobs = jobs };
 TypedDeltaPool* pool = context.pool;
 pool.mutex.lock();
 if (pool.batch)
 {
  pool.mutex.unlock();
  typed_delta_fail(context, "nested typed Delta worker-pool submission is forbidden");
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

 bool ok = true;
 foreach (index, &job : jobs)
 {
  typed_delta_adopt_child(context, &job.context);
  values[index] = job.value;
  if (job.context.failed)
  {
   if (!context.failed)
   {
    context.failed = true;
    context.diagnostic = job.context.diagnostic;
    job.context.diagnostic = { };
   }
   else
   {
    job.context.diagnostic.deinit();
   }
   ok = false;
  }
  else if (typed_delta_is_effect(job.value))
  {
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
 if (depth >= TYPED_DELTA_MAX_NATIVE_DEPTH
  || context.steps++ >= mitos::DELTA_MAX_EVALUATION_STEPS)
 {
  typed_delta_fail(context, "typed Delta evaluation resource limit exceeded");
  return null;
 }
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
			if (context.failed) return null;
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
					.effects = node.effect_row,
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
				context, (node.inputs.len - 1) * (usz)usz::size
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
			let_environment[environment.bindings.len] = { .name = node.names[0], .value = bound };
			return typed_delta_evaluate(context, node.inputs[1], { .bindings = let_environment }, depth + 1);
		case DELTA_CONSTRUCTOR:
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
				context, node.inputs, environment, dispatch_inputs
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
				context, node.inputs[:(sz)binding_count], environment, values
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
			if (context.failed) return null;
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

fn void typed_delta_append_string(DString* output, String value) @private
{
 output.append_char('"');
 foreach (character : value)
 {
  switch (character)
  {
   case '"': output.append_string("\\\"");
   case '\\': output.append_string("\\\\");
   case '\n': output.append_string("\\n");
   case '\r': output.append_string("\\r");
   case '\t': output.append_string("\\t");
   default: output.append_char(character);
  }
 }
 output.append_char('"');
}

fn void typed_delta_append_value(
	TypedDeltaContext* context,
	DString* output,
	TypedDeltaValue* value,
	usz depth
) @private
{
	if (context.failed) return;
	if (!value || depth >= DELTA_FORMAT_MAX_DEPTH || output.str_view().len >= DELTA_FORMAT_MAX_BYTES)
	{ typed_delta_fail(context, "typed Delta value exceeds formatting limits"); return; }
	switch (value.kind)
	{
		case TYPED_VALUE_I64:
			char[32] buffer;
			output.append_string((String)io::bprintf(&buffer, "%d", value.integer)!!);
		case TYPED_VALUE_BOOL: output.append_string(value.boolean ? "True" : "False");
		case TYPED_VALUE_UNIT: output.append_string("()");
		case TYPED_VALUE_STRING: typed_delta_append_string(output, value.string);
		case TYPED_VALUE_TYPE:
			String type_name = mitos::format_type(
				&context.program.types, value.type_id, context.allocator
			);
			output.append_string(type_name);
			alloc::free(context.allocator, type_name);
		case TYPED_VALUE_CLOSURE: output.append_string("<lambda>");
		case TYPED_VALUE_CONSTRUCTOR:
			if (value.constructor >= context.program.constructors.len) { typed_delta_fail(context, "constructor value has an invalid descriptor"); return; }
			output.append_string(context.program.constructors[value.constructor].name);
			if (value.fields.len)
			{
				output.append_string("(");
				foreach (index, field : value.fields)
				{ if (index) output.append_string(", "); typed_delta_append_value(context, output, field, depth + 1); }
				output.append_string(")");
			}
		case TYPED_VALUE_ARRAY:
			output.append_string("[");
			foreach (index, element : value.elements)
			{
				if (index) output.append_string(", ");
				typed_delta_append_value(context, output, element, depth + 1);
			}
			output.append_string("]");
		case TYPED_VALUE_SUPERPOSITION:
			output.append_string("superpose(");
			foreach (index, &alternative : value.alternatives)
			{
				if (index) output.append_string(", ");
				typed_delta_append_value(
					context, output, alternative.value, depth + 1
				);
			}
			output.append_string(")");
		case TYPED_VALUE_EFFECT_REQUEST:
			typed_delta_fail(context, "unhandled effect reached typed Delta formatting");
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
		usz byte_limit = context.max_owned_bytes
			? context.max_owned_bytes : TYPED_DELTA_MAX_OWNED_BYTES;
		if (context.owned_bytes > byte_limit
			|| value.alternatives.len > (
				byte_limit - context.owned_bytes
			) / (usz)long::size)
		{
			typed_delta_fail(
				context,
				"superposition reification exceeds its resource bound"
			);
			return false;
		}
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
		: value.kind == TYPED_VALUE_ARRAY ? value.elements.len : 0;
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
	if (value.kind == TYPED_VALUE_STRING)
	{
		node.agent.practical.text = value.string.copy(mem);
		node.agent.practical.owns_text = true;
	}
	(void)connect(net, destination, node.agent.practical.principal);
	if (value.kind == TYPED_VALUE_CONSTRUCTOR)
	{
		foreach (index, field : value.fields)
			if (!typed_delta_reify_value(
				context, net, field,
				node.agent.practical.auxiliaries[index], depth + 1
			)) return false;
	}
	if (value.kind == TYPED_VALUE_ARRAY)
	{
		foreach (index, element : value.elements)
			if (!typed_delta_reify_value(
				context, net, element,
				node.agent.practical.auxiliaries[index], depth + 1
			)) return false;
	}
	return true;
}
fn void typed_delta_context_free(TypedDeltaContext* context) @private
{
	foreach (environment : context.environments) alloc::free(context.allocator, environment);
	context.environments.free();
	foreach (value : context.values)
	{
		if (value.owns_string) alloc::free(context.allocator, value.string);
		alloc::free(context.allocator, value.fields);
		alloc::free(context.allocator, value.elements);
		foreach (&alternative : value.alternatives)
			alloc::free(context.allocator, alternative.assignments);
		alloc::free(context.allocator, value.alternatives);
		alloc::free(context.allocator, value.effect_arguments);
		alloc::free(context.allocator, value);
	}
	context.values.free();
	foreach (substitution : context.owned_substitutions)
		alloc::free(context.allocator, substitution);
	context.owned_substitutions.free();
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

/** Execute the immutable image in two explicit Delta phases. */
fn TypedDeltaExecutionResult run_typed_delta_program(
 mitos::DeltaProgram* program,
 int max_workers,
 TypedDeltaHostRegistry* host_handlers,
 Allocator allocator = mem
)
{
 TypedDeltaExecutionResult result = { .allocator = allocator };
 if (!program || program.format_version != mitos::DELTA_PROGRAM_FORMAT_VERSION
  || !program.entry)
 {
  result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
  result.diagnostics[0].init(
   allocator, "typed runtime requires a complete DeltaProgram entry image"
  );
  return result;
 }
 if (program.helper_abi.major != mitos::DELTA_HELPER_ABI_MAJOR
  || program.helper_abi.minor != mitos::DELTA_HELPER_ABI_MINOR
  || program.helper_abi.feature_bits != (ulong)0x1f
  || program.helper_abi.effect_tag != (uint)AgentType.EFFECT_AGENT
  || program.helper_abi.handler_tag != (uint)AgentType.HANDLER_AGENT
  || program.helper_abi.resume_tag != (uint)AgentType.RESUME_AGENT
  || program.helper_abi.abort_tag != (uint)AgentType.ABORT_AGENT)
 {
  result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
  result.diagnostics[0].init(
   allocator, "DeltaProgram helper ABI lacks the required typed superposition contract"
  );
  return result;
 }
 foreach (&operation : program.effects.operations)
 {
  if (operation.host_kind != DELTA_EFFECT_EXTERNAL) continue;
  TypedDeltaHostHandlerEntry* entry = host_handlers
   ? host_handlers.find(operation.id) : null;
  if (!entry || entry.abi_major != TYPED_DELTA_HOST_ABI_MAJOR
   || entry.abi_minor > TYPED_DELTA_HOST_ABI_MINOR)
  {
   mitos::MitosSpan span = { };
   if (operation.span && operation.span <= program.spans.len)
   {
    span = program.spans[operation.span - 1];
   }
   result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
   result.diagnostics[0].init(
    allocator,
    "external effect has no compatible registered host handler",
    span
   );
   return result;
  }
 }
 DeltaDiagnostic materialization_error;
 if (!typed_delta_materialize_root(
  program, program.entry, allocator, &materialization_error
 ))
 {
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
   result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
   result.diagnostics[0] = materialization_error;
   return result;
  }
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
  result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
  result.diagnostics[0] = pool_error;
  return result;
 }
 defer typed_delta_pool_stop(&pool, allocator);
 TypedDeltaPool* active_pool = pool.threads.len ? &pool : null;
 TypedDeltaContext context;
 typed_delta_context_init(
  &context, program, allocator, active_pool, host_handlers
 );
 context.stats.phase_one_roots = 1 + program.method_roots.len;
 TypedDeltaValue* value = typed_delta_evaluate(
  &context, program.entry, { }, 0
 );
 while (!context.failed && typed_delta_is_effect(value))
 {
  mitos::DeltaOperationDescriptor* operation = typed_delta_operation(
   &context, value.effect_operation
  );
  mitos::DeltaNode* occurrence = mitos::delta_node(
   program, value.effect_node
  );
  if (occurrence) context.active_span = occurrence.span;
  if (!operation || operation.host_kind != DELTA_EFFECT_EXTERNAL)
  {
   typed_delta_fail(
    &context,
    operation
     ? "unhandled effect operation escaped every lexical handler"
     : "unhandled effect has invalid operation metadata"
   );
   break;
  }
  TypedDeltaValue* host_result = typed_delta_invoke_external(
   &context, value
  );
  if (context.failed) break;
  if (!typed_delta_charge(
   &context, (usz)TypedDeltaSubstitution::size
  )) break;
  TypedDeltaSubstitution* substitution = alloc::new(
   allocator,
   TypedDeltaSubstitution,
   {
    .parent = context.substitution,
    .hole = value.effect_node,
    .value = host_result,
    .source_order = value.effect_source_order,
    .occurrence_order = value.effect_occurrence_order,
   }
  );
  context.current_occurrence_order = 0;
  context.parallel_source_order = 0;
  context.owned_substitutions.push(substitution);
  context.substitution = substitution;
  value = typed_delta_evaluate(&context, program.entry, { }, 0);
 }
 if (!context.failed)
 {
  Net result_net;
  result_net.init();
  NetRef root = new_interface(&result_net, ROOT, "");
  if (typed_delta_reify_value(
   &context,
   &result_net,
   value,
   result_net.interfaces.get_ref(root).port,
   0
  ) && validate_net(&result_net))
  {
   DeltaPracticalReadbackResult reified = readback_practical_root(
    &result_net, root, allocator
   );
   if (!reified.ok())
   {
    typed_delta_fail(&context, reified.diagnostics[0].message);
   }
   else
   {
    context.stats.phase_two_reifications++;
   }
   reified.deinit();
  }
  else if (!context.failed)
  {
   typed_delta_fail(
    &context, "phase-two practical value failed stable-slot validation"
   );
  }
  result_net.free();
 }
 if (!context.failed)
 {
  DString formatted;
  formatted.init(allocator);
  typed_delta_append_value(&context, &formatted, value, 0);
  if (!context.failed) result.formatted = formatted.copy_str(allocator);
  formatted.free();
 }
 result.stats = context.stats;
 result.type_id = value ? value.type_id : mitos::TYPE_ID_INVALID;
 if (context.failed)
 {
  result.diagnostics = alloc::new_array(allocator, DeltaDiagnostic, 1);
  result.diagnostics[0] = context.diagnostic;
  context.diagnostic = { };
 }
 typed_delta_context_free(&context);
 return result;
}
