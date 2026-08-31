module delta_net_abstract_machine::mitos;

import std::collections::list;
import std::core::mem;

/** Stable on-disk/in-memory schema version for allocator-owned Delta programs. */
const uint DELTA_PROGRAM_FORMAT_VERSION = 3;
const uint DELTA_HELPER_ABI_MAJOR = 1;
const uint DELTA_HELPER_ABI_MINOR = 2;

typedef DeltaNodeId = uint;
const DeltaNodeId DELTA_NODE_INVALID = (DeltaNodeId)0;
const usz DELTA_MAX_EVALUATION_DEPTH = 512;
const usz DELTA_MAX_EVALUATION_STEPS = 10_000_000;

enum DeltaNodeKind : char
{
	DELTA_LOCAL,
	DELTA_I64,
	DELTA_LAMBDA,
	DELTA_APPLY,
	DELTA_LET,
	DELTA_CONSTRUCTOR,
	DELTA_MATCH,
	DELTA_GENERIC_CALL,
	DELTA_TYPE_VALUE,
	DELTA_TYPE_ASSERT,
	DELTA_TYPE_OF,
	DELTA_PRIMITIVE,
	DELTA_PARALLEL_ROOT,
	DELTA_PARALLEL_JOIN,
	DELTA_EFFECT,
	DELTA_HANDLER,
	DELTA_RESUME,
	DELTA_ABORT,
	DELTA_STRING,
	DELTA_SUPERPOSE,
	DELTA_COLLAPSE,
}

enum DeltaPrimitiveOp : char
{
	DELTA_PRIMITIVE_ADD,
	DELTA_PRIMITIVE_SUBTRACT,
	DELTA_PRIMITIVE_MULTIPLY,
	DELTA_PRIMITIVE_DIVIDE,
	DELTA_PRIMITIVE_REMAINDER,
	DELTA_PRIMITIVE_EQUAL,
	DELTA_PRIMITIVE_LESS,
	DELTA_PRIMITIVE_LESS_EQUAL,
	DELTA_PRIMITIVE_GREATER,
	DELTA_PRIMITIVE_GREATER_EQUAL,
}

enum DeltaInterfaceKind : char
{
	DELTA_INTERFACE_ENTRY,
	DELTA_INTERFACE_METHOD,
	DELTA_INTERFACE_PARALLEL_ROOT,
	DELTA_INTERFACE_PARALLEL_JOIN,
}

enum DeltaEffectHostKind : char
{
	DELTA_EFFECT_PURE,
	DELTA_EFFECT_ORDERED,
	DELTA_EFFECT_EXTERNAL,
}

enum DeltaResumeState : char
{
	DELTA_CONTINUATION_CAPTURED,
	DELTA_CONTINUATION_RESUMED,
	DELTA_CONTINUATION_ERASED,
	DELTA_CONTINUATION_REPLICATED,
}

struct DeltaPrimitiveDescriptor
{
	uint id;
	DeltaPrimitiveOp operation;
	String name;
	usz arity;
	TypeId[] parameters;
	TypeId result;
}

struct DeltaConstructorDescriptor
{
	uint id;
	String name;
	TypeId runtime_type;
	TypeId type_constructor;
	String[] parameters;
	String[] fields;
	TypeId[] field_types;
	TypePattern[] field_patterns;
	MitosSpan span;
}

struct DeltaMatchBranch
{
	bool wildcard;
	uint constructor;
	String[] bindings;
	DeltaNodeId body;
	uint span;
}

/** A source-free executable node. All references are stable array identities. */
struct DeltaNode
{
	uint stable_id;
	DeltaNodeKind kind;
	TypeId static_type;
	uint span;
	long integer;
	String string_value;
	usz descriptor;
	String name;
	String[] names;
	TypeId[] types;
	TypeId runtime_type;
	TypeId result_type;
	EffectId[] effect_row;
	DeltaNodeId[] inputs;
	DeltaMatchBranch[] branches;
}

struct DeltaEdge
{
	DeltaNodeId producer;
	DeltaNodeId consumer;
	usz input;
}

struct DeltaInterface
{
	DeltaInterfaceKind kind;
	String name;
	DeltaNodeId root;
	usz source_order;
}

struct DeltaParallelRegion
{
	DeltaNodeId[] roots;
	DeltaNodeId join;
	usz source_order;
}

/** Serializable practical graph image embedded in a DeltaProgram. */
struct NetImage
{
	DeltaNode[] nodes;
	DeltaEdge[] edges;
	DeltaInterface[] interfaces;
	DeltaParallelRegion[] parallel_regions;
}

struct DeltaMethodRoot
{
	usz function_index;
	usz generic_index;
	usz method_index;
	DeltaNodeId root;
	String[] parameters;
	TypeId[] parameter_types;
	MethodTypePattern[] parameter_patterns;
	TypeId result_type;
	MethodTypePattern result_pattern;
	EffectId[] effect_row;
	usz source_order;
}

struct DeltaEffectDescriptor
{
	EffectId id;
	String name;
	bool multi;
	String[] parameters;
	OperationId[] operations;
	uint span;
}

struct DeltaOperationDescriptor
{
	OperationId id;
	EffectId effect;
	String name;
	String[] parameter_patterns;
	TypePattern[] parameter_types;
	String result_pattern;
	TypePattern result_type;
	uint span;
	DeltaEffectHostKind host_kind;
	bool ordered;
}
struct DeltaEffectInstanceDescriptor
{
	EffectId id;
	EffectId constructor;
	TypeId[] arguments;
}


struct DeltaEffectRowDescriptor
{
	usz function_index;
	EffectId[] inferred;
	EffectId[] asserted;
	bool has_assertion;
	ulong effect_epoch;
}

struct DeltaHandlerClauseDescriptor
{
	uint stable_id;
	EffectId effect;
	OperationId operation;
	String[] parameters;
	TypeId[] parameter_types;
	TypeId result_type;
	DeltaNodeId body;
	uint span;
	usz resume_count;
	bool multi;
}

struct DeltaHandlerDescriptor
{
	uint stable_id;
	DeltaNodeId handled;
	DeltaHandlerClauseDescriptor[] clauses;
	String return_parameter;
	TypeId return_type;
	DeltaNodeId return_body;
	uint span;
	usz source_order;
}

struct DeltaEffectSection
{
	EffectId next_effect_id;
	OperationId next_operation_id;
	ulong epoch;
	DeltaEffectDescriptor[] effects;
	DeltaOperationDescriptor[] operations;
	DeltaEffectInstanceDescriptor[] instances;
	DeltaEffectRowDescriptor[] rows;
	DeltaHandlerDescriptor[] handlers;
}

struct DeltaHelperAbi
{
	uint major;
	uint minor;
	ulong feature_bits;
	uint effect_tag;
	uint handler_tag;
	uint resume_tag;
	uint abort_tag;
}

/** Sole executable semantic IR. It owns every referenced string and slice. */
struct DeltaProgram
{
	Allocator allocator;
	uint format_version;
	TypeRegistry types;
	GenericFunctionTable methods;
	DeltaConstructorDescriptor[] constructors;
	DeltaPrimitiveDescriptor[] primitives;
	NetImage image;
	DeltaMethodRoot[] method_roots;
	DeltaNodeId entry;
	MitosSpan[] spans;
	DeltaEffectSection effects;
	DeltaHelperAbi helper_abi;
}

struct DeltaProgramBuildResult
{
	Allocator allocator;
	DeltaProgram program;
	MitosDiagnostic[] diagnostics;
}

fn bool DeltaProgramBuildResult.ok(&self) => self.diagnostics.len == 0;

fn void DeltaConstructorDescriptor.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.name);
	foreach (parameter : self.parameters) alloc::free(allocator, parameter);
	alloc::free(allocator, self.parameters);
	foreach (field : self.fields) alloc::free(allocator, field);
	alloc::free(allocator, self.fields);
	alloc::free(allocator, self.field_types);
	foreach (&pattern : self.field_patterns) pattern.deinit(allocator);
	alloc::free(allocator, self.field_patterns);
	*self = { };
}

fn void DeltaPrimitiveDescriptor.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.name);
	alloc::free(allocator, self.parameters);
	*self = { };
}

fn void DeltaNode.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.string_value);
	alloc::free(allocator, self.name);
	foreach (name : self.names) alloc::free(allocator, name);
	alloc::free(allocator, self.names);
	alloc::free(allocator, self.types);
	alloc::free(allocator, self.effect_row);
	alloc::free(allocator, self.inputs);
	foreach (&branch : self.branches)
	{
		foreach (binding : branch.bindings) alloc::free(allocator, binding);
		alloc::free(allocator, branch.bindings);
	}
	alloc::free(allocator, self.branches);
	*self = { };
}

fn void DeltaEffectSection.deinit(&self, Allocator allocator)
{
	foreach (&effect : self.effects)
	{
		alloc::free(allocator, effect.name);
		foreach (parameter : effect.parameters) alloc::free(allocator, parameter);
		alloc::free(allocator, effect.parameters);
		alloc::free(allocator, effect.operations);
	}
	alloc::free(allocator, self.effects);
	foreach (&operation : self.operations)
	{
		alloc::free(allocator, operation.name);
		foreach (pattern : operation.parameter_patterns) alloc::free(allocator, pattern);
		alloc::free(allocator, operation.parameter_patterns);
		alloc::free(allocator, operation.result_pattern);
		foreach (&pattern : operation.parameter_types) pattern.deinit(allocator);
		alloc::free(allocator, operation.parameter_types);
		operation.result_type.deinit(allocator);
	}
	alloc::free(allocator, self.operations);
	foreach (&instance : self.instances) alloc::free(allocator, instance.arguments);
	alloc::free(allocator, self.instances);
	foreach (&row : self.rows)
	{
		alloc::free(allocator, row.inferred);
		alloc::free(allocator, row.asserted);
	}
	alloc::free(allocator, self.rows);
	foreach (&handler : self.handlers)
	{
		foreach (&clause : handler.clauses)
		{
			foreach (parameter : clause.parameters) alloc::free(allocator, parameter);
			alloc::free(allocator, clause.parameters);
			alloc::free(allocator, clause.parameter_types);
		}
		alloc::free(allocator, handler.clauses);
		alloc::free(allocator, handler.return_parameter);
	}
	alloc::free(allocator, self.handlers);
	*self = { };
}

fn void NetImage.deinit(&self, Allocator allocator)
{
	foreach (&node : self.nodes) node.deinit(allocator);
	alloc::free(allocator, self.nodes);
	alloc::free(allocator, self.edges);
	foreach (&boundary : self.interfaces) alloc::free(allocator, boundary.name);
	alloc::free(allocator, self.interfaces);
	foreach (&region : self.parallel_regions) alloc::free(allocator, region.roots);
	alloc::free(allocator, self.parallel_regions);
	*self = { };
}

fn void DeltaProgram.deinit(&self)
{
	if (!self.allocator) return;
	self.types.deinit();
	self.methods.deinit();
	foreach (&constructor : self.constructors) constructor.deinit(self.allocator);
	alloc::free(self.allocator, self.constructors);
	foreach (&primitive : self.primitives) primitive.deinit(self.allocator);
	alloc::free(self.allocator, self.primitives);
	self.image.deinit(self.allocator);
	foreach (&method : self.method_roots)
	{
		foreach (parameter : method.parameters) alloc::free(self.allocator, parameter);
		alloc::free(self.allocator, method.parameters);
		alloc::free(self.allocator, method.parameter_types);
		foreach (&pattern : method.parameter_patterns) pattern.deinit(self.allocator);
		alloc::free(self.allocator, method.parameter_patterns);
		method.result_pattern.deinit(self.allocator);
		alloc::free(self.allocator, method.effect_row);
	}
	alloc::free(self.allocator, self.method_roots);
	alloc::free(self.allocator, self.spans);
	self.effects.deinit(self.allocator);
	*self = { };
}

fn void DeltaProgramBuildResult.deinit(&self)
{
	if (!self.allocator) return;
	self.program.deinit();
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = { };
}

fn DeltaNode* delta_node(DeltaProgram* program, DeltaNodeId id)
{
	if (!program || id == DELTA_NODE_INVALID || (usz)id > program.image.nodes.len) return null;
	return &program.image.nodes[(usz)id - 1];
}
