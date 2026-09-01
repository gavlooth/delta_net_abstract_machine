module delta_net_abstract_machine;
// Local interactions are coordinator-serialized in this wave. Any slot pointer
// retained across an arena push is therefore protected by global quiescence;
// the later parallel scheduler must replace that guarantee with slot claims.
fn bool erase_redex(Net* net, NetRef node_a_id, NetRef node_b_id,
NetRef wire_id, NetRef port_a_id, NetRef port_b_id)
{
 // Node retirement must succeed before any port or wire is erased.
 if (!destroy_node_record(net, node_a_id)) return false;
 if (!destroy_node_record(net, node_b_id)) return false;
 net.wires.erase(wire_id);
 net.ports.erase(port_a_id);
 net.ports.erase(port_b_id);
 return true;
}

fn void eraser_eraser_reduction(Net* net, NetRef node_a_id, NetRef node_b_id,
NetRef wire_id, NetRef port_a_id, NetRef port_b_id)
{
 (void)erase_redex(net, node_a_id, node_b_id, wire_id, port_a_id, port_b_id);
}

fn void fan_eraser_reduction(Net* net, NetRef fan_id, NetRef eraser_id,
NetRef wire_id, NetRef fan_port_id, NetRef eraser_port_id)
{
 Node* fan = net.nodes.get_ref(fan_id);
 NetRef left_id = fan.agent.fan.left;
 NetRef right_id = fan.agent.fan.right;

 // Each fan branch receives an eraser; the branch wires themselves survive.
 NetRef left_eraser_id = net.nodes.push({
  .agent = { .eraser = { .principal = left_id }},
  .type = ERASER
 });
NetRef right_eraser_id = net.nodes.push({
 .agent = { .eraser = { .principal = right_id }},
 .type = ERASER
});
Port* left = net.ports.get_ref(left_id);
Port* right = net.ports.get_ref(right_id);
left.node_id = left_eraser_id;
left.slot.type = PRINCIPAL;
right.node_id = right_eraser_id;
right.slot.type = PRINCIPAL;
(void)erase_redex(net, fan_id, eraser_id, wire_id, fan_port_id, eraser_port_id);
}

fn void fan_fan_reduction(Net* net, NetRef first_id, NetRef second_id,
	NetRef first_principal_id)
{
	Node* first = net.nodes.get_ref(first_id);
	Node* second = net.nodes.get_ref(second_id);
	NetRef second_principal_id = second.agent.fan.principal;
	NetRef principal_wire_id = net.ports.get_ref(first_principal_id).wire_id;

	// Canonicalize operand order because splice preserves its first wire ID.
	// This keeps the physical result independent of active-wire endpoint order;
	// it does not change either fan's auxiliary identities. The parent-principal
	// choice is only a deterministic wire-ownership choice, not an instruction
	// to pair different auxiliary indices.
	Node* parent_principal_fan =
		net.ports.get_ref(first_principal_id).polarity == PARENT ? first : second;
	Node* child_principal_fan = parent_principal_fan == first ? second : first;
	NetRef first_left = parent_principal_fan.agent.fan.left;
	NetRef first_right = parent_principal_fan.agent.fan.right;
	NetRef second_left = child_principal_fan.agent.fan.left;
	NetRef second_right = child_principal_fan.agent.fan.right;

	// FAN--FAN ANNIHILATION: pair corresponding auxiliary identities.
	//
	//   left/first/aux1   <--> left/first/aux1
	//   right/second/aux2 <--> right/second/aux2
	//
	// The agents may be drawn facing one another, so same-index wires may look
	// crossed on paper. That visual crossing is correct and must NOT be
	// implemented as left<-->right or right<-->left. Translation/readback may
	// assign local semantic names (body/result, variable/argument), but this
	// graph-level rule deliberately knows only the stable auxiliary identity.
	(void)splice(net, first_left, second_left);
	(void)splice(net, first_right, second_right);

	net.nodes.erase(first_id);
	net.nodes.erase(second_id);
	net.ports.erase(first_principal_id);
	net.ports.erase(second_principal_id);
	net.ports.erase(first_left);
	net.ports.erase(first_right);
	net.ports.erase(second_left);
	net.ports.erase(second_right);
	net.wires.erase(principal_wire_id);
}

fn void replicator_fan_reduction(Net* net, NetRef replicator_id, NetRef fan_id)
{
 Node* fan = net.nodes.get_ref(fan_id);
 Node* replicator = net.nodes.get_ref(replicator_id);
 NetRef fan_principal = fan.agent.fan.principal;
 NetRef fan_left = fan.agent.fan.left;
 NetRef fan_right = fan.agent.fan.right;
 NetRef old_principal_wire = net.ports.get_ref(fan_principal).wire_id;
 NetRef old_replicator_principal = replicator.agent.replicator.principal;
 ulong replicator_delta_level = replicator.agent.replicator.delta_level;
 ReplicatorStatus replicator_status = replicator.agent.replicator.status;
 bool replicator_observable = replicator.agent.replicator.observable;
 ulong replicator_origin = replicator.agent.replicator.origin;
 ReplicatorStatus copy_status =
  replicator_status == UNPAIRED ? UNKNOWN : replicator_status;

 NetRef[] old_auxiliaries = replicator.agent.replicator.auxiliaries;
 NetRef[] left_auxiliaries = {};
 NetRef[] right_auxiliaries = {};

 // Reuse the fan branches as the principals of two replicator copies.
 // These ports are not cloned; only their slot and owner change.
 // Save polarity before changing ownership so the orientation is explicit.
 Port* left_principal = net.ports.get_ref(fan_left);
 Port* right_principal = net.ports.get_ref(fan_right);
 left_principal.slot.type = PRINCIPAL;
 right_principal.slot.type = PRINCIPAL;
 Polarity left_principal_polarity = left_principal.polarity;
 Polarity right_principal_polarity = right_principal.polarity;
 Node left_copy = {
  .agent = { .replicator = {
    .principal = fan_left,
    .auxiliaries = left_auxiliaries,
    .delta_level = replicator_delta_level,
    .status = copy_status,
    .observable = replicator_observable && left_principal_polarity == PARENT,
    .origin = replicator_observable && left_principal_polarity == PARENT ? replicator_origin : 0
   }},
 .type = REPLICATOR
};
Node right_copy = {
 .agent = { .replicator = {
   .principal = fan_right,
   .auxiliaries = right_auxiliaries,
   .delta_level = replicator_delta_level,
   .status = copy_status,
   .observable = replicator_observable && right_principal_polarity == PARENT,
   .origin = replicator_observable && right_principal_polarity == PARENT ? replicator_origin : 0
  }},
.type = REPLICATOR
};
NetRef left_copy_id = net.nodes.push(left_copy);
NetRef right_copy_id = net.nodes.push(right_copy);
net.ports.get_ref(fan_left).node_id = left_copy_id;
net.ports.get_ref(fan_right).node_id = right_copy_id;
 // Clone every old auxiliary for each output replicator. A copied
 // replicator must orient its auxiliaries opposite its reused principal:
 // one output is a fan-out and the other a fan-in.
 left_auxiliaries = clone_ports(net, old_auxiliaries, left_copy_id);
 right_auxiliaries = clone_ports(net, old_auxiliaries, right_copy_id);
 foreach (auxiliary : left_auxiliaries)
  net.ports.get_ref(auxiliary).polarity = opposite_polarity(left_principal_polarity);
 foreach (auxiliary : right_auxiliaries)
  net.ports.get_ref(auxiliary).polarity = opposite_polarity(right_principal_polarity);
 net.nodes.get_ref(left_copy_id).agent.replicator.auxiliaries = left_auxiliaries;
 net.nodes.get_ref(right_copy_id).agent.replicator.auxiliaries = right_auxiliaries;

foreach (idx, old_auxiliary_id : old_auxiliaries)
{
 // Reuse the old auxiliary as the principal of a newly created fan.
 // The two branch ports below are genuinely new ports.
 Port* old_auxiliary = net.ports.get_ref(old_auxiliary_id);
 old_auxiliary.slot = { .type = PRINCIPAL };
 NetRef new_left = net.ports.push({
  .node_id = INVALID_NET_REF,
  .wire_id = INVALID_NET_REF,
  .slot = { .type = LEFT },
  // A wire must connect opposite endpoint polarities.
  .polarity = opposite_polarity(
   net.ports.get_ref(left_auxiliaries[idx]).polarity)
 });
 NetRef new_right = net.ports.push({
  .node_id = INVALID_NET_REF,
  .wire_id = INVALID_NET_REF,
  .slot = { .type = RIGHT },
  .polarity = opposite_polarity(
   net.ports.get_ref(right_auxiliaries[idx]).polarity)
 });
 NetRef new_fan_id = net.nodes.push({ .agent = { .fan = {
    .principal = old_auxiliary_id, .left = new_left, .right = new_right }}, .type = FAN });
 net.ports.get_ref(old_auxiliary_id).node_id = new_fan_id;
 net.ports.get_ref(new_left).node_id = new_fan_id;
 net.ports.get_ref(new_right).node_id = new_fan_id;
 (void)connect(net, new_left, left_auxiliaries[idx]);
 (void)connect(net, new_right, right_auxiliaries[idx]);
}

(void)destroy_node_record(net, replicator_id);
(void)destroy_node_record(net, fan_id);
net.ports.erase(old_replicator_principal);
net.ports.erase(fan_principal);
net.wires.erase(old_principal_wire);
}



fn void replicator_replicator_reduction(Net* net, NetRef first_id,
NetRef second_id)
{
 Node* first = net.nodes.get_ref(first_id);
 Node* second = net.nodes.get_ref(second_id);
 NetRef first_principal = first.agent.replicator.principal;
 NetRef second_principal = second.agent.replicator.principal;
 NetRef principal_wire = net.ports.get_ref(first_principal).wire_id;
 NetRef[] first_auxiliaries = first.agent.replicator.auxiliaries;
 NetRef[] second_auxiliaries = second.agent.replicator.auxiliaries;
 ulong first_level = first.agent.replicator.delta_level;
 ulong second_level = second.agent.replicator.delta_level;
 bool first_observable = first.agent.replicator.observable;
 bool second_observable = second.agent.replicator.observable;
 ulong first_origin = first.agent.replicator.origin;
 ulong second_origin = second.agent.replicator.origin;

 // Observable coordinates are their stable source origins, not mutable
 // reduction levels. Repeated origins annihilate index-for-index.
 bool same_coordinate = first_observable && second_observable
  ? first_origin == second_origin
  : !first_observable && !second_observable && first_level == second_level;
 if (same_coordinate)
 {
  assert(first_auxiliaries.len == second_auxiliaries.len,
  "Equal-level replicators must have the same arity");

  foreach (idx, first_auxiliary : first_auxiliaries)
  {
   NetRef second_auxiliary = second_auxiliaries[idx];
   if (VALIDATE_REPLICATOR_EQUALITY)
   {
    PortSlot first_slot = net.ports.get_ref(first_auxiliary).slot;
    PortSlot second_slot = net.ports.get_ref(second_auxiliary).slot;
    assert(first_slot.properties.has_value
    && second_slot.properties.has_value,
    "Replicator auxiliaries must have delta metadata");
    assert(first_slot.properties.value.delta_level
    == second_slot.properties.value.delta_level,
    "Equal-level replicators must have matching ordered deltas");
   }
  NetRef first_wire = net.ports.get_ref(first_auxiliary).wire_id;
  NetRef second_wire = net.ports.get_ref(second_auxiliary).wire_id;
  NetRef second_external = other_endpoint(net, second_wire, second_auxiliary);

  Wire* surviving_wire = net.wires.get_ref(first_wire);
  if (surviving_wire.a == first_auxiliary)
  {
   surviving_wire.a = second_external;
  }
 else
 {
  surviving_wire.b = second_external;
 }
net.ports.get_ref(second_external).wire_id = first_wire;

net.ports.erase(first_auxiliary);
net.ports.erase(second_auxiliary);
net.wires.erase(second_wire);
}

(void)erase_redex(net, first_id, second_id, principal_wire,
first_principal, second_principal);
return;
}

// Earlier source origins remain outer coordinates, yielding lexicographic
// Cartesian order; branch position is retained by each auxiliary slice.
bool first_is_higher = first_observable && second_observable
 ? first_origin < second_origin
 : first_level > second_level
  || (first_level == second_level && first_observable && !second_observable);
NetRef higher_id = first_is_higher ? first_id : second_id;
NetRef lower_id = first_is_higher ? second_id : first_id;
NetRef higher_principal = first_is_higher ? first_principal : second_principal;
NetRef lower_principal = first_is_higher ? second_principal : first_principal;
NetRef[] higher_auxiliaries = first_is_higher ? first_auxiliaries : second_auxiliaries;
NetRef[] lower_auxiliaries = first_is_higher ? second_auxiliaries : first_auxiliaries;
ReplicatorStatus higher_status = first_is_higher
 ? first.agent.replicator.status : second.agent.replicator.status;
ReplicatorStatus lower_status = first_is_higher
 ? second.agent.replicator.status : first.agent.replicator.status;
ulong higher_level = first_is_higher ? first_level : second_level;
ulong lower_level = first_is_higher ? second_level : first_level;
bool higher_observable = first_is_higher ? first_observable : second_observable;
bool lower_observable = first_is_higher ? second_observable : first_observable;
ulong higher_origin = first_is_higher ? first_origin : second_origin;
ulong lower_origin = first_is_higher ? second_origin : first_origin;
sz higher_count = higher_auxiliaries.len;
sz lower_count = lower_auxiliaries.len;

Port[] higher_templates = mem::alloc_array(Port, higher_count);
Port[] lower_templates = mem::alloc_array(Port, lower_count);
NetRef[][] higher_rows = mem::alloc_array(NetRef[], lower_count);
defer mem::free(higher_templates);
defer mem::free(lower_templates);
defer mem::free(higher_rows);

foreach (idx, auxiliary : higher_auxiliaries)
higher_templates[idx] = net.ports.get(auxiliary);
foreach (idx, auxiliary : lower_auxiliaries)
lower_templates[idx] = net.ports.get(auxiliary);

// Each lower auxiliary becomes the principal of a higher-level copy.
foreach (lower_idx, principal : lower_auxiliaries)
{
 NetRef[] auxiliaries = mem::alloc_array(NetRef, higher_count);
 int128 replica_level = (int128)higher_level
 + (int128)lower_templates[lower_idx].slot.properties.value.delta_level;
 assert(replica_level >= 0
 && replica_level <= (int128)18_446_744_073_709_551_615,
 "Replicator level is out of range");
 NetRef copy_id = net.nodes.push({
  .agent = { .replicator = {
    .principal = principal,
    .auxiliaries = auxiliaries,
    .delta_level = (ulong)replica_level,
    .status = higher_status,
    .observable = higher_observable,
    .origin = higher_origin
   }},
 .type = REPLICATOR
});

Port* principal_port = net.ports.get_ref(principal);
principal_port.node_id = copy_id;
principal_port.slot = { .type = PRINCIPAL };

foreach (higher_idx, template : higher_templates)
{
 auxiliaries[higher_idx] = clone_port_value(net, template, copy_id);
}
higher_rows[lower_idx] = auxiliaries;
}

// Lower-level copies retain their level and complete the Cartesian wiring.
foreach (higher_idx, principal : higher_auxiliaries)
{
 NetRef[] auxiliaries = mem::alloc_array(NetRef, lower_count);
 NetRef copy_id = net.nodes.push({
  .agent = { .replicator = {
    .principal = principal,
    .auxiliaries = auxiliaries,
    .delta_level = lower_level,
    .status = lower_status,
    .observable = lower_observable,
    .origin = lower_origin
   }},
 .type = REPLICATOR
});

Port* principal_port = net.ports.get_ref(principal);
principal_port.node_id = copy_id;
principal_port.slot = { .type = PRINCIPAL };

foreach (lower_idx, template : lower_templates)
{
 NetRef lower_auxiliary = clone_port_value(net, template, copy_id);
auxiliaries[lower_idx] = lower_auxiliary;

NetRef higher_auxiliary = higher_rows[lower_idx][higher_idx];
(void)connect(net, higher_auxiliary, lower_auxiliary);
}
}

(void)erase_redex(net, higher_id, lower_id, principal_wire,
higher_principal, lower_principal);
}

fn void replicator_eraser_reduction(Net* net, NetRef replicator_id,
NetRef eraser_id)
{
 Node* replicator = net.nodes.get_ref(replicator_id);
 Node* eraser = net.nodes.get_ref(eraser_id);

 NetRef replicator_principal =
 replicator.agent.replicator.principal;

 NetRef eraser_port =
 eraser.agent.eraser.principal;

 NetRef principal_wire_id =
 net.ports.get_ref(replicator_principal).wire_id;

 // Snapshot the auxiliary IDs before mutating or erasing the
 // replicator node. The auxiliary wires remain in the net.
 NetRef[] auxiliaries = replicator.agent.replicator.auxiliaries;

 foreach (auxiliary_id : auxiliaries)
 {
  // Every auxiliary port receives a new eraser.
  NetRef auxiliary_eraser_id = net.nodes.push({
   .agent = {
    .eraser = {
     .principal = auxiliary_id
    }
  },
 .type = ERASER
});

// The existing auxiliary port becomes the principal port of
// the newly created eraser. Its existing wire is preserved.
Port* auxiliary_port = net.ports.get_ref(auxiliary_id);
auxiliary_port.node_id = auxiliary_eraser_id;
auxiliary_port.slot = { .type = PRINCIPAL };
}

// Remove the original replicator, the interacting eraser, their
// principal ports, and the active principal wire.
(void)erase_redex(
net,
replicator_id,
eraser_id,
principal_wire_id,
replicator_principal,
eraser_port
);
}
fn bool commit_ordered_effect(Net* net, NetRef continuation_ref)
{
	if (!net.effects.continuations.contains_ref(continuation_ref)) return false;
	EffectContinuation* continuation = net.effects.continuations.get_ref(continuation_ref);
	if (!continuation.ordered || continuation.resumes_used) return true;
	while (net.effects.committed < net.effects.commits.len)
	{
		OrderedEffectCommit* next =
			&net.effects.commits[net.effects.committed];
		if (net.effects.continuations.contains_ref(next.continuation)) break;
		next.committed = true;
		net.effects.committed++;
	}
	if (net.effects.committed >= net.effects.commits.len) return false;
	OrderedEffectCommit* next = &net.effects.commits[net.effects.committed];
	if (next.continuation != continuation_ref) return false;
	next.committed = true;
	net.effects.committed++;
	return true;
}

fn bool resume_effect_continuation(Net* net, NetRef continuation_ref)
{
	if (!net.effects.continuations.contains_ref(continuation_ref)) return false;
	EffectContinuation* continuation = net.effects.continuations.get_ref(continuation_ref);
	if (continuation.effect_epoch != net.effects.execution_epoch
		|| continuation.state == CONTINUATION_ERASED) return false;
	if (!continuation.multi && continuation.resumes_used)
	{
		return false;
	}
	if (continuation.multi && continuation.resumes_used >= continuation.resume_count)
	{
		return false;
	}
	if (!commit_ordered_effect(net, continuation_ref)) return false;
	continuation.resumes_used++;
	continuation.state = continuation.multi
		? CONTINUATION_REPLICATED : CONTINUATION_RESUMED;
	return true;
}


fn usz practical_effect_index_capacity(usz count) @private
{
 if (!count) return 0;
 if (count > (usz::max - 1) / 2) return 0;
 usz required = count * 2 + 1;
 usz capacity = 1;
 while (capacity < required)
 {
  if (capacity > usz::max / 2) return 0;
  capacity *= 2;
 }
 return capacity;
}

fn ulong practical_effect_index_hash(
 NetRef handler,
 uint effect_id,
 uint operation_id,
 ulong effect_epoch,
 NetRef hole
) @private
{
 ulong hash = 1469598103934665603UL;
 hash ^= handler.id;
 hash *= 1099511628211UL;
 hash ^= handler.generation;
 hash *= 1099511628211UL;
 hash ^= (ulong)effect_id;
 hash *= 1099511628211UL;
 hash ^= (ulong)operation_id;
 hash *= 1099511628211UL;
 hash ^= effect_epoch;
 hash *= 1099511628211UL;
 hash ^= hole.id;
 hash *= 1099511628211UL;
 hash ^= hole.generation;
 hash *= 1099511628211UL;
 return hash;
}

fn void practical_continuation_index_add_node(
 PracticalContinuationIndex* index,
 NetRef node,
 NetRef continuation
) @private
{
 if (node == INVALID_NET_REF || node.id >= (SlotId)index.node_heads.len) return;
 assert(index.links_used < index.links.len,
  "practical continuation owner index capacity is inconsistent");
 SlotId* head = &index.node_heads[(usz)node.id];
 SlotId* tail = &index.node_tails[(usz)node.id];
 SlotId link_id = (SlotId)index.links_used++;
 index.links[(usz)link_id] = {
  .continuation = continuation,
  .next = stable_slot_arena::INVALID_SLOT_ID,
 };
 if (*tail == stable_slot_arena::INVALID_SLOT_ID)
 {
  *head = link_id;
 }
 else
 {
  index.links[(usz)*tail].next = link_id;
 }
 *tail = link_id;
}

fn bool practical_continuation_index_add_effect(
 PracticalContinuationIndex* index,
 NetRef reference,
 EffectContinuation* continuation
) @private
{
 usz capacity = index.effect_buckets.len;
 if (!capacity) return false;
 usz bucket = (usz)(practical_effect_index_hash(
  continuation.handler,
  continuation.effect_id,
  continuation.operation_id,
  continuation.effect_epoch,
  continuation.hole
 ) % (ulong)capacity);
 for (usz probe = 0; probe < capacity; probe++)
 {
  if (index.effect_buckets[bucket] == INVALID_NET_REF)
  {
   index.effect_buckets[bucket] = reference;
   return true;
  }
  bucket++;
  if (bucket == capacity) bucket = 0;
 }
 return false;
}

fn bool practical_continuation_index_build(
 Net* net,
 PracticalContinuationIndex* index
) @private
{
 index.free();
 usz live_count = net.effects.continuations.len();
 usz node_count = (usz)net.nodes.next_id;
 if (net.nodes.next_id > (SlotId)usz::max
  || node_count > (usz)sz::max / (usz)SlotId::size
  || live_count > (usz)sz::max / 6
  || live_count * 6
   > (usz)sz::max / (usz)PracticalContinuationLink::size) return false;
 usz effect_capacity = practical_effect_index_capacity(live_count);
 if (live_count && (!effect_capacity
  || effect_capacity > (usz)sz::max / (usz)NetRef::size)) return false;

 index.allocator = net.effects.continuations.allocator;
 index.continuation_next_id = net.effects.continuations.next_id;
 index.continuation_live_count = live_count;
 index.shape_version = net.effects.continuation_shape_version;
 index.built = true;
 foreach (&commit : net.effects.commits)
 {
  if (!net.effects.continuations.contains_ref(commit.continuation))
  {
   index.ordered_commit_tombstones++;
  }
 }
 if (!live_count) return true;
 index.node_heads = alloc::new_array(
  index.allocator, SlotId, (sz)node_count
 );
 index.node_tails = alloc::new_array(
  index.allocator, SlotId, (sz)node_count
 );
 index.links = alloc::new_array(
  index.allocator, PracticalContinuationLink, (sz)(live_count * 6)
 );
 index.effect_buckets = alloc::new_array(
  index.allocator, NetRef, (sz)effect_capacity
 );
 foreach (&head : index.node_heads) *head = stable_slot_arena::INVALID_SLOT_ID;
 foreach (&tail : index.node_tails) *tail = stable_slot_arena::INVALID_SLOT_ID;
 foreach (&bucket : index.effect_buckets) *bucket = INVALID_NET_REF;

 for (SlotId id = 0; id < net.effects.continuations.next_id; id++)
 {
  if (!net.effects.continuations.contains_id(id)) continue;
  NetRef reference = net.effects.continuations.generation_ref(id);
  EffectContinuation* continuation =
   net.effects.continuations.get_ref(reference);
  practical_continuation_index_add_node(
   index, continuation.handler, reference
  );
  practical_continuation_index_add_node(
   index, continuation.eraser, reference
  );
  practical_continuation_index_add_node(
   index, continuation.first_replicator, reference
  );
  practical_continuation_index_add_node(
   index, continuation.second_replicator, reference
  );
  if (net.ports.contains_ref(continuation.root))
  {
   practical_continuation_index_add_node(
    index, net.ports.get_ref(continuation.root).node_id, reference
   );
  }
  if (net.ports.contains_ref(continuation.hole))
  {
   practical_continuation_index_add_node(
    index, net.ports.get_ref(continuation.hole).node_id, reference
   );
  }
  if (!practical_continuation_index_add_effect(
   index, reference, continuation
  ))
  {
   index.free();
   return false;
  }
 }
 return true;
}

fn bool practical_continuation_index_ensure(
 Net* net,
 PracticalContinuationIndex* index
) @private
{
 if (!net.storage.identity || !net.effects.continuations.allocator) return false;
 return index.built
  && index.shape_version == net.effects.continuation_shape_version
  && index.continuation_next_id == net.effects.continuations.next_id
  && index.continuation_live_count == net.effects.continuations.len()
  ? true : practical_continuation_index_build(net, index);
}

fn bool practical_continuation_references_node(
 Net* net,
 EffectContinuation* continuation,
 NetRef node
) @private
{
 if (continuation.handler == node || continuation.eraser == node
  || continuation.first_replicator == node
  || continuation.second_replicator == node) return true;
 if (net.ports.contains_ref(continuation.root)
  && net.ports.get_ref(continuation.root).node_id == node) return true;
 return net.ports.contains_ref(continuation.hole)
  && net.ports.get_ref(continuation.hole).node_id == node;
}

// Retired continuations are tombstones until they occupy a fixed fraction of
// the queue. Each compaction then removes enough records to pay for its scan,
// while preserving the physical committed prefix of the retained records.
fn void practical_maybe_compact_effect_commits(
 Net* net,
 PracticalContinuationIndex* index
) @private
{
 usz count = net.effects.commits.len;
 if (!count)
 {
  index.ordered_commit_tombstones = 0;
  net.effects.committed = 0;
  return;
 }
 usz threshold = count / 4;
 if (count % 4) threshold++;
 if (index.ordered_commit_tombstones < threshold) return;

 usz retained_cursor = 0;
 usz retained_committed = 0;
 foreach (commit_index, &commit : net.effects.commits)
 {
  if (!net.effects.continuations.contains_ref(commit.continuation)) continue;
  net.effects.commits[retained_cursor++] = *commit;
  if ((usz)commit_index < net.effects.committed) retained_committed++;
 }
 net.effects.commits = net.effects.commits[:(sz)retained_cursor];
 net.effects.committed = retained_committed;
 index.ordered_commit_tombstones = 0;
}

fn bool practical_continuation_is_consumed(
 Net* net,
 EffectContinuation* continuation,
 NetRef first_id,
 NetRef second_id
) @private
{
 if (continuation.handler == first_id || continuation.handler == second_id
  || continuation.eraser == first_id || continuation.eraser == second_id)
 {
  return true;
 }
 if (net.ports.contains_ref(continuation.root))
 {
  NetRef owner = net.ports.get_ref(continuation.root).node_id;
  if (owner == first_id || owner == second_id) return true;
 }
 if (net.ports.contains_ref(continuation.hole))
 {
  NetRef owner = net.ports.get_ref(continuation.hole).node_id;
  if (owner == first_id || owner == second_id) return true;
 }
 return false;
}

fn void practical_retire_continuations_for_node(
 Net* net,
 PracticalContinuationIndex* index,
 NetRef indexed_node,
 NetRef first_id,
 NetRef second_id,
 usz* retired_ordered
) @private
{
 if (indexed_node.id >= (SlotId)index.node_heads.len) return;
 SlotId* cursor = &index.node_heads[(usz)indexed_node.id];
 while (*cursor != stable_slot_arena::INVALID_SLOT_ID)
 {
  PracticalContinuationLink* link = &index.links[(usz)*cursor];
  SlotId next = link.next;
  if (!net.effects.continuations.contains_ref(link.continuation))
  {
   *cursor = next;
   continue;
  }
  EffectContinuation* continuation =
   net.effects.continuations.get_ref(link.continuation);
  if (!practical_continuation_references_node(
   net, continuation, indexed_node
  ))
  {
   *cursor = next;
   continue;
  }
  if (!practical_continuation_is_consumed(
   net, continuation, first_id, second_id
  ))
  {
   cursor = &link.next;
   continue;
  }

  NetRef reference = link.continuation;
  NetRef first_resource = continuation.first_replicator;
  NetRef second_resource = continuation.second_replicator;
  bool ordered = continuation.ordered;
  practical_continuation_index_invalidate(net);
  continuation.first_replicator = INVALID_NET_REF;
  continuation.second_replicator = INVALID_NET_REF;
  if (first_resource != first_id && first_resource != second_id
   && net.nodes.contains_ref(first_resource))
  {
   destroy_node(net, first_resource);
  }
  if (second_resource != first_id && second_resource != second_id
   && net.nodes.contains_ref(second_resource))
  {
   destroy_node(net, second_resource);
  }
  if (net.effects.continuations.erase(reference))
  {
   assert(index.continuation_live_count > 0,
    "practical continuation index length underflow");
   index.continuation_live_count--;
   index.shape_version = net.effects.continuation_shape_version;
   index.built = true;
   if (ordered) (*retired_ordered)++;
  }
  *cursor = next;
 }
}

fn void practical_retire_continuations(
 Net* net,
 PracticalContinuationIndex* index,
 NetRef first_id,
 NetRef second_id
) @private
{
 usz retired_ordered = 0;
 practical_retire_continuations_for_node(
  net, index, first_id, first_id, second_id, &retired_ordered
 );
 practical_retire_continuations_for_node(
  net, index, second_id, first_id, second_id, &retired_ordered
 );
 if (!retired_ordered) return;
 assert(retired_ordered <= usz::max - index.ordered_commit_tombstones,
  "ordered effect tombstone count overflow");
 index.ordered_commit_tombstones += retired_ordered;
 practical_maybe_compact_effect_commits(net, index);
}

fn bool practical_eraser_reduction(
 Net* net,
 PracticalContinuationIndex* index,
 NetRef practical_id,
 NetRef eraser_id
)
{
 // Storage retirement is the commit point: a stale owner leaves every graph
 // record and continuation untouched so the same redex can be diagnosed.
 if (!practical_agent_can_drop(net, practical_id)
  || !practical_agent_retire_storage(net, practical_id)) return false;
 Node* practical = net.nodes.get_ref(practical_id);
 Node* eraser = net.nodes.get_ref(eraser_id);
 NetRef practical_principal = practical.agent.practical.principal;
 NetRef eraser_principal = eraser.agent.eraser.principal;
 practical_retire_continuations(net, index, practical_id, eraser_id);
 NetRef principal_wire = net.ports.get_ref(practical_principal).wire_id;
 NetRef[] auxiliaries = practical.agent.practical.auxiliaries;
 foreach (auxiliary : auxiliaries)
 {
  NetRef auxiliary_eraser = net.nodes.push({
   .agent = { .eraser = { .principal = auxiliary } },
   .type = ERASER
  });
  Port* port = net.ports.get_ref(auxiliary);
  port.node_id = auxiliary_eraser;
  port.slot = { .type = PRINCIPAL };
 }
 return erase_redex(
  net, practical_id, eraser_id, principal_wire,
  practical_principal, eraser_principal
 );
}
fn bool practical_value_agent(AgentType type) @private
{
 return type == I64_AGENT || type == STRING_AGENT || type == CONSTRUCTOR_AGENT
  || type == TYPE_VALUE_AGENT || type == LAMBDA_AGENT || type == ARRAY_AGENT;
}



fn bool practical_pair_consume(
 Net* net,
 PracticalContinuationIndex* continuation_index,
 NetRef first_id,
 NetRef second_id,
 NetRef principal_wire,
 NetRef first_principal,
 NetRef second_principal
) @private
{
 // Check both owners before retiring either one. Coordinator serialization
 // makes these preflights stable through the two retirement calls.
 if (!practical_agent_pair_can_drop(net, first_id, second_id)) return false;
 if (!practical_agent_retire_storage(net, first_id)
  || !practical_agent_retire_storage(net, second_id)) return false;
 practical_retire_continuations(
  net, continuation_index, first_id, second_id
 );
 Node* first = net.nodes.get_ref(first_id);
 Node* second = net.nodes.get_ref(second_id);
 NetRef[] first_auxiliaries = first.agent.practical.auxiliaries;
 NetRef[] second_auxiliaries = second.agent.practical.auxiliaries;
 usz common = first_auxiliaries.len < second_auxiliaries.len
  ? first_auxiliaries.len : second_auxiliaries.len;
 for (usz index = 0; index < common; index++)
 {
  (void)splice(net, first_auxiliaries[index], second_auxiliaries[index]);
 }
 for (usz index = common; index < first_auxiliaries.len; index++)
 {
  NetRef port_ref = first_auxiliaries[index];
  NetRef eraser_ref = net.nodes.push({
   .agent = { .eraser = { .principal = port_ref } },
   .type = ERASER,
  });
  Port* port = net.ports.get_ref(port_ref);
  port.node_id = eraser_ref;
  port.slot = { .type = PRINCIPAL };
 }
 for (usz index = common; index < second_auxiliaries.len; index++)
 {
  NetRef port_ref = second_auxiliaries[index];
  NetRef eraser_ref = net.nodes.push({
   .agent = { .eraser = { .principal = port_ref } },
   .type = ERASER,
  });
  Port* port = net.ports.get_ref(port_ref);
  port.node_id = eraser_ref;
  port.slot = { .type = PRINCIPAL };
 }
 for (usz index = 0; index < common; index++)
 {
  net.ports.erase(first_auxiliaries[index]);
  net.ports.erase(second_auxiliaries[index]);
 }
 net.ports.erase(first_principal);
 net.ports.erase(second_principal);
 net.wires.erase(principal_wire);
 if (!destroy_node_record(net, first_id)) return false;
 if (!destroy_node_record(net, second_id)) return false;
 return true;
}

fn NetRef practical_effect_continuation(
 Net* net,
 PracticalContinuationIndex* index,
 NetRef handler_ref,
 PracticalAgent* effect
) @private
{
 usz capacity = index.effect_buckets.len;
 if (!capacity) return INVALID_NET_REF;
 usz bucket = (usz)(practical_effect_index_hash(
  handler_ref,
  effect.effect_id,
  effect.operation_id,
  effect.effect_epoch,
  effect.principal
 ) % (ulong)capacity);
 for (usz probe = 0; probe < capacity; probe++)
 {
  NetRef reference = index.effect_buckets[bucket];
  if (reference == INVALID_NET_REF) return INVALID_NET_REF;
  if (net.effects.continuations.contains_ref(reference))
  {
   EffectContinuation* continuation =
    net.effects.continuations.get_ref(reference);
   if (continuation.handler == handler_ref
    && continuation.effect_id == effect.effect_id
    && continuation.operation_id == effect.operation_id
    && continuation.effect_epoch == effect.effect_epoch
    && continuation.hole == effect.principal) return reference;
  }
  bucket++;
  if (bucket == capacity) bucket = 0;
 }
 return INVALID_NET_REF;
}

fn bool practical_pair_reduction(
 Net* net,
 PracticalContinuationIndex* index,
 NetRef first_id,
 NetRef second_id,
 NetRef principal_wire,
 NetRef first_principal,
 NetRef second_principal
) @private
{
 // Reject stale storage before effect/continuation matching can mutate either
 // node or the ordered-effect state.
 if (!practical_agent_pair_can_drop(net, first_id, second_id)) return false;
 Node* first_node = net.nodes.get_ref(first_id);
 Node* second_node = net.nodes.get_ref(second_id);
 AgentType first_type = first_node.type;
 AgentType second_type = second_node.type;
 PracticalAgent* first = &first_node.agent.practical;
 PracticalAgent* second = &second_node.agent.practical;
 bool consume = false;

 if (first_type == second_type)
 {
  consume = first.semantic_id == second.semantic_id
   && first.type_id == second.type_id
   && first.descriptor == second.descriptor
   && first.payload == second.payload
   && practical_agent_payload_equal(net, first_type, first, second);
 }
 else if ((first_type == APPLY_AGENT && second_type == LAMBDA_AGENT)
  || (second_type == APPLY_AGENT && first_type == LAMBDA_AGENT)
  || (first_type == MATCH_AGENT && second_type == CONSTRUCTOR_AGENT)
  || (second_type == MATCH_AGENT && first_type == CONSTRUCTOR_AGENT)
  || (first_type == PARALLEL_JOIN_AGENT && second_type == PARALLEL_ROOT_AGENT)
  || (second_type == PARALLEL_JOIN_AGENT && first_type == PARALLEL_ROOT_AGENT))
 {
  consume = true;
 }
 else if ((first_type == LET_AGENT && practical_value_agent(second_type))
  || (second_type == LET_AGENT && practical_value_agent(first_type))
  || (first_type == TYPE_ASSERTION_AGENT && practical_value_agent(second_type))
  || (second_type == TYPE_ASSERTION_AGENT && practical_value_agent(first_type))
  || (first_type == GENERIC_DISPATCH_AGENT && practical_value_agent(second_type))
  || (second_type == GENERIC_DISPATCH_AGENT && practical_value_agent(first_type))
  || (first_type == GENERIC_CALL_AGENT && practical_value_agent(second_type))
  || (second_type == GENERIC_CALL_AGENT && practical_value_agent(first_type))
  || (first_type == PRIMITIVE_OP_AGENT && practical_value_agent(second_type))
  || (second_type == PRIMITIVE_OP_AGENT && practical_value_agent(first_type)))
 {
  consume = true;
 }
 else if ((first_type == HANDLER_AGENT && second_type == EFFECT_AGENT)
  || (second_type == HANDLER_AGENT && first_type == EFFECT_AGENT))
 {
  NetRef handler_ref = first_type == HANDLER_AGENT ? first_id : second_id;
  PracticalAgent* handler = first_type == HANDLER_AGENT ? first : second;
  PracticalAgent* effect = first_type == EFFECT_AGENT ? first : second;
  NetRef continuation = practical_effect_continuation(
   net, index, handler_ref, effect
  );
  if (continuation == INVALID_NET_REF) return false;
  handler.continuation = continuation;
  effect.continuation = continuation;
  consume = true;
 }
 else if ((first_type == RESUME_AGENT && second_type == HANDLER_AGENT)
  || (second_type == RESUME_AGENT && first_type == HANDLER_AGENT))
 {
  PracticalAgent* resume = first_type == RESUME_AGENT ? first : second;
  PracticalAgent* handler = first_type == HANDLER_AGENT ? first : second;
  NetRef continuation = resume.continuation != INVALID_NET_REF
   ? resume.continuation : handler.continuation;
  if (!resume_effect_continuation(net, continuation)) return false;
  consume = true;
 }
 else if ((first_type == ABORT_AGENT && second_type == HANDLER_AGENT)
  || (second_type == ABORT_AGENT && first_type == HANDLER_AGENT))
 {
  PracticalAgent* handler = first_type == HANDLER_AGENT ? first : second;
  PracticalAgent* abort = first_type == ABORT_AGENT ? first : second;
  if (!net.effects.continuations.contains_ref(handler.continuation)) return false;
  EffectContinuation* continuation =
   net.effects.continuations.get_ref(handler.continuation);
  practical_continuation_index_invalidate(net);
  continuation.state = CONTINUATION_ERASED;
  continuation.eraser = abort.auxiliaries.len
   ? net.ports.get_ref(abort.auxiliaries[abort.auxiliaries.len - 1]).node_id
   : INVALID_NET_REF;
  consume = true;
 }

 if (!consume) return false;
 return practical_pair_consume(
  net, index, first_id, second_id,
  principal_wire, first_principal, second_principal
 );
}

fn bool continuation_owns_resource_node(
 Net* net,
 PracticalContinuationIndex* index,
 NetRef node
) @private
{
 if (node.id >= (SlotId)index.node_heads.len) return false;
 SlotId* cursor = &index.node_heads[(usz)node.id];
 while (*cursor != stable_slot_arena::INVALID_SLOT_ID)
 {
  PracticalContinuationLink* link = &index.links[(usz)*cursor];
  if (!net.effects.continuations.contains_ref(link.continuation))
  {
   *cursor = link.next;
   continue;
  }
  EffectContinuation* continuation =
   net.effects.continuations.get_ref(link.continuation);
  if (!practical_continuation_references_node(net, continuation, node))
  {
   *cursor = link.next;
   continue;
  }
  if (continuation.eraser == node
   || continuation.first_replicator == node
   || continuation.second_replicator == node) return true;
  cursor = &link.next;
 }
 return false;
}

fn bool continuation_owns_either_resource_node(
 Net* net,
 PracticalContinuationIndex* index,
 NetRef first,
 NetRef second
) @private
{
 return continuation_owns_resource_node(net, index, first)
  || continuation_owns_resource_node(net, index, second);
}

fn bool practical_interact(
 Net* net,
 PracticalContinuationIndex* index,
 NetRef wire_id
) @private
{
 // Queued work may carry a retired generation. Reject it before dereference;
 // local rewrites remain coordinator-serialized until footprint claims land.
 if (!is_active(net, wire_id)) return false;
 Wire* wire = net.wires.get_ref(wire_id);
 NetRef port_a_id = wire.a;
 NetRef port_b_id = wire.b;
 Port* port_a = net.ports.get_ref(port_a_id);
 Port* port_b = net.ports.get_ref(port_b_id);
 NetRef node_a_id = port_a.node_id;
 NetRef node_b_id = port_b.node_id;
 if (continuation_owns_either_resource_node(
  net, index, node_a_id, node_b_id
 )) return false;
 AgentType type_a = net.nodes.get_ref(node_a_id).type;
 AgentType type_b = net.nodes.get_ref(node_b_id).type;

 if (type_a == ERASER)
 {
  if (type_b == ERASER)
  {
   eraser_eraser_reduction(net, node_a_id, node_b_id, wire_id, port_a_id, port_b_id);
  }
  else if (type_b == FAN)
  {
   fan_eraser_reduction(net, node_b_id, node_a_id, wire_id, port_b_id, port_a_id);
  }
  else if (type_b == REPLICATOR)
  {
   replicator_eraser_reduction(net, node_b_id, node_a_id);
  }
  else if (is_practical_agent_type(type_b))
  {
   return practical_eraser_reduction(net, index, node_b_id, node_a_id);
  }
  else
  {
   return false;
  }
  return true;
 }
 if (type_b == ERASER)
 {
  if (type_a == FAN)
  {
   fan_eraser_reduction(net, node_a_id, node_b_id, wire_id, port_a_id, port_b_id);
  }
  else if (type_a == REPLICATOR)
  {
   replicator_eraser_reduction(net, node_a_id, node_b_id);
  }
  else if (is_practical_agent_type(type_a))
  {
   return practical_eraser_reduction(net, index, node_a_id, node_b_id);
  }
  else
  {
   return false;
  }
  return true;
 }
 if (type_a == FAN && type_b == FAN)
 {
  fan_fan_reduction(net, node_a_id, node_b_id, port_a_id);
  return true;
 }
 if (type_a == REPLICATOR && type_b == FAN)
 {
  replicator_fan_reduction(net, node_a_id, node_b_id);
  return true;
 }
 if (type_a == FAN && type_b == REPLICATOR)
 {
  replicator_fan_reduction(net, node_b_id, node_a_id);
  return true;
 }
 if (type_a == REPLICATOR && type_b == REPLICATOR)
 {
  replicator_replicator_reduction(net, node_a_id, node_b_id);
  return true;
 }
 if (is_practical_agent_type(type_a) && is_practical_agent_type(type_b))
 {
  return practical_pair_reduction(
   net, index, node_a_id, node_b_id,
   wire_id, port_a_id, port_b_id
  );
 }
 // An active pair is successful only when a concrete rewrite occurred.
 return false;
}

fn bool interact(Net* net, NetRef wire_id)
{
 PracticalContinuationIndex* index = &net.effects.continuation_index;
 if (!practical_continuation_index_ensure(net, index)) return false;
 return practical_interact(net, index, wire_id);
}
