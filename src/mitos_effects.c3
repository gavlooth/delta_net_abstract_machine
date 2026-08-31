module delta_net_abstract_machine::mitos;

import std::collections::list;
import std::core::mem;

/** Stable identities are local to one program-lifetime EffectRegistry. */
typedef EffectId = uint;
typedef OperationId = uint;

const EffectId EFFECT_ID_INVALID = (EffectId)0;
const OperationId OPERATION_ID_INVALID = (OperationId)0;
const usz MITOS_MAX_EFFECTS = 4_096;
const usz MITOS_MAX_EFFECT_INSTANCES = 16_384;
const usz MITOS_MAX_EFFECT_INFERENCE_STEPS = 4_194_304;
enum EffectHostPolicy : char
{
	EFFECT_HOST_PURE,
	EFFECT_HOST_ORDERED,
	EFFECT_HOST_EXTERNAL,
}


struct EffectOperationDescriptor
{
	OperationId id;
	EffectId effect;
	String name;
	String[] parameter_patterns;
	TypePattern[] parameter_types;
	String result_pattern;
	TypePattern result_type;
	EffectHostPolicy host_policy;
	bool ordered;
}

struct EffectDescriptor
{
	EffectId id;
	String name;
	bool multi;
	String[] parameters;
	EffectOperationDescriptor[] operations;
	MitosSpan span;
}

struct EffectInstance
{
	EffectId id;
	EffectId constructor;
	TypeId[] arguments;
}

struct EffectRegistry
{
	Allocator allocator;
	List{EffectDescriptor} effects;
	List{EffectInstance} instances;
	OperationId next_operation_id;
	usz max_effects;
	usz max_instances;
	ulong epoch;
}

struct EffectRegistryBuildResult
{
	Allocator allocator;
	EffectRegistry registry;
	MitosDiagnostic[] diagnostics;
}

struct MethodEffectInfo
{
	usz function_index;
	EffectId[] inferred;
	EffectId[] asserted;
	bool has_assertion;
}


struct LambdaEffectInfo
{
	MitosSpan span;
	EffectId[] inferred;
	EffectId[] asserted;
	bool has_assertion;
}
struct EffectAnalysis
{
	Allocator allocator;
	MethodEffectInfo[] methods;
	LambdaEffectInfo[] lambdas;
	MitosDiagnostic[] diagnostics;
	usz inference_steps;
	ulong effect_epoch;
}

struct EffectInvalidation
{
	ulong previous_epoch;
	ulong current_epoch;
	EffectId changed_effect;
}

fn bool EffectRegistryBuildResult.ok(&self) => self.diagnostics.len == 0;
fn bool EffectAnalysis.ok(&self) => self.diagnostics.len == 0;

fn void EffectOperationDescriptor.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.name);
	foreach (pattern : self.parameter_patterns) alloc::free(allocator, pattern);
	alloc::free(allocator, self.parameter_patterns);
	foreach (&pattern : self.parameter_types) pattern.deinit(allocator);
	alloc::free(allocator, self.parameter_types);
	self.result_type.deinit(allocator);
	alloc::free(allocator, self.result_pattern);
	*self = { };
}

fn void EffectRegistry.deinit(&self)
{
	if (!self.allocator) return;
	foreach (&effect : self.effects)
	{
		alloc::free(self.allocator, effect.name);
		foreach (parameter : effect.parameters) alloc::free(self.allocator, parameter);
		alloc::free(self.allocator, effect.parameters);
		foreach (&operation : effect.operations) operation.deinit(self.allocator);
		alloc::free(self.allocator, effect.operations);
	}
	foreach (&instance : self.instances) alloc::free(self.allocator, instance.arguments);
	self.effects.free();
	self.instances.free();
	*self = { };
}

fn void EffectRegistryBuildResult.deinit(&self)
{
	if (!self.allocator) return;
	self.registry.deinit();
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

fn void EffectAnalysis.deinit(&self)
{
	if (!self.allocator) return;
	foreach (&method : self.methods)
	{
		alloc::free(self.allocator, method.inferred);
		alloc::free(self.allocator, method.asserted);
	}
	alloc::free(self.allocator, self.methods);
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	foreach (&lambda : self.lambdas)
	{
		alloc::free(self.allocator, lambda.inferred);
		alloc::free(self.allocator, lambda.asserted);
	}
	alloc::free(self.allocator, self.lambdas);
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

fn void effects_add_diagnostic(
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	String message,
	MitosSpan span
) @private
{
	foreach (&existing : *diagnostics)
	{
		if (existing.message == message && existing.span.start.offset == span.start.offset
			&& existing.span.end.offset == span.end.offset)
		{
			return;
		}
	}
	MitosDiagnostic diagnostic;
	diagnostic.init(allocator, message, span);
	diagnostics.push(diagnostic);
}

fn EffectDescriptor* effect_descriptor(EffectRegistry* registry, EffectId id)
{
	if (!registry || !id || (usz)id > (usz)registry.effects.len()) return null;
	return &registry.effects[(usz)id - 1];
}

fn EffectId find_effect(EffectRegistry* registry, String name)
{
	if (!registry) return EFFECT_ID_INVALID;
	foreach (&effect : registry.effects) if (effect.name == name) return effect.id;
	return EFFECT_ID_INVALID;
}

fn EffectOperationDescriptor* find_effect_operation(
	EffectRegistry* registry,
	EffectId effect,
	String operation
)
{
	EffectDescriptor* descriptor = effect_descriptor(registry, effect);
	if (!descriptor) return null;
	foreach (&candidate : descriptor.operations) if (candidate.name == operation) return candidate;
	return null;
}

fn EffectHostPolicy effect_host_policy(String effect_name)
{
	if (effect_name == "Console" || effect_name == "IO") return EFFECT_HOST_EXTERNAL;
	if (effect_name == "State") return EFFECT_HOST_ORDERED;
	return EFFECT_HOST_PURE;
}

fn EffectRegistryBuildResult build_effect_registry(
	Program* program,
	TypeRegistry* types,
	Allocator allocator = mem,
	usz max_effects = MITOS_MAX_EFFECTS,
	usz max_instances = MITOS_MAX_EFFECT_INSTANCES
)
{
	EffectRegistryBuildResult result = { .allocator = allocator };
	result.registry = {
		.allocator = allocator,
		.max_effects = max_effects,
		.max_instances = max_instances,
		.next_operation_id = (OperationId)1,
		.epoch = 1,
	};
	result.registry.effects.init(allocator);
	result.registry.instances.init(allocator);
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);
	foreach (&declaration : program.effects)
	{
		if ((usz)result.registry.effects.len() >= max_effects)
		{
			effects_add_diagnostic(&diagnostics, allocator, "effect registry exhausted its bounded capacity", declaration.span);
			break;
		}
		if (find_effect(&result.registry, declaration.name))
		{
			effects_add_diagnostic(&diagnostics, allocator, "duplicate effect declaration", declaration.span);
			continue;
		}
		EffectDescriptor descriptor = {
			.id = (EffectId)((usz)result.registry.effects.len() + 1),
			.name = declaration.name.copy(allocator),
			.multi = declaration.multi,
			.span = declaration.span,
		};
		descriptor.parameters = alloc::new_array(allocator, String, declaration.parameters.len);
		foreach (index, &parameter : declaration.parameters)
			descriptor.parameters[index] = parameter.name.copy(allocator);
		List{EffectOperationDescriptor} operations;
		operations.init(allocator);
		foreach (&operation : declaration.operations)
		{
			bool duplicate = false;
			foreach (&existing : operations) if (existing.name == operation.name) duplicate = true;
			if (duplicate)
			{
				effects_add_diagnostic(&diagnostics, allocator, "duplicate effect operation", operation.span);
				continue;
			}
			EffectOperationDescriptor registered = {
				.id = result.registry.next_operation_id++,
				.effect = descriptor.id,
				.name = operation.name.copy(allocator),
				.host_policy = effect_host_policy(declaration.name),
				.ordered = effect_host_policy(declaration.name) != EFFECT_HOST_PURE,
			};
			registered.parameter_patterns = alloc::new_array(allocator, String, operation.parameters.len);
			registered.parameter_types = alloc::new_array(allocator, TypePattern, operation.parameters.len);
			foreach (index, parameter : operation.parameters)
			{
				TypeExpr* annotation = index < operation.parameter_annotations.len
					? operation.parameter_annotations[index].value : null;
				registered.parameter_patterns[index] = annotation
					? format_type_expr(annotation, allocator) : "Any".copy(allocator);
				MitosDiagnostic diagnostic;
				if (!build_type_pattern(
					types, annotation, declaration.parameters,
					&registered.parameter_types[index], &diagnostic, allocator
				))
				{
					diagnostics.push(diagnostic);
				}
			}
			registered.result_pattern = operation.result.value
				? format_type_expr(operation.result.value, allocator) : "Any".copy(allocator);
			MitosDiagnostic result_diagnostic;
			if (!build_type_pattern(
				types, operation.result.value, declaration.parameters,
				&registered.result_type, &result_diagnostic, allocator
			))
			{
				diagnostics.push(result_diagnostic);
			}
			operations.push(registered);
		}
		descriptor.operations = operations.to_array(allocator);
		operations.free();
		result.registry.effects.push(descriptor);
	}
	result.diagnostics = diagnostics.to_array(allocator);
	diagnostics.free();
	return result;
}

fn bool effect_arguments_equal(TypeId[] left, TypeId[] right) @private
{
	if (left.len != right.len) return false;
	foreach (index, value : left) if (value != right[index]) return false;
	return true;
}

fn bool intern_effect(
	EffectRegistry* registry,
	EffectId constructor,
	TypeId[] arguments,
	EffectId* result,
	MitosDiagnostic* diagnostic = null,
	MitosSpan span = { }
)
{
	EffectDescriptor* descriptor = effect_descriptor(registry, constructor);
	if (!descriptor)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "invalid effect constructor", span);
		return false;
	}
	if (descriptor.parameters.len != arguments.len)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "effect application arity does not match its declaration", span);
		return false;
	}
	foreach (&instance : registry.instances)
	{
		if (instance.constructor == constructor && effect_arguments_equal(instance.arguments, arguments))
		{
			*result = instance.id;
			return true;
		}
	}
	if ((usz)registry.instances.len() >= registry.max_instances)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "effect instance registry exhausted its bounded capacity", span);
		return false;
	}
	EffectId id = (EffectId)(registry.max_effects + (usz)registry.instances.len() + 1);
	registry.instances.push({ .id = id, .constructor = constructor,
		.arguments = alloc::clone_slice(registry.allocator, arguments) });
	registry.epoch++;
	*result = id;
	return true;
}

fn EffectInstance* effect_instance(EffectRegistry* registry, EffectId id)
{
	foreach (&instance : registry.instances) if (instance.id == id) return instance;
	return null;
}

fn EffectId effect_constructor_id(EffectRegistry* registry, EffectId id)
{
	if (effect_descriptor(registry, id)) return id;
	EffectInstance* instance = effect_instance(registry, id);

	return instance ? instance.constructor : EFFECT_ID_INVALID;
}

fn bool resolve_effect_instance(
	EffectRegistry* registry,
	EffectId constructor,
	EffectId[] candidates,
	EffectId* result,
	MitosDiagnostic* diagnostic = null,
	MitosSpan span = { }
)
{
	EffectDescriptor* descriptor = effect_descriptor(registry, constructor);
	if (!descriptor)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "invalid effect constructor", span);
		return false;
	}
	if (!descriptor.parameters.len) { *result = constructor; return true; }
	EffectId selected = EFFECT_ID_INVALID;
	foreach (candidate : candidates)
	{
		if (effect_constructor_id(registry, candidate) != constructor || candidate == constructor) continue;
		if (selected && selected != candidate)
		{
			if (diagnostic) diagnostic.init(registry.allocator, "effect occurrence is ambiguous between concrete instances", span);
			return false;
		}
		selected = candidate;
	}
	if (!selected)
	{
		foreach (&instance : registry.instances)
		{
			if (instance.constructor != constructor) continue;
			if (selected && selected != instance.id)
			{
				if (diagnostic) diagnostic.init(registry.allocator, "effect occurrence requires an explicit concrete effect row", span);
				return false;
			}
			selected = instance.id;
		}
	}
	if (!selected)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "parametric effect occurrence has no concrete effect instance", span);
		return false;
	}
	*result = selected;
	return true;
}

fn bool resolve_effect_operation_types(
	EffectRegistry* registry,
	TypeRegistry* types,
	EffectOperationDescriptor* operation,
	EffectId concrete_effect,
	TypeId[] parameter_types,
	TypeId* result_type,
	MitosDiagnostic* diagnostic = null,
	MitosSpan span = { }
)
{
	EffectDescriptor* descriptor = effect_descriptor(registry, operation.effect);
	if (!descriptor || parameter_types.len != operation.parameter_types.len)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "effect operation type metadata is inconsistent", span);
		return false;
	}
	EffectInstance* instance = effect_instance(registry, concrete_effect);
	if (descriptor.parameters.len && (!instance || instance.constructor != operation.effect
		|| instance.arguments.len != descriptor.parameters.len))
	{
		if (diagnostic) diagnostic.init(registry.allocator, "effect operation requires a concrete effect instance", span);
		return false;
	}
	TypePatternBinding[] bindings = alloc::new_array(registry.allocator, TypePatternBinding, descriptor.parameters.len);
	defer alloc::free(registry.allocator, bindings);
	foreach (index, parameter : descriptor.parameters)
	{
		bindings[index] = {
			.variable = parameter,
			.type_id = instance ? instance.arguments[index] : TYPE_ID_INVALID,
		};
	}
	foreach (index, &pattern : operation.parameter_types)
	{
		if (!instantiate_type_pattern(types, pattern, bindings, &parameter_types[index], diagnostic, span)) return false;
	}
	return instantiate_type_pattern(types, &operation.result_type, bindings, result_type, diagnostic, span);
}
fn bool effect_type_variable(TypeExpr* expression) @private
{
	return expression && expression.kind == TYPE_EXPR_NAMED && expression.name.len == 1
		&& expression.name[0] >= 'A' && expression.name[0] <= 'Z';
}

fn bool resolve_effect_expr(
	EffectRegistry* registry,
	TypeRegistry* types,
	TypeExpr* expression,
	EffectId* result,
	MitosDiagnostic* diagnostic = null
)
{
	if (!expression)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "missing effect expression", { });
		return false;
	}
	EffectId constructor = find_effect(registry, expression.name);
	EffectDescriptor* descriptor = effect_descriptor(registry, constructor);
	if (!descriptor)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "unknown effect in finite effect row", expression.span);
		return false;
	}
	if (expression.kind == TYPE_EXPR_NAMED)
	{
		if (descriptor.parameters.len)
		{
			if (diagnostic) diagnostic.init(registry.allocator, "parametric effect requires its declared 'of' arguments", expression.span);
			return false;
		}
		*result = constructor;
		return true;
	}
	if (descriptor.parameters.len != expression.arguments.len)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "effect application has the wrong arity", expression.span);
		return false;
	}
	TypeId[] arguments = alloc::new_array(registry.allocator, TypeId, expression.arguments.len);
	defer alloc::free(registry.allocator, arguments);
	bool symbolic = false;
	foreach (index, &argument : expression.arguments)
	{
		if (effect_type_variable(argument.value) && !find_type(types, argument.value.name))
		{
			symbolic = true;
			arguments[index] = TYPE_ID_ANY;
			continue;
		}
		if (!resolve_type_expr(types, argument.value, &arguments[index], diagnostic)) return false;
	}
	if (symbolic)
	{
		*result = constructor;
		return true;
	}
	return intern_effect(registry, constructor, arguments, result, diagnostic, expression.span);
}

fn bool row_contains(List{EffectId}* row, EffectId effect) @private
{
	foreach (existing : *row) if (existing == effect) return true;
	return false;
}

fn bool row_add(List{EffectId}* row, EffectId effect) @private
{
	if (!effect || row_contains(row, effect)) return false;
	row.push(effect);
	return true;
}

fn void row_remove_constructor(EffectRegistry* registry, List{EffectId}* row, EffectId constructor) @private
{
	for (sz index = row.len() - 1; index >= 0; index--)
	{
		if (effect_constructor_id(registry, (*row)[(usz)index]) != constructor) continue;
		for (usz next = (usz)index + 1; next < (usz)row.len(); next++) (*row)[(sz)(next - 1)] = (*row)[(sz)next];
		(void)row.pop()!!;
	}
}

struct EffectCallGroup
{
	String name;
	usz arity;
	List{usz} targets;
}

struct EffectCallIndex
{
	Allocator allocator;
	List{EffectCallGroup} groups;
	sz[] buckets;
}

struct EffectInferenceWork
{
	usz used;
	usz max;
	bool exhausted;
}

fn ulong effect_call_hash(String name, usz arity) @private
{
	ulong hash = 1469598103934665603UL ^ (ulong)arity;
	foreach (byte : name)
	{
		hash ^= (ulong)byte;
		hash *= 1099511628211UL;
	}
	return hash;
}

fn usz effect_index_capacity(usz count) @private
{
	usz capacity = 8;
	while (capacity < count * 2) capacity *= 2;
	return capacity;
}

fn EffectCallGroup* effect_call_group(EffectCallIndex* index, String name, usz arity) @private
{
	if (!index.buckets.len) return null;
	usz mask = index.buckets.len - 1;
	usz slot = (usz)effect_call_hash(name, arity) & mask;
	for (usz probe = 0; probe < index.buckets.len; probe++)
	{
		sz group_index = index.buckets[slot];
		if (group_index < 0) return null;
		EffectCallGroup* group = &index.groups[group_index];
		if (group.name == name && group.arity == arity) return group;
		slot = (slot + 1) & mask;
	}
	return null;
}

fn void EffectCallIndex.deinit(&self)
{
	foreach (&group : self.groups) group.targets.free();
	self.groups.free();
	alloc::free(self.allocator, self.buckets);
	*self = { };
}

fn EffectCallIndex build_effect_call_index(Program* program, Allocator allocator) @private
{
	EffectCallIndex index = { .allocator = allocator };
	index.groups.init(allocator);
	index.buckets = alloc::new_array(allocator, sz, (sz)effect_index_capacity(program.functions.len));
	foreach (&bucket : index.buckets) *bucket = -1;
	usz mask = index.buckets.len - 1;
	foreach (function_index, &function : program.functions)
	{
		usz slot = (usz)effect_call_hash(function.name, function.parameters.len) & mask;
		for (usz probe = 0; probe < index.buckets.len; probe++)
		{
			sz group_index = index.buckets[slot];
			if (group_index < 0)
			{
				EffectCallGroup group = { .name = function.name, .arity = function.parameters.len };
				group.targets.init(allocator);
				group.targets.push((usz)function_index);
				index.groups.push(group);
				index.buckets[slot] = index.groups.len() - 1;
				break;
			}
			EffectCallGroup* group = &index.groups[group_index];
			if (group.name == function.name && group.arity == function.parameters.len)
			{
				group.targets.push((usz)function_index);
				break;
			}
			slot = (slot + 1) & mask;
		}
	}
	return index;
}

fn bool effect_charge(EffectInferenceWork* work, usz amount = 1) @private
{
	if (work.exhausted || work.used > work.max || amount > work.max - work.used)
	{
		work.exhausted = true;
		return false;
	}
	work.used += amount;
	return true;
}

fn bool inferred_row_add(
	List{EffectId}* row,
	EffectId effect,
	EffectInferenceWork* work
) @private
{
	if (!effect_charge(work, (usz)row.len() + 1)) return false;
	return row_add(row, effect);
}

fn void collect_expression_effects(
	EffectRegistry* registry,
	EffectCallIndex* calls,
	SurfaceExpr* expression,
	List{EffectId}* row,
	List{EffectId}[] current_rows,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	EffectInferenceWork* work,
	usz depth
) @private
{
	if (!expression || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH || !effect_charge(work)) return;
	switch (expression.kind)
	{
		case SURFACE_VARIABLE:
		case SURFACE_INTEGER:
		case SURFACE_LAMBDA:
			return;
		case SURFACE_APPLICATION:
			collect_expression_effects(registry, calls, expression.data.application.callee, row, current_rows,
				diagnostics, allocator, work, depth + 1);
			foreach (argument : expression.data.application.arguments)
				collect_expression_effects(registry, calls, argument, row, current_rows,
					diagnostics, allocator, work, depth + 1);
			if (expression.data.application.callee && expression.data.application.callee.kind == SURFACE_VARIABLE)
			{
				String name = expression.data.application.callee.data.variable.name;
				EffectCallGroup* group = effect_call_group(calls, name, expression.data.application.arguments.len);
				if (group)
				{
					(void)effect_charge(work, (usz)group.targets.len());
					foreach (function_index : group.targets)
						foreach (effect : current_rows[function_index])
							(void)inferred_row_add(row, effect, work);
				}
			}
			if (expression.data.application.callee
				&& expression.data.application.callee.kind == SURFACE_LAMBDA)
			{
				collect_expression_effects(
					registry, calls, expression.data.application.callee.data.lambda.body,
					row, current_rows, diagnostics, allocator, work, depth + 1
				);
			}
		case SURFACE_EFFECT_OPERATION:
			EffectId effect = find_effect(registry, expression.data.effect_operation.effect_name);
			EffectOperationDescriptor* operation = find_effect_operation(
				registry, effect, expression.data.effect_operation.operation_name
			);
			if (!effect)
			{
				effects_add_diagnostic(diagnostics, allocator, "unknown performed effect", expression.span);
			}
			else if (!operation)
			{
				effects_add_diagnostic(diagnostics, allocator, "unknown operation for performed effect", expression.span);
			}
			else if (operation.parameter_types.len != expression.data.effect_operation.arguments.len)
			{
				effects_add_diagnostic(diagnostics, allocator, "effect operation argument count does not match its signature", expression.span);
			}
			else
			{
				(void)inferred_row_add(row, effect, work);
			}
			foreach (argument : expression.data.effect_operation.arguments)
				collect_expression_effects(registry, calls, argument, row, current_rows,
					diagnostics, allocator, work, depth + 1);
		case SURFACE_BINARY:
			collect_expression_effects(registry, calls, expression.data.binary.left, row, current_rows,
				diagnostics, allocator, work, depth + 1);
			collect_expression_effects(registry, calls, expression.data.binary.right, row, current_rows,
				diagnostics, allocator, work, depth + 1);
		case SURFACE_DEFINITION:
			collect_expression_effects(registry, calls, expression.data.definition.value, row, current_rows,
				diagnostics, allocator, work, depth + 1);
			collect_expression_effects(registry, calls, expression.data.definition.body, row, current_rows,
				diagnostics, allocator, work, depth + 1);
		case SURFACE_MATCH:
			collect_expression_effects(registry, calls, expression.data.match_expr.scrutinee, row, current_rows,
				diagnostics, allocator, work, depth + 1);
			foreach (&arm : expression.data.match_expr.arms)
				collect_expression_effects(registry, calls, arm.body, row, current_rows,
					diagnostics, allocator, work, depth + 1);
		case SURFACE_PARALLEL:
			foreach (&binding : expression.data.parallel.bindings)
				collect_expression_effects(registry, calls, binding.value, row, current_rows,
					diagnostics, allocator, work, depth + 1);
			collect_expression_effects(registry, calls, expression.data.parallel.result, row, current_rows,
				diagnostics, allocator, work, depth + 1);
		case SURFACE_HANDLER:
			List{EffectId} handled;
			handled.init(allocator);
			collect_expression_effects(registry, calls, expression.data.handler.handled, &handled, current_rows,
				diagnostics, allocator, work, depth + 1);
			foreach (&clause : expression.data.handler.clauses)
			{
				EffectId clause_effect = find_effect(registry, clause.effect_name);
				EffectOperationDescriptor* clause_operation = find_effect_operation(registry, clause_effect, clause.operation_name);
				if (!clause_effect)
				{
					effects_add_diagnostic(diagnostics, allocator, "handler clause names an unknown effect", clause.span);
				}
				else if (!clause_operation)
				{
					effects_add_diagnostic(diagnostics, allocator, "handler clause names an unknown operation", clause.span);
				}
				else if (clause_operation.parameter_types.len != clause.parameters.len)
				{
					effects_add_diagnostic(diagnostics, allocator, "handler clause parameter count does not match the operation", clause.span);
				}
				collect_expression_effects(registry, calls, clause.body, row, current_rows,
					diagnostics, allocator, work, depth + 1);
			}
			foreach (&handled_effect : registry.effects)
			{
				if (!effect_charge(work, (usz)handled.len() + 1)) break;
				bool appears = false;
				foreach (effect : handled)
				{
					if (effect_constructor_id(registry, effect) == handled_effect.id) appears = true;
				}
				if (!appears) continue;
				bool complete = true;
				foreach (&operation : handled_effect.operations)
				{
					if (!effect_charge(work, expression.data.handler.clauses.len + 1))
					{
						complete = false;
						break;
					}
					bool found = false;
					foreach (&clause : expression.data.handler.clauses)
					{
						if (clause.effect_name == handled_effect.name && clause.operation_name == operation.name) found = true;
					}
					if (!found)
					{
						complete = false;
						effects_add_diagnostic(diagnostics, allocator, "handler is missing an operation clause", expression.span);
					}
				}
				if (complete && effect_charge(work, (usz)handled.len() + 1))
				{
					row_remove_constructor(registry, &handled, handled_effect.id);
				}
			}
			foreach (effect : handled) (void)inferred_row_add(row, effect, work);
			handled.free();
			collect_expression_effects(registry, calls, expression.data.handler.return_clause.body, row, current_rows,
				diagnostics, allocator, work, depth + 1);
		case SURFACE_RESUME:
			collect_expression_effects(registry, calls, expression.data.resume.value, row, current_rows,
				diagnostics, allocator, work, depth + 1);
		default:
	}
}

fn usz count_resumes(SurfaceExpr* expression, usz depth = 0) @private
{
	if (!expression || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH) return 0;
	switch (expression.kind)
	{
		case SURFACE_RESUME: return 1 + count_resumes(expression.data.resume.value, depth + 1);
		case SURFACE_LAMBDA: return count_resumes(expression.data.lambda.body, depth + 1);
		case SURFACE_APPLICATION:
			usz count = count_resumes(expression.data.application.callee, depth + 1);
			foreach (argument : expression.data.application.arguments) count += count_resumes(argument, depth + 1);
			return count;
		case SURFACE_EFFECT_OPERATION:
			usz count = 0;
			foreach (argument : expression.data.effect_operation.arguments) count += count_resumes(argument, depth + 1);
			return count;
		case SURFACE_BINARY:
			return count_resumes(expression.data.binary.left, depth + 1) + count_resumes(expression.data.binary.right, depth + 1);
		case SURFACE_DEFINITION:
			return count_resumes(expression.data.definition.value, depth + 1) + count_resumes(expression.data.definition.body, depth + 1);
		case SURFACE_MATCH:
			usz count = count_resumes(expression.data.match_expr.scrutinee, depth + 1);
			foreach (&arm : expression.data.match_expr.arms) count += count_resumes(arm.body, depth + 1);
			return count;
		case SURFACE_PARALLEL:
			usz count = count_resumes(expression.data.parallel.result, depth + 1);
			foreach (&binding : expression.data.parallel.bindings) count += count_resumes(binding.value, depth + 1);
			return count;
		case SURFACE_HANDLER:
			return count_resumes(expression.data.handler.handled, depth + 1)
				+ count_resumes(expression.data.handler.return_clause.body, depth + 1);
		default: return 0;
	}
}

fn void validate_handler_multiplicity(
	EffectRegistry* registry,
	SurfaceExpr* expression,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	usz depth = 0
) @private
{
	if (!expression || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH) return;
	switch (expression.kind)
	{
		case SURFACE_LAMBDA:
			validate_handler_multiplicity(registry, expression.data.lambda.body, diagnostics, allocator, depth + 1);
		case SURFACE_APPLICATION:
			validate_handler_multiplicity(registry, expression.data.application.callee, diagnostics, allocator, depth + 1);
			foreach (argument : expression.data.application.arguments)
				validate_handler_multiplicity(registry, argument, diagnostics, allocator, depth + 1);
		case SURFACE_EFFECT_OPERATION:
			foreach (argument : expression.data.effect_operation.arguments)
				validate_handler_multiplicity(registry, argument, diagnostics, allocator, depth + 1);
		case SURFACE_BINARY:
			validate_handler_multiplicity(registry, expression.data.binary.left, diagnostics, allocator, depth + 1);
			validate_handler_multiplicity(registry, expression.data.binary.right, diagnostics, allocator, depth + 1);
		case SURFACE_DEFINITION:
			validate_handler_multiplicity(registry, expression.data.definition.value, diagnostics, allocator, depth + 1);
			validate_handler_multiplicity(registry, expression.data.definition.body, diagnostics, allocator, depth + 1);
		case SURFACE_MATCH:
			validate_handler_multiplicity(registry, expression.data.match_expr.scrutinee, diagnostics, allocator, depth + 1);
			foreach (&arm : expression.data.match_expr.arms)
				validate_handler_multiplicity(registry, arm.body, diagnostics, allocator, depth + 1);
		case SURFACE_PARALLEL:
			foreach (&binding : expression.data.parallel.bindings)
				validate_handler_multiplicity(registry, binding.value, diagnostics, allocator, depth + 1);
			validate_handler_multiplicity(registry, expression.data.parallel.result, diagnostics, allocator, depth + 1);
		case SURFACE_HANDLER:
			validate_handler_multiplicity(registry, expression.data.handler.handled, diagnostics, allocator, depth + 1);
			foreach (&clause : expression.data.handler.clauses)
			{
				EffectDescriptor* descriptor = effect_descriptor(registry, find_effect(registry, clause.effect_name));
				if (descriptor && !descriptor.multi && count_resumes(clause.body) > 1)
				{
					effects_add_diagnostic(diagnostics, allocator, "one-shot effect continuation is resumed more than once", clause.span);
				}
				validate_handler_multiplicity(registry, clause.body, diagnostics, allocator, depth + 1);
			}
			validate_handler_multiplicity(registry, expression.data.handler.return_clause.body, diagnostics, allocator, depth + 1);
		case SURFACE_RESUME:
			validate_handler_multiplicity(registry, expression.data.resume.value, diagnostics, allocator, depth + 1);
		default:
	}
}

fn bool index_list_contains(List{usz}* values, usz value) @private
{
	foreach (existing : *values) if (existing == value) return true;
	return false;
}

fn void collect_effect_call_edges(
	EffectCallIndex* calls,
	SurfaceExpr* expression,
	usz caller,
	List{usz}[] callees,
	List{usz}[] callers,
	EffectInferenceWork* work,
	usz depth = 0
) @private
{
	if (!expression || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH || !effect_charge(work)) return;
	switch (expression.kind)
	{
		case SURFACE_LAMBDA: return;
		case SURFACE_APPLICATION:
			collect_effect_call_edges(calls, expression.data.application.callee, caller, callees, callers, work, depth + 1);
			foreach (argument : expression.data.application.arguments)
				collect_effect_call_edges(calls, argument, caller, callees, callers, work, depth + 1);
			if (expression.data.application.callee && expression.data.application.callee.kind == SURFACE_VARIABLE)
			{
				EffectCallGroup* group = effect_call_group(
					calls, expression.data.application.callee.data.variable.name,
					expression.data.application.arguments.len
				);
				if (group) foreach (target : group.targets)
				{
					if (!index_list_contains(&callees[caller], target)) callees[caller].push(target);
					if (!index_list_contains(&callers[target], caller)) callers[target].push(caller);
					(void)effect_charge(work);
				}
			}
		case SURFACE_EFFECT_OPERATION:
			foreach (argument : expression.data.effect_operation.arguments)
				collect_effect_call_edges(calls, argument, caller, callees, callers, work, depth + 1);
		case SURFACE_BINARY:
			collect_effect_call_edges(calls, expression.data.binary.left, caller, callees, callers, work, depth + 1);
			collect_effect_call_edges(calls, expression.data.binary.right, caller, callees, callers, work, depth + 1);
		case SURFACE_DEFINITION:
			collect_effect_call_edges(calls, expression.data.definition.value, caller, callees, callers, work, depth + 1);
			collect_effect_call_edges(calls, expression.data.definition.body, caller, callees, callers, work, depth + 1);
		case SURFACE_MATCH:
			collect_effect_call_edges(calls, expression.data.match_expr.scrutinee, caller, callees, callers, work, depth + 1);
			foreach (&arm : expression.data.match_expr.arms)
				collect_effect_call_edges(calls, arm.body, caller, callees, callers, work, depth + 1);
		case SURFACE_PARALLEL:
			foreach (&binding : expression.data.parallel.bindings)
				collect_effect_call_edges(calls, binding.value, caller, callees, callers, work, depth + 1);
			collect_effect_call_edges(calls, expression.data.parallel.result, caller, callees, callers, work, depth + 1);
		case SURFACE_HANDLER:
			collect_effect_call_edges(calls, expression.data.handler.handled, caller, callees, callers, work, depth + 1);
			foreach (&clause : expression.data.handler.clauses)
				collect_effect_call_edges(calls, clause.body, caller, callees, callers, work, depth + 1);
			collect_effect_call_edges(calls, expression.data.handler.return_clause.body, caller, callees, callers, work, depth + 1);
		case SURFACE_RESUME:
			collect_effect_call_edges(calls, expression.data.resume.value, caller, callees, callers, work, depth + 1);
		default:
	}
}

fn void effect_tarjan_visit(
	usz vertex,
	List{usz}[] callees,
	sz[] indices,
	usz[] lowlinks,
	bool[] on_stack,
	List{usz}* stack,
	usz* next_index,
	usz[] components,
	usz* component_count,
	EffectInferenceWork* work
) @private
{
	if (!effect_charge(work)) return;
	indices[vertex] = (sz)*next_index;
	lowlinks[vertex] = (*next_index)++;
	stack.push(vertex);
	on_stack[vertex] = true;
	foreach (target : callees[vertex])
	{
		if (indices[target] < 0)
		{
			effect_tarjan_visit(target, callees, indices, lowlinks, on_stack, stack,
				next_index, components, component_count, work);
			if (lowlinks[target] < lowlinks[vertex]) lowlinks[vertex] = lowlinks[target];
		}
		else if (on_stack[target] && (usz)indices[target] < lowlinks[vertex])
		{
			lowlinks[vertex] = (usz)indices[target];
		}
	}
	if (lowlinks[vertex] != (usz)indices[vertex]) return;
	while (stack.len())
	{
		usz member = stack.pop()!!;
		on_stack[member] = false;
		components[member] = *component_count;
		if (member == vertex) break;
	}
	(*component_count)++;
}

fn void collect_lambda_effect_info(
	EffectRegistry* registry,
	TypeRegistry* types,
	EffectCallIndex* calls,
	SurfaceExpr* expression,
	List{EffectId}[] rows,
	List{LambdaEffectInfo}* lambdas,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	EffectInferenceWork* work,
	usz depth = 0
) @private
{
	if (!expression || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH || !effect_charge(work)) return;
	if (expression.kind == SURFACE_LAMBDA)
	{
		List{EffectId} inferred;
		List{EffectId} asserted;
		inferred.init(allocator);
		asserted.init(allocator);
		collect_expression_effects(registry, calls, expression.data.lambda.body, &inferred, rows,
			diagnostics, allocator, work, depth + 1);
		if (expression.data.lambda.effect_row)
		{
			foreach (effect_expr : expression.data.lambda.effect_row.effects)
			{
				EffectId effect;
				MitosDiagnostic diagnostic;
				if (resolve_effect_expr(registry, types, effect_expr, &effect, &diagnostic))
				{
					row_add(&asserted, effect);
				}
				else
				{
					diagnostics.push(diagnostic);
				}
			}
			foreach (&effect : inferred)
			{
				bool declared = false;
				foreach (asserted_effect : asserted)
				{
					if (effect_constructor_id(registry, asserted_effect) == effect_constructor_id(registry, *effect))
					{
						declared = true;
						if (asserted_effect != effect_constructor_id(registry, asserted_effect)) *effect = asserted_effect;
					}
				}
				if (!declared)
				{
					effects_add_diagnostic(diagnostics, allocator,
						"lambda 'does' row omits an inferred transitive effect", expression.data.lambda.effect_row.span);
				}
			}
		}
		lambdas.push({
			.span = expression.span,
			.inferred = inferred.to_array(allocator),
			.asserted = asserted.to_array(allocator),
			.has_assertion = expression.data.lambda.effect_row != null,
		});
		inferred.free();
		asserted.free();
		collect_lambda_effect_info(registry, types, calls, expression.data.lambda.body, rows,
			lambdas, diagnostics, allocator, work, depth + 1);
		return;
	}
	switch (expression.kind)
	{
		case SURFACE_APPLICATION:
			collect_lambda_effect_info(registry, types, calls, expression.data.application.callee, rows,
				lambdas, diagnostics, allocator, work, depth + 1);
			foreach (argument : expression.data.application.arguments)
				collect_lambda_effect_info(registry, types, calls, argument, rows,
					lambdas, diagnostics, allocator, work, depth + 1);
		case SURFACE_EFFECT_OPERATION:
			foreach (argument : expression.data.effect_operation.arguments)
				collect_lambda_effect_info(registry, types, calls, argument, rows,
					lambdas, diagnostics, allocator, work, depth + 1);
		case SURFACE_BINARY:
			collect_lambda_effect_info(registry, types, calls, expression.data.binary.left, rows,
				lambdas, diagnostics, allocator, work, depth + 1);
			collect_lambda_effect_info(registry, types, calls, expression.data.binary.right, rows,
				lambdas, diagnostics, allocator, work, depth + 1);
		case SURFACE_DEFINITION:
			collect_lambda_effect_info(registry, types, calls, expression.data.definition.value, rows,
				lambdas, diagnostics, allocator, work, depth + 1);
			collect_lambda_effect_info(registry, types, calls, expression.data.definition.body, rows,
				lambdas, diagnostics, allocator, work, depth + 1);
		case SURFACE_MATCH:
			collect_lambda_effect_info(registry, types, calls, expression.data.match_expr.scrutinee, rows,
				lambdas, diagnostics, allocator, work, depth + 1);
			foreach (&arm : expression.data.match_expr.arms)
				collect_lambda_effect_info(registry, types, calls, arm.body, rows,
					lambdas, diagnostics, allocator, work, depth + 1);
		case SURFACE_PARALLEL:
			foreach (&binding : expression.data.parallel.bindings)
				collect_lambda_effect_info(registry, types, calls, binding.value, rows,
					lambdas, diagnostics, allocator, work, depth + 1);
			collect_lambda_effect_info(registry, types, calls, expression.data.parallel.result, rows,
				lambdas, diagnostics, allocator, work, depth + 1);
		case SURFACE_HANDLER:
			collect_lambda_effect_info(registry, types, calls, expression.data.handler.handled, rows,
				lambdas, diagnostics, allocator, work, depth + 1);
			foreach (&clause : expression.data.handler.clauses)
				collect_lambda_effect_info(registry, types, calls, clause.body, rows,
					lambdas, diagnostics, allocator, work, depth + 1);
			collect_lambda_effect_info(registry, types, calls, expression.data.handler.return_clause.body, rows,
				lambdas, diagnostics, allocator, work, depth + 1);
		case SURFACE_RESUME:
			collect_lambda_effect_info(registry, types, calls, expression.data.resume.value, rows,
				lambdas, diagnostics, allocator, work, depth + 1);
		default:
	}
}

fn EffectAnalysis infer_effect_rows(
	Program* program,
	EffectRegistry* registry,
	TypeRegistry* types,
	Allocator allocator = mem,
	usz max_steps = MITOS_MAX_EFFECT_INFERENCE_STEPS
)
{
	EffectAnalysis analysis = { .allocator = allocator, .effect_epoch = registry.epoch };
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);
	EffectInferenceWork work = { .max = max_steps };
	EffectCallIndex calls = build_effect_call_index(program, allocator);
	defer calls.deinit();
	List{EffectId}[] rows = alloc::new_array(allocator, List{EffectId}, program.functions.len);
	List{usz}[] callees = alloc::new_array(allocator, List{usz}, program.functions.len);
	List{usz}[] callers = alloc::new_array(allocator, List{usz}, program.functions.len);
	foreach (&row : rows) row.init(allocator);
	foreach (&edges : callees) edges.init(allocator);
	foreach (&edges : callers) edges.init(allocator);
	foreach (function_index, &function : program.functions)
		collect_effect_call_edges(&calls, function.body, (usz)function_index, callees, callers, &work);

	sz[] indices = alloc::new_array(allocator, sz, program.functions.len);
	usz[] lowlinks = alloc::new_array(allocator, usz, program.functions.len);
	bool[] on_stack = alloc::new_array(allocator, bool, program.functions.len);
	usz[] components = alloc::new_array(allocator, usz, program.functions.len);
	foreach (&index : indices) *index = -1;
	List{usz} stack;
	stack.init(allocator);
	usz next_index = 0;
	usz component_count = 0;
	foreach (function_index, &function : program.functions)
	{
		if (indices[function_index] < 0)
		{
			effect_tarjan_visit((usz)function_index, callees, indices, lowlinks, on_stack, &stack,
				&next_index, components, &component_count, &work);
		}
	}
	stack.free();

	List{usz} queue;
	queue.init(allocator);
	bool[] queued = alloc::new_array(allocator, bool, program.functions.len);
	foreach (function_index, &function : program.functions)
	{
		queue.push((usz)function_index);
		queued[function_index] = true;
	}
	usz head = 0;
	while (head < (usz)queue.len() && !work.exhausted)
	{
		usz function_index = queue[(sz)head++];
		queued[function_index] = false;
		List{EffectId} collected;
		collected.init(allocator);
		collect_expression_effects(registry, &calls, program.functions[function_index].body, &collected,
			rows, &diagnostics, allocator, &work, 0);
		bool changed = false;
		foreach (effect : collected)
			if (inferred_row_add(&rows[function_index], effect, &work)) changed = true;
		collected.free();
		if (!changed) continue;
		foreach (caller : callers[function_index])
		{
			if (!queued[caller]) { queue.push(caller); queued[caller] = true; }
		}
		if (!effect_charge(&work, components.len)) break;
		foreach (peer_index, component : components)
		{
			if (component == components[function_index] && !queued[peer_index])
			{
				queue.push((usz)peer_index);
				queued[peer_index] = true;
			}
		}
	}
	queue.free();
	List{LambdaEffectInfo} lambdas;
	lambdas.init(allocator);
	foreach (&function : program.functions)
		collect_lambda_effect_info(registry, types, &calls, function.body, rows, &lambdas,
			&diagnostics, allocator, &work);
	analysis.lambdas = lambdas.to_array(allocator);
	lambdas.free();
	analysis.inference_steps = work.used;
	if (work.exhausted)
	{
		MitosPosition origin = { .row = 1, .column = 1 };
		effects_add_diagnostic(&diagnostics, allocator, "effect-row inference exceeded its bounded graph-work budget", {
			.start = origin, .end = origin,
		});
	}

	analysis.methods = alloc::new_array(allocator, MethodEffectInfo, program.functions.len);
	foreach (function_index, &function : program.functions)
	{
		List{EffectId} asserted;
		asserted.init(allocator);
		if (function.effect_row)
		{
			foreach (effect_expr : function.effect_row.effects)
			{
				EffectId effect;
				MitosDiagnostic diagnostic;
				if (resolve_effect_expr(registry, types, effect_expr, &effect, &diagnostic))
				{
					row_add(&asserted, effect);
				}
				else
				{
					diagnostics.push(diagnostic);
				}
			}
			foreach (&inferred : rows[(usz)function_index])
			{
				bool declared = false;
				foreach (asserted_effect : asserted)
				{
					if (effect_constructor_id(registry, asserted_effect) == effect_constructor_id(registry, *inferred))
					{
						declared = true;
						if (asserted_effect != effect_constructor_id(registry, asserted_effect)) *inferred = asserted_effect;
					}
				}
				if (!declared)
				{
					effects_add_diagnostic(&diagnostics, allocator, "explicit 'does' row omits an inferred transitive effect", function.effect_row.span);
				}
			}
		}
		analysis.methods[(usz)function_index] = {
			.function_index = (usz)function_index,
			.inferred = rows[(usz)function_index].to_array(allocator),
			.asserted = asserted.to_array(allocator),
			.has_assertion = function.effect_row != null,
		};
		asserted.free();
		if (function.name == "main")
		{
			bool unhandled = false;
			foreach (effect : rows[(usz)function_index])
			{
				EffectDescriptor* descriptor = effect_descriptor(registry, effect_constructor_id(registry, effect));
				if (!descriptor) { unhandled = true; continue; }
				foreach (&operation : descriptor.operations)
					if (operation.host_policy != EFFECT_HOST_EXTERNAL) unhandled = true;
			}
			if (unhandled)
			{
				effects_add_diagnostic(&diagnostics, allocator, "main has an unhandled declared effect", function.span);
			}
		}
		validate_handler_multiplicity(registry, function.body, &diagnostics, allocator);
	}
	foreach (&row : rows) row.free();
	foreach (&edges : callees) edges.free();
	foreach (&edges : callers) edges.free();
	alloc::free(allocator, rows);
	alloc::free(allocator, callees);
	alloc::free(allocator, callers);
	alloc::free(allocator, indices);
	alloc::free(allocator, lowlinks);
	alloc::free(allocator, on_stack);
	alloc::free(allocator, components);
	alloc::free(allocator, queued);
	analysis.diagnostics = diagnostics.to_array(allocator);
	analysis.effect_epoch = registry.epoch;
	diagnostics.free();
	return analysis;
}

fn bool validate_effect_row_assertion(EffectRegistry* registry, MethodEffectInfo* info, EffectId actual)
{
	if (!info.has_assertion) return true;
	foreach (declared : info.asserted)
	{
		if (declared == actual || effect_constructor_id(registry, declared) == effect_constructor_id(registry, actual))
		{
			return true;
		}
	}
	return false;
}
fn EffectInvalidation bump_effect_epoch(EffectRegistry* registry, EffectId changed_effect)
{
	EffectInvalidation invalidation = {
		.previous_epoch = registry.epoch,
		.changed_effect = changed_effect,
	};
	registry.epoch++;
	invalidation.current_epoch = registry.epoch;
	return invalidation;
}
