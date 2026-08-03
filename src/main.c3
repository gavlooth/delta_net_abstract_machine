module delta_net_abstract_machine;
import std::core::main_stub, std::io, std::collections;


enum PortType : uint {
  PRINCIPAL,
  LEFT,
  RIGHT,
  AUXILIARY
}


struct AuxiliaryPortProperties {
  uint position;
  uint deltaLevel;
}


struct Endpoint {
  uint nodeId;
  PortType port;
  Maybe{AuxiliaryPortProperties} properties;
}


struct Wire {
  Endpoint[] edges;
  bool alive;
}

struct Fan {
  Wire principal;
  Wire left;
  Wire right;
}

struct Erraser {
  Wire wireId;
}

struct Replicator {
  Wire [] wireId;
  Wire principal;
  uint level_delta;

}

union Agent {
  Fan fan;
  Erraser erraser;
  Replicator replicator;
}


fn int main(String[] args)
{
  io::printn("Hello, World!");
  return 0;
}
