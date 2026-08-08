module delta_net_abstract_machine::stable_index_vector;

typedef StableId = ulong;

struct StableIndexMetadata
{
	StableId reverse_id;
	StableId validity_id;
}

module delta_net_abstract_machine::stable_index_vector <Type>;
import std::collections::list;


// A handle remains valid across insertions and unordered erases. The container
// itself must stay at the same address for the lifetime of its handles.
struct StableIndexHandle
{
	StableId id;
	StableId validity_id;
	StableIndexVector* vector;
}

// Dense storage with stable external IDs. Erase is O(1) and may move the last
// value, so pointers and data indexes are invalidated by erase and push.
struct StableIndexVector
{
	List{Type} values;
	List{StableIndexMetadata} metadata;
	List{sz} indexes;
}

fn StableIndexVector* StableIndexVector.init(&self, Allocator allocator = mem, sz initial_capacity = 0)
{
	self.values.init(allocator, initial_capacity);
	self.metadata.init(allocator, initial_capacity);
	self.indexes.init(allocator, initial_capacity);
	return self;
}

fn void StableIndexVector.free(&self)
{
	self.values.free();
	self.metadata.free();
	self.indexes.free();
}

fn sz StableIndexVector.len(&self) @operator(len) @inline
{
	return self.values.size;
}

fn bool StableIndexVector.is_empty(&self) @inline
{
	return self.values.size == 0;
}

fn sz StableIndexVector.capacity(&self) @inline
{
	return self.values.capacity;
}

fn bool StableIndexVector.contains(&self, StableId id) @inline
{
	if (id >= (StableId)self.indexes.size) return false;
	return self.indexes[(sz)id] < self.values.size;
}

fn bool StableIndexVector.is_valid(&self, StableId id, StableId validity_id) @inline
{
	if (!self.contains(id)) return false;
	return self.metadata[self.indexes[(sz)id]].validity_id == validity_id;
}

fn StableId StableIndexVector.next_id(&self)
{
	if (self.metadata.size > self.values.size)
	{
		return self.metadata[self.values.size].reverse_id;
	}
	return (StableId)self.values.size;
}

fn StableId StableIndexVector.push(&self, Type value)
{
	StableId id = self.acquire_free_id();
	self.indexes[(sz)id] = self.values.size;
	self.values.push(value);
	return id;
}

fn void StableIndexVector.erase(&self, StableId id)
{
	assert(self.contains(id), "Cannot erase an invalid stable ID");

	sz data_index      = self.indexes[(sz)id];
	sz last_data_index = self.values.size - 1;
	StableId last_id   = self.metadata[last_data_index].reverse_id;

	self.metadata[data_index].validity_id++;
	self.values.swap(data_index, last_data_index);
	self.metadata.swap(data_index, last_data_index);
	self.indexes.swap((sz)id, (sz)last_id);
	self.values.remove_last()!!;
}

fn void StableIndexVector.erase_at(&self, sz data_index)
{
	assert(data_index < self.values.size, "Cannot erase an invalid data index");
	self.erase(self.metadata[data_index].reverse_id);
}

fn void StableIndexVector.erase_handle(&self, StableIndexHandle handle)
{
	assert(handle.vector == self, "Handle belongs to a different stable index vector");
	assert(handle.is_valid(), "Cannot erase through an invalid handle");
	self.erase(handle.id);
}

fn sz StableIndexVector.data_index(&self, StableId id)
{
	assert(self.contains(id), "Cannot access an invalid stable ID");
	return self.indexes[(sz)id];
}

fn Type StableIndexVector.get(&self, StableId id)
{
	return *self.get_ref(id);
}

fn Type* StableIndexVector.get_ref(&self, StableId id)
{
	assert(self.contains(id), "Cannot access an invalid stable ID");
	return &self.values[self.indexes[(sz)id]];
}

fn StableIndexHandle StableIndexVector.create_handle(&self, StableId id)
{
	assert(self.contains(id), "Cannot create a handle for an invalid stable ID");
	sz index = self.indexes[(sz)id];
	return { .id = id, .validity_id = self.metadata[index].validity_id, .vector = self };
}

fn StableIndexHandle StableIndexVector.create_handle_at(&self, sz data_index)
{
	assert(data_index < self.values.size, "Cannot create a handle for an invalid data index");
	StableIndexMetadata* entry = &self.metadata[data_index];
	return { .id = entry.reverse_id, .validity_id = entry.validity_id, .vector = self };
}

fn Type[] StableIndexVector.array_view(&self) @inline
{
	return self.values.array_view();
}

fn Type* StableIndexVector.data(&self) @inline
{
	return self.values.entries;
}

fn void StableIndexVector.reserve(&self, sz capacity)
{
	if (capacity > self.values.size) self.values.reserve(capacity - self.values.size);
	if (capacity > self.metadata.size) self.metadata.reserve(capacity - self.metadata.size);
	if (capacity > self.indexes.size) self.indexes.reserve(capacity - self.indexes.size);
}

macro sz StableIndexVector.remove_if(&self, predicate)
{
	sz removed = 0;
	for (sz i = 0; i < self.values.size;)
	{
		if (predicate(&self.values[i]))
		{
			self.erase_at(i);
			removed++;
		}
		else
		{
			i++;
		}
	}
	return removed;
}

macro sz StableIndexVector.remove_using_test(&self, predicate, context)
{
	sz removed = 0;
	for (sz i = 0; i < self.values.size;)
	{
		if (predicate(&self.values[i], context))
		{
			self.erase_at(i);
			removed++;
		}
		else
		{
			i++;
		}
	}
	return removed;
}

fn void StableIndexVector.clear(&self)
{
	self.values.clear();
	foreach (&entry : self.metadata)
	{
		entry.validity_id++;
	}
}

fn StableId StableIndexVector.validity_id(&self, StableId id)
{
	assert(self.contains(id), "Cannot access an invalid stable ID");
	return self.metadata[self.indexes[(sz)id]].validity_id;
}

fn StableId StableIndexVector.acquire_free_id(&self)
{
	if (self.metadata.size > self.values.size)
	{
		StableIndexMetadata* entry = &self.metadata[self.values.size];
		entry.validity_id++;
		return entry.reverse_id;
	}

	StableId id = (StableId)self.values.size;
	self.metadata.push({ .reverse_id = id });
	self.indexes.push(self.values.size);
	return id;
}

fn bool StableIndexHandle.is_valid(&self) @inline
{
	return self.vector != null && self.vector.is_valid(self.id, self.validity_id);
}

fn StableId StableIndexHandle.get_id(&self) @inline
{
	return self.id;
}

fn Type StableIndexHandle.get(&self)
{
	return *self.get_ref();
}

fn Type* StableIndexHandle.get_ref(&self)
{
	assert(self.is_valid(), "Cannot access an invalid stable index handle");
	return self.vector.get_ref(self.id);
}