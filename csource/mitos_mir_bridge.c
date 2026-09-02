#include "mitos_mir_bridge.h"
#include <stdarg.h>

#include "mir-gen.h"
#include "mir.h"

#include <inttypes.h>
#include <limits.h>
#include <setjmp.h>
#include <stdatomic.h>
#include <stdio.h>
#include <threads.h>
#include <stdlib.h>
#include <string.h>

#define MITOS_MAX_FUNCTIONS 65536u
#define MITOS_MAX_CONSTRUCTORS 4096u
#define MITOS_MAX_TYPES 16384u
#define MITOS_MAX_EFFECT_OPERATIONS 1000000u
#define MITOS_MAX_INSTRUCTIONS 1000000u
#define MITOS_MAX_REGISTERS 65536u
#define MITOS_MAX_TOTAL_REGISTERS 1000000u
#define MITOS_MAX_EMITTED_INSTRUCTIONS 8000000u
#define MITOS_MAX_VALIDATION_STATE_BYTES (64u * 1024u * 1024u)
#define MITOS_MAX_OPERANDS 4000000u
#define MITOS_MAX_STRINGS 1000000u
#define MITOS_MAX_MATCH_ARMS 1000000u
#define MITOS_MAX_ARITY 1024u
#define MITOS_MAX_CALL_DEPTH 1024u
#define MITOS_MAX_CALL_FUEL 1000000u
#define MITOS_MAX_ALLOCATIONS 1000000u
#define MITOS_MAX_ALLOCATION_BYTES (64u * 1024u * 1024u)
#define MITOS_MAX_VALUE_DEPTH 1024u
#define MITOS_MAX_FORMAT_BYTES (1024u * 1024u)
#define MITOS_DIAGNOSTIC_BYTES 512u
#define MITOS_MAX_ALTERNATIVES 65536u
#define MITOS_MAX_SPANS 1000000u
#define MITOS_MAX_SOURCE_ORDER 1000000u
#define MITOS_MAX_ASSIGNMENTS 1024u
#define MITOS_HELPER_COUNT 33u
_Static_assert(sizeof(MitosMirHostDisposition) == 4,
               "MitosMirHostDisposition ABI drift");
_Static_assert(sizeof(MitosMirFunction) == 16, "MitosMirFunction ABI drift");
_Static_assert(sizeof(MitosMirInstruction) == 32, "MitosMirInstruction ABI drift");
_Static_assert(sizeof(MitosMirConstructor) == 32, "MitosMirConstructor ABI drift");
_Static_assert(sizeof(MitosMirType) == 40, "MitosMirType ABI drift");
_Static_assert(sizeof(MitosMirString) == 24, "MitosMirString ABI drift");
_Static_assert(sizeof(MitosMirLayout) == 48, "MitosMirLayout ABI drift");
_Static_assert(sizeof(MitosMirEffectOperation) == 32, "MitosMirEffectOperation ABI drift");
_Static_assert(sizeof(MitosMirMatchArm) == 8, "MitosMirMatchArm ABI drift");
_Static_assert(sizeof(MitosMirSpan) == 48, "MitosMirSpan ABI drift");
_Static_assert(sizeof(MitosMirProgram) == 192, "MitosMirProgram ABI drift");
_Static_assert(sizeof(MitosMirOutcome) == 72, "MitosMirOutcome ABI drift");


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

typedef struct ParallelJob ParallelJob;
typedef struct HostHelperEntry HostHelperEntry;
typedef struct EffectOccurrenceScope EffectOccurrenceScope;
typedef struct EffectInstanceEntry EffectInstanceEntry;
typedef enum ParallelJobStartState {
    PARALLEL_JOB_STARTING = 0,
    PARALLEL_JOB_THREADED = 1,
    PARALLEL_JOB_INLINE_RUNNING = 2,
    PARALLEL_JOB_INLINE_DONE = 3
} ParallelJobStartState;

typedef struct ExecutionControl {
    mtx_t mutex;
    cnd_t completed;
    ParallelJob *jobs;
    ParallelJob *jobs_tail;
    _Atomic uint32_t active_workers;
    uint32_t max_workers;
    int initialized;
    int join_failed;
    _Atomic size_t allocation_count;
    _Atomic size_t allocation_bytes;
    _Atomic uint64_t call_fuel;
    int parallel_replay_done;
    uint64_t next_job_order;
} ExecutionControl;

typedef struct Runtime {
    const MitosMirProgram *program;
    MitosMirRuntime *host_runtime;
    uint64_t program_cookie;
    Allocation *allocations;
    Allocation *allocation_tail;
    Value **nullary_values;
    HostHelperEntry *host_helpers;
    size_t host_helper_count;
    size_t allocation_count;
    uint64_t call_fuel_count;
    size_t allocation_bytes;
    size_t nullary_allocation_bytes;
    uint32_t call_depth;
    void **function_wrappers;
    uint32_t *constructor_index;
    size_t constructor_index_capacity;
    uint32_t *unary_type_index;
    size_t unary_type_index_capacity;
    EffectInstanceEntry *effect_instance_index;
    size_t effect_instance_index_capacity;
    ExecutionControl *execution;
    uint64_t source_order;
    EffectOccurrenceScope **effect_occurrence_buckets;
    size_t effect_occurrence_capacity;
    size_t effect_occurrence_count;
    EffectOccurrenceScope *active_effect_occurrence_scope;
    unsigned owns_function_wrappers : 1;
    unsigned owns_indexes : 1;
    unsigned owns_nullary_values : 1;
    unsigned is_parallel_worker : 1;
    unsigned budget_exhausted : 1;
    MitosMirSpan diagnostic_span;
    char diagnostic[MITOS_DIAGNOSTIC_BYTES];
} Runtime;

struct EffectOccurrenceScope {
    EffectOccurrenceScope *next;
    uint64_t source_order;
    uint64_t next_occurrence;
};

struct EffectInstanceEntry {
    uint32_t instance;
    uint32_t constructor;
};

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
    void *scratch_arguments;
    void *scratch_argument_names;
    void *scratch_registers;
    void *scratch_labels;
    void *scratch_call_ops;
    int generator_initialized;
} MirBuild;

typedef int64_t (*NativeWrapper)(int64_t *, uint32_t);



#define MITOS_MAX_HOST_HELPERS 4096u
#define MITOS_MAX_PROGRAM_ENROLLMENTS 4096u
#define MITOS_REGISTRY_GATE_CLOSED (UINT64_C(1) << 63)
#define MITOS_REGISTRY_GATE_COUNT (MITOS_REGISTRY_GATE_CLOSED - UINT64_C(1))
typedef struct ProgramEnrollment {
    const MitosMirProgram *program;
    uint64_t claimed_identity;
    uint64_t cookie;
    size_t active_executions;
} ProgramEnrollment;

struct HostHelperEntry {
    uint64_t program_cookie;
    uint32_t dense_handle;
    uint32_t effect;
    uint32_t operation;
    uint32_t arity;
    uint32_t result_type;
    uint32_t abi_major;
    uint32_t abi_minor;
    uint32_t flags;
    MitosMirHostHandler handler;
    void *context;
};

struct MitosMirRuntime {
    mtx_t mutex;
    HostHelperEntry host_helpers[MITOS_MAX_HOST_HELPERS];
    ProgramEnrollment enrollments[MITOS_MAX_PROGRAM_ENROLLMENTS];
    size_t host_helper_count;
    size_t enrollment_count;
    uint64_t next_program_cookie;
    uint64_t generation;
    size_t active_executions;
    _Atomic uint64_t entrant_gate;
    int shutting_down;
};


static int registry_enter(MitosMirRuntime *runtime) {
    uint64_t current;
    if (runtime == NULL) return 0;
    current = atomic_load(&runtime->entrant_gate);
    for (;;) {
        if ((current & MITOS_REGISTRY_GATE_CLOSED) != 0
            || (current & MITOS_REGISTRY_GATE_COUNT) == MITOS_REGISTRY_GATE_COUNT) return 0;
        if (atomic_compare_exchange_weak(
                &runtime->entrant_gate, &current, current + UINT64_C(1))) return 1;
    }
}

static void registry_leave(MitosMirRuntime *runtime) {
    (void) atomic_fetch_sub(&runtime->entrant_gate, UINT64_C(1));
}

static int registry_close(MitosMirRuntime *runtime) {
    uint64_t current;
    if (runtime == NULL) return 0;
    current = atomic_load(&runtime->entrant_gate);
    for (;;) {
        if ((current & MITOS_REGISTRY_GATE_CLOSED) != 0
            || (current & MITOS_REGISTRY_GATE_COUNT) != 0) return 0;
        if (atomic_compare_exchange_weak(
                &runtime->entrant_gate, &current,
                current | MITOS_REGISTRY_GATE_CLOSED)) return 1;
    }
}

static void registry_reopen(MitosMirRuntime *runtime) {
    atomic_store(&runtime->entrant_gate, UINT64_C(0));
}

static int registry_lock(MitosMirRuntime *runtime) {
    return runtime != NULL && mtx_lock(&runtime->mutex) == thrd_success;
}

static const MitosMirEffectOperation *host_operation(
    const MitosMirProgram *program,
    uint32_t dense_handle
) {
    const MitosMirEffectOperation *operation;
    if (program == NULL || program->program_identity == 0
        || dense_handle >= program->effect_operation_count
        || program->effect_operations == NULL) return NULL;
    operation = &program->effect_operations[dense_handle];
    if (operation->dense_handle != dense_handle
        || operation->operation != dense_handle + 1u || operation->effect == 0
        || operation->arity > MITOS_MAX_ARITY
        || operation->result_type == 0 || operation->result_type > program->type_count
        || operation->abi_major != 2u || operation->abi_minor != 0u
        || (operation->flags & MITOS_MIR_EFFECT_EXTERNAL) == 0
        || (operation->flags
            & ~(MITOS_MIR_EFFECT_ORDERED | MITOS_MIR_EFFECT_EXTERNAL)) != 0) return NULL;
    return operation;
}

static ProgramEnrollment *enrollment_by_cookie_unlocked(
    MitosMirRuntime *runtime,
    uint64_t cookie,
    size_t *index_out
) {
    size_t index;
    for (index = 0; index < runtime->enrollment_count; ++index) {
        if (runtime->enrollments[index].cookie != cookie) continue;
        if (index_out != NULL) *index_out = index;
        return &runtime->enrollments[index];
    }
    return NULL;
}

static int cookie_has_helpers_unlocked(
    const MitosMirRuntime *runtime,
    uint64_t cookie
) {
    size_t index;
    for (index = 0; index < runtime->host_helper_count; ++index)
        if (runtime->host_helpers[index].program_cookie == cookie) return 1;
    return 0;
}

static void retire_enrollment_unlocked(
    MitosMirRuntime *runtime,
    uint64_t cookie
) {
    size_t index;
    ProgramEnrollment *enrollment =
        enrollment_by_cookie_unlocked(runtime, cookie, &index);
    if (enrollment == NULL || enrollment->active_executions != 0
        || cookie_has_helpers_unlocked(runtime, cookie)) return;
    --runtime->enrollment_count;
    if (index != runtime->enrollment_count)
        runtime->enrollments[index] = runtime->enrollments[runtime->enrollment_count];
    memset(&runtime->enrollments[runtime->enrollment_count], 0,
           sizeof(runtime->enrollments[0]));
}

static uint64_t program_cookie_unlocked(
    MitosMirRuntime *runtime,
    const MitosMirProgram *program,
    int create
) {
    size_t index;
    if (runtime == NULL || program == NULL || program->program_identity == 0) return 0;
    for (index = 0; index < runtime->enrollment_count; ++index) {
        ProgramEnrollment *enrollment = &runtime->enrollments[index];
        size_t helper;
        if (enrollment->program != program) continue;
        if (enrollment->claimed_identity == program->program_identity)
            return enrollment->cookie;
        if (!create || enrollment->active_executions != 0
            || runtime->next_program_cookie == 0) return 0;
        for (helper = 0; helper < runtime->host_helper_count;) {
            if (runtime->host_helpers[helper].program_cookie != enrollment->cookie) {
                ++helper;
                continue;
            }
            if (helper + 1 < runtime->host_helper_count) {
                memmove(
                    &runtime->host_helpers[helper],
                    &runtime->host_helpers[helper + 1],
                    (runtime->host_helper_count - helper - 1)
                        * sizeof(*runtime->host_helpers)
                );
            }
            --runtime->host_helper_count;
        }
        enrollment->claimed_identity = program->program_identity;
        enrollment->cookie = runtime->next_program_cookie++;
        ++runtime->generation;
        return enrollment->cookie;
    }
    if (!create || runtime->enrollment_count >= MITOS_MAX_PROGRAM_ENROLLMENTS
        || runtime->next_program_cookie == 0) return 0;
    runtime->enrollments[runtime->enrollment_count++] = (ProgramEnrollment) {
        .program = program,
        .claimed_identity = program->program_identity,
        .cookie = runtime->next_program_cookie
    };
    return runtime->next_program_cookie++;
}

static int helper_metadata_equal(
    const HostHelperEntry *entry,
    uint64_t program_cookie,
    const MitosMirEffectOperation *operation
) {
    return entry->program_cookie == program_cookie
        && entry->dense_handle == operation->dense_handle
        && entry->effect == operation->effect
        && entry->operation == operation->operation
        && entry->arity == operation->arity
        && entry->result_type == operation->result_type
        && entry->abi_major == operation->abi_major
        && entry->abi_minor == operation->abi_minor
        && entry->flags == operation->flags;
}
static int host_helper_dense_compare(const void *left, const void *right) {
    uint32_t left_handle = ((const HostHelperEntry *) left)->dense_handle;
    uint32_t right_handle = ((const HostHelperEntry *) right)->dense_handle;
    return left_handle < right_handle ? -1 : left_handle != right_handle;
}

static HostHelperEntry *runtime_host_helper(
    Runtime *runtime,
    uint32_t dense_handle
) {
    size_t low = 0;
    size_t high = runtime == NULL ? 0 : runtime->host_helper_count;
    while (low < high) {
        size_t middle = low + (high - low) / 2u;
        HostHelperEntry *candidate = &runtime->host_helpers[middle];
        if (candidate->dense_handle < dense_handle) {
            low = middle + 1u;
        } else if (candidate->dense_handle > dense_handle) {
            high = middle;
        } else {
            return candidate;
        }
    }
    return NULL;
}


MitosMirRuntime *mitos_mir_runtime_create(void) {
    MitosMirRuntime *runtime = (MitosMirRuntime *) calloc(1, sizeof(*runtime));
    if (runtime == NULL) return NULL;
    if (mtx_init(&runtime->mutex, mtx_plain) != thrd_success) {
        free(runtime);
        return NULL;
    }
    atomic_init(&runtime->entrant_gate, UINT64_C(0));
    runtime->generation = 1;
    runtime->next_program_cookie = 1;
    return runtime;
}

uint32_t mitos_mir_runtime_destroy(MitosMirRuntime *runtime) {
    if (!registry_close(runtime)) return 0;
    if (!registry_lock(runtime)) {
        registry_reopen(runtime);
        return 0;
    }
    if (runtime->shutting_down || runtime->active_executions != 0) {
        mtx_unlock(&runtime->mutex);
        registry_reopen(runtime);
        return 0;
    }
    runtime->shutting_down = 1;
    memset(runtime->host_helpers, 0, sizeof(runtime->host_helpers));
    runtime->host_helper_count = 0;
    memset(runtime->enrollments, 0, sizeof(runtime->enrollments));
    runtime->enrollment_count = 0;
    mtx_unlock(&runtime->mutex);
    mtx_destroy(&runtime->mutex);
    free(runtime);
    return 1;
}

uint32_t mitos_mir_runtime_capabilities(MitosMirRuntime *runtime) {
    uint32_t capabilities = 0;
    if (!registry_enter(runtime)) return 0;
    if (registry_lock(runtime)) {
        if (!runtime->shutting_down) capabilities = MITOS_MIR_CAP_HOST_ABI_2;
        mtx_unlock(&runtime->mutex);
    }
    registry_leave(runtime);
    return capabilities;
}

uint32_t mitos_mir_runtime_snapshot(
    MitosMirRuntime *runtime,
    MitosMirRegistrySnapshot *snapshot
) {
    uint32_t ok = 0;
    if (!registry_enter(runtime)) return 0;
    if (snapshot != NULL && registry_lock(runtime)) {
        if (!runtime->shutting_down) {
            snapshot->generation = runtime->generation;
            snapshot->helper_count = (uint32_t) runtime->host_helper_count;
            snapshot->capabilities = MITOS_MIR_CAP_HOST_ABI_2;
            ok = 1;
        }
        mtx_unlock(&runtime->mutex);
    }
    registry_leave(runtime);
    return ok;
}

uint32_t mitos_mir_runtime_register_host_helper(
    MitosMirRuntime *runtime,
    const MitosMirProgram *program,
    uint32_t dense_handle,
    uint32_t abi_major,
    uint32_t abi_minor,
    MitosMirHostHandler handler,
    void *context
) {
    const MitosMirEffectOperation *operation;
    ProgramEnrollment *enrollment;
    HostHelperEntry entry;
    size_t index;
    size_t enrollment_count_before;
    uint64_t program_cookie = 0;
    uint32_t result = 0;
    if (!registry_enter(runtime)) return 0;
    operation = host_operation(program, dense_handle);
    if (operation == NULL || abi_major != operation->abi_major
        || abi_minor != operation->abi_minor || handler == NULL
        || !registry_lock(runtime)) {
        registry_leave(runtime);
        return 0;
    }
    enrollment_count_before = runtime->enrollment_count;
    if (runtime->shutting_down) goto done;
    program_cookie = program_cookie_unlocked(runtime, program, 1);
    enrollment = program_cookie == 0
        ? NULL : enrollment_by_cookie_unlocked(runtime, program_cookie, NULL);
    if (enrollment == NULL || enrollment->active_executions != 0) goto done;
    entry = (HostHelperEntry) {
        .program_cookie = program_cookie,
        .dense_handle = operation->dense_handle,
        .effect = operation->effect,
        .operation = operation->operation,
        .arity = operation->arity,
        .result_type = operation->result_type,
        .abi_major = abi_major,
        .abi_minor = abi_minor,
        .flags = operation->flags,
        .handler = handler,
        .context = context
    };
    for (index = 0; index < runtime->host_helper_count; ++index) {
        HostHelperEntry *existing = &runtime->host_helpers[index];
        if (existing->program_cookie != program_cookie
            || existing->dense_handle != dense_handle) continue;
        if (!helper_metadata_equal(existing, program_cookie, operation)) goto done;
        *existing = entry;
        ++runtime->generation;
        result = 1;
        goto done;
    }
    if (runtime->host_helper_count < MITOS_MAX_HOST_HELPERS) {
        runtime->host_helpers[runtime->host_helper_count++] = entry;
        ++runtime->generation;
        result = 1;
    }
done:
    if (!result && program_cookie != 0
        && runtime->enrollment_count > enrollment_count_before)
        retire_enrollment_unlocked(runtime, program_cookie);
    mtx_unlock(&runtime->mutex);
    registry_leave(runtime);
    return result;
}

uint32_t mitos_mir_runtime_unregister_host_helper(
    MitosMirRuntime *runtime,
    const MitosMirProgram *program,
    uint32_t dense_handle
) {
    const MitosMirEffectOperation *operation;
    ProgramEnrollment *enrollment;
    size_t index;
    uint64_t program_cookie;
    uint32_t result = 0;
    if (!registry_enter(runtime)) return 0;
    operation = host_operation(program, dense_handle);
    if (operation == NULL || !registry_lock(runtime)) {
        registry_leave(runtime);
        return 0;
    }
    if (runtime->shutting_down) goto done;
    program_cookie = program_cookie_unlocked(runtime, program, 0);
    enrollment = program_cookie == 0
        ? NULL : enrollment_by_cookie_unlocked(runtime, program_cookie, NULL);
    if (enrollment == NULL || enrollment->active_executions != 0) goto done;
    for (index = 0; index < runtime->host_helper_count; ++index) {
        if (!helper_metadata_equal(
                &runtime->host_helpers[index], program_cookie, operation)) continue;
        --runtime->host_helper_count;
        runtime->host_helpers[index] =
            runtime->host_helpers[runtime->host_helper_count];
        memset(&runtime->host_helpers[runtime->host_helper_count], 0,
               sizeof(runtime->host_helpers[0]));
        ++runtime->generation;
        result = 1;
        break;
    }
    if (result) retire_enrollment_unlocked(runtime, program_cookie);
done:
    mtx_unlock(&runtime->mutex);
    registry_leave(runtime);
    return result;
}

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
    MitosMirOutcome outcome = {.status = MITOS_MIR_ERROR};
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


static void fail(Runtime *runtime, const char *format, ...) {
    va_list arguments;
    if (runtime == NULL || runtime->diagnostic[0] != '\0') return;
    va_start(arguments, format);
    vsnprintf(runtime->diagnostic, sizeof(runtime->diagnostic), format, arguments);
    va_end(arguments);
}

static void escape_diagnostic_name(
    char *output,
    size_t capacity,
    const char *name,
    size_t length
) {
    static const char hex_digits[] = "0123456789abcdef";
    size_t input = 0;
    size_t used = 0;
    if (capacity == 0) return;
    while (input < length && used + 1u < capacity) {
        unsigned char byte = (unsigned char) name[input++];
        if (byte < 0x20u || byte == 0x7fu) {
            if (used + 4u >= capacity) break;
            output[used++] = '\\';
            output[used++] = 'x';
            output[used++] = hex_digits[byte >> 4];
            output[used++] = hex_digits[byte & 0x0fu];
        } else if (byte == '\\') {
            if (used + 2u >= capacity) break;
            output[used++] = '\\';
            output[used++] = '\\';
        } else {
            output[used++] = (char) byte;
        }
    }
    output[used] = '\0';
}

static int execution_budget_reserve(Runtime *runtime, size_t size) {
    ExecutionControl *control;
    size_t count;
    size_t bytes;
    if (runtime == NULL || runtime->diagnostic[0] != '\0') return 0;
    control = runtime->execution;
    if (control == NULL || !control->initialized) {
        fail(runtime, "native execution allocation budget is unavailable");
        return 0;
    }
    if (size > MITOS_MAX_ALLOCATION_BYTES) {
        runtime->budget_exhausted = 1;
        fail(runtime, "native value allocation byte limit exceeded");
        return 0;
    }
    count = atomic_load_explicit(
        &control->allocation_count, memory_order_relaxed);
    for (;;) {
        if (count >= MITOS_MAX_ALLOCATIONS) {
            runtime->budget_exhausted = 1;
            fail(runtime, "native value allocation count limit exceeded");
            return 0;
        }
        if (atomic_compare_exchange_weak_explicit(
                &control->allocation_count, &count, count + 1u,
                memory_order_acq_rel, memory_order_relaxed)) break;
    }
    bytes = atomic_load_explicit(
        &control->allocation_bytes, memory_order_relaxed);
    for (;;) {
        if (bytes > MITOS_MAX_ALLOCATION_BYTES - size) {
            runtime->budget_exhausted = 1;
            (void) atomic_fetch_sub_explicit(
                &control->allocation_count, 1u, memory_order_release);
            fail(runtime, "native value allocation byte limit exceeded");
            return 0;
        }
        if (atomic_compare_exchange_weak_explicit(
                &control->allocation_bytes, &bytes, bytes + size,
                memory_order_acq_rel, memory_order_relaxed)) return 1;
    }
}

static void execution_budget_release_control(
    ExecutionControl *control,
    size_t count,
    size_t bytes
) {
    if (control == NULL || !control->initialized || count == 0) return;
    (void) atomic_fetch_sub_explicit(
        &control->allocation_bytes, bytes, memory_order_release);
    (void) atomic_fetch_sub_explicit(
        &control->allocation_count, count, memory_order_release);
}

static void execution_budget_release(
    Runtime *runtime,
    size_t count,
    size_t bytes
) {
    if (runtime == NULL) return;
    execution_budget_release_control(runtime->execution, count, bytes);
}

static int runtime_allocate_nullaries(Runtime *runtime) {
    size_t bytes;
    if (runtime == NULL || runtime->program == NULL) {
        fail(runtime, "native nullary constructor table is unavailable");
        return 0;
    }
    bytes = (size_t) runtime->program->constructor_count * sizeof(Value *);
    if (runtime->program->constructor_count != 0
        && bytes / sizeof(Value *) != runtime->program->constructor_count) {
        fail(runtime, "native nullary constructor table is too large");
        return 0;
    }
    if (!execution_budget_reserve(runtime, bytes)) return 0;
    runtime->nullary_values = (Value **) calloc(
        runtime->program->constructor_count, sizeof(Value *));
    if (runtime->nullary_values == NULL) {
        execution_budget_release(runtime, 1, bytes);
        fail(runtime, "out of memory while initializing native constructors");
        return 0;
    }
    runtime->owns_nullary_values = 1;
    runtime->nullary_allocation_bytes = bytes;
    return 1;
}

static void *runtime_allocate(Runtime *runtime, size_t size) {
    Allocation *allocation;
    if (!execution_budget_reserve(runtime, size)) return NULL;
    allocation = (Allocation *) calloc(1, sizeof(*allocation) + size);
    if (allocation == NULL) {
        execution_budget_release(runtime, 1, size);
        fail(runtime, "out of memory while allocating a native value");
        return NULL;
    }
    allocation->size = size;
    allocation->next = runtime->allocations;
    runtime->allocations = allocation;
    if (runtime->allocation_tail == NULL) runtime->allocation_tail = allocation;
    runtime->allocation_count++;
    runtime->allocation_bytes += size;
    return allocation + 1;
}

static void runtime_free(Runtime *runtime) {
    Allocation *allocation = runtime->allocations;
    size_t allocation_count = runtime->allocation_count;
    size_t allocation_bytes = runtime->allocation_bytes;
    if (runtime->owns_nullary_values && runtime->nullary_values != NULL) {
        ++allocation_count;
        allocation_bytes += runtime->nullary_allocation_bytes;
    }
    while (allocation != NULL) {
        Allocation *next = allocation->next;
        free(allocation);
        allocation = next;
    }
    runtime->allocations = NULL;
    runtime->allocation_tail = NULL;
    runtime->allocation_count = 0;
    runtime->allocation_bytes = 0;
    if (runtime->owns_nullary_values) free(runtime->nullary_values);
    runtime->nullary_values = NULL;
    runtime->nullary_allocation_bytes = 0;
    runtime->owns_nullary_values = 0;
    runtime->host_helpers = NULL;
    runtime->host_helper_count = 0;
    if (runtime->owns_function_wrappers) free(runtime->function_wrappers);
    runtime->function_wrappers = NULL;
    if (runtime->owns_indexes) {
        free(runtime->constructor_index);
        free(runtime->unary_type_index);
        free(runtime->effect_instance_index);
    }
    runtime->constructor_index = NULL;
    runtime->unary_type_index = NULL;
    runtime->effect_instance_index = NULL;
    execution_budget_release(runtime, allocation_count, allocation_bytes);
}

static size_t metadata_hash(uint64_t value, size_t mask) {
    value ^= value >> 33;
    value *= UINT64_C(0xff51afd7ed558ccd);
    value ^= value >> 33;
    return (size_t) value & mask;
}

static size_t index_capacity(uint32_t count) {
    size_t capacity = 8;
    while (capacity < (size_t) count * 2u) capacity *= 2u;
    return capacity;
}

static int runtime_initialize_indexes(Runtime *runtime) {
    uint32_t index;
    uint32_t effect_keys = runtime->program->effect_operation_count
        + runtime->program->instruction_count;
    runtime->constructor_index_capacity =
        index_capacity(runtime->program->constructor_count);
    runtime->unary_type_index_capacity =
        index_capacity(runtime->program->type_count);
    runtime->effect_instance_index_capacity = index_capacity(effect_keys);
    runtime->owns_indexes = 1;
    runtime->constructor_index = (uint32_t *) calloc(
        runtime->constructor_index_capacity, sizeof(uint32_t));
    runtime->unary_type_index = (uint32_t *) calloc(
        runtime->unary_type_index_capacity, sizeof(uint32_t));
    runtime->effect_instance_index = (EffectInstanceEntry *) calloc(
        runtime->effect_instance_index_capacity, sizeof(EffectInstanceEntry));
    if (runtime->constructor_index == NULL || runtime->unary_type_index == NULL
        || runtime->effect_instance_index == NULL)
        return 0;
    for (index = 0; index < runtime->program->constructor_count; ++index) {
        size_t slot = metadata_hash(
            runtime->program->constructors[index].tag,
            runtime->constructor_index_capacity - 1u);
        while (runtime->constructor_index[slot] != 0)
            slot = (slot + 1u) & (runtime->constructor_index_capacity - 1u);
        runtime->constructor_index[slot] = index + 1u;
    }
    for (index = 0; index < runtime->program->type_count; ++index) {
        const MitosMirType *type = &runtime->program->types[index];
        uint64_t key = ((uint64_t) type->constructor << 32) | type->argument;
        size_t slot;
        if (type->constructor == 0 || type->argument == 0) continue;
        slot = metadata_hash(key, runtime->unary_type_index_capacity - 1u);
        while (runtime->unary_type_index[slot] != 0) {
            const MitosMirType *existing = &runtime->program->types[
                runtime->unary_type_index[slot] - 1u];
            if (existing->constructor == type->constructor
                && existing->argument == type->argument) break;
            slot = (slot + 1u) & (runtime->unary_type_index_capacity - 1u);
        }
        if (runtime->unary_type_index[slot] == 0)
            runtime->unary_type_index[slot] = index + 1u;
    }
    for (index = 0; index < runtime->program->effect_operation_count
         + runtime->program->instruction_count; ++index) {
        uint32_t instance;
        uint32_t constructor;
        size_t slot;
        if (index < runtime->program->effect_operation_count) {
            instance = runtime->program->effect_operations[index].effect;
            constructor = instance;
        } else {
            const MitosMirInstruction *instruction =
                &runtime->program->instructions[
                    index - runtime->program->effect_operation_count];
            if (instruction->opcode != MITOS_MIR_EXTERNAL_EFFECT) continue;
            instance = (uint32_t) ((uint64_t) instruction->immediate >> 32);
            constructor =
                runtime->program->effect_operations[instruction->a].effect;
        }
        slot = metadata_hash(instance,
                             runtime->effect_instance_index_capacity - 1u);
        while (runtime->effect_instance_index[slot].instance != 0
               && runtime->effect_instance_index[slot].instance != instance)
            slot = (slot + 1u)
                & (runtime->effect_instance_index_capacity - 1u);
        if (runtime->effect_instance_index[slot].instance != 0
            && runtime->effect_instance_index[slot].constructor != constructor)
            return 0;
        runtime->effect_instance_index[slot] =
            (EffectInstanceEntry) {instance, constructor};
    }
    return 1;
}

static int runtime_effect_instance_matches(
    const Runtime *runtime,
    uint32_t instance,
    uint32_t constructor
) {
    size_t slot, start;
    if (runtime == NULL || instance == 0 || constructor == 0
        || runtime->effect_instance_index == NULL
        || runtime->effect_instance_index_capacity == 0) return 0;
    slot = metadata_hash(instance,
                         runtime->effect_instance_index_capacity - 1u);
    start = slot;
    do {
        const EffectInstanceEntry *entry =
            &runtime->effect_instance_index[slot];
        if (entry->instance == 0) return 0;
        if (entry->instance == instance)
            return entry->constructor == constructor;
        slot = (slot + 1u)
            & (runtime->effect_instance_index_capacity - 1u);
    } while (slot != start);
    return 0;
}

static const MitosMirConstructor *constructor_by_tag(const Runtime *runtime, uint32_t tag,
                                                     uint32_t *index_out) {
    size_t slot, start;
    if (runtime->constructor_index == NULL
        || runtime->constructor_index_capacity == 0) return NULL;
    slot = metadata_hash(tag, runtime->constructor_index_capacity - 1u);
    start = slot;
    do {
        uint32_t encoded = runtime->constructor_index[slot];
        if (encoded == 0) return NULL;
        if (runtime->program->constructors[encoded - 1u].tag == tag) {
            if (index_out != NULL) *index_out = encoded - 1u;
            return &runtime->program->constructors[encoded - 1u];
        }
        slot = (slot + 1u) & (runtime->constructor_index_capacity - 1u);
    } while (slot != start);
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

static int constructor_runtime_type_matches(
    const MitosMirProgram *program,
    const MitosMirConstructor *descriptor,
    uint32_t runtime_type
) {
    const MitosMirType *type;
    if (program == NULL || descriptor == NULL || runtime_type == 0
        || runtime_type > program->type_count
        || descriptor->runtime_type == 0
        || descriptor->runtime_type > program->type_count) return 0;
    if (runtime_type == descriptor->runtime_type) return 1;
    type = &program->types[runtime_type - 1u];
    return type->id == runtime_type && type->kind == 2u
        && type->constructor == descriptor->runtime_type;
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
    if (!constructor_runtime_type_matches(
            runtime->program, descriptor, runtime_type)) {
        fail(runtime,
             "constructor tag %u received a runtime TypeId outside its descriptor",
             tag);
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
        value->fields = (Value **) runtime_allocate(runtime, (size_t) arity * sizeof(Value *));
        if (value->fields == NULL) return NULL;
    }
    if (arity == 0 && runtime_type == descriptor->runtime_type)
        runtime->nullary_values[descriptor_index] = value;
    return value;
}

static int runtime_initialize_nullaries(Runtime *runtime) {
    uint32_t index;
    if (runtime == NULL || runtime->nullary_values == NULL) return 0;
    for (index = 0; index < runtime->program->constructor_count; ++index) {
        const MitosMirConstructor *constructor =
            &runtime->program->constructors[index];
        if (constructor->arity == 0
            && new_constructor(runtime, constructor->tag, 0,
                               constructor->runtime_type) == NULL)
            return 0;
    }
    return 1;
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
    if (length == SIZE_MAX) {
        fail(runtime, "native String byte size overflows");
        return NULL;
    }
    value = (Value *) runtime_allocate(runtime, sizeof(*value));
    owned = (char *) runtime_allocate(runtime, length + 1u);
    if (value == NULL || owned == NULL) return NULL;
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
    uint64_t key = ((uint64_t) constructor << 32) | argument;
    size_t slot, start;
    if (runtime->unary_type_index == NULL
        || runtime->unary_type_index_capacity == 0) goto missing;
    slot = metadata_hash(key, runtime->unary_type_index_capacity - 1u);
    start = slot;
    do {
        uint32_t encoded = runtime->unary_type_index[slot];
        const MitosMirType *type;
        if (encoded == 0) break;
        type = &runtime->program->types[encoded - 1u];
        if (type->constructor == constructor && type->argument == argument)
            return type->id;
        slot = (slot + 1u) & (runtime->unary_type_index_capacity - 1u);
    } while (slot != start);
missing:
    fail(runtime, "native MIR lacks runtime metadata for unary TypeId %u of %u",
         constructor, argument);
    return 0;
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
            if (alternatives[index].assignments[assignment].origin == 0) {
                fail(runtime, "superposition branch assignment has no stable origin");
                return NULL;
            }
            if (assignment != 0
                && alternatives[index].assignments[assignment - 1u].origin
                    >= alternatives[index].assignments[assignment].origin) {
                fail(runtime,
                     "superposition branch assignments must have unique sorted origins");
                return NULL;
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
    uint32_t left_index = 0, right_index = 0, count = 0;
    if (left_count > MITOS_MAX_ASSIGNMENTS || right_count > MITOS_MAX_ASSIGNMENTS) {
        fail(runtime, "superposition assignment count exceeds the resource limit");
        return -1;
    }
    while (left_index < left_count || right_index < right_count) {
        if (left_index < left_count && right_index < right_count
            && left[left_index].origin == right[right_index].origin) {
            if (left[left_index].branch != right[right_index].branch) return 0;
            ++left_index;
            ++right_index;
        } else if (right_index >= right_count
                   || (left_index < left_count
                       && left[left_index].origin < right[right_index].origin)) {
            ++left_index;
        } else {
            ++right_index;
        }
        if (++count > MITOS_MAX_ASSIGNMENTS) {
            fail(runtime, "superposition assignment count exceeds the resource limit");
            return -1;
        }
    }
    merged = count == 0 ? NULL : (OriginAssignment *) runtime_allocate(
        runtime, (size_t) count * sizeof(*merged));
    if (count != 0 && merged == NULL) return -1;
    left_index = 0;
    right_index = 0;
    count = 0;
    while (left_index < left_count || right_index < right_count) {
        if (left_index < left_count && right_index < right_count
            && left[left_index].origin == right[right_index].origin) {
            merged[count++] = left[left_index++];
            ++right_index;
        } else if (right_index >= right_count
                   || (left_index < left_count
                       && left[left_index].origin < right[right_index].origin)) {
            merged[count++] = left[left_index++];
        } else {
            merged[count++] = right[right_index++];
        }
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
                if (left->integer == INT64_MIN && right->integer == -1)
                    return new_integer(runtime, 0);
                return new_integer(runtime, left->integer % right->integer);
        }
    }
    if (operation != BINARY_LIFT_EQUAL
        && (left->kind != VALUE_INTEGER || right->kind != VALUE_INTEGER
            || left->type_id != runtime->program->i64_type
            || right->type_id != runtime->program->i64_type)) {
        fail(runtime, "ordered comparison requires two I64 operands");
        return NULL;
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
    const MitosMirType *type;
    if (runtime == NULL || runtime->program == NULL
        || id == 0 || id > runtime->program->type_count) return NULL;
    type = &runtime->program->types[id - 1u];
    return type->id == id ? type : NULL;
}

static int runtime_subtype(const Runtime *runtime, uint32_t actual, uint32_t expected) {
    const MitosMirType *actual_type;
    const MitosMirType *expected_type;
    uint32_t actual_constructor;
    uint32_t expected_constructor;
    uint32_t actual_argument;
    uint32_t expected_argument;
    uint32_t depth = 0;
    if (runtime == NULL || runtime->program == NULL) return 0;
    if (actual == 2u || expected == 1u || actual == expected) return 1;
    actual_type = type_by_id(runtime, actual);
    expected_type = type_by_id(runtime, expected);
    if (actual_type == NULL || expected_type == NULL) return 0;
    actual_constructor = actual_type->kind == 2u
        ? actual_type->constructor : actual;
    expected_constructor = expected_type->kind == 2u
        ? expected_type->constructor : expected;
    actual_argument = actual_type->kind == 2u ? actual_type->argument : 0;
    expected_argument = expected_type->kind == 2u
        ? expected_type->argument : 0;
    while (actual_constructor != 0
           && depth++ < runtime->program->type_count) {
        const MitosMirType *descriptor;
        if (actual_constructor == expected_constructor)
            return expected_argument == 0
                || actual_argument == expected_argument;
        descriptor = type_by_id(runtime, actual_constructor);
        if (descriptor == NULL) return 0;
        actual_constructor = descriptor->parent;
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

typedef struct TypeAssertContext {
    uint32_t expected;
    uint32_t source_span;
} TypeAssertContext;

static Value *type_assert_concrete(Runtime *runtime, Value *value,
                                   uint32_t expected, uint32_t source_span) {
    if (!valid_value(runtime, value)) return NULL;
    if (!runtime_subtype(runtime, value->type_id, expected)) {
        const MitosMirType *actual_type = type_by_id(runtime, value->type_id);
        const MitosMirType *expected_type = type_by_id(runtime, expected);
        char actual_name[224];
        char expected_name[224];
        if (source_span != 0 && source_span <= runtime->program->span_count)
            runtime->diagnostic_span = runtime->program->spans[source_span - 1u];
        if (expected_type == NULL)
            memcpy(expected_name, "<invalid>", sizeof("<invalid>"));
        else
            escape_diagnostic_name(
                expected_name, sizeof(expected_name),
                expected_type->name, expected_type->name_length);
        if (actual_type == NULL)
            memcpy(actual_name, "<invalid>", sizeof("<invalid>"));
        else
            escape_diagnostic_name(
                actual_name, sizeof(actual_name),
                actual_type->name, actual_type->name_length);
        fail(runtime, "type assertion failed: expected %s, received %s",
             expected_name, actual_name);
        return NULL;
    }
    return value;
}

static Value *type_assert_lift_callback(Runtime *runtime, Value **arguments,
                                        uint32_t count, void *raw_context) {
    TypeAssertContext *context = (TypeAssertContext *) raw_context;
    if (count != 1) {
        fail(runtime, "lifted type assertion has invalid arity");
        return NULL;
    }
    return type_assert_concrete(
        runtime, arguments[0], context->expected, context->source_span);
}

static int64_t rt_type_assert(int64_t raw, int64_t expected_raw,
                              int64_t result_type_raw, int64_t source_span_raw) {
    Value *arguments[1] = {as_value(raw)};
    TypeAssertContext context;
    uint32_t result_type;
    if (expected_raw <= 0
        || (uint64_t) expected_raw > active_runtime->program->type_count) {
        fail(active_runtime, "TypeError: assertion references an invalid TypeId");
        return 0;
    }
    if (source_span_raw < 0
        || (uint64_t) source_span_raw > active_runtime->program->span_count) {
        fail(active_runtime, "TypeError: assertion references an invalid source span");
        return 0;
    }
    context.expected = (uint32_t) expected_raw;
    context.source_span = (uint32_t) source_span_raw;
    if (result_type_raw == 0)
        return from_value(type_assert_concrete(
            active_runtime, arguments[0], context.expected, context.source_span));
    result_type = result_type_raw > 0 && (uint64_t) result_type_raw <= UINT32_MAX
        ? (uint32_t) result_type_raw : 0;
    return from_value(lift_values(active_runtime, arguments, 1, result_type,
                                  type_assert_lift_callback, &context));
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
        fail(active_runtime, "native call argument count is out of range");
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
        fail(active_runtime, "native call argument initialization is invalid");
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

typedef struct NativeClosure {
    uint32_t function_index;
    uint32_t parameter_count;
    uint32_t capture_count;
    Value **captures;
} NativeClosure;

typedef struct ParallelCloneEntry {
    const Value *source;
    Value *copy;
} ParallelCloneEntry;

typedef struct ParallelCloneContext {
    Runtime *snapshot;
    Runtime *source;
    ParallelCloneEntry *entries;
    size_t entry_count;
    size_t entry_capacity;
} ParallelCloneContext;

static Value *parallel_clone_lookup(
    const ParallelCloneContext *context,
    const Value *source
) {
    size_t slot, start;
    if (context->entry_capacity == 0) return NULL;
    slot = metadata_hash(
        (uint64_t) (uintptr_t) source, context->entry_capacity - 1u);
    start = slot;
    do {
        const ParallelCloneEntry *entry = &context->entries[slot];
        if (entry->source == NULL) return NULL;
        if (entry->source == source) return entry->copy;
        slot = (slot + 1u) & (context->entry_capacity - 1u);
    } while (slot != start);
    return NULL;
}

static int parallel_clone_insert(
    ParallelCloneContext *context,
    const Value *source,
    Value *copy
) {
    size_t capacity = context->entry_capacity;
    size_t slot;
    if (capacity == 0 || context->entry_count >= capacity / 2u) {
        ParallelCloneEntry *entries;
        size_t index;
        if (capacity > SIZE_MAX / 2u) {
            fail(context->snapshot, "parallel MIR alias map is too large");
            return 0;
        }
        capacity = capacity == 0 ? 8u : capacity * 2u;
        if (capacity > SIZE_MAX / sizeof(*entries)) {
            fail(context->snapshot, "parallel MIR alias map is too large");
            return 0;
        }
        entries = (ParallelCloneEntry *) runtime_allocate(
            context->snapshot, capacity * sizeof(*entries));
        if (entries == NULL) return 0;
        for (index = 0; index < context->entry_capacity; ++index) {
            ParallelCloneEntry entry = context->entries[index];
            if (entry.source == NULL) continue;
            slot = metadata_hash(
                (uint64_t) (uintptr_t) entry.source, capacity - 1u);
            while (entries[slot].source != NULL)
                slot = (slot + 1u) & (capacity - 1u);
            entries[slot] = entry;
        }
        context->entries = entries;
        context->entry_capacity = capacity;
    }
    slot = metadata_hash(
        (uint64_t) (uintptr_t) source, context->entry_capacity - 1u);
    while (context->entries[slot].source != NULL)
        slot = (slot + 1u) & (context->entry_capacity - 1u);
    context->entries[slot] = (ParallelCloneEntry) {source, copy};
    context->entry_count++;
    return 1;
}

static void initialize_parallel_snapshot(Runtime *snapshot, const Runtime *source) {
    snapshot->program = source->program;
    snapshot->host_runtime = source->host_runtime;
    snapshot->program_cookie = source->program_cookie;
    snapshot->host_helpers = source->host_helpers;
    snapshot->host_helper_count = source->host_helper_count;
    snapshot->function_wrappers = source->function_wrappers;
    snapshot->constructor_index = source->constructor_index;
    snapshot->constructor_index_capacity = source->constructor_index_capacity;
    snapshot->unary_type_index = source->unary_type_index;
    snapshot->unary_type_index_capacity = source->unary_type_index_capacity;
    snapshot->effect_instance_index = source->effect_instance_index;
    snapshot->effect_instance_index_capacity =
        source->effect_instance_index_capacity;
    snapshot->execution = source->execution;
    snapshot->nullary_values = source->nullary_values;
}

static Value *clone_parallel_value(
    ParallelCloneContext *context,
    Value *value,
    uint32_t depth
) {
    Runtime *snapshot = context->snapshot;
    Runtime *source = context->source;
    Value *copy;
    uint32_t index;
    if (!valid_value(source, value)) return NULL;
    copy = parallel_clone_lookup(context, value);
    if (copy != NULL) return copy;
    if (depth >= MITOS_MAX_VALUE_DEPTH) {
        if (snapshot->diagnostic[0] == '\0')
            fail(snapshot, "parallel MIR argument exceeds the snapshot depth limit");
        return NULL;
    }
    copy = (Value *) runtime_allocate(snapshot, sizeof(*copy));
    if (copy == NULL || !parallel_clone_insert(context, value, copy)) return NULL;
    *copy = *value;
    copy->fields = NULL;
    copy->string = NULL;
    copy->alternatives = NULL;
    copy->function = NULL;
    if (value->kind == VALUE_STRING) {
        char *bytes;
        if (value->string_length == SIZE_MAX) {
            fail(snapshot, "parallel MIR String argument is too large");
            return NULL;
        }
        bytes = (char *) runtime_allocate(snapshot, value->string_length + 1u);
        if (bytes == NULL) return NULL;
        memcpy(bytes, value->string, value->string_length);
        bytes[value->string_length] = '\0';
        copy->string = bytes;
    } else if (value->kind == VALUE_CONSTRUCTOR
               || value->kind == VALUE_ARRAY) {
        if (value->arity != 0) {
            copy->fields = (Value **) runtime_allocate(
                snapshot, (size_t) value->arity * sizeof(*copy->fields));
            if (copy->fields == NULL) return NULL;
            for (index = 0; index < value->arity; ++index) {
                copy->fields[index] = clone_parallel_value(
                    context, value->fields[index], depth + 1u);
                if (copy->fields[index] == NULL) return NULL;
            }
        }
    } else if (value->kind == VALUE_SUPERPOSITION) {
        copy->alternatives = (Alternative *) runtime_allocate(
            snapshot, (size_t) value->arity * sizeof(*copy->alternatives));
        if (copy->alternatives == NULL) return NULL;
        for (index = 0; index < value->arity; ++index) {
            const Alternative *source_alternative = &value->alternatives[index];
            Alternative *copy_alternative = &copy->alternatives[index];
            *copy_alternative = *source_alternative;
            copy_alternative->value = clone_parallel_value(
                context, source_alternative->value, depth + 1u);
            copy_alternative->assignments = NULL;
            if (copy_alternative->value == NULL) return NULL;
            if (source_alternative->assignment_count != 0) {
                copy_alternative->assignments = (OriginAssignment *)
                    runtime_allocate(
                        snapshot,
                        (size_t) source_alternative->assignment_count
                            * sizeof(*copy_alternative->assignments));
                if (copy_alternative->assignments == NULL) return NULL;
                memcpy(
                    copy_alternative->assignments,
                    source_alternative->assignments,
                    (size_t) source_alternative->assignment_count
                        * sizeof(*copy_alternative->assignments));
            }
        }
    } else if (value->kind == VALUE_FUNCTION) {
        const NativeClosure *source_closure =
            (const NativeClosure *) value->function;
        NativeClosure *copy_closure;
        if (source_closure == NULL
            || source_closure->function_index >= source->program->function_count
            || source_closure->capture_count > MITOS_MAX_ARITY
            || source_closure->parameter_count > MITOS_MAX_ARITY
            || source_closure->capture_count
                > source->program->functions[source_closure->function_index]
                    .parameter_count
            || source_closure->parameter_count
                != source->program->functions[source_closure->function_index]
                    .parameter_count - source_closure->capture_count) {
            fail(snapshot, "parallel MIR Function argument is invalid");
            return NULL;
        }
        copy_closure = (NativeClosure *) runtime_allocate(
            snapshot, sizeof(*copy_closure));
        if (copy_closure == NULL) return NULL;
        *copy_closure = *source_closure;
        copy_closure->captures = NULL;
        if (source_closure->capture_count != 0) {
            copy_closure->captures = (Value **) runtime_allocate(
                snapshot,
                (size_t) source_closure->capture_count
                    * sizeof(*copy_closure->captures));
            if (copy_closure->captures == NULL) return NULL;
            for (index = 0; index < source_closure->capture_count; ++index) {
                copy_closure->captures[index] = clone_parallel_value(
                    context, source_closure->captures[index], depth + 1u);
                if (copy_closure->captures[index] == NULL) return NULL;
            }
        }
        copy->function = copy_closure;
    } else if (value->kind == VALUE_FUTURE) {
        copy->function = value->function;
    }
    return copy;
}

static int snapshot_parallel_arguments(
    Runtime *snapshot,
    Runtime *source,
    Value **arguments,
    uint32_t count,
    Value ***owned_arguments
) {
    ParallelCloneContext context = {
        .snapshot = snapshot,
        .source = source
    };
    uint32_t index;
    *owned_arguments = NULL;
    initialize_parallel_snapshot(snapshot, source);
    if (count == 0) return 1;
    *owned_arguments = (Value **) runtime_allocate(
        snapshot, (size_t) count * sizeof(**owned_arguments));
    if (*owned_arguments == NULL) return 0;
    for (index = 0; index < count; ++index) {
        (*owned_arguments)[index] = clone_parallel_value(
            &context, arguments[index], 0);
        if ((*owned_arguments)[index] == NULL) return 0;
    }
    return 1;
}

struct ParallelJob {
    thrd_t thread;
    Runtime child;
    Runtime argument_snapshot;
    Runtime result_snapshot;
    NativeWrapper wrapper;
    Value **arguments;
    uint32_t argument_count;
    Value *result;
    ParallelJob *next;
    uint64_t registration_order;
    uint64_t source_order;
    uint64_t site_order;
    ExecutionControl *control;
    int thread_result;
    ParallelJobStartState start_state;
    _Atomic int completed;
    int worker_slot_reserved;
    int joining;
    int joined;
    int detached;
    int join_failed;
    uint32_t entry_call_depth;
    int budget_reserved;
    int child_released;
};

static int parallel_job_run(ParallelJob *job) {
    Runtime *previous_runtime = active_runtime;
    Value *raw_result;
    int result;
    ParallelCloneContext clone_context;
    active_runtime = &job->child;
    raw_result = as_value(job->wrapper(
        (int64_t *) job->arguments, job->argument_count));
    /*
     * Native worker wrappers retain their root frame across the adapter
     * return.  The worker dispatcher owns that frame and closes it here;
     * nested frames must already have unwound.
     */
    if (job->child.call_depth == job->entry_call_depth + 1u)
        job->child.call_depth--;
    if (job->child.call_depth != job->entry_call_depth)
        fail(&job->child,
             "parallel MIR call depth ended at %u instead of %u",
             job->child.call_depth, job->entry_call_depth);
    if (job->child.diagnostic[0] == '\0' && raw_result != NULL) {
        if (job->result_snapshot.program == NULL)
            initialize_parallel_snapshot(
                &job->result_snapshot, &job->child);
        clone_context = (ParallelCloneContext) {
            .snapshot = &job->result_snapshot,
            .source = &job->child
        };
        job->result = clone_parallel_value(
            &clone_context, raw_result, 0);
        if (job->result == NULL) {
            if (job->result_snapshot.budget_exhausted)
                job->child.budget_exhausted = 1;
            fail(&job->child, "%s",
                 job->result_snapshot.diagnostic[0] == '\0'
                    ? "unable to snapshot parallel MIR result"
                    : job->result_snapshot.diagnostic);
        }
    } else {
        job->result = NULL;
    }
    active_runtime = previous_runtime;
    result = job->child.diagnostic[0] == '\0' ? 0 : -1;
    job->thread_result = result;
    return result;
}

static int parallel_job_main(void *raw_job) {
    ParallelJob *job = (ParallelJob *) raw_job;
    int result = parallel_job_run(job);
    atomic_store_explicit(&job->completed, 1, memory_order_release);
    if (mtx_lock(&job->control->mutex) == thrd_success) {
        cnd_broadcast(&job->control->completed);
        mtx_unlock(&job->control->mutex);
    } else {
        cnd_broadcast(&job->control->completed);
    }
    if (job->worker_slot_reserved)
        (void) atomic_fetch_sub_explicit(
            &job->control->active_workers, 1u, memory_order_release);
    return result;
}

static void parallel_job_spin_until_completed(ParallelJob *job) {
    while (!atomic_load_explicit(&job->completed, memory_order_acquire))
        thrd_yield();
}

static void parallel_job_wait_until_completed(ParallelJob *job) {
    ExecutionControl *control = job->control;
    if (mtx_lock(&control->mutex) == thrd_success) {
        while (!atomic_load_explicit(&job->completed, memory_order_acquire)) {
            if (cnd_wait(&control->completed, &control->mutex) != thrd_success) {
                mtx_unlock(&control->mutex);
                parallel_job_spin_until_completed(job);
                return;
            }
        }
        mtx_unlock(&control->mutex);
        return;
    }
    parallel_job_spin_until_completed(job);
}

static int parallel_job_record_join_failure(ParallelJob *job) {
    ExecutionControl *control = job->control;
    parallel_job_wait_until_completed(job);
    if (!job->detached) (void) thrd_detach(job->thread);
    if (mtx_lock(&control->mutex) != thrd_success) return 0;
    job->detached = 1;
    job->joining = 0;
    job->join_failed = 1;
    control->join_failed = 1;
    cnd_broadcast(&control->completed);
    mtx_unlock(&control->mutex);
    return 0;
}

static int parallel_job_wait(ParallelJob *job) {
    ExecutionControl *control = job->control;
    int thread_result = 0;
    if (mtx_lock(&control->mutex) != thrd_success) return 0;
    while ((job->start_state == PARALLEL_JOB_STARTING
            || job->start_state == PARALLEL_JOB_INLINE_RUNNING
            || job->joining)
           && !job->joined && !job->join_failed)
        if (cnd_wait(&control->completed, &control->mutex) != thrd_success) {
            mtx_unlock(&control->mutex);
            parallel_job_spin_until_completed(job);
            return 0;
        }
    if (job->join_failed) {
        mtx_unlock(&control->mutex);
        return 0;
    }
    if (job->joined) {
        mtx_unlock(&control->mutex);
        return 1;
    }
    if (job->start_state == PARALLEL_JOB_INLINE_DONE) {
        job->joined = 1;
        cnd_broadcast(&control->completed);
        mtx_unlock(&control->mutex);
        return 1;
    }
    if (job->start_state != PARALLEL_JOB_THREADED) {
        mtx_unlock(&control->mutex);
        return 0;
    }
    job->joining = 1;
    mtx_unlock(&control->mutex);
    if (thrd_join(job->thread, &thread_result) != thrd_success)
        return parallel_job_record_join_failure(job);
    if (mtx_lock(&control->mutex) != thrd_success) return 0;
    job->thread_result = thread_result;
    job->joining = 0;
    job->joined = 1;
    cnd_broadcast(&control->completed);
    mtx_unlock(&control->mutex);
    return 1;
}
static int parallel_start_pending(ExecutionControl *control) {
    ParallelJob *cursor = NULL;
    for (;;) {
        ParallelJob *job;
        uint32_t workers;
        if (mtx_lock(&control->mutex) != thrd_success) return 0;
        job = cursor == NULL ? control->jobs : cursor->next;
        cursor = job;
        if (job == NULL) {
            mtx_unlock(&control->mutex);
            return 1;
        }
        if (job->start_state != PARALLEL_JOB_STARTING) {
            mtx_unlock(&control->mutex);
            continue;
        }
        workers = atomic_load_explicit(
            &control->active_workers, memory_order_relaxed);
        while (workers < control->max_workers
               && !atomic_compare_exchange_weak_explicit(
                   &control->active_workers, &workers, workers + 1u,
                   memory_order_acq_rel, memory_order_relaxed)) { }
        if (workers < control->max_workers) {
            job->worker_slot_reserved = 1;
            if (thrd_create(&job->thread, parallel_job_main, job)
                == thrd_success) {
                job->start_state = PARALLEL_JOB_THREADED;
                cnd_broadcast(&control->completed);
                mtx_unlock(&control->mutex);
                continue;
            }
            job->worker_slot_reserved = 0;
            (void) atomic_fetch_sub_explicit(
                &control->active_workers, 1u, memory_order_release);
        }
        job->start_state = PARALLEL_JOB_INLINE_RUNNING;
        cnd_broadcast(&control->completed);
        mtx_unlock(&control->mutex);
        (void) parallel_job_main(job);
        if (mtx_lock(&control->mutex) != thrd_success) return 0;
        job->start_state = PARALLEL_JOB_INLINE_DONE;
        cnd_broadcast(&control->completed);
        mtx_unlock(&control->mutex);
    }
}

static void execution_finish_failed_drain(ExecutionControl *control) {
    ParallelJob *job;
    while (atomic_load_explicit(
               &control->active_workers, memory_order_acquire) != 0)
        thrd_yield();
    if (mtx_lock(&control->mutex) != thrd_success) return;
    for (job = control->jobs; job != NULL; job = job->next) {
        if (job->start_state == PARALLEL_JOB_THREADED
            && !job->joined && !job->detached) {
            parallel_job_spin_until_completed(job);
            (void) thrd_detach(job->thread);
            job->detached = 1;
        }
    }
    mtx_unlock(&control->mutex);
}

static int execution_drain(ExecutionControl *control) {
    for (;;) {
        ParallelJob *job;
        if (!parallel_start_pending(control)) {
            execution_finish_failed_drain(control);
            return 0;
        }
        if (mtx_lock(&control->mutex) != thrd_success) {
            execution_finish_failed_drain(control);
            return 0;
        }
        if (control->join_failed) {
            mtx_unlock(&control->mutex);
            execution_finish_failed_drain(control);
            return 0;
        }
        for (job = control->jobs; job != NULL; job = job->next)
            if (!job->joined) break;
        mtx_unlock(&control->mutex);
        if (job == NULL) return 1;
        if (!parallel_job_wait(job)) {
            execution_finish_failed_drain(control);
            return 0;
        }
    }
}
static void parallel_job_reset_child(ParallelJob *job) {
    Runtime *child = &job->child;
    const MitosMirProgram *program = child->program;
    MitosMirRuntime *host_runtime = child->host_runtime;
    uint64_t program_cookie = child->program_cookie;
    HostHelperEntry *host_helpers = child->host_helpers;
    size_t host_helper_count = child->host_helper_count;
    void **function_wrappers = child->function_wrappers;
    uint32_t *constructor_index = child->constructor_index;
    size_t constructor_index_capacity = child->constructor_index_capacity;
    uint32_t *unary_type_index = child->unary_type_index;
    size_t unary_type_index_capacity = child->unary_type_index_capacity;
    EffectInstanceEntry *effect_instance_index = child->effect_instance_index;
    size_t effect_instance_index_capacity =
        child->effect_instance_index_capacity;
    Value **nullary_values = child->nullary_values;
    job->result = NULL;
    runtime_free(&job->result_snapshot);
    memset(&job->result_snapshot, 0, sizeof(job->result_snapshot));
    runtime_free(child);
    memset(child, 0, sizeof(*child));
    child->program = program;
    child->host_runtime = host_runtime;
    child->program_cookie = program_cookie;
    child->host_helpers = host_helpers;
    child->host_helper_count = host_helper_count;
    child->function_wrappers = function_wrappers;
    child->constructor_index = constructor_index;
    child->constructor_index_capacity = constructor_index_capacity;
    child->unary_type_index = unary_type_index;
    child->unary_type_index_capacity = unary_type_index_capacity;
    child->effect_instance_index = effect_instance_index;
    child->effect_instance_index_capacity = effect_instance_index_capacity;
    child->execution = job->control;
    child->source_order = job->source_order;
    child->is_parallel_worker = 1;
    child->nullary_values = nullary_values;
    child->call_depth = job->entry_call_depth;
    job->thread_result = 0;
    job->child_released = 0;
}

static int parallel_job_source_compare(const void *left, const void *right) {
    const ParallelJob *a = *(ParallelJob *const *) left;
    const ParallelJob *b = *(ParallelJob *const *) right;
    if (a->source_order != b->source_order)
        return a->source_order < b->source_order ? -1 : 1;
    if (a->site_order != b->site_order)
        return a->site_order < b->site_order ? -1 : 1;
    return a->registration_order < b->registration_order ? -1
        : a->registration_order != b->registration_order;
}

static int parallel_replay_budget_failures(ExecutionControl *control) {
    ParallelJob *job;
    ParallelJob **ordered;
    size_t count = 0;
    size_t index = 0;
    int exhausted = 0;
    if (!execution_drain(control)) return 0;
    if (mtx_lock(&control->mutex) != thrd_success) return 0;
    if (control->parallel_replay_done) {
        mtx_unlock(&control->mutex);
        return 1;
    }
    for (job = control->jobs; job != NULL; job = job->next) {
        if (job->child_released) continue;
        ++count;
        if (job->child.budget_exhausted
            || job->result_snapshot.budget_exhausted) exhausted = 1;
    }
    mtx_unlock(&control->mutex);
    if (!exhausted) return 1;
    if (count > SIZE_MAX / sizeof(*ordered)) return 0;
    ordered = (ParallelJob **) malloc(count * sizeof(*ordered));
    if (ordered == NULL) return 0;
    if (mtx_lock(&control->mutex) != thrd_success) {
        free(ordered);
        return 0;
    }
    for (job = control->jobs; job != NULL; job = job->next)
        if (!job->child_released) ordered[index++] = job;
    mtx_unlock(&control->mutex);
    if (index != count) {
        free(ordered);
        return 0;
    }
    qsort(ordered, count, sizeof(*ordered), parallel_job_source_compare);
    for (index = 0; index < count; ++index) {
        if (ordered[index]->child.call_fuel_count != 0)
            (void) atomic_fetch_sub_explicit(
                &control->call_fuel,
                ordered[index]->child.call_fuel_count,
                memory_order_relaxed);
        parallel_job_reset_child(ordered[index]);
    }
    for (index = 0; index < count; ++index)
        (void) parallel_job_run(ordered[index]);
    free(ordered);
    if (!execution_drain(control)) return 0;
    if (mtx_lock(&control->mutex) != thrd_success) return 0;
    control->parallel_replay_done = 1;
    mtx_unlock(&control->mutex);
    return 1;
}

static ParallelJob *parallel_first_failed(ExecutionControl *control) {
    ParallelJob *job;
    ParallelJob *failed = NULL;
    if (mtx_lock(&control->mutex) != thrd_success) return NULL;
    for (job = control->jobs; job != NULL; job = job->next) {
        if (job->child_released) continue;
        if (job->thread_result == 0 && job->child.diagnostic[0] == '\0'
            && job->child.call_depth == job->entry_call_depth
            && job->result != NULL) continue;
        if (failed == NULL || job->source_order < failed->source_order
            || (job->source_order == failed->source_order
                && (job->site_order < failed->site_order
                    || (job->site_order == failed->site_order
                        && job->registration_order < failed->registration_order))))
            failed = job;
    }
    mtx_unlock(&control->mutex);
    return failed;
}

static void execution_control_free(ExecutionControl *control) {
    ParallelJob *job;
    if (mtx_lock(&control->mutex) != thrd_success) return;
    job = control->jobs;
    while (job != NULL) {
        ParallelJob *next = job->next;
        if (!job->child_released) runtime_free(&job->child);
        runtime_free(&job->result_snapshot);
        runtime_free(&job->argument_snapshot);
        if (job->budget_reserved)
            execution_budget_release_control(control, 1u, sizeof(*job));
        free(job);
        job = next;
    }
    control->jobs = NULL;
    control->jobs_tail = NULL;
    mtx_unlock(&control->mutex);
    cnd_destroy(&control->completed);
    mtx_destroy(&control->mutex);
    control->initialized = 0;
}

static int64_t rt_parallel_call(int64_t function_index, int64_t raw_arguments,
                                int64_t count, int64_t source_order_raw) {
    uint64_t packed_order = (uint64_t) source_order_raw;
    uint64_t source_order = (uint32_t) packed_order;
    uint64_t site_order = packed_order >> 32;
    ParallelJob *job;
    ExecutionControl *control = active_runtime->execution;
    Value *future;
    if (function_index < 0
        || (uint64_t) function_index >= active_runtime->program->function_count
        || count < 0 || (uint64_t) count > MITOS_MAX_ARITY
        || (uint32_t) count
            != active_runtime->program->functions[function_index].parameter_count
        || active_runtime->function_wrappers == NULL
        || active_runtime->function_wrappers[function_index] == NULL
        || (count != 0 && raw_arguments == 0)
        || source_order > active_runtime->program->max_source_order
        || site_order >= active_runtime->program->instruction_count
        || control == NULL || !control->initialized) {
        fail(active_runtime, "parallel MIR thunk metadata is invalid");
        return 0;
    }
    if (!execution_budget_reserve(active_runtime, sizeof(*job))) return 0;
    job = (ParallelJob *) calloc(1, sizeof(*job));
    if (job == NULL) {
        execution_budget_release_control(control, 1u, sizeof(*job));
        fail(active_runtime, "out of memory while materializing a parallel MIR root");
        return 0;
    }
    job->budget_reserved = 1;
    atomic_init(&job->completed, 0);
    job->child.program = active_runtime->program;
    job->child.host_runtime = active_runtime->host_runtime;
    job->child.program_cookie = active_runtime->program_cookie;
    job->child.host_helpers = active_runtime->host_helpers;
    job->child.host_helper_count = active_runtime->host_helper_count;
    job->child.source_order = (uint64_t) source_order_raw;
    job->child.function_wrappers = active_runtime->function_wrappers;
    job->child.constructor_index = active_runtime->constructor_index;
    job->child.constructor_index_capacity = active_runtime->constructor_index_capacity;
    job->child.unary_type_index = active_runtime->unary_type_index;
    job->child.unary_type_index_capacity = active_runtime->unary_type_index_capacity;
    job->child.effect_instance_index = active_runtime->effect_instance_index;
    job->child.effect_instance_index_capacity =
        active_runtime->effect_instance_index_capacity;
    job->child.execution = control;
    job->child.is_parallel_worker = 1;
    job->child.nullary_values = active_runtime->nullary_values;
    job->child.call_depth = active_runtime->call_depth;
    job->entry_call_depth = active_runtime->call_depth;
    job->wrapper = (NativeWrapper) active_runtime->function_wrappers[function_index];
    job->argument_count = (uint32_t) count;
    if (!snapshot_parallel_arguments(
            &job->argument_snapshot, active_runtime,
            (Value **) (intptr_t) raw_arguments, job->argument_count,
            &job->arguments)) {
        if (active_runtime->diagnostic[0] == '\0')
            fail(active_runtime, "%s",
                 job->argument_snapshot.diagnostic[0] == '\0'
                    ? "unable to snapshot parallel MIR arguments"
                    : job->argument_snapshot.diagnostic);
        runtime_free(&job->argument_snapshot);
        runtime_free(&job->child);
        free(job);
        execution_budget_release_control(control, 1u, sizeof(*job));
        return 0;
    }
    job->control = control;
    job->source_order = source_order;
    job->site_order = site_order;
    future = (Value *) runtime_allocate(active_runtime, sizeof(*future));
    if (future == NULL) {
        runtime_free(&job->child);
        runtime_free(&job->argument_snapshot);
        free(job);
        execution_budget_release_control(control, 1u, sizeof(*job));
        return 0;
    }
    future->kind = VALUE_FUTURE;
    future->type_id = 1u;
    future->function = job;
    if (mtx_lock(&control->mutex) != thrd_success) {
        runtime_free(&job->child);
        runtime_free(&job->argument_snapshot);
        free(job);
        execution_budget_release_control(control, 1u, sizeof(*job));
        fail(active_runtime, "unable to register a parallel MIR worker");
        return 0;
    }
    job->registration_order = control->next_job_order++;
    job->start_state = PARALLEL_JOB_STARTING;
    if (control->jobs_tail == NULL)
        control->jobs = job;
    else
        control->jobs_tail->next = job;
    control->jobs_tail = job;
    control->parallel_replay_done = 0;
    cnd_broadcast(&control->completed);
    mtx_unlock(&control->mutex);
    return from_value(future);
}

static int64_t rt_parallel_join(int64_t raw_future, int64_t u1,
                                int64_t u2, int64_t u3) {
    Value *future = as_value(raw_future);
    ParallelJob *job;
    ParallelJob *failed;
    (void) u1; (void) u2; (void) u3;
    if (future == NULL || future->kind != VALUE_FUTURE || future->function == NULL) {
        fail(active_runtime, "parallel MIR join requires a live future");
        return 0;
    }
    job = (ParallelJob *) future->function;
    future->function = NULL;
    if (active_runtime->is_parallel_worker) {
        if (!parallel_start_pending(job->control)
            || !parallel_job_wait(job)) {
            fail(active_runtime,
                 "parallel MIR workers could not be deterministically completed");
            return 0;
        }
        failed = job->thread_result == 0
                && job->child.diagnostic[0] == '\0'
                && job->child.call_depth == job->entry_call_depth
                && job->result != NULL
            ? NULL : job;
    } else {
        if (!parallel_replay_budget_failures(job->control)) {
            fail(active_runtime,
                 "parallel MIR workers could not be deterministically completed");
            return 0;
        }
        failed = parallel_first_failed(job->control);
    }
    if (failed != NULL) {
        if (active_runtime->diagnostic[0] == '\0')
            active_runtime->diagnostic_span = failed->child.diagnostic_span;
        fail(active_runtime, "%s", failed->child.diagnostic[0] != '\0'
             ? failed->child.diagnostic : "parallel MIR worker failed");
        return 0;
    }
    if (mtx_lock(&job->control->mutex) != thrd_success) {
        fail(active_runtime, "unable to release a completed parallel MIR worker");
        return 0;
    }
    if (!job->child_released) {
        runtime_free(&job->child);
        job->child_released = 1;
    }
    mtx_unlock(&job->control->mutex);
    return from_value(job->result);
}


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


static EffectOccurrenceScope *effect_occurrence_scope(
    Runtime *runtime,
    uint64_t source_order
) {
    EffectOccurrenceScope *scope;
    size_t slot;
    if (runtime == NULL || runtime->program == NULL) return NULL;
    if (source_order > runtime->program->max_source_order) {
        fail(runtime, "external effect source order exceeds its declared domain");
        return NULL;
    }
    if (runtime->effect_occurrence_capacity == 0) {
        runtime->effect_occurrence_capacity = 8u;
        runtime->effect_occurrence_buckets = (EffectOccurrenceScope **)
            runtime_allocate(
                runtime,
                runtime->effect_occurrence_capacity
                    * sizeof(*runtime->effect_occurrence_buckets));
        if (runtime->effect_occurrence_buckets == NULL) {
            runtime->effect_occurrence_capacity = 0;
            return NULL;
        }
    }
    slot = metadata_hash(
        source_order, runtime->effect_occurrence_capacity - 1u);
    for (scope = runtime->effect_occurrence_buckets[slot];
         scope != NULL;
         scope = scope->next)
        if (scope->source_order == source_order) return scope;
    if (runtime->effect_occurrence_count
        >= runtime->effect_occurrence_capacity / 2u) {
        EffectOccurrenceScope **grown;
        size_t old_capacity = runtime->effect_occurrence_capacity;
        size_t bucket;
        if (old_capacity > SIZE_MAX / 2u
            || old_capacity * 2u
                > MITOS_MAX_ALLOCATION_BYTES
                    / sizeof(*runtime->effect_occurrence_buckets)) {
            fail(runtime, "external effect occurrence index exceeds its limit");
            return NULL;
        }
        runtime->effect_occurrence_capacity = old_capacity * 2u;
        grown = (EffectOccurrenceScope **) runtime_allocate(
            runtime,
            runtime->effect_occurrence_capacity * sizeof(*grown));
        if (grown == NULL) {
            runtime->effect_occurrence_capacity = old_capacity;
            return NULL;
        }
        for (bucket = 0; bucket < old_capacity; ++bucket) {
            scope = runtime->effect_occurrence_buckets[bucket];
            while (scope != NULL) {
                EffectOccurrenceScope *next = scope->next;
                size_t grown_slot = metadata_hash(
                    scope->source_order,
                    runtime->effect_occurrence_capacity - 1u);
                scope->next = grown[grown_slot];
                grown[grown_slot] = scope;
                scope = next;
            }
        }
        runtime->effect_occurrence_buckets = grown;
        slot = metadata_hash(
            source_order, runtime->effect_occurrence_capacity - 1u);
    }
    scope = (EffectOccurrenceScope *) runtime_allocate(runtime, sizeof(*scope));
    if (scope == NULL) return NULL;
    scope->source_order = source_order;
    scope->next = runtime->effect_occurrence_buckets[slot];
    runtime->effect_occurrence_buckets[slot] = scope;
    ++runtime->effect_occurrence_count;
    return scope;
}

static int validate_host_result(
    Runtime *runtime,
    const MitosMirHostValue *value,
    uint32_t expected
) {
    static const uint8_t zero3[3] = {0, 0, 0};
    int scalar_shape;
    if (value == NULL || memcmp(value->reserved, zero3, sizeof(zero3)) != 0
        || memcmp(value->reserved2, zero3, sizeof(zero3)) != 0
        || value->kind > MITOS_HOST_ARRAY
        || value->type_id == 0
        || value->type_id > runtime->program->type_count) goto invalid;
    scalar_shape =
        (value->kind == MITOS_HOST_I64 || value->integer == 0)
        && (value->kind == MITOS_HOST_BOOL || value->boolean == 0)
        && (value->kind == MITOS_HOST_TYPE || value->represented_type == 0)
        && (value->kind == MITOS_HOST_STRING
            || (value->string == NULL && value->string_length == 0));
    if (!scalar_shape
        || (value->kind == MITOS_HOST_BOOL && value->boolean > 1)
        || (value->kind == MITOS_HOST_STRING
            && ((value->string == NULL && value->string_length != 0)
                || value->string_length >= MITOS_MAX_ALLOCATION_BYTES))
        || (value->kind == MITOS_HOST_I64
            && value->type_id != runtime->program->i64_type)
        || (value->kind == MITOS_HOST_BOOL
            && value->type_id != runtime->program->bool_type)
        || (value->kind == MITOS_HOST_STRING
            && value->type_id != runtime->program->string_type)
        || (value->kind == MITOS_HOST_UNIT && value->type_id != 6u)
        || (value->kind == MITOS_HOST_TYPE
            && (value->represented_type == 0
                || value->represented_type > runtime->program->type_count
                || value->type_id != runtime->program->types[
                    value->represented_type - 1u].type_value_runtime))
        || (expected != 1u
            && !runtime_subtype(runtime, value->type_id, expected)))
        goto invalid;
    return 1;
invalid:
    fail(runtime,
         "external effect helper returned a structurally invalid host value");
    return 0;
}

static int64_t rt_external_effect_concrete(int64_t operation, int64_t raw_arguments,
                                           int64_t count, int64_t packed_raw) {
    Value **arguments = (Value **) (intptr_t) raw_arguments;
    uint64_t packed = (uint64_t) packed_raw;
    uint32_t expected = (uint32_t) packed;
    uint32_t effect = (uint32_t) (packed >> 32);
    const MitosMirEffectOperation *descriptor;
    HostHelperEntry *helper = NULL;
    MitosMirHostValue *views;
    MitosMirHostCall call;
    MitosMirHostDisposition disposition;
    Value *result = NULL;
    uint64_t occurrence_order;
    size_t index;
    if (operation < 0 || (uint64_t) operation > UINT32_MAX || count < 0
        || (uint64_t) count > MITOS_MAX_ARITY
        || (count != 0 && arguments == NULL) || effect == 0
        || active_runtime->host_runtime == NULL) {
        fail(active_runtime, "external effect call metadata is invalid");
        return 0;
    }
    if (active_runtime->is_parallel_worker) {
        fail(active_runtime,
             "parallel MIR workers may not invoke external effects");
        return 0;
    }
    descriptor = host_operation(active_runtime->program, (uint32_t) operation);
    if (descriptor == NULL
        || !runtime_effect_instance_matches(
            active_runtime, effect, descriptor->effect)
        || (descriptor->result_type != 1u
            && descriptor->result_type != expected)
        || descriptor->arity != (uint32_t) count) {
        fail(active_runtime, "external effect operation has incompatible canonical MIR host metadata");
        return 0;
    }
    {
        HostHelperEntry *candidate =
            runtime_host_helper(active_runtime, (uint32_t) operation);
        if (candidate != NULL
            && helper_metadata_equal(candidate, active_runtime->program_cookie,
                                     descriptor))
            helper = candidate;
    }
    if (helper == NULL) {
        fail(active_runtime, "external effect operation %u has no compatible registered helper",
             (uint32_t) operation);
        return 0;
    }
    views = NULL;
    if (count != 0) {
        views = (MitosMirHostValue *) runtime_allocate(
            active_runtime, (size_t) count * sizeof(*views));
        if (views == NULL) return 0;
        memset(views, 0, (size_t) count * sizeof(*views));
    }

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
        } else if (value->kind == VALUE_SUPERPOSITION
                   || value->kind == VALUE_ARRAY) {
            fail(active_runtime,
                 "external effect arguments cannot contain aggregate values under host ABI 2.0");
            return 0;
        } else if (value->tag == active_runtime->program->true_tag
                   || value->tag == active_runtime->program->false_tag) {
            views[index].kind = MITOS_HOST_BOOL;
            views[index].boolean = value->tag == active_runtime->program->true_tag;
        } else if (value->type_id == 6u && value->arity == 0) {
            views[index].kind = MITOS_HOST_UNIT;
        } else {
            fail(active_runtime,
                 "external effect arguments cannot contain aggregate values under host ABI 2.0");
            return 0;
        }
    }
    memset(&call, 0, sizeof(call));
    call.abi_major = descriptor->abi_major;
    call.abi_minor = descriptor->abi_minor;
    call.effect = effect;
    call.operation = descriptor->operation;
    call.source_order = active_runtime->source_order;
    if (active_runtime->active_effect_occurrence_scope == NULL) {
        fail(active_runtime, "external effect source-order scope is unavailable");
        return 0;
    }
    occurrence_order =
        active_runtime->active_effect_occurrence_scope->next_occurrence++;
    call.occurrence_order = occurrence_order;
    call.arguments = views;
    call.argument_count = (size_t) count;
    disposition = helper->handler(&call, helper->context);
    if (call.abi_major != descriptor->abi_major
        || call.abi_minor != descriptor->abi_minor
        || call.effect != effect || call.operation != descriptor->operation
        || call.source_order != active_runtime->source_order
        || call.occurrence_order != occurrence_order
        || call.arguments != views || call.argument_count != (size_t) count
        || ((call.diagnostic == NULL) != (call.diagnostic_length == 0))
        || call.diagnostic_length >= MITOS_DIAGNOSTIC_BYTES) {
        fail(active_runtime,
             "external effect helper corrupted canonical host call metadata");
        return 0;
    }
    if (disposition == MITOS_MIR_HOST_SUSPEND) {
        fail(active_runtime,
             "native MIR host suspension is unsupported until resumable MIR frames exist");
        return 0;
    }
    if (disposition != MITOS_MIR_HOST_READY) {
        if (call.diagnostic_length != 0)
            fail(active_runtime, "%.*s", (int) call.diagnostic_length,
                 call.diagnostic);
        else
            fail(active_runtime, "external effect helper rejected operation %u",
                 (uint32_t) operation);
        return 0;
    }
    if (call.diagnostic_length != 0) {
        fail(active_runtime,
             "successful external effect helper returned a diagnostic");
        return 0;
    }
    if (!validate_host_result(active_runtime, &call.result, expected))
        return 0;
    switch (call.result.kind) {
        case MITOS_HOST_I64:
            result = new_integer(active_runtime, call.result.integer);
            break;
        case MITOS_HOST_BOOL:
            result = as_value(boolean_value(active_runtime, call.result.boolean != 0));
            break;
        case MITOS_HOST_STRING:
            result = new_string(active_runtime, call.result.string,
                                call.result.string_length,
                                active_runtime->program->string_type);
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

static int64_t rt_set_source_order(int64_t source_order, int64_t preserved,
                                   int64_t u2, int64_t u3) {
    EffectOccurrenceScope *scope;
    (void) u2; (void) u3;
    if (source_order < 0) {
        fail(active_runtime, "external effect source order is invalid");
        return 0;
    }
    scope = effect_occurrence_scope(active_runtime, (uint64_t) source_order);
    if (scope == NULL) return 0;
    active_runtime->source_order = (uint64_t) source_order;
    active_runtime->active_effect_occurrence_scope = scope;
    return preserved;
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
    ExecutionControl *control = active_runtime->execution;
    uint64_t fuel;
    (void) u0; (void) u1; (void) u2; (void) u3;
    if (active_runtime->call_depth >= MITOS_MAX_CALL_DEPTH) {
        fail(active_runtime, "native call-depth limit exceeded");
        return 0;
    }
    if (control == NULL || !control->initialized) {
        fail(active_runtime, "native call fuel is unavailable");
        return 0;
    }
    fuel = atomic_load_explicit(&control->call_fuel, memory_order_relaxed);
    for (;;) {
        if (fuel >= MITOS_MAX_CALL_FUEL) {
            active_runtime->budget_exhausted = 1;
            fail(active_runtime, "native call fuel limit exceeded");
            return 0;
        }
        if (atomic_compare_exchange_weak_explicit(
                &control->call_fuel, &fuel, fuel + 1u,
                memory_order_relaxed, memory_order_relaxed)) break;
    }
    active_runtime->call_fuel_count++;
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
    "mitos_rt_args_set", "mitos_rt_external_effect",
    "mitos_rt_parallel_call", "mitos_rt_parallel_join",
    "mitos_rt_make_function", "mitos_rt_apply_function",
    "mitos_rt_superpose", "mitos_rt_collapse", "mitos_rt_lift_constructor",
    "mitos_rt_lift_call", "mitos_rt_lift_match", "mitos_rt_lift_make_function",
    "mitos_rt_set_source_order"
};

static void *helper_addresses[MITOS_HELPER_COUNT] = {
    (void *) rt_const, (void *) rt_add, (void *) rt_subtract, (void *) rt_multiply,
    (void *) rt_divide, (void *) rt_remainder, (void *) rt_equal, (void *) rt_less,
    (void *) rt_less_equal, (void *) rt_greater, (void *) rt_greater_equal,
    (void *) rt_make_constructor, (void *) rt_set_field, (void *) rt_get_field,
    (void *) rt_tag_equal, (void *) rt_type_value, (void *) rt_type_of,
    (void *) rt_type_assert, (void *) rt_string, (void *) rt_args_new,
    (void *) rt_args_set, (void *) rt_external_effect,
    (void *) rt_parallel_call, (void *) rt_parallel_join,
    (void *) rt_make_function, (void *) rt_apply_function,
    (void *) rt_superpose, (void *) rt_collapse, (void *) rt_lift_constructor,
    (void *) rt_lift_call, (void *) rt_lift_match, (void *) rt_lift_make_function,
    (void *) rt_set_source_order
};

static int range_within(uint32_t start, uint32_t count, uint32_t total) {
    return start <= total && count <= total - start;
}

static void merge_register_state(
    uint8_t *states,
    uint8_t *seen,
    uint32_t slot,
    const uint8_t *current,
    uint32_t register_count
) {
    uint8_t *incoming =
        states + (size_t) slot * register_count;
    uint32_t index;
    if (!seen[slot]) {
        memcpy(incoming, current, register_count);
        seen[slot] = 1;
        return;
    }
    for (index = 0; index < register_count; ++index)
        incoming[index] &= current[index];
}

static int validate_program(const MitosMirProgram *program, char *diagnostic, size_t capacity) {
    uint32_t function_index, constructor_index, type_index, effect_index;
    uint32_t expected_instruction_start = 0;
    uint32_t *validation_labels = NULL;
    uint32_t *validation_label_slots = NULL;
    uint8_t *validation_registers = NULL;
    uint8_t *validation_cfg_states = NULL;
    uint8_t *validation_cfg_seen = NULL;
    uint32_t *validation_constructor_tags = NULL;
    uint32_t *validation_constructor_scratch = NULL;
    EffectInstanceEntry *validation_effect_instances = NULL;
    size_t validation_effect_instance_capacity = 0;
    uint64_t total_registers = 0;
    uint64_t total_emitted_instructions = 0;
#define VALIDATE(condition, ...) do { \
    if (!(condition)) { \
        free(validation_labels); \
        free(validation_label_slots); \
        free(validation_registers); \
        free(validation_cfg_states); \
        free(validation_cfg_seen); \
        free(validation_constructor_tags); \
        free(validation_constructor_scratch); \
        free(validation_effect_instances); \
        snprintf(diagnostic, capacity, __VA_ARGS__); \
        return 0; \
    } \
} while (0)
    VALIDATE(program != NULL, "native MIR requires a program");
    VALIDATE(program->program_identity != 0,
             "native MIR program capability identity is absent");
    VALIDATE(program->function_count != 0 && program->function_count <= MITOS_MAX_FUNCTIONS,
             "native MIR function count is out of range");
    VALIDATE(program->constructor_count >= 2
                 && program->constructor_count <= MITOS_MAX_CONSTRUCTORS,
             "native MIR constructor count is out of range");
    VALIDATE(program->instruction_count <= MITOS_MAX_INSTRUCTIONS,
             "native MIR instruction limit exceeded");
    VALIDATE(program->operand_count <= MITOS_MAX_OPERANDS, "native MIR operand limit exceeded");
    VALIDATE(program->type_count != 0 && program->type_count <= MITOS_MAX_TYPES
                 && program->types != NULL,
             "native MIR type registry is absent or exceeds its limit");
    VALIDATE(program->layout_count == program->type_count
                 && program->layouts != NULL,
             "native MIR layout table must parallel the type registry");
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
    VALIDATE(program->string_count <= MITOS_MAX_STRINGS
                 && (program->string_count == 0 || program->strings != NULL),
             "native MIR String table is null or exceeds its limit");
    VALIDATE(program->effect_operation_count <= MITOS_MAX_EFFECT_OPERATIONS
                 && (program->effect_operation_count == 0
                     || program->effect_operations != NULL),
             "native MIR external-effect table is null or exceeds its limit");
    VALIDATE(program->reserved_method_count == 0
                 && program->reserved_methods == NULL,
             "native MIR reserved specialization fields must be zero");
    VALIDATE(program->match_arm_count <= MITOS_MAX_MATCH_ARMS
                 && (program->match_arm_count == 0
                     || program->match_arms != NULL),
             "native MIR match-arm table is null or exceeds its limit");
    VALIDATE(program->span_count <= MITOS_MAX_SPANS
                 && (program->span_count == 0 || program->spans != NULL),
             "native MIR source-span table is null or exceeds its limit");
    VALIDATE(program->max_workers != 0 && program->max_workers <= 256,
             "native MIR worker count is out of range");
    VALIDATE(program->phase_one_root_count != 0,
             "native MIR practical phase has no materialized roots");
    VALIDATE(program->max_source_order <= MITOS_MAX_SOURCE_ORDER,
             "native MIR source-order domain exceeds its limit");
    VALIDATE(program->reserved == 0 && program->reserved2 == 0,
             "native MIR program reserved fields must be zero");
    for (function_index = 0;
         function_index < program->function_count;
         ++function_index) {
        const MitosMirFunction *function = &program->functions[function_index];
        uint64_t function_emitted;
        VALIDATE(function->parameter_count <= function->register_count
                     && function->parameter_count <= MITOS_MAX_ARITY
                     && function->register_count != 0
                     && function->register_count <= MITOS_MAX_REGISTERS,
                 "function %u register metadata is out of range",
                 function_index);
        VALIDATE(total_registers
                     <= MITOS_MAX_TOTAL_REGISTERS - function->register_count,
                 "native MIR aggregate register budget exceeded");
        total_registers += function->register_count;
        function_emitted =
            (uint64_t) function->instruction_count
            + (function->register_count - function->parameter_count) + 6u;
        VALIDATE(function_emitted <= MITOS_MAX_EMITTED_INSTRUCTIONS
                     && total_emitted_instructions
                        <= MITOS_MAX_EMITTED_INSTRUCTIONS - function_emitted,
                 "native MIR emitted-instruction budget exceeded");
        total_emitted_instructions += function_emitted;
    }
    for (type_index = 0;
         type_index < program->instruction_count;
         ++type_index) {
        const MitosMirInstruction *instruction = &program->instructions[type_index];
        uint64_t additional = 0;
        switch (instruction->opcode) {
            case MITOS_MIR_BRANCH_FALSE:
            case MITOS_MIR_RETURN:
                additional = 1u;
                break;
            case MITOS_MIR_MAKE_CONSTRUCTOR:
                additional = instruction->operand_count;
                break;
            case MITOS_MIR_EXTERNAL_EFFECT:
                additional = (uint64_t) instruction->operand_count + 2u;
                break;
            case MITOS_MIR_PARALLEL_CALL:
            case MITOS_MIR_MAKE_FUNCTION:
            case MITOS_MIR_APPLY_FUNCTION:
            case MITOS_MIR_SUPERPOSE:
            case MITOS_MIR_LIFT_CONSTRUCTOR:
            case MITOS_MIR_LIFT_CALL:
            case MITOS_MIR_LIFT_MATCH:
            case MITOS_MIR_LIFT_MAKE_FUNCTION:
                additional = (uint64_t) instruction->operand_count + 1u;
                break;
            default:
                break;
        }
        VALIDATE(additional <= MITOS_MAX_EMITTED_INSTRUCTIONS
                     && total_emitted_instructions
                        <= MITOS_MAX_EMITTED_INSTRUCTIONS - additional,
                 "native MIR emitted-instruction budget exceeded");
        total_emitted_instructions += additional;
    }
    validation_effect_instance_capacity = index_capacity(
        program->effect_operation_count + program->instruction_count);
    validation_effect_instances = (EffectInstanceEntry *) calloc(
        validation_effect_instance_capacity, sizeof(EffectInstanceEntry));
    VALIDATE(validation_effect_instances != NULL,
             "out of memory while validating external-effect instances");
    for (effect_index = 0;
         effect_index < program->effect_operation_count;
         ++effect_index) {
        const MitosMirEffectOperation *operation =
            &program->effect_operations[effect_index];
        VALIDATE(operation->dense_handle == effect_index
                     && operation->operation == effect_index + 1u
                     && operation->effect != 0
                     && operation->arity <= MITOS_MAX_ARITY
                     && operation->result_type != 0
                     && operation->result_type <= program->type_count
                     && operation->abi_major == 2u && operation->abi_minor == 0u
                     && (operation->flags
                         & ~(MITOS_MIR_EFFECT_ORDERED
                             | MITOS_MIR_EFFECT_EXTERNAL)) == 0,
                 "native MIR effect operation metadata is not canonical");
        {
            size_t slot = metadata_hash(
                operation->effect, validation_effect_instance_capacity - 1u);
            while (validation_effect_instances[slot].instance != 0
                   && validation_effect_instances[slot].instance
                        != operation->effect)
                slot = (slot + 1u)
                    & (validation_effect_instance_capacity - 1u);
            VALIDATE(validation_effect_instances[slot].instance == 0
                         || validation_effect_instances[slot].constructor
                            == operation->effect,
                     "native MIR effect constructor metadata is incoherent");
            validation_effect_instances[slot] =
                (EffectInstanceEntry) {operation->effect, operation->effect};
        }
    }
    for (type_index = 0; type_index < program->span_count; ++type_index) {
        const MitosMirSpan *span = &program->spans[type_index];
        VALIDATE(span->start_offset <= INT64_MAX
                     && span->start_row <= INT64_MAX
                     && span->start_column <= INT64_MAX
                     && span->end_offset <= INT64_MAX
                     && span->end_row <= INT64_MAX
                     && span->end_column <= INT64_MAX
                     && span->end_offset >= span->start_offset,
                 "native MIR source span %u is invalid", type_index);
    }
    for (type_index = 0; type_index < program->type_count; ++type_index) {
        const MitosMirType *type = &program->types[type_index];
        const MitosMirLayout *layout = &program->layouts[type_index];
        size_t name_index;
        VALIDATE(type->id == type_index + 1, "native MIR TypeIds are not dense and stable");
        VALIDATE(type->parent <= program->type_count, "native MIR type parent is invalid");
        VALIDATE(type->kind <= 3u,
                 "native MIR type descriptor kind is invalid");
        VALIDATE(type->type_value_runtime != 0
                     && type->type_value_runtime <= program->type_count,
                 "native MIR type has an invalid concrete Type-of identity");
        VALIDATE(type->constructor <= program->type_count
                     && type->argument <= program->type_count,
                 "native MIR type application metadata is invalid");
        if (type->kind == 2u) {
            const MitosMirType *base;
            VALIDATE(type->constructor != 0 && type->argument != 0,
                     "native MIR parametric type instance is incomplete");
            base = &program->types[type->constructor - 1u];
            VALIDATE(base->kind <= 1u && type->parent == base->parent,
                     "native MIR parametric type instance is noncanonical");
        }
        VALIDATE(type->name != NULL && type->name_length != 0
                     && type->name_length <= MITOS_MAX_FORMAT_BYTES,
                 "native MIR type %u has an invalid name", type->id);
        for (name_index = 0; name_index < type->name_length; ++name_index)
            VALIDATE((unsigned char) type->name[name_index] >= 0x20u
                         && (unsigned char) type->name[name_index] != 0x7fu,
                     "native MIR type %u name contains a control byte", type->id);
        VALIDATE(layout->type_id == type->id && layout->kind <= 4u
                     && layout->copy_policy <= 3u && (layout->flags & ~1u) == 0
                     && layout->reserved == 0
                     && layout->element_type <= program->type_count,
                 "native MIR type %u has invalid layout metadata", type->id);
        VALIDATE(layout->alignment != 0
                     && (layout->alignment & (layout->alignment - 1u)) == 0,
                 "native MIR type %u has invalid layout alignment", type->id);
        if ((layout->flags & 1u) != 0) {
            VALIDATE(layout->stride >= layout->size
                         && layout->stride % layout->alignment == 0
                         && (layout->size != 0 || layout->stride != 0),
                     "native MIR type %u has invalid sized layout", type->id);
        } else {
            VALIDATE(layout->size == 0 && layout->stride == 0,
                     "native MIR type %u has invalid unsized layout", type->id);
        }
    }
    for (type_index = 0; type_index < program->string_count; ++type_index) {
        const MitosMirString *literal = &program->strings[type_index];
        VALIDATE(literal->runtime_type != 0 && literal->runtime_type <= program->type_count,
                 "native MIR String literal has an invalid TypeId");
        VALIDATE(literal->length == 0 || literal->bytes != NULL,
                 "native MIR String literal has a null buffer");
        VALIDATE(literal->reserved == 0, "native MIR String literal reserved field is nonzero");
    }
    {
        const MitosMirConstructor *true_constructor = NULL;
        const MitosMirConstructor *false_constructor = NULL;
        validation_constructor_tags = (uint32_t *) malloc(
            (size_t) program->constructor_count * sizeof(*validation_constructor_tags));
        validation_constructor_scratch = (uint32_t *) malloc(
            (size_t) program->constructor_count * sizeof(*validation_constructor_scratch));
        VALIDATE(validation_constructor_tags != NULL
                     && validation_constructor_scratch != NULL,
                 "out of memory while validating constructor tags");
        for (constructor_index = 0;
             constructor_index < program->constructor_count;
             ++constructor_index) {
            const MitosMirConstructor *constructor =
                &program->constructors[constructor_index];
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
                VALIDATE((unsigned char) constructor->name[name_index] >= 0x20u
                             && (unsigned char) constructor->name[name_index]
                                != 0x7fu,
                         "constructor %u name contains a control byte",
                         constructor_index);
            validation_constructor_tags[constructor_index] = constructor->tag;
            if (constructor->tag == program->true_tag)
                true_constructor = constructor;
            if (constructor->tag == program->false_tag)
                false_constructor = constructor;
        }
        for (uint32_t shift = 0; shift < 32u; shift += 8u) {
            size_t counts[256] = {0};
            size_t offsets[256];
            uint32_t *swap;
            for (constructor_index = 0;
                 constructor_index < program->constructor_count;
                 ++constructor_index)
                ++counts[(validation_constructor_tags[constructor_index] >> shift) & 0xffu];
            offsets[0] = 0;
            for (size_t bucket = 1; bucket < 256; ++bucket)
                offsets[bucket] = offsets[bucket - 1] + counts[bucket - 1];
            for (constructor_index = 0;
                 constructor_index < program->constructor_count;
                 ++constructor_index) {
                uint32_t tag = validation_constructor_tags[constructor_index];
                validation_constructor_scratch[
                    offsets[(tag >> shift) & 0xffu]++] = tag;
            }
            swap = validation_constructor_tags;
            validation_constructor_tags = validation_constructor_scratch;
            validation_constructor_scratch = swap;
        }
        for (constructor_index = 1;
             constructor_index < program->constructor_count;
             ++constructor_index)
            VALIDATE(validation_constructor_tags[constructor_index - 1u]
                         != validation_constructor_tags[constructor_index],
                     "constructor tags must be unique");
        VALIDATE(true_constructor != NULL && false_constructor != NULL,
                 "native MIR True or False tag has no descriptor");
        VALIDATE(true_constructor->arity == 0 && false_constructor->arity == 0,
                 "native MIR True and False constructors must be nullary");
        free(validation_constructor_tags);
        free(validation_constructor_scratch);
        validation_constructor_tags = NULL;
        validation_constructor_scratch = NULL;
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
        uint32_t *labels;
        uint32_t *label_slots;
        uint8_t *defined_registers;
        uint32_t local_index;
        uint32_t label_count = 0;
        uint32_t highest_register_plus_one = function->parameter_count;
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
        labels = (uint32_t *) calloc(
            function->instruction_count, sizeof(uint32_t));
        label_slots = (uint32_t *) calloc(
            function->instruction_count, sizeof(uint32_t));
        validation_labels = labels;
        validation_label_slots = label_slots;
        VALIDATE(labels != NULL && label_slots != NULL,
                 "out of memory while validating native MIR labels");
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
#define REG(index) do { \
    VALIDATE((index) < function->register_count, \
             "function %u instruction %u has an invalid register", \
             function_index, local_index); \
    if ((index) + 1u > highest_register_plus_one) \
        highest_register_plus_one = (index) + 1u; \
} while (0)
#define USE(index) REG(index)
            VALIDATE(instruction->opcode <= MITOS_MIR_LIFT_MAKE_FUNCTION
                         && instruction->opcode != MITOS_MIR_RESERVED_31,
                     "function %u instruction %u has an invalid or reserved opcode",
                     function_index, local_index);
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
                    VALIDATE(constructor_runtime_type_matches(
                                 program,
                                 &program->constructors[instruction->a],
                                 instruction->b),
                             "function %u constructor runtime TypeId does not match its descriptor",
                             function_index);
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
                    labels[instruction->a] = local_index + 1u;
                    label_slots[instruction->a] = ++label_count;
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
                    VALIDATE(instruction->operand_start <= program->span_count
                                 && instruction->operand_count == 0,
                             "function %u assertion has invalid source-span metadata",
                             function_index);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_STRING_CONST:
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->string_count,
                             "function %u String literal index is invalid", function_index);
                    defined_registers[instruction->destination] = 1;
                    break;
                case MITOS_MIR_EXTERNAL_EFFECT: {
                    uint32_t instance;
                    uint32_t constructor;
                    size_t slot;
                    REG(instruction->destination);
                    VALIDATE(instruction->a < program->effect_operation_count,
                             "function %u external-effect descriptor is invalid", function_index);
                    VALIDATE((program->effect_operations[instruction->a].flags
                              & MITOS_MIR_EFFECT_EXTERNAL) != 0,
                             "function %u effect descriptor is not external", function_index);
                    VALIDATE(instruction->operand_count
                                 == program->effect_operations[instruction->a].arity,
                             "function %u external-effect arity is invalid",
                             function_index);
                    VALIDATE((uint32_t) instruction->immediate != 0
                                 && (uint32_t) instruction->immediate <= program->type_count,
                             "function %u external-effect result TypeId is invalid", function_index);
                    VALIDATE(program->effect_operations[instruction->a].result_type == 1u
                                 || program->effect_operations[instruction->a].result_type
                                    == (uint32_t) instruction->immediate,
                             "function %u external-effect result type is incompatible",
                             function_index);
                    instance =
                        (uint32_t) ((uint64_t) instruction->immediate >> 32);
                    constructor =
                        program->effect_operations[instruction->a].effect;
                    VALIDATE(instance != 0,
                             "function %u external-effect identity is invalid",
                             function_index);
                    slot = metadata_hash(
                        instance, validation_effect_instance_capacity - 1u);
                    while (validation_effect_instances[slot].instance != 0
                           && validation_effect_instances[slot].instance
                                != instance)
                        slot = (slot + 1u)
                            & (validation_effect_instance_capacity - 1u);
                    VALIDATE(validation_effect_instances[slot].instance == 0
                                 || validation_effect_instances[slot].constructor
                                    == constructor,
                             "function %u external-effect instance belongs to a different constructor",
                             function_index);
                    validation_effect_instances[slot] =
                        (EffectInstanceEntry) {instance, constructor};
                    VALIDATE(instruction->b <= program->max_source_order,
                             "function %u external-effect source order is invalid",
                             function_index);
                    VALIDATE(range_within(instruction->operand_start, instruction->operand_count,
                                          program->operand_count),
                             "function %u external-effect operand range is invalid", function_index);
                    for (operand_index = 0; operand_index < instruction->operand_count;
                         ++operand_index)
                        USE(program->operands[instruction->operand_start + operand_index]);
                    defined_registers[instruction->destination] = 1;
                    break;
                }
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
                    VALIDATE(instruction->b <= program->max_source_order,
                             "function %u parallel thunk source order is invalid",
                             function_index);
                    VALIDATE(instruction->immediate >= 0
                                 && (uint64_t) instruction->immediate
                                    == function->instruction_start + local_index,
                             "function %u parallel thunk site order is noncanonical",
                             function_index);
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
                    VALIDATE(constructor_runtime_type_matches(
                                 program,
                                 &program->constructors[instruction->a],
                                 instruction->b),
                             "function %u lifted constructor runtime TypeId does not match its descriptor",
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
            if (instruction->opcode == MITOS_MIR_JUMP) {
                VALIDATE(labels[instruction->a] != 0,
                         "function %u jumps to an undefined label",
                         function_index);
                VALIDATE(labels[instruction->a] - 1u > local_index,
                         "function %u has a non-forward jump", function_index);
            }
            if (instruction->opcode == MITOS_MIR_BRANCH_FALSE) {
                VALIDATE(labels[instruction->b] != 0,
                         "function %u branches to an undefined label", function_index);
                VALIDATE(labels[instruction->b] - 1u > local_index,
                         "function %u has a non-forward branch", function_index);
            }
            if ((instruction->opcode == MITOS_MIR_JUMP
                 || instruction->opcode == MITOS_MIR_RETURN)
                && local_index + 1 < function->instruction_count)
                VALIDATE(program->instructions[function->instruction_start + local_index + 1]
                                 .opcode == MITOS_MIR_LABEL,
                         "function %u has an instruction after a basic-block terminator",
                         function_index);
        }
        VALIDATE(label_count == 0
                     || function->register_count
                        <= MITOS_MAX_VALIDATION_STATE_BYTES / label_count,
                 "function %u control-flow validation state exceeds its budget",
                 function_index);
        if (label_count != 0) {
            validation_cfg_states = (uint8_t *) calloc(
                (size_t) label_count, function->register_count);
            validation_cfg_seen = (uint8_t *) calloc(label_count, 1);
            VALIDATE(validation_cfg_states != NULL
                         && validation_cfg_seen != NULL,
                     "out of memory while validating native MIR control flow");
        }
        memset(defined_registers, 0, function->register_count);
        for (local_index = 0;
             local_index < function->parameter_count;
             ++local_index)
            defined_registers[local_index] = 1;
        {
            int reachable = 1;
            for (local_index = 0;
                 local_index < function->instruction_count;
                 ++local_index) {
                const MitosMirInstruction *instruction =
                    &program->instructions[
                        function->instruction_start + local_index];
                uint32_t operand_index;
#define FLOW_USE(index) do { \
    if (reachable) \
        VALIDATE(defined_registers[(index)] != 0, \
                 "function %u instruction %u opcode %u uses undefined register %u", \
                 function_index, local_index, instruction->opcode, (unsigned) (index)); \
} while (0)
#define FLOW_DEFINE(index) do { \
    if (reachable) defined_registers[(index)] = 1; \
} while (0)
#define FLOW_OPERANDS() do { \
    for (operand_index = 0; operand_index < instruction->operand_count; \
         ++operand_index) \
        FLOW_USE(program->operands[instruction->operand_start + operand_index]); \
} while (0)
                switch (instruction->opcode) {
                    case MITOS_MIR_LABEL: {
                        uint32_t slot = label_slots[instruction->a] - 1u;
                        uint8_t *incoming = validation_cfg_states
                            + (size_t) slot * function->register_count;
                        if (validation_cfg_seen[slot]) {
                            if (reachable) {
                                uint32_t register_index;
                                for (register_index = 0;
                                     register_index < function->register_count;
                                     ++register_index)
                                    defined_registers[register_index] &=
                                        incoming[register_index];
                            } else {
                                memcpy(defined_registers, incoming,
                                       function->register_count);
                                reachable = 1;
                            }
                        }
                        break;
                    }
                    case MITOS_MIR_JUMP:
                        if (reachable)
                            merge_register_state(
                                validation_cfg_states, validation_cfg_seen,
                                label_slots[instruction->a] - 1u,
                                defined_registers, function->register_count);
                        reachable = 0;
                        break;
                    case MITOS_MIR_BRANCH_FALSE:
                        FLOW_USE(instruction->a);
                        if (reachable)
                            merge_register_state(
                                validation_cfg_states, validation_cfg_seen,
                                label_slots[instruction->b] - 1u,
                                defined_registers, function->register_count);
                        break;
                    case MITOS_MIR_RETURN:
                        FLOW_USE(instruction->a);
                        reachable = 0;
                        break;
                    case MITOS_MIR_MOVE:
                    case MITOS_MIR_TYPE_OF:
                    case MITOS_MIR_TYPE_ASSERT:
                    case MITOS_MIR_PARALLEL_JOIN:
                    case MITOS_MIR_COLLAPSE:
                        FLOW_USE(instruction->a);
                        FLOW_DEFINE(instruction->destination);
                        break;
                    case MITOS_MIR_ADD:
                    case MITOS_MIR_SUBTRACT:
                    case MITOS_MIR_MULTIPLY:
                    case MITOS_MIR_DIVIDE:
                    case MITOS_MIR_REMAINDER:
                    case MITOS_MIR_EQUAL:
                    case MITOS_MIR_LESS:
                    case MITOS_MIR_LESS_EQUAL:
                    case MITOS_MIR_GREATER:
                    case MITOS_MIR_GREATER_EQUAL:
                        FLOW_USE(instruction->a);
                        FLOW_USE(instruction->b);
                        FLOW_DEFINE(instruction->destination);
                        break;
                    case MITOS_MIR_TAG_EQUAL:
                    case MITOS_MIR_GET_FIELD:
                        FLOW_USE(instruction->a);
                        FLOW_DEFINE(instruction->destination);
                        break;
                    case MITOS_MIR_CALL:
                    case MITOS_MIR_MAKE_CONSTRUCTOR:
                    case MITOS_MIR_EXTERNAL_EFFECT:
                    case MITOS_MIR_PARALLEL_CALL:
                    case MITOS_MIR_MAKE_FUNCTION:
                    case MITOS_MIR_SUPERPOSE:
                    case MITOS_MIR_LIFT_CONSTRUCTOR:
                    case MITOS_MIR_LIFT_CALL:
                    case MITOS_MIR_LIFT_MAKE_FUNCTION:
                        FLOW_OPERANDS();
                        FLOW_DEFINE(instruction->destination);
                        break;
                    case MITOS_MIR_APPLY_FUNCTION:
                    case MITOS_MIR_LIFT_MATCH:
                        FLOW_USE(instruction->a);
                        FLOW_OPERANDS();
                        FLOW_DEFINE(instruction->destination);
                        break;
                    case MITOS_MIR_CONST:
                    case MITOS_MIR_TYPE_VALUE:
                    case MITOS_MIR_STRING_CONST:
                        FLOW_DEFINE(instruction->destination);
                        break;
                    case MITOS_MIR_RESERVED_31:
                        break;
                }
#undef FLOW_OPERANDS
#undef FLOW_DEFINE
#undef FLOW_USE
            }
        }
        free(validation_cfg_states);
        validation_cfg_states = NULL;
        free(validation_cfg_seen);
        validation_cfg_seen = NULL;
        VALIDATE(program->instructions[function->instruction_start + function->instruction_count - 1]
                         .opcode == MITOS_MIR_RETURN,
                 "function %u must end with RETURN", function_index);
        free(labels);
        validation_labels = NULL;
        free(label_slots);
        validation_label_slots = NULL;
        free(defined_registers);
        validation_registers = NULL;
        expected_instruction_start += function->instruction_count;
    }
    VALIDATE(expected_instruction_start == program->instruction_count,
             "native MIR instruction ranges do not cover the instruction array");
    VALIDATE(program->functions[program->main_function].parameter_count == 0,
             "native MIR main must have zero parameters");
    free(validation_effect_instances);
    validation_effect_instances = NULL;
#undef VALIDATE
    return 1;
}

static _Noreturn void mir_error(MIR_error_type_t type, const char *format, ...) {
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

static void finish_build_scratch(MirBuild *build) {
    free(build->scratch_call_ops);
    free(build->scratch_labels);
    free(build->scratch_registers);
    free(build->scratch_argument_names);
    free(build->scratch_arguments);
    build->scratch_call_ops = NULL;
    build->scratch_labels = NULL;
    build->scratch_registers = NULL;
    build->scratch_argument_names = NULL;
    build->scratch_arguments = NULL;
}

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
        char *argument_names = NULL;
        char name[48], proto_name[48];
        uint32_t argument;
        if (source->parameter_count != 0) {
            arguments = (MIR_var_t *) calloc(
                source->parameter_count, sizeof(*arguments));
            argument_names = (char *) malloc(
                (size_t) source->parameter_count * 32u);
            build->scratch_arguments = arguments;
            build->scratch_argument_names = argument_names;
            if (arguments == NULL || argument_names == NULL) return 0;
            for (argument = 0; argument < source->parameter_count; ++argument) {
                char *argument_name = argument_names + (size_t) argument * 32u;
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
        free(argument_names);
        free(arguments);
        build->scratch_argument_names = NULL;
        build->scratch_arguments = NULL;
    }
    for (index = 0; index < program->function_count; ++index) {
        const MitosMirFunction *source = &program->functions[index];
        MIR_var_t *arguments = NULL;
        char *argument_names = NULL;
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
            arguments = (MIR_var_t *) calloc(
                source->parameter_count, sizeof(*arguments));
            argument_names = (char *) malloc(
                (size_t) source->parameter_count * 32u);
            build->scratch_arguments = arguments;
            build->scratch_argument_names = argument_names;
            if (arguments == NULL || argument_names == NULL) return 0;
            for (argument = 0; argument < source->parameter_count; ++argument) {
                char *argument_name = argument_names + (size_t) argument * 32u;
                snprintf(argument_name, 32, "argument_%u", argument);
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
        build->scratch_registers = registers;
        build->scratch_labels = labels;
        if (registers == NULL || labels == NULL) return 0;
        for (argument = 0; argument < source->parameter_count; ++argument)
            registers[argument] = MIR_reg(
                build->context, arguments[argument].name, function_data);
        free(arguments);
        free(argument_names);
        build->scratch_arguments = NULL;
        build->scratch_argument_names = NULL;
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
        /*
         * MIR virtual registers otherwise carry indeterminate machine bits on
         * paths that bypass a syntactically earlier definition.  Zero makes
         * every such path fail closed at the boxed-value boundary instead of
         * turning those bits into an arbitrary Value pointer.
         */
        for (argument = source->parameter_count;
             argument < source->register_count; ++argument)
            MIR_append_insn(
                build->context, function,
                MIR_new_insn(build->context, MIR_MOV,
                             MIR_new_reg_op(build->context, registers[argument]),
                             zero_op(build)));
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
                    MIR_op_t *call_ops = (MIR_op_t *) malloc(
                        (size_t) (count + 3) * sizeof(*call_ops));
                    build->scratch_call_ops = call_ops;
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
                    build->scratch_call_ops = NULL;
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
                                          MIR_new_uint_op(build->context,
                                                          instruction->operand_start));
                    break;
                case MITOS_MIR_STRING_CONST:
                    emitted = helper_call(build, function, registers[instruction->destination], 18,
                                          MIR_new_uint_op(build->context, instruction->a),
                                          zero_op(build), zero_op(build), zero_op(build));
                    break;
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
                    emitted = helper_call(
                        build, function, registers[instruction->destination], 32,
                        MIR_new_uint_op(build->context, instruction->b),
                        MIR_new_reg_op(build->context,
                                       registers[instruction->destination]),
                        zero_op(build), zero_op(build));
                    MIR_append_insn(build->context, function, emitted);
                    emitted = helper_call(
                        build, function, registers[instruction->destination], 21,
                        MIR_new_uint_op(build->context, instruction->a),
                        MIR_new_reg_op(build->context,
                                       registers[instruction->destination]),
                        MIR_new_uint_op(build->context, instruction->operand_count),
                        MIR_new_uint_op(build->context,
                                        (uint64_t) instruction->immediate));
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
                        build, function, registers[instruction->destination], 22,
                        MIR_new_uint_op(build->context, instruction->a),
                        MIR_new_reg_op(build->context, registers[instruction->destination]),
                        MIR_new_uint_op(build->context, instruction->operand_count),
                        MIR_new_uint_op(
                            build->context,
                            (uint64_t) instruction->b
                                | ((uint64_t) (uint32_t) instruction->immediate << 32)));
                    break;
                }
                case MITOS_MIR_PARALLEL_JOIN:
                    emitted = helper_call(
                        build, function, registers[instruction->destination], 23,
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
                            build, function, registers[instruction->destination], 24,
                            MIR_new_uint_op(build->context, instruction->a),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, instruction->operand_count),
                            MIR_new_uint_op(build->context, packed));
                    } else if (instruction->opcode == MITOS_MIR_LIFT_MAKE_FUNCTION) {
                        uint64_t packed = ((uint64_t) instruction->immediate << 32)
                            | instruction->b;
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 31,
                            MIR_new_uint_op(build->context, instruction->a),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, packed),
                            zero_op(build));
                    } else {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 25,
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
                            build, function, registers[instruction->destination], 26,
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
                            build, function, registers[instruction->destination], 28,
                            MIR_new_uint_op(build->context, descriptor->tag),
                            MIR_new_uint_op(build->context, instruction->b),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, instruction->operand_count));
                    } else if (instruction->opcode == MITOS_MIR_LIFT_CALL) {
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 29,
                            MIR_new_uint_op(build->context, instruction->a),
                            MIR_new_reg_op(build->context,
                                           registers[instruction->destination]),
                            MIR_new_uint_op(build->context, instruction->operand_count),
                            MIR_new_uint_op(build->context, instruction->b));
                    } else {
                        uint64_t packed = ((uint64_t) instruction->b << 32)
                            | instruction->operand_count;
                        emitted = helper_call(
                            build, function, registers[instruction->destination], 30,
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
                        build, function, registers[instruction->destination], 27,
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
        build->scratch_labels = NULL;
        build->scratch_registers = NULL;
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
        build->scratch_call_ops = call_ops;
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
        build->scratch_call_ops = NULL;
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

static int builder_append_quoted_string(
    TextBuilder *builder,
    const char *text,
    size_t length
) {
    static const char hex_digits[] = "0123456789abcdef";
    size_t index;
    if (!builder_append(builder, "\"", 1)) return 0;
    for (index = 0; index < length; ++index) {
        const char *escaped = NULL;
        unsigned char byte = (unsigned char) text[index];
        switch (byte) {
            case '"': escaped = "\\\""; break;
            case '\\': escaped = "\\\\"; break;
            case '\n': escaped = "\\n"; break;
            case '\r': escaped = "\\r"; break;
            case '\t': escaped = "\\t"; break;
            default:
                if (byte < 0x20u || byte == 0x7fu) {
                    char hex_escape[4] = {
                        '\\', 'x',
                        hex_digits[byte >> 4],
                        hex_digits[byte & 0x0fu]
                    };
                    if (!builder_append(builder, hex_escape,
                                        sizeof(hex_escape))) return 0;
                } else if (!builder_append(builder, &text[index], 1)) {
                    return 0;
                }
                break;
        }
        if (escaped != NULL && !builder_append(builder, escaped, 2)) return 0;
    }
    return builder_append(builder, "\"", 1);
}

static int builder_append_metadata_name(
    TextBuilder *builder,
    const char *text,
    size_t length
) {
    static const char hex_digits[] = "0123456789abcdef";
    size_t index;
    for (index = 0; index < length; ++index) {
        unsigned char byte = (unsigned char) text[index];
        if (byte < 0x20u || byte == 0x7fu) {
            char escaped[4] = {
                '\\', 'x',
                hex_digits[byte >> 4],
                hex_digits[byte & 0x0fu]
            };
            if (!builder_append(builder, escaped, sizeof(escaped))) return 0;
        } else if (byte == '\\') {
            if (!builder_append(builder, "\\\\", 2)) return 0;
        } else if (!builder_append(builder, &text[index], 1)) {
            return 0;
        }
    }
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
        return builder_append_quoted_string(
            builder, value->string, value->string_length);
    if (value->kind == VALUE_TYPE) {
        const MitosMirType *descriptor = type_by_id(builder->runtime, value->type_id);
        if (descriptor == NULL) {
            fail(builder->runtime, "cannot format a Type value with an invalid runtime TypeId");
            return 0;
        }
        return builder_append_metadata_name(
            builder, descriptor->name, descriptor->name_length);
    }
    if (value->kind == VALUE_FUNCTION)
        return builder_append(builder, "<lambda>", 8);
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
        if (!builder_append_metadata_name(
                builder, descriptor->name, descriptor->name_length)) return 0;
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
    finish_build_scratch(build);
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


typedef struct MirExecuteState {
    Runtime runtime;
    ExecutionControl control;
    MirBuild build;
    TextBuilder builder;
    jmp_buf jump;
    char diagnostic[MITOS_DIAGNOSTIC_BYTES];
} MirExecuteState;

static MitosMirOutcome mitos_mir_execute_inner(
    MitosMirRuntime *host_runtime,
    const MitosMirProgram *program,
    uint64_t program_cookie,
    HostHelperEntry *host_helpers,
    size_t host_helper_count
) {
    typedef int64_t (*MainFunction)(void);
    MainFunction main_function = NULL;
    MitosMirOutcome outcome = {.status = MITOS_MIR_ERROR};
    MirExecuteState *state;
    Runtime *previous_runtime = active_runtime;
    jmp_buf *previous_jump = active_mir_jump;
    char *previous_diagnostic = active_mir_diagnostic;
    uint32_t index;

    state = (MirExecuteState *) calloc(1, sizeof(*state));
    if (state == NULL) return outcome_error("out of memory while initializing MIR execution");
    state->runtime.host_runtime = host_runtime;
    state->runtime.program = program;
    state->runtime.program_cookie = program_cookie;
    state->runtime.host_helpers = host_helpers;
    state->runtime.host_helper_count = host_helper_count;
    if (mtx_init(&state->control.mutex, mtx_plain) != thrd_success) {
        free(state);
        return outcome_error("unable to initialize native worker ownership");
    }
    if (cnd_init(&state->control.completed) != thrd_success) {
        mtx_destroy(&state->control.mutex);
        free(state);
        return outcome_error("unable to initialize native worker completion");
    }
    state->control.max_workers = program->max_workers;
    atomic_init(&state->control.active_workers, 0u);
    atomic_init(&state->control.allocation_count, 0u);
    atomic_init(&state->control.allocation_bytes, 0u);
    atomic_init(&state->control.call_fuel, 0u);
    state->control.initialized = 1;
    state->runtime.execution = &state->control;
    state->runtime.function_wrappers = (void **) calloc(
        program->function_count, sizeof(*state->runtime.function_wrappers));
    state->runtime.owns_function_wrappers = 1;
    if (state->runtime.function_wrappers == NULL
        || !runtime_initialize_indexes(&state->runtime)
        || !runtime_allocate_nullaries(&state->runtime)
        || !runtime_initialize_nullaries(&state->runtime)) {
        runtime_free(&state->runtime);
        execution_control_free(&state->control);
        free(state);
        return outcome_error("out of memory while initializing native metadata");
    }
    state->builder.runtime = &state->runtime;
    state->build.context = MIR_init();
    if (state->build.context == NULL) {
        runtime_free(&state->runtime);
        execution_control_free(&state->control);
        free(state);
        return outcome_error("MIR_init failed");
    }
    active_mir_jump = &state->jump;
    active_mir_diagnostic = state->diagnostic;
    if (setjmp(state->jump) != 0) {
        active_runtime = previous_runtime;
        active_mir_jump = previous_jump;
        active_mir_diagnostic = previous_diagnostic;
        outcome = outcome_error(state->diagnostic[0] == '\0'
            ? "MIR rejected generated code" : state->diagnostic);
        free(state->builder.data);
        runtime_free(&state->runtime);
        execution_control_free(&state->control);
        finish_build(&state->build);
        free(state);
        return outcome;
    }
    MIR_set_error_func(state->build.context, mir_error);
    MIR_gen_init(state->build.context);
    state->build.generator_initialized = 1;
    MIR_gen_set_optimize_level(state->build.context, 1);
    if (!build_mir(program, &state->build)) {
        outcome = outcome_error("out of memory while constructing MIR");
        goto done_mir;
    }
    MIR_load_module(state->build.context, state->build.module);
    for (index = 0; index < MITOS_HELPER_COUNT; ++index)
        MIR_load_external(state->build.context, helper_names[index], helper_addresses[index]);
    MIR_load_external(state->build.context, "mitos_rt_enter", (void *) rt_enter);
    MIR_load_external(state->build.context, "mitos_rt_leave", (void *) rt_leave);
    MIR_load_external(state->build.context, "mitos_rt_is_false", (void *) rt_is_false);
    MIR_link(state->build.context, MIR_set_gen_interface, NULL);
    for (index = 0; index < program->function_count; ++index) {
        state->runtime.function_wrappers[index] = MIR_gen(
            state->build.context, state->build.function_wrappers[index]);
        if (state->runtime.function_wrappers[index] == NULL) {
            snprintf(state->diagnostic, sizeof(state->diagnostic),
                     "MIR_gen returned no parallel wrapper for function %u", index);
            break;
        }
    }
    if (state->diagnostic[0] == '\0')
        main_function = (MainFunction) MIR_gen(
            state->build.context, state->build.function_items[program->main_function]);
    if (state->diagnostic[0] == '\0' && main_function == NULL)
        snprintf(state->diagnostic, sizeof(state->diagnostic),
                 "MIR_gen returned no main entry point");

done_mir:
    active_mir_jump = previous_jump;
    active_mir_diagnostic = previous_diagnostic;
    if (outcome.diagnostic != NULL) goto cleanup;
    if (state->diagnostic[0] != '\0') {
        outcome = outcome_error(state->diagnostic);
        goto cleanup;
    }
    active_runtime = &state->runtime;
    {
        Value *result_value = as_value(main_function());
        ParallelJob *failed;
        if (!parallel_replay_budget_failures(&state->control)) {
            active_runtime = previous_runtime;
            outcome = outcome_error(
                "parallel MIR worker cleanup failed after worker completion");
            goto cleanup;
        }
        failed = parallel_first_failed(&state->control);
        if (failed != NULL) {
            if (state->runtime.diagnostic[0] == '\0')
                state->runtime.diagnostic_span = failed->child.diagnostic_span;
            fail(&state->runtime, "%s",
                 failed->child.diagnostic[0] != '\0'
                    ? failed->child.diagnostic : "parallel MIR worker failed");
        }
        active_runtime = previous_runtime;
        if (state->runtime.diagnostic[0] != '\0') {
            outcome = outcome_error(state->runtime.diagnostic);
            outcome.diagnostic_span = state->runtime.diagnostic_span;
        } else if (state->runtime.call_depth != 0) {
            outcome = outcome_error("native call-depth accounting did not return to zero");
        } else if (!format_value(&state->builder, result_value, 0)) {
            outcome = outcome_error(state->runtime.diagnostic[0] == '\0'
                ? "native result formatting failed" : state->runtime.diagnostic);
        } else {
            if (state->builder.data == NULL) state->builder.data = copy_text("");
            outcome.status = MITOS_MIR_NATIVE;
            outcome.result = state->builder.data;
            outcome.diagnostic = copy_text("");
            state->builder.data = NULL;
            if (outcome.result == NULL || outcome.diagnostic == NULL) {
                mitos_mir_outcome_free(&outcome);
                outcome = outcome_error("out of memory while returning the native result");
            }
        }
    }
cleanup:
    active_runtime = previous_runtime;
    free(state->builder.data);
    runtime_free(&state->runtime);
    execution_control_free(&state->control);
    finish_build(&state->build);
    free(state);
    return outcome;
}

static int runtime_execution_acquire(
    MitosMirRuntime *runtime,
    const MitosMirProgram *program,
    uint64_t *program_cookie,
    HostHelperEntry **host_helpers,
    size_t *host_helper_count
) {
    HostHelperEntry *snapshot = NULL;
    size_t index;
    size_t snapshot_count = 0;
    size_t external_count = 0;
    int helpers_exact = 1;
    int ok = 0;
    if (program == NULL || program_cookie == NULL || host_helpers == NULL
        || host_helper_count == NULL) return 0;
    *program_cookie = 0;
    *host_helpers = NULL;
    *host_helper_count = 0;
    if (!registry_enter(runtime)) return 0;
    if (registry_lock(runtime)) {
        uint64_t cookie = program_cookie_unlocked(runtime, program, 1);
        ProgramEnrollment *enrollment = cookie == 0
            ? NULL : enrollment_by_cookie_unlocked(runtime, cookie, NULL);
        if (!runtime->shutting_down && runtime->active_executions != SIZE_MAX
            && enrollment != NULL
            && enrollment->active_executions != SIZE_MAX) {
            for (index = 0; index < program->effect_operation_count; ++index)
                if ((program->effect_operations[index].flags
                     & MITOS_MIR_EFFECT_EXTERNAL) != 0)
                    ++external_count;
            for (index = 0; index < runtime->host_helper_count; ++index) {
                const HostHelperEntry *entry = &runtime->host_helpers[index];
                if (entry->program_cookie != cookie) continue;
                ++snapshot_count;
                if (entry->dense_handle >= program->effect_operation_count
                    || (program->effect_operations[entry->dense_handle].flags
                        & MITOS_MIR_EFFECT_EXTERNAL) == 0
                    || !helper_metadata_equal(
                        entry, cookie,
                        &program->effect_operations[entry->dense_handle]))
                    helpers_exact = 0;
            }
            if (snapshot_count != external_count) helpers_exact = 0;
            if (helpers_exact && snapshot_count != 0)
                snapshot = (HostHelperEntry *) malloc(
                    snapshot_count * sizeof(*snapshot));
            if (helpers_exact && (snapshot_count == 0 || snapshot != NULL)) {
                size_t output = 0;
                for (index = 0; index < runtime->host_helper_count; ++index) {
                    const HostHelperEntry *entry = &runtime->host_helpers[index];
                    if (entry->program_cookie == cookie)
                        snapshot[output++] = *entry;
                }
                ++runtime->active_executions;
                ++enrollment->active_executions;
                *program_cookie = cookie;
                *host_helpers = snapshot;
                *host_helper_count = snapshot_count;
                ok = 1;
            }
        }
        if (!ok && cookie != 0) retire_enrollment_unlocked(runtime, cookie);
        mtx_unlock(&runtime->mutex);
    }
    registry_leave(runtime);
    if (ok && snapshot_count > 1u)
        qsort(snapshot, snapshot_count, sizeof(*snapshot),
              host_helper_dense_compare);
    if (!ok) free(snapshot);
    return ok;
}

static void runtime_execution_release(
    MitosMirRuntime *runtime,
    uint64_t program_cookie
) {
    if (!registry_lock(runtime)) return;
    if (runtime->active_executions != 0) --runtime->active_executions;
    if (program_cookie != 0) {
        ProgramEnrollment *enrollment =
            enrollment_by_cookie_unlocked(runtime, program_cookie, NULL);
        if (enrollment != NULL && enrollment->active_executions != 0)
            --enrollment->active_executions;
        retire_enrollment_unlocked(runtime, program_cookie);
    }
    mtx_unlock(&runtime->mutex);
}


MitosMirOutcome mitos_mir_execute(
    MitosMirRuntime *runtime,
    const MitosMirProgram *program
) {
    MitosMirOutcome outcome;
    char validation_diagnostic[MITOS_DIAGNOSTIC_BYTES] = {0};
    uint64_t program_cookie;
    HostHelperEntry *host_helpers;
    size_t host_helper_count;
    if (!validate_program(program, validation_diagnostic, sizeof(validation_diagnostic)))
        return outcome_error(validation_diagnostic);
    if (!runtime_execution_acquire(
            runtime, program, &program_cookie, &host_helpers,
            &host_helper_count))
        return outcome_error("MIR runtime is unavailable");
    outcome = mitos_mir_execute_inner(
        runtime, program, program_cookie, host_helpers, host_helper_count);
    runtime_execution_release(runtime, program_cookie);
    free(host_helpers);
    return outcome;
}