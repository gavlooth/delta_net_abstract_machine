module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::stable_slot_arena;
import std::collections::list;
import std::thread;
import std::atomic::types;

const int DELTA_MAX_WORKERS = 256;
const uint TYPED_DELTA_HOST_ABI_MAJOR = 2;
const uint TYPED_DELTA_HOST_ABI_MINOR = 0;
const usz DELTA_MAX_HOST_ENTRIES = 4096;
const usz DELTA_MAX_PROGRAM_ENROLLMENTS = 4096;
const usz DELTA_MAX_RETAINED_SUSPENSIONS = 64;
const usz DELTA_MAX_RETAINED_SUSPENSION_BYTES = 256 * 1024 * 1024;
const usz DELTA_MAX_RUNTIME_CONTROLS = 4096;
const ulong DELTA_REGISTRY_GATE_CLOSED = (ulong)1 << 63;
const ulong DELTA_REGISTRY_GATE_DESTROYED = (ulong)1 << 62;
const ulong DELTA_REGISTRY_GATE_OPEN = (ulong)1 << 61;
const ulong DELTA_REGISTRY_GATE_COUNT = DELTA_REGISTRY_GATE_OPEN - 1;

enum TypedDeltaHostDisposition : char
{
 HOST_READY,
 HOST_SUSPEND,
 HOST_FAIL,
}

enum TypedDeltaHostValueKind : char
{
 HOST_VALUE_I64,
 HOST_VALUE_BOOL,
 HOST_VALUE_UNIT,
 HOST_VALUE_STRING,
 HOST_VALUE_CONSTRUCTOR,
 HOST_VALUE_FUNCTION,
 HOST_VALUE_TYPE,
}

/** ABI 2.0 borrowed value view. A handler must not retain any referenced bytes. */
struct TypedDeltaHostValue
{
 TypedDeltaHostValueKind kind;
 mitos::TypeId type_id;
 long integer;
 bool boolean;
 mitos::TypeId represented_type;
 String string;
}

/** ABI 2.0 borrowed call view. Only READY consumes `result`. */
struct TypedDeltaHostCall
{
 uint abi_major;
 uint abi_minor;
 mitos::EffectId effect;
 mitos::OperationId operation;
 usz source_order;
 usz occurrence_order;
 TypedDeltaHostValue[] arguments;
 TypedDeltaHostValue result;
 String diagnostic;
}

alias TypedDeltaHostHandler = fn TypedDeltaHostDisposition(
 TypedDeltaHostCall* call,
 void* context
);

struct TypedDeltaHostHandlerEntry
{
 usz arity;
 TypedDeltaHostHandler handler;
 void* context;
}
struct TypedDeltaHostSnapshotEntry @private
{
 usz dense_handle;
 TypedDeltaHostHandlerEntry handler;
}


struct TypedDeltaHostHandlerRecord @private
{
 ulong program_cookie_high;
 ulong program_cookie_low;
 ulong program_runtime_identity;
 mitos::EffectId effect;
 usz arity;
 mitos::SymbolKey key;
 usz dense_handle;
 mitos::OperationId operation;
 uint abi_major;
 uint abi_minor;
 TypedDeltaHostHandler handler;
 void* context;
}

struct TypedDeltaProgramEnrollment @private
{
 mitos::DeltaProgram* program;
 ulong program_runtime_identity;
 ulong cookie_high;
 ulong cookie_low;
}

struct TypedDeltaHostRegistry @private
{
 Allocator allocator;
 List{TypedDeltaHostHandlerRecord} entries;
 List{TypedDeltaProgramEnrollment} enrollments;
 Mutex mutex;
 usz active_leases;
 usz active_runs;
 Atomic{ulong} entrant_gate;
 bool shutting_down;
 bool initialized;
}

fn bool typed_delta_registry_enter(TypedDeltaHostRegistry* registry) @private
{
 for (;;)
 {
  ulong current = registry.entrant_gate.load();
  if (!(current & DELTA_REGISTRY_GATE_OPEN)
   || current & DELTA_REGISTRY_GATE_CLOSED
   || (current & DELTA_REGISTRY_GATE_COUNT) == DELTA_REGISTRY_GATE_COUNT) return false;
  ulong expected = current;
  if (registry.entrant_gate.compare_exchange(&expected, current + 1)) return true;
 }
}

fn void typed_delta_registry_leave(TypedDeltaHostRegistry* registry) @private
{
 (void)registry.entrant_gate.sub(1);
}

fn bool typed_delta_registry_close_gate(TypedDeltaHostRegistry* registry) @private
{
 for (;;)
 {
  ulong current = registry.entrant_gate.load();
  if (!(current & DELTA_REGISTRY_GATE_OPEN)
   || current & DELTA_REGISTRY_GATE_CLOSED) return false;
  ulong expected = current;
  if (registry.entrant_gate.compare_exchange(
   &expected, current | DELTA_REGISTRY_GATE_CLOSED
  )) break;
 }
 while ((registry.entrant_gate.load() & DELTA_REGISTRY_GATE_COUNT) != 0) thread::yield();
 return true;
}

fn void typed_delta_registry_reopen_gate(TypedDeltaHostRegistry* registry) @private
{
 ulong expected = DELTA_REGISTRY_GATE_OPEN | DELTA_REGISTRY_GATE_CLOSED;
 bool reopened = registry.entrant_gate.compare_exchange(
  &expected, DELTA_REGISTRY_GATE_OPEN
 );
 assert(reopened, "typed Delta registry gate changed while exclusively closed");
}


fn void typed_delta_registry_mark_destroyed(TypedDeltaHostRegistry* registry) @private
{
 registry.entrant_gate.store(
  DELTA_REGISTRY_GATE_CLOSED | DELTA_REGISTRY_GATE_DESTROYED
 );
}

fn TypedDeltaHostRegistry* typed_delta_registry_init(
 TypedDeltaHostRegistry* registry,
 Allocator allocator = mem
) @private
{
 *registry = { .allocator = allocator };
 registry.entries.init(allocator);
 registry.enrollments.init(allocator);
 if (catch registry.mutex.init())
 {
  registry.entries.free();
  registry.enrollments.free();
  *registry = { };
  typed_delta_registry_mark_destroyed(registry);
  return registry;
 }
 registry.initialized = true;
 registry.entrant_gate.store(DELTA_REGISTRY_GATE_OPEN);
 return registry;
}

fn bool typed_delta_registry_begin_execution(TypedDeltaHostRegistry* registry) @private
{
 registry.mutex.lock();
 if (!registry.initialized || registry.shutting_down
  || registry.active_runs || registry.active_leases == usz::max)
 {
  registry.mutex.unlock();
  return false;
 }
 registry.active_runs++;
 registry.active_leases++;
 registry.mutex.unlock();
 return true;
}

fn void typed_delta_registry_finish_execution(TypedDeltaHostRegistry* registry) @private
{
 registry.mutex.lock();
 assert(registry.active_runs && registry.active_leases,
  "typed Delta registry execution lease underflow");
 registry.active_runs--;
 registry.active_leases--;
 registry.mutex.unlock();
}

fn bool typed_delta_dense_operation(
 mitos::DeltaProgram* program,
 usz dense_handle,
 mitos::DeltaOperationDescriptor** operation
) @private
{
 if (!program || !program.runtime_identity
  || dense_handle >= program.effects.operations.len) return false;
 mitos::DeltaOperationDescriptor* descriptor = &program.effects.operations[dense_handle];
 if (descriptor.id != (mitos::OperationId)(dense_handle + 1)
  || !descriptor.effect || !descriptor.name.len
  || descriptor.parameter_patterns.len != descriptor.parameter_types.len
  || !mitos::symbol_key_is_canonical(&descriptor.key)
  || descriptor.key.kind != mitos::SymbolKind.SYMBOL_EFFECT_OPERATION
  || descriptor.key.name != descriptor.name
  || descriptor.key.arity != (uint)descriptor.parameter_types.len) return false;
 mitos::DeltaEffectDescriptor* owner = null;
 foreach (&effect : program.effects.effects)
 {
  if (effect.id == descriptor.effect) { owner = effect; break; }
 }
 if (!owner || !mitos::symbol_key_is_canonical(&owner.key)
  || owner.key.kind != mitos::SymbolKind.SYMBOL_EFFECT
  || owner.key.name != owner.name
  || owner.key.arity != (uint)owner.parameters.len
  || !mitos::module_key_equal(&owner.key.owner, &program.module_key)
  || !mitos::module_key_equal(&descriptor.key.owner, &owner.key.owner)) return false;
 bool listed = false;
 foreach (id : owner.operations) if (id == descriptor.id) { listed = true; break; }
 if (!listed) return false;
 if (operation) *operation = descriptor;
 return true;
}

fn void typed_delta_registry_purge_cookie_unlocked(
 TypedDeltaHostRegistry* registry,
 ulong cookie_high,
 ulong cookie_low
) @private
{
 sz index = 0;
 while (index < registry.entries.len())
 {
  TypedDeltaHostHandlerRecord* entry = &registry.entries[index];
  if (entry.program_cookie_high != cookie_high
   || entry.program_cookie_low != cookie_low)
  {
   index++;
   continue;
  }
  entry.key.deinit(registry.allocator);
  registry.entries.remove_at(index);
 }
}

fn sz typed_delta_registry_enrollment_index_unlocked(
 TypedDeltaHostRegistry* registry,
 mitos::DeltaProgram* program
) @private
{
 if (!program || !program.runtime_identity) return -1;
 foreach (index, &enrollment : registry.enrollments)
 {
  if (enrollment.program != program) continue;
  if (enrollment.program_runtime_identity == program.runtime_identity)
  {
   return (sz)index;
  }
  typed_delta_registry_purge_cookie_unlocked(
   registry, enrollment.cookie_high, enrollment.cookie_low
  );
  registry.enrollments.remove_at(index);
  return -1;
 }
 return -1;
}

fn bool typed_delta_registry_cookie_exists_unlocked(
 TypedDeltaHostRegistry* registry,
 ulong cookie_high,
 ulong cookie_low
) @private
{
 foreach (&enrollment : registry.enrollments)
 {
  if (enrollment.cookie_high == cookie_high
   && enrollment.cookie_low == cookie_low) return true;
 }
 return false;
}

struct TypedDeltaSecretPair @private
{
 ulong high;
 ulong low;
}

fn bool typed_delta_secure_pair(ulong* high, ulong* low) @private
{
 for (usz attempt = 0; attempt < 8; attempt++)
 {
  TypedDeltaSecretPair secret;
  if (!mitos::fill_secure_entropy(
   ((char*)&secret)[:TypedDeltaSecretPair::size]
  )) return false;
  if (!secret.high || !secret.low) continue;
  *high = secret.high;
  *low = secret.low;
  return true;
 }
 return false;
}

fn TypedDeltaProgramEnrollment* typed_delta_registry_enroll_unlocked(
 TypedDeltaHostRegistry* registry,
 mitos::DeltaProgram* program
) @private
{
 sz existing = typed_delta_registry_enrollment_index_unlocked(registry, program);
 if (existing >= 0) return &registry.enrollments[existing];
 if (!program || !program.runtime_identity
  || (usz)registry.enrollments.len() >= DELTA_MAX_PROGRAM_ENROLLMENTS) return null;
 for (usz attempt = 0; attempt < 32; attempt++)
 {
  ulong cookie_high;
  ulong cookie_low;
  if (!typed_delta_secure_pair(&cookie_high, &cookie_low)) return null;
  if (typed_delta_registry_cookie_exists_unlocked(
   registry, cookie_high, cookie_low
  )) continue;
  registry.enrollments.push({
   .program = program,
   .program_runtime_identity = program.runtime_identity,
   .cookie_high = cookie_high,
   .cookie_low = cookie_low,
  });
  return &registry.enrollments[(sz)registry.enrollments.len() - 1];
 }
 return null;
}


fn bool typed_delta_host_record_precedes(
 TypedDeltaHostHandlerRecord* left,
 TypedDeltaHostHandlerRecord* right
) @private
{
 if (left.program_cookie_high != right.program_cookie_high)
 {
  return left.program_cookie_high < right.program_cookie_high;
 }
 if (left.program_cookie_low != right.program_cookie_low)
 {
  return left.program_cookie_low < right.program_cookie_low;
 }
 return left.dense_handle < right.dense_handle;
}

fn bool typed_delta_registry_register(
 TypedDeltaHostRegistry* registry,
 mitos::DeltaProgram* program,
 usz dense_handle,
 TypedDeltaHostHandler handler,
 void* context = null,
 uint abi_major = TYPED_DELTA_HOST_ABI_MAJOR,
 uint abi_minor = TYPED_DELTA_HOST_ABI_MINOR
) @private
{
 if (!typed_delta_registry_enter(registry)) return false;
 defer typed_delta_registry_leave(registry);
 mitos::DeltaOperationDescriptor* operation;
 if (!handler
  || abi_major != TYPED_DELTA_HOST_ABI_MAJOR
  || abi_minor != TYPED_DELTA_HOST_ABI_MINOR
  || !typed_delta_dense_operation(program, dense_handle, &operation)) return false;
 registry.mutex.lock();
 if (!registry.initialized || registry.shutting_down || registry.active_leases)
 {
  registry.mutex.unlock();
  return false;
 }
 sz enrollment_index = typed_delta_registry_enrollment_index_unlocked(registry, program);
 if (enrollment_index >= 0)
 {
  TypedDeltaProgramEnrollment* enrollment = &registry.enrollments[enrollment_index];
  foreach (&entry : registry.entries)
  {
   if (entry.program_cookie_high != enrollment.cookie_high
    || entry.program_cookie_low != enrollment.cookie_low
    || entry.dense_handle != dense_handle) continue;
   if (entry.effect != operation.effect || entry.operation != operation.id
    || entry.arity != operation.parameter_types.len
    || !mitos::symbol_key_equal(&entry.key, &operation.key))
   {
    registry.mutex.unlock();
    return false;
   }
   entry.handler = handler;
   entry.context = context;
   registry.mutex.unlock();
   return true;
  }
 }
 if ((usz)registry.entries.len() >= DELTA_MAX_HOST_ENTRIES)
 {
  registry.mutex.unlock();
  return false;
 }
 TypedDeltaProgramEnrollment* enrollment =
  typed_delta_registry_enroll_unlocked(registry, program);
 if (!enrollment)
 {
  registry.mutex.unlock();
  return false;
 }
 TypedDeltaHostHandlerRecord inserted = {
  .program_cookie_high = enrollment.cookie_high,
  .program_cookie_low = enrollment.cookie_low,
  .program_runtime_identity = program.runtime_identity,
  .effect = operation.effect,
  .arity = operation.parameter_types.len,
  .key = mitos::clone_symbol_key(&operation.key, registry.allocator),
  .dense_handle = dense_handle,
  .operation = operation.id,
  .abi_major = abi_major,
  .abi_minor = abi_minor,
  .handler = handler,
  .context = context,
 };
 registry.entries.push(inserted);
 usz insertion = (usz)registry.entries.len() - 1;
 while (insertion
  && typed_delta_host_record_precedes(
   &inserted, &registry.entries[(sz)insertion - 1]
  ))
 {
  registry.entries[(sz)insertion] =
   registry.entries[(sz)insertion - 1];
  insertion--;
 }
 registry.entries[(sz)insertion] = inserted;
 registry.mutex.unlock();
 return true;
}

fn bool typed_delta_registry_unregister(
 TypedDeltaHostRegistry* registry,
 mitos::DeltaProgram* program,
 usz dense_handle
) @private
{
 if (!typed_delta_registry_enter(registry)) return false;
 defer typed_delta_registry_leave(registry);
 mitos::DeltaOperationDescriptor* operation;
 if (!typed_delta_dense_operation(program, dense_handle, &operation)) return false;
 registry.mutex.lock();
 if (!registry.initialized || registry.shutting_down || registry.active_leases)
 {
  registry.mutex.unlock();
  return false;
 }
 sz enrollment_index = typed_delta_registry_enrollment_index_unlocked(registry, program);
 if (enrollment_index < 0)
 {
  registry.mutex.unlock();
  return false;
 }
 TypedDeltaProgramEnrollment enrollment = registry.enrollments[enrollment_index];
 foreach (index, &entry : registry.entries)
 {
  if (entry.program_cookie_high != enrollment.cookie_high
   || entry.program_cookie_low != enrollment.cookie_low
   || entry.dense_handle != dense_handle
   || entry.effect != operation.effect || entry.operation != operation.id
   || entry.arity != operation.parameter_types.len
   || !mitos::symbol_key_equal(&entry.key, &operation.key)) continue;
  entry.key.deinit(registry.allocator);
  registry.entries.remove_at(index);
  bool still_enrolled = false;
  foreach (&remaining : registry.entries)
  {
   if (remaining.program_cookie_high == enrollment.cookie_high
    && remaining.program_cookie_low == enrollment.cookie_low)
   {
    still_enrolled = true;
    break;
   }
  }
  if (!still_enrolled) registry.enrollments.remove_at(enrollment_index);
  registry.mutex.unlock();
  return true;
 }
 registry.mutex.unlock();
 return false;
}
/**
 * Copies exactly the external host operations while the execution lease keeps
 * registrations immutable. Registry records are kept ordered at enrollment,
 * so validation is a linear merge without a dense operation-sized table.
 */
fn bool typed_delta_registry_snapshot(
 TypedDeltaHostRegistry* registry,
 mitos::DeltaProgram* program,
 Allocator allocator,
 TypedDeltaHostSnapshotEntry[]* result,
 usz* missing_dense_handle
) @private
{
 *result = { };
 *missing_dense_handle = usz::max;
 if (!registry || !program || !program.runtime_identity) return false;
 usz external_count = 0;
 foreach (&operation : program.effects.operations)
 {
  if (operation.host_kind == mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL)
  {
   external_count++;
  }
 }
 TypedDeltaHostSnapshotEntry[] snapshot = { };
 if (external_count)
 {
  snapshot = alloc::new_array(
   allocator, TypedDeltaHostSnapshotEntry, (sz)external_count
  );
 }

 registry.mutex.lock();
 if (!registry.initialized || registry.shutting_down || !registry.active_runs
  || !registry.active_leases)
 {
  registry.mutex.unlock();
  if (snapshot.len) alloc::free(allocator, snapshot);
  return false;
 }
 sz enrollment_index = typed_delta_registry_enrollment_index_unlocked(
  registry, program
 );
 usz copied = 0;
 if (enrollment_index >= 0)
 {
  TypedDeltaProgramEnrollment enrollment =
   registry.enrollments[enrollment_index];
  foreach (&record : registry.entries)
  {
   if (record.program_cookie_high != enrollment.cookie_high
    || record.program_cookie_low != enrollment.cookie_low) continue;
   if (record.program_runtime_identity != program.runtime_identity
    || record.dense_handle >= program.effects.operations.len
    || record.abi_major != TYPED_DELTA_HOST_ABI_MAJOR
    || record.abi_minor != TYPED_DELTA_HOST_ABI_MINOR
    || !record.handler) continue;
   mitos::DeltaOperationDescriptor* operation =
    &program.effects.operations[record.dense_handle];
   if (operation.host_kind
     != mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL
    || operation.id != (mitos::OperationId)(record.dense_handle + 1)
    || operation.effect != record.effect
    || operation.id != record.operation
    || operation.parameter_types.len != record.arity
    || !mitos::symbol_key_equal(&operation.key, &record.key)) continue;
   if (copied >= external_count)
   {
    copied = usz::max;
    break;
   }
   snapshot[copied++] = {
    .dense_handle = record.dense_handle,
    .handler = {
     .arity = record.arity,
     .handler = record.handler,
     .context = record.context,
    },
   };
  }
 }
 registry.mutex.unlock();

 if (copied == usz::max)
 {
  if (snapshot.len) alloc::free(allocator, snapshot);
  return false;
 }
 usz cursor = 0;
 foreach (operation_index, &operation : program.effects.operations)
 {
  if (operation.host_kind
   != mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL) continue;
  if (cursor >= copied
   || snapshot[cursor].dense_handle != (usz)operation_index)
  {
   *missing_dense_handle = (usz)operation_index;
   if (snapshot.len) alloc::free(allocator, snapshot);
   return false;
  }
  cursor++;
 }
 if (cursor != copied)
 {
  if (snapshot.len) alloc::free(allocator, snapshot);
  return false;
 }
 *result = snapshot;
 return true;
}


enum DeltaResumptionState : char @private
{
 RESUMPTION_ACTIVE,
 RESUMPTION_RESUMING,
}

/** Opaque affine capability. Slot coordinates are never sufficient authority. */
struct DeltaResumptionToken
{
 ulong runtime_identity;
 SlotId slot_id;
 ulong generation;
 ulong capability_high;
 ulong capability_low;
 ulong effect_epoch;
}

struct DeltaSuspensionRecord @private
{
 ulong capability_high;
 ulong capability_low;
 ulong effect_epoch;
 usz retained_bytes;
 DeltaResumptionState state;
 TypedDeltaSuspension* suspension;
}

struct DeltaTokenActionResult
{
 bool ok;
 Allocator allocator;
 String diagnostic;
}

fn void DeltaTokenActionResult.deinit(&self)
{
 if (!self.allocator) return;
 alloc::free(self.allocator, self.diagnostic);
 *self = { };
}

struct DeltaRuntimeState @private
{
 TypedDeltaHostRegistry host_handlers;
 int max_workers;
 bool shutting_down;
 ulong identity;
 usz retained_suspension_bytes;
 StableSlotArena{DeltaSuspensionRecord} suspensions;
}

/*
 * Public handles carry only bounded coordinates. The outer gate remains valid
 * while the slot is recycled, so caller-controlled coordinates are checked
 * before addressing the table and generation/identity are revalidated after
 * entering the selected slot.
 */
struct DeltaRuntimeControl @private
{
 Atomic{ulong} entrant_gate;
 Atomic{ulong} generation;
 ulong identity;
 DeltaRuntimeState state;
}

DeltaRuntimeControl[DELTA_MAX_RUNTIME_CONTROLS] delta_runtime_controls @private;

/** Opaque alias-safe handle. Copies share one generation-tagged lifecycle slot. */
struct DeltaRuntime
{
 usz slot;
 ulong generation;
 ulong identity;
}

fn bool delta_runtime_control_enter(DeltaRuntimeControl* control) @private
{
 for (;;)
 {
  ulong current = control.entrant_gate.load();
  if (!(current & DELTA_REGISTRY_GATE_OPEN)
   || current & DELTA_REGISTRY_GATE_CLOSED
   || (current & DELTA_REGISTRY_GATE_COUNT) == DELTA_REGISTRY_GATE_COUNT) return false;
  ulong expected = current;
  if (control.entrant_gate.compare_exchange(&expected, current + 1)) return true;
 }
}

fn void delta_runtime_control_leave(DeltaRuntimeControl* control) @private
{
 (void)control.entrant_gate.sub(1);
}

fn bool delta_runtime_control_close_entered(DeltaRuntimeControl* control) @private
{
 for (;;)
 {
  ulong current = control.entrant_gate.load();
  if (!(current & DELTA_REGISTRY_GATE_OPEN) || current & DELTA_REGISTRY_GATE_CLOSED)
  {
   delta_runtime_control_leave(control);
   return false;
  }
  ulong expected = current;
  if (!control.entrant_gate.compare_exchange(
   &expected, current | DELTA_REGISTRY_GATE_CLOSED
  )) continue;
  delta_runtime_control_leave(control);
  while ((control.entrant_gate.load() & DELTA_REGISTRY_GATE_COUNT) != 0)
  {
   thread::yield();
  }
  return true;
 }
}

fn void delta_runtime_control_reopen(DeltaRuntimeControl* control) @private
{
 ulong expected = DELTA_REGISTRY_GATE_OPEN | DELTA_REGISTRY_GATE_CLOSED;
 bool reopened = control.entrant_gate.compare_exchange(
  &expected, DELTA_REGISTRY_GATE_OPEN
 );
 assert(reopened, "Delta runtime slot gate changed while exclusively closed");
}

fn void delta_runtime_control_recycle(DeltaRuntimeControl* control) @private
{
 control.identity = 0;
 control.entrant_gate.store(
  DELTA_REGISTRY_GATE_CLOSED | DELTA_REGISTRY_GATE_DESTROYED
 );
}

fn DeltaRuntimeControl* delta_runtime_allocate_control(
 ulong identity,
 usz* allocated_slot,
 ulong* allocated_generation
) @private
{
 for (usz slot = 0; slot < DELTA_MAX_RUNTIME_CONTROLS; slot++)
 {
  DeltaRuntimeControl* control = &delta_runtime_controls[slot];
  if (control.generation.load() == ulong::max) continue;
  ulong current = control.entrant_gate.load();
  if (current != 0 && current != (
   DELTA_REGISTRY_GATE_CLOSED | DELTA_REGISTRY_GATE_DESTROYED
  )) continue;
  ulong expected = current;
  if (!control.entrant_gate.compare_exchange(
   &expected, DELTA_REGISTRY_GATE_CLOSED
  )) continue;
  ulong generation = control.generation.load() + 1;
  control.generation.store(generation);
  control.identity = identity;
  *allocated_slot = slot;
  *allocated_generation = generation;
  return control;
 }
 return null;
}

fn DeltaRuntimeState* delta_runtime_enter(
 DeltaRuntime* runtime,
 DeltaRuntimeControl** entered_control
) @private
{
 if (!runtime || !runtime.generation || !runtime.identity
  || runtime.slot >= DELTA_MAX_RUNTIME_CONTROLS) return null;
 DeltaRuntimeControl* control = &delta_runtime_controls[runtime.slot];
 if (!delta_runtime_control_enter(control)) return null;
 if (control.generation.load() != runtime.generation
  || control.identity != runtime.identity
  || control.state.identity != runtime.identity)
 {
  delta_runtime_control_leave(control);
  return null;
 }
 if (entered_control) *entered_control = control;
 return &control.state;
}

fn ulong DeltaRuntime.runtime_identity(&self)
{
 DeltaRuntimeControl* control;
 DeltaRuntimeState* state = delta_runtime_enter(self, &control);
 if (!state) return 0;
 ulong identity = state.identity;
 delta_runtime_control_leave(control);
 return identity;
}

fn DeltaRuntime* DeltaRuntime.init(&self, int max_workers = 0)
{
 *self = { };
 ulong identity = mitos::new_runtime_identity();
 if (!identity) return self;
 usz slot;
 ulong generation;
 DeltaRuntimeControl* control = delta_runtime_allocate_control(
  identity, &slot, &generation
 );
 if (!control) return self;
 DeltaRuntimeState* state = &control.state;
 *state = {
  .max_workers = max_workers,
  .identity = identity,
 };
 typed_delta_registry_init(&state.host_handlers, mem);
 if (!state.host_handlers.initialized)
 {
  state.identity = 0;
  delta_runtime_control_recycle(control);
  return self;
 }
 state.suspensions.init(mem);
 control.entrant_gate.store(DELTA_REGISTRY_GATE_OPEN);
 *self = {
  .slot = slot,
  .generation = generation,
  .identity = identity,
 };
 return self;
}

fn bool DeltaRuntime.free(&self)
{
 DeltaRuntimeControl* control;
 DeltaRuntimeState* state = delta_runtime_enter(self, &control);
 if (!state) return true;
 if (!delta_runtime_control_close_entered(control)) return false;
 TypedDeltaHostRegistry* registry = &state.host_handlers;
 if (!typed_delta_registry_close_gate(registry))
 {
  delta_runtime_control_reopen(control);
  return false;
 }
 registry.mutex.lock();
 usz suspension_count = state.suspensions.len();
 if (!registry.initialized || state.shutting_down || registry.shutting_down
  || registry.active_runs || registry.active_leases != suspension_count
  || suspension_count > DELTA_MAX_RETAINED_SUSPENSIONS)
 {
  registry.mutex.unlock();
  typed_delta_registry_reopen_gate(registry);
  delta_runtime_control_reopen(control);
  return false;
 }
 state.shutting_down = true;
 registry.shutting_down = true;
 TypedDeltaSuspension*[DELTA_MAX_RETAINED_SUSPENSIONS] draining = { };
 usz drained = 0;
 for (SlotId id = 0; id < state.suspensions.next_id; id++)
 {
  if (!state.suspensions.contains_id(id)) continue;
  SlotRef reference = state.suspensions.generation_ref(id);
  DeltaSuspensionRecord* record = state.suspensions.get_ref(reference);
  draining[drained++] = record.suspension;
  assert(state.retained_suspension_bytes >= record.retained_bytes,
   "typed Delta retained suspension byte accounting underflow");
  state.retained_suspension_bytes -= record.retained_bytes;
  record.suspension = null;
  assert(state.suspensions.erase(reference),
   "typed Delta suspension slot could not be drained");
  assert(registry.active_leases,
   "typed Delta retained suspension lease underflow");
  registry.active_leases--;
 }
 foreach (&entry : registry.entries) entry.key.deinit(registry.allocator);
 registry.entries.clear();
 registry.enrollments.clear();
 registry.initialized = false;
 state.identity = 0;
 registry.mutex.unlock();
 for (usz index = 0; index < drained; index++)
 {
  destroy_typed_delta_suspension(draining[index]);
 }
 state.suspensions.free();
 registry.entries.free();
 registry.enrollments.free();
 registry.mutex.destroy();
 typed_delta_registry_mark_destroyed(registry);
 delta_runtime_control_recycle(control);
 *self = { };
 return true;
}

fn bool DeltaRuntime.register_host_handler(
 &self,
 mitos::DeltaProgram* program,
 usz dense_handle,
 TypedDeltaHostHandler handler,
 void* context = null,
 uint abi_major = TYPED_DELTA_HOST_ABI_MAJOR,
 uint abi_minor = TYPED_DELTA_HOST_ABI_MINOR
)
{
 DeltaRuntimeControl* control;
 DeltaRuntimeState* state = delta_runtime_enter(self, &control);
 if (!state) return false;
 defer delta_runtime_control_leave(control);
 return typed_delta_registry_register(
  &state.host_handlers, program, dense_handle, handler, context, abi_major, abi_minor
 );
}

fn bool DeltaRuntime.unregister_host_handler(
 &self,
 mitos::DeltaProgram* program,
 usz dense_handle
)
{
 DeltaRuntimeControl* control;
 DeltaRuntimeState* state = delta_runtime_enter(self, &control);
 if (!state) return false;
 defer delta_runtime_control_leave(control);
 return typed_delta_registry_unregister(
  &state.host_handlers, program, dense_handle
 );
}

fn usz DeltaRuntime.active_suspension_count(&self)
{
 DeltaRuntimeControl* control;
 DeltaRuntimeState* state = delta_runtime_enter(self, &control);
 if (!state) return 0;
 defer delta_runtime_control_leave(control);
 if (!typed_delta_registry_enter(&state.host_handlers)) return 0;
 defer typed_delta_registry_leave(&state.host_handlers);
 state.host_handlers.mutex.lock();
 if (!state.host_handlers.initialized || state.host_handlers.shutting_down)
 {
  state.host_handlers.mutex.unlock();
  return 0;
 }
 usz count = state.suspensions.len();
 state.host_handlers.mutex.unlock();
 return count;
}

fn DeltaTokenActionResult delta_token_action(
 bool ok,
 String diagnostic = "",
 Allocator allocator = mem
) @private
{
 return {
  .ok = ok,
  .allocator = allocator,
  .diagnostic = diagnostic.len ? diagnostic.copy(allocator) : "",
 };
}

fn DeltaSuspensionRecord* delta_token_record_unlocked(
 DeltaRuntimeState* state,
 DeltaResumptionToken token
) @private
{
 if (!state || token.runtime_identity != state.identity || !token.capability_high
  || !token.capability_low) return null;
 SlotRef reference = { .id = token.slot_id, .generation = token.generation };
 if (!state.suspensions.contains_ref(reference)) return null;
 DeltaSuspensionRecord* record = state.suspensions.get_ref(reference);
 if (record.capability_high != token.capability_high
  || record.capability_low != token.capability_low
  || record.effect_epoch != token.effect_epoch) return null;
 return record;
}

fn bool delta_capability_exists_unlocked(
 DeltaRuntimeState* state,
 ulong capability_high,
 ulong capability_low
) @private
{
 for (SlotId id = 0; id < state.suspensions.next_id; id++)
 {
  if (!state.suspensions.contains_id(id)) continue;
  DeltaSuspensionRecord* record =
   state.suspensions.get_ref(state.suspensions.generation_ref(id));
  if (record.capability_high == capability_high
   && record.capability_low == capability_low) return true;
 }
 return false;
}

fn bool delta_runtime_attach_suspension(
 DeltaRuntimeState* state,
 TypedDeltaSuspension* suspension,
 TypedDeltaExecutionResult* result
) @private
{
 if (!state || !suspension || !suspension.context || !result) return false;
 TypedDeltaHostRegistry* registry = &state.host_handlers;
 registry.mutex.lock();
 usz retained_bytes = suspension.context.owned_bytes;
 if (!retained_bytes) retained_bytes = 1;
 if (!registry.initialized || registry.shutting_down || state.shutting_down
  || !registry.active_runs
  || state.suspensions.len() >= DELTA_MAX_RETAINED_SUSPENSIONS
  || state.retained_suspension_bytes > DELTA_MAX_RETAINED_SUSPENSION_BYTES
  || retained_bytes > DELTA_MAX_RETAINED_SUSPENSION_BYTES
   - state.retained_suspension_bytes)
 {
  registry.mutex.unlock();
  return false;
 }
 ulong capability_high = 0;
 ulong capability_low = 0;
 bool unique = false;
 for (usz attempt = 0; attempt < 32; attempt++)
 {
  if (!typed_delta_secure_pair(&capability_high, &capability_low)) break;
  if (!delta_capability_exists_unlocked(
   state, capability_high, capability_low
  ))
  {
   unique = true;
   break;
  }
 }
 if (!unique)
 {
  registry.mutex.unlock();
  return false;
 }
 SlotRef reference = state.suspensions.push({
  .capability_high = capability_high,
  .capability_low = capability_low,
  .effect_epoch = suspension.effect_epoch,
  .retained_bytes = retained_bytes,
  .state = RESUMPTION_ACTIVE,
  .suspension = suspension,
 });
 state.retained_suspension_bytes += retained_bytes;
 result.token = {
  .runtime_identity = state.identity,
  .slot_id = reference.id,
  .generation = reference.generation,
  .capability_high = capability_high,
  .capability_low = capability_low,
  .effect_epoch = suspension.effect_epoch,
 };
 registry.active_runs--;
 registry.mutex.unlock();
 return true;
}

/** Typed DeltaProgram execution is the sole executable Mitos runtime path. */
fn bool delta_effect_metadata_current(mitos::DeltaProgram* program) @private
{
 if (!program || !program.runtime_identity || !program.effects.epoch) return false;
 foreach (&row : program.effects.rows)
 {
  if (row.effect_epoch != program.effects.epoch) return false;
 }
 return true;
}

fn TypedDeltaExecutionResult DeltaRuntime.run(&self, mitos::DeltaProgram* program)
{
 DeltaRuntimeControl* control;
 DeltaRuntimeState* state = delta_runtime_enter(self, &control);
 if (!state)
 {
  return typed_delta_failure("Delta runtime registry is unavailable", mem);
 }
 TypedDeltaHostRegistry* registry = &state.host_handlers;
 if (!typed_delta_registry_enter(registry))
 {
  delta_runtime_control_leave(control);
  return typed_delta_failure("Delta runtime registry is unavailable", mem);
 }
 if (!typed_delta_registry_begin_execution(registry))
 {
  typed_delta_registry_leave(registry);
  delta_runtime_control_leave(control);
  return typed_delta_failure("Delta runtime registry is unavailable", mem);
 }
 typed_delta_registry_leave(registry);
 delta_runtime_control_leave(control);
 if (!delta_effect_metadata_current(program))
 {
  typed_delta_registry_finish_execution(registry);
  return typed_delta_failure(
   "DeltaProgram effect rows are stale for the current effect epoch", mem
  );
 }
 TypedDeltaSuspension* suspension = null;
 TypedDeltaExecutionResult result = run_typed_delta_program(
  program, state.max_workers, registry, mem, &suspension
 );
 if (result.status != TYPED_DELTA_SUSPENDED)
 {
  typed_delta_registry_finish_execution(registry);
  return result;
 }
 if (!delta_runtime_attach_suspension(state, suspension, &result))
 {
  destroy_typed_delta_suspension(suspension);
  typed_delta_registry_finish_execution(registry);
  result.deinit();
  return typed_delta_failure(
   "Delta runtime retained-suspension budget or secure capability is unavailable", mem
  );
 }
 return result;
}

fn TypedDeltaExecutionResult DeltaRuntime.resume(
 &self,
 DeltaResumptionToken token,
 TypedDeltaHostValue value
)
{
 DeltaRuntimeControl* control;
 DeltaRuntimeState* state = delta_runtime_enter(self, &control);
 if (!state)
 {
  return typed_delta_failure("Delta runtime registry is unavailable", mem);
 }
 TypedDeltaHostRegistry* registry = &state.host_handlers;
 if (!typed_delta_registry_enter(registry))
 {
  delta_runtime_control_leave(control);
  return typed_delta_failure("Delta runtime registry is unavailable", mem);
 }
 registry.mutex.lock();
 if (!registry.initialized || registry.shutting_down)
 {
  registry.mutex.unlock();
  typed_delta_registry_leave(registry);
  delta_runtime_control_leave(control);
  return typed_delta_failure("Delta runtime registry is unavailable", mem);
 }
 if (registry.active_runs)
 {
  registry.mutex.unlock();
  typed_delta_registry_leave(registry);
  delta_runtime_control_leave(control);
  return typed_delta_failure("another Delta execution is already active", mem);
 }
 DeltaSuspensionRecord* record = delta_token_record_unlocked(state, token);
 if (!record)
 {
  registry.mutex.unlock();
  typed_delta_registry_leave(registry);
  delta_runtime_control_leave(control);
  return typed_delta_failure(
   "resumption token is invalid or belongs to another runtime", mem
  );
 }
 if (record.state != RESUMPTION_ACTIVE || !record.suspension)
 {
  registry.mutex.unlock();
  typed_delta_registry_leave(registry);
  delta_runtime_control_leave(control);
  return typed_delta_failure("resumption token has already been consumed", mem);
 }
 if (record.suspension.effect_epoch != token.effect_epoch)
 {
  registry.mutex.unlock();
  typed_delta_registry_leave(registry);
  delta_runtime_control_leave(control);
  return typed_delta_failure("resumption token effect epoch is stale", mem);
 }
 if (!typed_delta_suspension_accepts_host(record.suspension, value))
 {
  registry.mutex.unlock();
  typed_delta_registry_leave(registry);
  delta_runtime_control_leave(control);
  return typed_delta_failure(
   "resumption result is not a valid host representation for its TypeId", mem
  );
 }
 if (!typed_delta_suspension_accepts(record.suspension, value.type_id))
 {
  registry.mutex.unlock();
  typed_delta_registry_leave(registry);
  delta_runtime_control_leave(control);
  return typed_delta_failure(
   "resumption result TypeId does not match the suspended operation", mem
  );
 }
 assert(registry.active_leases,
  "typed Delta resumption has no retained registry lease");
 TypedDeltaSuspension* suspension = record.suspension;
 usz retained_bytes = record.retained_bytes;
 SlotRef reference = { .id = token.slot_id, .generation = token.generation };
 record.state = RESUMPTION_RESUMING;
 record.suspension = null;
 registry.active_runs++;
 registry.mutex.unlock();
 typed_delta_registry_leave(registry);
 delta_runtime_control_leave(control);

 TypedDeltaSuspension* next_suspension = null;
 TypedDeltaExecutionResult result = resume_typed_delta_suspension(
  suspension, value, state.max_workers, &next_suspension
 );
 registry.mutex.lock();
 assert(state.suspensions.contains_ref(reference),
  "typed Delta resumption record disappeared while owned");
 DeltaSuspensionRecord* consumed = state.suspensions.get_ref(reference);
 assert(consumed.state == RESUMPTION_RESUMING && !consumed.suspension,
  "typed Delta resumption record changed while owned");
 assert(state.retained_suspension_bytes >= retained_bytes,
  "typed Delta retained suspension byte accounting underflow");
 state.retained_suspension_bytes -= retained_bytes;
 assert(state.suspensions.erase(reference),
  "typed Delta consumed resumption slot could not be erased");
 registry.mutex.unlock();
 if (result.status == TYPED_DELTA_SUSPENDED)
 {
  if (!delta_runtime_attach_suspension(state, next_suspension, &result))
  {
   destroy_typed_delta_suspension(next_suspension);
   typed_delta_registry_finish_execution(registry);
   result.deinit();
   return typed_delta_failure(
    "Delta runtime retained-suspension budget or secure capability is unavailable", mem
   );
  }
 }
 else
 {
  typed_delta_registry_finish_execution(registry);
 }
 return result;
}

fn DeltaTokenActionResult DeltaRuntime.cancel(
 &self,
 DeltaResumptionToken token,
 Allocator allocator = mem
)
{
 DeltaRuntimeControl* control;
 DeltaRuntimeState* state = delta_runtime_enter(self, &control);
 if (!state)
 {
  return delta_token_action(false, "Delta runtime registry is unavailable", allocator);
 }
 defer delta_runtime_control_leave(control);
 TypedDeltaHostRegistry* registry = &state.host_handlers;
 if (!typed_delta_registry_enter(registry))
 {
  return delta_token_action(false, "Delta runtime registry is unavailable", allocator);
 }
 defer typed_delta_registry_leave(registry);
 registry.mutex.lock();
 if (!registry.initialized || registry.shutting_down)
 {
  registry.mutex.unlock();
  return delta_token_action(false, "Delta runtime registry is unavailable", allocator);
 }
 DeltaSuspensionRecord* record = delta_token_record_unlocked(state, token);
 if (!record)
 {
  registry.mutex.unlock();
  return delta_token_action(
   false, "resumption token is invalid or belongs to another runtime", allocator
  );
 }
 if (record.state != RESUMPTION_ACTIVE || !record.suspension)
 {
  registry.mutex.unlock();
  return delta_token_action(false, "resumption token has already been consumed", allocator);
 }
 TypedDeltaSuspension* suspension = record.suspension;
 usz retained_bytes = record.retained_bytes;
 SlotRef reference = { .id = token.slot_id, .generation = token.generation };
 record.suspension = null;
 assert(state.suspensions.erase(reference),
  "typed Delta cancelled resumption slot could not be erased");
 assert(state.retained_suspension_bytes >= retained_bytes,
  "typed Delta retained suspension byte accounting underflow");
 state.retained_suspension_bytes -= retained_bytes;
 assert(registry.active_leases,
  "typed Delta cancelled suspension lease underflow");
 registry.active_leases--;
 registry.mutex.unlock();
 destroy_typed_delta_suspension(suspension);
 return delta_token_action(true, "", allocator);
}
