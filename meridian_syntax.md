# Meridian Syntax Specification

Status: proposed surface syntax  
Supersedes: syntax in [meridian_spec.md](meridian_spec.md)

This document is the language surface. It does not describe compiler slices,
C lowering, or standard-library catalogs.

## Delta

Kept: `end` block closers, `:` header/body split, `=` equality, `:=` mutation,
`peek` / `consume`, `throws` / `try` / `throw`, `needs` / `context`, `of`.

Changed:

| Old | New |
| --- | --- |
| `name(x: T) returns U:` | `name(x: T) U:` |
| `name() returns Unit:` | `name:` |
| `do user: user.email end` | `.email` or `it.email` |
| `with user: user.email end` | removed |
| `operation area on Shape returns I32:` | `area on Shape I32:` |
| `copied type Point:` | `type Point:` |
| `value \|> f` / `piping` | `value pipe f` |
| `if x matches Some y:` | `if x is Some y:` |
| `from std import time exposing Instant` | `from std time exposing Instant` |
| `using x = e with drop(x):` | `using x = e:` |

`returns`, `operation`, `with`, `import`, `matches`, `piping`, and `|>` are
reserved and rejected.

## 1. Design Principles

Meridian is a low-punctuation, statically typed, expression-oriented language
with explicit block closure.

Favor:

- explicit block closure with `end`
- explicit header/body separation with `:`
- low punctuation density
- word-and-colon structure
- typed public APIs
- expression-oriented function bodies
- algebraic data types and pattern matching
- typed `throws`
- `requires` for structural generic constraints
- explicit capabilities
- `signal` / `enact` for scoped interpretation
- juxtaposition calls when unambiguous

Whitespace around structural `:` is insignificant. `x:T` and `x: T` are the
same. Prefer the spaced form.

Avoid:

- brace-delimited blocks
- semicolons
- `fn`, `def`
- `->`, `=>`
- mandatory `return` for normal results
- `Ok` / `Err` ceremony in ordinary error handling
- universal `null`
- dropping `end`

Structural words:

```meridian
throws try throw do end and or not is pipe
```

Punctuation that earns its place:

```meridian
: . = := () [] ,
+ - * / % **
< <= > >=
```

## 2. Ownership

Four source concepts:

```text
copied   pass freely, discard freely, no cleanup
owned    move once, compiler cleans up on every exit path
peek     temporary read-only view, non-escaping, no lifetimes
consume  transfer into callee, caller cannot reuse
```

Everything else is mechanism:

- `handle` is an opaque owned identity from signal operations
- `region` is a lexical bulk-allocation scope
- `using` is scoped finalization over `consume`
- runtime resources enter through signal operations and handles

Safe code does not use user-written lifetimes, generic `peek T` polymorphism,
or fallible cleanup hooks. Concrete peeks such as `peek User` and
`peek Array of T` are allowed. Peeks may be passed to ordinary functions and
direct non-escaping callbacks while the owner stays live. They may not be
returned, stored, captured by escaping closures, or described with lifetime
parameters.

Returned peek views use scoped signaling: a `signal` (or a signal-only function
as the direct body of a matching `enact`) may hand a peek to that handler. The
handler may read it and must not let it escape.

`owned` is not a parameter access word. Write `consume T` or `peek T` at
function boundaries. Ownership of values is inferred from the declared type.

Bare `type`, `enum`, and unmarked records/enums with only copied payloads are
copied. Write `owned type` / `owned enum` when the value is owned.
`copied type` is rejected.

## 3. Lexical Structure

Line comments: `// comment`  
Block comments: `/* comment */`

Identifiers are case-sensitive.

```meridian
lowerCamelCase  // values, functions, fields
UpperCamelCase  // types, variants, errors
SCREAMING_CASE  // constants
```

### Keywords

In use:

```text
package module from exposing export
type enum error handle capability
const let var
if else match for in while loop break continue return
throws try throw catch
signaling signal enact resume abandon
do end
and or not is
pipe
peek consume owned
requires needs context region using
derive for
packed aligned soa
pass
compile
parallel fork
```

Reserved, not syntax:

```text
returns operation with import matches piping
class instance impl implementation interface trait satisfies where
fold unfold when as use
unsafe linear
```

### Constants

```meridian
const ENABLED = true
const MODE: String = "fast"
const BASED: I32 = do:
  let base = 40
  base + 2
end
```

Constant initializers are pure: literals, other constants, operators over
`I32` / `I64` / `Bool` / `Unit` / `String`, and deterministic `if`. Mutation,
allocation, and IO are rejected unless the constant body has compile-time
authority from `from source files` or `from build ...`.

```meridian
const ANSWER: I32 = compile:
  BASE + 2
end
```

## 4. Files, Modules, And Imports

```meridian
package app
module app accounts

from std time exposing Instant
from app db users
from app email sendEmail
from source files
from build checks
```

`from namespace path` — first word is the namespace, the rest is the module
path. No dots in ordinary module paths. No import aliases.

`exposing` lists exported types, functions, or constructors. Without
`exposing`, the importer sees the module's exported surface only.

```meridian
export type User:
  id: UserId
  name: String
end

export findUser(id: UserId) User throws FindUserError:
  ...
end
```

`package`, `module`, and `from` lines do not use `end`.

A packaged module path must start with the package path. Manifests, lockfiles,
and registries are tooling, not syntax.

## 5. Blocks

`:` opens a body. `end` closes the nearest open block. Indentation is
formatter-enforced, not the terminator.

```meridian
if ready:
  start()
end

if ready: start() end
```

Empty body:

```meridian
todo:
  pass
end
```

## 6. Bindings And Assignment

```meridian
let name = "Ada"
let count: I32 = 3
var retries = 0
retries := retries + 1
retries += 1
self.name := name
```

Declaration uses `=`. Mutation uses `:=`.

```meridian
if x := 1:   // illegal
if x = 1:    // comparison
```

Local annotations sit on the binding: `let count: I32 = 3`. Bare
`count: I32 = 3` is rejected.

## 7. Functions

No `fn`, `def`, or `returns`. The result type follows the parameter list.
Omitted result type is `Unit`.

```meridian
add(a: I32 b: I32) I32:
  a + b
end

main I32:
  0
end

log(msg: peek String):
  pass
end

findUser(id: UserId) User throws FindUserError:
  ...
end
```

Parameter lists are parenthesized when there is at least one parameter.
Zero-parameter declarations omit `()`. Commas are optional when the next
`name: Type` is clear.

The final expression is the result. `return` is only for early exit.

```meridian
first(items: peek Array of I32) Option of I32:
  if empty(items):
    return None
  end
  Some(front(items, 0))
end
```

Static overloads are allowed when parameter type lists differ. Return type
does not participate in overload selection. Concrete overloads win over
generic ones. Ambiguous or duplicate overloads are rejected.

Header clause order:

```text
name (params)? ResultType? signaling ... throws ... needs ... requires ... :
```

## 8. Function Signatures

```meridian
name: Type
name: peek Type
name: consume Type
```

No access word means the ordinary copied path.

```meridian
transfer(from: Account to: Account amount: Money) Receipt throws TransferError:
  ...
end

connect(url: peek String timeout: I32 = 5) Connection throws ConnectError:
  ...
end

chooseLeft of A B(left: A right: B) A:
  left
end

divide(a: I32, b: I32) I32 requires not b = 0:
  a / b
end
```

Zero-argument calls still use `()`:

```meridian
now Instant:
  Instant.current()
end

let instant = now()
```

## 9. Calls

Juxtaposition when unambiguous:

```meridian
print message
users.find id
add 1 2
```

Named arguments:

```meridian
sendEmail to: user.email subject: "Welcome"
```

Parentheses when nested or inside arithmetic:

```meridian
let total = add(1 2) * 3
```

Field and method access:

```meridian
user.name
user.displayName()
text.contains "@"
```

## 10. Types

```meridian
type User:
  id: UserId
  name: String
  email: Option of String
end

type Page of T:
  items: Array of T
  total: I32
  next: Option of String
end

owned type Buffer:
end
```

Type constructors are word-based. No angle brackets.

```meridian
Array of I32
Array of owned Item
Map of String User
Option of Box of Node
```

Parentheses group nested or modified arguments. Commas only when needed.

Transparent aliases:

```meridian
type UserId = I32
type Digit = I32 range 0..10
```

Range aliases are half-open. Runtime values enter them through `narrow`:

```meridian
let digit: Digit = narrow(raw, 0)
let checked: Digit = narrow(raw, throw OutOfRange)
```

`I32` is the default integer. `I64` needs an expected type. No implicit
widening.

Layout descriptors, when used, are prefix words on `type`:

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

```meridian
derive equal for Point
derive show for Point
```

`equal(other: T) Bool`. `show` allocates: `show() String throws AllocError`
under `needs allocator` or an explicit allocator argument.

No `T?`. No universal `null`.

## 11. Record Construction

Named fields. No `end` on constructors.

```meridian
let point = Point(x: 10 y: 20)

let user = User(
  id: id
  name: name
  email: email
)
```

Bare local names may fill same-named fields:

```meridian
let user = User(
  id
  name
  email
)
```

Each field at most once.

## 12. Enums

```meridian
enum Option of T:
  Some value: T
  None
end

owned enum Token:
  Id value: I32
  End
end
```

Unmarked enums are copied when every payload is copied, owned when any payload
is owned.

```meridian
Some(user)
None
Circle(4)
Rect(width: 10, height: 20)
Shape.Circle(4)
```

## 13. Typed Throws

```meridian
error FindUserError:
  NotFound id: UserId
  Database source: DbError
end

throw NotFound id

findUser(id: UserId) User throws FindUserError:
  ...
end

loadUser(id: UserId) User throws DbError, DecodeError:
  ...
end
```

A function that does not declare `throws` cannot let a throw escape.
`throw` aborts. It does not resume.

## 14. Try / Catch

Prefix `try` propagates. Block `try` recovers.

```meridian
let user = try findUser(id)

try:
  findUser(id)
catch NotFound id:
  renderMissing id
catch Database err:
  renderError err
end

let view =
  try:
    findUser(id)
  catch NotFound id:
    MissingUserView id
  catch Database err:
    ErrorView err
  end
```

A catch must cover remaining error variants unless the enclosing function
declares them in `throws`.

## 15. Conditionals

```meridian
if condition:
  consequence
else if score >= 70:
  "good"
else:
  "needs work"
end

let label = if active: "Active" else: "Inactive" end
```

Boolean operators are `and`, `or`, `not`. Not `&&`, `||`, `!`.
Inequality is `not x = y`.

## 16. Pattern Matching

```meridian
match shape:
  Circle radius:
    radius * radius * 3
  Rect width, height:
    width * height
end
```

Patterns: `Some value`, `Some(value)`, `Some(value: item)`, `None`,
`User(id, name)`, `User(id: id, name: name)`, `_`.

No arrows in arms.

### Receiver operations

No `operation` keyword. Name, then `on`, then the receiver.

```meridian
area on Shape I32:
  Circle radius:
    radius * radius * 3
  Rect size:
    size * size
end

let a = shape.area()

scale on Shape(factor: I32) I32:
  Circle radius:
    radius * factor
  Rect size:
    size * factor
end

unwrapOr on Maybe of T(fallback: T) T:
  Some value:
    value
  None:
    fallback
end

get on Box of T T:
  self.value
end
```

Enum operations are exhaustive variant dispatch. Record operations are ordinary
bodies with `self`. `consume` receivers and parameters follow the same move
rules as functions. Operations may `throws` and `requires`. They may not
declare `signaling` in this surface.

## 17. Constructor Pattern If

`is`, not `matches`. Requires `else` because it is an expression.

```meridian
if user.email is Some email:
  sendEmail email
else:
  log "missing email"
end

if user.email is None:
  log "missing email"
else:
  log "has email"
end

if user.email is Some(email: address):
  sendEmail address
else:
  log "missing email"
end

if code is Some(3):
  handleThree
else:
  handleOther
end
```

`is` is constructor matching only. Equality remains `=`.

Equivalent to `match` with two arms. Payload bindings are then-branch only.

## 18. Loops

Statements.

```meridian
for user in users:
  total := total + user.score
end

while running:
  let message = try socket.read()
  process message
end

loop:
  tick()
end
```

`for` iterates copied elements of `Array of T`, `peek Array of T`, or
`Slice of T`, or a half-open `I32` / `I64` range `start..end`.

`break` and `continue` are statements. Bare loop-body expressions must be
`Unit` or `Never`.

## 19. Lambdas And Callbacks

Blocks use `do ... end`. Field and predicate callbacks do not.

```meridian
users.map .email
users.filter .active
users.filter it.age >= 18 and it.active
users.map .lower()
select(score, .boosted(amount: 2))
```

`.field` / `.method(...)` lower to a one-parameter lambda. `it` names the
callback subject in an expression step.

`do` is for multi-statement, typed, or throwing lambdas:

```meridian
do param:
  body
end

do:
  refresh()
end

do a, b:
  a + b
end

do (user: User):
  user.email
end

let increment: (I32) I32 = do value:
  value + 1
end
```

Stored lambdas need an explicit function type. They may capture copied values
by copy and owned values by move. Peek and exact-use captures are rejected on
stored closures. Direct non-escaping callbacks may read copied and peek locals
already live at the call site.

Trailing callback as the last argument of a positional call:

```meridian
users.map do user:
  try normalize user.email
end
```

Not after named-argument calls. Not on record constructors.

There is no `with` subject-binding form. There are no arrow lambdas.

## 20. Function Types

```meridian
(User) String
(I32, I32) I32
(UserId) User throws LoadError
```

No `->`.

## 21. Pipelines

One spelling: `pipe`. The left value becomes the first argument.

```meridian
let score = 20 pipe add(1) pipe twice
```

Grouped steps:

```meridian
let score = 20 pipe (
  add(1),
  twice,
)
```

Steps:

```text
function                 function(previous)
function(args)           function(previous, args)
it + 1                   expression over previous
.field                   previous.field
.method(args)            previous.method(args)
do name: ... end         lambda over previous
```

```meridian
users
pipe filter it.active
pipe map .email
pipe sort
```

`it` in a pipeline step is the previous value. Nested bindings named `it` do
not count as pipeline-subject use inside that nested scope.

## 22. Requires

Structural entries or one final `Bool` contract.

```meridian
max(a: T, b: T) T
requires lessThan(T, T) Bool:
  if lessThan(a, b): b else: a end
end

printArea(value: T)
requires area(T) I32:
  printInt(area(value))
end

divide(a: I32, b: I32) I32 requires not b = 0:
  a / b
end
```

No named requirement bundles. No `where`, `trait`, or `interface`.
Contracts see only copied parameters and copied context. They abort on
failure.

## 23. Capabilities And Signaling

Capabilities are copied authority tokens. Direct signal operations are
ordinary checked calls declared on a `signaling` group. `signal` / `enact` is
the scoped interpreter, not the default IO path.

```meridian
capability type FileSystem:
end

let fs = capability FileSystem

signaling FileIo:
  read(fs: peek FileSystem, path: peek String) String throws IoError
end

loadConfig(fs: peek FileSystem, path: peek String) Config signaling FileIo throws IoError, ParseError:
  let bytes = try FileIo.read(fs, path)
  try parseConfig(bytes)
end
```

A callee's `signaling` row must appear on the caller, except inside a matching
`enact`.

```meridian
signaling Log:
  info(message: peek String)
end

runBuild() signaling Log:
  signal Log.info("compiling")
end

testBuild():
  enact Log:
    runBuild()
  handle Log.info(message):
    resume ()
  end
end
```

`resume expr` continues with a value. `abandon expr` does not resume.
Continuations are one-shot and cannot escape the handler arm.

Peek views may be handed to a handler this way. Ordinary functions still
cannot return peeks.

### Context and needs

```meridian
usesTrace I32 needs trace:
  if trace:
    42
  else:
    0
  end
end

main I32:
  context trace = false:
    usesTrace()
  end
end
```

`needs` is a header clause, not a global keyword meaning. `main` cannot
declare `needs`; it establishes context locally.

Standard allocator-backed calls may omit a trailing `allocator: Allocator`
argument inside `context allocator = ...` or `needs allocator`.

### Handles, using, drop

```meridian
handle File
```

Handles have no source-visible fields and are created only by signal
operations. Cleanup is `drop(value: T)`. The compiler inserts `drop` on every
exit path for owned values that were not moved.

`using` takes ownership for a block and calls `drop` on exit, including
`throw`. Write an explicit finalizer only when it is not `drop`, as a later
extension; the canonical form is:

```meridian
using file = try FileIo.openReadPath(fileAccess, path):
  try FileIo.readI32(file)
end
```

The binding cannot be moved out of the block.

`region name: ... end` is lexical bulk allocation. Values allocated `in` that
region are cleaned with the region.

Source-level `unsafe` is not part of the language.

## 24. Standard Values

These are the closed collection and scalar shapes the syntax assumes.

`Allocator` is a copied capability. `AllocError` / `AllocationFailed` is
allocation failure. `Box of T`, `Buffer`, `Array of T`, and `String` are
owned allocator-backed values unless noted.

```meridian
let buffer = try allocBuffer(len)
let box = try allocBox(value)
let values = try allocArray(len, value)
```

`Array of T` is copied-element by default. `Array of owned T` is empty or
one-slot construction only. Bracket literals are peek `Slice of T` views,
not owned arrays:

```meridian
let nums: Slice of I32 = [1 2 3]
```

Shared helpers, function or method spelling equivalent:

```text
length empty notEmpty hasIndex hasRange
get(values, index, fallback)
front back contains count findIndex
view(values, start, len)
set swap fill          // Array only, not Slice
```

No `values[0]` indexing. `get` takes a fallback. Inequality in source is
`not x = y`.

`String` literals are owned values on static storage. Content ops in this
surface: `byteAt`, `concat`, `fromI32`, `fromI64`. No interpolation.

## 25. Generics

```meridian
type Box of T:
  value: T
end

enum Either of A B:
  Left value: A
  Right value: B
end

chooseLeft of A B(left: A, right: B) A:
  left
end
```

Single-letter uppercase names are type variables in generic declarations.
Longer uppercase names must resolve to declared types.

Group nested constructors:

```meridian
Map of String (Array of User)
```

## 26. Operators

```text
+ - * / % **
= < <= > >=
not x = y
and or not
:= += -= *= /= %=
.
1..10      exclusive end
1..=10     inclusive end
pipe
```

No `->`. No `=>`. No `!=`. No `[]` indexing.

## 27. Literals

```meridian
42
3.14
1_000_000
0xff
0b1010
"hello"
"""
line
"""
true
false
()
[1, 2, 3]
Some value
None
```

Strings are single-line with `\"`, `\\`, `\n`, `\r`, `\t`, or multiline
`"""..."""`. Map literals and owned array literals are not in this surface.

## 28. Option

```meridian
Option of String
Some "ada@example.com"
None

if user.email is Some email:
  sendEmail email
else:
  pass
end

match user.email:
  Some email:
    sendEmail email
  None:
    pass
end
```

## 29. Parallel

Accepted as a pure scoped block that currently runs sequentially.
`fork expr` is only legal inside `parallel:`. `fold` / `unfold` are reserved.

```meridian
main I32:
  parallel:
    let left = fork 20
    let right = fork 22
    left + right
  end
end
```

Event-loop runtime is not core syntax. It is a later module over signaling
and handles. No `async`, `await`, or `yield`.

## 30. Style

- two spaces
- `end` aligned with its opener
- one blank line between top-level declarations
- final-expression results
- `return` only for early exits
- named arguments when two arguments share a type
- `.field` / `it` for trivial callbacks; `do ... end` otherwise
- parentheses for nested calls
- trailing commas in multiline lists

## 31. Complete Example

```meridian
module app accounts

from std time exposing Instant
from app db users
from app email sendEmail

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

validateEmail(email: peek String) String throws CreateUserError:
  if containsAt(email):
    email
  else:
    throw InvalidEmail email
  end
end

createUser(input: CreateUser) User throws CreateUserError:
  let email = try validateEmail input.email

  if try users.exists email:
    throw DuplicateEmail email
  end

  let user = User(
    id: UserId.new()
    name: input.name
    email: email
    createdAt: Instant.now()
  )

  try users.insert user
  try sendEmail to: user.email subject: "Welcome"
  user
end

findUser(id: UserId) User throws FindUserError:
  match try users.find id:
    Some user:
      user
    None:
      throw NotFound id
  end
end

activeEmails(users: peek Array of User) Array of String:
  users
  pipe filter it.active
  pipe map .email
  pipe sort
end
```

## 32. Grammar Sketch

Sketch, not a complete grammar.

```text
file =
  packageDecl?
  moduleDecl?
  importDecl*
  topLevelDecl*

packageDecl = "package" modulePath
moduleDecl  = "module" modulePath
importDecl  = "from" identifier modulePath importSelection?
modulePath  = identifier+
importSelection = "exposing" Identifier+

topLevelDecl =
  export? (
    typeDecl | enumDecl | errorDecl | handleDecl | capabilityDecl
    | constDecl | deriveDecl | signalingDecl
    | functionDecl | receiverDecl
  )

functionDecl =
  identifier typeParamClause? parameterList? resultType?
  signalingClause? throwsClause? needsClause? requiresClause? block

receiverDecl =
  identifier "on" parameterAccess? type parameterList?
  resultType? throwsClause? needsClause? requiresClause? block

parameterList = "(" params ")"
params = param (listSeparator param)* ","?
param  = identifier ":" parameterAccess? type ("=" expression)?
parameterAccess = "peek" | "consume"
resultType = type

throwsClause     = "throws" type (listSeparator type)* ","?
signalingClause  = "signaling" Identifier+
needsClause      = "needs" identifier+
requiresClause   = "requires" (requiresEntryList | boolContractExpression)
requiresEntry    = identifier ("(" typeList? ")")? type throwsClause?

listSeparator = whitespace boundary | ","
block = ":" blockBody "end"

typeDecl =
  "owned"? layoutPrefix? "type" UpperIdentifier typeParamClause? block
layoutPrefix = "packed" | "aligned" integer | "soa"
enumDecl  = "owned"? "enum" UpperIdentifier typeParamClause? block
errorDecl = "error" UpperIdentifier block
handleDecl = "handle" UpperIdentifier
capabilityDecl = "capability" "type" UpperIdentifier block
signalingDecl = "signaling" UpperIdentifier block
constDecl = "const" identifier typeAnnotation? "=" expression
deriveDecl = "derive" ("equal" | "show") "for" UpperIdentifier
typeParamClause = "of" UpperIdentifier (listSeparator UpperIdentifier)* ","?

statement =
  letStmt | varStmt | assignment
  | ifExpr | matchExpr | forStmt | whileStmt | loopStmt
  | tryCatchExpr | throwStmt | returnStmt
  | breakStmt | continueStmt | expression

letStmt = "let" identifier typeAnnotation? "=" expression
varStmt = "var" identifier typeAnnotation? "=" expression
assignment = expression (":=" | "+=" | "-=" | "*=" | "/=" | "%=") expression

lambdaExpr = "do" lambdaParams? block
functionType = "(" typeList? ")" type throwsClause?

ifExpr =
  "if" expression ":" blockBody
  ("else if" expression ":" blockBody)*
  ("else" ":" blockBody)?
  "end"

patternIfExpr =
  "if" expression "is" pattern ":" blockBody "else" ":" blockBody "end"

matchExpr = "match" expression ":" matchArm+ "end"
matchArm  = pattern ":" blockBody

forStmt   = "for" identifier "in" expression block
whileStmt = "while" expression block
loopStmt  = "loop" block

tryCatchExpr = "try" ":" blockBody catchArm+ "end"
catchArm     = "catch" pattern ":" blockBody

signalExpr = "signal" qualifiedName argumentList?
enactExpr  = "enact" Identifier ":" blockBody enactArm+ "end"
enactArm   = "handle" qualifiedName enactParams? ":" blockBody
resumeExpr = "resume" expression
abandonExpr = "abandon" expression

usingExpr  = "using" identifier "=" expression block
contextExpr = "context" identifier "=" expression block
regionExpr = "region" identifier block

callExpr =
  expression argumentList
  | expression "(" argumentList? ")"

pipelineExpr = expression "pipe" pipelineStep
             | expression "pipe" "(" pipelineStep ("," pipelineStep)* ","? ")"

pipelineStep =
  identifier
  | identifier "(" argumentList? ")"
  | projectionExpr
  | itExpression
  | lambdaExpr

projectionExpr = "." identifier ("(" argumentList? ")")?
argument = expression | identifier ":" expression
```

## 33. Syntax Philosophy

Canonical Meridian:

```meridian
findUser(id: UserId) User throws FindUserError:
  match try users.find id:
    Some user:
      user
    None:
      throw NotFound id
  end
end
```

Not:

```rust
fn find_user(id: UserId) -> Result<User, FindUserError> {
  match users.find(id)? {
    Some(user) => Ok(user),
    None => Err(NotFound(id)),
  }
}
```

The guiding rule:

> Remove syntax that is merely traditional. Keep syntax that prevents
> ambiguity or improves scanning. Keep `end`.
