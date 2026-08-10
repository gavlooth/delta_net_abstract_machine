module delta_net_abstract_machine;
import std::core::main_stub, std::collections::maybe;
import delta_net_abstract_machine::stable_index_vector;
import std::io ;

enum PortType : uint
{
 PRINCIPAL,
 LEFT,
 RIGHT,
 AUXILIARY
}

enum AgentType
{
 REPLICATOR,
 FAN,
 ERASER
}

struct AuxiliaryPortMetadata
{
 StableId position;
 StableId delta_level;
}

// The slot describes the role of a port on its owning agent. Keeping this
// together makes changing a port's role an explicit operation and leaves room
// for role-specific metadata.
struct PortSlot
{
 PortType type;
 Maybe{AuxiliaryPortMetadata} properties;
}

struct Port
{
 StableId node_id;
 StableId wire_id;
 PortSlot slot;
}

struct Wire
{
 StableId a;
 StableId b;
 bool alive;
}

struct Fan
{
 StableId principal;
 StableId left;
 StableId right;
}

struct Eraser
{
 StableId principal;
}

struct Replicator
{
 StableId[] auxiliaries;
 StableId principal;
}

union Agent
{
 Fan fan;
 Eraser eraser;
 Replicator replicator;
}

struct Node
{
 Agent agent;
 AgentType type;
}

struct Net
{
 Siv{Port} ports;
 Siv{Wire} wires;
 Siv{Node} nodes;
}

fn Net* Net.init(&self)
{
 self.ports.init();
 self.wires.init();
 self.nodes.init();
 return self;
}

fn void Net.free(&self)
{
 self.ports.free();
 self.wires.free();
 self.nodes.free();
}

fn bool is_active(Net* net, StableId wire_id)
{
 if (!net.wires.contains(wire_id)) return false;

 Wire* wire = net.wires.get_ref(wire_id);
 if (!wire.alive) return false;
 if (!net.ports.contains(wire.a) || !net.ports.contains(wire.b)) return false;

 Port* port_a = net.ports.get_ref(wire.a);
 Port* port_b = net.ports.get_ref(wire.b);
 return port_a.slot.type == PRINCIPAL && port_b.slot.type == PRINCIPAL;
}



fn void erase_redex(Net* net, StableId node_a_id, StableId node_b_id,
StableId wire_id, StableId port_a_id, StableId port_b_id)
{
 // Erase the endpoints after reading all topology needed by the rewrite.
 // Stable IDs make the order independent of dense-storage movement.
 net.nodes.erase(node_a_id);
 net.nodes.erase(node_b_id);
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
StableId wire_id, StableId fan_port_id, StableId eraser_port_id,
StableId fan_left_id, StableId fan_right_id)
{
 // Copy IDs before inserting nodes: push may reallocate the node storage.
 Port* left_port = net.ports.get_ref(fan_left_id);
 Port* right_port = net.ports.get_ref(fan_right_id);
 StableId left_wire_id = left_port.wire_id;
 StableId right_wire_id = right_port.wire_id;

 Node left_eraser = {
  .agent = { .eraser = { .principal = left_wire_id } },
  .type = ERASER
 };
Node right_eraser = {
 .agent = { .eraser = { .principal = right_wire_id } },
 .type = ERASER
};

StableId left_eraser_id = net.nodes.push(left_eraser);
StableId right_eraser_id = net.nodes.push(right_eraser);

left_port = net.ports.get_ref(fan_left_id);
right_port = net.ports.get_ref(fan_right_id);
left_port.node_id = left_eraser_id;
left_port.slot.type = PRINCIPAL;
right_port.node_id = right_eraser_id;
right_port.slot.type = PRINCIPAL;

erase_redex(net, fan_id, eraser_id, wire_id, fan_port_id, eraser_port_id);
}


// Fan/fan and replicator interactions are intentionally separate rewrite
// rules. Their topology is not inferred from PortSlot, so they can be added
// without reintroducing agent-specific fields into Port.
fn void fan_fan_reduction(Net* net, StableId node_a_id, StableId node_b_id,
StableId port_a_id, StableId port_b_id)
{
 // Erasing an entry can move the last dense entry, so pointers into any
 // StableIndexVector are invalid after an erase. Snapshot all IDs first.
 Node* fan_1 = net.nodes.get_ref(node_a_id);
 Node* fan_2 = net.nodes.get_ref(node_b_id);
 StableId fan1_left_id = fan_1.agent.fan.left;
 StableId fan1_right_id = fan_1.agent.fan.right;
 StableId fan2_left_id = fan_2.agent.fan.left;
 StableId fan2_right_id = fan_2.agent.fan.right;

 StableId fan1_left_wire_id = net.ports.get_ref(fan1_left_id).wire_id;
 StableId fan1_right_wire_id = net.ports.get_ref(fan1_right_id).wire_id;
 StableId fan2_left_wire_id = net.ports.get_ref(fan2_left_id).wire_id;
 StableId fan2_right_wire_id = net.ports.get_ref(fan2_right_id).wire_id;
 StableId principal_wire_id = net.ports.get_ref(port_a_id).wire_id;

 Wire* fan2_left_wire = net.wires.get_ref(fan2_left_wire_id);
 Wire* fan2_right_wire = net.wires.get_ref(fan2_right_wire_id);
 StableId fan2_left_other_id = fan2_left_wire.a == fan2_left_id
 ? fan2_left_wire.b : fan2_left_wire.a;
 StableId fan2_right_other_id = fan2_right_wire.a == fan2_right_id
 ? fan2_right_wire.b : fan2_right_wire.a;

 // Reuse fan 1's auxiliary wires to connect the external neighbours.
 Wire* fan1_left_wire = net.wires.get_ref(fan1_left_wire_id);
 Wire* fan1_right_wire = net.wires.get_ref(fan1_right_wire_id);
 if (fan1_left_wire.a == fan1_left_id)
 {
  fan1_left_wire.a = fan2_left_other_id;
 }
else
{
 fan1_left_wire.b = fan2_left_other_id;
}
if (fan1_right_wire.a == fan1_right_id)
{
 fan1_right_wire.a = fan2_right_other_id;
}
else
{
 fan1_right_wire.b = fan2_right_other_id;
}

// Delete both fans and all six ports owned by them. External ports remain
// as endpoints of the two reused fan 1 wires.
net.nodes.erase(node_a_id);
net.nodes.erase(node_b_id);
net.ports.erase(port_a_id);
net.ports.erase(port_b_id);
net.ports.erase(fan1_left_id);
net.ports.erase(fan1_right_id);
net.ports.erase(fan2_left_id);
net.ports.erase(fan2_right_id);

// Remove the old principal wire and fan 2's two auxiliary wires exactly
// once. Fan 1's auxiliary wires were rewired and are retained.
net.wires.erase(principal_wire_id);
net.wires.erase(fan2_left_wire_id);
net.wires.erase(fan2_right_wire_id);
}



fn void replicator_fan_reduction(Net* net, StableId replicator_node_id, StableId fan_node_id)
// StableId port_a_id, StableId port_b_id)
{

Node* fan = net.nodes.get_ref(fan_node_id);
StableId fan_principal_id= fan.agent.fan.principal;
StableId fan_left_id = fan.agent.fan.left;
StableId fan_right_id = fan.agent.fan.right;

//will use the auxiliaries to connect new replicators
StableId fan_left_wire_id = net.ports.get_ref(fan_left_id).wire_id;
StableId fan_right_wire_id = net.ports.get_ref(fan_right_id).wire_id;

//connection wire, must be deleted at the end
StableId principal_wire_id = net.ports.get_ref(fan_principal_id).wire_id;

Node* replicator = net.nodes.get_ref(replicator_node_id);

 
 StableId replicator_principal_id = replicator.agent.replicator.principal;
 List{StableId} auxiliary_ids ;
 List{StableId} auxiliary_wire_ids ;

 List{Port} auxiliary_ports;
auxiliary_ids.init(mem);
 auxiliary_ports.init(mem);
 auxiliary_wire_ids.init(mem);
 defer auxiliary_ids.free();
 defer auxiliary_wire_ids.free();

 foreach (i:replicator.agent.replicator.auxiliaries) {
  auxiliary_ids.push(i)   ;
  auxiliary_wire_ids.push(net.ports.get_ref(i).wire_id) ;
  //we need to save whole ports for the deltas
  auxiliary_ports.push(net.ports.get_ref(i)) ;
 }


Port[] left_auxiliary_ports = mem.init(auxiliary_ports_slice.len);
Port[] right_auxiliary_ports = mem.init(auxiliary_ports_slice.len);

Node left_new_replicator = {
  .agent = { .replicator =
  { .principal = fan_left_wire_id,
    .auxiliaries =  left_auxiliary_ports} },
  .type = REPLICATOR
 };


Node right_new_replicator = {
  .agent = {.replicator = {
    .principal = fan_right_wire_id,
    .auxiliaries =  right_auxiliary_ports}},
  .type = REPLICATOR
 };

StableId left_replicator_id = net.nodes.create(left_new_replicator);
StableId right_replicator_id = net.nodes.create(right_new_replicator);



foreach(idx,val:auxiliary_ids) {
  //connect to the new replicator

 left_auxiliary_ports[idx].node_id = left_replicator_id;
 right_auxiliary_ports[idx].node_id = right_replicator_id;

  StableId  left_new_auxiliary_port_id = net.ports.create(left_auxiliary_ports[idx]);
  StableId  right_new_auxiliary_port_id = net.ports.create(right_auxiliary_ports[idx]);

  Wire* auxiliary_wire = net.wires.get_ref(auxiliary_wire_ids[idx]);
  if (auxiliary_wire.a == val)
  {
   auxiliary_wire.a = replicator_principal_id;
  }
  else
  {
   auxiliary_wire.b = replicator_principal_id;
 }
}




// Reuse fan 1's auxiliary wires to connect the external neighbours.
Wire* fan_left_wire = net.wires.get_ref(fan_left_wire_id);
Wire* fan_right_wire = net.wires.get_ref(fan_right_wire_id);
if (fan_left_wire.a == fan_left_id)
{
 //fan_left_wire.a = fan2_left_other_id;
}
// Delete both fans and all six ports owned by them. External ports remain
// as endpoints of the two reused fan 1 wires.
//net.nodes.erase(node_a_id);
//net.nodes.erase(node_b_id);
//net.ports.erase(port_a_id);
//net.ports.erase(port_b_id);
//net.ports.erase(fan1_left_id);
//net.ports.erase(fan1_right_id);
//net.ports.erase(fan2_left_id);
//net.ports.erase(fan2_right_id);
//
//// Remove the old principal wire and fan 2's two auxiliary wires exactly
//// once. Fan 1's auxiliary wires were rewired and are retained.
//net.wires.erase(principal_wire_id);
//net.wires.erase(fan2_left_wire_id);
//net.wires.erase(fan2_right_wire_id);
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
 Node* node_a = net.nodes.get_ref(node_a_id);
 Node* node_b = net.nodes.get_ref(node_b_id);
 AgentType type_a = node_a.type;
 AgentType type_b = node_b.type;

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
   port_b_id, port_a_id, node_b.agent.fan.left, node_b.agent.fan.right);
  default : io::printn("WIP");
  }
case FAN:
 switch (type_b)
 {
 case ERASER:
  fan_eraser_reduction(net, node_a_id, node_b_id, wire_id,
  port_a_id, port_b_id, node_a.agent.fan.left, node_a.agent.fan.right);
 case FAN:
  fan_fan_reduction(net, node_a_id, node_b_id, port_a_id, port_b_id);
 default : io::printn("WIP");
 }

default : io::printn("WIP");

}
}

fn int main(String[] args)
{
 (void)args;
 Net net;
 net.init();
 defer net.free();
 return 0;
}
