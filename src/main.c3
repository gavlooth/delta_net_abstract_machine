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
  uint nodeId;
  uint wireId;
  PortType type;
  Maybe{AuxiliaryPortProperties} properties;
}

struct AuxiliaryPortProperties {
  uint position;
  uint deltaLevel;
}


struct Wire {
  uint a;
  uint b;
  bool alive;
}

struct Fan {
  uint principal;
  uint left;
  uint right;
}

struct Erraser {
  uint wireId;
}

struct Replicator {
  uint [] auxilaries;
  uint principal;
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
  List{Port} ports;
  List{Wire} wires;
  List{Node} nodes;
}

fn bool is_active (Net* net, uint wire_id){
  Port* port_a =  &net.ports[net.wires[wire_id].a];
  Port* port_b =  &net.ports[net.wires[wire_id].b];
  Wire* wire = &net.wires[wire_id];
  return port_a.type == PRINCIPAL && port_b.type == PRINCIPAL   ;

}



fn void interact (Net* net, uint wire_id)  {
  // Node* node = &net.nodes[node_id];
  Port* port_a =  &net.ports[net.wires[wire_id].a];
  Port* port_b =  &net.ports[net.wires[wire_id].b];
  if (!is_active(net, wire_id)){return;} ;
  Node* node_a = &net.nodes[port_a.nodeId];
  Node* node_b = &net.nodes[port_b.nodeId];

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
  io::printn("Hello, World!");
  return 0;
}
