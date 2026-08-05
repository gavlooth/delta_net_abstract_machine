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

struct AuxiliaryPortProperties {
  uint position;
  uint deltaLevel;
}

struct Endpoint {
  uint nodeId;
  uint wireId;
  PortType port;
  Maybe{AuxiliaryPortProperties} properties;
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
  uint level_delta;

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

  Endpoint [] endpoints;
  Wire [] wires ;
  Node [] nodes;
}



fn int main(String[] args)
{
  io::printn("Hello, World!");
  return 0;
}
