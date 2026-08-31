module delta_net_abstract_machine::mitos;

import std::collections::list;
import std::core::mem;
import std::io;

/** Compact stable identity into one program-lifetime TypeRegistry. */
typedef TypeId = uint;

const TypeId TYPE_ID_INVALID = (TypeId)0;
const TypeId TYPE_ID_ANY = (TypeId)1;
const TypeId TYPE_ID_NEVER = (TypeId)2;
const TypeId TYPE_ID_TYPE = (TypeId)3;
const TypeId TYPE_ID_I64 = (TypeId)4;
const TypeId TYPE_ID_BOOL = (TypeId)5;
const TypeId TYPE_ID_UNIT = (TypeId)6;
const TypeId TYPE_ID_STRING = (TypeId)7;
const TypeId TYPE_ID_ARRAY = (TypeId)8;
const TypeId TYPE_ID_FUNCTION = (TypeId)9;
const TypeId TYPE_ID_SUPERPOSITION = (TypeId)10;
const usz MITOS_DEFAULT_MAX_TYPES = 16_384;
const usz MITOS_MAX_TYPE_FORMAT_DEPTH = 256;
const usz MITOS_MAX_TYPE_FORMAT_BYTES = 1_048_576;
const usz MITOS_MAX_CONSTRUCTOR_FIELDS = 4_096;
const usz MITOS_MAX_FUNCTION_PARAMETERS = 1_024;
const usz MITOS_MAX_FUNCTION_EFFECTS = 4_096;

enum TypeDescriptorKind : char
{
	TYPE_DESCRIPTOR_ABSTRACT,
	TYPE_DESCRIPTOR_CONCRETE,
	TYPE_DESCRIPTOR_INSTANCE,
	TYPE_DESCRIPTOR_FUNCTION_INSTANCE,
}

enum TypePatternKind : char
{
	TYPE_PATTERN_ANY,
	TYPE_PATTERN_EXACT,
	TYPE_PATTERN_VARIABLE,
	TYPE_PATTERN_APPLICATION,
}

/** Allocator-owned symbolic type used by constructors and effect operations. */
struct TypePattern
{
	TypePatternKind kind;
	String variable;
	TypeId constructor;
	TypePattern[] arguments;
	MitosSpan span;
}

struct TypePatternBinding
{
	String variable;
	TypeId type_id;
}

struct TypeFieldDescriptor
{
	String name;
	String type_pattern;
	TypeId declared_type;
	TypePattern pattern;
	MitosSpan span;
}

struct TypeDescriptor
{
	TypeId id;
	TypeDescriptorKind kind;
	String name;
	String[] parameters;
	TypeId nominal_parent;
	TypeId constructor;
	TypeId[] arguments;
	usz arity;
	TypeFieldDescriptor[] fields;
	TypeId[] function_parameters;
	TypeId function_result;
	EffectId[] function_effects;
	MitosSpan span;
}

struct TypeRegistry
{
	Allocator allocator;
	List{TypeDescriptor} descriptors;
	usz max_types;
	ulong epoch;
}

struct TypeRegistryBuildResult
{
	Allocator allocator;
	TypeRegistry registry;
	MitosDiagnostic[] diagnostics;
}

struct TypeValue
{
	TypeId represented;
	TypeId runtime_type;
}

struct RuntimeTypeMetadata
{
	TypeId type_id;
}

fn bool TypeRegistryBuildResult.ok(&self) => self.diagnostics.len == 0;

fn void TypePattern.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.variable);
	foreach (&argument : self.arguments) argument.deinit(allocator);
	alloc::free(allocator, self.arguments);
	*self = { };
}

fn TypePattern clone_type_pattern(TypePattern* pattern, Allocator allocator)
{
	TypePattern clone = {
		.kind = pattern.kind,
		.variable = pattern.variable.copy(allocator),
		.constructor = pattern.constructor,
		.span = pattern.span,
	};
	clone.arguments = alloc::new_array(allocator, TypePattern, pattern.arguments.len);
	foreach (index, &argument : pattern.arguments)
		clone.arguments[index] = clone_type_pattern(argument, allocator);
	return clone;
}

fn void TypeDescriptor.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.name);
	foreach (parameter : self.parameters) alloc::free(allocator, parameter);
	alloc::free(allocator, self.parameters);
	alloc::free(allocator, self.arguments);
	foreach (&field : self.fields)
	{
		field.pattern.deinit(allocator);
		alloc::free(allocator, field.name);
		alloc::free(allocator, field.type_pattern);
	}
	alloc::free(allocator, self.fields);
	alloc::free(allocator, self.function_parameters);
	alloc::free(allocator, self.function_effects);
	*self = { };
}

fn void TypeRegistry.deinit(&self)
{
	if (!self.allocator) return;
	foreach (&descriptor : self.descriptors) descriptor.deinit(self.allocator);
	self.descriptors.free();
	*self = { };
}

fn void TypeRegistryBuildResult.deinit(&self)
{
	if (!self.allocator) return;
	self.registry.deinit();
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

fn void types_add_diagnostic(
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	String message,
	MitosSpan span
) @private
{
	MitosDiagnostic diagnostic;
	diagnostic.init(allocator, message, span);
	diagnostics.push(diagnostic);
}

fn bool type_registry_append(
	TypeRegistry* registry,
	TypeDescriptor descriptor,
	TypeId* result = null
) @private
{
	if ((usz)registry.descriptors.len() >= registry.max_types) return false;
	descriptor.id = (TypeId)((usz)registry.descriptors.len() + 1);
	registry.descriptors.push(descriptor);
	if (result) *result = descriptor.id;
	return true;
}

fn bool type_registry_bootstrap(TypeRegistry* registry) @private
{
	MitosPosition origin = { .row = 1, .column = 1 };
	MitosSpan span = { .start = origin, .end = origin };
	return type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_ABSTRACT, .name = "Any".copy(registry.allocator), .span = span,
	}) && type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_CONCRETE, .name = "Never".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY, .span = span,
	}) && type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_CONCRETE, .name = "Type".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY, .arity = 1, .span = span,
	}) && type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_CONCRETE, .name = "I64".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY, .span = span,
	}) && type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_CONCRETE, .name = "Bool".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY, .span = span,
	}) && type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_CONCRETE, .name = "Unit".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY, .span = span,
	}) && type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_CONCRETE, .name = "String".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY, .span = span,
	}) && type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_CONCRETE, .name = "Array".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY, .arity = 1, .span = span,
	}) && type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_CONCRETE, .name = "Function".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY, .span = span,
	}) && type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_CONCRETE, .name = "Superposition".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY, .arity = 1, .span = span,
	});
}

fn TypeDescriptor* type_descriptor(TypeRegistry* registry, TypeId id)
{
	if (!registry || id == TYPE_ID_INVALID || (usz)id > (usz)registry.descriptors.len()) return null;
	return &registry.descriptors[(usz)id - 1];
}

fn TypeId find_type(TypeRegistry* registry, String name)
{
	if (!registry) return TYPE_ID_INVALID;
	foreach (&descriptor : registry.descriptors)
	{
		if (descriptor.kind != TYPE_DESCRIPTOR_INSTANCE
			&& descriptor.kind != TYPE_DESCRIPTOR_FUNCTION_INSTANCE && descriptor.name == name) return descriptor.id;
	}
	return TYPE_ID_INVALID;
}

fn bool type_id_is_valid(TypeRegistry* registry, TypeId id) => type_descriptor(registry, id) != null;

fn bool type_arguments_equal(TypeId[] left, TypeId[] right) @private
{
	if (left.len != right.len) return false;
	foreach (index, value : left) if (value != right[index]) return false;
	return true;
}

fn bool intern_type(
	TypeRegistry* registry,
	TypeId constructor,
	TypeId[] arguments,
	TypeId* result,
	MitosDiagnostic* diagnostic = null,
	MitosSpan span = { }
)
{
	if (arguments.len > MITOS_MAX_CONSTRUCTOR_FIELDS)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "type application exceeds its argument bound", span);
		return false;
	}
	TypeDescriptor* base = type_descriptor(registry, constructor);
	if (!base || base.kind == TYPE_DESCRIPTOR_INSTANCE || base.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "invalid parametric type constructor", span);
		return false;
	}
	if (base.arity != arguments.len)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "type constructor argument count does not match its declaration", span);
		return false;
	}
	foreach (argument : arguments)
	{
		if (!type_id_is_valid(registry, argument))
		{
			if (diagnostic) diagnostic.init(registry.allocator, "parametric type contains an invalid TypeId", span);
			return false;
		}
	}
	foreach (&descriptor : registry.descriptors)
	{
		if (descriptor.kind == TYPE_DESCRIPTOR_INSTANCE && descriptor.constructor == constructor
			&& type_arguments_equal(descriptor.arguments, arguments))
		{
			*result = descriptor.id;
			return true;
		}
	}
	TypeId instance;
	if (!type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_INSTANCE,
		.name = base.name.copy(registry.allocator),
		.nominal_parent = base.nominal_parent,
		.constructor = constructor,
		.arguments = alloc::clone_slice(registry.allocator, arguments),
		.span = span,
	}, &instance))
	{
		if (diagnostic) diagnostic.init(registry.allocator, "type registry exhausted its bounded capacity", span);
		return false;
	}
	registry.epoch++;
	*result = instance;
	return true;
}

fn bool intern_type_value_type(
	TypeRegistry* registry,
	TypeId represented,
	TypeId* result,
	MitosDiagnostic* diagnostic = null,
	MitosSpan span = { }
)
{
	TypeId[1] arguments = { represented };
	return intern_type(registry, TYPE_ID_TYPE, arguments[..], result, diagnostic, span);
}

fn bool effect_ids_equal(EffectId[] left, EffectId[] right) @private
{
	if (left.len != right.len) return false;
	foreach (index, value : left) if (value != right[index]) return false;
	return true;
}

/** Interns the concrete identity of a closure signature. */
fn bool intern_function_type(
	TypeRegistry* registry,
	TypeId[] parameters,
	TypeId result_type,
	EffectId[] effects,
	TypeId* result,
	MitosDiagnostic* diagnostic = null,
	MitosSpan span = { }
)
{
	if (parameters.len > MITOS_MAX_FUNCTION_PARAMETERS || effects.len > MITOS_MAX_FUNCTION_EFFECTS)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "function signature exceeds its metadata bound", span);
		return false;
	}
	foreach (parameter : parameters)
	{
		if (!type_id_is_valid(registry, parameter))
		{
			if (diagnostic) diagnostic.init(registry.allocator, "function signature contains an invalid parameter TypeId", span);
			return false;
		}
	}
	if (!type_id_is_valid(registry, result_type))
	{
		if (diagnostic) diagnostic.init(registry.allocator, "function signature contains an invalid result TypeId", span);
		return false;
	}
	foreach (&descriptor : registry.descriptors)
	{
		if (descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE
			&& type_arguments_equal(descriptor.function_parameters, parameters)
			&& descriptor.function_result == result_type
			&& effect_ids_equal(descriptor.function_effects, effects))
		{
			*result = descriptor.id;
			return true;
		}
	}
	TypeId instance;
	if (!type_registry_append(registry, {
		.kind = TYPE_DESCRIPTOR_FUNCTION_INSTANCE,
		.name = "Function".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY,
		.constructor = TYPE_ID_FUNCTION,
		.function_parameters = alloc::clone_slice(registry.allocator, parameters),
		.function_result = result_type,
		.function_effects = alloc::clone_slice(registry.allocator, effects),
		.span = span,
	}, &instance))
	{
		if (diagnostic) diagnostic.init(registry.allocator, "type registry exhausted its bounded capacity", span);
		return false;
	}
	registry.epoch++;
	*result = instance;
	return true;
}

fn bool declared_type_parameter(TypeParameterDecl[] parameters, String name) @private
{
	foreach (&parameter : parameters) if (parameter.name == name) return true;
	return false;
}

fn bool build_type_pattern(
	TypeRegistry* registry,
	TypeExpr* expression,
	TypeParameterDecl[] parameters,
	TypePattern* result,
	MitosDiagnostic* diagnostic,
	Allocator allocator,
	usz depth = 0
)
{
	if (depth >= MITOS_MAX_TYPE_FORMAT_DEPTH)
	{
		MitosSpan error_span = { };
		if (expression) error_span = expression.span;
		diagnostic.init(allocator, "type pattern exceeds its nesting bound", error_span);
		return false;
	}
	if (!expression)
	{
		*result = { .kind = TYPE_PATTERN_ANY, .constructor = TYPE_ID_ANY };
		return true;
	}
	if (expression.kind == TYPE_EXPR_NAMED && declared_type_parameter(parameters, expression.name))
	{
		*result = {
			.kind = TYPE_PATTERN_VARIABLE,
			.variable = expression.name.copy(allocator),
			.span = expression.span,
		};
		return true;
	}
	TypeId constructor = find_type(registry, expression.name);
	TypeDescriptor* descriptor = type_descriptor(registry, constructor);
	if (!descriptor)
	{
		diagnostic.init(allocator, "unknown nominal type in type pattern", expression.span);
		return false;
	}
	if (expression.kind == TYPE_EXPR_NAMED)
	{
		if (descriptor.arity)
		{
			diagnostic.init(allocator, "parametric type pattern requires its declared 'of' arguments", expression.span);
			return false;
		}
		*result = {
			.kind = constructor == TYPE_ID_ANY ? TYPE_PATTERN_ANY : TYPE_PATTERN_EXACT,
			.constructor = constructor,
			.span = expression.span,
		};
		return true;
	}
	if (descriptor.arity != expression.arguments.len)
	{
		diagnostic.init(allocator, "type pattern application has the wrong arity", expression.span);
		return false;
	}
	TypePattern[] arguments = alloc::new_array(allocator, TypePattern, expression.arguments.len);
	foreach (index, &argument : expression.arguments)
	{
		if (!build_type_pattern(
			registry, argument.value, parameters, &arguments[index], diagnostic, allocator, depth + 1
		))
		{
			for (usz owned = 0; owned < (usz)index; owned++) arguments[owned].deinit(allocator);
			alloc::free(allocator, arguments);
			return false;
		}
	}
	*result = {
		.kind = TYPE_PATTERN_APPLICATION,
		.constructor = constructor,
		.arguments = arguments,
		.span = expression.span,
	};
	return true;
}

fn sz type_pattern_binding_index(TypePatternBinding[] bindings, String variable) @private
{
	foreach (index, &binding : bindings) if (binding.variable == variable) return (sz)index;
	return -1;
}

fn bool match_type_pattern(
	TypeRegistry* registry,
	TypePattern* pattern,
	TypeId actual,
	TypePatternBinding[] bindings,
	usz* binding_count,
	usz depth = 0
)
{
	if (depth >= MITOS_MAX_TYPE_FORMAT_DEPTH) return false;
	if (pattern.kind == TYPE_PATTERN_ANY) return type_id_is_valid(registry, actual);
	if (pattern.kind == TYPE_PATTERN_EXACT) return type_is_subtype(registry, actual, pattern.constructor);
	if (pattern.kind == TYPE_PATTERN_VARIABLE)
	{
		sz existing = type_pattern_binding_index(bindings[:(sz)*binding_count], pattern.variable);
		if (existing >= 0) return bindings[(usz)existing].type_id == actual;
		if (*binding_count >= bindings.len) return false;
		bindings[*binding_count] = { .variable = pattern.variable, .type_id = actual };
		(*binding_count)++;
		return true;
	}
	TypeDescriptor* descriptor = type_descriptor(registry, actual);
	if (!descriptor || descriptor.kind != TYPE_DESCRIPTOR_INSTANCE
		|| descriptor.constructor != pattern.constructor
		|| descriptor.arguments.len != pattern.arguments.len) return false;
	foreach (index, &argument : pattern.arguments)
	{
		if (!match_type_pattern(
			registry, argument, descriptor.arguments[index], bindings, binding_count, depth + 1
		)) return false;
	}
	return true;
}

fn bool instantiate_type_pattern(
	TypeRegistry* registry,
	TypePattern* pattern,
	TypePatternBinding[] bindings,
	TypeId* result,
	MitosDiagnostic* diagnostic = null,
	MitosSpan span = { },
	usz depth = 0
)
{
	if (depth >= MITOS_MAX_TYPE_FORMAT_DEPTH)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "type pattern exceeds its nesting bound", span);
		return false;
	}
	if (pattern.kind == TYPE_PATTERN_ANY) { *result = TYPE_ID_ANY; return true; }
	if (pattern.kind == TYPE_PATTERN_EXACT) { *result = pattern.constructor; return true; }
	if (pattern.kind == TYPE_PATTERN_VARIABLE)
	{
		sz index = type_pattern_binding_index(bindings, pattern.variable);
		if (index >= 0) { *result = bindings[(usz)index].type_id; return true; }
		if (diagnostic) diagnostic.init(registry.allocator, "type pattern contains an unbound variable", span);
		return false;
	}
	TypeId[] arguments = alloc::new_array(registry.allocator, TypeId, pattern.arguments.len);
	defer alloc::free(registry.allocator, arguments);
	foreach (index, &argument : pattern.arguments)
	{
		if (!instantiate_type_pattern(
			registry, argument, bindings, &arguments[index], diagnostic, span, depth + 1
		)) return false;
	}
	return intern_type(registry, pattern.constructor, arguments, result, diagnostic, span);
}

/** Infers and interns a parametric constructor result from concrete field types. */
fn bool infer_constructor_instance(
	TypeRegistry* registry,
	TypeId constructor,
	String[] parameters,
	TypePattern[] field_patterns,
	TypeId[] actual_fields,
	TypeId* result,
	MitosDiagnostic* diagnostic = null,
	MitosSpan span = { }
)
{
	if (field_patterns.len != actual_fields.len || parameters.len > MITOS_MAX_TYPE_FORMAT_DEPTH
		|| field_patterns.len > MITOS_MAX_CONSTRUCTOR_FIELDS)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "constructor field metadata does not match its invocation", span);
		return false;
	}
	if (!parameters.len) { *result = constructor; return true; }
	TypePatternBinding[] bindings = alloc::new_array(registry.allocator, TypePatternBinding, parameters.len);
	defer alloc::free(registry.allocator, bindings);
	usz binding_count = 0;
	foreach (index, &pattern : field_patterns)
	{
		if (!match_type_pattern(registry, pattern, actual_fields[index], bindings, &binding_count))
		{
			if (diagnostic) diagnostic.init(registry.allocator, "constructor fields do not satisfy their parametric layout", span);
			return false;
		}
	}
	TypeId[] arguments = alloc::new_array(registry.allocator, TypeId, parameters.len);
	defer alloc::free(registry.allocator, arguments);
	foreach (index, parameter : parameters)
	{
		sz binding = type_pattern_binding_index(bindings[:(sz)binding_count], parameter);
		if (binding < 0)
		{
			if (diagnostic) diagnostic.init(registry.allocator, "constructor type parameter cannot be inferred from its fields", span);
			return false;
		}
		arguments[index] = bindings[(usz)binding].type_id;
	}
	return intern_type(registry, constructor, arguments, result, diagnostic, span);
}

fn bool resolve_type_expr(
	TypeRegistry* registry,
	TypeExpr* expression,
	TypeId* result,
	MitosDiagnostic* diagnostic = null
)
{
	if (!expression)
	{
		*result = TYPE_ID_ANY;
		return true;
	}
	TypeId constructor = find_type(registry, expression.name);
	if (!constructor)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "unknown nominal type", expression.span);
		return false;
	}
	TypeDescriptor* descriptor = type_descriptor(registry, constructor);
	if (expression.kind == TYPE_EXPR_NAMED)
	{
		if (descriptor.arity)
		{
			if (diagnostic) diagnostic.init(registry.allocator, "parametric type requires its declared 'of' arguments", expression.span);
			return false;
		}
		*result = constructor;
		return true;
	}
	if (expression.arguments.len != descriptor.arity)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "type application arity does not match its constructor", expression.span);
		return false;
	}
	TypeId[] arguments = alloc::new_array(registry.allocator, TypeId, expression.arguments.len);
	defer alloc::free(registry.allocator, arguments);
	foreach (index, &argument : expression.arguments)
	{
		if (!resolve_type_expr(registry, argument.value, &arguments[index], diagnostic)) return false;
	}
	return intern_type(registry, constructor, arguments, result, diagnostic, expression.span);
}

fn bool type_is_subtype(TypeRegistry* registry, TypeId candidate, TypeId expected)
{
	if (!type_id_is_valid(registry, candidate) || !type_id_is_valid(registry, expected)) return false;
	if (candidate == TYPE_ID_NEVER || expected == TYPE_ID_ANY || candidate == expected) return true;
	TypeDescriptor* candidate_descriptor = type_descriptor(registry, candidate);
	TypeDescriptor* expected_descriptor = type_descriptor(registry, expected);
	if (expected_descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE) return false;
	TypeId current_constructor = candidate_descriptor.kind == TYPE_DESCRIPTOR_INSTANCE
		|| candidate_descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE
		? candidate_descriptor.constructor : candidate;
	TypeId expected_constructor = expected_descriptor.kind == TYPE_DESCRIPTOR_INSTANCE
		|| expected_descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE
		? expected_descriptor.constructor : expected;
	TypeId[] candidate_arguments = candidate_descriptor.arguments;
	TypeId[] expected_arguments = expected_descriptor.arguments;
	for (usz depth = 0; depth < (usz)registry.descriptors.len(); depth++)
	{
		if (current_constructor == expected_constructor)
		{
			if (!expected_arguments.len) return true;
			return type_arguments_equal(candidate_arguments, expected_arguments);
		}
		TypeDescriptor* current = type_descriptor(registry, current_constructor);
		if (!current || !current.nominal_parent) return false;
		TypeDescriptor* parent = type_descriptor(registry, current.nominal_parent);
		if (!parent) return false;
		if (parent.arity != candidate_arguments.len) candidate_arguments = { };
		current_constructor = current.nominal_parent;
	}
	return false;
}

fn bool append_type_pattern(DString* output, TypeExpr* expression, usz depth) @private
{
	if (!expression || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH) return false;
	if (output.str_view().len + expression.name.len > MITOS_MAX_TYPE_FORMAT_BYTES) return false;
	output.append_string(expression.name);
	if (expression.kind == TYPE_EXPR_NAMED) return true;
	output.append_string(" of ");
	if (expression.arguments.len > 1) output.append_string("(");
	foreach (index, &argument : expression.arguments)
	{
		if (index) output.append_string(", ");
		if (!append_type_pattern(output, argument.value, depth + 1)) return false;
	}
	if (expression.arguments.len > 1) output.append_string(")");
	return output.str_view().len <= MITOS_MAX_TYPE_FORMAT_BYTES;
}

fn String format_type_expr(TypeExpr* expression, Allocator allocator = mem)
{
	DString output;
	output.init(allocator);
	if (!append_type_pattern(&output, expression, 0))
	{
		output.free();
		return "<type expression exceeds formatting limit>".copy(allocator);
	}
	String result = output.copy_str(allocator);
	output.free();
	return result;
}

fn bool append_type_id(TypeRegistry* registry, DString* output, TypeId id, usz depth) @private
{
	if (depth >= MITOS_MAX_TYPE_FORMAT_DEPTH) return false;
	TypeDescriptor* descriptor = type_descriptor(registry, id);
	if (!descriptor || output.str_view().len + descriptor.name.len > MITOS_MAX_TYPE_FORMAT_BYTES) return false;
	output.append_string(descriptor.name);
	if (descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
	{
		output.append_string(" of (");
		foreach (index, parameter : descriptor.function_parameters)
		{
			if (index) output.append_string(", ");
			if (!append_type_id(registry, output, parameter, depth + 1)) return false;
		}
		output.append_string(") -> ");
		return append_type_id(registry, output, descriptor.function_result, depth + 1);
	}
	if (descriptor.kind != TYPE_DESCRIPTOR_INSTANCE) return true;
	output.append_string(" of ");
	if (descriptor.arguments.len > 1) output.append_string("(");
	foreach (index, argument : descriptor.arguments)
	{
		if (index) output.append_string(", ");
		if (!append_type_id(registry, output, argument, depth + 1)) return false;
	}
	if (descriptor.arguments.len > 1) output.append_string(")");
	return output.str_view().len <= MITOS_MAX_TYPE_FORMAT_BYTES;
}

fn String format_type(TypeRegistry* registry, TypeId id, Allocator allocator = mem)
{
	DString output;
	output.init(allocator);
	if (!append_type_id(registry, &output, id, 0))
	{
		output.free();
		return "<invalid or excessively deep type>".copy(allocator);
	}
	String result = output.copy_str(allocator);
	output.free();
	return result;
}

fn bool validate_runtime_annotation(
	TypeRegistry* registry,
	TypeId actual,
	TypeId expected,
	MitosDiagnostic* diagnostic,
	MitosSpan span = { }
)
{
	if (type_is_subtype(registry, actual, expected)) return true;
	String actual_name = format_type(registry, actual, registry.allocator);
	String expected_name = format_type(registry, expected, registry.allocator);
	DString message;
	message.init(registry.allocator);
	message.append_string("type assertion failed: expected ");
	message.append_string(expected_name);
	message.append_string(", received ");
	message.append_string(actual_name);
	diagnostic.init(registry.allocator, message.str_view(), span);
	message.free();
	alloc::free(registry.allocator, actual_name);
	alloc::free(registry.allocator, expected_name);
	return false;
}

fn bool type_of_metadata(
	TypeRegistry* registry,
	RuntimeTypeMetadata metadata,
	TypeValue* value,
	MitosDiagnostic* diagnostic,
	MitosSpan span = { }
)
{
	if (!type_id_is_valid(registry, metadata.type_id))
	{
		diagnostic.init(registry.allocator, "runtime value carries an invalid TypeId", span);
		return false;
	}
	TypeId runtime_type;
	if (!intern_type_value_type(registry, metadata.type_id, &runtime_type, diagnostic, span)) return false;
	*value = { .represented = metadata.type_id, .runtime_type = runtime_type };
	return true;
}

fn bool type_value_equal(TypeValue left, TypeValue right) => left.represented == right.represented;

fn bool type_parameter_occurs(TypeExpr* expression, TypeParameterDecl[] parameters)
{
	if (!expression) return false;
	if (expression.kind == TYPE_EXPR_NAMED)
	{
		foreach (&parameter : parameters) if (expression.name == parameter.name) return true;
	}
	foreach (&argument : expression.arguments)
	{
		if (type_parameter_occurs(argument.value, parameters)) return true;
	}
	return false;
}
fn bool validate_type_pattern_names(
	TypeRegistry* registry,
	TypeExpr* expression,
	TypeParameterDecl[] parameters,
	MitosDiagnostic* diagnostic
)
{
	if (!expression) return true;
	if (expression.kind == TYPE_EXPR_NAMED)
	{
		foreach (&parameter : parameters) if (expression.name == parameter.name) return true;
	}
	TypeId constructor = find_type(registry, expression.name);
	TypeDescriptor* descriptor = type_descriptor(registry, constructor);
	if (!descriptor)
	{
		diagnostic.init(registry.allocator, "unknown nominal type in parametric field layout", expression.span);
		return false;
	}
	if (expression.kind == TYPE_EXPR_NAMED)
	{
		if (!descriptor.arity) return true;
		diagnostic.init(registry.allocator, "parametric field type requires its declared 'of' arguments", expression.span);
		return false;
	}
	if (descriptor.arity != expression.arguments.len)
	{
		diagnostic.init(registry.allocator, "parametric field type application has the wrong arity", expression.span);
		return false;
	}
	foreach (&argument : expression.arguments)
	{
		if (!validate_type_pattern_names(registry, argument.value, parameters, diagnostic)) return false;
	}
	return true;
}

fn TypeRegistryBuildResult build_type_registry(
	Program* program,
	Allocator allocator = mem,
	usz max_types = MITOS_DEFAULT_MAX_TYPES
)
{
	TypeRegistryBuildResult result = { .allocator = allocator };
	result.registry = { .allocator = allocator, .max_types = max_types, .epoch = 1 };
	result.registry.descriptors.init(allocator);
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);
	if (max_types < (usz)TYPE_ID_FUNCTION || !type_registry_bootstrap(&result.registry))
	{
		MitosPosition origin = { .row = 1, .column = 1 };
		types_add_diagnostic(&diagnostics, allocator, "type registry capacity is smaller than the stable primitive range", {
			.start = origin, .end = origin,
		});
		result.diagnostics = diagnostics.to_array(allocator);
		diagnostics.free();
		return result;
	}
	foreach (&type_decl : program.types)
	{
		TypeId existing = find_type(&result.registry, type_decl.name);
		if (existing)
		{
			TypeDescriptor* primitive = type_descriptor(&result.registry, existing);
			TypeDescriptorKind declared_kind = type_decl.kind == TYPE_DECL_ABSTRACT
				? TYPE_DESCRIPTOR_ABSTRACT : TYPE_DESCRIPTOR_CONCRETE;
			if (existing <= TYPE_ID_FUNCTION && primitive.arity == type_decl.parameters.len
				&& primitive.kind == declared_kind)
			{
				primitive.span = type_decl.span;
				continue;
			}
			types_add_diagnostic(&diagnostics, allocator, "duplicate nominal type name", type_decl.span);
			continue;
		}
		String[] parameters = alloc::new_array(allocator, String, type_decl.parameters.len);
		foreach (index, &parameter : type_decl.parameters) parameters[index] = parameter.name.copy(allocator);
		if (!type_registry_append(&result.registry, {
			.kind = type_decl.kind == TYPE_DECL_ABSTRACT ? TYPE_DESCRIPTOR_ABSTRACT : TYPE_DESCRIPTOR_CONCRETE,
			.name = type_decl.name.copy(allocator),
			.parameters = parameters,
			.arity = type_decl.parameters.len,
			.span = type_decl.span,
		}))
		{
			types_add_diagnostic(&diagnostics, allocator, "type registry exhausted its bounded capacity", type_decl.span);
			break;
		}
	}
	foreach (&enum_decl : program.enums)
	{
		if (find_type(&result.registry, enum_decl.name))
		{
			types_add_diagnostic(&diagnostics, allocator, "duplicate or reserved enum type name", enum_decl.span);
			continue;
		}
		String[] parameters = alloc::new_array(allocator, String, enum_decl.parameters.len);
		foreach (index, &parameter : enum_decl.parameters) parameters[index] = parameter.name.copy(allocator);
		if (!type_registry_append(&result.registry, {
			.kind = TYPE_DESCRIPTOR_CONCRETE,
			.name = enum_decl.name.copy(allocator),
			.parameters = parameters,
			.nominal_parent = TYPE_ID_ANY,
			.arity = enum_decl.parameters.len,
			.span = enum_decl.span,
		}))
		{
			types_add_diagnostic(&diagnostics, allocator, "type registry exhausted its bounded capacity", enum_decl.span);
			break;
		}
	}
	foreach (&type_decl : program.types)
	{
		TypeId id = find_type(&result.registry, type_decl.name);
		TypeDescriptor* descriptor = type_descriptor(&result.registry, id);
		if (!descriptor) continue;
		descriptor.nominal_parent = TYPE_ID_ANY;
		if (type_decl.supertype)
		{
			TypeId parent = find_type(&result.registry, type_decl.supertype.name);
			TypeDescriptor* parent_descriptor = type_descriptor(&result.registry, parent);
			if (!parent_descriptor)
			{
				types_add_diagnostic(&diagnostics, allocator, "unknown nominal supertype", type_decl.supertype.span);
			}
			else if (parent_descriptor.kind != TYPE_DESCRIPTOR_ABSTRACT)
			{
				types_add_diagnostic(&diagnostics, allocator, "concrete types are final and cannot be nominal supertypes", type_decl.supertype.span);
			}
			else if (type_decl.supertype.arguments.len && type_decl.supertype.arguments.len != parent_descriptor.arity)
			{
				types_add_diagnostic(&diagnostics, allocator, "nominal supertype application has the wrong arity", type_decl.supertype.span);
			}
			else
			{
				descriptor.nominal_parent = parent;
			}
		}
		List{TypeFieldDescriptor} fields;
		fields.init(allocator);
		foreach (&field : type_decl.fields)
		{
			String pattern = format_type_expr(field.annotation.value, allocator);
			TypeId resolved = TYPE_ID_ANY;
			TypePattern structured = { };
			MitosDiagnostic diagnostic;
			if (!build_type_pattern(
				&result.registry, field.annotation.value, type_decl.parameters,
				&structured, &diagnostic, allocator
			))
			{
				diagnostics.push(diagnostic);
			}
			else if (!type_parameter_occurs(field.annotation.value, type_decl.parameters)
				&& !resolve_type_expr(&result.registry, field.annotation.value, &resolved, &diagnostic))
			{
				diagnostics.push(diagnostic);
			}
			fields.push({
				.name = field.name.copy(allocator),
				.type_pattern = pattern,
				.declared_type = resolved,
				.pattern = structured,
				.span = field.span,
			});
		}
		type_descriptor(&result.registry, id).fields = fields.to_array(allocator);
		fields.free();
	}
	foreach (&descriptor : result.registry.descriptors)
	{
		TypeId current = descriptor.nominal_parent;
		for (usz depth = 0; current; depth++)
		{
			if (depth >= (usz)result.registry.descriptors.len() || current == descriptor.id)
			{
				types_add_diagnostic(&diagnostics, allocator, "nominal type hierarchy contains a cycle", descriptor.span);
				break;
			}
			TypeDescriptor* parent = type_descriptor(&result.registry, current);
			if (!parent) break;
			current = parent.nominal_parent;
		}
	}
	result.diagnostics = diagnostics.to_array(allocator);
	diagnostics.free();
	return result;
}
