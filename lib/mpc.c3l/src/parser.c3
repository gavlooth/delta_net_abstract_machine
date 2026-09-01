// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module mpc;

import std::collections::list;
import std::core::mem;
import std::io::file;

enum ParserKind
{
	ANY_CHAR, CHARACTER, RANGE, ONE_OF, NONE_OF, LITERAL,
	SOI, EOI, PASS, FAIL, EXPECT,
	SEQUENCE, CHOICE, PREDICTIVE_CHOICE, OPTIONAL, MANY, MANY1, COUNT, SEP_BY,
	LOOKAHEAD, NOT_FOLLOWED_BY, TOKEN, WHOLE, BETWEEN,
	RULE, NAMED, WORD_BOUNDARY, LINE_START, LINE_END,
}

struct ParserArena
{
	Allocator allocator;
	List{Parser*} parsers;
}

struct Parser
{
	ParserArena* arena;
	ParserKind kind;
	Parser* first;
	Parser* second;
	Parser* third;
	Parser* target;
	Parser*[] parts;
	String text;
	String name;
	char low;
	char high;
	sz amount;
	bool flag;
}

fn ParserArena* ParserArena.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.parsers.init(allocator);
	return self;
}

fn Parser* ParserArena.make(&self, ParserKind kind)
{
	Parser* parser = alloc::new(self.allocator, Parser, { .arena = self, .kind = kind });
	self.parsers.push(parser);
	return parser;
}

fn Parser* ParserArena.make_text(&self, ParserKind kind, String text)
{
	Parser* parser = self.make(kind);
	parser.text = text.copy(self.allocator);
	return parser;
}

fn Parser* ParserArena.make_unary(&self, ParserKind kind, Parser* inner)
{
	Parser* parser = self.make(kind);
	parser.first = inner;
	return parser;
}

fn Parser* ParserArena.make_parts(&self, ParserKind kind, Parser*[] parts)
{
	Parser* parser = self.make(kind);
	parser.parts = alloc::clone_slice(self.allocator, parts);
	return parser;
}

fn void ParserArena.deinit(&self)
{
	if (!self.allocator) return;
	foreach (parser : self.parsers)
	{
		alloc::free(self.allocator, parser.parts);
		alloc::free(self.allocator, parser.text);
		alloc::free(self.allocator, parser.name);
		alloc::free(self.allocator, parser);
	}
	self.parsers.free();
	*self = {};
}

fn Parser* ParserArena.any_char(&self) => self.make(ANY_CHAR);

fn Parser* ParserArena.character(&self, char value)
{
	Parser* parser = self.make(CHARACTER);
	parser.low = value;
	return parser;
}

fn Parser* ParserArena.range(&self, char low, char high)
{
	Parser* parser = self.make(RANGE);
	parser.low = low;
	parser.high = high;
	return parser;
}

fn Parser* ParserArena.one_of(&self, String characters) => self.make_text(ONE_OF, characters);
fn Parser* ParserArena.none_of(&self, String characters) => self.make_text(NONE_OF, characters);
fn Parser* ParserArena.literal(&self, String literal) => self.make_text(LITERAL, literal);
fn Parser* ParserArena.soi(&self) => self.make(SOI);
fn Parser* ParserArena.eoi(&self) => self.make(EOI);
fn Parser* ParserArena.pass(&self) => self.make(PASS);
fn Parser* ParserArena.fail(&self, String message) => self.make_text(FAIL, message);

fn Parser* ParserArena.expect(&self, Parser* inner, String label)
{
	Parser* parser = self.make_text(EXPECT, label);
	parser.first = inner;
	return parser;
}

fn Parser* ParserArena.sequence(&self, Parser*[] parts) => self.make_parts(SEQUENCE, parts);
fn Parser* ParserArena.choice(&self, Parser*[] parts) => self.make_parts(CHOICE, parts);
fn Parser* ParserArena.predictive_choice(&self, Parser*[] parts) => self.make_parts(PREDICTIVE_CHOICE, parts);
fn Parser* ParserArena.optional(&self, Parser* inner) => self.make_unary(OPTIONAL, inner);
fn Parser* ParserArena.many(&self, Parser* inner) => self.make_unary(MANY, inner);
fn Parser* ParserArena.many1(&self, Parser* inner) => self.make_unary(MANY1, inner);

fn Parser* ParserArena.count(&self, Parser* inner, sz amount)
{
	Parser* parser = self.make_unary(COUNT, inner);
	parser.amount = amount;
	return parser;
}

fn Parser* ParserArena.sep_by(&self, Parser* inner, Parser* separator, bool allow_empty = true)
{
	Parser* parser = self.make(SEP_BY);
	parser.first = inner;
	parser.second = separator;
	parser.flag = allow_empty;
	return parser;
}

fn Parser* ParserArena.lookahead(&self, Parser* inner) => self.make_unary(LOOKAHEAD, inner);
fn Parser* ParserArena.not_followed_by(&self, Parser* inner) => self.make_unary(NOT_FOLLOWED_BY, inner);
fn Parser* ParserArena.token(&self, Parser* inner) => self.make_unary(TOKEN, inner);
fn Parser* ParserArena.whole(&self, Parser* inner) => self.make_unary(WHOLE, inner);

fn Parser* ParserArena.between(&self, Parser* open, Parser* inner, Parser* close)
{
	Parser* parser = self.make(BETWEEN);
	parser.first = open;
	parser.second = inner;
	parser.third = close;
	return parser;
}

fn Parser* ParserArena.rule(&self, String name)
{
	Parser* parser = self.make(RULE);
	parser.name = name.copy(self.allocator);
	return parser;
}

fn Parser* ParserArena.word_boundary(&self, bool negated = false)
{
	Parser* parser = self.make(WORD_BOUNDARY);
	parser.flag = negated;
	return parser;
}

fn Parser* ParserArena.line_start(&self) => self.make(LINE_START);
fn Parser* ParserArena.line_end(&self) => self.make(LINE_END);

fn Parser* Parser.set_rule(&self, Parser* target)
{
	assert(self.kind == RULE, "set_rule requires a rule parser");
	self.target = target;
	return self;
}

fn Parser* Parser.named(&self, String tag)
{
	Parser* parser = self.arena.make_unary(NAMED, self);
	parser.name = tag.copy(self.arena.allocator);
	return parser;
}

struct ParseResult
{
	Allocator allocator;
	bool ok;
	AstNode* root;
	Diagnostic diagnostic;
	String source_name;
	String input;
	Span consumed;
	List{AstNode*} nodes;
}

fn void ParseResult.free_node(&self, AstNode* node)
{
	alloc::free(self.allocator, node.tag);
	alloc::free(self.allocator, node.text);
	alloc::free(self.allocator, node.children);
	alloc::free(self.allocator, node);
}

fn void ParseResult.rollback_nodes(&self, sz count)
{
	while (self.nodes.len() > count)
	{
		AstNode* node = self.nodes.pop()!!;
		self.free_node(node);
	}
}

fn AstNode* ParseResult.new_node(&self, String tag, Span span, AstNode*[] children)
{
	String text = "";
	if (span.end.offset > span.start.offset) text = self.input[span.start.offset .. span.end.offset - 1];
	AstNode* node = alloc::new(self.allocator, AstNode, {
		.tag = tag.copy(self.allocator),
		.text = text.copy(self.allocator),
		.span = span,
		.children = alloc::clone_slice(self.allocator, children),
	});
	self.nodes.push(node);
	return node;
}

fn void ParseResult.deinit(&self)
{
	if (!self.allocator) return;
	self.rollback_nodes(0);
	self.nodes.free();
	self.diagnostic.deinit();
	alloc::free(self.allocator, self.source_name);
	alloc::free(self.allocator, self.input);
	*self = {};
}

struct ParseCursor { SourcePos position; }

struct ParseErrorInfo
{
	bool set;
	SourcePos position;
	String[16] expected;
	sz expected_count;
}

struct EvalResult
{
	bool ok;
	ParseCursor cursor;
	AstNode* node;
	ParseErrorInfo error;
}

struct EvalContext
{
	ParseResult* result;
	Parser*[128] active_rules;
	sz[128] active_offsets;
	sz active_count;
}

fn bool contains_char(String set, char value)
{
	foreach (candidate : set) if (candidate == value) return true;
	return false;
}

fn bool is_space(char value)
{
	return value == ' ' || value == '\f' || value == '\n' || value == '\r' || value == '\t' || value == '\v';
}

fn bool is_word_char(char value)
{
	return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') ||
		(value >= '0' && value <= '9') || value == '_';
}

fn void advance_cursor(ParseCursor* cursor, char value)
{
	cursor.position.offset++;
	if (value == '\n')
	{
		cursor.position.row++;
		cursor.position.column = 1;
	}
	else { cursor.position.column++; }
}

fn ParseErrorInfo error_at(SourcePos position, String expected)
{
	ParseErrorInfo error = { .set = true, .position = position };
	if (expected.len)
	{
		error.expected[0] = expected;
		error.expected_count = 1;
	}
	return error;
}

fn void merge_error(ParseErrorInfo* destination, ParseErrorInfo source)
{
	if (!source.set) return;
	if (!destination.set || source.position.offset > destination.position.offset)
	{
		*destination = source;
		return;
	}
	if (source.position.offset < destination.position.offset) return;
	for (sz i = 0; i < source.expected_count; i++)
	{
		String item = source.expected[i];
		bool duplicate;
		for (sz j = 0; j < destination.expected_count; j++)
		{
			if (destination.expected[j] == item) { duplicate = true; break; }
		}
		if (!duplicate && destination.expected_count < destination.expected.len)
		{
			destination.expected[destination.expected_count++] = item;
		}
	}
}

fn String parser_label(Parser* parser)
{
	if (parser.name.len) return parser.name;
	switch (parser.kind)
	{
		case LITERAL: return parser.text;
		case EXPECT:
		case FAIL: return parser.text;
		case EOI: return "end of input";
		case SOI: return "start of input";
		case RANGE: return "character in range";
		case ONE_OF: return "character from set";
		case NONE_OF: return "character outside set";
		case WORD_BOUNDARY: return parser.flag ? "non-word boundary" : "word boundary";
		case LINE_START: return "start of line";
		case LINE_END: return "end of line";
		default: return "character";
	}
}

fn String parser_node_tag(Parser* parser)
{
	if (parser.name.len) return parser.name;
	switch (parser.kind)
	{
		case LITERAL: return "string";
		case SEQUENCE: return "sequence";
		case MANY: return "many";
		case MANY1: return "many1";
		case COUNT: return "count";
		case SEP_BY: return "list";
		default: return "char";
	}
}


fn EvalResult eval_sequence(Parser* parser, ParseCursor start, EvalContext* context)
{
	sz node_mark = context.result.nodes.len();
	List{AstNode*} children;
	children.init(context.result.allocator);
	defer children.free();
	ParseCursor cursor = start;
	foreach (part : parser.parts)
	{
		EvalResult item = eval(part, cursor, context);
		if (!item.ok)
		{
			context.result.rollback_nodes(node_mark);
			return { .cursor = start, .error = item.error };
		}
		cursor = item.cursor;
		if (item.node) children.push(item.node);
	}
	Span span = { .start = start.position, .end = cursor.position };
	AstNode* node = context.result.new_node(parser_node_tag(parser), span, children.entries[:children.size]);
	return { .ok = true, .cursor = cursor, .node = node };
}

fn EvalResult eval_choice(Parser* parser, ParseCursor start, EvalContext* context, bool predictive)
{
	ParseErrorInfo combined;
	foreach (part : parser.parts)
	{
		EvalResult item = eval(part, start, context);
		if (item.ok) return item;
		merge_error(&combined, item.error);
		if (predictive && item.error.set && item.error.position.offset > start.position.offset)
		{
			return { .cursor = start, .error = item.error };
		}
	}
	if (!combined.set) combined = error_at(start.position, "alternative");
	return { .cursor = start, .error = combined };
}

fn EvalResult eval_repeat(Parser* parser, ParseCursor start, EvalContext* context, sz minimum, sz maximum)
{
	sz node_mark = context.result.nodes.len();
	List{AstNode*} children;
	children.init(context.result.allocator);
	defer children.free();
	ParseCursor cursor = start;
	sz matched;
	ParseErrorInfo last_error;
	while (matched < maximum)
	{
		sz iteration_mark = context.result.nodes.len();
		EvalResult item = eval(parser.first, cursor, context);
		if (!item.ok) { last_error = item.error; break; }
		if (item.cursor.position.offset == cursor.position.offset)
		{
			context.result.rollback_nodes(iteration_mark);
			break;
		}
		cursor = item.cursor;
		if (item.node) children.push(item.node);
		matched++;
	}
	if (matched < minimum)
	{
		context.result.rollback_nodes(node_mark);
		if (!last_error.set) last_error = error_at(cursor.position, "non-empty repetition");
		return { .cursor = start, .error = last_error };
	}
	Span span = { .start = start.position, .end = cursor.position };
	AstNode* node = context.result.new_node(parser_node_tag(parser), span, children.entries[:children.size]);
	return { .ok = true, .cursor = cursor, .node = node };
}

fn EvalResult eval_sep_by(Parser* parser, ParseCursor start, EvalContext* context)
{
	List{AstNode*} children;
	children.init(context.result.allocator);
	defer children.free();
	EvalResult first = eval(parser.first, start, context);
	if (!first.ok)
	{
		if (!parser.flag) return first;
		AstNode* empty = context.result.new_node(parser_node_tag(parser), { .start = start.position, .end = start.position }, {});
		return { .ok = true, .cursor = start, .node = empty };
	}
	ParseCursor cursor = first.cursor;
	if (first.node) children.push(first.node);
	while (true)
	{
		sz item_mark = context.result.nodes.len();
		EvalResult separator = eval(parser.second, cursor, context);
		if (!separator.ok) break;
		EvalResult item = eval(parser.first, separator.cursor, context);
		if (!item.ok || item.cursor.position.offset == cursor.position.offset)
		{
			context.result.rollback_nodes(item_mark);
			break;
		}
		cursor = item.cursor;
		if (item.node) children.push(item.node);
	}
	AstNode* node = context.result.new_node(parser_node_tag(parser), { .start = start.position, .end = cursor.position }, children.entries[:children.size]);
	return { .ok = true, .cursor = cursor, .node = node };
}

fn EvalResult eval(Parser* parser, ParseCursor start, EvalContext* context)
{
	String input = context.result.input;
	sz node_mark = context.result.nodes.len();
	switch (parser.kind)
	{
		case ANY_CHAR:
			if (start.position.offset >= input.len) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			ParseCursor any_end = start;
			advance_cursor(&any_end, input[any_end.position.offset]);
			return { .ok = true, .cursor = any_end, .node = context.result.new_node(parser_node_tag(parser), { .start = start.position, .end = any_end.position }, {}) };
		case CHARACTER:
			if (start.position.offset >= input.len || input[start.position.offset] != parser.low) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			ParseCursor char_end = start;
			advance_cursor(&char_end, input[char_end.position.offset]);
			return { .ok = true, .cursor = char_end, .node = context.result.new_node(parser_node_tag(parser), { .start = start.position, .end = char_end.position }, {}) };
		case RANGE:
			if (start.position.offset >= input.len || input[start.position.offset] < parser.low || input[start.position.offset] > parser.high) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			ParseCursor range_end = start;
			advance_cursor(&range_end, input[range_end.position.offset]);
			return { .ok = true, .cursor = range_end, .node = context.result.new_node(parser_node_tag(parser), { .start = start.position, .end = range_end.position }, {}) };
		case ONE_OF:
		case NONE_OF:
			if (start.position.offset >= input.len) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			bool found = contains_char(parser.text, input[start.position.offset]);
			if ((parser.kind == ONE_OF && !found) || (parser.kind == NONE_OF && found)) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			ParseCursor set_end = start;
			advance_cursor(&set_end, input[set_end.position.offset]);
			return { .ok = true, .cursor = set_end, .node = context.result.new_node(parser_node_tag(parser), { .start = start.position, .end = set_end.position }, {}) };
		case LITERAL:
			ParseCursor literal_end = start;
			foreach (expected : parser.text)
			{
				if (literal_end.position.offset >= input.len || input[literal_end.position.offset] != expected) return { .cursor = start, .error = error_at(literal_end.position, parser_label(parser)) };
				advance_cursor(&literal_end, expected);
			}
			return { .ok = true, .cursor = literal_end, .node = context.result.new_node(parser_node_tag(parser), { .start = start.position, .end = literal_end.position }, {}) };
		case SOI:
			if (start.position.offset != 0) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			return { .ok = true, .cursor = start };
		case EOI:
			if (start.position.offset != input.len) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			return { .ok = true, .cursor = start };
		case PASS: return { .ok = true, .cursor = start };
		case FAIL: return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
		case EXPECT:
			EvalResult expected_result = eval(parser.first, start, context);
			if (!expected_result.ok) expected_result.error = error_at(expected_result.error.set ? expected_result.error.position : start.position, parser.text);
			return expected_result;
		case SEQUENCE: return eval_sequence(parser, start, context);
		case CHOICE: return eval_choice(parser, start, context, false);
		case PREDICTIVE_CHOICE: return eval_choice(parser, start, context, true);
		case OPTIONAL:
			EvalResult optional_result = eval(parser.first, start, context);
			if (optional_result.ok) return optional_result;
			return { .ok = true, .cursor = start };
		case MANY: return eval_repeat(parser, start, context, 0, sz::max);
		case MANY1: return eval_repeat(parser, start, context, 1, sz::max);
		case COUNT: return eval_repeat(parser, start, context, parser.amount, parser.amount);
		case SEP_BY: return eval_sep_by(parser, start, context);
		case LOOKAHEAD:
			EvalResult ahead = eval(parser.first, start, context);
			context.result.rollback_nodes(node_mark);
			if (ahead.ok) return { .ok = true, .cursor = start };
			return { .cursor = start, .error = ahead.error };
		case NOT_FOLLOWED_BY:
			EvalResult negative = eval(parser.first, start, context);
			context.result.rollback_nodes(node_mark);
			if (negative.ok) return { .cursor = start, .error = error_at(start.position, "negative lookahead") };
			return { .ok = true, .cursor = start };
		case TOKEN:
			EvalResult token_result = eval(parser.first, start, context);
			if (!token_result.ok) return token_result;
			while (token_result.cursor.position.offset < input.len && is_space(input[token_result.cursor.position.offset])) advance_cursor(&token_result.cursor, input[token_result.cursor.position.offset]);
			return token_result;
		case WHOLE:
			EvalResult whole_result = eval(parser.first, start, context);
			if (!whole_result.ok) return whole_result;
			while (whole_result.cursor.position.offset < input.len && is_space(input[whole_result.cursor.position.offset])) advance_cursor(&whole_result.cursor, input[whole_result.cursor.position.offset]);
			if (whole_result.cursor.position.offset != input.len)
			{
				context.result.rollback_nodes(node_mark);
				return { .cursor = start, .error = error_at(whole_result.cursor.position, "end of input") };
			}
			return whole_result;
		case BETWEEN:
			EvalResult open_result = eval(parser.first, start, context);
			if (!open_result.ok) return open_result;
			EvalResult inner_result = eval(parser.second, open_result.cursor, context);
			if (!inner_result.ok) { context.result.rollback_nodes(node_mark); return { .cursor = start, .error = inner_result.error }; }
			EvalResult close_result = eval(parser.third, inner_result.cursor, context);
			if (!close_result.ok) { context.result.rollback_nodes(node_mark); return { .cursor = start, .error = close_result.error }; }
			inner_result.cursor = close_result.cursor;
			return inner_result;
		case RULE:
			if (!parser.target) return { .cursor = start, .error = error_at(start.position, parser.name) };
			for (sz i = 0; i < context.active_count; i++) if (context.active_rules[i] == parser && context.active_offsets[i] == start.position.offset) return { .cursor = start, .error = error_at(start.position, parser.name) };
			if (context.active_count >= context.active_rules.len) return { .cursor = start, .error = error_at(start.position, "recursion limit") };
			context.active_rules[context.active_count] = parser;
			context.active_offsets[context.active_count++] = start.position.offset;
			EvalResult rule_result = eval(parser.target, start, context);
			context.active_count--;
			if (!rule_result.ok) return rule_result;
			AstNode*[1] rule_children;
			AstNode*[] rule_slice = {};
			if (rule_result.node) { rule_children[0] = rule_result.node; rule_slice = rule_children[..]; }
			rule_result.node = context.result.new_node(parser.name, { .start = start.position, .end = rule_result.cursor.position }, rule_slice);
			return rule_result;
		case NAMED:
			EvalResult named_result = eval(parser.first, start, context);
			if (!named_result.ok) return named_result;
			AstNode*[1] named_children;
			AstNode*[] named_slice = {};
			if (named_result.node) { named_children[0] = named_result.node; named_slice = named_children[..]; }
			named_result.node = context.result.new_node(parser.name, { .start = start.position, .end = named_result.cursor.position }, named_slice);
			return named_result;
		case WORD_BOUNDARY:
			bool left_word = start.position.offset > 0 && is_word_char(input[start.position.offset - 1]);
			bool right_word = start.position.offset < input.len && is_word_char(input[start.position.offset]);
			bool boundary = left_word != right_word;
			if (parser.flag) boundary = !boundary;
			if (boundary) return { .ok = true, .cursor = start };
			return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
		case LINE_START:
			if (start.position.offset == 0 || input[start.position.offset - 1] == '\n') return { .ok = true, .cursor = start };
			return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
		case LINE_END:
			if (start.position.offset == input.len || input[start.position.offset] == '\n') return { .ok = true, .cursor = start };
			return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
	}
}


/**
 * Borrowing recognizer used by lexers. It mirrors `eval`'s cursor and
 * backtracking semantics without owning the input or constructing AST nodes.
 */
struct PrefixContext
{
	String input;
	Parser*[128] active_rules;
	sz[128] active_offsets;
	sz active_count;
}


fn EvalResult recognize_sequence(Parser* parser, ParseCursor start, PrefixContext* context)
{
	ParseCursor cursor = start;
	foreach (part : parser.parts)
	{
		EvalResult item = recognize_eval(part, cursor, context);
		if (!item.ok) return { .cursor = start, .error = item.error };
		cursor = item.cursor;
	}
	return { .ok = true, .cursor = cursor };
}

fn EvalResult recognize_choice(
	Parser* parser,
	ParseCursor start,
	PrefixContext* context,
	bool predictive
)
{
	ParseErrorInfo combined;
	foreach (part : parser.parts)
	{
		EvalResult item = recognize_eval(part, start, context);
		if (item.ok) return item;
		merge_error(&combined, item.error);
		if (predictive && item.error.set && item.error.position.offset > start.position.offset)
		{
			return { .cursor = start, .error = item.error };
		}
	}
	if (!combined.set) combined = error_at(start.position, "alternative");
	return { .cursor = start, .error = combined };
}

fn EvalResult recognize_repeat(
	Parser* parser,
	ParseCursor start,
	PrefixContext* context,
	sz minimum,
	sz maximum
)
{
	ParseCursor cursor = start;
	sz matched;
	ParseErrorInfo last_error;
	while (matched < maximum)
	{
		EvalResult item = recognize_eval(parser.first, cursor, context);
		if (!item.ok) { last_error = item.error; break; }
		if (item.cursor.position.offset == cursor.position.offset) break;
		cursor = item.cursor;
		matched++;
	}
	if (matched < minimum)
	{
		if (!last_error.set) last_error = error_at(cursor.position, "non-empty repetition");
		return { .cursor = start, .error = last_error };
	}
	return { .ok = true, .cursor = cursor };
}

fn EvalResult recognize_sep_by(Parser* parser, ParseCursor start, PrefixContext* context)
{
	EvalResult first = recognize_eval(parser.first, start, context);
	if (!first.ok)
	{
		if (!parser.flag) return first;
		return { .ok = true, .cursor = start };
	}
	ParseCursor cursor = first.cursor;
	while (true)
	{
		EvalResult separator = recognize_eval(parser.second, cursor, context);
		if (!separator.ok) break;
		EvalResult item = recognize_eval(parser.first, separator.cursor, context);
		if (!item.ok || item.cursor.position.offset == cursor.position.offset) break;
		cursor = item.cursor;
	}
	return { .ok = true, .cursor = cursor };
}

fn EvalResult recognize_eval(Parser* parser, ParseCursor start, PrefixContext* context)
{
	String input = context.input;
	switch (parser.kind)
	{
		case ANY_CHAR:
			if (start.position.offset >= input.len) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			ParseCursor any_end = start;
			advance_cursor(&any_end, input[any_end.position.offset]);
			return { .ok = true, .cursor = any_end };
		case CHARACTER:
			if (start.position.offset >= input.len || input[start.position.offset] != parser.low) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			ParseCursor char_end = start;
			advance_cursor(&char_end, input[char_end.position.offset]);
			return { .ok = true, .cursor = char_end };
		case RANGE:
			if (start.position.offset >= input.len || input[start.position.offset] < parser.low || input[start.position.offset] > parser.high) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			ParseCursor range_end = start;
			advance_cursor(&range_end, input[range_end.position.offset]);
			return { .ok = true, .cursor = range_end };
		case ONE_OF:
		case NONE_OF:
			if (start.position.offset >= input.len) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			bool found = contains_char(parser.text, input[start.position.offset]);
			if ((parser.kind == ONE_OF && !found) || (parser.kind == NONE_OF && found)) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			ParseCursor set_end = start;
			advance_cursor(&set_end, input[set_end.position.offset]);
			return { .ok = true, .cursor = set_end };
		case LITERAL:
			ParseCursor literal_end = start;
			foreach (expected : parser.text)
			{
				if (literal_end.position.offset >= input.len || input[literal_end.position.offset] != expected) return { .cursor = start, .error = error_at(literal_end.position, parser_label(parser)) };
				advance_cursor(&literal_end, expected);
			}
			return { .ok = true, .cursor = literal_end };
		case SOI:
			if (start.position.offset != 0) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			return { .ok = true, .cursor = start };
		case EOI:
			if (start.position.offset != input.len) return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
			return { .ok = true, .cursor = start };
		case PASS: return { .ok = true, .cursor = start };
		case FAIL: return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
		case EXPECT:
			EvalResult expected_result = recognize_eval(parser.first, start, context);
			if (!expected_result.ok) expected_result.error = error_at(expected_result.error.set ? expected_result.error.position : start.position, parser.text);
			return expected_result;
		case SEQUENCE: return recognize_sequence(parser, start, context);
		case CHOICE: return recognize_choice(parser, start, context, false);
		case PREDICTIVE_CHOICE: return recognize_choice(parser, start, context, true);
		case OPTIONAL:
			EvalResult optional_result = recognize_eval(parser.first, start, context);
			return optional_result.ok ? optional_result : { .ok = true, .cursor = start };
		case MANY: return recognize_repeat(parser, start, context, 0, sz::max);
		case MANY1: return recognize_repeat(parser, start, context, 1, sz::max);
		case COUNT: return recognize_repeat(parser, start, context, parser.amount, parser.amount);
		case SEP_BY: return recognize_sep_by(parser, start, context);
		case LOOKAHEAD:
			EvalResult ahead = recognize_eval(parser.first, start, context);
			return ahead.ok ? { .ok = true, .cursor = start } : { .cursor = start, .error = ahead.error };
		case NOT_FOLLOWED_BY:
			EvalResult negative = recognize_eval(parser.first, start, context);
			if (negative.ok) return { .cursor = start, .error = error_at(start.position, "negative lookahead") };
			return { .ok = true, .cursor = start };
		case TOKEN:
			EvalResult token_result = recognize_eval(parser.first, start, context);
			if (!token_result.ok) return token_result;
			while (token_result.cursor.position.offset < input.len && is_space(input[token_result.cursor.position.offset])) advance_cursor(&token_result.cursor, input[token_result.cursor.position.offset]);
			return token_result;
		case WHOLE:
			EvalResult whole_result = recognize_eval(parser.first, start, context);
			if (!whole_result.ok) return whole_result;
			while (whole_result.cursor.position.offset < input.len && is_space(input[whole_result.cursor.position.offset])) advance_cursor(&whole_result.cursor, input[whole_result.cursor.position.offset]);
			if (whole_result.cursor.position.offset != input.len) return { .cursor = start, .error = error_at(whole_result.cursor.position, "end of input") };
			return whole_result;
		case BETWEEN:
			EvalResult open_result = recognize_eval(parser.first, start, context);
			if (!open_result.ok) return open_result;
			EvalResult inner_result = recognize_eval(parser.second, open_result.cursor, context);
			if (!inner_result.ok) return { .cursor = start, .error = inner_result.error };
			EvalResult close_result = recognize_eval(parser.third, inner_result.cursor, context);
			if (!close_result.ok) return { .cursor = start, .error = close_result.error };
			inner_result.cursor = close_result.cursor;
			return inner_result;
		case RULE:
			if (!parser.target) return { .cursor = start, .error = error_at(start.position, parser.name) };
			for (sz i = 0; i < context.active_count; i++) if (context.active_rules[i] == parser && context.active_offsets[i] == start.position.offset) return { .cursor = start, .error = error_at(start.position, parser.name) };
			if (context.active_count >= context.active_rules.len) return { .cursor = start, .error = error_at(start.position, "recursion limit") };
			context.active_rules[context.active_count] = parser;
			context.active_offsets[context.active_count++] = start.position.offset;
			EvalResult rule_result = recognize_eval(parser.target, start, context);
			context.active_count--;
			return rule_result;
		case NAMED: return recognize_eval(parser.first, start, context);
		case WORD_BOUNDARY:
			bool left_word = start.position.offset > 0 && is_word_char(input[start.position.offset - 1]);
			bool right_word = start.position.offset < input.len && is_word_char(input[start.position.offset]);
			bool boundary = left_word != right_word;
			if (parser.flag) boundary = !boundary;
			return boundary ? { .ok = true, .cursor = start } : { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
		case LINE_START:
			if (start.position.offset == 0 || input[start.position.offset - 1] == '\n') return { .ok = true, .cursor = start };
			return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
		case LINE_END:
			if (start.position.offset == input.len || input[start.position.offset] == '\n') return { .ok = true, .cursor = start };
			return { .cursor = start, .error = error_at(start.position, parser_label(parser)) };
	}
}

fn ParseResult parse(Parser* parser, String input, Allocator allocator, String source_name = "<input>")
{
	ParseResult result = { .allocator = allocator, .source_name = source_name.copy(allocator), .input = input.copy(allocator) };
	result.nodes.init(allocator);
	ParseCursor start = { .position = source_start() };
	EvalContext context = { .result = &result };
	EvalResult evaluated = eval(parser, start, &context);
	result.ok = evaluated.ok;
	result.consumed = { .start = start.position, .end = evaluated.ok ? evaluated.cursor.position : start.position };
	if (evaluated.ok) { result.root = evaluated.node; }
	else
	{
		SourcePos position = evaluated.error.set ? evaluated.error.position : start.position;
		result.diagnostic.init(allocator, "parse error", span_at(position));
		for (sz i = 0; i < evaluated.error.expected_count; i++) result.diagnostic.add_expected(evaluated.error.expected[i]);
	}
	return result;
}

fn ParseResult? parse_file(Parser* parser, String path, Allocator allocator)
{
	char[] contents = file::load(allocator, path)!;
	defer alloc::free(allocator, contents);
	return parse(parser, (String)contents, allocator, path);
}

fn bool match_prefix(Parser* parser, String input, sz* consumed)
{
	ParseCursor start = { .position = source_start() };
	PrefixContext context = { .input = input };
	EvalResult result = recognize_eval(parser, start, &context);
	if (!result.ok) { *consumed = 0; return false; }
	*consumed = result.cursor.position.offset;
	return true;
}
