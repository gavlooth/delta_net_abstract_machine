// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module mpc;

import std::io::file;

fn bool diagnostic_expects(Diagnostic* diagnostic, String label)
{
	foreach (expected : diagnostic.expected)
	{
		if (expected == label) return true;
	}
	return false;
}

fn void grammar_arithmetic_ast() @test
{
	String grammar =
		"maths: <expression>;"
		"expression: <product> (('+' | '-') <product>)*;"
		"product: <value> (('*' | '/') <value>)*;"
		"value: /[0-9]+/ | '(' <expression> ')';";
	LanguageCompileResult compiled = compile_language(grammar, mem);
	defer compiled.deinit();
	assert(compiled.ok(), "arithmetic grammar must compile");

	ParseResult parsed = compiled.language.parse("(4 * 2 + 11) + 5 ", mem, "maths");
	defer parsed.deinit();
	assert(parsed.ok, "recursive arithmetic input must parse");
	assert(parsed.root != null, "arithmetic parse must produce an AST");
	assert(parsed.root.tag == "maths", "the selected rule must tag the AST root");
	assert(parsed.root.find("expression") != null, "recursive rule tags must be preserved");
	assert(parsed.root.find("product") != null, "nested product rule must be represented");
	AstNode* value = parsed.root.find("value");
	assert(value != null && !value.span.is_empty(), "AST rule nodes must retain source spans");

	ParseResult trailing = compiled.language.parse("2b+4", mem, "maths");
	defer trailing.deinit();
	assert(!trailing.ok, "language parsing is full-input, not prefix parsing");
}

fn void grammar_full_language() @test
{
	String grammar =
		"doge: <phrase>*;"
		"phrase: <adjective> <noun>;"
		"adjective: 'wow' | 'many' | 'so' | 'such';"
		"noun: 'lisp' | 'language' | 'c' | 'book' | 'build';";
	LanguageCompileResult compiled = compile_language(grammar, mem);
	defer compiled.deinit();
	assert(compiled.ok());

	ParseResult parsed = compiled.language.parse("so c such language", mem);
	defer parsed.deinit();
	assert(parsed.ok);
	assert(parsed.root.tag == "doge");
	assert(parsed.root.find("phrase") != null, "repeated named rules must remain in the AST");
	assert(parsed.root.find("adjective") != null);
	assert(parsed.root.find("noun") != null);
}

fn void grammar_mutual_recursion() @test
{
	String grammar =
		"start: <even>;"
		"even: 'x' <odd>?;"
		"odd: 'y' <even>?;";
	LanguageCompileResult compiled = compile_language(grammar, mem);
	defer compiled.deinit();
	assert(compiled.ok(), "forward and mutual references must resolve in phase two");

	ParseResult parsed = compiled.language.parse("xyxy", mem);
	defer parsed.deinit();
	assert(parsed.ok, "mutually recursive rules must execute");
	assert(parsed.root.find("even") != null);
	assert(parsed.root.find("odd") != null);
}

fn void grammar_compile_diagnostics() @test
{
	LanguageCompileResult missing = compile_language("start: <absent>;", mem);
	defer missing.deinit();
	assert(!missing.ok() && missing.diagnostics.len == 1, "missing references are compile errors");
	assert(missing.diagnostics[0].message == "missing rule 'absent'");

	LanguageCompileResult duplicate = compile_language("item: 'a'; item: 'b';", mem);
	defer duplicate.deinit();
	assert(!duplicate.ok() && duplicate.diagnostics.len == 1, "duplicates must be deterministic");
	assert(duplicate.diagnostics[0].message == "duplicate rule 'item'");

	LanguageCompileResult malformed = compile_language("item: ('a' | ;", mem);
	defer malformed.deinit();
	assert(!malformed.ok() && malformed.diagnostics.len == 1, "malformed rules must be rejected during phase one");
	assert(!malformed.diagnostics[0].span.is_empty() || malformed.diagnostics[0].span.start.offset > 0);

	LanguageCompileResult overflow = compile_language("item: 'a'{999999999999999999999999999};", mem);
	defer overflow.deinit();
	assert(!overflow.ok() && overflow.diagnostics.len == 1, "overflowing repetition counts must be compile errors");
	assert(overflow.diagnostics[0].message == "repetition count is too large");
}

fn void grammar_expected_labels() @test
{
	LanguageCompileResult compiled = compile_language("number [\"decimal number\"]: /[0-9]+/;", mem);
	defer compiled.deinit();
	assert(compiled.ok());
	ParseResult parsed = compiled.language.parse("nope", mem);
	defer parsed.deinit();
	assert(!parsed.ok);
	assert(diagnostic_expects(&parsed.diagnostic, "decimal number"), "expected labels must reach parse diagnostics");
}

fn void grammar_options_and_regex_modes() @test
{
	LanguageCompileResult default_ws = compile_language("pair: 'a' 'b';", mem);
	defer default_ws.deinit();
	assert(default_ws.ok());
	ParseResult spaced = default_ws.language.parse("a   b  ", mem);
	defer spaced.deinit();
	assert(spaced.ok, "default grammar terminals consume trailing whitespace");

	LanguageCompileResult sensitive = compile_language("pair: 'a' 'b';", mem, { .whitespace_sensitive = true });
	defer sensitive.deinit();
	assert(sensitive.ok());
	ParseResult exact = sensitive.language.parse("ab", mem);
	defer exact.deinit();
	assert(exact.ok);
	ParseResult rejected_space = sensitive.language.parse("a b", mem);
	defer rejected_space.deinit();
	assert(!rejected_space.ok, "whitespace-sensitive grammars must not tokenize terminals");

	String modes =
		"dot: /.*/s;"
		"lines: /(^[a-z]*$)*/m;";
	LanguageCompileResult regex = compile_language(modes, mem);
	defer regex.deinit();
	assert(regex.ok(), "m and s suffixes must be accepted");
	ParseResult dot = regex.language.parse("one\ntwo", mem, "dot");
	defer dot.deinit();
	assert(dot.ok, "dotall suffix must make dot include newlines");
	ParseResult lines = regex.language.parse("one\ntwo", mem, "lines");
	defer lines.deinit();
	assert(lines.ok, "multiline suffix must change anchors per line");
}

fn void grammar_predictive_choice() @test
{
	String grammar = "start: ('ab' 'x') | ('a' 'y');";
	LanguageCompileResult ordinary = compile_language(grammar, mem);
	defer ordinary.deinit();
	assert(ordinary.ok());
	ParseResult backtracked = ordinary.language.parse("ay", mem);
	defer backtracked.deinit();
	assert(backtracked.ok, "ordinary choices backtrack in order");

	LanguageCompileResult predictive = compile_language(grammar, mem, { .predictive = true });
	defer predictive.deinit();
	assert(predictive.ok());
	ParseResult committed = predictive.language.parse("ay", mem);
	defer committed.deinit();
	assert(!committed.ok, "predictive choices commit after consuming a branch prefix");
}

fn void grammar_fixtures() @test
{
	char[] grammar_bytes = file::load_temp("test/fixtures/maths.grammar")!!;
	LanguageCompileResult compiled = compile_language((String)grammar_bytes, mem);
	defer compiled.deinit();
	assert(compiled.ok(), "the migrated arithmetic fixture must compile");

	ParseResult arithmetic = compiled.language.parse("(4 * 2 + 11) + 5", mem, "maths");
	defer arithmetic.deinit();
	assert(arithmetic.ok && arithmetic.root.find("expression") != null);

	LanguageCompileResult digits = compile_language("digit: /[0-9]/; program: <digit>+;", mem);
	defer digits.deinit();
	assert(digits.ok());
	ParseResult parsed_file = digits.language.parse_file("test/fixtures/digits.txt", mem, "program")!!;
	defer parsed_file.deinit();
	assert(parsed_file.ok, "Language.parse_file must parse the migrated fixture");
	assert(parsed_file.root.find("digit") != null, "file parsing must produce the same named AST nodes");
}
