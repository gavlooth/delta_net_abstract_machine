// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module arithmetic;

import mpc;
import std::io;

fn long integer_value(String text)
{
    long value = 0;
    foreach (c : text) value = value * 10 + (long)(c - '0');
    return value;
}

fn long integer_power(long base, long exponent)
{
    long value = 1;
    while (exponent > 0)
    {
        if ((exponent & 1) != 0) value *= base;
        base *= base;
        exponent >>= 1;
    }
    return value;
}


fn long parse_primary(TokenCursor* cursor, PrecedenceTable* table)
{
    if (cursor.match("LPAREN"))
    {
        long value = parse_expression(cursor, table, 0);
        cursor.expect("RPAREN", "expected ')' after expression");
        return value;
    }
    Token* number = cursor.expect("NUMBER", "expected a number or '('");
    return number == null ? 0 : integer_value(number.text);
}

fn long apply_operator(String kind, long left, long right)
{
    if (kind == "PLUS") return left + right;
    if (kind == "MINUS") return left - right;
    if (kind == "STAR") return left * right;
    if (kind == "SLASH") return left / right;
    return integer_power(left, right);
}

fn long parse_expression(TokenCursor* cursor, PrecedenceTable* table,
                         int minimum_power)
{
    long left = parse_primary(cursor, table);
    while (true)
    {
        Token* next = cursor.peek();
        if (next == null) break;
        OperatorSpec* spec = table.lookup(next.kind);
        if (spec == null) break;
        BindingPower power = spec.binding_power();
        if (power.left < minimum_power) break;
        cursor.advance();
        long right = parse_expression(cursor, table, power.right);
        left = apply_operator(spec.token_kind, left, right);
    }
    return left;
}

fn int main()
{
    ParserArena arena;
    arena.init(mem);
    defer arena.deinit();

    LexerRule[9] rules = {
        mpc::regex_token("TRIVIA", `[ \t\r\n]+`, ignored: true),
        mpc::regex_token("NUMBER", `[0-9]+`),
        mpc::literal_token("PLUS", "+"),
        mpc::literal_token("MINUS", "-"),
        mpc::literal_token("STAR", "*"),
        mpc::literal_token("SLASH", "/"),
        mpc::literal_token("POWER", "^"),
        mpc::literal_token("LPAREN", "("),
        mpc::literal_token("RPAREN", ")"),
    };
    LexerCompileResult compiled = mpc::compile_lexer(&arena, rules[..]);
    defer compiled.deinit();
    if (!compiled.ok())
    {
        io::printn("could not compile arithmetic lexer");
        return 1;
    }

    String input = "2 + 3 * 4 ^ 2";
    LexResult lexed = compiled.lexer.lex(input);
    defer lexed.deinit();
    if (!lexed.ok())
    {
        foreach (&diagnostic : lexed.diagnostics)
        {
            DString rendered = mpc::render_diagnostic(diagnostic, "arithmetic", input);
            io::print(rendered.str_view());
            rendered.free();
        }
        return 1;
    }

    OperatorSpec[5] operators = {
        { .token_kind = "PLUS", .precedence = 10, .associativity = LEFT },
        { .token_kind = "MINUS", .precedence = 10, .associativity = LEFT },
        { .token_kind = "STAR", .precedence = 20, .associativity = LEFT },
        { .token_kind = "SLASH", .precedence = 20, .associativity = LEFT },
        { .token_kind = "POWER", .precedence = 30, .associativity = RIGHT },
    };
    PrecedenceTable table;
    table.init(operators[..]);
    SourcePos end = { .offset = (sz)input.len, .row = 1,
                      .column = (sz)input.len + 1 };
    TokenCursor cursor;
    cursor.init(lexed.tokens.array_view(), end);
    defer cursor.deinit();
    long value = parse_expression(&cursor, &table, 0);
    if (!cursor.at_end()) cursor.expect("end of input");
    if (cursor.diagnostics.len() > 0)
    {
        foreach (&diagnostic : cursor.diagnostics)
        {
            DString rendered = mpc::render_diagnostic(diagnostic, "arithmetic", input);
            io::print(rendered.str_view());
            rendered.free();
        }
        return 1;
    }

    io::printfn("%s = %d", input, value);
    return 0;
}
