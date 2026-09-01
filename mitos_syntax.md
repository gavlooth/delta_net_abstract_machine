# Mitos syntax

Mitos source files use the `.mitos` extension. A complete program declares one or more methods and must provide a zero-argument `main()` method. Parsing and validation produce an owned typed `DeltaProgram`; the Delta runtime, MIR JIT, REPL, and AOT v4 all consume that same semantic image.

There is no legacy Core execution path. Surface syntax is parsed only to establish declarations and ownership, then lowered to the typed Delta image that defines execution. The ordinary runtime and the MIR backend consume that image; MIR preserves Delta-first semantics and performs runtime `TypeId` dispatch whenever a call tuple is not statically concrete rather than compiling an abstract tuple as a concrete dispatch choice.

## Types

Built-in nominal types are `Any`, `Never`, `Type`, `I64`, `Bool`, `Unit`, `String`, `Function`, `Array`, and `Superposition`. Type application uses `of`, never brackets, `::`, unions, or nullable suffixes:

```mitos
abstract Number
type I64 is Number

type Point:
  x of I64
  y of I64
end

enum Option of T:
  Some(value of T)
  None
end
```

`abstract Name` declares an abstract nominal type. `type Name` declares a concrete type; it may open a field block. `is Parent` declares the nominal parent. A generic declaration uses `of T` or `of (T, U)`, and an applied type is written `Option of I64`.
The built-in `Superposition` type constructor has reserved `TypeId` 10. Its public applied form is `Superposition of T`, produced by `superpose`; source declarations cannot redefine the built-in.

A value annotation is also introduced by `of`:

```mitos
identity(value of T) of T:
  value
end
```

A single uppercase identifier in a method signature is an implicit method type variable. `where` clauses are intentionally absent.

## Generic methods and dispatch

Functions with the same name and arity form one generic function. Each declaration is a method. At a call boundary, argument values reach weak-head normal form, their concrete `TypeId` tuple is formed, and the unique most-specific applicable method is selected.

An optional finite effect declaration appears at the end of a method header, after the optional `of Result` annotation and before `:`. Write `does Effect` for one effect or `does (A, B)` for a nonempty row of effects. Thus the supported header shapes include `name(parameters) does Effect:`, `name(parameters) of Result does Effect:`, and `name(parameters) of Result does (A, B):`. Each row entry is an effect type expression, so a parameterized effect uses the normal `Effect of T` type-application syntax. The source grammar has no notation for an open row tail.

```mitos
select(value of I64) of I64:
  value + 1
end

select(value of Bool) of I64:
  42
end

main():
  select(20 < 22)
end
```

A missing method reports `MethodError` with the concrete tuple. Incomparable maximal candidates report `AmbiguousMethodError` and list their signatures. Method table epochs participate in semantic dispatch, so adding or replacing a method in the REPL changes the next applicable call.

## Type values and reflection

Reflection is deliberately minimal. A nominal type name used as an expression produces a first-class type value. `typeOf(value)` evaluates `value` and produces the runtime type of the resulting concrete value. The value has the interned nominal identity `Type of T` and is formatted with the same canonical `of` syntax:

```mitos
main():
  typeOf(42)
end
```

This prints `Type of I64`. A method may therefore dispatch on `value of Type of I64`, and equality compares the represented type identity. Nested parametric identities retain their canonical form, such as `Type of Option of I64`. `assertType(value, I64)` evaluates to `value` when its runtime type is a subtype of `I64`; otherwise it reports a positioned diagnostic naming both the actual and required nominal types. There is no member enumeration, dynamic invocation, source reflection, or unrestricted runtime metadata API.

## Enums and constructors

Enums declare one or more constructors. Constructor payloads may carry annotations and determine arity:

```mitos
enum Option:
  Some(value of I64)
  None
end
```

Every call uses parentheses, including nullary constructor calls such as `None()`. A bare nullary constructor is also a value.

## Blocks, bindings, and results

Functions always have a parenthesized parameter list, including `main()`. A block contains zero or more immutable definitions written `name := expression`, followed by exactly one result expression. Definitions are sequential and visible only to later definitions and the final expression.

```mitos
sum(left of I64, right of I64) of I64:
  total := left + right
  total
end
```

There is no assignment or mutation: `:=` creates an immutable binding.

## Expressions

Integer literals are signed 64-bit values. Unary `-` negates an expression. String literals are concrete `String` values enclosed in double quotes. They may use only `\"`, `\\`, `\n`, `\r`, and `\t`; NUL bytes, raw line breaks, unknown escapes, and unterminated literals are rejected. Both the encoded token and decoded value are bounded, and a decoded literal may contain at most 1,048,576 bytes.

```mitos
label := "Mitos\tDelta\n"
```

Binary operators, from highest to lowest precedence, are:

```text
* / %
+ -
= < <= > >=
```

Operators of the same precedence associate left. Arithmetic requires `I64`; comparisons produce `Bool` values formatted as `True` or `False`. Parentheses group expressions.

A lambda starts with `do`, has a parenthesized parameter list, and captures its lexical scope:

A lambda places the same optional finite declaration after its optional result annotation and before `:`: `do(parameters) does Effect:`, `do(parameters) of Result does Effect:`, or `do(parameters) of Result does (A, B):`. Parenthesized rows must be nonempty; no open-tail form is accepted.

```mitos
twice := do(f, value):
  first := f(value)
  f(first)
end
```

The Delta runtime supports closure values. MIR specializes concrete named calls and retains runtime `TypeId` dispatch whenever closure provenance is statically recoverable, including immutable bindings, returned wrappers, constructor fields, and match bindings. A branch-selected or superposed set of distinct effectful closures requires the `DYNAMIC_EFFECT_CLOSURES` capability: `run` and `aot-run` execute it through generic Delta, while `jit` rejects it before MIR emission. This closure capability is independent of the separately unsupported `SUSPENSION` capability described below; dynamic closures are not the only reason a program can be ineligible for MIR. Both routes are explicit required-feature negotiation, not fallback after native failure.

## Deterministic superposition

`superpose(first, rest...)` eagerly evaluates one or more branch expressions in source order and produces `Superposition of T`. An empty call is invalid. After recursively flattening nested superpositions, every alternative must have the same concrete runtime `TypeId`; abstract compatibility or a shared nominal parent is not enough. Flattening preserves the assignments already attached to nested alternatives.

`collapse(value)` is strict: `value` must be a superposition, and any ordinary value is a positioned error rather than an implicit singleton. It returns an `Array of T` containing every alternative in deterministic order. An uncollapsed value formats canonically as `superpose(a, b)`; a collapsed array uses bracket-and-comma formatting such as `[a, b]`. Singleton forms retain their wrappers: `superpose(a)` and `[a]`.

Each lowered source node retains a stable origin in `DeltaNode.descriptor`. Reusing a value from the same `superpose` origin reuses its branch index, so occurrences correlate rather than multiply:

```mitos
choices := superpose(1, 2)
collapse(choices + choices)
```

The result is `[2, 4]`, not `[2, 3, 3, 4]`. Distinct origins form a Cartesian product. Its order is lexicographic by origin encounter and then by source branch position: for `left := superpose(1, 2)` followed by `right := superpose(10, 20)`, `collapse(left + right)` produces `[11, 21, 12, 22]`.

Arithmetic and comparison operations, constructors, generic calls, lambda creation/application, and matches lift over compatible alternatives. Generic dispatch and pattern selection occur separately for each resulting concrete alternative. A lifted expression retains the assignment map that produced it, which keeps same-origin references correlated through nested calls and constructors.

Evaluation remains source ordered at the observable boundary: the first branch error or effect is the one reported or performed, even when Delta work is scheduled in parallel. Effect operations do not implicitly accept a superposition as one scalar operation argument; write `superpose(Effect.op(first), Effect.op(second))` to perform one source-ordered request per branch. Physical superposition is represented by a marked core `REPLICATOR` whose principal port has `PARENT` polarity, whose auxiliary ports have `CHILD` polarity, and whose observable marker and origin delimit branch enumeration. Mitos has no `SUP` core agent; `SUPERPOSE`, `COLLAPSE`, and array construction are practical Delta operations around that replicator boundary.

## Match expressions

A match scrutinee must evaluate to a constructor. Constructor patterns bind payloads; nullary patterns omit parentheses. `_` is a final wildcard arm. Each arm is a block whose final expression is the arm result.

```mitos
match option:
  Some(value):
    adjusted := value + 1
    adjusted
  None: 0
end
```

A match must use constructors from one enum and be exhaustive unless it ends with `_`.

## Simultaneous parallel bindings

A parallel block has at least two bindings and one final result expression:

```mitos
parallel:
  left of I64 := compute_left()
  right of I64 := compute_right()
  left + right
end
```

Every root sees the scope outside the parallel block, never another root. Phase one materializes and evaluates roots in deterministic source order; phase two joins the values and evaluates the final expression. The threaded Delta runtime may execute phase-one work concurrently while preserving deterministic error precedence.

## Effects

Effect declarations and effect rows are part of the typed source and owned `DeltaProgram` schema. An operation is one-shot unless its declaration starts with `multi effect`. A handler clause may call `resume(value)`; a one-shot clause may instead return directly, which aborts the captured continuation and erases its unreachable Delta graph.

```mitos
effect Abort:
  abort(message of String) of I64
end

main():
  handle Abort.abort("cancelled\n") + 1:
    Abort.abort(message of String): 42
    return(value of I64): value
  end
end
```

The result is deterministically `42`; the pending `+ 1` continuation is erased. Multi-shot handlers may resume the same continuation more than once. Effect requests preserve source occurrence order across parallel roots. Operations declared on `Console` or `IO` are external host effects: execution requires a compatible versioned host helper explicitly enrolled for the operation, and absence or signature mismatch is a deterministic diagnostic rather than an interpreter fallback. A ready-only helper returns `HOST_READY` (or `HOST_FAIL`) without retaining execution; its program requires `HOST`, keeps `SUSPENSION` optional, and remains MIR-eligible. The standard `jit` path explicitly enrolls the ready-only `Console.print` helper. If a helper may return `HOST_SUSPEND` and resume later, its manifest must require `SUSPENSION`; direct `jit` then rejects before MIR emission and `aot-run` chooses generic Delta.

The representative programs are [`examples/effects_abort.mitos`](examples/effects_abort.mitos) for one-shot abort/eraser cleanup, [`examples/effects.mitos`](examples/effects.mitos) for multi-shot resumption, and [`examples/effects_parallel.mitos`](examples/effects_parallel.mitos) for parallel effects with source-ordered joins.

## REPL persistence

The REPL retains successful type, effect, method, and immutable binding source. Single-line nominal headers such as `abstract Number` and `type I64 is Number` are declarations immediately; they do not wait for an `end`. Annotated bindings such as `x of I64 := 20` persist under the name `x`, and later entries may refer to them. String-valued bindings use the same escaped literal syntax as files.

Entering a method whose name, arity, and parameter signature match a retained method replaces that method in place instead of appending a duplicate. The generic's epoch advances, and semantic dispatch in the next program image observes the replacement. Other methods of the same generic remain installed. Every successful entry reparses the accumulated source and lowers it into a fresh current `DeltaProgram`; any MIR execution is a per-program specialization of that image. `:clear` removes retained declarations, bindings, and epochs.

For example, these are separate successful entries; the second `select` declaration replaces the first and the final call observes the new body:

```mitos
abstract Number
type I64 is Number
x of I64 := 20
select(value of I64) of I64:
  value + 1
end
select(value of I64) of I64:
  value + 22
end
select(x)
```

## AOT artifacts

AOT v4.0 is a canonical little-endian, manifest-first tagged-record image of Delta schema 4.0. It stores the program `ModuleKey`; every persistent `SymbolKey` and owner; generic/method coherence; resolved effect rows and optional tails; `TypeId`-indexed layout descriptors and copy policies; types, constructors, primitives, effects, graph nodes, superposition origins, observable replicator metadata, spans; and schema/helper required and optional capabilities. Required and optional records are length-delimited and emitted once in ascending tag order. Higher minors load through required-capability negotiation; unknown optional records skip by bounded length, while unknown required, missing, duplicate, misflagged, out-of-order, truncated, overflowing, trailing, or feature-incoherent records fail closed. AOT v1-v3 are rejected. Runtime registries, handles, pointers, callbacks, refcounts, views, live resources, contexts, and resumption tokens are never serialized. After validation, `aot-run` uses MIR exactly when every required manifest bit is in MIR's advertised set; otherwise it deliberately selects generic Delta. The currently named MIR exclusions are `SUSPENSION` and `DYNAMIC_EFFECT_CLOSURES`.

## Comments

`//` starts a comment that continues to the end of the line.
