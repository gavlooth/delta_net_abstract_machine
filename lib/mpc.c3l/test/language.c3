// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module mpc;

import std::collections::list;

fn bool test_string_equal(String left, String right)
{
    if (left.len != right.len) return false;
    for (usz i = 0; i < left.len; i++) if (left[i] != right[i]) return false;
    return true;
}

fn bool test_contains(String text, String needle)
{
    if (needle.len > text.len) return false;
    for (usz i = 0; i + needle.len <= text.len; i++)
    {
        bool found = true;
        for (usz j = 0; j < needle.len; j++)
        {
            if (text[i + j] != needle[j])
            {
                found = false;
                break;
            }
        }
        if (found) return true;
    }
    return false;
}

fn void lexer_uses_maximal_munch_ordered_ties_keywords_and_spans() @test
{
    ParserArena arena;
    arena.init(mem);
    defer arena.deinit();

    LexerRule[5] rules = {
        regex_token("TRIVIA", `[ \t\n]+`, ignored: true),
        keyword_token("IF", "if"),
        regex_token("IDENT", `[A-Za-z_][A-Za-z0-9_]*`),
        literal_token("EQEQ", "=="),
        literal_token("EQ", "="),
    };
    LexerCompileResult compiled = compile_lexer(&arena, rules[..], mem);
    defer compiled.deinit();
    assert(compiled.ok());

    String input = "if ifx == =\nfoo";
    LexResult result = compiled.lexer.lex(input);
    defer result.deinit();
    assert(result.ok());
    assert(result.tokens.len() == 5);
    assert(result.tokens[0].is("IF"));
    assert(test_string_equal(result.tokens[0].text, "if"));
    assert(result.tokens[1].is("IDENT"));
    assert(test_string_equal(result.tokens[1].text, "ifx"));
    assert(result.tokens[2].is("EQEQ"));
    assert(result.tokens[3].is("EQ"));
    assert(result.tokens[4].is("IDENT"));

    assert(result.tokens[0].span.start.offset == 0);
    assert(result.tokens[1].span.start.column == 4);
    assert(result.tokens[2].span.start.column == 8);
    assert(result.tokens[4].span.start.row == 2);
    assert(result.tokens[4].span.start.column == 1);
    assert(result.tokens[4].span.end.column == 4);
}

fn void lexer_declaration_order_breaks_equal_length_ties() @test
{
    ParserArena arena;
    arena.init(mem);
    defer arena.deinit();

    LexerRule[2] rules = {
        regex_token("WORD", `[a-z]+`),
        keyword_token("LET", "let"),
    };
    LexerCompileResult compiled = compile_lexer(&arena, rules[..]);
    defer compiled.deinit();
    assert(compiled.ok());

    LexResult result = compiled.lexer.lex("let");
    defer result.deinit();
    assert(result.ok());
    assert(result.tokens.len() == 1);
    assert(result.tokens[0].is("WORD"));
}

fn void lexer_reports_unmatched_input_and_continues() @test
{
    ParserArena arena;
    arena.init(mem);
    defer arena.deinit();

    LexerRule[1] rules = { regex_token("NUMBER", `[0-9]+`) };
    LexerCompileResult compiled = compile_lexer(&arena, rules[..]);
    defer compiled.deinit();
    assert(compiled.ok());

    LexResult result = compiled.lexer.lex("1@2");
    defer result.deinit();
    assert(!result.ok());
    assert(result.tokens.len() == 2);
    assert(result.diagnostics.len() == 1);
    assert(result.diagnostics[0].span.start.offset == 1);
    assert(result.diagnostics[0].span.end.offset == 2);
}

fn void empty_matching_lexer_rules_are_compile_errors() @test
{
    ParserArena arena;
    arena.init(mem);
    defer arena.deinit();

    LexerRule[1] rules = { regex_token("EMPTY", `a*`) };
    LexerCompileResult compiled = compile_lexer(&arena, rules[..]);
    defer compiled.deinit();
    assert(!compiled.ok());
    assert(compiled.diagnostics.len() == 1);
}

fn void token_cursor_peeks_matches_and_records_expect_errors() @test
{
    Token[2] tokens = {
        {
            .kind = "NUMBER",
            .text = "12",
            .span = {
                .start = { .offset = 0, .row = 1, .column = 1 },
                .end = { .offset = 2, .row = 1, .column = 3 },
            },
        },
        {
            .kind = "PLUS",
            .text = "+",
            .span = {
                .start = { .offset = 2, .row = 1, .column = 3 },
                .end = { .offset = 3, .row = 1, .column = 4 },
            },
        },
    };
    TokenCursor cursor;
    cursor.init(tokens[..], { .offset = 3, .row = 1, .column = 4 });
    defer cursor.deinit();

    assert(cursor.peek().is("NUMBER"));
    assert(cursor.check("NUMBER"));
    assert(cursor.match("NUMBER"));
    assert(cursor.expect("PLUS") != null);
    assert(cursor.at_end());
    assert(cursor.expect("NUMBER", "expected an operand") == null);
    assert(cursor.diagnostics.len() == 1);
    assert(cursor.diagnostics[0].span.start.offset == 3);
    assert(cursor.diagnostics[0].expected.len == 1);
    assert(test_string_equal(cursor.diagnostics[0].expected[0], "NUMBER"));
}

fn void diagnostic_renderer_shows_location_line_caret_and_expected() @test
{
    Diagnostic diagnostic;
    diagnostic.init(mem, "unexpected value", {
        .start = { .offset = 8, .row = 2, .column = 3 },
        .end = { .offset = 10, .row = 2, .column = 5 },
    });
    defer diagnostic.deinit();
    diagnostic.add_expected("number");

    DString rendered = render_diagnostic(&diagnostic, "sample", "alpha\nbeta\ngamma");
    defer rendered.free();
    String text = rendered.str_view();
    assert(test_contains(text, "sample:2:3: unexpected value"));
    assert(test_contains(text, "beta\n  ^^"));
    assert(test_contains(text, "expected: number"));
}

fn void record_ast_visit(AstNode* node, void* context)
{
    List{String}* tags = (List{String}*)context;
    tags.push(node.tag);
}

fn void ast_walk_supports_preorder_postorder_and_queries() @test
{
    AstNode left = { .tag = "leaf", .text = "1" };
    AstNode right = { .tag = "leaf", .text = "2" };
    AstNode*[2] children = { &left, &right };
    AstNode root = { .tag = "sum", .text = "1+2", .children = children[..] };

    List{String} preorder;
    preorder.init(mem);
    defer preorder.free();
    walk_ast(&root, PREORDER, &record_ast_visit, &preorder);
    assert(preorder.len() == 3);
    assert(test_string_equal(preorder[0], "sum"));
    assert(test_string_equal(preorder[1], "leaf"));

    List{String} postorder;
    postorder.init(mem);
    defer postorder.free();
    walk_ast(&root, POSTORDER, &record_ast_visit, &postorder);
    assert(postorder.len() == 3);
    assert(test_string_equal(postorder[0], "leaf"));
    assert(test_string_equal(postorder[2], "sum"));

    List{AstNode*} leaves = find_all_ast(&root, "leaf");
    defer leaves.free();
    assert(leaves.len() == 2);
    assert(leaves[0] == &left);
    assert(leaves[1] == &right);
}

fn void precedence_helpers_encode_left_right_and_non_associativity() @test
{
    OperatorSpec[3] operators = {
        { .token_kind = "MINUS", .precedence = 10, .associativity = LEFT },
        { .token_kind = "POW", .precedence = 20, .associativity = RIGHT },
        { .token_kind = "LT", .precedence = 5, .associativity = NON_ASSOCIATIVE },
    };
    PrecedenceTable table;
    table.init(operators[..]);

    OperatorSpec* minus = table.lookup("MINUS");
    OperatorSpec* power = table.lookup("POW");
    OperatorSpec* less = table.lookup("LT");
    assert(minus != null && power != null && less != null);
    assert(should_reduce(minus, minus));
    assert(!should_reduce(power, power));
    assert(should_reduce(power, minus));
    assert(!should_reduce(minus, power));

    BindingPower left = minus.binding_power();
    BindingPower right = power.binding_power();
    assert(left.left == 10 && left.right == 11);
    assert(right.left == 20 && right.right == 20);
    assert(!may_chain(less, less));
}
