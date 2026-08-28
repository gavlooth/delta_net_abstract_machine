// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module mpc;

import std::collections::list;
import std::core::mem;

struct GrammarOptions
{
	bool whitespace_sensitive;
	bool predictive;
}

struct LanguageRule
{
	String name;
	Parser* parser;
	Parser* full_parser;
}

struct Language
{
	Allocator allocator;
	ParserArena arena;
	LanguageRule[] rules;
	String start_rule;
}

fn Parser* Language.rule(&self, String name)
{
	foreach (&entry : self.rules)
	{
		if (entry.name == name) return entry.parser;
	}
	return null;
}

fn Parser* Language.full_rule(&self, String name)
{
	if (!name.len) name = self.start_rule;
	foreach (&entry : self.rules)
	{
		if (entry.name == name) return entry.full_parser;
	}
	return null;
}

fn ParseResult Language.parse(&self, String input, Allocator allocator, String rule_name = "", String source_name = "<input>")
{
	Parser* parser = self.full_rule(rule_name);
	assert(parser != null, "unknown language rule");
	return parse(parser, input, allocator, source_name);
}

fn ParseResult? Language.parse_file(&self, String path, Allocator allocator, String rule_name = "")
{
	Parser* parser = self.full_rule(rule_name);
	assert(parser != null, "unknown language rule");
	return parse_file(parser, path, allocator);
}

fn void Language.deinit(&self)
{
	if (!self.allocator) return;
	self.arena.deinit();
	foreach (&entry : self.rules) alloc::free(self.allocator, entry.name);
	alloc::free(self.allocator, self.rules);
	*self = {};
}

struct LanguageCompileResult
{
	Allocator allocator;
	Language* language;
	Diagnostic[] diagnostics;
}

fn bool LanguageCompileResult.ok(&self) => self.language != null && !self.diagnostics.len;

fn Language* LanguageCompileResult.take_language(&self)
{
	Language* language = self.language;
	self.language = null;
	return language;
}

fn void LanguageCompileResult.deinit(&self)
{
	if (!self.allocator) return;
	if (self.language)
	{
		self.language.deinit();
		alloc::free(self.allocator, self.language);
	}
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = {};
}

struct RuleCompileResult
{
	Allocator allocator;
	Parser* parser;
	Diagnostic[] diagnostics;
}

fn bool RuleCompileResult.ok(&self) => self.parser != null && !self.diagnostics.len;

fn void RuleCompileResult.deinit(&self)
{
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = {};
}

enum GrammarTokenKind
{
	END,
	IDENTIFIER,
	STRING,
	REGEX,
	NUMBER,
	COLON,
	SEMICOLON,
	LEFT_PAREN,
	RIGHT_PAREN,
	LEFT_ANGLE,
	RIGHT_ANGLE,
	LEFT_BRACKET,
	RIGHT_BRACKET,
	LEFT_BRACE,
	RIGHT_BRACE,
	PIPE,
	STAR,
	PLUS,
	QUESTION,
	BANG,
	INVALID
}

struct GrammarToken
{
	GrammarTokenKind kind;
	String text;
	Span span;
	bool multiline;
	bool dotall;
}

struct GrammarLexer
{
	String source;
	sz cursor;
	SourcePos position;
}

fn GrammarLexer* GrammarLexer.init(&self, String source)
{
	*self = { .source = source, .position = source_start() };
	return self;
}

fn char GrammarLexer.peek(&self)
{
	return self.cursor < self.source.len ? self.source[self.cursor] : 0;
}

fn char GrammarLexer.advance(&self)
{
	if (self.cursor >= self.source.len) return 0;
	char c = self.source[self.cursor++];
	self.position.offset++;
	if (c == '\n')
	{
		self.position.row++;
		self.position.column = 1;
	}
	else { self.position.column++; }
	return c;
}

fn String grammar_slice(String source, sz start, sz end)
{
	if (end <= start) return "";
	return source[start : end - start];
}

fn bool grammar_ident_start(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
fn bool grammar_ident_continue(char c) => grammar_ident_start(c) || (c >= '0' && c <= '9');
fn bool grammar_digit(char c) => c >= '0' && c <= '9';
fn bool grammar_space(char c) => c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';

fn GrammarToken GrammarLexer.next(&self)
{
	while (grammar_space(self.peek())) self.advance();
	SourcePos start = self.position;
	char c = self.peek();
	if (!c) return { .kind = END, .span = { .start = start, .end = start } };

	if (grammar_ident_start(c))
	{
		sz offset = self.cursor;
		while (grammar_ident_continue(self.peek())) self.advance();
		return { .kind = IDENTIFIER, .text = grammar_slice(self.source, offset, self.cursor), .span = { .start = start, .end = self.position } };
	}
	if (grammar_digit(c))
	{
		sz offset = self.cursor;
		while (grammar_digit(self.peek())) self.advance();
		return { .kind = NUMBER, .text = grammar_slice(self.source, offset, self.cursor), .span = { .start = start, .end = self.position } };
	}
	if (c == '\'' || c == '"')
	{
		char quote = self.advance();
		sz offset = self.cursor;
		bool escaped = false;
		while (self.peek())
		{
			char current = self.peek();
			if (!escaped && current == quote)
			{
				sz end = self.cursor;
				self.advance();
				return { .kind = STRING, .text = grammar_slice(self.source, offset, end), .span = { .start = start, .end = self.position } };
			}
			if (!escaped && (current == '\n' || current == '\r')) break;
			self.advance();
			if (escaped) { escaped = false; }
			else if (current == '\\') { escaped = true; }
		}
		return { .kind = INVALID, .text = "unterminated string literal", .span = { .start = start, .end = self.position } };
	}
	if (c == '/')
	{
		self.advance();
		sz offset = self.cursor;
		bool escaped = false;
		while (self.peek())
		{
			char current = self.peek();
			if (!escaped && current == '/')
			{
				sz end = self.cursor;
				self.advance();
				bool multiline = false;
				bool dotall = false;
				while (self.peek() == 'm' || self.peek() == 's')
				{
					if (self.peek() == 'm') { multiline = true; }
					else { dotall = true; }
					self.advance();
				}
				return { .kind = REGEX, .text = grammar_slice(self.source, offset, end), .span = { .start = start, .end = self.position }, .multiline = multiline, .dotall = dotall };
			}
			self.advance();
			if (escaped) { escaped = false; }
			else if (current == '\\') { escaped = true; }
		}
		return { .kind = INVALID, .text = "unterminated regex literal", .span = { .start = start, .end = self.position } };
	}

	self.advance();
	GrammarTokenKind kind;
	switch (c)
	{
		case ':': kind = COLON;
		case ';': kind = SEMICOLON;
		case '(': kind = LEFT_PAREN;
		case ')': kind = RIGHT_PAREN;
		case '<': kind = LEFT_ANGLE;
		case '>': kind = RIGHT_ANGLE;
		case '[': kind = LEFT_BRACKET;
		case ']': kind = RIGHT_BRACKET;
		case '{': kind = LEFT_BRACE;
		case '}': kind = RIGHT_BRACE;
		case '|': kind = PIPE;
		case '*': kind = STAR;
		case '+': kind = PLUS;
		case '?': kind = QUESTION;
		case '!': kind = BANG;
		default: return { .kind = INVALID, .text = "unexpected character", .span = { .start = start, .end = self.position } };
	}
	return { .kind = kind, .span = { .start = start, .end = self.position } };
}

enum GrammarExprKind
{
	LITERAL_EXPR,
	REGEX_EXPR,
	REFERENCE_EXPR,
	SEQUENCE_EXPR,
	CHOICE_EXPR,
	OPTIONAL_EXPR,
	MANY_EXPR,
	MANY1_EXPR,
	COUNT_EXPR,
	NOT_EXPR,
	PASS_EXPR
}

struct GrammarExpr
{
	GrammarExprKind kind;
	String text;
	Span span;
	GrammarExpr* child;
	GrammarExpr*[] children;
	sz count;
	bool multiline;
	bool dotall;
}

struct GrammarStatement
{
	String name;
	String expected;
	Span span;
	GrammarExpr* expression;
}

struct GrammarCompiler
{
	Allocator allocator;
	GrammarOptions options;
	GrammarLexer lexer;
	GrammarToken token;
	List{Diagnostic} diagnostics;
	List{GrammarStatement} statements;
}

fn GrammarCompiler* GrammarCompiler.init(&self, String source, Allocator allocator, GrammarOptions options)
{
	*self = { .allocator = allocator, .options = options };
	self.lexer.init(source);
	self.diagnostics.init(allocator);
	self.statements.tinit();
	self.token = self.lexer.next();
	return self;
}

fn void GrammarCompiler.add_diagnostic(&self, String message, Span span, String expected = "")
{
	Diagnostic diagnostic;
	diagnostic.init(self.allocator, message, span);
	if (expected.len) diagnostic.add_expected(expected);
	self.diagnostics.push(diagnostic);
}

fn void GrammarCompiler.advance(&self)
{
	self.token = self.lexer.next();
}

fn bool GrammarCompiler.accept(&self, GrammarTokenKind kind)
{
	if (self.token.kind != kind) return false;
	self.advance();
	return true;
}

fn bool GrammarCompiler.require(&self, GrammarTokenKind kind, String label)
{
	if (self.accept(kind)) return true;
	String message = self.token.kind == INVALID ? self.token.text : "malformed grammar";
	self.add_diagnostic(message, self.token.span, label);
	return false;
}

fn GrammarExpr* new_grammar_expr(GrammarExprKind kind, Span span)
{
	return alloc::new(tmem, GrammarExpr, { .kind = kind, .span = span });
}

fn GrammarExpr* GrammarCompiler.parse_primary(&self)
{
	GrammarToken token = self.token;
	switch (token.kind)
	{
		case STRING:
			self.advance();
			GrammarExpr* literal = new_grammar_expr(LITERAL_EXPR, token.span);
			literal.text = token.text;
			return literal;
		case REGEX:
			self.advance();
			GrammarExpr* regex = new_grammar_expr(REGEX_EXPR, token.span);
			regex.text = token.text;
			regex.multiline = token.multiline;
			regex.dotall = token.dotall;
			return regex;
		case LEFT_ANGLE:
			self.advance();
			if (self.token.kind != IDENTIFIER)
			{
				self.add_diagnostic("malformed rule reference", self.token.span, "rule name");
				return null;
			}
			GrammarToken name = self.token;
			self.advance();
			if (!self.require(RIGHT_ANGLE, "'>'")) return null;
			GrammarExpr* reference = new_grammar_expr(REFERENCE_EXPR, { .start = token.span.start, .end = self.token.span.start });
			reference.text = name.text;
			return reference;
		case LEFT_PAREN:
			self.advance();
			GrammarExpr* expression = self.parse_choice();
			if (!expression || !self.require(RIGHT_PAREN, "')'")) return null;
			expression.span = { .start = token.span.start, .end = self.token.span.start };
			return expression;
		case INVALID:
			self.add_diagnostic(token.text, token.span);
			return null;
		default:
			self.add_diagnostic("expected grammar expression", token.span, "literal, regex, rule reference, or group");
			return null;
	}
}

fn GrammarExpr* GrammarCompiler.parse_factor(&self)
{
	GrammarExpr* expression = self.parse_primary();
	if (!expression) return null;
	while (true)
	{
		GrammarExprKind kind;
		sz count = 0;
		Span end_span = self.token.span;
		switch (self.token.kind)
		{
			case STAR: kind = MANY_EXPR; self.advance();
			case PLUS: kind = MANY1_EXPR; self.advance();
			case QUESTION: kind = OPTIONAL_EXPR; self.advance();
			case BANG: kind = NOT_EXPR; self.advance();
			case LEFT_BRACE:
				kind = COUNT_EXPR;
				self.advance();
				if (self.token.kind != NUMBER)
				{
					self.add_diagnostic("malformed repetition count", self.token.span, "non-negative integer");
					return null;
				}
				foreach (char digit_char : self.token.text)
				{
					sz digit = (sz)(digit_char - '0');
					if (count > (sz::max - digit) / 10)
					{
						self.add_diagnostic("repetition count is too large", self.token.span, "count representable as sz");
						return null;
					}
					count = count * 10 + digit;
				}
				self.advance();
				if (!self.require(RIGHT_BRACE, "'}'")) return null;
			default: return expression;
		}
		GrammarExpr* repeated = new_grammar_expr(kind, { .start = expression.span.start, .end = end_span.end });
		repeated.child = expression;
		repeated.count = count;
		expression = repeated;
	}
}

fn bool grammar_stops_sequence(GrammarTokenKind kind)
{
	return kind == PIPE || kind == RIGHT_PAREN || kind == SEMICOLON || kind == END;
}

fn GrammarExpr* GrammarCompiler.parse_sequence(&self)
{
	List{GrammarExpr*} expressions;
	expressions.tinit();
	SourcePos start = self.token.span.start;
	while (!grammar_stops_sequence(self.token.kind))
	{
		GrammarExpr* expression = self.parse_factor();
		if (!expression) return null;
		expressions.push(expression);
	}
	if (!expressions.size)
	{
		self.add_diagnostic("expected grammar expression", self.token.span);
		return null;
	}
	if (expressions.size == 1) return expressions.get(0);
	GrammarExpr* sequence = new_grammar_expr(SEQUENCE_EXPR, { .start = start, .end = expressions.get(expressions.size - 1).span.end });
	sequence.children = expressions.to_array(tmem);
	return sequence;
}

fn GrammarExpr* GrammarCompiler.parse_choice(&self)
{
	List{GrammarExpr*} expressions;
	expressions.tinit();
	GrammarExpr* first = self.parse_sequence();
	if (!first) return null;
	expressions.push(first);
	while (self.accept(PIPE))
	{
		GrammarExpr* next = self.parse_sequence();
		if (!next) return null;
		expressions.push(next);
	}
	if (expressions.size == 1) return first;
	GrammarExpr* choice = new_grammar_expr(CHOICE_EXPR, { .start = first.span.start, .end = expressions.get(expressions.size - 1).span.end });
	choice.children = expressions.to_array(tmem);
	return choice;
}

fn bool GrammarCompiler.parse_statement(&self)
{
	if (self.token.kind != IDENTIFIER)
	{
		self.add_diagnostic("malformed rule statement", self.token.span, "rule name");
		return false;
	}
	GrammarToken name = self.token;
	self.advance();
	String expected;
	if (self.accept(LEFT_BRACKET))
	{
		if (self.token.kind != STRING)
		{
			self.add_diagnostic("malformed expected label", self.token.span, "string literal");
			return false;
		}
		expected = self.token.text;
		self.advance();
		if (!self.require(RIGHT_BRACKET, "']'")) return false;
	}
	if (!self.require(COLON, "':'")) return false;
	GrammarExpr* expression = self.parse_choice();
	if (!expression || !self.require(SEMICOLON, "';'")) return false;
	self.statements.push({ .name = name.text, .expected = expected, .span = { .start = name.span.start, .end = self.token.span.start }, .expression = expression });
	return true;
}

fn bool GrammarCompiler.parse_language(&self)
{
	while (self.token.kind != END)
	{
		if (!self.parse_statement()) return false;
	}
	if (!self.statements.size)
	{
		self.add_diagnostic("language contains no rules", self.token.span, "rule statement");
		return false;
	}
	return true;
}

fn String decode_literal(String raw, Allocator allocator)
{
	char[] output = alloc::new_array(allocator, char, raw.len + 1);
	sz written = 0;
	for (sz i = 0; i < raw.len; i++)
	{
		char c = raw[i];
		if (c != '\\' || i + 1 >= raw.len)
		{
			output[written++] = c;
			continue;
		}
		c = raw[++i];
		switch (c)
		{
			case 'n': output[written++] = '\n';
			case 'r': output[written++] = '\r';
			case 't': output[written++] = '\t';
			case 'b': output[written++] = '\b';
			case 'f': output[written++] = '\f';
			case 'v': output[written++] = '\v';
			case '0': output[written++] = '\0';
			case '\\': output[written++] = '\\';
			case '\'': output[written++] = '\'';
			case '"': output[written++] = '"';
			default: output[written++] = c;
		}
	}
	output[written] = 0;
	return (String)output[:written];
}

fn String decode_regex_literal(String raw, Allocator allocator)
{
	char[] output = alloc::new_array(allocator, char, raw.len + 1);
	sz written = 0;
	for (sz i = 0; i < raw.len; i++)
	{
		if (raw[i] == '\\' && i + 1 < raw.len && raw[i + 1] == '/')
		{
			output[written++] = '/';
			i++;
			continue;
		}
		output[written++] = raw[i];
	}
	output[written] = 0;
	return (String)output[:written];
}

fn Parser* find_rule(Language* language, String name)
{
	return language ? language.rule(name) : null;
}

fn void GrammarCompiler.copy_regex_diagnostic(&self, Diagnostic* source, Span regex_span)
{
	Span span = source.span;
	span.start.offset += regex_span.start.offset + 1;
	span.end.offset += regex_span.start.offset + 1;
	if (source.span.start.row == 1)
	{
		span.start.row = regex_span.start.row;
		span.start.column += regex_span.start.column;
	}
	else { span.start.row += regex_span.start.row - 1; }
	if (source.span.end.row == 1)
	{
		span.end.row = regex_span.start.row;
		span.end.column += regex_span.start.column;
	}
	else { span.end.row += regex_span.start.row - 1; }
	Diagnostic diagnostic;
	diagnostic.init(self.allocator, source.message, span);
	foreach (expected : source.expected) diagnostic.add_expected(expected);
	self.diagnostics.push(diagnostic);
}

fn Parser* GrammarCompiler.lower(&self, Language* language, ParserArena* arena, GrammarExpr* expression)
{
	if (!expression) return null;
	switch (expression.kind)
	{
		case LITERAL_EXPR:
			String value = decode_literal(expression.text, tmem);
			Parser* literal = arena.literal(value);
			return self.options.whitespace_sensitive ? literal : arena.token(literal);
		case REGEX_EXPR:
			String pattern = decode_regex_literal(expression.text, tmem);
			RegexCompileResult regex = compile_regex(arena, pattern, { .multiline = expression.multiline, .dotall = expression.dotall });
			defer regex.deinit();
			if (!regex.ok())
			{
				foreach (&diagnostic : regex.diagnostics) self.copy_regex_diagnostic(diagnostic, expression.span);
				return null;
			}
			return self.options.whitespace_sensitive ? regex.parser : arena.token(regex.parser);
		case REFERENCE_EXPR:
			Parser* referenced = find_rule(language, expression.text);
			if (!referenced)
			{
				String message = "missing rule '".tconcat(expression.text).tconcat("'");
				self.add_diagnostic(message, expression.span, expression.text);
			}
			return referenced;
		case OPTIONAL_EXPR:
			Parser* optional = self.lower(language, arena, expression.child);
			return optional ? arena.optional(optional) : null;
		case MANY_EXPR:
			Parser* many = self.lower(language, arena, expression.child);
			return many ? arena.many(many) : null;
		case MANY1_EXPR:
			Parser* many1 = self.lower(language, arena, expression.child);
			return many1 ? arena.many1(many1) : null;
		case COUNT_EXPR:
			Parser* counted = self.lower(language, arena, expression.child);
			return counted ? arena.count(counted, expression.count) : null;
		case NOT_EXPR:
			Parser* negative = self.lower(language, arena, expression.child);
			return negative ? arena.not_followed_by(negative) : null;
		case SEQUENCE_EXPR:
		case CHOICE_EXPR:
			List{Parser*} parsers;
			parsers.tinit(expression.children.len);
			bool failed = false;
			foreach (child : expression.children)
			{
				Parser* parser = self.lower(language, arena, child);
				if (!parser) { failed = true; }
				else { parsers.push(parser); }
			}
			if (failed) return null;
			Parser*[] array = parsers.to_array(tmem);
			if (expression.kind == SEQUENCE_EXPR) return arena.sequence(array);
			return self.options.predictive ? arena.predictive_choice(array) : arena.choice(array);
		case PASS_EXPR: return arena.pass();
	}
}

fn Diagnostic[] GrammarCompiler.finish_diagnostics(&self)
{
	Diagnostic[] diagnostics = self.diagnostics.to_array(self.allocator);
	self.diagnostics.free();
	return diagnostics;
}

fn LanguageCompileResult compile_language_inner(String grammar, Allocator allocator, GrammarOptions options)
{
	GrammarCompiler compiler;
	compiler.init(grammar, allocator, options);
	if (!compiler.parse_language()) return { .allocator = allocator, .diagnostics = compiler.finish_diagnostics() };

	foreach (i, &statement : compiler.statements)
	{
		for (sz prior = 0; prior < i; prior++)
		{
			if (compiler.statements.get(prior).name == statement.name)
			{
				String message = "duplicate rule '".tconcat(statement.name).tconcat("'");
				compiler.add_diagnostic(message, statement.span, statement.name);
				break;
			}
		}
	}
	if (compiler.diagnostics.size) return { .allocator = allocator, .diagnostics = compiler.finish_diagnostics() };

	Language* language = alloc::new(allocator, Language);
	language.allocator = allocator;
	language.arena.init(allocator);
	language.rules = alloc::new_array(allocator, LanguageRule, compiler.statements.size);
	foreach (i, &statement : compiler.statements)
	{
		String name = statement.name.copy(allocator);
		language.rules[i] = { .name = name, .parser = language.arena.rule(name) };
	}
	language.start_rule = language.rules[0].name;

	foreach (i, &statement : compiler.statements)
	{
		Parser* body = compiler.lower(language, &language.arena, statement.expression);
		if (!body) continue;
		if (statement.expected.len)
		{
			String expected = decode_literal(statement.expected, tmem);
			body = language.arena.expect(body, expected);
		}
		body = body.named(statement.name);
		language.rules[i].parser.set_rule(body);
	}

	if (compiler.diagnostics.size)
	{
		language.deinit();
		alloc::free(allocator, language);
		return { .allocator = allocator, .diagnostics = compiler.finish_diagnostics() };
	}
	foreach (&entry : language.rules)
	{
		Parser* root = options.whitespace_sensitive ? entry.parser : language.arena.token(entry.parser);
		entry.full_parser = language.arena.whole(root);
	}
	return { .allocator = allocator, .language = language, .diagnostics = compiler.finish_diagnostics() };
}

fn LanguageCompileResult compile_language(String grammar, Allocator allocator, GrammarOptions options = {})
{
	@pool() { return compile_language_inner(grammar, allocator, options); };
}

fn RuleCompileResult compile_rule_inner(ParserArena* arena, String grammar, Allocator allocator, GrammarOptions options)
{
	GrammarCompiler compiler;
	compiler.init(grammar, allocator, options);
	GrammarExpr* expression = compiler.parse_choice();
	if (expression && compiler.token.kind != END) compiler.add_diagnostic("unexpected input after grammar expression", compiler.token.span, "end of expression");
	Parser* parser;
	if (!compiler.diagnostics.size) parser = compiler.lower(null, arena, expression);
	return { .allocator = allocator, .parser = parser, .diagnostics = compiler.finish_diagnostics() };
}

fn RuleCompileResult compile_rule(ParserArena* arena, String grammar, Allocator allocator, GrammarOptions options = {})
{
	@pool() { return compile_rule_inner(arena, grammar, allocator, options); };
}
