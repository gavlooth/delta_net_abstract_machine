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
    MITOS_MIR_RESERVED_31,
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

typedef uint32_t MitosMirHostDisposition;
enum {
    MITOS_MIR_HOST_READY = 0,
    MITOS_MIR_HOST_SUSPEND = 1,
    MITOS_MIR_HOST_FAIL = 2
};

typedef enum MitosMirCapability {
    MITOS_MIR_CAP_HOST_ABI_2 = 1u << 0
} MitosMirCapability;

typedef enum MitosMirEffectOperationFlag {
    MITOS_MIR_EFFECT_ORDERED = 1u << 0,
    MITOS_MIR_EFFECT_EXTERNAL = 1u << 1
} MitosMirEffectOperationFlag;

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

typedef struct MitosMirLayout {
    uint32_t type_id;
    uint32_t kind;
    uint32_t copy_policy;
    uint32_t flags;
    uint64_t size;
    uint64_t alignment;
    uint64_t stride;
    uint32_t element_type;
    uint32_t reserved;
} MitosMirLayout;

typedef struct MitosMirString {
    const char *bytes;
    size_t length;
    uint32_t runtime_type;
    uint32_t reserved;
} MitosMirString;

typedef struct MitosMirEffectOperation {
    uint32_t dense_handle;
    uint32_t effect;
    uint32_t operation;
    uint32_t arity;
    uint32_t result_type;
    uint32_t abi_major;
    uint32_t abi_minor;
    uint32_t flags;
} MitosMirEffectOperation;
typedef struct MitosMirMatchArm {
    uint32_t constructor;
    uint32_t flags;
} MitosMirMatchArm;
typedef struct MitosMirSpan {
    uint64_t start_offset;
    uint64_t start_row;
    uint64_t start_column;
    uint64_t end_offset;
    uint64_t end_row;
    uint64_t end_column;
} MitosMirSpan;



typedef struct MitosMirProgram {
    const MitosMirFunction *functions;
    const MitosMirInstruction *instructions;
    const uint32_t *operands;
    const MitosMirConstructor *constructors;
    const MitosMirType *types;
    const MitosMirLayout *layouts;
    const MitosMirString *strings;
    const MitosMirEffectOperation *effect_operations;
    void *const *reserved_methods;
    uint64_t program_identity;
    uint32_t function_count;
    uint32_t instruction_count;
    uint32_t operand_count;
    uint32_t constructor_count;
    uint32_t type_count;
    uint32_t layout_count;
    uint32_t string_count;
    uint32_t effect_operation_count;
    uint32_t reserved_method_count;
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
    const MitosMirSpan *spans;
    uint32_t span_count;
    uint32_t max_source_order;
} MitosMirProgram;

typedef struct MitosMirOutcome {
    uint32_t status;
    uint32_t reserved;
    char *result;
    char *diagnostic;
    MitosMirSpan diagnostic_span;
} MitosMirOutcome;



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

typedef MitosMirHostDisposition (*MitosMirHostHandler)(
    MitosMirHostCall *call,
    void *context
);

typedef struct MitosMirRuntime MitosMirRuntime;

typedef struct MitosMirRegistrySnapshot {
    uint64_t generation;
    uint32_t helper_count;
    uint32_t capabilities;
} MitosMirRegistrySnapshot;

MitosMirRuntime *mitos_mir_runtime_create(void);
uint32_t mitos_mir_runtime_destroy(MitosMirRuntime *runtime);
uint32_t mitos_mir_runtime_capabilities(MitosMirRuntime *runtime);
uint32_t mitos_mir_runtime_snapshot(
    MitosMirRuntime *runtime,
    MitosMirRegistrySnapshot *snapshot
);
uint32_t mitos_mir_runtime_register_host_helper(
    MitosMirRuntime *runtime,
    const MitosMirProgram *program,
    uint32_t dense_handle,
    uint32_t abi_major,
    uint32_t abi_minor,
    MitosMirHostHandler handler,
    void *context
);
uint32_t mitos_mir_runtime_unregister_host_helper(
    MitosMirRuntime *runtime,
    const MitosMirProgram *program,
    uint32_t dense_handle
);

MitosMirOutcome mitos_mir_execute(
    MitosMirRuntime *runtime,
    const MitosMirProgram *program
);
void mitos_mir_outcome_free(MitosMirOutcome *outcome);

#ifdef __cplusplus
}
#endif

#endif
