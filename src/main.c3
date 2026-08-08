module delta_net_abstract_machine;
import std::core::main_stub, std::io, std::collections;
import delta_net_abstract_machine::stable_index_vector;


//  ### Usage
//
//  ```c3
// StableIndexVector{Node} nodes;
// nodes.init();
// defer nodes.free();
//
// StableId id = nodes.push(node);
// Node* value = nodes.get_ref(id);
//
// StableIndexHandle{Node} handle = nodes.create_handle(id);
// nodes.erase(id);
//
// assert(!handle.is_valid());
//  ```
//
//  Handles require the container itself to remain at the same address. Stable IDs survive unrelated erases, but raw pointers and dense data indexes may be
//  invalidated by push or erase.
//

enum PortType : uint {
  PRINCIPAL,
  LEFT,
  RIGHT,
  AUXILIARY
}

enum AgentType {
  REPLICATOR,
  FAN,
  ERRASER,

}

struct Port {
  StableId nodeId;
  StableId wireId;
  PortType type;
  Maybe{AuxiliaryPortProperties} properties;
}

struct AuxiliaryPortProperties {
  StableId position;
  StableId deltaLevel;
}


struct Wire {
  StableId   a;
  StableId   b;
  bool alive;
}

struct Fan {
  StableId   principal;
  StableId   left;
  StableId   right;
}

struct Erraser {
  StableId   wireId;
}

struct Replicator {
  StableId   [] auxilaries;
  StableId   principal;
}

union Agent {
  Fan fan;
  Erraser erraser;
  Replicator replicator;
}

struct Node {
  Agent agent;
  AgentType type;
}

struct Net {
  Siv{Port} ports;
  Siv{Wire} wires;
  Siv{Node} nodes;
}

fn bool is_active (Net* net, StableId wire_id){
  Port* port_a =  net.ports.get_ref(net.wires.get_ref(wire_id).a);
  Port* port_b =  net.ports.get_ref(net.wires.get_ref(wire_id).b);
  return port_a.type == PRINCIPAL && port_b.type == PRINCIPAL   ;

}



fn void interact (Net* net, StableId wire_id)  {
  // Node* node = &net.nodes[node_id];
  Port* port_a =  net.ports.get_ref(net.wires.get_ref(wire_id).a);
  Port* port_b =  net.ports.get_ref(net.wires.get_ref(wire_id).b);

  if  (port_a.type != PRINCIPAL || port_b.type != PRINCIPAL) {return;}

  Node* node_a =  &net.nodes.get_ref(port_a.nodeId);
  Node* node_b =  &net.nodes.get_ref(port_b.nodeId);

  switch (node_a.type)  {
  case  ERRASER:
    io::printn("Erraser");
    switch (node_b.type) {
    case FAN:
      foreach (endpoint:node_b.agent.replicator.auxilaries)
      {
      }
  case  REPLICATOR:
    foreach (endpoint:node_b.agent.replicator.auxilaries)
    {

    }

case ERRASER:
  io::printn("ERRASER");
}

//find the node in the other end of the wire

case  REPLICATOR:
  io::printn("Replicator");

case FAN:
  io::printn("Fan");
}

}



fn int main(String[] args)
{
  StableIndexVector{Node} nodes;
  nodes.init();
  defer nodes.free    () ;
  io::printn("Hello, World!");
  return 0;


}
