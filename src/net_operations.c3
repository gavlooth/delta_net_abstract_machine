module delta_net_abstract_machine;
import std::collections::maybe;

// Net construction and mutation are coordinator-serialized in this wave.
// Stable slot addresses therefore may be used across arena pushes here; worker
// rewrites must claim every retained slot before parallel execution is enabled.

fn Net* Net.init(&self)
{
 self.ports.init();
 self.wires.init();
 self.nodes.init();
 self.interfaces.init();
 self.effects.continuations.init();
 return self;
}

fn void Net.free(&self)
{
 // Net mutation is coordinator-serialized in this wave, so enumerating live
 // generation references is safe while no rewrite can retire a node.
 for (SlotId id = 0; id < self.nodes.next_id; id++)
 {
  if (!self.nodes.contains_id(id)) continue;
  NetRef node_ref = self.nodes.generation_ref(id);
  Node* node = self.nodes.get_ref(node_ref);
  if (node.type == REPLICATOR)
  {
   mem::free(node.agent.replicator.auxiliaries);
  }
  else if (is_practical_agent_type(node.type))
  {
   mem::free(node.agent.practical.auxiliaries);
   if (node.agent.practical.owns_text)
   {
    mem::free(node.agent.practical.text);
   }
  }
 }
 self.ports.free();
 self.wires.free();
 self.nodes.free();
 self.interfaces.free();
 self.effects.continuations.free();
 mem::free(self.effects.commits);
 self.effects = { };
}

fn NetRef clone_port_value(Net* net, Port source, NetRef node_id) @private
{
 source.node_id = node_id;
 source.wire_id = INVALID_NET_REF;
 return net.ports.push(source);
}

fn NetRef clone_port(Net* net, NetRef source_port_id, NetRef node_id)
{
 return clone_port_value(net, net.ports.get(source_port_id), node_id);
}

// The returned slice is owned by the caller until it is transferred to a node.
fn NetRef[] clone_ports(Net* net, NetRef[] source_port_ids,
 NetRef node_id)
{
 NetRef[] clones = mem::alloc_array(NetRef, source_port_ids.len);
 foreach (idx, source_port_id : source_port_ids)
 {
  clones[idx] = clone_port(net, source_port_id, node_id);
 }
 return clones;
}


fn NetRef new_fan(Net* net, Polarity principal_polarity = PARENT)
{
 // Auxiliary identity follows the agent-local counterclockwise order:
 // LEFT is auxiliary 1 and RIGHT is auxiliary 2. Like a handshake, matching
 // two facing fans connects LEFT to LEFT and RIGHT to RIGHT; page positions
 // may appear crossed but never change the port identities.
 //
 //   principal PARENT (abstraction): left/aux1 CHILD,  right/aux2 PARENT
 //   principal CHILD  (application): left/aux1 PARENT, right/aux2 CHILD
 //
 // Do not swap fields when rendering or matching a rotated fan.
 NetRef principal = net.ports.push({
  .node_id = INVALID_NET_REF,
  .wire_id = INVALID_NET_REF,
  .slot = { .type = PRINCIPAL },
  .polarity = principal_polarity
 });
 NetRef left = net.ports.push({
  .node_id = INVALID_NET_REF,
  .wire_id = INVALID_NET_REF,
  .slot = { .type = LEFT },
  // LEFT is auxiliary 1: abstraction body or application result.
  .polarity = opposite_polarity(principal_polarity)
 });
 NetRef right = net.ports.push({
  .node_id = INVALID_NET_REF,
  .wire_id = INVALID_NET_REF,
  .slot = { .type = RIGHT },
  // RIGHT is auxiliary 2: abstraction variable or application argument.
  .polarity = principal_polarity
 });
 NetRef node_id = net.nodes.push({
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

fn NetRef new_eraser(Net* net, Polarity principal_polarity = CHILD)
{
 NetRef principal = net.ports.push({
  .node_id = INVALID_NET_REF,
  .wire_id = INVALID_NET_REF,
  .slot = { .type = PRINCIPAL },
  .polarity = principal_polarity
 });
 NetRef node_id = net.nodes.push({
  .agent = { .eraser = { .principal = principal }},
  .type = ERASER
 });
 net.ports.get_ref(principal).node_id = node_id;
 return node_id;
}

fn NetRef new_replicator(Net* net, ulong level, long[] ordered_deltas,
 ReplicatorStatus status, Polarity principal_polarity,
 bool observable = false, ulong origin = 0)
{
 NetRef principal = net.ports.push({
  .node_id = INVALID_NET_REF,
  .wire_id = INVALID_NET_REF,
  .slot = { .type = PRINCIPAL },
  .polarity = principal_polarity
 });
 NetRef[] auxiliaries = mem::alloc_array(NetRef, ordered_deltas.len);
 NetRef node_id = net.nodes.push({
  .agent = { .replicator = {
   .auxiliaries = auxiliaries,
   .principal = principal,
   .delta_level = level,
   .status = status,
   .observable = observable,
   .origin = origin
  }},
  .type = REPLICATOR
 });
 net.ports.get_ref(principal).node_id = node_id;
 foreach (idx, delta : ordered_deltas)
 {
  auxiliaries[idx] = net.ports.push({
   .node_id = node_id,
   .wire_id = INVALID_NET_REF,
   .slot = {
    .type = AUXILIARY,
    .properties = {
     .value = {
      .position = (usz)idx,
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

fn NetRef new_practical_agent(
 Net* net,
 AgentType type,
 usz arity,
 uint semantic_id = 0,
 uint type_id = 0,
 long payload = 0,
 usz descriptor = 0,
 usz source_order = 0
)
{
 assert(is_practical_agent_type(type), "Core interaction agents are not practical agents");
 NetRef principal = net.ports.push({
  .node_id = INVALID_NET_REF,
  .wire_id = INVALID_NET_REF,
  .slot = { .type = PRINCIPAL },
  .polarity = PARENT
 });
 NetRef[] auxiliaries = mem::alloc_array(NetRef, (sz)arity);
 NetRef node_id = net.nodes.push({
  .agent = { .practical = {
   .principal = principal,
   .auxiliaries = auxiliaries,
   .semantic_id = semantic_id,
   .type_id = type_id,
   .payload = payload,
   .descriptor = descriptor,
   .source_order = source_order,
   .text = "",
   .owns_text = false,
   .occurrence_order = 0,
   .continuation = INVALID_NET_REF,
  }},
  .type = type
 });
 net.ports.get_ref(principal).node_id = node_id;
 foreach (index, &auxiliary : auxiliaries)
 {
  *auxiliary = net.ports.push({
   .node_id = node_id,
   .wire_id = INVALID_NET_REF,
   .slot = {
    .type = AUXILIARY,
    .properties = {
     .value = { .position = (usz)index },
     .has_value = true
    }
   },
   .polarity = CHILD
  });
 }
 return node_id;
}

fn NetRef new_effect_continuation(
 Net* net,
 NetRef root,
 NetRef hole,
 NetRef handler,
 uint handler_id,
 uint effect_id,
 uint operation_id,
 ulong effect_epoch,
 usz resume_count,
 usz source_order,
 usz occurrence_order,
 bool multi,
 HostEffectKind host_effect,
 bool ordered,
 NetRef eraser = INVALID_NET_REF
)
{
 EffectContinuation continuation = {
  .root = root,
  .hole = hole,
  .handler = handler,
  .eraser = eraser,
  .first_replicator = INVALID_NET_REF,
  .second_replicator = INVALID_NET_REF,
  .handler_id = handler_id,
  .effect_id = effect_id,
  .operation_id = operation_id,
  .effect_epoch = effect_epoch,
  .resume_count = resume_count,
  .source_order = source_order,
  .occurrence_order = occurrence_order,
  .state = resume_count ? CONTINUATION_CAPTURED : CONTINUATION_ERASED,
  .host_effect = host_effect,
  .multi = multi,
  .ordered = ordered,
 };
 if (multi && resume_count > 1)
 {
  long[] deltas = mem::alloc_array(long, (sz)resume_count);
  foreach (index, &delta : deltas) *delta = (long)index;
  continuation.first_replicator = new_replicator(
   net, effect_epoch, deltas, UNKNOWN, PARENT
  );
  continuation.second_replicator = new_replicator(
   net, effect_epoch, deltas, UNKNOWN, CHILD
  );
  mem::free(deltas);
  Node* first = net.nodes.get_ref(continuation.first_replicator);
  Node* second = net.nodes.get_ref(continuation.second_replicator);
  (void)connect(net, first.agent.replicator.principal, second.agent.replicator.principal);
  foreach (index, auxiliary : first.agent.replicator.auxiliaries)
   (void)connect(net, auxiliary, second.agent.replicator.auxiliaries[index]);
  continuation.state = CONTINUATION_REPLICATED;
 }
 return net.effects.continuations.push(continuation);
}

fn NetRef new_interface(Net* net, InterfacePortType type, String name)
{
 assert(type == ROOT || name.len > 0,
  "A free-variable interface must have a name");
 NetRef port = net.ports.push({
  .node_id = INVALID_NET_REF,
  .wire_id = INVALID_NET_REF,
  .slot = { .type = AUXILIARY },
  .polarity = type == ROOT ? CHILD : PARENT
 });
 Maybe{String} optional_name;
 if (type == FREE_VARIABLE) optional_name.set(name);
 return net.interfaces.push({
  .type = type,
  .name = optional_name,
  .port = port
 });
}

fn NetRef connect(Net* net, NetRef port_a, NetRef port_b)
{
 assert(port_a != port_b, "A wire must have two distinct endpoints");
 Port* a = net.ports.get_ref(port_a);
 Port* b = net.ports.get_ref(port_b);
 assert(a.polarity != b.polarity,
  "A wire must connect one parent port and one child port");
 assert(!net.wires.contains_ref(a.wire_id), "First port is already connected");
 assert(!net.wires.contains_ref(b.wire_id), "Second port is already connected");
 NetRef wire_id = net.wires.push({ .a = port_a, .b = port_b });
 net.ports.get_ref(port_a).wire_id = wire_id;
 net.ports.get_ref(port_b).wire_id = wire_id;
 return wire_id;
}

fn void disconnect(Net* net, NetRef wire_id)
{
 Wire wire = net.wires.get(wire_id);
 Port* a = net.ports.get_ref(wire.a);
 Port* b = net.ports.get_ref(wire.b);
 assert(a.wire_id == wire_id && b.wire_id == wire_id,
  "Wire endpoint back-references do not agree");
 a.wire_id = INVALID_NET_REF;
 b.wire_id = INVALID_NET_REF;
 net.wires.erase(wire_id);
}

fn NetRef other_endpoint(Net* net, NetRef wire_id, NetRef endpoint_id)
{
 Wire* wire = net.wires.get_ref(wire_id);
 assert(wire.a == endpoint_id || wire.b == endpoint_id,
  "Port is not an endpoint of its wire");
 return wire.a == endpoint_id ? wire.b : wire.a;
}

fn NetRef splice(Net* net, NetRef port_a, NetRef port_b)
{
 Port* a = net.ports.get_ref(port_a);
 Port* b = net.ports.get_ref(port_b);
 NetRef wire_a_id = a.wire_id;
 NetRef wire_b_id = b.wire_id;
 assert(net.wires.contains_ref(wire_a_id), "First splice port is not connected");
 assert(net.wires.contains_ref(wire_b_id), "Second splice port is not connected");

 if (wire_a_id == wire_b_id)
 {
  disconnect(net, wire_a_id);
  return INVALID_NET_REF;
 }

 NetRef external_a = other_endpoint(net, wire_a_id, port_a);
 NetRef external_b = other_endpoint(net, wire_b_id, port_b);
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
 net.ports.get_ref(port_a).wire_id = INVALID_NET_REF;
 net.ports.get_ref(port_b).wire_id = INVALID_NET_REF;
 net.ports.get_ref(external_a).wire_id = wire_a_id;
 net.wires.erase(wire_b_id);
 return wire_a_id;
}

fn void destroy_node_record(Net* net, NetRef node_id)
{
 Node* node = net.nodes.get_ref(node_id);
 if (node.type == REPLICATOR)
 {
  mem::free(node.agent.replicator.auxiliaries);
 }
 else if (is_practical_agent_type(node.type))
 {
  mem::free(node.agent.practical.auxiliaries);
  if (node.agent.practical.owns_text)
  {
   mem::free(node.agent.practical.text);
  }
 }
 net.nodes.erase(node_id);
}

fn void destroy_port(Net* net, NetRef port_id) @private
{
 Port* port = net.ports.get_ref(port_id);
 if (net.wires.contains_ref(port.wire_id))
 {
  Wire* wire = net.wires.get_ref(port.wire_id);
  assert(wire.a == port_id || wire.b == port_id,
   "Port wire back-reference does not agree");
  disconnect(net, port.wire_id);
 }
 net.ports.erase(port_id);
}

fn void destroy_node(Net* net, NetRef node_id)
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
  if (!is_practical_agent_type(node.type)) unreachable("Unknown node type");
  destroy_port(net, node.agent.practical.principal);
  foreach (auxiliary : node.agent.practical.auxiliaries)
  {
   destroy_port(net, auxiliary);
  }
  mem::free(node.agent.practical.auxiliaries);
  if (node.agent.practical.owns_text)
  {
   mem::free(node.agent.practical.text);
  }
 }
 net.nodes.erase(node_id);
}


fn bool is_active(Net* net, NetRef wire_id)
{
 if (!net.wires.contains_ref(wire_id)) return false;
 Wire* wire = net.wires.get_ref(wire_id);
 if (wire.a == wire.b
  || !net.ports.contains_ref(wire.a)
  || !net.ports.contains_ref(wire.b)) return false;
 Port* a = net.ports.get_ref(wire.a);
 Port* b = net.ports.get_ref(wire.b);
 if (a.wire_id != wire_id || b.wire_id != wire_id
  || a.slot.type != PRINCIPAL || b.slot.type != PRINCIPAL
  || !net.nodes.contains_ref(a.node_id)
  || !net.nodes.contains_ref(b.node_id)) return false;
 return node_references_port(net.nodes.get_ref(a.node_id), wire.a)
  && node_references_port(net.nodes.get_ref(b.node_id), wire.b);
}
