module delta_net_abstract_machine;
import std::core::main_stub;
import std::collections::maybe;
import delta_net_abstract_machine::stable_index_vector;

enum PortType : uint { PRINCIPAL, LEFT, RIGHT, AUXILIARY }
enum AgentType { REPLICATOR, FAN, ERASER }

struct AuxiliaryPortMetadata { StableId position; StableId delta_level; }
struct PortSlot { PortType type; Maybe{AuxiliaryPortMetadata} properties; }
struct Port { StableId node_id; StableId wire_id; PortSlot slot; }
struct Wire { StableId a; StableId b; }
struct Fan { StableId principal; StableId left; StableId right; }
struct Eraser { StableId principal; }
struct Replicator { StableId[] auxiliaries; StableId principal; }

union Agent { Fan fan; Eraser eraser; Replicator replicator; }
struct Node { Agent agent; AgentType type; }
struct Net { Siv{Port} ports; Siv{Wire} wires; Siv{Node} nodes; }

fn Net* Net.init(&self)
{
 self.ports.init(); self.wires.init(); self.nodes.init(); return self;
}

fn void Net.free(&self)
{
 self.ports.free(); self.wires.free(); self.nodes.free();
}

fn bool is_active(Net* net, StableId wire_id)
{
 if (!net.wires.contains(wire_id)) return false;
 Wire* wire = net.wires.get_ref(wire_id);
 if (!net.ports.contains(wire.a) || !net.ports.contains(wire.b)) return false;
 return net.ports.get_ref(wire.a).slot.type == PRINCIPAL &&
  net.ports.get_ref(wire.b).slot.type == PRINCIPAL;
}

fn StableId other_endpoint(Net* net, StableId wire_id, StableId endpoint_id)
{
 Wire* wire = net.wires.get_ref(wire_id);
 assert(wire.a == endpoint_id || wire.b == endpoint_id,
  "Port is not an endpoint of its wire");
 return wire.a == endpoint_id ? wire.b : wire.a;
}

fn void erase_redex(Net* net, StableId node_a_id, StableId node_b_id,
 StableId wire_id, StableId port_a_id, StableId port_b_id)
{
 // Snapshot IDs before erasing: unordered erase can move dense entries.
 net.nodes.erase(node_a_id); net.nodes.erase(node_b_id);
 net.wires.erase(wire_id);
 net.ports.erase(port_a_id); net.ports.erase(port_b_id);
}

fn void eraser_eraser_reduction(Net* net, StableId node_a_id, StableId node_b_id,
 StableId wire_id, StableId port_a_id, StableId port_b_id)
{ erase_redex(net, node_a_id, node_b_id, wire_id, port_a_id, port_b_id); }

fn void fan_eraser_reduction(Net* net, StableId fan_id, StableId eraser_id,
 StableId wire_id, StableId fan_port_id, StableId eraser_port_id)
{
 Node* fan = net.nodes.get_ref(fan_id);
 StableId left_id = fan.agent.fan.left;
 StableId right_id = fan.agent.fan.right;

 // Each fan branch receives an eraser; the branch wires themselves survive.
 StableId left_eraser_id = net.nodes.push({
  .agent = { .eraser = { .principal = left_id }}, .type = ERASER });
 StableId right_eraser_id = net.nodes.push({
  .agent = { .eraser = { .principal = right_id }}, .type = ERASER });
 Port* left = net.ports.get_ref(left_id);
 Port* right = net.ports.get_ref(right_id);
 left.node_id = left_eraser_id; left.slot.type = PRINCIPAL;
 right.node_id = right_eraser_id; right.slot.type = PRINCIPAL;
 erase_redex(net, fan_id, eraser_id, wire_id, fan_port_id, eraser_port_id);
}

fn void fan_fan_reduction(Net* net, StableId first_id, StableId second_id,
 StableId first_principal_id)
{
 Node* first = net.nodes.get_ref(first_id);
 Node* second = net.nodes.get_ref(second_id);
 StableId first_left = first.agent.fan.left;
 StableId first_right = first.agent.fan.right;
 StableId second_left = second.agent.fan.left;
 StableId second_right = second.agent.fan.right;
 StableId first_left_wire_id = net.ports.get_ref(first_left).wire_id;
 StableId first_right_wire_id = net.ports.get_ref(first_right).wire_id;
 StableId second_left_wire_id = net.ports.get_ref(second_left).wire_id;
 StableId second_right_wire_id = net.ports.get_ref(second_right).wire_id;
 StableId principal_wire_id = net.ports.get_ref(first_principal_id).wire_id;
 StableId left_external = other_endpoint(net, second_left_wire_id, second_left);
 StableId right_external = other_endpoint(net, second_right_wire_id, second_right);

 Wire* left_wire = net.wires.get_ref(first_left_wire_id);
 if (left_wire.a == first_left) { left_wire.a = left_external; }
 else { left_wire.b = left_external; }
 Wire* right_wire = net.wires.get_ref(first_right_wire_id);
 if (right_wire.a == first_right) { right_wire.a = right_external; }
 else { right_wire.b = right_external; }

 StableId second_principal_id = second.agent.fan.principal;
 net.nodes.erase(first_id); net.nodes.erase(second_id);
 net.ports.erase(first_principal_id);
 // The remaining IDs are still valid handles, but erases may move dense
 // entries. Erase by the saved IDs, never by a dense index.
 net.ports.erase(first_left); net.ports.erase(first_right);
 net.ports.erase(second_left); net.ports.erase(second_right);
 net.ports.erase(second_principal_id);
 net.wires.erase(principal_wire_id);
 net.wires.erase(second_left_wire_id); net.wires.erase(second_right_wire_id);
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
 sz count = replicator.agent.replicator.auxiliaries.len;
 StableId[] left_auxiliaries = mem::alloc_array(StableId, count);
 StableId[] right_auxiliaries = mem::alloc_array(StableId, count);

 // The fan's branches become the principal ports of the two copies.
 Port* left_principal = net.ports.get_ref(fan_left);
 Port* right_principal = net.ports.get_ref(fan_right);
 left_principal.slot.type = PRINCIPAL; right_principal.slot.type = PRINCIPAL;
 Node left_copy = { .agent = { .replicator = { .principal = fan_left,
  .auxiliaries = left_auxiliaries }}, .type = REPLICATOR };
 Node right_copy = { .agent = { .replicator = { .principal = fan_right,
  .auxiliaries = right_auxiliaries }}, .type = REPLICATOR };
 StableId left_copy_id = net.nodes.push(left_copy);
 StableId right_copy_id = net.nodes.push(right_copy);
 net.ports.get_ref(fan_left).node_id = left_copy_id;
 net.ports.get_ref(fan_right).node_id = right_copy_id;

 foreach (idx, old_auxiliary_id : replicator.agent.replicator.auxiliaries)
 {
  StableId old_wire_id = net.ports.get_ref(old_auxiliary_id).wire_id;
  StableId external_id = other_endpoint(net, old_wire_id, old_auxiliary_id);
  left_auxiliaries[idx] = net.ports.push({ .node_id = left_copy_id,
   .slot = { .type = AUXILIARY }});
  right_auxiliaries[idx] = net.ports.push({ .node_id = right_copy_id,
   .slot = { .type = AUXILIARY }});

  // Reuse the old auxiliary edge as the principal edge of a new fan.
  Port* old_auxiliary = net.ports.get_ref(old_auxiliary_id);
  old_auxiliary.slot.type = PRINCIPAL;
  StableId new_left = net.ports.push({ .slot = { .type = LEFT }});
  StableId new_right = net.ports.push({ .slot = { .type = RIGHT }});
  StableId new_fan_id = net.nodes.push({ .agent = { .fan = {
   .principal = old_auxiliary_id, .left = new_left, .right = new_right }}, .type = FAN });
  net.ports.get_ref(old_auxiliary_id).node_id = new_fan_id;
  net.ports.get_ref(new_left).node_id = new_fan_id;
  net.ports.get_ref(new_right).node_id = new_fan_id;
  StableId left_wire_id = net.wires.push({ .a = new_left, .b = left_auxiliaries[idx] });
  StableId right_wire_id = net.wires.push({ .a = new_right, .b = right_auxiliaries[idx] });
  net.ports.get_ref(new_left).wire_id = left_wire_id;
  net.ports.get_ref(new_right).wire_id = right_wire_id;
  (void)external_id; // The old wire already retains its external endpoint.
 }

 net.nodes.erase(replicator_id); net.nodes.erase(fan_id);
 net.ports.erase(old_replicator_principal); net.ports.erase(fan_principal);
 net.wires.erase(old_principal_wire);
}

fn void interact(Net* net, StableId wire_id)
{
 if (!is_active(net, wire_id)) return;
 Wire* wire = net.wires.get_ref(wire_id);
 StableId port_a_id = wire.a; StableId port_b_id = wire.b;
 Port* port_a = net.ports.get_ref(port_a_id);
 Port* port_b = net.ports.get_ref(port_b_id);
 StableId node_a_id = port_a.node_id; StableId node_b_id = port_b.node_id;
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
  default: ;
  }
 default: ;
 }
}

fn int main(String[] args)
{
 (void)args; Net net; net.init(); defer net.free(); return 0;
}
