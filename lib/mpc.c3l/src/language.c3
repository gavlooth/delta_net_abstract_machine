// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module mpc;

import std::collections::list;
import std::core::mem;
import std::io;

/** A lexer rule is either an exact literal or a regular expression. */
enum LexerMatcher : char
{
    LEX_LITERAL,
    LEX_REGEX,
}

/**
 * Declarative lexer rule. Rules are borrowed by compile_lexer for the duration
 * of that call; the compiled parser is owned by the supplied ParserArena.
 */
struct LexerRule
{
    String kind;
    String pattern;
    LexerMatcher matcher;
    RegexOptions regex_options;
    bool ignored;
}

fn LexerRule literal_token(String kind, String literal, bool ignored = false)
{
    return {
        .kind = kind,
        .pattern = literal,
        .matcher = LEX_LITERAL,
        .ignored = ignored,
    };
}

fn LexerRule regex_token(String kind, String pattern, bool ignored = false,
                         RegexOptions options = {})
{
    return {
        .kind = kind,
        .pattern = pattern,
        .matcher = LEX_REGEX,
        .regex_options = options,
        .ignored = ignored,
    };
}

/** Convenience constructor; place keywords before the identifier rule. */
fn LexerRule keyword_token(String kind, String literal)
{
    return literal_token(kind, literal);
}

struct CompiledLexerRule
{
    String kind;
    Parser* parser;
    bool ignored;
}

/** A compiled, reusable ordered lexer. Parser storage remains arena-owned. */
struct Lexer
{
    Allocator allocator;
    ParserArena* arena;
    List{CompiledLexerRule} rules;
}

fn void Lexer.deinit(Lexer* self)
{
    foreach (&rule : self.rules) alloc::free(self.allocator, rule.kind);
    self.rules.free();
    self.arena = null;
}

struct LexerCompileResult
{
    Lexer lexer;
    List{Diagnostic} diagnostics;
}

fn bool LexerCompileResult.ok(LexerCompileResult* self)
{
    return self.diagnostics.len() == 0;
}

fn void LexerCompileResult.deinit(LexerCompileResult* self)
{
    foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
    self.diagnostics.free();
    self.lexer.deinit();
}

fn Diagnostic copy_diagnostic(Diagnostic* source, Allocator allocator) @private
{
    Diagnostic copy;
    copy.init(allocator, source.message, source.span);
    foreach (expected : source.expected) copy.add_expected(expected);
    return copy;
}

fn void add_lexer_compile_error(List{Diagnostic}* diagnostics,
                                Allocator allocator, String message) @private
{
    SourcePos position = source_start();
    Span span = { .start = position, .end = position };
    Diagnostic diagnostic;
    diagnostic.init(allocator, message, span);
    diagnostics.push(diagnostic);
}

/**
 * Compile literal and regex rules once. At a given input position the longest
 * match wins; equal-length matches retain declaration order. Consequently a
 * keyword placed before an identifier wins only for an exact-length tie.
 */
fn LexerCompileResult compile_lexer(ParserArena* arena, LexerRule[] rules,
                                    Allocator allocator = mem)
{
    LexerCompileResult result;
    result.lexer.allocator = allocator;
    result.lexer.arena = arena;
    result.lexer.rules.init(allocator, rules.len);
    result.diagnostics.init(allocator);

    foreach (rule : rules)
    {
        Parser* parser = null;
        if (rule.matcher == LEX_LITERAL)
        {
            if (rule.pattern.len == 0)
            {
                add_lexer_compile_error(&result.diagnostics, allocator,
                                        "literal lexer rules may not be empty");
                continue;
            }
            parser = arena.literal(rule.pattern);
        }
        else
        {
            RegexCompileResult regex = compile_regex(arena, rule.pattern,
                                                      rule.regex_options);
            if (!regex.ok())
            {
                foreach (&diagnostic : regex.diagnostics)
                {
                    result.diagnostics.push(copy_diagnostic(diagnostic,
                                                            allocator));
                }
                regex.deinit();
                continue;
            }
            parser = regex.parser;
            regex.deinit();
        }

        sz empty_length = 0;
        if (match_prefix(parser, "", &empty_length) && empty_length == 0)
        {
            add_lexer_compile_error(&result.diagnostics, allocator,
                                    "lexer rules may not match empty input");
            continue;
        }

        result.lexer.rules.push({
            .kind = rule.kind.copy(allocator),
            .parser = parser,
            .ignored = rule.ignored,
        });
    }

    return result;
}

struct Token
{
    String kind;
    String text;
    Span span;
}

fn bool Token.is(Token* self, String kind)
{
    return strings_equal(self.kind, kind);
}

/** Tokens borrow their text from the input supplied to Lexer.lex. */
struct LexResult
{
    Allocator allocator;
    List{Token} tokens;
    List{Diagnostic} diagnostics;
}

fn bool LexResult.ok(LexResult* self)
{
    return self.diagnostics.len() == 0;
}

fn void LexResult.deinit(LexResult* self)
{
    foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
    self.diagnostics.free();
    self.tokens.free();
}

fn bool strings_equal(String left, String right) @private
{
    if (left.len != right.len) return false;
    for (usz i = 0; i < left.len; i++)
    {
        if (left[i] != right[i]) return false;
    }
    return true;
}

fn void advance_source_position(SourcePos* position, String text) @private
{
    foreach (c : text)
    {
        position.offset++;
        if (c == '\n')
        {
            position.row++;
            position.column = 1;
        }
        else
        {
            position.column++;
        }
    }
}

fn void add_lexical_error(LexResult* result, SourcePos start,
                          SourcePos end) @private
{
    Diagnostic diagnostic;
    diagnostic.init(result.allocator, "no lexer rule matches this input",
                    { .start = start, .end = end });
    result.diagnostics.push(diagnostic);
}

/** Lex all input using maximal munch with ordered ties. */
fn LexResult Lexer.lex(Lexer* self, String input)
{
    LexResult result;
    result.allocator = self.allocator;
    result.tokens.init(self.allocator);
    result.diagnostics.init(self.allocator);

    SourcePos position = source_start();
    while ((usz)position.offset < input.len)
    {
        usz offset = (usz)position.offset;
        String remaining = input[offset:input.len - offset];
        sz best_rule = -1;
        sz best_length = 0;

        for (sz i = 0; i < self.rules.len(); i++)
        {
            sz consumed = 0;
            if (match_prefix(self.rules[i].parser, remaining, &consumed) &&
                consumed > best_length)
            {
                best_rule = (sz)i;
                best_length = consumed;
            }
        }

        if (best_rule < 0)
        {
            SourcePos start = position;
            advance_source_position(&position, input[offset:1]);
            add_lexical_error(&result, start, position);
            continue;
        }

        SourcePos start = position;
        String text = input[offset:(usz)best_length];
        advance_source_position(&position, text);
        CompiledLexerRule* rule = &self.rules[(usz)best_rule];
        if (!rule.ignored)
        {
            result.tokens.push({
                .kind = rule.kind,
                .text = text,
                .span = { .start = start, .end = position },
            });
        }
    }

    return result;
}

/** A lightweight cursor over an existing token slice. */
struct TokenCursor
{
    Allocator allocator;
    Token[] tokens;
    sz index;
    SourcePos eof_position;
    List{Diagnostic} diagnostics;
}

fn void TokenCursor.init(TokenCursor* self, Token[] tokens,
                         SourcePos eof_position, Allocator allocator = mem)
{
    self.allocator = allocator;
    self.tokens = tokens;
    self.index = 0;
    self.eof_position = eof_position;
    self.diagnostics.init(allocator);
}

fn void TokenCursor.deinit(TokenCursor* self)
{
    foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
    self.diagnostics.free();
}

fn bool TokenCursor.at_end(TokenCursor* self)
{
    return (usz)self.index >= self.tokens.len;
}

fn Token* TokenCursor.peek(TokenCursor* self, sz distance = 0)
{
    sz at = self.index + distance;
    if (at < 0 || (usz)at >= self.tokens.len) return null;
    return &self.tokens[(usz)at];
}

fn Token* TokenCursor.advance(TokenCursor* self)
{
    Token* token = self.peek();
    if (token != null) self.index++;
    return token;
}

fn bool TokenCursor.check(TokenCursor* self, String kind)
{
    Token* token = self.peek();
    return token != null && token.is(kind);
}

fn bool TokenCursor.match(TokenCursor* self, String kind)
{
    if (!self.check(kind)) return false;
    self.index++;
    return true;
}

fn Token* TokenCursor.expect(TokenCursor* self, String kind,
                             String message = "unexpected token")
{
    Token* token = self.peek();
    if (token != null && token.is(kind))
    {
        self.index++;
        return token;
    }

    Span span;
    if (token == null)
    {
        span = { .start = self.eof_position, .end = self.eof_position };
    }
    else
    {
        span = token.span;
    }
    Diagnostic diagnostic;
    diagnostic.init(self.allocator, message, span);
    diagnostic.add_expected(kind);
    self.diagnostics.push(diagnostic);
    return null;
}

fn void append_decimal(DString* output, sz value) @private
{
    char[32] buffer;
    String number = (String)io::bprintf(&buffer, "%d", (long)value)!!;
    output.append_string(number);
}

/**
 * Render a diagnostic as location, source line, caret range, and expectations.
 * Source positions use zero-based byte offsets and one-based rows/columns.
 */
fn DString render_diagnostic(Diagnostic* diagnostic, String source_name,
                             String source, Allocator allocator = mem)
{
    DString output;
    output.init(allocator);
    output.append_string(source_name);
    output.append_char(':');
    append_decimal(&output, diagnostic.span.start.row);
    output.append_char(':');
    append_decimal(&output, diagnostic.span.start.column);
    output.append_string(": ");
    output.append_string(diagnostic.message);
    output.append_char('\n');

    usz offset = diagnostic.span.start.offset < 0
        ? 0 : (usz)diagnostic.span.start.offset;
    if (offset > source.len) offset = source.len;
    usz line_start = offset;
    while (line_start > 0 && source[line_start - 1] != '\n') line_start--;
    usz line_end = offset;
    while (line_end < source.len && source[line_end] != '\n') line_end++;
    if (line_end > line_start)
    {
        output.append_string(source[line_start:line_end - line_start]);
    }
    output.append_char('\n');

    for (usz i = line_start; i < offset; i++)
    {
        output.append_char(source[i] == '\t' ? '\t' : ' ');
    }
    sz width = diagnostic.span.end.offset - diagnostic.span.start.offset;
    if (width < 1) width = 1;
    usz available = line_end > offset ? line_end - offset : 1;
    if ((usz)width > available) width = (sz)available;
    for (sz i = 0; i < width; i++) output.append_char('^');
    output.append_char('\n');

    if (diagnostic.expected.len > 0)
    {
        output.append_string("expected: ");
        for (usz i = 0; i < diagnostic.expected.len; i++)
        {
            if (i > 0) output.append_string(", ");
            output.append_string(diagnostic.expected[i]);
        }
        output.append_char('\n');
    }
    return output;
}

/** AST traversal order for walk_ast. */
enum AstWalkOrder : char
{
    PREORDER,
    POSTORDER,
}

alias AstVisitor = fn void(AstNode* node, void* context);

fn void walk_ast(AstNode* node, AstWalkOrder order, AstVisitor visitor,
                 void* context = null)
{
    if (node == null) return;
    if (order == PREORDER) visitor(node, context);
    foreach (child : node.children) walk_ast(child, order, visitor, context);
    if (order == POSTORDER) visitor(node, context);
}

fn void collect_ast_tag(AstNode* node, String tag,
                        List{AstNode*}* matches) @private
{
    if (node == null) return;
    if (strings_equal(node.tag, tag)) matches.push(node);
    foreach (child : node.children) collect_ast_tag(child, tag, matches);
}

/** Return an owning list of borrowed nodes matching tag in preorder. */
fn List{AstNode*} find_all_ast(AstNode* root, String tag,
                              Allocator allocator = mem)
{
    List{AstNode*} matches;
    matches.init(allocator);
    collect_ast_tag(root, tag, &matches);
    return matches;
}

enum Associativity : char
{
    LEFT,
    RIGHT,
    NON_ASSOCIATIVE,
}

struct OperatorSpec
{
    String token_kind;
    int precedence;
    Associativity associativity;
}

struct BindingPower
{
    int left;
    int right;
}

/** Borrowed operator table for Pratt or shunting-yard expression parsers. */
struct PrecedenceTable
{
    OperatorSpec[] operators;
}

fn void PrecedenceTable.init(PrecedenceTable* self, OperatorSpec[] operators)
{
    self.operators = operators;
}

fn OperatorSpec* PrecedenceTable.lookup(PrecedenceTable* self,
                                        String token_kind)
{
    for (usz i = 0; i < self.operators.len; i++)
    {
        if (strings_equal(self.operators[i].token_kind, token_kind))
        {
            return &self.operators[i];
        }
    }
    return null;
}

/** Binding powers for a precedence-climbing/Pratt parser. */
fn BindingPower OperatorSpec.binding_power(OperatorSpec* self)
{
    return {
        .left = self.precedence,
        .right = self.associativity == RIGHT
            ? self.precedence : self.precedence + 1,
    };
}

/** Whether a shunting-yard parser should reduce stack before incoming. */
fn bool should_reduce(OperatorSpec* stack, OperatorSpec* incoming)
{
    if (stack.precedence > incoming.precedence) return true;
    if (stack.precedence < incoming.precedence) return false;
    return incoming.associativity != RIGHT;
}

/** Non-associative operators of equal precedence may not be chained. */
fn bool may_chain(OperatorSpec* left, OperatorSpec* right)
{
    if (left.precedence != right.precedence) return true;
    return left.associativity != NON_ASSOCIATIVE &&
           right.associativity != NON_ASSOCIATIVE;
}
