module delta_net_abstract_machine::mitos_mir;
import delta_net_abstract_machine::mitos;

import std::atomic::types;
import std::thread;

enum MirOpcode : uint
{
	CONST,
	MOVE,
	ADD,
	SUBTRACT,
	MULTIPLY,
	DIVIDE,
	REMAINDER,
	EQUAL,
	LESS,
	LESS_EQUAL,
	GREATER,
	GREATER_EQUAL,
	CALL,
	MAKE_CONSTRUCTOR,
	TAG_EQUAL,
	GET_FIELD,
	LABEL,
	JUMP,
	BRANCH_FALSE,
	TYPE_VALUE,
	TYPE_OF,
	TYPE_ASSERT,
	STRING_CONST,
	RESERVED_31,
	EXTERNAL_EFFECT,
	PARALLEL_CALL,
	PARALLEL_JOIN,
	MAKE_FUNCTION,
	APPLY_FUNCTION,
	RETURN,
	SUPERPOSE,
	COLLAPSE,
	LIFT_CONSTRUCTOR,
	LIFT_CALL,
	LIFT_MATCH,
	LIFT_MAKE_FUNCTION,
}

enum MirStatus : uint
{
	NATIVE,
	ERROR,
}

enum MirHostDisposition : uint
{
	HOST_READY,
	HOST_SUSPEND,
	HOST_FAIL,
}

const uint MIR_CAP_HOST_ABI_2 = 1u << 0;
const ulong MIR_RUNTIME_GATE_CLOSED = (ulong)1 << 63;
const ulong MIR_RUNTIME_GATE_OPEN = (ulong)1 << 61;
const ulong MIR_RUNTIME_GATE_COUNT = MIR_RUNTIME_GATE_OPEN - 1;

struct MirFunction
{
	uint parameter_count;
	uint register_count;
	uint instruction_start;
	uint instruction_count;
}

struct MirInstruction
{
	MirOpcode opcode;
	uint destination;
	uint a;
	uint b;
	uint operand_start;
	uint operand_count;
	long immediate;
}

struct MirConstructor
{
	uint tag;
	uint arity;
	uint runtime_type;
	uint reserved;
	char* name;
	usz name_length;
}

struct MirType
{
	uint id;
	uint parent;
	uint type_value_runtime;
	uint kind;
	char* name;
	usz name_length;
	uint constructor;
	uint argument;
}

struct MirLayout
{
	uint type_id;
	uint kind;
	uint copy_policy;
	uint flags;
	ulong size;
	ulong alignment;
	ulong stride;
	uint element_type;
	uint reserved;
}

struct MirString
{
	char* bytes;
	usz length;
	uint runtime_type;
	uint reserved;
}

struct MirEffectOperation
{
	uint dense_handle;
	uint effect;
	uint operation;
	uint arity;
	uint result_type;
	uint abi_major;
	uint abi_minor;
	uint flags;
}
struct MirMatchArm
{
	uint constructor;
	uint flags;
}
struct MirSpan
{
	ulong start_offset;
	ulong start_row;
	ulong start_column;
	ulong end_offset;
	ulong end_row;
	ulong end_column;
}



struct MirProgram
{
	MirFunction* functions;
	MirInstruction* instructions;
	uint* operands;
	MirConstructor* constructors;
	MirType* types;
	MirLayout* layouts;
	MirString* strings;
	MirEffectOperation* effect_operations;
	void** reserved_methods;
	ulong program_identity;
	uint function_count;
	uint instruction_count;
	uint operand_count;
	uint constructor_count;
	uint type_count;
	uint layout_count;
	uint string_count;
	uint effect_operation_count;
	uint reserved_method_count;
	uint main_function;
	uint true_tag;
	uint false_tag;
	uint i64_type;
	uint bool_type;
	uint string_type;
	uint type_type;
	uint function_type;
	uint phase_one_root_count;
	uint max_workers;
	uint reserved;
	MirMatchArm* match_arms;
	uint match_arm_count;
	uint reserved2;
	MirSpan* spans;
	uint span_count;
	uint max_source_order;
}
 

struct MirBridgeOutcome @private
{
	uint status;
	uint reserved;
	char* result;
	char* diagnostic;
	MirSpan diagnostic_span;
}

/** Copyable lifecycle token; native handles remain private to validated controls. */
struct MirRuntime
{
	ulong generation;
	ulong capability_high;
	ulong capability_low;
}

struct MirRuntimeControl @private
{
	Atomic{ulong} entrant_gate;
	void* handle;
	MirRuntimeControl* next;
	ulong generation;
	ulong capability_high;
	ulong capability_low;
}

Atomic{ulong} mir_runtime_registry_guard @private;
Atomic{ulong} mir_runtime_next_generation @private;
MirRuntimeControl* mir_runtime_registry_controls @private;

struct MirRegistrySnapshot
{
	ulong generation;
	uint helper_count;
	uint capabilities;
}

struct MirHostValue
{
	char kind;
	char[3] reserved;
	uint type_id;
	long integer;
	char boolean;
	char[3] reserved2;
	uint represented_type;
	char* string;
	usz string_length;
}

struct MirHostCall
{
	uint abi_major;
	uint abi_minor;
	uint effect;
	uint operation;
	ulong source_order;
	ulong occurrence_order;
	MirHostValue* arguments;
	usz argument_count;
	MirHostValue result;
	char* diagnostic;
	usz diagnostic_length;
}

alias MirHostHandler = fn MirHostDisposition(MirHostCall* call, void* context);

struct MirExecutionResult
{
	MirStatus status;
	String result;
	String diagnostic;
	mitos::MitosSpan diagnostic_span;
	Allocator allocator;
}

$assert long::size == 8;
$assert uint::size == 4;
$assert MirHostDisposition::size == 4;
$assert MirFunction::size == 16;
$assert MirInstruction::size == 32;
$assert MirConstructor::size == 32;
$assert MirType::size == 40;
$assert MirLayout::size == 48;
$assert MirString::size == 24;
$assert MirEffectOperation::size == 32;
$assert MirMatchArm::size == 8;
$assert MirSpan::size == 48;
$assert MirProgram::size == 192;
$assert MirBridgeOutcome::size == 72;
$assert MirHostValue::size == 40;
$assert MirHostCall::size == 104;

extern fn void* mitos_mir_runtime_create() @private;
extern fn uint mitos_mir_runtime_destroy(void* runtime) @private;
extern fn uint mitos_mir_runtime_capabilities(void* runtime) @private;
extern fn uint mitos_mir_runtime_snapshot(
	void* runtime,
	MirRegistrySnapshot* snapshot
) @private;
extern fn uint mitos_mir_runtime_register_host_helper(
	void* runtime,
	MirProgram* program,
	uint dense_handle,
	uint abi_major,
	uint abi_minor,
	MirHostHandler handler,
	void* context
) @private;
extern fn uint mitos_mir_runtime_unregister_host_helper(
	void* runtime,
	MirProgram* program,
	uint dense_handle
) @private;
extern fn MirBridgeOutcome mitos_mir_execute(
	void* runtime,
	MirProgram* program
) @private;
extern fn void mitos_mir_outcome_free(MirBridgeOutcome* outcome) @private;

fn void mir_runtime_registry_lock() @private
{
	for (;;)
	{
		ulong expected = 0;
		if (mir_runtime_registry_guard.compare_exchange(&expected, 1)) return;
		thread::yield();
	}
}

fn void mir_runtime_registry_unlock() @private
{
	mir_runtime_registry_guard.store(0);
}
struct MirRuntimeCapability @private
{
	ulong high;
	ulong low;
}

fn bool mir_runtime_secure_capability(
	ulong* capability_high,
	ulong* capability_low
) @private
{
	for (usz attempt = 0; attempt < 8; attempt++)
	{
		MirRuntimeCapability capability;
		if (!mitos::fill_secure_entropy(
			((char*)&capability)[:MirRuntimeCapability::size]
		)) return false;
		if (!capability.high || !capability.low) continue;
		*capability_high = capability.high;
		*capability_low = capability.low;
		return true;
	}
	return false;
}


fn bool mir_runtime_register(MirRuntimeControl* control) @private
{
	for (usz attempt = 0; attempt < 8; attempt++)
	{
		ulong generation = mir_runtime_next_generation.add(1) + 1;
		ulong capability_high;
		ulong capability_low;
		if (!generation || !mir_runtime_secure_capability(
			&capability_high, &capability_low
		)) continue;
		mir_runtime_registry_lock();
		bool collision = false;
		for (
			MirRuntimeControl* current = mir_runtime_registry_controls;
			current;
			current = current.next
		)
		{
			if (current.generation == generation)
			{
				collision = true;
				break;
			}
		}
		if (!collision)
		{
			control.generation = generation;
			control.capability_high = capability_high;
			control.capability_low = capability_low;
			control.next = mir_runtime_registry_controls;
			mir_runtime_registry_controls = control;
			mir_runtime_registry_unlock();
			return true;
		}
		mir_runtime_registry_unlock();
	}
	return false;
}

fn void* mir_runtime_enter(
	MirRuntime* runtime,
	MirRuntimeControl** entered_control
) @private
{
	ulong generation = runtime ? runtime.generation : 0;
	ulong capability_high = runtime ? runtime.capability_high : 0;
	ulong capability_low = runtime ? runtime.capability_low : 0;
	if (!generation || !capability_high || !capability_low) return null;
	mir_runtime_registry_lock();
	for (
		MirRuntimeControl* current = mir_runtime_registry_controls;
		current;
		current = current.next
	)
	{
		if (current.generation != generation
			|| current.capability_high != capability_high
			|| current.capability_low != capability_low) continue;
		ulong gate = current.entrant_gate.load();
		if (!(gate & MIR_RUNTIME_GATE_OPEN)
			|| gate & MIR_RUNTIME_GATE_CLOSED
			|| (gate & MIR_RUNTIME_GATE_COUNT) == MIR_RUNTIME_GATE_COUNT)
		{
			mir_runtime_registry_unlock();
			return null;
		}
		(void)current.entrant_gate.add(1);
		void* handle = current.handle;
		if (entered_control) *entered_control = current;
		mir_runtime_registry_unlock();
		return handle;
	}
	mir_runtime_registry_unlock();
	return null;
}

fn void mir_runtime_leave(MirRuntimeControl* control) @private
{
	(void)control.entrant_gate.sub(1);
}

const uint MIR_RUNTIME_CLOSE_ABSENT = 0;
const uint MIR_RUNTIME_CLOSE_BUSY = 1;
const uint MIR_RUNTIME_CLOSE_READY = 2;

fn uint mir_runtime_close(
	MirRuntime* runtime,
	MirRuntimeControl** closed_control
) @private
{
	if (closed_control) *closed_control = null;
	ulong generation = runtime ? runtime.generation : 0;
	ulong capability_high = runtime ? runtime.capability_high : 0;
	ulong capability_low = runtime ? runtime.capability_low : 0;
	if (!generation || !capability_high || !capability_low)
	{
		return MIR_RUNTIME_CLOSE_ABSENT;
	}
	mir_runtime_registry_lock();
	for (
		MirRuntimeControl* current = mir_runtime_registry_controls;
		current;
		current = current.next
	)
	{
		if (current.generation != generation
			|| current.capability_high != capability_high
			|| current.capability_low != capability_low) continue;
		ulong gate = current.entrant_gate.load();
		if (!(gate & MIR_RUNTIME_GATE_OPEN)
			|| gate & MIR_RUNTIME_GATE_CLOSED
			|| (gate & MIR_RUNTIME_GATE_COUNT) != 0)
		{
			mir_runtime_registry_unlock();
			return MIR_RUNTIME_CLOSE_BUSY;
		}
		ulong expected = gate;
		if (!current.entrant_gate.compare_exchange(
			&expected, gate | MIR_RUNTIME_GATE_CLOSED
		))
		{
			mir_runtime_registry_unlock();
			return MIR_RUNTIME_CLOSE_BUSY;
		}
		if (closed_control) *closed_control = current;
		mir_runtime_registry_unlock();
		return MIR_RUNTIME_CLOSE_READY;
	}
	mir_runtime_registry_unlock();
	return MIR_RUNTIME_CLOSE_ABSENT;
}

fn void mir_runtime_remove(MirRuntimeControl* control) @private
{
	mir_runtime_registry_lock();
	MirRuntimeControl* previous = null;
	MirRuntimeControl* current = mir_runtime_registry_controls;
	while (current)
	{
		if (current == control && current.generation == control.generation
			&& current.capability_high == control.capability_high
			&& current.capability_low == control.capability_low)
		{
			if (previous)
			{
				previous.next = current.next;
			}
			else
			{
				mir_runtime_registry_controls = current.next;
			}
			current.next = null;
			break;
		}
		previous = current;
		current = current.next;
	}
	mir_runtime_registry_unlock();
}

fn MirRuntime* MirRuntime.init(&self)
{
	*self = { };
	void* handle = mitos_mir_runtime_create();
	if (!handle) return self;
	MirRuntimeControl* control = alloc::new(mem, MirRuntimeControl, {
		.handle = handle,
	});
	control.entrant_gate.store(MIR_RUNTIME_GATE_OPEN);
	if (!mir_runtime_register(control))
	{
		(void)mitos_mir_runtime_destroy(handle);
		alloc::free(mem, control);
		return self;
	}
	self.generation = control.generation;
	self.capability_high = control.capability_high;
	self.capability_low = control.capability_low;
	return self;
}

fn bool MirRuntime.ready(&self)
{
	MirRuntimeControl* control;
	if (!mir_runtime_enter(self, &control)) return false;
	defer mir_runtime_leave(control);
	return true;
}

fn bool MirRuntime.free(&self)
{
	if (!self.generation) return true;
	MirRuntimeControl* control;
	uint close_result = mir_runtime_close(self, &control);
	if (close_result == MIR_RUNTIME_CLOSE_BUSY) return false;
	if (close_result == MIR_RUNTIME_CLOSE_ABSENT)
	{
		*self = { };
		return true;
	}
	if (!control.handle || mitos_mir_runtime_destroy(control.handle) == 0)
	{
		control.entrant_gate.store(MIR_RUNTIME_GATE_OPEN);
		return false;
	}
	control.handle = null;
	mir_runtime_remove(control);
	alloc::free(mem, control);
	*self = { };
	return true;
}

fn uint MirRuntime.capabilities(&self)
{
	MirRuntimeControl* control;
	void* handle = mir_runtime_enter(self, &control);
	if (!handle) return 0;
	defer mir_runtime_leave(control);
	return mitos_mir_runtime_capabilities(handle);
}

fn bool MirRuntime.snapshot(&self, MirRegistrySnapshot* snapshot)
{
	if (!snapshot) return false;
	MirRuntimeControl* control;
	void* handle = mir_runtime_enter(self, &control);
	if (!handle) return false;
	defer mir_runtime_leave(control);
	return mitos_mir_runtime_snapshot(handle, snapshot) != 0;
}

fn bool MirRuntime.register_host_helper(
	&self,
	MirProgram* program,
	uint dense_handle,
	MirHostHandler handler,
	void* context = null
)
{
	if (!program || !program.program_identity || !handler) return false;
	MirRuntimeControl* control;
	void* handle = mir_runtime_enter(self, &control);
	if (!handle) return false;
	defer mir_runtime_leave(control);
	return mitos_mir_runtime_register_host_helper(
		handle, program, dense_handle, 2, 0, handler, context
	) != 0;
}

fn bool MirRuntime.unregister_host_helper(
	&self,
	MirProgram* program,
	uint dense_handle
)
{
	if (!program || !program.program_identity) return false;
	MirRuntimeControl* control;
	void* handle = mir_runtime_enter(self, &control);
	if (!handle) return false;
	defer mir_runtime_leave(control);
	return mitos_mir_runtime_unregister_host_helper(
		handle, program, dense_handle
	) != 0;
}


fn MirExecutionResult execute(
	MirRuntime* runtime,
	MirProgram* program,
	Allocator allocator = mem
)
{
	MirRuntimeControl* control;
	void* handle = mir_runtime_enter(runtime, &control);
	if (!handle) return {
		.status = ERROR,
		.diagnostic = "MIR runtime is unavailable".copy(allocator),
		.allocator = allocator,
	};
	defer mir_runtime_leave(control);
	MirBridgeOutcome outcome = mitos_mir_execute(handle, program);
	defer mitos_mir_outcome_free(&outcome);
	String result = { };
	String diagnostic = { };
	if (outcome.result) result = ((ZString)outcome.result).copy(allocator);
	if (outcome.diagnostic) diagnostic = ((ZString)outcome.diagnostic).copy(allocator);
	return {
		.status = outcome.status == 0 ? NATIVE : ERROR,
		.result = result,
		.diagnostic = diagnostic,
		.diagnostic_span = {
			.start = {
				.offset = (sz)outcome.diagnostic_span.start_offset,
				.row = (sz)outcome.diagnostic_span.start_row,
				.column = (sz)outcome.diagnostic_span.start_column,
			},
			.end = {
				.offset = (sz)outcome.diagnostic_span.end_offset,
				.row = (sz)outcome.diagnostic_span.end_row,
				.column = (sz)outcome.diagnostic_span.end_column,
			},
		},
		.allocator = allocator,
	};
}

fn void MirExecutionResult.free(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.result);
	alloc::free(self.allocator, self.diagnostic);
	*self = { };
}
