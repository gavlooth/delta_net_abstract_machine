module delta_net_abstract_machine::mitos;

import std::collections::list;
import std::core::mem;
import std::io;

const usz MITOS_MAX_STRING_LITERAL_BYTES = 1024 * 1024;

struct MitosPosition
{
	sz offset;
	sz row;
	sz column;
}
struct MitosSpan
{
	MitosPosition start;
	MitosPosition end;
}

struct MitosDiagnostic
{
	Allocator allocator;
	String message;
	MitosSpan span;
}

fn MitosDiagnostic* MitosDiagnostic.init(&self, Allocator allocator, String message, MitosSpan span)
{
	*self = { .allocator = allocator, .message = message.copy(allocator), .span = span };
	return self;
}

fn void MitosDiagnostic.deinit(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.message);
	*self = { };
}

enum TypeExprKind : char
{
	TYPE_EXPR_NAMED,
	TYPE_EXPR_APPLICATION,
}


struct TypeArgument
{
	TypeExpr* value;
	MitosSpan span;
}

struct TypeExpr
{
	TypeExprKind kind;
	String name;
	TypeArgument[] arguments;
	MitosSpan span;
}

struct TypeAnnotation
{
	TypeExpr* value;
	MitosSpan span;
}

struct TypeParameterDecl
{
	String name;
	MitosSpan span;
}

enum TypeDeclKind : char
{
	TYPE_DECL_ABSTRACT,
	TYPE_DECL_CONCRETE,
}

struct FieldDecl
{
	String name;
	TypeAnnotation annotation;
	MitosSpan span;
}

struct TypeDecl
{
	TypeDeclKind kind;
	String name;
	TypeParameterDecl[] parameters;
	TypeExpr* supertype;
	FieldDecl[] fields;
	MitosSpan span;
}

struct EffectRow
{
	TypeExpr*[] effects;
	MitosSpan span;
}

struct EffectOperationDecl
{
	String name;
	String[] parameters;
	TypeAnnotation[] parameter_annotations;
	TypeAnnotation result;
	MitosSpan span;
}

struct EffectDecl
{
	bool multi;
	String name;
	TypeParameterDecl[] parameters;
	EffectOperationDecl[] operations;
	MitosSpan span;
}

fn void TypeExpr.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.name);
	foreach (&argument : self.arguments)
	{
		if (!argument.value) continue;
		argument.value.deinit(allocator);
		alloc::free(allocator, argument.value);
	}
	alloc::free(allocator, self.arguments);
	*self = { };
}

fn void TypeAnnotation.deinit(&self, Allocator allocator)
{
	if (self.value)
	{
		self.value.deinit(allocator);
		alloc::free(allocator, self.value);
	}
	*self = { };
}

fn void EffectRow.deinit(&self, Allocator allocator)
{
	foreach (effect : self.effects)
	{
		if (!effect) continue;
		effect.deinit(allocator);
		alloc::free(allocator, effect);
	}
	alloc::free(allocator, self.effects);
	*self = { };
}

fn void TypeDecl.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.name);
	foreach (&parameter : self.parameters) alloc::free(allocator, parameter.name);
	alloc::free(allocator, self.parameters);
	if (self.supertype)
	{
		self.supertype.deinit(allocator);
		alloc::free(allocator, self.supertype);
	}
	foreach (&field : self.fields)
	{
		alloc::free(allocator, field.name);
		field.annotation.deinit(allocator);
	}
	alloc::free(allocator, self.fields);
	*self = { };
}

fn void EffectDecl.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.name);
	foreach (&parameter : self.parameters) alloc::free(allocator, parameter.name);
	alloc::free(allocator, self.parameters);
	foreach (&operation : self.operations)
	{
		alloc::free(allocator, operation.name);
		foreach (parameter : operation.parameters) alloc::free(allocator, parameter);
		alloc::free(allocator, operation.parameters);
		foreach (&annotation : operation.parameter_annotations) annotation.deinit(allocator);
		alloc::free(allocator, operation.parameter_annotations);
		operation.result.deinit(allocator);
	}
	alloc::free(allocator, self.operations);
	*self = { };
}

enum SurfaceExprKind : char
{
	SURFACE_VARIABLE,
	SURFACE_INTEGER,
	SURFACE_LAMBDA,
	SURFACE_STRING,
	SURFACE_APPLICATION,
	SURFACE_EFFECT_OPERATION,
	SURFACE_BINARY,
	SURFACE_DEFINITION,
	SURFACE_MATCH,
	SURFACE_PARALLEL,
	SURFACE_HANDLER,
	SURFACE_RESUME,
}

enum BinaryOperator : char
{
	BINARY_ADD,
	BINARY_SUBTRACT,
	BINARY_MULTIPLY,
	BINARY_DIVIDE,
	BINARY_REMAINDER,
	BINARY_EQUAL,
	BINARY_LESS,
	BINARY_LESS_EQUAL,
	BINARY_GREATER,
	BINARY_GREATER_EQUAL,
}

enum PatternKind : char
{
	PATTERN_CONSTRUCTOR,
	PATTERN_WILDCARD,
}

struct VariableExpr
{
	String name;
}
struct IntegerExpr
{
	long value;
}
struct StringExpr
{
	String value;
}
struct LambdaExpr
{
	String[] parameters;
	TypeAnnotation[] parameter_annotations;
	TypeAnnotation result;
	EffectRow* effect_row;
	SurfaceExpr* body;
}
struct ApplicationExpr
{
	SurfaceExpr* callee;
	SurfaceExpr*[] arguments;
}
struct EffectOperationExpr
{
	String effect_name;
	String operation_name;
	SurfaceExpr*[] arguments;
}
struct BinaryExpr
{
	BinaryOperator operator;
	SurfaceExpr* left;
	SurfaceExpr* right;
}
struct DefinitionExpr
{
	String name;
	TypeAnnotation annotation;
	SurfaceExpr* value;
	SurfaceExpr* body;
}

struct Pattern
{
	PatternKind kind;
	String constructor;
	String[] bindings;
	MitosSpan span;
}

struct MatchArm
{
	Pattern pattern;
	SurfaceExpr* body;
	MitosSpan span;
}
struct MatchExpr
{
	SurfaceExpr* scrutinee;
	MatchArm[] arms;
}
struct ParallelBinding
{
	String name;
	TypeAnnotation annotation;
	SurfaceExpr* value;
	MitosSpan span;
}

struct ParallelExpr
{
	ParallelBinding[] bindings;
	SurfaceExpr* result;
}

struct HandlerClause
{
	String effect_name;
	String operation_name;
	String[] parameters;
	TypeAnnotation[] parameter_annotations;
	SurfaceExpr* body;
	MitosSpan span;
}

struct HandlerReturnClause
{
	String parameter;
	TypeAnnotation annotation;
	SurfaceExpr* body;
	MitosSpan span;
}

struct HandlerExpr
{
	SurfaceExpr* handled;
	HandlerClause[] clauses;
	HandlerReturnClause return_clause;
}

struct ResumeExpr
{
	SurfaceExpr* value;
}

union SurfaceExprData
{
	VariableExpr variable;
	IntegerExpr integer;
	StringExpr string;
	LambdaExpr lambda;
	ApplicationExpr application;
	EffectOperationExpr effect_operation;
	BinaryExpr binary;
	DefinitionExpr definition;
	MatchExpr match_expr;
	ParallelExpr parallel;
	HandlerExpr handler;
	ResumeExpr resume;
}

struct SurfaceExpr
{
	SurfaceExprKind kind;
	MitosSpan span;
	SurfaceExprData data;
}
struct VariantDecl
{
	String name;
	String[] parameters;
	TypeAnnotation[] parameter_annotations;
	MitosSpan span;
}
struct EnumDecl
{
	String name;
	TypeParameterDecl[] parameters;
	VariantDecl[] variants;
	MitosSpan span;
}
struct FunctionDecl
{
	String name;
	String[] parameters;
	TypeAnnotation[] parameter_annotations;
	TypeAnnotation result;
	EffectRow* effect_row;
	SurfaceExpr* body;
	MitosSpan span;
}
struct Program
{
	Allocator allocator;
	EnumDecl[] enums;
	TypeDecl[] types;
	EffectDecl[] effects;
	FunctionDecl[] functions;
}

fn void Pattern.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.constructor);
	foreach (binding : self.bindings) alloc::free(allocator, binding);
	alloc::free(allocator, self.bindings);
	*self = { };
}

fn void SurfaceExpr.deinit(&self, Allocator allocator)
{
	switch (self.kind)
	{
		case SURFACE_VARIABLE:
			alloc::free(allocator, self.data.variable.name);
			break;
		case SURFACE_INTEGER:
			break;
		case SURFACE_STRING:
			alloc::free(allocator, self.data.string.value);
			break;
		case SURFACE_LAMBDA:
			foreach (parameter : self.data.lambda.parameters) alloc::free(allocator, parameter);
			alloc::free(allocator, self.data.lambda.parameters);
			foreach (&annotation : self.data.lambda.parameter_annotations) annotation.deinit(allocator);
			alloc::free(allocator, self.data.lambda.parameter_annotations);
			self.data.lambda.result.deinit(allocator);
			if (self.data.lambda.effect_row)
			{
				self.data.lambda.effect_row.deinit(allocator);
				alloc::free(allocator, self.data.lambda.effect_row);
			}
			if (self.data.lambda.body)
			{
				self.data.lambda.body.deinit(allocator);
				alloc::free(allocator, self.data.lambda.body);
			}
			break;
		case SURFACE_APPLICATION:
			if (self.data.application.callee)
			{
				self.data.application.callee.deinit(allocator);
				alloc::free(allocator, self.data.application.callee);
			}
			foreach (argument : self.data.application.arguments)
			{
				if (!argument) continue;
				argument.deinit(allocator);
				alloc::free(allocator, argument);
			}
			alloc::free(allocator, self.data.application.arguments);
			break;
		case SURFACE_EFFECT_OPERATION:
			alloc::free(allocator, self.data.effect_operation.effect_name);
			alloc::free(allocator, self.data.effect_operation.operation_name);
			foreach (argument : self.data.effect_operation.arguments)
			{
				if (!argument) continue;
				argument.deinit(allocator);
				alloc::free(allocator, argument);
			}
			alloc::free(allocator, self.data.effect_operation.arguments);
			break;
		case SURFACE_BINARY:
			if (self.data.binary.left)
			{
				self.data.binary.left.deinit(allocator);
				alloc::free(allocator, self.data.binary.left);
			}
			if (self.data.binary.right)
			{
				self.data.binary.right.deinit(allocator);
				alloc::free(allocator, self.data.binary.right);
			}
			break;
		case SURFACE_DEFINITION:
			alloc::free(allocator, self.data.definition.name);
			self.data.definition.annotation.deinit(allocator);
			if (self.data.definition.value)
			{
				self.data.definition.value.deinit(allocator);
				alloc::free(allocator, self.data.definition.value);
			}
			if (self.data.definition.body)
			{
				self.data.definition.body.deinit(allocator);
				alloc::free(allocator, self.data.definition.body);
			}
			break;
		case SURFACE_MATCH:
			if (self.data.match_expr.scrutinee)
			{
				self.data.match_expr.scrutinee.deinit(allocator);
				alloc::free(allocator, self.data.match_expr.scrutinee);
			}
			foreach (&arm : self.data.match_expr.arms)
			{
				arm.pattern.deinit(allocator);
				if (arm.body)
				{
					arm.body.deinit(allocator);
					alloc::free(allocator, arm.body);
				}
			}
			alloc::free(allocator, self.data.match_expr.arms);
			break;
		case SURFACE_PARALLEL:
			foreach (&binding : self.data.parallel.bindings)
			{
				alloc::free(allocator, binding.name);
				binding.annotation.deinit(allocator);
				if (binding.value)
				{
					binding.value.deinit(allocator);
					alloc::free(allocator, binding.value);
				}
			}
			alloc::free(allocator, self.data.parallel.bindings);
			if (self.data.parallel.result)
			{
				self.data.parallel.result.deinit(allocator);
				alloc::free(allocator, self.data.parallel.result);
			}
			break;
		case SURFACE_HANDLER:
			if (self.data.handler.handled)
			{
				self.data.handler.handled.deinit(allocator);
				alloc::free(allocator, self.data.handler.handled);
			}
			foreach (&clause : self.data.handler.clauses)
			{
				alloc::free(allocator, clause.effect_name);
				alloc::free(allocator, clause.operation_name);
				foreach (parameter : clause.parameters) alloc::free(allocator, parameter);
				alloc::free(allocator, clause.parameters);
				foreach (&annotation : clause.parameter_annotations) annotation.deinit(allocator);
				alloc::free(allocator, clause.parameter_annotations);
				if (clause.body)
				{
					clause.body.deinit(allocator);
					alloc::free(allocator, clause.body);
				}
			}
			alloc::free(allocator, self.data.handler.clauses);
			alloc::free(allocator, self.data.handler.return_clause.parameter);
			self.data.handler.return_clause.annotation.deinit(allocator);
			if (self.data.handler.return_clause.body)
			{
				self.data.handler.return_clause.body.deinit(allocator);
				alloc::free(allocator, self.data.handler.return_clause.body);
			}
			break;
		case SURFACE_RESUME:
			if (self.data.resume.value)
			{
				self.data.resume.value.deinit(allocator);
				alloc::free(allocator, self.data.resume.value);
			}
			break;
		default:
	}
	*self = { };
}

fn void Program.deinit(&self)
{
	if (!self.allocator) return;
	foreach (&enum_decl : self.enums)
	{
		alloc::free(self.allocator, enum_decl.name);
		foreach (&parameter : enum_decl.parameters) alloc::free(self.allocator, parameter.name);
		alloc::free(self.allocator, enum_decl.parameters);
		foreach (&variant : enum_decl.variants)
		{
			alloc::free(self.allocator, variant.name);
			foreach (parameter : variant.parameters) alloc::free(self.allocator, parameter);
			alloc::free(self.allocator, variant.parameters);
			foreach (&annotation : variant.parameter_annotations) annotation.deinit(self.allocator);
			alloc::free(self.allocator, variant.parameter_annotations);
		}
		alloc::free(self.allocator, enum_decl.variants);
	}
	foreach (&type_decl : self.types) type_decl.deinit(self.allocator);
	foreach (&effect : self.effects) effect.deinit(self.allocator);
	foreach (&function : self.functions)
	{
		alloc::free(self.allocator, function.name);
		foreach (parameter : function.parameters) alloc::free(self.allocator, parameter);
		alloc::free(self.allocator, function.parameters);
		foreach (&annotation : function.parameter_annotations) annotation.deinit(self.allocator);
		alloc::free(self.allocator, function.parameter_annotations);
		function.result.deinit(self.allocator);
		if (function.effect_row)
		{
			function.effect_row.deinit(self.allocator);
			alloc::free(self.allocator, function.effect_row);
		}
		if (function.body)
		{
			function.body.deinit(self.allocator);
			alloc::free(self.allocator, function.body);
		}
	}
	alloc::free(self.allocator, self.enums);
	alloc::free(self.allocator, self.types);
	alloc::free(self.allocator, self.effects);
	alloc::free(self.allocator, self.functions);
	*self = { };
}

enum CoreExprKind : char
{
	CORE_VARIABLE,
	CORE_ABSTRACTION,
	CORE_APPLICATION,
	CORE_PARALLEL,
}
struct CoreVariable
{
	String name;
}
struct CoreAbstraction
{
	String parameter;
	CoreExpr* body;
}
struct CoreApplication
{
	CoreExpr* function;
	CoreExpr* argument;
}
struct CoreParallelBinding
{
	String name;
	CoreExpr* value;
}
struct CoreParallel
{
	CoreParallelBinding[] bindings;
	CoreExpr* result;
}
union CoreExprData
{
	CoreVariable variable;
	CoreAbstraction abstraction;
	CoreApplication application;
	CoreParallel parallel;
}
struct CoreExpr
{
	CoreExprKind kind;
	CoreExprData data;
}
struct CoreProgram
{
	Allocator allocator;
	CoreExpr* expression;
}

fn void CoreExpr.deinit(&self, Allocator allocator)
{
	switch (self.kind)
	{
		case CORE_VARIABLE:
			alloc::free(allocator, self.data.variable.name);
			break;
		case CORE_ABSTRACTION:
			alloc::free(allocator, self.data.abstraction.parameter);
			if (self.data.abstraction.body)
			{
				self.data.abstraction.body.deinit(allocator);
				alloc::free(allocator, self.data.abstraction.body);
			}
			break;
		case CORE_APPLICATION:
			if (self.data.application.function)
			{
				self.data.application.function.deinit(allocator);
				alloc::free(allocator, self.data.application.function);
			}
			if (self.data.application.argument)
			{
				self.data.application.argument.deinit(allocator);
				alloc::free(allocator, self.data.application.argument);
			}
			break;
		case CORE_PARALLEL:
			foreach (&binding : self.data.parallel.bindings)
			{
				alloc::free(allocator, binding.name);
				if (!binding.value) continue;
				binding.value.deinit(allocator);

				alloc::free(allocator, binding.value);
			}
			alloc::free(allocator, self.data.parallel.bindings);
			if (self.data.parallel.result)
			{
				self.data.parallel.result.deinit(allocator);
				alloc::free(allocator, self.data.parallel.result);
			}
			break;
		default:
	}
	*self = { };
}

fn void CoreProgram.deinit(&self)
{
	if (!self.allocator) return;
	if (self.expression)
	{
		self.expression.deinit(self.allocator);
		alloc::free(self.allocator, self.expression);
	}
	*self = { };
}
fn bool type_expr_equal(TypeExpr* left, TypeExpr* right)
{
	if (left == right) return true;
	if (!left || !right || left.kind != right.kind || left.name != right.name
		|| left.arguments.len != right.arguments.len) return false;
	foreach (index, &argument : left.arguments)
	{
		if (!type_expr_equal(argument.value, right.arguments[index].value)) return false;
	}
	return true;
}

fn bool annotation_equal(TypeAnnotation* left, TypeAnnotation* right)
{
	if (!left.value && !right.value) return true;
	if (!left.value || !right.value) return false;
	return type_expr_equal(left.value, right.value);
}

fn bool method_signature_equal(FunctionDecl* left, FunctionDecl* right) @private
{
	if (left.name != right.name || left.parameters.len != right.parameters.len) return false;
	foreach (index, parameter : left.parameters)
	{
		TypeExpr* left_type = index < left.parameter_annotations.len
			? left.parameter_annotations[index].value : null;
		TypeExpr* right_type = index < right.parameter_annotations.len
			? right.parameter_annotations[index].value : null;
		if (left_type || right_type)
		{
			if (!left_type || !right_type || !type_expr_equal(left_type, right_type)) return false;
		}
	}
	return true;
}

struct LowerResult
{
	Allocator allocator;
	CoreProgram program;
	MitosDiagnostic[] diagnostics;
}
fn bool LowerResult.ok(&self) => self.diagnostics.len == 0;

fn void LowerResult.deinit(&self)
{
	if (!self.allocator) return;
	self.program.deinit();
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

struct ConstructorRef
{
	sz enum_index;
	sz variant_index;
	bool found;
}

fn ConstructorRef find_constructor(Program* program, String name) @private
{
	foreach (enum_index, &enum_decl : program.enums)
	{
		foreach (variant_index, &variant : enum_decl.variants)
		{
			if (variant.name
				== name) return { .enum_index = (sz)enum_index, .variant_index = (sz)variant_index, .found = true };
		}
	}
	return { };
}

fn void add_validation_error(
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


fn void validate_application(
	Program* program,
	SurfaceExpr* expression,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	ApplicationExpr* application = &expression.data.application;
	bool constructor_call        = false;
	if (application.callee && application.callee.kind == SURFACE_VARIABLE)
	{
		String callee_name = application.callee.data.variable.name;
		if (callee_name == "superpose" && !application.arguments.len)
		{
			add_validation_error(
				diagnostics, allocator, "superpose requires at least one branch", expression.span
			);
		}
		if (callee_name == "collapse" && application.arguments.len != 1)
		{
			add_validation_error(
				diagnostics, allocator, "collapse expects exactly one argument", expression.span
			);
		}
		ConstructorRef reference = find_constructor(program, application.callee.data.variable.name);
		if (reference.found)
		{
			constructor_call = true;
			VariantDecl* variant = &program.enums[(usz)reference.enum_index].variants[(usz)reference.variant_index];
			if (application.arguments.len != variant.parameters.len)
			{
				add_validation_error(
					diagnostics,
					allocator,
					"constructor argument count does not match its declaration",
					expression.span
				);
			}
		}
	}
	if (!constructor_call) validate_expression(program, application.callee, diagnostics, allocator);
	foreach (argument : application.arguments) validate_expression(program, argument, diagnostics, allocator);
}

fn void validate_match(
	Program* program,
	SurfaceExpr* expression,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	validate_expression(program, expression.data.match_expr.scrutinee, diagnostics, allocator);
	sz matched_enum = -1;
	bool wildcard   =  false;
	foreach (arm_index, &arm : expression.data.match_expr.arms)
	{
		if (arm.pattern.kind == PATTERN_WILDCARD)
		{
			if (wildcard)
			{
				add_validation_error(diagnostics, allocator, "duplicate wildcard arm in match", arm.pattern.span);
			}
			if (arm_index + 1 != expression.data.match_expr.arms.len)
			{
				add_validation_error(diagnostics, allocator, "wildcard match arm must be final", arm.pattern.span);
			}
			wildcard = true;
		}
		else
		{
			if (wildcard)
			{
				add_validation_error(
					diagnostics,
					allocator,
					"constructor match arm cannot follow a wildcard arm",
					arm.pattern.span
				);
			}
			foreach (binding_index, binding : arm.pattern.bindings)
			{
				for (sz previous_index = 0; previous_index < binding_index; previous_index++)
				{
					if (arm.pattern.bindings[(usz)previous_index] == binding)
					{
						add_validation_error(
							diagnostics,
							allocator,
							"duplicate binding in constructor pattern",
							arm.pattern.span
						);
					}
				}
			}
			ConstructorRef reference = find_constructor(program, arm.pattern.constructor);
			if (!reference.found)
			{
				add_validation_error(diagnostics, allocator, "unknown constructor in match pattern", arm.pattern.span);
			}
			else
			{
				VariantDecl* variant = &program.enums[(usz)reference.enum_index].variants[(usz)reference.variant_index];
				if (arm.pattern.bindings.len != variant.parameters.len)
				{
					add_validation_error(
						diagnostics,
						allocator,
						"pattern binding count does not match constructor arity",
						arm.pattern.span
					);
				}
				if (matched_enum < 0)
				{
					matched_enum = reference.enum_index;
				}
				else if (matched_enum != reference.enum_index)
				{
					add_validation_error(
						diagnostics,
						allocator,
						"match arms use constructors from different enums",
						arm.pattern.span
					);
				}
			}
		}
		validate_expression(program, arm.body, diagnostics, allocator);
	}
	if (matched_enum < 0)
	{
		add_validation_error(
			diagnostics,
			allocator,
			"match needs a constructor arm to identify its enum",
			expression.span
		);
		return;
	}
	EnumDecl* enum_decl = &program.enums[(usz)matched_enum];
	foreach (&variant : enum_decl.variants)
	{
		bool covered      = wildcard;
		bool explicit_arm = false;
		foreach (&arm : expression.data.match_expr.arms)
		{
			if (arm.pattern.kind != PATTERN_CONSTRUCTOR || arm.pattern.constructor != variant.name) continue;
			if (explicit_arm) add_validation_error(
				diagnostics,
				allocator,
				"duplicate constructor arm in match",
				arm.pattern.span
			);
			explicit_arm = true;
			covered = true;
		}
		if (!covered)
		{
			add_validation_error(diagnostics, allocator, "non-exhaustive match", expression.span);
			break;
		}
	}
}

fn void validate_expression(
	Program* program,
	SurfaceExpr* expression,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	if (!expression) return;
	switch (expression.kind)
	{
		case SURFACE_VARIABLE:
			ConstructorRef reference = find_constructor(program, expression.data.variable.name);
			if (reference.found
				&& program.enums[(usz)reference.enum_index].variants[(usz)reference.variant_index].parameters.len != 0)
			{
				add_validation_error(
					diagnostics,
					allocator,
					"constructor must be applied to its declared argument count",
					expression.span
				);
			}
		case SURFACE_INTEGER:
		case SURFACE_STRING:
			if (expression.data.string.value.len > MITOS_MAX_STRING_LITERAL_BYTES)
			{
				add_validation_error(
					diagnostics,
					allocator,
					"decoded string literal cannot exceed 1048576 bytes",
					expression.span
				);
			}
			foreach (character : expression.data.string.value)
			{
				if (character != '\0') continue;
				add_validation_error(
					diagnostics,
					allocator,
					"string literal cannot contain a NUL byte",
					expression.span
				);
				break;
			}
		case SURFACE_LAMBDA:
			validate_expression(program, expression.data.lambda.body, diagnostics, allocator);
		case SURFACE_APPLICATION:
			validate_application(program, expression, diagnostics, allocator);
		case SURFACE_EFFECT_OPERATION:
			foreach (argument : expression.data.effect_operation.arguments)
			{
				validate_expression(program, argument, diagnostics, allocator);
			}
		case SURFACE_BINARY:
			validate_expression(program, expression.data.binary.left, diagnostics, allocator);
			validate_expression(program, expression.data.binary.right, diagnostics, allocator);
		case SURFACE_DEFINITION:
			for (
				SurfaceExpr* nested = expression.data.definition.body;
				nested && nested.kind == SURFACE_DEFINITION;
				nested = nested.data.definition.body
			)
			{
				if (nested.data.definition.name == expression.data.definition.name)
				{
					add_validation_error(
						diagnostics,
						allocator,
						"duplicate definition in the same block",
						nested.span
					);
				}
			}
			validate_expression(program, expression.data.definition.value, diagnostics, allocator);
			validate_expression(program, expression.data.definition.body, diagnostics, allocator);
		case SURFACE_MATCH:
			validate_match(program, expression, diagnostics, allocator);
		case SURFACE_PARALLEL:
			if (expression.data.parallel.bindings.len < 2)
			{
				add_validation_error(
					diagnostics,
					allocator,
					"parallel requires at least two bindings",
					expression.span
				);
			}
			foreach (binding_index, &binding : expression.data.parallel.bindings)
			{
				for (sz previous_index = 0; previous_index < binding_index; previous_index++)
				{
					if (expression.data.parallel.bindings[(usz)previous_index].name == binding.name)
					{
						add_validation_error(
							diagnostics,
							allocator,
							"duplicate parallel binding",
							binding.span
						);
					}
				}
				validate_expression(program, binding.value, diagnostics, allocator);
			}
			validate_expression(program, expression.data.parallel.result, diagnostics, allocator);
		case SURFACE_HANDLER:
			validate_expression(program, expression.data.handler.handled, diagnostics, allocator);
			foreach (clause_index, &clause : expression.data.handler.clauses)
			{
				for (sz previous_index = 0; previous_index < clause_index; previous_index++)
				{
					HandlerClause* previous = &expression.data.handler.clauses[(usz)previous_index];
					if (previous.effect_name == clause.effect_name
						&& previous.operation_name == clause.operation_name)
					{
						add_validation_error(diagnostics, allocator, "duplicate handler operation clause", clause.span);
					}
				}
				validate_expression(program, clause.body, diagnostics, allocator);
			}
			if (!expression.data.handler.return_clause.body)
			{
				add_validation_error(diagnostics, allocator, "handler requires exactly one return clause", expression.span);
			}
			else
			{
				validate_expression(program, expression.data.handler.return_clause.body, diagnostics, allocator);
			}
		case SURFACE_RESUME:
			validate_expression(program, expression.data.resume.value, diagnostics, allocator);
		default:
	}
}

fn MitosDiagnostic[] validate_program(Program* program, Allocator allocator = mem)
{
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);
	bool found_main = false;
	foreach (enum_index, &enum_decl : program.enums)
	{
		for (sz previous_index = 0; previous_index < enum_index; previous_index++)
		{
			if (program.enums[(usz)previous_index].name == enum_decl.name)
			{
				add_validation_error(&diagnostics, allocator, "duplicate enum declaration", enum_decl.span);
			}
		}
		foreach (parameter_index, &parameter : enum_decl.parameters)
		{
			for (sz previous_index = 0; previous_index < parameter_index; previous_index++)
			{
				if (enum_decl.parameters[(usz)previous_index].name == parameter.name)
				{
					add_validation_error(&diagnostics, allocator, "duplicate enum type parameter", parameter.span);
				}
			}
		}
		foreach (variant_index, &variant : enum_decl.variants)
		{
			for (sz previous_index = 0; previous_index < variant_index; previous_index++)
			{
				if (enum_decl.variants[(usz)previous_index].name == variant.name)
				{
					add_validation_error(&diagnostics, allocator, "duplicate enum variant", variant.span);
				}
			}
			for (sz other_enum = 0; other_enum <= enum_index; other_enum++)
			{
				EnumDecl* candidate_enum = &program.enums[(usz)other_enum];
				sz limit = other_enum == enum_index ? variant_index : (sz)candidate_enum.variants.len;
				for (sz other_variant = 0; other_variant < limit; other_variant++)
				{
					if (candidate_enum.variants[(usz)other_variant].name == variant.name)
					{
						add_validation_error(
							&diagnostics,
							allocator,
							"constructor names must be unique across enums",
							variant.span
						);
					}
				}
			}
			foreach (parameter_index, parameter : variant.parameters)
			{
				for (sz previous_index = 0; previous_index < parameter_index; previous_index++)
				{
					if (variant.parameters[(usz)previous_index] == parameter)
					{
						add_validation_error(&diagnostics, allocator, "duplicate constructor parameter", variant.span);
					}
				}
			}
		}
	}
	foreach (type_index, &type_decl : program.types)
	{
		for (sz previous_index = 0; previous_index < type_index; previous_index++)
		{
			if (program.types[(usz)previous_index].name == type_decl.name)
			{
				add_validation_error(&diagnostics, allocator, "duplicate type declaration", type_decl.span);
			}
		}
		foreach (&enum_decl : program.enums)
		{
			if (enum_decl.name == type_decl.name)
			{
				add_validation_error(&diagnostics, allocator, "type name collides with an enum name", type_decl.span);
			}
		}
		foreach (parameter_index, &parameter : type_decl.parameters)
		{
			for (sz previous_index = 0; previous_index < parameter_index; previous_index++)
			{
				if (type_decl.parameters[(usz)previous_index].name == parameter.name)
				{
					add_validation_error(&diagnostics, allocator, "duplicate type parameter", parameter.span);
				}
			}
		}
		foreach (field_index, &field : type_decl.fields)
		{
			for (sz previous_index = 0; previous_index < field_index; previous_index++)
			{
				if (type_decl.fields[(usz)previous_index].name == field.name)
				{
					add_validation_error(&diagnostics, allocator, "duplicate type field", field.span);
				}
			}
		}
		if (type_decl.kind == TYPE_DECL_ABSTRACT && type_decl.fields.len)
		{
			add_validation_error(&diagnostics, allocator, "abstract types cannot declare fields", type_decl.span);
		}
	}
	foreach (effect_index, &effect : program.effects)
	{
		for (sz previous_index = 0; previous_index < effect_index; previous_index++)
		{
			if (program.effects[(usz)previous_index].name == effect.name)
			{
				add_validation_error(&diagnostics, allocator, "duplicate effect declaration", effect.span);
			}
		}
		foreach (operation_index, &operation : effect.operations)
		{
			for (sz previous_index = 0; previous_index < operation_index; previous_index++)
			{
				if (effect.operations[(usz)previous_index].name == operation.name)
				{
					add_validation_error(&diagnostics, allocator, "duplicate effect operation", operation.span);
				}
			}
			foreach (parameter_index, parameter : operation.parameters)
			{
				for (sz previous_index = 0; previous_index < parameter_index; previous_index++)
				{
					if (operation.parameters[(usz)previous_index] == parameter)
					{
						add_validation_error(&diagnostics, allocator, "duplicate effect operation parameter", operation.span);
					}
				}
			}
		}
	}
	foreach (function_index, &function : program.functions)
	{
		for (sz previous_index = 0; previous_index < function_index; previous_index++)
		{
			if (method_signature_equal(&program.functions[(usz)previous_index], function))
			{
				add_validation_error(&diagnostics, allocator, "duplicate method signature", function.span);
			}
		}
		if (function.name == "superpose" || function.name == "collapse")
		{
			add_validation_error(
				&diagnostics,
				allocator,
				"generic function name is reserved for a superposition intrinsic",
				function.span
			);
		}
		foreach (&enum_decl : program.enums)
		{
			if (enum_decl.name == function.name)
			{
				add_validation_error(&diagnostics, allocator, "duplicate declaration name", function.span);
			}
			foreach (&variant : enum_decl.variants)
			{
				if (variant.name == function.name)
				{
					add_validation_error(
						&diagnostics,
						allocator,
						"generic function name collides with a constructor name",
						function.span
					);
				}
			}
		}
		foreach (&type_decl : program.types)
		{
			if (type_decl.name == function.name)
			{
				add_validation_error(&diagnostics, allocator, "generic function name collides with a type name", function.span);
			}
		}
		foreach (parameter_index, parameter : function.parameters)
		{
			for (sz previous_index = 0; previous_index < parameter_index; previous_index++)
			{
				if (function.parameters[(usz)previous_index] == parameter)
				{
					add_validation_error(&diagnostics, allocator, "duplicate function parameter", function.span);
				}
			}
		}
		if (function.name == "main")
		{
			found_main = true;
			if (function.parameters.len != 0)
			{
				add_validation_error(&diagnostics, allocator, "main must have no parameters", function.span);
			}
		}
		validate_expression(program, function.body, &diagnostics, allocator);
	}
	if (!found_main)
	{
		MitosPosition start = { .offset = 0, .row = 1, .column = 1 };
		add_validation_error(&diagnostics, allocator, "program must declare main", { .start = start, .end = start });
	}
	MitosDiagnostic[] result = diagnostics.to_array(allocator);
	diagnostics.free();
	return result;
}

struct CoreNameScope
{
	CoreNameScope* parent;
	String[] names;
	ParallelBinding[] parallel_bindings;
}

fn bool core_name_is_bound(CoreNameScope* scope, String name) @private
{
	for (CoreNameScope* current = scope; current; current = current.parent)
	{
		foreach (bound_name : current.names) if (bound_name == name) return true;
		foreach (&binding : current.parallel_bindings) if (binding.name == name) return true;
	}
	return false;
}

fn bool is_named_global_function(Program* program, String name) @private
{
	foreach (&function : program.functions) if (function.name == name) return true;
	return false;
}

fn void validate_lambda_core_expression(
	Program* program,
	SurfaceExpr* expression,
	CoreNameScope* scope,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	if (!expression) return;
	switch (expression.kind)
	{
		case SURFACE_VARIABLE:
			if (!core_name_is_bound(scope, expression.data.variable.name)
				&& is_named_global_function(program, expression.data.variable.name))
			{
				add_validation_error(
					diagnostics,
					allocator,
					"lambda-core lowering does not support references between named functions",
					expression.span
				);
			}
		case SURFACE_INTEGER:
		case SURFACE_LAMBDA:
			CoreNameScope lambda_scope = { .parent = scope, .names = expression.data.lambda.parameters };
			validate_lambda_core_expression(
				program,
				expression.data.lambda.body,
				&lambda_scope,
				diagnostics,
				allocator
			);
		case SURFACE_APPLICATION:
			validate_lambda_core_expression(program, expression.data.application.callee, scope, diagnostics, allocator);
			foreach (argument : expression.data.application.arguments)
			{
				validate_lambda_core_expression(program, argument, scope, diagnostics, allocator);
			}
		case SURFACE_BINARY:
			validate_lambda_core_expression(program, expression.data.binary.left, scope, diagnostics, allocator);
			validate_lambda_core_expression(program, expression.data.binary.right, scope, diagnostics, allocator);
		case SURFACE_DEFINITION:
			validate_lambda_core_expression(program, expression.data.definition.value, scope, diagnostics, allocator);
			String[1] definition_names = { expression.data.definition.name };
			CoreNameScope definition_scope = { .parent = scope, .names = definition_names[..] };
			validate_lambda_core_expression(program, expression.data.definition.body, &definition_scope, diagnostics, allocator);
		case SURFACE_MATCH:
			validate_lambda_core_expression(
				program,
				expression.data.match_expr.scrutinee,
				scope,
				diagnostics,
				allocator
			);
			foreach (&arm : expression.data.match_expr.arms)
			{
				if (arm.pattern.kind == PATTERN_CONSTRUCTOR)
				{
					CoreNameScope arm_scope = { .parent = scope, .names = arm.pattern.bindings };
					validate_lambda_core_expression(program, arm.body, &arm_scope, diagnostics, allocator);
				}
				else
				{
					validate_lambda_core_expression(program, arm.body, scope, diagnostics, allocator);
				}
			}
		case SURFACE_PARALLEL:
			foreach (&binding : expression.data.parallel.bindings)
			{
				validate_lambda_core_expression(program, binding.value, scope, diagnostics, allocator);
			}
			CoreNameScope parallel_scope = { .parent = scope, .parallel_bindings = expression.data.parallel.bindings, };
			validate_lambda_core_expression(
				program,
				expression.data.parallel.result,
				&parallel_scope,
				diagnostics,
				allocator
			);
		default:
	}
}

fn MitosDiagnostic[] validate_lambda_core_program(Program* program, Allocator allocator) @private
{
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);
	foreach (&function : program.functions)
	{
		if (function.name == "main") continue;
		CoreNameScope function_scope = { .names = function.parameters };
		validate_lambda_core_expression(program, function.body, &function_scope, &diagnostics, allocator);
	}
	MitosDiagnostic[] result = diagnostics.to_array(allocator);
	diagnostics.free();
	return result;
}

struct Lowerer
{
	Allocator allocator;
	Program* source;
	sz next_handler;
}

fn CoreExpr* core_variable(Lowerer* lowerer, String name) @private
{
	return alloc::new(
		lowerer.allocator,
		CoreExpr,
		{ .kind = CORE_VARIABLE, .data = { .variable = { .name = name.copy(lowerer.allocator) } } }
	);
}

fn CoreExpr* core_abstraction(Lowerer* lowerer, String parameter, CoreExpr* body) @private
{
	return alloc::new(
		lowerer.allocator,
		CoreExpr,
		{
			.kind = CORE_ABSTRACTION,
			.data = { .abstraction = { .parameter = parameter.copy(lowerer.allocator), .body = body } }
		}
	);
}

fn CoreExpr* core_application(Lowerer* lowerer, CoreExpr* function, CoreExpr* argument) @private
{
	return alloc::new(
		lowerer.allocator,
		CoreExpr,
		{ .kind = CORE_APPLICATION, .data = { .application = { .function = function, .argument = argument } } }
	);
}


fn CoreExpr* core_parallel(Lowerer* lowerer, ParallelExpr* parallel_expression) @private
{
	CoreParallelBinding[] bindings = alloc::new_array(
		lowerer.allocator,
		CoreParallelBinding,
		(sz)parallel_expression.bindings.len
	);
	foreach (index, &binding : parallel_expression.bindings)
	{
		bindings[index] = {
			.name = binding.name.copy(lowerer.allocator),
			.value = lower_expression(lowerer, binding.value),
		};
	}
	return alloc::new(
		lowerer.allocator,
		CoreExpr,
		{
			.kind = CORE_PARALLEL,
			.data = {
				.parallel = {
					.bindings = bindings,
					.result = lower_expression(lowerer, parallel_expression.result),
				}
			}
		}
	);
}
fn CoreExpr* curry(Lowerer* lowerer, String[] parameters, CoreExpr* body) @private
{
	for (sz i = (sz)parameters.len - 1; i >= 0; i--) body = core_abstraction(lowerer, parameters[(usz)i], body);
	return body;
}

fn String prelude_name(BinaryOperator operator) @private
{
	switch (operator)
	{
		case BINARY_ADD: return "mitos.add";
		case BINARY_SUBTRACT: return "mitos.subtract";
		case BINARY_MULTIPLY: return "mitos.multiply";
		case BINARY_DIVIDE: return "mitos.divide";
		case BINARY_REMAINDER: return "mitos.remainder";
		case BINARY_EQUAL: return "mitos.equal";
		case BINARY_LESS: return "mitos.less";
		case BINARY_LESS_EQUAL: return "mitos.lessEqual";
		case BINARY_GREATER: return "mitos.greater";
		case BINARY_GREATER_EQUAL: return "mitos.greaterEqual";
		default: return "mitos.invalidOperator";
	}
}


fn CoreExpr* lower_constructor(Lowerer* lowerer, sz enum_index, sz variant_index) @private
{
	EnumDecl* enum_decl  = &lowerer.source.enums[(usz)enum_index];
	VariantDecl* variant = &enum_decl.variants[(usz)variant_index];
	sz first_handler     = lowerer.next_handler;
	lowerer.next_handler += (sz)enum_decl.variants.len;
	char[32] selected_buffer;
	String selected_name = (String)io::bprintf(&selected_buffer, "$handler%d", (long)(first_handler + variant_index))!!;
	CoreExpr* body = core_variable(lowerer, selected_name);
	foreach (parameter : variant.parameters) body = core_application(lowerer, body, core_variable(lowerer, parameter));
	for (sz i = (sz)enum_decl.variants.len - 1; i >= 0; i--)
	{
		char[32] handler_buffer;
		String handler_name = (String)io::bprintf(&handler_buffer, "$handler%d", (long)(first_handler + i))!!;
		body = core_abstraction(lowerer, handler_name, body);
	}
	return curry(lowerer, variant.parameters, body);
}

fn MatchArm* find_match_arm(MatchExpr* match_expr, String constructor) @private
{
	MatchArm* wildcard = null;
	foreach (&arm : match_expr.arms)
	{
		if (arm.pattern.kind == PATTERN_WILDCARD)
		{
			wildcard = arm;
		}
		else if (arm.pattern.constructor == constructor)
		{
			return arm;
		}
	}
	return wildcard;
}

fn CoreExpr* lower_match(Lowerer* lowerer, MatchExpr* match_expr) @private
{
	sz enum_index = -1;
	foreach (&arm : match_expr.arms)
	{
		if (arm.pattern.kind != PATTERN_CONSTRUCTOR) continue;
		ConstructorRef reference = find_constructor(lowerer.source, arm.pattern.constructor);
		if (reference.found)
		{
			enum_index = reference.enum_index;
			break;
		}
	}
	CoreExpr* result    = lower_expression(lowerer, match_expr.scrutinee);
	EnumDecl* enum_decl = &lowerer.source.enums[(usz)enum_index];
	foreach (&variant : enum_decl.variants)
	{
		MatchArm* arm    = find_match_arm(match_expr, variant.name);
		CoreExpr* branch = lower_expression(lowerer, arm.body);
		if (arm.pattern.kind == PATTERN_CONSTRUCTOR)
		{
			branch = curry(lowerer, arm.pattern.bindings, branch);
		}
		else
		{
			for (sz i = (sz)variant.parameters.len - 1; i >= 0; i--)
			{
				branch = core_abstraction(lowerer, "$discard", branch);
			}
		}
		result = core_application(lowerer, result, branch);
	}
	return result;
}

fn CoreExpr* lower_expression(Lowerer* lowerer, SurfaceExpr* expression) @private
{
	switch (expression.kind)
	{
		case SURFACE_VARIABLE:
			return core_variable(lowerer, expression.data.variable.name);
		case SURFACE_INTEGER:
			char[32] buffer;
			String value = (String)io::bprintf(&buffer, "%d", expression.data.integer.value)!!;
			return core_variable(lowerer, value);
		case SURFACE_LAMBDA:
			return curry(
				lowerer,
				expression.data.lambda.parameters,
				lower_expression(lowerer, expression.data.lambda.body)
			);
		case SURFACE_APPLICATION:
			CoreExpr* application = lower_expression(lowerer, expression.data.application.callee);
			foreach (argument : expression.data.application.arguments) application = core_application(
				lowerer,
				application,
				lower_expression(lowerer, argument)
			);
			return application;
		case SURFACE_BINARY:
			CoreExpr* operation = core_variable(lowerer, prelude_name(expression.data.binary.operator));
			operation = core_application(lowerer, operation, lower_expression(lowerer, expression.data.binary.left));
			return core_application(lowerer, operation, lower_expression(lowerer, expression.data.binary.right));
		case SURFACE_DEFINITION:
			CoreExpr* body = lower_expression(lowerer, expression.data.definition.body);
			return core_application(
				lowerer,
				core_abstraction(lowerer, expression.data.definition.name, body),
				lower_expression(lowerer, expression.data.definition.value)
			);
		case SURFACE_MATCH:
			return lower_match(lowerer, &expression.data.match_expr);
		case SURFACE_PARALLEL:
			return core_parallel(lowerer, &expression.data.parallel);
		default:
			return core_variable(lowerer, "mitos.invalidExpression");
	}
}

fn LowerResult lower_program(Program* source, Allocator allocator = mem)
{
	LowerResult result = { .allocator = allocator };
	result.diagnostics = validate_program(source, allocator);
	if (result.diagnostics.len != 0) return result;
	alloc::free(allocator, result.diagnostics);
	result.diagnostics = validate_lambda_core_program(source, allocator);
	if (result.diagnostics.len != 0) return result;
	Lowerer lowerer             = { .allocator = allocator, .source = source };
	FunctionDecl* main_function = null;
	foreach (&function : source.functions) if (function.name == "main") main_function = function;
	CoreExpr* expression = lower_expression(&lowerer, main_function.body);
	for (sz i = (sz)source.functions.len - 1; i >= 0; i--)
	{
		FunctionDecl* function = &source.functions[(usz)i];
		if (function.name == "main") continue;
		CoreExpr* function_value = curry(&lowerer, function.parameters, lower_expression(&lowerer, function.body));
		expression = core_application(&lowerer, core_abstraction(&lowerer, function.name, expression), function_value);
	}
	for (sz enum_index = (sz)source.enums.len - 1; enum_index >= 0; enum_index--)
	{
		EnumDecl* enum_decl = &source.enums[(usz)enum_index];
		for (sz variant_index = (sz)enum_decl.variants.len - 1; variant_index >= 0; variant_index--)
		{
			VariantDecl* variant = &enum_decl.variants[(usz)variant_index];
			expression = core_application(
				&lowerer,
				core_abstraction(&lowerer, variant.name, expression),
				lower_constructor(&lowerer, enum_index, variant_index)
			);
		}
	}
	result.program = { .allocator = allocator, .expression = expression };
	return result;
}