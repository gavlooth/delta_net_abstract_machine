module delta_net_abstract_machine;
import std::collections::maybe;
import delta_net_abstract_machine::stable_index_vector;
enum ReplicatorStatus
{
 UNPAIRED,
 UNKNOWN,
}


enum Polarity
{
 PARENT,
 CHILD,
}

fn Polarity opposite_polarity(Polarity polarity) @private
{
 return polarity == PARENT ? CHILD : PARENT;
}



// An InterfacePort is an exposed net boundary, not an active agent.
// ROOT is the result boundary; FREE_VARIABLE preserves a free name.
enum InterfacePortType
{
    ROOT,
    FREE_VARIABLE,
}

struct InterfacePort
{
    InterfacePortType type;
    Maybe{String} name;
    StableId port;
}


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

// Canonical nets produced by the lambda-term translation guarantee that
// equal-level replicators are equal. Enable this for defensive validation of
// arbitrary/proper nets as well.
const bool VALIDATE_REPLICATOR_EQUALITY = false;
const StableId INVALID_STABLE_ID = ~(StableId)0;

struct AuxiliaryPortMetadata
{
 StableId position;
 long delta_level;
}

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
 Polarity polarity;
}

struct Wire
{
 StableId a;
 StableId b;
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
 ulong delta_level;
 ReplicatorStatus status;
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
    Siv{InterfacePort} interfaces;
}
