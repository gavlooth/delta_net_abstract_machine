module delta_net_abstract_machine;
import std::collections::maybe;

fn Net* Net.init(&self)
{
 self.ports.init();
 self.wires.init();
 self.nodes.init();
 self.interfaces.init();
 return self;
}

fn void Net.free(&self)
{
 foreach (&node : self.nodes.array_view())
 {
  if (node.type == REPLICATOR)
  {
   mem::free(node.agent.replicator.auxiliaries);
  }
 }
 self.ports.free();
 self.wires.free();
 self.nodes.free();
 self.interfaces.free();
}

fn StableId clone_port_value(Net* net, Port source, StableId node_id) @private
{
 source.node_id = node_id;
 source.wire_id = INVALID_STABLE_ID;
 return net.ports.push(source);
}

fn StableId clone_port(Net* net, StableId source_port_id, StableId node_id)
{
 return clone_port_value(net, net.ports.get(source_port_id), node_id);
}

// The returned slice is owned by the caller until it is transferred to a node.
fn StableId[] clone_ports(Net* net, StableId[] source_port_ids,
 StableId node_id)
{
 StableId[] clones = mem::alloc_array(StableId, source_port_ids.len);
 foreach (idx, source_port_id : source_port_ids)
 {
  clones[idx] = clone_port(net, source_port_id, node_id);
 }
 return clones;
}


fn StableId new_fan(Net* net)
{
 StableId principal = net.ports.push({
  .wire_id = INVALID_STABLE_ID,
  .slot = { .type = PRINCIPAL },
  .polarity = PARENT
 });
 StableId left = net.ports.push({
  .wire_id = INVALID_STABLE_ID,
  .slot = { .type = LEFT },
  .polarity = PARENT
 });
 StableId right = net.ports.push({
  .wire_id = INVALID_STABLE_ID,
  .slot = { .type = RIGHT },
  .polarity = CHILD
 });
 StableId node_id = net.nodes.push({
  .agent = { .fan = {
   .principal = principal,
   .left = left,
   .right = right
  }},
  .type = FAN
 });
 net.ports.get_ref(principal).node_id = node_id;
 net.ports.get_ref(left).node_id = node_id;
 net.ports.get_ref(right).node_id = node_id;
 return node_id;
}

fn StableId new_eraser(Net* net)
{
 StableId principal = net.ports.push({
  .wire_id = INVALID_STABLE_ID,
  .slot = { .type = PRINCIPAL },
  .polarity = CHILD
 });
 StableId node_id = net.nodes.push({
  .agent = { .eraser = { .principal = principal }},
  .type = ERASER
 });
 net.ports.get_ref(principal).node_id = node_id;
 return node_id;
}

fn StableId new_replicator(Net* net, ulong level, long[] ordered_deltas,
 ReplicatorStatus status, Polarity principal_polarity)
{
 StableId principal = net.ports.push({
  .wire_id = INVALID_STABLE_ID,
  .slot = { .type = PRINCIPAL },
  .polarity = principal_polarity
 });
 StableId[] auxiliaries = mem::alloc_array(StableId, ordered_deltas.len);
 StableId node_id = net.nodes.push({
  .agent = { .replicator = {
   .auxiliaries = auxiliaries,
   .principal = principal,
   .delta_level = level,
   .status = status
  }},
  .type = REPLICATOR
 });
 net.ports.get_ref(principal).node_id = node_id;
 foreach (idx, delta : ordered_deltas)
 {
  auxiliaries[idx] = net.ports.push({
   .node_id = node_id,
   .wire_id = INVALID_STABLE_ID,
   .slot = {
    .type = AUXILIARY,
    .properties = {
     .value = {
      .position = (StableId)idx,
      .delta_level = delta
     },
     .has_value = true
    }
   },
   .polarity = opposite_polarity(principal_polarity)
  });
 }
 return node_id;
}

fn StableId new_interface(Net* net, InterfacePortType type, String name)
{
 assert(type == ROOT || name.len > 0,
  "A free-variable interface must have a name");
 StableId port = net.ports.push({
  .node_id = INVALID_STABLE_ID,
  .wire_id = INVALID_STABLE_ID,
  .slot = { .type = AUXILIARY },
  .polarity = type == ROOT ? PARENT : CHILD
 });
 Maybe{String} optional_name;
 if (type == FREE_VARIABLE) optional_name.set(name);
 return net.interfaces.push({
  .type = type,
  .name = optional_name,
  .port = port
 });
}

fn StableId connect(Net* net, StableId port_a, StableId port_b)
{
 assert(port_a != port_b, "A wire must have two distinct endpoints");
 Port* a = net.ports.get_ref(port_a);
 Port* b = net.ports.get_ref(port_b);
 assert(a.polarity != b.polarity,
  "A wire must connect one parent port and one child port");
 assert(!net.wires.contains(a.wire_id), "First port is already connected");
 assert(!net.wires.contains(b.wire_id), "Second port is already connected");
 StableId wire_id = net.wires.push({ .a = port_a, .b = port_b });
 net.ports.get_ref(port_a).wire_id = wire_id;
 net.ports.get_ref(port_b).wire_id = wire_id;
 return wire_id;
}

fn void disconnect(Net* net, StableId wire_id)
{
 Wire wire = net.wires.get(wire_id);
 Port* a = net.ports.get_ref(wire.a);
 Port* b = net.ports.get_ref(wire.b);
 assert(a.wire_id == wire_id && b.wire_id == wire_id,
  "Wire endpoint back-references do not agree");
 a.wire_id = INVALID_STABLE_ID;
 b.wire_id = INVALID_STABLE_ID;
 net.wires.erase(wire_id);
}

fn StableId other_endpoint(Net* net, StableId wire_id, StableId endpoint_id)
{
 Wire* wire = net.wires.get_ref(wire_id);
 assert(wire.a == endpoint_id || wire.b == endpoint_id,
  "Port is not an endpoint of its wire");
 return wire.a == endpoint_id ? wire.b : wire.a;
}

fn StableId splice(Net* net, StableId port_a, StableId port_b)
{
 Port* a = net.ports.get_ref(port_a);
 Port* b = net.ports.get_ref(port_b);
 StableId wire_a_id = a.wire_id;
 StableId wire_b_id = b.wire_id;
 assert(net.wires.contains(wire_a_id), "First splice port is not connected");
 assert(net.wires.contains(wire_b_id), "Second splice port is not connected");

 if (wire_a_id == wire_b_id)
 {
  disconnect(net, wire_a_id);
  return INVALID_STABLE_ID;
 }

 StableId external_a = other_endpoint(net, wire_a_id, port_a);
 StableId external_b = other_endpoint(net, wire_b_id, port_b);
 Wire* wire_a = net.wires.get_ref(wire_a_id);
 if (wire_a.a == port_a)
 {
  wire_a.a = external_b;
 }
 else
 {
  wire_a.b = external_b;
 }
 net.ports.get_ref(external_b).wire_id = wire_a_id;
 net.ports.get_ref(port_a).wire_id = INVALID_STABLE_ID;
 net.ports.get_ref(port_b).wire_id = INVALID_STABLE_ID;
 net.ports.get_ref(external_a).wire_id = wire_a_id;
 net.wires.erase(wire_b_id);
 return wire_a_id;
}

fn void destroy_node_record(Net* net, StableId node_id)
{
 Node* node = net.nodes.get_ref(node_id);
 if (node.type == REPLICATOR)
 {
  mem::free(node.agent.replicator.auxiliaries);
 }
 net.nodes.erase(node_id);
}

fn void destroy_port(Net* net, StableId port_id) @private
{
 Port* port = net.ports.get_ref(port_id);
 if (net.wires.contains(port.wire_id))
 {
  Wire* wire = net.wires.get_ref(port.wire_id);
  assert(wire.a == port_id || wire.b == port_id,
   "Port wire back-reference does not agree");
  disconnect(net, port.wire_id);
 }
 net.ports.erase(port_id);
}

fn void destroy_node(Net* net, StableId node_id)
{
 Node node = net.nodes.get(node_id);
 switch (node.type)
 {
 case FAN:
  destroy_port(net, node.agent.fan.principal);
  destroy_port(net, node.agent.fan.left);
  destroy_port(net, node.agent.fan.right);
 case ERASER:
  destroy_port(net, node.agent.eraser.principal);
 case REPLICATOR:
  destroy_port(net, node.agent.replicator.principal);
  foreach (auxiliary : node.agent.replicator.auxiliaries)
  {
   destroy_port(net, auxiliary);
  }
  mem::free(node.agent.replicator.auxiliaries);
 default:
  unreachable("Unknown node type");
 }
 net.nodes.erase(node_id);
}


fn bool is_active(Net* net, StableId wire_id)
{
 if (!net.wires.contains(wire_id)) return false;
 Wire* wire = net.wires.get_ref(wire_id);
 if (!net.ports.contains(wire.a) || !net.ports.contains(wire.b)) return false;
 return net.ports.get_ref(wire.a).slot.type == PRINCIPAL
 && net.ports.get_ref(wire.b).slot.type == PRINCIPAL;
}
