module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import std::collections::list;

const int DELTA_MAX_WORKERS = 256;
const uint TYPED_DELTA_HOST_ABI_MAJOR = 1;
const uint TYPED_DELTA_HOST_ABI_MINOR = 1;

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

/** ABI-stable, borrowed view passed to an external effect helper. */
struct TypedDeltaHostValue
{
 TypedDeltaHostValueKind kind;
 mitos::TypeId type_id;
 long integer;
 bool boolean;
 mitos::TypeId represented_type;
 String string;
}

/** Versioned external-effect helper call. Arguments and diagnostic are borrowed. */
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

alias TypedDeltaHostHandler = fn bool(TypedDeltaHostCall* call, void* context);

struct TypedDeltaHostHandlerEntry
{
 mitos::OperationId operation;
 uint abi_major;
 uint abi_minor;
 TypedDeltaHostHandler handler;
 void* context;
}

struct TypedDeltaHostRegistry
{
 Allocator allocator;
 List{TypedDeltaHostHandlerEntry} entries;
}

fn TypedDeltaHostRegistry* TypedDeltaHostRegistry.init(
 &self,
 Allocator allocator = mem
)
{
 *self = { .allocator = allocator };
 self.entries.init(allocator);
 return self;
}

fn void TypedDeltaHostRegistry.free(&self)
{
 if (!self.allocator) return;
 self.entries.free();
 *self = { };
}

fn bool TypedDeltaHostRegistry.register(
 &self,
 mitos::OperationId operation,
 TypedDeltaHostHandler handler,
 void* context = null,
 uint abi_major = TYPED_DELTA_HOST_ABI_MAJOR,
 uint abi_minor = TYPED_DELTA_HOST_ABI_MINOR
)
{
 if (!operation || !handler || abi_major != TYPED_DELTA_HOST_ABI_MAJOR
  || abi_minor > TYPED_DELTA_HOST_ABI_MINOR) return false;
 foreach (&entry : self.entries)
 {
  if (entry.operation != operation) continue;
  *entry = {
   .operation = operation,
   .abi_major = abi_major,
   .abi_minor = abi_minor,
   .handler = handler,
   .context = context,
  };
  return true;
 }
 self.entries.push({
  .operation = operation,
  .abi_major = abi_major,
  .abi_minor = abi_minor,
  .handler = handler,
  .context = context,
 });
 return true;
}

fn TypedDeltaHostHandlerEntry* TypedDeltaHostRegistry.find(
 &self,
 mitos::OperationId operation
)
{
 foreach (&entry : self.entries)
  if (entry.operation == operation) return entry;
 return null;
}

struct DeltaRuntime
{
 int max_workers;
 ulong minimum_effect_epoch;
 TypedDeltaHostRegistry host_handlers;
}

fn DeltaRuntime* DeltaRuntime.init(&self, int max_workers = 0)
{
 *self = { .max_workers = max_workers, .minimum_effect_epoch = 1 };
 self.host_handlers.init(mem);
 return self;
}

fn void DeltaRuntime.free(&self)
{
 self.host_handlers.free();
 *self = { };
}

fn bool DeltaRuntime.register_host_handler(
 &self,
 mitos::OperationId operation,
 TypedDeltaHostHandler handler,
 void* context = null,
 uint abi_major = TYPED_DELTA_HOST_ABI_MAJOR,
 uint abi_minor = TYPED_DELTA_HOST_ABI_MINOR
)
{
 return self.host_handlers.register(
  operation, handler, context, abi_major, abi_minor
 );
}

/** Typed DeltaProgram execution is the sole executable Mitos runtime path. */
fn bool delta_effect_metadata_current(mitos::DeltaProgram* program) @private
{
 if (!program || !program.effects.epoch) return false;
 foreach (&row : program.effects.rows)
  if (row.effect_epoch != program.effects.epoch) return false;
 return true;
}

fn TypedDeltaExecutionResult DeltaRuntime.run(&self, mitos::DeltaProgram* program)
{
 if (!delta_effect_metadata_current(program)
  || program.effects.epoch < self.minimum_effect_epoch)
 {
  TypedDeltaExecutionResult result = { .allocator = mem };
  result.diagnostics = alloc::new_array(mem, DeltaDiagnostic, 1);
  result.diagnostics[0].init(
   mem, "DeltaProgram effect rows are stale for the current effect epoch"
  );
  return result;
 }
 return run_typed_delta_program(
  program, self.max_workers, &self.host_handlers, mem
 );
}
