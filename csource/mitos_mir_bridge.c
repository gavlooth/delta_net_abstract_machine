#include "mitos_mir_bridge.h"

#include "mir-gen.h"
#include "mir.h"

#include <inttypes.h>
#include <limits.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <threads.h>
#include <stdlib.h>
#include <string.h>

#define MITOS_MAX_FUNCTIONS 65536u
#define MITOS_MAX_CONSTRUCTORS 4096u
#define MITOS_MAX_REGISTERS 65536u
#define MITOS_MAX_INSTRUCTIONS 1000000u
#define MITOS_MAX_OPERANDS 4000000u
#define MITOS_MAX_ARITY 1024u
#define MITOS_MAX_CALL_DEPTH 1024u
#define MITOS_MAX_ALLOCATIONS 1000000u
#define MITOS_MAX_ALLOCATION_BYTES (64u * 1024u * 1024u)
#define MITOS_MAX_VALUE_DEPTH 1024u
#define MITOS_MAX_FORMAT_BYTES (1024u * 1024u)
#define MITOS_DIAGNOSTIC_BYTES 512u
#define MITOS_MAX_ALTERNATIVES 65536u
#define MITOS_MAX_ASSIGNMENTS 1024u
#define MITOS_HELPER_COUNT 33u
_Static_assert(sizeof(MitosMirFunction) == 16, "MitosMirFunction ABI drift");
_Static_assert(sizeof(MitosMirInstruction) == 32, "MitosMirInstruction ABI drift");
_Static_assert(sizeof(MitosMirConstructor) == 32, "MitosMirConstructor ABI drift");
_Static_assert(sizeof(MitosMirType) == 40, "MitosMirType ABI drift");
_Static_assert(sizeof(MitosMirString) == 24, "MitosMirString ABI drift");
_Static_assert(sizeof(MitosMirEffectOperation) == 24, "MitosMirEffectOperation ABI drift");
_Static_assert(sizeof(MitosMirMatchArm) == 8, "MitosMirMatchArm ABI drift");
_Static_assert(sizeof(MitosMirProgram) == 160, "MitosMirProgram ABI drift");


typedef enum ValueKind {
    VALUE_INTEGER = 1,
    VALUE_CONSTRUCTOR = 2,
    VALUE_TYPE = 3,
    VALUE_STRING = 4,
    VALUE_FUNCTION = 5,
    VALUE_FUTURE = 6,
    VALUE_SUPERPOSITION = 7,
    VALUE_ARRAY = 8
} ValueKind;

typedef struct OriginAssignment {
    uint64_t origin;
    uint32_t branch;
    uint32_t reserved;
} OriginAssignment;

struct Value;
typedef struct Alternative {
    struct Value *value;
    OriginAssignment *assignments;
    uint32_t assignment_count;
    uint32_t reserved;
} Alternative;

typedef struct Value {
    uint32_t kind;
    uint32_t tag;
    uint32_t type_id;
    uint32_t represented_type;
    int64_t integer;
    uint32_t arity;
    uint32_t initialized;
    struct Value **fields;
    const char *string;
    size_t string_length;
    void *function;
    Alternative *alternatives;
} Value;

typedef struct Allocation {
    struct Allocation *next;
    size_t size;
} Allocation;

typedef struct Runtime {
    const MitosMirProgram *program;
    Allocation *allocations;
    Value **nullary_values;
    size_t allocation_count;
    size_t allocation_bytes;
    uint32_t call_depth;
    void **function_wrappers;
    uint64_t effect_occurrence;
    char diagnostic[MITOS_DIAGNOSTIC_BYTES];
} Runtime;

typedef struct TextBuilder {
    char *data;
    size_t length;
    size_t capacity;
    Runtime *runtime;
} TextBuilder;
typedef struct MirBuild {
    MIR_context_t context;
    MIR_module_t module;
    MIR_item_t helper_proto;
    MIR_item_t helper_imports[MITOS_HELPER_COUNT];
    MIR_item_t enter_import;
    MIR_item_t leave_import;
    MIR_item_t false_import;
    MIR_item_t *function_protos;
    MIR_item_t *function_forwards;
    MIR_item_t *function_items;
    MIR_item_t *function_wrappers;
    int generator_initialized;
} MirBuild;

typedef int64_t (*NativeWrapper)(int64_t *, uint32_t);

typedef struct NativeMethod {
    MirBuild build;
    NativeWrapper wrapper;
    uint32_t arity;
} NativeMethod;


#define MITOS_MAX_HOST_HELPERS 4096u
typedef struct HostHelperEntry {
    uint32_t operation;
    uint32_t abi_major;
    uint32_t abi_minor;
    MitosMirHostHandler handler;
    void *context;
} HostHelperEntry;

static HostHelperEntry host_helpers[MITOS_MAX_HOST_HELPERS];
static size_t host_helper_count;

int mitos_mir_register_host_helper(uint32_t operation, uint32_t abi_major,
                                   uint32_t abi_minor, MitosMirHostHandler handler,
                                   void *context) {
    size_t index;
    if (operation == 0 || abi_major != 1u || abi_minor > 2u || handler == NULL)
        return 0;
    for (index = 0; index < host_helper_count; ++index) {
        if (host_helpers[index].operation != operation) continue;
        host_helpers[index] = (HostHelperEntry) {
            operation, abi_major, abi_minor, handler, context
        };
        return 1;
    }
    if (host_helper_count >= MITOS_MAX_HOST_HELPERS) return 0;
    host_helpers[host_helper_count++] = (HostHelperEntry) {
        operation, abi_major, abi_minor, handler, context
    };
    return 1;
}

void mitos_mir_unregister_host_helper(uint32_t operation) {
    size_t index;
    for (index = 0; index < host_helper_count; ++index) {
        if (host_helpers[index].operation != operation) continue;
        --host_helper_count;
        host_helpers[index] = host_helpers[host_helper_count];
        memset(&host_helpers[host_helper_count], 0, sizeof(host_helpers[0]));
        return;
    }
}
static void finish_build(MirBuild *build);

static _Thread_local Runtime *active_runtime;
static _Thread_local jmp_buf *active_mir_jump;
static _Thread_local char *active_mir_diagnostic;

static char *copy_text(const char *text) {
    size_t length = text == NULL ? 0 : strlen(text);
    char *copy = (char *) malloc(length + 1);
    if (copy == NULL) return NULL;
    if (length != 0) memcpy(copy, text, length);
    copy[length] = '\0';
    return copy;
}

static MitosMirOutcome outcome_error(const char *message) {
    MitosMirOutcome outcome = {MITOS_MIR_ERROR, 0, NULL, NULL};
    outcome.diagnostic = copy_text(message == NULL ? "native MIR execution failed" : message);
    if (outcome.diagnostic == NULL) outcome.result = NULL;
    return outcome;
}

void mitos_mir_outcome_free(MitosMirOutcome *outcome) {
    if (outcome == NULL) return;
    free(outcome->result);
    free(outcome->diagnostic);
    memset(outcome, 0, sizeof(*outcome));
}

void mitos_mir_native_result_free(void *native_result) {
    NativeMethod *method = (NativeMethod *) native_result;
    if (method == NULL) return;
    finish_build(&method->build);
    free(method);
}

void mitos_mir_compile_outcome_free(MitosMirNativeCompileOutcome *outcome) {
    if (outcome == NULL) return;
    free(outcome->diagnostic);
    outcome->diagnostic = NULL;
}

static void fail(Runtime *runtime, const char *format, ...) {
    va_list arguments;
    if (runtime == NULL || runtime->diagnostic[0] != '\0') return;
    va_start(arguments, format);
    vsnprintf(runtime->diagnostic, sizeof(runtime->diagnostic), format, arguments);
    va_end(arguments);
}

static void *runtime_allocate(Runtime *runtime, size_t size) {
    Allocation *allocation;
    if (runtime == NULL || runtime->diagnostic[0] != '\0') return NULL;
    if (size > MITOS_MAX_ALLOCATION_BYTES
        || runtime->allocation_bytes > MITOS_MAX_ALLOCATION_BYTES - size) {
        fail(runtime, "native value allocation byte limit exceeded");
        return NULL;
    }
    if (runtime->allocation_count >= MITOS_MAX_ALLOCATIONS) {
        fail(runtime, "native value allocation count limit exceeded");
        return NULL;
    }
    allocation = (Allocation *) calloc(1, sizeof(*allocation) + size);
    if (allocation == NULL) {
        fail(runtime, "out of memory while allocating a native value");
        return NULL;
    }
    allocation->size = size;
    allocation->next = runtime->allocations;
    runtime->allocations = allocation;
    runtime->allocation_count++;
    runtime->allocation_bytes += size;
    return allocation + 1;
}

static void runtime_free(Runtime *runtime) {
    Allocation *allocation = runtime->allocations;
    while (allocation != NULL) {
        Allocation *next = allocation->next;
        free(allocation);
        allocation = next;
    }
    runtime->allocations = NULL;
    free(runtime->nullary_values);
    runtime->nullary_values = NULL;
    free(runtime->function_wrappers);
    runtime->function_wrappers = NULL;
}

static const MitosMirConstructor *constructor_by_tag(const Runtime *runtime, uint32_t tag,
                                                     uint32_t *index_out) {
    uint32_t index;
    for (index = 0; index < runtime->program->constructor_count; ++index) {
        if (runtime->program->constructors[index].tag == tag) {
            if (index_out != NULL) *index_out = index;
            return &runtime->program->constructors[index];
        }
    }
    return NULL;
}

static Value *as_value(int64_t raw) { return (Value *) (intptr_t) raw; }
static int64_t from_value(Value *value) { return (int64_t) (intptr_t) value; }

static Value *new_integer(Runtime *runtime, int64_t integer) {
    Value *value = (Value *) runtime_allocate(runtime, sizeof(*value));
    if (value == NULL) return NULL;
    value->kind = VALUE_INTEGER;
    value->type_id = runtime->program->i64_type;
    value->integer = integer;
    return value;
}

static Value *new_constructor(Runtime *runtime, uint32_t tag, uint32_t arity,
                              uint32_t runtime_type) {
    uint32_t descriptor_index = 0;
    const MitosMirConstructor *descriptor =
        constructor_by_tag(runtime, tag, &descriptor_index);
    Value *value;
    if (descriptor == NULL) {
        fail(runtime, "native code requested unknown constructor tag %u", tag);
        return NULL;
    }
    if (descriptor->arity != arity) {
        fail(runtime, "constructor tag %u expected arity %u but received %u", tag,
             descriptor->arity, arity);
        return NULL;
    }
    if (runtime_type == 0) runtime_type = descriptor->runtime_type;
    if (runtime_type == 0 || runtime_type > runtime->program->type_count) {
        fail(runtime, "constructor tag %u has an invalid concrete runtime TypeId", tag);
        return NULL;
    }
    if (arity == 0 && runtime_type == descriptor->runtime_type
        && runtime->nullary_values[descriptor_index] != NULL)
        return runtime->nullary_values[descriptor_index];
    value = (Value *) runtime_allocate(runtime, sizeof(*value));
    if (value == NULL) return NULL;
    value->kind = VALUE_CONSTRUCTOR;
    value->tag = tag;
    value->type_id = runtime_type;
    value->arity = arity;
    if (arity != 0) {
        if (arity > SIZE_MAX / sizeof(Value *)) {
            fail(runtime, "constructor field allocation overflows");
            return NULL;
        }
        value->fields = (Value **) runtime_allocate(runtime, (size_t) arity * sizeof(Value *));
        if (value->fields == NULL) return NULL;
    }
    if (arity == 0 && runtime_type == descriptor->runtime_type)
        runtime->nullary_values[descriptor_index] = value;
    return value;
}

static Value *new_type_value(Runtime *runtime, uint32_t represented_type) {
    Value *value;
    const MitosMirType *represented;
    if (represented_type == 0 || represented_type > runtime->program->type_count) {
        fail(runtime, "native Type value represents an invalid TypeId");
        return NULL;
    }
    represented = &runtime->program->types[represented_type - 1];
    value = (Value *) runtime_allocate(runtime, sizeof(*value));
    if (value == NULL) return NULL;
    value->kind = VALUE_TYPE;
    value->type_id = represented->type_value_runtime;
    value->represented_type = represented_type;
    return value;
}

static Value *new_string(Runtime *runtime, const char *bytes, size_t length,
                         uint32_t runtime_type) {
    Value *value;
    char *owned;
    if (bytes == NULL && length != 0) {
        fail(runtime, "native String literal has a null byte buffer");
        return NULL;
    }
    value = (Value *) runtime_allocate(runtime, sizeof(*value));
    if (value == NULL) return NULL;
    owned = (char *) runtime_allocate(runtime, length + 1);
    if (owned == NULL) return NULL;
    if (length != 0) memcpy(owned, bytes, length);
    owned[length] = '\0';
    value->kind = VALUE_STRING;
    value->type_id = runtime_type;
    value->string = owned;
    value->string_length = length;
    return value;
}
static uint32_t unary_runtime_type(Runtime *runtime, uint32_t constructor,
                                   uint32_t argument) {
    uint32_t index;
    for (index = 0; index < runtime->program->type_count; ++index) {
        const MitosMirType *type = &runtime->program->types[index];
        if (type->constructor == constructor && type->argument == argument)
            return type->id;
    }
    fail(runtime, "native MIR lacks runtime metadata for unary TypeId %u of %u",
         constructor, argument);
    return 0;
}

static int compare_alternative_assignments(const void *left_raw,
                                           const void *right_raw) {
    const Alternative *left = (const Alternative *) left_raw;
    const Alternative *right = (const Alternative *) right_raw;
    uint32_t index, shared = left->assignment_count < right->assignment_count
        ? left->assignment_count : right->assignment_count;
    for (index = 0; index < shared; ++index) {
        const OriginAssignment *l = &left->assignments[index];
        const OriginAssignment *r = &right->assignments[index];
        if (l->origin != r->origin) return l->origin < r->origin ? -1 : 1;
        if (l->branch != r->branch) return l->branch < r->branch ? -1 : 1;
    }
    if (left->assignment_count != right->assignment_count)
        return left->assignment_count < right->assignment_count ? -1 : 1;
    return left->reserved < right->reserved ? -1
        : left->reserved > right->reserved ? 1 : 0;
}

static Value *new_superposition(Runtime *runtime, Alternative *alternatives,
                                uint32_t count, uint32_t runtime_type) {
    Value *value;
    Alternative *owned;
    uint32_t index, element_type;
    if (count == 0 || count > MITOS_MAX_ALTERNATIVES) {
        fail(runtime, "superposition alternative count is out of range");
        return NULL;
    }
    if (alternatives == NULL || alternatives[0].value == NULL
        || alternatives[0].value->kind == VALUE_SUPERPOSITION) {
        fail(runtime, "superposition alternatives must be flattened concrete values");
        return NULL;
    }
    element_type = alternatives[0].value->type_id;
    for (index = 0; index < count; ++index) {
        uint32_t assignment;
        if (alternatives[index].value == NULL
            || alternatives[index].value->kind == VALUE_SUPERPOSITION
            || alternatives[index].value->type_id != element_type
            || alternatives[index].assignment_count > MITOS_MAX_ASSIGNMENTS) {
            fail(runtime, "superposition alternatives must have one concrete runtime TypeId");
            return NULL;
        }
        for (assignment = 0; assignment < alternatives[index].assignment_count; ++assignment) {
            uint32_t previous;
            if (alternatives[index].assignments[assignment].origin == 0) {
                fail(runtime, "superposition branch assignment has no stable origin");
                return NULL;
            }
            for (previous = 0; previous < assignment; ++previous) {
                if (alternatives[index].assignments[previous].origin
                    == alternatives[index].assignments[assignment].origin) {
                    fail(runtime, "superposition branch assignment repeats an origin");
                    return NULL;
                }
            }
        }
    }
    if (runtime_type == 0 || (runtime_type <= runtime->program->type_count
        && runtime->program->types[runtime_type - 1].constructor == 10u
        && runtime->program->types[runtime_type - 1].argument == 1u))
        runtime_type = unary_runtime_type(runtime, 10u, element_type);
    if (runtime_type == 0 || runtime_type > runtime->program->type_count
        || runtime->program->types[runtime_type - 1].constructor != 10u
        || runtime->program->types[runtime_type - 1].argument != element_type) {
        fail(runtime, "superposition runtime TypeId does not match its element TypeId");
        return NULL;
    }
    for (index = 0; index < count; ++index) alternatives[index].reserved = index;
    value = (Value *) runtime_allocate(runtime, sizeof(*value));
    owned = (Alternative *) runtime_allocate(runtime, (size_t) count * sizeof(*owned));
    if (value == NULL || owned == NULL) return NULL;
    memcpy(owned, alternatives, (size_t) count * sizeof(*owned));
    value->kind = VALUE_SUPERPOSITION;
    value->type_id = runtime_type;
    value->represented_type = element_type;
    value->arity = count;
    value->initialized = count;
    value->alternatives = owned;
    return value;
}

static Value *new_array(Runtime *runtime, Value **elements, uint32_t count,
                        uint32_t runtime_type, uint32_t element_type) {
    Value *value;
    Value **owned = NULL;
    uint32_t index;
    if (count > MITOS_MAX_ALTERNATIVES) {
        fail(runtime, "Array element count exceeds the alternative limit");
        return NULL;
    }
    for (index = 0; index < count; ++index) {
        if (elements == NULL || elements[index] == NULL
            || elements[index]->type_id != element_type) {
            fail(runtime, "Array elements must have one concrete runtime TypeId");
            return NULL;
        }
    }
    if (runtime_type == 0 || (runtime_type <= runtime->program->type_count
        && runtime->program->types[runtime_type - 1].constructor == 8u
        && runtime->program->types[runtime_type - 1].argument == 1u))
        runtime_type = unary_runtime_type(runtime, 8u, element_type);
    if (runtime_type == 0 || runtime_type > runtime->program->type_count
        || runtime->program->types[runtime_type - 1].constructor != 8u
        || runtime->program->types[runtime_type - 1].argument != element_type) {
        fail(runtime, "Array runtime TypeId does not match its element TypeId");
        return NULL;
    }
    value = (Value *) runtime_allocate(runtime, sizeof(*value));
    if (count != 0)
        owned = (Value **) runtime_allocate(runtime, (size_t) count * sizeof(*owned));
    if (value == NULL || (count != 0 && owned == NULL)) return NULL;
    if (count != 0) memcpy(owned, elements, (size_t) count * sizeof(*owned));
    value->kind = VALUE_ARRAY;
    value->type_id = runtime_type;
    value->represented_type = element_type;
    value->arity = count;
    value->initialized = count;
    value->fields = owned;
    return value;
}

/* Returns zero for incompatible assignments, one for success, and -1 on error. */
static int merge_assignments(Runtime *runtime,
                             const OriginAssignment *left, uint32_t left_count,
                             const OriginAssignment *right, uint32_t right_count,
                             OriginAssignment **merged_out, uint32_t *count_out) {
    OriginAssignment *merged;
    uint32_t left_index, right_index, count = left_count;
    if (left_count > MITOS_MAX_ASSIGNMENTS || right_count > MITOS_MAX_ASSIGNMENTS) {
        fail(runtime, "superposition assignment count exceeds the resource limit");
        return -1;
    }
    for (right_index = 0; right_index < right_count; ++right_index) {
        int found = 0;
        for (left_index = 0; left_index < left_count; ++left_index) {
            if (left[left_index].origin != right[right_index].origin) continue;
            if (left[left_index].branch != right[right_index].branch) return 0;
            found = 1;
            break;
        }
        if (!found) {
            if (count == MITOS_MAX_ASSIGNMENTS) {
                fail(runtime, "superposition assignment count exceeds the resource limit");
                return -1;
            }
            ++count;
        }
    }
    merged = count == 0 ? NULL : (OriginAssignment *) runtime_allocate(
        runtime, (size_t) count * sizeof(*merged));
    if (count != 0 && merged == NULL) return -1;
    if (left_count != 0) memcpy(merged, left, (size_t) left_count * sizeof(*merged));
    count = left_count;
    for (right_index = 0; right_index < right_count; ++right_index) {
        int found = 0;
        for (left_index = 0; left_index < left_count; ++left_index)
            if (left[left_index].origin == right[right_index].origin) {
                found = 1;
                break;
            }
        if (!found) merged[count++] = right[right_index];
    }
    for (right_index = 1; right_index < count; ++right_index) {
        OriginAssignment moving = merged[right_index];
        left_index = right_index;
        while (left_index != 0
               && merged[left_index - 1].origin > moving.origin) {
            merged[left_index] = merged[left_index - 1];
            --left_index;
        }
        merged[left_index] = moving;
    }
    *merged_out = merged;
    *count_out = count;
    return 1;
}


static int valid_value(Runtime *runtime, Value *value) {
    if (value == NULL) {
        if (runtime->diagnostic[0] == '\0') fail(runtime, "native operation received no value");
        return 0;
    }
    if (value->kind != VALUE_INTEGER && value->kind != VALUE_CONSTRUCTOR
        && value->kind != VALUE_TYPE && value->kind != VALUE_STRING
        && value->kind != VALUE_FUNCTION && value->kind != VALUE_SUPERPOSITION
        && value->kind != VALUE_ARRAY) {
        fail(runtime, "native operation received a corrupt boxed value");
        return 0;
    }
    if (value->type_id == 0 || value->type_id > runtime->program->type_count) {
        fail(runtime, "native operation received a value with an invalid TypeId");
        return 0;
    }
    if (value->kind == VALUE_CONSTRUCTOR && value->initialized != value->arity) {
        fail(runtime, "native operation received an incompletely initialized constructor");
        return 0;
    }
    if ((value->kind == VALUE_SUPERPOSITION || value->kind == VALUE_ARRAY)
        && (value->initialized != value->arity
            || value->arity > MITOS_MAX_ALTERNATIVES
            || (value->arity != 0
                && (value->kind == VALUE_SUPERPOSITION
                    ? value->alternatives == NULL : value->fields == NULL)))) {
        fail(runtime, "native operation received a corrupt aggregate value");
        return 0;
    }
    return 1;
}

static int compare_values(Runtime *runtime, Value *left, Value *right, uint32_t depth, int *order) {
    uint32_t index;
    if (depth >= MITOS_MAX_VALUE_DEPTH) {
        fail(runtime, "structural comparison depth limit exceeded");
        return 0;
    }
    if (!valid_value(runtime, left) || !valid_value(runtime, right)) return 0;
    if (left->kind != right->kind) {
        *order = left->kind < right->kind ? -1 : 1;
        return 1;
    }
    if (left->kind == VALUE_INTEGER) {
        *order = left->integer < right->integer ? -1 : left->integer > right->integer ? 1 : 0;
        return 1;
    }
    if (left->kind == VALUE_TYPE) {
        *order = left->represented_type < right->represented_type ? -1
                 : left->represented_type > right->represented_type ? 1 : 0;
        return 1;
    }
    if (left->kind == VALUE_STRING) {
        size_t shared = left->string_length < right->string_length
            ? left->string_length : right->string_length;
        int compared = shared == 0 ? 0 : memcmp(left->string, right->string, shared);
        *order = compared < 0 ? -1 : compared > 0 ? 1
            : left->string_length < right->string_length ? -1
            : left->string_length > right->string_length ? 1 : 0;
        return 1;
    }
    if (left->kind == VALUE_FUNCTION) {
        *order = left == right ? 0 : (uintptr_t) left < (uintptr_t) right ? -1 : 1;
        return 1;
    }
    if (left->kind == VALUE_ARRAY) {
        if (left->arity != right->arity) {
            *order = left->arity < right->arity ? -1 : 1;
            return 1;
        }
        for (index = 0; index < left->arity; ++index) {
            if (!compare_values(runtime, left->fields[index], right->fields[index],
                                depth + 1, order))
                return 0;
            if (*order != 0) return 1;
        }
        *order = 0;
        return 1;
    }
    if (left->kind == VALUE_SUPERPOSITION) {
        if (left->arity != right->arity) {
            *order = left->arity < right->arity ? -1 : 1;
            return 1;
        }
        for (index = 0; index < left->arity; ++index) {
            Alternative *left_alt = &left->alternatives[index];
            Alternative *right_alt = &right->alternatives[index];
            uint32_t assignment;
            if (left_alt->assignment_count != right_alt->assignment_count) {
                *order = left_alt->assignment_count < right_alt->assignment_count ? -1 : 1;
                return 1;
            }
            for (assignment = 0; assignment < left_alt->assignment_count; ++assignment) {
                OriginAssignment *l = &left_alt->assignments[assignment];
                OriginAssignment *r = &right_alt->assignments[assignment];
                if (l->origin != r->origin || l->branch != r->branch) {
                    *order = l->origin < r->origin ? -1 : l->origin > r->origin ? 1
                        : l->branch < r->branch ? -1 : 1;
                    return 1;
                }
            }
            if (!compare_values(runtime, left_alt->value, right_alt->value,
                                depth + 1, order))
                return 0;
            if (*order != 0) return 1;
        }
        *order = 0;
        return 1;
    }
    {
        uint32_t left_index = 0, right_index = 0;
        const MitosMirConstructor *left_descriptor =
            constructor_by_tag(runtime, left->tag, &left_index);
        const MitosMirConstructor *right_descriptor =
            constructor_by_tag(runtime, right->tag, &right_index);
        if (left_descriptor == NULL || right_descriptor == NULL) {
            fail(runtime, "structural comparison encountered an unknown constructor tag");
            return 0;
        }
        if (left_index != right_index) {
            *order = left_index < right_index ? -1 : 1;
            return 1;
        }
        if (left->arity != right->arity || left->arity != left_descriptor->arity) {
            fail(runtime, "structural comparison encountered invalid constructor arity");
            return 0;
        }
    }
    for (index = 0; index < left->arity; ++index) {
        if (!compare_values(runtime, left->fields[index], right->fields[index], depth + 1, order))
            return 0;
        if (*order != 0) return 1;
    }
    *order = 0;
    return 1;
}
typedef struct AlternativeBuffer {
    Alternative *data;
    uint32_t count;
    uint32_t capacity;
} AlternativeBuffer;

typedef Value *(*LiftCallback)(Runtime *, Value **, uint32_t, void *);

static int alternative_buffer_push(Runtime *runtime, AlternativeBuffer *buffer,
                                   Alternative alternative) {
    Alternative *grown;
    uint32_t capacity;
    if (buffer->count >= MITOS_MAX_ALTERNATIVES) {
        fail(runtime, "lifted execution exceeds the alternative-count limit");
        return 0;
    }
    if (buffer->count == buffer->capacity) {
        capacity = buffer->capacity == 0 ? 8u : buffer->capacity * 2u;
        if (capacity > MITOS_MAX_ALTERNATIVES) capacity = MITOS_MAX_ALTERNATIVES;
        grown = (Alternative *) realloc(buffer->data,
                                       (size_t) capacity * sizeof(*grown));
        if (grown == NULL) {
            fail(runtime, "out of memory while combining superposition alternatives");
            return 0;
        }
        buffer->data = grown;
        buffer->capacity = capacity;
    }
    alternative.reserved = buffer->count;
    buffer->data[buffer->count++] = alternative;
    return 1;
}

static int append_lift_result(Runtime *runtime, AlternativeBuffer *buffer,
                              Value *result, const OriginAssignment *assignments,
                              uint32_t assignment_count) {
    uint32_t index;
    if (!valid_value(runtime, result)) return 0;
    if (result->kind == VALUE_SUPERPOSITION) {
        for (index = 0; index < result->arity; ++index) {
            Alternative *nested = &result->alternatives[index];
            OriginAssignment *merged = NULL;
            uint32_t merged_count = 0;
            int compatible = merge_assignments(
                runtime, assignments, assignment_count,
                nested->assignments, nested->assignment_count,
                &merged, &merged_count);
            if (compatible < 0) return 0;
            if (compatible == 0) continue;
            if (!alternative_buffer_push(runtime, buffer, (Alternative) {
                    nested->value, merged, merged_count, 0
                }))
                return 0;
        }
        return 1;
    }
    {
        OriginAssignment *copied = NULL;
        uint32_t copied_count = 0;
        int compatible = merge_assignments(runtime, assignments, assignment_count,
                                           NULL, 0, &copied, &copied_count);
        if (compatible <= 0) return compatible == 0;
        return alternative_buffer_push(runtime, buffer, (Alternative) {
            result, copied, copied_count, 0
        });
    }
}

typedef struct LiftState {
    Runtime *runtime;
    Value **inputs;
    Value **selected;
    uint32_t input_count;
    LiftCallback callback;
    void *context;
    AlternativeBuffer output;
} LiftState;

static int lift_walk(LiftState *state, uint32_t input,
                     const OriginAssignment *assignments,
                     uint32_t assignment_count) {
    Value *value;
    uint32_t alternative;
    if (input == state->input_count) {
        Value *result = state->callback(
            state->runtime, state->selected, state->input_count, state->context);
        if (result == NULL) return 0;
        return append_lift_result(state->runtime, &state->output, result,
                                  assignments, assignment_count);
    }
    value = state->inputs[input];
    if (!valid_value(state->runtime, value)) return 0;
    if (value->kind != VALUE_SUPERPOSITION) {
        state->selected[input] = value;
        return lift_walk(state, input + 1, assignments, assignment_count);
    }
    for (alternative = 0; alternative < value->arity; ++alternative) {
        Alternative *candidate = &value->alternatives[alternative];
        OriginAssignment *merged = NULL;
        uint32_t merged_count = 0;
        int compatible = merge_assignments(
            state->runtime, assignments, assignment_count,
            candidate->assignments, candidate->assignment_count,
            &merged, &merged_count);
        if (compatible < 0) return 0;
        if (compatible == 0) continue;
        state->selected[input] = candidate->value;
        if (!lift_walk(state, input + 1, merged, merged_count)) return 0;
    }
    return 1;
}

static Value *lift_values(Runtime *runtime, Value **inputs, uint32_t input_count,
                          uint32_t result_superposition_type,
                          LiftCallback callback, void *context) {
    LiftState state;
    Value **selected;
    uint32_t index;
    int lifted = 0;
    if (input_count > MITOS_MAX_ARITY || callback == NULL) {
        fail(runtime, "lifted operation arity is out of range");
        return NULL;
    }
    for (index = 0; index < input_count; ++index) {
        if (!valid_value(runtime, inputs[index])) return NULL;
        if (inputs[index]->kind == VALUE_SUPERPOSITION) lifted = 1;
    }
    if (!lifted) return callback(runtime, inputs, input_count, context);
    selected = input_count == 0 ? NULL : (Value **) runtime_allocate(
        runtime, (size_t) input_count * sizeof(*selected));
    if (input_count != 0 && selected == NULL) return NULL;
    memset(&state, 0, sizeof(state));
    state.runtime = runtime;
    state.inputs = inputs;
    state.selected = selected;
    state.input_count = input_count;
    state.callback = callback;
    state.context = context;
    if (!lift_walk(&state, 0, NULL, 0)) {
        free(state.output.data);
        return NULL;
    }
    if (state.output.count == 0) {
        free(state.output.data);
        fail(runtime, "lifted operation has no compatible branch assignments");
        return NULL;
    }
    {
        Value *result = new_superposition(runtime, state.output.data,
                                          state.output.count,
                                          result_superposition_type);
        free(state.output.data);
        return result;
    }
}

static int64_t rt_superpose(int64_t raw_arguments, int64_t count,
                            int64_t origin_raw, int64_t runtime_type_raw) {
    Value **arguments = (Value **) (intptr_t) raw_arguments;
    AlternativeBuffer output = {0};
    uint64_t origin = (uint64_t) origin_raw;
    uint32_t branch;
    if (count <= 0 || (uint64_t) count > MITOS_MAX_ALTERNATIVES
        || origin == 0 || runtime_type_raw <= 0
        || (uint64_t) runtime_type_raw > UINT32_MAX
        || arguments == NULL) {
        fail(active_runtime, "superpose MIR metadata is invalid");
        return 0;
    }
    for (branch = 0; branch < (uint32_t) count; ++branch) {
        OriginAssignment assignment = {origin, branch, 0};
        if (!append_lift_result(active_runtime, &output, arguments[branch],
                                &assignment, 1)) {
            free(output.data);
            return 0;
        }
    }
    if (output.count == 0) {
        free(output.data);
        fail(active_runtime, "superpose has no compatible flattened alternatives");
        return 0;
    }
    {
        Value *result = new_superposition(active_runtime, output.data, output.count,
                                          (uint32_t) runtime_type_raw);
        free(output.data);
        return from_value(result);
    }
}

static int64_t rt_collapse(int64_t raw_value, int64_t runtime_type_raw,
                           int64_t element_type_raw, int64_t unused) {
    Value *value = as_value(raw_value);
    Value **elements;
    uint32_t index;
    (void) unused;
    if (!valid_value(active_runtime, value)) return 0;
    if (value->kind != VALUE_SUPERPOSITION || runtime_type_raw <= 0
        || (uint64_t) runtime_type_raw > UINT32_MAX || element_type_raw <= 0
        || (uint64_t) element_type_raw > UINT32_MAX) {
        fail(active_runtime, "collapse strictly requires a Superposition value");
        return 0;
    }
    if ((uint32_t) element_type_raw == 1u)
        element_type_raw = (int64_t) value->represented_type;
    if ((uint32_t) runtime_type_raw <= active_runtime->program->type_count
        && active_runtime->program->types[(uint32_t) runtime_type_raw - 1].constructor == 8u
        && active_runtime->program->types[(uint32_t) runtime_type_raw - 1].argument == 1u)
        runtime_type_raw = (int64_t) unary_runtime_type(
            active_runtime, 8u, (uint32_t) element_type_raw);
    elements = (Value **) runtime_allocate(
        active_runtime, (size_t) value->arity * sizeof(*elements));
    if (elements == NULL) return 0;
    for (index = 0; index < value->arity; ++index)
        elements[index] = value->alternatives[index].value;
    return from_value(new_array(active_runtime, elements, value->arity,
                                (uint32_t) runtime_type_raw,
                                (uint32_t) element_type_raw));
}


static int64_t boolean_value(Runtime *runtime, int truth) {
    return from_value(new_constructor(runtime,
                                      truth ? runtime->program->true_tag
                                            : runtime->program->false_tag,
                                      0, runtime->program->bool_type));
}

static int64_t rt_const(int64_t value, int64_t unused1, int64_t unused2, int64_t unused3) {
    (void) unused1; (void) unused2; (void) unused3;
    return from_value(new_integer(active_runtime, value));
}

typedef enum BinaryLiftOp {
    BINARY_LIFT_ADD,
    BINARY_LIFT_SUBTRACT,
    BINARY_LIFT_MULTIPLY,
    BINARY_LIFT_DIVIDE,
    BINARY_LIFT_REMAINDER,
    BINARY_LIFT_EQUAL,
    BINARY_LIFT_LESS,
    BINARY_LIFT_LESS_EQUAL,
    BINARY_LIFT_GREATER,
    BINARY_LIFT_GREATER_EQUAL
} BinaryLiftOp;

static Value *binary_lift_callback(Runtime *runtime, Value **arguments,
                                   uint32_t count, void *raw_operation) {
    BinaryLiftOp operation = *(BinaryLiftOp *) raw_operation;
    Value *left, *right;
    int order = 0;
    if (count != 2) {
        fail(runtime, "lifted binary primitive has invalid arity");
        return NULL;
    }
    left = arguments[0];
    right = arguments[1];
    if (operation <= BINARY_LIFT_REMAINDER) {
        if (left->kind != VALUE_INTEGER || right->kind != VALUE_INTEGER) {
            fail(runtime, "integer operation requires two boxed integers");
            return NULL;
        }
        switch (operation) {
            case BINARY_LIFT_ADD:
                return new_integer(runtime, (int64_t) (
                    (uint64_t) left->integer + (uint64_t) right->integer));
            case BINARY_LIFT_SUBTRACT:
                return new_integer(runtime, (int64_t) (
                    (uint64_t) left->integer - (uint64_t) right->integer));
            case BINARY_LIFT_MULTIPLY:
                return new_integer(runtime, (int64_t) (
                    (uint64_t) left->integer * (uint64_t) right->integer));
            case BINARY_LIFT_DIVIDE:
                if (right->integer == 0) {
                    fail(runtime, "division by zero");
                    return NULL;
                }
                if (left->integer == INT64_MIN && right->integer == -1) {
                    fail(runtime, "signed division overflow");
                    return NULL;
                }
                return new_integer(runtime, left->integer / right->integer);
            default:
                if (right->integer == 0) {
                    fail(runtime, "remainder by zero");
                    return NULL;
                }
                if (left->integer == INT64_MIN && right->integer == -1) {
                    fail(runtime, "signed remainder overflow");
                    return NULL;
                }
                return new_integer(runtime, left->integer % right->integer);
        }
    }
    if (!compare_values(runtime, left, right, 0, &order)) return NULL;
    switch (operation) {
        case BINARY_LIFT_EQUAL:
            return as_value(boolean_value(runtime, order == 0));
        case BINARY_LIFT_LESS:
            return as_value(boolean_value(runtime, order < 0));
        case BINARY_LIFT_LESS_EQUAL:
            return as_value(boolean_value(runtime, order <= 0));
        case BINARY_LIFT_GREATER:
            return as_value(boolean_value(runtime, order > 0));
        default:
            return as_value(boolean_value(runtime, order >= 0));
    }
}

static int64_t rt_binary_lift(int64_t a, int64_t b, int64_t result_type,
                              BinaryLiftOp operation) {
    Value *arguments[2] = {as_value(a), as_value(b)};
    uint32_t lifted_type = result_type > 0 && (uint64_t) result_type <= UINT32_MAX
        ? (uint32_t) result_type : 0;
    return from_value(lift_values(active_runtime, arguments, 2, lifted_type,
                                  binary_lift_callback, &operation));
}

static int64_t rt_add(int64_t a, int64_t b, int64_t result_type, int64_t unused) {
    (void) unused; return rt_binary_lift(a, b, result_type, BINARY_LIFT_ADD);
}
static int64_t rt_subtract(int64_t a, int64_t b, int64_t result_type, int64_t unused) {
    (void) unused; return rt_binary_lift(a, b, result_type, BINARY_LIFT_SUBTRACT);
}
static int64_t rt_multiply(int64_t a, int64_t b, int64_t result_type, int64_t unused) {
    (void) unused; return rt_binary_lift(a, b, result_type, BINARY_LIFT_MULTIPLY);
}
static int64_t rt_divide(int64_t a, int64_t b, int64_t result_type, int64_t unused) {
    (void) unused; return rt_binary_lift(a, b, result_type, BINARY_LIFT_DIVIDE);
}
static int64_t rt_remainder(int64_t a, int64_t b, int64_t result_type, int64_t unused) {
    (void) unused; return rt_binary_lift(a, b, result_type, BINARY_LIFT_REMAINDER);
}
static int64_t rt_equal(int64_t a, int64_t b, int64_t result_type, int64_t unused) {
    (void) unused; return rt_binary_lift(a, b, result_type, BINARY_LIFT_EQUAL);
}
static int64_t rt_less(int64_t a, int64_t b, int64_t result_type, int64_t unused) {
    (void) unused; return rt_binary_lift(a, b, result_type, BINARY_LIFT_LESS);
}
static int64_t rt_less_equal(int64_t a, int64_t b, int64_t result_type, int64_t unused) {
    (void) unused; return rt_binary_lift(a, b, result_type, BINARY_LIFT_LESS_EQUAL);
}
static int64_t rt_greater(int64_t a, int64_t b, int64_t result_type, int64_t unused) {
    (void) unused; return rt_binary_lift(a, b, result_type, BINARY_LIFT_GREATER);
}
static int64_t rt_greater_equal(int64_t a, int64_t b, int64_t result_type, int64_t unused) {
    (void) unused; return rt_binary_lift(a, b, result_type, BINARY_LIFT_GREATER_EQUAL);
}

static int64_t rt_make_constructor(int64_t tag, int64_t arity,
                                   int64_t runtime_type, int64_t unused) {
    (void) unused;
    if (tag < 0 || (uint64_t) tag > UINT32_MAX || arity < 0
        || (uint64_t) arity > UINT32_MAX || runtime_type <= 0
        || (uint64_t) runtime_type > UINT32_MAX) {
        fail(active_runtime, "native constructor metadata is out of range");
        return 0;
    }
    return from_value(new_constructor(active_runtime, (uint32_t) tag, (uint32_t) arity,
                                      (uint32_t) runtime_type));
}

static int64_t rt_set_field(int64_t raw, int64_t index, int64_t field_raw, int64_t unused) {
    Value *value = as_value(raw), *field = as_value(field_raw); (void) unused;
    if (!valid_value(active_runtime, field)) return 0;
    if (value == NULL || value->kind != VALUE_CONSTRUCTOR) {
        fail(active_runtime, "constructor field initialization requires a constructor");
        return 0;
    }
    if (index < 0 || (uint64_t) index >= value->arity || (uint32_t) index != value->initialized) {
        fail(active_runtime, "constructor fields must be initialized once in source order");
        return 0;
    }
    value->fields[index] = field;
    value->initialized++;
    return raw;
}
typedef struct ConstructorLiftContext {
    uint32_t tag;
    uint32_t runtime_type;
} ConstructorLiftContext;

static Value *constructor_lift_callback(Runtime *runtime, Value **fields,
                                        uint32_t count, void *raw_context) {
    ConstructorLiftContext *context = (ConstructorLiftContext *) raw_context;
    Value *value = new_constructor(runtime, context->tag, count,
                                   context->runtime_type);
    uint32_t index;
    if (value == NULL) return NULL;
    for (index = 0; index < count; ++index) {
        value->fields[index] = fields[index];
        value->initialized++;
    }
    return value;
}

static int64_t rt_lift_constructor(int64_t tag_raw, int64_t runtime_type_raw,
                                   int64_t raw_fields, int64_t count_raw) {
    ConstructorLiftContext context;
    Value **fields = (Value **) (intptr_t) raw_fields;
    uint32_t index, lifted_type = 0;
    if (tag_raw < 0 || (uint64_t) tag_raw > UINT32_MAX
        || runtime_type_raw <= 0 || (uint64_t) runtime_type_raw > UINT32_MAX
        || count_raw < 0 || (uint64_t) count_raw > MITOS_MAX_ARITY
        || (count_raw != 0 && fields == NULL)) {
        fail(active_runtime, "lifted constructor metadata is invalid");
        return 0;
    }
    context.tag = (uint32_t) tag_raw;
    context.runtime_type = (uint32_t) runtime_type_raw;
    for (index = 0; index < (uint32_t) count_raw; ++index)
        if (fields[index] != NULL && fields[index]->kind == VALUE_SUPERPOSITION) {
            lifted_type = unary_runtime_type(active_runtime, 10u, context.runtime_type);
            break;
        }
    return from_value(lift_values(active_runtime, fields, (uint32_t) count_raw,
                                  lifted_type, constructor_lift_callback, &context));
}


static int64_t rt_tag_equal(int64_t raw, int64_t tag, int64_t u1, int64_t u2) {
    Value *value = as_value(raw); (void) u1; (void) u2;
    if (!valid_value(active_runtime, value)) return 0;
    if (value->kind != VALUE_CONSTRUCTOR) {
        fail(active_runtime, "constructor tag test requires a constructor value");
        return 0;
    }
    return boolean_value(active_runtime, tag >= 0 && (uint64_t) tag <= UINT32_MAX
                                             && value->tag == (uint32_t) tag);
}

static int64_t rt_get_field(int64_t raw, int64_t index, int64_t u1, int64_t u2) {
    Value *value = as_value(raw); (void) u1; (void) u2;
    if (!valid_value(active_runtime, value)) return 0;
    if (value->kind != VALUE_CONSTRUCTOR || index < 0 || (uint64_t) index >= value->arity) {
        fail(active_runtime, "constructor field index is out of range");
        return 0;
    }
    return from_value(value->fields[index]);
}

static const MitosMirType *type_by_id(const Runtime *runtime, uint32_t id) {
    uint32_t index;
    for (index = 0; index < runtime->program->type_count; ++index)
        if (runtime->program->types[index].id == id) return &runtime->program->types[index];
    return NULL;
}

static int runtime_subtype(const Runtime *runtime, uint32_t actual, uint32_t expected) {
    uint32_t depth = 0;
    if (expected == 1u) return 1; /* TypeId 1 is the stable Any bootstrap identity. */
    while (actual != 0 && depth++ < runtime->program->type_count) {
        const MitosMirType *descriptor;
        if (actual == expected) return 1;
        descriptor = type_by_id(runtime, actual);
        if (descriptor == NULL) return 0;
        actual = descriptor->parent;
    }
    return 0;
}

static int64_t rt_type_value(int64_t type_id, int64_t u1, int64_t u2, int64_t u3) {
    (void) u1; (void) u2; (void) u3;
    if (type_id <= 0 || (uint64_t) type_id > UINT32_MAX
        || type_by_id(active_runtime, (uint32_t) type_id) == NULL) {
        fail(active_runtime, "native Type value references an unknown TypeId");
        return 0;
    }
    return from_value(new_type_value(active_runtime, (uint32_t) type_id));
}

static int64_t rt_type_of(int64_t raw, int64_t u1, int64_t u2, int64_t u3) {
    Value *value = as_value(raw); (void) u1; (void) u2; (void) u3;
    if (!valid_value(active_runtime, value)) return 0;
    return from_value(new_type_value(active_runtime, value->type_id));
}

static Value *type_assert_concrete(Runtime *runtime, Value *value,
                                   uint32_t expected) {
    if (!valid_value(runtime, value)) return NULL;
    if (!runtime_subtype(runtime, value->type_id, expected)) {
        const MitosMirType *actual_type = type_by_id(runtime, value->type_id);
        const MitosMirType *expected_type = type_by_id(runtime, expected);
        fail(runtime, "TypeError: value of type %.*s does not satisfy %.*s",
             actual_type == NULL ? 9 : (int) actual_type->name_length,
             actual_type == NULL ? "<invalid>" : actual_type->name,
             expected_type == NULL ? 9 : (int) expected_type->name_length,
             expected_type == NULL ? "<invalid>" : expected_type->name);
        return NULL;
    }
    return value;
}

static Value *type_assert_lift_callback(Runtime *runtime, Value **arguments,
                                        uint32_t count, void *raw_expected) {
    if (count != 1) {
        fail(runtime, "lifted type assertion has invalid arity");
        return NULL;
    }
    return type_assert_concrete(runtime, arguments[0], *(uint32_t *) raw_expected);
}

static int64_t rt_type_assert(int64_t raw, int64_t expected_raw,
                              int64_t result_type_raw, int64_t unused) {
    Value *arguments[1] = {as_value(raw)};
    uint32_t expected, result_type;
    (void) unused;
    if (expected_raw <= 0 || (uint64_t) expected_raw > UINT32_MAX) {
        fail(active_runtime, "TypeError: assertion references an invalid TypeId");
        return 0;
    }
    expected = (uint32_t) expected_raw;
    result_type = result_type_raw > 0 && (uint64_t) result_type_raw <= UINT32_MAX
        ? (uint32_t) result_type_raw : 0;
    return from_value(lift_values(active_runtime, arguments, 1, result_type,
                                  type_assert_lift_callback, &expected));
}

static int64_t rt_string(int64_t string_index, int64_t u1, int64_t u2, int64_t u3) {
    const MitosMirString *literal;
    (void) u1; (void) u2; (void) u3;
    if (string_index < 0 || (uint64_t) string_index >= active_runtime->program->string_count) {
        fail(active_runtime, "native String literal index is out of range");
        return 0;
    }
    literal = &active_runtime->program->strings[string_index];
    return from_value(new_string(active_runtime, literal->bytes, literal->length,
                                 literal->runtime_type));
}

static int64_t rt_args_new(int64_t count, int64_t u1, int64_t u2, int64_t u3) {
    (void) u1; (void) u2; (void) u3;
    if (count < 0 || (uint64_t) count > MITOS_MAX_ARITY
        || (uint64_t) count > SIZE_MAX / sizeof(Value *)) {
        fail(active_runtime, "native cached-call argument count is out of range");
        return 0;
    }
    return (int64_t) (intptr_t) runtime_allocate(
        active_runtime, (size_t) count * sizeof(Value *));
}

static int64_t rt_args_set(int64_t raw_arguments, int64_t index,
                           int64_t raw_value, int64_t count) {
    Value **arguments = (Value **) (intptr_t) raw_arguments;
    Value *value = as_value(raw_value);
    if (arguments == NULL || index < 0 || count < 0 || index >= count
        || !valid_value(active_runtime, value)) {
        fail(active_runtime, "native cached-call argument initialization is invalid");
        return 0;
    }
    arguments[index] = value;
    return raw_arguments;
}

typedef struct NativeCallContext {
    NativeWrapper wrapper;
    uint32_t arity;
} NativeCallContext;

static Value *native_call_callback(Runtime *runtime, Value **arguments,
                                   uint32_t count, void *raw_context) {
    NativeCallContext *context = (NativeCallContext *) raw_context;
    (void) runtime;
    if (count != context->arity) {
        fail(runtime, "lifted native call arity is invalid");
        return NULL;
    }
    return as_value(context->wrapper((int64_t *) arguments, count));
}

static int64_t rt_cached_call(int64_t raw_method, int64_t raw_arguments,
                              int64_t count, int64_t result_type_raw) {
    NativeMethod *method = (NativeMethod *) (intptr_t) raw_method;
    Value **arguments = (Value **) (intptr_t) raw_arguments;
    NativeCallContext context;
    uint32_t result_type = result_type_raw > 0
        && (uint64_t) result_type_raw <= UINT32_MAX ? (uint32_t) result_type_raw : 0;
    if (method == NULL || method->wrapper == NULL || count < 0
        || (uint64_t) count != method->arity || (count != 0 && arguments == NULL)) {
        fail(active_runtime, "native specialization handle or arity is invalid");
        return 0;
    }
    context.wrapper = method->wrapper;
    context.arity = method->arity;
    return from_value(lift_values(active_runtime, arguments, (uint32_t) count,
                                  result_type, native_call_callback, &context));
}

static int64_t rt_lift_call(int64_t function_index, int64_t raw_arguments,
                            int64_t count, int64_t result_type_raw) {
    NativeCallContext context;
    Value **arguments = (Value **) (intptr_t) raw_arguments;
    uint32_t result_type = result_type_raw > 0
        && (uint64_t) result_type_raw <= UINT32_MAX ? (uint32_t) result_type_raw : 0;
    if (function_index < 0
        || (uint64_t) function_index >= active_runtime->program->function_count
        || count < 0 || (uint64_t) count > MITOS_MAX_ARITY
        || (uint32_t) count
            != active_runtime->program->functions[function_index].parameter_count
        || active_runtime->function_wrappers == NULL
        || active_runtime->function_wrappers[function_index] == NULL
        || (count != 0 && arguments == NULL)) {
        fail(active_runtime, "lifted MIR call metadata is invalid");
        return 0;
    }
    context.wrapper = (NativeWrapper) active_runtime->function_wrappers[function_index];
    context.arity = (uint32_t) count;
    return from_value(lift_values(active_runtime, arguments, (uint32_t) count,
                                  result_type, native_call_callback, &context));
}

typedef struct ParallelJob {
    thrd_t thread;
    Runtime child;
    NativeWrapper wrapper;
    Value **arguments;
    uint32_t argument_count;
    Value *result;
    int started;
} ParallelJob;

static int parallel_job_main(void *raw_job) {
    ParallelJob *job = (ParallelJob *) raw_job;
    active_runtime = &job->child;
    job->result = as_value(job->wrapper(
        (int64_t *) job->arguments, job->argument_count));
    active_runtime = NULL;
    return job->child.diagnostic[0] == '\0' ? 0 : -1;
}

static int64_t rt_parallel_call(int64_t function_index, int64_t raw_arguments,
                                int64_t count, int64_t unused) {
    ParallelJob *job;
    Value *future;
    (void) unused;
    if (function_index < 0
        || (uint64_t) function_index >= active_runtime->program->function_count
        || count < 0 || (uint64_t) count > MITOS_MAX_ARITY
        || (uint32_t) count
            != active_runtime->program->functions[function_index].parameter_count
        || active_runtime->function_wrappers == NULL
        || active_runtime->function_wrappers[function_index] == NULL) {
        fail(active_runtime, "parallel MIR thunk metadata is invalid");
        return 0;
    }
    job = (ParallelJob *) calloc(1, sizeof(*job));
    if (job == NULL) {
        fail(active_runtime, "out of memory while materializing a parallel MIR root");
        return 0;
    }
    job->child.program = active_runtime->program;
    job->child.nullary_values = (Value **) calloc(
        active_runtime->program->constructor_count, sizeof(Value *));
    if (job->child.nullary_values == NULL) {
        free(job);
        fail(active_runtime, "out of memory while initializing a parallel MIR root");
        return 0;
    }
    job->wrapper = (NativeWrapper) active_runtime->function_wrappers[function_index];
    job->arguments = (Value **) (intptr_t) raw_arguments;
    job->argument_count = (uint32_t) count;
    future = (Value *) runtime_allocate(active_runtime, sizeof(*future));
    if (future == NULL) {
        runtime_free(&job->child);
        free(job);
        return 0;
    }
    future->kind = VALUE_FUTURE;
    future->type_id = 1u;
    future->function = job;
    if (thrd_create(&job->thread, parallel_job_main, job) != thrd_success) {
        runtime_free(&job->child);
        free(job);
        fail(active_runtime, "unable to start a parallel MIR worker");
        return 0;
    }
    job->started = 1;
    return from_value(future);
}

static int64_t rt_parallel_join(int64_t raw_future, int64_t u1,
                                int64_t u2, int64_t u3) {
    Value *future = as_value(raw_future);
    ParallelJob *job;
    Allocation *tail;
    int thread_result = 0;
    (void) u1; (void) u2; (void) u3;
    if (future == NULL || future->kind != VALUE_FUTURE || future->function == NULL) {
        fail(active_runtime, "parallel MIR join requires a live future");
        return 0;
    }
    job = (ParallelJob *) future->function;
    future->function = NULL;
    if (!job->started || thrd_join(job->thread, &thread_result) != thrd_success) {
        runtime_free(&job->child);
        free(job);
        fail(active_runtime, "parallel MIR worker could not be joined");
        return 0;
    }
    if (thread_result != 0 || job->child.diagnostic[0] != '\0'
        || job->child.call_depth != 0 || job->result == NULL) {
        fail(active_runtime, "%s", job->child.diagnostic[0] != '\0'
             ? job->child.diagnostic : "parallel MIR worker failed");
        runtime_free(&job->child);
        free(job);
        return 0;
    }
    if (job->child.allocation_bytes > MITOS_MAX_ALLOCATION_BYTES
            - active_runtime->allocation_bytes
        || job->child.allocation_count > MITOS_MAX_ALLOCATIONS
            - active_runtime->allocation_count) {
        runtime_free(&job->child);
        free(job);
        fail(active_runtime, "parallel MIR results exceed the cumulative allocation budget");
        return 0;
    }
    tail = job->child.allocations;
    if (tail != NULL) {
        while (tail->next != NULL) tail = tail->next;
        tail->next = active_runtime->allocations;
        active_runtime->allocations = job->child.allocations;
    }
    active_runtime->allocation_bytes += job->child.allocation_bytes;
    active_runtime->allocation_count += job->child.allocation_count;
    free(job->child.nullary_values);
    {
        Value *result = job->result;
        free(job);
        return from_value(result);
    }
}

typedef struct NativeClosure {
    uint32_t function_index;
    uint32_t parameter_count;
    uint32_t capture_count;
    Value **captures;
} NativeClosure;

typedef struct ClosureLiftContext {
    uint32_t function_index;
    uint32_t parameter_count;
    uint32_t runtime_type;
} ClosureLiftContext;

static Value *make_function_concrete(Runtime *runtime, uint32_t function_index,
                                     Value **captures, uint32_t capture_count,
                                     uint32_t parameter_count,
                                     uint32_t runtime_type) {
    NativeClosure *closure;
    Value *value;
    Value **owned_captures = NULL;
    if (function_index >= runtime->program->function_count
        || capture_count > MITOS_MAX_ARITY || parameter_count > MITOS_MAX_ARITY
        || runtime->program->functions[function_index].parameter_count
            != parameter_count + capture_count) {
        fail(runtime, "native Function closure metadata is invalid");
        return NULL;
    }
    closure = (NativeClosure *) runtime_allocate(runtime, sizeof(*closure));
    value = (Value *) runtime_allocate(runtime, sizeof(*value));
    if (capture_count != 0)
        owned_captures = (Value **) runtime_allocate(
            runtime, (size_t) capture_count * sizeof(*owned_captures));
    if (closure == NULL || value == NULL
        || (capture_count != 0 && owned_captures == NULL)) return NULL;
    if (capture_count != 0)
        memcpy(owned_captures, captures, (size_t) capture_count * sizeof(*owned_captures));
    closure->function_index = function_index;
    closure->parameter_count = parameter_count;
    closure->capture_count = capture_count;
    closure->captures = owned_captures;
    value->kind = VALUE_FUNCTION;
    value->type_id = runtime_type;
    value->function = closure;
    return value;
}

static Value *closure_lift_callback(Runtime *runtime, Value **captures,
                                    uint32_t count, void *raw_context) {
    ClosureLiftContext *context = (ClosureLiftContext *) raw_context;
    return make_function_concrete(runtime, context->function_index, captures, count,
                                  context->parameter_count, context->runtime_type);
}

static int64_t rt_make_function(int64_t function_index, int64_t raw_captures,
                                int64_t capture_count, int64_t packed_raw) {
    uint64_t packed = (uint64_t) packed_raw;
    if (function_index < 0 || (uint64_t) function_index > UINT32_MAX
        || capture_count < 0 || (uint64_t) capture_count > UINT32_MAX)
        return 0;
    return from_value(make_function_concrete(
        active_runtime, (uint32_t) function_index,
        (Value **) (intptr_t) raw_captures, (uint32_t) capture_count,
        (uint32_t) (packed >> 32), (uint32_t) packed));
}

static int64_t rt_lift_make_function(int64_t function_index, int64_t raw_captures,
                                     int64_t packed_raw, int64_t result_type_raw) {
    uint64_t packed = (uint64_t) packed_raw;
    ClosureLiftContext context;
    uint32_t function_parameters, capture_count, result_type;
    Value **captures = (Value **) (intptr_t) raw_captures;
    if (function_index < 0
        || (uint64_t) function_index >= active_runtime->program->function_count
        || (uint32_t) (packed >> 32) > MITOS_MAX_ARITY) {
        fail(active_runtime, "lifted Function closure metadata is invalid");
        return 0;
    }
    function_parameters =
        active_runtime->program->functions[function_index].parameter_count;
    if (function_parameters < (uint32_t) (packed >> 32)) {
        fail(active_runtime, "lifted Function closure parameter count is invalid");
        return 0;
    }
    capture_count = function_parameters - (uint32_t) (packed >> 32);
    if (capture_count != 0 && captures == NULL) {
        fail(active_runtime, "lifted Function closure captures are absent");
        return 0;
    }
    context.function_index = (uint32_t) function_index;
    context.parameter_count = (uint32_t) (packed >> 32);
    context.runtime_type = (uint32_t) packed;
    result_type = result_type_raw > 0 && (uint64_t) result_type_raw <= UINT32_MAX
        ? (uint32_t) result_type_raw
        : unary_runtime_type(active_runtime, 10u, context.runtime_type);
    return from_value(lift_values(active_runtime, captures, capture_count,
                                  result_type, closure_lift_callback, &context));
}

static Value *apply_function_concrete(Runtime *runtime, Value *function,
                                      Value **arguments, uint32_t argument_count) {
    NativeClosure *closure;
    Value **combined;
    uint32_t index;
    if (!valid_value(runtime, function) || function->kind != VALUE_FUNCTION
        || function->function == NULL) {
        fail(runtime, "function application requires a concrete Function value");
        return NULL;
    }
    closure = (NativeClosure *) function->function;
    if (argument_count != closure->parameter_count
        || runtime->function_wrappers == NULL
        || runtime->function_wrappers[closure->function_index] == NULL) {
        fail(runtime, "Function application arity or native target is invalid");
        return NULL;
    }
    combined = (Value **) runtime_allocate(
        runtime, (size_t) (closure->parameter_count + closure->capture_count)
            * sizeof(*combined));
    if (combined == NULL) return NULL;
    for (index = 0; index < closure->parameter_count; ++index)
        combined[index] = arguments[index];
    for (index = 0; index < closure->capture_count; ++index)
        combined[closure->parameter_count + index] = closure->captures[index];
    return as_value(((NativeWrapper) runtime->function_wrappers[closure->function_index])(
        (int64_t *) combined, closure->parameter_count + closure->capture_count));
}

static Value *apply_lift_callback(Runtime *runtime, Value **inputs,
                                  uint32_t count, void *unused) {
    (void) unused;
    if (count == 0) {
        fail(runtime, "lifted Function application has no callee");
        return NULL;
    }
    return apply_function_concrete(runtime, inputs[0], inputs + 1, count - 1);
}

static int64_t rt_apply_function(int64_t raw_function, int64_t raw_arguments,
                                 int64_t argument_count, int64_t result_type_raw) {
    Value **arguments = (Value **) (intptr_t) raw_arguments;
    Value **inputs;
    uint32_t index;
    uint32_t result_type = result_type_raw > 0
        && (uint64_t) result_type_raw <= UINT32_MAX ? (uint32_t) result_type_raw : 0;
    if (argument_count < 0 || (uint64_t) argument_count > MITOS_MAX_ARITY
        || (argument_count != 0 && arguments == NULL)) {
        fail(active_runtime, "Function application argument metadata is invalid");
        return 0;
    }
    inputs = (Value **) runtime_allocate(
        active_runtime, ((size_t) argument_count + 1) * sizeof(*inputs));
    if (inputs == NULL) return 0;
    inputs[0] = as_value(raw_function);
    for (index = 0; index < (uint32_t) argument_count; ++index)
        inputs[index + 1] = arguments[index];
    return from_value(lift_values(
        active_runtime, inputs, (uint32_t) argument_count + 1, result_type,
        apply_lift_callback, NULL));
}
static int select_match_arm(Runtime *runtime, Value *scrutinee,
                            uint32_t arm_start, uint32_t arm_count,
                            uint32_t *selected) {
    uint32_t arm;
    if (!valid_value(runtime, scrutinee) || scrutinee->kind != VALUE_CONSTRUCTOR) {
        fail(runtime, "match control flow requires a concrete constructor branch");
        return 0;
    }
    for (arm = 0; arm < arm_count; ++arm) {
        const MitosMirMatchArm *descriptor =
            &runtime->program->match_arms[arm_start + arm];
        if ((descriptor->flags & 1u) != 0) {
            *selected = arm;
            return 1;
        }
        if (descriptor->constructor >= runtime->program->constructor_count) {
            fail(runtime, "match arm references an invalid constructor descriptor");
            return 0;
        }
        if (runtime->program->constructors[descriptor->constructor].tag
            == scrutinee->tag) {
            *selected = arm;
            return 1;
        }
    }
    fail(runtime, "match has no branch for constructor tag %u", scrutinee->tag);
    return 0;
}

static Value *apply_match_closure(Runtime *runtime, Value *closure,
                                  Value *scrutinee) {
    NativeClosure *native;
    if (!valid_value(runtime, closure) || closure->kind != VALUE_FUNCTION
        || closure->function == NULL) {
        fail(runtime, "match arm requires a concrete Function closure");
        return NULL;
    }
    native = (NativeClosure *) closure->function;
    if (native->parameter_count != 0
        && native->parameter_count != scrutinee->arity) {
        fail(runtime, "match arm binding count disagrees with constructor arity");
        return NULL;
    }
    return apply_function_concrete(runtime, closure, scrutinee->fields,
                                   native->parameter_count);
}

static int append_match_result(Runtime *runtime, AlternativeBuffer *output,
                               Value *scrutinee, Value *closure,
                               const OriginAssignment *assignments,
                               uint32_t assignment_count) {
    uint32_t closure_alt;
    if (!valid_value(runtime, closure)) return 0;
    if (closure->kind == VALUE_SUPERPOSITION) {
        for (closure_alt = 0; closure_alt < closure->arity; ++closure_alt) {
            Alternative *candidate = &closure->alternatives[closure_alt];
            OriginAssignment *merged = NULL;
            uint32_t merged_count = 0;
            int compatible = merge_assignments(
                runtime, assignments, assignment_count,
                candidate->assignments, candidate->assignment_count,
                &merged, &merged_count);
            Value *result;
            if (compatible < 0) return 0;
            if (compatible == 0) continue;
            result = apply_match_closure(runtime, candidate->value, scrutinee);
            if (result == NULL
                || !append_lift_result(runtime, output, result, merged, merged_count))
                return 0;
        }
        return 1;
    }
    {
        Value *result = apply_match_closure(runtime, closure, scrutinee);
        return result != NULL
            && append_lift_result(runtime, output, result,
                                  assignments, assignment_count);
    }
}

static int64_t rt_lift_match(int64_t raw_scrutinee, int64_t raw_closures,
                             int64_t arm_start_raw, int64_t packed_raw) {
    Value *scrutinee = as_value(raw_scrutinee);
    Value **closures = (Value **) (intptr_t) raw_closures;
    uint64_t packed = (uint64_t) packed_raw;
    uint32_t arm_count = (uint32_t) packed;
    uint32_t result_type = (uint32_t) (packed >> 32);
    uint32_t arm_start, alternative;
    AlternativeBuffer output = {0};
    int lifted;
    if (arm_start_raw < 0 || (uint64_t) arm_start_raw > UINT32_MAX
        || arm_count == 0 || arm_count > MITOS_MAX_ARITY
        || (uint32_t) arm_start_raw > active_runtime->program->match_arm_count
        || arm_count > active_runtime->program->match_arm_count
            - (uint32_t) arm_start_raw
        || closures == NULL || !valid_value(active_runtime, scrutinee)) {
        fail(active_runtime, "lifted match metadata is invalid");
        return 0;
    }
    arm_start = (uint32_t) arm_start_raw;
    lifted = scrutinee->kind == VALUE_SUPERPOSITION;
    if (!lifted) {
        uint32_t selected;
        Value *closure;
        if (!select_match_arm(active_runtime, scrutinee, arm_start, arm_count,
                              &selected))
            return 0;
        closure = closures[selected];
        if (!valid_value(active_runtime, closure)) return 0;
        if (closure->kind != VALUE_SUPERPOSITION)
            return from_value(apply_function_concrete(
                active_runtime, closure, scrutinee->fields, scrutinee->arity));
        lifted = 1;
        if (!append_match_result(active_runtime, &output, scrutinee, closure,
                                 NULL, 0)) {
            free(output.data);
            return 0;
        }
    } else {
        for (alternative = 0; alternative < scrutinee->arity; ++alternative) {
            Alternative *candidate = &scrutinee->alternatives[alternative];
            uint32_t selected;
            if (!select_match_arm(active_runtime, candidate->value,
                                  arm_start, arm_count, &selected)
                || !append_match_result(
                    active_runtime, &output, candidate->value, closures[selected],
                    candidate->assignments, candidate->assignment_count)) {
                free(output.data);
                return 0;
            }
        }
    }
    if (!lifted || output.count == 0) {
        free(output.data);
        fail(active_runtime, "lifted match has no compatible result alternatives");
        return 0;
    }
    {
        Value *result = new_superposition(active_runtime, output.data,
                                          output.count, result_type);
        free(output.data);
        return from_value(result);
    }
}

static int standard_console_handler(MitosMirHostCall *call, void *context) {
    (void) context;
    if (call == NULL || call->argument_count != 1
        || call->arguments[0].kind != MITOS_HOST_STRING) {
        return 0;
    }
    if (fwrite(call->arguments[0].string, 1,
               call->arguments[0].string_length, stdout)
            != call->arguments[0].string_length
        || fputc('\n', stdout) == EOF) {
        return 0;
    }
    call->result.kind = MITOS_HOST_UNIT;
    call->result.type_id = 6u;
    return 1;
}

static int64_t rt_external_effect_concrete(int64_t operation, int64_t raw_arguments,
                                           int64_t count, int64_t packed_raw) {
    Value **arguments = (Value **) (intptr_t) raw_arguments;
    uint64_t packed = (uint64_t) packed_raw;
    uint32_t effect = (uint32_t) (packed >> 32);
    uint32_t expected = (uint32_t) packed;
    const MitosMirEffectOperation *descriptor = NULL;
    HostHelperEntry *helper = NULL;
    HostHelperEntry builtin_helper;
    MitosMirHostValue *views;
    MitosMirHostCall call;
    Value *result = NULL;
    size_t index;
    if (operation <= 0 || (uint64_t) operation > UINT32_MAX || count < 0
        || (uint64_t) count > MITOS_MAX_ARITY
        || (count != 0 && arguments == NULL)) {
        fail(active_runtime, "external effect call metadata is invalid");
        return 0;
    }
    for (index = 0; index < active_runtime->program->effect_operation_count; ++index) {
        if (active_runtime->program->effect_operations[index].operation
            == (uint32_t) operation) {
            descriptor = &active_runtime->program->effect_operations[index];
            break;
        }
    }
    if (descriptor == NULL || (descriptor->flags & 2u) == 0) {
        fail(active_runtime, "external effect operation has no MIR ABI descriptor");
        return 0;
    }
    for (index = 0; index < host_helper_count; ++index) {
        if (host_helpers[index].operation == (uint32_t) operation
            && host_helpers[index].abi_major == descriptor->abi_major
            && host_helpers[index].abi_minor == descriptor->abi_minor) {
            helper = &host_helpers[index];
            break;
        }
    }
    if (helper == NULL && (descriptor->flags & 4u) != 0) {
        builtin_helper = (HostHelperEntry) {
            (uint32_t) operation, descriptor->abi_major, descriptor->abi_minor,
            standard_console_handler, NULL
        };
        helper = &builtin_helper;
    }
    if (helper == NULL) {
        fail(active_runtime, "external effect operation %u has no compatible registered helper",
             (uint32_t) operation);
        return 0;
    }
    views = (MitosMirHostValue *) runtime_allocate(
        active_runtime, (size_t) count * sizeof(*views));
    if (count != 0 && views == NULL) return 0;
    memset(views, 0, (size_t) count * sizeof(*views));

    for (index = 0; index < (size_t) count; ++index) {
        Value *value = arguments[index];
        if (!valid_value(active_runtime, value)) return 0;
        views[index].type_id = value->type_id;
        if (value->kind == VALUE_INTEGER) {
            views[index].kind = MITOS_HOST_I64;
            views[index].integer = value->integer;
        } else if (value->kind == VALUE_STRING) {
            views[index].kind = MITOS_HOST_STRING;
            views[index].string = value->string;
            views[index].string_length = value->string_length;
        } else if (value->kind == VALUE_TYPE) {
            views[index].kind = MITOS_HOST_TYPE;
            views[index].represented_type = value->represented_type;
        } else if (value->kind == VALUE_FUNCTION) {
            views[index].kind = MITOS_HOST_FUNCTION;
        } else if (value->kind == VALUE_SUPERPOSITION) {
            views[index].kind = MITOS_HOST_SUPERPOSITION;
        } else if (value->kind == VALUE_ARRAY) {
            views[index].kind = MITOS_HOST_ARRAY;
        } else if (value->tag == active_runtime->program->true_tag
                   || value->tag == active_runtime->program->false_tag) {
            views[index].kind = MITOS_HOST_BOOL;
            views[index].boolean = value->tag == active_runtime->program->true_tag;
        } else if (value->type_id == 6u && value->arity == 0) {
            views[index].kind = MITOS_HOST_UNIT;
        } else {
            views[index].kind = MITOS_HOST_CONSTRUCTOR;
        }
    }
    memset(&call, 0, sizeof(call));
    call.abi_major = descriptor->abi_major;
    call.abi_minor = descriptor->abi_minor;
    call.effect = effect;
    call.operation = (uint32_t) operation;
    call.occurrence_order = ++active_runtime->effect_occurrence;
    call.arguments = views;
    call.argument_count = (size_t) count;
    if (!helper->handler(&call, helper->context)) {
        if (call.diagnostic != NULL && call.diagnostic_length != 0)
            fail(active_runtime, "%.*s", (int) (
                call.diagnostic_length > INT_MAX ? INT_MAX : call.diagnostic_length),
                 call.diagnostic);
        else
            fail(active_runtime, "external effect helper rejected operation %u",
                 (uint32_t) operation);
        return 0;
    }
    if (call.result.type_id == 0 || call.result.type_id > active_runtime->program->type_count
        || (expected != 1u
            && !runtime_subtype(active_runtime, call.result.type_id, expected))) {
        fail(active_runtime, "external effect helper returned an invalid result TypeId");
        return 0;
    }
    switch (call.result.kind) {
        case MITOS_HOST_I64:
            result = new_integer(active_runtime, call.result.integer);
            break;
        case MITOS_HOST_BOOL:
            result = as_value(boolean_value(active_runtime, call.result.boolean != 0));
            break;
        case MITOS_HOST_STRING:
            result = new_string(active_runtime, call.result.string,
                                call.result.string_length, call.result.type_id);
            break;
        case MITOS_HOST_TYPE:
            result = new_type_value(active_runtime, call.result.represented_type);
            break;
        case MITOS_HOST_UNIT: {
            uint32_t constructor_index;
            for (constructor_index = 0;
                 constructor_index < active_runtime->program->constructor_count;
                 ++constructor_index) {
                const MitosMirConstructor *constructor =
                    &active_runtime->program->constructors[constructor_index];
                if (constructor->runtime_type == call.result.type_id
                    && constructor->arity == 0) {
                    result = new_constructor(active_runtime, constructor->tag, 0,
                                             call.result.type_id);
                    break;
                }
            }
            break;
        }
        default:
            fail(active_runtime,
                 "external effect helper returned an unsupported aggregate/function result");
            return 0;
    }
    if (result == NULL || result->type_id != call.result.type_id) {
        fail(active_runtime, "external effect helper result does not match its declared TypeId");
        return 0;
    }
    return from_value(result);
}

typedef struct ExternalEffectLiftContext {
    int64_t operation;
    int64_t packed;
} ExternalEffectLiftContext;

static Value *external_effect_lift_callback(Runtime *runtime, Value **arguments,
                                            uint32_t count, void *raw_context) {
    ExternalEffectLiftContext *context = (ExternalEffectLiftContext *) raw_context;
    (void) runtime;
    return as_value(rt_external_effect_concrete(
        context->operation, (int64_t) (intptr_t) arguments, count, context->packed));
}

static int64_t rt_external_effect(int64_t operation, int64_t raw_arguments,
                                  int64_t count, int64_t packed_raw) {
    ExternalEffectLiftContext context = {operation, packed_raw};
    Value **arguments = (Value **) (intptr_t) raw_arguments;
    if (count < 0 || (uint64_t) count > MITOS_MAX_ARITY
        || (count != 0 && arguments == NULL)) {
        fail(active_runtime, "external effect call metadata is invalid");
        return 0;
    }
    return from_value(lift_values(
        active_runtime, arguments, (uint32_t) count, 0,
        external_effect_lift_callback, &context));
}

static int64_t rt_is_false(int64_t raw, int64_t u1, int64_t u2, int64_t u3) {
    Value *value = as_value(raw); (void) u1; (void) u2; (void) u3;
    if (!valid_value(active_runtime, value)) return 1;
    if (value->kind != VALUE_CONSTRUCTOR) {
        fail(active_runtime, "branch condition must be a True or False constructor");
        return 1;
    }
    if (value->tag == active_runtime->program->false_tag) return 1;
    if (value->tag == active_runtime->program->true_tag) return 0;
    fail(active_runtime, "branch condition must be a True or False constructor");
    return 1;
}

static int64_t rt_enter(int64_t u0, int64_t u1, int64_t u2, int64_t u3) {
    (void) u0; (void) u1; (void) u2; (void) u3;
    if (active_runtime->call_depth >= MITOS_MAX_CALL_DEPTH) {
        fail(active_runtime, "native call-depth limit exceeded");
        return 0;
    }
    active_runtime->call_depth++;
    return 1;
}

static int64_t rt_leave(int64_t u0, int64_t u1, int64_t u2, int64_t u3) {
    (void) u0; (void) u1; (void) u2; (void) u3;
    if (active_runtime->call_depth == 0) {
        fail(active_runtime, "native call-depth accounting underflow");
        return 0;
    }
    active_runtime->call_depth--;
    return 1;
}

static const char *helper_names[MITOS_HELPER_COUNT] = {
    "mitos_rt_const", "mitos_rt_add", "mitos_rt_subtract", "mitos_rt_multiply",
    "mitos_rt_divide", "mitos_rt_remainder", "mitos_rt_equal", "mitos_rt_less",
    "mitos_rt_less_equal", "mitos_rt_greater", "mitos_rt_greater_equal",
    "mitos_rt_make_constructor", "mitos_rt_set_field", "mitos_rt_get_field",
    "mitos_rt_tag_equal", "mitos_rt_type_value", "mitos_rt_type_of",
    "mitos_rt_type_assert", "mitos_rt_string", "mitos_rt_args_new",
    "mitos_rt_args_set", "mitos_rt_cached_call", "mitos_rt_external_effect",
    "mitos_rt_parallel_call", "mitos_rt_parallel_join",
    "mitos_rt_make_function", "mitos_rt_apply_function",
    "mitos_rt_superpose", "mitos_rt_collapse", "mitos_rt_lift_constructor",
    "mitos_rt_lift_call", "mitos_rt_lift_match", "mitos_rt_lift_make_function"
};

static void *helper_addresses[MITOS_HELPER_COUNT] = {
    (void *) rt_const, (void *) rt_add, (void *) rt_subtract, (void *) rt_multiply,
    (void *) rt_divide, (void *) rt_remainder, (void *) rt_equal, (void *) rt_less,
    (void *) rt_less_equal, (void *) rt_greater, (void *) rt_greater_equal,
    (void *) rt_make_constructor, (void *) rt_set_field, (void *) rt_get_field,
    (void *) rt_tag_equal, (void *) rt_type_value, (void *) rt_type_of,
    (void *) rt_type_assert, (void *) rt_string, (void *) rt_args_new,
    (void *) rt_args_set, (void *) rt_cached_call, (void *) rt_external_effect,
    (void *) rt_parallel_call, (void *) rt_parallel_join,
    (void *) rt_make_function, (void *) rt_apply_function,
    (void *) rt_superpose, (void *) rt_collapse, (void *) rt_lift_constructor,
    (void *) rt_lift_call, (void *) rt_lift_match, (void *) rt_lift_make_function
};

static int range_within(uint32_t start, uint32_t count, uint32_t total) {
    return start <= total && count <= total - start;
}

static int validate_program(const MitosMirProgram *program, char *diagnostic, size_t capacity) {
    uint32_t function_index, constructor_index, type_index;
    uint32_t expected_instruction_start = 0;
    uint8_t *validation_labels = NULL;
    uint8_t *validation_registers = NULL;
#define VALIDATE(condition, ...) do { \
    if (!(condition)) { \
        free(validation_labels); \
        free(validation_registers); \
        snprintf(diagnostic, capacity, __VA_ARGS__); \
        return 0; \
    } \
} while (0)
    VALIDATE(program != NULL, "native MIR requires a program");
    VALIDATE(program->function_count != 0 && program->function_count <= MITOS_MAX_FUNCTIONS,
             "native MIR function count is out of range");
    VALIDATE(program->constructor_count >= 2
                 && program->constructor_count <= MITOS_MAX_CONSTRUCTORS,
             "native MIR constructor count is out of range");
    VALIDATE(program->instruction_count <= MITOS_MAX_INSTRUCTIONS,
             "native MIR instruction limit exceeded");
    VALIDATE(program->operand_count <= MITOS_MAX_OPERANDS, "native MIR operand limit exceeded");
    VALIDATE(program->type_count != 0 && program->types != NULL,
             "native MIR type registry is absent");
    VALIDATE(program->functions != NULL && program->instructions != NULL
                 && program->constructors != NULL,
             "native MIR program contains a null required array");
    VALIDATE(program->operand_count == 0 || program->operands != NULL,
             "native MIR operand pool is null");
    VALIDATE(program->main_function < program->function_count,
             "native MIR main function index is out of range");
    VALIDATE(program->true_tag != program->false_tag,
             "native MIR True and False tags must differ");
    VALIDATE(program->i64_type != 0 && program->i64_type <= program->type_count
                 && program->bool_type != 0 && program->bool_type <= program->type_count
                 && program->string_type != 0 && program->string_type <= program->type_count
                 && program->type_type != 0 && program->type_type <= program->type_count
                 && program->function_type != 0 && program->function_type <= program->type_count,
             "native MIR bootstrap TypeIds are invalid");
    VALIDATE(program->string_count == 0 || program->strings != NULL,
             "native MIR String table is null");
    VALIDATE(program->effect_operation_count == 0 || program->effect_operations != NULL,
             "native MIR external-effect table is null");
    VALIDATE(program->native_method_count == 0 || program->native_methods != NULL,
             "native MIR specialization table is null");
    VALIDATE(program->match_arm_count == 0 || program->match_arms != NULL,
             "native MIR match-arm table is null");
    VALIDATE(program->max_workers != 0 && program->max_workers <= 256,
             "native MIR worker count is out of range");
    VALIDATE(program->phase_one_root_count != 0,
             "native MIR practical phase has no materialized roots");
    VALIDATE(program->reserved == 0 && program->reserved2 == 0,
             "native MIR program reserved fields must be zero");
    for (type_index = 0; type_index < program->type_count; ++type_index) {
        const MitosMirType *type = &program->types[type_index];
        size_t name_index;
        VALIDATE(type->id == type_index + 1, "native MIR TypeIds are not dense and stable");
        VALIDATE(type->parent <= program->type_count, "native MIR type parent is invalid");
        VALIDATE(type->type_value_runtime != 0
                     && type->type_value_runtime <= program->type_count,
                 "native MIR type has an invalid concrete Type-of identity");
        VALIDATE(type->constructor <= program->type_count
                     && type->argument <= program->type_count,
                 "native MIR type application metadata is invalid");
        VALIDATE(type->name != NULL && type->name_length != 0
                     && type->name_length <= MITOS_MAX_FORMAT_BYTES,
                 "native MIR type %u has an invalid name", type->id);
        for (name_index = 0; name_index < type->name_length; ++name_index)
            VALIDATE(type->name[name_index] != '\0',
                     "native MIR type %u name contains an embedded NUL byte", type->id);
    }
    for (type_index = 0; type_index < program->string_count; ++type_index) {
        const MitosMirString *literal = &program->strings[type_index];
        VALIDATE(literal->runtime_type != 0 && literal->runtime_type <= program->type_count,
                 "native MIR String literal has an invalid TypeId");
        VALIDATE(literal->length == 0 || literal->bytes != NULL,
                 "native MIR String literal has a null buffer");
        VALIDATE(literal->reserved == 0, "native MIR String literal reserved field is nonzero");
    }
    for (constructor_index = 0; constructor_index < program->constructor_count;
         ++constructor_index) {
        const MitosMirConstructor *constructor = &program->constructors[constructor_index];
        uint32_t other;
        size_t name_index;
        VALIDATE(constructor->arity <= MITOS_MAX_ARITY,
                 "constructor %u exceeds the arity cap", constructor_index);
        VALIDATE(constructor->reserved == 0,
                 "constructor %u reserved field must be zero", constructor_index);
        VALIDATE(constructor->runtime_type != 0
                     && constructor->runtime_type <= program->type_count,
                 "constructor %u has an invalid runtime TypeId", constructor_index);
        VALIDATE(constructor->name != NULL && constructor->name_length != 0
                     && constructor->name_length <= MITOS_MAX_FORMAT_BYTES,
                 "constructor %u has an invalid name", constructor_index);
        for (name_index = 0; name_index < constructor->name_length; ++name_index)
            VALIDATE(constructor->name[name_index] != '\0',
                     "constructor %u name contains an embedded NUL byte", constructor_index);
        for (other = 0; other < constructor_index; ++other)
            VALIDATE(program->constructors[other].tag != constructor->tag,
                     "constructor tags must be unique");
    }
    {
        const MitosMirConstructor *true_constructor = NULL, *false_constructor = NULL;
        for (constructor_index = 0; constructor_index < program->constructor_count;
             ++constructor_index) {
            if (program->constructors[constructor_index].tag == program->true_tag)
                true_constructor = &program->constructors[constructor_index];
            if (program->constructors[constructor_index].tag == program->false_tag)
                false_constructor = &program->constructors[constructor_index];
        }
        VALIDATE(true_constructor != NULL && false_constructor != NULL,
                 "native MIR True or False tag has no descriptor");
        VALIDATE(true_constructor->arity == 0 && false_constructor->arity == 0,
                 "native MIR True and False constructors must be nullary");
    }
    for (type_index = 0; type_index < program->match_arm_count; ++type_index) {
        const MitosMirMatchArm *arm = &program->match_arms[type_index];
        VALIDATE((arm->flags & ~1u) == 0,
                 "native MIR match arm has invalid flags");
        VALIDATE((arm->flags & 1u) != 0
                     || arm->constructor < program->constructor_count,
                 "native MIR match arm constructor is invalid");
    }
    for (function_index = 0; function_index < program->function_count; ++function_index) {
        const MitosMirFunction *function = &program->functions[function_index];
        uint8_t *labels;
        uint8_t *defined_registers;
        uint32_t local_index;
        VALIDATE(function->parameter_count <= function->register_count,
                 "function %u has more parameters than registers", function_index);
        VALIDATE(function->parameter_count <= MITOS_MAX_ARITY,
                 "function %u exceeds the call arity cap", function_index);
        VALIDATE(function->register_count != 0 && function->register_count <= MITOS_MAX_REGISTERS,
                 "function %u register count is out of range", function_index);
        VALIDATE(function->instruction_count != 0
                     && range_within(function->instruction_start, function->instruction_count,
                                     program->instruction_count),
                 "function %u instruction range is invalid", function_index);
        VALIDATE(function->instruction_start == expected_instruction_start,
                 "function %u instruction range overlaps or leaves a gap", function_index);
        labels = (uint8_t *) calloc(function->instruction_count, 1);
        validation_labels = labels;
        VALIDATE(labels != NULL, "out of memory while validating native MIR labels");
        defined_registers = (uint8_t *) calloc(function->register_count, 1);
        validation_registers = defined_registers;
        VALIDATE(defined_registers != NULL,
                 "out of memory while validating native MIR registers");
        for (local_index = 0; local_index < function->parameter_count; ++local_index)
            defined_registers[local_index] = 1;
        for (local_index = 0; local_index < function->instruction_count; ++local_index) {
            const MitosMirInstruction *instruction =
                &program->instructions[function->instruction_start + local_index];
            uint32_t operand_index;
#define REG(index) VALIDATE((index) < function->register_count, \
                            "function %u instruction %u has an invalid register", \
                            function_index, local_index)
#define USE(index) do { \
    REG(index); \
    VALIDATE(defined_registers[(index)] != 0, \
             "function %u instruction %u uses an undefined register", \
             function_index, local_index); \
} while (0)
            VALIDATE(instruction->opcode <= MITOS_MIR_LIFT_MAKE_FUNCTION,
                     "function %u instruction %u has an invalid opcode", function_index,
                     local_index);
            switch (instruction->opcode) {
                case MITOS_MIR_CONST:
                    REG(instruction->destination);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_MOVE:
                    USE(instruction->a);
                    REG(instruction->destination);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_ADD: case MITOS_MIR_SUBTRACT: case MITOS_MIR_MULTIPLY:
                case MITOS_MIR_DIVIDE: case MITOS_MIR_REMAINDER: case MITOS_MIR_EQUAL:
                case MITOS_MIR_LESS: case MITOS_MIR_LESS_EQUAL: case MITOS_MIR_GREATER:
                case MITOS_MIR_GREATER_EQUAL:
                    USE(instruction->a);
                    USE(instruction->b);
                    REG(instruction->destination);
                    defined_registers[instruction->destination] = 1;
                    VALIDATE(instruction->immediate == 0
                                 || ((uint64_t) instruction->immediate <= program->type_count),
                             "function %u lifted primitive result TypeId is invalid",
                             function_index);
                    break;
                case MITOS_MIR_CALL:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->function_count,
                             "function %u call target is invalid", function_index);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count),
                             "function %u call operand range is invalid", function_index);
                    VALIDATE(instruction->operand_count
                                 == program->functions[instruction->a].parameter_count,
                             "function %u call arity is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_MAKE_CONSTRUCTOR:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->constructor_count,
                             "function %u constructor index is invalid", function_index);
                    VALIDATE(instruction->b != 0 && instruction->b <= program->type_count,
                             "function %u constructor runtime TypeId is invalid", function_index);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count),
                             "function %u constructor operand range is invalid", function_index);
                    VALIDATE(instruction->operand_count
                                 == program->constructors[instruction->a].arity,
                             "function %u constructor arity is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_TAG_EQUAL:
                    USE(instruction->a);
                    REG(instruction->destination);
                    VALIDATE(instruction->b < program->constructor_count,
                             "function %u tag test constructor is invalid", function_index);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_GET_FIELD:
                    USE(instruction->a);
                    REG(instruction->destination);
                    VALIDATE(instruction->b < MITOS_MAX_ARITY,
                             "function %u field index exceeds the cap", function_index);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_LABEL:
                    VALIDATE(instruction->a < function->instruction_count,
                             "function %u label index is invalid", function_index);
                    VALIDATE(labels[instruction->a] == 0,
                             "function %u defines a label more than once", function_index);
                    labels[instruction->a] = 1;
                    break;
                case MITOS_MIR_JUMP:
                    VALIDATE(instruction->a < function->instruction_count,
                             "function %u jump label is invalid", function_index);
                    break;
                case MITOS_MIR_BRANCH_FALSE:
                    USE(instruction->a);
                    VALIDATE(instruction->b < function->instruction_count,
                             "function %u branch label is invalid", function_index);
                    break;
                case MITOS_MIR_TYPE_VALUE:
                    REG(instruction->destination);
                    VALIDATE(instruction->a != 0 && instruction->a <= program->type_count,
                             "function %u Type value has an invalid TypeId", function_index);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_TYPE_OF:
                    USE(instruction->a);
                    REG(instruction->destination);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_TYPE_ASSERT:
                    USE(instruction->a);
                    REG(instruction->destination);
                    VALIDATE(instruction->b != 0 && instruction->b <= program->type_count,
                             "function %u assertion has an invalid TypeId", function_index);
                    VALIDATE(instruction->immediate == 0
                                 || (uint64_t) instruction->immediate <= program->type_count,
                             "function %u lifted assertion result TypeId is invalid",
                             function_index);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_STRING_CONST:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->string_count,
                             "function %u String literal index is invalid", function_index);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_CACHED_CALL:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->native_method_count
                                 && program->native_methods[instruction->a] != NULL,
                             "function %u specialization handle is invalid", function_index);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count),
                             "function %u specialization operand range is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    VALIDATE(instruction->b == 0 || instruction->b <= program->type_count,
                             "function %u specialization lifted result TypeId is invalid",
                             function_index);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_EXTERNAL_EFFECT:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->effect_operation_count,
                             "function %u external-effect descriptor is invalid", function_index);
                    VALIDATE((program->effect_operations[instruction->a].flags & 2u) != 0,
                             "function %u effect descriptor is not external", function_index);
                    VALIDATE((uint32_t) instruction->immediate != 0
                                 && (uint32_t) instruction->immediate <= program->type_count,
                             "function %u external-effect result TypeId is invalid", function_index);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count),
                             "function %u external-effect operand range is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_PARALLEL_CALL:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->function_count,
                             "function %u parallel thunk target is invalid", function_index);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count),
                             "function %u parallel thunk operand range is invalid", function_index);
                    VALIDATE(instruction->operand_count
                                 == program->functions[instruction->a].parameter_count,
                             "function %u parallel thunk arity is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_PARALLEL_JOIN:
                    USE(instruction->a);
                    REG(instruction->destination);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_MAKE_FUNCTION:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->function_count
                                 && instruction->b != 0 && instruction->b <= program->type_count,
                             "function %u closure target or TypeId is invalid", function_index);
                    VALIDATE(instruction->immediate >= 0
                                 && (uint64_t) instruction->immediate <= MITOS_MAX_ARITY,
                             "function %u closure parameter count is invalid", function_index);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count),
                             "function %u closure capture range is invalid", function_index);
                    VALIDATE(program->functions[instruction->a].parameter_count
                                 == instruction->operand_count
                                    + (uint32_t) instruction->immediate,
                             "function %u closure target arity is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_APPLY_FUNCTION:
                    USE(instruction->a);
                    REG(instruction->destination);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count),
                             "function %u application operand range is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    VALIDATE(instruction->b == 0 || instruction->b <= program->type_count,
                             "function %u application lifted result TypeId is invalid",
                             function_index);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_RETURN:
                    USE(instruction->a);
                    break;
                case MITOS_MIR_SUPERPOSE:
                    REG(instruction->destination);
                    VALIDATE(instruction->b != 0 && instruction->b <= program->type_count
                                 && instruction->immediate > 0
                                 && instruction->operand_count != 0
                                 && instruction->operand_count <= MITOS_MAX_ARITY,
                             "function %u superpose metadata is invalid", function_index);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count),
                             "function %u superpose operand range is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_COLLAPSE:
                    USE(instruction->a);
                    REG(instruction->destination);
                    VALIDATE(instruction->b != 0 && instruction->b <= program->type_count
                                 && instruction->immediate > 0
                                 && (uint64_t) instruction->immediate <= program->type_count,
                             "function %u collapse metadata is invalid", function_index);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_LIFT_CONSTRUCTOR:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->constructor_count
                                 && instruction->b != 0
                                 && instruction->b <= program->type_count,
                             "function %u lifted constructor metadata is invalid",
                             function_index);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count)
                                 && instruction->operand_count
                                    == program->constructors[instruction->a].arity,
                             "function %u lifted constructor operands are invalid",
                             function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_LIFT_CALL:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->function_count
                                 && instruction->b != 0
                                 && instruction->b <= program->type_count,
                             "function %u lifted call metadata is invalid", function_index);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count)
                                 && instruction->operand_count
                                    == program->functions[instruction->a].parameter_count,
                             "function %u lifted call operands are invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_LIFT_MATCH:
                    USE(instruction->a);
                    REG(instruction->destination);
                    VALIDATE((instruction->b == 0 || instruction->b <= program->type_count)
                                 && instruction->operand_count != 0
                                 && range_within(instruction->operand_start,
                                                 instruction->operand_count,
                                                 program->operand_count)
                                 && (uint64_t) instruction->immediate
                                    <= program->match_arm_count
                                 && instruction->operand_count
                                    <= program->match_arm_count
                                        - (uint32_t) instruction->immediate,
                             "function %u lifted match metadata is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_LIFT_MAKE_FUNCTION:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->function_count
                                 && instruction->b != 0
                                 && instruction->b <= program->type_count
                                 && instruction->immediate >= 0
                                 && (uint64_t) instruction->immediate <= MITOS_MAX_ARITY
                                 && range_within(instruction->operand_start,
                                                 instruction->operand_count,
                                                 program->operand_count)
                                 && program->functions[instruction->a].parameter_count
                                    == instruction->operand_count
                                        + (uint32_t) instruction->immediate,
                             "function %u lifted closure metadata is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
            }
#undef USE
#undef REG
        }
        for (local_index = 0; local_index < function->instruction_count; ++local_index) {
            const MitosMirInstruction *instruction =
                &program->instructions[function->instruction_start + local_index];
            if (instruction->opcode == MITOS_MIR_JUMP)
                VALIDATE(labels[instruction->a] != 0, "function %u jumps to an undefined label",
                         function_index);
            if (instruction->opcode == MITOS_MIR_BRANCH_FALSE)
                VALIDATE(labels[instruction->b] != 0,
                         "function %u branches to an undefined label", function_index);
            if ((instruction->opcode == MITOS_MIR_JUMP
                 || instruction->opcode == MITOS_MIR_RETURN)
                && local_index + 1 < function->instruction_count)
                VALIDATE(program->instructions[function->instruction_start + local_index + 1]
                                 .opcode == MITOS_MIR_LABEL,
                         "function %u has an instruction after a basic-block terminator",
                         function_index);
        }
        VALIDATE(program->instructions[function->instruction_start + function->instruction_count - 1]
                         .opcode == MITOS_MIR_RETURN,
                 "function %u must end with RETURN", function_index);
        free(labels);
        validation_labels = NULL;
        free(defined_registers);
        validation_registers = NULL;
        expected_instruction_start += function->instruction_count;
    }
    VALIDATE(expected_instruction_start == program->instruction_count,
             "native MIR instruction ranges do not cover the instruction array");
    VALIDATE(program->functions[program->main_function].parameter_count == 0,
             "native MIR main must have zero parameters");
#undef VALIDATE
    return 1;
}

static void mir_error(MIR_error_type_t type, const char *format, ...) {
    va_list arguments;
    (void) type;
    if (active_mir_diagnostic != NULL && active_mir_diagnostic[0] == '\0') {
        va_start(arguments, format);
        vsnprintf(active_mir_diagnostic, MITOS_DIAGNOSTIC_BYTES, format, arguments);
        va_end(arguments);
    }
    if (active_mir_jump != NULL) longjmp(*active_mir_jump, 1);
    abort();
}

static MIR_insn_t helper_call(MirBuild *build, MIR_item_t function, MIR_reg_t destination,
                              uint32_t helper, MIR_op_t a, MIR_op_t b, MIR_op_t c, MIR_op_t d) {
    MIR_op_t operands[7];
    (void) function;
    operands[0] = MIR_new_ref_op(build->context, build->helper_proto);
    operands[1] = MIR_new_ref_op(build->context, build->helper_imports[helper]);
    operands[2] = MIR_new_reg_op(build->context, destination);
    operands[3] = a; operands[4] = b; operands[5] = c; operands[6] = d;
    return MIR_new_insn_arr(build->context, MIR_CALL, 7, operands);
}

static MIR_op_t zero_op(MirBuild *build) { return MIR_new_int_op(build->context, 0); }

static int build_mir(const MitosMirProgram *program, MirBuild *build) {
    MIR_type_t result_type = MIR_T_I64;
    MIR_var_t helper_arguments[4] = {{MIR_T_I64, "a", 0}, {MIR_T_I64, "b", 0},
                                     {MIR_T_I64, "c", 0}, {MIR_T_I64, "d", 0}};
    uint32_t index;
    build->module = MIR_new_module(build->context, "mitos_native");
    build->helper_proto = MIR_new_proto_arr(build->context, "mitos_helper_proto", 1,
                                            &result_type, 4, helper_arguments);
    for (index = 0; index < MITOS_HELPER_COUNT; ++index)
        build->helper_imports[index] = MIR_new_import(build->context, helper_names[index]);
    build->enter_import = MIR_new_import(build->context, "mitos_rt_enter");
    build->leave_import = MIR_new_import(build->context, "mitos_rt_leave");
    build->false_import = MIR_new_import(build->context, "mitos_rt_is_false");
    build->function_protos = (MIR_item_t *) calloc(program->function_count, sizeof(MIR_item_t));
    build->function_forwards = (MIR_item_t *) calloc(program->function_count, sizeof(MIR_item_t));
    build->function_items = (MIR_item_t *) calloc(program->function_count, sizeof(MIR_item_t));
    build->function_wrappers = (MIR_item_t *) calloc(program->function_count, sizeof(MIR_item_t));
    if (build->function_protos == NULL || build->function_forwards == NULL
        || build->function_items == NULL || build->function_wrappers == NULL) return 0;
    for (index = 0; index < program->function_count; ++index) {
        const MitosMirFunction *source = &program->functions[index];
        MIR_var_t *arguments = NULL;
        char name[48], proto_name[48];
        uint32_t argument;
        if (source->parameter_count != 0) {
            arguments = (MIR_var_t *) calloc(source->parameter_count, sizeof(*arguments));
            if (arguments == NULL) return 0;
            for (argument = 0; argument < source->parameter_count; ++argument) {
                char *argument_name = (char *) malloc(32);
                if (argument_name == NULL) return 0;
                snprintf(argument_name, 32, "argument_%u", argument);
                arguments[argument] = (MIR_var_t) {MIR_T_I64, argument_name, 0};
            }
        }
        snprintf(name, sizeof(name), "mitos_function_%u", index);
        snprintf(proto_name, sizeof(proto_name), "mitos_proto_%u", index);
        build->function_protos[index] = MIR_new_proto_arr(build->context, proto_name, 1,
                                                          &result_type, source->parameter_count,
                                                          arguments);
        build->function_forwards[index] = MIR_new_forward(build->context, name);
        for (argument = 0; argument < source->parameter_count; ++argument)
            free((void *) arguments[argument].name);
        free(arguments);
    }
    for (index = 0; index < program->function_count; ++index) {
        const MitosMirFunction *source = &program->functions[index];
        MIR_var_t *arguments = NULL;
        char **argument_names = NULL;
        MIR_reg_t *registers = NULL;
        MIR_label_t *labels = NULL;
        MIR_label_t entry_failure;
        MIR_item_t function;
        MIR_func_t function_data;
        MIR_item_t enter_import = build->enter_import;
        MIR_item_t leave_import = build->leave_import;
        MIR_item_t false_import = build->false_import;
        MIR_reg_t enter_result, scratch;
        char name[48];
        uint32_t argument, local_index;
        if (source->parameter_count != 0) {
            arguments = (MIR_var_t *) calloc(source->parameter_count, sizeof(*arguments));
            argument_names = (char **) calloc(source->parameter_count, sizeof(*argument_names));
            if (arguments == NULL || argument_names == NULL) return 0;
            for (argument = 0; argument < source->parameter_count; ++argument) {
                char *argument_name = (char *) malloc(32);
                if (argument_name == NULL) return 0;
                snprintf(argument_name, 32, "argument_%u", argument);
                argument_names[argument] = argument_name;
                arguments[argument] = (MIR_var_t) {MIR_T_I64, argument_name, 0};
            }
        }
        snprintf(name, sizeof(name), "mitos_function_%u", index);
        function = MIR_new_func_arr(build->context, name, 1, &result_type,
                                    source->parameter_count, arguments);
        build->function_items[index] = function;
        function_data = MIR_get_item_func(build->context, function);
        registers = (MIR_reg_t *) calloc(source->register_count, sizeof(*registers));
        labels = (MIR_label_t *) calloc(source->instruction_count, sizeof(*labels));
        if (registers == NULL || labels == NULL) return 0;
        for (argument = 0; argument < source->parameter_count; ++argument) {
            registers[argument] = MIR_reg(build->context, arguments[argument].name, function_data);
            free(argument_names[argument]);
        }
        free(arguments);
        free(argument_names);
        for (argument = source->parameter_count; argument < source->register_count; ++argument) {
            char register_name[32];
            snprintf(register_name, sizeof(register_name), "value_%u", argument);
            registers[argument] = MIR_new_func_reg(build->context, function_data, MIR_T_I64,
                                                   register_name);
        }
        enter_result = MIR_new_func_reg(build->context, function_data, MIR_T_I64, "entered");
        scratch = MIR_new_func_reg(build->context, function_data, MIR_T_I64, "scratch");
        entry_failure = MIR_new_label(build->context);
        for (local_index = 0; local_index < source->instruction_count; ++local_index) {
            const MitosMirInstruction *instruction =
                &program->instructions[source->instruction_start + local_index];
            if (instruction->opcode == MITOS_MIR_LABEL)
                labels[instruction->a] = MIR_new_label(build->context);
        }
        {
            MIR_op_t call_ops[7] = {MIR_new_ref_op(build->context, build->helper_proto),
                                    MIR_new_ref_op(build->context, enter_import),
                                    MIR_new_reg_op(build->context, enter_result), zero_op(build),
                                    zero_op(build), zero_op(build), zero_op(build)};
            MIR_append_insn(build->context, function,
                            MIR_new_insn_arr(build->context, MIR_CALL, 7, call_ops));
            MIR_append_insn(build->context, function,
                            MIR_new_insn(build->context, MIR_BEQ,
                                         MIR_new_label_op(build->context, entry_failure),
                                         MIR_new_reg_op(build->context, enter_result), zero_op(build)));
        }
        for (local_index = 0; local_index < source->instruction_count; ++local_index) {
            const MitosMirInstruction *instruction =
                &program->instructions[source->instruction_start + local_index];
            MIR_insn_t emitted = NULL;
            uint32_t helper = 0;
            switch (instruction->opcode) {
                case MITOS_MIR_CONST:
                    emitted = helper_call(build, function, registers[instruction->destination], 0,
                                          MIR_new_int_op(build->context, instruction->immediate),
                                          zero_op(build), zero_op(build), zero_op(build));
                    break;
                case MITOS_MIR_MOVE:
                    emitted = MIR_new_insn(build->context, MIR_MOV,
                                           MIR_new_reg_op(build->context, registers[instruction->destination]),
                                           MIR_new_reg_op(build->context, registers[instruction->a]));
                    break;
                case MITOS_MIR_ADD: helper = 1; goto binary_helper;
                case MITOS_MIR_SUBTRACT: helper = 2; goto binary_helper;
                case MITOS_MIR_MULTIPLY: helper = 3; goto binary_helper;
                case MITOS_MIR_DIVIDE: helper = 4; goto binary_helper;
                case MITOS_MIR_REMAINDER: helper = 5; goto binary_helper;
                case MITOS_MIR_EQUAL: helper = 6; goto binary_helper;
                case MITOS_MIR_LESS: helper = 7; goto binary_helper;
                case MITOS_MIR_LESS_EQUAL: helper = 8; goto binary_helper;
                case MITOS_MIR_GREATER: helper = 9; goto binary_helper;
                case MITOS_MIR_GREATER_EQUAL: helper = 10;
binary_helper:
                    emitted = helper_call(build, function, registers[instruction->destination], helper,
                                          MIR_new_reg_op(build->context, registers[instruction->a]),
                                          MIR_new_reg_op(build->context, registers[instruction->b]),
                                          MIR_new_uint_op(build->context,
                                                          (uint64_t) instruction->immediate),
                                          zero_op(build));
                    break;
                case MITOS_MIR_CALL: {
                    uint32_t operand, count = instruction->operand_count;
                    MIR_op_t *call_ops = (MIR_op_t *) malloc((size_t) (count + 3) * sizeof(*call_ops));
                    if (call_ops == NULL) return 0;
                    call_ops[0] = MIR_new_ref_op(build->context,
                                                 build->function_protos[instruction->a]);
                    call_ops[1] = MIR_new_ref_op(build->context,
                                                 build->function_forwards[instruction->a]);
                    call_ops[2] = MIR_new_reg_op(build->context,
                                                 registers[instruction->destination]);
                    for (operand = 0; operand < count; ++operand)
                        call_ops[operand + 3] = MIR_new_reg_op(
                            build->context,
                            registers[program->operands[instruction->operand_start + operand]]);
                    emitted = MIR_new_insn_arr(build->context, MIR_CALL, count + 3, call_ops);
                    free(call_ops);
                    break;
                }
                case MITOS_MIR_MAKE_CONSTRUCTOR: {
                    uint32_t operand;
                    const MitosMirConstructor *descriptor =
                        &program->constructors[instruction->a];
                    emitted = helper_call(build, function, registers[instruction->destination], 11,
                                          MIR_new_uint_op(build->context, descriptor->tag),
                                          MIR_new_uint_op(build->context, descriptor->arity),
                                          MIR_new_uint_op(build->context, instruction->b),
                                          zero_op(build));
                    MIR_append_insn(build->context, function, emitted);
                    emitted = NULL;
                    for (operand = 0; operand < instruction->operand_count; ++operand) {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 12,
                            MIR_new_reg_op(build->context, registers[instruction->destination]),
                            MIR_new_uint_op(build->context, operand),
                            MIR_new_reg_op(build->context,
                                           registers[program->operands[instruction->operand_start + operand]]),
                            zero_op(build));
                        MIR_append_insn(build->context, function, emitted);
                        emitted = NULL;
                    }
                    break;
                }
                case MITOS_MIR_TAG_EQUAL: {
                    const MitosMirConstructor *descriptor = &program->constructors[instruction->b];
                    emitted = helper_call(build, function, registers[instruction->destination], 14,
                                          MIR_new_reg_op(build->context, registers[instruction->a]),
                                          MIR_new_uint_op(build->context, descriptor->tag),
                                          zero_op(build), zero_op(build));
                    break;
                }
                case MITOS_MIR_GET_FIELD:
                    emitted = helper_call(build, function, registers[instruction->destination], 13,
                                          MIR_new_reg_op(build->context, registers[instruction->a]),
                                          MIR_new_uint_op(build->context, instruction->b),
                                          zero_op(build), zero_op(build));
                    break;
                case MITOS_MIR_LABEL: emitted = labels[instruction->a]; break;
                case MITOS_MIR_JUMP:
                    emitted = MIR_new_insn(build->context, MIR_JMP,
                                           MIR_new_label_op(build->context, labels[instruction->a]));
                    break;
                case MITOS_MIR_BRANCH_FALSE: {
                    MIR_op_t call_ops[7] = {MIR_new_ref_op(build->context, build->helper_proto),
                                            MIR_new_ref_op(build->context, false_import),
                                            MIR_new_reg_op(build->context, scratch),
                                            MIR_new_reg_op(build->context, registers[instruction->a]),
                                            zero_op(build), zero_op(build), zero_op(build)};
                    MIR_append_insn(build->context, function,
                                    MIR_new_insn_arr(build->context, MIR_CALL, 7, call_ops));
                    emitted = MIR_new_insn(build->context, MIR_BNE,
                                           MIR_new_label_op(build->context, labels[instruction->b]),
                                           MIR_new_reg_op(build->context, scratch), zero_op(build));
                    break;
                }
                case MITOS_MIR_TYPE_VALUE:
                    emitted = helper_call(build, function, registers[instruction->destination], 15,
                                          MIR_new_uint_op(build->context, instruction->a),
                                          zero_op(build), zero_op(build), zero_op(build));
                    break;
                case MITOS_MIR_TYPE_OF:
                    emitted = helper_call(build, function, registers[instruction->destination], 16,
                                          MIR_new_reg_op(build->context, registers[instruction->a]),
                                          zero_op(build), zero_op(build), zero_op(build));
                    break;
                case MITOS_MIR_TYPE_ASSERT:
                    emitted = helper_call(build, function, registers[instruction->destination], 17,
                                          MIR_new_reg_op(build->context, registers[instruction->a]),
                                          MIR_new_uint_op(build->context, instruction->b),
                                          MIR_new_uint_op(build->context,
                                                          (uint64_t) instruction->immediate),
                                          zero_op(build));
                    break;
                case MITOS_MIR_STRING_CONST:
                    emitted = helper_call(build, function, registers[instruction->destination], 18,
                                          MIR_new_uint_op(build->context, instruction->a),
                                          zero_op(build), zero_op(build), zero_op(build));
                    break;
                case MITOS_MIR_CACHED_CALL:
                case MITOS_MIR_EXTERNAL_EFFECT: {
                    uint32_t operand;
                    emitted = helper_call(build, function, registers[instruction->destination], 19,
                                          MIR_new_uint_op(build->context,
                                                          instruction->operand_count),
                                          zero_op(build), zero_op(build), zero_op(build));
                    MIR_append_insn(build->context, function, emitted);
                    emitted = NULL;
                    for (operand = 0; operand < instruction->operand_count; ++operand) {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 20,
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, operand),
                            MIR_new_reg_op(build->context,
                                           registers[program->operands[
                                               instruction->operand_start + operand]]),
                            MIR_new_uint_op(build->context, instruction->operand_count));
                        MIR_append_insn(build->context, function, emitted);
                        emitted = NULL;
                    }
                    if (instruction->opcode == MITOS_MIR_CACHED_CALL) {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 21,
                            MIR_new_uint_op(build->context,
                                (uint64_t) (uintptr_t) program->native_methods[instruction->a]),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, instruction->operand_count),
                            MIR_new_uint_op(build->context, instruction->b));
                    } else {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 22,
                            MIR_new_uint_op(build->context,
                                program->effect_operations[instruction->a].operation),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, instruction->operand_count),
                            MIR_new_uint_op(build->context,
                                            (uint64_t) instruction->immediate));
                    }
                    break;
                }
                case MITOS_MIR_PARALLEL_CALL: {
                    uint32_t operand;
                    emitted = helper_call(build, function, registers[instruction->destination], 19,
                                          MIR_new_uint_op(build->context,
                                                          instruction->operand_count),
                                          zero_op(build), zero_op(build), zero_op(build));
                    MIR_append_insn(build->context, function, emitted);
                    emitted = NULL;
                    for (operand = 0; operand < instruction->operand_count; ++operand) {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 20,
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, operand),
                            MIR_new_reg_op(build->context,
                                           registers[program->operands[
                                               instruction->operand_start + operand]]),
                            MIR_new_uint_op(build->context, instruction->operand_count));
                        MIR_append_insn(build->context, function, emitted);
                        emitted = NULL;
                    }
                    emitted = helper_call(
                        build, function, registers[instruction->destination], 23,
                        MIR_new_uint_op(build->context, instruction->a),
                        MIR_new_reg_op(build->context, registers[instruction->destination]),
                        MIR_new_uint_op(build->context, instruction->operand_count),
                        zero_op(build));
                    break;
                }
                case MITOS_MIR_PARALLEL_JOIN:
                    emitted = helper_call(
                        build, function, registers[instruction->destination], 24,
                        MIR_new_reg_op(build->context, registers[instruction->a]),
                        zero_op(build), zero_op(build), zero_op(build));
                    break;
                case MITOS_MIR_MAKE_FUNCTION:
                case MITOS_MIR_APPLY_FUNCTION:
                case MITOS_MIR_LIFT_MAKE_FUNCTION: {
                    uint32_t operand;
                    emitted = helper_call(build, function, registers[instruction->destination], 19,
                                          MIR_new_uint_op(build->context,
                                                          instruction->operand_count),
                                          zero_op(build), zero_op(build), zero_op(build));
                    MIR_append_insn(build->context, function, emitted);
                    emitted = NULL;
                    for (operand = 0; operand < instruction->operand_count; ++operand) {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 20,
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, operand),
                            MIR_new_reg_op(build->context,
                                           registers[program->operands[
                                               instruction->operand_start + operand]]),
                            MIR_new_uint_op(build->context, instruction->operand_count));
                        MIR_append_insn(build->context, function, emitted);
                        emitted = NULL;
                    }
                    if (instruction->opcode == MITOS_MIR_MAKE_FUNCTION) {
                        uint64_t packed = ((uint64_t) instruction->immediate << 32)
                            | instruction->b;
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 25,
                            MIR_new_uint_op(build->context, instruction->a),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, instruction->operand_count),
                            MIR_new_uint_op(build->context, packed));
                    } else if (instruction->opcode == MITOS_MIR_LIFT_MAKE_FUNCTION) {
                        uint64_t packed = ((uint64_t) instruction->immediate << 32)
                            | instruction->b;
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 32,
                            MIR_new_uint_op(build->context, instruction->a),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, packed),
                            zero_op(build));
                    } else {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 26,
                            MIR_new_reg_op(build->context, registers[instruction->a]),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, instruction->operand_count),
                            MIR_new_uint_op(build->context, instruction->b));
                    }
                    break;
                }
                case MITOS_MIR_SUPERPOSE:
                case MITOS_MIR_LIFT_CONSTRUCTOR:
                case MITOS_MIR_LIFT_CALL:
                case MITOS_MIR_LIFT_MATCH: {
                    uint32_t operand;
                    emitted = helper_call(build, function,
                                          registers[instruction->destination], 19,
                                          MIR_new_uint_op(build->context,
                                                          instruction->operand_count),
                                          zero_op(build), zero_op(build), zero_op(build));
                    MIR_append_insn(build->context, function, emitted);
                    emitted = NULL;
                    for (operand = 0; operand < instruction->operand_count; ++operand) {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 20,
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, operand),
                            MIR_new_reg_op(build->context,
                                registers[program->operands[
                                    instruction->operand_start + operand]]),
                            MIR_new_uint_op(build->context, instruction->operand_count));
                        MIR_append_insn(build->context, function, emitted);
                        emitted = NULL;
                    }
                    if (instruction->opcode == MITOS_MIR_SUPERPOSE) {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 27,
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, instruction->operand_count),
                            MIR_new_uint_op(build->context,
                                            (uint64_t) instruction->immediate),
                            MIR_new_uint_op(build->context, instruction->b));
                    } else if (instruction->opcode == MITOS_MIR_LIFT_CONSTRUCTOR) {
                        const MitosMirConstructor *descriptor =
                            &program->constructors[instruction->a];
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 29,
                            MIR_new_uint_op(build->context, descriptor->tag),
                            MIR_new_uint_op(build->context, instruction->b),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, instruction->operand_count));
                    } else if (instruction->opcode == MITOS_MIR_LIFT_CALL) {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 30,
                            MIR_new_uint_op(build->context, instruction->a),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, instruction->operand_count),
                            MIR_new_uint_op(build->context, instruction->b));
                    } else {
                        uint64_t packed = ((uint64_t) instruction->b << 32)
                            | instruction->operand_count;
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 31,
                            MIR_new_reg_op(build->context, registers[instruction->a]),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context,
                                            (uint64_t) instruction->immediate),
                            MIR_new_uint_op(build->context, packed));
                    }
                    break;
                }
                case MITOS_MIR_COLLAPSE:
                    emitted = helper_call(
                        build, function, registers[instruction->destination], 28,
                        MIR_new_reg_op(build->context, registers[instruction->a]),
                        MIR_new_uint_op(build->context, instruction->b),
                        MIR_new_uint_op(build->context,
                                        (uint64_t) instruction->immediate),
                        zero_op(build));
                    break;
                case MITOS_MIR_RETURN: {
                    MIR_op_t call_ops[7] = {MIR_new_ref_op(build->context, build->helper_proto),
                                            MIR_new_ref_op(build->context, leave_import),
                                            MIR_new_reg_op(build->context, scratch), zero_op(build),
                                            zero_op(build), zero_op(build), zero_op(build)};
                    MIR_append_insn(build->context, function,
                                    MIR_new_insn_arr(build->context, MIR_CALL, 7, call_ops));
                    emitted = MIR_new_ret_insn(
                        build->context, 1,
                        MIR_new_reg_op(build->context, registers[instruction->a]));
                    break;
                }
            }
            if (emitted != NULL) MIR_append_insn(build->context, function, emitted);
        }
        MIR_append_insn(build->context, function, entry_failure);
        MIR_append_insn(build->context, function,
                        MIR_new_ret_insn(build->context, 1, zero_op(build)));
        MIR_finish_func(build->context);
        free(labels);
        free(registers);
    }
    for (index = 0; index < program->function_count; ++index) {
        const MitosMirFunction *source = &program->functions[index];
        MIR_var_t arguments[2] = {
            {MIR_T_I64, "arguments", 0},
            {MIR_T_I64, "argument_count", 0}
        };
        MIR_item_t wrapper;
        MIR_func_t wrapper_data;
        MIR_reg_t arguments_reg, result_reg;
        MIR_op_t *call_ops;
        uint32_t argument;
        char name[48];
        snprintf(name, sizeof(name), "mitos_wrapper_%u", index);
        wrapper = MIR_new_func_arr(build->context, name, 1, &result_type, 2, arguments);
        build->function_wrappers[index] = wrapper;
        wrapper_data = MIR_get_item_func(build->context, wrapper);
        arguments_reg = MIR_reg(build->context, "arguments", wrapper_data);
        result_reg = MIR_new_func_reg(build->context, wrapper_data, MIR_T_I64, "result");
        call_ops = (MIR_op_t *) malloc(
            (size_t) (source->parameter_count + 3) * sizeof(*call_ops));
        if (call_ops == NULL) return 0;
        call_ops[0] = MIR_new_ref_op(build->context, build->function_protos[index]);
        call_ops[1] = MIR_new_ref_op(build->context, build->function_forwards[index]);
        call_ops[2] = MIR_new_reg_op(build->context, result_reg);
        for (argument = 0; argument < source->parameter_count; ++argument) {
            call_ops[argument + 3] = MIR_new_mem_op(
                build->context, MIR_T_I64, (MIR_disp_t) argument * 8,
                arguments_reg, 0, 1);
        }
        MIR_append_insn(build->context, wrapper,
                        MIR_new_insn_arr(build->context, MIR_CALL,
                                         source->parameter_count + 3, call_ops));
        free(call_ops);
        MIR_append_insn(build->context, wrapper,
                        MIR_new_ret_insn(build->context, 1,
                                         MIR_new_reg_op(build->context, result_reg)));
        MIR_finish_func(build->context);
    }
    MIR_finish_module(build->context);
    return 1;
}

static int builder_reserve(TextBuilder *builder, size_t additional) {
    size_t required, capacity;
    char *replacement;
    if (additional > MITOS_MAX_FORMAT_BYTES
        || builder->length > MITOS_MAX_FORMAT_BYTES - additional) {
        fail(builder->runtime, "formatted result exceeds the byte limit");
        return 0;
    }
    required = builder->length + additional + 1;
    if (required <= builder->capacity) return 1;
    capacity = builder->capacity == 0 ? 64 : builder->capacity;
    while (capacity < required) {
        if (capacity >= MITOS_MAX_FORMAT_BYTES / 2) {
            capacity = MITOS_MAX_FORMAT_BYTES + 1;
            break;
        }
        capacity *= 2;
    }
    replacement = (char *) realloc(builder->data, capacity);
    if (replacement == NULL) {
        fail(builder->runtime, "out of memory while formatting the native result");
        return 0;
    }
    builder->data = replacement;
    builder->capacity = capacity;
    return 1;
}

static int builder_append(TextBuilder *builder, const char *text, size_t length) {
    if (!builder_reserve(builder, length)) return 0;
    memcpy(builder->data + builder->length, text, length);
    builder->length += length;
    builder->data[builder->length] = '\0';
    return 1;
}

static int format_value(TextBuilder *builder, Value *value, uint32_t depth) {
    uint32_t index;
    if (depth >= MITOS_MAX_VALUE_DEPTH) {
        fail(builder->runtime, "formatted result exceeds the nesting-depth limit");
        return 0;
    }
    if (!valid_value(builder->runtime, value)) return 0;
    if (value->kind == VALUE_INTEGER) {
        char integer[32];
        int length = snprintf(integer, sizeof(integer), "%" PRId64, value->integer);
        return length > 0 && builder_append(builder, integer, (size_t) length);
    }
    if (value->kind == VALUE_STRING)
        return builder_append(builder, value->string, value->string_length);
    if (value->kind == VALUE_TYPE) {
        const MitosMirType *descriptor = type_by_id(builder->runtime, value->type_id);
        if (descriptor == NULL) {
            fail(builder->runtime, "cannot format a Type value with an invalid runtime TypeId");
            return 0;
        }
        return builder_append(builder, descriptor->name, descriptor->name_length);
    }
    if (value->kind == VALUE_FUNCTION)
        return builder_append(builder, "<function>", 10);
    if (value->kind == VALUE_SUPERPOSITION) {
        if (!builder_append(builder, "superpose(", 10)) return 0;
        for (index = 0; index < value->arity; ++index) {
            if (index != 0 && !builder_append(builder, ", ", 2)) return 0;
            if (!format_value(builder, value->alternatives[index].value,
                              depth + 1)) return 0;
        }
        return builder_append(builder, ")", 1);
    }
    if (value->kind == VALUE_ARRAY) {
        if (!builder_append(builder, "[", 1)) return 0;
        for (index = 0; index < value->arity; ++index) {
            if (index != 0 && !builder_append(builder, ", ", 2)) return 0;
            if (!format_value(builder, value->fields[index], depth + 1)) return 0;
        }
        return builder_append(builder, "]", 1);
    }
    {
        const MitosMirConstructor *descriptor =
            constructor_by_tag(builder->runtime, value->tag, NULL);
        if (descriptor == NULL || descriptor->arity != value->arity) {
            fail(builder->runtime, "cannot format a constructor with invalid metadata");
            return 0;
        }
        if (!builder_append(builder, descriptor->name, descriptor->name_length)) return 0;
    }
    if (value->arity == 0) return 1;
    if (!builder_append(builder, "(", 1)) return 0;
    for (index = 0; index < value->arity; ++index) {
        if (index != 0 && !builder_append(builder, ", ", 2)) return 0;
        if (!format_value(builder, value->fields[index], depth + 1)) return 0;
    }
    return builder_append(builder, ")", 1);
}

static void finish_build(MirBuild *build) {
    free(build->function_items);
    free(build->function_wrappers);
    free(build->function_forwards);
    free(build->function_protos);
    if (build->context != NULL) {
        if (build->generator_initialized) MIR_gen_finish(build->context);
        MIR_finish(build->context);
    }
    memset(build, 0, sizeof(*build));
}

MitosMirNativeCompileOutcome mitos_mir_compile_method(
    const MitosMirProgram *program,
    uint32_t function_index
) {
    MitosMirNativeCompileOutcome outcome = {NULL, NULL};
    NativeMethod *method = NULL;
    MirBuild build;
    char validation_diagnostic[MITOS_DIAGNOSTIC_BYTES] = {0};
    char mir_diagnostic[MITOS_DIAGNOSTIC_BYTES] = {0};
    jmp_buf mir_jump;
    uint32_t index;

    if (!validate_program(program, validation_diagnostic, sizeof(validation_diagnostic))) {
        outcome.diagnostic = copy_text(validation_diagnostic);
        return outcome;
    }
    if (function_index >= program->function_count
        || function_index == program->main_function) {
        outcome.diagnostic = copy_text("native method compilation target is invalid");
        return outcome;
    }
    memset(&build, 0, sizeof(build));
    build.context = MIR_init();
    if (build.context == NULL) {
        outcome.diagnostic = copy_text("MIR_init failed while compiling a method instance");
        return outcome;
    }
    MIR_set_error_func(build.context, mir_error);
    active_mir_jump = &mir_jump;
    active_mir_diagnostic = mir_diagnostic;
    if (setjmp(mir_jump) != 0) {
        active_mir_jump = NULL;
        active_mir_diagnostic = NULL;
        finish_build(&build);
        outcome.diagnostic = copy_text(
            mir_diagnostic[0] == '\0' ? "MIR rejected a method instance" : mir_diagnostic);
        return outcome;
    }
    MIR_gen_init(build.context);
    build.generator_initialized = 1;
    MIR_gen_set_optimize_level(build.context, 1);
    if (!build_mir(program, &build)) {
        active_mir_jump = NULL;
        active_mir_diagnostic = NULL;
        finish_build(&build);
        outcome.diagnostic = copy_text("out of memory while compiling a MIR method instance");
        return outcome;
    }
    MIR_load_module(build.context, build.module);
    for (index = 0; index < MITOS_HELPER_COUNT; ++index)
        MIR_load_external(build.context, helper_names[index], helper_addresses[index]);
    MIR_load_external(build.context, "mitos_rt_enter", (void *) rt_enter);
    MIR_load_external(build.context, "mitos_rt_leave", (void *) rt_leave);
    MIR_load_external(build.context, "mitos_rt_is_false", (void *) rt_is_false);
    MIR_link(build.context, MIR_set_gen_interface, NULL);
    method = (NativeMethod *) calloc(1, sizeof(*method));
    if (method == NULL) {
        active_mir_jump = NULL;
        active_mir_diagnostic = NULL;
        finish_build(&build);
        outcome.diagnostic = copy_text("out of memory while retaining native method code");
        return outcome;
    }
    method->wrapper = (NativeWrapper) MIR_gen(
        build.context, build.function_wrappers[function_index]);
    method->arity = program->functions[function_index].parameter_count;
    if (method->wrapper == NULL) {
        free(method);
        active_mir_jump = NULL;
        active_mir_diagnostic = NULL;
        finish_build(&build);
        outcome.diagnostic = copy_text("MIR_gen returned no method-instance entry point");
        return outcome;
    }
    method->build = build;
    active_mir_jump = NULL;
    active_mir_diagnostic = NULL;
    outcome.native_result = method;
    outcome.diagnostic = copy_text("");
    return outcome;
}

MitosMirOutcome mitos_mir_execute(const MitosMirProgram *program) {
    Runtime runtime;
    MirBuild build;
    TextBuilder builder;
    char validation_diagnostic[MITOS_DIAGNOSTIC_BYTES] = {0};
    char mir_diagnostic[MITOS_DIAGNOSTIC_BYTES] = {0};
    jmp_buf mir_jump;
    typedef int64_t (*MainFunction)(void);
    MainFunction main_function = NULL;
    Value *result_value = NULL;
    MitosMirOutcome outcome = {MITOS_MIR_ERROR, 0, NULL, NULL};
    uint32_t index;

    if (!validate_program(program, validation_diagnostic, sizeof(validation_diagnostic)))
        return outcome_error(validation_diagnostic);

    memset(&runtime, 0, sizeof(runtime));
    memset(&build, 0, sizeof(build));
    memset(&builder, 0, sizeof(builder));
    runtime.program = program;
    runtime.nullary_values =
        (Value **) calloc(program->constructor_count, sizeof(*runtime.nullary_values));
    if (runtime.nullary_values == NULL)
        return outcome_error("out of memory while initializing native constructors");
    runtime.function_wrappers = (void **) calloc(
        program->function_count, sizeof(*runtime.function_wrappers));
    if (runtime.function_wrappers == NULL) {
        runtime_free(&runtime);
        return outcome_error("out of memory while initializing parallel MIR wrappers");
    }
    builder.runtime = &runtime;

    build.context = MIR_init();
    if (build.context == NULL) {
        runtime_free(&runtime);
        return outcome_error("MIR_init failed");
    }
    MIR_set_error_func(build.context, mir_error);
    active_mir_jump = &mir_jump;
    active_mir_diagnostic = mir_diagnostic;
    if (setjmp(mir_jump) != 0) {
        active_mir_jump = NULL;
        active_mir_diagnostic = NULL;
        finish_build(&build);
        runtime_free(&runtime);
        return outcome_error(mir_diagnostic[0] == '\0' ? "MIR rejected generated code"
                                                        : mir_diagnostic);
    }

    MIR_gen_init(build.context);
    build.generator_initialized = 1;
    MIR_gen_set_optimize_level(build.context, 1);
    if (!build_mir(program, &build)) {
        active_mir_jump = NULL;
        active_mir_diagnostic = NULL;
        finish_build(&build);
        runtime_free(&runtime);
        return outcome_error("out of memory while constructing MIR");
    }
    MIR_load_module(build.context, build.module);
    for (index = 0; index < MITOS_HELPER_COUNT; ++index)
        MIR_load_external(build.context, helper_names[index], helper_addresses[index]);
    MIR_load_external(build.context, "mitos_rt_enter", (void *) rt_enter);
    MIR_load_external(build.context, "mitos_rt_leave", (void *) rt_leave);
    MIR_load_external(build.context, "mitos_rt_is_false", (void *) rt_is_false);
    MIR_link(build.context, MIR_set_gen_interface, NULL);
    for (index = 0; index < program->function_count; ++index) {
        runtime.function_wrappers[index] = MIR_gen(
            build.context, build.function_wrappers[index]);
        if (runtime.function_wrappers[index] == NULL) {
            snprintf(mir_diagnostic, sizeof(mir_diagnostic),
                     "MIR_gen returned no parallel wrapper for function %u", index);
            break;
        }
    }
    if (mir_diagnostic[0] != '\0') {
        active_mir_jump = NULL;
        active_mir_diagnostic = NULL;
        finish_build(&build);
        runtime_free(&runtime);
        return outcome_error(mir_diagnostic);
    }
    main_function = (MainFunction) MIR_gen(build.context,
                                           build.function_items[program->main_function]);
    if (main_function == NULL) {
        snprintf(mir_diagnostic, sizeof(mir_diagnostic), "MIR_gen returned no main entry point");
    } else {
        active_runtime = &runtime;
        result_value = as_value(main_function());
        active_runtime = NULL;
    }
    active_mir_jump = NULL;
    active_mir_diagnostic = NULL;

    if (mir_diagnostic[0] != '\0') {
        outcome = outcome_error(mir_diagnostic);
    } else if (runtime.diagnostic[0] != '\0') {
        outcome = outcome_error(runtime.diagnostic);
    } else if (runtime.call_depth != 0) {
        outcome = outcome_error("native call-depth accounting did not return to zero");
    } else if (!format_value(&builder, result_value, 0)) {
        outcome = outcome_error(runtime.diagnostic[0] == '\0'
                                    ? "native result formatting failed"
                                    : runtime.diagnostic);
    } else {
        if (builder.data == NULL) builder.data = copy_text("");
        outcome.status = MITOS_MIR_NATIVE;
        outcome.result = builder.data;
        outcome.diagnostic = copy_text("");
        builder.data = NULL;
        if (outcome.result == NULL || outcome.diagnostic == NULL) {
            mitos_mir_outcome_free(&outcome);
            outcome = outcome_error("out of memory while returning the native result");
        }
    }

    free(builder.data);
    runtime_free(&runtime);
    finish_build(&build);
    return outcome;
}