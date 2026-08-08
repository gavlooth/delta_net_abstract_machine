module delta_net_abstract_machine::stable_index_vector_test;

import delta_net_abstract_machine::stable_index_vector;

fn bool is_even(int* value)
{
	return *value % 2 == 0;
}

fn void stable_ids_survive_unordered_erase() @test
{
	StableIndexVector{int} vector;
	vector.init();
	defer vector.free();

	StableId first  = vector.push(10);
	StableId middle = vector.push(20);
	StableId last   = vector.push(30);

	vector.erase(middle);

	assert(vector.len() == 2);
	assert(vector.contains(first));
	assert(!vector.contains(middle));
	assert(vector.contains(last));
	assert(vector.get(first) == 10);
	assert(vector.get(last) == 30);
	assert(vector.data_index(last) == 1);
}

fn void handles_detect_erasure_and_id_reuse() @test
{
	StableIndexVector{int} vector;
	vector.init();
	defer vector.free();

	StableId erased_id                = vector.push(7);
	StableIndexHandle{int} old_handle = vector.create_handle(erased_id);
	vector.erase(erased_id);

	assert(!old_handle.is_valid());
	assert(vector.next_id() == erased_id);

	StableId reused_id                = vector.push(9);
	StableIndexHandle{int} new_handle = vector.create_handle(reused_id);
	assert(reused_id == erased_id);
	assert(!old_handle.is_valid());
	assert(new_handle.is_valid());
	assert(new_handle.get() == 9);
}

fn void erase_at_and_erase_handle_preserve_other_ids() @test
{
	StableIndexVector{int} vector;
	vector.init();
	defer vector.free();

	StableId first                      = vector.push(1);
	StableId second                     = vector.push(2);
	StableId third                      = vector.push(3);
	StableIndexHandle{int} third_handle = vector.create_handle_at(2);

	vector.erase_at(0);
	assert(!vector.contains(first));
	assert(vector.get(second) == 2);
	assert(third_handle.is_valid());
	assert(third_handle.get() == 3);

	vector.erase_handle(third_handle);
	assert(!third_handle.is_valid());
	assert(vector.len() == 1);
	assert(vector.get(second) == 2);
}

fn void remove_if_checks_values_swapped_into_erased_slots() @test
{
	StableIndexVector{int} vector;
	vector.init();
	defer vector.free();

	StableId one   = vector.push(1);
	StableId two   = vector.push(2);
	StableId four  = vector.push(4);
	StableId three = vector.push(3);

	sz removed = vector.remove_if(&is_even);

	assert(removed == 2);
	assert(vector.len() == 2);
	assert(vector.contains(one));
	assert(!vector.contains(two));
	assert(!vector.contains(four));
	assert(vector.contains(three));
	assert(vector.get(one) == 1);
	assert(vector.get(three) == 3);
}

fn void clear_invalidates_handles_and_reuses_slots() @test
{
	StableIndexVector{int} vector;
	vector.init(initial_capacity: 1);
	defer vector.free();

	StableId first                       = vector.push(11);
	StableId second                      = vector.push(22);
	StableIndexHandle{int} first_handle  = vector.create_handle(first);
	StableIndexHandle{int} second_handle = vector.create_handle(second);

	vector.clear();

	assert(vector.is_empty());
	assert(!vector.contains(first));
	assert(!vector.contains(second));
	assert(!first_handle.is_valid());
	assert(!second_handle.is_valid());
	assert(vector.next_id() == first);

	StableId reused = vector.push(33);
	assert(reused == first);
	assert(vector.get(reused) == 33);
	assert(!first_handle.is_valid());
}

fn void reserve_and_array_view_expose_dense_storage() @test
{
	StableIndexVector{int} vector;
	vector.init();
	defer vector.free();

	vector.reserve(40);
	assert(vector.capacity() >= 40);
	vector.push(5);
	vector.push(6);

	int[] values = vector.array_view();
	assert(values.len == 2);
	assert(values[0] == 5);
	assert(values[1] == 6);
}