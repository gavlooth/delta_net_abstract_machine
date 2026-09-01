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
			.key = declaration_symbol_key(
				&declaration.key, &program.module_key, SYMBOL_EFFECT,
				declaration.name, declaration.parameters.len, "", allocator
			),
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
			EffectHostPolicy host_policy = declaration.name == "Console" || declaration.name == "IO"
				? EFFECT_HOST_EXTERNAL
				: declaration.name == "State" ? EFFECT_HOST_ORDERED : EFFECT_HOST_PURE;
			EffectOperationDescriptor registered = {
				.key = declaration_symbol_key(
					&operation.key, &descriptor.key.owner, SYMBOL_EFFECT_OPERATION,
					operation.name, operation.parameters.len, parent_signature, allocator
				),
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
	String name;
	usz arity;
	List{usz} targets;
}

struct EffectCallIndex
{
	Allocator allocator;
	List{EffectCallGroup} groups;
	sz[] buckets;
}

struct EffectInferenceWork
{
	usz used;
	usz max;
	bool exhausted;
}

fn ulong effect_call_hash(String name, usz arity) @private
{
	ulong hash = 1469598103934665603UL ^ (ulong)arity;
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
	if (!index.buckets.len) return null;
	usz mask = index.buckets.len - 1;
	usz slot = (usz)effect_call_hash(name, arity) & mask;
	for (usz probe = 0; probe < index.buckets.len; probe++)
	{
		sz group_index = index.buckets[slot];
		if (group_index < 0) return null;
		EffectCallGroup* group = &index.groups[group_index];
		if (group.name == name && group.arity == arity) return group;
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

fn EffectCallIndex build_effect_call_index(Program* program, Allocator allocator) @private
{
	EffectCallIndex index = { .allocator = allocator };
	index.groups.init(allocator);
	index.buckets = alloc::new_array(allocator, sz, (sz)effect_index_capacity(program.functions.len));
	foreach (&bucket : index.buckets) *bucket = -1;
	usz mask = index.buckets.len - 1;
	foreach (function_index, &function : program.functions)
	{
		usz slot = (usz)effect_call_hash(function.name, function.parameters.len) & mask;
		for (usz probe = 0; probe < index.buckets.len; probe++)
		{
			sz group_index = index.buckets[slot];
			if (group_index < 0)
			{
				EffectCallGroup group = { .name = function.name, .arity = function.parameters.len };
				group.targets.init(allocator);
				group.targets.push((usz)function_index);
				index.groups.push(group);
				index.buckets[slot] = index.groups.len() - 1;
				break;
			}
			EffectCallGroup* group = &index.groups[group_index];
			if (group.name == function.name && group.arity == function.parameters.len)
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

fn void collect_expression_effects(
	EffectRegistry* registry,
	EffectCallIndex* calls,
	SurfaceExpr* expression,
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
			collect_expression_effects(
				registry, calls, expression.data.application.callee, row,
				current_rows, current_tails, tail, diagnostics, allocator, work, depth + 1
			);
			foreach (argument : expression.data.application.arguments)
				collect_expression_effects(
					registry, calls, argument, row, current_rows, current_tails,
					tail, diagnostics, allocator, work, depth + 1
				);
			if (expression.data.application.callee
				&& expression.data.application.callee.kind == SURFACE_VARIABLE)
			{
				EffectCallGroup* group = effect_call_group(
					calls, expression.data.application.callee.data.variable.name,
					expression.data.application.arguments.len
				);
				if (group)
				{
					(void)effect_charge(work, (usz)group.targets.len());
					foreach (function_index : group.targets)
					{
						foreach (effect : current_rows[function_index])
							(void)inferred_row_add(row, effect, work);
						inferred_row_tail(
							tail, current_tails[function_index], diagnostics,
							allocator, expression.span
						);
					}
				}
			}
			if (expression.data.application.callee
				&& expression.data.application.callee.kind == SURFACE_LAMBDA)
			{
				LambdaExpr* lambda = &expression.data.application.callee.data.lambda;
				collect_expression_effects(
					registry, calls, lambda.body, row, current_rows, current_tails,
					tail, diagnostics, allocator, work, depth + 1
				);
				if (lambda.effect_row && lambda.effect_row.has_tail)
				{
					inferred_row_tail(
						tail, &lambda.effect_row.tail, diagnostics, allocator, expression.span
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
					registry, calls, argument, row, current_rows, current_tails,
					tail, diagnostics, allocator, work, depth + 1
				);
		case SURFACE_BINARY:
			collect_expression_effects(
				registry, calls, expression.data.binary.left, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
			collect_expression_effects(
				registry, calls, expression.data.binary.right, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_DEFINITION:
			collect_expression_effects(
				registry, calls, expression.data.definition.value, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
			collect_expression_effects(
				registry, calls, expression.data.definition.body, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_MATCH:
			collect_expression_effects(
				registry, calls, expression.data.match_expr.scrutinee, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
			foreach (&arm : expression.data.match_expr.arms)
				collect_expression_effects(
					registry, calls, arm.body, row, current_rows, current_tails,
					tail, diagnostics, allocator, work, depth + 1
				);
		case SURFACE_PARALLEL:
			foreach (&binding : expression.data.parallel.bindings)
				collect_expression_effects(
					registry, calls, binding.value, row, current_rows, current_tails,
					tail, diagnostics, allocator, work, depth + 1
				);
			collect_expression_effects(
				registry, calls, expression.data.parallel.result, row, current_rows,
				current_tails, tail, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_HANDLER:
			List{EffectId} handled;
			handled.init(allocator);
			SymbolKey* handled_tail = null;
			collect_expression_effects(
				registry, calls, expression.data.handler.handled, &handled, current_rows,
				current_tails, &handled_tail, diagnostics, allocator, work, depth + 1
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
				collect_expression_effects(
					registry, calls, clause.body, row, current_rows, current_tails,
					tail, diagnostics, allocator, work, depth + 1
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
			collect_expression_effects(
				registry, calls, expression.data.handler.return_clause.body, row,
				current_rows, current_tails, tail, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_RESUME:
			collect_expression_effects(
				registry, calls, expression.data.resume.value, row, current_rows,
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


fn void collect_effect_call_edges(
	EffectCallIndex* calls,
	SurfaceExpr* expression,
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
			collect_effect_call_edges(calls, expression.data.application.callee, caller, callers, work, depth + 1);
			foreach (argument : expression.data.application.arguments)
				collect_effect_call_edges(calls, argument, caller, callers, work, depth + 1);
			if (expression.data.application.callee && expression.data.application.callee.kind == SURFACE_VARIABLE)
			{
				EffectCallGroup* group = effect_call_group(
					calls, expression.data.application.callee.data.variable.name,
					expression.data.application.arguments.len
				);
				if (group) foreach (target : group.targets)
				{
					if (!add_reverse_effect_edge(&callers[target], caller, work)) break;
				}
			}
		case SURFACE_EFFECT_OPERATION:
			foreach (argument : expression.data.effect_operation.arguments)
				collect_effect_call_edges(calls, argument, caller, callers, work, depth + 1);
		case SURFACE_BINARY:
			collect_effect_call_edges(calls, expression.data.binary.left, caller, callers, work, depth + 1);
			collect_effect_call_edges(calls, expression.data.binary.right, caller, callers, work, depth + 1);
		case SURFACE_DEFINITION:
			collect_effect_call_edges(calls, expression.data.definition.value, caller, callers, work, depth + 1);
			collect_effect_call_edges(calls, expression.data.definition.body, caller, callers, work, depth + 1);
		case SURFACE_MATCH:
			collect_effect_call_edges(calls, expression.data.match_expr.scrutinee, caller, callers, work, depth + 1);
			foreach (&arm : expression.data.match_expr.arms)
				collect_effect_call_edges(calls, arm.body, caller, callers, work, depth + 1);
		case SURFACE_PARALLEL:
			foreach (&binding : expression.data.parallel.bindings)
				collect_effect_call_edges(calls, binding.value, caller, callers, work, depth + 1);
			collect_effect_call_edges(calls, expression.data.parallel.result, caller, callers, work, depth + 1);
		case SURFACE_HANDLER:
			collect_effect_call_edges(calls, expression.data.handler.handled, caller, callers, work, depth + 1);
			foreach (&clause : expression.data.handler.clauses)
				collect_effect_call_edges(calls, clause.body, caller, callers, work, depth + 1);
			collect_effect_call_edges(calls, expression.data.handler.return_clause.body, caller, callers, work, depth + 1);
		case SURFACE_RESUME:
			collect_effect_call_edges(calls, expression.data.resume.value, caller, callers, work, depth + 1);
		default:
	}
}


fn void collect_lambda_effect_info(
	EffectRegistry* registry,
	TypeRegistry* types,
	EffectCallIndex* calls,
	SurfaceExpr* expression,
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
		List{EffectId} inferred;
		List{EffectId} asserted;
		inferred.init(allocator);
		asserted.init(allocator);
		SymbolKey* inferred_tail = null;
		collect_expression_effects(
			registry, calls, expression.data.lambda.body, &inferred, rows,
			row_tails, &inferred_tail, diagnostics, allocator, work, depth + 1
		);
		if (expression.data.lambda.effect_row)
		{
			foreach (effect_expr : expression.data.lambda.effect_row.effects)
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
				if (!declared && !expression.data.lambda.effect_row.has_tail)
				{
					effects_add_diagnostic(
						diagnostics, allocator,
						"lambda 'does' row omits an inferred transitive effect",
						expression.data.lambda.effect_row.span
					);
				}
			}
		}
		EffectId[] inferred_ids = inferred.to_array(allocator);
		EffectId[] asserted_ids = asserted.to_array(allocator);
		SymbolKey* asserted_tail = expression.data.lambda.effect_row
			&& expression.data.lambda.effect_row.has_tail
			? &expression.data.lambda.effect_row.tail : null;
		if (expression.data.lambda.effect_row && inferred_tail
			&& (!asserted_tail || !symbol_key_equal(inferred_tail, asserted_tail)))
		{
			effects_add_diagnostic(
				diagnostics, allocator,
				"lambda 'does' row tail does not unify with its inferred open effect tail",
				expression.data.lambda.effect_row.span
			);
		}
		lambdas.push({
			.span = expression.span,
			.inferred = normalize_effect_row(inferred_ids, inferred_tail, allocator),
			.asserted = normalize_effect_row(asserted_ids, asserted_tail, allocator),
			.has_assertion = expression.data.lambda.effect_row != null,
		});
		alloc::free(allocator, inferred_ids);
		alloc::free(allocator, asserted_ids);
		inferred.free();
		asserted.free();
		collect_lambda_effect_info(
			registry, types, calls, expression.data.lambda.body, rows, row_tails,
			lambdas, diagnostics, allocator, work, depth + 1
		);
		return;
	}
	switch (expression.kind)
	{
		case SURFACE_APPLICATION:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.application.callee, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
			);
			foreach (argument : expression.data.application.arguments)
				collect_lambda_effect_info(
					registry, types, calls, argument, rows, row_tails,
					lambdas, diagnostics, allocator, work, depth + 1
				);
		case SURFACE_EFFECT_OPERATION:
			foreach (argument : expression.data.effect_operation.arguments)
				collect_lambda_effect_info(
					registry, types, calls, argument, rows, row_tails,
					lambdas, diagnostics, allocator, work, depth + 1
				);
		case SURFACE_BINARY:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.binary.left, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
			);
			collect_lambda_effect_info(
				registry, types, calls, expression.data.binary.right, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_DEFINITION:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.definition.value, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
			);
			collect_lambda_effect_info(
				registry, types, calls, expression.data.definition.body, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_MATCH:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.match_expr.scrutinee, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
			);
			foreach (&arm : expression.data.match_expr.arms)
				collect_lambda_effect_info(
					registry, types, calls, arm.body, rows, row_tails,
					lambdas, diagnostics, allocator, work, depth + 1
				);
		case SURFACE_PARALLEL:
			foreach (&binding : expression.data.parallel.bindings)
				collect_lambda_effect_info(
					registry, types, calls, binding.value, rows, row_tails,
					lambdas, diagnostics, allocator, work, depth + 1
				);
			collect_lambda_effect_info(
				registry, types, calls, expression.data.parallel.result, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_HANDLER:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.handler.handled, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
			);
			foreach (&clause : expression.data.handler.clauses)
				collect_lambda_effect_info(
					registry, types, calls, clause.body, rows, row_tails,
					lambdas, diagnostics, allocator, work, depth + 1
				);
			collect_lambda_effect_info(
				registry, types, calls, expression.data.handler.return_clause.body, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
			);
		case SURFACE_RESUME:
			collect_lambda_effect_info(
				registry, types, calls, expression.data.resume.value, rows, row_tails,
				lambdas, diagnostics, allocator, work, depth + 1
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
	EffectInferenceWork work = { .max = max_steps };
	EffectCallIndex calls = build_effect_call_index(program, allocator);
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
		collect_effect_call_edges(&calls, function.body, (usz)function_index, callers, &work);


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
		collect_expression_effects(
			registry, &calls, program.functions[function_index].body, &collected,
			rows, propagated_tails, &collected_tail, &diagnostics, allocator, &work, 0
		);
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
	foreach (&function : program.functions)
		collect_lambda_effect_info(
			registry, types, &calls, function.body, rows, propagated_tails,
			&lambdas, &diagnostics, allocator, &work
		);
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
	analysis.diagnostics = diagnostics.to_array(allocator);
	analysis.effect_epoch = registry.epoch;
	diagnostics.free();
	return analysis;
}

