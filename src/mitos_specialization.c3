module delta_net_abstract_machine::mitos_specialization;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_mir;

const usz MITOS_DEFAULT_SPECIALIZATION_CAPACITY = 256;
const usz MITOS_MAX_SPECIALIZATION_CAPACITY = 4_096;

struct MethodInstanceKey
{
	usz generic_index;
	usz method_index;
	mitos::TypeId[] concrete_types;
	ulong method_epoch;
	ulong effect_epoch;
}

struct MethodSpecialization
{
	MethodInstanceKey key;
	ulong last_used;
	void* native_result;
	uint function_index;
}

struct SpecializationCache
{
	Allocator allocator;
	MethodSpecialization[] entries;
	usz count;
	ulong clock;
}

fn void MethodSpecialization.deinit(&self, Allocator allocator)
{
	if (self.native_result) mitos_mir::release_native_result(self.native_result);
	alloc::free(allocator, self.key.concrete_types);
	*self = { };
}

fn bool MethodInstanceKey.matches(
	&self,
	usz generic_index,
	mitos::TypeId[] concrete_types,
	ulong method_epoch,
	ulong effect_epoch
)
{
	if (self.generic_index != generic_index || self.method_epoch != method_epoch
		|| self.effect_epoch != effect_epoch
		|| self.concrete_types.len != concrete_types.len) return false;
	foreach (index, type_id : concrete_types)
	{
		if (self.concrete_types[index] != type_id) return false;
	}
	return true;
}

fn void SpecializationCache.init(
	&self,
	Allocator allocator = mem,
	usz capacity = MITOS_DEFAULT_SPECIALIZATION_CAPACITY
)
{
	if (!capacity) capacity = 1;
	if (capacity > MITOS_MAX_SPECIALIZATION_CAPACITY) capacity = MITOS_MAX_SPECIALIZATION_CAPACITY;
	self.allocator = allocator;
	self.entries = alloc::new_array(allocator, MethodSpecialization, (sz)capacity);
}

fn void SpecializationCache.deinit(&self)
{
	if (!self.allocator) return;
	foreach (&entry : self.entries[:(sz)self.count]) entry.deinit(self.allocator);
	alloc::free(self.allocator, self.entries);
	*self = { };
}

fn MethodSpecialization* SpecializationCache.lookup(
	&self,
	usz generic_index,
	mitos::TypeId[] concrete_types,
	ulong method_epoch,
	ulong effect_epoch
)
{
	foreach (&entry : self.entries[:(sz)self.count])
	{
		if (!entry.key.matches(generic_index, concrete_types, method_epoch, effect_epoch)) continue;
		entry.last_used = ++self.clock;
		return entry;
	}
	return null;
}

fn MethodSpecialization* SpecializationCache.record(
	&self,
	usz generic_index,
	usz method_index,
	mitos::TypeId[] concrete_types,
	ulong method_epoch,
	ulong effect_epoch,
	void* native_result = null,
	uint function_index = uint::max
)
{
	MethodSpecialization* existing = self.lookup(
		generic_index, concrete_types, method_epoch, effect_epoch
	);
	if (existing)
	{
		if (native_result && existing.native_result != native_result)
		{
			if (existing.native_result) mitos_mir::release_native_result(existing.native_result);
			existing.native_result = native_result;
		}
		if (function_index != uint::max) existing.function_index = function_index;
		existing.key.method_index = method_index;
		return existing;
	}
	usz slot = self.count;
	if (self.count < self.entries.len)
	{
		self.count++;
	}
	else
	{
		slot = 0;
		foreach (index, &entry : self.entries)
		{
			if (entry.last_used < self.entries[slot].last_used) slot = (usz)index;
		}
		self.entries[slot].deinit(self.allocator);
	}
	mitos::TypeId[] owned = alloc::clone_slice(self.allocator, concrete_types);
	self.entries[slot] = {
		.key = {
			.generic_index = generic_index,
			.method_index = method_index,
			.concrete_types = owned,
			.method_epoch = method_epoch,
			.effect_epoch = effect_epoch,
		},
		.last_used = ++self.clock,
		.native_result = native_result,
		.function_index = function_index,
	};
	return &self.entries[slot];
}

fn void SpecializationCache.invalidate_generic(&self, usz generic_index)
{
	usz index = 0;
	while (index < self.count)
	{
		if (self.entries[index].key.generic_index != generic_index)
		{
			index++;
			continue;
		}
		self.entries[index].deinit(self.allocator);
		self.count--;
		if (index != self.count) self.entries[index] = self.entries[self.count];
		self.entries[self.count] = { };
	}
}

fn void SpecializationCache.invalidate_epoch(&self, ulong minimum_epoch)
{
	usz index = 0;
	while (index < self.count)
	{
		if (self.entries[index].key.method_epoch >= minimum_epoch)
		{
			index++;
			continue;
		}
		self.entries[index].deinit(self.allocator);
		self.count--;
		if (index != self.count) self.entries[index] = self.entries[self.count];
		self.entries[self.count] = { };
	}
}

fn void SpecializationCache.invalidate_effect_epoch(&self, ulong effect_epoch)
{
	usz index = 0;
	while (index < self.count)
	{
		if (self.entries[index].key.effect_epoch == effect_epoch)
		{
			index++;
			continue;
		}
		self.entries[index].deinit(self.allocator);
		self.count--;
		if (index != self.count) self.entries[index] = self.entries[self.count];
		self.entries[self.count] = { };
	}
}

fn void SpecializationCache.invalidate_all(&self)
{
	foreach (&entry : self.entries[:(sz)self.count]) entry.deinit(self.allocator);
	self.count = 0;
	self.clock++;
}
