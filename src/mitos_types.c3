module delta_net_abstract_machine::mitos;

import std::collections::list;
import std::core::mem;
import std::io;
import std::thread;
import std::atomic::types;

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

enum LayoutKind : char
{
	LAYOUT_UNSIZED,
	LAYOUT_SCALAR,
	LAYOUT_TAGGED_RECORD,
	LAYOUT_SEQUENCE,
	LAYOUT_CALLABLE,
}

enum CopyPolicy : char
{
	COPY_TRIVIAL,
	COPY_SHARED_IMMUTABLE,
	COPY_AFFINE,
	COPY_BORROWED,
}

/**
 * Persistent data-layout ABI. It contains no allocator, address, callback,
 * retain count, host handle, or other runtime pointer.
 */
struct LayoutDescriptor
{
	LayoutKind kind;
	CopyPolicy copy_policy;
	bool sized;
	ulong size;
	ulong alignment;
	ulong stride;
	TypeId element_type;
	SymbolKey stable_key;
}

fn bool layout_descriptor_is_valid(LayoutDescriptor* layout)
{
	if (!layout || !symbol_key_is_canonical(&layout.stable_key)
		|| (uint)layout.kind > (uint)LayoutKind.LAYOUT_CALLABLE
		|| (uint)layout.copy_policy > (uint)CopyPolicy.COPY_BORROWED
		|| !layout.alignment
		|| (layout.alignment & (layout.alignment - 1)) != 0) return false;
	if (layout.kind != LAYOUT_SEQUENCE && layout.element_type != TYPE_ID_INVALID)
	{
		return false;
	}
	switch (layout.kind)
	{
		case LAYOUT_UNSIZED:
			return !layout.sized && !layout.size && !layout.stride
				&& layout.alignment == 1;
		case LAYOUT_SEQUENCE:
			return !layout.sized && !layout.size && !layout.stride;
		case LAYOUT_CALLABLE:
			return !layout.sized && !layout.size && !layout.stride
				&& layout.alignment == 1 && layout.copy_policy == COPY_AFFINE;
		case LAYOUT_SCALAR:
			return layout.sized && layout.stride >= layout.size
				&& !(layout.stride % layout.alignment)
				&& (layout.size || layout.stride);
		case LAYOUT_TAGGED_RECORD:
			return layout.sized && layout.size >= 4 && layout.alignment >= 4
				&& layout.stride >= layout.size
				&& !(layout.stride % layout.alignment);
		default:
			return false;
	}
}

fn LayoutDescriptor clone_layout_descriptor(
	LayoutDescriptor* layout,
	Allocator allocator = mem
)
{
	if (!layout) return { };
	LayoutDescriptor clone = *layout;
	clone.stable_key = clone_symbol_key(&layout.stable_key, allocator);
	return clone;
}

fn void LayoutDescriptor.deinit(&self, Allocator allocator)
{
	self.stable_key.deinit(allocator);
	*self = { };
}

fn bool checked_layout_add(ulong left, ulong right, ulong* result) @private
{
	if (right > ulong::max - left) return false;
	*result = left + right;
	return true;
}

fn bool checked_layout_align(ulong value, ulong alignment, ulong* result) @private
{
	if (!alignment || (alignment & (alignment - 1))) return false;
	ulong remainder = value & (alignment - 1);
	if (!remainder)
	{
		*result = value;
		return true;
	}
	return checked_layout_add(value, alignment - remainder, result);
}

fn CopyPolicy combined_copy_policy(CopyPolicy current, CopyPolicy field) @private
{
	if (current == COPY_BORROWED || field == COPY_BORROWED) return COPY_BORROWED;
	if (current == COPY_AFFINE || field == COPY_AFFINE) return COPY_AFFINE;
	if (current == COPY_SHARED_IMMUTABLE || field == COPY_SHARED_IMMUTABLE)
	{
		return COPY_SHARED_IMMUTABLE;
	}
	return COPY_TRIVIAL;
}

enum LayoutDerivationResult : char
{
	LAYOUT_DERIVATION_OK,
	LAYOUT_DERIVATION_UNSIZED,
	LAYOUT_DERIVATION_INVALID,
	LAYOUT_DERIVATION_OVERFLOW,
}

struct TypeLayoutDerivationFrame @private
{
	TypeLayoutDerivationFrame* parent;
	TypeId constructor;
	TypeId[] arguments;
}

fn bool type_layout_derivation_contains(
	TypeLayoutDerivationFrame* frame,
	TypeId constructor,
	TypeId[] arguments
) @private
{
	usz depth = 0;
	for (TypeLayoutDerivationFrame* current = frame; current; current = current.parent)
	{
		if (depth++ >= MITOS_MAX_TYPE_FORMAT_DEPTH
			|| (current.constructor == constructor
				&& type_arguments_equal(current.arguments, arguments))) return true;
	}
	return false;
}

fn void make_layout_unsized(LayoutDescriptor* layout) @private
{
	layout.kind = LAYOUT_UNSIZED;
	layout.sized = false;
	layout.size = 0;
	layout.alignment = 1;
	layout.stride = 0;
	layout.element_type = TYPE_ID_INVALID;
}


fn LayoutDerivationResult derive_tagged_layout(
	TypeRegistry* registry,
	TypeDescriptor* base,
	TypeId[] arguments,
	LayoutDescriptor* result,
	TypeLayoutDerivationFrame* frame = null,
	List{TypeId}* blockers = null
) @private
{
	if (!registry || !base || !result || base.kind == TYPE_DESCRIPTOR_ABSTRACT)
	{
		return LAYOUT_DERIVATION_INVALID;
	}
	if (base.parameters.len != arguments.len) return LAYOUT_DERIVATION_INVALID;
	TypePatternBinding[] bindings = alloc::new_array(
		registry.allocator, TypePatternBinding, arguments.len
	);
	defer alloc::free(registry.allocator, bindings);
	foreach (index, parameter : base.parameters)
		bindings[index] = { .variable = parameter, .type_id = arguments[index] };
	ulong size = 4;
	ulong alignment = 4;
	CopyPolicy policy = COPY_TRIVIAL;
	bool layout_blocked = false;
	foreach (&field : base.fields)
	{
		TypeId field_type = field.declared_type;
		MitosDiagnostic ignored;
		if (!field_type || field_type == TYPE_ID_ANY)
		{
			bool recursive_layout = false;
			if (!instantiate_type_pattern(
				registry, &field.pattern, bindings, &field_type, &ignored, field.span,
				0, frame, &recursive_layout
			))
			{
				ignored.deinit();
				if (recursive_layout)
				{
					layout_blocked = true;
					continue;
				}
				return LAYOUT_DERIVATION_INVALID;
			}
		}
		TypeDescriptor* field_descriptor = type_descriptor(registry, field_type);
		if (!field_descriptor || !layout_descriptor_is_valid(&field_descriptor.layout))
		{
			return LAYOUT_DERIVATION_INVALID;
		}
		if (!field_descriptor.layout.sized)
		{
			if (blockers) blockers.push(field_type);
			layout_blocked = true;
			continue;
		}
		if (layout_blocked) continue;
		ulong field_offset;
		if (!checked_layout_align(size, field_descriptor.layout.alignment, &field_offset)
			|| !checked_layout_add(field_offset, field_descriptor.layout.size, &size))
		{
			return LAYOUT_DERIVATION_OVERFLOW;
		}
		if (field_descriptor.layout.alignment > alignment)
		{
			alignment = field_descriptor.layout.alignment;
		}
		policy = combined_copy_policy(policy, field_descriptor.layout.copy_policy);
	}
	if (layout_blocked) return LAYOUT_DERIVATION_UNSIZED;
	ulong stride;
	if (!checked_layout_align(size, alignment, &stride))
	{
		return LAYOUT_DERIVATION_OVERFLOW;
	}
	result.kind = LAYOUT_TAGGED_RECORD;
	result.copy_policy = policy;
	result.sized = true;
	result.size = size;
	result.alignment = alignment;
	result.stride = stride ? stride : alignment;
	result.element_type = TYPE_ID_INVALID;
	return layout_descriptor_is_valid(result)
		? LAYOUT_DERIVATION_OK : LAYOUT_DERIVATION_INVALID;
}

fn bool type_registry_layouts_are_valid(TypeRegistry* registry)
{
	if (!registry) return false;
	foreach (&descriptor : registry.descriptors)
	{
		if (descriptor.id == TYPE_ID_INVALID
			|| !layout_descriptor_is_valid(&descriptor.layout)) return false;
		if (descriptor.kind == TYPE_DESCRIPTOR_INSTANCE)
		{
			TypeDescriptor* base = type_descriptor(registry, descriptor.constructor);
			if (!base || base.arity != descriptor.arguments.len) return false;
		}
	}
	return true;
}

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
	SymbolKey key;
	LayoutDescriptor layout;
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
	ResolvedEffectRow function_effects;
	MitosSpan span;
}

struct TypeRegistryIndexes @private
{
	TypeId[] key_index;
	TypeId[] name_index;
	TypeId[] instance_index;
}

/**
 * Non-dereferenceable cache capability. Backing addresses remain in the
 * module-owned slot table and every use revalidates all three coordinates.
 */
struct TypeRegistryIndexHandle
{
	usz slot;
	ulong generation;
	ulong identity;
}

struct TypeRegistryIndexSlot @private
{
	TypeRegistryIndexes indexes;
	Allocator allocator;
	char* owner_key;
	usz owner_key_len;
	ulong owner_identity;
	ulong generation;
	ulong identity;
	bool active;
}

const usz MITOS_MAX_TYPE_INDEX_STATES = 4_096;
Atomic{ulong} type_registry_index_guard @private;
TypeRegistryIndexSlot[MITOS_MAX_TYPE_INDEX_STATES] type_registry_index_slots @private;

struct TypeRegistry
{
	Allocator allocator;
	ModuleKey module_key;
	List{TypeDescriptor} descriptors;
	/** Runtime-only validated cache handle; persistent/AOT metadata remains in descriptors. */
	TypeRegistryIndexHandle runtime_indexes;
	ulong runtime_index_owner;

	usz max_types;
	ulong epoch;
}

struct TypeRegistryBuildResult
{
	Allocator allocator;
	TypeRegistry registry;
	MitosDiagnostic[] diagnostics;
}


fn bool TypeRegistryBuildResult.ok(&self) => self.diagnostics.len == 0;
fn ulong type_hash_string(ulong hash, String value) @private
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

fn ulong type_hash_id(ulong hash, TypeId id) @private
{
	hash ^= (ulong)id;
	hash *= 1099511628211UL;
	return hash;
}

fn ulong type_symbol_hash(SymbolKey* key) @private
{
	ulong hash = 1469598103934665603UL;
	hash = type_hash_string(hash, key.owner.canonical);
	hash = type_hash_id(hash, (TypeId)key.kind);
	hash = type_hash_string(hash, key.name);
	hash = type_hash_id(hash, (TypeId)key.arity);
	return type_hash_string(hash, key.canonical_signature);
}

fn ulong type_name_hash(ModuleKey* owner, String name) @private
{
	ulong hash = type_hash_string(1469598103934665603UL, owner.canonical);
	return type_hash_string(hash, name);
}

fn ulong type_instance_hash(TypeDescriptor* descriptor) @private
{
	ulong hash = type_hash_id(1469598103934665603UL, (TypeId)descriptor.kind);
	hash = type_hash_id(hash, descriptor.constructor);
	if (descriptor.kind == TYPE_DESCRIPTOR_INSTANCE)
	{
		foreach (argument : descriptor.arguments) hash = type_hash_id(hash, argument);
		return hash;
	}
	foreach (parameter : descriptor.function_parameters) hash = type_hash_id(hash, parameter);
	hash = type_hash_id(hash, descriptor.function_result);
	foreach (effect : descriptor.function_effects.required) hash = type_hash_id(hash, (TypeId)effect);
	hash = type_hash_id(hash, descriptor.function_effects.has_tail ? (TypeId)1 : TYPE_ID_INVALID);
	if (descriptor.function_effects.has_tail)
	{
		hash ^= type_symbol_hash(&descriptor.function_effects.tail);
		hash *= 1099511628211UL;
	}
	return hash;
}

fn bool type_instance_equal(TypeDescriptor* left, TypeDescriptor* right) @private
{
	if (left.kind != right.kind || left.constructor != right.constructor) return false;
	if (left.kind == TYPE_DESCRIPTOR_INSTANCE)
	{
		return type_arguments_equal(left.arguments, right.arguments);
	}
	return type_arguments_equal(left.function_parameters, right.function_parameters)
		&& left.function_result == right.function_result
		&& resolved_effect_row_equal(&left.function_effects, &right.function_effects);
}

fn usz type_registry_index_capacity(usz max_types) @private
{
	usz capacity = 32;
	while (capacity < max_types * 2) capacity *= 2;
	return capacity;
}

fn void type_registry_index_lock() @private
{
	for (;;)
	{
		ulong expected = 0;
		if (type_registry_index_guard.compare_exchange(&expected, 1)) return;
		thread::yield();
	}
}

fn void type_registry_index_unlock() @private
{
	type_registry_index_guard.store(0);
}

fn bool type_registry_index_handle_is_set(TypeRegistryIndexHandle handle) @private
{
	return handle.slot != 0 || handle.generation != 0 || handle.identity != 0;
}

fn void type_registry_free_index_arrays(
	TypeRegistryIndexes* indexes,
	Allocator allocator
) @private
{
	alloc::free(allocator, indexes.key_index);
	alloc::free(allocator, indexes.name_index);
	alloc::free(allocator, indexes.instance_index);
	*indexes = { };
}

fn bool type_registry_slot_is_owned_by(
	TypeRegistryIndexSlot* slot,
	TypeRegistry* registry
) @private
{
	return slot.active && registry.runtime_index_owner
		&& slot.owner_identity == registry.runtime_index_owner
		&& slot.owner_key == registry.module_key.canonical.ptr
		&& slot.owner_key_len == registry.module_key.canonical.len;
}

fn TypeRegistryIndexes* type_registry_indexes(TypeRegistry* registry) @private
{
	if (!registry
		|| registry.max_types < (usz)TYPE_ID_SUPERPOSITION
		|| registry.max_types > MITOS_DEFAULT_MAX_TYPES
		|| (usz)registry.descriptors.len() > registry.max_types)
	{
		return null;
	}
	TypeRegistryIndexHandle handle = registry.runtime_indexes;
	if (!handle.slot || handle.slot > MITOS_MAX_TYPE_INDEX_STATES
		|| !handle.generation || !handle.identity) return null;

	type_registry_index_lock();
	TypeRegistryIndexSlot* slot = &type_registry_index_slots[handle.slot - 1];
	if (!slot.active || slot.generation != handle.generation
		|| slot.identity != handle.identity
		|| !type_registry_slot_is_owned_by(slot, registry))
	{
		type_registry_index_unlock();
		return null;
	}
	TypeRegistryIndexes* indexes = &slot.indexes;
	usz capacity = type_registry_index_capacity(registry.max_types);
	if (indexes.key_index.len != capacity
		|| indexes.name_index.len != capacity
		|| indexes.instance_index.len != capacity)
	{
		type_registry_index_unlock();
		return null;
	}
	type_registry_index_unlock();
	return indexes;
}

fn bool type_registry_register_indexes(
	TypeRegistry* registry,
	TypeRegistryIndexes indexes
) @private
{
	if (!registry.runtime_index_owner)
	{
		registry.runtime_index_owner = new_runtime_identity();
		if (!registry.runtime_index_owner) return false;
	}
	ulong identity = new_runtime_identity();
	if (!identity) return false;
	type_registry_index_lock();
	for (usz index = 0; index < MITOS_MAX_TYPE_INDEX_STATES; index++)
	{
		TypeRegistryIndexSlot* slot = &type_registry_index_slots[index];
		if (slot.active) continue;
		ulong generation = slot.generation == ulong::max ? 1 : slot.generation + 1;
		*slot = {
			.indexes = indexes,
			.allocator = registry.allocator,
			.owner_key = registry.module_key.canonical.ptr,
			.owner_key_len = registry.module_key.canonical.len,
			.owner_identity = registry.runtime_index_owner,
			.generation = generation,
			.identity = identity,
			.active = true,
		};
		registry.runtime_indexes = {
			.slot = index + 1,
			.generation = generation,
			.identity = identity,
		};
		type_registry_index_unlock();
		return true;
	}
	type_registry_index_unlock();
	return false;
}

fn void type_registry_clear_indexes(TypeRegistry* registry) @private
{
	if (!registry) return;
	TypeRegistryIndexHandle handle = registry.runtime_indexes;
	registry.runtime_indexes = { };

	TypeRegistryIndexes released;
	Allocator allocator;
	bool found = false;
	type_registry_index_lock();
	TypeRegistryIndexSlot* selected = null;
	if (handle.slot && handle.slot <= MITOS_MAX_TYPE_INDEX_STATES
		&& handle.generation && handle.identity)
	{
		TypeRegistryIndexSlot* candidate =
			&type_registry_index_slots[handle.slot - 1];
		if (candidate.generation == handle.generation
			&& candidate.identity == handle.identity
			&& type_registry_slot_is_owned_by(candidate, registry))
		{
			selected = candidate;
		}
	}
	if (!selected)
	{
		foreach (&candidate : type_registry_index_slots)
		{
			if (type_registry_slot_is_owned_by(candidate, registry))
			{
				selected = candidate;
				break;
			}
		}
	}
	if (selected)
	{
		released = selected.indexes;
		allocator = selected.allocator;
		ulong generation = selected.generation;
		*selected = { .generation = generation };
		found = true;
	}
	type_registry_index_unlock();
	if (found) type_registry_free_index_arrays(&released, allocator);
}

fn TypeId type_key_index_lookup(TypeRegistry* registry, SymbolKey* key) @private
{
	TypeRegistryIndexes* indexes = type_registry_indexes(registry);
	if (!indexes || !key) return TYPE_ID_INVALID;
	usz mask = indexes.key_index.len - 1;
	usz slot = (usz)type_symbol_hash(key) & mask;
	for (usz probe = 0; probe < indexes.key_index.len; probe++)
	{
		TypeId id = indexes.key_index[slot];
		if (!id) return TYPE_ID_INVALID;
		if ((usz)id > (usz)registry.descriptors.len()) return TYPE_ID_INVALID;
		TypeDescriptor* descriptor = type_descriptor(registry, id);
		if (!descriptor || descriptor.id != id) return TYPE_ID_INVALID;
		if (symbol_key_equal(&descriptor.key, key)) return id;
		slot = (slot + 1) & mask;
	}
	return TYPE_ID_INVALID;
}

fn TypeId type_name_index_lookup(
	TypeRegistry* registry,
	ModuleKey* owner,
	String name
) @private
{
	TypeRegistryIndexes* indexes = type_registry_indexes(registry);
	if (!indexes || !owner) return TYPE_ID_INVALID;
	usz mask = indexes.name_index.len - 1;
	usz slot = (usz)type_name_hash(owner, name) & mask;
	for (usz probe = 0; probe < indexes.name_index.len; probe++)
	{
		TypeId id = indexes.name_index[slot];
		if (!id) return TYPE_ID_INVALID;
		if ((usz)id > (usz)registry.descriptors.len()) return TYPE_ID_INVALID;
		TypeDescriptor* descriptor = type_descriptor(registry, id);
		if (!descriptor || descriptor.id != id) return TYPE_ID_INVALID;
		if (descriptor.kind != TYPE_DESCRIPTOR_INSTANCE
			&& descriptor.kind != TYPE_DESCRIPTOR_FUNCTION_INSTANCE
			&& descriptor.name == name
			&& module_key_equal(&descriptor.key.owner, owner)) return id;
		slot = (slot + 1) & mask;
	}
	return TYPE_ID_INVALID;
}

fn TypeId type_instance_index_lookup(
	TypeRegistry* registry,
	TypeDescriptor* candidate
) @private
{
	TypeRegistryIndexes* indexes = type_registry_indexes(registry);
	if (!indexes || !candidate) return TYPE_ID_INVALID;
	usz mask = indexes.instance_index.len - 1;
	usz slot = (usz)type_instance_hash(candidate) & mask;
	for (usz probe = 0; probe < indexes.instance_index.len; probe++)
	{
		TypeId id = indexes.instance_index[slot];
		if (!id) return TYPE_ID_INVALID;
		if ((usz)id > (usz)registry.descriptors.len()) return TYPE_ID_INVALID;
		TypeDescriptor* descriptor = type_descriptor(registry, id);
		if (!descriptor || descriptor.id != id) return TYPE_ID_INVALID;
		if (type_instance_equal(descriptor, candidate)) return id;
		slot = (slot + 1) & mask;
	}
	return TYPE_ID_INVALID;
}

fn bool type_registry_index_descriptor(
	TypeRegistry* registry,
	TypeDescriptor* descriptor
) @private
{
	TypeRegistryIndexes* indexes = type_registry_indexes(registry);
	if (!indexes || !descriptor || !descriptor.id
		|| (usz)descriptor.id > (usz)registry.descriptors.len()) return false;
	usz key_mask = indexes.key_index.len - 1;
	usz key_slot = (usz)type_symbol_hash(&descriptor.key) & key_mask;
	for (usz probe = 0; probe < indexes.key_index.len; probe++)
	{
		TypeId existing = indexes.key_index[key_slot];
		if (!existing)
		{
			indexes.key_index[key_slot] = descriptor.id;
			break;
		}
		if ((usz)existing > (usz)registry.descriptors.len()) return false;
		TypeDescriptor* other = type_descriptor(registry, existing);
		if (!other || other.id != existing) return false;
		if (symbol_key_equal(&other.key, &descriptor.key)) return false;
		key_slot = (key_slot + 1) & key_mask;
		if (probe + 1 == indexes.key_index.len) return false;
	}
	if (descriptor.kind != TYPE_DESCRIPTOR_INSTANCE
		&& descriptor.kind != TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
	{
		usz name_mask = indexes.name_index.len - 1;
		usz name_slot = (usz)type_name_hash(&descriptor.key.owner, descriptor.name) & name_mask;
		for (usz probe = 0; probe < indexes.name_index.len; probe++)
		{
			TypeId existing = indexes.name_index[name_slot];
			if (!existing)
			{
				indexes.name_index[name_slot] = descriptor.id;
				break;
			}
			if ((usz)existing > (usz)registry.descriptors.len()) return false;
			TypeDescriptor* other = type_descriptor(registry, existing);
			if (!other || other.id != existing) return false;
			if (other.name == descriptor.name
				&& module_key_equal(&other.key.owner, &descriptor.key.owner)) break;
			name_slot = (name_slot + 1) & name_mask;
		}
	}
	if (descriptor.kind != TYPE_DESCRIPTOR_INSTANCE
		&& descriptor.kind != TYPE_DESCRIPTOR_FUNCTION_INSTANCE) return true;
	usz instance_mask = indexes.instance_index.len - 1;
	usz instance_slot = (usz)type_instance_hash(descriptor) & instance_mask;
	for (usz probe = 0; probe < indexes.instance_index.len; probe++)
	{
		TypeId existing = indexes.instance_index[instance_slot];
		if (!existing)
		{
			indexes.instance_index[instance_slot] = descriptor.id;
			return true;
		}
		if ((usz)existing > (usz)registry.descriptors.len()) return false;
		TypeDescriptor* other = type_descriptor(registry, existing);
		if (!other || other.id != existing) return false;
		if (type_instance_equal(other, descriptor)) return false;
		instance_slot = (instance_slot + 1) & instance_mask;
	}
	return false;
}

fn bool type_registry_prepare_indexes(TypeRegistry* registry) @private
{
	if (!registry || registry.max_types < (usz)TYPE_ID_SUPERPOSITION
		|| registry.max_types > MITOS_DEFAULT_MAX_TYPES
		|| (usz)registry.descriptors.len() > registry.max_types) return false;
	if (type_registry_indexes(registry)) return true;
	if (type_registry_index_handle_is_set(registry.runtime_indexes))
	{
		type_registry_clear_indexes(registry);
	}
	usz capacity = type_registry_index_capacity(registry.max_types);
	TypeRegistryIndexes allocated = {
		.key_index = alloc::new_array(registry.allocator, TypeId, (sz)capacity),
		.name_index = alloc::new_array(registry.allocator, TypeId, (sz)capacity),
		.instance_index = alloc::new_array(registry.allocator, TypeId, (sz)capacity),
	};
	foreach (&bucket : allocated.key_index) *bucket = TYPE_ID_INVALID;
	foreach (&bucket : allocated.name_index) *bucket = TYPE_ID_INVALID;
	foreach (&bucket : allocated.instance_index) *bucket = TYPE_ID_INVALID;
	if (!type_registry_register_indexes(registry, allocated))
	{
		type_registry_free_index_arrays(&allocated, registry.allocator);
		return false;
	}
	foreach (index, &descriptor : registry.descriptors)
	{
		if (descriptor.id != (TypeId)((usz)index + 1)
			|| !symbol_key_is_canonical(&descriptor.key)
			|| !type_registry_index_descriptor(registry, descriptor))
		{
			type_registry_clear_indexes(registry);
			return false;
		}
	}
	return true;
}


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
	self.key.deinit(allocator);
	self.layout.deinit(allocator);
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
	self.function_effects.deinit(allocator);
	*self = { };
}

fn void TypeRegistry.deinit(&self)
{
	if (!self.allocator) return;
	type_registry_clear_indexes(self);
	self.module_key.deinit(self.allocator);
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
	if ((usz)registry.descriptors.len() >= registry.max_types
		|| !symbol_key_is_canonical(&descriptor.key)
		|| !type_registry_prepare_indexes(registry)
		|| type_key_index_lookup(registry, &descriptor.key)
		|| ((descriptor.kind == TYPE_DESCRIPTOR_INSTANCE
			|| descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
			&& type_instance_index_lookup(registry, &descriptor)))

	{
		descriptor.deinit(registry.allocator);
		return false;
	}
	descriptor.id = (TypeId)((usz)registry.descriptors.len() + 1);
	registry.descriptors.push(descriptor);
	TypeDescriptor* appended = &registry.descriptors[(usz)descriptor.id - 1];
	if (!type_registry_index_descriptor(registry, appended))
	{
		return false;
	}
	if (result) *result = descriptor.id;
	return true;
}

fn TypeDescriptor builtin_type_descriptor(
	Allocator allocator,
	String name,
	TypeDescriptorKind descriptor_kind,
	TypeId nominal_parent,
	usz arity,
	LayoutKind layout_kind,
	CopyPolicy copy_policy,
	bool sized,
	ulong size,
	ulong alignment,
	ulong stride,
	TypeId element_type,
	MitosSpan span
) @private
{
	ModuleKey core = { .canonical = MITOS_CORE_MODULE_CANONICAL };
	SymbolKey key = symbol_key(&core, SYMBOL_TYPE, name, arity, "", allocator);
	return {
		.key = key,
		.layout = {
			.kind = layout_kind,
			.copy_policy = copy_policy,
			.sized = sized,
			.size = size,
			.alignment = alignment,
			.stride = stride,
			.element_type = element_type,
			.stable_key = clone_symbol_key(&key, allocator),
		},
		.kind = descriptor_kind,
		.name = name.copy(allocator),
		.nominal_parent = nominal_parent,
		.arity = arity,
		.span = span,
	};
}

fn bool type_registry_bootstrap(TypeRegistry* registry) @private
{
	MitosPosition origin = { .row = 1, .column = 1 };
	MitosSpan span = { .start = origin, .end = origin };
	return type_registry_append(registry, builtin_type_descriptor(
		registry.allocator, "Any", TYPE_DESCRIPTOR_ABSTRACT, TYPE_ID_INVALID, 0,
		LAYOUT_UNSIZED, COPY_BORROWED, false, 0, 1, 0, TYPE_ID_INVALID, span
	)) && type_registry_append(registry, builtin_type_descriptor(
		registry.allocator, "Never", TYPE_DESCRIPTOR_CONCRETE, TYPE_ID_ANY, 0,
		LAYOUT_UNSIZED, COPY_TRIVIAL, false, 0, 1, 0, TYPE_ID_INVALID, span
	)) && type_registry_append(registry, builtin_type_descriptor(
		registry.allocator, "Type", TYPE_DESCRIPTOR_CONCRETE, TYPE_ID_ANY, 1,
		LAYOUT_SCALAR, COPY_TRIVIAL, true, 4, 4, 4, TYPE_ID_INVALID, span
	)) && type_registry_append(registry, builtin_type_descriptor(
		registry.allocator, "I64", TYPE_DESCRIPTOR_CONCRETE, TYPE_ID_ANY, 0,
		LAYOUT_SCALAR, COPY_TRIVIAL, true, 8, 8, 8, TYPE_ID_INVALID, span
	)) && type_registry_append(registry, builtin_type_descriptor(
		registry.allocator, "Bool", TYPE_DESCRIPTOR_CONCRETE, TYPE_ID_ANY, 0,
		LAYOUT_SCALAR, COPY_TRIVIAL, true, 1, 1, 1, TYPE_ID_INVALID, span
	)) && type_registry_append(registry, builtin_type_descriptor(
		registry.allocator, "Unit", TYPE_DESCRIPTOR_CONCRETE, TYPE_ID_ANY, 0,
		LAYOUT_SCALAR, COPY_TRIVIAL, true, 0, 1, 1, TYPE_ID_INVALID, span
	)) && type_registry_append(registry, builtin_type_descriptor(
		registry.allocator, "String", TYPE_DESCRIPTOR_CONCRETE, TYPE_ID_ANY, 0,
		LAYOUT_SEQUENCE, COPY_SHARED_IMMUTABLE, false, 0, 1, 0, TYPE_ID_INVALID, span
	)) && type_registry_append(registry, builtin_type_descriptor(
		registry.allocator, "Array", TYPE_DESCRIPTOR_CONCRETE, TYPE_ID_ANY, 1,
		LAYOUT_SEQUENCE, COPY_SHARED_IMMUTABLE, false, 0, 1, 0, TYPE_ID_INVALID, span
	)) && type_registry_append(registry, builtin_type_descriptor(
		registry.allocator, "Function", TYPE_DESCRIPTOR_CONCRETE, TYPE_ID_ANY, 0,
		LAYOUT_CALLABLE, COPY_AFFINE, false, 0, 1, 0, TYPE_ID_INVALID, span
	)) && type_registry_append(registry, builtin_type_descriptor(
		registry.allocator, "Superposition", TYPE_DESCRIPTOR_CONCRETE, TYPE_ID_ANY, 1,
		LAYOUT_SEQUENCE, COPY_SHARED_IMMUTABLE, false, 0, 1, 0, TYPE_ID_INVALID, span
	));
}

fn TypeDescriptor* type_descriptor(TypeRegistry* registry, TypeId id)
{
	if (!registry || id == TYPE_ID_INVALID || (usz)id > (usz)registry.descriptors.len()) return null;
	return &registry.descriptors[(usz)id - 1];
}
fn TypeId find_type_by_key(TypeRegistry* registry, SymbolKey* key)
{
	if (!registry || !symbol_key_is_canonical(key)
		|| !type_registry_prepare_indexes(registry)) return TYPE_ID_INVALID;
	return type_key_index_lookup(registry, key);
}

fn TypeId find_type_in_module(TypeRegistry* registry, ModuleKey* owner, String name)
{
	if (!registry || !owner || !type_registry_prepare_indexes(registry))
	{
		return TYPE_ID_INVALID;
	}
	TypeId found = type_name_index_lookup(registry, owner, name);
	if (found) return found;
	ModuleKey core = { .canonical = MITOS_CORE_MODULE_CANONICAL };
	if (!module_key_equal(owner, &core))
	{
		return type_name_index_lookup(registry, &core, name);
	}
	return TYPE_ID_INVALID;
}


fn TypeId find_type(TypeRegistry* registry, String name)
{
	if (!registry) return TYPE_ID_INVALID;
	if (registry.module_key.canonical.len)
	{
		return find_type_in_module(registry, &registry.module_key, name);
	}
	foreach (&descriptor : registry.descriptors)
	{
		if (descriptor.kind != TYPE_DESCRIPTOR_INSTANCE
			&& descriptor.kind != TYPE_DESCRIPTOR_FUNCTION_INSTANCE
			&& descriptor.name == name) return descriptor.id;
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

fn void append_symbol_key_component(DString* output, String component) @private
{
	foreach (character : component)
	{
		if (character == '\\' || character == '|' || character == ';'
			|| character == '!' || character == ',') output.append_char('\\');
		output.append_char(character);
	}
}

fn String type_tuple_key_signature(
	TypeRegistry* registry,
	TypeId[] types,
	Allocator allocator
) @private
{
	DString output;
	output.init(allocator);
	foreach (index, type : types)
	{
		if (index) output.append_char(';');
		TypeDescriptor* descriptor = type_descriptor(registry, type);
		if (!descriptor)
		{
			output.append_string("<invalid>");
			continue;
		}
		append_symbol_key_component(&output, descriptor.key.owner.canonical);
		output.append_char('|');
		append_symbol_key_component(&output, descriptor.key.name);
		output.append_char('|');
		char[32] arity_buffer;
		output.append_string((String)io::bprintf(
			&arity_buffer, "%d", (long)descriptor.key.arity
		)!!);
		output.append_char('|');
		append_symbol_key_component(&output, descriptor.key.canonical_signature);
	}
	String signature = output.copy_str(allocator);
	output.free();
	return signature;
}

fn int type_key_string_compare(String left, String right) @private
{
	usz common = left.len < right.len ? left.len : right.len;
	for (usz index = 0; index < common; index++)
	{
		if (left[index] < right[index]) return -1;
		if (left[index] > right[index]) return 1;
	}
	if (left.len < right.len) return -1;
	if (left.len > right.len) return 1;
	return 0;
}

fn int function_effect_key_compare(SymbolKey* left, SymbolKey* right) @private
{
	int order = type_key_string_compare(left.owner.canonical, right.owner.canonical);
	if (order) return order;
	if (left.kind < right.kind) return -1;
	if (left.kind > right.kind) return 1;
	order = type_key_string_compare(left.name, right.name);
	if (order) return order;
	if (left.arity < right.arity) return -1;
	if (left.arity > right.arity) return 1;
	return type_key_string_compare(left.canonical_signature, right.canonical_signature);
}

fn void function_effect_key_sift_down(SymbolKey*[] keys, usz root, usz count) @private
{
	for (;;)
	{
		usz child = root * 2 + 1;
		if (child >= count) return;
		if (child + 1 < count
			&& function_effect_key_compare(keys[child], keys[child + 1]) < 0) child++;
		if (function_effect_key_compare(keys[root], keys[child]) >= 0) return;
		SymbolKey* swap = keys[root];
		keys[root] = keys[child];
		keys[child] = swap;
		root = child;
	}
}

fn void sort_function_effect_keys(SymbolKey*[] keys) @private
{
	if (keys.len < 2) return;
	for (usz parent = keys.len / 2; parent > 0; parent--)
	{
		function_effect_key_sift_down(keys, parent - 1, keys.len);
	}
	for (usz end = keys.len; end > 1; end--)
	{
		SymbolKey* swap = keys[0];
		keys[0] = keys[end - 1];
		keys[end - 1] = swap;
		function_effect_key_sift_down(keys, 0, end - 1);
	}
}

fn void append_function_effect_component(
	DString* output,
	String component
) @private
{
	char[32] buffer;
	output.append_string((String)io::bprintf(
		&buffer, "%d:", (long)component.len
	)!!);
	output.append_string(component);
}

fn void append_function_effect_key(DString* output, SymbolKey* key) @private
{
	char[32] buffer;
	append_function_effect_component(output, key.owner.canonical);
	output.append_char('/');
	output.append_string((String)io::bprintf(
		&buffer, "%d/", (long)key.kind
	)!!);
	append_function_effect_component(output, key.name);
	output.append_char('/');
	output.append_string((String)io::bprintf(
		&buffer, "%d/", (long)key.arity
	)!!);
	append_function_effect_component(output, key.canonical_signature);
}

fn String function_type_key_signature(
	TypeRegistry* registry,
	EffectRegistry* effect_registry,
	TypeId[] parameters,
	TypeId result_type,
	ResolvedEffectRow* effects,
	Allocator allocator
) @private
{
	TypeId[] signature_types = alloc::new_array(allocator, TypeId, parameters.len + 1);
	foreach (index, parameter : parameters) signature_types[index] = parameter;
	signature_types[parameters.len] = result_type;
	String type_signature = type_tuple_key_signature(registry, signature_types, allocator);
	alloc::free(allocator, signature_types);
	SymbolKey*[] effect_keys = alloc::new_array(
		allocator, SymbolKey*, effects.required.len
	);
	defer alloc::free(allocator, effect_keys);
	foreach (index, effect : effects.required)
		effect_keys[index] = effect_symbol_key(effect_registry, effect);
	sort_function_effect_keys(effect_keys);
	DString output;
	output.init(allocator);
	output.append_string(type_signature);
	output.append_char('!');
	foreach (index, key : effect_keys)
	{
		if (index) output.append_char(',');
		append_function_effect_key(&output, key);
	}
	if (effects.has_tail)
	{
		output.append_string("|tail:");
		append_function_effect_key(&output, &effects.tail);
	}
	String signature = output.copy_str(allocator);
	output.free();
	alloc::free(allocator, type_signature);
	return signature;
}

fn bool intern_type(
	TypeRegistry* registry,
	TypeId constructor,
	TypeId[] arguments,
	TypeId* result,
	MitosDiagnostic* diagnostic = null,
	MitosSpan span = { },
	TypeLayoutDerivationFrame* derivation_frame = null,
	bool* recursive_layout = null
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
	TypeDescriptor base_snapshot = *base;
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
	TypeDescriptor candidate = {
		.kind = TYPE_DESCRIPTOR_INSTANCE,
		.constructor = constructor,
		.arguments = arguments,
	};
	if (!type_registry_prepare_indexes(registry))
	{
		if (diagnostic) diagnostic.init(registry.allocator, "type registry index is invalid", span);
		return false;
	}
	TypeId existing = type_instance_index_lookup(registry, &candidate);
	if (existing)
	{
		*result = existing;
		return true;
	}
	if (type_layout_derivation_contains(derivation_frame, constructor, arguments))
	{
		if (recursive_layout) *recursive_layout = true;
		return false;
	}
	if ((usz)registry.descriptors.len() >= registry.max_types)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "type registry exhausted its bounded capacity", span);
		return false;
	}

	String signature = type_tuple_key_signature(registry, arguments, registry.allocator);
	SymbolKey key = symbol_key(
		&base_snapshot.key.owner, SYMBOL_TYPE, base_snapshot.name,
		arguments.len, signature, registry.allocator
	);
	alloc::free(registry.allocator, signature);
	LayoutDescriptor layout = clone_layout_descriptor(&base_snapshot.layout, registry.allocator);
	layout.stable_key.deinit(registry.allocator);
	layout.stable_key = clone_symbol_key(&key, registry.allocator);
	LayoutDerivationResult derivation = LAYOUT_DERIVATION_OK;
	if (layout.kind == LAYOUT_SEQUENCE && arguments.len)
	{
		layout.element_type = arguments[0];
	}
	else if (base_snapshot.fields.len)
	{
		TypeLayoutDerivationFrame current_frame = {
			.parent = derivation_frame,
			.constructor = constructor,
			.arguments = arguments,
		};
		derivation = derive_tagged_layout(
			registry, &base_snapshot, arguments, &layout, &current_frame
		);
	}
	if (derivation == LAYOUT_DERIVATION_UNSIZED) make_layout_unsized(&layout);
	if (derivation == LAYOUT_DERIVATION_OVERFLOW
		|| derivation == LAYOUT_DERIVATION_INVALID
		|| !layout_descriptor_is_valid(&layout))
	{
		key.deinit(registry.allocator);
		layout.deinit(registry.allocator);
		if (diagnostic) diagnostic.init(
			registry.allocator,
			derivation == LAYOUT_DERIVATION_OVERFLOW
				? "derived type layout size or alignment overflows its persistent representation"
				: "derived type instance has an invalid persistent layout",
			span
		);
		return false;
	}

	TypeId instance;
	if (!type_registry_append(registry, {
		.key = key,
		.layout = layout,
		.kind = TYPE_DESCRIPTOR_INSTANCE,
		.name = base_snapshot.name.copy(registry.allocator),
		.nominal_parent = base_snapshot.nominal_parent,
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


/** Interns the concrete identity of a closure signature. */
fn bool intern_function_type(
	TypeRegistry* registry,
	EffectRegistry* effect_registry,
	TypeId[] parameters,
	TypeId result_type,
	ResolvedEffectRow* effects,
	TypeId* result,
	MitosDiagnostic* diagnostic = null,
	MitosSpan span = { }
)
{
	usz effect_count = effects ? effects.required.len : 0;
	if (parameters.len > MITOS_MAX_FUNCTION_PARAMETERS
		|| effect_count > MITOS_MAX_FUNCTION_EFFECTS)
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
	if (effects)
	{
		foreach (effect : effects.required)
		{
			SymbolKey* key = effect_symbol_key(effect_registry, effect);
			if (!key || !symbol_key_is_canonical(key))
			{
				if (diagnostic) diagnostic.init(
					registry.allocator,
					"function signature contains an invalid effect identity",
					span
				);
				return false;
			}
		}
		if (effects.has_tail
			&& (effects.tail.kind != SYMBOL_EFFECT_ROW_TAIL
				|| !symbol_key_is_canonical(&effects.tail)))
		{
			if (diagnostic) diagnostic.init(
				registry.allocator,
				"function signature contains a noncanonical effect-row tail",
				span
			);
			return false;
		}
	}
	ResolvedEffectRow canonical_effects = effects
		? normalize_effect_row(
			effects.required, effects.has_tail ? &effects.tail : null, registry.allocator
		) : normalize_effect_row({ }, null, registry.allocator);
	defer canonical_effects.deinit(registry.allocator);
	TypeDescriptor candidate = {
		.kind = TYPE_DESCRIPTOR_FUNCTION_INSTANCE,
		.constructor = TYPE_ID_FUNCTION,
		.function_parameters = parameters,
		.function_result = result_type,
		.function_effects = canonical_effects,
	};
	if (!type_registry_prepare_indexes(registry))
	{
		if (diagnostic) diagnostic.init(registry.allocator, "type registry index is invalid", span);
		return false;
	}
	TypeId existing = type_instance_index_lookup(registry, &candidate);
	if (existing)
	{
		*result = existing;
		return true;
	}
	if ((usz)registry.descriptors.len() >= registry.max_types)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "type registry exhausted its bounded capacity", span);
		return false;
	}
	TypeDescriptor* function_base = type_descriptor(registry, TYPE_ID_FUNCTION);
	String signature = function_type_key_signature(
		registry, effect_registry, parameters, result_type,
		&canonical_effects, registry.allocator
	);
	SymbolKey key = symbol_key(
		&function_base.key.owner, SYMBOL_TYPE, function_base.name,
		parameters.len, signature, registry.allocator
	);
	alloc::free(registry.allocator, signature);
	LayoutDescriptor layout = clone_layout_descriptor(&function_base.layout, registry.allocator);
	layout.stable_key.deinit(registry.allocator);
	layout.stable_key = clone_symbol_key(&key, registry.allocator);
	TypeId instance;
	if (!type_registry_append(registry, {
		.key = key,
		.layout = layout,
		.kind = TYPE_DESCRIPTOR_FUNCTION_INSTANCE,
		.name = "Function".copy(registry.allocator),
		.nominal_parent = TYPE_ID_ANY,
		.constructor = TYPE_ID_FUNCTION,
		.function_parameters = alloc::clone_slice(registry.allocator, parameters),
		.function_result = result_type,
		.function_effects = clone_resolved_effect_row(&canonical_effects, registry.allocator),
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
	usz depth = 0,
	TypeLayoutDerivationFrame* derivation_frame = null,
	bool* recursive_layout = null
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
			registry, argument, bindings, &arguments[index], diagnostic, span, depth + 1,
			derivation_frame, recursive_layout
		)) return false;
	}
	return intern_type(
		registry, pattern.constructor, arguments, result, diagnostic, span,
		derivation_frame, recursive_layout
	);
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

struct TypeSubtypeFrame @private
{
	TypeSubtypeFrame* parent;
	TypeId candidate;
	TypeId expected;
	usz depth;
}

fn bool type_is_subtype_inner(
	TypeRegistry* registry,
	TypeId candidate,
	TypeId expected,
	TypeSubtypeFrame* frame
) @private
{
	if (!type_id_is_valid(registry, candidate) || !type_id_is_valid(registry, expected)) return false;
	if (candidate == TYPE_ID_NEVER || expected == TYPE_ID_ANY || candidate == expected) return true;
	usz depth = frame ? frame.depth + 1 : 1;
	if (depth > MITOS_MAX_TYPE_FORMAT_DEPTH) return false;
	for (TypeSubtypeFrame* current = frame; current; current = current.parent)
	{
		if (current.candidate == candidate && current.expected == expected) return true;
	}
	TypeSubtypeFrame current_frame = {
		.parent = frame,
		.candidate = candidate,
		.expected = expected,
		.depth = depth,
	};
	TypeDescriptor* candidate_descriptor = type_descriptor(registry, candidate);
	TypeDescriptor* expected_descriptor = type_descriptor(registry, expected);
	if (expected_descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
	{
		if (candidate_descriptor.kind != TYPE_DESCRIPTOR_FUNCTION_INSTANCE
			|| candidate_descriptor.function_parameters.len
				!= expected_descriptor.function_parameters.len) return false;
		foreach (index, expected_parameter : expected_descriptor.function_parameters)
		{
			if (!type_is_subtype_inner(
				registry, expected_parameter,
				candidate_descriptor.function_parameters[index], &current_frame
			)) return false;
		}
		return type_is_subtype_inner(
			registry, candidate_descriptor.function_result,
			expected_descriptor.function_result, &current_frame
		) && resolved_effect_row_satisfies(
			&candidate_descriptor.function_effects,
			&expected_descriptor.function_effects
		);
	}
	TypeId current_constructor = candidate_descriptor.kind == TYPE_DESCRIPTOR_INSTANCE
		|| candidate_descriptor.kind == TYPE_DESCRIPTOR_FUNCTION_INSTANCE
		? candidate_descriptor.constructor : candidate;
	TypeId expected_constructor = expected_descriptor.kind == TYPE_DESCRIPTOR_INSTANCE
		? expected_descriptor.constructor : expected;
	TypeId[] candidate_arguments = candidate_descriptor.arguments;
	TypeId[] expected_arguments = expected_descriptor.arguments;
	for (usz hierarchy_depth = 0;
		hierarchy_depth < (usz)registry.descriptors.len(); hierarchy_depth++)
	{
		if (current_constructor == expected_constructor)
		{
			if (expected_descriptor.kind == TYPE_DESCRIPTOR_INSTANCE)
			{
				return type_arguments_equal(candidate_arguments, expected_arguments);
			}
			return !expected_descriptor.arity;
		}
		TypeDescriptor* current = type_descriptor(registry, current_constructor);
		if (!current || !current.nominal_parent) return false;
		TypeDescriptor* parent = type_descriptor(registry, current.nominal_parent);
		if (!parent) return false;
		if (parent.arity)
		{
			if (current.arity != parent.arity
				|| candidate_arguments.len != current.arity) return false;
		}
		else
		{
			candidate_arguments = { };
		}
		current_constructor = current.nominal_parent;
	}
	return false;
}

fn bool type_is_subtype(TypeRegistry* registry, TypeId candidate, TypeId expected)
{
	return type_is_subtype_inner(registry, candidate, expected, null);
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


fn bool nominal_parent_forwards_parameters(
	TypeExpr* supertype,
	TypeParameterDecl[] parameters
) @private
{
	if (!supertype || supertype.kind != TYPE_EXPR_APPLICATION
		|| supertype.arguments.len != parameters.len) return false;
	foreach (index, &argument : supertype.arguments)
	{
		TypeExpr* value = argument.value;
		if (!value || value.kind != TYPE_EXPR_NAMED
			|| value.name != parameters[index].name) return false;
	}
	return true;
}

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

fn void deinit_type_layout_dependencies(
	List{TypeId}[] dependents,
	List{TypeId}* queue,
	Allocator allocator
) @private
{
	foreach (&list : dependents) list.free();
	alloc::free(allocator, dependents);
	queue.free();
}

fn bool derive_completed_type_layouts(
	TypeRegistry* registry,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	usz capacity = registry.max_types + 1;
	List{TypeId}[] dependents = alloc::new_array(
		allocator, List{TypeId}, (sz)capacity
	);
	foreach (&list : dependents) list.init(allocator);
	List{TypeId} queue;
	queue.init(allocator);
	bool[] queued = alloc::new_array(allocator, bool, (sz)capacity);
	defer alloc::free(allocator, queued);
	usz[] unresolved = alloc::new_array(allocator, usz, (sz)capacity);
	defer alloc::free(allocator, unresolved);
	foreach (&pending : queued) *pending = false;
	foreach (&count : unresolved) *count = 0;
	for (usz offset = (usz)TYPE_ID_SUPERPOSITION;
		offset < (usz)registry.descriptors.len(); offset++)
	{
		TypeId id = (TypeId)(offset + 1);
		queue.push(id);
		queued[(usz)id] = true;
	}
	usz head = 0;
	while (head < (usz)queue.len())
	{
		TypeId id = queue[(sz)head++];
		queued[(usz)id] = false;
		TypeDescriptor* current_descriptor = type_descriptor(registry, id);
		if (!current_descriptor || current_descriptor.layout.sized) continue;
		TypeDescriptor snapshot = *current_descriptor;
		TypeDescriptor base = snapshot;
		TypeId[] arguments = { };
		bool derivable = snapshot.kind == TYPE_DESCRIPTOR_CONCRETE
			&& snapshot.key.kind == SYMBOL_TYPE
			&& !snapshot.parameters.len;
		if (snapshot.kind == TYPE_DESCRIPTOR_INSTANCE)
		{
			TypeDescriptor* constructor = type_descriptor(registry, snapshot.constructor);
			if (!constructor)
			{
				types_add_diagnostic(
					diagnostics, allocator,
					"derived type instance has no valid constructor layout",
					snapshot.span
				);
				deinit_type_layout_dependencies(dependents, &queue, allocator);
				return false;
			}
			base = *constructor;
			arguments = snapshot.arguments;
			derivable = constructor.id > TYPE_ID_SUPERPOSITION
				&& constructor.key.kind == SYMBOL_TYPE;
		}
		if (!derivable) continue;

		usz previous_count = (usz)registry.descriptors.len();
		LayoutDescriptor candidate = snapshot.layout;
		List{TypeId} blockers;
		blockers.init(allocator);
		LayoutDerivationResult derivation = derive_tagged_layout(
			registry, &base, arguments, &candidate, null, &blockers
		);
		for (usz offset = previous_count;
			offset < (usz)registry.descriptors.len(); offset++)
		{
			TypeId added = (TypeId)(offset + 1);
			if (!queued[(usz)added])
			{
				queue.push(added);
				queued[(usz)added] = true;
			}
		}
		TypeDescriptor* completed = type_descriptor(registry, id);
		if (!completed)
		{
			types_add_diagnostic(
				diagnostics, allocator,
				"type registry changed incompatibly during layout derivation",
				snapshot.span
			);
			blockers.free();
			deinit_type_layout_dependencies(dependents, &queue, allocator);
			return false;
		}
		if (derivation == LAYOUT_DERIVATION_OK)
		{
			completed.layout = candidate;
			foreach (dependent : dependents[(usz)id])
			{
				if (unresolved[(usz)dependent])
				{
					unresolved[(usz)dependent]--;
					if (!unresolved[(usz)dependent]
						&& !queued[(usz)dependent])
					{
						queue.push(dependent);
						queued[(usz)dependent] = true;
					}
				}
			}
			blockers.free();
			continue;
		}
		make_layout_unsized(&completed.layout);
		if (derivation == LAYOUT_DERIVATION_UNSIZED)
		{
			unresolved[(usz)id] = 0;
			foreach (blocked_on : blockers)
			{
				if (blocked_on && blocked_on != id
					&& (usz)blocked_on < capacity)
				{
					dependents[(usz)blocked_on].push(id);
					unresolved[(usz)id]++;
				}
			}
			blockers.free();
			continue;
		}
		blockers.free();
		types_add_diagnostic(
			diagnostics, allocator,
			derivation == LAYOUT_DERIVATION_OVERFLOW
				? "type layout size or alignment overflows its persistent representation"
				: "type fields do not have a valid persistent layout",
			snapshot.span
		);
		deinit_type_layout_dependencies(dependents, &queue, allocator);
		return false;
	}
	deinit_type_layout_dependencies(dependents, &queue, allocator);
	return true;
}

fn void validate_nominal_hierarchy(
	TypeRegistry* registry,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	usz count = (usz)registry.descriptors.len();
	char[] colors = alloc::new_array(allocator, char, (sz)(count + 1));
	TypeId[] path = alloc::new_array(allocator, TypeId, (sz)count);
	foreach (&color : colors) *color = 0;
	defer alloc::free(allocator, colors);
	defer alloc::free(allocator, path);
	for (TypeId start = (TypeId)1; (usz)start <= count; start++)
	{
		if (colors[(usz)start] == 2) continue;
		usz path_len = 0;
		TypeId current = start;
		while (current)
		{
			if ((usz)current > count) break;
			if (colors[(usz)current] == 2) break;
			if (colors[(usz)current] == 1)
			{
				TypeDescriptor* descriptor = type_descriptor(registry, current);
				types_add_diagnostic(
					diagnostics, allocator,
					"nominal type hierarchy contains a cycle",
					descriptor ? descriptor.span : (MitosSpan){ }
				);
				break;
			}
			colors[(usz)current] = 1;
			path[path_len++] = current;
			TypeDescriptor* descriptor = type_descriptor(registry, current);
			if (!descriptor) break;
			current = descriptor.nominal_parent;
		}
		foreach (visited : path[:(sz)path_len]) colors[(usz)visited] = 2;
	}
}

fn TypeRegistryBuildResult build_type_registry(
	Program* program,
	Allocator allocator = mem,
	usz max_types = MITOS_DEFAULT_MAX_TYPES
)
{
	TypeRegistryBuildResult result = { .allocator = allocator };
	result.registry = {
		.allocator = allocator,
		.module_key = clone_module_key(&program.module_key, allocator),
		.max_types = max_types,
		.epoch = 1,
	};
	result.registry.descriptors.init(allocator);
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);

	if (max_types < (usz)TYPE_ID_SUPERPOSITION
		|| max_types > MITOS_DEFAULT_MAX_TYPES
		|| !type_registry_bootstrap(&result.registry))
	{
		MitosPosition origin = { .row = 1, .column = 1 };
		types_add_diagnostic(&diagnostics, allocator, "type registry capacity is outside its supported bounded range", {
			.start = origin, .end = origin,
		});

		result.diagnostics = diagnostics.to_array(allocator);
		diagnostics.free();
		return result;
	}
	TypeId[] accepted_types = alloc::new_array(allocator, TypeId, program.types.len);
	defer alloc::free(allocator, accepted_types);
	foreach (&accepted : accepted_types) *accepted = TYPE_ID_INVALID;
	foreach (type_index, &type_decl : program.types)
	{
		if (!symbol_key_matches_declaration(
			&type_decl.key, &program.module_key, SYMBOL_TYPE,
			type_decl.name, type_decl.parameters.len, ""
		))
		{
			types_add_diagnostic(
				&diagnostics, allocator,
				"type declaration has an invalid canonical identity", type_decl.span
			);
			continue;
		}

		TypeId existing = find_type_by_key(&result.registry, &type_decl.key);
		TypeId reserved = find_type(&result.registry, type_decl.name);
		if (reserved == TYPE_ID_SUPERPOSITION)
		{
			types_add_diagnostic(
				&diagnostics, allocator,
				"Superposition is a reserved type constructor and cannot be redeclared",
				type_decl.span
			);
			continue;
		}
		if (!existing && reserved) existing = reserved;
		if (existing)
		{
			TypeDescriptor* primitive = type_descriptor(&result.registry, existing);
			TypeDescriptorKind declared_kind = type_decl.kind == TYPE_DECL_ABSTRACT
				? TYPE_DESCRIPTOR_ABSTRACT : TYPE_DESCRIPTOR_CONCRETE;
			if (existing < TYPE_ID_SUPERPOSITION
				&& primitive.arity == type_decl.parameters.len
				&& primitive.kind == declared_kind
				&& !type_decl.fields.len)
			{
				primitive.span = type_decl.span;
				accepted_types[type_index] = existing;

				continue;
			}
			types_add_diagnostic(&diagnostics, allocator, "duplicate nominal type name", type_decl.span);
			continue;
		}
		if ((usz)result.registry.descriptors.len() >= result.registry.max_types)
		{
			types_add_diagnostic(&diagnostics, allocator, "type registry exhausted its bounded capacity", type_decl.span);
			break;
		}

		String[] parameters = alloc::new_array(allocator, String, type_decl.parameters.len);
		foreach (index, &parameter : type_decl.parameters) parameters[index] = parameter.name.copy(allocator);
		SymbolKey key = clone_symbol_key(&type_decl.key, allocator);
		LayoutDescriptor layout = {
			.kind = LAYOUT_UNSIZED,
			.copy_policy = type_decl.kind == TYPE_DECL_ABSTRACT ? COPY_BORROWED : COPY_AFFINE,
			.sized = false,
			.alignment = 1,
			.stable_key = clone_symbol_key(&key, allocator),
		};
		TypeId registered;
		if (!type_registry_append(&result.registry, {
			.key = key,
			.layout = layout,
			.kind = type_decl.kind == TYPE_DECL_ABSTRACT ? TYPE_DESCRIPTOR_ABSTRACT : TYPE_DESCRIPTOR_CONCRETE,
			.name = type_decl.name.copy(allocator),
			.parameters = parameters,
			.arity = type_decl.parameters.len,
			.span = type_decl.span,
		}, &registered))
		{
			types_add_diagnostic(&diagnostics, allocator, "type registry exhausted its bounded capacity", type_decl.span);
			break;
		}
		accepted_types[type_index] = registered;

	}
	foreach (&enum_decl : program.enums)
	{
		if (!symbol_key_matches_declaration(
			&enum_decl.key, &program.module_key, SYMBOL_ENUM,
			enum_decl.name, enum_decl.parameters.len, ""
		))
		{
			types_add_diagnostic(
				&diagnostics, allocator,
				"enum declaration has an invalid canonical identity", enum_decl.span
			);
			continue;
		}
		if (find_type_in_module(&result.registry, &program.module_key, enum_decl.name))
		{
			types_add_diagnostic(&diagnostics, allocator, "duplicate or reserved enum type name", enum_decl.span);
			continue;
		}
		if ((usz)result.registry.descriptors.len() >= result.registry.max_types)
		{
			types_add_diagnostic(&diagnostics, allocator, "type registry exhausted its bounded capacity", enum_decl.span);
			break;
		}

		String[] parameters = alloc::new_array(allocator, String, enum_decl.parameters.len);
		foreach (index, &parameter : enum_decl.parameters) parameters[index] = parameter.name.copy(allocator);
		SymbolKey key = clone_symbol_key(&enum_decl.key, allocator);
		LayoutDescriptor layout = {
			.kind = LAYOUT_UNSIZED,
			.copy_policy = COPY_AFFINE,
			.sized = false,
			.alignment = 1,
			.stable_key = clone_symbol_key(&key, allocator),
		};
		if (!type_registry_append(&result.registry, {
			.key = key,
			.layout = layout,
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
	foreach (type_index, &type_decl : program.types)
	{
		TypeId id = accepted_types[type_index];
		if (!id) continue;
		TypeDescriptor* descriptor = type_descriptor(&result.registry, id);
		if (!descriptor) continue;
		if (id > TYPE_ID_SUPERPOSITION) descriptor.nominal_parent = TYPE_ID_ANY;
		if (type_decl.supertype)
		{
			TypeId parent = find_type_in_module(
				&result.registry, &program.module_key, type_decl.supertype.name
			);
			TypeDescriptor* parent_descriptor = type_descriptor(&result.registry, parent);
			if (!parent_descriptor)
			{
				types_add_diagnostic(&diagnostics, allocator, "unknown nominal supertype", type_decl.supertype.span);
			}
			else if (parent_descriptor.kind != TYPE_DESCRIPTOR_ABSTRACT)
			{
				types_add_diagnostic(&diagnostics, allocator, "concrete types are final and cannot be nominal supertypes", type_decl.supertype.span);
			}
			else if (parent_descriptor.arity
				&& type_decl.supertype.kind == TYPE_EXPR_NAMED)
			{
				types_add_diagnostic(
					&diagnostics, allocator,
					"parametric nominal supertype requires its declared 'of' arguments",
					type_decl.supertype.span
				);
			}
			else if (type_decl.supertype.arguments.len != parent_descriptor.arity)
			{
				types_add_diagnostic(&diagnostics, allocator, "nominal supertype application has the wrong arity", type_decl.supertype.span);
			}
			else if (parent_descriptor.arity
				&& !nominal_parent_forwards_parameters(
					type_decl.supertype, type_decl.parameters
				))
			{
				types_add_diagnostic(
					&diagnostics, allocator,
					"parametric nominal supertype arguments must forward child parameters in positional order",
					type_decl.supertype.span
				);
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
	derive_completed_type_layouts(&result.registry, &diagnostics, allocator);
	validate_nominal_hierarchy(&result.registry, &diagnostics, allocator);
	if (!type_registry_layouts_are_valid(&result.registry))
	{
		MitosPosition origin = { .row = 1, .column = 1 };
		types_add_diagnostic(
			&diagnostics, allocator, "type registry contains an invalid persistent layout",
			{ .start = origin, .end = origin }
		);
	}
	result.diagnostics = diagnostics.to_array(allocator);
	diagnostics.free();
	return result;
}
