module delta_net_abstract_machine;
import std::core::main_stub, std::io, std::collections;


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
  PortType port;
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




fn void interact (Net net, uint node_id)  {
  Node node = net.nodes[node_id];

  switch (node.type)  {
  case  ERRASER:
    io::printn("Erraser");
    uint wire_id = node.agent.erraser.wireId ;
    Wire wire = net.wires[wire_id];
    Port port_a = net.ports[wire.a];
    Port the_port  =  (port_a.nodeId != node_id) ? port_a : net.ports[wire.b];
    Node end_node = net.nodes[the_port.nodeId];
    switch (end_node.type) {

    case  REPLICATOR:
      io::printn("Replicator");
      foreach (endpoint:end_node.agent.replicator.auxilaries)
      {
      }
  case FAN:
    io::printn("Fan");

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
