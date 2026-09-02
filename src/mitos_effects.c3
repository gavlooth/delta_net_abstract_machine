module delta_net_abstract_machine::mitos;

import std::collections::list;
import std::core::mem;
import std::io;
import std::thread;
import std::atomic::types;

/** Stable identities are local to one program-lifetime EffectRegistry. */
typedef EffectId = uint;
typedef OperationId = uint;

const EffectId EFFECT_ID_INVALID = (EffectId)0;
const OperationId OPERATION_ID_INVALID = (OperationId)0;
const usz MITOS_MAX_EFFECTS = 4_096;
const usz MITOS_MAX_EFFECT_INSTANCES = 16_384;
const usz MITOS_MAX_EFFECT_INFERENCE_STEPS = 4_194_304;
const usz MITOS_MAX_EFFECT_INDEX_PROBES = 128;

/**
 * Canonical allocator-owned resolved row. `required` is sorted, unique, and
 * excludes EFFECT_ID_INVALID. When present, `tail` is a canonical
 * SYMBOL_EFFECT_ROW_TAIL key.
 */
struct ResolvedEffectRow
{
	EffectId[] required;
	bool has_tail;
	SymbolKey tail;
}

fn void effect_row_sift_down(EffectId[] values, usz root, usz count) @private
{
	for (;;)
	{
		usz child = root * 2 + 1;
		if (child >= count) return;
		if (child + 1 < count && values[child] < values[child + 1]) child++;
		if (values[root] >= values[child]) return;
		EffectId swap = values[root];
		values[root] = values[child];
		values[child] = swap;
		root = child;
	}
}

fn void sort_effect_ids(EffectId[] values) @private
{
	usz count = values.len;
	if (count < 2) return;
	for (usz parent = count / 2; parent > 0; parent--)
	{
		effect_row_sift_down(values, parent - 1, count);
	}
	for (usz end = count; end > 1; end--)
	{
		EffectId swap = values[0];
		values[0] = values[end - 1];
		values[end - 1] = swap;
		effect_row_sift_down(values, 0, end - 1);
	}
}

fn ResolvedEffectRow normalize_effect_row(
	EffectId[] required,
	SymbolKey* optional_tail = null,
	Allocator allocator = mem
)
{
	EffectId[] owned = alloc::new_array(allocator, EffectId, required.len);
	usz count = 0;
	foreach (effect : required)
	{
		if (effect == EFFECT_ID_INVALID) continue;
		owned[count++] = effect;
	}
	sort_effect_ids(owned[:(sz)count]);
	usz unique = 0;
	for (usz index = 0; index < count; index++)
	{
		if (unique && owned[index] == owned[unique - 1]) continue;
		owned[unique++] = owned[index];
	}
	ResolvedEffectRow row = { .required = owned[:(sz)unique] };
	if (optional_tail)
	{
		row.has_tail = true;
		row.tail = clone_symbol_key(optional_tail, allocator);
	}
	return row;
}

fn ResolvedEffectRow clone_resolved_effect_row(
	ResolvedEffectRow* row,
	Allocator allocator = mem
)
{
	if (!row) return { };
	ResolvedEffectRow clone = {
		.required = alloc::clone_slice(allocator, row.required),
		.has_tail = row.has_tail,
	};
	if (row.has_tail) clone.tail = clone_symbol_key(&row.tail, allocator);
	return clone;
}

fn void ResolvedEffectRow.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.required);
	if (self.has_tail) self.tail.deinit(allocator);
	*self = { };
}

fn bool resolved_effect_row_equal(ResolvedEffectRow* left, ResolvedEffectRow* right)
{
	if (left == right) return true;
	if (!left || !right || left.required.len != right.required.len
		|| left.has_tail != right.has_tail) return false;
	foreach (index, effect : left.required)
		if (effect != right.required[index]) return false;
	return !left.has_tail || symbol_key_equal(&left.tail, &right.tail);
}

fn bool resolved_effect_row_contains(ResolvedEffectRow* row, EffectId effect)
{
	if (!row || effect == EFFECT_ID_INVALID) return false;
	foreach (required : row.required)
	{
		if (required == effect) return true;
		if (required > effect) return false;
	}
	return false;
}

fn bool resolved_effect_row_is_canonical(ResolvedEffectRow* row)
{
	if (!row || (row.has_tail
		&& (row.tail.kind != SYMBOL_EFFECT_ROW_TAIL
			|| !symbol_key_is_canonical(&row.tail)))) return false;
	EffectId previous = EFFECT_ID_INVALID;
	foreach (effect : row.required)
	{
		if (effect == EFFECT_ID_INVALID || effect <= previous) return false;
		previous = effect;
	}
	return true;
}

/** True when `actual` is within the capability upper bound `expected`. */
fn bool resolved_effect_row_satisfies(
	ResolvedEffectRow* actual,
	ResolvedEffectRow* expected
)
{
	if (!actual || !expected
		|| !resolved_effect_row_is_canonical(actual)
		|| !resolved_effect_row_is_canonical(expected)) return false;
	if (actual.has_tail && !expected.has_tail) return false;
	if (actual.has_tail && expected.has_tail
		&& !symbol_key_equal(&actual.tail, &expected.tail)) return false;
	if (expected.has_tail && !actual.has_tail) return true;
	usz expected_index = 0;
	foreach (effect : actual.required)
	{
		while (expected_index < (usz)expected.required.len
			&& expected.required[(sz)expected_index] < effect) expected_index++;
		if (expected_index >= (usz)expected.required.len
			|| expected.required[(sz)expected_index] != effect) return false;
	}
	return true;
}

/** An open tail conservatively admits a request not yet named in `required`. */
fn bool resolved_effect_row_allows(
	ResolvedEffectRow* row,
	EffectId effect
)
{
	return row && (resolved_effect_row_contains(row, effect) || row.has_tail);
}


enum EffectHostPolicy : char
{
	EFFECT_HOST_PURE,
	EFFECT_HOST_ORDERED,
	EFFECT_HOST_EXTERNAL,
}


struct EffectOperationDescriptor
{
	SymbolKey key;
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
	SymbolKey key;
	EffectId id;
	String name;
	bool multi;
	String[] parameters;
	EffectOperationDescriptor[] operations;
	MitosSpan span;
}

struct EffectInstance
{
	SymbolKey key;
	EffectId id;
	EffectId constructor;
	TypeId[] arguments;
}

struct EffectRegistryIndexes @private
{
	/** Open-addressed module-local effect-name index; entries are descriptor index + 1. */
	usz[] effect_buckets;
	/** Open-addressed `(constructor, TypeId[])` index; entries are instance index + 1. */
	usz[] instance_buckets;
	/** Sole instance ID per constructor, or `uint::max` when multiple exist. */
	EffectId[] constructor_instances;
}

/**
 * Non-dereferenceable cache capability. Backing addresses remain in the
 * module-owned slot table and every use revalidates all three coordinates.
 */
struct EffectRegistryIndexHandle
{
	usz slot;
	ulong generation;
	ulong identity;
}

struct EffectRegistryIndexSlot @private
{
	EffectRegistryIndexes indexes;
	Allocator allocator;
	char* owner_key;
	usz owner_key_len;
	ulong owner_identity;
	ulong generation;
	ulong identity;
	bool active;
}

const usz MITOS_MAX_EFFECT_INDEX_STATES = 4_096;
Atomic{ulong} effect_registry_index_guard @private;
EffectRegistryIndexSlot[MITOS_MAX_EFFECT_INDEX_STATES] effect_registry_index_slots @private;

struct EffectRegistry
{
	ModuleKey module_key;
	Allocator allocator;
	List{EffectDescriptor} effects;
	List{EffectInstance} instances;
	/** Validated runtime-only cache handle; descriptors remain public registry data. */
	EffectRegistryIndexHandle index_state;
	OperationId next_operation_id;
	ulong index_owner;
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
	ResolvedEffectRow inferred;
	ResolvedEffectRow asserted;
	bool has_assertion;
}


struct LambdaEffectInfo
{
	MitosSpan span;
	ResolvedEffectRow inferred;
	ResolvedEffectRow asserted;
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


fn bool EffectRegistryBuildResult.ok(&self) => self.diagnostics.len == 0;
fn bool EffectAnalysis.ok(&self) => self.diagnostics.len == 0;

fn void EffectOperationDescriptor.deinit(&self, Allocator allocator)
{
	self.key.deinit(allocator);
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
	effect_registry_clear_indexes(self);
	self.module_key.deinit(self.allocator);
	foreach (&effect : self.effects)
	{
		effect.key.deinit(self.allocator);
		alloc::free(self.allocator, effect.name);
		foreach (parameter : effect.parameters) alloc::free(self.allocator, parameter);
		alloc::free(self.allocator, effect.parameters);
		foreach (&operation : effect.operations) operation.deinit(self.allocator);
		alloc::free(self.allocator, effect.operations);
	}
	foreach (&instance : self.instances)
	{
		instance.key.deinit(self.allocator);
		alloc::free(self.allocator, instance.arguments);
	}
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
		method.inferred.deinit(self.allocator);
		method.asserted.deinit(self.allocator);
	}
	alloc::free(self.allocator, self.methods);
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	foreach (&lambda : self.lambdas)
	{
		lambda.inferred.deinit(self.allocator);
		lambda.asserted.deinit(self.allocator);
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

fn void effect_registry_index_lock() @private
{
	for (;;)
	{
		ulong expected = 0;
		if (effect_registry_index_guard.compare_exchange(&expected, 1)) return;
		thread::yield();
	}
}

fn void effect_registry_index_unlock() @private
{
	effect_registry_index_guard.store(0);
}

fn bool effect_registry_index_handle_is_set(EffectRegistryIndexHandle handle) @private
{
	return handle.slot != 0 || handle.generation != 0 || handle.identity != 0;
}

fn void effect_registry_free_index_arrays(
	EffectRegistryIndexes* indexes,
	Allocator allocator
) @private
{
	alloc::free(allocator, indexes.effect_buckets);
	alloc::free(allocator, indexes.instance_buckets);
	alloc::free(allocator, indexes.constructor_instances);
	*indexes = { };
}

fn bool effect_registry_slot_is_owned_by(
	EffectRegistryIndexSlot* slot,
	EffectRegistry* registry
) @private
{
	return slot.active && registry.index_owner
		&& slot.owner_identity == registry.index_owner
		&& slot.owner_key == registry.module_key.canonical.ptr
		&& slot.owner_key_len == registry.module_key.canonical.len;
}

fn EffectRegistryIndexes* effect_registry_indexes(EffectRegistry* registry) @private
{
	if (!registry || registry.max_effects > MITOS_MAX_EFFECTS
		|| registry.max_instances > MITOS_MAX_EFFECT_INSTANCES
		|| (usz)registry.effects.len() > registry.max_effects
		|| (usz)registry.instances.len() > registry.max_instances)
	{
		return null;
	}
	EffectRegistryIndexHandle handle = registry.index_state;
	if (!handle.slot || handle.slot > MITOS_MAX_EFFECT_INDEX_STATES
		|| !handle.generation || !handle.identity) return null;

	effect_registry_index_lock();
	EffectRegistryIndexSlot* slot = &effect_registry_index_slots[handle.slot - 1];
	if (!slot.active || slot.generation != handle.generation
		|| slot.identity != handle.identity
		|| !effect_registry_slot_is_owned_by(slot, registry))
	{
		effect_registry_index_unlock();
		return null;
	}
	EffectRegistryIndexes* indexes = &slot.indexes;
	if (indexes.effect_buckets.len != registry.max_effects * 2 + 1
		|| indexes.instance_buckets.len != registry.max_instances * 2 + 1
		|| indexes.constructor_instances.len != registry.max_effects + 1)
	{
		effect_registry_index_unlock();
		return null;
	}
	effect_registry_index_unlock();
	return indexes;
}

fn bool effect_registry_register_indexes(
	EffectRegistry* registry,
	EffectRegistryIndexes indexes
) @private
{
	if (!registry.index_owner)
	{
		registry.index_owner = new_runtime_identity();
		if (!registry.index_owner) return false;
	}
	ulong identity = new_runtime_identity();
	if (!identity) return false;
	effect_registry_index_lock();
	for (usz index = 0; index < MITOS_MAX_EFFECT_INDEX_STATES; index++)
	{
		EffectRegistryIndexSlot* slot = &effect_registry_index_slots[index];
		if (slot.active) continue;
		ulong generation = slot.generation == ulong::max ? 1 : slot.generation + 1;
		*slot = {
			.indexes = indexes,
			.allocator = registry.allocator,
			.owner_key = registry.module_key.canonical.ptr,
			.owner_key_len = registry.module_key.canonical.len,
			.owner_identity = registry.index_owner,
			.generation = generation,
			.identity = identity,
			.active = true,
		};
		registry.index_state = {
			.slot = index + 1,
			.generation = generation,
			.identity = identity,
		};
		effect_registry_index_unlock();
		return true;
	}
	effect_registry_index_unlock();
	return false;
}

fn void effect_registry_clear_indexes(EffectRegistry* registry) @private
{
	if (!registry) return;
	EffectRegistryIndexHandle handle = registry.index_state;
	registry.index_state = { };

	EffectRegistryIndexes released;
	Allocator allocator;
	bool found = false;
	effect_registry_index_lock();
	EffectRegistryIndexSlot* selected = null;
	if (handle.slot && handle.slot <= MITOS_MAX_EFFECT_INDEX_STATES
		&& handle.generation && handle.identity)
	{
		EffectRegistryIndexSlot* candidate =
			&effect_registry_index_slots[handle.slot - 1];
		if (candidate.generation == handle.generation
			&& candidate.identity == handle.identity
			&& effect_registry_slot_is_owned_by(candidate, registry))
		{
			selected = candidate;
		}
	}
	if (!selected)
	{
		foreach (&candidate : effect_registry_index_slots)
		{
			if (effect_registry_slot_is_owned_by(candidate, registry))
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
	effect_registry_index_unlock();
	if (found) effect_registry_free_index_arrays(&released, allocator);
}

fn ulong effect_registry_name_hash(String name) @private
{
	ulong hash = 1469598103934665603UL;
	foreach (character : name)
	{
		hash ^= (ulong)character;
		hash *= 1099511628211UL;
	}
	return hash;
}

fn ulong effect_registry_instance_hash(
	EffectId constructor,
	TypeId[] arguments
) @private
{
	ulong hash = 1469598103934665603UL;
	hash ^= (ulong)constructor;
	hash *= 1099511628211UL;
	foreach (argument : arguments)
	{
		hash ^= (ulong)argument;
		hash *= 1099511628211UL;
	}
	return hash;
}

fn bool effect_registry_index_effect(
	EffectRegistry* registry,
	EffectRegistryIndexes* indexes,
	EffectDescriptor* effect
) @private
{
	if (!effect || !effect.id || (usz)effect.id > (usz)registry.effects.len())
	{
		return false;
	}
	usz bucket_count = indexes.effect_buckets.len;
	usz bucket = (usz)(effect_registry_name_hash(effect.name) % (ulong)bucket_count);
	usz probe_limit = bucket_count < MITOS_MAX_EFFECT_INDEX_PROBES
		? bucket_count : MITOS_MAX_EFFECT_INDEX_PROBES;
	for (usz probe = 0; probe < probe_limit; probe++)
	{
		usz stored = indexes.effect_buckets[bucket];
		if (!stored)
		{
			indexes.effect_buckets[bucket] = (usz)effect.id;
			return true;
		}
		if (stored > (usz)registry.effects.len()) return false;
		EffectDescriptor* other = &registry.effects[(sz)(stored - 1)];
		if (other.id != (EffectId)stored || other.name == effect.name) return false;
		bucket++;
		if (bucket == bucket_count) bucket = 0;
	}
	return false;
}

fn bool effect_registry_index_instance(
	EffectRegistry* registry,
	EffectRegistryIndexes* indexes,
	EffectInstance* instance,
	usz ordinal
) @private
{
	if (!instance || !instance.constructor
		|| (usz)instance.constructor > (usz)registry.effects.len()
		|| instance.id != (EffectId)((usz)registry.effects.len() + ordinal + 1))
	{
		return false;
	}
	usz bucket_count = indexes.instance_buckets.len;
	usz bucket = (usz)(effect_registry_instance_hash(
		instance.constructor, instance.arguments
	) % (ulong)bucket_count);
	usz probe_limit = bucket_count < MITOS_MAX_EFFECT_INDEX_PROBES
		? bucket_count : MITOS_MAX_EFFECT_INDEX_PROBES;
	for (usz probe = 0; probe < probe_limit; probe++)
	{
		usz stored = indexes.instance_buckets[bucket];
		if (!stored)
		{
			indexes.instance_buckets[bucket] = ordinal + 1;
			EffectId previous = indexes.constructor_instances[(usz)instance.constructor];
			indexes.constructor_instances[(usz)instance.constructor] = previous
				? (EffectId)uint::max : instance.id;
			return true;
		}
		if (stored > (usz)registry.instances.len()) return false;
		EffectInstance* other = &registry.instances[(sz)(stored - 1)];
		if (other.id != (EffectId)((usz)registry.effects.len() + stored))
		{
			return false;
		}
		if (other.constructor == instance.constructor
			&& type_arguments_equal(other.arguments, instance.arguments)) return false;
		bucket++;
		if (bucket == bucket_count) bucket = 0;
	}
	return false;
}

fn bool effect_registry_prepare_indexes(EffectRegistry* registry) @private
{
	if (!registry || registry.max_effects > MITOS_MAX_EFFECTS
		|| registry.max_instances > MITOS_MAX_EFFECT_INSTANCES
		|| (usz)registry.effects.len() > registry.max_effects
		|| (usz)registry.instances.len() > registry.max_instances) return false;
	if (effect_registry_indexes(registry)) return true;
	if (effect_registry_index_handle_is_set(registry.index_state))
	{
		effect_registry_clear_indexes(registry);
	}
	EffectRegistryIndexes allocated = {
		.effect_buckets = alloc::new_array(
			registry.allocator, usz, (sz)(registry.max_effects * 2 + 1)
		),
		.instance_buckets = alloc::new_array(
			registry.allocator, usz, (sz)(registry.max_instances * 2 + 1)
		),
		.constructor_instances = alloc::new_array(
			registry.allocator, EffectId, (sz)(registry.max_effects + 1)
		),
	};
	foreach (&bucket : allocated.effect_buckets) *bucket = 0;
	foreach (&bucket : allocated.instance_buckets) *bucket = 0;
	foreach (&instance : allocated.constructor_instances) *instance = EFFECT_ID_INVALID;
	if (!effect_registry_register_indexes(registry, allocated))
	{
		effect_registry_free_index_arrays(&allocated, registry.allocator);
		return false;
	}
	EffectRegistryIndexes* indexes = effect_registry_indexes(registry);
	foreach (index, &effect : registry.effects)
	{
		if (effect.id != (EffectId)((usz)index + 1)
			|| !effect_registry_index_effect(registry, indexes, effect))
		{
			effect_registry_clear_indexes(registry);
			return false;
		}
	}
	foreach (index, &instance : registry.instances)
	{
		if (!effect_registry_index_instance(registry, indexes, instance, (usz)index))
		{
			effect_registry_clear_indexes(registry);
			return false;
		}
	}
	return true;
}

fn EffectId effect_index_lookup(
	EffectRegistry* registry,
	ModuleKey* owner,
	String name,
	usz* insertion_bucket = null
) @private
{
	if (insertion_bucket) *insertion_bucket = usz::max;
	if (!registry || !owner || !effect_registry_prepare_indexes(registry))
	{
		return EFFECT_ID_INVALID;
	}
	EffectRegistryIndexes* indexes = effect_registry_indexes(registry);
	if (!indexes) return EFFECT_ID_INVALID;
	usz bucket_count = indexes.effect_buckets.len;
	if (insertion_bucket) *insertion_bucket = bucket_count;
	if (!module_key_equal(&registry.module_key, owner)) return EFFECT_ID_INVALID;
	usz bucket = (usz)(effect_registry_name_hash(name) % (ulong)bucket_count);
	usz probe_limit = bucket_count < MITOS_MAX_EFFECT_INDEX_PROBES
		? bucket_count : MITOS_MAX_EFFECT_INDEX_PROBES;
	for (usz probe = 0; probe < probe_limit; probe++)
	{
		usz stored = indexes.effect_buckets[bucket];
		if (!stored)
		{
			if (insertion_bucket) *insertion_bucket = bucket;
			return EFFECT_ID_INVALID;
		}
		if (stored > (usz)registry.effects.len()) return EFFECT_ID_INVALID;
		EffectDescriptor* effect = &registry.effects[(sz)(stored - 1)];
		if (effect.id != (EffectId)stored) return EFFECT_ID_INVALID;
		if (effect.name == name) return effect.id;
		bucket++;
		if (bucket == bucket_count) bucket = 0;
	}
	return EFFECT_ID_INVALID;
}



fn EffectId find_effect(EffectRegistry* registry, String name)
{
	if (!registry) return EFFECT_ID_INVALID;
	return effect_index_lookup(registry, &registry.module_key, name);
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



fn String effect_instance_signature(
	TypeRegistry* types,
	TypeId[] arguments,
	Allocator allocator
) @private
{
	DString output;
	output.init(allocator);
	foreach (argument : arguments)
	{
		TypeDescriptor* type = type_descriptor(types, argument);
		append_length_prefixed_component(&output, type.key.owner.canonical);
		append_length_prefixed_component(&output, type.key.name);
		append_length_prefixed_component(&output, type.key.canonical_signature);
	}
	String result = output.copy_str(allocator);
	output.free();
	return result;
}


/** Byte-identical to the parser's canonical full-parent identity encoding. */
fn String effect_parent_identity_signature(
	SymbolKey* parent,
	Allocator allocator
) @private
{
	DString signature;
	signature.init(allocator);
	char[32] buffer;
	append_length_prefixed_component(&signature, parent.owner.canonical);
	signature.append_char('/');
	signature.append_string((String)io::bprintf(
		&buffer, "%d/", (long)parent.kind
	)!!);
	append_length_prefixed_component(&signature, parent.name);
	signature.append_char('/');
	signature.append_string((String)io::bprintf(
		&buffer, "%d/", (long)parent.arity
	)!!);
	append_length_prefixed_component(&signature, parent.canonical_signature);
	String result = signature.copy_str(allocator);
	signature.free();
	return result;
}


fn EffectRegistryBuildResult build_effect_registry(
	Program* program,
	TypeRegistry* types,
	Allocator allocator = mem,
	usz max_effects = MITOS_MAX_EFFECTS,
	usz max_instances = MITOS_MAX_EFFECT_INSTANCES
)
{
	if (max_effects > MITOS_MAX_EFFECTS) max_effects = MITOS_MAX_EFFECTS;
	if (max_instances > MITOS_MAX_EFFECT_INSTANCES) max_instances = MITOS_MAX_EFFECT_INSTANCES;
	EffectRegistryBuildResult result = { .allocator = allocator };
	result.registry = {
		.allocator = allocator,
		.max_effects = max_effects,
		.module_key = clone_module_key(&program.module_key, allocator),
		.max_instances = max_instances,
		.next_operation_id = (OperationId)1,
		.epoch = 1,
	};
	result.registry.effects.init(allocator);
	result.registry.instances.init(allocator);
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);
	if (!effect_registry_prepare_indexes(&result.registry))
	{
		effects_add_diagnostic(
			&diagnostics, allocator,
			"effect registry index slots are exhausted", { }
		);
		result.diagnostics = diagnostics.to_array(allocator);
		diagnostics.free();
		return result;
	}
	EffectRegistryIndexes* indexes = effect_registry_indexes(&result.registry);
	foreach (&declaration : program.effects)
	{
		if (!symbol_key_matches_declaration(
			&declaration.key, &program.module_key, SYMBOL_EFFECT,
			declaration.name, declaration.parameters.len, ""
		))
		{
			effects_add_diagnostic(
				&diagnostics, allocator,
				"effect declaration has an invalid canonical identity", declaration.span
			);
			continue;
		}
		if ((usz)result.registry.effects.len() >= max_effects)
		{
			effects_add_diagnostic(&diagnostics, allocator, "effect registry exhausted its bounded capacity", declaration.span);
			break;
		}
		usz effect_bucket;
		if (effect_index_lookup(
			&result.registry, &program.module_key, declaration.name, &effect_bucket
		))
		{
			effects_add_diagnostic(&diagnostics, allocator, "duplicate effect declaration", declaration.span);
			continue;
		}
		if (effect_bucket >= indexes.effect_buckets.len)
		{
			effects_add_diagnostic(
				&diagnostics, allocator,
				"effect registry index exceeded its bounded collision budget", declaration.span
			);
			continue;
		}
		EffectDescriptor descriptor = {
			.key = clone_symbol_key(&declaration.key, allocator),
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
			String parent_signature = effect_parent_identity_signature(
				&descriptor.key, allocator
			);
			if (!symbol_key_matches_declaration(
				&operation.key, &descriptor.key.owner, SYMBOL_EFFECT_OPERATION,
				operation.name, operation.parameters.len, parent_signature
			))
			{
				alloc::free(allocator, parent_signature);
				effects_add_diagnostic(
					&diagnostics, allocator,
					"effect operation has an invalid canonical identity", operation.span
				);
				continue;
			}
			EffectHostPolicy host_policy = declaration.name == "Console" || declaration.name == "IO"
				? EFFECT_HOST_EXTERNAL
				: declaration.name == "State" ? EFFECT_HOST_ORDERED : EFFECT_HOST_PURE;
			EffectOperationDescriptor registered = {
				.key = clone_symbol_key(&operation.key, allocator),
				.id = result.registry.next_operation_id++,
				.effect = descriptor.id,
				.name = operation.name.copy(allocator),
				.host_policy = host_policy,
				.ordered = host_policy != EFFECT_HOST_PURE,
			};
			alloc::free(allocator, parent_signature);
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
		indexes.effect_buckets[effect_bucket] = (usz)result.registry.effects.len();
	}
	result.diagnostics = diagnostics.to_array(allocator);
	diagnostics.free();
	return result;
}


fn bool intern_effect(
	EffectRegistry* registry,
	TypeRegistry* types,
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
	foreach (argument : arguments)
	{
		if (!type_id_is_valid(types, argument))
		{
			if (diagnostic) diagnostic.init(
				registry.allocator, "parametric effect contains an invalid TypeId", span
			);
			return false;
		}
	}
	ulong instance_hash = effect_registry_instance_hash(constructor, arguments);
	if (!effect_registry_prepare_indexes(registry))
	{
		if (diagnostic) diagnostic.init(
			registry.allocator, "effect registry index state is invalid", span
		);
		return false;
	}
	EffectRegistryIndexes* indexes = effect_registry_indexes(registry);
	if (!indexes)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "effect registry index state is invalid", span);
		return false;
	}
	usz bucket_count = indexes.instance_buckets.len;
	usz bucket = (usz)(instance_hash % (ulong)bucket_count);
	usz insertion_bucket = 0;
	bool has_insertion_bucket = false;
	usz probe_limit = bucket_count < MITOS_MAX_EFFECT_INDEX_PROBES
		? bucket_count : MITOS_MAX_EFFECT_INDEX_PROBES;
	for (usz probe = 0; probe < probe_limit; probe++)
	{
		usz stored = indexes.instance_buckets[bucket];
		if (!stored)
		{
			insertion_bucket = bucket;
			has_insertion_bucket = true;
			break;
		}
		if (stored > (usz)registry.instances.len())
		{
			if (diagnostic) diagnostic.init(registry.allocator, "effect registry index state is invalid", span);
			return false;
		}
		EffectInstance* instance = &registry.instances[(sz)(stored - 1)];
		EffectId expected_id = (EffectId)((usz)registry.effects.len() + stored);
		if (instance.id != expected_id)
		{
			if (diagnostic) diagnostic.init(registry.allocator, "effect registry index state is invalid", span);
			return false;
		}
		if (instance.constructor == constructor && instance.arguments.len == arguments.len)
		{
			bool equal = true;
			foreach (index, argument : arguments)
			{
				if (instance.arguments[index] != argument)
				{
					equal = false;
					break;
				}
			}
			if (equal)
			{
				*result = instance.id;
				return true;
			}
		}
		bucket++;
		if (bucket == bucket_count) bucket = 0;
	}
	if ((usz)registry.instances.len() >= registry.max_instances)
	{
		if (diagnostic) diagnostic.init(registry.allocator, "effect instance registry exhausted its bounded capacity", span);
		return false;
	}
	if (!has_insertion_bucket)
	{
		if (diagnostic) diagnostic.init(
			registry.allocator, "effect instance index exceeded its bounded collision budget", span
		);
		return false;
	}
	EffectId id = (EffectId)((usz)registry.effects.len() + (usz)registry.instances.len() + 1);
	String signature = effect_instance_signature(types, arguments, registry.allocator);
	SymbolKey key = symbol_key(
		&descriptor.key.owner, SYMBOL_EFFECT, descriptor.name, arguments.len,
		signature, registry.allocator
	);
	alloc::free(registry.allocator, signature);
	registry.instances.push({
		.key = key,
		.id = id,
		.constructor = constructor,
		.arguments = alloc::clone_slice(registry.allocator, arguments),
	});
	indexes.instance_buckets[insertion_bucket] = (usz)registry.instances.len();
	EffectId previous_instance = indexes.constructor_instances[(usz)constructor];
	indexes.constructor_instances[(usz)constructor] = previous_instance
		? (EffectId)uint::max : id;
	registry.epoch++;
	*result = id;
	return true;
}

fn EffectInstance* effect_instance(EffectRegistry* registry, EffectId id)
{
	if (!registry) return null;
	usz first_instance = (usz)registry.effects.len() + 1;
	if ((usz)id < first_instance) return null;
	usz index = (usz)id - first_instance;
	if (index >= (usz)registry.instances.len()) return null;
	EffectInstance* instance = &registry.instances[(sz)index];
	return instance.id == id ? instance : null;
}

fn SymbolKey* effect_symbol_key(EffectRegistry* registry, EffectId id)
{
	EffectDescriptor* descriptor = effect_descriptor(registry, id);
	if (descriptor) return &descriptor.key;
	EffectInstance* instance = effect_instance(registry, id);
	return instance ? &instance.key : null;
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
		if (!effect_registry_prepare_indexes(registry))
		{
			if (diagnostic) diagnostic.init(registry.allocator, "effect registry index state is invalid", span);
			return false;
		}
		EffectRegistryIndexes* indexes = effect_registry_indexes(registry);
		if (!indexes)
		{
			if (diagnostic) diagnostic.init(registry.allocator, "effect registry index state is invalid", span);
			return false;
		}
		selected = indexes.constructor_instances[(usz)constructor];
		if (selected == (EffectId)uint::max)
		{
			if (diagnostic) diagnostic.init(
				registry.allocator,
				"effect occurrence requires an explicit concrete effect row", span
			);
			return false;
		}
		if (selected)
		{
			EffectInstance* cached = effect_instance(registry, selected);
			if (!cached || cached.constructor != constructor)
			{
				if (diagnostic) diagnostic.init(registry.allocator, "effect registry index state is invalid", span);
				return false;
			}
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
	return intern_effect(registry, types, constructor, arguments, result, diagnostic, expression.span);
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
	SymbolKey* key;
	List{usz} targets;
}

struct EffectCallIndex
{
	Allocator allocator;
	ModuleKey* caller_module;
	List{EffectCallGroup} groups;
	sz[] buckets;
	Program* program;
}

struct EffectLexicalScope
{
	EffectLexicalScope* parent;
	String[] names;
	SurfaceExpr*[] closures;
	EffectLexicalScope*[] closure_scopes;
	ParallelBinding[] parallel_bindings;
	SurfaceExpr*[] values;
	EffectLexicalScope*[] value_scopes;
	EffectLexicalScope* value_default_scope;
	SurfaceExpr* pattern_scrutinee;
	String pattern_constructor;
	EffectLexicalScope* pattern_scope;
	EffectCallIndex* calls;
	usz function_index_plus_one;
	String handler_effect_name;
	String handler_operation_name;
}

struct EffectInferenceWork
{
	Allocator allocator;
	List{EffectLexicalScope*} scopes;
	usz used;
	usz max;
	bool exhausted;
}

fn EffectCallIndex* effect_scope_call_index(
	EffectLexicalScope* scope,
	EffectInferenceWork* work
) @private
{
	for (EffectLexicalScope* current = scope; current; current = current.parent)
	{
		if (!effect_charge(work)) return null;
		if (current.calls) return current.calls;
	}
	return null;
}


fn bool effect_lexical_lookup(
	EffectLexicalScope* scope,
	String name,
	EffectInferenceWork* work,
	SurfaceExpr** closure = null,
	EffectLexicalScope** closure_scope = null,
	SurfaceExpr** value = null,
	EffectLexicalScope** value_scope = null,
	bool* unresolved_producer = null
) @private
{
	for (EffectLexicalScope* current = scope; current; current = current.parent)
	{
		if (!effect_charge(work)) return false;
		foreach (index, candidate : current.names)
		{
			if (!effect_charge(work)) return false;
			if (candidate != name) continue;
			SurfaceExpr* resolved_value = index < current.values.len
				? current.values[index] : null;
			EffectLexicalScope* resolved_value_scope =
				index < current.value_scopes.len
					? current.value_scopes[index] : current.value_default_scope;
			if (!resolved_value && current.pattern_scrutinee)
			{
				EffectCallIndex* calls = effect_scope_call_index(
					current.pattern_scope, work
				);
				if (calls)
				{
					(void)effect_resolve_pattern_value(
						calls, current.pattern_scrutinee, current.pattern_scope,
						current.pattern_constructor, (usz)index, &resolved_value,
						&resolved_value_scope, work, 0
					);
				}
			}
			if (closure)
			{
				*closure = index < current.closures.len ? current.closures[index] : null;
			}
			if (closure_scope)
			{
				*closure_scope = index < current.closure_scopes.len
					? current.closure_scopes[index] : resolved_value_scope;
			}
			if (value) *value = resolved_value;
			if (value_scope) *value_scope = resolved_value_scope;
			if (unresolved_producer)
			{
				*unresolved_producer = current.pattern_scrutinee && !resolved_value;
			}
			return true;
		}
		foreach (&binding : current.parallel_bindings)
		{
			if (!effect_charge(work)) return false;
			if (binding.name != name) continue;
			SurfaceExpr* resolved_closure = null;
			EffectLexicalScope* resolved_scope = current.parent;
			if (binding.value && binding.value.kind == SURFACE_LAMBDA)
			{
				resolved_closure = binding.value;
			}
			else if (binding.value && binding.value.kind == SURFACE_VARIABLE)
			{
				(void)effect_lexical_lookup(
					current.parent, binding.value.data.variable.name, work,
					&resolved_closure, &resolved_scope
				);
			}
			if (closure) *closure = resolved_closure;
			if (closure_scope) *closure_scope = resolved_scope;
			if (value) *value = binding.value;
			if (value_scope) *value_scope = current.parent;
			if (unresolved_producer) *unresolved_producer = false;
			return true;
		}
	}
	return false;
}

fn bool effect_lexical_origin(
	EffectLexicalScope* scope,
	String name,
	EffectInferenceWork* work,
	usz* function_index,
	usz* parameter_index,
	String* effect_name,
	String* operation_name
) @private
{
	for (EffectLexicalScope* current = scope; current; current = current.parent)
	{
		if (!effect_charge(work)) return false;
		foreach (index, candidate : current.names)
		{
			if (!effect_charge(work)) return false;
			if (candidate != name) continue;
			if (current.function_index_plus_one)
			{
				*function_index = current.function_index_plus_one - 1;
				*parameter_index = (usz)index;
				return true;
			}
			if (current.handler_effect_name.len && current.handler_operation_name.len)
			{
				*parameter_index = (usz)index;
				*effect_name = current.handler_effect_name;
				*operation_name = current.handler_operation_name;
				return true;
			}
			return false;
		}
		foreach (&binding : current.parallel_bindings)
		{
			if (!effect_charge(work)) return false;
			if (binding.name == name) return false;
		}
	}
	return false;
}

fn bool effect_lexical_is_bound(
	EffectLexicalScope* scope,
	String name,
	EffectInferenceWork* work
) @private
{
	for (EffectLexicalScope* current = scope; current; current = current.parent)
	{
		if (!effect_charge(work)) return false;
		foreach (candidate : current.names)
		{
			if (!effect_charge(work)) return false;
			if (candidate == name) return true;
		}
		foreach (&binding : current.parallel_bindings)
		{
			if (!effect_charge(work)) return false;
			if (binding.name == name) return true;
		}
	}
	return false;
}


fn void effect_follow_callable_alias(
	SurfaceExpr** callable,
	EffectLexicalScope** callable_scope,
	bool* lexical,
	String* callable_name,
	EffectInferenceWork* work,
	usz depth
) @private
{
	for (usz step = depth; *lexical && *callable
		&& (*callable).kind == SURFACE_VARIABLE
		&& step < MITOS_MAX_TYPE_FORMAT_DEPTH; step++)
	{
		String candidate_name = (*callable).data.variable.name;
		SurfaceExpr* nested_closure = null;
		EffectLexicalScope* nested_closure_scope = *callable_scope;
		SurfaceExpr* nested_value = null;
		EffectLexicalScope* nested_value_scope = *callable_scope;
		if (!effect_lexical_lookup(
			*callable_scope, candidate_name, work,
			&nested_closure, &nested_closure_scope,
			&nested_value, &nested_value_scope
		))
		{
			if (!work.exhausted)
			{
				*callable_name = candidate_name;
				*callable = null;
				*lexical = false;
			}
			return;
		}
		SurfaceExpr* next = nested_closure ? nested_closure : nested_value;
		EffectLexicalScope* next_scope = nested_closure
			? nested_closure_scope : nested_value_scope;
		if (!next
			|| (next == *callable && next_scope == *callable_scope)) return;
		*callable = next;
		*callable_scope = next_scope;
	}
}

fn ulong effect_call_hash(ModuleKey* owner, String name, usz arity) @private
{
	ulong hash = 1469598103934665603UL;
	foreach (byte : owner.canonical)
	{
		hash ^= (ulong)byte;
		hash *= 1099511628211UL;
	}
	hash ^= (ulong)SymbolKind.SYMBOL_GENERIC;
	hash *= 1099511628211UL;
	hash ^= (ulong)arity;
	hash *= 1099511628211UL;
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
	if (!index.buckets.len || !index.caller_module) return null;
	usz mask = index.buckets.len - 1;
	usz slot = (usz)effect_call_hash(index.caller_module, name, arity) & mask;
	for (usz probe = 0; probe < index.buckets.len; probe++)
	{
		sz group_index = index.buckets[slot];
		if (group_index < 0) return null;
		EffectCallGroup* group = &index.groups[group_index];
		if (symbol_key_matches_declaration(
			group.key, index.caller_module, SYMBOL_GENERIC, name, arity, ""
		)) return group;
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
fn bool effect_resolve_pattern_value(
	EffectCallIndex* calls,
	SurfaceExpr* producer,
	EffectLexicalScope* scope,
	String constructor,
	usz field_index,
	SurfaceExpr** result,
	EffectLexicalScope** result_scope,
	EffectInferenceWork* work,
	usz depth
) @private
{
	if (!producer || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH
		|| !effect_charge(work)) return false;
	switch (producer.kind)
	{
		case SURFACE_VARIABLE:
			SurfaceExpr* value = null;
			EffectLexicalScope* value_scope = scope;
			if (!effect_lexical_lookup(
				scope, producer.data.variable.name, work,
				null, null, &value, &value_scope
			) || !value || value == producer) return false;
			return effect_resolve_pattern_value(
				calls, value, value_scope, constructor, field_index,
				result, result_scope, work, depth + 1
			);
		case SURFACE_APPLICATION:
			ApplicationExpr* application = &producer.data.application;
			bool constructor_call = application.callee
				&& application.callee.kind == SURFACE_VARIABLE
				&& application.callee.data.variable.name == constructor;
			bool constructor_shadowed = constructor_call
				&& effect_lexical_is_bound(scope, constructor, work);
			if (work.exhausted) return false;
			if (constructor_call && !constructor_shadowed
				&& field_index < application.arguments.len)
			{
				SurfaceExpr* selected = application.arguments[field_index];
				EffectLexicalScope* selected_scope = scope;
				for (usz selected_depth = depth + 1;
					selected && selected_depth < MITOS_MAX_TYPE_FORMAT_DEPTH;
					selected_depth++)
				{
					if (selected.kind != SURFACE_VARIABLE) break;
					SurfaceExpr* nested = null;
					EffectLexicalScope* nested_scope = selected_scope;
					if (!effect_lexical_lookup(
						selected_scope, selected.data.variable.name, work,
						null, null, &nested, &nested_scope
					) || !nested || nested == selected) break;
					selected = nested;
					selected_scope = nested_scope;
				}
				if (!selected) return false;
				*result = selected;
				*result_scope = selected_scope;
				return true;
			}
			SurfaceExpr* callable = null;
			EffectLexicalScope* callable_scope = scope;
			bool lexical = false;
			String callable_name;
			if (application.callee && application.callee.kind == SURFACE_LAMBDA)
			{
				callable = application.callee;
				lexical = true;
			}
			else if (application.callee && application.callee.kind == SURFACE_VARIABLE)
			{
				callable_name = application.callee.data.variable.name;
				SurfaceExpr* callable_value = null;
				EffectLexicalScope* callable_value_scope = scope;
				lexical = effect_lexical_lookup(
					scope, application.callee.data.variable.name, work,
					&callable, &callable_scope, &callable_value, &callable_value_scope
				);
				if (lexical && !callable)
				{
					callable = callable_value;
					callable_scope = callable_value_scope;
				}
				effect_follow_callable_alias(
					&callable, &callable_scope, &lexical, &callable_name,
					work, 0
				);
				if (work.exhausted) return false;
			}
			if (lexical && callable && callable.kind == SURFACE_LAMBDA)
			{
				EffectLexicalScope invocation_value = {
					.parent = callable_scope,
					.names = callable.data.lambda.parameters,
					.values = application.arguments,
					.value_default_scope = scope,
					.calls = calls,
				};
				EffectLexicalScope* invocation_scope = effect_work_scope(
					work, &invocation_value
				);
				if (!invocation_scope) return false;
				return effect_resolve_pattern_value(
					calls, callable.data.lambda.body, invocation_scope,
					constructor, field_index, result, result_scope, work, depth + 1
				);
			}
			if (lexical) return false;
			EffectCallGroup* group = callable_name.len
				? effect_call_group(
					calls, callable_name, application.arguments.len
				) : null;
			if (!group) return false;
			SurfaceExpr* resolved = null;
			EffectLexicalScope* resolved_scope = null;
			bool found = false;
			foreach (target : group.targets)
			{
				if (!effect_charge(work)) return false;
				if (target >= calls.program.functions.len) continue;
				FunctionDecl* function = &calls.program.functions[target];
				EffectLexicalScope function_value = {
					.names = function.parameters,
					.values = application.arguments,
					.value_default_scope = scope,
					.calls = calls,
				};
				EffectLexicalScope* function_scope = effect_work_scope(
					work, &function_value
				);
				if (!function_scope) return false;
				SurfaceExpr* candidate = null;
				EffectLexicalScope* candidate_scope = null;
				if (!effect_resolve_pattern_value(
					calls, function.body, function_scope, constructor, field_index,
					&candidate, &candidate_scope, work, depth + 1
				)) return false;
				if (found && (candidate != resolved || candidate_scope != resolved_scope))
				{
					return false;
				}
				resolved = candidate;
				resolved_scope = candidate_scope;
				found = true;
			}
			if (!found) return false;
			*result = resolved;
			*result_scope = resolved_scope;
			return true;
		case SURFACE_DEFINITION:
			String[1] definition_name = { producer.data.definition.name };
			SurfaceExpr*[1] definition_value = { producer.data.definition.value };
			EffectLexicalScope definition_prototype = {
				.parent = scope,
				.names = definition_name[..],
				.values = definition_value[..],
				.value_default_scope = scope,
				.calls = calls,
			};
			EffectLexicalScope* definition_scope = effect_work_scope(
				work, &definition_prototype
			);
			if (!definition_scope) return false;
			return effect_resolve_pattern_value(
				calls, producer.data.definition.body, definition_scope,
				constructor, field_index, result, result_scope, work, depth + 1
			);
		case SURFACE_MATCH:
			SurfaceExpr* resolved = null;
			EffectLexicalScope* resolved_scope = null;
			bool found = false;
			foreach (&arm : producer.data.match_expr.arms)
			{
				if (!effect_charge(work)) return false;
				EffectLexicalScope arm_value = {
					.parent = scope,
					.names = arm.pattern.bindings,
					.pattern_scrutinee = producer.data.match_expr.scrutinee,
					.pattern_constructor = arm.pattern.constructor,
					.pattern_scope = scope,
					.calls = calls,
				};
				EffectLexicalScope* arm_scope = effect_work_scope(work, &arm_value);
				if (!arm_scope) return false;
				SurfaceExpr* candidate = null;
				EffectLexicalScope* candidate_scope = null;
				if (!effect_resolve_pattern_value(
					calls, arm.body, arm_scope, constructor, field_index,
					&candidate, &candidate_scope, work, depth + 1
				)) return false;
				if (found && (candidate != resolved || candidate_scope != resolved_scope))
				{
					return false;
				}
				resolved = candidate;
				resolved_scope = candidate_scope;
				found = true;
			}
			if (!found) return false;
			*result = resolved;
			*result_scope = resolved_scope;
			return true;
		case SURFACE_PARALLEL:
			EffectLexicalScope parallel_value = {
				.parent = scope,
				.parallel_bindings = producer.data.parallel.bindings,
				.calls = calls,
			};
			EffectLexicalScope* parallel_scope = effect_work_scope(
				work, &parallel_value
			);
			if (!parallel_scope) return false;
			return effect_resolve_pattern_value(
				calls, producer.data.parallel.result, parallel_scope,
				constructor, field_index, result, result_scope, work, depth + 1
			);
		case SURFACE_RESUME:
			return effect_resolve_pattern_value(
				calls, producer.data.resume.value, scope, constructor, field_index,
				result, result_scope, work, depth + 1
			);
		case SURFACE_HANDLER:
			SurfaceExpr* resolved = null;
			EffectLexicalScope* resolved_scope = null;
			bool found = false;
			foreach (&clause : producer.data.handler.clauses)
			{
				if (!effect_charge(work)) return false;
				EffectLexicalScope clause_value = {
					.parent = scope,
					.names = clause.parameters,
					.calls = calls,
				};
				EffectLexicalScope* clause_scope = effect_work_scope(
					work, &clause_value
				);
				if (!clause_scope) return false;
				SurfaceExpr* candidate = null;
				EffectLexicalScope* candidate_scope = null;
				if (!effect_resolve_pattern_value(
					calls, clause.body, clause_scope, constructor, field_index,
					&candidate, &candidate_scope, work, depth + 1
				)) return false;
				if (found && (candidate != resolved || candidate_scope != resolved_scope))
				{
					return false;
				}
				resolved = candidate;
				resolved_scope = candidate_scope;
				found = true;
			}
			String[1] return_name = { producer.data.handler.return_clause.parameter };
			SurfaceExpr*[1] return_value = { producer.data.handler.handled };
			EffectLexicalScope return_value_scope = {
				.parent = scope,
				.names = return_name[..],
				.values = return_value[..],
				.value_default_scope = scope,
				.calls = calls,
			};
			EffectLexicalScope* return_scope = effect_work_scope(
				work, &return_value_scope
			);
			if (!return_scope) return false;
			SurfaceExpr* candidate = null;
			EffectLexicalScope* candidate_scope = null;
			if (!effect_resolve_pattern_value(
				calls, producer.data.handler.return_clause.body, return_scope,
				constructor, field_index, &candidate, &candidate_scope,
				work, depth + 1
			)) return false;
			if (found && (candidate != resolved || candidate_scope != resolved_scope))
			{
				return false;
			}
			*result = candidate;
			*result_scope = candidate_scope;
			return true;
		default:
			return false;
	}
}

fn EffectCallIndex build_effect_call_index(
	Program* program,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator
) @private
{
	EffectCallIndex index = {
		.allocator = allocator,
		.caller_module = &program.module_key,
		.program = program,
	};
	index.groups.init(allocator);
	index.buckets = alloc::new_array(
		allocator, sz, (sz)effect_index_capacity(program.functions.len)
	);
	foreach (&bucket : index.buckets) *bucket = -1;
	usz mask = index.buckets.len - 1;
	foreach (function_index, &function : program.functions)
	{
		if (!symbol_key_matches_declaration(
			&function.generic_key, &function.generic_key.owner, SYMBOL_GENERIC,
			function.name, function.parameters.len, ""
		))
		{
			effects_add_diagnostic(
				diagnostics, allocator,
				"effect inference requires a canonical generic identity", function.span
			);
			continue;
		}
		usz slot = (usz)effect_call_hash(
			&function.generic_key.owner, function.generic_key.name, function.generic_key.arity
		) & mask;
		for (usz probe = 0; probe < index.buckets.len; probe++)
		{
			sz group_index = index.buckets[slot];
			if (group_index < 0)
			{
				EffectCallGroup group = { .key = &function.generic_key };
				group.targets.init(allocator);
				group.targets.push((usz)function_index);
				index.groups.push(group);
				index.buckets[slot] = index.groups.len() - 1;
				break;
			}
			EffectCallGroup* group = &index.groups[group_index];
			if (symbol_key_equal(group.key, &function.generic_key))
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

fn EffectLexicalScope* effect_work_scope(
	EffectInferenceWork* work,
	EffectLexicalScope* prototype
) @private
{
	if (!effect_charge(work)
		|| !effect_charge(work, prototype.names.len)
		|| !effect_charge(work, prototype.closures.len)
		|| !effect_charge(work, prototype.closure_scopes.len)
		|| !effect_charge(work, prototype.parallel_bindings.len)
		|| !effect_charge(work, prototype.values.len)
		|| !effect_charge(work, prototype.value_scopes.len)) return null;
	EffectLexicalScope* owned = alloc::new(
		work.allocator, EffectLexicalScope, *prototype
	);
	owned.names = alloc::clone_slice(work.allocator, prototype.names);
	owned.closures = alloc::clone_slice(work.allocator, prototype.closures);
	owned.closure_scopes = alloc::clone_slice(
		work.allocator, prototype.closure_scopes
	);
	owned.parallel_bindings = alloc::clone_slice(
		work.allocator, prototype.parallel_bindings
	);
	owned.values = alloc::clone_slice(work.allocator, prototype.values);
	owned.value_scopes = alloc::clone_slice(
		work.allocator, prototype.value_scopes
	);
	work.scopes.push(owned);
	return owned;
}

fn void effect_work_clear_scopes(EffectInferenceWork* work) @private
{
	foreach (scope : work.scopes)
	{
		alloc::free(work.allocator, scope.names);
		alloc::free(work.allocator, scope.closures);
		alloc::free(work.allocator, scope.closure_scopes);
		alloc::free(work.allocator, scope.parallel_bindings);
		alloc::free(work.allocator, scope.values);
		alloc::free(work.allocator, scope.value_scopes);
		alloc::free(work.allocator, scope);
	}
	work.scopes.clear();
}

fn bool effect_producer_contains_closure(
	EffectCallIndex* calls,
	SurfaceExpr* producer,
	EffectLexicalScope* scope,
	EffectInferenceWork* work,
	usz depth
) @private
{
	if (!producer || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH || !effect_charge(work)) return false;
	switch (producer.kind)
	{
		case SURFACE_LAMBDA:
			return true;
		case SURFACE_VARIABLE:
			SurfaceExpr* closure = null;
			EffectLexicalScope* closure_scope = scope;
			SurfaceExpr* value = null;
			EffectLexicalScope* value_scope = scope;
			if (!effect_lexical_lookup(
				scope, producer.data.variable.name, work,
				&closure, &closure_scope, &value, &value_scope
			)) return false;
			return closure || effect_producer_contains_closure(
				calls, value, value_scope, work, depth + 1
			);
		case SURFACE_APPLICATION:
			ApplicationExpr* application = &producer.data.application;
			SurfaceExpr* callable = null;
			EffectLexicalScope* callable_scope = scope;
			bool lexical = false;
			String callable_name;
			if (application.callee && application.callee.kind == SURFACE_LAMBDA)
			{
				callable = application.callee;
				lexical = true;
			}
			else if (application.callee && application.callee.kind == SURFACE_VARIABLE)
			{
				callable_name = application.callee.data.variable.name;
				SurfaceExpr* callable_value = null;
				EffectLexicalScope* callable_value_scope = scope;
				lexical = effect_lexical_lookup(
					scope, callable_name, work,
					&callable, &callable_scope, &callable_value, &callable_value_scope
				);
				if (lexical && !callable)
				{
					callable = callable_value;
					callable_scope = callable_value_scope;
				}
				effect_follow_callable_alias(
					&callable, &callable_scope, &lexical, &callable_name,
					work, 0
				);
				if (work.exhausted) return false;
			}
			if (lexical && callable && callable.kind == SURFACE_LAMBDA)
			{
				EffectLexicalScope invocation_scope = {
					.parent = callable_scope,
					.names = callable.data.lambda.parameters,
					.values = application.arguments,
					.value_default_scope = scope,
					.calls = calls,
				};
				return effect_producer_contains_closure(
					calls, callable.data.lambda.body, &invocation_scope,
					work, depth + 1
				);
			}
			if (lexical) return callable && effect_producer_contains_closure(
				calls, callable, callable_scope, work, depth + 1
			);
			if (!callable_name.len) return false;
			if (callable_name == "superpose")
			{
				if (!application.arguments.len) return false;
				foreach (alternative : application.arguments)
				{
					if (!effect_producer_contains_closure(
						calls, alternative, scope, work, depth + 1
					)) return false;
				}
				return true;
			}
			EffectCallGroup* group = effect_call_group(
				calls, callable_name, application.arguments.len
			);
			if (!group || !group.targets.len()) return false;
			foreach (target : group.targets)
			{
				if (!effect_charge(work)) return false;
				if (target >= calls.program.functions.len) return false;
				FunctionDecl* function = &calls.program.functions[target];
				EffectLexicalScope function_scope = {
					.names = function.parameters,
					.values = application.arguments,
					.value_default_scope = scope,
					.calls = calls,
				};
				if (!effect_producer_contains_closure(
					calls, function.body, &function_scope, work, depth + 1
				)) return false;
			}
			return true;
		case SURFACE_DEFINITION:
			String[1] definition_name = { producer.data.definition.name };
			SurfaceExpr*[1] definition_value = { producer.data.definition.value };
			EffectLexicalScope definition_scope = {
				.parent = scope,
				.names = definition_name[..],
				.values = definition_value[..],
				.value_default_scope = scope,
				.calls = calls,
			};
			return effect_producer_contains_closure(
				calls, producer.data.definition.body, &definition_scope,
				work, depth + 1
			);
		case SURFACE_MATCH:
			if (!producer.data.match_expr.arms.len) return false;
			foreach (&arm : producer.data.match_expr.arms)
			{
				EffectLexicalScope arm_scope = {
					.parent = scope,
					.names = arm.pattern.bindings,
					.pattern_scrutinee = producer.data.match_expr.scrutinee,
					.pattern_constructor = arm.pattern.constructor,
					.pattern_scope = scope,
					.calls = calls,
				};
				if (!effect_producer_contains_closure(
					calls, arm.body, &arm_scope, work, depth + 1
				)) return false;
			}
			return true;
		case SURFACE_PARALLEL:
			EffectLexicalScope parallel_scope = {
				.parent = scope,
				.parallel_bindings = producer.data.parallel.bindings,
				.calls = calls,
			};
			return effect_producer_contains_closure(
				calls, producer.data.parallel.result, &parallel_scope,
				work, depth + 1
			);
		case SURFACE_RESUME:
			return effect_producer_contains_closure(
				calls, producer.data.resume.value, scope, work, depth + 1
			);
		case SURFACE_HANDLER:
			foreach (&clause : producer.data.handler.clauses)
			{
				EffectLexicalScope clause_scope = {
					.parent = scope,
					.names = clause.parameters,
					.calls = calls,
				};
				if (effect_producer_contains_closure(
					calls, clause.body, &clause_scope, work, depth + 1
				)) return true;
			}
			String[1] return_name = { producer.data.handler.return_clause.parameter };
			SurfaceExpr*[1] return_value = { producer.data.handler.handled };
			EffectLexicalScope return_scope = {
				.parent = scope,
				.names = return_name[..],
				.values = return_value[..],
				.value_default_scope = scope,
				.calls = calls,
			};
			return effect_producer_contains_closure(
				calls, producer.data.handler.return_clause.body, &return_scope,
				work, depth + 1
			);
		default:
			return false;
	}
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

fn void inferred_row_tail(
	SymbolKey** tail,
	SymbolKey* candidate,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	MitosSpan span
) @private
{
	if (!candidate) return;
	if (!*tail)
	{
		*tail = candidate;
		return;
	}
	if (!symbol_key_equal(*tail, candidate))
	{
		effects_add_diagnostic(
			diagnostics, allocator,
			"effect inference cannot unify two distinct open row tails", span
		);
	}
}

fn bool collect_known_callable_producer(
	EffectRegistry* registry,
	EffectCallIndex* calls,
	SurfaceExpr* producer,
	EffectLexicalScope* scope,
	List{EffectId}* row,
	List{EffectId}[] current_rows,
	SymbolKey*[] current_tails,
	SymbolKey** tail,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	EffectInferenceWork* work,
	usz depth
) @private
{
	if (!producer || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH) return false;
	if (effect_producer_contains_closure(calls, producer, scope, work, depth + 1))
	{
		collect_callable_producer_effects(
			registry, calls, producer, scope, row, current_rows, current_tails,
			tail, diagnostics, allocator, work, depth + 1
		);
		return true;
	}
	if (producer.kind != SURFACE_VARIABLE) return false;
	usz origin_function = usz::max;
	usz origin_parameter = usz::max;
	String origin_effect;
	String origin_operation;
	if (!effect_lexical_origin(
		scope, producer.data.variable.name, work,
		&origin_function, &origin_parameter, &origin_effect, &origin_operation
	)) return false;
	return collect_reachable_parameter_effects(
		registry, calls, origin_function, origin_effect, origin_operation,
		origin_parameter, row, current_rows, current_tails, tail, diagnostics,
		allocator, work, depth + 1
	);
}


fn void collect_reachable_callable_arguments(
	EffectRegistry* registry,
	EffectCallIndex* calls,
	SurfaceExpr* expression,
	EffectLexicalScope* scope,
	usz target_function,
	String target_effect,
	String target_operation,
	usz parameter_index,
	List{EffectId}* row,
	List{EffectId}[] current_rows,
	SymbolKey*[] current_tails,
	SymbolKey** tail,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	EffectInferenceWork* work,
	bool* found,
	usz depth
) @private
{
	if (!expression || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH || !effect_charge(work)) return;
	switch (expression.kind)
	{
		case SURFACE_LAMBDA:
			EffectLexicalScope lambda_scope = {
				.parent = scope,
				.names = expression.data.lambda.parameters,
				.calls = calls,
			};
			collect_reachable_callable_arguments(
				registry, calls, expression.data.lambda.body, &lambda_scope,
				target_function, target_effect, target_operation, parameter_index,
				row, current_rows, current_tails, tail, diagnostics, allocator,
				work, found, depth + 1
			);
		case SURFACE_APPLICATION:
			ApplicationExpr* application = &expression.data.application;
			collect_reachable_callable_arguments(
				registry, calls, application.callee, scope, target_function,
				target_effect, target_operation, parameter_index, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, found, depth + 1
			);
			foreach (argument : application.arguments)
			{
				collect_reachable_callable_arguments(
					registry, calls, argument, scope, target_function,
					target_effect, target_operation, parameter_index, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, found, depth + 1
				);
			}
			if (target_function != usz::max && application.callee
				&& application.callee.kind == SURFACE_VARIABLE
				&& !effect_lexical_is_bound(
					scope, application.callee.data.variable.name, work
				))
			{
				EffectCallGroup* group = effect_call_group(
					calls, application.callee.data.variable.name,
					application.arguments.len
				);
				bool targets_function = false;
				if (group) foreach (target : group.targets)
				{
					if (!effect_charge(work)) return;
					if (target == target_function)
					{
						targets_function = true;
						break;
					}
				}
				if (targets_function && parameter_index < application.arguments.len)
				{
					SurfaceExpr* argument = application.arguments[parameter_index];
					if (collect_known_callable_producer(
						registry, calls, argument, scope, row, current_rows,
						current_tails, tail, diagnostics, allocator, work, depth + 1
					)) *found = true;
				}
			}
		case SURFACE_EFFECT_OPERATION:
			foreach (argument : expression.data.effect_operation.arguments)
			{
				collect_reachable_callable_arguments(
					registry, calls, argument, scope, target_function,
					target_effect, target_operation, parameter_index, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, found, depth + 1
				);
			}
			if (target_function == usz::max
				&& expression.data.effect_operation.effect_name == target_effect
				&& expression.data.effect_operation.operation_name == target_operation
				&& parameter_index < expression.data.effect_operation.arguments.len)
			{
				SurfaceExpr* argument =
					expression.data.effect_operation.arguments[parameter_index];
				if (collect_known_callable_producer(
					registry, calls, argument, scope, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, depth + 1
				)) *found = true;
			}
		case SURFACE_BINARY:
			collect_reachable_callable_arguments(
				registry, calls, expression.data.binary.left, scope, target_function,
				target_effect, target_operation, parameter_index, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, found, depth + 1
			);
			collect_reachable_callable_arguments(
				registry, calls, expression.data.binary.right, scope, target_function,
				target_effect, target_operation, parameter_index, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, found, depth + 1
			);
		case SURFACE_DEFINITION:
			DefinitionExpr* definition = &expression.data.definition;
			collect_reachable_callable_arguments(
				registry, calls, definition.value, scope, target_function,
				target_effect, target_operation, parameter_index, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, found, depth + 1
			);
			String[1] definition_name = { definition.name };
			SurfaceExpr*[1] definition_value = { definition.value };
			EffectLexicalScope definition_scope = {
				.parent = scope,
				.names = definition_name[..],
				.values = definition_value[..],
				.value_default_scope = scope,
				.calls = calls,
			};
			collect_reachable_callable_arguments(
				registry, calls, definition.body, &definition_scope, target_function,
				target_effect, target_operation, parameter_index, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, found, depth + 1
			);
		case SURFACE_MATCH:
			collect_reachable_callable_arguments(
				registry, calls, expression.data.match_expr.scrutinee, scope,
				target_function, target_effect, target_operation, parameter_index,
				row, current_rows, current_tails, tail, diagnostics, allocator,
				work, found, depth + 1
			);
			foreach (&arm : expression.data.match_expr.arms)
			{
				EffectLexicalScope arm_scope = {
					.parent = scope,
					.names = arm.pattern.bindings,
					.pattern_scrutinee = expression.data.match_expr.scrutinee,
					.pattern_constructor = arm.pattern.constructor,
					.pattern_scope = scope,
					.calls = calls,
				};
				collect_reachable_callable_arguments(
					registry, calls, arm.body, &arm_scope, target_function,
					target_effect, target_operation, parameter_index, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, found, depth + 1
				);
			}
		case SURFACE_PARALLEL:
			foreach (&binding : expression.data.parallel.bindings)
			{
				collect_reachable_callable_arguments(
					registry, calls, binding.value, scope, target_function,
					target_effect, target_operation, parameter_index, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, found, depth + 1
				);
			}
			EffectLexicalScope parallel_scope = {
				.parent = scope,
				.parallel_bindings = expression.data.parallel.bindings,
				.calls = calls,
			};
			collect_reachable_callable_arguments(
				registry, calls, expression.data.parallel.result, &parallel_scope,
				target_function, target_effect, target_operation, parameter_index,
				row, current_rows, current_tails, tail, diagnostics, allocator,
				work, found, depth + 1
			);
		case SURFACE_HANDLER:
			collect_reachable_callable_arguments(
				registry, calls, expression.data.handler.handled, scope,
				target_function, target_effect, target_operation, parameter_index,
				row, current_rows, current_tails, tail, diagnostics, allocator,
				work, found, depth + 1
			);
			foreach (&clause : expression.data.handler.clauses)
			{
				EffectLexicalScope clause_scope = {
					.parent = scope,
					.names = clause.parameters,
					.handler_effect_name = clause.effect_name,
					.handler_operation_name = clause.operation_name,
					.calls = calls,
				};
				collect_reachable_callable_arguments(
					registry, calls, clause.body, &clause_scope, target_function,
					target_effect, target_operation, parameter_index, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, found, depth + 1
				);
			}
			String[1] return_name = { expression.data.handler.return_clause.parameter };
			SurfaceExpr*[1] return_value = { expression.data.handler.handled };
			EffectLexicalScope return_scope = {
				.parent = scope,
				.names = return_name[..],
				.values = return_value[..],
				.value_default_scope = scope,
				.calls = calls,
			};
			collect_reachable_callable_arguments(
				registry, calls, expression.data.handler.return_clause.body,
				&return_scope, target_function, target_effect, target_operation,
				parameter_index, row, current_rows, current_tails, tail, diagnostics,
				allocator, work, found, depth + 1
			);
		case SURFACE_RESUME:
			collect_reachable_callable_arguments(
				registry, calls, expression.data.resume.value, scope, target_function,
				target_effect, target_operation, parameter_index, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, found, depth + 1
			);
		default:
	}
}

fn bool collect_reachable_parameter_effects(
	EffectRegistry* registry,
	EffectCallIndex* calls,
	usz target_function,
	String target_effect,
	String target_operation,
	usz parameter_index,
	List{EffectId}* row,
	List{EffectId}[] current_rows,
	SymbolKey*[] current_tails,
	SymbolKey** tail,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	EffectInferenceWork* work,
	usz depth
) @private
{
	bool found = false;
	foreach (function_index, &function : calls.program.functions)
	{
		EffectLexicalScope function_scope = {
			.names = function.parameters,
			.calls = calls,
			.function_index_plus_one = (usz)function_index + 1,
		};
		collect_reachable_callable_arguments(
			registry, calls, function.body, &function_scope, target_function,
			target_effect, target_operation, parameter_index, row, current_rows,
			current_tails, tail, diagnostics, allocator, work, &found, depth + 1
		);
	}
	return found;
}


fn void collect_callable_producer_effects(
	EffectRegistry* registry,
	EffectCallIndex* calls,
	SurfaceExpr* producer,
	EffectLexicalScope* producer_scope,
	List{EffectId}* row,
	List{EffectId}[] current_rows,
	SymbolKey*[] current_tails,
	SymbolKey** tail,
	List{MitosDiagnostic}* diagnostics,
	Allocator allocator,
	EffectInferenceWork* work,
	usz depth
) @private
{
	if (!producer || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH || !effect_charge(work)) return;
	switch (producer.kind)
	{
		case SURFACE_VARIABLE:
			SurfaceExpr* closure = null;
			EffectLexicalScope* closure_scope = producer_scope;
			SurfaceExpr* value = null;
			EffectLexicalScope* value_scope = producer_scope;
			if (effect_lexical_lookup(
				producer_scope, producer.data.variable.name, work,
				&closure, &closure_scope, &value, &value_scope
			))
			{
				collect_callable_producer_effects(
					registry, calls, closure ? closure : value,
					closure ? closure_scope : value_scope, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, depth + 1
				);
			}
		case SURFACE_LAMBDA:
			LambdaExpr* lambda = &producer.data.lambda;
			EffectLexicalScope lambda_scope = {
				.parent = producer_scope,
				.names = lambda.parameters,
			};
			collect_expression_effects(
				registry, calls, lambda.body, &lambda_scope, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
			if (lambda.effect_row && lambda.effect_row.has_tail)
			{
				inferred_row_tail(
					tail, &lambda.effect_row.tail, diagnostics, allocator, producer.span
				);
			}
		case SURFACE_APPLICATION:
			ApplicationExpr* application = &producer.data.application;
			SurfaceExpr* callable = null;
			EffectLexicalScope* callable_scope = producer_scope;
			String producer_name;
			bool lexical = false;
			if (application.callee && application.callee.kind == SURFACE_LAMBDA)
			{
				callable = application.callee;
				lexical = true;
			}
			else if (application.callee && application.callee.kind == SURFACE_VARIABLE)
			{
				producer_name = application.callee.data.variable.name;
				SurfaceExpr* callable_value = null;
				EffectLexicalScope* callable_value_scope = producer_scope;
				lexical = effect_lexical_lookup(
					producer_scope, producer_name, work,
					&callable, &callable_scope, &callable_value, &callable_value_scope
				);
				if (lexical && !callable)
				{
					callable = callable_value;
					callable_scope = callable_value_scope;
				}
				effect_follow_callable_alias(
					&callable, &callable_scope, &lexical, &producer_name,
					work, 0
				);
				if (work.exhausted) return;
				if (!lexical)
				{
					if (producer_name == "superpose")
					{
						foreach (alternative : application.arguments)
						{
							collect_callable_producer_effects(
								registry, calls, alternative, producer_scope, row,
								current_rows, current_tails, tail, diagnostics,
								allocator, work, depth + 1
							);
						}
						return;
					}
					if (producer_name == "collapse" || producer_name == "typeOf"
						|| producer_name == "assertType")
					{
						effects_add_diagnostic(
							diagnostics, allocator,
							"effect inference cannot resolve a callable intrinsic producer",
							producer.span
						);
						return;
					}
					EffectCallGroup* group = effect_call_group(
						calls, producer_name, application.arguments.len
					);
					if (group) foreach (target : group.targets)
					{
						if (!effect_charge(work)) return;
						if (target >= calls.program.functions.len) continue;
						FunctionDecl* function = &calls.program.functions[target];
						EffectLexicalScope function_scope = {
							.names = function.parameters,
							.values = application.arguments,
							.value_default_scope = producer_scope,
							.calls = calls,
						};
						collect_callable_producer_effects(
							registry, calls, function.body, &function_scope, row,
							current_rows, current_tails, tail, diagnostics, allocator,
							work, depth + 1
						);
					}
					return;
				}
			}
			if (callable && callable.kind == SURFACE_LAMBDA)
			{
				EffectLexicalScope invocation_scope = {
					.parent = callable_scope,
					.names = callable.data.lambda.parameters,
					.values = application.arguments,
					.value_default_scope = producer_scope,
				};
				collect_callable_producer_effects(
					registry, calls, callable.data.lambda.body, &invocation_scope, row,
					current_rows, current_tails, tail, diagnostics, allocator,
					work, depth + 1
				);
			}
			else if (callable)
			{
				collect_callable_producer_effects(
					registry, calls, callable, callable_scope, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, depth + 1
				);
			}
		case SURFACE_DEFINITION:
			DefinitionExpr* definition = &producer.data.definition;
			String[1] definition_name = { definition.name };
			SurfaceExpr*[1] definition_value = { definition.value };
			EffectLexicalScope definition_scope = {
				.parent = producer_scope,
				.names = definition_name[..],
				.values = definition_value[..],
				.value_default_scope = producer_scope,
			};
			collect_callable_producer_effects(
				registry, calls, definition.body, &definition_scope, row,
				current_rows, current_tails, tail, diagnostics, allocator,
				work, depth + 1
			);
		case SURFACE_MATCH:
			foreach (&arm : producer.data.match_expr.arms)
			{
				EffectLexicalScope arm_scope = {
					.parent = producer_scope,
					.names = arm.pattern.bindings,
					.pattern_scrutinee = producer.data.match_expr.scrutinee,
					.pattern_constructor = arm.pattern.constructor,
					.pattern_scope = producer_scope,
				};
				collect_callable_producer_effects(
					registry, calls, arm.body, &arm_scope, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, depth + 1
				);
			}
		case SURFACE_PARALLEL:
			EffectLexicalScope parallel_scope = {
				.parent = producer_scope,
				.parallel_bindings = producer.data.parallel.bindings,
				.calls = calls,
			};
			collect_callable_producer_effects(
				registry, calls, producer.data.parallel.result, &parallel_scope, row,
				current_rows, current_tails, tail, diagnostics, allocator,
				work, depth + 1
			);
		case SURFACE_RESUME:
			collect_callable_producer_effects(
				registry, calls, producer.data.resume.value, producer_scope, row,
				current_rows, current_tails, tail, diagnostics, allocator,
				work, depth + 1
			);
		case SURFACE_HANDLER:
			foreach (&clause : producer.data.handler.clauses)
			{
				EffectLexicalScope clause_scope = {
					.parent = producer_scope,
					.names = clause.parameters,
					.handler_effect_name = clause.effect_name,
					.handler_operation_name = clause.operation_name,
					.calls = calls,
				};
				collect_callable_producer_effects(
					registry, calls, clause.body, &clause_scope, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, depth + 1
				);
			}
			String[1] return_name = { producer.data.handler.return_clause.parameter };
			SurfaceExpr*[1] return_value = { producer.data.handler.handled };
			EffectLexicalScope return_scope = {
				.parent = producer_scope,
				.names = return_name[..],
				.values = return_value[..],
				.value_default_scope = producer_scope,
			};
			collect_callable_producer_effects(
				registry, calls, producer.data.handler.return_clause.body,
				&return_scope, row, current_rows, current_tails, tail, diagnostics,
				allocator, work, depth + 1
			);
		default:
	}
}


fn void collect_expression_effects(
	EffectRegistry* registry,
	EffectCallIndex* calls,
	SurfaceExpr* expression,
	EffectLexicalScope* scope,
	List{EffectId}* row,
	List{EffectId}[] current_rows,
	SymbolKey*[] current_tails,
	SymbolKey** tail,
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
		case SURFACE_STRING:
		case SURFACE_LAMBDA:
			return;
		case SURFACE_APPLICATION:
			ApplicationExpr* application = &expression.data.application;
			collect_expression_effects(
				registry, calls, application.callee, scope, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
			foreach (argument : application.arguments)
				collect_expression_effects(
					registry, calls, argument, scope, row, current_rows, current_tails,
					tail, diagnostics, allocator, work, depth + 1
				);
			SurfaceExpr* applied_closure = null;
			EffectLexicalScope* closure_scope = scope;
			SurfaceExpr* applied_producer = null;
			EffectLexicalScope* producer_scope = scope;
			bool unresolved_producer = false;
			bool lexical_callee = false;
			String callee_name;
			if (application.callee && application.callee.kind == SURFACE_VARIABLE)
			{
				callee_name = application.callee.data.variable.name;
				lexical_callee = effect_lexical_lookup(
					scope, callee_name, work,
					&applied_closure, &closure_scope,
					&applied_producer, &producer_scope, &unresolved_producer
				);
				if (lexical_callee && !applied_closure && applied_producer)
				{
					SurfaceExpr* resolved_callable = applied_producer;
					EffectLexicalScope* resolved_scope = producer_scope;
					bool resolved_lexical = true;
					effect_follow_callable_alias(
						&resolved_callable, &resolved_scope, &resolved_lexical,
						&callee_name, work, 0
					);
					if (resolved_callable && resolved_callable.kind == SURFACE_LAMBDA)
					{
						applied_closure = resolved_callable;
						closure_scope = resolved_scope;
						applied_producer = null;
					}
					else if (!resolved_lexical)
					{
						applied_producer = null;
						unresolved_producer = false;
						lexical_callee = false;
					}
					else
					{
						applied_producer = resolved_callable;
						producer_scope = resolved_scope;
					}
				}
				if (work.exhausted) return;
				if (!lexical_callee)
				{
					EffectCallGroup* group = effect_call_group(
						calls, callee_name, application.arguments.len
					);
					if (group)
					{
						bool specialize = false;
						foreach (argument : application.arguments)
						{
							if (effect_producer_contains_closure(
								calls, argument, scope, work, depth + 1
							))
							{
								specialize = true;
								break;
							}
						}
						foreach (function_index : group.targets)
						{
							if (!effect_charge(work)) break;
							if (specialize && function_index < calls.program.functions.len)
							{
								FunctionDecl* function =
									&calls.program.functions[function_index];
								EffectLexicalScope function_scope = {
									.names = function.parameters,
									.values = application.arguments,
									.value_default_scope = scope,
									.calls = calls,
								};
								collect_expression_effects(
									registry, calls, function.body, &function_scope, row,
									current_rows, current_tails, tail, diagnostics,
									allocator, work, depth + 1
								);
								if (function.effect_row && function.effect_row.has_tail)
								{
									inferred_row_tail(
										tail, &function.effect_row.tail, diagnostics,
										allocator, expression.span
									);
								}
								continue;
							}
							foreach (effect : current_rows[function_index])
								(void)inferred_row_add(row, effect, work);
							inferred_row_tail(
								tail, current_tails[function_index], diagnostics,
								allocator, expression.span
							);
						}
					}
				}
			}
			else if (application.callee && application.callee.kind == SURFACE_LAMBDA)
			{
				applied_closure = application.callee;
			}
			if (applied_closure && applied_closure.kind == SURFACE_LAMBDA)
			{
				LambdaExpr* lambda = &applied_closure.data.lambda;
				EffectLexicalScope lambda_scope = {
					.parent = closure_scope,
					.names = lambda.parameters,
					.values = application.arguments,
					.value_default_scope = scope,
				};
				collect_expression_effects(
					registry, calls, lambda.body, &lambda_scope, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, depth + 1
				);
				if (lambda.effect_row && lambda.effect_row.has_tail)
				{
					inferred_row_tail(
						tail, &lambda.effect_row.tail, diagnostics, allocator, expression.span
					);
				}
			}
			else if (lexical_callee && applied_producer)
			{
				if (applied_producer.kind == SURFACE_HANDLER)
				{
					collect_callable_producer_effects(
						registry, calls, applied_producer, producer_scope, row,
						current_rows, current_tails, tail, diagnostics, allocator,
						work, depth + 1
					);
				}
				else if (!collect_known_callable_producer(
					registry, calls, applied_producer, producer_scope, row,
					current_rows, current_tails, tail, diagnostics, allocator,
					work, depth + 1
				))
				{
					effects_add_diagnostic(
						diagnostics, allocator,
						"effect inference cannot prove a lexical callable producer pure",
						expression.span
					);
				}
			}
			else if (lexical_callee && unresolved_producer)
			{
				effects_add_diagnostic(
					diagnostics, allocator,
					"effect inference cannot resolve a callable pattern binding producer",
					expression.span
				);
			}
			else if (lexical_callee)
			{
				usz origin_function = usz::max;
				usz origin_parameter = usz::max;
				String origin_effect;
				String origin_operation;
				bool has_origin = effect_lexical_origin(
					scope, application.callee.data.variable.name, work,
					&origin_function, &origin_parameter,
					&origin_effect, &origin_operation
				);
				bool found_reachable = has_origin && collect_reachable_parameter_effects(
					registry, calls, origin_function, origin_effect, origin_operation,
					origin_parameter, row, current_rows, current_tails, tail,
					diagnostics, allocator, work, depth + 1
				);
				if (!found_reachable)
				{
					effects_add_diagnostic(
						diagnostics, allocator,
						"effect inference cannot prove a lexical callable binding pure",
						expression.span
					);
				}
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
				effects_add_diagnostic(
					diagnostics, allocator,
					"effect operation argument count does not match its signature", expression.span
				);
			}
			else
			{
				(void)inferred_row_add(row, effect, work);
			}
			foreach (argument : expression.data.effect_operation.arguments)
				collect_expression_effects(
					registry, calls, argument, scope, row, current_rows, current_tails,
					tail, diagnostics, allocator, work, depth + 1
				);
		case SURFACE_BINARY:
			collect_expression_effects(
				registry, calls, expression.data.binary.left, scope, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
			collect_expression_effects(
				registry, calls, expression.data.binary.right, scope, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_DEFINITION:
			DefinitionExpr* definition = &expression.data.definition;
			collect_expression_effects(
				registry, calls, definition.value, scope, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
			SurfaceExpr* bound_closure = null;
			EffectLexicalScope* bound_scope = scope;
			if (definition.value && definition.value.kind == SURFACE_LAMBDA)
			{
				bound_closure = definition.value;
			}
			else if (definition.value && definition.value.kind == SURFACE_VARIABLE)
			{
				(void)effect_lexical_lookup(
					scope, definition.value.data.variable.name, work,
					&bound_closure, &bound_scope
				);
			}
			String[1] definition_name = { definition.name };
			SurfaceExpr*[1] definition_closure = { bound_closure };
			EffectLexicalScope*[1] definition_capture = { bound_scope };
			SurfaceExpr*[1] definition_value = { definition.value };
			EffectLexicalScope definition_scope = {
				.parent = scope,
				.names = definition_name[..],
				.closures = definition_closure[..],
				.closure_scopes = definition_capture[..],
				.values = definition_value[..],
				.value_default_scope = scope,
			};
			collect_expression_effects(
				registry, calls, definition.body, &definition_scope, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_MATCH:
			collect_expression_effects(
				registry, calls, expression.data.match_expr.scrutinee, scope, row,
				current_rows, current_tails, tail, diagnostics, allocator, work, depth + 1
			);
			foreach (&arm : expression.data.match_expr.arms)
			{
				EffectLexicalScope arm_scope = {
					.parent = scope,
					.names = arm.pattern.bindings,
					.pattern_scrutinee = expression.data.match_expr.scrutinee,
					.pattern_constructor = arm.pattern.constructor,
					.pattern_scope = scope,
				};
				collect_expression_effects(
					registry, calls, arm.body, &arm_scope, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, depth + 1
				);
			}
		case SURFACE_PARALLEL:
			ParallelExpr* parallel = &expression.data.parallel;
			foreach (&binding : parallel.bindings)
			{
				collect_expression_effects(
					registry, calls, binding.value, scope, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, depth + 1
				);
			}
			EffectLexicalScope parallel_scope = {
				.parent = scope,
				.parallel_bindings = parallel.bindings,
			};
			collect_expression_effects(
				registry, calls, parallel.result, &parallel_scope, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_HANDLER:
			List{EffectId} handled;
			handled.init(allocator);
			SymbolKey* handled_tail = null;
			collect_expression_effects(
				registry, calls, expression.data.handler.handled, scope, &handled,
				current_rows, current_tails, &handled_tail, diagnostics, allocator,
				work, depth + 1
			);
			foreach (&clause : expression.data.handler.clauses)
			{
				EffectId clause_effect = find_effect(registry, clause.effect_name);
				EffectOperationDescriptor* clause_operation = find_effect_operation(
					registry, clause_effect, clause.operation_name
				);
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
					effects_add_diagnostic(
						diagnostics, allocator,
						"handler clause parameter count does not match the operation", clause.span
					);
				}
				EffectLexicalScope clause_scope = {
					.parent = scope,
					.names = clause.parameters,
					.handler_effect_name = clause.effect_name,
					.handler_operation_name = clause.operation_name,
					.calls = calls,
				};
				collect_expression_effects(
					registry, calls, clause.body, &clause_scope, row, current_rows,
					current_tails, tail, diagnostics, allocator, work, depth + 1
				);
			}
			foreach (&handled_effect : registry.effects)
			{
				if (!effect_charge(work, (usz)handled.len() + 1)) break;
				bool appears = false;
				foreach (candidate : handled)
				{
					if (effect_constructor_id(registry, candidate) == handled_effect.id)
					{
						appears = true;
					}
				}
				if (!appears) continue;
				bool complete = true;
				foreach (&candidate_operation : handled_effect.operations)
				{
					if (!effect_charge(work, expression.data.handler.clauses.len + 1))
					{
						complete = false;
						break;
					}
					bool found = false;
					foreach (&clause : expression.data.handler.clauses)
					{
						if (clause.effect_name == handled_effect.name
							&& clause.operation_name == candidate_operation.name)
						{
							found = true;
						}
					}
					if (!found)
					{
						complete = false;
						effects_add_diagnostic(
							diagnostics, allocator,
							"handler is missing an operation clause", expression.span
						);
					}
				}
				if (complete && effect_charge(work, (usz)handled.len() + 1))
				{
					row_remove_constructor(registry, &handled, handled_effect.id);
				}
			}
			foreach (candidate : handled) (void)inferred_row_add(row, candidate, work);
			handled.free();
			inferred_row_tail(tail, handled_tail, diagnostics, allocator, expression.span);
			String[1] return_name = { expression.data.handler.return_clause.parameter };
			SurfaceExpr*[1] return_value = { expression.data.handler.handled };
			EffectLexicalScope return_scope = {
				.parent = scope,
				.names = return_name[..],
				.values = return_value[..],
				.value_default_scope = scope,
			};
			collect_expression_effects(
				registry, calls, expression.data.handler.return_clause.body,
				&return_scope, row, current_rows, current_tails, tail, diagnostics,
				allocator, work, depth + 1
			);
		case SURFACE_RESUME:
			collect_expression_effects(
				registry, calls, expression.data.resume.value, scope, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
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
			usz arm_max = 0;
			foreach (&arm : expression.data.match_expr.arms)
			{
				usz arm_count = count_resumes(arm.body, depth + 1);
				if (arm_count > arm_max) arm_max = arm_count;
			}
			return count + arm_max;
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


fn bool add_reverse_effect_edge(
	List{usz}* reverse_edges,
	usz caller,
	EffectInferenceWork* work
) @private
{
	// Functions are visited in source-index order, so equal callers are contiguous.
	// This preserves sorted reverse edges and makes syntactic-call deduplication O(1).
	if (reverse_edges.len() && (*reverse_edges)[reverse_edges.len() - 1] == caller) return true;
	if (!effect_charge(work)) return false;
	reverse_edges.push(caller);
	return true;
}


fn void collect_callable_producer_edges(
	EffectCallIndex* calls,
	SurfaceExpr* producer,
	EffectLexicalScope* producer_scope,
	usz caller,
	List{usz}[] callers,
	EffectInferenceWork* work,
	usz depth
) @private
{
	if (!producer || depth >= MITOS_MAX_TYPE_FORMAT_DEPTH || !effect_charge(work)) return;
	switch (producer.kind)
	{
		case SURFACE_VARIABLE:
			SurfaceExpr* closure = null;
			EffectLexicalScope* closure_scope = producer_scope;
			SurfaceExpr* value = null;
			EffectLexicalScope* value_scope = producer_scope;
			if (effect_lexical_lookup(
				producer_scope, producer.data.variable.name, work,
				&closure, &closure_scope, &value, &value_scope
			))
			{
				collect_callable_producer_edges(
					calls, closure ? closure : value,
					closure ? closure_scope : value_scope,
					caller, callers, work, depth + 1
				);
			}
		case SURFACE_LAMBDA:
			EffectLexicalScope lambda_scope = {
				.parent = producer_scope,
				.names = producer.data.lambda.parameters,
			};
			collect_effect_call_edges(
				calls, producer.data.lambda.body, &lambda_scope,
				caller, callers, work, depth + 1
			);
		case SURFACE_APPLICATION:
			ApplicationExpr* application = &producer.data.application;
			SurfaceExpr* callable = null;
			EffectLexicalScope* callable_scope = producer_scope;
			String producer_name;
			bool lexical = false;
			if (application.callee && application.callee.kind == SURFACE_LAMBDA)
			{
				callable = application.callee;
				lexical = true;
			}
			else if (application.callee && application.callee.kind == SURFACE_VARIABLE)
			{
				producer_name = application.callee.data.variable.name;
				SurfaceExpr* callable_value = null;
				EffectLexicalScope* callable_value_scope = producer_scope;
				lexical = effect_lexical_lookup(
					producer_scope, producer_name, work,
					&callable, &callable_scope, &callable_value, &callable_value_scope
				);
				if (lexical && !callable)
				{
					callable = callable_value;
					callable_scope = callable_value_scope;
				}
				effect_follow_callable_alias(
					&callable, &callable_scope, &lexical, &producer_name,
					work, 0
				);
				if (work.exhausted) return;
				if (!lexical)
				{
					if (producer_name == "superpose")
					{
						foreach (alternative : application.arguments)
						{
							collect_callable_producer_edges(
								calls, alternative, producer_scope,
								caller, callers, work, depth + 1
							);
						}
						return;
					}
					if (producer_name == "collapse" || producer_name == "typeOf"
						|| producer_name == "assertType") return;
					EffectCallGroup* group = effect_call_group(
						calls, producer_name, application.arguments.len
					);
					if (group) foreach (target : group.targets)
					{
						if (!effect_charge(work)) return;
						if (target >= calls.program.functions.len) continue;
						FunctionDecl* function = &calls.program.functions[target];
						EffectLexicalScope function_scope = {
							.names = function.parameters,
							.values = application.arguments,
							.value_default_scope = producer_scope,
							.calls = calls,
						};
						collect_callable_producer_edges(
							calls, function.body, &function_scope,
							caller, callers, work, depth + 1
						);
					}
					return;
				}
			}
			if (callable && callable.kind == SURFACE_LAMBDA)
			{
				EffectLexicalScope invocation_scope = {
					.parent = callable_scope,
					.names = callable.data.lambda.parameters,
					.values = application.arguments,
					.value_default_scope = producer_scope,
				};
				collect_callable_producer_edges(
					calls, callable.data.lambda.body, &invocation_scope,
					caller, callers, work, depth + 1
				);
			}
			else if (callable)
			{
				collect_callable_producer_edges(
					calls, callable, callable_scope, caller, callers, work, depth + 1
				);
			}
		case SURFACE_DEFINITION:
			DefinitionExpr* definition = &producer.data.definition;
			String[1] definition_name = { definition.name };
			SurfaceExpr*[1] definition_value = { definition.value };
			EffectLexicalScope definition_scope = {
				.parent = producer_scope,
				.names = definition_name[..],
				.values = definition_value[..],
				.value_default_scope = producer_scope,
			};
			collect_callable_producer_edges(
				calls, definition.body, &definition_scope,
				caller, callers, work, depth + 1
			);
		case SURFACE_MATCH:
			foreach (&arm : producer.data.match_expr.arms)
			{
				EffectLexicalScope arm_scope = {
					.parent = producer_scope,
					.names = arm.pattern.bindings,
					.pattern_scrutinee = producer.data.match_expr.scrutinee,
					.pattern_constructor = arm.pattern.constructor,
					.pattern_scope = producer_scope,
				};
				collect_callable_producer_edges(
					calls, arm.body, &arm_scope, caller, callers, work, depth + 1
				);
			}
		case SURFACE_PARALLEL:
			EffectLexicalScope parallel_scope = {
				.parent = producer_scope,
				.parallel_bindings = producer.data.parallel.bindings,
				.calls = calls,
			};
			collect_callable_producer_edges(
				calls, producer.data.parallel.result, &parallel_scope,
				caller, callers, work, depth + 1
			);
		case SURFACE_RESUME:
			collect_callable_producer_edges(
				calls, producer.data.resume.value, producer_scope,
				caller, callers, work, depth + 1
			);
		case SURFACE_HANDLER:
			foreach (&clause : producer.data.handler.clauses)
			{
				EffectLexicalScope clause_scope = {
					.parent = producer_scope,
					.names = clause.parameters,
					.calls = calls,
				};
				collect_callable_producer_edges(
					calls, clause.body, &clause_scope,
					caller, callers, work, depth + 1
				);
			}
			String[1] return_name = { producer.data.handler.return_clause.parameter };
			SurfaceExpr*[1] return_value = { producer.data.handler.handled };
			EffectLexicalScope return_scope = {
				.parent = producer_scope,
				.names = return_name[..],
				.values = return_value[..],
				.value_default_scope = producer_scope,
			};
			collect_callable_producer_edges(
				calls, producer.data.handler.return_clause.body, &return_scope,
				caller, callers, work, depth + 1
			);
		default:
	}
}


fn void collect_effect_call_edges(
	EffectCallIndex* calls,
	SurfaceExpr* expression,
	EffectLexicalScope* scope,
	usz caller,
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
			ApplicationExpr* application = &expression.data.application;
			collect_effect_call_edges(
				calls, application.callee, scope, caller, callers, work, depth + 1
			);
			foreach (argument : application.arguments)
				collect_effect_call_edges(
					calls, argument, scope, caller, callers, work, depth + 1
				);
			SurfaceExpr* applied_closure = null;
			EffectLexicalScope* closure_scope = scope;
			SurfaceExpr* applied_producer = null;
			EffectLexicalScope* producer_scope = scope;
			bool lexical_callee = false;
			String callee_name;
			if (application.callee && application.callee.kind == SURFACE_VARIABLE)
			{
				callee_name = application.callee.data.variable.name;
				lexical_callee = effect_lexical_lookup(
					scope, callee_name, work,
					&applied_closure, &closure_scope,
					&applied_producer, &producer_scope
				);
				if (lexical_callee && !applied_closure && applied_producer)
				{
					SurfaceExpr* resolved_callable = applied_producer;
					EffectLexicalScope* resolved_scope = producer_scope;
					bool resolved_lexical = true;
					effect_follow_callable_alias(
						&resolved_callable, &resolved_scope, &resolved_lexical,
						&callee_name, work, 0
					);
					if (resolved_callable && resolved_callable.kind == SURFACE_LAMBDA)
					{
						applied_closure = resolved_callable;
						closure_scope = resolved_scope;
						applied_producer = null;
					}
					else if (!resolved_lexical)
					{
						applied_producer = null;
						lexical_callee = false;
					}
					else
					{
						applied_producer = resolved_callable;
						producer_scope = resolved_scope;
					}
				}
				if (work.exhausted) return;
				if (!lexical_callee)
				{
					EffectCallGroup* group = effect_call_group(
						calls, callee_name, application.arguments.len
					);
					if (group)
					{
						bool specialize = false;
						foreach (argument : application.arguments)
						{
							if (effect_producer_contains_closure(
								calls, argument, scope, work, depth + 1
							))
							{
								specialize = true;
								break;
							}
						}
						foreach (target : group.targets)
						{
							if (!effect_charge(work)) break;
							if (specialize && target < calls.program.functions.len)
							{
								FunctionDecl* function = &calls.program.functions[target];
								EffectLexicalScope function_scope = {
									.names = function.parameters,
									.values = application.arguments,
									.value_default_scope = scope,
									.calls = calls,
								};
								collect_effect_call_edges(
									calls, function.body, &function_scope,
									caller, callers, work, depth + 1
								);
								continue;
							}
							if (!add_reverse_effect_edge(&callers[target], caller, work)) break;
						}
					}
				}
			}
			else if (application.callee && application.callee.kind == SURFACE_LAMBDA)
			{
				applied_closure = application.callee;
			}
			if (applied_closure && applied_closure.kind == SURFACE_LAMBDA)
			{
				EffectLexicalScope lambda_scope = {
					.parent = closure_scope,
					.names = applied_closure.data.lambda.parameters,
					.values = application.arguments,
					.value_default_scope = scope,
				};
				collect_effect_call_edges(
					calls, applied_closure.data.lambda.body, &lambda_scope,
					caller, callers, work, depth + 1
				);
			}
			else if (lexical_callee && applied_producer)
			{
				collect_callable_producer_edges(
					calls, applied_producer, producer_scope,
					caller, callers, work, depth + 1
				);
			}
		case SURFACE_EFFECT_OPERATION:
			foreach (argument : expression.data.effect_operation.arguments)
				collect_effect_call_edges(
					calls, argument, scope, caller, callers, work, depth + 1
				);
		case SURFACE_BINARY:
			collect_effect_call_edges(
				calls, expression.data.binary.left, scope, caller, callers, work, depth + 1
			);
			collect_effect_call_edges(
				calls, expression.data.binary.right, scope, caller, callers, work, depth + 1
			);
		case SURFACE_DEFINITION:
			DefinitionExpr* definition = &expression.data.definition;
			collect_effect_call_edges(
				calls, definition.value, scope, caller, callers, work, depth + 1
			);
			SurfaceExpr* bound_closure = null;
			EffectLexicalScope* bound_scope = scope;
			if (definition.value && definition.value.kind == SURFACE_LAMBDA)
			{
				bound_closure = definition.value;
			}
			else if (definition.value && definition.value.kind == SURFACE_VARIABLE)
			{
				(void)effect_lexical_lookup(
					scope, definition.value.data.variable.name, work,
					&bound_closure, &bound_scope
				);
			}
			String[1] definition_name = { definition.name };
			SurfaceExpr*[1] definition_closure = { bound_closure };
			EffectLexicalScope*[1] definition_capture = { bound_scope };
			SurfaceExpr*[1] definition_value = { definition.value };
			EffectLexicalScope definition_scope = {
				.parent = scope,
				.names = definition_name[..],
				.closures = definition_closure[..],
				.closure_scopes = definition_capture[..],
				.values = definition_value[..],
				.value_default_scope = scope,
			};
			collect_effect_call_edges(
				calls, definition.body, &definition_scope, caller, callers, work, depth + 1
			);
		case SURFACE_MATCH:
			collect_effect_call_edges(
				calls, expression.data.match_expr.scrutinee, scope,
				caller, callers, work, depth + 1
			);
			foreach (&arm : expression.data.match_expr.arms)
			{
				EffectLexicalScope arm_scope = {
					.parent = scope,
					.names = arm.pattern.bindings,
					.pattern_scrutinee = expression.data.match_expr.scrutinee,
					.pattern_constructor = arm.pattern.constructor,
					.pattern_scope = scope,
				};
				collect_effect_call_edges(
					calls, arm.body, &arm_scope, caller, callers, work, depth + 1
				);
			}
		case SURFACE_PARALLEL:
			ParallelExpr* parallel = &expression.data.parallel;
			foreach (&binding : parallel.bindings)
			{
				collect_effect_call_edges(
					calls, binding.value, scope, caller, callers, work, depth + 1
				);
			}
			EffectLexicalScope parallel_scope = {
				.parent = scope,
				.parallel_bindings = parallel.bindings,
			};
			collect_effect_call_edges(
				calls, parallel.result, &parallel_scope, caller, callers, work, depth + 1
			);
		case SURFACE_HANDLER:
			collect_effect_call_edges(
				calls, expression.data.handler.handled, scope,
				caller, callers, work, depth + 1
			);
			foreach (&clause : expression.data.handler.clauses)
			{
				EffectLexicalScope clause_scope = {
					.parent = scope,
					.names = clause.parameters,
				};
				collect_effect_call_edges(
					calls, clause.body, &clause_scope, caller, callers, work, depth + 1
				);
			}
			String[1] return_name = { expression.data.handler.return_clause.parameter };
			SurfaceExpr*[1] return_value = { expression.data.handler.handled };
			EffectLexicalScope return_scope = {
				.parent = scope,
				.names = return_name[..],
				.values = return_value[..],
				.value_default_scope = scope,
			};
			collect_effect_call_edges(
				calls, expression.data.handler.return_clause.body, &return_scope,
				caller, callers, work, depth + 1
			);
		case SURFACE_RESUME:
			collect_effect_call_edges(
				calls, expression.data.resume.value, scope,
				caller, callers, work, depth + 1
			);
		default:
	}
}


fn void collect_lambda_effect_info(
	EffectRegistry* registry,
	TypeRegistry* types,
	EffectCallIndex* calls,
	SurfaceExpr* expression,
	EffectLexicalScope* scope,
	List{EffectId}[] rows,
	SymbolKey*[] row_tails,
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
		LambdaExpr* lambda = &expression.data.lambda;
		EffectLexicalScope lambda_scope = {
			.parent = scope,
			.names = lambda.parameters,
		};
		List{EffectId} inferred;
		List{EffectId} asserted;
		inferred.init(allocator);
		asserted.init(allocator);
		SymbolKey* inferred_tail = null;
		collect_expression_effects(
			registry, calls, lambda.body, &lambda_scope, &inferred, rows,
			row_tails, &inferred_tail, diagnostics, allocator, work, depth + 1
		);
		if (lambda.effect_row)
		{
			foreach (effect_expr : lambda.effect_row.effects)
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
					if (effect_constructor_id(registry, asserted_effect)
						== effect_constructor_id(registry, *effect))
					{
						declared = true;
						if (asserted_effect != effect_constructor_id(registry, asserted_effect))
						{
							*effect = asserted_effect;
						}
					}
				}
				if (!declared && !lambda.effect_row.has_tail)
				{
					effects_add_diagnostic(
						diagnostics, allocator,
						"lambda 'does' row omits an inferred transitive effect",
						lambda.effect_row.span
					);
				}
			}
		}
		EffectId[] inferred_ids = inferred.to_array(allocator);
		EffectId[] asserted_ids = asserted.to_array(allocator);
		SymbolKey* asserted_tail = lambda.effect_row && lambda.effect_row.has_tail
			? &lambda.effect_row.tail : null;
		if (lambda.effect_row && inferred_tail
			&& (!asserted_tail || !symbol_key_equal(inferred_tail, asserted_tail)))
		{
			effects_add_diagnostic(
				diagnostics, allocator,
				"lambda 'does' row tail does not unify with its inferred open effect tail",
				lambda.effect_row.span
			);
		}
		lambdas.push({
			.span = expression.span,
			.inferred = normalize_effect_row(inferred_ids, inferred_tail, allocator),
			.asserted = normalize_effect_row(asserted_ids, asserted_tail, allocator),
			.has_assertion = lambda.effect_row != null,
		});
		alloc::free(allocator, inferred_ids);
		alloc::free(allocator, asserted_ids);
		inferred.free();
		asserted.free();
		collect_lambda_effect_info(
			registry, types, calls, lambda.body, &lambda_scope, rows, row_tails,
			lambdas, diagnostics, allocator, work, depth + 1
		);
		return;
	}
	switch (expression.kind)
	{
		case SURFACE_APPLICATION:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.application.callee, scope,
				rows, row_tails, lambdas, diagnostics, allocator, work, depth + 1
			);
			foreach (argument : expression.data.application.arguments)
				collect_lambda_effect_info(
					registry, types, calls, argument, scope, rows, row_tails,
					lambdas, diagnostics, allocator, work, depth + 1
				);
		case SURFACE_EFFECT_OPERATION:
			foreach (argument : expression.data.effect_operation.arguments)
				collect_lambda_effect_info(
					registry, types, calls, argument, scope, rows, row_tails,
					lambdas, diagnostics, allocator, work, depth + 1
				);
		case SURFACE_BINARY:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.binary.left, scope,
				rows, row_tails, lambdas, diagnostics, allocator, work, depth + 1
			);
			collect_lambda_effect_info(
				registry, types, calls, expression.data.binary.right, scope,
				rows, row_tails, lambdas, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_DEFINITION:
			DefinitionExpr* definition = &expression.data.definition;
			collect_lambda_effect_info(
				registry, types, calls, definition.value, scope, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
			);
			SurfaceExpr* bound_closure = null;
			EffectLexicalScope* bound_scope = scope;
			if (definition.value && definition.value.kind == SURFACE_LAMBDA)
			{
				bound_closure = definition.value;
			}
			else if (definition.value && definition.value.kind == SURFACE_VARIABLE)
			{
				(void)effect_lexical_lookup(
					scope, definition.value.data.variable.name, work,
					&bound_closure, &bound_scope
				);
			}
			String[1] definition_name = { definition.name };
			SurfaceExpr*[1] definition_closure = { bound_closure };
			EffectLexicalScope*[1] definition_capture = { bound_scope };
			SurfaceExpr*[1] definition_value = { definition.value };
			EffectLexicalScope definition_scope = {
				.parent = scope,
				.names = definition_name[..],
				.closures = definition_closure[..],
				.closure_scopes = definition_capture[..],
				.values = definition_value[..],
				.value_default_scope = scope,
			};
			collect_lambda_effect_info(
				registry, types, calls, definition.body, &definition_scope,
				rows, row_tails, lambdas, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_MATCH:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.match_expr.scrutinee, scope,
				rows, row_tails, lambdas, diagnostics, allocator, work, depth + 1
			);
			foreach (&arm : expression.data.match_expr.arms)
			{
				EffectLexicalScope arm_scope = {
					.parent = scope,
					.names = arm.pattern.bindings,
					.pattern_scrutinee = expression.data.match_expr.scrutinee,
					.pattern_constructor = arm.pattern.constructor,
					.pattern_scope = scope,
				};
				collect_lambda_effect_info(
					registry, types, calls, arm.body, &arm_scope, rows, row_tails,
					lambdas, diagnostics, allocator, work, depth + 1
				);
			}
		case SURFACE_PARALLEL:
			ParallelExpr* parallel = &expression.data.parallel;
			foreach (&binding : parallel.bindings)
			{
				collect_lambda_effect_info(
					registry, types, calls, binding.value, scope, rows, row_tails,
					lambdas, diagnostics, allocator, work, depth + 1
				);
			}
			EffectLexicalScope parallel_scope = {
				.parent = scope,
				.parallel_bindings = parallel.bindings,
			};
			collect_lambda_effect_info(
				registry, types, calls, parallel.result, &parallel_scope,
				rows, row_tails, lambdas, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_HANDLER:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.handler.handled, scope,
				rows, row_tails, lambdas, diagnostics, allocator, work, depth + 1
			);
			foreach (&clause : expression.data.handler.clauses)
			{
				EffectLexicalScope clause_scope = {
					.parent = scope,
					.names = clause.parameters,
					.handler_effect_name = clause.effect_name,
					.handler_operation_name = clause.operation_name,
					.calls = calls,
				};
				collect_lambda_effect_info(
					registry, types, calls, clause.body, &clause_scope,
					rows, row_tails, lambdas, diagnostics, allocator, work, depth + 1
				);
			}
			String[1] return_name = { expression.data.handler.return_clause.parameter };
			SurfaceExpr*[1] return_value = { expression.data.handler.handled };
			EffectLexicalScope return_scope = {
				.parent = scope,
				.names = return_name[..],
				.values = return_value[..],
				.value_default_scope = scope,
			};
			collect_lambda_effect_info(
				registry, types, calls, expression.data.handler.return_clause.body,
				&return_scope, rows, row_tails, lambdas, diagnostics, allocator,
				work, depth + 1
			);
		case SURFACE_RESUME:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.resume.value, scope,
				rows, row_tails, lambdas, diagnostics, allocator, work, depth + 1
			);
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
	EffectInferenceWork work = { .allocator = allocator, .max = max_steps };
	work.scopes.init(allocator);
	EffectCallIndex calls = build_effect_call_index(program, &diagnostics, allocator);
	defer calls.deinit();
	List{EffectId}[] rows = alloc::new_array(allocator, List{EffectId}, program.functions.len);
	List{usz}[] callers = alloc::new_array(allocator, List{usz}, program.functions.len);
	SymbolKey*[] inferred_tails = alloc::new_array(
		allocator, SymbolKey*, program.functions.len
	);
	SymbolKey*[] propagated_tails = alloc::new_array(
		allocator, SymbolKey*, program.functions.len
	);
	foreach (function_index, &function : program.functions)
	{
		if (function.effect_row && function.effect_row.has_tail)
		{
			propagated_tails[function_index] = &function.effect_row.tail;
		}
	}
	foreach (&row : rows) row.init(allocator);
	foreach (&edges : callers) edges.init(allocator);
	foreach (function_index, &function : program.functions)
	{
		EffectLexicalScope function_scope = {
			.names = function.parameters,
			.calls = &calls,
			.function_index_plus_one = (usz)function_index + 1,
		};
		collect_effect_call_edges(
			&calls, function.body, &function_scope, (usz)function_index, callers, &work
		);
		effect_work_clear_scopes(&work);
	}


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
		SymbolKey* collected_tail = null;
		EffectLexicalScope function_scope = {
			.names = program.functions[function_index].parameters,
			.calls = &calls,
			.function_index_plus_one = function_index + 1,
		};
		collect_expression_effects(
			registry, &calls, program.functions[function_index].body, &function_scope,
			&collected, rows, propagated_tails, &collected_tail, &diagnostics,
			allocator, &work, 0
		);
		effect_work_clear_scopes(&work);
		bool changed = false;
		foreach (effect : collected)
			if (inferred_row_add(&rows[function_index], effect, &work)) changed = true;
		collected.free();
		if (collected_tail && !inferred_tails[function_index])
		{
			inferred_tails[function_index] = collected_tail;
			if (!(program.functions[function_index].effect_row
				&& program.functions[function_index].effect_row.has_tail))
			{
				propagated_tails[function_index] = collected_tail;
			}
			changed = true;
		}
		else if (collected_tail && inferred_tails[function_index]
			&& !symbol_key_equal(inferred_tails[function_index], collected_tail))
		{
			effects_add_diagnostic(
				&diagnostics, allocator,
				"effect inference cannot unify transitive open row tails",
				program.functions[function_index].span
			);
		}
		if (!changed) continue;
		foreach (caller : callers[function_index])
		{
			if (!effect_charge(&work)) break;
			if (!queued[caller]) { queue.push(caller); queued[caller] = true; }
		}
	}
	queue.free();
	List{LambdaEffectInfo} lambdas;
	lambdas.init(allocator);
	foreach (function_index, &function : program.functions)
	{
		EffectLexicalScope function_scope = {
			.names = function.parameters,
			.calls = &calls,
			.function_index_plus_one = (usz)function_index + 1,
		};
		collect_lambda_effect_info(
			registry, types, &calls, function.body, &function_scope,
			rows, propagated_tails, &lambdas, &diagnostics, allocator, &work
		);
		effect_work_clear_scopes(&work);
	}
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
				if (!declared && !function.effect_row.has_tail)
				{
					effects_add_diagnostic(
						&diagnostics, allocator,
						"explicit 'does' row omits an inferred transitive effect",
						function.effect_row.span
					);
				}
			}
		}
		EffectId[] inferred_ids = rows[(usz)function_index].to_array(allocator);
		EffectId[] asserted_ids = asserted.to_array(allocator);
		SymbolKey* asserted_tail = function.effect_row && function.effect_row.has_tail
			? &function.effect_row.tail : null;
		if (function.effect_row && inferred_tails[function_index]
			&& (!asserted_tail
				|| !symbol_key_equal(inferred_tails[function_index], asserted_tail)))
		{
			effects_add_diagnostic(
				&diagnostics, allocator,
				"explicit 'does' row tail does not unify with its inferred open effect tail",
				function.effect_row.span
			);
		}
		analysis.methods[(usz)function_index] = {
			.function_index = (usz)function_index,
			.inferred = normalize_effect_row(
				inferred_ids, inferred_tails[function_index], allocator
			),
			.asserted = normalize_effect_row(asserted_ids, asserted_tail, allocator),
			.has_assertion = function.effect_row != null,
		};
		alloc::free(allocator, inferred_ids);
		alloc::free(allocator, asserted_ids);
		asserted.free();
		if (function.name == "main")
		{
			bool unhandled = inferred_tails[function_index] != null;
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
	foreach (&edges : callers) edges.free();
	alloc::free(allocator, rows);
	alloc::free(allocator, callers);
	alloc::free(allocator, inferred_tails);
	alloc::free(allocator, propagated_tails);
	alloc::free(allocator, queued);
	effect_work_clear_scopes(&work);
	work.scopes.free();
	analysis.diagnostics = diagnostics.to_array(allocator);
	analysis.effect_epoch = registry.epoch;
	diagnostics.free();
	return analysis;
}

