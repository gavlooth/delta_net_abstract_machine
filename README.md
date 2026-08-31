# Mitos

Mitos is a small typed expression language whose sole executable semantic image is an owned `DeltaProgram`. The project is implemented in C3 and vendors MIR as its only native JIT backend; there is no legacy Core execution path.

## Build

```sh
c3c build
```

The executable is `build/mitos`. MIR is vendored under `lib/mir`; no alternate JIT backend, surface evaluator, legacy Core normalizer, or interpreter fallback is compiled into the language path.

## Command line

```text
build/mitos run FILE [--threads N]
build/mitos jit FILE
build/mitos check FILE
build/mitos eval SOURCE
build/mitos repl
build/mitos aot FILE OUTPUT
build/mitos aot-run ARTIFACT
```

- `run` parses and validates a `.mitos` program, lowers it once to an owned typed `DeltaProgram`, and executes that image on the Delta runtime.
- `jit` consumes the same Delta image. It materializes practical graph nodes as MIR, specializes concrete calls, and performs runtime `TypeId` dispatch when a call tuple is dynamic. It never treats abstract tuples as concrete dispatch choices, re-lowers surface expressions, or falls back to `run`.
- `check` parses, validates, and lowers a program without executing it.
- `eval` wraps one source expression in `main()` and runs the resulting Delta image.
- `repl` is a persistent Delta/MIR session. It retains single-line nominal declarations such as `abstract Number` and `type I64 is Number`, annotated bindings such as `x of I64 := 20`, strings, effects, and methods. A same-name, same-arity, same-parameter-signature method replaces its prior declaration in place, advances that generic's epoch, and invalidates its bounded native specializations.
- `aot FILE OUTPUT` atomically writes portable AOT **v3** over Delta schema v3. Its sections own the complete typed `DeltaProgram`: type registry, concrete instance identities, generic and method descriptors, constructors, primitives, nodes, edges, interfaces, parallel roots, spans, effect registry, stable origins, observable replicator metadata, and helper ABI 1.2 requirements, including superposition feature bit `0x10`.
- `aot-run ARTIFACT` validates and reconstructs that `DeltaProgram`, then invokes Delta/MIR execution without the parser or source lowerer. AOT versions 1 and 2 are deliberately rejected rather than upgraded.

`run` accepts simultaneous `parallel` bindings and uses `--threads N` to bound parallel work while preserving source-order joins and deterministic error precedence. Thread counts must be from 1 through 256. Source input is limited to 16 MiB; decoded string literals are limited to 1 MiB; and AOT artifacts are limited to 64 MiB. The AOT decoder bounds every count against its section's remaining bytes, a production ceiling, and a cumulative allocation budget before allocation.

External `Console` and `IO` operations are host effects. Execution requires a compatible registered versioned helper; a missing helper or mismatched operation signature is a deterministic diagnostic. One-shot handlers may abort without `resume`, multi-shot handlers may resume repeatedly, and parallel effect commits retain source occurrence order.

`superpose(a, b, ...)` is nonempty and eager. Its recursively flattened alternatives must share one concrete runtime `TypeId`, and it produces `Superposition of T`. Operations, constructors, generic calls, lambdas/applications, and matches lift over compatible alternatives. Repeated uses of the same source origin correlate their branch indexes; distinct origins form a lexicographic Cartesian product ordered by origin encounter and branch position. Effect operations remain explicit branch boundaries: use `superpose(Effect.op(a), Effect.op(b))` rather than passing a superposition as one scalar effect argument. Uncollapsed values format as `superpose(a, b)`. `collapse(value)` strictly requires a superposition and returns an ordered `Array of T`, formatted `[a, b]`.

The physical boundary is an observable, origin-marked core `REPLICATOR`: its principal port is `PARENT` and its auxiliaries are `CHILD`. There is no `SUP` core agent; practical superpose/collapse and array operations expose and read back the marked replicator without introducing a second sharing calculus.

Diagnostics go to stderr. Method errors print the concrete argument tuple and ambiguity candidates; type assertions print the actual and required types with their source span. Reflected values use canonical nominal syntax—`typeOf(42)` prints `Type of I64`. Successful `run`, `jit`, `eval`, and `aot-run` invocations print only the resulting value.

The AOT output is a portable source-free Delta v3 artifact, **not a native executable or object file**. Native code generation occurs only after `aot-run` validates and reconstructs the image. No source text, surface AST, legacy Core program, or fallback evaluator is embedded.

```sh
./build/mitos check examples/typed_dispatch.mitos
./build/mitos run examples/typed_dispatch.mitos
./build/mitos jit examples/typed_dispatch.mitos
# 42

./build/mitos run examples/effects_abort.mitos
./build/mitos jit examples/effects_abort.mitos
# 42

./build/mitos run examples/effects.mitos
# 42

./build/mitos run examples/effects_parallel.mitos --threads 2
# 42

./build/mitos run examples/superposition.mitos
./build/mitos jit examples/superposition.mitos
# [Pair(2, 11), Pair(2, 21), Pair(4, 12), Pair(4, 22)]

./build/mitos aot examples/superposition.mitos /tmp/superposition.mita
./build/mitos aot-run /tmp/superposition.mita
# [Pair(2, 11), Pair(2, 21), Pair(4, 12), Pair(4, 22)]

./build/mitos aot examples/effects_abort.mitos /tmp/effects-abort.mita
./build/mitos aot-run /tmp/effects-abort.mita
# 42

printf 'effect Abort:\n  abort(message of String) of I64\nend\nx of I64 := handle Abort.abort("cancelled") + 1:\n  Abort.abort(message of String): 42\n  return(value of I64): value\nend\nx\n:quit\n' | ./build/mitos repl
# 42
# 42

./build/mitos eval "20 + 22"
# 42
```

This smoke matrix covers nominal/parametric specificity and `typeOf`, deterministic one-shot abort with continuation erasure through run/JIT/REPL/AOT, multi-shot resumption, parallel effect scheduling, and same-origin correlation plus distinct-origin Cartesian superposition through run/JIT/AOT.

## Language

A Mitos program contains enums and named functions and defines a zero-argument `main()`. Definitions use `:=`, calls and function declarations always use parentheses, and every block ends in its result expression. `match` is the only branching construct. A `parallel` block declares two or more simultaneous bindings and then computes a result after all bindings finish. `superpose` expresses deterministic alternatives; `collapse` is the explicit observable boundary that returns their ordered array.

```mitos
enum Choice:
  Left(value)
  Right(value)
end

unwrap(choice):
  match choice:
    Left(value): value
    Right(value): value
  end
end

main():
  parallel:
    left := unwrap(Left(20))
    right := unwrap(Right(22))
    left + right
  end
end
```

See [`mitos_syntax.md`](mitos_syntax.md) for the complete grammar and semantics.
