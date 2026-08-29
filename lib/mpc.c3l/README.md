# Micro Parser Combinators for C3

`mpc` is an allocator-aware parser toolkit for C3 0.8.3 (`langrev` 1). It provides parser combinators, recursive named rules, regular-expression compilation, a declarative grammar compiler, owned AST and diagnostic results, and practical lexer and language-authoring utilities.

## Features

- Ordered parser choice with backtracking and furthest-error diagnostics
- Sequence, repetition, lookahead, token, whole-input, and separator combinators
- Named recursive rules
- Regular-expression compilation with multiline and dot-all options
- Declarative grammar compilation with forward references
- Source positions, spans, AST nodes, traversal, and diagnostic rendering
- Maximal-munch lexers with ordered ties, ignored trivia, and keyword precedence
- Token cursors and expression precedence/associativity helpers
- Explicit allocators and deterministic `deinit` methods for owning values

## Build and run

The repository is a C3 project; no C source is used by its build targets.

```sh
c3c build mpc
c3c test mpc
c3c run arithmetic
c3c run json
```

`mpc` is the static-library target. `arithmetic` and `json` are runnable examples in `examples/`.

## Quick start

The grammar compiler accepts named statements, literals, regexes, rule references, grouping, ordered alternatives, and postfix repetition operators.

```c3
module example;

import mpc;
import std::io;

fn int main()
{
    String grammar = `
        expression: <product> (("+" | "-") <product>)*;
        product: <value> (("*" | "/") <value>)*;
        value ["number or parenthesized expression"]:
            /[0-9]+/ | "(" <expression> ")";
    `;

    LanguageCompileResult compiled = mpc::compile_language(grammar, mem);
    defer compiled.deinit();
    if (!compiled.ok()) return 1;

    String input = "(4 * 2 + 11) - 5";
    ParseResult result = compiled.language.parse(input, mem, "expression",
                                                  "example");
    defer result.deinit();
    if (!result.ok)
    {
        DString message = mpc::render_diagnostic(&result.diagnostic,
                                                  "example", input);
        defer message.free();
        io::print(message.str_view());
        return 1;
    }

    AstNode* first_value = result.root.find("value");
    if (first_value != null) io::printn(first_value.text);
    return 0;
}
```

`LanguageCompileResult` owns its compiled `Language` unless it is transferred with `take_language`. `ParseResult` owns its copied source data, AST, and diagnostic. Keep each corresponding `deinit` in scope.

## Parser combinators

Create parsers in a `ParserArena`; the arena owns every parser it constructs.

```c3
ParserArena arena;
arena.init(mem);
defer arena.deinit();

Parser* digit = arena.range('0', '9');
Parser* integer = arena.many1(digit).named("integer");
Parser* signed_parts[2] = { arena.optional(arena.character('-')), integer };
Parser* signed_integer = arena.sequence(signed_parts[..]);
Parser* parser = arena.whole(signed_integer);

ParseResult result = mpc::parse(parser, "-42", mem, "input");
defer result.deinit();
```

Primitive constructors include `any_char`, `character`, `range`, `one_of`, `none_of`, `literal`, `soi`, `eoi`, `pass`, and `fail`. Combinators include `expect`, `sequence`, `choice`, `predictive_choice`, `optional`, `many`, `many1`, `count`, `sep_by`, `lookahead`, `not_followed_by`, `token`, `whole`, and `between`. Use `arena.rule` followed by `Parser.set_rule` for recursion.

Parser choice is ordered. A failed branch restores its input position before the next branch runs. Repetition rejects a successful iteration that consumes no input.

## Regular expressions

```c3
RegexCompileResult regex = mpc::compile_regex(&arena, `[A-Za-z_][A-Za-z0-9_]*`,
                                              { .multiline = false,
                                                .dotall = false });
defer regex.deinit();
if (!regex.ok()) return 1;
```

Supported syntax includes ordered alternation, groups, character classes and ranges, negated classes, `.`, `^`, `$`, `*`, `+`, `?`, exact `{n}` repetition, standard/control escapes, and the `dDsSwWbBAZ` escapes.

## Declarative grammars

A grammar statement has this form:

```text
name ["expected description"]: expression;
```

Expressions support quoted literals, `/regex/ms`, `<rule>` references, grouping, `|`, and postfix `*`, `+`, `?`, `!`, and `{n}`. Forward and recursive references are resolved during compilation. `GrammarOptions` controls whitespace sensitivity and predictive choice. Invalid grammars return structured compile diagnostics; they are not converted into parsers which fail later.

Use `Language.rule(name)` for a prefix parser, `Language.full_rule(name)` for a whole-input parser, or `Language.parse` for a named whole-input parse.

## Lexer utilities

Lexer rules are explicit slices rather than variadic arguments:

```c3
LexerRule[4] rules = {
    mpc::regex_token("TRIVIA", `[ \t\r\n]+`, ignored: true),
    mpc::keyword_token("LET", "let"),
    mpc::regex_token("IDENT", `[A-Za-z_][A-Za-z0-9_]*`),
    mpc::literal_token("EQUAL", "="),
};
LexerCompileResult lexer = mpc::compile_lexer(&arena, rules[..], mem);
defer lexer.deinit();
```

At each position the longest rule match wins. Declaration order breaks equal-length ties, so placing a keyword before an identifier makes `let` a keyword while `letter` remains an identifier. Ignored rules still advance source positions but do not produce tokens.

`Token` contains `kind`, borrowed `text`, and `span`. `LexResult` owns token and diagnostic lists while token text borrows the input and token kinds borrow the compiled lexer. `TokenCursor` provides `peek`, `advance`, `check`, `match`, and diagnostic-producing `expect`.

## ASTs and diagnostics

`AstNode` contains `tag`, `text`, `span`, and child pointers. It provides child access, leaf checks, tag lookup, and text comparison. `walk_ast` visits nodes in `PREORDER` or `POSTORDER`; `find_all_ast` returns an owning list of borrowed matching nodes.

`SourcePos` uses a zero-based byte offset and one-based row and column; `Span` is half-open. `render_diagnostic` displays the location, source line, a caret range, and expected items.

## Expression parsing

`PrecedenceTable` maps token kinds to `OperatorSpec` values. Each operator records its precedence and `LEFT`, `RIGHT`, or `NON_ASSOCIATIVE` associativity. `binding_power` supports Pratt/precedence-climbing parsers; `should_reduce` and `may_chain` support shunting-yard parsers. See `examples/arithmetic.c3` for a complete evaluator.

## Ownership

- `ParserArena.deinit` releases all parsers created by that arena.
- Compile results own their diagnostics; language compile results also own the language until transferred.
- `ParseResult.deinit` releases its source copies, AST, and diagnostic.
- `LexerCompileResult`, `LexResult`, and `TokenCursor` each release their own lists and diagnostics with `deinit`.
- Lists returned by `find_all_ast` must be freed by the caller; the nodes remain owned by their parse result.

## Upstream and license

This project is a C3 port of Daniel Holden's
[`orangeduck/mpc`](https://github.com/orangeduck/mpc). The original copyright
and license are retained.

Copyright (c) 2013 Daniel Holden. C3 port modifications are copyright (c) 2026
mpc contributors. The project is distributed under the BSD 2-Clause FreeBSD
license; see [`LICENSE.md`](LICENSE.md) for the complete terms.
