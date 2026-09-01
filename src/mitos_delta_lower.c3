module delta_net_abstract_machine::mitos;

import std::collections::list;
import std::core::mem;

struct DeltaResumeScope
{
	DeltaResumeScope* parent;
	usz handler_index;
	EffectId effect;
	OperationId operation;
	bool multi;
	TypeId result_type;
	usz resume_count;
	usz next_resume;
}

struct DeltaLowerScope
{
	DeltaLowerScope* parent;
	String[] names;
	TypeId[] types;
	ResolvedEffectRow* effects;
	bool has_effect_context;
	DeltaResumeScope* resume;
	bool resume_barrier;
}

struct DeltaProgramLowerer
{
	Allocator allocator;
	Program* source;
	DeltaProgram* program;
	List{DeltaNode} nodes;
	EffectRegistry* effect_registry;
	EffectAnalysis* effect_analysis;
	List{DeltaEdge} edges;
	List{DeltaInterface} interfaces;
	List{DeltaParallelRegion} parallel_regions;
	List{MitosSpan} spans;
	List{MitosDiagnostic} diagnostics;
	usz parallel_order;
	usz next_source_order;
	List{DeltaHandlerDescriptor} handlers;
	usz handler_order;
}

fn void delta_lower_error(DeltaProgramLowerer* lowerer, String message, MitosSpan span) @private
{
	MitosDiagnostic diagnostic;
	diagnostic.init(lowerer.allocator, message, span);
	lowerer.diagnostics.push(diagnostic);
}

fn bool delta_scope_contains(DeltaLowerScope* scope, String name) @private
{
	for (DeltaLowerScope* current = scope; current; current = current.parent)
	{
		foreach (candidate : current.names) if (candidate == name) return true;
	}
	return false;
}

fn TypeId delta_scope_type(DeltaLowerScope* scope, String name) @private
{
	for (DeltaLowerScope* current = scope; current; current = current.parent)
	{
		foreach (index, candidate : current.names)
		{
			if (candidate == name)
			{
				return index < current.types.len ? current.types[index] : TYPE_ID_ANY;
			}
		}
	}
	return TYPE_ID_ANY;
}

fn TypeId delta_node_static_type(
	DeltaProgramLowerer* lowerer,
	DeltaNodeId node
) @private
{
	if (!node || (usz)node > (usz)lowerer.nodes.len()) return TYPE_ID_ANY;
	TypeId type_id = lowerer.nodes[(sz)((usz)node - 1)].static_type;
	return type_id ? type_id : TYPE_ID_ANY;
}

fn uint delta_record_span(DeltaProgramLowerer* lowerer, MitosSpan span) @private
{
	lowerer.spans.push(span);
	return (uint)lowerer.spans.len();
}

fn DeltaNodeId delta_append_node(DeltaProgramLowerer* lowerer, DeltaNode node) @private
{
	node.span = node.span ? node.span : delta_record_span(lowerer, { });
	node.stable_id = (uint)lowerer.nodes.len() + 1;
	lowerer.nodes.push(node);
	DeltaNodeId id = (DeltaNodeId)lowerer.nodes.len();
	foreach (input_index, input : node.inputs)
	{
		lowerer.edges.push({ .producer = input, .consumer = id, .input = (usz)input_index });
	}
	foreach (branch_index, &branch : node.branches)
	{
		lowerer.edges.push({
			.producer = branch.body,
			.consumer = id,
			.input = node.inputs.len + (usz)branch_index,
		});
	}
	return id;
}

fn DeltaNodeId delta_node_with_span(
	DeltaProgramLowerer* lowerer,
	DeltaNode node,
	MitosSpan span
) @private
{
	node.span = delta_record_span(lowerer, span);
	return delta_append_node(lowerer, node);
}

fn sz delta_constructor_index(DeltaProgram* program, String name) @private
{
	foreach (index, &constructor : program.constructors)
	{
		if (constructor.name == name
			&& module_key_equal(&constructor.key.owner, &program.module_key)) return (sz)index;
	}
	return -1;
}

fn sz delta_generic_index(DeltaProgram* program, String name, usz arity) @private
{
	foreach (index, &generic : program.methods.generics)
	{
		if (generic.name == name && generic.arity == arity
			&& module_key_equal(&generic.key.owner, &program.module_key)) return (sz)index;
	}
	return -1;
}

fn bool delta_implicit_type_variable(TypeExpr* expression) @private
{
	if (!expression) return false;
	if (expression.kind == TYPE_EXPR_NAMED && expression.name.len == 1
		&& expression.name[0] >= 'A' && expression.name[0] <= 'Z') return true;
	foreach (&argument : expression.arguments)
	{
		if (delta_implicit_type_variable(argument.value)) return true;
	}
	return false;
}

fn TypeId delta_resolve_annotation(
	DeltaProgramLowerer* lowerer,
	TypeAnnotation* annotation,
	bool permit_variable
) @private
{
	if (!annotation || !annotation.value) return TYPE_ID_ANY;
	if (permit_variable && delta_implicit_type_variable(annotation.value)) return TYPE_ID_ANY;
	TypeId result = TYPE_ID_ANY;
	MitosDiagnostic diagnostic;
	if (!resolve_type_expr(&lowerer.program.types, annotation.value, &result, &diagnostic))
	{
		lowerer.diagnostics.push(diagnostic);
		return TYPE_ID_ANY;
	}
	return result;
}

fn EffectId[] delta_current_effects(DeltaLowerScope* scope) @private
{
	for (DeltaLowerScope* current = scope; current; current = current.parent)
	{
		if (current.has_effect_context && current.effects)
		{
			return current.effects.required;
		}
	}
	return { };
}

fn ResolvedEffectRow delta_lambda_effects(
	DeltaProgramLowerer* lowerer,
	MitosSpan span
) @private
{
	foreach (&lambda : lowerer.effect_analysis.lambdas)
	{
		if (lambda.span.start.offset != span.start.offset
			|| lambda.span.end.offset != span.end.offset) continue;
		ResolvedEffectRow* row = lambda.has_assertion ? &lambda.asserted : &lambda.inferred;
		return clone_resolved_effect_row(row, lowerer.allocator);
	}
	delta_lower_error(lowerer, "lambda effect analysis metadata is missing", span);
	return { };
}

fn DeltaPrimitiveOp delta_primitive_for_binary(BinaryOperator operation) @private
{
	switch (operation)
	{
		case BINARY_ADD: return DELTA_PRIMITIVE_ADD;
		case BINARY_SUBTRACT: return DELTA_PRIMITIVE_SUBTRACT;
		case BINARY_MULTIPLY: return DELTA_PRIMITIVE_MULTIPLY;
		case BINARY_DIVIDE: return DELTA_PRIMITIVE_DIVIDE;
		case BINARY_REMAINDER: return DELTA_PRIMITIVE_REMAINDER;
		case BINARY_EQUAL: return DELTA_PRIMITIVE_EQUAL;
		case BINARY_LESS: return DELTA_PRIMITIVE_LESS;
		case BINARY_LESS_EQUAL: return DELTA_PRIMITIVE_LESS_EQUAL;
		case BINARY_GREATER: return DELTA_PRIMITIVE_GREATER;
		case BINARY_GREATER_EQUAL: return DELTA_PRIMITIVE_GREATER_EQUAL;
		default: return DELTA_PRIMITIVE_ADD;
	}
}

fn usz delta_primitive_descriptor(DeltaProgram* program, DeltaPrimitiveOp operation) @private
{
	foreach (index, &primitive : program.primitives)
	{
		if (primitive.operation == operation) return (usz)index;
	}
	return 0;
}

fn sz delta_effect_index(DeltaProgram* program, String name) @private
{
	foreach (index, &effect : program.effects.effects)
	{
		if (effect.name == name
			&& module_key_equal(&effect.key.owner, &program.module_key)) return (sz)index;
	}
	return -1;
}

fn sz delta_operation_index(DeltaProgram* program, EffectId effect, String name) @private
{
	foreach (index, &operation : program.effects.operations)
		if (operation.effect == effect && operation.name == name) return (sz)index;
	return -1;
}

fn usz delta_count_resumes(SurfaceExpr* expression, usz depth = 0) @private
{
	if (!expression || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH) return 0;
	switch (expression.kind)
	{
		case SURFACE_RESUME: return 1 + delta_count_resumes(expression.data.resume.value, depth + 1);
		case SURFACE_LAMBDA: return 0;
		case SURFACE_APPLICATION:
			usz count = delta_count_resumes(expression.data.application.callee, depth + 1);
			foreach (argument : expression.data.application.arguments) count += delta_count_resumes(argument, depth + 1);
			return count;
		case SURFACE_EFFECT_OPERATION:
			usz count = 0;
			foreach (argument : expression.data.effect_operation.arguments) count += delta_count_resumes(argument, depth + 1);
			return count;
		case SURFACE_BINARY:
			return delta_count_resumes(expression.data.binary.left, depth + 1)
				+ delta_count_resumes(expression.data.binary.right, depth + 1);
		case SURFACE_DEFINITION:
			return delta_count_resumes(expression.data.definition.value, depth + 1)
				+ delta_count_resumes(expression.data.definition.body, depth + 1);
		case SURFACE_MATCH:
			usz count = delta_count_resumes(expression.data.match_expr.scrutinee, depth + 1);
			usz arm_max = 0;
			foreach (&arm : expression.data.match_expr.arms)
			{
				usz arm_count = delta_count_resumes(arm.body, depth + 1);
				if (arm_count > arm_max) arm_max = arm_count;
			}
			return count + arm_max;
		case SURFACE_PARALLEL:
			usz count = delta_count_resumes(expression.data.parallel.result, depth + 1);
			foreach (&binding : expression.data.parallel.bindings) count += delta_count_resumes(binding.value, depth + 1);
			return count;
		case SURFACE_HANDLER:
			return delta_count_resumes(expression.data.handler.handled, depth + 1)
				+ delta_count_resumes(expression.data.handler.return_clause.body, depth + 1);
		default: return 0;
	}
}

fn DeltaResumeScope* delta_current_resume(DeltaLowerScope* scope) @private
{
	for (DeltaLowerScope* current = scope; current; current = current.parent)
	{
		if (current.resume) return current.resume;
		if (current.resume_barrier) return null;
	}
	return null;
}

fn bool delta_resume_blocked_by_lambda(DeltaLowerScope* scope) @private
{
	for (DeltaLowerScope* current = scope; current; current = current.parent)
	{
		if (current.resume) return false;
		if (current.resume_barrier) return true;
	}
	return false;
}

fn DeltaNodeId delta_lower_effect_operation(
	DeltaProgramLowerer* lowerer,
	SurfaceExpr* expression,
	DeltaLowerScope* scope
) @private
{
	EffectOperationExpr* performed = &expression.data.effect_operation;
	sz effect_index = delta_effect_index(lowerer.program, performed.effect_name);
	if (effect_index < 0)
	{
		delta_lower_error(lowerer, "unhandled effect names an unknown effect descriptor", expression.span);
		return DELTA_NODE_INVALID;
	}
	EffectId effect_constructor = lowerer.program.effects.effects[(usz)effect_index].id;
	sz operation_index = delta_operation_index(lowerer.program, effect_constructor, performed.operation_name);
	if (operation_index < 0)
	{
		delta_lower_error(lowerer, "performed effect is missing its operation descriptor", expression.span);
		return DELTA_NODE_INVALID;
	}
	EffectId concrete_effect;
	MitosDiagnostic effect_diagnostic;
	if (!resolve_effect_instance(
		lowerer.effect_registry, effect_constructor, delta_current_effects(scope),
		&concrete_effect, &effect_diagnostic, expression.span
	))
	{
		lowerer.diagnostics.push(effect_diagnostic);
		return DELTA_NODE_INVALID;
	}
	EffectOperationDescriptor* source_operation = find_effect_operation(
		lowerer.effect_registry, effect_constructor, performed.operation_name
	);
	if (!source_operation || source_operation.parameter_types.len != performed.arguments.len)
	{
		delta_lower_error(lowerer, "effect operation argument count does not match its descriptor", expression.span);
		return DELTA_NODE_INVALID;
	}
	TypeId[] resolved_types = alloc::new_array(lowerer.allocator, TypeId, performed.arguments.len + 1);
	if (!resolve_effect_operation_types(
		lowerer.effect_registry, &lowerer.program.types, source_operation, concrete_effect,
		resolved_types[:(sz)performed.arguments.len], &resolved_types[performed.arguments.len],
		&effect_diagnostic, expression.span
	))
	{
		lowerer.diagnostics.push(effect_diagnostic);
		alloc::free(lowerer.allocator, resolved_types);
		return DELTA_NODE_INVALID;
	}
	DeltaNodeId[] inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, (sz)performed.arguments.len);
	foreach (index, argument : performed.arguments)
		inputs[index] = delta_lower_expression(lowerer, argument, scope);
	return delta_node_with_span(lowerer, {
		.key = clone_symbol_key(
			&lowerer.program.effects.operations[(usz)operation_index].key,
			lowerer.allocator
		),
		.kind = DELTA_EFFECT,
		.static_type = resolved_types[performed.arguments.len],
		.result_type = resolved_types[performed.arguments.len],
		.descriptor = (usz)operation_index,
		.integer = (long)concrete_effect,
		.name = performed.operation_name.copy(lowerer.allocator),
		.types = resolved_types,
		.inputs = inputs,
	}, expression.span);
}

fn DeltaNodeId delta_lower_handler(
	DeltaProgramLowerer* lowerer,
	SurfaceExpr* expression,
	DeltaLowerScope* scope
) @private
{
	HandlerExpr* source = &expression.data.handler;
	usz handler_index = (usz)lowerer.handlers.len();
	lowerer.handlers.push({ });
	usz handler_order = lowerer.handler_order++;
	DeltaNodeId handled = delta_lower_expression(lowerer, source.handled, scope);
	DeltaHandlerClauseDescriptor[] clauses = alloc::new_array(
		lowerer.allocator, DeltaHandlerClauseDescriptor, (sz)source.clauses.len
	);
	DeltaNodeId[] inputs = alloc::new_array(
		lowerer.allocator, DeltaNodeId, (sz)source.clauses.len + 2
	);
	inputs[0] = handled;
	foreach (clause_index, &clause : source.clauses)
	{
		sz effect_index = delta_effect_index(lowerer.program, clause.effect_name);
		if (effect_index < 0)
		{
			delta_lower_error(lowerer, "handler clause names an unknown effect", clause.span);
			continue;
		}
		DeltaEffectDescriptor* effect = &lowerer.program.effects.effects[(usz)effect_index];
		sz operation_index = delta_operation_index(lowerer.program, effect.id, clause.operation_name);
		if (operation_index < 0)
		{
			delta_lower_error(lowerer, "handler is missing a matching operation clause descriptor", clause.span);
			continue;
		}
		EffectId concrete_effect;
		MitosDiagnostic effect_diagnostic;
		if (!resolve_effect_instance(
			lowerer.effect_registry, effect.id, delta_current_effects(scope),
			&concrete_effect, &effect_diagnostic, clause.span
		))
		{
			lowerer.diagnostics.push(effect_diagnostic);
			continue;
		}
		EffectOperationDescriptor* source_operation = find_effect_operation(
			lowerer.effect_registry, effect.id, clause.operation_name
		);
		if (!source_operation || source_operation.parameter_types.len != clause.parameters.len)
		{
			delta_lower_error(lowerer, "handler clause parameter count does not match the operation", clause.span);
			continue;
		}
		String[] parameters = alloc::new_array(lowerer.allocator, String, (sz)clause.parameters.len);
		TypeId[] parameter_types = alloc::new_array(lowerer.allocator, TypeId, (sz)clause.parameters.len);
		TypeId operation_result;
		if (!resolve_effect_operation_types(
			lowerer.effect_registry, &lowerer.program.types, source_operation, concrete_effect,
			parameter_types, &operation_result, &effect_diagnostic, clause.span
		))
		{
			lowerer.diagnostics.push(effect_diagnostic);
			alloc::free(lowerer.allocator, parameters);
			alloc::free(lowerer.allocator, parameter_types);
			continue;
		}
		foreach (parameter_index, parameter : clause.parameters)
			parameters[parameter_index] = parameter.copy(lowerer.allocator);
		usz resume_count = delta_count_resumes(clause.body);
		DeltaResumeScope resume = {
			.handler_index = handler_index,
			.effect = concrete_effect,
			.operation = source_operation.id,
			.multi = effect.multi,
			.result_type = operation_result,
			.resume_count = resume_count,
		};
		DeltaLowerScope clause_scope = {
			.parent = scope,
			.names = clause.parameters,
			.types = parameter_types,
			.resume = &resume,
		};
		DeltaNodeId body = delta_lower_expression(lowerer, clause.body, &clause_scope);
		if (!resume_count)
		{
			DeltaNodeId[] abort_inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, 1);
			abort_inputs[0] = body;
			body = delta_node_with_span(lowerer, {
				.key = clone_symbol_key(&source_operation.key, lowerer.allocator),
				.kind = DELTA_ABORT,
				.static_type = TYPE_ID_ANY,
				.descriptor = handler_index,
				.integer = (long)source_operation.id,
				.inputs = abort_inputs,
			}, clause.span);
		}
		inputs[(usz)clause_index + 1] = body;
		clauses[clause_index] = {
			.key = clone_symbol_key(&source_operation.key, lowerer.allocator),
			.stable_id = (uint)clause_index + 1,
			.effect = concrete_effect,
			.operation = source_operation.id,
			.parameters = parameters,
			.parameter_types = parameter_types,
			.result_type = operation_result,
			.body = body,
			.span = delta_record_span(lowerer, clause.span),
			.resume_count = resume_count,
			.multi = effect.multi,
		};
	}
	HandlerReturnClause* return_clause = &source.return_clause;
	TypeId return_type = delta_resolve_annotation(lowerer, &return_clause.annotation, true);
	if (!return_clause.annotation.value) return_type = delta_node_static_type(lowerer, handled);
	String[1] return_name = { return_clause.parameter };
	TypeId[1] return_types = { return_type };
	DeltaLowerScope return_scope = {
		.parent = scope,
		.names = return_name[..],
		.types = return_types[..],
	};
	DeltaNodeId return_body = delta_lower_expression(lowerer, return_clause.body, &return_scope);
	inputs[source.clauses.len + 1] = return_body;
	DeltaHandlerDescriptor handler = {
		.stable_id = (uint)handler_index + 1,
		.handled = handled,
		.clauses = clauses,
		.return_parameter = return_clause.parameter.copy(lowerer.allocator),
		.return_type = return_type,
		.return_body = return_body,
		.span = delta_record_span(lowerer, expression.span),
		.source_order = handler_order,
	};
	lowerer.handlers[(sz)handler_index] = handler;
	return delta_node_with_span(lowerer, {
		.kind = DELTA_HANDLER,
		.static_type = TYPE_ID_ANY,
		.descriptor = handler_index,
		.inputs = inputs,
	}, expression.span);
}

fn TypeId delta_known_node_type(DeltaProgramLowerer* lowerer, DeltaNodeId node_id) @private
{
	if (!node_id || (usz)node_id > (usz)lowerer.nodes.len()) return TYPE_ID_ANY;
	DeltaNode* node = &lowerer.nodes[(sz)node_id - 1];
	if (node.kind == DELTA_SUPERPOSE) return node.result_type;
	return node.runtime_type ? node.runtime_type : node.static_type;
}

fn TypeId delta_intern_unary_runtime_type(
	DeltaProgramLowerer* lowerer,
	TypeId constructor,
	TypeId argument,
	MitosSpan span
) @private
{
	TypeId[1] arguments = { argument };
	TypeId result;
	MitosDiagnostic diagnostic;
	if (!intern_type(
		&lowerer.program.types, constructor, arguments[..], &result, &diagnostic, span
	))
	{
		lowerer.diagnostics.push(diagnostic);
		return TYPE_ID_INVALID;
	}
	return result;
}

fn DeltaNodeId delta_lower_application(
	DeltaProgramLowerer* lowerer,
	SurfaceExpr* expression,
	DeltaLowerScope* scope
) @private
{
	ApplicationExpr* application = &expression.data.application;
	usz arity = application.arguments.len;
	if (application.callee && application.callee.kind == SURFACE_VARIABLE)
	{
		String name = application.callee.data.variable.name;
		sz constructor = delta_constructor_index(lowerer.program, name);
		if (constructor >= 0)
		{
			DeltaConstructorDescriptor* descriptor = &lowerer.program.constructors[(usz)constructor];
			if (descriptor.fields.len != arity)
			{
				delta_lower_error(lowerer, "constructor argument count does not match its field layout", expression.span);
				return DELTA_NODE_INVALID;
			}
			DeltaNodeId[] inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, (sz)arity);
			TypeId[] actual_fields = alloc::new_array(lowerer.allocator, TypeId, (sz)arity);
			defer alloc::free(lowerer.allocator, actual_fields);
			bool concrete_fields = true;
			foreach (index, argument : application.arguments)
			{
				inputs[index] = delta_lower_expression(lowerer, argument, scope);
				actual_fields[index] = delta_known_node_type(lowerer, inputs[index]);
				if (!type_id_is_valid(&lowerer.program.types, actual_fields[index])
					|| actual_fields[index] == TYPE_ID_ANY) concrete_fields = false;
			}
			TypeId runtime_type = descriptor.runtime_type;
			if (descriptor.parameters.len && concrete_fields)
			{
				MitosDiagnostic diagnostic;
				if (!infer_constructor_instance(
					&lowerer.program.types,
					descriptor.type_constructor,
					descriptor.parameters,
					descriptor.field_patterns,
					actual_fields,
					&runtime_type,
					&diagnostic,
					expression.span
				))
				{
					lowerer.diagnostics.push(diagnostic);
					runtime_type = TYPE_ID_INVALID;
				}
			}
			return delta_node_with_span(lowerer, {
				.key = clone_symbol_key(&descriptor.key, lowerer.allocator),
				.kind = DELTA_CONSTRUCTOR,
				.static_type = runtime_type ? runtime_type : TYPE_ID_ANY,
				.runtime_type = runtime_type,
				.descriptor = (usz)constructor,
				.inputs = inputs,
			}, expression.span);
		}
		if (name == "superpose")
		{
			if (!arity)
			{
				delta_lower_error(lowerer, "superpose requires at least one branch", expression.span);
				return DELTA_NODE_INVALID;
			}
			DeltaNodeId[] inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, (sz)arity);
			TypeId element_type = TYPE_ID_INVALID;
			foreach (index, argument : application.arguments)
			{
				inputs[index] = delta_lower_expression(lowerer, argument, scope);
				TypeId branch_type = delta_known_node_type(lowerer, inputs[index]);
				if (branch_type == TYPE_ID_ANY || branch_type == TYPE_ID_INVALID)
				{
					element_type = TYPE_ID_ANY;
					continue;
				}
				if (element_type == TYPE_ID_INVALID)
				{
					element_type = branch_type;
				}
				else if (element_type != TYPE_ID_ANY && element_type != branch_type)
				{
					delta_lower_error(
						lowerer,
						"superpose branches must have one concrete runtime type",
						argument.span
					);
					alloc::free(lowerer.allocator, inputs);
					return DELTA_NODE_INVALID;
				}
			}
			if (element_type == TYPE_ID_INVALID) element_type = TYPE_ID_ANY;
			TypeId runtime_type = delta_intern_unary_runtime_type(
				lowerer, TYPE_ID_SUPERPOSITION, element_type, expression.span
			);
			TypeId[1] types = { element_type };
			return delta_node_with_span(lowerer, {
				.kind = DELTA_SUPERPOSE,
				.static_type = runtime_type,
				.runtime_type = runtime_type,
				.result_type = element_type,
				.descriptor = (usz)lowerer.nodes.len() + 1,
				.types = alloc::clone_slice(lowerer.allocator, types[..]),
				.inputs = inputs,
			}, expression.span);
		}
		if (name == "collapse" && arity == 1)
		{
			DeltaNodeId[] inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, 1);
			inputs[0] = delta_lower_expression(lowerer, application.arguments[0], scope);
			TypeId input_type = delta_known_node_type(lowerer, inputs[0]);
			TypeId element_type = TYPE_ID_ANY;
			if (input_type != TYPE_ID_ANY && input_type != TYPE_ID_INVALID)
			{
				TypeDescriptor* descriptor = type_descriptor(&lowerer.program.types, input_type);
				if (descriptor && descriptor.constructor == TYPE_ID_SUPERPOSITION
					&& descriptor.arguments.len == 1)
				{
					element_type = descriptor.arguments[0];
				}
			}
			TypeId runtime_type = delta_intern_unary_runtime_type(
				lowerer, TYPE_ID_ARRAY, element_type, expression.span
			);
			TypeId[1] types = { element_type };
			return delta_node_with_span(lowerer, {
				.kind = DELTA_COLLAPSE,
				.static_type = runtime_type,
				.runtime_type = runtime_type,
				.result_type = element_type,
				.descriptor = (usz)lowerer.nodes.len() + 1,
				.types = alloc::clone_slice(lowerer.allocator, types[..]),
				.inputs = inputs,
			}, expression.span);
		}
		if (name == "collapse")
		{
			delta_lower_error(lowerer, "collapse expects exactly one argument", expression.span);
			return DELTA_NODE_INVALID;
		}
		if (name == "typeOf" && arity == 1)
		{
			DeltaNodeId[] inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, 1);
			inputs[0] = delta_lower_expression(lowerer, application.arguments[0], scope);
			return delta_node_with_span(lowerer, {
				.kind = DELTA_TYPE_OF, .static_type = TYPE_ID_TYPE, .inputs = inputs,
			}, expression.span);
		}
		if (name == "assertType" && arity == 2)
		{
			SurfaceExpr* type_expression = application.arguments[1];
			TypeId asserted = TYPE_ID_INVALID;
			if (!type_expression || type_expression.kind != SURFACE_VARIABLE)
			{
				delta_lower_error(lowerer, "assertType expects a nominal type as its second argument", expression.span);
				return DELTA_NODE_INVALID;
			}
			asserted = find_type(&lowerer.program.types, type_expression.data.variable.name);
			if (!asserted)
			{
				delta_lower_error(lowerer, "assertType names an unknown nominal type", type_expression.span);
				return DELTA_NODE_INVALID;
			}
			DeltaNodeId[] inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, 1);
			inputs[0] = delta_lower_expression(lowerer, application.arguments[0], scope);
			return delta_node_with_span(lowerer, {
				.kind = DELTA_TYPE_ASSERT, .static_type = asserted, .descriptor = (usz)asserted, .inputs = inputs,
			}, expression.span);
		}
		sz generic = delta_generic_index(lowerer.program, name, arity);
		if (generic >= 0 && !delta_scope_contains(scope, name))
		{
			DeltaNodeId[] inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, (sz)arity);
			foreach (index, argument : application.arguments) inputs[index] = delta_lower_expression(lowerer, argument, scope);
			GenericFunction* selected_generic = &lowerer.program.methods.generics[generic];
			return delta_node_with_span(lowerer, {
				.key = clone_symbol_key(&selected_generic.key, lowerer.allocator),
				.kind = DELTA_GENERIC_CALL,
				.static_type = TYPE_ID_ANY,
				.descriptor = (usz)generic,
				.name = name.copy(lowerer.allocator),
				.inputs = inputs,
			}, expression.span);
		}
	}
	DeltaNodeId[] inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, (sz)arity + 1);
	inputs[0] = delta_lower_expression(lowerer, application.callee, scope);
	foreach (index, argument : application.arguments)
		inputs[index + 1] = delta_lower_expression(lowerer, argument, scope);
	TypeId callee_type = delta_node_static_type(lowerer, inputs[0]);
	TypeDescriptor* callee_descriptor = type_descriptor(&lowerer.program.types, callee_type);
	ResolvedEffectRow application_effects = { };
	TypeId result_type = TYPE_ID_ANY;
	if (callee_descriptor && callee_descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
	{
		application_effects = clone_resolved_effect_row(
			&callee_descriptor.function_effects, lowerer.allocator
		);
		result_type = callee_descriptor.function_result;
	}
	return delta_node_with_span(lowerer, {
		.kind = DELTA_APPLY,
		.static_type = result_type,
		.result_type = result_type,
		.effect_row = application_effects,
		.inputs = inputs,
	}, expression.span);
}

fn TypeId[] delta_match_binding_types(
	DeltaProgramLowerer* lowerer,
	sz constructor_index,
	TypeId scrutinee_type,
	usz binding_count
) @private
{
	TypeId[] result = alloc::new_array(lowerer.allocator, TypeId, (sz)binding_count);
	foreach (&binding_type : result) *binding_type = TYPE_ID_ANY;
	if (constructor_index < 0) return result;
	DeltaConstructorDescriptor* constructor =
		&lowerer.program.constructors[(usz)constructor_index];
	foreach (index, field_type : constructor.field_types)
	{
		if ((usz)index >= binding_count) break;
		result[index] = field_type ? field_type : TYPE_ID_ANY;
	}
	if (!constructor.parameters.len) return result;
	TypeDescriptor* scrutinee = type_descriptor(&lowerer.program.types, scrutinee_type);
	if (!scrutinee || scrutinee.kind != TYPE_DESCRIPTOR_INSTANCE
		|| scrutinee.constructor != constructor.type_constructor
		|| scrutinee.arguments.len != constructor.parameters.len) return result;
	TypePatternBinding[] bindings = alloc::new_array(
		lowerer.allocator, TypePatternBinding, constructor.parameters.len
	);
	defer alloc::free(lowerer.allocator, bindings);
	foreach (index, parameter : constructor.parameters)
		bindings[index] = { .variable = parameter, .type_id = scrutinee.arguments[index] };
	foreach (index, &pattern : constructor.field_patterns)
	{
		if ((usz)index >= binding_count) break;
		TypeId instantiated = TYPE_ID_ANY;
		if (instantiate_type_pattern(
			&lowerer.program.types, pattern, bindings, &instantiated
		)) result[index] = instantiated;
	}
	return result;
}

fn DeltaNodeId delta_lower_match(
	DeltaProgramLowerer* lowerer,
	SurfaceExpr* expression,
	DeltaLowerScope* scope
) @private
{
	MatchExpr* match_expression = &expression.data.match_expr;
	DeltaNodeId[] inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, 1);
	inputs[0] = delta_lower_expression(lowerer, match_expression.scrutinee, scope);
	DeltaMatchBranch[] branches = alloc::new_array(lowerer.allocator, DeltaMatchBranch, (sz)match_expression.arms.len);
	DeltaResumeScope* resume = delta_current_resume(scope);
	usz resume_baseline = resume ? resume.next_resume : 0;
	usz resume_merged = resume_baseline;
	foreach (index, &arm : match_expression.arms)
	{
		if (resume) resume.next_resume = resume_baseline;
		bool wildcard = arm.pattern.kind == PATTERN_WILDCARD;
		sz constructor = wildcard ? -1 : delta_constructor_index(lowerer.program, arm.pattern.constructor);
		if (!wildcard && constructor < 0)
		{
			delta_lower_error(lowerer, "match arm names an unknown constructor", arm.span);
			continue;
		}
		String[] bindings = alloc::new_array(lowerer.allocator, String, (sz)arm.pattern.bindings.len);
		foreach (binding_index, binding : arm.pattern.bindings) bindings[binding_index] = binding.copy(lowerer.allocator);
		TypeId[] binding_types = delta_match_binding_types(
			lowerer,
			constructor,
			delta_known_node_type(lowerer, inputs[0]),
			arm.pattern.bindings.len
		);
		DeltaLowerScope arm_scope = {
			.parent = scope,
			.names = arm.pattern.bindings,
			.types = binding_types,
		};
		DeltaNodeId body = delta_lower_expression(lowerer, arm.body, &arm_scope);
		if (resume && resume.next_resume > resume_merged)
		{
			resume_merged = resume.next_resume;
		}
		alloc::free(lowerer.allocator, binding_types);
		branches[index] = {
			.wildcard = wildcard,
			.constructor = constructor < 0 ? uint::max : (uint)constructor,
			.bindings = bindings,
			.body = body,
			.span = delta_record_span(lowerer, arm.span),
		};
	}
	if (resume) resume.next_resume = resume_merged;
	return delta_node_with_span(lowerer, {
		.kind = DELTA_MATCH, .static_type = TYPE_ID_ANY, .inputs = inputs, .branches = branches,
	}, expression.span);
}

fn DeltaNodeId delta_lower_parallel(
	DeltaProgramLowerer* lowerer,
	SurfaceExpr* expression,
	DeltaLowerScope* scope
) @private
{
	ParallelExpr* parallel = &expression.data.parallel;
	usz region_order = lowerer.parallel_order++;
	usz first_root_order = lowerer.next_source_order;
	lowerer.next_source_order += parallel.bindings.len;
	DeltaNodeId[] roots = alloc::new_array(lowerer.allocator, DeltaNodeId, (sz)parallel.bindings.len);
	String[] names = alloc::new_array(lowerer.allocator, String, (sz)parallel.bindings.len);
	TypeId[] types = alloc::new_array(lowerer.allocator, TypeId, (sz)parallel.bindings.len);
	foreach (index, &binding : parallel.bindings)
	{
		DeltaNodeId[] root_input = alloc::new_array(lowerer.allocator, DeltaNodeId, 1);
		root_input[0] = delta_lower_expression(lowerer, binding.value, scope);
		TypeId annotation = delta_resolve_annotation(lowerer, &binding.annotation, false);
		if (!binding.annotation.value && root_input[0] && (usz)root_input[0] <= (usz)lowerer.nodes.len())
		{
			DeltaNode* inferred_root = &lowerer.nodes[(sz)root_input[0] - 1];
			annotation = inferred_root.runtime_type
				? inferred_root.runtime_type : inferred_root.static_type;
		}
		if (binding.annotation.value)
		{
			DeltaNodeId[] assertion_input = alloc::new_array(lowerer.allocator, DeltaNodeId, 1);
			assertion_input[0] = root_input[0];
			root_input[0] = delta_node_with_span(lowerer, {
				.kind = DELTA_TYPE_ASSERT, .static_type = annotation,
				.descriptor = (usz)annotation, .inputs = assertion_input,
			}, binding.span);
		}
		roots[index] = delta_node_with_span(lowerer, {
			.kind = DELTA_PARALLEL_ROOT,
			.static_type = annotation,
			.descriptor = first_root_order + (usz)index,
			.name = binding.name.copy(lowerer.allocator),
			.inputs = root_input,
		}, binding.span);
		names[index] = binding.name.copy(lowerer.allocator);
		types[index] = annotation;
	}
	DeltaLowerScope result_scope = { .parent = scope, .names = names, .types = types };
	DeltaNodeId result_body = delta_lower_expression(lowerer, parallel.result, &result_scope);
	DeltaNodeId[] join_inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, (sz)roots.len + 1);
	foreach (index, root : roots) join_inputs[index] = root;
	join_inputs[roots.len] = result_body;
	DeltaNodeId join = delta_node_with_span(lowerer, {
		.kind = DELTA_PARALLEL_JOIN,
		.static_type = TYPE_ID_ANY,
		.names = names,
		.types = types,
		.inputs = join_inputs,
		.descriptor = region_order,
	}, expression.span);
	DeltaNodeId[] region_roots = alloc::clone_slice(lowerer.allocator, roots);
	lowerer.parallel_regions.push({
		.roots = region_roots, .join = join, .source_order = region_order,
	});
	alloc::free(lowerer.allocator, roots);
	return join;
}

fn DeltaNodeId delta_lower_expression(
	DeltaProgramLowerer* lowerer,
	SurfaceExpr* expression,
	DeltaLowerScope* scope
) @private
{
	if (!expression)
	{
		delta_lower_error(lowerer, "cannot lower a missing expression", { });
		return DELTA_NODE_INVALID;
	}
	switch (expression.kind)
	{
		case SURFACE_VARIABLE:
			String name = expression.data.variable.name;
			if (delta_scope_contains(scope, name)) return delta_node_with_span(lowerer, {
				.kind = DELTA_LOCAL,
				.static_type = delta_scope_type(scope, name),
				.name = name.copy(lowerer.allocator),
			}, expression.span);
			sz constructor = delta_constructor_index(lowerer.program, name);
			if (constructor >= 0 && !lowerer.program.constructors[(usz)constructor].fields.len)
			{
				DeltaConstructorDescriptor* selected_constructor =
					&lowerer.program.constructors[(usz)constructor];
				return delta_node_with_span(lowerer, {
					.key = clone_symbol_key(&selected_constructor.key, lowerer.allocator),
					.kind = DELTA_CONSTRUCTOR,
					.static_type = selected_constructor.runtime_type
						? selected_constructor.runtime_type : TYPE_ID_ANY,
					.runtime_type = selected_constructor.runtime_type,
					.descriptor = (usz)constructor,
				}, expression.span);
			}
			TypeId type_id = find_type(&lowerer.program.types, name);
			if (type_id)
			{
				TypeId runtime_type;
				MitosDiagnostic diagnostic;
				if (!intern_type_value_type(
					&lowerer.program.types, type_id, &runtime_type, &diagnostic, expression.span
				))
				{
					lowerer.diagnostics.push(diagnostic);
					return DELTA_NODE_INVALID;
				}
				return delta_node_with_span(lowerer, {
					.kind = DELTA_TYPE_VALUE,
					.static_type = runtime_type,
					.runtime_type = runtime_type,
					.descriptor = (usz)type_id,
				}, expression.span);
			}
			sz zero_generic = delta_generic_index(lowerer.program, name, 0);
			if (zero_generic >= 0)
			{
				GenericFunction* selected_generic =
					&lowerer.program.methods.generics[(usz)zero_generic];
				return delta_node_with_span(lowerer, {
					.key = clone_symbol_key(&selected_generic.key, lowerer.allocator),
					.kind = DELTA_GENERIC_CALL,
					.static_type = TYPE_ID_ANY,
					.descriptor = (usz)zero_generic,
					.name = name.copy(lowerer.allocator),
				}, expression.span);
			}
			delta_lower_error(lowerer, "unbound name has no Delta semantic form", expression.span);
			return DELTA_NODE_INVALID;
		case SURFACE_INTEGER:
			return delta_node_with_span(lowerer, {
				.kind = DELTA_I64, .static_type = TYPE_ID_I64, .integer = expression.data.integer.value,
			}, expression.span);
		case SURFACE_STRING:
			return delta_node_with_span(lowerer, {
				.kind = DELTA_STRING,
				.static_type = TYPE_ID_STRING,
				.string_value = expression.data.string.value.copy(lowerer.allocator),
			}, expression.span);
		case SURFACE_LAMBDA:
			LambdaExpr* lambda = &expression.data.lambda;
			String[] parameters = alloc::new_array(lowerer.allocator, String, (sz)lambda.parameters.len);
			TypeId[] parameter_types = alloc::new_array(lowerer.allocator, TypeId, (sz)lambda.parameters.len);
			foreach (index, parameter : lambda.parameters)
			{
				parameters[index] = parameter.copy(lowerer.allocator);
				TypeAnnotation* parameter_annotation = index < lambda.parameter_annotations.len
					? &lambda.parameter_annotations[index] : null;
				parameter_types[index] = delta_resolve_annotation(lowerer, parameter_annotation, true);
			}
			TypeId result_type = delta_resolve_annotation(lowerer, &lambda.result, true);
			ResolvedEffectRow owned_effects = delta_lambda_effects(lowerer, expression.span);
			TypeId function_type;
			MitosDiagnostic function_diagnostic;
			if (!intern_function_type(
				&lowerer.program.types, lowerer.effect_registry,
				parameter_types, result_type, &owned_effects,
				&function_type, &function_diagnostic, expression.span
			))
			{
				lowerer.diagnostics.push(function_diagnostic);
				owned_effects.deinit(lowerer.allocator);
				foreach (parameter : parameters) alloc::free(lowerer.allocator, parameter);
				alloc::free(lowerer.allocator, parameters);
				alloc::free(lowerer.allocator, parameter_types);
				return DELTA_NODE_INVALID;
			}
			DeltaLowerScope lambda_scope = {
				.parent = scope,
				.names = lambda.parameters,
				.types = parameter_types,
				.effects = &owned_effects,
				.has_effect_context = true,
				.resume_barrier = true,
			};
			DeltaNodeId[] lambda_inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, 1);
			lambda_inputs[0] = delta_lower_expression(lowerer, lambda.body, &lambda_scope);
			return delta_node_with_span(lowerer, {
				.kind = DELTA_LAMBDA,
				.static_type = function_type,
				.runtime_type = function_type,
				.result_type = result_type,
				.names = parameters,
				.types = parameter_types,
				.effect_row = owned_effects,
				.inputs = lambda_inputs,
			}, expression.span);
		case SURFACE_APPLICATION:
			return delta_lower_application(lowerer, expression, scope);
		case SURFACE_BINARY:
			DeltaNodeId[] binary_inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, 2);
			binary_inputs[0] = delta_lower_expression(lowerer, expression.data.binary.left, scope);
			binary_inputs[1] = delta_lower_expression(lowerer, expression.data.binary.right, scope);
			DeltaPrimitiveOp operation = delta_primitive_for_binary(expression.data.binary.operator);
			bool comparison = operation >= DELTA_PRIMITIVE_EQUAL;
			return delta_node_with_span(lowerer, {
				.key = clone_symbol_key(
					&lowerer.program.primitives[
						delta_primitive_descriptor(lowerer.program, operation)
					].key,
					lowerer.allocator
				),
				.kind = DELTA_PRIMITIVE,
				.static_type = comparison ? TYPE_ID_BOOL : TYPE_ID_I64,
				.descriptor = delta_primitive_descriptor(lowerer.program, operation),
				.inputs = binary_inputs,
			}, expression.span);
		case SURFACE_DEFINITION:
			DefinitionExpr* definition = &expression.data.definition;
			DeltaNodeId value = delta_lower_expression(lowerer, definition.value, scope);
			TypeId annotation = delta_resolve_annotation(lowerer, &definition.annotation, false);
			if (definition.annotation.value)
			{
				DeltaNodeId[] assertion_input = alloc::new_array(lowerer.allocator, DeltaNodeId, 1);
				assertion_input[0] = value;
				value = delta_node_with_span(lowerer, {
					.kind = DELTA_TYPE_ASSERT, .static_type = annotation,
					.descriptor = (usz)annotation, .inputs = assertion_input,
				}, expression.span);
			}
			String[1] definition_name = { definition.name };
			TypeId[1] definition_type = { delta_node_static_type(lowerer, value) };
			DeltaLowerScope definition_scope = {
				.parent = scope,
				.names = definition_name[..],
				.types = definition_type[..],
			};
			DeltaNodeId[] let_inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, 2);
			let_inputs[0] = value;
			let_inputs[1] = delta_lower_expression(lowerer, definition.body, &definition_scope);
			String[] let_names = alloc::new_array(lowerer.allocator, String, 1);
			let_names[0] = definition.name.copy(lowerer.allocator);
			return delta_node_with_span(lowerer, {
				.kind = DELTA_LET, .static_type = TYPE_ID_ANY, .names = let_names, .inputs = let_inputs,
			}, expression.span);
		case SURFACE_MATCH:
			return delta_lower_match(lowerer, expression, scope);
		case SURFACE_PARALLEL:
			return delta_lower_parallel(lowerer, expression, scope);
		case SURFACE_EFFECT_OPERATION:
			return delta_lower_effect_operation(lowerer, expression, scope);
		case SURFACE_HANDLER:
			return delta_lower_handler(lowerer, expression, scope);
		case SURFACE_RESUME:
			DeltaResumeScope* resume = delta_current_resume(scope);
			if (!resume)
			{
				delta_lower_error(
					lowerer,
					delta_resume_blocked_by_lambda(scope)
						? "resume cannot escape its operation handler clause through a lambda"
						: "invalid resume outside an operation handler clause",
					expression.span
				);
				return DELTA_NODE_INVALID;
			}
			if (!resume.multi && resume.next_resume)
			{
				delta_lower_error(lowerer, "one-shot effect continuation is resumed more than once", expression.span);
				return DELTA_NODE_INVALID;
			}
			DeltaNodeId[] resume_inputs = alloc::new_array(lowerer.allocator, DeltaNodeId, 1);
			resume_inputs[0] = delta_lower_expression(lowerer, expression.data.resume.value, scope);
			TypeId[] resume_types = alloc::new_array(lowerer.allocator, TypeId, 1);
			resume_types[0] = resume.result_type;
			return delta_node_with_span(lowerer, {
				.kind = DELTA_RESUME,
				.static_type = TYPE_ID_ANY,
				.result_type = resume.result_type,
				.descriptor = resume.handler_index,
				.integer = (long)resume.next_resume++,
				.types = resume_types,
				.inputs = resume_inputs,
			}, expression.span);
		default:
			delta_lower_error(lowerer, "expression has no Delta semantic form", expression.span);
			return DELTA_NODE_INVALID;
	}
}

fn DeltaPrimitiveDescriptor[] delta_build_primitives(Allocator allocator) @private
{
	ModuleKey core = { .canonical = MITOS_CORE_MODULE_CANONICAL };
	String[10] names = {
		"add", "subtract", "multiply", "divide", "remainder",
		"equal", "less", "lessEqual", "greater", "greaterEqual",
	};
	DeltaPrimitiveDescriptor[] primitives = alloc::new_array(
		allocator, DeltaPrimitiveDescriptor, 10
	);
	foreach (index, name : names)
	{
		TypeId[] parameters = alloc::new_array(allocator, TypeId, 2);
		parameters[0] = TYPE_ID_I64;
		parameters[1] = TYPE_ID_I64;
		primitives[index] = {
			.key = symbol_key(&core, SYMBOL_FUNCTION, name, 2, "primitive", allocator),
			.id = (uint)index + 1,
			.operation = (DeltaPrimitiveOp)index,
			.name = name.copy(allocator),
			.arity = 2,
			.parameters = parameters,
			.result = index >= 5 ? TYPE_ID_BOOL : TYPE_ID_I64,
		};
	}
	return primitives;
}

fn DeltaConstructorDescriptor[] delta_build_constructors(
	DeltaProgramLowerer* lowerer
) @private
{
	usz count = 0;
	foreach (&enum_decl : lowerer.source.enums) count += enum_decl.variants.len;
	foreach (&type_decl : lowerer.source.types)
		if (type_decl.kind == TYPE_DECL_CONCRETE) count++;
	DeltaConstructorDescriptor[] constructors = alloc::new_array(
		lowerer.allocator, DeltaConstructorDescriptor, (sz)count
	);
	usz cursor = 0;
	foreach (&enum_decl : lowerer.source.enums)
	{
		TypeId constructor_type = find_type_by_key(&lowerer.program.types, &enum_decl.key);
		foreach (&variant : enum_decl.variants)
		{
			String[] parameters = alloc::new_array(
				lowerer.allocator, String, enum_decl.parameters.len
			);
			foreach (index, &parameter : enum_decl.parameters)
				parameters[index] = parameter.name.copy(lowerer.allocator);
			String[] fields = alloc::new_array(
				lowerer.allocator, String, (sz)variant.parameters.len
			);
			TypeId[] field_types = alloc::new_array(
				lowerer.allocator, TypeId, (sz)variant.parameters.len
			);
			TypePattern[] field_patterns = alloc::new_array(
				lowerer.allocator, TypePattern, (sz)variant.parameters.len
			);
			foreach (index, parameter : variant.parameters)
			{
				fields[index] = parameter.copy(lowerer.allocator);
				TypeExpr* annotation = index < variant.parameter_annotations.len
					? variant.parameter_annotations[index].value : null;
				MitosDiagnostic diagnostic;
				if (!build_type_pattern(
					&lowerer.program.types, annotation, enum_decl.parameters,
					&field_patterns[index], &diagnostic, lowerer.allocator
				)) lowerer.diagnostics.push(diagnostic);
				if (!type_parameter_occurs(annotation, enum_decl.parameters))
				{
					TypeAnnotation* field_annotation = index < variant.parameter_annotations.len
						? &variant.parameter_annotations[index] : null;
					field_types[index] = delta_resolve_annotation(
						lowerer, field_annotation, false
					);
				}
				else
				{
					field_types[index] = TYPE_ID_ANY;
				}
			}
			constructors[cursor] = {
				.key = clone_symbol_key(&variant.key, lowerer.allocator),
				.id = (uint)cursor + 1,
				.name = variant.name.copy(lowerer.allocator),
				.runtime_type = enum_decl.parameters.len ? TYPE_ID_INVALID : constructor_type,
				.type_constructor = constructor_type,
				.parameters = parameters,
				.fields = fields,
				.field_types = field_types,
				.field_patterns = field_patterns,
				.span = variant.span,
			};
			cursor++;
		}
	}
	foreach (&type_decl : lowerer.source.types)
	{
		if (type_decl.kind != TYPE_DECL_CONCRETE) continue;
		TypeId constructor_type = find_type_by_key(&lowerer.program.types, &type_decl.key);
		if (!constructor_type)
		{
			TypeId reserved = find_type(&lowerer.program.types, type_decl.name);
			if (reserved <= TYPE_ID_SUPERPOSITION) constructor_type = reserved;
		}
		TypeDescriptor* type = type_descriptor(&lowerer.program.types, constructor_type);
		String[] parameters = alloc::new_array(
			lowerer.allocator, String, type_decl.parameters.len
		);
		foreach (index, &parameter : type_decl.parameters)
			parameters[index] = parameter.name.copy(lowerer.allocator);
		String[] fields = alloc::new_array(
			lowerer.allocator, String, (sz)type_decl.fields.len
		);
		TypeId[] field_types = alloc::new_array(
			lowerer.allocator, TypeId, (sz)type_decl.fields.len
		);
		TypePattern[] field_patterns = alloc::new_array(
			lowerer.allocator, TypePattern, (sz)type_decl.fields.len
		);
		foreach (index, &field : type_decl.fields)
		{
			fields[index] = field.name.copy(lowerer.allocator);
			field_types[index] = type && index < type.fields.len
				? type.fields[index].declared_type : TYPE_ID_ANY;
			if (type && index < type.fields.len)
			{
				field_patterns[index] = clone_type_pattern(
					&type.fields[index].pattern, lowerer.allocator
				);
			}
		}
		constructors[cursor] = {
			.key = clone_symbol_key(&type_decl.key, lowerer.allocator),
			.id = (uint)cursor + 1,
			.name = type_decl.name.copy(lowerer.allocator),
			.runtime_type = type_decl.parameters.len ? TYPE_ID_INVALID : constructor_type,
			.type_constructor = constructor_type,
			.parameters = parameters,
			.fields = fields,
			.field_types = field_types,
			.field_patterns = field_patterns,
			.span = type_decl.span,
		};
		cursor++;
	}
	return constructors;
}

fn DeltaEffectHostKind delta_effect_host_kind(EffectHostPolicy policy) @private
{
	switch (policy)
	{
		case EFFECT_HOST_ORDERED: return DELTA_EFFECT_ORDERED;
		case EFFECT_HOST_EXTERNAL: return DELTA_EFFECT_EXTERNAL;
		default: return DELTA_EFFECT_PURE;
	}
}

fn void delta_copy_effect_section(
	DeltaProgramLowerer* lowerer,
	EffectRegistry* registry,
	EffectAnalysis* analysis
) @private
{
	DeltaEffectSection* section = &lowerer.program.effects;
	section.epoch = registry.epoch;
	section.next_effect_id = (EffectId)(
		(usz)registry.effects.len() + (usz)registry.instances.len() + 1
	);
	section.next_operation_id = registry.next_operation_id;
	section.effects = alloc::new_array(
		lowerer.allocator, DeltaEffectDescriptor, (sz)registry.effects.len()
	);
	usz operation_count = 0;
	foreach (&effect : registry.effects) operation_count += effect.operations.len;
	section.operations = alloc::new_array(
		lowerer.allocator, DeltaOperationDescriptor, (sz)operation_count
	);
	usz operation_cursor = 0;
	foreach (effect_index, &effect : registry.effects)
	{
		String[] parameters = alloc::new_array(
			lowerer.allocator, String, (sz)effect.parameters.len
		);
		foreach (index, parameter : effect.parameters)
			parameters[index] = parameter.copy(lowerer.allocator);
		OperationId[] operations = alloc::new_array(
			lowerer.allocator, OperationId, (sz)effect.operations.len
		);
		foreach (index, &operation : effect.operations)
		{
			operations[index] = operation.id;
			String[] patterns = alloc::new_array(
				lowerer.allocator, String, (sz)operation.parameter_patterns.len
			);
			foreach (pattern_index, pattern : operation.parameter_patterns)
				patterns[pattern_index] = pattern.copy(lowerer.allocator);
			TypePattern[] parameter_types = alloc::new_array(
				lowerer.allocator, TypePattern, operation.parameter_types.len
			);
			foreach (pattern_index, &pattern : operation.parameter_types)
				parameter_types[pattern_index] = clone_type_pattern(
					pattern, lowerer.allocator
				);
			DeltaEffectHostKind host_kind = delta_effect_host_kind(operation.host_policy);
			section.operations[operation_cursor++] = {
				.key = clone_symbol_key(&operation.key, lowerer.allocator),
				.id = operation.id,
				.effect = operation.effect,
				.name = operation.name.copy(lowerer.allocator),
				.parameter_patterns = patterns,
				.parameter_types = parameter_types,
				.result_pattern = operation.result_pattern.copy(lowerer.allocator),
				.result_type = clone_type_pattern(
					&operation.result_type, lowerer.allocator
				),
				.span = delta_record_span(lowerer, effect.span),
				.host_kind = host_kind,
				.ordered = host_kind != DELTA_EFFECT_PURE,
			};
		}
		section.effects[effect_index] = {
			.key = clone_symbol_key(&effect.key, lowerer.allocator),
			.id = effect.id,
			.name = effect.name.copy(lowerer.allocator),
			.multi = effect.multi,
			.parameters = parameters,
			.operations = operations,
			.span = delta_record_span(lowerer, effect.span),
		};
	}
	section.instances = alloc::new_array(
		lowerer.allocator, DeltaEffectInstanceDescriptor, (sz)registry.instances.len()
	);
	foreach (index, &instance : registry.instances)
	{
		section.instances[index] = {
			.key = clone_symbol_key(&instance.key, lowerer.allocator),
			.id = instance.id,
			.constructor = instance.constructor,
			.arguments = alloc::clone_slice(lowerer.allocator, instance.arguments),
		};
	}
	section.rows = alloc::new_array(
		lowerer.allocator, DeltaEffectRowDescriptor, (sz)analysis.methods.len
	);
	foreach (index, &row : analysis.methods)
	{
		section.rows[index] = {
			.key = row.function_index < lowerer.source.functions.len
				? clone_symbol_key(
					&lowerer.source.functions[row.function_index].key, lowerer.allocator
				) : (SymbolKey){},
			.function_index = row.function_index,
			.inferred = clone_resolved_effect_row(&row.inferred, lowerer.allocator),
			.asserted = clone_resolved_effect_row(&row.asserted, lowerer.allocator),
			.has_assertion = row.has_assertion,
			.effect_epoch = analysis.effect_epoch,
		};
	}
}


fn void delta_preintern_aggregate_types(DeltaProgramLowerer* lowerer) @private
{
	usz type_count = (usz)lowerer.program.types.descriptors.len();
	for (usz index = 0; index < type_count; index++)
	{
		TypeDescriptor* descriptor = &lowerer.program.types.descriptors[(sz)index];
		if (descriptor.kind == TYPE_DESCRIPTOR_ABSTRACT) continue;
		(void)delta_intern_unary_runtime_type(
			lowerer, TYPE_ID_SUPERPOSITION, descriptor.id, descriptor.span
		);
		(void)delta_intern_unary_runtime_type(
			lowerer, TYPE_ID_ARRAY, descriptor.id, descriptor.span
		);
	}
}
fn DeltaProgramBuildResult lower_delta_program(Program* source, Allocator allocator = mem)
{
	DeltaProgramBuildResult result = { .allocator = allocator };
	result.program = {
		.allocator = allocator,
		.runtime_identity = new_runtime_identity(),
		.schema = delta_schema_v4(),
		.feature_manifest = delta_feature_manifest(
			DELTA_V4_CORE_REQUIRED_FEATURES,
			DELTA_FEATURE_TYPED | DELTA_FEATURE_EFFECTS | DELTA_FEATURE_PARALLEL
				| DELTA_FEATURE_HOST | DELTA_FEATURE_SUPERPOSITION | DELTA_FEATURE_SUSPENSION
		),
		.effects = {
			.next_effect_id = (EffectId)1,
			.next_operation_id = (OperationId)1,
		},
		.helper_abi = delta_helper_abi_v2(delta_feature_manifest(
			DELTA_V4_CORE_REQUIRED_FEATURES,
			DELTA_FEATURE_TYPED | DELTA_FEATURE_EFFECTS | DELTA_FEATURE_PARALLEL
				| DELTA_FEATURE_HOST | DELTA_FEATURE_SUPERPOSITION | DELTA_FEATURE_SUSPENSION
		)),
	};
	if (!source)
	{
		result.diagnostics = alloc::new_array(allocator, MitosDiagnostic, 1);
		result.diagnostics[0].init(allocator, "Delta lowering requires a Program", { });
		return result;
	}
	result.program.module_key = clone_module_key(&source.module_key, allocator);
	result.program.feature_manifest = source.feature_manifest;
	result.program.feature_manifest.required |= DELTA_V4_CORE_REQUIRED_FEATURES;
	result.program.feature_manifest.optional |= DELTA_FEATURE_TYPED | DELTA_FEATURE_EFFECTS
		| DELTA_FEATURE_PARALLEL | DELTA_FEATURE_HOST | DELTA_FEATURE_SUPERPOSITION
		| DELTA_FEATURE_SUSPENSION;
	result.program.helper_abi.features = result.program.feature_manifest;
	result.diagnostics = validate_program(source, allocator);
	if (result.diagnostics.len) return result;
	alloc::free(allocator, result.diagnostics);
	result.diagnostics = { };

	TypeRegistryBuildResult type_build = build_type_registry(source, allocator);
	if (!type_build.ok())
	{
		result.diagnostics = type_build.diagnostics;
		type_build.diagnostics = { };
		type_build.deinit();
		return result;
	}
	result.program.types = type_build.registry;
	type_build.registry = { };

	type_build.deinit();

	GenericFunctionBuildResult method_build = build_generic_function_table(source, &result.program.types, allocator);
	if (!method_build.ok())
	{
		result.diagnostics = method_build.diagnostics;
		method_build.diagnostics = { };
		method_build.deinit();
		return result;
	}
	usz[] generic_by_function = method_build.generic_by_function;
	usz[] method_by_function = method_build.method_by_function;
	method_build.generic_by_function = { };
	method_build.method_by_function = { };
	defer alloc::free(allocator, generic_by_function);
	defer alloc::free(allocator, method_by_function);
	result.program.methods = method_build.table;
	method_build.table = { };
	method_build.deinit();

	EffectRegistryBuildResult effect_build = build_effect_registry(source, &result.program.types, allocator);
	if (!effect_build.ok())
	{
		result.diagnostics = effect_build.diagnostics;
		effect_build.diagnostics = { };
		effect_build.deinit();
		return result;
	}
	EffectAnalysis effect_analysis = infer_effect_rows(
		source, &effect_build.registry, &result.program.types, allocator
	);
	if (!effect_analysis.ok())
	{
		result.diagnostics = effect_analysis.diagnostics;
		effect_analysis.diagnostics = { };
		effect_analysis.deinit();
		effect_build.deinit();
		return result;
	}

	DeltaProgramLowerer lowerer = {
		.allocator = allocator,
		.source = source,
		.program = &result.program,
		.effect_registry = &effect_build.registry,
		.effect_analysis = &effect_analysis,
	};
	lowerer.next_source_order = source.functions.len + 1;
	lowerer.nodes.init(allocator);
	lowerer.edges.init(allocator);
	lowerer.interfaces.init(allocator);
	lowerer.parallel_regions.init(allocator);
	lowerer.spans.init(allocator);
	lowerer.diagnostics.init(allocator);
	lowerer.handlers.init(allocator);
	delta_copy_effect_section(&lowerer, &effect_build.registry, &effect_analysis);
	result.program.primitives = delta_build_primitives(allocator);
	result.program.constructors = delta_build_constructors(&lowerer);
	result.program.method_roots = alloc::new_array(allocator, DeltaMethodRoot, (sz)source.functions.len);

	foreach (function_index, &function : source.functions)
	{
		usz source_index = (usz)function_index;
		if (source_index >= (usz)generic_by_function.len
			|| source_index >= (usz)method_by_function.len)
		{
			delta_lower_error(&lowerer, "method table lost a source function", function.span);
			continue;
		}
		usz generic_index = generic_by_function[source_index];
		usz method_index = method_by_function[source_index];
		if (generic_index == usz::max || method_index == usz::max
			|| generic_index >= (usz)result.program.methods.generics.len()
			|| method_index >= (usz)result.program.methods.generics[(sz)generic_index].methods.len())
		{
			delta_lower_error(&lowerer, "method table lost a source function", function.span);
			continue;
		}
		String[] parameters = alloc::new_array(allocator, String, (sz)function.parameters.len);
		TypeId[] parameter_types = alloc::new_array(allocator, TypeId, (sz)function.parameters.len);
		foreach (index, parameter : function.parameters)
		{
			parameters[index] = parameter.copy(allocator);
			TypeAnnotation* parameter_annotation = index < function.parameter_annotations.len
				? &function.parameter_annotations[index] : null;
			parameter_types[index] = delta_resolve_annotation(&lowerer, parameter_annotation, true);
		}
		GenericFunction* generic = &result.program.methods.generics[(sz)generic_index];
		MethodDescriptor* method = &generic.methods[(sz)method_index];
		String[] scope_names = alloc::new_array(
			allocator, String,
			(sz)function.parameters.len + (sz)method.type_variables.len
		);
		TypeId[] scope_types = alloc::new_array(
			allocator, TypeId,
			(sz)function.parameters.len + (sz)method.type_variables.len
		);
		foreach (index, parameter : function.parameters)
		{
			scope_names[index] = parameter;
			scope_types[index] = parameter_types[index];
		}
		foreach (index, variable : method.type_variables)
		{
			scope_names[function.parameters.len + index] = variable;
			scope_types[function.parameters.len + index] = TYPE_ID_TYPE;
		}
		MethodEffectInfo* effect_info = &effect_analysis.methods[(usz)function_index];
		ResolvedEffectRow* method_effect_row = effect_info.has_assertion
			? &effect_info.asserted : &effect_info.inferred;
		DeltaLowerScope scope = {
			.names = scope_names,
			.types = scope_types,
			.effects = method_effect_row,
			.has_effect_context = true,
		};
		DeltaNodeId root = delta_lower_expression(&lowerer, function.body, &scope);
		alloc::free(allocator, scope_names);
		alloc::free(allocator, scope_types);
		TypeId result_type = delta_resolve_annotation(&lowerer, &function.result, true);
		if (function.result.value)
		{
			DeltaNodeId[] assertion_input = alloc::new_array(allocator, DeltaNodeId, 1);
			assertion_input[0] = root;
			root = delta_node_with_span(&lowerer, {
				.kind = DELTA_TYPE_ASSERT,
				.static_type = result_type,
				.descriptor = (usz)result_type,
				.inputs = assertion_input,
			}, function.span);
		}
		MethodTypePattern[] parameter_patterns = alloc::new_array(
			allocator, MethodTypePattern, method.parameters.len
		);
		foreach (index, &pattern : method.parameters)
			parameter_patterns[index] = clone_method_pattern(pattern, allocator);
		MethodTypePattern result_pattern = clone_method_pattern(&method.result, allocator);
		ResolvedEffectRow owned_effects = clone_resolved_effect_row(
			method_effect_row, allocator
		);
		result.program.method_roots[function_index] = {
			.key = clone_symbol_key(&method.key, allocator),
			.generic_key = clone_symbol_key(&generic.key, allocator),
			.function_index = (usz)function_index,
			.generic_index = generic_index,
			.method_index = method_index,
			.root = root,
			.parameters = parameters,
			.parameter_types = parameter_types,
			.parameter_patterns = parameter_patterns,
			.result_type = result_type,
			.result_pattern = result_pattern,
			.effect_row = owned_effects,
			.source_order = (usz)function_index,
		};
		lowerer.interfaces.push({
			.key = clone_symbol_key(&method.key, allocator),
			.kind = DELTA_INTERFACE_METHOD,
			.name = function.name.copy(allocator),
			.root = root,
			.source_order = (usz)function_index,
		});
	}

	sz main_generic = delta_generic_index(&result.program, "main", 0);
	if (main_generic < 0)
	{
		delta_lower_error(&lowerer, "program has no zero-argument main method", { });
	}
	else
	{
		result.program.entry = delta_node_with_span(&lowerer, {
			.key = clone_symbol_key(
				&result.program.methods.generics[(usz)main_generic].key, allocator
			),
			.kind = DELTA_GENERIC_CALL,
			.static_type = TYPE_ID_ANY,
			.descriptor = (usz)main_generic,
			.name = "main".copy(allocator),
		}, { });
		lowerer.interfaces.push({
			.key = clone_symbol_key(
				&result.program.methods.generics[(usz)main_generic].key, allocator
			),
			.kind = DELTA_INTERFACE_ENTRY,
			.name = "main".copy(allocator),
			.root = result.program.entry,
			.source_order = source.functions.len,
		});
	}

	delta_preintern_aggregate_types(&lowerer);

	result.program.image = {
		.nodes = lowerer.nodes.to_array(allocator),
		.edges = lowerer.edges.to_array(allocator),
		.interfaces = lowerer.interfaces.to_array(allocator),
		.parallel_regions = lowerer.parallel_regions.to_array(allocator),
	};
	result.program.effects.handlers = lowerer.handlers.to_array(allocator);
	result.program.spans = lowerer.spans.to_array(allocator);
	DeltaFeatureBits semantic_features = delta_program_semantic_features(&result.program);
	result.program.feature_manifest.required |= semantic_features;
	result.program.feature_manifest.optional &= ~result.program.feature_manifest.required;
	result.program.helper_abi.features = result.program.feature_manifest;
	result.diagnostics = lowerer.diagnostics.to_array(allocator);
	lowerer.nodes.free();
	lowerer.edges.free();
	lowerer.interfaces.free();
	lowerer.parallel_regions.free();
	lowerer.spans.free();
	lowerer.handlers.free();
	lowerer.diagnostics.free();
	effect_analysis.deinit();
	effect_build.deinit();
	return result;
}
