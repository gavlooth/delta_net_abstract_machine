[PRD]
# PRD: Typed Delta-First Mitos

## 1. Overview

Mitos uses an owned typed `DeltaProgram` as its sole executable semantic image. `run`, `jit`, REPL, AOT creation, and `aot-run` share source lowering, runtime types, generic dispatch, algebraic effects, graph metadata, and observable results. MIR specializes the Delta image; it does not independently compile surface expressions or fall back to another evaluator.

Phases one and two established typed multiple dispatch and algebraic effects. Phase three adds first-class deterministic `Superposition of T` values and strict ordered collapse while preserving the core replicator calculus, source-ordered effects/errors, and one Delta-first backend contract.

Mitos remains dynamically typed: names are immutable bindings, while every runtime value has a concrete nominal `TypeId`. Type annotations are optional and use the word `of`. Generic functions dispatch over all argument types, including each concrete lifted alternative.

## Core-Lock Phase: Shared v4 IR/ABI Schemas

This phase precedes subsystem implementation. It locks exactly these five seams:

1. **Canonical identity.** `ModuleKey` and `SymbolKey` are allocator-owned structural records with clone/deinit/equality helpers. Core, default, and REPL module keys are reserved. Program and named declarations own canonical keys; display names remain separate, and a hash is never sufficient for identity.
2. **Resolved effect rows.** One owned `ResolvedEffectRow` contains sorted unique required `EffectId`s plus an optional canonical `SymbolKey` tail. Normalize/clone/deinit/equality/membership are shared contracts; the source AST continues to own its parsed `EffectRow`.
3. **Persistent data layouts.** `LayoutDescriptor` records layout kind, copy policy, explicit sized/unsized state, size, nonzero power-of-two alignment, stride, element `TypeId`, and stable key, with no runtime address. Built-in `TypeId`s 1 through 10 and their deterministic layouts are fixed.
4. **Persistence and helper ABI.** `DeltaProgram` uses schema 4.0, helper ABI 2.0, tagged records, and a program-owned required/optional feature manifest. Named bits cover typed values, effects, parallelism, host calls, superposition, identity keys, effect rows, layouts, suspension, tagged records, and dynamic effectful closures. Effect/handler/resume/abort tags remain 32/33/34/35. MIR advertises every known feature except `SUSPENSION` and `DYNAMIC_EFFECT_CLOSURES`. Direct `jit` rejects either required bit before MIR emission; after artifact validation, `aot-run` uses the same predicate and selects generic Delta whenever any required bit is outside MIR's advertised set.
5. **Host suspension boundary.** Persistent data describes suspension capability only. A ready-only external helper returns `HOST_READY` (or `HOST_FAIL`), requires `HOST` while leaving `SUSPENSION` optional, and remains MIR-eligible when its exact versioned operation slot is explicitly enrolled. A helper that may retain execution and return `HOST_SUSPEND` makes `SUSPENSION` required and therefore routes to generic Delta. Opaque suspension tokens, execution contexts, allocators, callbacks, pointers, retain counts, and host handles are runtime-only and must never be serialized.

**Dependency order:** canonical identity → resolved effect rows → persistent data layouts → persistence/helper ABI → host suspension boundary. Downstream parser, lowering, runtime, net, MIR, AOT, REPL, and CLI work starts only after these contracts are fixed.

**Explicit library deferrals:** module/import syntax, collection APIs, scheduler types, FFI syntax, Vulkan types, traits, unions, macros, library implementations, and new core agents are outside this phase. No placeholder library surface or compatibility shim is introduced.

**Security and resource invariants:**

- Every owned string/slice/key/row/layout has one documented allocator owner and a matching clone/deinit path; persisted records contain no raw runtime pointer or token.
- Decoders must bound counts and byte lengths before allocation, reject overflow and overlapping required/optional bits, reject unknown required features, and skip unknown optional tagged records by validated length.
- Layout alignment is nonzero and power-of-two; sized arithmetic is checked before allocation; abstract/unsized layouts are explicit and unallocatable.
- Effect rows are canonical sorted unique sets; symbol identity is compared structurally; helper tags and existing enum ordinals are append-only and stable.
- Suspension tokens are runtime-bound, single-consumption capabilities; stale, duplicate, cross-runtime, and persisted-token use is rejected before resumption.

**Verification acceptance criteria:**

- [ ] Structural inspection finds all five schemas and their ownership helpers in the shared core files, with no deferred library surface or new core agent.
- [ ] Built-in `TypeId`s remain exactly 1–10; effect/handler/resume/abort tags remain exactly 32–35; pre-existing enum ordinals are unchanged.
- [ ] Canonical-row examples normalize to sorted unique IDs and preserve or clone the optional structural tail key.
- [ ] Every built-in layout passes the alignment/sized invariant and carries a stable key without a runtime address.
- [ ] A schema-4.0/helper-2.0 manifest distinguishes required from optional named features, rejects overlap/unknown required bits, and contains no host suspension token.
- [ ] Programs with branch-selected or superposed distinct effectful closures require `DYNAMIC_EFFECT_CLOSURES`; `run` and `aot-run` execute them through generic Delta, while `jit` rejects before MIR emission with a capability diagnostic.
- [ ] Ready-only external host operations require `HOST`, keep `SUSPENSION` optional, and remain MIR-eligible through explicit exact-slot helper enrollment; a manifest that truly requires `SUSPENSION` is rejected by direct `jit` before emission and routed to generic Delta by `aot-run`.
- [ ] Ownership review accounts for success, clone, partial-construction failure, and deinit paths without leaks or double frees.

## 2. Goals

- Add nominal abstract, concrete-final, and parametric runtime types.
- Use one low-punctuation `of` syntax for annotations and type application.
- Add optional typed fields, parameters, results, bindings, and constructor payloads.
- Add generic functions and deterministic multiple dispatch over all arguments.
- Keep method tables open in the REPL, with method epochs participating in semantic dispatch so updates affect the next applicable call.
- Expose minimal reflection through `typeOf(value)` and first-class `Type of T` values.
- Introduce serializable typed `DeltaProgram`/`NetImage` as the only executable semantic IR.
- Make `run`, `jit`, `repl`, `aot`, and `aot-run` consume the same Delta semantics.
- Replace direct `SurfaceExpr -> MirProgram` lowering with `DeltaProgram -> MIR` specialization.
- Evolve the source-free artifact contract to canonical AOT v4.0 over Delta schema 4.0; AOT v1-v3 and prior Delta schemas are rejected rather than upgraded.
- Preserve stable-slot allocation, eraser reclamation, Delta phase ordering, explicit parallel roots, and observable replicator boundaries.
- Add first-class deterministic superposition without adding a `SUP` core agent.

## 3. Quality Gates

These commands must pass for every user story. Core-lock behavior is additionally defended by permanent identity/effect-row, storage ownership, suspension isolation, and net-invariant tests.

```sh
c3c build mitos
c3c test
./build/mitos check examples/native_math.mitos
./build/mitos run examples/parallel_match.mitos --threads 2
./build/mitos jit examples/native_math.mitos
printf 'x := 20\nx + 22\n:quit\n' | ./build/mitos repl
./build/mitos aot examples/native_math.mitos build/native_math.mita
./build/mitos aot-run build/native_math.mita
./build/mitos check examples/superposition.mitos
./build/mitos run examples/superposition.mitos
./build/mitos jit examples/superposition.mitos
./build/mitos aot examples/superposition.mitos build/superposition.mita
./build/mitos aot-run build/superposition.mita
```

Expected observable results:

- Both `check` commands and both `aot` commands exit successfully without stdout.
- The native arithmetic/parallel `run`, `jit`, and `aot-run` paths print `42`.
- Superposition `run`, `jit`, and `aot-run` each print `[Pair(2, 11), Pair(2, 21), Pair(4, 12), Pair(4, 22)]`.
- REPL prints `20` and then `42`.
- `jit` never silently falls back to another backend. It rejects before MIR emission when the required-feature manifest contains a capability MIR does not advertise. `aot-run` uses that same predicate to deliberately select generic Delta; the currently named MIR exclusions are `SUSPENSION` and `DYNAMIC_EFFECT_CLOSURES`.
- The superposition commands are active quality gates, not illustrative snippets.

## 4. Locked Surface Syntax

### 4.1 Token meanings

| Token | Sole meaning |
|---|---|
| `:=` | immutable definition |
| `=` | value equality |
| `:` | open block or match arm |
| `of` | associate/apply a type |
| `is` | declare nominal supertype in a type header |
| `end` | close block |

`of` and `is` are lowercase keywords. `Of` and `Is` remain identifiers.

### 4.2 Type declarations

```mitos
abstract Number
abstract Real is Number
abstract Sequence of T

type I64 is Number

type Point of T:
  x of T
  y of T
end

type Vector of T is Sequence of T:
  length of I64
end

enum Option of T:
  Some(value of T)
  None
end
```

### 4.3 Typed values and methods

```mitos
point of Point of I64 := Point(20, 22)

add(x of I64, y of I64) of I64:
  x + y
end

add(x of Number, y of Number) of Number:
  numericFallback(x, y)
end

first(values of Array of T) of T:
  values(0)
end
```

Unresolved single-uppercase identifiers in a method signature are implicit method type variables. Unannotated parameters and results mean `Any`.

### 4.4 Type application

`of` is right-associative:

```text
Array of Option of I64 == Array of (Option of I64)
```

Multiple type arguments require grouping:

```mitos
Map of (String, I64)
Function of (A, B)
```

Angle brackets, square-bracket generic arguments, `::`, `<:`, `where`, and implicit argument conversion are rejected.

## 5. User Stories

### US-001: Parse type expressions and `of` annotations
**Description:** As a Mitos programmer, I want one readable type syntax so that typed and untyped code use the same low-punctuation grammar.

**Acceptance Criteria:**
- [ ] Add lexer tokens `OF`, `IS`, `ABSTRACT`, and `TYPE` with longest-token behavior preserving `:=` and `:`.
- [ ] Parse right-associative type application and grouped multi-argument application.
- [ ] Parse optional `of TypeExpr` on bindings, parameters, results, fields, and constructor payloads.
- [ ] Parse `abstract`, `type`, and parametric type headers with optional `is` supertype.
- [ ] Reject `::`, angle-bracket generics, square-bracket generics, and `where` clauses with positioned diagnostics.
- [ ] Existing unannotated Mitos programs remain accepted.

### US-002: Own type syntax in the source AST
**Description:** As the compiler, I want owned type-expression and declaration nodes so that validation and lowering never depend on parser token lifetimes.

**Acceptance Criteria:**
- [ ] Add owned `TypeExpr`, type-argument, abstract-type, concrete-type, and field declarations to `Program`.
- [ ] Add optional owned type annotations to definitions, parameters, results, and constructor payloads.
- [ ] Extend every deinitializer and failure-cleanup path for the new nodes.
- [ ] Preserve source spans for declarations, applications, and annotations.
- [ ] Enforce existing parser depth/count/resource ceilings for type syntax.

### US-003: Build the nominal TypeId registry
**Description:** As the runtime, I want compact immutable type identities so that graph values can dispatch without carrying full type expressions.

**Acceptance Criteria:**
- [ ] Define fixed-width `TypeId` and immutable `TypeDescriptor` records.
- [ ] Bootstrap `Any`, `Never`, `Type`, `I64`, `Bool`, and other required primitive descriptors at stable IDs.
- [ ] Register abstract/concrete type names and reject duplicate declarations.
- [ ] Enforce one nominal supertype, acyclic hierarchy, concrete-final semantics, and valid field layouts.
- [ ] Provide subtype queries with bounded traversal and deterministic results.
- [ ] Store the registry in program-lifetime arena memory, outside ordinary net reclamation.

### US-004: Intern parametric type instances
**Description:** As the runtime, I want canonical parametric type instances so that equivalent applications share one TypeId and dispatch identity.

**Acceptance Criteria:**
- [ ] Intern `(type constructor, type/value parameter tuple)` into one stable TypeId.
- [ ] Validate constructor arity and parameter kinds.
- [ ] Make `Array of Option of I64` and its explicitly grouped equivalent resolve identically.
- [ ] Represent `Type of T` as a first-class runtime value referring to T's TypeId.
- [ ] Bound registry growth and return diagnostics on resource exhaustion.

### US-005: Validate typed definitions and layouts
**Description:** As a programmer, I want annotations to catch mismatches without turning Mitos into a static-only language.

**Acceptance Criteria:**
- [ ] Unannotated bindings, parameters, and results accept `Any`.
- [ ] `name of T := value` checks the resulting runtime value is a subtype of T.
- [ ] Typed constructor fields and payloads are checked at construction.
- [ ] Typed function results are checked before returning.
- [ ] Argument values are never implicitly converted during method dispatch.
- [ ] Type failures report expected and actual nominal type names.

### US-006: Convert functions into generic method sets
**Description:** As a programmer, I want several methods under one function name so that behavior can vary by all argument types.

**Acceptance Criteria:**
- [ ] Replace duplicate-function rejection with generic-function method registration.
- [ ] Group methods by function name and arity.
- [ ] Store each method's parameter type patterns, result constraint, type variables, body, and source order metadata.
- [ ] Reject exact duplicate signatures.
- [ ] Keep unannotated methods as `Any` catch-all methods.
- [ ] Constructors and generic functions cannot occupy the same callable name.

### US-007: Implement parametric signature matching
**Description:** As the dispatcher, I want to bind signature type variables so that generic methods work for concrete argument tuples.

**Acceptance Criteria:**
- [ ] Match concrete TypeIds against nominal, abstract, and parametric signature expressions.
- [ ] Bind one implicit single-uppercase type variable consistently across a method signature.
- [ ] Reject inconsistent repeated bindings such as incompatible `Pair of (T, T)` arguments.
- [ ] Apply bound type variables to result constraints and method-body type references.
- [ ] Perform matching without allocating ordinary graph values.

### US-008: Select the unique most-specific method
**Description:** As a caller, I want deterministic multiple dispatch so that definition order never changes behavior.

**Acceptance Criteria:**
- [ ] Filter methods by function, arity, and applicable parameter tuple.
- [ ] Define A as more specific than B when every A parameter is a subtype/specialization of B and at least one is strict.
- [ ] Select the unique maximal applicable method.
- [ ] Emit `MethodError` when none applies.
- [ ] Emit `AmbiguousMethodError` with candidate signatures when several incomparable maxima apply.
- [ ] Do not use declaration order as a tie breaker.

### US-009: Define typed DeltaProgram as the sole executable IR
**Description:** As a backend maintainer, I want one serializable semantic program image so that `run`, `jit`, REPL, and AOT cannot diverge.

**Acceptance Criteria:**
- [ ] Add `DeltaProgram`/`NetImage` records for type registry, generic functions, methods, constructors, primitives, interfaces, agents, wires, parallel roots, and joins.
- [ ] Give every executable value/constructor/closure/primitive node a compact TypeId field.
- [ ] Represent integers, operations, constructors, matching, generic calls, and reflection explicitly rather than as free-name strings.
- [ ] Preserve FAN/REPLICATOR/ERASER as the core sharing/erasure calculus.
- [ ] Make the format independently owned and serializable without source AST pointers.

### US-010: Lower source exactly once into DeltaProgram
**Description:** As the compiler, I want all backends to share one lowering so that semantic behavior is defined in one place.

**Acceptance Criteria:**
- [ ] Implement `Program -> DeltaProgram` for methods, types, values, calls, matching, definitions, and parallel blocks.
- [ ] Remove primitive post-readback recognition based on names such as `mitos.add`.
- [ ] Preserve simultaneous sibling-invisible parallel bindings as multiple demanded roots plus one join continuation.
- [ ] Carry source spans into diagnostic metadata without retaining source text pointers.
- [ ] Reject unsupported source before selecting a runtime backend.

### US-011: Add typed value and primitive Delta agents
**Description:** As the Delta runtime, I want practical typed agents so that dynamic values do not require Church encoding or free-name interpretation.

**Acceptance Criteria:**
- [ ] Add agents for I64 values, constructors, generic calls/dispatch, type values, type assertions, and required primitive operations.
- [ ] Define principal/auxiliary ports and local interaction/reification rules for every new agent.
- [ ] Preserve opposite-polarity wiring, exact ownership, generation checks, and eraser propagation.
- [ ] Dropping typed values attaches erasers and returns stable slots without tracing GC.
- [ ] Extend validation and readback for all practical agents.

### US-012: Execute generic dispatch in Delta
**Description:** As the Delta machine, I want calls to select methods from runtime value types while preserving laziness and parallelism.

**Acceptance Criteria:**
- [ ] A dispatch node demands each argument only to weak-head form sufficient to reveal TypeId.
- [ ] Independent argument type demands can enter the existing fixed worker scheduler concurrently.
- [ ] Dispatch resolves through the method table and rewires to the selected Delta method body.
- [ ] Shared arguments are not duplicated merely to inspect a type tag.
- [ ] Dispatch errors are first-class deterministic runtime diagnostics.

### US-013: Route generic `run` through typed DeltaProgram
**Description:** As a user, I want the reference runtime to execute the same typed image used by every backend.

**Acceptance Criteria:**
- [ ] `run` materializes `DeltaProgram` into `StableSlotArena` and executes both Delta phases.
- [ ] Type assertions, method dispatch, constructors, matching, recursion, primitives, and parallel roots execute through Delta.
- [ ] Readback formats typed values and type objects without consulting the source AST.
- [ ] Existing untyped arithmetic and parallel examples still print `42`.

### US-014: Replace surface MIR lowering with DeltaProgram MIR lowering
**Description:** As a JIT user, I want MIR to specialize the Delta machine rather than define a second Mitos implementation.

**Acceptance Criteria:**
- [ ] Delete direct `Program/SurfaceExpr -> MirProgram` lowering from `src/mitos_jit.c3`.
- [ ] Add `DeltaProgram -> MIR` lowering for net materialization, phase loops, agent-pair dispatch, typed primitives, method dispatch, and readback.
- [ ] Generated MIR specializes constructor/type tables and omits impossible agent-pair cases for the program.
- [ ] MIR preserves Delta phase barriers, stable-slot generations, eraser rules, and explicit parallel-root scheduling.
- [ ] MIR does not merely emit one call to the generic Delta runtime.
- [ ] `run` and `jit` produce identical values/errors for the typed dispatch example.

### US-015: Specialize each Delta program in MIR
**Description:** As a JIT user, I want concrete calls specialized from the current lowered program so that MIR improves execution without changing semantics.

**Acceptance Criteria:**
- [ ] Each MIR context specializes one `DeltaProgram`; a later successful REPL entry reparses and lowers the retained source before MIR specializes the new current image.
- [ ] Compile the selected Delta method body, not the source AST method.
- [ ] Eliminate redundant dispatch and type assertions where the current program proves a concrete call tuple.
- [ ] Unbox stable primitive layouts where ABI and escape rules permit.

### US-016: Support open method tables in the REPL
**Description:** As a REPL user, I want to add methods interactively and have later calls use them immediately.

**Acceptance Criteria:**
- [ ] REPL retains type and method declarations in addition to immutable bindings.
- [ ] Adding or replacing a method increments only that generic function's epoch.
- [ ] Method epochs participate in semantic dispatch, and every successful entry reparses and lowers the retained source into the current `DeltaProgram`.
- [ ] The next call sees the newest unique most-specific method.
- [ ] `typeOf(value)` returns a first-class `Type of T` value in the REPL.
- [ ] No Julia-style world-age restriction is introduced.

### US-017: Persist typed DeltaProgram schema 4.0 in AOT v4
**Description:** As an AOT user, I want artifacts to preserve Mitos's Delta paradigm, type/method semantics, effects, layouts, and observable superpositions rather than backend-specific MIR instructions.

**Acceptance Criteria:**
- [ ] Serialize Delta schema 4.0 in canonical little-endian AOT v4 with major/minor/header-length/artifact-length header fields and a required manifest as the first tagged record.
- [ ] Emit deterministic ascending singleton records with explicit REQUIRED or OPTIONAL flags and checked `u64` payload lengths.
- [ ] Persist the program `ModuleKey`, every persistent `SymbolKey` and owner, method identity/coherence, resolved effect rows and optional tails, `TypeId`-indexed layouts and copy policies, type/effect/graph/superposition metadata, and schema/helper required and optional capabilities.
- [ ] Accept higher compatible minors when every required feature and record is supported; skip unknown optional records exactly by bounded length; reject unknown required, missing, duplicate, misflagged, out-of-order, feature-incoherent, truncated, overflowing, and trailing records.
- [ ] Prove structural lengths, counts, and allocation budgets before allocating decoded collections; validate semantic identities, owners, TypeIds, method/local-ID mappings, rows, layouts, ports, wires, origins, observable markers, and ABI fields after reconstruction but before execution.
- [ ] Never serialize runtime registries, storage handles, pointers, callbacks, refcounts, views, live resources, execution contexts, suspension tokens, or resumption tokens.
- [ ] `aot-run` invokes generic or MIR-specialized Delta execution without parsing or lowering source.
- [ ] AOT versions 1, 2, and 3 fail with an explicit unsupported-version diagnostic; no compatibility loader upgrades them.

### US-018: Add minimal type reflection
**Description:** As a programmer, I want to inspect a value's type without exposing the entire runtime registry.

**Acceptance Criteria:**
- [ ] Implement `typeOf(value)` returning a first-class type value.
- [ ] Format type values using canonical `of` syntax.
- [ ] Support equality and method dispatch on type values.
- [ ] Do not expose mutable registry access, full field enumeration, method enumeration, or runtime type creation.

### US-019: Produce precise typed diagnostics
**Description:** As a programmer, I want method and type failures to explain the actual mismatch.

**Acceptance Criteria:**
- [ ] Type assertion errors include expected and actual types.
- [ ] Method errors include generic name and concrete argument tuple.
- [ ] Ambiguity errors list all maximal candidate signatures in stable order.
- [ ] Parametric mismatch errors identify the conflicting type-variable binding.
- [ ] Diagnostics retain source position where source metadata exists.

### US-020: Remove duplicate semantic paths and stale artifacts
**Description:** As a maintainer, I want one current architecture so future changes cannot accidentally target obsolete backends.

**Acceptance Criteria:**
- [ ] Remove direct surface MIR runtime helpers and pre-v4 AOT constants and files.
- [ ] Production search finds no direct `SurfaceExpr` dependency in the MIR backend.
- [ ] Documentation and examples describe Delta-first JIT, typed AOT v4, open methods, `of` syntax, and deterministic superposition only.
- [ ] Existing AOT v1-v3 artifacts fail with an explicit unsupported-version diagnostic.

### US-021: Add typed dispatch examples and complete CLI smoke
**Description:** As a user, I want concrete examples proving generic Delta execution, MIR specialization, REPL method updates, and typed AOT artifacts.

**Acceptance Criteria:**
- [ ] Add a `.mitos` example with abstract/concrete/parametric declarations and at least three methods of one generic function.
- [ ] `check` accepts the example.
- [ ] Delta `run` and MIR `jit` print the same result.
- [ ] REPL can add a more-specific method and observe it on the next call.
- [ ] AOT v4 creation and `aot-run` print the same result.
- [ ] No tests are added or run.

## 6. Functional Requirements

- FR-1: Mitos must remain dynamically typed; runtime values, not immutable names, own concrete types.
- FR-2: All concrete runtime values must carry a valid concrete TypeId.
- FR-3: Concrete types must be final and have at most one nominal supertype.
- FR-4: Abstract types must not be directly instantiated.
- FR-5: Parametric type applications must be interned and canonical.
- FR-6: `of` must be right-associative; grouped tuples must represent multiple type arguments.
- FR-7: `is` must be legal only in type headers.
- FR-8: Unannotated parameters/results must mean `Any`.
- FR-9: Annotations must constrain dispatch and assert runtime values; they must not trigger implicit conversion.
- FR-10: Generic functions must dispatch on all argument TypeIds.
- FR-11: Method specificity must be based on subtype/parametric containment, never declaration order.
- FR-12: Ambiguous calls must fail rather than select arbitrarily.
- FR-13: Method tables must remain open in the REPL and use per-generic epochs.
- FR-14: DeltaProgram must be the sole executable semantic IR.
- FR-15: Generic and MIR runtimes must consume identical DeltaProgram semantics.
- FR-16: MIR must specialize Delta execution, not independently lower SurfaceExpr.
- FR-17: Parallel argument demands and explicit parallel roots must use the fixed Delta worker scheduler.
- FR-18: Type metadata must live in program-lifetime arenas; ordinary values remain eraser-reclaimed stable slots.
- FR-19: `typeOf` and `Type of T` are the only initial public reflection facilities.
- FR-20: AOT v4 must serialize Delta schema 4.0 through manifest-first feature-negotiated records and reject artifact versions 1 through 3.
- FR-21: All parsers, loaders, and registries must retain existing bounded-resource behavior; structural safety precedes allocation and semantic/reference validation precedes execution.
- FR-22: No backend may silently fall back to another backend.
- FR-23: `superpose` must be nonempty, eager, source ordered, and homogeneous by concrete runtime TypeId after nested flattening.
- FR-24: `superpose` must produce `Superposition of T`; `collapse` must require that type strictly and produce an ordered `Array of T`.
- FR-25: Every lowered source node must retain its stable origin in `DeltaNode.descriptor`.
- FR-26: Repeated occurrences of one origin must correlate branch indexes.
- FR-27: Distinct origins must enumerate a lexicographic Cartesian product ordered by origin encounter and then branch position.
- FR-28: Nested superpositions must flatten without losing existing origin assignments.
- FR-29: Operations, constructors, generic calls, lambdas/applications, and matches must lift over compatible alternatives.
- FR-30: The first observable branch error or effect must follow source order under every worker count and backend.
- FR-31: Observable superposition must cross a marked `REPLICATOR` boundary with a `PARENT` principal and `CHILD` auxiliaries.
- FR-32: No core `SUP` agent may be introduced.
- FR-33: Uncollapsed superpositions must format as `superpose(a, b)` and collapsed arrays as `[a, b]`.
- FR-34: Existing effect tags 32 through 35 and all prior enum ordinals must remain stable.
- FR-35: Helper ABI 2.0 must advertise superposition with the named `DELTA_FEATURE_SUPERPOSITION` bit.
- FR-36: The `Superposition` type constructor must retain reserved built-in TypeId 10.

## 7. Non-Goals

- Union types or `UnionAll` in the first typed release.
- Structural typing, duck-typed field constraints, traits, or interfaces.
- Mutable fields, mutable bindings, or object-oriented method ownership.
- Implicit argument conversion or Julia-style promotion tables.
- Full reflection over fields, methods, or mutable type construction.
- Julia world-age semantics.
- Native object/executable emission from MIR v1.
- GPU execution or a second JIT backend.
- Compatibility loading for AOT v1 or v2 artifacts.
- Tests that do not defend an observable contract.

## 8. Technical Architecture

### 8.1 Compiler pipeline

```text
Mitos source
  -> owned Program + TypeExpr
  -> TypeRegistry + GenericFunctionTable
  -> typed DeltaProgram / NetImage
       -> generic Delta execution (`run`)
       -> MIR-specialized Delta execution (`jit`, REPL)
       -> serialized DeltaProgram schema 4.0 (`aot`)
```

### 8.2 Runtime metadata

```text
TypeDescriptor {
  TypeId id
  name
  kind: abstract | concrete | parametric-instance | type-value
  supertype
  constructor
  parameters
  immutable field layout
}

GenericFunction {
  id
  name
  arity-indexed method sets
  epoch
}

Method {
  id
  parameter TypeExpr patterns
  result TypeExpr constraint
  type variables
  DeltaProgram body root
}
```

### 8.3 Delta practical agents

```text
FAN / REPLICATOR / ERASER      core ΔK
I64_VALUE                      typed primitive value
CONSTRUCTOR_VALUE              typed immutable fields
GENERIC_CALL / DISPATCH        multiple dispatch
TYPE_VALUE / TYPE_ASSERT       minimal reflection and constraints
PRIMITIVE_OP                    typed arithmetic/comparison
PARALLEL_ROOT / JOIN           explicit simultaneous bindings
EFFECT_OP / HANDLER / RESUME   reserved phase-two algebraic-effect forms
```

### 8.4 MIR specialization boundary

MIR receives one current `DeltaProgram` and produces a specialization scoped to that program image. Generated code owns:

- program-specific net materialization;
- Delta phase-one and phase-two loops;
- specialized agent-pair dispatch;
- typed primitive operations;
- method-instance entry points;
- program-specific constructor/type tables;
- readback/formatting entry.

Dynamic nodes and stable slots remain runtime data because rewrites create and retire graph records.

## 9. Phase Two: Algebraic Effects

Algebraic effects are the locked phase-two control model. They fit Delta execution because a captured continuation is already a graph root: zero resumptions attach an eraser, one resumption is a direct wire, and multiple resumptions use a replicator rather than copying a stack.

The typed foundation reserves stable effect/opcode ID ranges, an effect record in DeltaProgram/AOT v4, versioned runtime-helper slots, and practical-agent tags so effects and superposition share one artifact and helper contract.

### 9.1 Locked effect syntax

```mitos
effect Console:
  print(text of String) of Unit
end

effect State of S:
  get() of S
  put(value of S) of Unit
end

multi effect Choose of T:
  pick(values of Array of T) of T
end

greet(name of String) of Unit does Console:
  Console.print(name)
end

main():
  handle greet(\"Ada\"):
    Console.print(text):
      resume(Unit)
    return(value):
      value
  end
end
```

- `effect` declares a nominal, optionally parametric effect.
- Qualified operation calls such as `Console.print(value)` perform the effect; there is no extra `perform` keyword.
- `does Effect` or `does (EffectA, EffectB)` is an optional method effect-row assertion. Omitted rows are inferred.
- `handle expression:` installs the nearest lexical handler.
- `resume(value)` resumes the captured continuation.
- Returning from an operation clause without `resume` aborts that continuation and erases its graph.
- Resumptions are one-shot by default. `multi effect` explicitly permits multiple resumptions.

### 9.2 Effect runtime model

```text
EFFECT_OP(effect_id, operation_id, arguments, continuation)
HANDLER(effect_set, clauses, return_clause, body)
RESUME(continuation, value)
ABORT(continuation)
```

An effect operation travels outward through handler boundaries until the nearest matching handler is found. The continuation is represented as a stable Delta subgraph root, not a copied native stack.

External effects such as console or filesystem operations terminate at registered host handlers. Pure user handlers remain ordinary DeltaProgram method bodies.

### US-022: Parse effect declarations, rows, and handlers
**Description:** As a Mitos programmer, I want terse algebraic-effect syntax that follows the same word-oriented grammar as types and matching.

**Acceptance Criteria:**
- [ ] Add `effect`, `multi`, `does`, `handle`, `resume`, and `return` effect-context tokens.
- [ ] Parse nominal/parametric effect declarations and typed operations.
- [ ] Parse optional single/grouped `does` rows on methods and lambdas.
- [ ] Parse handler operation clauses and one return clause.
- [ ] Reject duplicate operation names, duplicate clauses, and `resume` outside a handler clause.

### US-023: Build the effect registry and inferred rows
**Description:** As the compiler, I want stable effect identities and bounded row inference so Delta and MIR share one effect model.

**Acceptance Criteria:**
- [ ] Add stable `EffectId` and `OperationId` descriptors to DeltaProgram.
- [ ] Resolve nominal/parametric effects through the TypeId registry.
- [ ] Infer transitive method effect rows to a fixpoint.
- [ ] Treat explicit `does` rows as runtime/compiler assertions.
- [ ] Diagnose unhandled declared effects and recursive inference overflow.

### US-024: Add effect and handler Delta agents
**Description:** As the Delta runtime, I want operations and handlers represented in the graph rather than native stack exceptions.

**Acceptance Criteria:**
- [ ] Add practical agents/forms for EFFECT_OP, HANDLER, RESUME, and ABORT.
- [ ] Preserve nearest lexical handler semantics during rewrites.
- [ ] Capture continuation roots with stable generations and exact ownership.
- [ ] Extend validation, serialization, readback, and eraser propagation.
- [ ] Report unhandled effects deterministically.

### US-025: Implement one-shot continuation semantics
**Description:** As a handler author, I want default resumptions to be linear so resources and effects remain predictable.

**Acceptance Criteria:**
- [ ] A one-shot continuation may be resumed at most once.
- [ ] One resume connects the supplied value directly to the continuation hole.
- [ ] A clause returning without resume attaches an eraser to the continuation.
- [ ] A second resume produces a deterministic continuation-use error.
- [ ] One-shot continuation state survives parallel scheduling and stale-work checks.

### US-026: Implement multi-shot effects through replicators
**Description:** As a search/choice handler author, I want explicit multi-shot continuation sharing without native stack copying.

**Acceptance Criteria:**
- [ ] Only operations declared under `multi effect` permit multiple resumes.
- [ ] Multiple resumes create a paired replicator structure over the continuation root.
- [ ] Same-origin continuation paths correlate; independent origins commute through Delta level/delta rules.
- [ ] Discarded branches receive erasers.
- [ ] Branch results retain source resume order.

### US-027: Define deterministic effects under `parallel`
**Description:** As a parallel Mitos programmer, I want effect ordering to be explicit and reproducible.

**Acceptance Criteria:**
- [ ] Pure handled effects may execute independently in parallel roots.
- [ ] External or ordered effects are queued at their handler boundary.
- [ ] Observable ordered effects commit in source-root order.
- [ ] Multi-shot branch effects preserve branch order and handler scope.
- [ ] Unhandled effects select the first source-order error.

### US-028: Specialize effects in Delta-first MIR
**Description:** As a JIT user, I want handled effects optimized without bypassing Delta semantics.

**Acceptance Criteria:**
- [ ] MIR consumes DeltaProgram effect/handler agents, never surface effect AST directly.
- [ ] Statically known handlers remove generic handler lookup.
- [ ] Closed handler clauses may inline into specialized method instances.
- [ ] One-shot resume may lower to a direct native continuation edge.
- [ ] External effects call versioned runtime-helper slots with exact ABI signatures, and every ready-only helper is explicitly enrolled for its operation.
- [ ] Ready-only host operations return `HOST_READY` or `HOST_FAIL`, require `HOST` while keeping `SUSPENSION` optional and MIR-eligible; operations that may return `HOST_SUSPEND` require `SUSPENSION`, so direct `jit` rejects before emission and `aot-run` selects generic Delta.

### US-029: Persist effects in REPL and AOT
**Description:** As an interactive/AOT user, I want effects to survive the same program-image lifecycle as types and methods.

**Acceptance Criteria:**
- [ ] REPL persists effect declarations and handler methods.
- [ ] Effect changes are reflected when the next successful entry reparses and lowers the retained source into the current `DeltaProgram`.
- [ ] AOT DeltaProgram artifacts serialize effect registry, operation signatures, rows, handlers, and helper requirements.
- [ ] AOT loading rejects missing/incompatible host handlers before execution.
- [ ] AOT v4 artifacts with an empty effect registry remain valid for programs that declare no effects.

### US-030: Add algebraic-effect examples and smoke
**Description:** As a user, I want examples proving one-shot, aborting, multi-shot, parallel, MIR, REPL, and AOT effect behavior.

**Acceptance Criteria:**
- [ ] Add a deterministic state or reader handler example.
- [ ] Add a one-shot abort example showing eraser cleanup.
- [ ] Add a multi-shot choice example backed by replicators.
- [ ] Generic Delta `run` and MIR `jit` produce identical results.
- [ ] REPL and AOT effect smoke succeed without adding or running tests.

### 9.3 Effect persistence requirements

- Keep effect and operation ID namespaces stable in DeltaProgram.
- Serialize the effect registry in AOT v4.
- Version the MIR/native runtime-helper table independently from artifact layout, and explicitly enroll every ready-only helper in its exact operation slot.
- Keep `SUSPENSION` optional for ready-only host operations that return `HOST_READY` or `HOST_FAIL`; require it only when the helper contract may retain execution and return `HOST_SUSPEND`.
- Keep practical-agent tags for EFFECT_OP, HANDLER, RESUME, and ABORT stable.
- Serialize only static handler roots and requirements; live continuation/resumption tokens remain runtime-only.

### 9.4 Phase-two non-goals

- Native stack unwinding or exception-based handlers.
- Implicit multi-shot continuations.
- Thread-local dynamic handler stacks outside DeltaProgram.
- Unordered external IO from parallel roots.
- Effect polymorphism beyond inferred/explicit finite rows in the first effect release.

## 10. Phase Three: Deterministic Superposition

Phase three adds explicit deterministic alternatives to the typed Delta image. Superposition is a language/runtime protocol around the existing sharing calculus: the physical boundary is a marked core `REPLICATOR`, not a new core agent.

### 10.1 Locked source semantics

```mitos
enum Observation:
  Pair(correlated of I64, cartesian of I64)
end

main():
  shared := superpose(1, 2)
  independent := superpose(10, 20)
  collapse(Pair(shared + shared, shared + independent))
end
```

The canonical result is `[Pair(2, 11), Pair(2, 21), Pair(4, 12), Pair(4, 22)]`. The repeated `shared` origin correlates in both fields; `independent` forms the inner dimension of the lexicographic Cartesian product.

### US-031: Validate and type superposition
**Description:** As a Mitos programmer, I want explicit alternatives with one reliable element type so invalid branch sets fail before observation.

**Acceptance Criteria:**
- [ ] `superpose` requires at least one argument and eagerly evaluates arguments in source order.
- [ ] Nested superpositions recursively flatten before homogeneity is checked.
- [ ] Every flattened alternative has exactly the same concrete runtime `TypeId`; sharing only an abstract parent is insufficient.
- [ ] A valid expression has runtime type `Superposition of T`.
- [ ] The `Superposition` type constructor retains reserved built-in `TypeId` 10 and prior TypeId assignments remain unchanged.
- [ ] Empty or heterogeneous calls produce positioned diagnostics.
- [ ] `superpose` and `collapse` remain reserved built-ins and cannot be redeclared as methods.

### US-032: Correlate stable origins and enumerate products
**Description:** As a Mitos programmer, I want repeated choices to stay correlated while independent choices compose predictably.

**Acceptance Criteria:**
- [ ] Every lowered source node stores a stable origin in `DeltaNode.descriptor`.
- [ ] Every alternative carries an origin-to-branch assignment map.
- [ ] Combining occurrences of the same origin accepts only equal branch indexes.
- [ ] Distinct origins form a Cartesian product ordered lexicographically by first origin encounter, then source branch position.
- [ ] Nested flattening preserves all existing assignments and their encounter order.
- [ ] Re-evaluation under a different worker count produces the same ordered assignments.

### US-033: Lift language constructs and preserve observations
**Description:** As a Mitos programmer, I want ordinary expressions to operate pointwise on alternatives without losing dispatch, pattern, error, or effect semantics.

**Acceptance Criteria:**
- [ ] Arithmetic and comparison operations lift over compatible alternatives.
- [ ] Constructors, generic calls, lambda creation/application, and matches lift over compatible alternatives.
- [ ] Generic dispatch and match arm selection use each alternative's concrete runtime value.
- [ ] Lifted results retain the merged origin assignment map.
- [ ] The first branch error is selected in source order.
- [ ] Effects commit in source order, including lifted work scheduled in parallel.

### US-034: Expose superposition through observable replicators
**Description:** As a Delta maintainer, I want superposition to reuse the physical sharing calculus so there is no second fan-out mechanism.

**Acceptance Criteria:**
- [ ] Extend `new_replicator(..., Polarity principal_polarity, bool observable = false, ulong origin = 0)`.
- [ ] Extend `Replicator` with persisted `observable` and `origin` fields.
- [ ] A physical superposition uses a marked `REPLICATOR` with a `PARENT` principal and `CHILD` auxiliaries.
- [ ] Practical `DELTA_SUPERPOSE` and `DELTA_COLLAPSE` nodes lower through the marked boundary.
- [ ] Practical `COLLAPSE_AGENT` and `ARRAY_AGENT` perform observation and ordered materialization.
- [ ] No `SUP` member is added to the core agent enum.
- [ ] Existing effect tags 32 through 35 and every prior enum ordinal remain unchanged.

### US-035: Collapse strictly and format canonically
**Description:** As a Mitos programmer, I want one explicit observation operation whose result is stable and inspectable.

**Acceptance Criteria:**
- [ ] `collapse` accepts exactly one argument of runtime type `Superposition of T`.
- [ ] Passing an ordinary value is an error; it is not promoted to a singleton superposition.
- [ ] The result is a variable-length `Array of T` in deterministic assignment order.
- [ ] Empty output is impossible for a valid nonempty superposition.
- [ ] Uncollapsed superpositions format as `superpose(a, b)` and collapsed arrays format as `[a, b]`, including singleton and nested constructor values.

### US-036: Carry superposition through Delta, MIR, helpers, and AOT
**Description:** As a backend user, I want run, native execution, and artifacts to implement one superposition contract.

**Acceptance Criteria:**
- [ ] Delta schema version is 4.0 and serializes superposition nodes, stable origins, and observable replicator fields as tagged records.
- [ ] MIR preserves correlation, Cartesian order, nested flattening, lifting, and source-ordered observations from the Delta image.
- [ ] Runtime helper ABI 2.0 publishes `DELTA_FEATURE_SUPERPOSITION` and validates the required/optional manifest before superposition execution.
- [ ] AOT version 4 persists all required Delta/helper metadata and negotiates additive optional capabilities.
- [ ] AOT versions 1 through 3 are rejected cleanly without partial upgrade or execution.
- [ ] `run`, `jit`, and `aot-run` produce byte-identical canonical results for the same program.

### US-037: Publish the deterministic example and active smoke
**Description:** As a user, I want an executable example that makes correlation and Cartesian composition visible.

**Acceptance Criteria:**
- [ ] Add `examples/superposition.mitos` using current Mitos syntax.
- [ ] The example repeats one origin and combines it with one distinct origin in the same collapsed result.
- [ ] The example states the expected output `[Pair(2, 11), Pair(2, 21), Pair(4, 12), Pair(4, 22)]`.
- [ ] The Quality Gates run `check`, `run`, `jit`, `aot`, and `aot-run` on the example.
- [ ] The three executing backends print the stated output.
- [ ] No tests are added or run.

### 10.2 Phase-three non-goals

- A `SUP` core interaction agent or a second fan-out calculus.
- Lazy branch creation or unordered branch observation.
- Implicit collapse, implicit singleton promotion, or heterogeneous alternatives.
- Probabilistic, weighted, fair-search, or breadth-first choice policies.
- Compatibility loading for AOT v1 or v2.

## 11. Post-Core Phase Four: Effect-Mediated State and Affine Mutation

This is a planned library/runtime-adapter phase, not a new core-lock seam. Mitos keeps immutable bindings and fields. Logical state is expressed through algebraic effects; actual in-place mutation is exposed only through an opaque affine resource backed by the existing layout, storage, generation, eraser, and runtime-local registry contracts.

### 11.1 Locked direction

- Do not add assignment, mutable fields, ambient references, or a generally shared mutable `Box`.
- Retain `:=` exclusively for immutable definitions.
- Use the existing parametric `State of S` effect for logical state. Its standard handler threads immutable state through resumptions and defines branch, abort, and return behavior without requiring mutable language values.
- Reserve `Box of T`, if it is ever introduced, for immutable allocation/indirection. Name mutable identity explicitly `Cell of T` or `BufferBuilder of T`.
- Make `Cell of T` an opaque library-level affine resource with runtime-local identity and a generation-bearing storage handle. It is never a raw address, serializable live handle, constructor field with implicit copy semantics, or new core agent.
- Mediate creation, reads, writes, and freezing through a declared effect so effect rows expose stateful behavior and handler boundaries define ordering and lifetime.

Proposed library surface:

```mitos
effect Cells of T:
  create(initial of T) of Cell of T
  read(cell of Cell of T) of T
  write(cell of Cell of T, value of T) of Unit
  freeze(cell of Cell of T) of T
end
```

`freeze` consumes the affine capability, invalidates its generation, and returns an immutable value. Replication of a live cell is rejected. A caller must explicitly freeze it, request an independent snapshot, or opt into a separately specified synchronized shared resource.

### US-038: Publish a pure State handler

**Description:** As a Mitos programmer, I want ordinary logical state without ambient mutation so state remains visible in effect rows and deterministic across handlers.

**Acceptance Criteria:**
- [ ] Provide a standard `State of S` handler example implementing `get` and `put` by threading immutable handler state.
- [ ] Return both the computation result and final state through an immutable nominal value.
- [ ] Nested state handlers obey nearest lexical handler selection.
- [ ] A one-shot operation clause that aborts discards the continuation's uncommitted state.
- [ ] Multi-shot resumption starts each resumed path from an explicit state snapshot and preserves source resume order.
- [ ] Generic Delta, MIR where supported, REPL, and AOT-run agree on result and final state.

### US-039: Add an opaque affine Cell adapter

**Description:** As a library or host-adapter author, I want bounded in-place updates for buffers, FFI, and performance-sensitive local algorithms without introducing general shared mutation.

**Acceptance Criteria:**
- [ ] Define opaque `Cell of T` identity separately from immutable `Box of T` semantics.
- [ ] Back every cell with a runtime-local generation-bearing handle and `COPY_AFFINE`; persist only its static type/layout/helper requirements.
- [ ] Implement effect-mediated `create`, `read`, `write`, and consuming `freeze` operations with checked type, runtime, generation, bounds, and lifecycle validation.
- [ ] Reject stale, frozen, cross-runtime, cross-program, or double-released cells before access.
- [ ] Erasers, handler exit, abort, cancellation, and partial construction release cell storage exactly once.
- [ ] Reject implicit replication through constructors, superposition, parallel capture, or multi-shot continuation capture unless an explicit snapshot/freeze/synchronized-sharing policy applies.
- [ ] Generic Delta and every advertised backend agree on successful results and deterministic rejection diagnostics.

### US-040: Prove branch and concurrency policy before sugar

**Description:** As a language designer, I want mutation behavior under replication to be explicit before considering convenient surface syntax.

**Acceptance Criteria:**
- [ ] Demonstrate branch-local `State` behavior under superposition and multi-shot effects.
- [ ] Demonstrate that two distinct state handlers do not alias.
- [ ] Demonstrate deterministic rejection of an affine cell shared across simultaneous parallel roots.
- [ ] Keep synchronized `SharedCell`/`AtomicCell`, transaction, lock, and scheduler policy as separate libraries or host effects.
- [ ] Do not add `var`, reassignment with `=`, mutable fields, or mutation operators in this phase.
- [ ] Any future mutation sugar must lower to the effect API and must not change the meaning of `:=`.

### 11.2 Phase-four non-goals

- A mutable-by-default object model.
- Implicit aliasing or copy-on-write for affine resources.
- Serializing live cells, storage handles, host addresses, locks, or callbacks.
- Treating effect implementation state as justification for ambient language mutation.
- Silently choosing alias, snapshot, or synchronization semantics at a replicator.

## 12. Implementation Order

1. Type grammar and owned AST.
2. Type registry and parametric interning.
3. Generic method tables and specificity.
4. Typed DeltaProgram format and source lowering.
5. Practical typed Delta agents and dispatch.
6. Generic typed Delta execution.
7. Per-program `DeltaProgram`-to-MIR specialization.
8. REPL open-method epochs and minimal reflection.
9. Delta schema 4.0 in AOT v4 artifacts with clean prior-schema and v1-v3 rejection.
10. Remove direct surface MIR and legacy AOT paths.
11. Typed examples, documentation, and complete CLI smoke.
12. Algebraic effects US-022 through US-030.
13. Deterministic superposition US-031 through US-037.
14. Pure `State of S` standard handler and deterministic branch examples.
15. Opaque affine `Cell of T` adapter over the locked storage/runtime seams.
16. Mutation ergonomics only after state, lifecycle, replication, and parallel policy gates pass.

Each step must leave `c3c build mitos` and the active CLI quality-gate smoke passing.

## 13. Success Metrics

- One typed dispatch program returns the same value under `run`, `jit`, REPL, and `aot-run`.
- Adding a more-specific method in the REPL changes the next applicable call without restarting.
- `typeOf` returns a stable, correctly formatted first-class type value.
- MIR production modules contain no direct `SurfaceExpr` lowering.
- AOT v4 artifacts contain no MirProgram instruction section and invoke no source parser/lowerer.
- AOT versions 1 through 3 fail cleanly before reconstruction.
- Existing untyped arithmetic and parallel examples continue to produce `42`.
- No tracing GC, backend fallback, alternate JIT, compatibility type syntax, or `SUP` core agent is introduced.
- One-shot and multi-shot effect examples agree under Delta and MIR execution.
- The superposition example returns the stated correlated Cartesian array under `run`, `jit`, and `aot-run`.
- Helper ABI 2.0 and `DELTA_FEATURE_SUPERPOSITION` gate every superposition-capable native path.
- A pure State example returns the same result and final state under every advertised backend.
- Affine cells reject stale, cross-runtime, frozen, replicated, and multiply consumed handles deterministically.
- No mutable binding, mutable field, implicit shared box, new core agent, or serialized live resource is introduced.

## 14. Open Questions

The typed/effect/superposition core and its v4 backend contract remain locked. The planned post-core mutation phase must resolve two questions before implementation: the most economical surface form for passing immutable state through handlers, and whether one-shot closure capture of an affine cell is permitted or all continuation capture requires an explicit resource policy. Library packaging, dependency resolution, synchronized shared cells, and cross-artifact linking remain deferred.
[/PRD]
