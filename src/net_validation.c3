module delta_net_abstract_machine;

// Validation is coordinator-only in this wave. Enumerating raw arena slots and
// immediately upgrading each live ID to its generation-bearing reference is
// safe because no rewrite may run concurrently with validation.

fn bool node_port_is_valid(Net* net, NetRef node_ref, NetRef port_ref,
 PortType expected_type)
{
 if (!net.ports.contains_ref(port_ref)) return false;
 Port* port = net.ports.get_ref(port_ref);
 return port.node_id == node_ref
  && port.slot.type == expected_type
  && (expected_type == AUXILIARY || !port.slot.properties.has_value);
}

fn bool node_is_valid(Net* net, NetRef node_ref, Node* node)
{
 switch (node.type)
 {
 case ERASER:
  return node_port_is_valid(net, node_ref, node.agent.eraser.principal,
   PRINCIPAL);
 case FAN:
  if (node.agent.fan.principal == node.agent.fan.left
   || node.agent.fan.principal == node.agent.fan.right
   || node.agent.fan.left == node.agent.fan.right) return false;
  if (!node_port_is_valid(net, node_ref, node.agent.fan.principal, PRINCIPAL)
   || !node_port_is_valid(net, node_ref, node.agent.fan.left, LEFT)
   || !node_port_is_valid(net, node_ref, node.agent.fan.right, RIGHT)) return false;
  Polarity principal_polarity =
   net.ports.get_ref(node.agent.fan.principal).polarity;
  return net.ports.get_ref(node.agent.fan.left).polarity
    == opposite_polarity(principal_polarity)
   && net.ports.get_ref(node.agent.fan.right).polarity
    == principal_polarity;
 case REPLICATOR:
  NetRef principal = node.agent.replicator.principal;
  if (!node_port_is_valid(net, node_ref, principal, PRINCIPAL)) return false;
  Polarity auxiliary_polarity =
   opposite_polarity(net.ports.get_ref(principal).polarity);
  Replicator* replicator = &node.agent.replicator;
  Polarity principal_polarity = net.ports.get_ref(principal).polarity;
  if (replicator.observable)
  {
   if (!replicator.origin || principal_polarity != PARENT
    || !replicator.auxiliaries.len) return false;
  }
  else if (replicator.origin)
  {
   return false;
  }
  foreach (idx, auxiliary : node.agent.replicator.auxiliaries)
  {
   if (auxiliary == principal
    || !node_port_is_valid(net, node_ref, auxiliary, AUXILIARY)) return false;
   Port* auxiliary_port = net.ports.get_ref(auxiliary);
   if (auxiliary_port.polarity != auxiliary_polarity
    || !auxiliary_port.slot.properties.has_value
    || auxiliary_port.slot.properties.value.position != (usz)idx) return false;
  }
  return true;
 default:
  if (!is_practical_agent_type(node.type)) return false;
  NetRef practical_principal = node.agent.practical.principal;
  if (!node_port_is_valid(net, node_ref, practical_principal, PRINCIPAL)) return false;
  Polarity practical_auxiliary_polarity =
   opposite_polarity(net.ports.get_ref(practical_principal).polarity);
  foreach (idx, auxiliary : node.agent.practical.auxiliaries)
  {
   if (auxiliary == practical_principal
    || !node_port_is_valid(net, node_ref, auxiliary, AUXILIARY)) return false;
   Port* auxiliary_port = net.ports.get_ref(auxiliary);
   if (auxiliary_port.polarity != practical_auxiliary_polarity
    || !auxiliary_port.slot.properties.has_value
    || auxiliary_port.slot.properties.value.position != (usz)idx) return false;
  }
  PracticalAgent* practical = &node.agent.practical;
  bool has_storage =
   practical.storage != mitos_storage::INVALID_STORAGE_HANDLE;
  if (has_storage)
  {
   if (!agent_type_supports_storage(node.type)
    || practical.owns_text || practical.text.len) return false;
   mitos_storage::StorageMetadata metadata;
   if (!practical.type_id || !practical.storage_stride
    || practical.storage_policy != mitos::CopyPolicy.COPY_SHARED_IMMUTABLE
    || mitos_storage::storage_metadata(
     &net.storage, practical.storage, &metadata
    ) != mitos_storage::StorageError.STORAGE_OK
    || !practical_storage_metadata_matches_agent(node.type, &metadata)
    || metadata.type_id != (mitos::TypeId)practical.type_id
    || metadata.copy_policy != practical.storage_policy
    || metadata.stride != practical.storage_stride
    || metadata.element_size != practical.storage_stride
    || !metadata.owner_count
    || practical.storage_count > usz::max / practical.storage_stride
    || metadata.byte_length
     != practical.storage_count * practical.storage_stride) return false;
  }
  else
  {
   if (practical.storage_count || practical.storage_stride
    || practical.storage_policy != mitos::CopyPolicy.COPY_TRIVIAL) return false;
   if (node.type == STRING_AGENT)
   {
    if (!practical.type_id || !practical.owns_text) return false;
   }
   else if (practical.owns_text || practical.text.len)
   {
    return false;
   }
  }
  if (node.type == COLLAPSE_AGENT && practical.auxiliaries.len != 1) return false;
  if (node.type == ARRAY_AGENT && has_storage && practical.auxiliaries.len) return false;
  if (node.type == EFFECT_AGENT
   && (!practical.effect_id || !practical.operation_id || !practical.effect_epoch)) return false;
  if (node.type == HANDLER_AGENT)
  {
   if (!practical.handler_id || !practical.effect_epoch) return false;
   if (practical.continuation != INVALID_NET_REF
    && !net.effects.continuations.contains_ref(practical.continuation)) return false;
  }
  if (node.type == RESUME_AGENT
   && (!practical.handler_id || !practical.effect_epoch
    || practical.resume_state != CONTINUATION_CAPTURED)) return false;
  if (node.type == ABORT_AGENT
   && (!practical.handler_id || !practical.operation_id
    || !practical.effect_epoch || practical.resume_state != CONTINUATION_ERASED)) return false;
  return true;
 }
}

fn bool nodes_are_valid(Net* net)
{
 for (SlotId id = 0; id < net.nodes.next_id; id++)
 {
  if (!net.nodes.contains_id(id)) continue;
  NetRef node_ref = net.nodes.generation_ref(id);
  if (!node_is_valid(net, node_ref, net.nodes.get_ref(node_ref))) return false;
 }

 return true;
}
fn bool observable_origins_are_valid(Net* net)
{
 for (SlotId first_id = 0; first_id < net.nodes.next_id; first_id++)
 {
  if (!net.nodes.contains_id(first_id)) continue;
  Node* first_node = net.nodes.get_ref(net.nodes.generation_ref(first_id));
  if (first_node.type != REPLICATOR) continue;
  Replicator* first = &first_node.agent.replicator;
  if (!first.observable) continue;
  for (SlotId second_id = first_id + 1; second_id < net.nodes.next_id; second_id++)
  {
   if (!net.nodes.contains_id(second_id)) continue;
   Node* second_node = net.nodes.get_ref(net.nodes.generation_ref(second_id));
   if (second_node.type != REPLICATOR) continue;
   Replicator* second = &second_node.agent.replicator;
   if (second.observable && second.origin == first.origin
    && second.auxiliaries.len != first.auxiliaries.len) return false;
  }
 }
 return true;
}

fn bool interfaces_are_valid(Net* net)
{
 for (SlotId first_id = 0; first_id < net.interfaces.next_id; first_id++)
 {
  if (!net.interfaces.contains_id(first_id)) continue;
  NetRef first_ref = net.interfaces.generation_ref(first_id);
  InterfacePort* first = net.interfaces.get_ref(first_ref);
  if (!net.ports.contains_ref(first.port)) return false;
  Port* boundary = net.ports.get_ref(first.port);
  if (boundary.node_id != INVALID_NET_REF
   || boundary.slot.type != AUXILIARY
   || boundary.slot.properties.has_value) return false;

  if (first.type == ROOT)
  {
   if (first.name.has_value || boundary.polarity != CHILD) return false;
  }
  else if (first.type == FREE_VARIABLE)
  {
   if (!first.name.has_value || first.name.value.len == 0
    || boundary.polarity != PARENT) return false;
  }
  else
  {
   return false;
  }

  for (SlotId second_id = first_id + 1;
   second_id < net.interfaces.next_id; second_id++)
  {
   if (!net.interfaces.contains_id(second_id)) continue;
   InterfacePort* second =
    net.interfaces.get_ref(net.interfaces.generation_ref(second_id));
   if (first.port == second.port) return false;
   if (first.type == ROOT && second.type == ROOT) return false;
   if (first.type == FREE_VARIABLE && second.type == FREE_VARIABLE
    && second.name.has_value && first.name.value == second.name.value) return false;
  }
 }
 return true;
}

fn bool add_port_owner(Net* net, char[] owner_counts, NetRef port_ref) @private
{
 if (!net.ports.contains_ref(port_ref)) return false;
 usz port_id = (usz)port_ref.id;
 if (owner_counts[port_id]) return false;
 owner_counts[port_id] = 1;
 return true;
}

fn bool ports_have_exactly_one_owner(Net* net)
{
 char[] owner_counts =
  alloc::new_array(mem, char, (sz)net.ports.next_id);
 defer alloc::free(mem, owner_counts);
 foreach (&count : owner_counts) *count = 0;

 for (SlotId node_id = 0; node_id < net.nodes.next_id; node_id++)
 {
  if (!net.nodes.contains_id(node_id)) continue;
  Node* node = net.nodes.get_ref(net.nodes.generation_ref(node_id));
  switch (node.type)
  {
  case ERASER:
   if (!add_port_owner(net, owner_counts, node.agent.eraser.principal))
   {
    return false;
   }
  case FAN:
   if (!add_port_owner(net, owner_counts, node.agent.fan.principal)
    || !add_port_owner(net, owner_counts, node.agent.fan.left)
    || !add_port_owner(net, owner_counts, node.agent.fan.right)) return false;
  case REPLICATOR:
   if (!add_port_owner(net, owner_counts, node.agent.replicator.principal))
   {
    return false;
   }
   foreach (auxiliary : node.agent.replicator.auxiliaries)
   {
    if (!add_port_owner(net, owner_counts, auxiliary)) return false;
   }
  default:
   if (!is_practical_agent_type(node.type)
    || !add_port_owner(net, owner_counts, node.agent.practical.principal))
   {
    return false;
   }
   foreach (auxiliary : node.agent.practical.auxiliaries)
   {
    if (!add_port_owner(net, owner_counts, auxiliary)) return false;
   }
  }
 }
 for (SlotId interface_id = 0;
  interface_id < net.interfaces.next_id; interface_id++)
 {
  if (!net.interfaces.contains_id(interface_id)) continue;
  InterfacePort* boundary =
   net.interfaces.get_ref(net.interfaces.generation_ref(interface_id));
  if (!add_port_owner(net, owner_counts, boundary.port)) return false;
 }
 for (SlotId port_id = 0; port_id < net.ports.next_id; port_id++)
 {
  if (net.ports.contains_id(port_id) && !owner_counts[(usz)port_id])
  {
   return false;
  }
 }
 return true;
}

fn bool wires_are_valid(Net* net)
{
 for (SlotId id = 0; id < net.wires.next_id; id++)
 {
  if (!net.wires.contains_id(id)) continue;
  NetRef wire_ref = net.wires.generation_ref(id);
  Wire* wire = net.wires.get_ref(wire_ref);
  if (wire.a == wire.b
   || !net.ports.contains_ref(wire.a)
   || !net.ports.contains_ref(wire.b)) return false;
  Port* a = net.ports.get_ref(wire.a);
  Port* b = net.ports.get_ref(wire.b);
  if (a.wire_id != wire_ref || b.wire_id != wire_ref
   || a.polarity == b.polarity) return false;
 }
 return true;
}

fn bool ports_have_live_wires(Net* net)
{
 for (SlotId id = 0; id < net.ports.next_id; id++)
 {
  if (!net.ports.contains_id(id)) continue;
  NetRef port_ref = net.ports.generation_ref(id);
  Port* port = net.ports.get_ref(port_ref);
  if (!net.wires.contains_ref(port.wire_id)) return false;
  Wire* wire = net.wires.get_ref(port.wire_id);
  if (wire.a != port_ref && wire.b != port_ref) return false;
 }
 return true;
}

// Storage handles are owner leases, not record IDs. One live handle may
// therefore appear in at most one practical agent; replicated shared records
// carry distinct handles and advertise their backing owner count via metadata.
fn bool practical_storage_owners_are_unique(Net* net) @private
{
 bool has_storage = false;
 usz last_owner_id = 0;
 for (SlotId node_id = 0; node_id < net.nodes.next_id; node_id++)
 {
  if (!net.nodes.contains_id(node_id)) continue;
  Node* node = net.nodes.get_ref(net.nodes.generation_ref(node_id));
  if (!is_practical_agent_type(node.type)
   || node.agent.practical.storage
    == mitos_storage::INVALID_STORAGE_HANDLE) continue;
  mitos_storage::StorageHandle handle = node.agent.practical.storage;
  if (handle.id >= (ulong)sz::max) return false;
  usz owner_id = (usz)handle.id;
  if (!has_storage || owner_id > last_owner_id) last_owner_id = owner_id;
  has_storage = true;
 }
 if (!has_storage) return true;
 char[] seen = alloc::new_array(mem, char, (sz)(last_owner_id + 1));
 defer alloc::free(mem, seen);
 foreach (&value : seen) *value = 0;
 for (SlotId node_id = 0; node_id < net.nodes.next_id; node_id++)
 {
  if (!net.nodes.contains_id(node_id)) continue;
  Node* node = net.nodes.get_ref(net.nodes.generation_ref(node_id));
  if (!is_practical_agent_type(node.type)
   || node.agent.practical.storage
    == mitos_storage::INVALID_STORAGE_HANDLE) continue;
  usz owner_id = (usz)node.agent.practical.storage.id;
  if (seen[owner_id]) return false;
  seen[owner_id] = 1;
 }
 return true;
}

fn bool effect_continuations_are_valid(Net* net)
{
 for (SlotId id = 0; id < net.effects.continuations.next_id; id++)
 {
  if (!net.effects.continuations.contains_id(id)) continue;
  NetRef continuation_ref = net.effects.continuations.generation_ref(id);
  EffectContinuation* continuation = net.effects.continuations.get_ref(continuation_ref);
  if (!net.ports.contains_ref(continuation.root)
   || !net.ports.contains_ref(continuation.hole)
   || !net.nodes.contains_ref(continuation.handler)
   || !continuation.effect_id
   || !continuation.operation_id
   || !continuation.effect_epoch) return false;
  if (!continuation.resume_count)
  {
   if (continuation.state != CONTINUATION_ERASED
    || !net.nodes.contains_ref(continuation.eraser)
    || net.nodes.get_ref(continuation.eraser).type != ERASER) return false;
  }
  if (continuation.multi && continuation.resume_count > 1)
  {
   if (continuation.state != CONTINUATION_REPLICATED
    || !net.nodes.contains_ref(continuation.first_replicator)
    || !net.nodes.contains_ref(continuation.second_replicator)
    || net.nodes.get_ref(continuation.first_replicator).type != REPLICATOR
    || net.nodes.get_ref(continuation.second_replicator).type != REPLICATOR) return false;
  }
  else if (continuation.first_replicator != INVALID_NET_REF
   || continuation.second_replicator != INVALID_NET_REF) return false;
 }
 for (usz index = 0; index < net.effects.commits.len; index++)
 {
  OrderedEffectCommit* commit = &net.effects.commits[index];
  if (!net.effects.continuations.contains_ref(commit.continuation)) return false;
  EffectContinuation* continuation = net.effects.continuations.get_ref(commit.continuation);
  if (!continuation.ordered
   || continuation.source_order != commit.source_root_order
   || continuation.occurrence_order != commit.operation_order) return false;
  if (index)
  {
   OrderedEffectCommit* previous = &net.effects.commits[index - 1];
   if (previous.source_root_order > commit.source_root_order
    || (previous.source_root_order == commit.source_root_order
     && previous.operation_order > commit.operation_order)) return false;
  }
 }
 return true;
}

fn bool validate_net(Net* net)
{
 return nodes_are_valid(net)
  && observable_origins_are_valid(net)
  && interfaces_are_valid(net)
  && ports_have_exactly_one_owner(net)
  && practical_storage_owners_are_unique(net)
  && wires_are_valid(net)
  && ports_have_live_wires(net)
  && effect_continuations_are_valid(net);
}
