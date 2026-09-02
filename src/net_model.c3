module delta_net_abstract_machine;
import std::collections::maybe;
import delta_net_abstract_machine::stable_slot_arena;
import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_storage;
alias NetRef = SlotRef;
const NetRef INVALID_NET_REF = { .id = stable_slot_arena::INVALID_SLOT_ID, .generation = 0 };
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
 NetRef port;
}


enum PortType : uint
{
 PRINCIPAL,
 LEFT,
 RIGHT,
 AUXILIARY
}

enum EffectContinuationState : char
{
 CONTINUATION_CAPTURED,
 CONTINUATION_RESUMED,
 CONTINUATION_ERASED,
 CONTINUATION_REPLICATED,
}

enum HostEffectKind : char
{
 HOST_EFFECT_PURE,
 HOST_EFFECT_ORDERED,
 HOST_EFFECT_EXTERNAL,
}

enum AgentType : uint
{
 REPLICATOR,
 FAN,
 ERASER,
 LOCAL_AGENT,
 LAMBDA_AGENT,
 APPLY_AGENT,
 LET_AGENT,
 I64_AGENT,
 CONSTRUCTOR_AGENT,
 GENERIC_DISPATCH_AGENT,
 GENERIC_CALL_AGENT,
 TYPE_VALUE_AGENT,
 TYPE_ASSERTION_AGENT,
 PRIMITIVE_OP_AGENT,
 MATCH_AGENT,
 PARALLEL_ROOT_AGENT,
 PARALLEL_JOIN_AGENT,
 STRING_AGENT,
 COLLAPSE_AGENT,
 ARRAY_AGENT,
 RESERVED_AGENT_20,
 RESERVED_AGENT_21,
 RESERVED_AGENT_22,
 RESERVED_AGENT_23,
 RESERVED_AGENT_24,
 RESERVED_AGENT_25,
 RESERVED_AGENT_26,
 RESERVED_AGENT_27,
 RESERVED_AGENT_28,
 RESERVED_AGENT_29,
 RESERVED_AGENT_30,
 RESERVED_AGENT_31,
 EFFECT_AGENT,
 HANDLER_AGENT,
 RESUME_AGENT,
 ABORT_AGENT,
}

fn bool is_practical_agent_type(AgentType type)
{
 switch (type)
 {
  case LOCAL_AGENT:
  case LAMBDA_AGENT:
  case APPLY_AGENT:
  case LET_AGENT:
  case I64_AGENT:
  case CONSTRUCTOR_AGENT:
  case GENERIC_DISPATCH_AGENT:
  case GENERIC_CALL_AGENT:
  case TYPE_VALUE_AGENT:
  case TYPE_ASSERTION_AGENT:
  case PRIMITIVE_OP_AGENT:
  case MATCH_AGENT:
  case PARALLEL_ROOT_AGENT:
  case PARALLEL_JOIN_AGENT:
  case STRING_AGENT:
  case COLLAPSE_AGENT:
  case ARRAY_AGENT:
  case EFFECT_AGENT:
  case HANDLER_AGENT:
  case RESUME_AGENT:
  case ABORT_AGENT:
   return true;
  default:
   return false;
 }
}

fn bool agent_type_supports_storage(AgentType type)
{
 return type == STRING_AGENT || type == ARRAY_AGENT;
}

// Canonical nets produced by the lambda-term translation guarantee that
// equal-level replicators are equal. Enable this for defensive validation of
// arbitrary/proper nets as well.
const bool VALIDATE_REPLICATOR_EQUALITY = false;

struct AuxiliaryPortMetadata
{
 usz position;
 long delta_level;
}

struct PortSlot
{
 PortType type;
 Maybe{AuxiliaryPortMetadata} properties;
}

struct Port
{
 NetRef node_id;
 NetRef wire_id;
 PortSlot slot;
 Polarity polarity;
}

struct Wire
{
 NetRef a;
 NetRef b;
}

// A fan has two *named auxiliary identities*, not two global positions.
//
// `left` is auxiliary 1 (also called `first`) and `right` is auxiliary 2
// (also called `second`). These names stay attached to the agent when a
// diagram mirrors it. Consequently a fan--fan annihilation always pairs
// left with left and right with right. In a facing diagram those same-index
// wires can look crossed; that is a drawing consequence, never a reason to
// exchange the stored fields.
//
// Semantic names are only local views of these identities:
//   parent-principal fan: left = abstraction body, right = bound variable
//   child-principal fan:  left = application result, right = argument
// Do not encode the semantic roles as different fields: the generic graph
// rewrite operates on the stable auxiliary identities below.
struct Fan
{
 NetRef principal;
 NetRef left;
 NetRef right;
 bool phase_two_rotated;
}

struct Eraser
{
 NetRef principal;
}

struct Replicator
{
 NetRef[] auxiliaries;
 NetRef principal;
 ulong delta_level;
 ReplicatorStatus status;
 bool observable;
 ulong origin;
}

// Practical agents are typed Delta runtime records. `semantic_id` identifies
// the immutable DeltaProgram node which owns names, signatures, and spans;
// stable-slot ports and this copied payload are the complete runtime form.
struct PracticalAgent
{
 NetRef principal;
 NetRef[] auxiliaries;
 uint semantic_id;
 uint type_id;
 long payload;
 String text;
 bool owns_text;
 mitos_storage::StorageHandle storage;
 mitos::CopyPolicy storage_policy;
 usz storage_count;
 usz storage_stride;
 usz occurrence_order;
 usz descriptor;
 usz source_order;
 NetRef continuation;
 uint handler_id;
 uint effect_id;
 uint operation_id;
 ulong effect_epoch;
 usz resume_count;
 EffectContinuationState resume_state;
 HostEffectKind host_effect;
 bool ordered_effect;
}

struct EffectContinuation
{
 NetRef root;
 NetRef hole;
 NetRef handler;
 NetRef eraser;
 NetRef first_replicator;
 NetRef second_replicator;
 uint handler_id;
 uint effect_id;
 uint operation_id;
 ulong effect_epoch;
 usz resume_count;
 usz resumes_used;
 usz source_order;
 usz occurrence_order;
 EffectContinuationState state;
 HostEffectKind host_effect;
 bool multi;
 bool ordered;
}

struct OrderedEffectCommit
{
 NetRef continuation;
 usz source_root_order;
 usz operation_order;
 bool committed;
}

// Each net owns its lazily-built continuation adjacency and effect lookup.
// The captured allocator keeps teardown independent of the ambient allocator.
struct PracticalContinuationLink @private
{
 NetRef continuation;
 SlotId next;
}

struct PracticalContinuationIndex @private
{
 Allocator allocator;
 ulong shape_version;
 SlotId continuation_next_id;
 usz continuation_live_count;
 SlotId[] node_heads;
 SlotId[] node_tails;
 PracticalContinuationLink[] links;
 usz links_used;
 NetRef[] effect_buckets;
 usz ordered_commit_tombstones;
 bool built;
}

struct EffectNetMetadata
{
 StableSlotArena{EffectContinuation} continuations;
 OrderedEffectCommit[] commits;
 usz committed;
 // Physical allocation count may exceed commits.len after in-place compaction.
 usz commit_allocation_count;
 ulong program_epoch;
 ulong execution_epoch;
 ulong continuation_shape_version;
 PracticalContinuationIndex continuation_index;
}
union Agent
{
 Fan fan;
 Eraser eraser;
 Replicator replicator;
 PracticalAgent practical;
}

struct Node
{
 Agent agent;
 AgentType type;
 usz accounted_payload_bytes;
}

struct Net
{
 StableSlotArena{Port} ports;
 StableSlotArena{Wire} wires;
 StableSlotArena{Node} nodes;
 StableSlotArena{InterfacePort} interfaces;
 EffectNetMetadata effects;
 // Heap payloads embedded in live nodes; arena pages are accounted separately.
 usz node_payload_bytes;
 bool node_payload_bytes_accounted;
 mitos_storage::StorageRuntime storage;
}
