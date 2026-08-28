// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module mpc;

import std::core::mem;

struct RegexOptions
{
	bool multiline;
	bool dotall;
}

struct RegexCompileResult
{
	Allocator allocator;
	Parser* parser;
	Diagnostic[] diagnostics;
}

fn bool RegexCompileResult.ok(&self) => self.parser != null && self.diagnostics.len == 0;

fn void RegexCompileResult.deinit(&self)
{
	if (!self.allocator) return;
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = {};
}

struct RegexCompiler @private
{
	ParserArena* arena;
	String source;
	RegexOptions options;
	sz offset;
	bool failed;
	Diagnostic diagnostic;
}

fn SourcePos RegexCompiler.position_at(&self, sz offset)
{
	SourcePos position = source_start();
	for (sz i = 0; i < offset && i < self.source.len; i++)
	{
		position.offset++;
		if (self.source[i] == '\n')
		{
			position.row++;
			position.column = 1;
		}
		else
		{
			position.column++;
		}
	}
	return position;
}

fn void RegexCompiler.report(&self, String message, String expected, sz start, sz end)
{
	if (self.failed) return;
	self.failed = true;
	if (end > self.source.len) end = self.source.len;
	if (start > end) start = end;
	Span span = {
		.start = self.position_at(start),
		.end = self.position_at(end),
	};
	self.diagnostic.init(self.arena.allocator, message, span);
	if (expected.len) self.diagnostic.add_expected(expected);
}

fn bool RegexCompiler.at_end(&self) => self.offset >= self.source.len;

fn bool RegexCompiler.peek_is(&self, char value)
{
	return !self.at_end() && self.source[self.offset] == value;
}

fn bool RegexCompiler.take_if(&self, char value)
{
	if (!self.peek_is(value)) return false;
	self.offset++;
	return true;
}

fn bool regex_ascii_letter(char value) @private
{
	return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z');
}

fn Parser* regex_sequence(ParserArena* arena, Parser* first, Parser* second) @private
{
	Parser*[2] parsers = { first, second };
	return arena.sequence(parsers[..]);
}

fn Parser* regex_choice(ParserArena* arena, Parser* first, Parser* second) @private
{
	Parser*[2] parsers = { first, second };
	return arena.choice(parsers[..]);
}

fn Parser* regex_complement(ParserArena* arena, Parser* parser) @private
{
	return regex_sequence(arena, arena.not_followed_by(parser), arena.any_char());
}

fn Parser* regex_digits(ParserArena* arena) @private => arena.range('0', '9');

fn Parser* regex_space(ParserArena* arena) @private
{
	return arena.one_of(" \f\n\r\t\v");
}

fn Parser* regex_word(ParserArena* arena) @private
{
	Parser*[4] parsers = {
		arena.range('a', 'z'),
		arena.range('A', 'Z'),
		arena.range('0', '9'),
		arena.character('_'),
	};
	return arena.choice(parsers[..]);
}

fn Parser* RegexCompiler.escape_parser(&self, bool in_class, bool* single, char* value)
{
	sz slash = self.offset;
	self.offset++;
	if (self.at_end())
	{
		self.report("unterminated escape sequence", "a character after '\\'", slash, self.offset);
		return null;
	}

	char escaped = self.source[self.offset++];
	*single = false;
	*value = 0;

	switch (escaped)
	{
		case 'a': *single = true; *value = (char)7; return self.arena.character(*value);
		case '0': *single = true; *value = '\0'; return self.arena.character(*value);
		case 'f': *single = true; *value = '\f'; return self.arena.character(*value);
		case 'n': *single = true; *value = '\n'; return self.arena.character(*value);
		case 'r': *single = true; *value = '\r'; return self.arena.character(*value);
		case 't': *single = true; *value = '\t'; return self.arena.character(*value);
		case 'v': *single = true; *value = '\v'; return self.arena.character(*value);
		case 'd': return regex_digits(self.arena);
		case 'D': return regex_complement(self.arena, regex_digits(self.arena));
		case 's': return regex_space(self.arena);
		case 'S': return regex_complement(self.arena, regex_space(self.arena));
		case 'w': return regex_word(self.arena);
		case 'W': return regex_complement(self.arena, regex_word(self.arena));
		case 'b':
			if (!in_class) return self.arena.word_boundary();
			*single = true;
			*value = '\b';
			return self.arena.character(*value);
		case 'B':
			if (!in_class) return self.arena.word_boundary(true);
			*single = true;
			*value = 'B';
			return self.arena.character(*value);
		case 'A':
			if (!in_class) return self.arena.soi();
			*single = true;
			*value = 'A';
			return self.arena.character(*value);
		case 'Z':
			if (!in_class) return self.arena.eoi();
			*single = true;
			*value = 'Z';
			return self.arena.character(*value);
		default:
			if (regex_ascii_letter(escaped))
			{
				self.report("unknown regular-expression escape", "a supported escape", slash, self.offset);
				return null;
			}
			*single = true;
			*value = escaped;
			return self.arena.character(escaped);
	}
}

fn Parser* RegexCompiler.class_item(&self, bool* single, char* value)
{
	if (self.peek_is('\\')) return self.escape_parser(true, single, value);
	if (self.at_end() || self.peek_is(']'))
	{
		self.report("missing character-class item", "a class character", self.offset, self.offset);
		return null;
	}
	*single = true;
	*value = self.source[self.offset++];
	return self.arena.character(*value);
}

fn Parser* RegexCompiler.character_class(&self)
{
	sz open = self.offset;
	self.offset++;
	bool negated = self.take_if('^');
	Parser*[] alternatives = mem::temp_array(Parser*, self.source.len - open + 1);
	sz count;

	while (!self.at_end() && !self.peek_is(']'))
	{
		bool left_single;
		char left_value;
		sz item_start = self.offset;
		Parser* item = self.class_item(&left_single, &left_value);
		if (self.failed) return null;

		if (self.peek_is('-') && self.offset + 1 < self.source.len && self.source[self.offset + 1] != ']')
		{
			self.offset++;
			bool right_single;
			char right_value;
			Parser* right = self.class_item(&right_single, &right_value);
			if (self.failed) return null;
			if (!left_single || !right_single)
			{
				self.report("character-class ranges require literal endpoints", "a literal range endpoint", item_start, self.offset);
				return null;
			}
			if (left_value > right_value)
			{
				self.report("descending character-class range", "an endpoint not less than the start", item_start, self.offset);
				return null;
			}
			item = self.arena.range(left_value, right_value);
		}
		alternatives[count++] = item;
	}

	if (!self.take_if(']'))
	{
		self.report("unterminated character class", "']'", open, self.offset);
		return null;
	}
	if (count == 0)
	{
		self.report("empty character class", "at least one class item", open, self.offset);
		return null;
	}

	Parser* included = count == 1 ? alternatives[0] : self.arena.choice(alternatives[:count]);
	return negated ? regex_complement(self.arena, included) : included;
}

fn Parser* RegexCompiler.end_anchor(&self)
{
	if (self.options.multiline) return regex_choice(self.arena, self.arena.character('\n'), self.arena.eoi());
	Parser* newline_then_end = regex_sequence(self.arena, self.arena.character('\n'), self.arena.eoi());
	return regex_choice(self.arena, self.arena.eoi(), self.arena.lookahead(newline_then_end));
}

fn Parser* RegexCompiler.atom(&self)
{
	if (self.at_end())
	{
		self.report("missing regular-expression atom", "an expression", self.offset, self.offset);
		return null;
	}

	sz start = self.offset;
	char current = self.source[self.offset];
	switch (current)
	{
		case '(':
			self.offset++;
			Parser* enclosed = self.expression();
			if (self.failed) return null;
			if (!self.take_if(')'))
			{
				self.report("unterminated group", "')'", start, self.offset);
				return null;
			}
			return enclosed;
		case '[': return self.character_class();
		case '.':
			self.offset++;
			return self.options.dotall ? self.arena.any_char() : self.arena.none_of("\n");
		case '^':
			self.offset++;
			return self.options.multiline ? self.arena.line_start() : self.arena.soi();
		case '$':
			self.offset++;
			return self.end_anchor();
		case '\\':
			bool single;
			char value;
			return self.escape_parser(false, &single, &value);
		default:
			self.offset++;
			return self.arena.character(current);
	}
}

fn Parser* RegexCompiler.repetition(&self)
{
	Parser* parser = self.atom();
	if (self.failed) return null;
	if (self.at_end()) return parser;

	sz quantifier = self.offset;
	if (self.take_if('*')) { parser = self.arena.many(parser); }
	else if (self.take_if('+')) { parser = self.arena.many1(parser); }
	else if (self.take_if('?')) { parser = self.arena.optional(parser); }
	else if (self.take_if('{'))
	{
		if (self.at_end() || self.source[self.offset] < '0' || self.source[self.offset] > '9')
		{
			self.report("exact repetition requires a decimal count", "a decimal count", quantifier, self.offset);
			return null;
		}
		ulong count;
		while (!self.at_end() && self.source[self.offset] >= '0' && self.source[self.offset] <= '9')
		{
			uint digit = (uint)(self.source[self.offset] - '0');
			if (count > 1844674407370955161UL || (count == 1844674407370955161UL && digit > 5))
			{
				while (!self.at_end() && self.source[self.offset] >= '0' && self.source[self.offset] <= '9') self.offset++;
				self.report("exact repetition count is too large", "a count representable as sz", quantifier, self.offset);
				return null;
			}
			count = count * 10 + digit;
			self.offset++;
		}
		if (!self.take_if('}'))
		{
			self.report("unterminated exact repetition", "'}'", quantifier, self.offset);
			return null;
		}
		parser = count == 0 ? self.arena.pass() : self.arena.count(parser, (sz)count);
	}
	else { return parser; }

	if (!self.at_end())
	{
		char next = self.source[self.offset];
		if (next == '*' || next == '+' || next == '?' || next == '{')
		{
			self.report("multiple repetition operators on one atom", "the next expression", self.offset, self.offset + 1);
			return null;
		}
	}
	return parser;
}

fn Parser* RegexCompiler.concatenation(&self)
{
	Parser*[] parsers = mem::temp_array(Parser*, self.source.len - self.offset + 1);
	sz count;
	while (!self.at_end() && !self.peek_is('|') && !self.peek_is(')'))
	{
		char current = self.source[self.offset];
		if (current == '*' || current == '+' || current == '?' || current == '{')
		{
			self.report("repetition operator has no target", "a regular-expression atom", self.offset, self.offset + 1);
			return null;
		}
		parsers[count++] = self.repetition();
		if (self.failed) return null;
	}
	if (count == 0) return self.arena.pass();
	if (count == 1) return parsers[0];
	return self.arena.sequence(parsers[:count]);
}

fn Parser* RegexCompiler.expression(&self)
{
	Parser*[] alternatives = mem::temp_array(Parser*, self.source.len - self.offset + 1);
	sz count;
	alternatives[count++] = self.concatenation();
	if (self.failed) return null;
	while (self.take_if('|'))
	{
		alternatives[count++] = self.concatenation();
		if (self.failed) return null;
	}
	return count == 1 ? alternatives[0] : self.arena.choice(alternatives[:count]);
}

fn RegexCompileResult compile_regex(ParserArena* arena, String pattern, RegexOptions options = {})
{
	RegexCompiler compiler = {
		.arena = arena,
		.source = pattern,
		.options = options,
	};
	Parser* parser = compiler.expression();
	if (!compiler.failed && !compiler.at_end())
	{
		if (compiler.peek_is(')'))
		{
			compiler.report("unmatched closing parenthesis", "the end of the pattern", compiler.offset, compiler.offset + 1);
		}
		else
		{
			compiler.report("unexpected regular-expression syntax", "the end of the pattern", compiler.offset, compiler.offset + 1);
		}
	}

	if (compiler.failed)
	{
		Diagnostic[] diagnostics = alloc::new_array(arena.allocator, Diagnostic, 1);
		diagnostics[0] = compiler.diagnostic;
		return { .allocator = arena.allocator, .diagnostics = diagnostics };
	}
	return { .allocator = arena.allocator, .parser = parser };
}
