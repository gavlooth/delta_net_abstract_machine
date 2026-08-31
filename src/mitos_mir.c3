module delta_net_abstract_machine::mitos_mir;

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
	CACHED_CALL,
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

struct MirString
{
	char* bytes;
	usz length;
	uint runtime_type;
	uint reserved;
}

struct MirEffectOperation
{
	uint effect;
	uint operation;
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


struct MirProgram
{
	MirFunction* functions;
	MirInstruction* instructions;
	uint* operands;
	MirConstructor* constructors;
	MirType* types;
	MirString* strings;
	MirEffectOperation* effect_operations;
	void** native_methods;
	uint function_count;
	uint instruction_count;
	uint operand_count;
	uint constructor_count;
	uint type_count;
	uint string_count;
	uint effect_operation_count;
	uint native_method_count;
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
}
 
struct MirNativeCompileOutcome @private
{
	void* native_result;
	char* diagnostic;
}

struct MirBridgeOutcome @private
{
	uint status;
	uint reserved;
	char* result;
	char* diagnostic;
}

struct MirExecutionResult
{
	MirStatus status;
	String result;
	String diagnostic;
	Allocator allocator;
}

$assert long::size == 8;
$assert uint::size == 4;
$assert MirFunction::size == 16;
$assert MirInstruction::size == 32;
$assert MirConstructor::size == 32;
$assert MirType::size == 40;
$assert MirString::size == 24;
$assert MirEffectOperation::size == 24;
$assert MirMatchArm::size == 8;
$assert MirProgram::size == 160;
$assert MirBridgeOutcome::size == 24;
$assert MirNativeCompileOutcome::size == 16;

extern fn MirBridgeOutcome mitos_mir_execute(MirProgram* program) @private;
extern fn void mitos_mir_outcome_free(MirBridgeOutcome* outcome) @private;
extern fn MirNativeCompileOutcome mitos_mir_compile_method(
	MirProgram* program,
	uint function_index
) @private;
extern fn void mitos_mir_compile_outcome_free(MirNativeCompileOutcome* outcome) @private;
extern fn void mitos_mir_native_result_free(void* native_result) @private;

fn void release_native_result(void* native_result)
{
	if (native_result) mitos_mir_native_result_free(native_result);
}

fn void* compile_method(
	MirProgram* program,
	uint function_index,
	String* diagnostic,
	Allocator allocator = mem
)
{
	MirNativeCompileOutcome outcome = mitos_mir_compile_method(program, function_index);
	defer mitos_mir_compile_outcome_free(&outcome);
	if (outcome.diagnostic && diagnostic)
	{
		*diagnostic = ((ZString)outcome.diagnostic).copy(allocator);
	}
	return outcome.native_result;
}

fn MirExecutionResult execute(MirProgram* program, Allocator allocator = mem)
{
	MirBridgeOutcome outcome = mitos_mir_execute(program);
	defer mitos_mir_outcome_free(&outcome);
	String result = { };
	String diagnostic = { };
	if (outcome.result) result = ((ZString)outcome.result).copy(allocator);
	if (outcome.diagnostic) diagnostic = ((ZString)outcome.diagnostic).copy(allocator);
	return {
		.status = outcome.status == 0 ? NATIVE : ERROR,
		.result = result,
		.diagnostic = diagnostic,
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
