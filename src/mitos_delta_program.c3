module delta_net_abstract_machine::mitos;

import std::collections::list;
import std::core::mem;

/** Clean-cut persistent Delta schema 4.0 and runtime-helper ABI 2.0. */
const uint DELTA_PROGRAM_SCHEMA_MAJOR = 4;
const uint DELTA_PROGRAM_SCHEMA_MINOR = 0;
const uint DELTA_HELPER_ABI_MAJOR = 2;
const uint DELTA_HELPER_ABI_MINOR = 0;
const uint DELTA_AOT_CONTAINER_MAJOR = 4;
const uint DELTA_AOT_CONTAINER_MINOR = 0;

typedef DeltaFeatureBits = ulong;
const DeltaFeatureBits DELTA_FEATURE_TYPED = (DeltaFeatureBits)1 << 0;
const DeltaFeatureBits DELTA_FEATURE_EFFECTS = (DeltaFeatureBits)1 << 1;
const DeltaFeatureBits DELTA_FEATURE_PARALLEL = (DeltaFeatureBits)1 << 2;
const DeltaFeatureBits DELTA_FEATURE_HOST = (DeltaFeatureBits)1 << 3;
const DeltaFeatureBits DELTA_FEATURE_SUPERPOSITION = (DeltaFeatureBits)1 << 4;
const DeltaFeatureBits DELTA_FEATURE_IDENTITY_KEYS = (DeltaFeatureBits)1 << 5;
const DeltaFeatureBits DELTA_FEATURE_EFFECT_ROWS = (DeltaFeatureBits)1 << 6;
const DeltaFeatureBits DELTA_FEATURE_LAYOUTS = (DeltaFeatureBits)1 << 7;
const DeltaFeatureBits DELTA_FEATURE_SUSPENSION = (DeltaFeatureBits)1 << 8;
const DeltaFeatureBits DELTA_FEATURE_TAGGED_RECORDS = (DeltaFeatureBits)1 << 9;
const DeltaFeatureBits DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES = (DeltaFeatureBits)1 << 10;
const DeltaFeatureBits DELTA_FEATURE_ALL_KNOWN =
	DELTA_FEATURE_TYPED
	| DELTA_FEATURE_EFFECTS
	| DELTA_FEATURE_PARALLEL
	| DELTA_FEATURE_HOST
	| DELTA_FEATURE_SUPERPOSITION
	| DELTA_FEATURE_IDENTITY_KEYS
	| DELTA_FEATURE_EFFECT_ROWS
	| DELTA_FEATURE_LAYOUTS
	| DELTA_FEATURE_SUSPENSION
	| DELTA_FEATURE_TAGGED_RECORDS
	| DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES;

const uint DELTA_EFFECT_AGENT_TAG = 32;
const DeltaFeatureBits DELTA_V4_CORE_REQUIRED_FEATURES =
	DELTA_FEATURE_IDENTITY_KEYS
	| DELTA_FEATURE_EFFECT_ROWS
	| DELTA_FEATURE_LAYOUTS
	| DELTA_FEATURE_TAGGED_RECORDS;
const uint DELTA_HANDLER_AGENT_TAG = 33;
const uint DELTA_RESUME_AGENT_TAG = 34;
const uint DELTA_ABORT_AGENT_TAG = 35;

struct DeltaSchemaVersion
{
	uint major;
	uint minor;
}

struct DeltaFeatureManifest
{
	DeltaFeatureBits required;
	DeltaFeatureBits optional;
}

fn DeltaFeatureManifest delta_feature_manifest(
	DeltaFeatureBits required,
	DeltaFeatureBits optional
)
{
	return { .required = required, .optional = optional };
}

fn DeltaSchemaVersion delta_schema_v4()
{
	return {
		.major = DELTA_PROGRAM_SCHEMA_MAJOR,
		.minor = DELTA_PROGRAM_SCHEMA_MINOR,
	};
}

typedef DeltaRecordTag = uint;
typedef DeltaRecordFlags = uint;
const DeltaRecordFlags DELTA_RECORD_REQUIRED = (DeltaRecordFlags)1 << 0;
const DeltaRecordFlags DELTA_RECORD_OPTIONAL = (DeltaRecordFlags)1 << 1;
const DeltaRecordFlags DELTA_RECORD_ALL_FLAGS =
	DELTA_RECORD_REQUIRED | DELTA_RECORD_OPTIONAL;

const DeltaRecordTag DELTA_RECORD_MANIFEST = (DeltaRecordTag)1;
const DeltaRecordTag DELTA_RECORD_MODULE = (DeltaRecordTag)2;
const DeltaRecordTag DELTA_RECORD_TYPES = (DeltaRecordTag)3;
const DeltaRecordTag DELTA_RECORD_METHODS = (DeltaRecordTag)4;
const DeltaRecordTag DELTA_RECORD_CONSTRUCTORS = (DeltaRecordTag)5;
const DeltaRecordTag DELTA_RECORD_PRIMITIVES = (DeltaRecordTag)6;
const DeltaRecordTag DELTA_RECORD_NODES = (DeltaRecordTag)7;
const DeltaRecordTag DELTA_RECORD_GRAPH = (DeltaRecordTag)8;
const DeltaRecordTag DELTA_RECORD_ROOTS = (DeltaRecordTag)9;
const DeltaRecordTag DELTA_RECORD_SPANS = (DeltaRecordTag)10;
const DeltaRecordTag DELTA_RECORD_EFFECTS = (DeltaRecordTag)11;
const DeltaRecordTag DELTA_RECORD_HELPER_ABI = (DeltaRecordTag)12;
const DeltaRecordTag DELTA_RECORD_LAST_CORE = DELTA_RECORD_HELPER_ABI;

/** Fixed-width envelope for bounded, length-delimited schema-4 records. */
struct DeltaTaggedRecordHeader
{
	DeltaRecordTag tag;
	DeltaRecordFlags flags;
	ulong byte_length;
}

fn bool delta_tagged_record_header_is_valid(DeltaTaggedRecordHeader header)
{
	return header.tag
		&& !(header.flags & ~DELTA_RECORD_ALL_FLAGS)
		&& (header.flags == DELTA_RECORD_REQUIRED
			|| header.flags == DELTA_RECORD_OPTIONAL);
}

fn bool delta_feature_manifest_is_valid(DeltaFeatureManifest manifest)
{
	return !(manifest.required & manifest.optional);
}

fn bool delta_feature_manifest_is_supported(
	DeltaFeatureManifest manifest,
	DeltaFeatureBits supported
)
{
	return delta_feature_manifest_is_valid(manifest)
		&& !(manifest.required & ~supported);
}

/**
 * Schema-4 minor releases are additive and feature negotiated. A higher minor
 * is compatible when every required feature is understood.
 */
fn bool delta_schema_is_supported(
	DeltaSchemaVersion schema,
	DeltaFeatureManifest manifest,
	DeltaFeatureBits supported = DELTA_FEATURE_ALL_KNOWN
)
{
	return schema.major == DELTA_PROGRAM_SCHEMA_MAJOR
		&& delta_feature_manifest_is_supported(manifest, supported);
}

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
	SymbolKey key;
	uint id;
	DeltaPrimitiveOp operation;
	String name;
	usz arity;
	TypeId[] parameters;
	TypeId result;
}

struct DeltaConstructorDescriptor
{
	SymbolKey key;
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
	SymbolKey key;
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
	ResolvedEffectRow effect_row;
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
	SymbolKey key;
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
	SymbolKey key;
	SymbolKey generic_key;
	usz function_index;
	usz generic_index;
	usz method_index;
	DeltaNodeId root;
	String[] parameters;
	TypeId[] parameter_types;
	MethodTypePattern[] parameter_patterns;
	TypeId result_type;
	MethodTypePattern result_pattern;
	ResolvedEffectRow effect_row;
	usz source_order;
}

struct DeltaEffectDescriptor
{
	SymbolKey key;
	EffectId id;
	String name;
	bool multi;
	String[] parameters;
	OperationId[] operations;
	uint span;
}

struct DeltaOperationDescriptor
{
	SymbolKey key;
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
	SymbolKey key;
	EffectId id;
	EffectId constructor;
	TypeId[] arguments;
}


struct DeltaEffectRowDescriptor
{
	SymbolKey key;
	usz function_index;
	ResolvedEffectRow inferred;
	ResolvedEffectRow asserted;
	bool has_assertion;
	ulong effect_epoch;
}

struct DeltaHandlerClauseDescriptor
{
	SymbolKey key;
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
	DeltaFeatureManifest features;
	uint effect_tag;
	uint handler_tag;
	uint resume_tag;
	uint abort_tag;
}

fn bool delta_helper_abi_is_supported(
	DeltaHelperAbi* abi,
	DeltaFeatureBits supported
)
{
	return abi
		&& abi.major == DELTA_HELPER_ABI_MAJOR
		&& abi.minor == DELTA_HELPER_ABI_MINOR
		&& delta_feature_manifest_is_supported(abi.features, supported)
		&& abi.effect_tag == DELTA_EFFECT_AGENT_TAG
		&& abi.handler_tag == DELTA_HANDLER_AGENT_TAG
		&& abi.resume_tag == DELTA_RESUME_AGENT_TAG
		&& abi.abort_tag == DELTA_ABORT_AGENT_TAG;
}

fn DeltaHelperAbi delta_helper_abi_v2(DeltaFeatureManifest features)
{
	return {
		.major = DELTA_HELPER_ABI_MAJOR,
		.minor = DELTA_HELPER_ABI_MINOR,
		.features = features,
		.effect_tag = DELTA_EFFECT_AGENT_TAG,
		.handler_tag = DELTA_HANDLER_AGENT_TAG,
		.resume_tag = DELTA_RESUME_AGENT_TAG,
		.abort_tag = DELTA_ABORT_AGENT_TAG,
	};
}

/** Sole executable semantic IR. It owns every referenced string and slice. */
/**
 * Host suspension tokens and execution contexts are runtime-only. They are
 * deliberately absent from this persistent schema.
 */
struct DeltaProgram
{
	Allocator allocator;
	/** Runtime-only capability domain; deliberately omitted from AOT records. */
	ulong runtime_identity;
	ModuleKey module_key;
	DeltaSchemaVersion schema;
	DeltaFeatureManifest feature_manifest;
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

const usz DELTA_PROVENANCE_MIN_WORK = 64;
const usz DELTA_PROVENANCE_MAX_WORK = 1_000_000;

struct DeltaClosureOrigin
{
	DeltaNodeId lambda;
	DeltaClosureBinding* environment;
}

struct DeltaConstructorOrigin
{
	DeltaNodeId constructor;
	DeltaClosureBinding* environment;
}

/**
 * Closure identities are intentionally capped at two: the capability
 * boundary only distinguishes a singleton target from a set of distinct
 * targets. Constructor identities are likewise retained only far enough to
 * recover common field/match flows; overflow is analyzed through every arm
 * with typed unknown fields and therefore fails closed when a closure can
 * escape.
 */
struct DeltaValueProvenance
{
	DeltaClosureOrigin first_closure;
	DeltaClosureOrigin second_closure;
	bool closure_many;
	bool has_effectful_closure;
	bool uncertain_closure;
	bool has_request_free_path;
	bool suspended_request_path;
	bool uncertain_effectful_closure;
	DeltaConstructorOrigin first_constructor;
	DeltaConstructorOrigin second_constructor;
	bool constructor_many;
	bool uncertain_constructor;
}

struct DeltaClosureBinding
{
	DeltaClosureBinding* parent;
	String name;
	DeltaNodeId value;
	DeltaClosureBinding* value_environment;
	TypeId unknown_type;
	bool type_value;
	TypeId represented_type;
	bool has_provenance;
	DeltaValueProvenance provenance;
}

struct DeltaProvenanceFrame
{
	DeltaNodeId node;
	DeltaClosureBinding* bindings;
}

struct DeltaRequestCapture
{
	DeltaRequestCapture* parent;
	DeltaHandlerDescriptor* handler;
	DeltaValueProvenance[] arguments;
	char[] matched_clauses;
	List{DeltaNodeId} holes;
}

struct DeltaProvenanceResume
{
	DeltaProvenanceResume* parent;
	DeltaHandlerDescriptor* handler;
	DeltaNodeId handled;
	DeltaNodeId hole;
	DeltaClosureBinding* bindings;
}

struct DeltaProvenanceSubstitution
{
	DeltaProvenanceSubstitution* parent;
	DeltaNodeId hole;
	DeltaValueProvenance value;
}

struct DeltaProvenanceContext
{
	DeltaProgram* program;
	Allocator allocator;
	usz work;
	usz work_limit;
	bool dynamic_effectful_closure;
	bool failed_closed;
	List{DeltaClosureBinding[]} binding_sets;
	List{DeltaProvenanceFrame} active;
	DeltaRequestCapture* request_capture;
	DeltaProvenanceResume* resume;
	DeltaProvenanceSubstitution* substitution;
	char[] root_active;
	char[] memo_state;
	DeltaValueProvenance[] memo_values;
}

fn bool delta_effect_row_has_effects(ResolvedEffectRow* row)
{
	return row && (row.required.len != 0 || row.has_tail);
}

fn bool delta_provenance_charge(DeltaProvenanceContext* context, usz amount)
{
	if (!context || amount > context.work_limit
		|| context.work > context.work_limit - amount)
	{
		if (context) context.failed_closed = true;
		return false;
	}
	context.work += amount;
	return true;
}
fn bool delta_provenance_type_is_function(
	DeltaProgram* program,
	TypeId type_id,
	usz depth = 0
)
{
	if (!program || !type_id || depth >= 8) return false;
	if (type_id == TYPE_ID_FUNCTION) return true;
	TypeDescriptor* descriptor = type_descriptor(&program.types, type_id);
	if (!descriptor) return false;
	if (descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE) return true;
	return descriptor.kind == TYPE_DESCRIPTOR_INSTANCE
		&& descriptor.constructor == TYPE_ID_SUPERPOSITION
		&& descriptor.arguments.len == 1
		&& delta_provenance_type_is_function(
			program, descriptor.arguments[0], depth + 1
		);
}

fn TypeId delta_provenance_node_type(DeltaProgram* program, DeltaNode* node)
{
	if (!program || !node) return TYPE_ID_INVALID;
	switch (node.kind)
	{
		case DELTA_LAMBDA:
		case DELTA_CONSTRUCTOR:
			return node.runtime_type ? node.runtime_type : node.static_type;
		case DELTA_SUPERPOSE:
			return node.result_type;
		case DELTA_APPLY:
		case DELTA_EFFECT:
		case DELTA_RESUME:
			return node.result_type ? node.result_type : node.static_type;
		default:
			return node.runtime_type ? node.runtime_type : node.static_type;
	}
}

fn DeltaValueProvenance delta_unknown_provenance_for_type(
	DeltaProgram* program,
	TypeId type_id,
	usz depth = 0
)
{
	DeltaValueProvenance result;
	result.has_request_free_path = true;
	if (!program || depth >= 8 || type_id == TYPE_ID_INVALID
		|| type_id == TYPE_ID_ANY)
	{
		result.uncertain_closure = true;
		result.uncertain_effectful_closure = true;
		result.uncertain_constructor = true;
		return result;
	}
	TypeDescriptor* descriptor = type_descriptor(&program.types, type_id);
	if (!descriptor)
	{
		result.uncertain_closure = true;
		result.uncertain_effectful_closure = true;
		result.uncertain_constructor = true;
		return result;
	}
	if (descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE
		|| type_id == TYPE_ID_FUNCTION)
	{
		result.uncertain_closure = true;
		result.uncertain_effectful_closure =
			type_id == TYPE_ID_FUNCTION
			|| delta_effect_row_has_effects(&descriptor.function_effects);
		return result;
	}
	if (descriptor.kind == TYPE_DESCRIPTOR_INSTANCE
		&& descriptor.constructor == TYPE_ID_SUPERPOSITION
		&& descriptor.arguments.len == 1)
	{
		return delta_unknown_provenance_for_type(
			program, descriptor.arguments[0], depth + 1
		);
	}
	if (descriptor.kind == TYPE_DESCRIPTOR_ABSTRACT)
	{
		result.uncertain_closure = true;
		result.uncertain_effectful_closure = true;
	}
	result.uncertain_constructor = true;
	return result;
}

fn void delta_add_closure_origin(
	DeltaProvenanceContext* context,
	DeltaValueProvenance* value,
	DeltaClosureOrigin origin
)
{
	if (!context || !value || !origin.lambda
		|| (usz)origin.lambda > context.program.image.nodes.len)
	{
		if (context) context.failed_closed = true;
		return;
	}
	DeltaNode* lambda = &context.program.image.nodes[(usz)origin.lambda - 1];
	if (lambda.kind != DELTA_LAMBDA)
	{
		context.failed_closed = true;
		return;
	}
	if (delta_effect_row_has_effects(&lambda.effect_row))
	{
		value.has_effectful_closure = true;
	}
	if ((value.first_closure.lambda == origin.lambda
			&& value.first_closure.environment == origin.environment)
		|| (value.second_closure.lambda == origin.lambda
			&& value.second_closure.environment == origin.environment)) return;
	if (!value.first_closure.lambda)
	{
		value.first_closure = origin;
		return;
	}
	if (!value.second_closure.lambda)
	{
		value.second_closure = origin;
		return;
	}
	value.closure_many = true;
}

fn void delta_add_constructor_origin(
	DeltaValueProvenance* value,
	DeltaConstructorOrigin origin
)
{
	if (!value || !origin.constructor) return;
	if ((value.first_constructor.constructor == origin.constructor
			&& value.first_constructor.environment == origin.environment)
		|| (value.second_constructor.constructor == origin.constructor
			&& value.second_constructor.environment == origin.environment)) return;
	if (!value.first_constructor.constructor)
	{
		value.first_constructor = origin;
		return;
	}
	if (!value.second_constructor.constructor)
	{
		value.second_constructor = origin;
		return;
	}
	value.constructor_many = true;
}

fn void delta_merge_provenance(
	DeltaProvenanceContext* context,
	DeltaValueProvenance* destination,
	DeltaValueProvenance source
)
{
	if (!destination) return;
	destination.has_request_free_path =
		destination.has_request_free_path || source.has_request_free_path;
	destination.suspended_request_path =
		destination.suspended_request_path || source.suspended_request_path;
	if (source.first_closure.lambda)
	{
		delta_add_closure_origin(context, destination, source.first_closure);
	}
	if (source.second_closure.lambda)
	{
		delta_add_closure_origin(context, destination, source.second_closure);
	}
	destination.closure_many = destination.closure_many || source.closure_many;
	destination.has_effectful_closure =
		destination.has_effectful_closure || source.has_effectful_closure;
	destination.uncertain_closure =
		destination.uncertain_closure || source.uncertain_closure;
	destination.uncertain_effectful_closure =
		destination.uncertain_effectful_closure
		|| source.uncertain_effectful_closure;
	if (source.first_constructor.constructor)
	{
		delta_add_constructor_origin(destination, source.first_constructor);
	}
	if (source.second_constructor.constructor)
	{
		delta_add_constructor_origin(destination, source.second_constructor);
	}
	destination.constructor_many =
		destination.constructor_many || source.constructor_many;
	destination.uncertain_constructor =
		destination.uncertain_constructor || source.uncertain_constructor;
}

fn void delta_note_merged_closure_provenance(
	DeltaProvenanceContext* context,
	DeltaValueProvenance value
)
{
	if (!context) return;
	bool distinct = value.second_closure.lambda != DELTA_NODE_INVALID
		|| value.closure_many;
	if ((distinct && value.has_effectful_closure)
		|| value.uncertain_effectful_closure)
	{
		context.dynamic_effectful_closure = true;
	}
}

fn DeltaClosureBinding* delta_bind_sources(
	DeltaProvenanceContext* context,
	DeltaClosureBinding* parent,
	String[] names,
	DeltaNodeId[] sources,
	DeltaClosureBinding* source_environment
)
{
	if (!context || names.len != sources.len
		|| !delta_provenance_charge(context, names.len)) return null;
	if (!names.len) return parent;
	DeltaClosureBinding[] owned = alloc::new_array(
		context.allocator, DeltaClosureBinding, (sz)names.len
	);
	context.binding_sets.push(owned);
	DeltaClosureBinding* current = parent;
	foreach (index, name : names)
	{
		owned[index] = {
			.parent = current,
			.name = name,
			.value = sources[index],
			.value_environment = source_environment,
		};
		current = &owned[index];
	}
	return current;
}

fn DeltaClosureBinding* delta_bind_unknowns(
	DeltaProvenanceContext* context,
	DeltaClosureBinding* parent,
	String[] names,
	TypeId[] types
)
{
	if (!context || names.len != types.len
		|| !delta_provenance_charge(context, names.len)) return null;
	if (!names.len) return parent;
	DeltaClosureBinding[] owned = alloc::new_array(
		context.allocator, DeltaClosureBinding, (sz)names.len
	);
	context.binding_sets.push(owned);
	DeltaClosureBinding* current = parent;
	foreach (index, name : names)
	{
		owned[index] = {
			.parent = current,
			.name = name,
			.unknown_type = types[index],
		};
		current = &owned[index];
	}
	return current;
}

fn DeltaClosureBinding* delta_bind_provenances(
	DeltaProvenanceContext* context,
	DeltaClosureBinding* parent,
	String[] names,
	TypeId[] types,
	DeltaValueProvenance[] provenances
)
{
	if (!context || names.len != types.len || names.len != provenances.len
		|| !delta_provenance_charge(context, names.len)) return null;
	if (!names.len) return parent;
	DeltaClosureBinding[] owned = alloc::new_array(
		context.allocator, DeltaClosureBinding, (sz)names.len
	);
	context.binding_sets.push(owned);
	DeltaClosureBinding* current = parent;
	foreach (index, name : names)
	{
		owned[index] = {
			.parent = current,
			.name = name,
			.unknown_type = types[index],
			.has_provenance = true,
			.provenance = provenances[index],
		};
		current = &owned[index];
	}
	return current;
}

fn DeltaClosureBinding* delta_bind_type_values(
	DeltaProvenanceContext* context,
	DeltaClosureBinding* parent,
	TypeBinding[] bindings
)
{
	if (!context || !delta_provenance_charge(context, bindings.len)) return null;
	if (!bindings.len) return parent;
	DeltaClosureBinding[] owned = alloc::new_array(
		context.allocator, DeltaClosureBinding, (sz)bindings.len
	);
	context.binding_sets.push(owned);
	DeltaClosureBinding* current = parent;
	foreach (index, &binding : bindings)
	{
		owned[index] = {
			.parent = current,
			.name = binding.variable,
			.type_value = true,
			.represented_type = binding.type_id,
		};
		current = &owned[index];
	}
	return current;
}

fn DeltaClosureBinding* delta_bind_unknown_type_values(
	DeltaProvenanceContext* context,
	DeltaClosureBinding* parent,
	String[] variables
)
{
	if (!context || !delta_provenance_charge(context, variables.len)) return null;
	if (!variables.len) return parent;
	DeltaClosureBinding[] owned = alloc::new_array(
		context.allocator, DeltaClosureBinding, (sz)variables.len
	);
	context.binding_sets.push(owned);
	DeltaClosureBinding* current = parent;
	foreach (index, variable : variables)
	{
		owned[index] = {
			.parent = current,
			.name = variable,
			.type_value = true,
		};
		current = &owned[index];
	}
	return current;
}

fn TypeId delta_provenance_type_value_type(
	DeltaProvenanceContext* context,
	TypeId represented
)
{
	if (!context || !represented || represented == TYPE_ID_ANY) return TYPE_ID_ANY;
	TypeId runtime_type;
	MitosDiagnostic diagnostic;
	if (intern_type_value_type(
		&context.program.types, represented, &runtime_type, &diagnostic
	))
	{
		return runtime_type;
	}
	diagnostic.deinit();
	context.failed_closed = true;
	return TYPE_ID_ANY;
}

fn bool delta_provenance_dispatch_generic(
	DeltaProvenanceContext* context,
	DeltaNode* node,
	DeltaClosureBinding* bindings,
	usz depth,
	DispatchResult* result
)
{
	if (result) *result = { };
	if (!context || !node || !result
		|| node.descriptor >= (usz)context.program.methods.generics.len())
	{
		if (context) context.failed_closed = true;
		return false;
	}
	TypeId[] actual = alloc::new_array(
		context.allocator, TypeId, (sz)node.inputs.len
	);
	defer alloc::free(context.allocator, actual);
	foreach (index, input : node.inputs)
	{
		actual[index] = delta_provenance_source_type(
			context, input, bindings, depth + 1
		);
		if (!actual[index] || actual[index] == TYPE_ID_ANY) return false;
	}
	GenericFunction* generic =
		&context.program.methods.generics[(sz)node.descriptor];
	usz method_count = (usz)generic.methods.len();
	if (method_count
		&& (method_count > context.work_limit / method_count
			|| !delta_provenance_charge(
				context, method_count * method_count
			)))
	{
		return false;
	}
	*result = dispatch_method(
		&context.program.methods,
		&context.program.types,
		generic.name,
		actual,
		context.allocator,
		{ },
		&node.key
	);
	return result.matched;
}

fn TypeId delta_provenance_generic_result_type(
	DeltaProvenanceContext* context,
	DeltaNode* node,
	DeltaClosureBinding* bindings,
	usz depth
)
{
	DispatchResult dispatch;
	if (!delta_provenance_dispatch_generic(
		context, node, bindings, depth, &dispatch
	))
	{
		dispatch.deinit();
		return TYPE_ID_ANY;
	}
	defer dispatch.deinit();
	if (!dispatch.matched
		|| dispatch.generic_index >= (usz)context.program.methods.generics.len())
	{
		return TYPE_ID_ANY;
	}
	GenericFunction* selected_generic =
		&context.program.methods.generics[(sz)dispatch.generic_index];
	if (dispatch.method_index >= (usz)selected_generic.methods.len())
	{
		context.failed_closed = true;
		return TYPE_ID_ANY;
	}
	TypeId result_type;
	if (!resolve_method_result_type(
		&context.program.types,
		&selected_generic.methods[(sz)dispatch.method_index],
		dispatch.bindings,
		&result_type
	))
	{
		context.failed_closed = true;
		return TYPE_ID_ANY;
	}
	return result_type;
}

fn TypeId delta_provenance_source_type(
	DeltaProvenanceContext* context,
	DeltaNodeId node_id,
	DeltaClosureBinding* bindings,
	usz depth = 0
)
{
	if (!context || !node_id || depth >= DELTA_MAX_EVALUATION_DEPTH
		|| (usz)node_id > context.program.image.nodes.len)
	{
		if (context) context.failed_closed = true;
		return TYPE_ID_ANY;
	}
	DeltaNode* node = &context.program.image.nodes[(usz)node_id - 1];
	if (node.kind == DELTA_LOCAL)
	{
		for (DeltaClosureBinding* binding = bindings; binding; binding = binding.parent)
		{
			if (binding.name != node.name) continue;
			if (binding.type_value)
			{
				return delta_provenance_type_value_type(
					context, binding.represented_type
				);
			}
			if (binding.has_provenance) return binding.unknown_type;
			if (!binding.value) return binding.unknown_type;
			return delta_provenance_source_type(
				context,
				binding.value,
				binding.value_environment,
				depth + 1
			);
		}
	}
	if (node.kind == DELTA_GENERIC_CALL)
	{
		return delta_provenance_generic_result_type(
			context, node, bindings, depth
		);
	}
	return delta_provenance_node_type(context.program, node);
}


fn DeltaValueProvenance delta_analyze_method_root(
	DeltaProvenanceContext* context,
	usz root_index,
	DeltaNode* call,
	DeltaClosureBinding* caller_bindings,
	TypeBinding[] type_bindings,
	bool concrete_type_bindings
)
{
	if (!context || root_index >= context.program.method_roots.len)
	{
		if (context) context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context ? context.program : null, TYPE_ID_ANY
		);
	}
	DeltaMethodRoot* root = &context.program.method_roots[root_index];
	if (root.parameters.len != call.inputs.len)
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program, root.result_type
		);
	}
	if (context.root_active[root_index])
	{
		return delta_unknown_provenance_for_type(
			context.program, root.result_type
		);
	}
	DeltaClosureBinding* method_bindings = delta_bind_sources(
		context,
		null,
		root.parameters,
		call.inputs,
		caller_bindings
	);
	if (root.parameters.len && !method_bindings)
	{
		return delta_unknown_provenance_for_type(
			context.program, root.result_type
		);
	}
	usz type_binding_count;
	if (concrete_type_bindings)
	{
		type_binding_count = type_bindings.len;
		method_bindings = delta_bind_type_values(
			context, method_bindings, type_bindings
		);
	}
	else
	{
		if (root.generic_index >= (usz)context.program.methods.generics.len())
		{
			context.failed_closed = true;
			return delta_unknown_provenance_for_type(
				context.program, root.result_type
			);
		}
		GenericFunction* generic =
			&context.program.methods.generics[(sz)root.generic_index];
		if (root.method_index >= (usz)generic.methods.len())
		{
			context.failed_closed = true;
			return delta_unknown_provenance_for_type(
				context.program, root.result_type
			);
		}
		String[] variables = generic.methods[(sz)root.method_index].type_variables;
		type_binding_count = variables.len;
		method_bindings = delta_bind_unknown_type_values(
			context, method_bindings, variables
		);
	}
	if (type_binding_count && !method_bindings)
	{
		return delta_unknown_provenance_for_type(
			context.program, root.result_type
		);
	}
	context.root_active[root_index] = 1;
	DeltaValueProvenance result = delta_analyze_provenance(
		context, root.root, method_bindings, root.result_type
	);
	context.root_active[root_index] = 0;
	return result;
}
fn DeltaValueProvenance delta_analyze_generic_call(
	DeltaProvenanceContext* context,
	DeltaNode* node,
	DeltaClosureBinding* bindings
)
{
	DeltaValueProvenance result;
	foreach (input : node.inputs)
	{
		DeltaValueProvenance argument = delta_analyze_provenance(
			context, input, bindings
		);
		delta_note_merged_closure_provenance(context, argument);
		if (argument.suspended_request_path)
		{
			result.suspended_request_path = true;
		}
		if (!argument.has_request_free_path) return result;
	}
	if (node.descriptor >= (usz)context.program.methods.generics.len())
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program, TYPE_ID_ANY
		);
	}

	DispatchResult selected_dispatch;
	defer selected_dispatch.deinit();
	bool selected = delta_provenance_dispatch_generic(
		context, node, bindings, 0, &selected_dispatch
	);
	usz selected_generic = selected ? selected_dispatch.generic_index : 0;
	usz selected_method = selected ? selected_dispatch.method_index : 0;

	bool found = false;
	foreach (root_index, &root : context.program.method_roots)
	{
		if (root.generic_index != node.descriptor) continue;
		if (selected && (root.generic_index != selected_generic
			|| root.method_index != selected_method)) continue;
		found = true;
		DeltaValueProvenance candidate = delta_analyze_method_root(
			context,
			(usz)root_index,
			node,
			bindings,
			selected ? selected_dispatch.bindings : { },
			selected
		);
		delta_merge_provenance(context, &result, candidate);
	}
	if (!found)
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program, TYPE_ID_ANY
		);
	}
	delta_note_merged_closure_provenance(context, result);
	return result;
}

fn DeltaValueProvenance delta_analyze_lambda_application(
	DeltaProvenanceContext* context,
	DeltaNode* application,
	DeltaClosureBinding* caller_bindings,
	DeltaClosureOrigin origin
)
{
	if (!origin.lambda
		|| (usz)origin.lambda > context.program.image.nodes.len)
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program, application.result_type
		);
	}
	DeltaNode* lambda = &context.program.image.nodes[(usz)origin.lambda - 1];
	if (lambda.kind != DELTA_LAMBDA || lambda.inputs.len != 1
		|| lambda.names.len + 1 != application.inputs.len)
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program, application.result_type
		);
	}
	DeltaClosureBinding* lambda_bindings = delta_bind_sources(
		context,
		origin.environment,
		lambda.names,
		application.inputs[1..],
		caller_bindings
	);
	if (lambda.names.len && !lambda_bindings)
	{
		return delta_unknown_provenance_for_type(
			context.program, lambda.result_type
		);
	}
	return delta_analyze_provenance(
		context, lambda.inputs[0], lambda_bindings, lambda.result_type
	);
}

fn DeltaValueProvenance delta_analyze_match_branch(
	DeltaProvenanceContext* context,
	DeltaNode* match_node,
	DeltaConstructorOrigin origin,
	DeltaClosureBinding* outer_bindings
)
{
	if (!origin.constructor
		|| (usz)origin.constructor > context.program.image.nodes.len)
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program, match_node.static_type
		);
	}
	DeltaNode* constructor =
		&context.program.image.nodes[(usz)origin.constructor - 1];
	if (constructor.kind != DELTA_CONSTRUCTOR
		|| constructor.descriptor >= context.program.constructors.len)
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program, match_node.static_type
		);
	}
	DeltaMatchBranch* selected = null;
	foreach (&candidate : match_node.branches)
	{
		if (!candidate.wildcard
			&& candidate.constructor == (uint)constructor.descriptor)
		{
			selected = candidate;
			break;
		}
		if (candidate.wildcard && !selected) selected = candidate;
	}
	if (!selected)
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program, match_node.static_type
		);
	}
	DeltaClosureBinding* branch_bindings = outer_bindings;
	if (!selected.wildcard)
	{
		if (selected.bindings.len != constructor.inputs.len)
		{
			context.failed_closed = true;
			return delta_unknown_provenance_for_type(
				context.program, match_node.static_type
			);
		}
		branch_bindings = delta_bind_sources(
			context,
			outer_bindings,
			selected.bindings,
			constructor.inputs,
			origin.environment
		);
		if (selected.bindings.len && !branch_bindings)
		{
			return delta_unknown_provenance_for_type(
				context.program, match_node.static_type
			);
		}
	}
	return delta_analyze_provenance(
		context, selected.body, branch_bindings
	);
}

fn DeltaValueProvenance delta_analyze_unknown_match_branches(
	DeltaProvenanceContext* context,
	DeltaNode* node,
	DeltaClosureBinding* bindings
)
{
	DeltaValueProvenance result;
	foreach (&branch : node.branches)
	{
		DeltaClosureBinding* branch_bindings = bindings;
		if (!branch.wildcard)
		{
			if ((usz)branch.constructor >= context.program.constructors.len)
			{
				context.failed_closed = true;
				continue;
			}
			DeltaConstructorDescriptor* descriptor =
				&context.program.constructors[(usz)branch.constructor];
			if (branch.bindings.len != descriptor.field_types.len)
			{
				context.failed_closed = true;
				continue;
			}
			branch_bindings = delta_bind_unknowns(
				context,
				bindings,
				branch.bindings,
				descriptor.field_types
			);
			if (branch.bindings.len && !branch_bindings) continue;
		}
		DeltaValueProvenance candidate = delta_analyze_provenance(
			context, branch.body, branch_bindings
		);
		delta_merge_provenance(context, &result, candidate);
	}
	return result;
}

fn DeltaValueProvenance delta_analyze_match(
	DeltaProvenanceContext* context,
	DeltaNode* node,
	DeltaClosureBinding* bindings
)
{
	if (node.inputs.len != 1)
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program, node.static_type
		);
	}
	DeltaValueProvenance scrutinee = delta_analyze_provenance(
		context, node.inputs[0], bindings
	);
	if (scrutinee.suspended_request_path
		&& !scrutinee.has_request_free_path) return scrutinee;
	DeltaValueProvenance result;
	result.suspended_request_path = scrutinee.suspended_request_path;
	if (scrutinee.first_constructor.constructor)
	{
		DeltaValueProvenance candidate = delta_analyze_match_branch(
			context,
			node,
			scrutinee.first_constructor,
			bindings
		);
		delta_merge_provenance(context, &result, candidate);
	}
	if (scrutinee.second_constructor.constructor)
	{
		DeltaValueProvenance candidate = delta_analyze_match_branch(
			context,
			node,
			scrutinee.second_constructor,
			bindings
		);
		delta_merge_provenance(context, &result, candidate);
	}
	if (scrutinee.constructor_many || scrutinee.uncertain_constructor)
	{
		DeltaValueProvenance uncertain = delta_analyze_unknown_match_branches(
			context, node, bindings
		);
		delta_merge_provenance(context, &result, uncertain);
	}
	if (!scrutinee.first_constructor.constructor
		&& !scrutinee.uncertain_constructor)
	{
		context.failed_closed = true;
	}
	delta_note_merged_closure_provenance(context, result);
	return result;
}

fn DeltaRequestCapture* delta_find_request_capture(
	DeltaProvenanceContext* context,
	DeltaNodeId request_id,
	DeltaNode* request,
	DeltaOperationDescriptor* operation
)
{
	if (!context || !request || !operation) return null;
	for (DeltaRequestCapture* capture = context.request_capture;
		capture; capture = capture.parent)
	{
		usz clause_count = capture.handler.clauses.len;
		if (clause_count > context.work_limit / 2
			|| !delta_provenance_charge(context, clause_count * 2))
		{
			return null;
		}
		bool captured;
		foreach (clause_index, &clause : capture.handler.clauses)
		{
			if (clause.effect != (EffectId)request.integer
				|| clause.operation != operation.id) continue;
			captured = true;
			capture.matched_clauses[clause_index] = 1;
			if (clause.parameters.len != request.inputs.len)
			{
				context.failed_closed = true;
			}
		}
		if (captured)
		{
			usz hole_count = (usz)capture.holes.len();
			if (hole_count >= context.work_limit
				|| !delta_provenance_charge(context, hole_count + 1))
			{
				return null;
			}
			foreach (hole : capture.holes)
			{
				if (hole == request_id) return capture;
			}
			capture.holes.push(request_id);
			return capture;
		}
	}
	return null;
}

fn void delta_capture_request_argument(
	DeltaProvenanceContext* context,
	DeltaRequestCapture* capture,
	DeltaNode* request,
	DeltaOperationDescriptor* operation,
	usz argument_index,
	DeltaValueProvenance value
)
{
	if (!context || !capture || !request || !operation) return;
	usz offset;
	foreach (&clause : capture.handler.clauses)
	{
		if (clause.effect == (EffectId)request.integer
			&& clause.operation == operation.id
			&& clause.parameters.len == request.inputs.len
			&& argument_index < clause.parameters.len)
		{
			delta_merge_provenance(
				context, &capture.arguments[offset + argument_index], value
			);
			delta_note_merged_closure_provenance(
				context, capture.arguments[offset + argument_index]
			);
		}
		offset += clause.parameters.len;
	}
}

fn DeltaValueProvenance delta_analyze_handler_return(
	DeltaProvenanceContext* context,
	DeltaHandlerDescriptor* handler,
	DeltaClosureBinding* bindings,
	DeltaValueProvenance handled
)
{
	String[1] names = { handler.return_parameter };
	TypeId[1] types = { handler.return_type };
	DeltaValueProvenance[1] provenances = { handled };
	DeltaClosureBinding* return_bindings = delta_bind_provenances(
		context,
		bindings,
		names[..],
		types[..],
		provenances[..]
	);
	if (!return_bindings)
	{
		return delta_unknown_provenance_for_type(
			context.program, TYPE_ID_ANY
		);
	}
	return delta_analyze_provenance(
		context, handler.return_body, return_bindings
	);
}

fn DeltaValueProvenance delta_analyze_handler(
	DeltaProvenanceContext* context,
	DeltaNode* node,
	DeltaClosureBinding* bindings
)
{
	DeltaValueProvenance result;
	if (node.descriptor >= context.program.effects.handlers.len
		|| !node.inputs.len)
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program, node.static_type
		);
	}
	DeltaHandlerDescriptor* handler =
		&context.program.effects.handlers[node.descriptor];
	usz argument_count;
	foreach (&clause : handler.clauses)
	{
		if (clause.parameters.len > context.work_limit - argument_count)
		{
			context.failed_closed = true;
			return delta_unknown_provenance_for_type(
				context.program, node.static_type
			);
		}
		argument_count += clause.parameters.len;
	}
	if (handler.clauses.len > context.work_limit - argument_count
		|| !delta_provenance_charge(
			context, argument_count + handler.clauses.len
		))
	{
		return delta_unknown_provenance_for_type(
			context.program, node.static_type
		);
	}
	DeltaValueProvenance[] request_arguments = alloc::new_array(
		context.allocator, DeltaValueProvenance, (sz)argument_count
	);
	defer alloc::free(context.allocator, request_arguments);
	char[] matched_clauses = alloc::new_array(
		context.allocator, char, (sz)handler.clauses.len
	);
	defer alloc::free(context.allocator, matched_clauses);
	foreach (&argument : request_arguments) *argument = { };
	foreach (&matched : matched_clauses) *matched = 0;
	DeltaRequestCapture capture = {
		.parent = context.request_capture,
		.handler = handler,
		.arguments = request_arguments,
		.matched_clauses = matched_clauses,
	};
	capture.holes.init(context.allocator);
	defer capture.holes.free();
	context.request_capture = &capture;
	DeltaValueProvenance handled = delta_analyze_provenance(
		context, node.inputs[0], bindings
	);
	context.request_capture = capture.parent;
	if (handled.has_request_free_path)
	{
		DeltaValueProvenance request_free = handled;
		request_free.suspended_request_path = false;
		delta_note_merged_closure_provenance(context, request_free);
		DeltaValueProvenance returned = delta_analyze_handler_return(
			context, handler, bindings, request_free
		);
		delta_merge_provenance(context, &result, returned);
	}

	usz argument_offset;
	foreach (clause_index, &clause : handler.clauses)
	{
		if (matched_clauses[clause_index])
		{
			DeltaClosureBinding* clause_bindings = delta_bind_provenances(
				context,
				bindings,
				clause.parameters,
				clause.parameter_types,
				request_arguments[
					argument_offset:(sz)clause.parameters.len
				]
			);
			if (!clause.parameters.len || clause_bindings)
			{
				foreach (hole : capture.holes)
				{
					DeltaNode* request = &context.program.image.nodes[
						(usz)hole - 1
					];
					if (request.kind != DELTA_EFFECT
						|| request.descriptor
							>= context.program.effects.operations.len)
					{
						context.failed_closed = true;
						continue;
					}
					DeltaOperationDescriptor* operation =
						&context.program.effects.operations[
							request.descriptor
						];
					if (clause.effect != (EffectId)request.integer
						|| clause.operation != operation.id) continue;
					DeltaProvenanceResume resume = {
						.parent = context.resume,
						.handler = handler,
						.handled = handler.handled,
						.hole = hole,
						.bindings = bindings,
					};
					context.resume = &resume;
					DeltaValueProvenance candidate =
						delta_analyze_provenance(
							context, clause.body, clause_bindings
						);
					if (clause.body
						&& (usz)clause.body
							<= context.program.image.nodes.len)
					{
						DeltaNode* clause_result =
							&context.program.image.nodes[
								(usz)clause.body - 1
							];
						if (clause_result.kind == DELTA_ABORT
							&& clause_result.inputs.len == 1
							&& clause_result.inputs[0]
							&& (usz)clause_result.inputs[0]
								<= context.program.image.nodes.len)
						{
							DeltaNode* aborted =
								&context.program.image.nodes[
									(usz)clause_result.inputs[0] - 1
								];
							TypeId aborted_type =
								delta_provenance_node_type(
									context.program, aborted
								);
							if (aborted_type != TYPE_ID_ANY
								&& !delta_provenance_type_is_function(
									context.program, aborted_type
								))
							{
								candidate =
									delta_unknown_provenance_for_type(
										context.program, aborted_type
									);
							}
						}
					}
					context.resume = resume.parent;
					delta_merge_provenance(context, &result, candidate);
				}
			}
		}
		argument_offset += clause.parameters.len;
	}
	delta_note_merged_closure_provenance(context, result);
	return result;
}

fn DeltaValueProvenance delta_analyze_provenance_body(
	DeltaProvenanceContext* context,
	DeltaNodeId node_id,
	DeltaNode* node,
	DeltaClosureBinding* bindings,
	TypeId expected_type
)
{
	DeltaValueProvenance result;
	switch (node.kind)
	{
		case DELTA_LOCAL:
			for (DeltaClosureBinding* binding = bindings;
				binding; binding = binding.parent)
			{
				if (binding.name != node.name) continue;
				if (binding.type_value)
				{
					result.has_request_free_path = true;
					return result;
				}
				if (binding.has_provenance) return binding.provenance;
				if (!binding.value)
				{
					return delta_unknown_provenance_for_type(
						context.program, binding.unknown_type
					);
				}
				return delta_analyze_provenance(
					context,
					binding.value,
					binding.value_environment
				);
			}
			context.failed_closed = true;
			return delta_unknown_provenance_for_type(
				context.program, node.static_type
			);
		case DELTA_I64:
		case DELTA_STRING:
		case DELTA_TYPE_VALUE:
			result.has_request_free_path = true;
			return result;
		case DELTA_LAMBDA:
			if (node.inputs.len != 1)
			{
				context.failed_closed = true;
				return delta_unknown_provenance_for_type(
					context.program, node.runtime_type
				);
			}
			delta_add_closure_origin(context, &result, {
				.lambda = node_id,
				.environment = bindings,
			});
			result.has_request_free_path = true;
			return result;
		case DELTA_APPLY:
			if (!node.inputs.len)
			{
				context.failed_closed = true;
				return delta_unknown_provenance_for_type(
					context.program, node.result_type
				);
			}
			DeltaValueProvenance callee = delta_analyze_provenance(
				context, node.inputs[0], bindings
			);
			if (callee.suspended_request_path)
			{
				result.suspended_request_path = true;
			}
			if (!callee.has_request_free_path) return result;
			foreach (argument : node.inputs[1..])
			{
				DeltaValueProvenance argument_value =
					delta_analyze_provenance(context, argument, bindings);
				delta_note_merged_closure_provenance(
					context, argument_value
				);
				if (argument_value.suspended_request_path)
				{
					result.suspended_request_path = true;
				}
				if (!argument_value.has_request_free_path) return result;
			}
			if (callee.uncertain_effectful_closure)
			{
				context.dynamic_effectful_closure = true;
			}
			if (callee.first_closure.lambda)
			{
				DeltaValueProvenance applied =
					delta_analyze_lambda_application(
						context,
						node,
						bindings,
						callee.first_closure
					);
				delta_merge_provenance(context, &result, applied);
			}
			if (callee.second_closure.lambda)
			{
				DeltaValueProvenance applied =
					delta_analyze_lambda_application(
						context,
						node,
						bindings,
						callee.second_closure
					);
				delta_merge_provenance(context, &result, applied);
			}
			if (callee.closure_many || callee.uncertain_closure)
			{
				DeltaValueProvenance uncertain =
					delta_unknown_provenance_for_type(
						context.program,
						node.result_type
					);
				delta_merge_provenance(context, &result, uncertain);
			}
			if (!callee.first_closure.lambda
				&& !callee.uncertain_closure)
			{
				context.failed_closed = true;
			}
			delta_note_merged_closure_provenance(context, result);
			return result;
		case DELTA_LET:
		case DELTA_PARALLEL_JOIN:
			if (!node.names.len
				|| node.inputs.len != node.names.len + 1)
			{
				context.failed_closed = true;
				return delta_unknown_provenance_for_type(
					context.program, expected_type
				);
			}
			foreach (input : node.inputs[:(sz)node.names.len])
			{
				DeltaValueProvenance bound = delta_analyze_provenance(
					context, input, bindings
				);
				delta_note_merged_closure_provenance(context, bound);
				if (bound.suspended_request_path)
				{
					result.suspended_request_path = true;
				}
				if (!bound.has_request_free_path) return result;
			}
			DeltaClosureBinding* result_bindings = delta_bind_sources(
				context,
				bindings,
				node.names,
				node.inputs[:(sz)node.names.len],
				bindings
			);
			if (!result_bindings)
			{
				return delta_unknown_provenance_for_type(
					context.program, expected_type
				);
			}
			DeltaValueProvenance let_result = delta_analyze_provenance(
				context,
				node.inputs[node.inputs.len - 1],
				result_bindings,
				expected_type
			);
			let_result.suspended_request_path =
				let_result.suspended_request_path
				|| result.suspended_request_path;
			return let_result;
		case DELTA_CONSTRUCTOR:
			foreach (input : node.inputs)
			{
				DeltaValueProvenance field = delta_analyze_provenance(
					context, input, bindings
				);
				delta_note_merged_closure_provenance(context, field);
				if (field.suspended_request_path)
				{
					result.suspended_request_path = true;
				}
				if (!field.has_request_free_path) return result;
			}
			delta_add_constructor_origin(&result, {
				.constructor = node_id,
				.environment = bindings,
			});
			result.has_request_free_path = true;
			return result;
		case DELTA_MATCH:
			return delta_analyze_match(context, node, bindings);
		case DELTA_GENERIC_CALL:
			return delta_analyze_generic_call(context, node, bindings);
		case DELTA_TYPE_ASSERT:
		case DELTA_PARALLEL_ROOT:
			if (!node.inputs.len)
			{
				context.failed_closed = true;
				return delta_unknown_provenance_for_type(
					context.program, expected_type
				);
			}
			return delta_analyze_provenance(
				context,
				node.inputs[0],
				bindings,
				node.kind == DELTA_TYPE_ASSERT
					? node.static_type : expected_type
			);
		case DELTA_SUPERPOSE:
			foreach (input : node.inputs)
			{
				DeltaValueProvenance alternative =
					delta_analyze_provenance(context, input, bindings);
				delta_merge_provenance(context, &result, alternative);
			}
			delta_note_merged_closure_provenance(context, result);
			return result;
		case DELTA_HANDLER:
			return delta_analyze_handler(context, node, bindings);
		case DELTA_ABORT:
			if (!node.inputs.len)
			{
				context.failed_closed = true;
				return delta_unknown_provenance_for_type(
					context.program, expected_type
				);
			}
			return delta_analyze_provenance(
				context, node.inputs[0], bindings, expected_type
			);
		case DELTA_EFFECT:
			DeltaOperationDescriptor* operation = null;
			DeltaRequestCapture* request_capture = null;
			DeltaValueProvenance* substitution_value = null;
			if (node.descriptor >= context.program.effects.operations.len)
			{
				context.failed_closed = true;
			}
			else
			{
				operation = &context.program.effects.operations[node.descriptor];
				for (DeltaProvenanceSubstitution* substitution =
						context.substitution;
					substitution; substitution = substitution.parent)
				{
					if (substitution.hole != node_id) continue;
					substitution_value = &substitution.value;
					break;
				}
				if (!substitution_value)
				{
					request_capture = delta_find_request_capture(
						context, node_id, node, operation
					);
				}
			}
			foreach (argument_index, input : node.inputs)
			{
				DeltaValueProvenance input_value =
					delta_analyze_provenance(context, input, bindings);
				delta_note_merged_closure_provenance(
					context, input_value
				);
				if (request_capture)
				{
					delta_capture_request_argument(
						context,
						request_capture,
						node,
						operation,
						(usz)argument_index,
						input_value
					);
				}
			}
			if (substitution_value) return *substitution_value;
			if (request_capture)
			{
				result.suspended_request_path = true;
				return result;
			}
			return delta_unknown_provenance_for_type(
				context.program,
				node.result_type ? node.result_type : expected_type
			);
		case DELTA_RESUME:
			if (node.inputs.len != 1)
			{
				context.failed_closed = true;
				return delta_unknown_provenance_for_type(
					context.program,
					node.result_type ? node.result_type : expected_type
				);
			}
			DeltaValueProvenance resumed = delta_analyze_provenance(
				context, node.inputs[0], bindings
			);
			delta_note_merged_closure_provenance(context, resumed);
			if (resumed.suspended_request_path
				&& !resumed.has_request_free_path) return resumed;
			DeltaProvenanceResume* resume = context.resume;
			while (resume && (node.descriptor
					>= context.program.effects.handlers.len
				|| &context.program.effects.handlers[node.descriptor]
					!= resume.handler))
			{
				resume = resume.parent;
			}
			if (resume)
			{
				TypeId resumed_type = node.result_type
					? node.result_type : expected_type;
				DeltaValueProvenance substituted =
					delta_provenance_type_is_function(
						context.program, resumed_type
					)
					? resumed
					: delta_unknown_provenance_for_type(
						context.program, resumed_type
					);
				DeltaProvenanceSubstitution substitution = {
					.parent = context.substitution,
					.hole = resume.hole,
					.value = substituted,
				};
				context.substitution = &substitution;
				DeltaValueProvenance continued = delta_analyze_provenance(
					context, resume.handled, resume.bindings
				);
				context.substitution = substitution.parent;
				return delta_analyze_handler_return(
					context, resume.handler, resume.bindings, continued
				);
			}
			return delta_unknown_provenance_for_type(
				context.program,
				node.result_type ? node.result_type : expected_type
			);
		case DELTA_TYPE_OF:
		case DELTA_PRIMITIVE:
		case DELTA_COLLAPSE:
			foreach (input : node.inputs)
			{
				DeltaValueProvenance input_value =
					delta_analyze_provenance(context, input, bindings);
				delta_note_merged_closure_provenance(
					context, input_value
				);
				if (input_value.suspended_request_path)
				{
					result.suspended_request_path = true;
				}
				if (!input_value.has_request_free_path) return result;
			}
			result.has_request_free_path = true;
			return result;
		default:
			context.failed_closed = true;
			return delta_unknown_provenance_for_type(
				context.program, expected_type
			);
	}
}

fn DeltaValueProvenance delta_analyze_provenance(
	DeltaProvenanceContext* context,
	DeltaNodeId node_id,
	DeltaClosureBinding* bindings,
	TypeId expected_type = TYPE_ID_INVALID
)
{
	if (!context || !delta_provenance_charge(context, 1)
		|| !node_id || (usz)node_id > context.program.image.nodes.len)
	{
		if (context) context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context ? context.program : null, expected_type
		);
	}
	DeltaNode* node = &context.program.image.nodes[(usz)node_id - 1];
	if ((usz)context.active.len() >= DELTA_MAX_EVALUATION_DEPTH)
	{
		context.failed_closed = true;
		return delta_unknown_provenance_for_type(
			context.program,
			expected_type
				? expected_type
				: delta_provenance_node_type(context.program, node)
		);
	}
	bool memoized = !bindings && !context.request_capture
		&& !context.resume && !context.substitution
		&& expected_type == TYPE_ID_INVALID;
	if (memoized)
	{
		char state = context.memo_state[(usz)node_id - 1];
		if (state == 2) return context.memo_values[(usz)node_id - 1];
		if (state == 1)
		{
			context.failed_closed = true;
			return delta_unknown_provenance_for_type(
				context.program,
				delta_provenance_node_type(context.program, node)
			);
		}
		context.memo_state[(usz)node_id - 1] = 1;
	}
	else
	{
		foreach (&frame : context.active)
		{
			if (frame.node != node_id || frame.bindings != bindings)
			{
				continue;
			}
			context.failed_closed = true;
			return delta_unknown_provenance_for_type(
				context.program,
				expected_type
					? expected_type
					: delta_provenance_node_type(context.program, node)
			);
		}
	}
	context.active.push({ .node = node_id, .bindings = bindings });
	DeltaValueProvenance result = delta_analyze_provenance_body(
		context, node_id, node, bindings, expected_type
	);
	(void)context.active.pop()!!;
	if (memoized)
	{
		context.memo_values[(usz)node_id - 1] = result;
		context.memo_state[(usz)node_id - 1] = 2;
	}
	return result;
}

fn usz delta_provenance_work_limit(DeltaProgram* program)
{
	if (!program) return DELTA_PROVENANCE_MIN_WORK;
	usz nodes = program.image.nodes.len;
	usz roots = program.method_roots.len;
	if (roots == usz::max || nodes > usz::max - roots - 1)
	{
		return DELTA_PROVENANCE_MAX_WORK;
	}
	usz size = nodes + roots + 1;
	usz limit = DELTA_PROVENANCE_MAX_WORK;
	if (size <= DELTA_PROVENANCE_MAX_WORK / size)
	{
		usz square = size * size;
		if (square <= DELTA_PROVENANCE_MAX_WORK / 4)
		{
			limit = square * 4;
		}
	}
	return limit < DELTA_PROVENANCE_MIN_WORK
		? DELTA_PROVENANCE_MIN_WORK : limit;
}

fn bool delta_program_has_semantic_effects(DeltaProgram* program)
{
	if (!program) return false;
	if (program.effects.effects.len || program.effects.operations.len
		|| program.effects.instances.len || program.effects.handlers.len)
	{
		return true;
	}
	foreach (&row : program.effects.rows)
	{
		if (delta_effect_row_has_effects(&row.inferred)
			|| (row.has_assertion
				&& delta_effect_row_has_effects(&row.asserted))) return true;
	}
	foreach (&root : program.method_roots)
	{
		if (delta_effect_row_has_effects(&root.effect_row)) return true;
	}
	foreach (&node : program.image.nodes)
	{
		if (delta_effect_row_has_effects(&node.effect_row)) return true;
		switch (node.kind)
		{
			case DELTA_EFFECT:
			case DELTA_HANDLER:
			case DELTA_RESUME:
			case DELTA_ABORT:
				return true;
			default:
		}
	}
	return false;
}

fn bool delta_program_requires_dynamic_effect_closures(
	DeltaProgram* program
)
{
	if (!program || !program.entry || !program.image.nodes.len) return false;
	Allocator allocator = program.allocator ? program.allocator : mem;
	DeltaProvenanceContext context = {
		.program = program,
		.allocator = allocator,
		.work_limit = delta_provenance_work_limit(program),
	};
	context.binding_sets.init(allocator);
	context.active.init(allocator);
	context.root_active = alloc::new_array(
		allocator, char, (sz)program.method_roots.len
	);
	context.memo_state = alloc::new_array(
		allocator, char, (sz)program.image.nodes.len
	);
	context.memo_values = alloc::new_array(
		allocator, DeltaValueProvenance, (sz)program.image.nodes.len
	);
	foreach (&state : context.root_active) *state = 0;
	foreach (&state : context.memo_state) *state = 0;
	foreach (&value : context.memo_values) *value = { };

	DeltaValueProvenance entry = delta_analyze_provenance(
		&context, program.entry, null
	);
	delta_note_merged_closure_provenance(&context, entry);
	bool required = context.dynamic_effectful_closure
		|| context.failed_closed;

	foreach (set : context.binding_sets)
	{
		alloc::free(allocator, set);
	}
	context.binding_sets.free();
	context.active.free();
	alloc::free(allocator, context.root_active);
	alloc::free(allocator, context.memo_state);
	alloc::free(allocator, context.memo_values);
	return required;
}

fn DeltaFeatureBits delta_program_semantic_features(DeltaProgram* program)
{
	if (!program) return (DeltaFeatureBits)0;
	DeltaFeatureBits required =
		DELTA_V4_CORE_REQUIRED_FEATURES | DELTA_FEATURE_TYPED;
	if (delta_program_has_semantic_effects(program))
	{
		required |= DELTA_FEATURE_EFFECTS;
	}
	if (program.image.parallel_regions.len)
	{
		required |= DELTA_FEATURE_PARALLEL;
	}
	foreach (&operation : program.effects.operations)
	{
		if (operation.host_kind == DELTA_EFFECT_EXTERNAL)
		{
			required |= DELTA_FEATURE_HOST;
		}
	}
	foreach (&node : program.image.nodes)
	{
		switch (node.kind)
		{
			case DELTA_PARALLEL_ROOT:
			case DELTA_PARALLEL_JOIN:
				required |= DELTA_FEATURE_PARALLEL;
			case DELTA_SUPERPOSE:
			case DELTA_COLLAPSE:
				required |= DELTA_FEATURE_SUPERPOSITION;
			default:
		}
	}
	if (delta_program_requires_dynamic_effect_closures(program))
	{
		required |= DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES;
	}
	return required;
}

fn bool delta_program_feature_coherence(DeltaProgram* program)
{
	if (!program
		|| !delta_feature_manifest_is_valid(program.feature_manifest)
		|| !delta_feature_manifest_is_valid(program.helper_abi.features)
		|| (program.feature_manifest.required & DELTA_V4_CORE_REQUIRED_FEATURES)
			!= DELTA_V4_CORE_REQUIRED_FEATURES
		|| program.feature_manifest.required != program.helper_abi.features.required
		|| program.feature_manifest.optional != program.helper_abi.features.optional)
	{
		return false;
	}
	DeltaFeatureBits semantic = delta_program_semantic_features(program);
	return !(semantic & ~program.feature_manifest.required);
}

/** One compatibility gate shared by every Delta consumer. */
fn bool delta_program_is_compatible(
	DeltaProgram* program,
	DeltaFeatureBits supported = DELTA_FEATURE_ALL_KNOWN
)
{
	return program
		&& program.runtime_identity
		&& delta_schema_is_supported(program.schema, program.feature_manifest, supported)
		&& delta_helper_abi_is_supported(&program.helper_abi, supported)
		&& delta_program_feature_coherence(program);
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
	self.key.deinit(allocator);
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
	self.key.deinit(allocator);
	alloc::free(allocator, self.name);
	alloc::free(allocator, self.parameters);
	*self = { };
}

fn void DeltaNode.deinit(&self, Allocator allocator)
{
	self.key.deinit(allocator);
	alloc::free(allocator, self.string_value);
	alloc::free(allocator, self.name);
	foreach (name : self.names) alloc::free(allocator, name);
	alloc::free(allocator, self.names);
	alloc::free(allocator, self.types);
	self.effect_row.deinit(allocator);
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
		effect.key.deinit(allocator);
		alloc::free(allocator, effect.name);
		foreach (parameter : effect.parameters) alloc::free(allocator, parameter);
		alloc::free(allocator, effect.parameters);
		alloc::free(allocator, effect.operations);
	}
	alloc::free(allocator, self.effects);
	foreach (&operation : self.operations)
	{
		operation.key.deinit(allocator);
		alloc::free(allocator, operation.name);
		foreach (pattern : operation.parameter_patterns) alloc::free(allocator, pattern);
		alloc::free(allocator, operation.parameter_patterns);
		alloc::free(allocator, operation.result_pattern);
		foreach (&pattern : operation.parameter_types) pattern.deinit(allocator);
		alloc::free(allocator, operation.parameter_types);
		operation.result_type.deinit(allocator);
	}
	alloc::free(allocator, self.operations);
	foreach (&instance : self.instances)
	{
		instance.key.deinit(allocator);
		alloc::free(allocator, instance.arguments);
	}
	alloc::free(allocator, self.instances);
	foreach (&row : self.rows)
	{
		row.key.deinit(allocator);
		row.inferred.deinit(allocator);
		row.asserted.deinit(allocator);
	}
	alloc::free(allocator, self.rows);
	foreach (&handler : self.handlers)
	{
		foreach (&clause : handler.clauses)
		{
			clause.key.deinit(allocator);
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
	foreach (&boundary : self.interfaces)
	{
		boundary.key.deinit(allocator);
		alloc::free(allocator, boundary.name);
	}
	alloc::free(allocator, self.interfaces);
	foreach (&region : self.parallel_regions) alloc::free(allocator, region.roots);
	alloc::free(allocator, self.parallel_regions);
	*self = { };
}

fn void DeltaProgram.deinit(&self)
{
	if (!self.allocator) return;
	self.module_key.deinit(self.allocator);
	self.types.deinit();
	self.methods.deinit();
	foreach (&constructor : self.constructors) constructor.deinit(self.allocator);
	alloc::free(self.allocator, self.constructors);
	foreach (&primitive : self.primitives) primitive.deinit(self.allocator);
	alloc::free(self.allocator, self.primitives);
	self.image.deinit(self.allocator);
	foreach (&method : self.method_roots)
	{
		method.key.deinit(self.allocator);
		method.generic_key.deinit(self.allocator);
		foreach (parameter : method.parameters) alloc::free(self.allocator, parameter);
		alloc::free(self.allocator, method.parameters);
		alloc::free(self.allocator, method.parameter_types);
		foreach (&pattern : method.parameter_patterns) pattern.deinit(self.allocator);
		alloc::free(self.allocator, method.parameter_patterns);
		method.result_pattern.deinit(self.allocator);
		method.effect_row.deinit(self.allocator);
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
