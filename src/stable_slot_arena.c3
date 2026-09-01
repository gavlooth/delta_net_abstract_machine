module delta_net_abstract_machine::stable_slot_arena;


alias SlotId = ulong;

const SlotId INVALID_SLOT_ID = ulong::max;
struct SlotRef
{
	SlotId id;
	ulong generation;
}

fn bool SlotRef.equals(self, SlotRef other) @operator(==) @inline
{
	return self.id == other.id && self.generation == other.generation;
}

module delta_net_abstract_machine::stable_slot_arena <Type>;

import std::collections::list;
import std::thread;

const usz STABLE_SLOT_PAGE_CAPACITY = 256;

enum SlotState : char
{
	SLOT_STATE_FREE,
	SLOT_STATE_LIVE,
	SLOT_STATE_CLAIMED,
	SLOT_STATE_RETIRED,
}


struct StableSlot
{
	Type value;
	ulong generation;
	SlotId next_free;
	SlotState state;
}

struct StableSlotPage
{
	StableSlot[STABLE_SLOT_PAGE_CAPACITY] slots;
}

// Pages are individually allocated and are never relocated or released before
// arena.free(). The arena itself must not be copied or moved after init because
// it owns a Mutex.
struct StableSlotArena
{
	Allocator allocator;
	List{StableSlotPage*} pages;
	Mutex mutex;
	SlotId next_id;
	SlotId free_head;
	usz live_count;
}

fn bool slot_state_is_active(SlotState state) @private
{
	return state == SLOT_STATE_LIVE || state == SLOT_STATE_CLAIMED;
}

fn void lock_arena(StableSlotArena* self) @private
{
	if (catch self.mutex.lock()) unreachable("failed to lock stable slot arena");
}

fn void unlock_arena(StableSlotArena* self) @private
{
	self.mutex.unlock();
}

fn StableSlot* slot_unlocked(StableSlotArena* self, SlotId id) @private
{
	if (id >= self.next_id) return null;
	usz raw_id = (usz)id;
	usz page_index = raw_id / STABLE_SLOT_PAGE_CAPACITY;
	usz slot_index = raw_id % STABLE_SLOT_PAGE_CAPACITY;
	return &self.pages[(sz)page_index].slots[slot_index];
}

fn StableSlotPage* allocate_page_unlocked(StableSlotArena* self) @private
{
	StableSlotPage* page = alloc::new_aligned(self.allocator, StableSlotPage)!!;
	self.pages.push(page);
	return page;
}

fn StableSlotArena* StableSlotArena.init(&self, Allocator allocator = mem)
{
	*self = { .allocator = allocator, .free_head = INVALID_SLOT_ID };
	self.pages.init(allocator, 0);
	if (catch self.mutex.init())
	{
		self.pages.free();
		*self = { };
		unreachable("failed to initialize stable slot arena mutex");
	}
	return self;
}

// free() requires all users of the arena to have quiesced.
fn void StableSlotArena.free(&self)
{
	if (!self.allocator) return;

	lock_arena(self);
	Allocator allocator = self.allocator;
	foreach (page : self.pages)
	{
		alloc::free_aligned(allocator, page);
	}
	self.pages.free();
	self.next_id = 0;
	self.free_head = INVALID_SLOT_ID;
	self.live_count = 0;
	unlock_arena(self);
	self.mutex.destroy();
	*self = { };
}

fn SlotRef StableSlotArena.push(&self, Type value)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);

	SlotId id;
	StableSlot* slot;
	if (self.free_head != INVALID_SLOT_ID)
	{
		id = self.free_head;
		slot = slot_unlocked(self, id);
		assert(slot != null && slot.state == SLOT_STATE_FREE,
			"stable slot arena free list is corrupt");
		self.free_head = slot.next_free;
		assert(slot.generation < ulong::max,
			"stable slot generation exhausted");
		slot.generation++;
	}
	else
	{
		assert(self.next_id < INVALID_SLOT_ID, "stable slot ID space exhausted");
		id = self.next_id;
		usz page_index = (usz)id / STABLE_SLOT_PAGE_CAPACITY;
		if (page_index == (usz)self.pages.size) allocate_page_unlocked(self);
		slot = slot_unlocked(self, id);
		// slot_unlocked excludes next_id until it is published.
		if (!slot)
		{
			usz slot_index = (usz)id % STABLE_SLOT_PAGE_CAPACITY;
			slot = &self.pages[(sz)page_index].slots[slot_index];
		}
		self.next_id++;
		slot.generation = 1;
	}

	slot.value = value;
	slot.next_free = INVALID_SLOT_ID;
	slot.state = SLOT_STATE_LIVE;
	self.live_count++;
	return { .id = id, .generation = slot.generation };
}

// Worker-safe membership: both generation and active lifecycle state must match.
fn bool StableSlotArena.contains_ref(&self, SlotRef reference)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	StableSlot* slot = slot_unlocked(self, reference.id);
	return slot != null
		&& slot.generation == reference.generation
		&& slot_state_is_active(slot.state);
}

// Coordinator-only migration path. It intentionally does not protect against a
// stale ID being reused; worker code must use contains_ref().
fn bool StableSlotArena.contains_id(&self, SlotId id)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	StableSlot* slot = slot_unlocked(self, id);
	return slot != null && slot_state_is_active(slot.state);
}

fn Type StableSlotArena.get(&self, SlotRef reference)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	StableSlot* slot = slot_unlocked(self, reference.id);
	assert(slot != null
		&& slot.generation == reference.generation
		&& slot_state_is_active(slot.state),
		"cannot access an invalid stable slot reference");
	return slot.value;
}

// The returned address never moves. A worker that retains it across calls must
// hold the corresponding claim until it is done with the value.
fn Type* StableSlotArena.get_ref(&self, SlotRef reference)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	StableSlot* slot = slot_unlocked(self, reference.id);
	assert(slot != null
		&& slot.generation == reference.generation
		&& slot_state_is_active(slot.state),
		"cannot access an invalid stable slot reference");
	return &slot.value;
}

// Coordinator-only migration path. Unlike get_ref(), this accepts a retired
// slot so its value can be cleaned up before erase(). It must not be used by
// workers because it cannot detect an ID that was freed and reused.
fn Type* StableSlotArena.get_ref_id(&self, SlotId id)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	StableSlot* slot = slot_unlocked(self, id);
	assert(slot != null && slot.state != SLOT_STATE_FREE,
		"cannot access an unallocated stable slot ID");
	return &slot.value;
}

fn SlotRef StableSlotArena.generation_ref(&self, SlotId id)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	StableSlot* slot = slot_unlocked(self, id);
	assert(slot != null && slot_state_is_active(slot.state),
		"cannot create a reference for an inactive stable slot ID");
	return { .id = id, .generation = slot.generation };
}

fn bool StableSlotArena.claim(&self, SlotRef reference)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	StableSlot* slot = slot_unlocked(self, reference.id);
	if (!slot
		|| slot.generation != reference.generation
		|| slot.state != SLOT_STATE_LIVE) return false;
	slot.state = SLOT_STATE_CLAIMED;
	return true;
}

fn bool StableSlotArena.release_claim(&self, SlotRef reference)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	StableSlot* slot = slot_unlocked(self, reference.id);
	if (!slot
		|| slot.generation != reference.generation
		|| slot.state != SLOT_STATE_CLAIMED) return false;
	slot.state = SLOT_STATE_LIVE;
	return true;
}

fn bool StableSlotArena.retire_claimed(&self, SlotRef reference)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	StableSlot* slot = slot_unlocked(self, reference.id);
	if (!slot
		|| slot.generation != reference.generation
		|| slot.state != SLOT_STATE_CLAIMED) return false;
	slot.state = SLOT_STATE_RETIRED;
	assert(self.live_count > 0, "stable slot arena length underflow");
	self.live_count--;
	return true;
}

// Coordinator-only removal. A claimed slot cannot be stolen from its owner.
// Erasing a retired slot publishes it to the free list; erasing a live slot is
// also allowed when the coordinator has established global quiescence.
fn bool StableSlotArena.erase(&self, SlotRef reference)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	StableSlot* slot = slot_unlocked(self, reference.id);
	if (!slot
		|| slot.generation != reference.generation
		|| slot.state == SLOT_STATE_FREE
		|| slot.state == SLOT_STATE_CLAIMED) return false;

	if (slot.state == SLOT_STATE_LIVE)
	{
		assert(self.live_count > 0, "stable slot arena length underflow");
		self.live_count--;
	}
	slot.value = { };
	slot.state = SLOT_STATE_FREE;
	slot.next_free = self.free_head;
	self.free_head = reference.id;
	return true;
}

fn usz StableSlotArena.len(&self) @operator(len)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	return self.live_count;
}

fn bool StableSlotArena.is_empty(&self)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	return self.live_count == 0;
}

// The callback receives (SlotRef, Type*) for every active slot while the arena
// mutex is held. It must not call arena methods, and it must not retain the
// pointer across retirement. Callers inspecting claimed values must separately
// ensure the claim owner is quiescent.
macro void StableSlotArena.each_snapshot(&self, callback)
{
	assert(self.allocator != null, "stable slot arena is not initialized");
	lock_arena(self);
	defer unlock_arena(self);
	for (SlotId id = 0; id < self.next_id; id++)
	{
		StableSlot* slot = slot_unlocked(self, id);
		if (!slot_state_is_active(slot.state)) continue;
		SlotRef reference = { .id = id, .generation = slot.generation };
		callback(reference, &slot.value);
	}
}
