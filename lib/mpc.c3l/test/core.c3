// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module mpc;

import std::core::mem;

fn void primitives_and_prefix_positions() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();
	Parser*[4] pieces = {
		arena.soi(), arena.range('a', 'z'), arena.one_of("0123456789"), arena.none_of("!")
	};
	Parser* parser = arena.sequence(pieces[..]);
	ParseResult result = parse(parser, "q7x-rest", mem);
	defer result.deinit();
	assert(result.ok);
	assert(result.consumed.end.offset == 3);
	assert(result.consumed.end.row == 1);
	assert(result.consumed.end.column == 4);
	assert(result.root.child_count() == 3);
	assert(result.root.text == "q7x");
}

fn void ordered_choice_backtracks_sequences() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();
	Parser*[2] first_parts = { arena.literal("ab"), arena.literal("x") };
	Parser*[2] second_parts = { arena.literal("ab"), arena.literal("c") };
	Parser*[2] alternatives = { arena.sequence(first_parts[..]), arena.sequence(second_parts[..]) };
	ParseResult result = parse(arena.choice(alternatives[..]), "abc", mem);
	defer result.deinit();
	assert(result.ok);
	assert(result.consumed.end.offset == 3);
	assert(result.root.text_is("abc"));
}

fn void furthest_error_tracks_line_and_expectation() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();
	Parser*[2] long_parts = { arena.literal("a\n"), arena.expect(arena.character('x'), "letter x") };
	Parser*[2] short_parts = { arena.literal("a"), arena.expect(arena.character('y'), "letter y") };
	Parser*[2] alternatives = { arena.sequence(long_parts[..]), arena.sequence(short_parts[..]) };
	ParseResult result = parse(arena.choice(alternatives[..]), "a\nz", mem, "positions");
	defer result.deinit();
	assert(!result.ok);
	assert(result.diagnostic.span.start.offset == 2);
	assert(result.diagnostic.span.start.row == 2);
	assert(result.diagnostic.span.start.column == 1);
	assert(result.diagnostic.expected.len == 1);
	assert(result.diagnostic.expected[0] == "letter x");
}

fn void repetitions_count_and_no_progress_guard() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();
	{
		ParseResult result = parse(arena.many(arena.character('a')), "aaab", mem);
		defer result.deinit();
		assert(result.ok && result.consumed.end.offset == 3);
		assert(result.root.child_count() == 3);
	}
	{
		ParseResult result = parse(arena.count(arena.range('0', '9'), 3), "123x", mem);
		defer result.deinit();
		assert(result.ok && result.consumed.end.offset == 3);
	}
	{
		ParseResult result = parse(arena.many(arena.pass()), "anything", mem);
		defer result.deinit();
		assert(result.ok && result.consumed.end.offset == 0);
	}
	{
		ParseResult result = parse(arena.many1(arena.pass()), "anything", mem);
		defer result.deinit();
		assert(!result.ok);
	}
}

fn void lookahead_and_negative_lookahead_are_zero_width() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();
	Parser*[3] parts = {
		arena.lookahead(arena.literal("let")),
		arena.literal("let"),
		arena.not_followed_by(arena.range('a', 'z')),
	};
	ParseResult good = parse(arena.sequence(parts[..]), "let ", mem);
	defer good.deinit();
	assert(good.ok && good.consumed.end.offset == 3);
	ParseResult bad = parse(arena.sequence(parts[..]), "letter", mem);
	defer bad.deinit();
	assert(!bad.ok);
	assert(bad.diagnostic.span.start.offset == 3);
}

fn void token_whole_between_and_separated_values() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();
	Parser* word = arena.token(arena.many1(arena.range('a', 'z')));
	Parser* comma = arena.token(arena.character(','));
	Parser* list = arena.sep_by(word, comma, false);
	Parser* bracketed = arena.between(arena.token(arena.character('[')), list, arena.character(']'));
	ParseResult result = parse(arena.whole(bracketed), "[one, two,three]  \n", mem);
	defer result.deinit();
	assert(result.ok);
	assert(result.consumed.end.offset == 19);
	assert(result.root.child_count() == 3);
	assert(result.root.child(1).text == "two");
}

fn void recursive_rules_build_named_ast() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();
	Parser* expression = arena.rule("expression");
	Parser* atom = arena.literal("x").named("atom");
	Parser* nested = arena.between(arena.character('('), expression, arena.character(')'));
	Parser*[2] forms = { atom, nested };
	expression.set_rule(arena.choice(forms[..]));
	ParseResult result = parse(arena.whole(expression), "((x))", mem);
	defer result.deinit();
	assert(result.ok);
	assert(result.root.tag == "expression");
	assert(result.root.find("atom"));
	assert(result.root.find("atom").text == "x");
	assert(result.root.span.length() == 5);
}

fn void prefix_match_and_deterministic_cleanup() @test
{
	ParserArena arena;
	arena.init(mem);
	Parser* parser = arena.literal("hello");
	sz consumed;
	assert(match_prefix(parser, "hello world", &consumed));
	assert(consumed == 5);
	assert(!match_prefix(parser, "help", &consumed));
	assert(consumed == 0);
	ParseResult result = parse(parser, "hello", mem);
	assert(result.ok && result.root.is_leaf());
	result.deinit();
	assert(!result.allocator);
	assert(!result.root);
	arena.deinit();
	assert(!arena.allocator);
}

fn void spans_are_half_open() @test
{
	Span span = {
		.start = { .offset = 2, .row = 1, .column = 3 },
		.end = { .offset = 5, .row = 1, .column = 6 },
	};
	assert(span.contains({ .offset = 2 }));
	assert(span.contains({ .offset = 4 }));
	assert(!span.contains({ .offset = 5 }), "a half-open span excludes its end");
}
