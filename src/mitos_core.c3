module delta_net_abstract_machine::mitos;

import std::collections::list;
import std::core::mem;
import std::crypto::entropy;

const usz MITOS_MAX_STRING_LITERAL_BYTES = 1024 * 1024;
/** Fills the complete destination from the operating system CSPRNG or fails closed. */
fn bool fill_secure_entropy(char[] destination)
{
	if (catch entropy::fill(destination)) return false;
	return true;
}

/** Cryptographically unpredictable process-local identity; zero means unavailable. */
fn ulong new_runtime_identity()
{
	for (usz attempt = 0; attempt < 8; attempt++)
	{
		ulong identity;
		if (!fill_secure_entropy(((char*)&identity)[:ulong::size])) return 0;
		if (identity) return identity;
	}
	return 0;
}

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

/** True exactly for the byte grammar accepted by the source lexer. */
fn bool source_identifier_is_valid(String identifier)
{
	if (!identifier.len) return false;
	char first = identifier[0];
	if (!((first >= 'A' && first <= 'Z')
			|| (first >= 'a' && first <= 'z') || first == '_'))
	{
		return false;
	}
	foreach (character : identifier[1..])
	{
		if (!((character >= 'A' && character <= 'Z')
				|| (character >= 'a' && character <= 'z')
				|| (character >= '0' && character <= '9')
				|| character == '_'))
		{
			return false;
		}
	}
	return true;
}

/** Allocator-owned canonical module identity. Display names never participate in equality. */
struct ModuleKey
{
	String canonical;
}

const String MITOS_CORE_MODULE_CANONICAL = "mitos://core";
const String MITOS_DEFAULT_MODULE_CANONICAL = "mitos://default";
const String MITOS_REPL_MODULE_CANONICAL = "mitos://repl";

enum SymbolKind : char
{
	SYMBOL_TYPE,
	SYMBOL_ENUM,
	SYMBOL_VARIANT,
	SYMBOL_EFFECT,
	SYMBOL_EFFECT_OPERATION,
	SYMBOL_FUNCTION,
	SYMBOL_EFFECT_ROW_TAIL,
	SYMBOL_GENERIC,
	SYMBOL_METHOD,
}

/**
 * Allocator-owned structural symbol identity. `canonical_signature` is a
 * canonical, display-independent signature; hashes may index but never replace
 * comparisons of these fields.
 */
struct SymbolKey
{
	ModuleKey owner;
	SymbolKind kind;
	String name;
	uint arity;
	String canonical_signature;
}

fn ModuleKey module_key(String canonical, Allocator allocator = mem)
{
	return { .canonical = canonical.copy(allocator) };
}

fn ModuleKey core_module_key(Allocator allocator = mem)
{
	return module_key(MITOS_CORE_MODULE_CANONICAL, allocator);
}

fn ModuleKey default_module_key(Allocator allocator = mem)
{
	return module_key(MITOS_DEFAULT_MODULE_CANONICAL, allocator);
}

fn ModuleKey repl_module_key(Allocator allocator = mem)
{
	return module_key(MITOS_REPL_MODULE_CANONICAL, allocator);
}

fn ModuleKey clone_module_key(ModuleKey* key, Allocator allocator = mem)
{
	if (!key) return { };
	return module_key(key.canonical, allocator);
}

fn bool module_key_equal(ModuleKey* left, ModuleKey* right)
{
	if (left == right) return true;
	return left && right && left.canonical == right.canonical;
}

fn void ModuleKey.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.canonical);
	*self = { };
}

fn SymbolKey symbol_key(
	ModuleKey* owner,
	SymbolKind kind,
	String name,
	usz arity,
	String canonical_signature,
	Allocator allocator = mem
)
{
	return {
		.owner = clone_module_key(owner, allocator),
		.kind = kind,
		.name = name.copy(allocator),
		.arity = (uint)arity,
		.canonical_signature = canonical_signature.copy(allocator),
	};
}

fn SymbolKey clone_symbol_key(SymbolKey* key, Allocator allocator = mem)
{
	if (!key) return { };
	return symbol_key(
		&key.owner, key.kind, key.name, key.arity, key.canonical_signature, allocator
	);
}

fn bool symbol_key_equal(SymbolKey* left, SymbolKey* right)
{
	if (left == right) return true;
	return left && right
		&& module_key_equal(&left.owner, &right.owner)
		&& left.kind == right.kind
		&& left.name == right.name
		&& left.arity == right.arity
		&& left.canonical_signature == right.canonical_signature;
}

fn bool symbol_key_is_canonical(SymbolKey* key)
{
	return key && key.owner.canonical.len > 0 && key.name.len > 0;
}

fn bool symbol_key_matches_declaration(
	SymbolKey* key,
	ModuleKey* owner,
	SymbolKind kind,
	String name,
	usz arity,
	String canonical_signature
)
{
	return symbol_key_is_canonical(key) && module_key_equal(&key.owner, owner)
		&& key.kind == kind && key.name == name && key.arity == (uint)arity
		&& key.canonical_signature == canonical_signature;
}

fn void SymbolKey.deinit(&self, Allocator allocator)
{
	self.owner.deinit(allocator);
	alloc::free(allocator, self.name);
	alloc::free(allocator, self.canonical_signature);
	*self = { };
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
	SymbolKey key;
	MitosSpan span;
}

struct EffectRow
{
	TypeExpr*[] effects;
	bool has_tail;
	SymbolKey tail;
	MitosSpan span;
}

struct EffectOperationDecl
{
	SymbolKey key;
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
	SymbolKey key;
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
	if (self.has_tail) self.tail.deinit(allocator);
	*self = { };
}

fn void TypeDecl.deinit(&self, Allocator allocator)
{
	self.key.deinit(allocator);
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
	self.key.deinit(allocator);
	alloc::free(allocator, self.name);
	foreach (&parameter : self.parameters) alloc::free(allocator, parameter.name);
	alloc::free(allocator, self.parameters);
	foreach (&operation : self.operations)
	{
		operation.key.deinit(allocator);
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
	usz structural_height;
	SurfaceExprData data;
}
struct VariantDecl
{
	SymbolKey key;
	String name;
	String[] parameters;
	TypeAnnotation[] parameter_annotations;
	MitosSpan span;
}
struct EnumDecl
{
	SymbolKey key;
	String name;
	TypeParameterDecl[] parameters;
	VariantDecl[] variants;
	MitosSpan span;
}
struct FunctionDecl
{
	SymbolKey key;
	SymbolKey generic_key;
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
	ModuleKey module_key;
	DeltaFeatureManifest feature_manifest;
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
	self.module_key.deinit(self.allocator);
	foreach (&enum_decl : self.enums)
	{
		enum_decl.key.deinit(self.allocator);
		alloc::free(self.allocator, enum_decl.name);
		foreach (&parameter : enum_decl.parameters) alloc::free(self.allocator, parameter.name);
		alloc::free(self.allocator, enum_decl.parameters);
		foreach (&variant : enum_decl.variants)
		{
			variant.key.deinit(self.allocator);
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
		function.key.deinit(self.allocator);
		function.generic_key.deinit(self.allocator);
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

fn bool method_signature_equal(FunctionDecl* left, FunctionDecl* right) @private
{
	return symbol_key_equal(&left.key, &right.key);
}

const usz MITOS_MAX_VALIDATION_DIAGNOSTICS = 256;

/** Borrowed-name open-addressed set used only for one validation pass. */
struct ValidationNameIndex
{
	Allocator allocator;
	String[] names;
	bool[] occupied;
}

fn ulong validation_hash_string(String value) @private
{
	ulong hash = 1469598103934665603UL;
	foreach (byte : value)
	{
		hash ^= (ulong)byte;
		hash *= 1099511628211UL;
	}
	return hash;
}

fn usz validation_index_capacity(usz count) @private
{
	usz capacity = 8;
	while (capacity < count * 2) capacity *= 2;
	return capacity;
}

fn void ValidationNameIndex.init(&self, Allocator allocator, usz count)
{
	self.allocator = allocator;
	usz capacity = validation_index_capacity(count);
	self.names = alloc::new_array(allocator, String, (sz)capacity);
	self.occupied = alloc::new_array(allocator, bool, (sz)capacity);
	foreach (&entry : self.occupied) *entry = false;
}

fn void ValidationNameIndex.deinit(&self)
{
	alloc::free(self.allocator, self.names);
	alloc::free(self.allocator, self.occupied);
	*self = { };
}

fn bool ValidationNameIndex.contains(&self, String name)
{
	usz mask = self.names.len - 1;
	usz slot = (usz)validation_hash_string(name) & mask;
	for (usz probe = 0; probe < self.names.len; probe++)
	{
		if (!self.occupied[slot]) return false;
		if (self.names[slot] == name) return true;
		slot = (slot + 1) & mask;
	}
	return false;
}

/** Returns true exactly when `name` was not already present. */
fn bool ValidationNameIndex.insert(&self, String name)
{
	usz mask = self.names.len - 1;
	usz slot = (usz)validation_hash_string(name) & mask;
	for (usz probe = 0; probe < self.names.len; probe++)
	{
		if (!self.occupied[slot])
		{
			self.occupied[slot] = true;
			self.names[slot] = name;
			return true;
		}
		if (self.names[slot] == name) return false;
		slot = (slot + 1) & mask;
	}
	return false;
}

struct ValidationMethodIndex
{
	Allocator allocator;
	Program* program;
	usz[] buckets;
}

fn ulong validation_hash_symbol_key(SymbolKey* key) @private
{
	ulong hash = validation_hash_string(key.owner.canonical);
	hash ^= (ulong)key.kind;
	hash *= 1099511628211UL;
	hash ^= (ulong)key.arity;
	hash *= 1099511628211UL;
	hash ^= validation_hash_string(key.name);
	hash *= 1099511628211UL;
	hash ^= validation_hash_string(key.canonical_signature);
	return hash;
}

fn ulong validation_method_hash(FunctionDecl* function) @private
{
	return validation_hash_symbol_key(&function.key);
}

fn void ValidationMethodIndex.init(&self, Program* program, Allocator allocator)
{
	self.allocator = allocator;
	self.program = program;
	self.buckets = alloc::new_array(
		allocator, usz, (sz)validation_index_capacity(program.functions.len)
	);
	foreach (&bucket : self.buckets) *bucket = 0;
}

fn void ValidationMethodIndex.deinit(&self)
{
	alloc::free(self.allocator, self.buckets);
	*self = { };
}

/** Returns true exactly when the current method signature was not indexed. */
fn bool ValidationMethodIndex.insert(&self, usz function_index)
{
	FunctionDecl* function = &self.program.functions[function_index];
	usz mask = self.buckets.len - 1;
	usz slot = (usz)validation_method_hash(function) & mask;
	for (usz probe = 0; probe < self.buckets.len; probe++)
	{
		usz entry = self.buckets[slot];
		if (!entry)
		{
			self.buckets[slot] = function_index + 1;
			return true;
		}
		if (method_signature_equal(&self.program.functions[entry - 1], function)) return false;
		slot = (slot + 1) & mask;
	}
	return false;
}


struct ConstructorRef
{
	sz enum_index;
	sz variant_index;
	bool found;
}

struct ValidationConstructorIndex
{
	Allocator allocator;
	Program* program;
	ConstructorRef[] buckets;
}

fn void ValidationConstructorIndex.init(
	&self,
	Program* program,
	Allocator allocator,
	usz constructor_count
)
{
	self.allocator = allocator;
	self.program = program;
	self.buckets = alloc::new_array(
		allocator, ConstructorRef, (sz)validation_index_capacity(constructor_count)
	);
	foreach (&entry : self.buckets) *entry = { };
	usz mask = self.buckets.len - 1;
	foreach (enum_index, &enum_decl : program.enums)
	{
		foreach (variant_index, &variant : enum_decl.variants)
		{
			usz slot = (usz)validation_hash_string(variant.name) & mask;
			for (usz probe = 0; probe < self.buckets.len; probe++)
			{
				ConstructorRef* entry = &self.buckets[slot];
				if (!entry.found)
				{
					*entry = {
						.enum_index = (sz)enum_index,
						.variant_index = (sz)variant_index,
						.found = true,
					};
					break;
				}
				VariantDecl* indexed = &program.enums[(usz)entry.enum_index]
					.variants[(usz)entry.variant_index];
				if (indexed.name == variant.name) break;
				slot = (slot + 1) & mask;
			}
		}
	}
}

fn void ValidationConstructorIndex.deinit(&self)
{
	alloc::free(self.allocator, self.buckets);
	*self = { };
}

fn ConstructorRef ValidationConstructorIndex.find(&self, String name)
{
	if (!self.buckets.len || !name.len) return { };
	usz mask = self.buckets.len - 1;
	usz slot = (usz)validation_hash_string(name) & mask;
	for (usz probe = 0; probe < self.buckets.len; probe++)
	{
		ConstructorRef entry = self.buckets[slot];
		if (!entry.found) return { };
		VariantDecl* variant = &self.program.enums[(usz)entry.enum_index]
			.variants[(usz)entry.variant_index];
		if (variant.name == name) return entry;
		slot = (slot + 1) & mask;
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
	if ((usz)diagnostics.len() >= MITOS_MAX_VALIDATION_DIAGNOSTICS) return;
	MitosDiagnostic diagnostic;
	if ((usz)diagnostics.len() + 1 == MITOS_MAX_VALIDATION_DIAGNOSTICS)
	{
		diagnostic.init(allocator, "additional validation diagnostics omitted", span);
	}
	else
	{
		diagnostic.init(allocator, message, span);
	}
	diagnostics.push(diagnostic);
}


struct ValidationLexicalScope
{
	ValidationLexicalScope* parent;
	String[] names;
	ParallelBinding[] parallel_bindings;
}

fn bool validation_scope_contains(
	ValidationLexicalScope* scope,
	String name
) @private
{
	for (ValidationLexicalScope* current = scope; current; current = current.parent)
	{
		foreach (candidate : current.names) if (candidate == name) return true;
		foreach (&binding : current.parallel_bindings)
			if (binding.name == name) return true;
	}
	return false;
}


fn void validate_application(
	Program* program,
	ValidationConstructorIndex* constructors,
	SurfaceExpr* expression,
	ValidationLexicalScope* scope,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	ApplicationExpr* application = &expression.data.application;
	bool constructor_call        = false;
	if (application.callee && application.callee.kind == SURFACE_VARIABLE)
	{
		String callee_name = application.callee.data.variable.name;
		bool lexical_callee = validation_scope_contains(scope, callee_name);
		if (!lexical_callee && callee_name == "superpose" && !application.arguments.len)
		{
			add_validation_error(
				diagnostics, allocator, "superpose requires at least one branch", expression.span
			);
		}
		if (!lexical_callee && callee_name == "collapse" && application.arguments.len != 1)
		{
			add_validation_error(
				diagnostics, allocator, "collapse expects exactly one argument", expression.span
			);
		}
		ConstructorRef reference = constructors.find(callee_name);
		if (reference.found && !lexical_callee)
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
	if (!constructor_call)
	{
		validate_expression(
			program, constructors, application.callee, scope, diagnostics, allocator
		);
	}
	foreach (argument : application.arguments)
		validate_expression(program, constructors, argument, scope, diagnostics, allocator);
}

fn void validate_match(
	Program* program,
	ValidationConstructorIndex* constructors,
	SurfaceExpr* expression,
	ValidationLexicalScope* scope,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	validate_expression(
		program, constructors, expression.data.match_expr.scrutinee, scope,
		diagnostics, allocator
	);
	sz matched_enum = -1;
	bool wildcard   =  false;
	ValidationNameIndex explicit_constructors;
	explicit_constructors.init(allocator, expression.data.match_expr.arms.len);
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
			ConstructorRef reference = constructors.find(arm.pattern.constructor);
			if (!reference.found)
			{
				add_validation_error(diagnostics, allocator, "unknown constructor in match pattern", arm.pattern.span);
			}
			else
			{
				VariantDecl* variant = &program.enums[(usz)reference.enum_index].variants[(usz)reference.variant_index];
				if (!explicit_constructors.insert(arm.pattern.constructor))
				{
					add_validation_error(
						diagnostics, allocator,
						"duplicate constructor arm in match", arm.pattern.span
					);
				}
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
		ValidationLexicalScope arm_scope = {
			.parent = scope,
			.names = arm.pattern.bindings,
		};
		validate_expression(
			program, constructors, arm.body, &arm_scope, diagnostics, allocator
		);
	}
	if (matched_enum < 0)
	{
		add_validation_error(
			diagnostics,
			allocator,
			"match needs a constructor arm to identify its enum",
			expression.span
		);
		explicit_constructors.deinit();
		return;
	}
	EnumDecl* enum_decl = &program.enums[(usz)matched_enum];
	foreach (&variant : enum_decl.variants)
	{
		if (!wildcard && !explicit_constructors.contains(variant.name))
		{
			add_validation_error(diagnostics, allocator, "non-exhaustive match", expression.span);
			break;
		}
	}
	explicit_constructors.deinit();
}

fn void validate_expression(
	Program* program,
	ValidationConstructorIndex* constructors,
	SurfaceExpr* expression,
	ValidationLexicalScope* scope,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	if (!expression) return;
	switch (expression.kind)
	{
		case SURFACE_VARIABLE:
			String variable_name = expression.data.variable.name;
			ConstructorRef reference = constructors.find(variable_name);
			if (reference.found && !validation_scope_contains(scope, variable_name)
				&& program.enums[(usz)reference.enum_index]
					.variants[(usz)reference.variant_index].parameters.len != 0)
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
			ValidationLexicalScope lambda_scope = {
				.parent = scope,
				.names = expression.data.lambda.parameters,
			};
			validate_expression(
				program, constructors, expression.data.lambda.body, &lambda_scope,
				diagnostics, allocator
			);
		case SURFACE_APPLICATION:
			validate_application(
				program, constructors, expression, scope, diagnostics, allocator
			);
		case SURFACE_EFFECT_OPERATION:
			foreach (argument : expression.data.effect_operation.arguments)
			{
				validate_expression(
					program, constructors, argument, scope, diagnostics, allocator
				);
			}
		case SURFACE_BINARY:
			validate_expression(
				program, constructors, expression.data.binary.left, scope,
				diagnostics, allocator
			);
			validate_expression(
				program, constructors, expression.data.binary.right, scope,
				diagnostics, allocator
			);
		case SURFACE_DEFINITION:
			DefinitionExpr* definition = &expression.data.definition;
			for (
				SurfaceExpr* nested = definition.body;
				nested && nested.kind == SURFACE_DEFINITION;
				nested = nested.data.definition.body
			)
			{
				if (nested.data.definition.name == definition.name)
				{
					add_validation_error(
						diagnostics,
						allocator,
						"duplicate definition in the same block",
						nested.span
					);
				}
			}
			validate_expression(
				program, constructors, definition.value, scope, diagnostics, allocator
			);
			String[1] definition_name = { definition.name };
			ValidationLexicalScope definition_scope = {
				.parent = scope,
				.names = definition_name[..],
			};
			validate_expression(
				program, constructors, definition.body, &definition_scope,
				diagnostics, allocator
			);
		case SURFACE_MATCH:
			validate_match(
				program, constructors, expression, scope, diagnostics, allocator
			);
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
			ParallelBinding[] parallel_bindings = expression.data.parallel.bindings;
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
				validate_expression(
					program, constructors, binding.value, scope, diagnostics, allocator
				);
			}
			ValidationLexicalScope parallel_scope = {
				.parent = scope,
				.parallel_bindings = parallel_bindings,
			};
			validate_expression(
				program, constructors, expression.data.parallel.result, &parallel_scope,
				diagnostics, allocator
			);
		case SURFACE_HANDLER:
			validate_expression(
				program, constructors, expression.data.handler.handled, scope,
				diagnostics, allocator
			);
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
				ValidationLexicalScope clause_scope = {
					.parent = scope,
					.names = clause.parameters,
				};
				validate_expression(
					program, constructors, clause.body, &clause_scope,
					diagnostics, allocator
				);
			}
			if (!expression.data.handler.return_clause.body)
			{
				add_validation_error(diagnostics, allocator, "handler requires exactly one return clause", expression.span);
			}
			else
			{
				String[1] return_name = {
					expression.data.handler.return_clause.parameter,
				};
				ValidationLexicalScope return_scope = {
					.parent = scope,
					.names = return_name[..],
				};
				validate_expression(
					program, constructors,
					expression.data.handler.return_clause.body, &return_scope,
					diagnostics, allocator
				);
			}
		case SURFACE_RESUME:
			validate_expression(
				program, constructors, expression.data.resume.value, scope,
				diagnostics, allocator
			);
		default:
	}
}

fn MitosDiagnostic[] validate_program(Program* program, Allocator allocator = mem)
{
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);
	bool found_main = false;
	usz constructor_count = 0;
	foreach (&enum_decl : program.enums) constructor_count += enum_decl.variants.len;

	ValidationNameIndex enum_names;
	ValidationNameIndex constructor_names;
	ValidationNameIndex type_names;
	ValidationNameIndex effect_names;
	ValidationMethodIndex method_signatures;
	ValidationConstructorIndex constructors;
	enum_names.init(allocator, program.enums.len);
	constructor_names.init(allocator, constructor_count);
	type_names.init(allocator, program.types.len);
	effect_names.init(allocator, program.effects.len);
	method_signatures.init(program, allocator);
	constructors.init(program, allocator, constructor_count);

	foreach (&enum_decl : program.enums)
	{
		if (!symbol_key_matches_declaration(
			&enum_decl.key, &program.module_key, SYMBOL_ENUM,
			enum_decl.name, enum_decl.parameters.len, ""
		))
		{
			add_validation_error(
				&diagnostics, allocator,
				"enum declaration has an invalid canonical identity", enum_decl.span
			);
		}
		if (!enum_names.insert(enum_decl.name))
		{
			add_validation_error(&diagnostics, allocator, "duplicate enum declaration", enum_decl.span);
		}
		foreach (parameter_index, &parameter : enum_decl.parameters)
		{
			for (sz previous_index = 0; previous_index < parameter_index; previous_index++)
			{
				if (enum_decl.parameters[(usz)previous_index].name != parameter.name) continue;
				add_validation_error(&diagnostics, allocator, "duplicate enum type parameter", parameter.span);
				break;
			}
		}
		ValidationNameIndex variant_names;
		variant_names.init(allocator, enum_decl.variants.len);
		foreach (&variant : enum_decl.variants)
		{
			if (!variant.key.canonical_signature.len
				|| !symbol_key_matches_declaration(
					&variant.key, &program.module_key, SYMBOL_VARIANT,
					variant.name, variant.parameters.len, variant.key.canonical_signature
				))
			{
				add_validation_error(
					&diagnostics, allocator,
					"constructor declaration has an invalid canonical identity", variant.span
				);
			}
			if (!variant_names.insert(variant.name))
			{
				add_validation_error(&diagnostics, allocator, "duplicate enum variant", variant.span);
			}
			if (!constructor_names.insert(variant.name))
			{
				add_validation_error(
					&diagnostics,
					allocator,
					"constructor names must be unique across enums",
					variant.span
				);
			}
			foreach (parameter_index, parameter : variant.parameters)
			{
				for (sz previous_index = 0; previous_index < parameter_index; previous_index++)
				{
					if (variant.parameters[(usz)previous_index] != parameter) continue;
					add_validation_error(&diagnostics, allocator, "duplicate constructor parameter", variant.span);
					break;
				}
			}
		}
		variant_names.deinit();
	}

	foreach (&type_decl : program.types)
	{
		if (!symbol_key_matches_declaration(
			&type_decl.key, &program.module_key, SYMBOL_TYPE,
			type_decl.name, type_decl.parameters.len, ""
		))
		{
			add_validation_error(
				&diagnostics, allocator,
				"type declaration has an invalid canonical identity", type_decl.span
			);
		}
		if (!type_names.insert(type_decl.name))
		{
			add_validation_error(&diagnostics, allocator, "duplicate type declaration", type_decl.span);
		}
		if (enum_names.contains(type_decl.name))
		{
			add_validation_error(&diagnostics, allocator, "type name collides with an enum name", type_decl.span);
		}
		foreach (parameter_index, &parameter : type_decl.parameters)
		{
			for (sz previous_index = 0; previous_index < parameter_index; previous_index++)
			{
				if (type_decl.parameters[(usz)previous_index].name != parameter.name) continue;
				add_validation_error(&diagnostics, allocator, "duplicate type parameter", parameter.span);
				break;
			}
		}
		ValidationNameIndex field_names;
		field_names.init(allocator, type_decl.fields.len);
		foreach (&field : type_decl.fields)
		{
			if (!field_names.insert(field.name))
			{
				add_validation_error(&diagnostics, allocator, "duplicate type field", field.span);
			}
		}
		field_names.deinit();
		if (type_decl.kind == TYPE_DECL_ABSTRACT && type_decl.fields.len)
		{
			add_validation_error(&diagnostics, allocator, "abstract types cannot declare fields", type_decl.span);
		}
	}

	foreach (&effect : program.effects)
	{
		if (!symbol_key_matches_declaration(
			&effect.key, &program.module_key, SYMBOL_EFFECT,
			effect.name, effect.parameters.len, ""
		))
		{
			add_validation_error(
				&diagnostics, allocator,
				"effect declaration has an invalid canonical identity", effect.span
			);
		}
		if (!effect_names.insert(effect.name))
		{
			add_validation_error(&diagnostics, allocator, "duplicate effect declaration", effect.span);
		}
		ValidationNameIndex operation_names;
		operation_names.init(allocator, effect.operations.len);
		foreach (&operation : effect.operations)
		{
			if (!operation.key.canonical_signature.len
				|| !symbol_key_matches_declaration(
					&operation.key, &effect.key.owner, SYMBOL_EFFECT_OPERATION,
					operation.name, operation.parameters.len, operation.key.canonical_signature
				))
			{
				add_validation_error(
					&diagnostics, allocator,
					"effect operation has an invalid canonical identity", operation.span
				);
			}
			if (!operation_names.insert(operation.name))
			{
				add_validation_error(&diagnostics, allocator, "duplicate effect operation", operation.span);
			}
			foreach (parameter_index, parameter : operation.parameters)
			{
				for (sz previous_index = 0; previous_index < parameter_index; previous_index++)
				{
					if (operation.parameters[(usz)previous_index] != parameter) continue;
					add_validation_error(&diagnostics, allocator, "duplicate effect operation parameter", operation.span);
					break;
				}
			}
		}
		operation_names.deinit();
	}

	foreach (function_index, &function : program.functions)
	{
		if (!symbol_key_matches_declaration(
			&function.generic_key, &function.generic_key.owner, SYMBOL_GENERIC,
			function.name, function.parameters.len, ""
		) || !function.key.canonical_signature.len
			|| !symbol_key_matches_declaration(
				&function.key, &function.key.owner, SYMBOL_METHOD,
				function.name, function.parameters.len, function.key.canonical_signature
			))
		{
			add_validation_error(
				&diagnostics, allocator,
				"function declaration has an invalid canonical identity", function.span
			);
		}
		if (!method_signatures.insert((usz)function_index))
		{
			add_validation_error(&diagnostics, allocator, "duplicate method signature", function.span);
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
		if (enum_names.contains(function.name))
		{
			add_validation_error(&diagnostics, allocator, "duplicate declaration name", function.span);
		}
		if (constructor_names.contains(function.name))
		{
			add_validation_error(
				&diagnostics,
				allocator,
				"generic function name collides with a constructor name",
				function.span
			);
		}
		if (type_names.contains(function.name))
		{
			add_validation_error(&diagnostics, allocator, "generic function name collides with a type name", function.span);
		}
		foreach (parameter_index, parameter : function.parameters)
		{
			for (sz previous_index = 0; previous_index < parameter_index; previous_index++)
			{
				if (function.parameters[(usz)previous_index] != parameter) continue;
				add_validation_error(&diagnostics, allocator, "duplicate function parameter", function.span);
				break;
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
		ValidationLexicalScope function_scope = { .names = function.parameters };
		validate_expression(
			program, &constructors, function.body, &function_scope, &diagnostics, allocator
		);
	}
	if (!found_main)
	{
		MitosPosition start = { .offset = 0, .row = 1, .column = 1 };
		add_validation_error(&diagnostics, allocator, "program must declare main", { .start = start, .end = start });
	}

	method_signatures.deinit();
	constructors.deinit();
	effect_names.deinit();
	type_names.deinit();
	constructor_names.deinit();
	enum_names.deinit();
	MitosDiagnostic[] result = diagnostics.to_array(allocator);
	diagnostics.free();
	return result;
}
