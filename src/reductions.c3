module delta_net_abstract_machine;
fn void erase_redex(Net* net, StableId node_a_id, StableId node_b_id,
StableId wire_id, StableId port_a_id, StableId port_b_id)
{
 // Snapshot IDs before erasing: unordered erase can move dense entries.
 destroy_node_record(net, node_a_id);
 destroy_node_record(net, node_b_id);
 net.wires.erase(wire_id);
 net.ports.erase(port_a_id);
 net.ports.erase(port_b_id);
}

fn void eraser_eraser_reduction(Net* net, StableId node_a_id, StableId node_b_id,
StableId wire_id, StableId port_a_id, StableId port_b_id)
{
 erase_redex(net, node_a_id, node_b_id, wire_id, port_a_id, port_b_id);
}

fn void fan_eraser_reduction(Net* net, StableId fan_id, StableId eraser_id,
StableId wire_id, StableId fan_port_id, StableId eraser_port_id)
{
 Node* fan = net.nodes.get_ref(fan_id);
 StableId left_id = fan.agent.fan.left;
 StableId right_id = fan.agent.fan.right;

 // Each fan branch receives an eraser; the branch wires themselves survive.
 StableId left_eraser_id = net.nodes.push({
  .agent = { .eraser = { .principal = left_id }},
  .type = ERASER
 });
StableId right_eraser_id = net.nodes.push({
 .agent = { .eraser = { .principal = right_id }},
 .type = ERASER
});
Port* left = net.ports.get_ref(left_id);
Port* right = net.ports.get_ref(right_id);
left.node_id = left_eraser_id;
left.slot.type = PRINCIPAL;
right.node_id = right_eraser_id;
right.slot.type = PRINCIPAL;
erase_redex(net, fan_id, eraser_id, wire_id, fan_port_id, eraser_port_id);
}

fn void fan_fan_reduction(Net* net, StableId first_id, StableId second_id,
	StableId first_principal_id)
{
	Node* first = net.nodes.get_ref(first_id);
	Node* second = net.nodes.get_ref(second_id);
	StableId second_principal_id = second.agent.fan.principal;
	StableId principal_wire_id = net.ports.get_ref(first_principal_id).wire_id;

	// Canonicalize operand order because splice preserves its first wire ID.
	// This keeps the physical result independent of active-wire endpoint order;
	// it does not change either fan's auxiliary identities. The parent-principal
	// choice is only a deterministic wire-ownership choice, not an instruction
	// to pair different auxiliary indices.
	Node* parent_principal_fan =
		net.ports.get_ref(first_principal_id).polarity == PARENT ? first : second;
	Node* child_principal_fan = parent_principal_fan == first ? second : first;
	StableId first_left = parent_principal_fan.agent.fan.left;
	StableId first_right = parent_principal_fan.agent.fan.right;
	StableId second_left = child_principal_fan.agent.fan.left;
	StableId second_right = child_principal_fan.agent.fan.right;

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

fn void replicator_fan_reduction(Net* net, StableId replicator_id, StableId fan_id)
{
 Node* fan = net.nodes.get_ref(fan_id);
 Node* replicator = net.nodes.get_ref(replicator_id);
 StableId fan_principal = fan.agent.fan.principal;
 StableId fan_left = fan.agent.fan.left;
 StableId fan_right = fan.agent.fan.right;
 StableId old_principal_wire = net.ports.get_ref(fan_principal).wire_id;
 StableId old_replicator_principal = replicator.agent.replicator.principal;
 ulong replicator_delta_level = replicator.agent.replicator.delta_level;
 ReplicatorStatus replicator_status = replicator.agent.replicator.status;

 StableId[] old_auxiliaries = replicator.agent.replicator.auxiliaries;
 StableId[] left_auxiliaries = {};
 StableId[] right_auxiliaries = {};

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
    .status = replicator_status
   }},
 .type = REPLICATOR
};
Node right_copy = {
 .agent = { .replicator = {
   .principal = fan_right,
   .auxiliaries = right_auxiliaries,
   .delta_level = replicator_delta_level,
   .status = replicator_status
  }},
.type = REPLICATOR
};
StableId left_copy_id = net.nodes.push(left_copy);
StableId right_copy_id = net.nodes.push(right_copy);
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
 StableId new_left = net.ports.push({
  .wire_id = INVALID_STABLE_ID,
  .slot = { .type = LEFT },
  // A wire must connect opposite endpoint polarities.
  .polarity = opposite_polarity(
   net.ports.get_ref(left_auxiliaries[idx]).polarity)
 });
 StableId new_right = net.ports.push({
  .wire_id = INVALID_STABLE_ID,
  .slot = { .type = RIGHT },
  .polarity = opposite_polarity(
   net.ports.get_ref(right_auxiliaries[idx]).polarity)
 });
 StableId new_fan_id = net.nodes.push({ .agent = { .fan = {
    .principal = old_auxiliary_id, .left = new_left, .right = new_right }}, .type = FAN });
 net.ports.get_ref(old_auxiliary_id).node_id = new_fan_id;
 net.ports.get_ref(new_left).node_id = new_fan_id;
 net.ports.get_ref(new_right).node_id = new_fan_id;
 (void)connect(net, new_left, left_auxiliaries[idx]);
 (void)connect(net, new_right, right_auxiliaries[idx]);
}

destroy_node_record(net, replicator_id);
destroy_node_record(net, fan_id);
net.ports.erase(old_replicator_principal);
net.ports.erase(fan_principal);
net.wires.erase(old_principal_wire);
}



fn void replicator_replicator_reduction(Net* net, StableId first_id,
StableId second_id)
{
 Node* first = net.nodes.get_ref(first_id);
 Node* second = net.nodes.get_ref(second_id);
 StableId first_principal = first.agent.replicator.principal;
 StableId second_principal = second.agent.replicator.principal;
 StableId principal_wire = net.ports.get_ref(first_principal).wire_id;
 StableId[] first_auxiliaries = first.agent.replicator.auxiliaries;
 StableId[] second_auxiliaries = second.agent.replicator.auxiliaries;
 ulong first_level = first.agent.replicator.delta_level;
 ulong second_level = second.agent.replicator.delta_level;

 if (first_level == second_level)
 {
  assert(first_auxiliaries.len == second_auxiliaries.len,
  "Equal-level replicators must have the same arity");

  foreach (idx, first_auxiliary : first_auxiliaries)
  {
   StableId second_auxiliary = second_auxiliaries[idx];
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
  StableId first_wire = net.ports.get_ref(first_auxiliary).wire_id;
  StableId second_wire = net.ports.get_ref(second_auxiliary).wire_id;
  StableId second_external = other_endpoint(net, second_wire, second_auxiliary);

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

erase_redex(net, first_id, second_id, principal_wire,
first_principal, second_principal);
return;
}

StableId higher_id = first_level > second_level ? first_id : second_id;
StableId lower_id = first_level > second_level ? second_id : first_id;
StableId higher_principal = first_level > second_level
? first_principal : second_principal;
StableId lower_principal = first_level > second_level
? second_principal : first_principal;
StableId[] higher_auxiliaries = first_level > second_level
? first_auxiliaries : second_auxiliaries;
StableId[] lower_auxiliaries = first_level > second_level
? second_auxiliaries : first_auxiliaries;
ReplicatorStatus higher_status = first_level > second_level
? first.agent.replicator.status : second.agent.replicator.status;
ReplicatorStatus lower_status = first_level > second_level
? second.agent.replicator.status : first.agent.replicator.status;
ulong higher_level = first_level > second_level ? first_level : second_level;
ulong lower_level = first_level > second_level ? second_level : first_level;
sz higher_count = higher_auxiliaries.len;
sz lower_count = lower_auxiliaries.len;

Port[] higher_templates = mem::alloc_array(Port, higher_count);
Port[] lower_templates = mem::alloc_array(Port, lower_count);
StableId[][] higher_rows = mem::alloc_array(StableId[], lower_count);
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
 StableId[] auxiliaries = mem::alloc_array(StableId, higher_count);
 int128 replica_level = (int128)higher_level
 + (int128)lower_templates[lower_idx].slot.properties.value.delta_level;
 assert(replica_level >= 0
 && replica_level <= (int128)18_446_744_073_709_551_615,
 "Replicator level is out of range");
 StableId copy_id = net.nodes.push({
  .agent = { .replicator = {
    .principal = principal,
    .auxiliaries = auxiliaries,
    .delta_level = (ulong)replica_level,
    .status = higher_status
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
 StableId[] auxiliaries = mem::alloc_array(StableId, lower_count);
 StableId copy_id = net.nodes.push({
  .agent = { .replicator = {
    .principal = principal,
    .auxiliaries = auxiliaries,
    .delta_level = lower_level,
    .status = lower_status
   }},
 .type = REPLICATOR
});

Port* principal_port = net.ports.get_ref(principal);
principal_port.node_id = copy_id;
principal_port.slot = { .type = PRINCIPAL };

foreach (lower_idx, template : lower_templates)
{
 StableId lower_auxiliary = clone_port_value(net, template, copy_id);
auxiliaries[lower_idx] = lower_auxiliary;

StableId higher_auxiliary = higher_rows[lower_idx][higher_idx];
(void)connect(net, higher_auxiliary, lower_auxiliary);
}
}

erase_redex(net, higher_id, lower_id, principal_wire,
higher_principal, lower_principal);
}

fn void replicator_eraser_reduction(Net* net, StableId replicator_id,
StableId eraser_id)
{
 Node* replicator = net.nodes.get_ref(replicator_id);
 Node* eraser = net.nodes.get_ref(eraser_id);

 StableId replicator_principal =
 replicator.agent.replicator.principal;

 StableId eraser_port =
 eraser.agent.eraser.principal;

 StableId principal_wire_id =
 net.ports.get_ref(replicator_principal).wire_id;

 // Snapshot the auxiliary IDs before mutating or erasing the
 // replicator node. The auxiliary wires remain in the net.
 StableId[] auxiliaries = replicator.agent.replicator.auxiliaries;

 foreach (auxiliary_id : auxiliaries)
 {
  // Every auxiliary port receives a new eraser.
  StableId auxiliary_eraser_id = net.nodes.push({
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
auxiliary_port.slot.type = PRINCIPAL;
}

// Remove the original replicator, the interacting eraser, their
// principal ports, and the active principal wire.
erase_redex(
net,
replicator_id,
eraser_id,
principal_wire_id,
replicator_principal,
eraser_port
);
}


fn void interact(Net* net, StableId wire_id)
{
 if (!is_active(net, wire_id)) return;
 Wire* wire = net.wires.get_ref(wire_id);
 StableId port_a_id = wire.a;
 StableId port_b_id = wire.b;
 Port* port_a = net.ports.get_ref(port_a_id);
 Port* port_b = net.ports.get_ref(port_b_id);
 StableId node_a_id = port_a.node_id;
 StableId node_b_id = port_b.node_id;
 AgentType type_a = net.nodes.get_ref(node_a_id).type;
 AgentType type_b = net.nodes.get_ref(node_b_id).type;

 switch (type_a)
 {
 case ERASER:
  switch (type_b)
  {
  case ERASER:
   eraser_eraser_reduction(net, node_a_id, node_b_id, wire_id,
   port_a_id, port_b_id);
  case FAN:
   fan_eraser_reduction(net, node_b_id, node_a_id, wire_id,
   port_b_id, port_a_id);
  case REPLICATOR:
   replicator_eraser_reduction(net, node_b_id, node_a_id);
  default: ;
  }
case FAN:
 switch (type_b)
 {
 case ERASER:
  fan_eraser_reduction(net, node_a_id, node_b_id, wire_id,
  port_a_id, port_b_id);
 case FAN:
  fan_fan_reduction(net, node_a_id, node_b_id, port_a_id);
 case REPLICATOR:
  replicator_fan_reduction(net, node_b_id, node_a_id);
 default: ;
 }
case REPLICATOR:
 switch (type_b)
 {
 case FAN:
  replicator_fan_reduction(net, node_a_id, node_b_id);
 case REPLICATOR:
  replicator_replicator_reduction(net, node_a_id, node_b_id);
 case ERASER:
  replicator_eraser_reduction(net, node_a_id, node_b_id);
 default: ;
 }
default: ;
}
}
