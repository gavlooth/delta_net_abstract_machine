# Meridian Syntax Specification

Status: draft  
Scope: surface syntax and core language shape

V0 scope is governed by [V0_CONTRACT.md](V0_CONTRACT.md). This specification may
describe post-v0 syntax, but the contract decides what the current compiler
must implement, reject with a diagnostic, or defer.

This document defines the current proposed syntax for Meridian, a low-punctuation,
statically typed, expression-oriented programming language with explicit block
closure.

The design goal is to keep code readable and low-friction without depending on
braces, semicolons, arrows, or indentation-only block structure.

## Current Status

Implementation percentages, strategic tracks, the Jai-inspired path, and active
known gaps are centralized in [LANGUAGE_STATUS.md](LANGUAGE_STATUS.md). Keep
this specification focused on syntax and semantics; do not duplicate status
tables here.

## 1. Design Principles

Meridian syntax favors:

- explicit block closure with `end`
- explicit header/body separation with `:`
- low punctuation density
- word-and-colon structural syntax
- typed public APIs
- expression-oriented function bodies
- algebraic data types and pattern matching
- typed `throws` as built-in abortive error flow
- `requires` clauses for structural generic constraints
- explicit capabilities for authority
- `signal`/`enact` one-shot signaling for structured operations
- callback blocks with `do ...: ... end`; the callback surface includes
  immediate block expressions and trailing callback-call syntax
- simple calls without parentheses when unambiguous
- parentheses where they improve grouping or scanning

Whitespace around structural `:` is insignificant. `x:T`, `x: T`, and
`x : T` are the same token sequence for declarations; `x:value` and
`x: value` are likewise equivalent for named fields and named arguments.
Examples should prefer the clearer spaced form after `:`.

Meridian avoids:

- brace-delimited blocks
- semicolons
- `fn` and `def`
- `->` return arrows
- `=>` lambda arrows
- mandatory `return` for normal function results
- `Ok(...)` / `Err(...)` ceremony in ordinary error-handling code
- universal `null`

Structural syntax uses words:

```meridian
returns
throws
try
throw
do
end
and
or
not
```

Punctuation is used where it earns its place:

```meridian
:
.
=
()
[]
,
+ - * / %
matches < <= > >=
```

## 1.1 Production Memory-Management Closure

Memory semantics are the first language priority for Meridian. The central
status and closure table live in [LANGUAGE_STATUS.md](LANGUAGE_STATUS.md);
this section defines the source-level rules the compiler must enforce.

The ownership model has four concepts:

```text
copied   pass freely, discard freely, no cleanup
owned    move once, compiler cleans up on every exit path
peek     temporary read-only view, non-escaping, no lifetimes
consume  transfer into callee, caller cannot reuse
```

Everything else is mechanism built on these four rules:

- `handle` is an opaque `owned` identity from signal operations (FFI/runtime
  boundary, not a separate ownership category)
- `region` is a lexical bulk-allocation scope (uses `owned` cleanup rules)
- `using` is scoped finalization sugar over `consume`
- runtime resources enter through signal operations and opaque handles;
  source-level `unsafe` is removed

Safe code does not use user-written lifetimes, generic peek polymorphism, or
fallible/overloaded cleanup hooks. The current compiler rejects lifetime-like
tokens such as `'a` and rejects generic `peek T` in generic functions and
`requires` entries. Concrete read-only parameters such as `peek User` remain
the supported peek shape. The collection exception is `peek Array of T`,
which peeks a concrete standard container view while inferring `T` from its
element type; it does not permit storing, returning, or abstracting over
generic peeks. An existing `peek Array of T` value may be forwarded to
another generic `peek Array of T` helper; the specialized operation still
uses the concrete element rules, so owned-element reads remain limited to
operations that prove replacement or cleanup.

The v1 peek promise is intentionally small: peeks are scoped, local,
read-only, non-escaping views. They may be passed to ordinary functions and
direct non-escaping callbacks when the owner stays live for the call, but they
may not be returned, stored, captured by escaping closures, carried through
general signaling continuations, or described with user-written lifetime
parameters.

Returned peek views use scoped signaling, not normal return values. A direct
`signal`, or a signal-only function called as the direct body of a matching
`enact`, may hand a peek view to that handler. The handler may read the view
while the source peek is live, but it may not store, return, capture by copying, or
otherwise let the view escape the handler. This gives Meridian the useful part
of peek-return APIs without user-written lifetime parameters.

Future source-language extensions are not part of the closed current boundary.
They must close in the priority order tracked by
[LANGUAGE_STATUS.md](LANGUAGE_STATUS.md) and [TODO.md](TODO.md): first general
continuation values, then copied-only data-oriented extensions, explicit
authority-scoped build operations, richer C interop tooling, event-loop as a
library/runtime module, parallel-friendly constructs, package discovery, and
finally broad Jai/overall rollups. Each extension must state its memory,
authority, lowering, cleanup, and rejection rules before it stops being reserved
or future syntax.

`Allocator` is the standard copied capability token for allocation-heavy APIs,
and `allocator` is the compiler-provided empty authority value for the default
allocator token. `AllocError` is the standard allocation failure error type, with
`AllocationFailed` as its v0 variant. Allocator-backed owned values may keep
allocator provenance only as an internal cleanup detail; it is not a public
surface and does not require user-written lifetimes.

Standard direct-signal operations whose last parameter is `allocator:
Allocator` may omit that trailing allocator only inside a visible
`context allocator = ...: ... end` block or a function declaring
`needs allocator`. The omitted form lowers as if the explicit allocator
argument had been written, including named direct-signal calls such as
`Environment.readString(name: name, environmentAccess: environmentAccess)`.
Without that context, the checker rejects the call and asks for either local
allocator context, forwarded `needs allocator`, or an explicit allocator
argument.

Ordinary non-generic functions follow the same rule when their final parameter
is exactly `allocator: Allocator`: `makeText(value)` or
`makeText(value: value)` may stand for `makeText(value, allocator)` only under
visible `context allocator` or forwarded `needs allocator`. The call remains
overload-checked by arity and argument type, exact named overloads win before
the shorthand, and generated C still passes the allocator argument explicitly.

`Buffer` is the first standard allocator-backed owned value. It is created with
`allocBuffer(allocator, len)`, or with `allocBuffer(len)` when a local
`context allocator = ...: ... end` binding is visible. Both forms return
`Buffer throws AllocError`. Named forms using the same parameter names are
equivalent: `allocBuffer(allocator: allocator, len: len)` and contextual
`allocBuffer(len: len)`.
`Buffer` cannot be constructed directly. Its storage and allocator provenance
are hidden from safe source code, and compiler-inserted cleanup frees the
storage when the value remains live at scope exit. Moving or returning a
`Buffer` transfers cleanup responsibility like any other owned value. Metadata
helpers read only the stored length and do not move the buffer: `length(buffer)`,
`buffer.length()`, `empty(buffer)`, `notEmpty(buffer)`, `hasIndex(buffer, index)`,
`buffer.hasIndex(index: index)`, and `buffer.hasRange(start: start, len: len)`
are equivalent to the shared standard metadata helper forms.

`Box of T` is the standard allocator-backed owned indirection for recursive
owned structures. It is created with `allocBox(allocator, value)`, or with
`allocBox(value)` when a local allocator context is visible. Both forms return
`Box of T throws AllocError`; named `allocBox(allocator: allocator, value:
value)` and contextual `allocBox(value: value)` are equivalent. Direct standard
`Box` construction is rejected.

Type constructors are word-based. The canonical form is `Name of T`, such as
`Array of I32`, `Slice of I32`, and `Box of User`. Angle-bracket forms such as
`Array<I32>` are not Meridian syntax. Multi-argument type constructors remain
word-based as well. Parentheses group nested or modified type arguments, and
commas separate multiple type arguments only when needed to remove real
ambiguity:

```meridian
Array of copied I32
Array of (copied I32)
Array of owned Item
Map of String User
Map of (String, owned User)
Option of Box of Node
Option of owned Item
```

Transparent type aliases use `type Name = Target`. The current closed base
slice supports copied `I32` and `I64` aliases; they are checked for duplicate
names and cycles, then lowered transparently before typechecking:

```meridian
type UserId = I32
type WideId = I64

read(id: UserId) returns UserId:
  id
end
```

Transparent aliases may name `Bool`, `I32`, `I64`, `Unit`, a known named type
such as a copied or owned record or standard `String`, or a constructed
collection/view type such as `Array of I32`, `Slice of I32`, or `Option of I32`.
Function-type
aliases such as `type Handler = (I32) returns I32` are also transparent callback
signature aliases, including `peek` parameters inside the full callable
signature. Aliases lower before typechecking and do not create constructors or
runtime wrapper types; owned named or constructed aliases such as
`type BufferAlias = Buffer` and `type IntBox = Box of I32` keep the underlying
owned cleanup rules. The current range alias slice supports half-open copied
`I32` and `I64` bounds:

```meridian
type Digit = I32 range 0..10
type WideDigit = I64 range 5000000000..5000000010
```

Range aliases accept literal and constant expressions inside the half-open
bounds at explicit constant/local annotations, simple direct call arguments
including unambiguous positional and named overload-selected calls, record construction fields,
enum/error payload constructors, direct function returns, and `if`/`match` tail
branches that return from a range-annotated function. Runtime expressions use
explicit fallback narrowing for `I32` and `I64` range aliases:

```meridian
let raw = read()
let digit: Digit = narrow(raw, 0)
```

`requires` precondition contracts may inspect range-typed copied parameters.
The alias lowers to its copied scalar for expression checking, so both `I32`
and `I64` range aliases work in ordered Bool contracts:

```meridian
within(value: WideDigit) returns I32 requires value >= 5000000000 and value < 5000000010:
  42
end
```

Once a local, parameter, same-alias function result, direct or nested field
projection from a tracked record local, or direct or nested field projection
from a record-returning function has been checked as a range alias, that checked
value may flow into another site requiring the same alias: annotated locals,
mutable assignments, direct same-alias function arguments, record fields, and
enum/error payload constructors, and returns from same-alias functions.
Positional and named record-operation calls use the same argument and return
rules for tracked record receivers. Different aliases do not implicitly
substitute for each other even when they share a scalar target; use explicit
`narrow` at that boundary.

Fallible narrowing uses the same `narrow` form with an explicit `throw`
fallback:

```meridian
let digit: Digit = narrow(raw, throw OutOfRange)
let checked: Digit = narrow(raw, throw OutOfRange(raw: raw))
```

The narrowed value may be a runtime result expression; generated C evaluates it
once into a temporary before checking the range. The non-throwing fallback must
itself satisfy the alias range. The generated C checks the range and either
chooses the fallback or propagates the thrown error when the value is outside the
half-open bounds.

Mutable assignments into `var` bindings annotated with a range alias use the
same literal, fallback, and throwing checks as initial bindings:

```meridian
var digit: Digit = 1
digit = narrow(raw, throw OutOfRange)
```

Aliases do not create constructors, storage wrappers, or new runtime ABI types
in these slices. Range aliases require `I32` or `I64` targets, and richer
numeric aliases remain separate planned work. A transparent alias may not erase
a target range alias; write a new explicit range alias instead. If a range alias
targets another range alias, its half-open bounds must stay within the target
range. Alias targets obey the same import visibility rule as other type
positions: an importing module may use only locally declared types or names made
visible by `exposing`. Exported aliases expose their target as public API, so
their target may name only exported or built-in types; private helper aliases
must not appear in exported alias targets.

`I64` is active as an explicitly typed copied scalar. Integer literals infer as
`I32` by default and must fit in `I32` unless an expected type supplies `I64`,
such as an annotated local, parameter, return, record field, enum/error payload
constructor, or concrete parameter inside a generic call:

```meridian
copied type Wide:
  value: I64
end

keep(value: I64) returns I64:
  value
end

main returns I32:
  let wide = Wide(value: 5000000000)
  let stored: I64 = keep(wide.value)
  42
end
```

`I64` supports the same scalar arithmetic, unary minus, equality, and ordered
comparison operators as `I32` when both operands are `I64`. A left `I64`
operand or an expected `I64` result can give integer literals `I64` context, so
`value + 1` works when `value` is `I64`. Annotated constants may also use pure
`I64` literals, arithmetic, unary minus, and `Bool` comparisons over `I64`
values:

```meridian
const WIDE: I64 = 5000000000
const STEP: I64 = WIDE + 7
const SAME: Bool = STEP = 5000000007
```

There is no implicit `I32` to `I64` widening in this slice. `I64` range aliases
are active for literal/constant checks and runtime fallback narrowing through
`narrow(value, fallback)` or `narrow(value, throw Variant)`, including runtime
result expressions evaluated once before the range check. Checked values and
checked direct or nested record-field projections from locals or
record-returning functions flow only to same-alias range sinks. Other numeric
widths remain separate planned work.

Data-structure element modifiers are adjectives, not actions:

| Modifier | Meaning |
| --- | --- |
| `copied T` | The container stores copyable elements. `Array of T` is accepted as shorthand when `T` is copied. |
| `owned T` | The container owns initialized elements and must move/drop each exactly once. Current arrays support metadata reads, replacement, slot permutation, move-out with fallback replacement, one-slot fill, and empty/one-slot allocation. |

`Array of T` is the standard allocator-backed owned array for copied elements
in v0. It is created with `allocArray(allocator, len, value)`, or with
`allocArray(len, value)` when a local allocator context is visible. Both forms
return `Array of T throws AllocError`, fill every element with the copied
`value`, expose `len`, and hide element storage and allocator provenance from
safe source code. Named forms using `allocator`, `len`, and `element` are
equivalent; contextual named forms omit `allocator`. `Array of copied T` and
`Array of (copied T)` are explicit
spellings for the same current copied-element array. `Array of owned T` is
accepted for the closed owned-array subset; broad multi-slot owned allocation,
broad owned fill, owned slice reads, and owned array literals remain gated.
For owned arrays, literal `len > 1` in `allocArray` is a checker error. Dynamic
`len > 1` is still checked at runtime and throws `AllocError` after cleaning the
consumed initializer, so there is one ownership rule for the current boundary:
empty and one-slot construction only.
Generated owned arrays carry hidden initialized-slot metadata. Safe source still
sees only `len`; lowering uses the hidden initialized count to clean only live
owned slots, to reject owned `get`/`swap` reads of uninitialized slots, and to
allow owned `set` only when it replaces an initialized slot or appends exactly at
the initialized frontier. The move/drop invariant is that every initialized slot
has exactly one live owner: `get` moves the old value out only after replacing
the slot with the consumed fallback, `set` drops only an initialized displaced
slot, failed writes clean the consumed incoming value, and array drop cleans the
initialized prefix before resetting the hidden initialized count.
`Array of linear T` is not a source form; exact-use transfer is spelled with
`consume` at API and operation boundaries. Owned-array direct helpers and
method spellings are equivalent for the supported owned subset:
`values.length()`, `values.empty()`, `values.notEmpty()`, `values.hasIndex(0)`,
`values.get(0, fallback)`, `values.set(0, element)`, `values.swap(0, 1)`, and
named forms such as `values.hasRange(start: 0, len: values.len)` or
`values.get(index: 0, fallback: fallback)` lower to the same checked helper
calls as `length(values)`, `hasRange(values, ...)`, `get(values, ...)`,
`set(values, ...)`, and `swap(values, ...)`. `length(values)` reads the array length without moving the owner,
`length(values: values)` is equivalent. `empty(values)` /
`empty(values: values)` returns whether that peek array length is zero,
equivalent to `length(values) = 0`; `notEmpty(values)` /
`notEmpty(values: values)` returns whether it is nonzero, equivalent to
`not length(values) = 0`.
`hasIndex(values, index)` and `hasIndex(values: values, index: index)` check
whether an index is nonnegative and less than the array length without moving
the owner or reading an element.
`hasRange(values, start, len)` and
`hasRange(values: values, start: start, len: len)` check whether a half-open
window is inside the array length without moving the owner or reading elements.
`get(values, index, fallback)` reads from
`values: peek Array of T` for copied elements and returns `fallback` when the
index is negative, out of bounds, or the backing storage is unavailable. The named form
`get(values: values, index: index, fallback: fallback)` is equivalent.

`String` is the minimal standard owned text storage in v0. Allocation-heavy
strings are created with `allocString(allocator, len)`, or with
`allocString(len)` when a local allocator context is visible. Both forms return
`String throws AllocError`, allocate zeroed byte storage of that length, expose
`len`, and hide storage and allocator provenance from safe source code. Named
forms using `allocator` and `len` are equivalent; contextual named forms omit
`allocator`. String
literals create move-only `String` values backed by static immutable storage, so
they do not allocate implicitly and compiler cleanup does not free their
static bytes. `byteAt(text index)` is the first explicit content
operation: it takes `text: peek String`, returns the byte at `index` as `I32`,
and returns `-1` when the index is out of bounds. `byteAt(text: text,
index: index)` is equivalent. String metadata helpers read only the stored byte
length and do not move the string: `length(text)`, `text.length()`, `empty(text)`,
`notEmpty(text)`, `hasIndex(text, index)`, and
`text.hasIndex(index: index)`, and `text.hasRange(start: start, len: len)` are
equivalent to the shared standard metadata helper forms. `concat(allocator left
right)` and `concat(left right)` inside a visible allocator context return
`String throws AllocError`, allocate a new owned string, and copy bytes from
peek inputs without consuming them. `fromI32(allocator value)` /
contextual `fromI32(value)` and `fromI64(allocator value)` /
contextual `fromI64(value)` return `String throws AllocError` and allocate
decimal text for integer values. Named forms using `allocator`, `left`, `right`,
and `value` are equivalent; contextual named forms omit `allocator`. Encoding
operations, mutation, slicing, and broader conversion APIs remain outside this
minimal surface unless implemented by another layer.

`Slice of T` is a copied view with peek-like restrictions: it is allowed only
as a local or parameter view, returned slices are rejected in the production-safe
subset, it does not own or drop elements, and it does not create or extend
element lifetimes. It exposes `len` as a public copied field.
`Slice of T(values: values)` creates a slice header from an addressable
`Array of T` or an existing `Slice of T`; array sources are peek, not
moved, and element types must match exactly.
Bracket literals create peek copied-slice views, not owned arrays:
`let values: Slice of I32 = [1 2 3]`, `[1, 2, 3]`, and `[1, 2, 3,]`
are equivalent.
Literal elements must be copied values of one type, and the backing storage is
only a temporary view for the enclosing expression/scope. Empty slice literals
are accepted only where an expected `Slice of T` type is already known, such as
`let values: Slice of I32 = []`, `values = []` for an already typed mutable
slice, or a positional/named argument expecting `Slice of I32`. In generic
calls, an empty slice argument may use the specialized expected type after other
arguments infer the generic slot, for example `readFirst([], 42)` for
`readFirst of T(values: Slice of T, fallback: T)`.
`length(values)` and `length(values: values)` read the same view length.
`empty(values)` and `empty(values: values)` return whether that view length is
zero without moving the slice or touching elements, equivalent to
`length(values) = 0`. `notEmpty(values)` and `notEmpty(values: values)` return
whether that view length is nonzero, equivalent to `not length(values) = 0`.
`hasIndex(values, index)` and `hasIndex(values: values, index: index)` check
whether an index is nonnegative and less than the slice length without reading
an element.
`hasRange(values, start, len)` and
`hasRange(values: values, start: start, len: len)` check whether a half-open
window is inside the slice length without reading elements.
`view(values, start, len)` returns a peek `Slice of T` window over an
`Array of T` or `Slice of T` without moving the collection. Negative starts,
non-positive lengths, starts past the end, or unbacked collections return an
empty slice. Windows that run past the end are clamped to the remaining length.
The named form `view(values: values, start: start, len: len)` is equivalent.
Copied record and enum elements are valid `view` element types; no equality
operation is needed because the operation only creates a peek window over
existing copied elements.
`get(values, index, fallback)` also reads from
`values: Slice of T` for copied elements and returns `fallback` when the index
is negative, out of bounds, or the view has no backing storage. The named form
`get(values: values, index: index, fallback: fallback)` is equivalent. Generic
helpers over `Slice of T` infer `T` from the slice element type, not from the
whole slice value; empty slice arguments in generic calls may infer `T` from
another argument such as a fallback value. Returned slices, stored slices,
owned `Array` literals, and owned slice reads remain outside the
production-safe subset. Copied record and enum elements are valid `get` element
types; no equality operation is needed because the operation only copies one
element or returns the fallback.

`front(values, fallback)` reads the first copied element from an `Array of T` or
`Slice of T`, returning `fallback` when the collection is empty or has no backing
storage. The named form `front(values: values, fallback: fallback)` is
equivalent. It follows the same copied-element and peek rules as
`get(values, 0, fallback)` and lowers through that checked path, including
copied record and enum elements.

`back(values, fallback)` reads the last copied element from an `Array of T` or
`Slice of T`, returning `fallback` when the collection is empty or has no backing
storage. The named form `back(values: values, fallback: fallback)` is
equivalent. It follows the same copied-element and peek rules as
`get(values, length(values) - 1, fallback)` and lowers through that checked path,
including copied record and enum elements.

`contains(values, element)` checks whether an `Array of T` or `Slice of T`
contains a copied element without moving the collection. `I32` and `Bool`
elements compare directly; copied record and enum elements require a visible
concrete `equal(other: T) returns Bool` operation, usually from `derive equal
for T`. The named form
`contains(values: values, element: element)` is equivalent. Owned element
membership waits until equality reads can avoid moving or duplicating elements.

`count(values, element)` counts matching copied elements in an `Array of T` or
`Slice of T` without moving the collection. It uses the same comparison rule as
`contains`: direct comparison for `I32` and `Bool`, and a visible concrete
`equal(other: T) returns Bool` operation for copied record and enum elements.
The named form `count(values: values, element: element)` is
equivalent. Owned element counting follows the same deferred read rule as
`contains`.

`findIndex(values, element)` returns the first matching copied element index in
an `Array of T` or `Slice of T`, or `-1` when no match exists. It uses the same
comparison rule as `contains` and `count`, and does not move the collection or
read owned elements. The named form
`findIndex(values: values, element: element)` is equivalent.

`empty(values)` checks whether an `Array of T` or `Slice of T` has zero length
without moving the collection and without reading any element. It works through
the same peek collection view as `length(values)`, including the named form
`empty(values: values)`. Its source-level meaning is `length(values) = 0`.

`notEmpty(values)` checks whether an `Array of T` or `Slice of T` has nonzero
length without moving the collection and without reading any element. It works
through the same peek collection view as `length(values)`, including the named
form `notEmpty(values: values)`. Its source-level meaning is
`not length(values) = 0`; `!=` is not Meridian syntax.

`hasIndex(values, index)` checks whether an `Array of T` or `Slice of T` can be
read at `index` without moving the collection and without reading any element.
It works through the same peek collection view as `length(values)`, including the
named form `hasIndex(values: values, index: index)`. Its source-level meaning is
`index >= 0 and index < length(values)`.

`hasRange(values, start, len)` checks whether an `Array of T` or `Slice of T`
can expose a half-open window starting at `start` with length `len` without
moving the collection and without reading any element. It works through the same
peek collection view as `length(values)`, including the named form
`hasRange(values: values, start: start, len: len)`. Its source-level meaning is
`start >= 0 and len >= 0 and start <= length(values) and len <= length(values) - start`.

`set(values, index, element)` replaces an element in an addressable
`Array of T` for copied elements and returns `Bool`: `true` for an in-bounds
write, `false` when the index is negative, out of bounds, or the array has no
backing storage. The named form
`set(values: values, index: index, element: element)` is equivalent. `set` is
not available for `Slice of T`, because slices are peek views. Copied
record and enum elements are valid `set` element types; no equality operation
is needed because the operation overwrites one slot with a copied value. Owned
element arrays support checked replacement when the incoming value is consumed
and the displaced slot is cleaned. If an owned array has spare capacity but the
target slot is exactly the initialized frontier, `set` initializes that one next
slot; gaps remain rejected and the consumed incoming value is cleaned. Generic
helpers over `peek Array of T` may call `set` after specialization when `T` is
copied or when the owned-element specialization proves the consumed replacement
rule.

`swap(values, left, right)` swaps two elements in an addressable `Array of T`
for copied elements and returns `Bool`: `true` when both indices are in bounds,
`false` when either index is negative, out of bounds, or the array has no
backing storage. The named form
`swap(values: values, left: left, right: right)` is equivalent. `swap` follows
the same v0 limits as `set`: it is not available for `Slice of T`, copied
record and enum elements are valid, and owned element arrays may permute slots
without copying or cleanup. Generic helpers over `peek Array of T` may call
`swap` after specialization when the element rule is supported.

`fill(values, element)` replaces every element in an addressable `Array of T`
for copied elements and returns `Bool`: `true` when the array has backing
storage and every slot is written, `false` when the array has no backing
storage. The named form `fill(values: values, element: element)` is equivalent.
`fill` follows the same v0 limits as `set` and `swap`: it is not available for
`Slice of T`, copied record and enum elements are valid, and owned element
arrays support only the exact one-slot replacement case; successful owned fill
marks that single slot initialized. Generic helpers over `peek Array of T` may
call `fill` after specialization when the element rule is supported.

Source-level `unsafe` functions and `unsafe: ... end` blocks are removed from
Meridian. Normal code requests resource authority through direct signal
operations, receives checked Meridian values, and handles runtime failures with
typed `throws`. The boundary is expressed by signal operations and opaque
handles, not by a local escape hatch.

Raw memory boundary names are `rawAlloc`, `rawFree`, `rawRead`, `rawWrite`,
`alloc`, `free`, and `realloc`. They are reserved implementation names, not
safe-source functions. Raw pointer types stay out of public and safe type
surfaces; runtime resources must be described as checked Meridian values,
opaque handles, peek views, and typed errors.

File-like resources use explicit handles. A handle is an opaque runtime
identity.

Source syntax:

```meridian
handle Name
```

`owned handle Name` is accepted for automatic cleanup and plain `handle Name`
is accepted for exact-use handles:

```meridian
handle File
```

Handles have no source-visible fields, cannot be constructed with record
constructor syntax, and can only be created by signal operations.

A `handle` follows checked usage obligations on every path:
- it may be explicitly `consume`d,
- moved into a callee with ownership transfer, or
- returned to the caller.

In the current implementation, parameter-local `consume T` is parsed, stored,
and validated on functions, operations, and signal operations. Calls to consumed
parameters are explicit moves and diagnostics name the call and parameter.
Non-copied by-value parameters are rejected unless they are written as `peek T`
for access or `consume T` for transfer.
`peek File` is a temporary non-owning view of an existing handle and obeys the
same non-escaping peek rules as other peek values. Raw pointers and raw
integer ids do not become safe source-level handles. Generated C lowers handles
through the versioned `MeridianHandle` ABI wrapper described in
[docs/abi.md](docs/abi.md); standard runtime resources may carry host-private
fields beside that wrapper, but those fields are not source-visible.

`owned` cleanup has one source form:
`drop(value: T) returns Unit`.

In the current global-name model, this form is safe, infallible, and non-generic.
The compiler still inserts automatic cleanup for matching owned values on normal
scope exits, `throw`, and `try` propagation. Direct source calls to `drop`
remain allowed as ordinary safe functions, and cleanup hooks are checked to use
no hidden authority. For structural cleanup, each owned field/payload inside
owned records/enums/errors uses a matching source `drop(value: T) returns Unit`
hook when available; otherwise the compiler emits structural drops recursively.

## 2. Lexical Structure

Line comments:

```meridian
// comment
```

Block comments:

```meridian
/*
  comment
*/
```

Identifiers are case-sensitive.

Recommended naming conventions:

```meridian
lowerCamelCase  // values, variables, functions, fields
UpperCamelCase  // types, variants, errors
SCREAMING_CASE  // constants, if used
```

Top-level constants use `const NAME = expr` or `const NAME: Type = expr`.
The current compiler accepts copied constants whose initializer contains only
literals, other constants, pure operators over `I32`, `Bool`, and `Unit`, pure
`String` and `Unit` equality with `=` and inequality with `not x = y`, and deterministic
`if` expressions whose condition resolves to a pure `Bool`. Only the selected
constant branch is expanded, and constant `and` / `or` conditions short-circuit
normally. Ordinary constants may also use a `do:` block with pure `let` setup
before the final expression. Pure Bool constant expressions resolve to literal
`true` or `false`. Pure integer arithmetic and unary minus resolve to literal
integer values with checked overflow and divide-by-zero diagnostics. Constants
are compile-time aliases and may be shadowed by local bindings.

```meridian
const ENABLED = true
const MODE: String = "fast"
const BASED: I32 = do:
  let base = 40
  base + 2
end

const ANSWER: I32 = if ENABLED and MODE = "fast":
  42
else:
  0
end
```

Pure compile-time constants may also use a block form:

```meridian
const ANSWER: I32 = compile:
  BASE + 2
end
```

In the current slice, `compile:` is accepted only inside top-level constant
initializers. The body may contain pure `let` setup and the same deterministic
`if` selection followed by one final pure expression. A compile-time `if`
condition must resolve to a pure `Bool`; only the selected branch is expanded,
and that branch follows the same pure `let` setup plus final expression rule.
Ordinary calls, allocation, IO, mutation, `var`, assignment, and control-flow
statements other than this expression-form `if` are rejected.

Source-file compile-time authority is used as a built-in module and used
through `from source import files`

```meridian
from source import files

const VERSION: I32 import files:
  files.readI32("version.txt")
end

const SELECTED_VERSION: I32 import files:
  let path: String = "version.txt"
  let mode: String = files.readString("mode.txt")
  if files.pathExists(path) and mode = "fast":
    files.readI32(path)
  else:
    0
  end
end

const SECOND_ASSET_PATH: String import files:
  files.entryPath("assets" 1)
end
```

Specific operations may be exposed into the local compile-constant namespace:

```meridian
from source import files exposing readI32 entryPath

const VERSION: I32 import files:
  readI32("version.txt")
end

const SECOND_ASSET_PATH: String import files:
  entryPath("assets" 1)
end
```

Build-check compile-time authority is a separate built-in module:

```meridian
from build import checks

const BUILD_CONTRACT: Unit import checks:
  checks.require(true, "generated table is available")
end
```

The first build-check operation is `checks.require(condition, message)`. It
returns `Unit` when `condition` is `true` and fails compilation with `message`
when `condition` is `false`. It is deterministic and has no filesystem,
mutation, process, network, clock, randomness, or allocation authority. Specific
operations may also be exposed:

`checks.same(actual, expected, message)` is the companion equality check for
compile-time contracts. It accepts values that resolve to `Unit`, `Bool`,
integer, or `String`, returns `Unit` when they match, and fails compilation with
the message plus the actual and expected values when they differ.

`checks.range(value, min, max, message)` checks an integer value against an
inclusive integer range. It returns `Unit` when `min <= value <= max` and fails
compilation with the message plus the actual value and expected range otherwise.

`checks.oneOf(value, option..., message)` checks a compile-time value against
one or more expected values of the same kind. It accepts `Unit`, `Bool`,
integer, or `String` values and fails compilation with the accepted set when no
option matches.

```meridian
from build import checks exposing require same range oneOf

const BUILD_CONTRACT: Unit import checks:
  require(true, "generated table is available")
end

const TABLE_SIZE: Unit import checks:
  same(40 + 2, 42, "generated table size")
end

const TABLE_LIMIT: Unit import checks:
  range(42, 1, 128, "generated table size")
end

const TARGET_GATE: Unit import checks:
  oneOf("linux", "linux", "macos", "windows", "supported target")
end
```

Build-target metadata is also explicit:

```meridian
from build import target

const TARGET_OS: String import target:
  target.os()
end

const TARGET_POINTER_WIDTH: I32 import target:
  target.pointerWidth()
end
```

The first `build target` operations are `target.os()`, `target.arch()`,
`target.family()`, and `target.pointerWidth()`. They expose the compiler target
as deterministic copied values. They do not grant filesystem, process, network,
clock, randomness, mutation, or allocation authority.

Build-text inspection is explicit:

```meridian
from build import text

const NAME_LEN: I32 import text:
  text.len("meridian")
end

const HAS_PREFIX: Bool import text:
  text.hasPrefix("meridian", "meri")
end

const FULL_NAME: String import text:
  text.concat("meri", "dian")
end

const SUFFIX: String import text:
  text.slice("meridian", 4, 4)
end

const C_NAME: String import text:
  text.replace("meridian-lang", "-", "_")
end

const NORMALIZED: String import text:
  text.lower("MERIDIAN")
end

const CLEAN: String import text:
  text.trim("  meridian  ")
end

const DASHES: String import text:
  text.repeat("-", 8)
end

const COUNT_TEXT: String import text:
  text.fromI32(42)
end

const WIDE_COUNT_TEXT: String import text:
  text.fromI64(5000000000)
end

const ENABLED_TEXT: String import text:
  text.fromBool(true)
end

const COUNT: I32 import text:
  text.parseI32("42")
end

const WIDE_COUNT: I64 import text:
  text.parseI64("5000000000")
end

const ENABLED: Bool import text:
  text.parseBool("true")
end
```

The first `build text` operations are `text.len(value)`,
`text.contains(value, pattern)`, `text.hasPrefix(value, pattern)`, and
`text.hasSuffix(value, pattern)`. `text.concat(left, right)` composes two
compile-time strings into a copied `String`. `text.slice(value, start, len)`
returns a copied `String` by character indexes and rejects negative or
out-of-range windows. `text.replace(value, from, to)` replaces all occurrences
of a non-empty pattern. `text.lower(value)` and `text.upper(value)` apply
deterministic Unicode default case conversion. `text.trim(value)`,
`text.trimStart(value)`, and `text.trimEnd(value)` remove Unicode whitespace at
the requested edges. `text.repeat(value, count)` repeats a compile-time string
with a checked non-negative count and a bounded result size.
`text.fromI32(value)`, `text.fromI64(value)`, and `text.fromBool(value)` render
copied scalar constants into deterministic `String` values; `text.fromI32`
rejects values outside the `I32` range. `text.parseI32(value)` trims surrounding
whitespace, parses an `I32`, and rejects invalid or out-of-range text.
`text.parseI64(value)` does the same for `I64`. `text.parseBool(value)` trims
surrounding whitespace, accepts only `true` or `false`, and returns a copied
`Bool`. These operations do not grant filesystem, process, network, clock,
randomness, mutation, or allocation authority.

The current `build` namespace is closed to `checks`, `target`, and `text`.
Imports such as `from build import process`, `from build import network`,
`from build import clock`, `from build import random`, `from build import files`,
or mutation/allocation modules are rejected. Source-local filesystem authority
stays under `from source import files`, not under `build`.

The accepted `source files` operations are:

```text
readI32, readByte, readByteAt, readBool, readString, readLine,
pathExists, pathIsSymlink, fileSize, fileModifiedSeconds,
canReadPath, canWritePath, canExecutePath,
directoryExists, fileExists,
entryCount, entryName, entryPath, entryIsDirectory, entryIsFile,
entryIsSymlink, entrySize, entryModifiedSeconds,
entryCanRead, entryCanWrite, entryCanExecute
```

With `source files` authority, constant initializers may call
`files.readI32("relative/path")` to read an I32 integer from a source-relative
file, `files.readByte("relative/path")` to read the first byte of a
source-relative file as an `I32`,
`files.readByteAt("relative/path" index)` to read a byte at a non-negative
compile-time `I32` index from a source-relative file, `files.readBool("relative/path")` to read
`true` or `false` from a
source-relative file, `files.readString("relative/path")` to read UTF-8
text into a compile-time `String` constant, or
`files.readLine("relative/path")` to read the first line before newline into a
compile-time `String` constant, or `files.pathExists("relative/path")` to
produce a compile-time `Bool` without reading the file contents, or
`files.pathIsSymlink("relative/path")` to produce a compile-time `Bool` that
is true only for an existing source-local symlink, or
`files.fileSize("relative/path")` to read a file's byte length into a
compile-time `I32`, or `files.fileModifiedSeconds("relative/path")` to read a
regular file's modified timestamp as Unix seconds into a compile-time `I32`, or
`files.canReadPath("relative/path")`, `files.canWritePath("relative/path")`,
or `files.canExecutePath("relative/path")` to check host readability,
writability, or executability for an existing source-local path without reading
its contents, or `files.directoryExists("relative/path")` to produce a
compile-time `Bool` that is true only for existing directories, or
`files.fileExists("relative/path")` to produce a compile-time `Bool` that is
true only for existing regular files, or
`files.entryCount("relative/path")` to count direct entries in a
source-relative directory as an `I32`, or
`files.entryName("relative/path" index)` to read the sorted direct
entry name at a non-negative compile-time `I32` index into a compile-time
`String`, or `files.entryPath("relative/path" index)` to read the
sorted direct entry as a source-relative path string using `/` separators, or
`files.entryIsDirectory("relative/path" index)` to check
whether the sorted direct entry at that index resolves to a source-local
directory, or `files.entryIsFile("relative/path" index)` to check
whether it resolves to a source-local regular file, or
`files.entryIsSymlink("relative/path" index)` to check whether the
sorted direct entry is a source-local symlink, or
`files.entrySize("relative/path" index)` to read the sorted direct
entry's regular-file byte length into a compile-time `I32`, or
`files.entryModifiedSeconds("relative/path" index)` to read the
sorted direct entry's regular-file modified timestamp as Unix seconds into a
compile-time `I32`, or `files.entryCanRead("relative/path" index)`,
`files.entryCanWrite("relative/path" index)`, and
`files.entryCanExecute("relative/path" index)` to check sorted direct
entry readability, writability, and executability without reading contents.
Paths must be relative and source-local;
absolute paths and `..` components are rejected. Broader filesystem, process,
network, clock, randomness, allocation, and mutation authority remains
unavailable at compile time. If an existing path resolves through a symlink,
the resolved target must still stay inside the source directory.
`files.pathIsSymlink` returns false for missing paths and still validates
existing symlink targets against the same source-local rule. File read and file
metadata operations require the resolved target to be a regular file; directory
entry operations require the resolved target to be a directory; `readByte` and
`readLine` reject empty files; `readByteAt` rejects indexes outside the file
byte length; directory entry operations reject indexes outside the sorted
direct-entry count; and `entrySize` / `entryModifiedSeconds` require the
selected entry to be a regular file. Modified-time and permission probes are
source-local and authority-gated, but they reflect host checkout metadata and
permissions, so they are intended for build configuration checks rather than
reproducible content hashing.
`const ... import files:` bodies may also use pure `let` setup before the final
expression, for example to name a source-relative path:

```meridian
const VERSION: I32 import files:
  let path: String = "version.txt"
  files.readI32(path)
end
```


Reserved keywords:

```meridian
module
use
as
export
type
enum
error
requires
with
let
var
if
else
match
for
in
while
loop
break
continue
return
throws
try
throw
catch
signaling
signal
enact
do
end
and
or
not
is
fold
unfold
fork
parallel
when
class
instance
impl
implementation
interface
trait
satisfies
where
```

The legacy abstraction words `class`, `instance`, `impl`, `implementation`,
`interface`, `trait`, `satisfies`, and `where` are reserved and not part of
Meridian's syntax surface. Use direct `requires` clauses and `operation`
declarations instead.

## 3. Files, Modules, And Imports

A source file may begin with a package declaration, followed by an optional
module declaration:

```meridian
package app
module app accounts
```

Package paths are metadata and a visibility boundary in the current compiler
slice. Imports are accepted when both files are package-less, both files name
the same package, or the import crosses package boundaries with an explicit
`exposing` list naming exported declarations. Same-package imports whose path
begins with the current package resolve from the package root. Without a
manifest, the compiler infers that root from files with package-qualified module
paths, so a nested `module app sub main` can use `from app import http` from the
package root. With a `meridian.package` file, the manifest directory is the
package root:

```text
package app
depends lib
```

The manifest package must match the source file's `package` declaration.
`package` and `depends` paths use the same source identifier word parts as
module and package declarations, so reserved words, dotted names, and other
non-source package names are rejected. `depends` lines name packages that this
package may import through manifest-discovered sibling package roots. Dependency
entries must not duplicate another `depends` entry and must not name the
manifest's own package.
Cross-package imports from packaged modules, including nested packaged modules,
resolve from the sibling package root and must use `exposing`; bare
cross-package imports are rejected so they cannot accidentally import a whole
package surface. If sibling directories contain `meridian.package` files, the
compiler discovers the imported package by the manifest's declared package name
rather than by the directory name, and manifest-backed imports must be listed in
the importing package's `depends` entries. This is the current distribution
boundary: explicit manifests, declared dependencies, and deterministic sibling
discovery. `meridian package-lock <dir> [-o meridian.lock]` reads the existing
manifest, resolves exact sibling manifest dependencies, and writes a
deterministic lockfile with package/root entries. Transitive `depends` entries
from resolved sibling manifests are included once in deterministic order. Each
entry records a stable `fnv64` manifest fingerprint so source-control diffs show
which manifest content was locked. If multiple sibling manifests declare the
same exact dependency package, lockfile emission fails instead of choosing one;
if transitive resolution finds a dependency cycle, lockfile emission fails with
the cycle path. When a workspace `meridian.lock` exists for the importing
package, cross-package import resolution uses the pinned dependency root and
rejects unpinned or stale dependency manifests instead of silently scanning
sibling directories. Lockfile consumption does not add import authority:
`depends` and `exposing` checks still apply. Registries, version solving,
downloads, and publishing are left to future tooling.
When an explicit `-o` path names a nested directory, `package-lock` creates the
parent directories before writing. `meridian package-verify <dir>
[meridian.lock]` regenerates the expected lockfile from current manifests and
fails when the existing lockfile is missing or differs, including manifest
fingerprint drift. The stale-lock diagnostic reports the first differing,
missing, or extra line. Verification is a tooling check only; it does not change
package authority.
When a file has both `package` and `module` declarations, the module path must
start with the package path. Packaged module file paths must also end with the
declared module tail, so `module app sub main` must live at a path ending in
`sub/main.mer`; this keeps package-root inference from escaping the intended
package layout.

Module paths are word-separated. Do not use dots for ordinary module paths.
When an imported file declares a module path, that declared path must match the
`from` declaration path that resolved the file. Imported source files must
declare the module path they provide; module-less imported files are rejected.

Imports use one source form: `from namespace import module`, with an optional
same-line `exposing` list. The namespace is the first path word, such as `app`,
`std`, `source`, or `build`; the module path follows `import`.

```meridian
from std import time exposing Instant
from std import fs
from app import db users
from app import email sendEmail
```

Import `exposing` lists use the word `exposing` instead of braces:

```meridian
from app import http exposing Client Message Response
```

Exposed names must be exported types, functions, or constructors from the
imported module. The compiler filters the importing source namespace to those
names while keeping imported private helpers available inside the imported
module's own definitions.

When an imported module contains export markers and the import omits an
`exposing` list, the importing source sees the module's exported surface only.
Modules without export markers make their declared names visible only after the
imported file has declared the matching module path.

Exported receiver types do not expose private operations. Operation method calls
from another module require the generated operation function to be part of the
using module's visible exported surface.
Exported generic operations remain visible after receiver specialization: if
`Box_get` is exported, an using module may call the generated concrete
`Box_of_I32_get` through method syntax when `Box of I32` is otherwise visible.

Constant initializers obey the same use visibility boundary as function
bodies. A constant in an using module cannot reference a private constant
from an used module. An exported used constant may still use private
helper constants inside its own defining module.

Signal group names obey the same boundary. A function or operation in an using
module cannot declare `signaling Name`, `signal Name.operation`, or
`enact Name:` unless the signal group declaration is visible through the use. The
compiler-generated signal operation functions inherit the source signal group's
visibility instead of becoming globally callable.

Use aliases are not allowed in Meridian. Imports expose declarations
directly through `exposing`; there is no separate namespace alias form.

Exports are marked on declarations:

```meridian
export type User:
  id: UserId
  name: String
end

export findUser(id: UserId) returns User throws FindUserError:
  ...
end
```

`package`, `module`, and `use` declarations do not use `end`.

## 4. Blocks

All block forms use `:` to separate the header from the body, and `end` to
close the block.

```meridian
if ready:
  start()
end
```

```meridian
do user:
  user.email
end
```

`:` is canonical, not optional. It appears in both multiline and single-line
blocks.

Multiline form:

```meridian
if ready:
  start()
end
```

Single-line form:

```meridian
if ready: start() end
```

`end` closes the nearest open block. Indentation is required by the formatter for
multiline blocks and should be used by the parser for diagnostics, but `end` is
the actual block terminator.

Empty block:

```meridian
todo returns Void:
  pass
end
```

## 5. Bindings And Assignment

Immutable binding:

```meridian
let name = "Ada"
let count: I32 = 3
```

Mutable binding:

```meridian
var retries = 0
var limit: I32 = 3
retries := retries + 1
```

Local type annotations are written on the binding, after the name and before
`=`. The compiler rejects bare assignment-style annotations such as
`count: I32 = 3`.

Mutation uses `:=`. Declaration bindings keep `=` because they introduce a new
name; the grammar cleanup moves expression equality to `=` and reserves
statement mutation for `:=`.

Compound assignment:

```meridian
retries += 1
total -= discount
```

Assignment updates an existing mutable binding or mutable field:

```meridian
self.name := name
```

Assignment in conditions is illegal:

```meridian
if x = 1:
  ...
end
```

Use comparison:

```meridian
if x = 1:
  ...
end
```

## 6. Functions

Named functions do not use `fn` or `def`.

Canonical form:

```meridian
name(param: Type other: Type) returns ReturnType:
  body
end
```

Parameter lists are parenthesized when a declaration has one or more
parameters. Zero-parameter declarations omit empty parentheses. Commas are not
required between parameters when the next `name: Type` entry is clear.

Example:

```meridian
add(a: Int b: Int) returns Int:
  a + b
end
```

Zero-parameter function:

```meridian
main returns Int:
  0
end
```

Throwing function:

```meridian
findUser(id: UserId) returns User throws FindUserError:
  ...
end
```

Meridian has no coroutine-style function modifier in core. Event-loop runtime
work belongs in a later library/runtime module expressed through signaling,
handles, and ordinary checked calls.

The final expression is the return value:

```meridian
square(x: Int) returns Int:
  x * x
end
```

`return` is allowed for early exit:

```meridian
first(items: List of T) returns Option of T:
  if items.isEmpty:
    return None
  end

  Some items[0]
end
```

Final-expression style is preferred over `return` at the end of a function.

Static function overloads are allowed when the overloads have the same function
name and different parameter type lists:

```meridian
pick(value: I32) returns I32:
  value
end

pick(value: Bool) returns I32:
  if value:
    40
  else:
    0
  end
end
```

An ordinary positional call resolves against the visible overload set by arity
and argument types. A named call resolves against the same visible overload set
by argument names and types. The return type does not participate in overload
selection. Concrete overloads win over generic overloads when both match. If no
overload matches, or if two viable overloads remain equally specific, the
program is rejected. Duplicate overloads with the same parameter type list are
rejected. The generated C backend mangles user-function symbols, so overloaded
Meridian names do not require matching C names and do not collide with C library
symbols. The rule uses static overload resolution, not runtime multiple
dispatch. A bare overloaded function name is not a dynamic overloaded value; it
can be used as a function value only when an expected function type from an
annotation, parameter, or return type selects exactly one safe non-generic
  overload.

## 7. Function Signatures

Parameter syntax:

```meridian
name: Type
```

The compact form `name:Type` is accepted and has the same meaning.

Parameter access syntax:

```meridian
name: peek Type
name: consume Type
```

No access word means the ordinary copied/default parameter path. `peek` gives
temporary read-only access without transfer. `consume` transfers the argument
into the callee and participates in the same move/cleanup checks as other
ownership transfers. `owned` is not a parameter access word; ownership is
inferred from the declared type, field, handle, or container element shape.
Write `consume T`, not `owned T` or `consume owned T`, at function boundaries.

Multiple parameters:

```meridian
transfer(from: Account to: Account amount: Money) returns Receipt throws TransferError:
  ...
end
```

Default values:

```meridian
connect(url: String timeout: Duration = 5.seconds) returns Connection throws ConnectError:
  ...
end
```

Generic functions:

```meridian
chooseLeft of A B(left: A right: B) returns A:
  left
end
```

Constraints:

```meridian
max(a: T b: T) returns T:
  if a > b: a else: b end
end
```

Requires clause:

```meridian
save(value: T) returns Void throws SaveError
requires serialize(T) returns Bytes validate(T) returns Unit throws ValidateError:
  try validate value
  try db.insert value
end
```

Precondition contract:

```meridian
divide(a: I32, b: I32) returns I32 requires not b = 0:
  a / b
end
```

Current compiler slice: a `requires` clause may be either structural requirement
entries or one final Bool precondition contract. Structural entries keep the
existing `name(Type ...) returns Type` shape. A contract is an ordinary Bool
expression over copied parameters and copied context values; non-Bool contracts
are rejected. Copied `I32` and `I64` range-alias parameters are valid contract
inputs after transparent alias lowering. Contract helper calls are allowed only
when the selected callee does not need context, throw, signal, or use unsafe
source; direct context reads remain allowed. Contract failure aborts the
generated program in this first slice. Contracts over owned, consumed, peek, or
region state remain gated until failure handling and cleanup semantics are
specified.

Zero-parameter declarations omit empty parentheses:

```meridian
now returns Instant:
  Instant.current()
end
```

Calls still use `()` when no arguments are supplied:

```meridian
let instant = now()
```

## 8. Calls

Simple calls may omit parentheses:

```meridian
print message
validate email
users.find id
text.contains "@"
```

Multiple arguments are separated by whitespace when expression boundaries are
clear. Commas are accepted only where they improve readability or remove
ambiguity.

```meridian
add 1 2
distance a b
```

Named arguments:

```meridian
sendEmail to: user.email subject: "Welcome"
```

Parentheses are recommended when a call is nested, complex, or used inside
arithmetic:

```meridian
let total = add(1 2) * 3
let message = format(user.name user.email)
```

Zero-argument calls use parentheses:

```meridian
Instant.now()
user.displayName()
```

Field access:

```meridian
user.name
order.customer.email
```

Method calls:

```meridian
user.displayName()
name.trim()
email.lower()
```

Single-argument method calls may omit parentheses:

```meridian
text.contains "@"
users.find id
```

## 9. Types

Record type:

```meridian
type User:
  id: UserId
  name: String
  email: Option of String
end
```

Generic record type:

```meridian
type Page of T:
  items: List of T
  total: Int
  next: Option of String
end
```

First explicit layout records:

```meridian
packed type Packet:
  tag: I32
  code: I32
end

aligned 16 type Page:
  id: I32
end

soa type Points:
  x: I32
  y: I32
end
```

`packed type`, `aligned N type`, and the first `soa type` descriptor slice are
implemented only for non-generic records whose fields are layout-stable copied
values: `Bool`, `I32`, `I64`, `Unit`, or nested packed/aligned layout records.
A `packed type` cannot contain a nested `aligned N type` field with alignment
greater than 1, because packed storage may place that field at an unaligned
offset. A `soa type` cannot contain nested soa descriptors or nested aligned
records with alignment greater than 1 in this slice, because the source API for
owned columns is not closed yet. Ordinary records, enums, errors, slices, peeks,
function values, owned/exact-use values, and capability tokens remain gated out of
layout-controlled fields. `aligned N type` requires a positive power-of-two
alignment that fits Meridian's `I32` layout metadata range.

Generated C uses explicit backend layout attributes for packed/aligned records.
For `soa type`, generated C emits a declaration-only column descriptor:

```c
typedef struct {
  int32_t len;
  int32_t *x;
  int32_t *y;
} Points;
```

Source construction for `soa type` values is rejected in this slice. Source may
read descriptors only through borrowed `peek SoaName` parameters. By-value
descriptor function parameters, signal operation parameters, descriptor returns
or throws, stored descriptor fields or enum/error payloads, constant
annotations, and callable type alias or `requires` signatures are rejected until
owned SoA containers define their lifetime and cleanup rules. Lambda parameter
annotations are checked before callback lowering, so generic callback inference
cannot hide a by-value descriptor parameter inside a generated helper. Callable
type aliases and `requires` entries may name a descriptor only as a direct
`peek SoaName` parameter. Source may read descriptor columns through read-only slice views:
`points.x` has type `Slice of I32` and `points.y` has type `Slice of I32` in
the example above.
`owned soa type Name:` is the owned SoA container declaration form. The
declaration parses, checks, and emits an owned storage shape with hidden
`len`, `capacity`, `initialized`, and `allocator` metadata plus private typed
column storage. Expected-result `try allocSoa(allocator, len)` constructs an
empty or bounded copied-column owned SoA container:

```meridian
owned soa type Points:
  x: I32
  active: Bool
end

main returns I32:
  try:
    let points: Points = try allocSoa(allocator, 3)
    length(points)
  catch AllocationFailed:
    0
  end
end
```

`allocSoa` is fallible, requires allocator authority explicitly or through the
checked contextual allocator shorthand, and needs an explicit result type so the
container layout is known. This slice supports copied columns; non-copied
columns reject until initialized-element mutation semantics are closed. If a
later column allocation fails, already allocated columns are freed before the
`AllocationFailed` result is returned. Generated owned SoA cleanup frees every
allocated column through ordinary compiler cleanup paths on normal exit,
return, throw, and local recovery. Owned SoA metadata reads use the same helper
surface as descriptors: `length(points)`, `empty(points)`, `notEmpty(points)`,
`hasIndex(points, index)`, and `hasRange(points, start, len)` plus the
corresponding method spellings borrow the container and do not move it. Copied
columns on owned SoA values project to the same non-escaping `Slice of T` views
as descriptor columns, so `points.x`, `get(points.x, index, fallback)`,
`points.x.get(index, fallback)`, `points.x.view(start, len)`, generic
`Slice of T` helpers, and copied `for` iteration all work without moving the
owned container or exposing raw backing pointers. Local owned SoA copied
columns also accept checked mutation through the same column projection:
`set(points.x, index, value)`, `set(values: points.x, index: index, element: value)`,
`points.x.set(index: index, element: value)`, `swap(points.x, left, right)`,
and `points.x.fill(element: value)` mutate only when the column belongs to a
local owned SoA container and the index/range checks succeed. Descriptor-backed
columns remain read-only `Slice` views, so the same write helpers reject for
`peek Points` descriptor columns. Owned SoA column views keep the ordinary
`Slice` escape rules: they cannot be returned or stored, do not expose
`.data`, do not implicitly materialize into `Array of T`, and do not coerce an
owned SoA container into an array-of-rows view. Hidden owned SoA storage
metadata such as `len`, `capacity`, `initialized`, and `allocator` is not
public field access; use helpers or methods such as `length(points)` and
`points.length()`. Generated C still exposes layout metadata for tooling: owned
SoA records carry `MERIDIAN_LAYOUT_KIND_SOA`, source-field counts, hidden
storage-field metadata, source-index metadata for source columns, and order
assertions for both metadata and column storage.
Other spellings such as `soa owned type`, `mut soa type`, `mutable soa type`,
`soa mut type`, and `soa mutable type` are rejected as non-selected aliases so
`soa type` cannot be mistaken for an owned mutable column container.
The slice header is produced from the descriptor's column pointer and `len`;
Meridian source still does not expose the raw pointer or perform implicit
AoS/SoA conversion. Because the column projection is an ordinary local slice
view, copied-element slice helpers such as `empty(points.x)`,
`notEmpty(points.x)`, `get(points.x, index, fallback)`,
`front(points.x, fallback)`, `back(points.x, fallback)`,
`view(points.x, start, len)`, `hasIndex(points.x, index)`,
`hasRange(points.x, start, len)`, `contains(points.x, element)`,
`count(points.x, element)`, and `findIndex(points.x, element)` follow the same
non-owning slice rules. Generic helpers over `Slice of T` infer `T` from a
column view in the same way as any other slice. Collection method calls on a
column view, such as `points.x.get(0, fallback)`,
`points.x.get(index: 0, fallback: fallback)`,
`points.x.view(start, len)`, `points.x.front(fallback)`, and
`points.active.contains(element: true)`, desugar to the same helper calls. `for
value in points.x` iterates copied column elements without moving the
descriptor. The slice backing fields remain private, so `points.x.data` is
rejected. Column views are not
mutable array owners; `set(points.x, ...)`, `swap(points.x, ...)`,
`fill(points.x, ...)`, and method spellings such as `points.x.set(...)` are
rejected by the same Array-only write-helper gate as ordinary slices. Column
views obey the same local/parameter-only slice boundary as ordinary slices, so
returning or storing `points.x` is rejected rather than extending
descriptor-backed storage lifetimes. They also do not implicitly materialize an
owned array: binding or passing `points.x` where `Array of T` is expected is
rejected. Source may also read descriptor length through
`length(points)` or `length(values: points)` on a descriptor value, including `peek`
descriptors.
Generated descriptor storage fields remain private source details: `points.len`
is rejected, while `points.x.len` is accepted because `points.x` is a slice
view.
`empty(points)` and `notEmpty(points)` are the corresponding zero/nonzero
length checks. `hasIndex(points, index)` and
`hasIndex(values: points, index: index)` check `0 <= index < length(points)`.
`hasRange(points, start, len)` and
`hasRange(values: points, start: start, len: len)` check that a half-open
descriptor window is inside `length(points)`.
These lower to the descriptor `len` field without exposing column pointers.
Safe source operations over owned columns are a later data-oriented API slice.

Generated C emits `_Static_assert` checks for packed field offsets, packed size,
packed byte alignment, minimum aligned-record alignment, aligned-record stride,
aligned-record field non-overlap and extent, empty packed/aligned-record backing
fields, and soa descriptor column order/extent.
For each layout-controlled record, generated C also defines
`MERIDIAN_LAYOUT_METADATA_VERSION` plus `MERIDIAN_LAYOUT_METADATA_HAS_*`
feature flags describing the emitted layout metadata contract.
Per-record generated C defines
`MERIDIAN_LAYOUT_KIND_Name`, `MERIDIAN_LAYOUT_REQUESTED_ALIGN_Name`,
`MERIDIAN_LAYOUT_SIZE_Name`, `MERIDIAN_LAYOUT_ALIGN_Name`, and
`MERIDIAN_LAYOUT_FIELD_COUNT_Name`, where field count is the source field count,
and `MERIDIAN_LAYOUT_STORAGE_FIELD_COUNT_Name`, where storage field count
includes compiler backing fields such as `_unit`, plus length-tagged
`MERIDIAN_LAYOUT_OFFSET_Rn_Name_Fm_field` and
`MERIDIAN_LAYOUT_FIELD_SIZE_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_TYPE_NAME_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_TYPE_KIND_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_TYPE_LAYOUT_KIND_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_TYPE_REQUESTED_ALIGN_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_TYPE_SIZE_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_TYPE_ALIGN_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_TYPE_FIELD_COUNT_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_TYPE_STORAGE_FIELD_COUNT_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_END_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_ALIGN_Rn_Name_Fm_field` /
`MERIDIAN_LAYOUT_FIELD_INDEX_Rn_Name_Fm_field` macros so C bindings can inspect
the pinned layout without duplicating the compiler's lowering rules. For source
fields, generated C also defines index-addressable aliases:
`MERIDIAN_LAYOUT_FIELD_NAME_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_OFFSET_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_SIZE_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_TYPE_NAME_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_TYPE_KIND_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_TYPE_LAYOUT_KIND_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_TYPE_REQUESTED_ALIGN_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_TYPE_SIZE_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_TYPE_ALIGN_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_TYPE_FIELD_COUNT_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_TYPE_STORAGE_FIELD_COUNT_Rn_Name_Ii`,
`MERIDIAN_LAYOUT_FIELD_END_Rn_Name_Ii`, and
`MERIDIAN_LAYOUT_FIELD_ALIGN_Rn_Name_Ii`. Generated C also defines storage-index
aliases `MERIDIAN_LAYOUT_STORAGE_FIELD_NAME_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_IS_SOURCE_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_SOURCE_INDEX_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_OFFSET_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_SIZE_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_TYPE_NAME_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_TYPE_KIND_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_TYPE_LAYOUT_KIND_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_TYPE_REQUESTED_ALIGN_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_TYPE_SIZE_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_TYPE_ALIGN_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_TYPE_FIELD_COUNT_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_TYPE_STORAGE_FIELD_COUNT_Rn_Name_Si`,
`MERIDIAN_LAYOUT_STORAGE_FIELD_END_Rn_Name_Si`, and
`MERIDIAN_LAYOUT_STORAGE_FIELD_ALIGN_Rn_Name_Si` over the emitted C storage
fields. Field indexes are source-field indexes only; empty record backing fields
such as `_unit` have offset, size, end, alignment, and storage-index aliases but
no source-field index or index-addressable source-field alias. Storage aliases
include `MERIDIAN_LAYOUT_STORAGE_FIELD_IS_SOURCE_Rn_Name_Si`, which is `1` for
source fields and `0` for compiler backing fields, and
`MERIDIAN_LAYOUT_STORAGE_FIELD_SOURCE_INDEX_Rn_Name_Si`, which gives the
matching source-field index or `-1` for compiler backing fields. The length tags
prevent collisions between names such as `A_B.c` and `A.B_c`. Those macros are
guarded by `_Static_assert` checks proving the requested alignment, record size,
record alignment, source field count, storage field count, field offsets, field
sizes, field ends, field alignments, and field indexes fit Meridian's `I32`
metadata range.
`MERIDIAN_LAYOUT_KIND_NONE`, `MERIDIAN_LAYOUT_KIND_PACKED`,
`MERIDIAN_LAYOUT_KIND_ALIGNED`, and `MERIDIAN_LAYOUT_KIND_SOA` name the
currently emitted layout-kind values.
`MERIDIAN_LAYOUT_FIELD_TYPE_KIND_PRIMITIVE`,
`MERIDIAN_LAYOUT_FIELD_TYPE_KIND_LAYOUT_RECORD`, and
`MERIDIAN_LAYOUT_FIELD_TYPE_KIND_BACKING` name the currently emitted field type
kind values for primitive fields, nested layout-record fields, and compiler
backing fields. Field type layout-reference macros point at a nested
layout-controlled record's own kind, requested alignment, source field count,
size, alignment, and storage field count, or emit `MERIDIAN_LAYOUT_KIND_NONE`
and `0` values for primitive and backing fields. The standalone ABI header from
`meridian emit-abi` emits the same metadata version, feature flags, and
layout-kind and field type-kind values so C bindings can check compatibility
before consuming generated layout metadata.
Ordinary `type` still uses the backend's natural record layout.

Layout control cannot contain owned or exact-use fields, cannot contain capability
tokens, cannot contain unpinned aggregate fields, cannot define cleanup
behavior, and cannot bypass wrapper invariants. The current boundary closes
packed/aligned records plus declaration-only soa descriptors and copied-column
owned SoA construction/cleanup; mutable owned-column operations, implicit
AoS/SoA conversion, generic layout records, owned/exact-use layout fields, and
richer layout reflection are future modules outside this boundary.
formats, file formats, and device protocols should still use explicit
encode/decode functions unless the ABI contract for that boundary is also
specified.

The first implemented derive form is equality for concrete copied records, copied
enums, and copied errors:

```meridian
copied type Point:
  x: I32
  y: I32
end

derive equal for Point
```

This generates an operation-style equality function that is called with method
syntax:

```meridian
if left.equal(right):
  42
else:
  0
end
```

Current `derive equal` restriction: the target must be a concrete copied record,
concrete copied enum, or copied error. Record fields, enum payloads, and error
payloads must be `I32`, `I64`, `Bool`, `Unit`, or a copied record/enum/error that also
has `derive equal` or a visible-at-the-derive-site `equal` operation with the
shape `equal(other: T) returns Bool`. Imported private derived operations and
private manual operations do not participate in local derivation. Unit fields
and payloads are always equal.
Generic types and owned/exact-use targets are later slices.
`derive equal` can target error types for caught/thrown error workflows, but
bare error variants are not ordinary value constructors in v0. Standard
collection equality therefore has run-tested record and enum element coverage;
error-value collection membership waits until error value construction is a real
source surface.

`derive show for T` currently supports concrete copied records with `I32`,
`I64`, `Bool`, `Unit`, or showable copied record/enum/error fields, concrete copied enums
with `I32`, `I64`, `Bool`, `Unit`, or showable copied record/enum/error payloads, and
copied errors with the same payload restrictions. A nested copied record/enum/error
is showable when it also has `derive show` or a visible-at-the-derive-site
`show` operation with the shape
`show(allocator: Allocator) returns String throws AllocError`. Imported private
derived operations and private manual operations do not participate in local
derivation. It
generates an operation-style function called with allocator authority because
showing allocates a `String`:

```meridian
let text = try point.show(allocator)
```

Inside a checked allocator context, or inside a helper declaring
`needs allocator`, the same operation may omit the trailing allocator:

```meridian
context allocator = allocator:
  let text = try point.show()
end
```

The omitted form still lowers to an emitted C call that passes allocator
explicitly. Without visible or forwarded allocator context, `point.show()`
rejects; write `point.show(allocator)` when the allocator should be explicit at
the call site.

Record fields render as `Type field: value`; enum and error variants without
payloads render as `Variant`, and enum/error variants with payloads render as
`Variant payload: value`.

The generated operation returns `String throws AllocError`. Generic records and
enums/errors, owned/exact-use records/enums/errors, and richer formatting are later
slices.

Field syntax:

```meridian
fieldName: Type
```

Optional type:

```meridian
Option of T
```

There is no universal `null`, and Meridian does not use `T?` optional sugar.

## 10. Record Construction

Records are constructed with named arguments.

Compact:

```meridian
let point = Point(x: 10 y: 20)
```

Parenthesized:

```meridian
let point = Point(x: 10 y: 20)
```

Multiline parenthesized construction is preferred for larger values:

```meridian
let user = User(
  id: UserId.new()
  name: input.name.trim()
  email: email
  createdAt: Instant.now()
)
```

Field shorthand may use a bare local name when a binding has the same name as a
record field:

```meridian
let id = UserId.new()
let name = "Ada"
let email = None

let user = User(
  id
  name
  email
)
```

Equivalent to:

```meridian
let user = User(
  id: id
  name: name
  email: None
)
```

Constructor blocks with `end` are not canonical. `end` is reserved for
declarations, control flow, lambdas, and signal group blocks.

Current v0 record literal restriction: each field may be initialized at most
once. Duplicate initializer names are rejected before C emission.

## 11. Enums

Enums define variants:

```meridian
enum Option of T:
  Some value: T
  None
end
```

```meridian
enum Shape:
  Circle radius: Float
  Rect width: Float, height: Float
end
```

Enums may be explicitly classified with the same ownership modifiers as
records:

```meridian
copied enum MaybeId:
  Some value: I32
  None
end

owned enum Token:
  Id value: I32
  End
end
```

Unmarked enums are copied when all payloads are copied and owned when any payload
is owned. `copied enum` rejects owned payloads. Exact-use transfer is expressed
with `consume` at function, operation, and signal-operation boundaries;
`linear enum` is not a source declaration form.

Variant construction:

```meridian
Some user
None
Circle 4.0
Rect width: 10, height: 20
```

Parentheses may be used for clarity:

```meridian
Rect(width: 10, height: 20)
```

Qualified variants use dot syntax:

```meridian
Shape.Circle 4.0
Result.Ok value
```

Slash qualification is not used:

```meridian
Shape/Circle
```

## 12. Typed Throws

Typed `throws` is Meridian's built-in abortive error flow. Recoverable error
payloads are declared with `error`.

```meridian
error FindUserError:
  NotFound id: UserId
  Database source: DbError
end
```

Throwing:

```meridian
throw NotFound id
```

Throwing function:

```meridian
findUser(id: UserId) returns User throws FindUserError:
  ...
end
```

Using a throwing expression in a value position requires `try`:

```meridian
let user = try findUser(id)
```

Multiple error types:

```meridian
loadUser(id: UserId) returns User throws DbError, DecodeError:
  ...
end
```

Every `throws` entry must name an `error` type, and duplicate entries are
rejected. The surface language treats `throws` as a set of possible abortive
error types. The current compiler slice lowers multi-error `throws` sets with a
generated tagged error-set wrapper for C, and block `try` / `catch` can recover
from multiple thrown error types in one local handler.

A function that does not declare `throws` cannot let an abortive throw escape.
A local `catch` handles the thrown error and removes it from the expression's
outward error set.

`throws`, `throw`, `try`, and `catch` are typed error-flow syntax, not
unchecked exception plumbing. `throw` aborts the current path and does not
resume the failed continuation.

## 13. Try / Catch

`try` and `catch` are handlers for typed abortive errors. Prefix `try expr`
propagates a thrown error; block `try: ... catch ... end` recovers locally from
errors raised anywhere in the protected expression,
including a direct `throw`.

The current compiler slice implements typed `throw`, prefix `try` propagation
for fallible expressions including throwing calls and direct `throw`, and block
`try` / `catch` local recovery for fallible expressions including throwing
calls, nested call arguments, binary expressions, direct local `throw`, and
block bodies whose local declarations are copied or owned values. Owned
try/catch-local declarations are dropped when the handler block exits, including
after a later fallible expression fails. Owned try/catch-local values can be
used or transferred under the same move-once rule as ordinary owned locals, and
cleanup is skipped after transfer. Exact-use transfers inside `try` / `catch`
must happen before any fallible path that could skip them, or through a direct
throwing tail call that owns moved arguments. If a fallible statement could skip
the transfer, the program is rejected.
Coroutine wait syntax is not core Meridian. Event-loop work belongs in a
library/runtime module over signaling and handles. Space-call examples remain
design syntax until that frontend piece lands.

Try expression:

```meridian
let user = try findUser(id)
```

Catch block:

```meridian
try:
  findUser(id)
catch NotFound id:
  renderMissing id
catch Database err:
  renderError err
end
```

A `try` block is an expression:

```meridian
let view =
  try:
    findUser(id)
  catch NotFound id:
    MissingUserView id
  catch Database err:
    ErrorView err
end
```

A catch block can also recover from a direct local `throw`:

```meridian
try:
  throw NotFound id
catch NotFound id:
  renderMissing id
catch Database err:
  renderError err
end
```

A catch must cover all possible thrown error variants or error types unless
the enclosing function declares the unhandled errors in its own `throws` set.

## 14. Conditionals

Block conditional:

```meridian
if condition:
  consequence
else:
  alternative
end
```

Else-if:

```meridian
if score >= 90:
  "excellent"
else if score >= 70:
  "good"
else:
  "needs work"
end
```

`if` is an expression:

```meridian
let label =
  if active:
    "Active"
  else:
    "Inactive"
  end
```

Inline conditional uses `:`:

```meridian
let label = if active: "Active" else: "Inactive" end
```

Boolean operators are words:

```meridian
if user.active and not user.deleted:
  sendEmail user.email
end
```

Use `and`, `or`, and `not`, not `&&`, `||`, or `!`.

## 15. Pattern Matching

Match expression:

```meridian
match value:
  Pattern:
    body

  OtherPattern:
    body
end
```

Example:

```meridian
area(shape: Shape) returns Float:
  match shape:
    Circle radius:
      pi * radius * radius

    Rect width, height:
      width * height
  end
end
```

Short arms use `:`:

```meridian
let label = match status:
  Active: "Active"
  Paused: "Paused"
  Deleted: "Deleted"
end
```

Multiline arms use `:` with an indented body:

```meridian
match result:
  Success value:
    value

  Failure reason:
    log reason
    fallback
end
```

Patterns:

```meridian
Some value
Some(value)
Some(value: item)
None
Ok value
Err error
User(id, name, email)
User(id: id, name: name)
_
```

Wildcard:

```meridian
_
```

No arrow syntax is used in match arms.

Current v0 match syntax accepts `Variant:` or `Variant():` for a no-payload
variant and `Variant binding:`, `Variant(binding):`, or
`Variant(payload: binding):` for a single enum payload binding. The checker
applies the same payload/no-payload rules to every spelling and verifies the
payload name when one is written.

Current v0 ownership restriction: `match` may inspect copied enum values and
consume owned enum values with payload transfer and arm-local cleanup.
Source-level `linear enum` is rejected; exact-use behavior is expressed through
owned values and `consume` boundaries.

Current v0 variant operations provide exhaustive variant dispatch for copied or
owned enum receivers. A variant operation is written as cases over
one enum's variants and called with ordinary operation syntax. The declaration
stays explicit about the data cases, and the compiler requires every variant to
be handled. Ordinary parameters after the receiver are allowed when they are
copied, owned, `consume` transfer parameters, or read-only peek values; dispatch
is still based only on the receiver.

Canonical operation declarations put the operation name immediately after the
`operation` keyword, then introduce the receiver with `on`. The word after
`operation` is the declared operation name; `on Receiver` is only the dispatch
target. This keeps names such as `scoreOrDefault` visible instead of burying
them inside a receiver-qualified header.

```text
operation name on Receiver(...)
```

```meridian
operation area on Shape returns I32:
  Circle(radius):
    radius * radius * 3
  Rect(size):
    size * size
end

let a = shape.area()
```

Operation case bindings accept the same forms as match arms: `Variant:` or
`Variant():` for a no-payload variant and `Variant binding:`,
`Variant(binding):`, or `Variant(payload: binding):` for a single-payload
variant.

Copied parameters:

```meridian
operation scale on Shape(factor: I32) returns I32:
  Circle radius:
    radius * factor
  Rect size:
    size * factor
end

let a = shape.scale 2
```

Generic enum receivers may declare the same operation once over one or two type
parameters. The operation specializes when a concrete receiver type reaches a
method call:

```meridian
enum Maybe of T:
  Some value: T:
  None:
end

operation unwrapOr on Maybe of T(fallback: T) returns T:
  Some value:
    value
  None:
    fallback
end

operation scoreOrDefault on Maybe of T(fallback: I32) returns I32 requires score(T) returns I32:
  Some value:
    score(value)
  None:
    fallback
end

main returns I32:
  let maybe = Some of I32(42)
  maybe.unwrapOr 0
end
```

Two-parameter generic enum operations use the same explicit `of A B` receiver
shape:

```meridian
enum Either of A B:
  Left value: A:
  Right value: B:
end

operation valueOr on Either of A B(fallback: A) returns A:
  Left value:
    value
  Right ignored:
    fallback
end
```

Nested generic constructor arguments also materialize the inner concrete type:

```meridian
let maybe = None of Box of I32
```

Record generic specializations support multiple type parameters:

```meridian
type Pair of A B:
  first: A
  second: B
end

let pair = Pair of I32 Bool(first: 42 second: true)
```

Record receivers use the same operation call syntax, but their bodies are
ordinary expression bodies with an explicit `self` receiver:

```meridian
type Box of T:
  value: T
end

operation get on Box of T returns T:
  self.value
end

let box = Box of I32(value: 42)
let value = box.get
```

Two-parameter generic record receivers are also specialized at method-call
sites:

```meridian
operation first on Pair of A B returns A:
  self.first
end
```

Record receiver operations may use `requires` clauses, and owned record
receivers follow the same move and cleanup rules as ordinary owned parameters:

```meridian
operation score on Box of T returns I32 requires score(T) returns I32:
  score(self.value)
end

operation takeFirst on Pair returns Inner:
  self.first
end
```

Peek parameters:

```meridian
operation scaleBy on Shape(factor: peek Factor) returns I32:
  Circle radius:
    radius * factor.value
  Rect size:
    size * factor.value
end

let factor = Factor(value: 2)
let a = shape.scaleBy factor
```

Owned and exact-use parameters:

```meridian
operation measure on consume Shape(buffer: consume Buffer ticket: consume Ticket) returns I32:
  Circle radius:
    radius + buffer.value + useTicket(ticket)
  Rect size:
    size + buffer.value + useTicket(ticket)
end
```

The call is surface syntax for an exhaustive `match` over `Shape`. It is not a
dynamic method and it is not unchecked multiple dispatch. Multi-argument
variant operations may be considered later, but single-receiver exhaustive
variant dispatch is the first model. Owned receivers are consumed by the
generated operation exactly as an explicit `match` would consume them.
Operation calls may use named arguments:

```meridian
let measured = shape.measure(ticket: tx, buffer: buf)
```

Named operation arguments, including arguments to generic operation
specializations, are checked against operation parameter names and
evaluated/emitted in the declaration's parameter order.
Owned parameters are cleaned by the generated operation when still live, and
`consume` parameters cannot be reused by the caller.
Variant operations may declare typed `throws`; callers must
use `try` just as they do for ordinary throwing functions, and operation bodies
may only throw declared errors. Generic operation specializations preserve
typed `throws`, including record-receiver operations and enum variant
operations. Generic operation headers may use concrete structural `requires`
clauses. Operation headers still reject `signaling` clauses in v0. The
compiler reserves its
generated operation receiver name, so ordinary operation parameters and case
bindings cannot be named `nl_op_receiver`. Operation names follow the same
public identifier restrictions as other backend-emitted names, and operation
case bindings follow the same local binding restrictions as ordinary match
bindings. Operation case bindings may use `Variant:`, `Variant():`,
`Variant binding:`, `Variant(binding):`, or `Variant(payload: binding):`.
Although operations lower through an exhaustive `match`, diagnostics
for missing, duplicate, unknown, incorrectly bound, or inconsistently typed
operation cases are reported in operation terms.

Current v0 field restriction: field access may project from copied records. Owned
records may expose copied fields by value without moving the record.
Owned rvalue records may also expose copied fields by first storing the base in a
compiler-owned temporary, reading the copied field, and then cleaning the base
temporary. Owned records may move owned fields out of local records or owned
rvalue record temporaries with partial-move cleanup for the remaining fields.
The moved field may transfer into a binding or return value directly. When that
moved field appears before later fallible call arguments or record fields,
lowering stores the field in a compiler-owned temporary and cleans it on the
later failure edge. Exact-use field moves outside owned cleanup remain gated
until the language has peek-only projection or checked partial-move obligations.

Current conditional restriction: `Bool`, `true`, and `false` are supported.
`I32` arithmetic supports `+`, `-`, `*`, `/`, `%`, and unary `-`; the minimum `I32`
literal may be written as `-2147483648`. Equality uses `=` and accepts either
two `I32` operands or two `Bool` operands. Inequality is written as `not x = y`.
Ordered comparisons
`<`, `<=`, `>`, and `>=` are supported for `I32`. Boolean operators are the
words `and`, `or`, and `not`; their operands must be `Bool`. The supported
boolean-operator slice supports fallible operands. The left operand of `and` and
`or`, and the operand of `not`, may move owned or consumed values because they are
always evaluated. The right operand of `and` and `or` may not move owned or
consumed values yet because short-circuiting control flow needs branch-sensitive
move joins. `if` expressions require a `Bool` condition and same-typed branches.
Branches may be small blocks with copied, owned, or branch-local consumed
`let` bindings. Owned branch locals are cleaned before the branch assigns its
result. Consumed branch locals must be consumed, moved, or returned inside that
same branch before it exits. Conditions and branch bodies may be fallible, and
fallible branch paths use the branch block's cleanup scope before propagation.
`if` uses the same branch-sensitive move join as `match`: moving an outer owned
or consumed value in every branch is valid, while moving it in only one branch is
rejected.

Current v0 peek restriction: `peek T` is supported only for read-only
ordinary function and variant operation parameters. A peek argument must be
a local value or a copied field projection rooted in a local value at the call
site; the call does not move or clean up the peek value. The temporary
peek root stays live for the remainder of that same call/method argument list,
so safe code rejects moving or consuming that peek owner before the
call/method expression completes. Peek record values may read copied fields.
Returned peeks, stored peeks, peek fields, escaping peeks, and
`peek mut T` are rejected. Mutation uses owned collection operations in the
core surface; future mutable column/view authority belongs to owned SoA or
data-oriented modules, not to general mutable peek syntax. Returned peek views
should be modeled as scoped `signal` payloads handled by an enclosing `enact`,
not as ordinary return values with lifetime parameters.
Peek polymorphism is also rejected: a generic function or `requires` entry
cannot use direct `peek T`. Use a concrete peek parameter, a standard
peek collection view such as `peek Array of T`, or pass a generic value
by ordinary owned/copied rules. Peek standard collection views can be
forwarded through matching generic helpers, but they remain non-storable and
non-returnable.

`Slice of T` follows the same local-or-parameter-only restriction as a
peek-like copied view. Returned slices are rejected, and slices stored in
owned records, enums, or errors are rejected. `values.len` or `length(values)` reads the view
length. Copied-element slice reads use the shared
`get(values, index, fallback)` operation, including its named-argument form;
the read copies the element and does not change slice ownership.

Current v0 error restriction: recoverable `error` payloads may be copied or owned
values. Owned payloads move into the thrown error value and move out through the
catch payload binding. Catch payload bindings may be written as
`catch Variant:`, `catch Variant():`, `catch Variant binding:`,
`catch Variant(binding):`, or `catch Variant(payload: binding):`. If the
binding remains live at catch-arm exit, it is cleaned like any other owned
local. Exact-use error payload transfer uses ordinary owned payloads plus
`consume` where a boundary takes ownership. Error payload expressions may throw through
ordinary propagation paths and inside locally recovering `try` block bodies. On
propagation paths, live owned locals are cleaned before propagating the payload
evaluation error. Inside local recovery, a payload evaluation error is stored in
the local recovery state and dispatched to the matching catch arm.

### Current exact-use transfer rule

Values passed through `consume` boundaries
cannot be reused by the caller, and checked handles or other exact-use values
must be consumed, moved into another owner, or returned on every path.
`consume value with finalizer(value)` requires
the finalizer to exist, take exactly one argument of the consumed value's type,
return `Unit`, and not declare `throws`. `using name = expr with
finalizer(name): ... end` gives the compiler ownership of one exact-use binding for
the duration of the block; the binding cannot be moved or consumed inside the
body, and the named finalizer is emitted on normal exit and thrown paths.
Source-level `linear` declarations and `linear T` element modifiers are rejected
in favor of `owned` storage plus explicit `consume` transfer.

`with` is not a standalone scope keyword. Its source meanings are deliberately
closed to subject binding (`with subject: ... end`) and explicit finalizer
clauses (`consume value with finalizer(value)` and
`using value = expr with finalizer(value): ... end`). Meridian uses specific
scope words for specific powers: `region` for lexical bulk allocation,
`context` for scoped capabilities/defaults, and `compile` for compile-time
execution.

Current v1 context restriction: `context name = value: ... end` is supported as a
local lexical block expression. The initializer is evaluated first, then `name`
is visible only inside the body. The bound value must be copied; owned and consumed
values are rejected because `context` is for capability/default selection, not
resource transfer. The C backend emits a nested lexical block.

`needs name` clauses on function and operation headers declare explicit
contextual authority requirements. The compiler currently recognizes
standard authority values such as `needs allocator`, `needs timeSource`,
`needs randomSource`, `needs terminal`, `needs environmentAccess`, and
`needs fileAccess`, plus context names established by top-level copied constants.
The constant gives a custom need its name and type; it does not silently satisfy
the need at call sites. A needed context must be visible at every call site,
normally through a surrounding `context name = ...: ... end` block or by
forwarding the same `needs name` clause from the caller. For example:

```meridian
const trace: Bool = true

usesTrace returns I32 needs trace:
  if trace:
    42
  else:
    0
  end
end

main returns I32:
  context trace = false:
    usesTrace()
  end
end
```

`main` cannot declare `needs`; it must establish context locally. Needed values
are emitted as hidden C parameters, but the Meridian source keeps the authority
visible through the `needs` header and the local `context` block. `needs` is
context-sensitive: it is a header clause word, not a globally reserved
identifier.

Custom `needs name` entries must be visible where the function or operation is
declared. A private constant from an imported module cannot silently define a
local contextual authority name in the importing module. The declaring module
must define the top-level copied constant itself or import an exported context
constant. With an explicit `from namespace import module exposing ...` list,
must be named in that exposing list before local code can declare `needs name`.
The same visibility rule applies at call sites: a caller cannot satisfy an
imported callee's custom context need with a local `context name = ...` block
unless `name` is visible to the caller. Standard authority names are built-in
exceptions: `allocator`, `timeSource`, `randomSource`, `terminal`,
`environmentAccess`, and `fileAccess` do not need exported top-level constants.

When a module uses explicit `export` markers, any exported function or operation
whose header includes a custom `needs name` must also export the top-level copied
constant that defines that context name. Standard authority names remain
built-in exceptions. This keeps public APIs from smuggling private authority
names across module boundaries.

Exported function and operation signatures are also public APIs. Every named
type or error appearing in an exported callable's parameters, receiver type,
return type, nested function types, or `throws` list must also be exported or be
a standard always-visible type. Generic type parameters declared by the callable
are nameable through that callable and do not need separate exports.

Exported data declarations follow the same public-surface rule. Every named
type or error appearing in an exported record field, enum payload, error
payload, or nested function type inside those field/payload signatures must also
be exported or be a standard always-visible type. Generic type parameters
declared by the exported record or enum are nameable through that declaration
and do not need separate exports.

The same public-surface rule applies to user-defined signaling. When a module uses
explicit `export` markers, any exported function or operation whose header
includes a user-defined `signaling Name` row must also export the matching
`signaling Name:` declaration. Standard signaling such as `Memory`, `Time`, `Random`,
`TerminalIo`, `Environment`, and `FileIo` are built-in public names and do not
need local export markers. This keeps public signaling rows nameable by importers
and prevents exported APIs from depending on non-exported signaling authority
names.
An exported signal group declaration is itself a public API: every named type or
error appearing in its operation parameters, return types, nested function
types, or `throws` list must also be exported or be a standard always-visible
type.

Current v0 cleanup order: live owned locals are dropped in reverse declaration
order. Structural drops for owned records/enums/errors drop owned fields or
payloads in reverse field declaration order. For each such owned component, the
generated structural drop calls `drop(value: T) returns Unit` when a matching
source drop exists, otherwise it recurses structurally. Cleanup is skipped for
owned values that were moved into another owner or returned to the caller.

Current v0 region restriction: `region name: ... end` is supported as a local
lexical block expression. `region r: ... end` is local and lexical only.
Region-local `let` bindings do not escape the region, owned region-local values
are cleaned at region exit, and the C backend emits a nested C block for
source-name containment.

The region name introduced by `region r:` is a lexical capability token, not an
owned value and not a public copied value. It authorizes allocation into that
region only while checking the matching region body. It cannot be assigned,
returned, stored, captured, thrown, or constructed.

`Region` is the explicit capability parameter type for APIs that need caller
provided temporary allocation authority:

```meridian
useRegion(scratch: Region) returns I32 throws AllocError:
  let buffer: Buffer in scratch = try allocRegionBuffer(scratch, len)
  buffer.len
end

main returns I32:
  try:
    region scratch:
      try useRegion(scratch)
    end
  catch AllocationFailed:
    1
  end
end
```

A `Region` parameter may be passed to another function that expects `Region`
and may authorize local `T in region` bindings inside that function. It is still
parameter authority only: `Region` cannot be returned, thrown, stored in
records/enums/errors, constructed as a source value, or hidden behind a type
alias. Public imports and exports may expose explicit `Region` parameters, but
`type Scratch = Region` is rejected; region authority must stay visibly named as
`Region`. Region-qualified `T in r` public parameters, returns, throws, fields,
payloads, constants, callable type aliases, `requires` entries, and signal
operation signatures remain rejected until their import/export and escape rules
are complete.

The first bulk region allocation surface is intentionally narrow:

```meridian
region scratch:
  let buffer: Buffer in scratch = try allocRegionBuffer(scratch, len)
  buffer.len
end
```

`allocRegionBuffer(region, len)` returns `Buffer throws AllocError`, requires a
matching `Buffer in region` binding, exposes only `len`, and releases the
allocated bytes at normal region exit, `return`, `throw`, and `try`
propagation. The named form `allocRegionBuffer(region: r, len: len)` is
equivalent. Region-qualified buffers may use the same metadata-only helper
surface as ordinary buffers: `length(buffer)`, `buffer.length()`, `empty(buffer)`,
`buffer.empty()`, `notEmpty(buffer)`, `hasIndex(buffer, index)`,
`buffer.hasIndex(index: index)`, and
`hasRange(values: buffer, start: start, len: len)` read only the stored length
and do not move or escape the buffer. Multiple
region-buffer allocations in the same region body are allowed. Copied-state
loops inside an allocating region may use `break` and `continue`; loop control
does not skip lexical region teardown. Explicit public `T in r`
region-polymorphic APIs are not part of the current v0 implementation slice; use
a `Region` capability parameter and keep region-qualified values local to the
function body.

In this slice, a local region-provenance annotation is available as an internal
form:

`T in r`

`T in r` is only valid inside the matching `region r: ... end` body or inside a
function body whose parameter `r: Region` grants that authority. It is not a
public API feature. Function parameters, returns, and throws, record fields,
enum payloads, error payloads, constant annotations, callable type aliases,
`requires` entries, and signal operation signatures including throws reject
`T in r` until public region-polymorphic APIs own their authority and escape
rules. Lambda parameter annotations are checked before callback lowering, so a
direct callback argument cannot use `T in r` outside the matching lexical region
or capability-authorized function body and then have the qualifier erased by
callback specialization.

Region-qualified values cannot escape:

- by `return`
- by assignment to an outer binding
- by function-call transfer that moves ownership out of the region
- by being stored in an owned value that outlives the region.

This slice provides the standard allocator token, allocation error surface,
owned `Buffer`, region-owned `Buffer in r` through `allocRegionBuffer(r, len)`,
heap indirection through `Box of T`, and copied-element `Array of T`, plus minimal
owned `String`. Other allocator-backed owned containers remain future work unless
implemented by another layer.

Runtime and FFI representation rule for this slice:

- Raw C pointers have no source-level Meridian type yet. They are not `copied`,
  `owned`, `peek`, `region`, or handle values.
- C-owned memory and Meridian-owned memory do not cross the FFI boundary as raw
  values. Runtime-backed operations are declared as ordinary direct signal
  operations over explicit capability parameters, `peek` parameters,
  handle resource values, and typed `throws`.
- Passing an owned value or `consume` parameter into a runtime-backed signal transfers it by
  the same move rules as an ordinary call. Passing `peek T` does not transfer
  ownership. Owned results are compiler-cleaned or dropped by their safe drop
  hook. Exact-use handle results must be consumed, moved, returned, or finalized
  exactly once.
- C-owned allocations stay behind runtime stubs and opaque handles. Meridian
  owned allocations stay Meridian-owned and are freed by normal compiler
  cleanup. If a later C binding needs a different allocator/free rule, that rule
  must be represented as a typed handle/signaling contract before it is safe
  source.
- Generated C defines `MERIDIAN_ABI_VERSION`, stable primitive aliases, stable
  standard `Allocator`/`Buffer`/`String` ABI layouts, standard authority tokens,
  standard `File`/`Directory` resource wrappers, standard typed errors, standard
  result wrappers for fallible runtime-backed signaling, standard runtime-backed
  signal prototypes, feature macros, layout-kind constants, C11 layout
  assertions for standard authority tokens, typed errors, error sets, and every
  standard result wrapper, and lowers source handles through the shared
  `MeridianHandle` wrapper. `meridian emit-abi module.mer` also emits the
  checked module's source-level copied-record, enum, capability, handle, error,
  multi-error error-set, direct slice-parameter, fallible signal-result, and
  signal prototype declarations for runtime binding code, plus generator-facing
  binding metadata for each source signal operation: C symbol, source/C result
  type, throw count/type names, parameter names, source/C parameter types, and
  copy/peek/consume access mode. It also emits `static inline
  MeridianBinding_Group_operation(...)` wrappers that keep peek parameters
  pointer-free at the binding surface while delegating to the ABI prototype
  internally. It also emits C11 layout assertions for
  copied-record fields, enum tags and payloads, capability tokens, handles,
  error tags and payloads, error-set tags and payloads, direct slice-parameter
  `data`/`len` order, and result boundary types. Stored and returned slices
  remain rejected. ABI layout details are tracked in
  [docs/abi.md](docs/abi.md), snapshot-tested, and available through `meridian
  emit-abi`. `meridian emit-bindings module.mer -o dir` packages the same
  checked header with `meridian_bindings.h` wrapper aliases and typed
  `MeridianBindingFn_Group_operation` function-pointer aliases,
  `meridian_host_adapter.h` typed host adapter tables,
  `meridian_bindings.json` generator metadata including package file names,
  feature flags, ABI/bindings versions, operation/throw/parameter counts,
  wrapper names, adapter header names, and typedef names, `meridian_runtime_template.c`
  implementation guidance, `meridian_runtime_link_stub.c` generated-package
  link-smoke stubs, `meridian_binding_smoke.c` caller-side signature checks,
  `meridian_binding_link_smoke.c` link-smoke main, `meridian_bindings.pc`
  pkg-config include metadata, and a short README, so C binding code can include
  one package header and other generators can consume the manifest without
  introducing safe source raw pointers. The generated package is regression
  checked across opaque handles, direct slices, typed errors, pointer-free peek
  wrapper parameters, and consumed values.
- Runtime resources enter the safe language through direct signaling and opaque
  handles, such as `FileIo` returning owned handle `File`; safe code does not use
  `external`, `trusted`, `unsafe`, raw pointer, or FFI-specific escape keywords.
- Peek-view expansion should not introduce user-written lifetime parameters.
  Temporary parser/string/buffer/resource views should be authorized by scoped
  signaling where needed, while ordinary local peek checks still reject storing
  or returning peeks, moving an owner under a live peek, and suspension
  across boundaries that do not explicitly permit peek state.
- Callback-heavy APIs are not the preferred way to express borrowed traversal,
  event streams, parser output, or staged resource interaction. Use
  `signal`/`enact` as the structured handoff layer for those cases; keep
  callback parameters for small local customization, stored function values, and
  interop with function-typed APIs.
- `async`, `await`, and `yield` are not part of the core direction. If a design
  wants coroutine-like or generator-like handoff, model it first as runtime
  handles plus typed signaling through a scoped `enact` handler.
- Removing source-level `unsafe` does not disable the safe memory checker:
  ordinary code still cannot reuse consumed values, return/store peeks,
  manufacture region-qualified values, or expose raw pointer-like values through
  a safe API.

Current v0 constructor restriction: record fields, enum payloads, and function
arguments all obey the same move-once rule. Passing the same owned or consumed
binding into more than one argument or field is rejected as use after move.
Parameters, arguments, record fields, generic type variables, generic type
arguments, `throws` entries, and `requires` entries may omit commas when the next
entry has a clear syntactic start. Keep a comma only when it removes real
ambiguity. When a comma-separated list is already open, function/operation/signal
parameters, lambda parameters, function-type parameters, enact handler
parameters, generic declaration type-parameter lists, unambiguous generic
type-argument lists, call arguments, record fields, copied-slice literals,
grouped pipeline steps, `throws` entries, and `requires` entries may also keep
one final trailing comma. Empty entries remain rejected. Generic type-argument
trailing commas are accepted only before an explicit same-line terminator such as
`)`, `:`, `=`, a header clause, or constructor `(`; a comma before another
outer-list item is still the outer separator.
Enum variants with no payload may be written bare or with empty parentheses,
such as `None`, `None()`, `None of I32`, or `None of I32()`. Payload variants
require explicit call syntax, such as `Some(1)`, and may name the payload
argument, such as `Some(value: 1)` or `Some of I32(value: 1)`. Local names shadow
bare variant constructors. Bare recoverable-error variants are not ordinary
values; use `throw Variant` or `throw Variant()` to construct a no-payload error
path. Error payload throws may use the payload name, such as
`throw Failed(code: 1)`.
`Never` expressions, such as direct `throw` or explicit `return`, may satisfy
result positions by not continuing, but they cannot initialize `let` bindings
because there is no runtime value to bind or clean up. `return expr` is a
cleanup-aware early exit: the value must match the enclosing function result
type, owned locals are cleaned before the return, and live exact-use values must
be consumed or moved
before that returning path. A value managed by `using` is finalized by the
declared `using` finalizer before return.
Loop bodies are statement-only, but direct `throw Variant` is a valid loop-body
exit statement; loop-local owned values are cleaned before the error return.
Inside a local `try: ... catch ... end` recovery expression, v0 supports
`return` as the direct final expression of the `try` body. If the returned value
expression throws, local recovery continues into the matching `catch`; if it
succeeds, block locals and active outer cleanup scopes are cleaned before the
function returns. Nested `return` inside a local `try` body statement or nested
expression is still rejected; make it the try body's final expression. Return
from ordinary blocks or from catch arms is allowed.

Current v0 recursion restriction: records, enums, and errors cannot recursively
contain themselves by value. Recursive data must wait for explicit indirection
types, because structural layout and structural drop generation require a finite
ownership shape.

Current v0 fallible-expression restriction: a `try` or `try`/`catch` body may
move owned or consumed locals only when the fallible expression is a direct
throwing call that owns those arguments. For consumed arguments, the callee must
still own the transfer according to the normal consume rules. Ordinary
propagation paths also allow owned moves and consumed arguments on the left of
binary expressions with nested `try`, because binary operands are sequenced into
temporaries and cleanup or move state is settled before the right operand can
fail. Owned fields moved from owned rvalue records
may appear inside either binary operand when the subexpression has a modeled
cleanup story. Local recovery paths also allow binary shapes where owned moves
occur on either side of a fallible copied-valued operand, using dynamic
moved-state cleanup on the failure edge. Consumes are allowed on the left before
fallible copied-valued work, but consumed moves on the right after a fallible
left operand remain rejected on local recovery and propagation paths.
Owned-producing call arguments and record fields may appear on propagation and
local recovery paths even when sibling operands can throw. Values created or
moved before later fallible work are first stored in compiler-owned temporaries,
and local recovery tracks moved-state flags for outer owned values so cleanup
runs exactly once on each error edge. Consumed call arguments or record fields
with fallible sibling operands remain rejected in either order: an earlier
fallible operand can skip the required consume, and a later fallible operand
cannot auto-clean a consumed temporary. `try` block bodies may move
outer consumed locals before the first fallible statement, including explicit
`consume` statements, non-throwing statements that transfer the value, and
direct throwing tail calls that own moved arguments, but a fallible statement
before the move remains rejected because the catch edge could skip the required
consumption. Other composite fallible expressions that move or create owned or
consumed values are rejected until
lowering tracks move state and temporary cleanup at each subexpression exit.
Nested fallible composites that only move copied values remain valid.

Current v0 match behavior: match scrutinees and match arms may throw on ordinary
propagation paths, such as `match try choose(): ... end` or an arm that evaluates
`try load()` in a throwing function. Fallible matches, record literals, enum
payload constructors, and field projections may also appear in nested
copied-valued positions, such as call arguments. The same shapes are supported
inside local `try` recovery bodies, where a scrutinee, arm, field, payload, or
projection failure updates the local attempt state and dispatches to the
matching `catch` arm.

Current v0 call argument behavior: a function call may receive owned-producing
arguments on propagation and local recovery paths, including `takeInner(try
makeInner())`, `takeInner(makeInner(), try fail())`, owned field moves such as
`take(outer.first, try fail())`, and nested owned constructors such as
`take(Pair(first: try makeInner(), second: Inner(value: 2)), try fail())` or
`take(Some(try makeInner()), try fail())`. Owned-producing match expressions
may also appear before later fallible arguments when each arm transfers an
owned value. If a later argument can throw after the owned value is created, the
compiler first moves the owned value into a compiler-owned temporary and cleans
that temporary on the later failure edge. Consumed call arguments with fallible
sibling arguments remain rejected because the compiler cannot auto-clean a
skipped transfer.

Current v0 record field behavior: a record literal may receive owned-producing
field initializers on propagation and local recovery paths, including
`Pair(first: try makeInner(), second: try load())`, `Pair(first: makeInner(),
second: try fail())`, owned field moves such as `Pair(first: outer.first,
second: try fail())`, and nested owned constructors such as `Wrapper(pair:
Pair(first: try makeInner(), second: Inner(value: 2)), code: try fail())`.
Owned-producing match expressions may also appear before later fallible fields
when each arm transfers an owned value. If a later field initializer can throw
after the owned value is created, the compiler first moves the owned value into
a compiler-owned temporary and cleans that temporary on the later failure edge.
Consumed field initializers with fallible sibling fields remain rejected.

Current v0 enum payload behavior: an enum payload constructor may directly wrap
an owned fallible result, such as `Some(try makeInner())`, on propagation and
local recovery paths because the owned result either does not exist on failure
or transfers immediately into the enum payload on success. This includes owned
fields moved from owned rvalue records, such as `Some((try makeOuter()).first)`;
lowering cleans the remaining owned fields of the rvalue record after the field
move. The payload may also be an owned-producing match expression when every
arm transfers an owned value. The resulting owned enum may appear as a call
argument or record field before later fallible operands; lowering stores it in
a compiler-owned temporary and cleans that temporary on later failure. Other
nested enum payload shapes remain rejected if their cleanup story is not
modeled.

Current v0 match behavior: fallible match scrutinees and arms are supported on
propagation and local recovery paths. Match scrutinees and arms may move owned
fields out of owned rvalue records, such as
`match (try makeOuter()).choice: ... end` or
`match choice: Yes: (try makeOuter()).first ... end`; lowering cleans the
remaining owned fields of the rvalue record before dispatching the match or
assigning the arm result.

Current v0 throw payload behavior: a `throw` expression may directly wrap an
owned fallible result, such as `throw Failed(try makeInner())` or
`throw Failed(inner: try makeInner())`, on propagation and local recovery paths
because the owned result either does not exist on failure or transfers
immediately into the error payload on success. Owned fields moved from owned
rvalue records are also valid throw payloads when the remaining owned fields of
the rvalue record can be cleaned immediately.

Current v0 catch behavior: catch arm block bodies may propagate typed errors
through existing `try` and `throw` rules when the enclosing function declares
those errors. Owned locals declared inside a catch arm are cleaned before that
propagation path returns.

Current C backend restriction: `main` must take no parameters, must not declare
`throws`, and must return `I32`.

Current C backend emission rule: non-`main` zero-parameter functions are emitted
with an explicit `void` parameter list.

Current call syntax rule: functions may always be called with parentheses, but
same-line positional and named arguments may omit parentheses when the argument
boundary is clear, as in `add 1 2` or `send to: user subject: text`.
Non-throwing zero-parameter functions may also be called by name without
parentheses. Throwing zero-parameter functions are called as `try name()`.
Function and operation calls, including generic function and operation calls,
may use named arguments. Enum and error payload constructors may also use the
payload name as a named argument. Positional and named enum/error payload
constructors check the payload expression with the declared payload type as its
expected type, so wide literals work in `I64` payloads. The compiler
evaluates/emits named arguments in parameter order. A trailing `do ... end`
callback may follow a named function or operation call when it fills the final
missing function-typed parameter.

Current C backend namespace restriction: top-level type names, error names,
enum names, variant constructors, error constructors, and function names must
not collide. This keeps source lookup unambiguous and avoids invalid generated C
identifiers.

Current identifier restriction: source names emitted directly to C must not be
built-in type names such as `I32` and `Unit`, C keywords, standard identifiers
used by the emitted prelude, or generated backend prefixes such as `nl_drop_`
and `__Meridian_`. This applies to type names, constructors, payload names,
generated payload field names, functions, parameters, locals, match payload
bindings, catch payload bindings, and record fields. Names beginning with `_`
are reserved for the backend. Generated enum/error tag typedef names such as
`Choice_Tag`, generated enum/error variant tags such as `Choice_Yes`, and
generated result struct names such as `__Meridian_Result_I32_Boom` also
participate in the backend symbol table. Multiple functions may share the same
generated result struct when they have the same return and error types.
Generated enum/error payload fields such as `Some_value_code` must also be
unique within their generated payload union.

Current local binding restriction: `let` bindings, parameters, match payload
bindings, pattern payload bindings, and catch payload bindings may not duplicate
an already live local name in the same function body.

## 16. Constructor Pattern If

Pattern conditional expression:

```meridian
if user.email matches Some(email):
  sendEmail email
else:
  log "missing email"
end
```

No-payload variants omit the branch binding. Both `None` and constructor-form
`None()` are accepted:

```meridian
if user.email matches None():
  log "missing email"
else:
  log "has email"
end
```

Named payloads may bind by payload name:

```meridian
if user.email matches Some(email: address):
  sendEmail address
else:
  log "missing email"
end
```

Literal payloads check the payload value instead of binding:

```meridian
if code matches Some(3):
  handleThree
else:
  handleOther
end
```

Current v0 rule: constructor-pattern `if` requires `else` because it is an expression. Copied
enum and error scrutinees are accepted. Owned enum/error scrutinees are consumed
before either branch runs; matched owned payload bindings are cleaned or moved by
the then branch, and unmatched owned payloads are cleaned through the hidden enum
temporary in the `else` branch. Payload bindings are scoped only to the then
branch and may not duplicate an already live local name. Exact-use payload
extraction remains gated unless the payload is owned and cleanup/move-out is
modeled by the current pattern lowering. When both branches
return `Unit`, constructor-pattern `if` may also be used as a statement before the surrounding
block tail, including directly inside loop bodies.

The simple form is equivalent to:

```meridian
match user.email:
  Some email:
    sendEmail email

  None:
    log "missing email"
end
```

## 17. Loops

For loop:

```meridian
for user in users:
  total = total + user.score
end
```

While loop:

```meridian
while socket.open:
  let message = try socket.read()
  process message
end
```

Infinite loop:

```meridian
loop:
  tick()
end
```

Break:

```meridian
break
```

Continue:

```meridian
continue
```

Current compiler slice: `while`, conditionless `loop`, and `for item in values`
blocks are active statements. `for` iterates copied elements from `Array of T`,
`peek Array of T`, or `Slice of T` without moving the collection. It also
supports half-open copied `I32` and `I64` ranges as direct iterables:
`for value in start..end` visits `start` through `end - 1`. Range bounds must
both typecheck as `I32` or both typecheck as `I64`; range expressions are not
general first-class values yet. Transparent `I32`/`I64` aliases may be used where
their targets are expected because they lower before checking. Owned element
iteration is explicitly gated by the collection element rules: `Array of owned
T` and owned slice literals cannot be used to bypass missing element
initialization, replacement, move-out, and cleanup semantics. `Array of linear
T` is rejected as source syntax. Loop bodies support loop-local `let`/`var`
bindings, assignment, statement-level `if` branches, Unit or Never expression
statements for action calls, nested `while`/`loop`/`for`, `consume`, direct
`throw`, `break`, `continue`, and conditional loop exits:

```meridian
if condition:
  continue
else:
  break
end
```

The condition of a loop statement `if` must typecheck as `Bool`. Branch-local
bindings do not leak out of the branch and are cleaned at branch end or before a
branch exit. `break` and `continue` are supported only as direct loop-body
statements or inside loop statement `if` branches. They are not expressions and
are not supported inside local recovery blocks. Bare loop-body expression
statements must typecheck as `Unit` or `Never`; discarding ordinary values such as
`I32` is rejected. Direct `return expr` is also supported inside loop bodies and
exits the enclosing function through the same cleanup-aware explicit-return path
as return expressions. Loop-local owned values are cleaned exactly once on
ordinary iteration end, branch end, `break`, `continue`, conditional loop exits,
`return`, `throw`, and fallible exits through `try` in loop-body expressions.
Moving or consuming pre-branch owned/exact-use state inside a branch that can fall
through remains gated; move such state through an explicit branch exit instead.

Loops are statements by default.

## 18. Lambdas And Callback Blocks

Lambdas use `do ...: ... end`.

Current compiler slice:

- `do: ... end` is an immediate block expression and can read surrounding locals.
- `do param: ... end` can be stored only when the binding has an explicit
  function type, such as `(I32) returns I32`. Without that explicit type, the
  binding is rejected instead of inferred as a hidden closure object.
- Stored lambda values can capture copied locals by value when the binding has an
  explicit function type. The captured value is copied into an owned closure
  environment, so the closure can be returned or passed without peeking the
  original stack frame.
- Stored lambda values can capture owned locals by move when the binding has an
  explicit function type. The source local is moved into the owned closure
  environment and cannot be used afterward. Inside the lambda body, the captured
  owned value is viewed through a hidden read-only peek, so a repeatable
  function value can read copied fields or pass peek arguments without consuming
  its own environment.
- A no-capture `do param: ... end` literal can be passed directly to a named
  function parameter whose type is a matching function type, through positional
  or named arguments. This is the first non-escaping callback form.
- Operation method calls may also pass direct callback literals in positional or
  named arguments when the operation parameter has a matching function type.
- Named function and operation calls may place a final callback parameter after
  the call with trailing `do ... end` syntax instead of naming that callback
  inside the argument list.
- Direct non-escaping callback literals may read copied locals and peek locals
  that are already visible at the call site. The compiler specializes that one
  call and passes the captured locals explicitly; no closure object is created.
- Generic function calls may use captured direct callback literals when the
  callback parameter has a concrete function type, or when the callback type
  becomes concrete after call-site specialization or explicit lambda parameter
  annotations, such as `(T) returns I32` with `T` inferred as `I32`.
- Generic operation calls follow the same rule: captured direct callback
  literals are accepted when the operation's type parameters or explicit lambda
  parameter annotations specialize the callback parameter to a concrete function
  type.
- Generic callback parameter types that cannot be made concrete from the
  receiver, non-callback call arguments, or explicit lambda parameter
  annotations are rejected.
- Direct non-escaping callback literals still reject owned and exact-use captures.
- Direct callback literals cannot be stored as untyped general function values.
  When a function return type is an explicit function type, a tail `do ... end`
  literal, direct `return do ... end`, `if`/`match` branch tail `do ... end`,
  immediate `do:` block tail `do ... end`, `try`/`catch` tail `do ... end`, or
  copied `context` tail `do ... end`, or lexical `region` tail `do ... end`
  lowers to the same owned closure object as an annotated function-value
  binding.
- Throwing function values are supported with the same transfer and cleanup
  rules as non-throwing function values. A throwing function value is called
  with `try` and can flow through matching typed `throws` contracts in `apply`
  and callback positions.
- Named non-generic, safe functions can be passed where a matching function
  value is expected. Throwing functions are supported in the same positions when
  both declaration and use sites use matching `throws` types.
- Named non-generic functions can be returned where a matching function value is
  expected. Throwing function values can also be returned or passed as values.
- Overloaded named functions can be passed, bound with an explicit annotation,
  stored in a record field, or returned as function values only when the expected
  function type selects exactly one safe non-generic overload. Without that
  expected type, a bare overloaded function name is rejected. Mutable reassignment
  of function values remains outside the current mutable-assignment slice because
  function values are owned values.
- Function values lower to explicit closure objects internally. A closure object
  has a call slot, an environment pointer, and an optional drop slot. No-capture
  lambdas and named functions use a null environment and null drop. Capturing
  stored lambdas use a heap-backed environment and a generated drop slot that
  releases owned captures before freeing that environment.
- Function values are owned values for cleanup purposes. Calling a function
  value does not consume it; returning or passing one transfers the closure
  object. Cleanup calls the drop slot when it is present.
- Stored lambda bindings reject peek captures because escaping closures cannot
  carry peek views. They reject exact-use captures in this slice because capture
  must make consumption explicit.
- Trailing callbacks are supported for direct function and operation calls as a
  final `do ... end` argument.
- Exact-use callback capture support is still planned for later work.

Design preference: callbacks are a local function-value mechanism, not the main
structured-flow abstraction. For borrowed traversal, repeated events, parser
views, request/response handoff, or APIs that would otherwise stack callbacks,
prefer a typed `signal` group interpreted by a scoped `enact` handler. This
keeps the callback surface useful without making callback nesting the language's
primary control-flow story.

Recommended ordering:

| Priority | Rule | Short version |
| ---: | --- | --- |
| 1 | Ordinary `return` of `peek` remains rejected. | No escaping borrowed views. |
| 2 | `signal`/`enact` is the preferred handoff model. | Structured channels over callback stacks. |
| 3 | Callback parameters stay as the local escape hatch. | Small customization only. |
| 4 | Signals may return values through handlers. | Request/response without callbacks. |
| 5 | Regions cover temporary allocation-heavy APIs. | Lexical ownership for short-lived outputs. |
| 6 | Escaping views require owned materialization. | Long-lived data must be owned. |
| 7 | Avoid `yield` syntax. | Generator-like flow should prove itself through signaling first. |

Canonical lambda:

```meridian
do param:
  body
end
```

No-argument lambda:

```meridian
do:
  refresh()
end
```

Multiple parameters:

```meridian
do a, b:
  a + b
end
```

Typed parameters:

```meridian
do (user: User):
  user.email
end
```

Multiple typed parameters:

```meridian
do (total: Int, user: User):
  total + user.score
end
```

The final expression is the lambda result.

Typed lambda value:

```meridian
let increment: (I32) returns I32 = do value:
  value + 1
end
```

Pass a named function as a function value:

```meridian
apply(value: I32 handler: (I32) returns I32) returns I32:
  handler(value)
end

increment(value: I32) returns I32:
  value + 1
end

main returns I32:
  apply(41 increment)
end
```

Throwing lambda type:

```meridian
let loadUser: (UserId) returns User throws LoadError = do id:
  try users.load id
end

error Problem:
  TooSmall:
end

let guard: (I32) returns I32 throws Problem = do value:
  if value > 0:
    value
  else:
    throw TooSmall
  end
end

main returns I32:
  try:
    guard(1)
  catch TooSmall:
    0
  end
end
```

Trailing callback:

```meridian
users.map do user:
  user.email
end
```

```meridian
onClick saveButton do event:
  try saveForm event.form
end
```

Trailing callback syntax is accepted as a trailing argument on positional
function and method calls. It is not accepted after named-argument calls such as
`foo(value: x) do ... end`, and it is not accepted for record or constructor
initializers.

Arrow lambdas are not used:

```meridian
user => user.email
```

Use:

```meridian
do user:
  user.email
end
```

## 19. Function Types

Function types use `returns`.

Single parameter:

```meridian
(User) returns String
```

Multiple parameters:

```meridian
(Int, Int) returns Int
```

Throwing function:

```meridian
(UserId) returns User throws LoadError
```

No `->` is used in function types.

## 20. Subject Binding And Projection

Use `with` to create a unary function with an explicit subject name. It is the
named-subject alternative to implicit placeholder forms like `it.email`.

`with` uses `:`. The `with` keyword already marks a subject-binding
form, so `:` separates the subject name from the body.

Subject binding:

```meridian
with user: user.email end
```

In a call that expects a function, `with` names the value passed to that
function:

```meridian
users.map with user: user.email end
```

This is equivalent to:

```meridian
users.map do user: user.email end
```

For predicates:

```meridian
users.filter with user: user.active and not user.deleted end
```

`with` may also use multiline form:

```meridian
users.filter with user:
  user.active and not user.deleted
end
```

Projection shorthand is allowed for trivial field and method selection where a
callback function is expected. It lowers to a one-parameter lambda and uses the
same callback checking as `do`.

Field projection:

```meridian
map(users, .email)
```

Equivalent to:

```meridian
map(users, do user: user.email end)
```

Predicate projection:

```meridian
filter(users, .active)
```

Equivalent to:

```meridian
filter(users, do user: user.active end)
```

Method projection:

```meridian
map(names, .lower())
```

Equivalent to:

```meridian
map(names, do name: name.lower() end)
```

Named method projection is the same form with named arguments:

```meridian
select(score, .boosted(amount: 2))
```

Equivalent to:

```meridian
select(score, do score: score.boosted(amount: 2) end)
```

For complex predicates or transformations, prefer `with` in pipelines or a
named `do` lambda:

```meridian
users
pipe filter with user: user.age >= 18 and user.active end
```

```meridian
users.filter do user: user.age >= 18 and user.active end
```

Projection shorthand should remain simple. It should not become a second
expression language.

## 21. Pipelines

The canonical pipeline spelling is the word `pipe`. It lowers the left value
into the first argument of an ordinary function call:

```meridian
value pipe function
```

The compact `|>` spelling remains an alias for dense chains:

```meridian
value |> function
```

It is equivalent to:

```meridian
function(value)
```

Example:

```meridian
let score = 20 pipe add(1) pipe twice
let same = 20 |> add(1) |> twice
```

Equivalent to:

```meridian
let score = twice(add(20, 1))
```

For longer repetitive chains, `pipe` may take a comma-separated grouped step
list. A final trailing comma is allowed. The comma is only a separator inside
`pipe (...)`; it is not a general sequencing operator.

```meridian
let score = 20 pipe (
  add(1),
  twice
)
```

The word `piping` is the grouped-only spelling for the same form:

```meridian
let score = 20 piping (
  add(1),
  twice
)
```

Each grouped step lowers through the same pipeline rule:

```meridian
function                 // function(previous)
function(args)           // function(previous, args)
it + 1                   // expression over previous
clamp(it, 0, 10)         // expression call over previous
Box(value: it)           // constructor over previous
.field                   // previous.field
.method(args)            // previous.method(args)
.method(name: value)
with name: ... end
do name:
  ...
end
```

Pipeline targets may take callback shorthand:

```meridian
users pipe map .email
users pipe filter with user: user.active end
```

Pipeline targets may also be direct projection targets. These lower to ordinary
field or method access on the piped value:

```meridian
user pipe .email
user pipe .scoreWith(2)
user pipe .scoreWith(amount: 2)
user pipe it.score + 1
user pipe clamp(it, 0, 10)
user |> (it + 1)
```

Inside an `it` expression step, `it` names the previous pipeline value. Nested
lambda, match, constructor-pattern, catch, and enact bindings named `it` do not
count as pipeline-subject use inside that nested scope. If a step already uses
pipeline `it`, normal duplicate-binding rules still reject another `it` binding
in the same generated subject scope.

Pipeline targets may be direct subject bindings. The piped value is evaluated
once, bound to the subject name, and the body runs in that scoped binding:

```meridian
user pipe with subject: subject.score + 1 end
```

Method calls may take the same callback shorthand when the callback is separated
from the method name by whitespace:

```meridian
users.map .email
users.filter with user: user.active end
```

No whitespace keeps ordinary chained field/method access:

```meridian
user.profile.email
```

The callback shorthand still lowers to ordinary function arguments, so normal
function typing, capture checks, ownership checks, and fallible-call checks
apply.
This closes the current v1 pipeline/projection boundary; richer flow syntax is
future work outside this boundary.

## 22. Requires Clauses

Meridian uses `requires` clauses directly at declarations that need
operations. There is no separate generic abstraction layer before this constraint
model is revised.

Inline `requires` clauses attach directly to generic functions:

```meridian
max(a: T, b: T) returns T
requires lessThan(T, T) returns Bool:
  if lessThan(a, b): b else: a end
end
```

Each `requires` entry is satisfied structurally when the compiler can find
exactly one visible function or operation with the named type. No separate
abstraction declaration is required in this phase.

Variant operations may satisfy function-shaped `requires` entries:

```meridian
operation area on Shape returns I32:
  Circle radius:
    radius * radius * 3
  Square size:
    size * size
end

printArea(value: T) returns Unit
requires area(T) returns I32:
  printInt(area(value))
end
```

Named reusable constraint bundles are not allowed in Meridian, and there is no
`requirements` keyword. Repeat the required operation signatures directly in
`requires` clauses.

The current compiler accepts concrete structural `requires` entries, validating
that exactly one visible function or variant operation matches the required
name and signature.

The current compiler also accepts a final Bool precondition contract in a
`requires` clause:

```meridian
divide(a: I32, b: I32) returns I32 requires not b = 0:
  a / b
end
```

This contract form is runtime-checked before the function body and aborts on
failure in this first slice. It is intentionally narrow: contract expressions
must typecheck as `Bool`, may only depend on copied parameters and copied
context values, may call only non-throwing/non-signaling/no-context safe helper
functions, and cannot move owned or consumed values. Structural requirement
entries and precondition contracts share the `requires` keyword, but a contract
must be the final header clause.

## 23. Capabilities And Signaling

Capabilities are explicit authority-bearing values. Signaling are first and
foremost visible operation contracts for authority-bearing work. The primary v1
direction is direct resource signaling: a function calls a typed signal operation,
declares the matching `signaling` row, passes explicit capability values, and
receives ordinary checked Meridian values. This direct form is not a fully
algebraic-control system and does not require continuations.

Peek-view expansion follows the same bias. Meridian should not expose
user-written lifetime parameters for ordinary code. Temporary
parser/string/buffer/resource views should be authorized by scoped signaling when
local checking alone is not expressive enough, while the compiler still rejects
stored or returned peeks, owner moves under live peeks, and suspension across
signaling boundaries that do not explicitly allow peek state.

This also sets the API-design bias: when an API needs to hand out a sequence of
short-lived views, signal them through a scoped `enact` handler before reaching
for callback parameters. Callback parameters remain valid for small local
customization and function-value APIs, but `signal`/`enact` is the preferred
shape for channel-like or event-loop-like flow. Do not add `async`, `await`, or
`yield` to cover this space until the runtime-handle plus typed-signaling model
has failed in concrete examples.

`signal`/`enact` is a separate, narrower control-flow layer for scoped
interpretation of operations. It exists, but it should not be the default model
for IO, handles, FFI, allocators, clocks, randomness, networking, or compile-time
authority. Those systems should become direct signal operations first, with
runtime implementations hidden behind authority and safe wrappers. The current
standard direct signaling surface includes `Memory` over explicit `Allocator`
authority and `Time.nowSeconds(timeSource)` over explicit `TimeSource`
authority. It also includes `Random.nextI32(randomSource)` and
`Random.nextBool(randomSource)` over explicit `RandomSource` authority as
non-cryptographic runtime pseudorandom stubs, plus
`Random.secureI32(randomSource)` returning `I32 throws RandomError` from OS
entropy. The first IO slice is `TerminalIo.writeI32(terminal, value)`,
`TerminalIo.writeString(terminal, text)`, and
`TerminalIo.writeBool(terminal, value)` plus
`TerminalIo.writeLine(terminal, text)`, `TerminalIo.readI32(terminal)`,
`TerminalIo.readBool(terminal)`, `TerminalIo.readLine(terminal, allocator)`
returning `String throws IoError, AllocError`, and
`TerminalIo.flush(terminal)` over explicit `Terminal` authority.
`TerminalIo.readI32(terminal)` returns `I32 throws IoError`, reads one stdin
line through explicit `Terminal` authority, parses decimal `I32` text, and
reports `FileReadFailed` on read or parse failure. `TerminalIo.readBool(terminal)`
returns `Bool throws IoError`, reads one stdin line through explicit `Terminal`
authority, accepts `true` or `false`, and reports `FileReadFailed` on read or
parse failure.
`Environment.variableExists(environmentAccess, name)` returns `Bool` over
explicit `EnvironmentAccess` authority and a peek `String` name.
`Environment.readString(environmentAccess, name, allocator)` returns
`String throws EnvironmentError, AllocError`, copies the host environment value
into an owned Meridian `String`, and reports `VariableMissing` when absent.
Inside a visible allocator context,
`Environment.readString(environmentAccess, name)` is equivalent to the explicit
allocator form and still emits an ordinary direct signaling call with allocator
authority.
`Environment.readI32(environmentAccess, name)` returns `I32 throws
EnvironmentError`, parsing a host environment value as a decimal `I32`,
reporting `VariableMissing` when absent and `InvalidInteger` when present but
not a valid `I32`. `Environment.readBool(environmentAccess, name)` returns
`Bool throws EnvironmentError`, accepts host text `true` or `false`, reports
`VariableMissing` when absent, and reports `InvalidBoolean` for any other value.
`Environment.setString(environmentAccess, name, value)` returns
`Unit throws EnvironmentWriteError`, writes a peek `String` value to a
peek `String` environment name through explicit `EnvironmentAccess`, and
reports `VariableWriteFailed` on runtime failure.
`Environment.setI32(environmentAccess, name, value)` returns
`Unit throws EnvironmentWriteError`, writes a copied `I32` value as decimal
text through explicit `EnvironmentAccess`, and reports `VariableWriteFailed` on
runtime failure. `Environment.setBool(environmentAccess, name, value)` returns
`Unit throws EnvironmentWriteError`, writes copied `Bool` values as `true` /
`false` text through explicit `EnvironmentAccess`, and reports
`VariableWriteFailed` on runtime failure.
`Environment.removeString(environmentAccess, name)` returns
`Unit throws EnvironmentWriteError`, removes a peek `String` environment
name through explicit `EnvironmentAccess`, and reports `VariableWriteFailed` on
runtime failure.
The
first handle slice is `FileIo.openReadId(fileAccess, id)` returning an
owned opaque `File` handle, `FileIo.openReadPath(fileAccess, path)` returning
`File throws IoError`, `FileIo.pathExists(fileAccess, path)` returning `Bool`,
`FileIo.pathIsSymlink(fileAccess, path)` returning `Bool`,
`FileIo.fileExists(fileAccess, path)` returning `Bool`,
`FileIo.canReadPath(fileAccess, path)` returning `Bool`,
`FileIo.canWritePath(fileAccess, path)` returning `Bool`,
`FileIo.canExecutePath(fileAccess, path)` returning `Bool`,
`FileIo.directoryExists(fileAccess, path)` returning `Bool`,
`FileIo.fileSize(fileAccess, path)` returning `I32 throws IoError`,
`FileIo.modifiedSeconds(fileAccess, path)` returning `I32 throws IoError`,
`FileIo.createDirectory(fileAccess, path)` returning `Unit throws IoError`,
`FileIo.createDirectoryIfMissing(fileAccess, path)` returning
`Unit throws IoError` and succeeding when the path is already a directory,
`FileIo.createDirectoryRecursive(fileAccess, path)` returning
`Unit throws IoError` and creating missing parent directories,
`FileIo.removeDirectory(fileAccess, path)` returning `Unit throws IoError`,
`FileIo.removeDirectoryRecursive(fileAccess, path)` returning
`Unit throws IoError` and removing a non-empty directory tree,
`FileIo.openDirectoryPath(fileAccess, path)` returning
`Directory throws IoError`,
`FileIo.directoryEntryCount(directory)` peeking the `Directory` handle and
returning `I32 throws IoError`,
`FileIo.directoryEntryName(directory, index, allocator)` peeking the
`Directory` handle and returning `String throws IoError, AllocError`,
`FileIo.directoryEntryIsDirectory(directory, index)` peeking the `Directory`
handle and returning `Bool throws IoError`,
`FileIo.directoryEntryIsFile(directory, index)` peeking the `Directory`
handle and returning `Bool throws IoError`,
`FileIo.directoryEntryIsSymlink(directory, index)` peeking the `Directory`
handle and returning `Bool throws IoError`,
`FileIo.directoryEntrySize(directory, index)` peeking the `Directory` handle
and returning `I32 throws IoError` for regular-file entries,
`FileIo.directoryEntryModifiedSeconds(directory, index)` peeking the
`Directory` handle and returning `I32 throws IoError` for regular-file entries,
`FileIo.openDirectoryEntryRead(directory, index)` peeking the `Directory`
handle and returning `File throws IoError` for regular-file entries,
`FileIo.openDirectoryEntryDirectory(directory, index)` peeking the
`Directory` handle and returning `Directory throws IoError` for directory
entries,
`FileIo.removePath(fileAccess, path)` returning `Unit throws IoError`,
`FileIo.renamePath(fileAccess, from, to)` returning `Unit throws IoError`,
`FileIo.copyPath(fileAccess, from, to)` returning `Unit throws IoError`,
`FileIo.currentDirectory(fileAccess, allocator)` returning
`String throws IoError, AllocError`,
`FileIo.changeDirectory(fileAccess, path)` returning `Unit throws IoError`,
`FileIo.absolutePath(fileAccess, path, allocator)` returning
`String throws IoError, AllocError`,
`FileIo.readStringPath(fileAccess, path, allocator)` returning
`String throws IoError, AllocError`,
`FileIo.readLinePath(fileAccess, path, allocator)` returning
`String throws IoError, AllocError`,
`FileIo.readI32Path(fileAccess, path)` returning `I32 throws IoError`,
`FileIo.readBytePath(fileAccess, path)` returning `I32 throws IoError`,
`FileIo.readBoolPath(fileAccess, path)` returning `Bool throws IoError`,
`FileIo.writeStringPath(fileAccess, path, text)` returning
`Unit throws IoError`,
`FileIo.writeLinePath(fileAccess, path, text)` returning `Unit throws IoError`,
`FileIo.writeI32Path(fileAccess, path, value)` returning `Unit throws IoError`,
`FileIo.writeBytePath(fileAccess, path, value)` returning
`Unit throws IoError`,
`FileIo.writeBoolPath(fileAccess, path, value)` returning
`Unit throws IoError`,
`FileIo.appendStringPath(fileAccess, path, text)` returning
`Unit throws IoError`,
`FileIo.appendLinePath(fileAccess, path, text)` returning `Unit throws IoError`,
`FileIo.appendI32Path(fileAccess, path, value)` returning `Unit throws IoError`,
`FileIo.appendBytePath(fileAccess, path, value)` returning
`Unit throws IoError`,
`FileIo.appendBoolPath(fileAccess, path, value)` returning
`Unit throws IoError`,
`FileIo.readI32(file)` over a peek handle, and `FileIo.readI32Checked(file)`
returning `I32 throws IoError`.
`FileIo.readStringChecked(file, allocator)` returns `String throws IoError,
AllocError`. `FileIo.readLineChecked(file, allocator)` returns
`String throws IoError, AllocError`, reads up to but not including the next
newline, reports `FileReadFailed` on EOF before any input, and returns an owned
`String` with allocator cleanup. `FileIo.openWritePath(fileAccess, path)` returns
`File throws IoError`, `FileIo.openAppendPath(fileAccess, path)` returns
`File throws IoError`, `FileIo.openReadWritePath(fileAccess, path)` returns
`File throws IoError` for an existing host file opened for update, and
`FileIo.openCreateReadWritePath(fileAccess, path)` returns
`File throws IoError` for a host file created or truncated for update.
`FileIo.truncatePath(fileAccess, path)` returns `Unit throws IoError` for a
host path created if needed and truncated to zero bytes without exposing a raw
file identity.
`FileIo.writeStringChecked(file, text)` returns
`Unit throws IoError` with typed `FileWriteFailed` recovery.
`FileIo.writeLineChecked(file, text)` returns `Unit throws IoError`, writes
peek string data followed by a newline, and reports `FileWriteFailed`.
`FileIo.writeI32Checked(file, value)` returns `Unit throws IoError` through the
same opaque handle. `FileIo.readByteChecked(file)` returns
`I32 throws IoError` and `FileIo.writeByteChecked(file, value)` returns
`Unit throws IoError`, both through a peek `File` handle; byte writes reject
values outside `0..255`. `FileIo.readBoolChecked(file)` returns
`Bool throws IoError` and accepts host text `true` or `false`;
`FileIo.writeBoolChecked(file, value)` returns `Unit throws IoError` and writes
the same text shape through the peek handle. `FileIo.position(file)` peeks the `File` handle and
returns `I32 throws IoError`, reporting the current stream offset as a checked
copied value. `FileIo.fileLength(file)` peeks the `File` handle and returns
`I32 throws IoError`, reporting the current host file length through runtime
`fstat` while permitting later handle use. `FileIo.seekTo(file, position)` peeks the `File` handle and
returns `Unit throws IoError`, rejects negative offsets, and positions the
stream at an absolute byte offset. `FileIo.truncateTo(file, size)` peeks the
`File` handle and returns `Unit throws IoError`, rejects negative sizes,
truncates the host file through runtime `ftruncate`, and permits later length
checks, writes, or close. `FileIo.seekStart(file)` peeks the `File`
handle and returns `Unit throws IoError`, positioning the stream at the start
and permitting later handle use. `FileIo.seekEnd(file)` peeks the `File`
handle and returns `Unit throws IoError`, positioning the stream at the end and
permitting later handle use. `FileIo.flush(file)` peeks the `File` handle and
returns
`Unit throws IoError`, permitting later handle use. `FileIo.close(file)`
consumes the owned `File` handle and returns `Unit throws IoError`, rejecting
reuse of the moved handle. `FileIo.closeDirectory(directory)` consumes the
owned `Directory` handle and returns `Unit throws IoError`, rejecting reuse of
the moved handle. Directory entry counting peeks the `Directory` handle and
permits later close. This proves the
handle shape, cleanup rule, peek path passing, typed open failure, typed
checked-read/write failure, linked host-file integer/string/byte/bool reads, linked
host-file append/write paths, linked host-file path integer/byte/bool read/write
and integer/byte append, linked
host-file string/integer/byte writes, linked
host-file path string/line append, linked host-file path
size/directory-exists/directory/copy/removal/rename, checked file
position, checked absolute seek, checked seek-to-start, checked seek-to-end,
checked explicit flush, checked explicit close, and owned `String` cleanup after
file reads.
Broader file operations beyond this first path-management slice remain future
work.

The useful job for `signal`/`enact` is local policy and interpretation. Good
first domains are logging, tracing, diagnostics, parser recovery, test doubles,
interactive prompts, transactions, scoped instrumentation, and compiler/build
phase events. In those cases the caller emits a typed operation, and the nearest
`enact` boundary decides whether to resume with a value, abandon with a result,
buffer the event, turn a warning into an error, simulate an environment, or
collect operations for later commit. This keeps `signal`/`enact` valuable without
making it the default resource/FFI/IO mechanism.
The current compiler suite includes runnable direct-tail examples for logging
capture, diagnostics collection, test environment substitution, parser recovery,
transaction-style collection, and scoped instrumentation, plus negative coverage
that those examples cannot store, return, copy, capture, branch over, or nest
continuation use.
The current re-evaluation found no production example in that suite that needs
escaping/general continuation values. Direct-tail `resume`, direct-tail
`abandon`, and one direct call to a named continuation binding are the supported
useful surface; source-level general continuation values remain gated behind the
saved-local frame-lifetime ownership rule.

Vocabulary:

```text
requires    structural generic constraint
capability  explicit authority value, passed as a parameter
signaling   named group of typed operations and authority/resource contracts
direct      ordinary checked operation call declared in the caller's signaling row
signal      scoped operation signal to an enact boundary
enact       scoped interpreter for signaled operations
one-shot    continuation can be resumed at most once
throws      built-in abortive error flow
```

Capability declaration:

```meridian
capability type FileSystem:
end
```

Empty capability types can be minted as ordinary copied authority tokens:

```meridian
let fs = capability FileSystem
```

`capability Name` requires a matching empty `capability type Name: ... end`
declaration. It does not create runtime resources or handles; those still come
from checked signal operations that return handle values under current
consume/move/return rules. Parameter-local `consume T` is the canonical transfer
spelling; consumed call-site diagnostics name the call and parameter, and
ambiguous non-copied by-value parameters are rejected unless they are `peek T` or
`consume T`.
Capability tokens are copied authority values: they can be passed by value or
peek by an operation, require no cleanup, and do not hide allocation, IO, or
runtime resource ownership. A public callable that mentions a custom capability
type must make that capability type visible through the same export rules as
other named public API types.

Direct resource signal group declaration:

```meridian
signaling FileIo:
  read(fs: peek FileSystem, path: Path) returns Bytes throws IoError
end
```

Function and operation headers may declare signaling rows with `signaling`:

```meridian
loadConfig(fs: peek FileSystem, path: Path) returns Config signaling FileIo throws IoError, ParseError:
  bytes = try FileIo.read(fs, path)
  try parseConfig(bytes)
end
```

Direct resource operation calls may use positional or named arguments. Named
arguments are checked against the signal operation parameters and emitted in
declaration order, so `FileIo.read(path: path, fs: fs)` lowers like
`FileIo.read(fs, path)`. Move and peek analysis use that same declaration order:
a named `peek` parameter does not move its argument, and a later consumed
parameter cannot move a value while that earlier peek is live. Named direct
signal calls also use the same fallible-call cleanup rule as positional calls:
a throwing signal operation may consume an owned argument as the direct `try`
target without leaving a skipped cleanup obligation.

Calling a function that declares signaling requires the caller to declare those
same signaling. Direct `signal`/`enact` is the scoped exception: the handled
signal group is interpreted by the matching `enact`, while any other callee signaling
still must appear in the enclosing function's `signaling` row.

Direct resource signaling are the preferred path for runtime/FFI replacement. They
lower as ordinary checked calls to generated runtime stub symbols, without
capturing a continuation. Their operation signatures must state the memory and
authority contract through existing Meridian types:

- capability parameters authorize the operation
- `peek` parameters do not transfer ownership
- `consume` parameters transfer owned or exact-use values into the signal
  operation call and cannot be reused
- `owned` results are compiler-cleaned or have safe `drop` hooks
- exact-use results must satisfy checked usage obligations on every path through
  current consume/move/return rules; consumed call-site diagnostics name the call
  and parameter.
- non-copied by-value parameters are rejected unless they are `peek T` or
  `consume T`.
- raw pointers do not cross the safe boundary
- runtime identities are returned as handles from direct signaling; source
  accepts plain `handle` for exact-use identities and `owned handle` for
  automatic cleanup

The current syntax preference in docs is now plain `handle` plus checked usage
obligations as the user-facing model.

- [x] Parse, store, and validate parameter-local `consume T` access on
  functions, operations, and signal operations.
- [x] Treat call sites for `consume T` parameters as explicit argument moves.
- [x] Reject non-copied by-value parameters unless they are `peek` or
  `consume`.
- [x] Accept plain `handle Name` source declarations.
- [x] Migrate user-facing examples to `handle` with explicit checked usage
  obligations (`consumes`, moves, returns).

`handle` is a declaration kind for opaque runtime-resource types; it is not a
generic wrapper type.

Handled `signal`/`enact` signaling remain available for scoped operation control
flow:

```meridian
signaling Log:
  info(message: String) returns Unit
end

runBuild(log: peek Logger) returns Unit signaling Log:
  signal Log.info("compiling")
end

testBuild(log: peek Logger) returns Unit:
  enact Log:
    runBuild(log)
  handle Log.info(message):
    // The handler may buffer, assert, print, ignore, or enrich this event.
    resume unit
  end
end
```

`signal` is the branded operation form for this feature. It does not mean a
network request, process signal, event broadcast, event-loop notification, or
multi-listener callback. It means: ask the nearest matching `enact` boundary to
interpret one typed operation.

Peek views may use this scoped boundary as the language's lifetime-light
handoff form. In the current direct lowering, the enacted body may signal a
peek view directly to the handler, or call a signal-only function that does
the same:

```meridian
signaling Lines:
  line(value: peek String) returns I32
end

sumFirstLine(text: peek String) returns I32:
  enact Lines:
    signal Lines.line(lineView(text, 0))
  handle Lines.line(line):
    resume line.len
  end
end
```

A single-hop callee form is also active when the callee declares the handled
signal group, has only peek, slice, or copied-scalar parameters, and tail-calls
the signal after setup. Setup may use pure `let`, `var`, and assignment expressions
built from parameters, locals, literals, field reads, constructors, record
construction, copied-slice literals, operators, non-throwing copied-scalar helper
calls, signaling helper calls whose extra signaling are declared by the enclosing
function, Unit expression statements, expression-only `if`/constructor-pattern `if`/`match`
bindings,
fallible `try` expressions, and direct resource-signal operations checked
against the caller's enclosing signaling row. Discarded setup expressions must
have type `Unit` or `Never`. It may also use setup `while` loops whose
conditions and assignment expressions are checked against the enclosing
signaling row and may be signaling or fallible; their bodies contain copied or
owned loop-local bindings, nested setup loops under the same gate, assignments
to mutable copied setup or loop locals, plus `break`/`continue`. Extra callee
signaling not declared by the enclosing function and nested
`signal`/`enact` remain gated. Signal payloads may also use expression-only
`if`, constructor-pattern `if`, and `match` payloads. Payload bindings remain local to their
branch or arm.

The current setup-loop condition rule is explicit:

- Setup `while` conditions before a direct `signal`, before a direct
  `resume`/`abandon`, or inside a single-hop signal-only callee must have type
  `Bool`.
- A setup-loop condition may read copied setup locals and parameters, call
  signaling helpers whose signaling are declared by the enclosing function,
  perform direct resource signaling, and use `try` for fallible boolean work.
- A setup-loop condition may not use `throw`, `signal`, `enact`, `resume`, or
  `abandon` directly.
- The loop body may declare copied or owned loop-local `let`/`var` bindings,
  assign mutable copied setup or loop locals, nest setup loops under the same
  gate, and use signaling/fallible binding or assignment expressions checked
  against the enclosing function. It may also use `break`/`continue`. Owned
  loop locals are cleaned exactly once on normal iteration end, `break`,
  `continue`, and fallible exits. The loop body may not consume exact-use values
  or assign through owned setup locals.
- If a fallible condition or assignment fails, failure leaves before handler entry, runs
  cleanup for all live owned setup locals exactly once, runs any outer cleanup
  scope, and preserves the same no-escaping-peek rule as direct straight-line
  setup.

```meridian
firstLine(line: peek String) returns I32 signaling Lines:
  var selected = normalizeLine(line)
  selected = selected
  signal Lines.line(if selected.len = 0:
    line
  else:
    selected
  end)
end

sumFirstLine(text: peek String) returns I32:
  enact Lines:
    firstLine(text)
  handle Lines.line(line):
    resume line.len
  end
end
```

The `line` binding is valid only inside the handler arm. It cannot be returned,
stored in a record/enum/error, captured by an escaping closure, or moved across
another suspension boundary. This is intentionally less general than Rust-style
lifetime polymorphism, but it covers efficient parser, substring, lookup, and
iterator-like APIs without making lifetime names part of Meridian source.
Ordinary returns of peek views remain rejected.

`enact` blocks interpret signaled signal operations. A resumable enact arm
receives a one-shot continuation. The continuation may be resumed at most once,
cannot be copied, and cannot escape the enact arm. In the first direct lowering,
operation payloads may be copied, owned, or peek view values. Owned payloads
transfer into the handler binding and are cleaned after the direct `resume` or
`abandon` result is materialized. Peek payloads are handler-local views and
cannot escape the handler arm. Enacted-body and handler setup locals may also be
copied or owned; owned setup locals are cleaned after the direct result is
materialized. Direct enacted bodies may use setup `while` loops before the
direct `signal`, and handler arms may use the same shape before direct
`resume`/`abandon` tails; loop bodies are limited to copied or owned loop-local
bindings, nested setup loops under the same gate, assignments to mutable copied
setup or loop locals, plus `break`/`continue`. Owned loop locals are cleaned
exactly once on every loop exit path. Direct enacted bodies and handler arms may
also use Unit expression statements before the direct tail for local
instrumentation or preparation; discarded non-Unit setup expressions are
rejected. Their setup bindings may use expression-only constructor-pattern `if` in the same
restricted shape as expression-only `if` and `match`: branch bodies must be
empty except for the tail expression, and payload bindings stay branch-local.
Handler arms may either use the keyword form `resume expr` or bind the direct
continuation as one extra handle parameter after the operation payloads and call
that binding exactly once as the direct tail, for example
`handle Clock.now(cont): cont(42)`. A zero-resume handler uses `abandon expr`.
The named direct continuation binding is not a general first-class continuation:
it cannot be stored, returned, thrown, consumed, copied, captured, used in setup
statements, shadowed by handler setup locals, redeclared inside handler setup
expressions, or shadowed by nested tail-value bindings, branched over, used
inside the value passed to its own direct tail call, or resumed from nested
control flow. Those broader continuation forms are rejected until explicit
continuation-frame lowering exists. The direct lowering represents the optional
named direct continuation as a source-level continuation binding descriptor
carrying the source binding name and the operation return type it resumes with,
rather than as an ordinary function-local name. It already emits a
frame-shaped scaffold in generated C: a state id, body/handler live flags,
continuation available/resumed/abandoned flags, and binding-level
address/live/moved slots bracket the direct signal and handler path. The
generated frame also includes an explicit one-shot continuation descriptor
pointing at the frame's available/resumed/abandoned/state fields, cleanup
started/completed fields, abandoned-cleanup started/completed fields, and naming
the abandoned-cleanup executed count as well as the handled signal operation and
result type. In generated C, the descriptor uses the reusable
`MeridianContinuationFrameDescriptor` shape and the cleanup table uses
`MeridianContinuationCleanupSlot`, so later general continuation lowering can
share the same saved-local metadata contract instead of duplicating a direct-only
anonymous struct. The backend builds those cleanup slots from reusable
saved-local slot metadata: address field, live flag, moved flag, ownership bit,
phase, source type label, and cleanup target. Cleanup table construction also
uses a reusable grouped saved-local builder and reusable cleanup summary, with
the direct lowering as one caller and future escaped continuation frames using
the same shape. Continuation frame descriptor initialization is also reusable:
direct frames and inactive general continuation scaffolding use the same backend
path to link one-shot state pointers, signal-group/operation/result identity, cleanup
table/count metadata, owned cleanup totals, abandoned-cleanup metadata, lifecycle
pointers, and resume/abandon descriptor transitions. The compiler also has an
inactive general-continuation capture table emitter that uses this same grouped
builder. When source continuation values are explicitly enabled in tests, the
handoff path can feed source activation into that reusable capture-table plan;
production source still keeps escaping continuation values gated behind the
frame-lifetime ownership switch. That continuation descriptor also points at the
generated cleanup table and count when saved-local cleanup entries exist, plus
owned cleanup totals split by enacted-body and handler phase, the number of
captured/body owned cleanups that an abandoned continuation must run, the
cleanup-table phase that contains those captured values, and a flag that marks
direct abandon tails whose descriptor cleanup path must run exactly once before
general handler cleanup. A cleanup table descriptor over saved-local slots gives
the direct lowering an explicit enumerable cleanup shape before general
continuation-frame lowering exists. Each table entry
records the saved address, live flag, moved flag, whether the slot requires
owned cleanup, whether the slot belongs to enacted-body or handler state, the
saved value type, and the cleanup target the backend will use for that value.
Those slots drive owned cleanup for direct body and handler bindings through
saved-local addresses when the binding is still live, has not been moved, and
still has an address. Direct `resume` and zero-resume `abandon` completion now
uses the same explicit descriptor transition shape planned for general
continuations: handler tail classification produces a reusable resume-or-abandon
transition, then backend completion guards through the reusable continuation
descriptor's state pointers that the continuation is still available and has not
already resumed or been abandoned, then marks either the resumed or abandoned
state explicitly through the same descriptor path. The direct lowering uses one
backend completion hook for this transition and the saved-local abandoned
cleanup table path, so abandoned descriptor state is recorded before the
abandoned cleanup preflight and captured/body owned cleanup execution. The
descriptor transition portion is a reusable completion plan separate from the
direct-frame abandoned cleanup path, so later general continuation lowering can
reuse the same one-shot state transition without inheriting direct-frame cleanup
assumptions. The backend-facing general continuation resume/abandon entry point
already builds that same completion plan, though source-level escaping
continuation values remain gated off until their frame lifetime and cleanup
semantics are fully closed. Abandoned continuation cleanup validation is also
descriptor-level: the shared validator checks signal-group/operation/result identity,
one-shot state, cleanup table and count metadata, lifecycle pointers, fresh
started/completed/executed counters, selected owned cleanup entry integrity,
selected-entry count, and finish-time executed count before marking abandoned
cleanup completed. Direct lowering runs that validator after direct
frame-specific descriptor identity checks, and future general continuation
frames can use it without depending on direct-frame field names. The inactive
general continuation frame plan now assembles that shared capture table,
descriptor initialization, resume/abandon transition, descriptor validation, and
compiler-owned saved-local abandoned cleanup execution path as a single backend
entry point. Moved owned captures are marked before abandoned-cleanup validation
and are not counted as live cleanup obligations, so the executed cleanup count
matches only owned values still held by the continuation frame. Active direct
abandoned-body cleanup now also routes through that
same phase-filtered saved-local cleanup executor after its direct descriptor
identity checks. The general frame plan remains source-gated until escaping
continuation values are enabled as a future extension. Non-direct source-level
continuation use now reports that gate explicitly: general continuation frame
lowering is source-gated until escaping continuation values can own saved-local
frame lifetimes. This fail-closed source gate is part of the closed production
memory contract: the direct-tail `signal`/`enact` slice is accepted, while
copied, stored, returned, thrown, captured, branched, nested, or value-resumed
continuations do not enter active production lowering. The reusable
source-activation path is already shaped around the source continuation binding,
transition hint,
capture-table metadata, and backend general frame plan for enabled handoff tests.
That enabled handoff exists only in test builds and is deliberately narrow: it
accepts only a non-escaping source resume/abandon activation shape and rejects
branch-shaped activation before lowering, so test-only enablement cannot
accidentally become broad continuation capture. Production builds compile only
the disabled source-continuation policy and activation switch; there is no
dormant production boolean that can flip the enabled handoff into safe source.
The enabled handoff also stores the already-validated source resume/abandon
value and transition metadata; active lowering consumes that stored handoff
instead of re-deriving the source value from the AST tail. That handoff is not
itself production enablement: direct-tail checking still rejects the nested or
escaping continuation shape until the active source lowering path is explicitly
wired into production. The production diagnostic says this directly: enabled
handoff proofs do not bypass direct-tail lowering.
This closes the current continuation boundary: production code uses direct-tail
`signal`/`enact`; source-level general continuation values are a future
extension, not part of the current safe surface.
The handoff includes opaque continuation binding, binding result-type, stored
source-value, active-transition selection, selected source-transition, stored
source-expression, source-value identity, direct resume/abandon source-shape,
source-transition, gate-requirement, and compiler-owned non-escaping
frame-lifetime proofs.
Enabled active source lowering rejects emission if any proof is absent. Stored
payload helper access is also proof-gated: a handoff cannot return its
resume/abandon payload unless both the stored source-expression proof and the
source-value identity proof are present. The source-expression proof is opaque
and non-`Copy`: it is produced by source-transition validation and inspected
through a predicate instead of being recreated from a public enum variant. The
source-value identity proof is also opaque and non-`Copy`: it is produced by the
enabled handoff and inspected through a predicate before payload access or active
lowering. The stored source-value proof is opaque to production code too: it is
produced by source shape/transition validation and checked through a predicate
before active lowering trusts it. The active-transition proof is opaque too: it
is produced by source-transition validation and checked through a predicate
before active lowering trusts it. The selected source-transition proof is also
opaque: it is produced by source-transition validation and checked through an
exact transition predicate before active lowering trusts it. The handoff stores its request, source
expression, and proofs behind private fields; compiler callers use proof-gated
helpers instead of reading or mutating handoff internals directly.
Enabled active-source emission then runs one named preflight validator over the
active activation input before constructing the backend plan. Direct-frame
cleanup coverage, saved-local uniqueness, saved-local metadata, cleanup-order,
moved saved-local, abandoned-cleanup phase, and active-frame proofs are opaque
too: active lowering only accepts the tokens produced by the bridge validators
and checks them through predicates before trusting saved-local cleanup or frame
metadata. That preflight is
the boundary that checks continuation, transition, frame-lifetime, saved-local,
cleanup-order, moved-local, abandoned-phase, and active-frame proofs together.
The validator returns an opaque, non-`Copy` preflight proof token, and the active
backend-plan construction path consumes that token after checking it matches the
activation mode before it can route to the reusable general capture-table
emitter: enabled activation accepts only enabled preflight proof, while gated
activation accepts only gated fail-closed proof. This follows the same
interaction-net intuition used elsewhere in the continuation design: evidence
moves through the handoff instead of being freely recreated.
The active bridge also
derives direct-frame saved-local cleanup coverage from body and handler capture
slots plus cleanup order, and enabled active source lowering rejects emission if
that coverage proof is absent. It proves saved-local slot name uniqueness and
rejects duplicate body or handler saved-local slot names before emission. It
also proves saved-local slot type metadata for captured body and handler slots,
and rejects active bridge construction if any captured slot lacks local type
metadata. It proves cleanup-order integrity and rejects duplicate body or
handler cleanup-order locals before emission. It also proves moved saved-local
integrity and rejects moved locals that are not captured saved-local slots
before cleanup can skip them. It also proves the selected abandoned-cleanup
phase is the direct-frame body phase and rejects enabled active source lowering
if that proof is absent or the phase drifts. Enabled active source lowering also
requires a typed active-frame proof and rejects empty frame names before
emission.
Before producing that backend plan, it validates that the source binding, result
type label, saved-local slot metadata, and cleanup order agree. The corresponding
source activation emitter fails closed without partial output while gated, and
emits through the reusable general continuation frame plan once enabled.
On direct `abandon`, captured enacted-body owned slots run in the abandoned
cleanup phase first, then their live/address state is cleared so the later
general cleanup pass cannot drop them again. The abandoned cleanup phase resets
an executed-count field only after validating that the continuation descriptor
still names the handled signal group, operation, and result type and still points at
the frame one-shot state, cleanup table, cleanup count, owned-count split,
abandoned cleanup count/phase, and cleanup lifecycle fields. It also validates
that the pointed-at one-shot state records a completed zero-resume abandon in
the handler state, that abandoned cleanup has not started or completed, that its
executed count is still zero, and that later handler/general cleanup has not
started or completed before any abandoned cleanup action runs. It then
scans the cleanup table for owned entries in the abandoned captured-body phase,
aborts if that table-selected count differs from the descriptor's captured-owned
cleanup count, aborts if any selected entry is missing its saved address, live
flag, moved flag, or cleanup target, increments the executed count only after an
actual owned cleanup call, and aborts if the executed count differs from the same
descriptor count. Cleanup
table execution is guarded by cleanup started/completed state, and abandoned
cleanup has its own started/completed guard, so the direct frame records
exact-once cleanup for both the abandoned captured-body phase and the later
handler/general phase. Outer cleanup still falls back to the direct cleanup
scopes proven by this slice.

One-shot continuation rules:

- a resumable continuation is affine
- it may be resumed zero or one time
- it cannot be stored in records, returned, spawned, or captured outside the
  enact arm
- the value passed to `resume` must match the signal operation return type
- a named direct continuation call must be the handler tail and must receive
  exactly one value matching the signal operation return type
- that direct continuation call's argument cannot mention or redeclare the same
  continuation binding
- a named direct continuation binding cannot be shadowed by handler setup
  locals, nested handler setup expressions, or nested tail-value bindings
- the value passed to direct-tail `abandon` must match the surrounding `enact`
  result type
- signaling signaled by enact arms are tracked in the surrounding signaling row

Signal/enact memory contract:

- `signal` is not networking, broadcast, deferred event delivery, or a
  multi-listener event bus. It transfers control to the nearest matching
  `enact` boundary or escapes through the function's checked `signaling` row.
- `enact` is a scoped interpreter for signaled signal operations. It does not
  grant authority; operations that touch runtime resources still require
  explicit capability values.
- A suspended continuation owns an explicit cleanup path for every live owned
  value captured at the `signal` point. If an enact arm does not resume the
  continuation, compiler cleanup runs for those owned values exactly once.
- In the first direct lowering, operation payloads may be copied or owned; owned
  payloads transfer into the handler binding and are cleaned after a direct
  `resume` or `abandon` result is materialized. Enacted-body and handler setup
  locals may also be copied or owned. Owned setup locals are cleaned after the
  direct result is materialized, so suspended body and handler state are not
  leaked. Owned values created inside nested `resume` or `abandon` tail
  expressions are cleaned before the resumed or abandoned result is assigned.
- Live exact-use values may not cross a `signal` unless they are inside an
  explicit finalizer scope that the abandoned-continuation cleanup path can run.
  The first lowering should reject unfinalized exact-use values live across
  `signal`.
- Live peek values may not cross `signal` in the first lowering. Later
  revisions may relax this only when the compiler can prove the enact boundary
  and continuation cannot outlive the peek.
- Region-qualified values may not cross `signal` in the first lowering. Later
  revisions may relax this only when the continuation is proven not to outlive
  the matching region.
- A continuation cannot be copied, stored, returned, thrown, consumed, passed
  as an ordinary function value, captured by an escaping closure, sent to
  another thread, or resumed more than once.
- `signal` lowering is stackless. The active direct slice emits a local frame
  scaffold with state, body/handler liveness, and binding-level
  address/live/moved slots, plus a cleanup table descriptor over those slots
  that marks which entries require owned cleanup and which entries belong to
  enacted-body or handler state. Those direct-frame slots drive owned cleanup for
  direct body and handler bindings through saved-local addresses when the
  binding is still live, has not been moved, and still has an address.
  General functions that can suspend must be lowered to explicit continuation
  frames with saved locals, drop/move flags, and cleanup tables. The C backend
  must not rely on hidden stack copying,
  garbage collection, or unchecked longjmp-style unwinding for memory safety.

```meridian
enact loadConfig(fs, path) with:
  FileIo.read(fs, path, resume):
    let bytes = try hostRead(fs, path)
    resume(bytes)
end
```

`throws` is built-in abortive error flow: `throw` raises it, `try` propagates
it, and `catch` recovers from it. The current compiler slice
implements `signaling Name:` declarations, checked `signaling` rows, generated operation
signatures, direct `SignalGroup.operation(...)` calls with row and argument checks,
`try` enforcement for throwing operations, generated C prototypes/calls for the
runtime stub symbols, linked standard `Memory.allocBuffer`, `Memory.liveBytes`,
`Memory.allocString`, `Memory.concat`, `Memory.fromI32`, and
`Memory.fromI64` direct signaling stubs over explicit `Allocator` authority, linked
`Time.nowSeconds(timeSource)` over explicit `TimeSource` authority, linked
non-cryptographic `Random.nextI32(randomSource)` and
`Random.nextBool(randomSource)`, plus secure `Random.secureI32(randomSource)`,
over explicit `RandomSource` authority, linked
`TerminalIo.writeI32(terminal, value)`,
`TerminalIo.writeString(terminal, text)`, and
`TerminalIo.writeBool(terminal, value)` plus
`TerminalIo.writeLine(terminal, text)`, `TerminalIo.readI32(terminal)`,
`TerminalIo.readBool(terminal)`, `TerminalIo.readLine(terminal, allocator)`,
and `TerminalIo.flush(terminal)` over explicit `Terminal`
authority, linked
`Environment.variableExists(environmentAccess, name)` over explicit
`EnvironmentAccess` authority,
`Environment.readString(environmentAccess, name, allocator)` over explicit
`EnvironmentAccess` and `Allocator` authority,
`Environment.readI32(environmentAccess, name)` over explicit
`EnvironmentAccess` authority,
`Environment.readBool(environmentAccess, name)` over explicit
`EnvironmentAccess` authority,
`Environment.setString(environmentAccess, name, value)` over explicit
`EnvironmentAccess` authority,
`Environment.setI32(environmentAccess, name, value)` over explicit
`EnvironmentAccess` authority,
`Environment.setBool(environmentAccess, name, value)` over explicit
`EnvironmentAccess` authority,
`Environment.removeString(environmentAccess, name)` over explicit
`EnvironmentAccess` authority, linked `FileIo.openReadId(fileAccess, id)` /
`FileIo.openReadPath(fileAccess, path)` / `FileIo.readI32(file)` /
`FileIo.openWritePath(fileAccess, path)` /
`FileIo.openAppendPath(fileAccess, path)` /
`FileIo.openReadWritePath(fileAccess, path)` /
`FileIo.openCreateReadWritePath(fileAccess, path)` /
`FileIo.openDirectoryPath(fileAccess, path)` /
`FileIo.directoryEntryCount(directory)` /
`FileIo.directoryEntryName(directory, index, allocator)` /
`FileIo.directoryEntryIsDirectory(directory, index)` /
`FileIo.directoryEntryIsFile(directory, index)` /
`FileIo.directoryEntryIsSymlink(directory, index)` /
`FileIo.directoryEntrySize(directory, index)` /
`FileIo.directoryEntryModifiedSeconds(directory, index)` /
`FileIo.openDirectoryEntryRead(directory, index)` /
`FileIo.openDirectoryEntryDirectory(directory, index)` /
`FileIo.truncatePath(fileAccess, path)` /
`FileIo.pathExists(fileAccess, path)` /
`FileIo.pathIsSymlink(fileAccess, path)` /
`FileIo.fileExists(fileAccess, path)` /
`FileIo.canReadPath(fileAccess, path)` /
`FileIo.canWritePath(fileAccess, path)` /
`FileIo.canExecutePath(fileAccess, path)` /
`FileIo.directoryExists(fileAccess, path)` /
`FileIo.fileSize(fileAccess, path)` /
`FileIo.modifiedSeconds(fileAccess, path)` /
`FileIo.createDirectory(fileAccess, path)` /
`FileIo.createDirectoryIfMissing(fileAccess, path)` /
`FileIo.createDirectoryRecursive(fileAccess, path)` /
`FileIo.removeDirectory(fileAccess, path)` /
`FileIo.removeDirectoryRecursive(fileAccess, path)` /
`FileIo.removePath(fileAccess, path)` /
`FileIo.renamePath(fileAccess, from, to)` /
`FileIo.copyPath(fileAccess, from, to)` /
`FileIo.currentDirectory(fileAccess, allocator)` /
`FileIo.changeDirectory(fileAccess, path)` /
`FileIo.absolutePath(fileAccess, path, allocator)` /
`FileIo.readStringPath(fileAccess, path, allocator)` /
`FileIo.readLinePath(fileAccess, path, allocator)` /
`FileIo.readI32Path(fileAccess, path)` /
`FileIo.readBytePath(fileAccess, path)` /
`FileIo.readBoolPath(fileAccess, path)` /
`FileIo.writeStringPath(fileAccess, path, text)` /
`FileIo.writeLinePath(fileAccess, path, text)` /
`FileIo.writeI32Path(fileAccess, path, value)` /
`FileIo.writeBytePath(fileAccess, path, value)` /
`FileIo.writeBoolPath(fileAccess, path, value)` /
`FileIo.appendStringPath(fileAccess, path, text)` /
`FileIo.appendLinePath(fileAccess, path, text)` /
`FileIo.appendI32Path(fileAccess, path, value)` /
`FileIo.appendBytePath(fileAccess, path, value)` /
`FileIo.appendBoolPath(fileAccess, path, value)` /
`FileIo.readI32Checked(file)` /
`FileIo.readByteChecked(file)` / `FileIo.readBoolChecked(file)` /
`FileIo.readStringChecked(file, allocator)` /
`FileIo.readLineChecked(file, allocator)` /
`FileIo.writeStringChecked(file, text)` /
`FileIo.writeLineChecked(file, text)` /
`FileIo.writeI32Checked(file, value)` /
`FileIo.writeByteChecked(file, value)` /
`FileIo.writeBoolChecked(file, value)` /
`FileIo.position(file)` /
`FileIo.fileLength(file)` /
`FileIo.seekTo(file, position)` /
`FileIo.truncateTo(file, size)` /
`FileIo.seekStart(file)` /
`FileIo.seekEnd(file)` /
`FileIo.flush(file)` /
`FileIo.close(file)` /
`FileIo.closeDirectory(directory)` over explicit `FileAccess` and
`Allocator` authority, typed `IoError` / `AllocError`, and an owned opaque
`File` or `Directory` handle, and the first `signal`/`enact` lowering. The
next useful signaling milestone is narrowing the remaining runtime resource gaps,
especially later FFI/layout binding mechanics, not deeper general continuation
semantics.
The existing handled lowering accepts a direct `signal
SignalGroup.operation(...)` tail inside an `enact SignalGroup:` body, plus copied or owned
setup statements and Unit expression statements before the signal, and a matching
`handle SignalGroup.operation(...):` arm with copied or owned operation payloads plus
copied or owned setup statements and Unit expression statements before a
direct-tail `resume expr`, `abandon expr`, or named direct continuation call.
Owned operation payloads and owned setup locals in the enacted body or handler
are cleaned after the direct handler result is materialized.
This is not general continuation capture or escape: handlers cannot store,
return, duplicate, or otherwise expose the suspended computation in this slice.
Broader cross-function suspension and full continuation-frame lowering remain
future signaling milestones, behind direct resource signaling and explicit handle
wrappers in priority.

This section describes the surface model for capabilities and one-shot signaling.
The current compiler slice also implements `error`, typed `throws`, `throw`,
prefix `try` propagation for fallible expressions including throwing calls and
direct `throw`, and local `try` / `catch` recovery for fallible expressions including
throwing calls, nested call arguments, binary expressions, and direct local
`throw`.

## 25. Generics

Parametric type application uses `of`.

```meridian
List of User
Map of String User
Option of String
```

Multi-argument `of` type constructors are word-separated. Commas are accepted
for compatibility and for rare grouping clarity, but the canonical form omits
commas when the sequence is obvious.

Generic type:

```meridian
type Box of T:
  value: T
end
```

Generic enum:

```meridian
enum Either of A B:
  Left value: A
  Right value: B
end
```

Current generic enums support multiple type parameters with concrete
specialization at constructor and type-use sites.

Generic function:

```meridian
chooseLeft of A B(left: A, right: B) returns A:
  left
end
```

Current generic functions support multiple type parameters with concrete
specialization at call sites. Generic functions may declare concrete typed
`throws`; the specialized function uses the same `try` and `catch` rules as an
ordinary throwing function.
When a generic function parameter is concrete rather than type-parameter
dependent, its declared type remains the expected type for the argument.

Constraints:

```meridian
max(a: T, b: T) returns T:
  if a > b: a else: b end
end
```

Requires clause:

```meridian
save(value: T) returns Void throws SaveError
requires serialize(T) returns Bytes validate(T) returns Unit throws ValidateError:
  try validate value
  try db.insert value
end
```

Nested parametric types must use parentheses when the grouping would otherwise
be ambiguous.

Prefer:

```meridian
Map of String (List of User)
Result of (List of User) DbError
```

Avoid relying on readers to infer grouping in forms like:

```meridian
Map of String List of User
Result of List of User DbError
```

Single-letter uppercase type names such as `T`, `U`, `K`, `V`, and `E` are
treated as type variables in function signatures and generic type declarations.
Longer uppercase names must resolve to declared or used types.

## 26. Event-loop runtime

Event-loop runtime work is not core Meridian. It is deferred to a later library/runtime module
that uses signaling, handles, and an event-loop backend. The first substrate is
direct resource signaling:

```meridian
useEventLoop returns I32 signaling EventLoopIo:
  let reactor = EventLoopIo.open(eventLoopAccess)
  let timer = EventLoopIo.openTimer(reactor, 0)
  let ranTimer = EventLoopIo.runUntilTimer(reactor, timer)
  let ready = EventLoopIo.timerReady(timer)
  let timerClosed = EventLoopIo.closeTimer(timer)
  let channel = EventLoopIo.openChannel(reactor)
  let sent = EventLoopIo.sendI32(channel, 7)
  let channelReady = EventLoopIo.channelReady(sent)
  let ranChannel = EventLoopIo.runUntilChannel(reactor, sent)
  let boundedChannel = EventLoopIo.runUntilChannelFor(reactor, sent, 0)
  let received = EventLoopIo.receiveI32(sent, 1)
  let channelClosed = EventLoopIo.closeChannel(sent)
  let finishingChannel = EventLoopIo.openChannel(reactor)
  let finishingChannelWithValue = EventLoopIo.sendI32(finishingChannel, 15)
  let finishedChannelResult = EventLoopIo.finishChannelI32(reactor, finishingChannelWithValue, 16)
  let boundedFinishingChannel = EventLoopIo.openChannel(reactor)
  let boundedFinishingChannelWithValue = EventLoopIo.sendI32(boundedFinishingChannel, 17)
  let boundedFinishedChannelResult = EventLoopIo.finishChannelI32For(reactor, boundedFinishingChannelWithValue, 0, 18)
  let timeoutFinishingChannel = EventLoopIo.openChannel(reactor)
  let timeoutFinishedChannelResult = EventLoopIo.finishChannelI32For(reactor, timeoutFinishingChannel, 0, 19)
  let group = EventLoopIo.openGroup(reactor)
  let task = EventLoopIo.scheduleI32(group, 5)
  let taskReady = EventLoopIo.taskReady(task)
  let taskResult = EventLoopIo.taskResultI32(task, 2)
  let taskClosed = EventLoopIo.closeTask(task)
  let delayed = EventLoopIo.scheduleI32After(group, 0, 4)
  let ranDelayed = EventLoopIo.runUntilTask(reactor, delayed)
  let boundedDelayed = EventLoopIo.runUntilTaskFor(reactor, delayed, 0)
  let delayedReady = EventLoopIo.taskReady(delayed)
  let delayedResult = EventLoopIo.taskResultI32(delayed, 3)
  let delayedClosed = EventLoopIo.closeTask(delayed)
  let finishingTask = EventLoopIo.scheduleI32After(group, 0, 6)
  let finishedResult = EventLoopIo.finishTaskI32(reactor, finishingTask, 11)
  let boundedFinishingTask = EventLoopIo.scheduleI32After(group, 0, 8)
  let boundedFinishedResult = EventLoopIo.finishTaskI32For(reactor, boundedFinishingTask, 0, 12)
  let timeoutFinishingTask = EventLoopIo.scheduleI32After(group, 10, 13)
  let timeoutFinishedResult = EventLoopIo.finishTaskI32For(reactor, timeoutFinishingTask, 0, 14)
  let groupClosed = EventLoopIo.closeGroup(group)
  let cancelGroup = EventLoopIo.openGroup(reactor)
  let cancelledTask = EventLoopIo.scheduleI32(cancelGroup, 99)
  let groupCancelled = EventLoopIo.cancelGroup(cancelGroup)
  let cancelledReady = EventLoopIo.taskReady(cancelledTask)
  let cancelledResult = EventLoopIo.taskResultI32(cancelledTask, 9)
  let cancelledTaskClosed = EventLoopIo.closeTask(cancelledTask)
  let closeProbe = EventLoopIo.open(eventLoopAccess)
  let staleTimer = EventLoopIo.openTimer(closeProbe, 0)
  let staleChannel = EventLoopIo.openChannel(closeProbe)
  let staleChannelWithValue = EventLoopIo.sendI32(staleChannel, 21)
  let staleGroup = EventLoopIo.openGroup(closeProbe)
  let staleTask = EventLoopIo.scheduleI32(staleGroup, 22)
  let closeProbeClosed = EventLoopIo.close(closeProbe)
  let staleTimerReady = EventLoopIo.timerReady(staleTimer)
  let staleChannelReady = EventLoopIo.channelReady(staleChannelWithValue)
  let staleTaskReady = EventLoopIo.taskReady(staleTask)
  let staleTaskResult = EventLoopIo.taskResultI32(staleTask, 23)
  let staleTimerClosed = EventLoopIo.closeTimer(staleTimer)
  let staleChannelClosed = EventLoopIo.closeChannel(staleChannelWithValue)
  let staleTaskClosed = EventLoopIo.closeTask(staleTask)
  let staleGroupClosed = EventLoopIo.closeGroup(staleGroup)
  let pumped = EventLoopIo.runFor(reactor, 0)
  let polled = EventLoopIo.poll(reactor)
  let closed = EventLoopIo.close(reactor)
  if ranTimer and ready and channelReady and ranChannel and boundedChannel and taskReady and ranDelayed and boundedDelayed and delayedReady and groupCancelled and pumped and not cancelledReady and not staleTimerReady and not staleChannelReady and not staleTaskReady:
    polled + received + finishedChannelResult + boundedFinishedChannelResult + timeoutFinishedChannelResult + taskResult + delayedResult + finishedResult + boundedFinishedResult + timeoutFinishedResult + cancelledResult + staleTaskResult - 127
  else:
    1
  end
end
```

`EventLoopAccess` is the explicit authority token. `EventLoop`,
`EventLoopTimer`, `EventLoopChannel`, `EventLoopTaskGroup`, and `EventLoopTask`
are owned opaque handles. `EventLoopTaskGroup` is the structured owner for task
lifetimes: scheduling requires a peeked group, tasks remember their group and
loop identity, `cancelGroup` is the explicit checked cancellation boundary, and
`closeGroup` is the Unit cleanup boundary for the group. `close` marks the
event loop closed; timer, channel, group, and task operations tied to that loop
then fail closed, while explicit handle cleanup remains available. Ordinary
Meridian code is run-to-completion; runtime progress is explicit
through `poll`, `runFor`, `runUntilTimer`, `runUntilTask`, `runUntilTaskFor`, or
scoped `signal`/`enact` handoff. `poll`, `timerReady`, `channelReady`,
`runUntilChannel`, `runUntilChannelFor`, `receiveI32`,
`taskReady`, and `taskResultI32` peek handles; `sendI32`,
`finishChannelI32`, `finishChannelI32For`, `finishTaskI32`,
`finishTaskI32For`, `close`, `closeTimer`, `closeChannel`, `closeTask`,
`cancelGroup`, and `closeGroup` consume handles. `sendI32` returns
the next owned channel state instead of mutating through `peek`. The core
language has no coroutine keyword surface. The runtime backend is deliberately
not Tokio or libuv-shaped; the source contract is a backend-neutral owned-handle
reactor that can be implemented by the simplest platform event substrate.
Generated runtime code checks active loop ownership through centralized
predicates for loops, timers, channels, task groups, and tasks. Timer/channel
and task wait or finish operations reject wrong-loop, closed-loop, closed-group,
and stale handles; `cancelGroup` rejects groups that are already closed or tied
to a closed loop. The minimal wait/cancel contract is deliberately split:
`runUntilTimer`, `runUntilChannel`, `runUntilChannelFor`, `runUntilTask`, and
`runUntilTaskFor` peek loop/resource handles; `finishChannelI32`,
`finishChannelI32For`, `finishTaskI32`, `finishTaskI32For`, and `cancelGroup`
consume owned handles.
Timers and `scheduleI32After` use monotonic-time due points, while
`runFor`, `runUntilTimer`, `runUntilTask`, `runUntilTaskFor`,
`finishChannelI32For`, and `finishTaskI32For` let the runtime pump, block, or wait with a bounded timeout
without adding callbacks or continuation syntax; richer OS integration belongs
to the later event-loop module.

## 27. Operators

Arithmetic:

```meridian
+ - * / %
```

Power:

```meridian
**
```

Comparison:

```meridian
= < <= > >=
not x = y
```

Boolean:

```meridian
and or not
```

Assignment:

```meridian
:=
+=
-=
*=
/=
%=
```

Access:

```meridian
.
[]
```

Ranges:

```meridian
1..10      // exclusive end
1..=10     // inclusive end
```

Pipeline:

```meridian
pipe
piping
|>
```

No function arrow:

```meridian
->
```

No lambda arrow:

```meridian
=>
```

## 28. Literals

Numbers:

```meridian
42
3.14
1_000_000
0xff
0b1010
```

Strings are single-line literals with `\"`, `\\`, `\n`, `\r`, and `\t`
escapes. They produce owned `String` values backed by static immutable storage:

```meridian
"hello"
```

Multiline strings:

```meridian
"""
select id, name
from users
where active = true
"""
```

Booleans:

```meridian
true
false
```

Unit:

```meridian
()
```

Lists:

```meridian
[1, 2, 3]
```

Maps:

```meridian
[
  "name": "Ada",
  "age": 42,
]
```

Option values:

```meridian
Some value
None
```

## 29. Collections

List type:

```meridian
List of User
```

Map type:

```meridian
Map of String User
```

Copied slice literal:

```meridian
let nums: Slice of I32 = [1 2 3]
let more: Slice of I32 = [1, 2, 3]
let none: Slice of I32 = []
```

Owned list/array literal and multiline list syntax are future work:

```meridian
let users = [
  ada,
  grace,
  alan,
]
```

Map literal is future work:

```meridian
let scores = [
  "Ada": 10,
  "Grace": 9,
]
```

Indexing:

```meridian
users[0]
scores["Ada"]
```

Safe lookup should return an option:

```meridian
let user = users.get 0
```

## 30. Optional Values

Optional type:

```meridian
Option of String
```

Construct values:

```meridian
Some "ada@example.com"
None
```

Use constructor-pattern `if`:

```meridian
if user.email matches Some(email):
  sendEmail email
else:
  pass
end
```

Meridian does not use `T?` optional sugar. The explicit `Option of T` spelling
keeps absence visible in data-structure types and composes with ownership
modifiers, for example `Option of owned Item`.

Or `match`:

```meridian
match user.email:
  Some email:
    sendEmail email

  None:
    pass
end
```

No universal `null`.

## 31. Parallel-Friendly Constructs

Current boundary: Meridian accepts a conservative `parallel: ... end` block
expression. It is checked and lowered like an ordinary scoped block today; no
threads, tasks, or runtime handles are created by this syntax yet. The current
slice also gates the body to pure scoped work: `let` setup, pure expressions,
pure calls, expression `if` / `match`, and nested pure `do` / `parallel` blocks.
Mutable state, loops, early exits, `throw` / `try`, `signal` / `enact`,
`using`, `region`, capability minting, and `consume` stay outside the accepted
surface until F6 lowering owns scheduling and resource semantics.

Inside a `parallel:` block, `fork expr` marks a pure expression as a future
scheduling unit. It is retained in the AST as `Expr::Fork` so later F6
independence analysis can find explicit work units. It still lowers
sequentially today and is accepted only under the same pure-work gate as the
surrounding block. `fork` outside `parallel:` remains reserved and rejected.

Fork work is independent inside a block. A `fork` may read pre-existing copied
inputs, but it cannot read a value produced by earlier fork-derived work in the
same `parallel:` block. Combine fork results after the fork work, normally in
the block tail.

Generated C keeps the current sequential behavior, but each `parallel:` block
is emitted with stable group begin/end metadata and each forked expression is
emitted with a stable group/item marker. That metadata is a backend boundary
for later scheduling/lowering work; it is not a thread, task, or runtime handle
by itself.

The point of the first F6 slices is to give the language one explicit place
where future parallel evaluation can attach without weakening memory rules.
This is the closed v1 boundary: `parallel:` and scoped `fork` are accepted,
checked, and emitted sequentially with metadata; real scheduling is future
runtime/module work rather than hidden core semantics.

Example:

```meridian
main returns I32:
  parallel:
    let left = fork 20
    let right = fork 22
    left + right
  end
end
```

`fold` and `unfold` remain future-reserved for v1 and fail closed with a
dedicated diagnostic. They are not part of the current language surface because
tree/stream recursion helpers would need their own ownership, region, exact-use
handle, and result-combining rules. The current v1 parallel surface is
`parallel:` plus scoped `fork`.

The intended later direction is pure-by-default analysis and parallel evaluation
of independent pure expressions.

Example:

```meridian
sumRange(start: Int, target: Int) returns Int:
  if start is target:
    start
  else:
    let half = (start + target) / 2
    let left = sumRange start, half
    let right = sumRange half + 1, target
    left + right
  end
end
```

The compiler may evaluate `left` and `right` in parallel if it can prove
independence.

Possible later fold syntax:

```meridian
fold tree:
  Node left, right:
    left + right

  Leaf value:
    value
end
```

Possible later unfold syntax:

```meridian
unfold depth = 0:
  when depth < 3:
    Node(fork depth + 1, fork depth + 1)
  else:
    Leaf 7
end
```

These are inspired by functional languages and Bend-like parallel programming,
but they are not required for ordinary control flow. Any accepted F6 construct
must preserve Meridian's memory rules: no hidden movement of owned or exact-use
values, no escaping peek or region state, and no hidden runtime handles.

## 32. Style Rules

The official formatter should enforce:

- two spaces per indentation level
- no semicolons
- no braces for blocks
- no arrows for return types or lambdas
- `end` aligned with its opener
- one blank line between top-level declarations
- no aligned columns
- final-expression returns where practical
- `return` only for early exits
- named arguments when multiple same-typed arguments appear
- `do ...: ... end` for callbacks
- projection shorthand for trivial field or method mapping
- parentheses for complex or nested calls
- guard clauses over deep nesting
- trailing commas in multiline calls, record constructors, copied-slice
  literals, grouped pipelines, generic type-parameter lists, unambiguous generic
  type-argument lists, and declaration/header lists

Good:

```meridian
transfer from: source, to: destination, amount: amount
```

Clearer when same-typed arguments could be confused:

```meridian
transfer(
  from: source,
  to: destination,
  amount: amount,
)
```

## 33. Complete Example

```meridian
module app accounts

from std import time exposing Instant
from app import db users
from app import email sendEmail

type User:
  id: UserId
  name: String
  email: String
  createdAt: Instant
end

type CreateUser:
  name: String
  email: String
end

error CreateUserError:
  InvalidEmail email: String
  DuplicateEmail email: String
  Database source: DbError
  Email source: EmailError
end

validateEmail(email: String) returns String throws CreateUserError:
  let clean = email.trim().lower()

  if clean.contains "@":
    clean
  else:
    throw InvalidEmail email
  end
end

createUser(input: CreateUser) returns User throws CreateUserError:
  let email = try validateEmail input.email

  if try users.exists email:
    throw DuplicateEmail email
  end

  let user = User(
    id: UserId.new(),
    name: input.name.trim(),
    email: email,
    createdAt: Instant.now(),
  )

  try users.insert user

  try sendEmail to: user.email, subject: "Welcome, {user.name}"

  user
end

findUser(id: UserId) returns User throws FindUserError:
  match try users.find id:
    Some user:
      user

    None:
      throw NotFound id
  end
end

activeEmails(users: List of User) returns List of String:
  users
  pipe filter with user: user.active and not user.deleted end
  pipe map .email
  pipe sort
end
```

## 34. Grammar Sketch

This is a sketch, not a complete grammar.

```text
file =
  packageDecl?
  moduleDecl?
  importDecl*
  topLevelDecl*

packageDecl =
  "package" modulePath

moduleDecl =
  "module" modulePath

importDecl =
  "from" identifier "import" modulePath importSelection?

modulePath =
  identifier+

importSelection =
  "exposing" Identifier+

topLevelDecl =
  export? (
    typeDecl
    | enumDecl
    | errorDecl
    | constDecl
    | deriveDecl
    | signalingDecl
    | functionDecl
    | operationDecl
  )

functionDecl =
  identifier parameterList returnClause? signalingClause? throwsClause? requiresClause? block
  | identifier returnClause signalingClause? throwsClause? requiresClause? block

parameterList =
  "(" params ")"

params =
  param (listSeparator param)* ","?

identifierList =
  identifier (listSeparator identifier)*

param =
  identifier ":" parameterAccess? type ("=" expression)?

parameterAccess =
  "peek" | "consume"

returnClause =
  "returns" type

throwsClause =
  "throws" errorTypeList

errorTypeList =
  type (listSeparator type)* ","?

signalingClause =
  "signaling" signalGroupList

requiresClause =
  "requires" (requiresEntryList | boolContractExpression)

requiresEntryList =
  requiresEntry (listSeparator requiresEntry)* ","?

requiresEntry =
  identifier ("(" typeList? ")")? "returns" type throwsClause?

listSeparator =
  whitespace boundary | ","

block =
  ":" blockBody "end"

blockBody =
  expression
  | newline indent statement* expression? dedent

ownershipModifier =
  "copied" | "owned"

typeDecl =
  ownershipModifier? "type" UpperIdentifier typeParamClause? block

deriveDecl =
  "derive" "equal" "for" UpperIdentifier
  | reservedDeriveShowDecl

reservedDeriveShowDecl =
  "derive" "show" "for" UpperIdentifier

reservedLayoutDecl =
  "packed" "type" UpperIdentifier typeParamClause? block
  | "aligned" Int "type" UpperIdentifier typeParamClause? block
  | "soa" "type" UpperIdentifier typeParamClause? block

`packed type`, `aligned N type`, and declaration-only `soa type` descriptors
lower through the layout-control path.

typeParamClause =
  "of" typeVariableList ","?

typeVariableList =
  UpperIdentifier (listSeparator UpperIdentifier)*

enumDecl =
  ownershipModifier? "enum" UpperIdentifier typeParamClause? block

errorDecl =
  "error" UpperIdentifier block

signalingDecl =
  "signaling" UpperIdentifier block

fieldDecl =
  identifier ":" type

variantDecl =
  UpperIdentifier variantPayload?

statement =
  letStmt
  | varStmt
  | assignment
  | ifExpr
  | matchExpr
  | forStmt
  | whileStmt
  | loopStmt
  | tryCatchExpr
  | throwStmt
  | returnStmt
  | breakStmt
  | continueStmt
  | loopExitIfStmt
  | expression

letStmt =
  "let" identifier typeAnnotation? "=" expression

varStmt =
  "var" identifier typeAnnotation? "=" expression

typeAnnotation =
  ":" type

throwStmt =
  "throw" expression

returnStmt =
  "return" expression

lambdaExpr =
  "do" lambdaParams? block

lambdaParams =
  identifierList ","?
  | "(" params? ")"

functionType =
  "(" typeList? ")" "returns" type throwsClause?

typeList =
  type (listSeparator type)* ","?

ifExpr =
  "if" expression ":" blockBody ("else if" expression ":" blockBody)* ("else" ":" blockBody)? "end"

inlineIfExpr =
  "if" expression ":" expression "else" ":" expression "end"

matchExpr =
  "match" expression ":" newline indent matchArm+ dedent "end"

matchArm =
  pattern ":" blockBody

forStmt =
  "for" identifier "in" expression block

whileStmt =
  "while" expression block

loopStmt =
  "loop" block

loopExitIfStmt =
  "if" expression ":" loopExitBranch ("else" ":" loopExitBranch)? "end"

loopExitBranch =
  breakStmt
  | continueStmt

tryCatchExpr =
  "try" ":" blockBody catchArm+ "end"

resumeExpr =
  "resume" expression

abandonExpr =
  "abandon" expression

signalExpr =
  "signal" qualifiedName argumentList?

enactExpr =
  "enact" signalGroupName ":" blockBody enactArm+ "end"

catchArm =
  "catch" pattern ":" blockBody

enactArm =
  "handle" qualifiedName enactParams? ":" blockBody

enactParams =
  "(" identifierList ","? ")"

callExpr =
  expression argumentList
  | expression "(" argumentList? ")"

pipelineExpr =
  expression "pipe" pipelineStep
  | expression "|>" pipelineStep
  | expression "pipe" "(" pipelineStep ("," pipelineStep)* ","? ")"
  | expression "piping" "(" pipelineStep ("," pipelineStep)* ","? ")"
  | expression "|>" "(" pipelineStep ("," pipelineStep)* ","? ")"

pipelineStep =
  identifier
  | identifier "(" argumentList? ")"
  | expressionContainingFreeIt
  | projectionExpr
  | withExpr
  | doExpr

expressionContainingFreeIt =
  expression with a free `it` identifier scoped to the previous pipeline value

argumentList =
  argument (listSeparator argument)* ","?

argument =
  expression | identifier ":" expression

projectionExpr =
  "." identifier ("(" argumentList? ")")?

withExpr =
  "with" identifier ":" blockBody "end"
```

## 35. Syntax Philosophy

Canonical Meridian should look like this:

```meridian
findUser(id: UserId) returns User throws FindUserError:
  match try users.find id:
    Some user:
      user

    None:
      throw NotFound id
  end
end
```

Not like this:

```rust
fn find_user(id: UserId) -> Result<User, FindUserError> {
  match users.find(id)? {
    Some(user) => Ok(user),
    None => Err(NotFound(id)),
  }
}
```

And not like this:

```python
def find_user(id: UserId) -> User:
  ...
```

The guiding rule is:

> Remove syntax that is merely traditional. Keep syntax that prevents ambiguity
> or improves scanning.
