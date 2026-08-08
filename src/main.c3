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
  ERASER,

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

struct Eraser {
  StableId   wireId;
}

struct Replicator {
  StableId   [] auxilaries;
  StableId   principal;
}

union Agent {
  Fan fan;
  Eraser eraser;
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



fn void fun_eraser_recuction(Net* net, StableId fan_id, StableId erraser_id)    {

}

fn void interact (Net* net, StableId wire_id)  {

  AgentType node_a_type = node_a.type;

  Wire* wire = net.wires.get_ref(wire_id) ;
  StableId wire_a_id = wire.a;
  StableId wire_b_id = wire.b;
  Port* port_a =  net.ports.get_ref(wire_a_id);
  Port* port_b =  net.ports.get_ref(wire_b_id);
  StableId node_a_id = port_a.nodeId;
  StableId node_b_id = port_b.nodeId;
  AgentType node_b_type = node_b.type;
  if  (port_a.type != PRINCIPAL || port_b.type != PRINCIPAL) {return;}

  Node* node_a =  net.nodes.get_ref(node_a_id);
  Node* node_b =  net.nodes.get_ref(node_b_id);

  StableId fan_left_id = node_b.agent.fan.left;
  StableId fan_right_id = node_b.agent.fan.right;


  switch (node_a_type)  {
  case  ERASER:
    io::printn("Eraser");
    switch (node_b_type) {
    case  FAN:
      Port* port_left = net.ports.get_ref(fan_left_id );

      Port* port_right = net.ports.get_ref(fan_right_id );

      StableId  port_left_wire_id  =  port_left.wireId ;

      StableId   port_right_wire_id  =  port_right.wireId ;

      Node eraser_1 = {
        .agent = {
          .eraser = { .wireId = port_left_wire_id  }
        }  ,
      .type = ERASER
    };


  Node eraser_2 = {
    .agent = {
      .eraser = { .wireId = port_right_wire_id  }
    }  ,
  .type = ERASER
}              ;
StableId eraser1_id = net.nodes.push(eraser_1);
StableId eraser2_id  = net.nodes.push(eraser_2);



port_left.nodeId = eraser1_id;
port_left.type = PRINCIPAL;

port_right.nodeId = eraser2_id;
port_right.type = PRINCIPAL;



net.nodes.erase(node_a_id) ;
net.nodes.erase(node_b_id) ;
net.wires.erase(wire_id) ;
net.ports.erase(wire_a_id);
net.ports.erase(wire_b_id);

case REPLICATOR:
  foreach (endpoint:node_b.agent.replicator.auxilaries)
  {


  }

case ERASER:
  io::printn("ERASER");
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
