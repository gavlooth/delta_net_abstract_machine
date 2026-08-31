#ifndef MITOS_MIR_BRIDGE_H
#define MITOS_MIR_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum MitosMirOpcode {
    MITOS_MIR_CONST = 0,
    MITOS_MIR_MOVE,
    MITOS_MIR_ADD,
    MITOS_MIR_SUBTRACT,
    MITOS_MIR_MULTIPLY,
    MITOS_MIR_DIVIDE,
    MITOS_MIR_REMAINDER,
    MITOS_MIR_EQUAL,
    MITOS_MIR_LESS,
    MITOS_MIR_LESS_EQUAL,
    MITOS_MIR_GREATER,
    MITOS_MIR_GREATER_EQUAL,
    MITOS_MIR_CALL,
    MITOS_MIR_MAKE_CONSTRUCTOR,
    MITOS_MIR_TAG_EQUAL,
    MITOS_MIR_GET_FIELD,
    MITOS_MIR_LABEL,
    MITOS_MIR_JUMP,
    MITOS_MIR_BRANCH_FALSE,
    MITOS_MIR_TYPE_VALUE,
    MITOS_MIR_TYPE_OF,
    MITOS_MIR_TYPE_ASSERT,
    MITOS_MIR_STRING_CONST,
    MITOS_MIR_CACHED_CALL,
    MITOS_MIR_EXTERNAL_EFFECT,
    MITOS_MIR_PARALLEL_CALL,
    MITOS_MIR_PARALLEL_JOIN,
    MITOS_MIR_MAKE_FUNCTION,
    MITOS_MIR_APPLY_FUNCTION,
    MITOS_MIR_RETURN,
    MITOS_MIR_SUPERPOSE,
    MITOS_MIR_COLLAPSE,
    MITOS_MIR_LIFT_CONSTRUCTOR,
    MITOS_MIR_LIFT_CALL,
    MITOS_MIR_LIFT_MATCH,
    MITOS_MIR_LIFT_MAKE_FUNCTION
} MitosMirOpcode;

typedef enum MitosMirStatus {
    MITOS_MIR_NATIVE = 0,
    MITOS_MIR_ERROR = 1
} MitosMirStatus;

typedef struct MitosMirFunction {
    uint32_t parameter_count;
    uint32_t register_count;
    uint32_t instruction_start;
    uint32_t instruction_count;
} MitosMirFunction;

typedef struct MitosMirInstruction {
    uint32_t opcode;
    uint32_t destination;
    uint32_t a;
    uint32_t b;
    uint32_t operand_start;
    uint32_t operand_count;
    int64_t immediate;
} MitosMirInstruction;

typedef struct MitosMirConstructor {
    uint32_t tag;
    uint32_t arity;
    uint32_t runtime_type;
    uint32_t reserved;
    const char *name;
    size_t name_length;
} MitosMirConstructor;

typedef struct MitosMirType {
    uint32_t id;
    uint32_t parent;
    uint32_t type_value_runtime;
    uint32_t kind;
    const char *name;
    size_t name_length;
    uint32_t constructor;
    uint32_t argument;
} MitosMirType;

typedef struct MitosMirString {
    const char *bytes;
    size_t length;
    uint32_t runtime_type;
    uint32_t reserved;
} MitosMirString;

typedef struct MitosMirEffectOperation {
    uint32_t effect;
    uint32_t operation;
    uint32_t result_type;
    uint32_t abi_major;
    uint32_t abi_minor;
    uint32_t flags;
} MitosMirEffectOperation;
typedef struct MitosMirMatchArm {
    uint32_t constructor;
    uint32_t flags;
} MitosMirMatchArm;


typedef struct MitosMirProgram {
    const MitosMirFunction *functions;
    const MitosMirInstruction *instructions;
    const uint32_t *operands;
    const MitosMirConstructor *constructors;
    const MitosMirType *types;
    const MitosMirString *strings;
    const MitosMirEffectOperation *effect_operations;
    void *const *native_methods;
    uint32_t function_count;
    uint32_t instruction_count;
    uint32_t operand_count;
    uint32_t constructor_count;
    uint32_t type_count;
    uint32_t string_count;
    uint32_t effect_operation_count;
    uint32_t native_method_count;
    uint32_t main_function;
    uint32_t true_tag;
    uint32_t false_tag;
    uint32_t i64_type;
    uint32_t bool_type;
    uint32_t string_type;
    uint32_t type_type;
    uint32_t function_type;
    uint32_t phase_one_root_count;
    uint32_t max_workers;
    uint32_t reserved;
    const MitosMirMatchArm *match_arms;
    uint32_t match_arm_count;
    uint32_t reserved2;
} MitosMirProgram;

typedef struct MitosMirOutcome {
    uint32_t status;
    uint32_t reserved;
    char *result;
    char *diagnostic;
} MitosMirOutcome;

typedef struct MitosMirNativeCompileOutcome {
    void *native_result;
    char *diagnostic;
} MitosMirNativeCompileOutcome;


typedef enum MitosMirHostValueKind {
    MITOS_HOST_I64 = 0,
    MITOS_HOST_BOOL,
    MITOS_HOST_UNIT,
    MITOS_HOST_STRING,
    MITOS_HOST_CONSTRUCTOR,
    MITOS_HOST_FUNCTION,
    MITOS_HOST_TYPE,
    MITOS_HOST_SUPERPOSITION,
    MITOS_HOST_ARRAY
} MitosMirHostValueKind;

typedef struct MitosMirHostValue {
    uint8_t kind;
    uint8_t reserved[3];
    uint32_t type_id;
    int64_t integer;
    uint8_t boolean;
    uint8_t reserved2[3];
    uint32_t represented_type;
    const char *string;
    size_t string_length;
} MitosMirHostValue;

typedef struct MitosMirHostCall {
    uint32_t abi_major;
    uint32_t abi_minor;
    uint32_t effect;
    uint32_t operation;
    uint64_t source_order;
    uint64_t occurrence_order;
    const MitosMirHostValue *arguments;
    size_t argument_count;
    MitosMirHostValue result;
    const char *diagnostic;
    size_t diagnostic_length;
} MitosMirHostCall;

typedef int (*MitosMirHostHandler)(MitosMirHostCall *call, void *context);

int mitos_mir_register_host_helper(uint32_t operation, uint32_t abi_major,
                                   uint32_t abi_minor, MitosMirHostHandler handler,
                                   void *context);
void mitos_mir_unregister_host_helper(uint32_t operation);

MitosMirOutcome mitos_mir_execute(const MitosMirProgram *program);
MitosMirNativeCompileOutcome mitos_mir_compile_method(
    const MitosMirProgram *program,
    uint32_t function_index
);
void mitos_mir_compile_outcome_free(MitosMirNativeCompileOutcome *outcome);
void mitos_mir_outcome_free(MitosMirOutcome *outcome);
void mitos_mir_native_result_free(void *native_result);

#ifdef __cplusplus
}
#endif

#endif
