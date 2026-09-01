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
struct PatternVariableOccurrence
{
	String variable;
	ulong position;
	usz variable_ordinal;
	MethodTypePattern* pattern;
}

struct MethodDescriptor
{
	SymbolKey key;
	SymbolKey generic_key;
	ModuleKey owner;
	usz function_index;
	MethodTypePattern[] parameters;
	MethodTypePattern result;
	String[] type_variables;
	usz source_order;
	PatternVariableOccurrence[] relation_positions;
	bool relations_ready;
	MitosSpan span;
}

struct GenericFunction
{
	SymbolKey key;
	ModuleKey owner;
	String name;
	usz arity;
	List{MethodDescriptor} methods;
	ulong epoch;
}

struct GenericFunctionTable
{
	Allocator allocator;
	ModuleKey module_key;
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
	/** O(1) source-function to accepted method location, indexed by FunctionDecl order. */
	usz[] generic_by_function;
	usz[] method_by_function;
}

struct TypeBinding
{
	String variable;
	TypeId type_id;
}

struct PatternUnificationTerm
{
	MethodTypePattern* pattern;
	bool right_side;
}

struct PatternUnificationBinding
{
	String variable;
	bool right_side;
	bool bound;
	PatternUnificationTerm value;
	TypeId nominal_head;
	bool requires_application;
	usz application_arity;
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
	self.key.deinit(allocator);
	self.generic_key.deinit(allocator);
	self.owner.deinit(allocator);
	foreach (&parameter : self.parameters) parameter.deinit(allocator);
	alloc::free(allocator, self.parameters);
	self.result.deinit(allocator);
	foreach (variable : self.type_variables) alloc::free(allocator, variable);
	alloc::free(allocator, self.relation_positions);
	alloc::free(allocator, self.type_variables);
	*self = { };
}

fn void GenericFunctionTable.deinit(&self)
{
	if (!self.allocator) return;
	self.module_key.deinit(self.allocator);
	foreach (&generic : self.generics)
	{
		generic.key.deinit(self.allocator);
		generic.owner.deinit(self.allocator);
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
	alloc::free(self.allocator, self.generic_by_function);
	alloc::free(self.allocator, self.method_by_function);
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

fn usz method_variable_ordinal(String[] variables, String name) @private
{
	foreach (index, variable : variables) if (variable == name) return (usz)index;
	return usz::max;
}

fn void append_length_prefixed_component(DString* output, String component)
{
	char[32] length;
	output.append_string((String)io::bprintf(&length, "%d:", (long)component.len)!!);
	output.append_string(component);
}

fn void append_canonical_method_pattern(
	TypeRegistry* registry,
	DString* output,
	MethodTypePattern* pattern,
	String[] variables
) @private
{
	switch (pattern.kind)
	{
		case METHOD_PATTERN_ANY:
			output.append_char('*');
		case METHOD_PATTERN_VARIABLE:
			char[32] ordinal;
			usz variable = method_variable_ordinal(variables, pattern.name);
			output.append_string((String)io::bprintf(&ordinal, "$%d", (long)variable)!!);
		case METHOD_PATTERN_EXACT:
			output.append_char('=');
			TypeDescriptor* exact = type_descriptor(registry, pattern.type_id);
			if (!exact)
			{
				append_length_prefixed_component(output, "<invalid>");
				return;
			}
			append_length_prefixed_component(output, exact.key.owner.canonical);
			append_length_prefixed_component(output, exact.key.name);
			append_length_prefixed_component(output, exact.key.canonical_signature);
		case METHOD_PATTERN_APPLICATION:
			output.append_char('@');
			TypeDescriptor* application = type_descriptor(registry, pattern.type_id);
			if (!application)
			{
				append_length_prefixed_component(output, "<invalid>");
				return;
			}
			append_length_prefixed_component(output, application.key.owner.canonical);
			append_length_prefixed_component(output, application.key.name);
			append_length_prefixed_component(output, application.key.canonical_signature);
			output.append_char('[');
			foreach (&argument : pattern.arguments)
			{
				append_canonical_method_pattern(registry, output, argument, variables);
				output.append_char(';');
			}
			output.append_char(']');
		default:
	}
}

fn String canonical_method_signature(
	TypeRegistry* registry,
	MethodTypePattern[] parameters,
	String[] variables,
	Allocator allocator
) @private
{
	DString signature;
	signature.init(allocator);
	signature.append_char('(');
	foreach (index, &parameter : parameters)
	{
		if (index) signature.append_char(',');
		append_canonical_method_pattern(registry, &signature, parameter, variables);
	}
	signature.append_char(')');
	String result = signature.copy_str(allocator);
	signature.free();
	return result;
}

fn GenericFunction* find_generic_by_key(
	GenericFunctionTable* table,
	SymbolKey* key,
	usz* index = null
)
{
	if (!table || !symbol_key_is_canonical(key)) return null;
	foreach (generic_index, &generic : table.generics)
	{
		if (!symbol_key_equal(&generic.key, key)) continue;
		if (index) *index = (usz)generic_index;
		return generic;
	}
	return null;
}

fn GenericFunction* find_generic(GenericFunctionTable* table, String name, usz arity, usz* index = null) @private
{
	foreach (generic_index, &generic : table.generics)
	{
		if (generic.name == name && generic.arity == arity
			&& (!table.module_key.canonical.len
				|| module_key_equal(&generic.key.owner, &table.module_key)))
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
	String[] owned_variables = variables.to_array(allocator);
	String signature = canonical_method_signature(
		registry, parameters, owned_variables, allocator
	);
	ModuleKey* method_owner = symbol_key_is_canonical(&function.key)
		? &function.key.owner : &program.module_key;
	SymbolKey generic_key = declaration_symbol_key(
		&function.generic_key, &program.module_key, SYMBOL_GENERIC,
		function.name, function.parameters.len, "", allocator
	);
	*method = {
		.key = symbol_key(
			method_owner, SYMBOL_METHOD, function.name,
			function.parameters.len, signature, allocator
		),
		.generic_key = clone_symbol_key(&generic_key, allocator),
		.owner = clone_module_key(method_owner, allocator),
		.function_index = function_index,
		.parameters = parameters,
		.result = result_pattern,
		.type_variables = owned_variables,
		.source_order = function_index,
		.span = function.span,
	};
	prepare_method_relations(method, allocator);
	generic_key.deinit(allocator);
	alloc::free(allocator, signature);
	function.key.deinit(program.allocator);
	function.key = clone_symbol_key(&method.key, program.allocator);
	variables.free();
	return true;
}

fn bool method_has_nominal_head_owned_by(
	MethodDescriptor* method,
	TypeRegistry* registry,
	ModuleKey* owner
) @private
{
	foreach (&parameter : method.parameters)
	{
		if (parameter.kind != METHOD_PATTERN_EXACT
			&& parameter.kind != METHOD_PATTERN_APPLICATION) continue;
		if (parameter.type_id == TYPE_ID_ANY) continue;
		TypeDescriptor* descriptor = type_descriptor(registry, parameter.type_id);
		if (descriptor && module_key_equal(&descriptor.key.owner, owner)) return true;
	}
	return false;
}

fn sz find_pattern_unification_binding(
	PatternUnificationBinding[] bindings,
	usz binding_count,
	PatternUnificationTerm variable
) @private
{
	foreach (index, &binding : bindings[:(sz)binding_count])
	{
		if (binding.right_side == variable.right_side
			&& binding.variable == variable.pattern.name) return (sz)index;
	}
	return -1;
}

fn bool overlap_term_contains_variable(
	PatternUnificationBinding[] bindings,
	usz binding_count,
	PatternUnificationTerm term,
	PatternUnificationTerm variable,
	usz depth
) @private
{
	if (depth > bindings.len) return true;
	if (term.pattern.kind == METHOD_PATTERN_VARIABLE)
	{
		if (term.right_side == variable.right_side
			&& term.pattern.name == variable.pattern.name) return true;
		sz index = find_pattern_unification_binding(bindings, binding_count, term);
		return index >= 0 && bindings[(usz)index].bound
			&& overlap_term_contains_variable(
				bindings, binding_count, bindings[(usz)index].value,
				variable, depth + 1
			);
	}
	foreach (&argument : term.pattern.arguments)
	{
		if (overlap_term_contains_variable(
			bindings, binding_count,
			{ .pattern = argument, .right_side = term.right_side },
			variable, depth + 1
		)) return true;
	}
	return false;
}

fn PatternUnificationTerm overlap_preferred_term(
	TypeRegistry* registry,
	PatternUnificationTerm left,
	PatternUnificationTerm right
) @private
{
	if (left.pattern.kind == METHOD_PATTERN_ANY) return right;
	if (right.pattern.kind == METHOD_PATTERN_ANY) return left;
	if (left.pattern.kind == METHOD_PATTERN_EXACT && right.pattern.kind == METHOD_PATTERN_EXACT)
	{
		return type_is_subtype(registry, left.pattern.type_id, right.pattern.type_id)
			? left : right;
	}
	if (left.pattern.kind == METHOD_PATTERN_APPLICATION
		&& right.pattern.kind == METHOD_PATTERN_APPLICATION)
	{
		return type_is_subtype(registry, left.pattern.type_id, right.pattern.type_id)
			? left : right;
	}
	if (left.pattern.kind == METHOD_PATTERN_APPLICATION) return left;
	if (right.pattern.kind == METHOD_PATTERN_APPLICATION) return right;
	return left;
}
fn bool overlap_constructor_exists(
	TypeRegistry* registry,
	TypeId left,
	TypeId right,
	usz arity
) @private
{
	foreach (&descriptor : registry.descriptors)
	{
		if (descriptor.kind == TYPE_DESCRIPTOR_INSTANCE
			|| descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE
			|| descriptor.arity != arity) continue;
		if (type_is_subtype(registry, descriptor.id, left)
			&& type_is_subtype(registry, descriptor.id, right)) return true;
	}
	return false;
}
fn bool merge_overlap_nominal_constraint(
	TypeRegistry* registry,
	PatternUnificationBinding* binding,
	PatternUnificationTerm term
) @private
{
	bool application = term.pattern.kind == METHOD_PATTERN_APPLICATION;
	if (!application && term.pattern.kind != METHOD_PATTERN_EXACT) return true;
	TypeId head = term.pattern.type_id;
	usz arity = application ? term.pattern.arguments.len : binding.application_arity;
	if (!binding.nominal_head)
	{
		binding.nominal_head = head;
		binding.requires_application = application;
		binding.application_arity = application ? term.pattern.arguments.len : 0;
		return true;
	}
	if (binding.requires_application && application
		&& binding.application_arity != term.pattern.arguments.len) return false;
	if (binding.requires_application || application)
	{
		arity = binding.requires_application
			? binding.application_arity : term.pattern.arguments.len;
		if (!overlap_constructor_exists(
			registry, binding.nominal_head, head, arity
		)) return false;
	}
	else if (!type_is_subtype(registry, binding.nominal_head, head)
		&& !type_is_subtype(registry, head, binding.nominal_head)) return false;
	if (type_is_subtype(registry, head, binding.nominal_head))
	{
		binding.nominal_head = head;
	}
	if (application)
	{
		binding.requires_application = true;
		binding.application_arity = term.pattern.arguments.len;
	}
	return true;
}




fn bool unify_overlap_terms(
	TypeRegistry* registry,
	PatternUnificationTerm left,
	PatternUnificationTerm right,
	PatternUnificationBinding[] bindings,
	usz* binding_count
) @private
{
	if (left.pattern.kind == METHOD_PATTERN_VARIABLE)
	{
		if (right.pattern.kind == METHOD_PATTERN_VARIABLE
			&& left.right_side == right.right_side
			&& left.pattern.name == right.pattern.name) return true;
		sz existing = find_pattern_unification_binding(bindings, *binding_count, left);
		if (existing >= 0 && bindings[(usz)existing].bound)
		{
			PatternUnificationTerm previous = bindings[(usz)existing].value;
			if (!merge_overlap_nominal_constraint(
				registry, &bindings[(usz)existing], right
			)) return false;
			if (!unify_overlap_terms(registry, previous, right, bindings, binding_count)) return false;
			bindings[(usz)existing].value = overlap_preferred_term(registry, previous, right);
			return true;
		}
		if (overlap_term_contains_variable(
			bindings, *binding_count, right, left, 0
		)) return false;
		if (existing < 0)
		{
			if (*binding_count >= bindings.len) return true;
			existing = (sz)(*binding_count);
			bindings[*binding_count] = {
				.variable = left.pattern.name,
				.right_side = left.right_side,
			};
			(*binding_count)++;
		}
		bindings[(usz)existing].bound = true;
		bindings[(usz)existing].value = right;
		if (!merge_overlap_nominal_constraint(
			registry, &bindings[(usz)existing], right
		)) return false;
		return true;
	}
	if (right.pattern.kind == METHOD_PATTERN_VARIABLE)
	{
		return unify_overlap_terms(registry, right, left, bindings, binding_count);
	}
	if (left.pattern.kind == METHOD_PATTERN_ANY || right.pattern.kind == METHOD_PATTERN_ANY) return true;
	if (left.pattern.kind == METHOD_PATTERN_EXACT && right.pattern.kind == METHOD_PATTERN_EXACT)
	{
		return type_is_subtype(registry, left.pattern.type_id, right.pattern.type_id)
			|| type_is_subtype(registry, right.pattern.type_id, left.pattern.type_id);
	}
	if (left.pattern.kind == METHOD_PATTERN_APPLICATION
		&& right.pattern.kind == METHOD_PATTERN_APPLICATION)
	{
		if (left.pattern.arguments.len != right.pattern.arguments.len
			|| !overlap_constructor_exists(
				registry, left.pattern.type_id, right.pattern.type_id,
				left.pattern.arguments.len
			)) return false;
		foreach (index, &argument : left.pattern.arguments)
		{
			if (!unify_overlap_terms(
				registry,
				{ .pattern = argument, .right_side = left.right_side },
				{ .pattern = &right.pattern.arguments[index], .right_side = right.right_side },
				bindings, binding_count
			)) return false;
		}
		return true;
	}
	MethodTypePattern* exact = left.pattern.kind == METHOD_PATTERN_EXACT
		? left.pattern : right.pattern;
	MethodTypePattern* application = left.pattern.kind == METHOD_PATTERN_APPLICATION
		? left.pattern : right.pattern;
	return overlap_constructor_exists(
		registry, application.type_id, exact.type_id, application.arguments.len
	);
}

fn bool method_tuples_overlap(
	TypeRegistry* registry,
	MethodDescriptor* left,
	MethodDescriptor* right
) @private
{
	if (left.parameters.len != right.parameters.len) return false;
	PatternUnificationBinding[MITOS_MAX_METHOD_VARIABLES * 2] bindings;
	usz binding_count = 0;
	foreach (index, &parameter : left.parameters)
	{
		if (!unify_overlap_terms(
			registry,
			{ .pattern = parameter },
			{ .pattern = &right.parameters[index], .right_side = true },
			bindings[..], &binding_count
		)) return false;
	}
	return true;
}

fn void dispatch_qualified_conflict(
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	String prefix,
	ModuleKey* left,
	ModuleKey* right,
	MitosSpan span
) @private
{
	DString message;
	message.init(allocator);
	message.append_string(prefix);
	message.append_string(" [");
	message.append_string(left.canonical);
	message.append_string(" vs ");
	message.append_string(right.canonical);
	message.append_char(']');
	dispatch_add_diagnostic(diagnostics, allocator, message.str_view(), span);
	message.free();
}

fn ulong dispatch_build_hash_string(ulong hash, String value) @private
{
	hash ^= (ulong)value.len;
	hash *= 1099511628211UL;
	foreach (byte : value)
	{
		hash ^= (ulong)byte;
		hash *= 1099511628211UL;
	}
	return hash;
}

fn ulong dispatch_build_hash_key(SymbolKey* key) @private
{
	ulong hash = dispatch_build_hash_string(
		1469598103934665603UL, key.owner.canonical
	);
	hash ^= (ulong)key.kind;
	hash *= 1099511628211UL;
	hash ^= (ulong)key.arity;
	hash *= 1099511628211UL;
	hash = dispatch_build_hash_string(hash, key.name);
	return dispatch_build_hash_string(hash, key.canonical_signature);
}

fn usz dispatch_build_index_capacity(usz count) @private
{
	usz target = count > usz::max / 2 ? usz::max : count * 2;
	usz capacity = 8;
	while (capacity < target)
	{
		if (capacity > usz::max / 2) return 0;
		capacity *= 2;
	}
	return capacity;
}

fn bool dispatch_constructor_name_insert(String[] slots, String name) @private
{
	if (!slots.len || !name.len) return false;
	usz mask = slots.len - 1;
	usz slot = (usz)dispatch_build_hash_string(1469598103934665603UL, name) & mask;
	for (usz probe = 0; probe < slots.len; probe++)
	{
		if (!slots[slot].len)
		{
			slots[slot] = name;
			return true;
		}
		if (slots[slot] == name) return true;
		slot = (slot + 1) & mask;
	}
	return false;
}

fn bool dispatch_constructor_name_contains(String[] slots, String name) @private
{
	if (!slots.len || !name.len) return false;
	usz mask = slots.len - 1;
	usz slot = (usz)dispatch_build_hash_string(1469598103934665603UL, name) & mask;
	for (usz probe = 0; probe < slots.len; probe++)
	{
		if (!slots[slot].len) return false;
		if (slots[slot] == name) return true;
		slot = (slot + 1) & mask;
	}
	return false;
}

fn sz dispatch_generic_index_lookup(
	GenericFunctionTable* table,
	usz[] slots,
	SymbolKey* key
) @private
{
	if (!slots.len || !symbol_key_is_canonical(key)) return -1;
	usz mask = slots.len - 1;
	usz slot = (usz)dispatch_build_hash_key(key) & mask;
	for (usz probe = 0; probe < slots.len; probe++)
	{
		usz stored = slots[slot];
		if (!stored) return -1;
		if (stored <= (usz)table.generics.len()
			&& symbol_key_equal(&table.generics[(sz)(stored - 1)].key, key))
		{
			return (sz)(stored - 1);
		}
		slot = (slot + 1) & mask;
	}
	return -1;
}

fn bool dispatch_generic_index_insert(
	GenericFunctionTable* table,
	usz[] slots,
	usz generic_index
) @private
{
	if (!slots.len || generic_index >= (usz)table.generics.len()) return false;
	SymbolKey* key = &table.generics[(sz)generic_index].key;
	usz mask = slots.len - 1;
	usz slot = (usz)dispatch_build_hash_key(key) & mask;
	for (usz probe = 0; probe < slots.len; probe++)
	{
		if (!slots[slot])
		{
			slots[slot] = generic_index + 1;
			return true;
		}
		slot = (slot + 1) & mask;
	}
	return false;
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
	result.table = {
		.allocator = allocator,
		.module_key = clone_module_key(&program.module_key, allocator),
		.max_generics = max_generics,
		.max_methods = max_methods,
	};
	result.table.generics.init(allocator);
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);
	result.generic_by_function = alloc::new_array(
		allocator, usz, program.functions.len
	);
	result.method_by_function = alloc::new_array(
		allocator, usz, program.functions.len
	);
	foreach (&index : result.generic_by_function) *index = usz::max;
	foreach (&index : result.method_by_function) *index = usz::max;
	usz generic_capacity = dispatch_build_index_capacity(max_generics);
	usz[] generic_slots = alloc::new_array(allocator, usz, (sz)generic_capacity);
	defer alloc::free(allocator, generic_slots);
	foreach (&slot : generic_slots) *slot = 0;
	usz constructor_count = 0;
	foreach (&enum_decl : program.enums)
		constructor_count += enum_decl.variants.len;
	usz constructor_capacity = dispatch_build_index_capacity(constructor_count);
	String[] constructor_names = alloc::new_array(
		allocator, String, (sz)constructor_capacity
	);
	defer alloc::free(allocator, constructor_names);
	foreach (&name : constructor_names) *name = "";
	foreach (&enum_decl : program.enums)
	{
		foreach (&variant : enum_decl.variants)
			(void)dispatch_constructor_name_insert(constructor_names, variant.name);
	}
	foreach (function_index, &function : program.functions)
	{
		if (result.table.method_count >= max_methods)
		{
			dispatch_add_diagnostic(&diagnostics, allocator, "method table exhausted its bounded capacity", function.span);
			break;
		}
		if (dispatch_constructor_name_contains(constructor_names, function.name))
		{
			dispatch_add_diagnostic(
				&diagnostics, allocator,
				"generic function name collides with a constructor", function.span
			);
		}
		SymbolKey generic_key = declaration_symbol_key(
			&function.generic_key, &program.module_key, SYMBOL_GENERIC,
			function.name, function.parameters.len, "", allocator
		);
		sz indexed_generic = dispatch_generic_index_lookup(
			&result.table, generic_slots, &generic_key
		);
		usz generic_index;
		GenericFunction* generic;
		if (indexed_generic < 0)
		{
			if ((usz)result.table.generics.len() >= max_generics)
			{
				generic_key.deinit(allocator);
				dispatch_add_diagnostic(&diagnostics, allocator, "generic function table exhausted its bounded capacity", function.span);
				break;
			}
			GenericFunction created = {
				.key = clone_symbol_key(&generic_key, allocator),
				.owner = clone_module_key(&generic_key.owner, allocator),
				.name = function.name.copy(allocator),
				.arity = function.parameters.len,
				.epoch = 1,
			};
			created.methods.init(allocator);
			result.table.generics.push(created);
			generic_index = (usz)result.table.generics.len() - 1;
			(void)dispatch_generic_index_insert(
				&result.table, generic_slots, generic_index
			);
		}
		else
		{
			generic_index = (usz)indexed_generic;
		}
		generic = &result.table.generics[(sz)generic_index];
		generic_key.deinit(allocator);
		MethodDescriptor method;
		if (!build_method_descriptor(
			program, (usz)function_index, registry, &method, &diagnostics, allocator
		)) continue;
		if (!symbol_key_equal(&method.generic_key, &generic.key))
		{
			dispatch_add_diagnostic(
				&diagnostics, allocator,
				"method contribution names an inconsistent canonical generic owner",
				function.span
			);
			method.deinit(allocator);
			continue;
		}
		if (!module_key_equal(&method.owner, &generic.owner)
			&& !method_has_nominal_head_owned_by(&method, registry, &method.owner))
		{
			dispatch_qualified_conflict(
				&diagnostics, allocator,
				"orphan method owner owns neither the generic nor a nominal parameter head",
				&method.owner, &generic.owner, function.span
			);
			method.deinit(allocator);
			continue;
		}
		bool rejected = false;
		foreach (&existing : generic.methods)
		{
			if (symbol_key_equal(&existing.key, &method.key)
				|| method_signature_equal_owned(existing, &method))
			{
				dispatch_qualified_conflict(
					&diagnostics, allocator, "duplicate canonical method signature",
					&existing.owner, &method.owner, function.span
				);
				rejected = true;
				break;
			}
			if (!module_key_equal(&existing.owner, &method.owner)
				&& method_tuples_overlap(registry, existing, &method)
				&& !method_more_specific(registry, existing, &method)
				&& !method_more_specific(registry, &method, existing))
			{
				dispatch_qualified_conflict(
					&diagnostics, allocator,
					"cross-owner methods have overlapping incomparable maxima",
					&existing.owner, &method.owner, function.span
				);
				rejected = true;
				break;
			}
		}
		if (rejected)
		{
			method.deinit(allocator);
			continue;
		}
		usz method_index = (usz)generic.methods.len();
		generic.methods.push(method);
		result.generic_by_function[(usz)function_index] = generic_index;
		result.method_by_function[(usz)function_index] = method_index;
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
fn void prepare_method_relations(
	MethodDescriptor* method,
	Allocator allocator
) @private
{
	if (method.relations_ready) return;
	List{PatternVariableOccurrence} occurrences;
	occurrences.init(allocator);
	foreach (index, &parameter : method.parameters)
	{
		usz local_position = 0;
		collect_pattern_variables(
			parameter, &occurrences, (ulong)index << 32, &local_position
		);
	}
	foreach (&occurrence : occurrences)
	{
		occurrence.variable_ordinal = occurrence.variable.len
			? method_variable_ordinal(method.type_variables, occurrence.variable)
			: usz::max;
	}
	method.relation_positions = occurrences.to_array(allocator);
	method.relations_ready = true;
	occurrences.free();
}

fn PatternVariableOccurrence* method_relation_position(
	MethodDescriptor* method,
	ulong position
) @private
{
	usz lower = 0;
	usz upper = method.relation_positions.len;
	while (lower < upper)
	{
		usz middle = lower + (upper - lower) / 2;
		ulong candidate = method.relation_positions[middle].position;
		if (candidate < position)
		{
			lower = middle + 1;
		}
		else
		{
			upper = middle;
		}
	}
	if (lower >= method.relation_positions.len
		|| method.relation_positions[lower].position != position) return null;
	return &method.relation_positions[lower];
}

fn bool method_positions_force_equal(
	MethodDescriptor* method,
	TypeRegistry* registry,
	ulong left_position,
	ulong right_position
) @private
{
	PatternVariableOccurrence* left = method_relation_position(method, left_position);
	PatternVariableOccurrence* right = method_relation_position(method, right_position);
	if (!left || !right) return false;
	if (left.variable_ordinal != usz::max
		&& left.variable_ordinal == right.variable_ordinal) return true;
	return ground_pattern_is_final(registry, left.pattern)
		&& ground_pattern_is_final(registry, right.pattern)
		&& method_pattern_equal(left.pattern, right.pattern);
}

fn bool method_variable_relations_satisfied(
	MethodDescriptor* required,
	MethodDescriptor* available,
	TypeRegistry* registry
) @private
{
	ulong[MITOS_MAX_METHOD_VARIABLES] first_positions;
	foreach (&position : first_positions) *position = ulong::max;
	foreach (&occurrence : required.relation_positions)
	{
		if (occurrence.variable_ordinal == usz::max) continue;
		if (occurrence.variable_ordinal >= MITOS_MAX_METHOD_VARIABLES) return false;
		ulong* first = &first_positions[occurrence.variable_ordinal];
		if (*first == ulong::max)
		{
			*first = occurrence.position;
			continue;
		}
		if (!method_positions_force_equal(
			available, registry, *first, occurrence.position
		)) return false;
	}
	return true;
}

/** Compares equality constraints across the entire parameter tuple. */
fn bool tuple_relations_at_least_as_specific(
	MethodDescriptor* candidate,
	TypeRegistry* registry,
	MethodDescriptor* other,
	bool* strict
) @private
{
	prepare_method_relations(candidate, registry.allocator);
	prepare_method_relations(other, registry.allocator);
	if (!method_variable_relations_satisfied(other, candidate, registry)) return false;
	if (!method_variable_relations_satisfied(candidate, other, registry)) *strict = true;
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
	if (candidate.kind == METHOD_PATTERN_APPLICATION && other.kind == METHOD_PATTERN_EXACT)
	{
		if (candidate.type_id == other.type_id
			|| !type_is_subtype(registry, candidate.type_id, other.type_id)) return false;
		*strict = true;
		return true;
	}
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
	if (!tuple_relations_at_least_as_specific(candidate, registry, other, &strict)) return false;
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
	MitosSpan span = { },
	SymbolKey* canonical_generic = null
)
{
	DispatchResult result = { .allocator = allocator };
	usz generic_index;
	GenericFunction* generic = canonical_generic
		? find_generic_by_key(table, canonical_generic, &generic_index)
		: find_generic(table, name, actual.len, &generic_index);
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
	usz selected = applicable[0];
	foreach (other_index : applicable[1:(sz)applicable_count])
	{
		if (method_more_specific(
			registry, &generic.methods[(sz)other_index], &generic.methods[(sz)selected]
		)) selected = other_index;
	}
	usz ambiguous = usz::max;
	foreach (other_index : applicable[:(sz)applicable_count])
	{
		if (other_index == selected || method_more_specific(
			registry, &generic.methods[(sz)selected], &generic.methods[(sz)other_index]
		)) continue;
		ambiguous = other_index;
		break;
	}
	if (ambiguous != usz::max)
	{
		foreach (other_index : applicable[:(sz)applicable_count])
		{
			if (other_index == selected || other_index == ambiguous) continue;
			if (method_more_specific(
				registry, &generic.methods[(sz)other_index], &generic.methods[(sz)ambiguous]
			)) ambiguous = other_index;
		}
		DString message;
		message.init(allocator);
		message.append_string("AmbiguousMethodError: '");
		message.append_string(name);
		message.append_string("' has incomparable maximal candidates: ");
		append_method_signature(registry, &message, name, &generic.methods[(sz)selected]);
		message.append_string("; ");
		append_method_signature(registry, &message, name, &generic.methods[(sz)ambiguous]);
		result.diagnostic.init(allocator, message.str_view(), span);
		message.free();
		return result;
	}
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


