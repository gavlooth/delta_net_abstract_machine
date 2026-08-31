module delta_net_abstract_machine::mitos;

import std::collections::list;
import std::core::mem;
import std::io;

const usz MITOS_MAX_GENERIC_FUNCTIONS = 2_048;
const usz MITOS_MAX_METHODS = 8_192;
const usz MITOS_MAX_METHOD_VARIABLES = 256;

enum MethodTypePatternKind : char
{
	METHOD_PATTERN_ANY,
	METHOD_PATTERN_EXACT,
	METHOD_PATTERN_VARIABLE,
	METHOD_PATTERN_APPLICATION,
}

struct MethodTypePattern
{
	MethodTypePatternKind kind;
	String name;
	TypeId type_id;
	MethodTypePattern[] arguments;
	MitosSpan span;
}

struct MethodDescriptor
{
	usz function_index;
	MethodTypePattern[] parameters;
	MethodTypePattern result;
	String[] type_variables;
	usz source_order;
	MitosSpan span;
}

struct GenericFunction
{
	String name;
	usz arity;
	List{MethodDescriptor} methods;
	ulong epoch;
}

struct GenericFunctionTable
{
	Allocator allocator;
	List{GenericFunction} generics;
	usz max_generics;
	usz max_methods;
	usz method_count;
}

struct GenericFunctionBuildResult
{
	Allocator allocator;
	GenericFunctionTable table;
	MitosDiagnostic[] diagnostics;
}

struct TypeBinding
{
	String variable;
	TypeId type_id;
}

struct PatternVariableOccurrence
{
	String variable;
	ulong position;
	MethodTypePattern* pattern;
}

struct DispatchResult
{
	Allocator allocator;
	bool matched;
	usz generic_index;
	usz method_index;
	TypeBinding[] bindings;
	MitosDiagnostic diagnostic;
}

struct MethodInvalidation
{
	usz generic_index;
	ulong previous_epoch;
	ulong current_epoch;
}

fn bool GenericFunctionBuildResult.ok(&self) => self.diagnostics.len == 0;

fn void MethodTypePattern.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.name);
	foreach (&argument : self.arguments) argument.deinit(allocator);
	alloc::free(allocator, self.arguments);
	*self = { };
}

fn MethodTypePattern clone_method_pattern(MethodTypePattern* pattern, Allocator allocator)
{
	MethodTypePattern clone = {
		.kind = pattern.kind,
		.name = pattern.name.copy(allocator),
		.type_id = pattern.type_id,
		.span = pattern.span,
	};
	clone.arguments = alloc::new_array(allocator, MethodTypePattern, pattern.arguments.len);
	foreach (index, &argument : pattern.arguments)
		clone.arguments[index] = clone_method_pattern(argument, allocator);
	return clone;
}

fn void MethodDescriptor.deinit(&self, Allocator allocator)
{
	foreach (&parameter : self.parameters) parameter.deinit(allocator);
	alloc::free(allocator, self.parameters);
	self.result.deinit(allocator);
	foreach (variable : self.type_variables) alloc::free(allocator, variable);
	alloc::free(allocator, self.type_variables);
	*self = { };
}

fn void GenericFunctionTable.deinit(&self)
{
	if (!self.allocator) return;
	foreach (&generic : self.generics)
	{
		alloc::free(self.allocator, generic.name);
		foreach (&method : generic.methods) method.deinit(self.allocator);
		generic.methods.free();
	}
	self.generics.free();
	*self = { };
}

fn void GenericFunctionBuildResult.deinit(&self)
{
	if (!self.allocator) return;
	self.table.deinit();
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

fn void DispatchResult.deinit(&self)
{
	if (!self.allocator) return;
	foreach (&binding : self.bindings) alloc::free(self.allocator, binding.variable);
	alloc::free(self.allocator, self.bindings);
	self.diagnostic.deinit();
	*self = { };
}

fn void dispatch_add_diagnostic(
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

fn bool implicit_type_variable(String name) @private
{
	return name.len == 1 && name[0] >= 'A' && name[0] <= 'Z';
}

fn bool variable_exists(List{String}* variables, String name) @private
{
	foreach (variable : *variables) if (variable == name) return true;
	return false;
}

fn bool build_method_pattern(
	TypeRegistry* registry,
	TypeExpr* expression,
	MethodTypePattern* pattern,
	List{String}* variables,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	if (!expression)
	{
		*pattern = { .kind = METHOD_PATTERN_ANY, .type_id = TYPE_ID_ANY };
		return true;
	}
	TypeId named = find_type(registry, expression.name);
	if (!named && expression.kind == TYPE_EXPR_NAMED && implicit_type_variable(expression.name))
	{
		if (!variable_exists(variables, expression.name)) variables.push(expression.name.copy(allocator));
		*pattern = {
			.kind = METHOD_PATTERN_VARIABLE,
			.name = expression.name.copy(allocator),
			.span = expression.span,
		};
		return true;
	}
	if (!named)
	{
		dispatch_add_diagnostic(diagnostics, allocator, "unknown type in method signature", expression.span);
		return false;
	}
	TypeDescriptor* descriptor = type_descriptor(registry, named);
	if (expression.kind == TYPE_EXPR_NAMED)
	{
		if (descriptor.arity)
		{
			dispatch_add_diagnostic(diagnostics, allocator, "parametric method type requires its declared 'of' arguments", expression.span);
			return false;
		}
		*pattern = { .kind = named == TYPE_ID_ANY ? METHOD_PATTERN_ANY : METHOD_PATTERN_EXACT,
			.type_id = named, .span = expression.span };
		return true;
	}
	if (descriptor.arity != expression.arguments.len)
	{
		dispatch_add_diagnostic(diagnostics, allocator, "method type application has the wrong arity", expression.span);
		return false;
	}
	MethodTypePattern[] arguments = alloc::new_array(allocator, MethodTypePattern, expression.arguments.len);
	foreach (index, &argument : expression.arguments)
	{
		if (!build_method_pattern(registry, argument.value, &arguments[index], variables, diagnostics, allocator))
		{
			for (usz owned = 0; owned < (usz)index; owned++) arguments[owned].deinit(allocator);
			alloc::free(allocator, arguments);
			return false;
		}
	}
	*pattern = {
		.kind = METHOD_PATTERN_APPLICATION,
		.type_id = named,
		.arguments = arguments,
		.span = expression.span,
	};
	return true;
}

fn bool method_pattern_equal(MethodTypePattern* left, MethodTypePattern* right) @private
{
	if (left.kind != right.kind || left.type_id != right.type_id || left.name != right.name
		|| left.arguments.len != right.arguments.len) return false;
	foreach (index, &argument : left.arguments)
	{
		if (!method_pattern_equal(argument, &right.arguments[index])) return false;
	}
	return true;
}

fn bool method_pattern_alpha_equal(
	MethodTypePattern* left,
	MethodTypePattern* right,
	String[] left_variables,
	String[] right_variables,
	usz* variable_count
) @private
{
	if (left.kind != right.kind || left.type_id != right.type_id || left.arguments.len != right.arguments.len) return false;
	if (left.kind == METHOD_PATTERN_VARIABLE)
	{
		foreach (index, name : left_variables[:(sz)*variable_count])
		{
			if (name == left.name) return right_variables[index] == right.name;
			if (right_variables[index] == right.name) return false;
		}
		if (*variable_count >= left_variables.len) return false;
		left_variables[*variable_count] = left.name;
		right_variables[*variable_count] = right.name;
		(*variable_count)++;
		return true;
	}
	if (left.name != right.name) return false;
	foreach (index, &argument : left.arguments)
	{
		if (!method_pattern_alpha_equal(
			argument,
			&right.arguments[index],
			left_variables,
			right_variables,
			variable_count
		)) return false;
	}
	return true;
}

fn bool method_signature_equal_owned(MethodDescriptor* left, MethodDescriptor* right) @private
{
	if (left.parameters.len != right.parameters.len) return false;
	String[MITOS_MAX_METHOD_VARIABLES] left_variables;
	String[MITOS_MAX_METHOD_VARIABLES] right_variables;
	usz variable_count = 0;
	foreach (index, &parameter : left.parameters)
	{
		if (!method_pattern_alpha_equal(
			parameter,
			&right.parameters[index],
			left_variables[..],
			right_variables[..],
			&variable_count
		)) return false;
	}
	return true;
}

fn GenericFunction* find_generic(GenericFunctionTable* table, String name, usz arity, usz* index = null) @private
{
	foreach (generic_index, &generic : table.generics)
	{
		if (generic.name == name && generic.arity == arity)
		{
			if (index) *index = (usz)generic_index;
			return generic;
		}
	}
	return null;
}
fn bool method_pattern_contains_variable(MethodTypePattern* pattern, String name) @private
{
	if (pattern.kind == METHOD_PATTERN_VARIABLE) return pattern.name == name;
	foreach (&argument : pattern.arguments)
	{
		if (method_pattern_contains_variable(argument, name)) return true;
	}
	return false;
}


fn bool build_method_descriptor(
	Program* program,
	usz function_index,
	TypeRegistry* registry,
	MethodDescriptor* method,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	FunctionDecl* function = &program.functions[function_index];
	List{String} variables;
	variables.init(allocator);
	MethodTypePattern[] parameters = alloc::new_array(allocator, MethodTypePattern, function.parameters.len);
	foreach (index, parameter : function.parameters)
	{
		TypeExpr* annotation = index < function.parameter_annotations.len
			? function.parameter_annotations[index].value : null;
		if (!build_method_pattern(registry, annotation, &parameters[index], &variables, diagnostics, allocator))
		{
			for (usz owned = 0; owned < (usz)index; owned++) parameters[owned].deinit(allocator);
			alloc::free(allocator, parameters);
			foreach (variable : variables) alloc::free(allocator, variable);
			variables.free();
			return false;
		}
	}
	MethodTypePattern result_pattern;
	if (!build_method_pattern(registry, function.result.value, &result_pattern, &variables, diagnostics, allocator))
	{
		foreach (&parameter : parameters) parameter.deinit(allocator);
		alloc::free(allocator, parameters);
		foreach (variable : variables) alloc::free(allocator, variable);
		variables.free();
		return false;
	}
	foreach (variable : variables)
	{
		bool bound = false;
		foreach (&parameter : parameters)
		{
			if (method_pattern_contains_variable(parameter, variable)) bound = true;
		}
		if (!bound)
		{
			dispatch_add_diagnostic(diagnostics, allocator, "method result contains an unbound type variable", function.result.span);
			foreach (&parameter : parameters) parameter.deinit(allocator);
			alloc::free(allocator, parameters);
			result_pattern.deinit(allocator);
			foreach (owned_variable : variables) alloc::free(allocator, owned_variable);
			variables.free();
			return false;
		}
	}
	*method = {
		.function_index = function_index,
		.parameters = parameters,
		.result = result_pattern,
		.type_variables = variables.to_array(allocator),
		.source_order = function_index,
		.span = function.span,
	};
	variables.free();
	return true;
}

fn GenericFunctionBuildResult build_generic_function_table(
	Program* program,
	TypeRegistry* registry,
	Allocator allocator = mem,
	usz max_generics = MITOS_MAX_GENERIC_FUNCTIONS,
	usz max_methods = MITOS_MAX_METHODS
)
{
	GenericFunctionBuildResult result = { .allocator = allocator };
	result.table = { .allocator = allocator, .max_generics = max_generics, .max_methods = max_methods };
	result.table.generics.init(allocator);
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);
	foreach (function_index, &function : program.functions)
	{
		if (result.table.method_count >= max_methods)
		{
			dispatch_add_diagnostic(&diagnostics, allocator, "method table exhausted its bounded capacity", function.span);
			break;
		}
		foreach (&enum_decl : program.enums)
		{
			foreach (&variant : enum_decl.variants)
			{
				if (variant.name == function.name)
				{
					dispatch_add_diagnostic(&diagnostics, allocator, "generic function name collides with a constructor", function.span);
				}
			}
		}
		GenericFunction* generic = find_generic(&result.table, function.name, function.parameters.len);
		if (!generic)
		{
			if ((usz)result.table.generics.len() >= max_generics)
			{
				dispatch_add_diagnostic(&diagnostics, allocator, "generic function table exhausted its bounded capacity", function.span);
				break;
			}
			GenericFunction created = { .name = function.name.copy(allocator), .arity = function.parameters.len, .epoch = 1 };
			created.methods.init(allocator);
			result.table.generics.push(created);
			generic = &result.table.generics[result.table.generics.len() - 1];
		}
		MethodDescriptor method;
		if (!build_method_descriptor(program, (usz)function_index, registry, &method, &diagnostics, allocator)) continue;
		bool duplicate = false;
		foreach (&existing : generic.methods)
		{
			if (method_signature_equal_owned(existing, &method)) duplicate = true;
		}
		if (duplicate)
		{
			dispatch_add_diagnostic(&diagnostics, allocator, "duplicate method signature", function.span);
			method.deinit(allocator);
			continue;
		}
		generic.methods.push(method);
		result.table.method_count++;
	}
	result.diagnostics = diagnostics.to_array(allocator);
	diagnostics.free();
	return result;
}

fn sz find_binding_index(TypeBinding[] bindings, String variable) @private
{
	foreach (index, &binding : bindings) if (binding.variable == variable) return (sz)index;
	return -1;
}

fn bool unify_method_pattern(
	TypeRegistry* registry,
	MethodTypePattern* pattern,
	TypeId actual,
	TypeBinding[] bindings,
	usz* binding_count,
	String* conflict
) @private
{
	if (pattern.kind == METHOD_PATTERN_ANY) return type_id_is_valid(registry, actual);
	if (pattern.kind == METHOD_PATTERN_EXACT) return type_is_subtype(registry, actual, pattern.type_id);
	if (pattern.kind == METHOD_PATTERN_VARIABLE)
	{
		sz existing = find_binding_index(bindings[:(sz)*binding_count], pattern.name);
		if (existing >= 0)
		{
			if (bindings[(usz)existing].type_id == actual) return true;
			*conflict = pattern.name;
			return false;
		}
		if (*binding_count >= bindings.len) return false;
		bindings[*binding_count] = { .variable = pattern.name, .type_id = actual };
		(*binding_count)++;
		return true;
	}
	TypeDescriptor* actual_descriptor = type_descriptor(registry, actual);
	if (!actual_descriptor || actual_descriptor.kind != TYPE_DESCRIPTOR_INSTANCE
		|| actual_descriptor.arguments.len != pattern.arguments.len) return false;
	if (!type_is_subtype(registry, actual_descriptor.constructor, pattern.type_id)) return false;
	foreach (index, &argument : pattern.arguments)
	{
		if (!unify_method_pattern(registry, argument, actual_descriptor.arguments[index], bindings, binding_count, conflict))
		{
			return false;
		}
	}
	return true;
}

fn bool method_applicable(
	TypeRegistry* registry,
	MethodDescriptor* method,
	TypeId[] actual,
	TypeBinding[] bindings,
	usz* binding_count,
	String* conflict
) @private
{
	if (method.parameters.len != actual.len) return false;
	*binding_count = 0;
	*conflict = "";
	foreach (index, &pattern : method.parameters)
	{
		if (!unify_method_pattern(registry, pattern, actual[index], bindings, binding_count, conflict)) return false;
	}
	return true;
}

fn void collect_pattern_variables(
	MethodTypePattern* pattern,
	List{PatternVariableOccurrence}* occurrences,
	ulong parameter_prefix,
	usz* local_position
) @private
{
	ulong position = parameter_prefix | (ulong)(*local_position)++;
	occurrences.push({
		.variable = pattern.kind == METHOD_PATTERN_VARIABLE ? pattern.name : "",
		.position = position,
		.pattern = pattern,
	});
	foreach (&argument : pattern.arguments)
		collect_pattern_variables(argument, occurrences, parameter_prefix, local_position);
}

fn String variable_at_pattern_position(PatternVariableOccurrence[] occurrences, ulong position) @private
{
	foreach (&occurrence : occurrences) if (occurrence.position == position) return occurrence.variable;
	return "";
}

fn MethodTypePattern* pattern_at_position(
	PatternVariableOccurrence[] occurrences,
	ulong position
) @private
{
	foreach (&occurrence : occurrences) if (occurrence.position == position) return occurrence.pattern;
	return null;
}

fn bool pattern_has_variable(MethodTypePattern* pattern) @private
{
	if (pattern.kind == METHOD_PATTERN_VARIABLE) return true;
	foreach (&argument : pattern.arguments) if (pattern_has_variable(argument)) return true;
	return false;
}

fn bool ground_pattern_is_final(TypeRegistry* registry, MethodTypePattern* pattern) @private
{
	if (pattern.kind == METHOD_PATTERN_EXACT)
	{
		TypeDescriptor* descriptor = type_descriptor(registry, pattern.type_id);
		return descriptor && descriptor.kind == TYPE_DESCRIPTOR_CONCRETE
			&& descriptor.id != TYPE_ID_FUNCTION && descriptor.arity == 0;
	}
	if (pattern.kind != METHOD_PATTERN_APPLICATION) return false;
	TypeDescriptor* descriptor = type_descriptor(registry, pattern.type_id);
	if (!descriptor || descriptor.kind != TYPE_DESCRIPTOR_CONCRETE) return false;
	foreach (&argument : pattern.arguments)
		if (!ground_pattern_is_final(registry, argument)) return false;
	return true;
}

fn bool pattern_relation_exists(
	TypeRegistry* registry,
	PatternVariableOccurrence[] occurrences,
	ulong left,
	ulong right
) @private
{
	String left_variable = variable_at_pattern_position(occurrences, left);
	String right_variable = variable_at_pattern_position(occurrences, right);
	if (left_variable.len && left_variable == right_variable) return true;
	MethodTypePattern* left_pattern = pattern_at_position(occurrences, left);
	MethodTypePattern* right_pattern = pattern_at_position(occurrences, right);
	return left_pattern && right_pattern
		&& ground_pattern_is_final(registry, left_pattern)
		&& ground_pattern_is_final(registry, right_pattern)
		&& method_pattern_equal(left_pattern, right_pattern);
}

/** Compares equality constraints across the entire parameter tuple, not one slot at a time. */
fn bool tuple_relations_at_least_as_specific(
	MethodDescriptor* candidate,
	TypeRegistry* registry,
	MethodDescriptor* other,
	Allocator allocator,
	bool* strict
) @private
{
	List{PatternVariableOccurrence} candidate_occurrences;
	List{PatternVariableOccurrence} other_occurrences;
	candidate_occurrences.init(allocator);
	other_occurrences.init(allocator);
	defer candidate_occurrences.free();
	defer other_occurrences.free();
	foreach (index, &parameter : candidate.parameters)
	{
		usz local_position = 0;
		collect_pattern_variables(parameter, &candidate_occurrences, (ulong)index << 32, &local_position);
	}
	foreach (index, &parameter : other.parameters)
	{
		usz local_position = 0;
		collect_pattern_variables(parameter, &other_occurrences, (ulong)index << 32, &local_position);
	}

	foreach (left_index, &left : other_occurrences)
	{
		for (sz right_index = (sz)left_index + 1; right_index < other_occurrences.len(); right_index++)
		{
			PatternVariableOccurrence* right = &other_occurrences[right_index];
			if (!left.variable.len || left.variable != right.variable) continue;
			if (!pattern_relation_exists(registry, candidate_occurrences.array_view(), left.position, right.position)) return false;
		}
	}
	foreach (left_index, &left : candidate_occurrences)
	{
		for (sz right_index = (sz)left_index + 1; right_index < candidate_occurrences.len(); right_index++)
		{
			PatternVariableOccurrence* right = &candidate_occurrences[right_index];
			if (!left.variable.len || left.variable != right.variable) continue;
			if (!pattern_relation_exists(registry, other_occurrences.array_view(), left.position, right.position))
			{
				*strict = true;
				return true;
			}
		}
	}
	return true;
}

fn bool pattern_at_least_as_specific(
	TypeRegistry* registry,
	MethodTypePattern* candidate,
	MethodTypePattern* other,
	bool* strict
) @private
{
	if (method_pattern_equal(candidate, other)) return true;
	bool candidate_broad = candidate.kind == METHOD_PATTERN_ANY || candidate.kind == METHOD_PATTERN_VARIABLE;
	bool other_broad = other.kind == METHOD_PATTERN_ANY || other.kind == METHOD_PATTERN_VARIABLE;
	if (candidate_broad && other_broad) return true;
	if (other_broad)
	{
		*strict = true;
		return true;
	}
	if (candidate_broad) return false;
	if (candidate.kind == METHOD_PATTERN_EXACT && other.kind == METHOD_PATTERN_EXACT)
	{
		if (!type_is_subtype(registry, candidate.type_id, other.type_id)) return false;
		*strict = candidate.type_id != other.type_id;
		return true;
	}
	if (candidate.kind != METHOD_PATTERN_APPLICATION || other.kind != METHOD_PATTERN_APPLICATION
		|| candidate.arguments.len != other.arguments.len
		|| !type_is_subtype(registry, candidate.type_id, other.type_id)) return false;
	if (candidate.type_id != other.type_id) *strict = true;
	foreach (index, &argument : candidate.arguments)
	{
		if (!pattern_at_least_as_specific(registry, argument, &other.arguments[index], strict)) return false;
	}
	return true;
}

fn bool method_more_specific(
	TypeRegistry* registry,
	MethodDescriptor* candidate,
	MethodDescriptor* other
) @private
{
	if (candidate.parameters.len != other.parameters.len) return false;
	bool strict = false;
	foreach (index, &parameter : candidate.parameters)
	{
		if (!pattern_at_least_as_specific(registry, parameter, &other.parameters[index], &strict)) return false;
	}
	if (!tuple_relations_at_least_as_specific(candidate, registry, other, registry.allocator, &strict)) return false;
	return strict;
}

fn void append_concrete_tuple(TypeRegistry* registry, DString* message, TypeId[] actual) @private
{
	message.append_string("(");
	foreach (index, type : actual)
	{
		if (index) message.append_string(", ");
		String name = format_type(registry, type, registry.allocator);
		message.append_string(name);
		alloc::free(registry.allocator, name);

	}
	message.append_string(")");
}
fn void append_method_pattern(TypeRegistry* registry, DString* output, MethodTypePattern* pattern, usz depth = 0) @private
{
	if (depth >= MITOS_MAX_TYPE_FORMAT_DEPTH)
	{
		output.append_string("<deep>");
		return;
	}
	switch (pattern.kind)
	{
		case METHOD_PATTERN_ANY: output.append_string("Any");
		case METHOD_PATTERN_VARIABLE: output.append_string(pattern.name);
		case METHOD_PATTERN_EXACT:
			String name = format_type(registry, pattern.type_id, registry.allocator);
			output.append_string(name);
			alloc::free(registry.allocator, name);
		case METHOD_PATTERN_APPLICATION:
			TypeDescriptor* descriptor = type_descriptor(registry, pattern.type_id);
			output.append_string(descriptor ? descriptor.name : "<invalid>");
			output.append_string(" of ");
			if (pattern.arguments.len > 1) output.append_string("(");
			foreach (index, &argument : pattern.arguments)
			{
				if (index) output.append_string(", ");
				append_method_pattern(registry, output, argument, depth + 1);
			}
			if (pattern.arguments.len > 1) output.append_string(")");
		default:
	}
}

fn void append_method_signature(TypeRegistry* registry, DString* output, String name, MethodDescriptor* method) @private
{
	output.append_string(name);
	output.append_string("(");
	foreach (index, &parameter : method.parameters)
	{
		if (index) output.append_string(", ");
		append_method_pattern(registry, output, parameter);
	}
	output.append_string(")");
}

fn DispatchResult dispatch_method(
	GenericFunctionTable* table,
	TypeRegistry* registry,
	String name,
	TypeId[] actual,
	Allocator allocator = mem,
	MitosSpan span = { }
)
{
	DispatchResult result = { .allocator = allocator };
	usz generic_index;
	GenericFunction* generic = find_generic(table, name, actual.len, &generic_index);
	if (!generic)
	{
		DString message;
		message.init(allocator);
		message.append_string("MethodError: no generic function '");
		message.append_string(name);
		message.append_string("' for argument types ");
		append_concrete_tuple(registry, &message, actual);
		result.diagnostic.init(allocator, message.str_view(), span);
		message.free();
		return result;
	}
	usz[MITOS_MAX_METHODS] applicable;
	usz applicable_count = 0;
	String first_conflict = "";
	foreach (method_index, &method : generic.methods)
	{
		TypeBinding[MITOS_MAX_METHOD_VARIABLES] bindings;
		usz binding_count;
		String conflict;
		if (method_applicable(registry, method, actual, bindings[..], &binding_count, &conflict))
		{
			applicable[applicable_count++] = (usz)method_index;
		}
		else if (first_conflict.len == 0 && conflict.len) first_conflict = conflict;
	}
	if (!applicable_count)
	{
		DString message;
		message.init(allocator);
		message.append_string("MethodError: '");
		message.append_string(name);
		message.append_string("' has no method for ");
		append_concrete_tuple(registry, &message, actual);
		if (first_conflict.len)
		{
			message.append_string("; conflicting binding for type variable ");
			message.append_string(first_conflict);
		}
		result.diagnostic.init(allocator, message.str_view(), span);
		message.free();
		return result;
	}
	usz[MITOS_MAX_METHODS] maxima;
	usz maxima_count = 0;
	foreach (candidate_position, candidate_index : applicable[:(sz)applicable_count])
	{
		bool dominated = false;
		foreach (other_position, other_index : applicable[:(sz)applicable_count])
		{
			if (candidate_position == other_position) continue;
			if (method_more_specific(registry, &generic.methods[(sz)other_index], &generic.methods[(sz)candidate_index]))
			{
				dominated = true;
				break;
			}
		}
		if (!dominated) maxima[maxima_count++] = candidate_index;
	}
	if (maxima_count != 1)
	{
		DString message;
		message.init(allocator);
		message.append_string("AmbiguousMethodError: '");
		message.append_string(name);
		message.append_string("' has incomparable maximal candidates: ");
		foreach (index, method_index : maxima[:(sz)maxima_count])
		{
			if (index) message.append_string("; ");
			append_method_signature(registry, &message, name, &generic.methods[(sz)method_index]);
		}
		result.diagnostic.init(allocator, message.str_view(), span);
		message.free();
		return result;
	}
	usz selected = maxima[0];
	TypeBinding[MITOS_MAX_METHOD_VARIABLES] temporary;
	usz binding_count;
	String conflict;
	method_applicable(registry, &generic.methods[(sz)selected], actual, temporary[..], &binding_count, &conflict);
	TypeBinding[] owned = alloc::new_array(allocator, TypeBinding, (sz)binding_count);
	foreach (index, &binding : temporary[:(sz)binding_count])
	{
		owned[index] = { .variable = binding.variable.copy(allocator), .type_id = binding.type_id };
	}
	result.matched = true;
	result.generic_index = generic_index;
	result.method_index = selected;
	result.bindings = owned;
	return result;
}

fn bool resolve_method_result_type(
	TypeRegistry* registry,
	MethodDescriptor* method,
	TypeBinding[] bindings,
	TypeId* result
)
{
	MethodTypePattern* pattern = &method.result;
	if (pattern.kind == METHOD_PATTERN_ANY) { *result = TYPE_ID_ANY; return true; }
	if (pattern.kind == METHOD_PATTERN_EXACT) { *result = pattern.type_id; return true; }
	if (pattern.kind == METHOD_PATTERN_VARIABLE)
	{
		sz index = find_binding_index(bindings, pattern.name);
		if (index < 0) return false;
		*result = bindings[(usz)index].type_id;
		return true;
	}
	TypeId[] arguments = alloc::new_array(registry.allocator, TypeId, pattern.arguments.len);
	defer alloc::free(registry.allocator, arguments);
	foreach (index, &argument : pattern.arguments)
	{
		MethodDescriptor nested = { .result = *argument };
		if (!resolve_method_result_type(registry, &nested, bindings, &arguments[index])) return false;
	}
	return intern_type(registry, pattern.type_id, arguments, result);
}

fn bool bump_method_epoch(
	GenericFunctionTable* table,
	String name,
	usz arity,
	MethodInvalidation* invalidation
)
{
	usz index;
	GenericFunction* generic = find_generic(table, name, arity, &index);
	if (!generic) return false;
	ulong previous = generic.epoch;
	generic.epoch++;
	*invalidation = { .generic_index = index, .previous_epoch = previous, .current_epoch = generic.epoch };
	return true;
}
