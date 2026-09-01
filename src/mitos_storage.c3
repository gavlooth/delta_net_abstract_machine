module delta_net_abstract_machine::mitos_storage;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::stable_slot_arena;
import std::thread;
import std::atomic::types;

alias StorageId = ulong;

const StorageHandle INVALID_STORAGE_HANDLE = { .id = stable_slot_arena::INVALID_SLOT_ID };
const LayoutHandle INVALID_LAYOUT_HANDLE = { .id = stable_slot_arena::INVALID_SLOT_ID };
const usz MITOS_STORAGE_DEFAULT_MAX_RECORDS = 1_000_000;
const usz MITOS_STORAGE_DEFAULT_MAX_BYTES = 64 * 1024 * 1024;
const usz MITOS_STORAGE_MAX_RUNTIME_CONTROLS = 4096;
const usz STORAGE_CONTROL_SLOT_BITS = 12;
const ulong STORAGE_CONTROL_SLOT_MASK = (ulong)MITOS_STORAGE_MAX_RUNTIME_CONTROLS - 1;
const ulong STORAGE_CONTROL_MAX_GENERATION = ulong::max >> STORAGE_CONTROL_SLOT_BITS;
const ulong STORAGE_GATE_CLOSED = (ulong)1 << 63;
const ulong STORAGE_GATE_DESTROYED = (ulong)1 << 62;
const ulong STORAGE_GATE_OPEN = (ulong)1 << 61;
const ulong STORAGE_GATE_COUNT = STORAGE_GATE_OPEN - 1;
const ulong STORAGE_OWNER_AUTH_HIGH_DOMAIN = 0x6f776e65722d6869;
const ulong STORAGE_OWNER_AUTH_LOW_DOMAIN = 0x6f776e65722d6c6f;
const ulong STORAGE_VIEW_AUTH_HIGH_DOMAIN = 0x766965772d2d6869;
const ulong STORAGE_VIEW_AUTH_LOW_DOMAIN = 0x766965772d2d6c6f;

struct LayoutHandle
{
	ulong runtime_identity;
	StorageId id;
	ulong generation;
}

/** An authenticated, generation-checked owner lease. Copies alias one lease. */
struct StorageHandle
{
	ulong runtime_identity;
	StorageId id;
	ulong generation;
	ulong authentication_high;
	ulong authentication_low;
}

/** An authenticated, generation-checked view lease. Bounds remain runtime-private. */
struct StorageView
{
	ulong runtime_identity;
	StorageId id;
	ulong generation;
	ulong authentication_high;
	ulong authentication_low;
}

enum StorageError : char
{
	STORAGE_OK,
	STORAGE_NOT_INITIALIZED,
	STORAGE_INVALID_LAYOUT,
	STORAGE_INVALID_HANDLE,
	STORAGE_STALE_VIEW,
	STORAGE_POLICY_VIOLATION,
	STORAGE_BOUNDS,
	STORAGE_ALIGNMENT,
	STORAGE_OVERFLOW,
	STORAGE_LIMIT,
	STORAGE_BUSY,
	STORAGE_ALREADY_RELEASED,
}

struct StorageHandleResult
{
	StorageError error;
	StorageHandle handle;
}

struct LayoutHandleResult
{
	StorageError error;
	LayoutHandle handle;
}

struct StorageViewResult
{
	StorageError error;
	StorageView view;
}

/** Validated, pointer-free metadata for graph attachment and validation. */
struct StorageMetadata
{
	mitos::TypeId type_id;
	mitos::CopyPolicy copy_policy;
	usz byte_length;
	usz alignment;
	usz stride;
	usz element_size;
	usz owner_count;
	mitos::LayoutKind kind;
	mitos::TypeId element_type;
}

struct RuntimeLayout @private
{
	mitos::TypeId type_id;
	mitos::LayoutKind kind;
	mitos::CopyPolicy copy_policy;
	bool sized;
	usz size;
	usz alignment;
	usz stride;
	mitos::TypeId element_type;
	mitos::SymbolKey stable_key;
}

struct RuntimeStorage @private
{
	LayoutHandle layout;
	mitos::CopyPolicy copy_policy;
	char[] bytes;
	usz alignment;
	usz stride;
	usz element_size;
	usz owner_count;
	usz view_count;
	usz read_count;
}

struct RuntimeOwner @private
{
	stable_slot_arena::SlotRef record;
}

struct RuntimeView @private
{
	stable_slot_arena::SlotRef record;
	LayoutHandle layout;
	usz offset;
	usz count;
	usz stride;
	usz element_size;
}

struct StorageState @private
{
	ulong identity;
	Allocator allocator;
	StableSlotArena{RuntimeLayout} layouts;
	StableSlotArena{RuntimeStorage} records;
	StableSlotArena{RuntimeOwner} owners;
	StableSlotArena{RuntimeView} views;
	LayoutHandle[] type_layouts;
	Mutex mutex;
	usz max_records;
	usz max_bytes;
	usz retained_control_bytes;
	usz owned_bytes;
	usz reserved_records;
	usz reserved_bytes;
	usz reserved_control_bytes;
	ulong capability_secret_high;
	ulong capability_secret_low;
	usz pending_bytes;
}

/** Fixed-capacity lifecycle slot. Public aliases retain only its coordinates. */
struct StorageControl @private
{
	Atomic{ulong} entrant_gate;
	Atomic{ulong} generation;
	StorageState* state;
	ulong identity;
}

/*
 * Controls live in a bounded static table. Runtime aliases carry a packed
 * 64-bit slot/generation coordinate plus an independently generated identity,
 * so validation never dereferences caller-controlled memory and never scans
 * unrelated runtimes.
 */
StorageControl[MITOS_STORAGE_MAX_RUNTIME_CONTROLS] storage_controls @private;

/** Copyable public wrapper with an integer, non-dereferenceable coordinate. */
struct StorageRuntime
{
	ulong control_coordinate;
	ulong identity;
}

fn bool LayoutHandle.equals(self, LayoutHandle other) @operator(==) @inline
{
	return self.runtime_identity == other.runtime_identity
		&& self.id == other.id && self.generation == other.generation;
}

fn bool StorageHandle.equals(self, StorageHandle other) @operator(==) @inline
{
	return self.runtime_identity == other.runtime_identity
		&& self.id == other.id && self.generation == other.generation
		&& self.authentication_high == other.authentication_high
		&& self.authentication_low == other.authentication_low;
}

fn ulong storage_control_coordinate(usz slot, ulong generation) @private
{
	return (generation << STORAGE_CONTROL_SLOT_BITS) | (ulong)slot;
}

fn bool storage_control_coordinates(
	StorageRuntime* runtime,
	usz* slot,
	ulong* generation
) @private
{
	if (!runtime || !runtime.control_coordinate || !runtime.identity) return false;
	ulong coordinate = runtime.control_coordinate;
	usz decoded_slot = (usz)(coordinate & STORAGE_CONTROL_SLOT_MASK);
	ulong decoded_generation = coordinate >> STORAGE_CONTROL_SLOT_BITS;
	if (decoded_slot >= MITOS_STORAGE_MAX_RUNTIME_CONTROLS || !decoded_generation)
	{
		return false;
	}
	*slot = decoded_slot;
	*generation = decoded_generation;
	return true;
}

fn bool storage_control_enter(StorageControl* control) @private
{
	for (;;)
	{
		ulong current = control.entrant_gate.load();
		if (!(current & STORAGE_GATE_OPEN)
			|| current & STORAGE_GATE_CLOSED
			|| (current & STORAGE_GATE_COUNT) == STORAGE_GATE_COUNT) return false;
		ulong expected = current;
		if (control.entrant_gate.compare_exchange(&expected, current + 1)) return true;
	}
}

fn void storage_leave(StorageControl* control) @private
{
	(void)control.entrant_gate.sub(1);
}

fn bool storage_control_close_entered(StorageControl* control) @private
{
	for (;;)
	{
		ulong current = control.entrant_gate.load();
		if (!(current & STORAGE_GATE_OPEN) || current & STORAGE_GATE_CLOSED)
		{
			storage_leave(control);
			return false;
		}
		ulong expected = current;
		if (!control.entrant_gate.compare_exchange(
			&expected, current | STORAGE_GATE_CLOSED
		)) continue;
		storage_leave(control);
		while ((control.entrant_gate.load() & STORAGE_GATE_COUNT) != 0)
		{
			thread::yield();
		}
		return true;
	}
}

fn StorageControl* storage_allocate_control(
	ulong identity,
	usz* allocated_slot,
	ulong* allocated_generation
) @private
{
	for (usz slot = 0; slot < MITOS_STORAGE_MAX_RUNTIME_CONTROLS; slot++)
	{
		StorageControl* control = &storage_controls[slot];
		ulong current = control.entrant_gate.load();
		if (current != 0
			&& current != (STORAGE_GATE_CLOSED | STORAGE_GATE_DESTROYED)) continue;
		ulong expected = current;
		if (!control.entrant_gate.compare_exchange(&expected, STORAGE_GATE_CLOSED))
		{
			continue;
		}
		ulong prior_generation = control.generation.load();
		if (prior_generation >= STORAGE_CONTROL_MAX_GENERATION)
		{
			control.entrant_gate.store(
				STORAGE_GATE_CLOSED | STORAGE_GATE_DESTROYED
			);
			continue;
		}
		ulong generation = prior_generation + 1;
		control.generation.store(generation);
		control.identity = identity;
		control.state = null;
		*allocated_slot = slot;
		*allocated_generation = generation;
		return control;
	}
	return null;
}

fn void storage_recycle_control(StorageControl* control) @private
{
	control.state = null;
	control.identity = 0;
	control.entrant_gate.store(STORAGE_GATE_CLOSED | STORAGE_GATE_DESTROYED);
}

fn StorageState* storage_enter(
	StorageRuntime* runtime,
	StorageControl** entered_control
) @private
{
	usz slot;
	ulong generation;
	if (!storage_control_coordinates(runtime, &slot, &generation)) return null;
	StorageControl* control = &storage_controls[slot];
	if (!storage_control_enter(control)) return null;
	StorageState* state = control.state;
	if (control.generation.load() != generation
		|| control.identity != runtime.identity
		|| !state || state.identity != runtime.identity)
	{
		storage_leave(control);
		return null;
	}
	if (entered_control) *entered_control = control;
	return state;
}

fn StorageControl* storage_detach_control(StorageRuntime* runtime) @private
{
	StorageControl* control;
	if (!storage_enter(runtime, &control)) return null;
	if (!storage_control_close_entered(control)) return null;
	return control;
}

fn stable_slot_arena::SlotRef layout_slot(LayoutHandle handle) @private
{
	return { .id = handle.id, .generation = handle.generation };
}

fn stable_slot_arena::SlotRef owner_slot(StorageHandle handle) @private
{
	return { .id = handle.id, .generation = handle.generation };
}

fn stable_slot_arena::SlotRef view_slot(StorageView view) @private
{
	return { .id = view.id, .generation = view.generation };
}

fn ulong storage_rotate_left(ulong value, uint shift) @private @inline
{
	return (value << shift) | (value >> (64 - shift));
}

fn void storage_sip_round(ulong* v0, ulong* v1, ulong* v2, ulong* v3) @private @inline
{
	*v0 += *v1;
	*v1 = storage_rotate_left(*v1, 13);
	*v1 ^= *v0;
	*v0 = storage_rotate_left(*v0, 32);
	*v2 += *v3;
	*v3 = storage_rotate_left(*v3, 16);
	*v3 ^= *v2;
	*v0 += *v3;
	*v3 = storage_rotate_left(*v3, 21);
	*v3 ^= *v0;
	*v2 += *v1;
	*v1 = storage_rotate_left(*v1, 17);
	*v1 ^= *v2;
	*v2 = storage_rotate_left(*v2, 32);
}

/** SipHash-2-4 over the fixed capability tuple, keyed by runtime-only entropy. */
fn ulong storage_capability_mac(
	StorageState* state,
	stable_slot_arena::SlotRef reference,
	ulong domain
) @private
{
	ulong v0 = state.capability_secret_high ^ 0x736f6d6570736575;
	ulong v1 = state.capability_secret_low ^ 0x646f72616e646f6d;
	ulong v2 = state.capability_secret_high ^ 0x6c7967656e657261;
	ulong v3 = state.capability_secret_low ^ 0x7465646279746573;
	ulong[3] words = { domain, reference.id, reference.generation };
	foreach (word : words)
	{
		v3 ^= word;
		storage_sip_round(&v0, &v1, &v2, &v3);
		storage_sip_round(&v0, &v1, &v2, &v3);
		v0 ^= word;
	}
	ulong final_word = (ulong)24 << 56;
	v3 ^= final_word;
	storage_sip_round(&v0, &v1, &v2, &v3);
	storage_sip_round(&v0, &v1, &v2, &v3);
	v0 ^= final_word;
	v2 ^= 0xff;
	storage_sip_round(&v0, &v1, &v2, &v3);
	storage_sip_round(&v0, &v1, &v2, &v3);
	storage_sip_round(&v0, &v1, &v2, &v3);
	storage_sip_round(&v0, &v1, &v2, &v3);
	return v0 ^ v1 ^ v2 ^ v3;
}

fn bool storage_capability_matches(
	StorageState* state,
	stable_slot_arena::SlotRef reference,
	ulong domain_high,
	ulong domain_low,
	ulong authentication_high,
	ulong authentication_low
) @private
{
	ulong expected_high = storage_capability_mac(state, reference, domain_high);
	ulong expected_low = storage_capability_mac(state, reference, domain_low);
	return ((expected_high ^ authentication_high)
		| (expected_low ^ authentication_low)) == 0;
}

fn LayoutHandle layout_handle(StorageState* state, stable_slot_arena::SlotRef reference) @private
{
	return {
		.runtime_identity = state.identity,
		.id = reference.id,
		.generation = reference.generation,
	};
}

fn StorageHandle storage_handle(StorageState* state, stable_slot_arena::SlotRef reference) @private
{
	return {
		.runtime_identity = state.identity,
		.id = reference.id,
		.generation = reference.generation,
		.authentication_high = storage_capability_mac(
			state, reference, STORAGE_OWNER_AUTH_HIGH_DOMAIN
		),
		.authentication_low = storage_capability_mac(
			state, reference, STORAGE_OWNER_AUTH_LOW_DOMAIN
		),
	};
}

fn StorageView storage_view(StorageState* state, stable_slot_arena::SlotRef reference) @private
{
	return {
		.runtime_identity = state.identity,
		.id = reference.id,
		.generation = reference.generation,
		.authentication_high = storage_capability_mac(
			state, reference, STORAGE_VIEW_AUTH_HIGH_DOMAIN
		),
		.authentication_low = storage_capability_mac(
			state, reference, STORAGE_VIEW_AUTH_LOW_DOMAIN
		),
	};
}

fn void storage_lock(StorageState* state) @private
{
	if (catch state.mutex.lock()) unreachable("failed to lock storage runtime");
}

fn void storage_unlock(StorageState* state) @private
{
	state.mutex.unlock();
}

fn bool runtime_owns_layout(StorageState* state, LayoutHandle handle) @private
{
	return state && handle.runtime_identity == state.identity
		&& state.layouts.contains_ref(layout_slot(handle));
}

fn RuntimeStorage* owner_record(
	StorageState* state,
	StorageHandle handle,
	stable_slot_arena::SlotRef* record_reference = null
) @private
{
	stable_slot_arena::SlotRef reference = owner_slot(handle);
	if (!state || handle.runtime_identity != state.identity
		|| !storage_capability_matches(
			state, reference,
			STORAGE_OWNER_AUTH_HIGH_DOMAIN, STORAGE_OWNER_AUTH_LOW_DOMAIN,
			handle.authentication_high, handle.authentication_low
		)
		|| !state.owners.contains_ref(reference)) return null;
	RuntimeOwner owner = state.owners.get(reference);
	if (!state.records.contains_ref(owner.record)) return null;
	if (record_reference) *record_reference = owner.record;
	return state.records.get_ref(owner.record);
}

fn RuntimeView* runtime_view(
	StorageState* state,
	StorageView view,
	RuntimeStorage** record = null
) @private
{
	stable_slot_arena::SlotRef reference = view_slot(view);
	if (!state || view.runtime_identity != state.identity
		|| !storage_capability_matches(
			state, reference,
			STORAGE_VIEW_AUTH_HIGH_DOMAIN, STORAGE_VIEW_AUTH_LOW_DOMAIN,
			view.authentication_high, view.authentication_low
		)
		|| !state.views.contains_ref(reference)) return null;
	RuntimeView* lease = state.views.get_ref(reference);
	if (!state.records.contains_ref(lease.record)) return null;
	RuntimeStorage* backing = state.records.get_ref(lease.record);
	if (backing.layout != lease.layout) return null;
	if (record) *record = backing;
	return lease;
}

fn bool checked_multiply(usz left, usz right, usz* result) @private
{
	if (left && right > usz::max / left) return false;
	*result = left * right;
	return true;
}

fn bool checked_add(usz left, usz right, usz* result) @private
{
	if (right > usz::max - left) return false;
	*result = left + right;
	return true;
}

fn bool storage_arena_push_delta(
	stable_slot_arena::SlotId next_id,
	stable_slot_arena::SlotId free_head,
	sz pages_size,
	sz pages_capacity,
	usz page_size,
	usz* delta
) @private
{
	*delta = 0;
	if (free_head != stable_slot_arena::INVALID_SLOT_ID
		|| (usz)next_id % stable_slot_arena::STABLE_SLOT_PAGE_CAPACITY{RuntimeLayout} != 0) return true;
	if (pages_size < 0 || pages_capacity < pages_size) return false;
	usz pointer_bytes = 0;
	if (pages_size == pages_capacity)
	{
		usz old_capacity = (usz)pages_capacity;
		usz new_capacity;
		if (!old_capacity)
		{
			new_capacity = 16;
		}
		else
		{
			if (old_capacity > (usz)sz::max / 2) return false;
			new_capacity = old_capacity * 2;
		}
		if (!checked_multiply(
			new_capacity - old_capacity, (usz)void*::size, &pointer_bytes
		)) return false;
	}
	return checked_add(page_size, pointer_bytes, delta);
}

fn bool storage_layout_push_delta(StorageState* state, usz* delta) @private
{
	return storage_arena_push_delta(
		state.layouts.next_id, state.layouts.free_head,
		state.layouts.pages.size, state.layouts.pages.capacity,
		(usz)stable_slot_arena::StableSlotPage{RuntimeLayout}::size, delta
	);
}

fn bool storage_record_push_delta(StorageState* state, usz* delta) @private
{
	return storage_arena_push_delta(
		state.records.next_id, state.records.free_head,
		state.records.pages.size, state.records.pages.capacity,
		(usz)stable_slot_arena::StableSlotPage{RuntimeStorage}::size, delta
	);
}

fn bool storage_owner_push_delta(StorageState* state, usz* delta) @private
{
	return storage_arena_push_delta(
		state.owners.next_id, state.owners.free_head,
		state.owners.pages.size, state.owners.pages.capacity,
		(usz)stable_slot_arena::StableSlotPage{RuntimeOwner}::size, delta
	);
}

fn bool storage_view_push_delta(StorageState* state, usz* delta) @private
{
	return storage_arena_push_delta(
		state.views.next_id, state.views.free_head,
		state.views.pages.size, state.views.pages.capacity,
		(usz)stable_slot_arena::StableSlotPage{RuntimeView}::size, delta
	);
}

fn bool storage_retained_bytes_unlocked(StorageState* state, usz* retained) @private
{
	return checked_add(state.retained_control_bytes, state.owned_bytes, retained)
		&& checked_add(*retained, state.pending_bytes, retained);
}


fn bool storage_fits_byte_quota(
	StorageState* state,
	usz additional_payload,
	usz additional_control
) @private
{
	usz usage;
	if (!storage_retained_bytes_unlocked(state, &usage)
		|| state.pending_bytes > state.reserved_bytes
		|| !checked_add(usage, state.reserved_bytes - state.pending_bytes, &usage)
		|| !checked_add(usage, state.reserved_control_bytes, &usage)
		|| !checked_add(usage, additional_payload, &usage)
		|| !checked_add(usage, additional_control, &usage)) return false;
	return usage <= state.max_bytes;
}

fn bool new_storage_capability_secret(
	ulong identity,
	ulong* secret_high,
	ulong* secret_low
) @private
{
	for (usz attempt = 0; attempt < 8; attempt++)
	{
		ulong[2] secret;
		if (!mitos::fill_secure_entropy(((char*)&secret)[:ulong[2]::size])) return false;
		if (!secret[0] || !secret[1] || secret[0] == secret[1]
			|| secret[0] == identity || secret[1] == identity) continue;
		*secret_high = secret[0];
		*secret_low = secret[1];
		return true;
	}
	return false;
}

/**
 * max_records bounds every record/owner/view arena slot. Outstanding payload
 * reservations hold two slots each because publication creates one record and
 * its initial owner. Layout count is independently bounded by max_types.
 */
fn bool storage_can_add_slots(StorageState* state, usz additional) @private
{
	usz usage = state.records.len();
	usz reserved_slots;
	if (!checked_add(usage, state.owners.len(), &usage)
		|| !checked_add(usage, state.views.len(), &usage)
		|| !checked_multiply(state.reserved_records, 2, &reserved_slots)
		|| !checked_add(usage, reserved_slots, &usage)) return false;
	return usage <= state.max_records && additional <= state.max_records - usage;
}

fn bool power_of_two(usz value) @private
{
	return value && (value & (value - 1)) == 0;
}

fn StorageRuntime* StorageRuntime.init(
	&self,
	Allocator allocator = mem,
	usz max_types = mitos::MITOS_DEFAULT_MAX_TYPES,
	usz max_records = MITOS_STORAGE_DEFAULT_MAX_RECORDS,
	usz max_bytes = MITOS_STORAGE_DEFAULT_MAX_BYTES
)
{
	*self = { };
	if (!allocator || !max_types || max_types >= (usz)sz::max || !max_records || !max_bytes)
	{
		return self;
	}
	usz type_layout_bytes;
	usz initial_retained;
	if (!checked_multiply(max_types + 1, (usz)LayoutHandle::size, &type_layout_bytes)
		|| !checked_add((usz)StorageState::size, type_layout_bytes, &initial_retained)
		|| initial_retained > max_bytes) return self;
	ulong identity = mitos::new_runtime_identity();
	ulong secret_high;
	ulong secret_low;
	if (!identity || !new_storage_capability_secret(identity, &secret_high, &secret_low))
	{
		return self;
	}
	usz control_slot;
	ulong control_generation;
	StorageControl* control = storage_allocate_control(
		identity, &control_slot, &control_generation
	);
	if (!control) return self;
	StorageState* state = alloc::new(allocator, StorageState, {
		.identity = identity,
		.allocator = allocator,
		.max_records = max_records,
		.max_bytes = max_bytes,
		.retained_control_bytes = initial_retained,
		.capability_secret_high = secret_high,
		.capability_secret_low = secret_low,
	});
	state.layouts.init(allocator);
	state.records.init(allocator);
	state.owners.init(allocator);
	state.views.init(allocator);
	state.type_layouts = alloc::new_array(allocator, LayoutHandle, (sz)(max_types + 1));
	foreach (&handle : state.type_layouts) *handle = INVALID_LAYOUT_HANDLE;
	if (catch state.mutex.init())
	{
		alloc::free(allocator, state.type_layouts);
		state.views.free();
		state.owners.free();
		state.records.free();
		state.layouts.free();
		alloc::free(allocator, state);
		storage_recycle_control(control);
		return self;
	}
	control.state = state;
	control.entrant_gate.store(STORAGE_GATE_OPEN);
	self.control_coordinate = storage_control_coordinate(
		control_slot, control_generation
	);
	self.identity = identity;
	return self;
}

fn void StorageRuntime.free(&self)
{
	StorageControl* control = storage_detach_control(self);
	if (!control)
	{
		*self = { };
		return;
	}
	StorageState* state = control.state;
	assert(state != null, "open storage control must retain its backing state");
	storage_lock(state);
	for (stable_slot_arena::SlotId id = 0; id < state.records.next_id; id++)
	{
		if (!state.records.contains_id(id)) continue;
		RuntimeStorage* record = state.records.get_ref_id(id);
		alloc::free(state.allocator, record.bytes);
		*record = { };
	}
	for (stable_slot_arena::SlotId id = 0; id < state.layouts.next_id; id++)
	{
		if (!state.layouts.contains_id(id)) continue;
		RuntimeLayout* layout = state.layouts.get_ref_id(id);
		layout.stable_key.deinit(state.allocator);
		*layout = { };
	}
	state.owned_bytes = 0;
	storage_unlock(state);
	state.mutex.destroy();
	state.views.free();
	state.owners.free();
	state.records.free();
	state.layouts.free();
	alloc::free(state.allocator, state.type_layouts);
	Allocator allocator = state.allocator;
	alloc::free(allocator, state);
	storage_recycle_control(control);
	*self = { };
}

fn LayoutHandleResult register_layout(
	StorageRuntime* runtime,
	mitos::TypeId type_id,
	mitos::LayoutDescriptor* descriptor
)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return { .error = STORAGE_NOT_INITIALIZED };
	defer storage_leave(control);
	if (!type_id || (usz)type_id >= state.type_layouts.len
		|| !mitos::layout_descriptor_is_valid(descriptor)
		|| descriptor.size > (ulong)usz::max
		|| descriptor.alignment > (ulong)usz::max
		|| descriptor.stride > (ulong)usz::max)
	{
		return { .error = STORAGE_INVALID_LAYOUT };
	}
	storage_lock(state);
	defer storage_unlock(state);
	LayoutHandle existing = state.type_layouts[(usz)type_id];
	if (existing != INVALID_LAYOUT_HANDLE)
	{
		if (!runtime_owns_layout(state, existing))
		{
			return { .error = STORAGE_INVALID_LAYOUT };
		}
		RuntimeLayout current = state.layouts.get(layout_slot(existing));
		bool same = current.type_id == type_id
			&& current.kind == descriptor.kind
			&& current.copy_policy == descriptor.copy_policy
			&& current.sized == descriptor.sized
			&& current.size == (usz)descriptor.size
			&& current.alignment == (usz)descriptor.alignment
			&& current.stride == (usz)descriptor.stride
			&& current.element_type == descriptor.element_type
			&& mitos::symbol_key_equal(&current.stable_key, &descriptor.stable_key);
		return { .error = same ? STORAGE_OK : STORAGE_INVALID_LAYOUT, .handle = existing };
	}
	usz key_bytes;
	usz layout_control_bytes;
	usz layout_retained_bytes;
	if (!checked_add(
			descriptor.stable_key.owner.canonical.len,
			descriptor.stable_key.name.len,
			&key_bytes
		)
		|| !checked_add(
			key_bytes, descriptor.stable_key.canonical_signature.len, &key_bytes
		)
		|| !checked_add(key_bytes, 3, &key_bytes)
		|| !storage_layout_push_delta(state, &layout_control_bytes)
		|| !checked_add(key_bytes, layout_control_bytes, &layout_retained_bytes)
		|| !storage_fits_byte_quota(state, 0, layout_retained_bytes))
	{
		return { .error = STORAGE_LIMIT };
	}
	stable_slot_arena::SlotRef reference = state.layouts.push({
		.type_id = type_id,
		.kind = descriptor.kind,
		.copy_policy = descriptor.copy_policy,
		.sized = descriptor.sized,
		.size = (usz)descriptor.size,
		.alignment = (usz)descriptor.alignment,
		.stride = (usz)descriptor.stride,
		.element_type = descriptor.element_type,
		.stable_key = mitos::clone_symbol_key(&descriptor.stable_key, state.allocator),
	});
	state.retained_control_bytes += layout_retained_bytes;
	LayoutHandle handle = layout_handle(state, reference);
	state.type_layouts[(usz)type_id] = handle;
	return { .error = STORAGE_OK, .handle = handle };
}

fn StorageError register_type_registry(StorageRuntime* runtime, mitos::TypeRegistry* types)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return STORAGE_NOT_INITIALIZED;
	defer storage_leave(control);
	if (!types) return STORAGE_INVALID_LAYOUT;
	foreach (&descriptor : types.descriptors)
	{
		LayoutHandleResult registered = register_layout(runtime, descriptor.id, &descriptor.layout);
		if (registered.error != STORAGE_OK) return registered.error;
	}
	return STORAGE_OK;
}

fn StorageError validate_allocation(
	RuntimeLayout* layout,
	usz byte_count,
	usz alignment,
	usz stride,
	usz element_size
) @private
{
	if (!power_of_two(alignment) || alignment < layout.alignment) return STORAGE_ALIGNMENT;
	if (!stride || !element_size || stride < element_size || stride % alignment)
	{
		return STORAGE_ALIGNMENT;
	}
	if (layout.sized && (byte_count != layout.size || stride != layout.stride
		|| element_size != layout.size)) return STORAGE_INVALID_LAYOUT;
	if (layout.stride && stride != layout.stride) return STORAGE_INVALID_LAYOUT;
	if (byte_count && byte_count < element_size) return STORAGE_BOUNDS;
	return STORAGE_OK;
}

struct StorageAllocationReservation @private
{
	usz control_bytes;
}

fn StorageError reserve_allocation(
	StorageState* state,
	LayoutHandle handle,
	mitos::CopyPolicy requested_policy,
	usz byte_count,
	usz alignment,
	usz stride,
	usz element_size,
	StorageAllocationReservation* reservation
) @private
{
	storage_lock(state);
	defer storage_unlock(state);
	if (!runtime_owns_layout(state, handle)) return STORAGE_INVALID_LAYOUT;
	RuntimeLayout layout = state.layouts.get(layout_slot(handle));
	if (requested_policy != layout.copy_policy
		|| (requested_policy != mitos::CopyPolicy.COPY_SHARED_IMMUTABLE
			&& requested_policy != mitos::CopyPolicy.COPY_AFFINE))
	{
		return STORAGE_POLICY_VIOLATION;
	}
	StorageError valid = validate_allocation(&layout, byte_count, alignment, stride, element_size);
	if (valid != STORAGE_OK) return valid;
	if (byte_count > (usz)sz::max) return STORAGE_LIMIT;
	usz record_control_bytes;
	usz owner_control_bytes;
	usz control_bytes;
	if (!reservation || !storage_can_add_slots(state, 2)
		|| !storage_record_push_delta(state, &record_control_bytes)
		|| !storage_owner_push_delta(state, &owner_control_bytes)
		|| !checked_add(record_control_bytes, owner_control_bytes, &control_bytes)
		|| !storage_fits_byte_quota(state, byte_count, control_bytes))
	{
		return STORAGE_LIMIT;
	}
	usz next_reserved_bytes;
	usz next_reserved_control_bytes;
	if (!checked_add(state.reserved_bytes, byte_count, &next_reserved_bytes)
		|| !checked_add(
			state.reserved_control_bytes, control_bytes, &next_reserved_control_bytes
		))
	{
		return STORAGE_LIMIT;
	}
	state.reserved_records++;
	state.reserved_bytes = next_reserved_bytes;
	state.reserved_control_bytes = next_reserved_control_bytes;
	reservation.control_bytes = control_bytes;
	return STORAGE_OK;
}

fn char[] allocate_reserved_bytes(StorageState* state, usz byte_count) @private
{
	storage_lock(state);
	defer storage_unlock(state);
	assert(state.reserved_bytes >= byte_count,
		"storage allocation must be reserved before allocating bytes");
	char[] bytes = alloc::alloc_array(state.allocator, char, (sz)byte_count);
	assert(state.pending_bytes <= usz::max - byte_count,
		"pending storage byte accounting overflow");
	state.pending_bytes += byte_count;
	return bytes;
}

fn StorageHandleResult publish_allocation(
	StorageState* state,
	LayoutHandle handle,
	mitos::CopyPolicy policy,
	char[] bytes,
	usz alignment,
	usz stride,
	usz element_size,
	StorageAllocationReservation reservation
) @private
{
	storage_lock(state);
	defer storage_unlock(state);
	assert(state.pending_bytes >= bytes.len,
		"published storage bytes must be tracked as pending");
	if (!state.reserved_records || state.reserved_bytes < bytes.len
		|| state.reserved_control_bytes < reservation.control_bytes)
	{
		alloc::free(state.allocator, bytes);
		return { .error = STORAGE_INVALID_LAYOUT };
	}
	state.reserved_control_bytes -= reservation.control_bytes;
	if (!runtime_owns_layout(state, handle))
	{
		state.reserved_records--;
		state.reserved_bytes -= bytes.len;
		state.pending_bytes -= bytes.len;
		alloc::free(state.allocator, bytes);
		return { .error = STORAGE_INVALID_LAYOUT };
	}
	RuntimeLayout layout = state.layouts.get(layout_slot(handle));
	StorageError valid = validate_allocation(&layout, bytes.len, alignment, stride, element_size);
	if (valid != STORAGE_OK || layout.copy_policy != policy)
	{
		state.reserved_records--;
		state.reserved_bytes -= bytes.len;
		state.pending_bytes -= bytes.len;
		alloc::free(state.allocator, bytes);
		return { .error = valid != STORAGE_OK ? valid : STORAGE_POLICY_VIOLATION };
	}
	usz record_control_bytes;
	usz owner_control_bytes;
	usz actual_control_bytes;
	if (!storage_record_push_delta(state, &record_control_bytes)
		|| !storage_owner_push_delta(state, &owner_control_bytes)
		|| !checked_add(
			record_control_bytes, owner_control_bytes, &actual_control_bytes
		)
		|| !storage_fits_byte_quota(state, 0, actual_control_bytes))
	{
		state.reserved_records--;
		state.reserved_bytes -= bytes.len;
		state.pending_bytes -= bytes.len;
		alloc::free(state.allocator, bytes);
		return { .error = STORAGE_LIMIT };
	}
	stable_slot_arena::SlotRef record = state.records.push({
		.layout = handle,
		.copy_policy = policy,
		.bytes = bytes,
		.alignment = alignment,
		.stride = stride,
		.element_size = element_size,
		.owner_count = 1,
	});
	stable_slot_arena::SlotRef owner = state.owners.push({ .record = record });
	state.retained_control_bytes += actual_control_bytes;
	state.reserved_records--;
	state.reserved_bytes -= bytes.len;
	state.pending_bytes -= bytes.len;
	state.owned_bytes += bytes.len;
	return { .error = STORAGE_OK, .handle = storage_handle(state, owner) };
}

fn StorageHandleResult allocate_bytes(
	StorageRuntime* runtime,
	LayoutHandle layout,
	mitos::CopyPolicy policy,
	char[] source,
	usz alignment,
	usz stride,
	usz element_size
) @private
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return { .error = STORAGE_NOT_INITIALIZED };
	defer storage_leave(control);
	StorageAllocationReservation reservation;
	StorageError reserved = reserve_allocation(
		state, layout, policy, source.len, alignment, stride, element_size, &reservation
	);
	if (reserved != STORAGE_OK) return { .error = reserved };
	char[] bytes = allocate_reserved_bytes(state, source.len);
	foreach (index, byte : source) bytes[index] = byte;
	return publish_allocation(
		state, layout, policy, bytes, alignment, stride, element_size, reservation
	);
}

fn StorageHandleResult allocate_shared_bytes(
	StorageRuntime* runtime,
	LayoutHandle layout,
	char[] source,
	usz alignment = 1,
	usz stride = 1,
	usz element_size = 1
)
{
	return allocate_bytes(
		runtime, layout, mitos::CopyPolicy.COPY_SHARED_IMMUTABLE,
		source, alignment, stride, element_size
	);
}

fn StorageHandleResult allocate_affine_bytes(
	StorageRuntime* runtime,
	LayoutHandle layout,
	usz byte_count,
	usz alignment,
	usz stride,
	usz element_size
)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return { .error = STORAGE_NOT_INITIALIZED };
	defer storage_leave(control);
	StorageAllocationReservation reservation;
	StorageError reserved = reserve_allocation(
		state, layout, mitos::CopyPolicy.COPY_AFFINE,
		byte_count, alignment, stride, element_size, &reservation
	);
	if (reserved != STORAGE_OK) return { .error = reserved };
	char[] bytes = allocate_reserved_bytes(state, byte_count);
	foreach (&byte : bytes) *byte = 0;
	return publish_allocation(
		state, layout, mitos::CopyPolicy.COPY_AFFINE,
		bytes, alignment, stride, element_size, reservation
	);
}

fn StorageError storage_metadata(
	StorageRuntime* runtime,
	StorageHandle handle,
	StorageMetadata* metadata
)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return STORAGE_NOT_INITIALIZED;
	defer storage_leave(control);
	storage_lock(state);
	defer storage_unlock(state);
	RuntimeStorage* record = owner_record(state, handle);
	if (!record || !runtime_owns_layout(state, record.layout)) return STORAGE_INVALID_HANDLE;
	RuntimeLayout layout = state.layouts.get(layout_slot(record.layout));
	if (metadata) *metadata = {
		.type_id = layout.type_id,
		.copy_policy = record.copy_policy,
		.kind = layout.kind,
		.byte_length = record.bytes.len,
		.alignment = record.alignment,
		.stride = record.stride,
		.element_size = record.element_size,
		.element_type = layout.element_type,
		.owner_count = record.owner_count,
	};
	return STORAGE_OK;
}


/** Atomically validates and moves one owner token into an empty attachment slot. */
fn StorageError attach_owner(
	StorageRuntime* runtime,
	StorageHandle* source,
	StorageHandle* attached
)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return STORAGE_NOT_INITIALIZED;
	defer storage_leave(control);
	if (!source || !attached || source == attached)
	{
		return STORAGE_INVALID_HANDLE;
	}
	storage_lock(state);
	defer storage_unlock(state);
	if (*attached != INVALID_STORAGE_HANDLE) return STORAGE_INVALID_HANDLE;
	stable_slot_arena::SlotRef record_reference;
	RuntimeStorage* record = owner_record(state, *source, &record_reference);
	if (!record) return STORAGE_INVALID_HANDLE;
	if (record.copy_policy != mitos::CopyPolicy.COPY_SHARED_IMMUTABLE)
	{
		return STORAGE_POLICY_VIOLATION;
	}
	if (!state.owners.erase(owner_slot(*source))) return STORAGE_INVALID_HANDLE;
	stable_slot_arena::SlotRef attached_owner =
		state.owners.push({ .record = record_reference });
	*attached = storage_handle(state, attached_owner);
	*source = INVALID_STORAGE_HANDLE;
	return STORAGE_OK;
}

fn void retire_record(StorageState* state, stable_slot_arena::SlotRef reference) @private
{
	RuntimeStorage* record = state.records.get_ref(reference);
	usz released = record.bytes.len;
	alloc::free(state.allocator, record.bytes);
	*record = { };
	assert(state.records.erase(reference), "live storage record must retire exactly once");
	assert(state.owned_bytes >= released, "storage byte accounting underflow");
	state.owned_bytes -= released;
}

struct StorageReadLease @private
{
	stable_slot_arena::SlotRef record;
	LayoutHandle layout;
	char[] bytes;
}

fn StorageError acquire_storage_read_unlocked(
	StorageState* state,
	StorageHandle handle,
	StorageReadLease* lease
) @private
{
	stable_slot_arena::SlotRef record_reference;
	RuntimeStorage* record = owner_record(state, handle, &record_reference);
	if (!record) return STORAGE_INVALID_HANDLE;
	if (record.read_count == usz::max) return STORAGE_OVERFLOW;
	record.read_count++;
	*lease = {
		.record = record_reference,
		.layout = record.layout,
		.bytes = record.bytes,
	};
	return STORAGE_OK;
}

fn void drop_storage_read_unlocked(
	StorageState* state,
	StorageReadLease* lease
) @private
{
	assert(state.records.contains_ref(lease.record),
		"temporary storage read must keep its record alive");
	RuntimeStorage* record = state.records.get_ref(lease.record);
	assert(record.read_count != 0, "temporary storage read count underflow");
	record.read_count--;
	if (!record.owner_count && !record.view_count && !record.read_count)
	{
		retire_record(state, lease.record);
	}
	*lease = { };
}

fn StorageError release(StorageRuntime* runtime, StorageHandle handle)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return STORAGE_NOT_INITIALIZED;
	defer storage_leave(control);
	storage_lock(state);
	defer storage_unlock(state);
	if (handle.runtime_identity != state.identity) return STORAGE_INVALID_HANDLE;
	stable_slot_arena::SlotRef record_reference;
	RuntimeStorage* record = owner_record(state, handle, &record_reference);
	if (!record) return STORAGE_ALREADY_RELEASED;
	if (!record.owner_count) return STORAGE_ALREADY_RELEASED;
	if (!state.owners.erase(owner_slot(handle))) return STORAGE_ALREADY_RELEASED;
	record.owner_count--;
	if (!record.owner_count && !record.view_count && !record.read_count)
	{
		retire_record(state, record_reference);
	}
	return STORAGE_OK;
}

fn StorageHandleResult replicate(StorageRuntime* runtime, StorageHandle handle)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return { .error = STORAGE_NOT_INITIALIZED };
	defer storage_leave(control);
	storage_lock(state);
	defer storage_unlock(state);
	stable_slot_arena::SlotRef record_reference;
	RuntimeStorage* source = owner_record(state, handle, &record_reference);
	if (!source) return { .error = STORAGE_INVALID_HANDLE };
	if (source.copy_policy != mitos::CopyPolicy.COPY_SHARED_IMMUTABLE)
	{
		return { .error = STORAGE_POLICY_VIOLATION };
	}
	usz owner_control_bytes;
	if (!storage_can_add_slots(state, 1)
		|| !storage_owner_push_delta(state, &owner_control_bytes)
		|| !storage_fits_byte_quota(state, 0, owner_control_bytes))
	{
		return { .error = STORAGE_LIMIT };
	}
	if (source.owner_count == usz::max) return { .error = STORAGE_OVERFLOW };
	stable_slot_arena::SlotRef owner = state.owners.push({ .record = record_reference });
	state.retained_control_bytes += owner_control_bytes;
	source.owner_count++;
	return { .error = STORAGE_OK, .handle = storage_handle(state, owner) };
}

fn StorageError validate_region(
	RuntimeStorage* record,
	usz offset,
	usz count,
	usz stride,
	usz element_size
) @private
{
	if (!stride || !element_size || stride < element_size || stride % record.alignment)
	{
		return STORAGE_ALIGNMENT;
	}
	if (!count) return offset <= record.bytes.len ? STORAGE_OK : STORAGE_BOUNDS;
	if (offset % record.alignment) return STORAGE_ALIGNMENT;
	usz stepped;
	usz end;
	if (!checked_multiply(count - 1, stride, &stepped)
		|| !checked_add(offset, stepped, &end)
		|| !checked_add(end, element_size, &end)) return STORAGE_OVERFLOW;
	return end <= record.bytes.len ? STORAGE_OK : STORAGE_BOUNDS;
}

fn StorageViewResult view(
	StorageRuntime* runtime,
	StorageHandle handle,
	usz offset,
	usz count,
	usz stride = 1,
	usz element_size = 1
)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return { .error = STORAGE_NOT_INITIALIZED };
	defer storage_leave(control);
	storage_lock(state);
	defer storage_unlock(state);
	stable_slot_arena::SlotRef record_reference;
	RuntimeStorage* record = owner_record(state, handle, &record_reference);
	if (!record) return { .error = STORAGE_INVALID_HANDLE };
	StorageError valid = validate_region(record, offset, count, stride, element_size);
	if (valid != STORAGE_OK) return { .error = valid };
	if (record.view_count == usz::max) return { .error = STORAGE_OVERFLOW };
	usz view_control_bytes;
	if (!storage_can_add_slots(state, 1)
		|| !storage_view_push_delta(state, &view_control_bytes)
		|| !storage_fits_byte_quota(state, 0, view_control_bytes))
	{
		return { .error = STORAGE_LIMIT };
	}
	stable_slot_arena::SlotRef lease = state.views.push({
		.record = record_reference,
		.layout = record.layout,
		.offset = offset,
		.count = count,
		.stride = stride,
		.element_size = element_size,
	});
	state.retained_control_bytes += view_control_bytes;
	record.view_count++;
	return { .error = STORAGE_OK, .view = storage_view(state, lease) };
}

fn StorageError close_view(StorageRuntime* runtime, StorageView* owner_view)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return STORAGE_NOT_INITIALIZED;
	defer storage_leave(control);
	if (!owner_view) return STORAGE_STALE_VIEW;
	storage_lock(state);
	defer storage_unlock(state);
	RuntimeStorage* record;
	RuntimeView* lease = runtime_view(state, *owner_view, &record);
	if (!lease) return STORAGE_STALE_VIEW;
	if (!record.view_count) return STORAGE_STALE_VIEW;
	stable_slot_arena::SlotRef record_reference = lease.record;
	if (!state.views.erase(view_slot(*owner_view))) return STORAGE_STALE_VIEW;
	record.view_count--;
	*owner_view = { };
	if (!record.owner_count && !record.view_count && !record.read_count)
	{
		retire_record(state, record_reference);
	}
	return STORAGE_OK;
}

fn StorageError load(
	StorageRuntime* runtime,
	StorageView* source,
	usz index,
	char[] destination
)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return STORAGE_NOT_INITIALIZED;
	defer storage_leave(control);
	if (!source) return STORAGE_STALE_VIEW;
	storage_lock(state);
	defer storage_unlock(state);
	RuntimeStorage* record;
	RuntimeView* lease = runtime_view(state, *source, &record);
	if (!lease) return STORAGE_STALE_VIEW;
	if (index >= lease.count || destination.len != lease.element_size) return STORAGE_BOUNDS;
	usz relative;
	usz offset;
	if (!checked_multiply(index, lease.stride, &relative)
		|| !checked_add(lease.offset, relative, &offset)) return STORAGE_OVERFLOW;
	StorageError valid = validate_region(record, offset, 1, lease.stride, lease.element_size);
	if (valid != STORAGE_OK) return valid;
	foreach (byte_index, &byte : destination)
	{
		*byte = record.bytes[offset + (usz)byte_index];
	}
	return STORAGE_OK;
}

fn StorageError store(
	StorageRuntime* runtime,
	StorageView* destination,
	usz index,
	char[] source
)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return STORAGE_NOT_INITIALIZED;
	defer storage_leave(control);
	if (!destination) return STORAGE_STALE_VIEW;
	storage_lock(state);
	defer storage_unlock(state);
	RuntimeStorage* record;
	RuntimeView* lease = runtime_view(state, *destination, &record);
	if (!lease) return STORAGE_STALE_VIEW;
	if (index >= lease.count || source.len != lease.element_size) return STORAGE_BOUNDS;
	if (record.copy_policy != mitos::CopyPolicy.COPY_AFFINE) return STORAGE_POLICY_VIOLATION;
	if (record.read_count) return STORAGE_BUSY;
	usz relative;
	usz offset;
	if (!checked_multiply(index, lease.stride, &relative)
		|| !checked_add(lease.offset, relative, &offset)) return STORAGE_OVERFLOW;
	StorageError valid = validate_region(record, offset, 1, lease.stride, lease.element_size);
	if (valid != STORAGE_OK) return valid;
	foreach (byte_index, byte : source)
	{
		record.bytes[offset + (usz)byte_index] = byte;
	}
	return STORAGE_OK;
}

fn StorageHandleResult freeze(StorageRuntime* runtime, StorageHandle affine)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return { .error = STORAGE_NOT_INITIALIZED };
	defer storage_leave(control);
	storage_lock(state);
	defer storage_unlock(state);
	if (affine.runtime_identity != state.identity)
	{
		return { .error = STORAGE_INVALID_HANDLE };
	}
	stable_slot_arena::SlotRef record_reference;
	RuntimeStorage* source = owner_record(state, affine, &record_reference);
	if (!source) return { .error = STORAGE_ALREADY_RELEASED };
	if (source.copy_policy != mitos::CopyPolicy.COPY_AFFINE || source.owner_count != 1)
	{
		return { .error = STORAGE_POLICY_VIOLATION };
	}
	if (source.view_count) return { .error = STORAGE_BUSY };
	if (!state.owners.erase(owner_slot(affine)))
	{
		return { .error = STORAGE_INVALID_HANDLE };
	}
	source.copy_policy = mitos::CopyPolicy.COPY_SHARED_IMMUTABLE;
	stable_slot_arena::SlotRef owner = state.owners.push({ .record = record_reference });
	return { .error = STORAGE_OK, .handle = storage_handle(state, owner) };
}

fn StorageError copy_all(StorageRuntime* runtime, StorageHandle handle, char[] destination)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return STORAGE_NOT_INITIALIZED;
	defer storage_leave(control);

	StorageReadLease lease;
	storage_lock(state);
	StorageError acquired = acquire_storage_read_unlocked(state, handle, &lease);
	if (acquired != STORAGE_OK)
	{
		storage_unlock(state);
		return acquired;
	}
	if (destination.len != lease.bytes.len)
	{
		drop_storage_read_unlocked(state, &lease);
		storage_unlock(state);
		return STORAGE_BOUNDS;
	}
	char[] source = lease.bytes;
	storage_unlock(state);

	foreach (index, &byte : destination) *byte = source[index];

	storage_lock(state);
	drop_storage_read_unlocked(state, &lease);
	storage_unlock(state);
	return STORAGE_OK;
}

fn StorageError bytes_equal(
	StorageRuntime* runtime,
	StorageHandle left,
	StorageHandle right,
	bool* equal
)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return STORAGE_NOT_INITIALIZED;
	defer storage_leave(control);

	StorageReadLease left_lease;
	StorageReadLease right_lease;
	storage_lock(state);
	StorageError acquired = acquire_storage_read_unlocked(state, left, &left_lease);
	if (acquired != STORAGE_OK)
	{
		storage_unlock(state);
		return acquired;
	}
	acquired = acquire_storage_read_unlocked(state, right, &right_lease);
	if (acquired != STORAGE_OK)
	{
		drop_storage_read_unlocked(state, &left_lease);
		storage_unlock(state);
		return acquired;
	}
	bool same = left_lease.layout == right_lease.layout
		&& left_lease.bytes.len == right_lease.bytes.len;
	bool needs_scan = same && left_lease.record != right_lease.record;
	char[] left_bytes = left_lease.bytes;
	char[] right_bytes = right_lease.bytes;
	if (!needs_scan)
	{
		drop_storage_read_unlocked(state, &right_lease);
		drop_storage_read_unlocked(state, &left_lease);
		storage_unlock(state);
		if (equal) *equal = same;
		return STORAGE_OK;
	}
	storage_unlock(state);

	foreach (index, byte : left_bytes)
	{
		if (byte == right_bytes[index]) continue;
		same = false;
		break;
	}

	storage_lock(state);
	drop_storage_read_unlocked(state, &right_lease);
	drop_storage_read_unlocked(state, &left_lease);
	storage_unlock(state);
	if (equal) *equal = same;
	return STORAGE_OK;
}

fn StorageError byte_length(StorageRuntime* runtime, StorageHandle handle, usz* length)
{
	StorageMetadata metadata;
	StorageError error = storage_metadata(runtime, handle, &metadata);
	if (error == STORAGE_OK && length) *length = metadata.byte_length;
	return error;
}


/**
 * Exact allocator-requested live retention owned by this runtime, excluding
 * allocator bookkeeping and the process-wide fixed control table. Includes
 * state, arena backing capacity and pages, layout keys, the type-layout table,
 * live payloads, and unpublished allocated payloads.
 */
fn StorageError retained_bytes(StorageRuntime* runtime, usz* bytes)
{
	StorageControl* control;
	StorageState* state = storage_enter(runtime, &control);
	if (!state) return STORAGE_NOT_INITIALIZED;
	defer storage_leave(control);
	storage_lock(state);
	defer storage_unlock(state);

	usz retained;
	if (!storage_retained_bytes_unlocked(state, &retained)) return STORAGE_OVERFLOW;
	if (bytes) *bytes = retained;
	return STORAGE_OK;
}
fn String storage_error_message(StorageError error)
{
	switch (error)
	{
		case STORAGE_OK: return "ok";
		case STORAGE_NOT_INITIALIZED: return "storage runtime is not initialized";
		case STORAGE_INVALID_LAYOUT: return "storage layout is invalid or unregistered";
		case STORAGE_INVALID_HANDLE: return "storage handle is invalid for this runtime";
		case STORAGE_STALE_VIEW: return "storage view is stale or already closed";
		case STORAGE_POLICY_VIOLATION: return "storage copy policy forbids this operation";
		case STORAGE_BOUNDS: return "storage range is out of bounds";
		case STORAGE_ALIGNMENT: return "storage alignment or stride is invalid";
		case STORAGE_OVERFLOW: return "storage arithmetic overflow";
		case STORAGE_LIMIT: return "storage runtime resource limit exceeded";
		case STORAGE_BUSY: return "storage has active views or reads";
		case STORAGE_ALREADY_RELEASED: return "storage owner was already consumed or released";
		default: return "unknown storage error";
	}
}
