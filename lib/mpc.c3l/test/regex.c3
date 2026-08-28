// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module mpc;

import std::core::mem;

fn Parser* test_regex(ParserArena* arena, String pattern, RegexOptions options = {})
{
	RegexCompileResult compiled = compile_regex(arena, pattern, options);
	assert(compiled.ok(), "regular expression should compile");
	Parser* parser = compiled.parser;
	compiled.deinit();
	return parser;
}

fn void assert_regex_match(Parser* parser, String input, String expected)
{
	ParseResult parsed = parse(parser, input, mem, "<regex-test>");
	defer parsed.deinit();
	assert(parsed.ok, "regular expression should match");
	assert(parsed.consumed.length() == expected.len, "match should consume the expected number of bytes");
	String consumed = input[parsed.consumed.start.offset : parsed.consumed.length()];
	assert(consumed == expected, "regular expression should consume the expected text");
}

fn void assert_regex_full_match(ParserArena* arena, Parser* parser, String input)
{
	Parser*[2] parts = { parser, arena.eoi() };
	ParseResult parsed = parse(arena.sequence(parts[..]), input, mem, "<regex-test>");
	defer parsed.deinit();
	assert(parsed.ok, "regular expression should match the complete input");
	assert(parsed.consumed.length() == input.len, "full match should consume every byte");
}

fn void assert_regex_no_match(Parser* parser, String input)
{
	ParseResult parsed = parse(parser, input, mem, "<regex-test>");
	defer parsed.deinit();
	assert(!parsed.ok, "regular expression should reject the input");
}

fn void assert_regex_not_full(ParserArena* arena, Parser* parser, String input)
{
	Parser*[2] parts = { parser, arena.eoi() };
	ParseResult parsed = parse(arena.sequence(parts[..]), input, mem, "<regex-test>");
	defer parsed.deinit();
	assert(!parsed.ok, "regular expression should reject trailing or mismatched input");
}

fn void regex_alternation_grouping_and_reuse() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();

	Parser* ordered = test_regex(&arena, "abc|bcd|e");
	assert_regex_match(ordered, "abc!", "abc");
	assert_regex_match(ordered, "bcd", "bcd");
	assert_regex_match(ordered, "e", "e");
	assert_regex_no_match(ordered, "bc");

	Parser* grouped = test_regex(&arena, "ab()c(ab)*");
	assert_regex_full_match(&arena, grouped, "abc");
	assert_regex_full_match(&arena, grouped, "abcabab");
	assert_regex_match(grouped, "abcababd", "abcabab");

	Parser* ordered_prefix = test_regex(&arena, "a|ab");
	assert_regex_match(ordered_prefix, "ab", "a");
}

fn void regex_repetition_families() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();

	Parser* parser = test_regex(&arena, "ab*c+d?e{3}");
	assert_regex_full_match(&arena, parser, "acdeee");
	assert_regex_full_match(&arena, parser, "abbbccceee");
	assert_regex_full_match(&arena, parser, "aceee");
	assert_regex_not_full(&arena, parser, "abce");
	assert_regex_not_full(&arena, parser, "abccdeeee");

	Parser* zero = test_regex(&arena, "x{0}y");
	assert_regex_full_match(&arena, zero, "y");
	Parser* exact = test_regex(&arena, "(ab){3}");
	assert_regex_full_match(&arena, exact, "ababab");
	assert_regex_not_full(&arena, exact, "abab");
}

fn void regex_character_classes_and_ranges() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();

	Parser* simple = test_regex(&arena, "abg[abcdef]");
	assert_regex_full_match(&arena, simple, "abga");
	assert_regex_full_match(&arena, simple, "abgf");
	assert_regex_no_match(simple, "abgg");

	Parser* ranges = test_regex(&arena, "[a-z][A-Z_0-9-]*");
	assert_regex_full_match(&arena, ranges, "yAZ_09-");
	assert_regex_not_full(&arena, ranges, "YAZ");

	Parser* escaped = test_regex(&arena, "[\\]\\-]+");
	assert_regex_full_match(&arena, escaped, "]-]-");

	Parser* negated = test_regex(&arena, "^[^56hy].*$");
	assert_regex_full_match(&arena, negated, "apple");
	assert_regex_not_full(&arena, negated, "hello");
	assert_regex_not_full(&arena, negated, "5ive");
}

fn void regex_character_class_escapes_and_consuming_complements() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();

	Parser* positive = test_regex(&arena, "[\\d\\s\\w]+");
	assert_regex_full_match(&arena, positive, "a_9 \t");

	Parser* class_complements = test_regex(&arena, "[\\D][\\S][\\W]");
	assert_regex_full_match(&arena, class_complements, "a_!");
	assert_regex_not_full(&arena, class_complements, "1_!");
	assert_regex_not_full(&arena, class_complements, "a !");
	assert_regex_not_full(&arena, class_complements, "a_a");

	Parser* complements = test_regex(&arena, "\\D\\S\\W");
	assert_regex_match(complements, "a_!tail", "a_!");
	assert_regex_not_full(&arena, complements, "1_!");
	assert_regex_not_full(&arena, complements, "a !");
	assert_regex_not_full(&arena, complements, "a_a");
}

fn void regex_strings_comments_and_controls() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();

	Parser* string_literal = test_regex(&arena, "\"(\\\\.|[^\"])*\"");
	assert_regex_full_match(&arena, string_literal, "\"there\"");
	assert_regex_full_match(&arena, string_literal, "\"i a\\\"m dan\"");
	assert_regex_not_full(&arena, string_literal, "\"unterminated");

	Parser* comment = test_regex(&arena, ";[^\\n\\r]*");
	assert_regex_match(comment, ";i am the\nman", ";i am the");

	Parser* controls = test_regex(&arena, "\\a\\0\\f\\n\\r\\t\\v");
	assert_regex_full_match(&arena, controls, "\x07\0\f\n\r\t\v");
}

fn void regex_boundaries_and_absolute_anchors() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();

	Parser* word = test_regex(&arena, "\\bfoo\\b");
	assert_regex_match(word, "foo.", "foo");
	assert_regex_no_match(word, "foobar");
	assert_regex_no_match(word, "foo3");

	Parser* non_boundary = test_regex(&arena, "py\\B\\w+");
	assert_regex_full_match(&arena, non_boundary, "python");
	assert_regex_full_match(&arena, non_boundary, "py3");
	assert_regex_no_match(non_boundary, "py!");

	Parser* absolute = test_regex(&arena, "\\Aabc\\Z");
	assert_regex_full_match(&arena, absolute, "abc");
	assert_regex_not_full(&arena, absolute, "abc\n");
}

fn void regex_multiline_anchors() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();

	Parser* multiline = test_regex(&arena, "first\\n^second$", { .multiline = true });
	assert_regex_match(multiline, "first\nsecond\nthird", "first\nsecond\n");

	Parser* single_line = test_regex(&arena, "first\\n^second$", {});
	assert_regex_no_match(single_line, "first\nsecond");

	Parser* final_newline = test_regex(&arena, "^hello$");
	assert_regex_match(final_newline, "hello\n", "hello");
	assert_regex_not_full(&arena, final_newline, "hello\n");
}

fn void regex_dotall_option() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();

	Parser* normal = test_regex(&arena, "^.*$");
	assert_regex_full_match(&arena, normal, "hello");
	assert_regex_not_full(&arena, normal, "he\nllo");

	Parser* dotall = test_regex(&arena, "^.*$", { .dotall = true });
	assert_regex_full_match(&arena, dotall, "he\nllo");
	assert_regex_full_match(&arena, dotall, "hello\n");
}

fn void regex_compile_diagnostics() @test
{
	ParserArena arena;
	arena.init(mem);
	defer arena.deinit();

	String[11] malformed = {
		"(",
		"[abc",
		"[]",
		"[^]",
		"[z-a]",
		"[a-\\d]",
		"a{",
		"a{}",
		"a{2",
		"*a",
		"a**",
	};
	foreach (pattern : malformed)
	{
		RegexCompileResult compiled = compile_regex(&arena, pattern);
		assert(!compiled.ok(), "malformed regular expression should not compile");
		assert(compiled.parser == null, "compile failure must not return an executable fail parser");
		assert(compiled.diagnostics.len == 1, "compile failure should return one focused diagnostic");
		assert(compiled.diagnostics[0].message.len > 0, "compile diagnostic should explain the failure");
		assert(compiled.diagnostics[0].span.start.offset <= pattern.len, "diagnostic start should point into the pattern");
		assert(compiled.diagnostics[0].span.end.offset <= pattern.len, "diagnostic end should point into the pattern");
		assert(compiled.diagnostics[0].span.start.row >= 1, "diagnostic should carry a source row");
		assert(compiled.diagnostics[0].span.start.column >= 1, "diagnostic should carry a source column");
		compiled.deinit();
	}

	RegexCompileResult trailing_escape = compile_regex(&arena, "line\n\\");
	assert(!trailing_escape.ok(), "trailing escape should be rejected");
	assert(trailing_escape.diagnostics[0].span.start.row == 2, "diagnostic rows should account for newlines in the regex source");
	assert(trailing_escape.diagnostics[0].span.start.column == 1, "diagnostic columns should reset after newlines");
	trailing_escape.deinit();

	RegexCompileResult overflow = compile_regex(&arena, "a{18446744073709551616}");
	assert(!overflow.ok(), "overflowing exact counts should be rejected");
	assert(overflow.diagnostics.len == 1, "overflow should produce a structured diagnostic");
	overflow.deinit();
}
