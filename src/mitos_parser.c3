module delta_net_abstract_machine::mitos;

import mpc;
import std::collections::list;
import std::core::mem;
import std::io;

const usz MITOS_MAX_EXPRESSION_DEPTH = 256;
const usz MITOS_MAX_TYPE_DEPTH = 256;
const sz MITOS_MAX_TOKENS = 100_000;
const sz MITOS_MAX_LEXER_MATCHES = MITOS_MAX_TOKENS * 2;
const sz MITOS_MAX_TOP_LEVEL_DECLARATIONS = 2_048;
const sz MITOS_MAX_PARAMETERS = 256;
const sz MITOS_MAX_TYPE_ARGUMENTS = 256;
const sz MITOS_MAX_ENUM_VARIANTS = 512;
const sz MITOS_MAX_TYPE_FIELDS = 512;
const sz MITOS_MAX_EFFECT_OPERATIONS = 512;
const sz MITOS_MAX_HANDLER_CLAUSES = 512;
const sz MITOS_MAX_MATCH_ARMS = 512;
const sz MITOS_MAX_SEQUENTIAL_DEFINITIONS = 256;
const sz MITOS_MAX_PARALLEL_BINDINGS = 256;
const usz MITOS_MAX_STRING_LITERAL_SOURCE_BYTES = MITOS_MAX_STRING_LITERAL_BYTES * 2 + 2;

struct MitosParseResult
{
	Allocator allocator;
	Program program;
	MitosDiagnostic[] diagnostics;
}

fn bool MitosParseResult.ok(&self) => self.diagnostics.len == 0;

fn void MitosParseResult.deinit(&self)
{
	if (!self.allocator) return;
	self.program.deinit();
	foreach (&diagnostic : self.diagnostics) diagnostic.deinit();
	alloc::free(self.allocator, self.diagnostics);
	*self = {};
}

enum MitosParseStop : char
{
	MITOS_STOP_END,
	MITOS_STOP_MATCH_ARM,
	MITOS_STOP_HANDLER_CLAUSE,
}

struct MitosPendingDefinition
{
	String name;
	TypeAnnotation annotation;
	SurfaceExpr* value;
	MitosSpan span;
}

struct MitosSourceParser
{
	Allocator allocator;
	TokenCursor* cursor;
	List{MitosDiagnostic}* diagnostics;
	usz expression_depth;
	usz type_depth;
	usz handler_clause_depth;
}

fn MitosPosition mitos_position(SourcePos position) @private
{
	return { .offset = position.offset, .row = position.row, .column = position.column };
}

fn MitosSpan mitos_span(Span span) @private
{
	return { .start = mitos_position(span.start), .end = mitos_position(span.end) };
}

fn MitosSpan mitos_span_between(SourcePos start, SourcePos end) @private
{
	return { .start = mitos_position(start), .end = mitos_position(end) };
}

fn SourcePos mitos_source_end(String source) @private
{
	SourcePos position = { .offset = 0, .row = 1, .column = 1 };
	foreach (character : source)
	{
		position.offset++;
		if (character == '\n')
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

fn void mitos_advance_source_position(SourcePos* position, String text) @private
{
	foreach (character : text)
	{
		position.offset++;
		if (character == '\n')
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

fn LexResult mitos_lex_bounded(
	Lexer* lexer,
	String input,
	sz max_tokens,
	sz max_matches
) @private
{
	LexResult result;
	result.allocator = lexer.allocator;
	result.tokens.init(lexer.allocator);
	result.diagnostics.init(lexer.allocator);
	SourcePos position = { .offset = 0, .row = 1, .column = 1 };
	sz matched_count;
	while ((usz)position.offset < input.len)
	{
		if (matched_count >= max_matches)
		{
			Diagnostic diagnostic;
			diagnostic.init(
				lexer.allocator, "source cannot contain more than 200000 lexer matches",
				{ .start = position, .end = position }
			);
			result.diagnostics.push(diagnostic);
			return result;
		}
		usz offset = (usz)position.offset;
		String remaining = input[offset:input.len - offset];
		sz best_rule = -1;
		sz best_length = 0;
		for (sz index = 0; index < lexer.rules.len(); index++)
		{
			sz consumed = 0;
			if (mpc::match_prefix(lexer.rules[index].parser, remaining, &consumed)
				&& consumed > best_length)
			{
				best_rule = index;
				best_length = consumed;
			}
		}
		if (best_rule < 0)
		{
			SourcePos start = position;
			mitos_advance_source_position(&position, input[offset:1]);
			Diagnostic diagnostic;
			diagnostic.init(
				lexer.allocator, "no lexer rule matches this input",
				{ .start = start, .end = position }
			);
			result.diagnostics.push(diagnostic);
			return result;
		}
		SourcePos start = position;
		String text = input[offset:(usz)best_length];
		mitos_advance_source_position(&position, text);
		matched_count++;
		CompiledLexerRule* rule = &lexer.rules[(usz)best_rule];
		if (rule.ignored) continue;
		if (result.tokens.len() >= max_tokens)
		{
			Diagnostic diagnostic;
			diagnostic.init(
				lexer.allocator, "source cannot contain more than 100000 tokens",
				{ .start = start, .end = position }
			);
			result.diagnostics.push(diagnostic);
			return result;
		}
		result.tokens.push({
			.kind = rule.kind,
			.text = text,
			.span = { .start = start, .end = position },
		});
	}
	return result;
}

fn MitosSpan mitos_current_span(MitosSourceParser* parser) @private
{
	Token* token = parser.cursor.peek();
	if (token) return mitos_span(token.span);
	return mitos_span_between(parser.cursor.eof_position, parser.cursor.eof_position);
}

fn void mitos_add_error(MitosSourceParser* parser, String message, MitosSpan span) @private
{
	MitosDiagnostic diagnostic;
	diagnostic.init(parser.allocator, message, span);
	parser.diagnostics.push(diagnostic);
}

fn void mitos_copy_mpc_diagnostic(List{MitosDiagnostic}* diagnostics, Allocator allocator, Diagnostic* source) @private
{
	MitosDiagnostic diagnostic;
	diagnostic.init(allocator, source.message, mitos_span(source.span));
	diagnostics.push(diagnostic);
}

fn void mitos_skip_newlines(MitosSourceParser* parser) @private
{
	while (parser.cursor.match("NEWLINE")) {}
}

fn Token* mitos_expect(MitosSourceParser* parser, String kind, String message) @private
{
	Token* token = parser.cursor.expect(kind, message);
	return token;
}

fn void mitos_free_expression(Allocator allocator, SurfaceExpr* expression) @private
{
	if (!expression) return;
	expression.deinit(allocator);
	alloc::free(allocator, expression);
}

fn bool mitos_check_expression_height(
	MitosSourceParser* parser,
	usz child_height,
	MitosSpan span
) @private
{
	if (child_height < MITOS_MAX_EXPRESSION_DEPTH) return true;
	mitos_add_error(parser, "expression structure exceeds the maximum height of 256", span);
	return false;
}

fn void mitos_free_expressions(Allocator allocator, List{SurfaceExpr*}* expressions) @private
{
	foreach (expression : *expressions) mitos_free_expression(allocator, expression);
	expressions.free();
}

fn void mitos_free_names(Allocator allocator, List{String}* names) @private
{
	foreach (name : *names) alloc::free(allocator, name);
	names.free();
}

fn void mitos_free_annotations(Allocator allocator, List{TypeAnnotation}* annotations) @private
{
	foreach (&annotation : *annotations) annotation.deinit(allocator);
	annotations.free();
}

fn void mitos_free_type_parameters(Allocator allocator, List{TypeParameterDecl}* parameters) @private
{
	foreach (&parameter : *parameters) alloc::free(allocator, parameter.name);
	parameters.free();
}

fn void mitos_free_type_arguments(Allocator allocator, List{TypeArgument}* arguments) @private
{
	foreach (&argument : *arguments)
	{
		if (!argument.value) continue;
		argument.value.deinit(allocator);
		alloc::free(allocator, argument.value);
	}
	arguments.free();
}

fn bool mitos_name_exists(List{String}* names, String name) @private
{
	foreach (existing : *names) if (existing == name) return true;
	return false;
}

fn void mitos_free_pending_definitions(Allocator allocator, List{MitosPendingDefinition}* bindings) @private
{
	foreach (&binding : *bindings)
	{
		alloc::free(allocator, binding.name);
		binding.annotation.deinit(allocator);
		mitos_free_expression(allocator, binding.value);
	}
	bindings.free();
}

fn SurfaceExpr* mitos_new_variable(MitosSourceParser* parser, Token* token) @private
{
	return alloc::new(parser.allocator, SurfaceExpr, {
		.kind = SURFACE_VARIABLE,
		.structural_height = 1,
		.span = mitos_span(token.span),
		.data = { .variable = { .name = token.text.copy(parser.allocator) } },
	});
}

fn SurfaceExpr* mitos_new_integer(MitosSourceParser* parser, Token* token) @private
{
	ulong value = 0;
	foreach (character : token.text)
	{
		ulong digit = (ulong)(character - '0');
		if (value > 922337203685477580 || (value == 922337203685477580 && digit > 7))
		{
			mitos_add_error(parser, "integer literal is outside the signed 64-bit range", mitos_span(token.span));
			return null;
		}
		value = value * 10 + digit;
	}
	return alloc::new(parser.allocator, SurfaceExpr, {
		.kind = SURFACE_INTEGER,
		.structural_height = 1,
		.span = mitos_span(token.span),
		.data = { .integer = { .value = (long)value } },
	});
}

fn SurfaceExpr* mitos_new_string(MitosSourceParser* parser, Token* token) @private
{
	MitosSpan span = mitos_span(token.span);
	if (token.text.len < 2 || token.text[0] != '"' || token.text[token.text.len - 1] != '"')
	{
		mitos_add_error(parser, "malformed string literal", span);
		return null;
	}
	if (token.text.len > MITOS_MAX_STRING_LITERAL_SOURCE_BYTES)
	{
		mitos_add_error(parser, "string literal source cannot exceed 2097154 bytes", span);
		return null;
	}
	DString decoded;
	decoded.init(parser.allocator);
	defer decoded.free();
	for (usz index = 1; index + 1 < token.text.len; index++)
	{
		char character = token.text[index];
		if (character == '\\')
		{
			index++;
			if (index >= token.text.len - 1)
			{
				mitos_add_error(parser, "unterminated escape sequence in string literal", span);
				return null;
			}
			char escaped = token.text[index];
			if (escaped == '"')
			{
				character = '"';
			}
			else if (escaped == '\\')
			{
				character = '\\';
			}
			else if (escaped == 'n')
			{
				character = '\n';
			}
			else if (escaped == 'r')
			{
				character = '\r';
			}
			else if (escaped == 't')
			{
				character = '\t';
			}
			else
			{
				mitos_add_error(parser, "unsupported string escape; use \\\" \\\\ \\n \\r or \\t", span);
				return null;
			}
		}
		else if (character == '\0')
		{
			mitos_add_error(parser, "string literal cannot contain a NUL byte", span);
			return null;
		}
		if (decoded.str_view().len >= MITOS_MAX_STRING_LITERAL_BYTES)
		{
			mitos_add_error(parser, "decoded string literal cannot exceed 1048576 bytes", span);
			return null;
		}
		decoded.append_char(character);
	}
	return alloc::new(parser.allocator, SurfaceExpr, {
		.kind = SURFACE_STRING,
		.structural_height = 1,
		.span = span,
		.data = { .string = { .value = decoded.copy_str(parser.allocator) } },
	});
}

fn SurfaceExpr* mitos_new_application(MitosSourceParser* parser, SurfaceExpr* callee, List{SurfaceExpr*}* arguments, SourcePos end) @private
{
	usz child_height = callee.structural_height;
	foreach (argument : *arguments)
	{
		if (argument.structural_height > child_height) child_height = argument.structural_height;
	}
	MitosSpan span = { .start = callee.span.start, .end = mitos_position(end) };
	if (!mitos_check_expression_height(parser, child_height, span))
	{
		mitos_free_expression(parser.allocator, callee);
		mitos_free_expressions(parser.allocator, arguments);
		return null;
	}
	SurfaceExpr*[] owned_arguments = arguments.to_array(parser.allocator);
	arguments.free();
	return alloc::new(parser.allocator, SurfaceExpr, {
		.kind = SURFACE_APPLICATION,
		.span = span,
		.structural_height = child_height + 1,
		.data = { .application = { .callee = callee, .arguments = owned_arguments } },
	});
}

fn TypeExpr* mitos_parse_type_expr(MitosSourceParser* parser) @private
{
	if (parser.type_depth >= MITOS_MAX_TYPE_DEPTH)
	{
		mitos_add_error(parser, "type expression nesting exceeds the maximum depth of 256", mitos_current_span(parser));
		return null;
	}
	parser.type_depth++;
	defer parser.type_depth--;
	Token* name = parser.cursor.peek();
	if (!name || !name.is("IDENTIFIER"))
	{
		String message = "expected a type name";
		if (name && name.is("DOUBLE_COLON"))
		{
			message = "'::' type qualification is forbidden; use nominal names and 'of'";
		}
		else if (name && (name.is("LBRACKET") || name.is("RBRACKET")))
		{
			message = "square-bracket generic syntax is forbidden; use 'of'";
		}
		else if (name && (name.is("LESS") || name.is("GREATER") || name.is("SUBTYPE")))
		{
			message = "angle-bracket and '<:' type syntax is forbidden; use 'of' and type-header 'is'";
		}
		else if (name && name.is("WHERE"))
		{
			message = "'where' clauses are forbidden; use implicit single-uppercase method variables";
		}
		else if (name && name.is("PIPE"))
		{
			message = "union types are not supported";
		}
		mitos_add_error(parser, message, name ? mitos_span(name.span) : mitos_current_span(parser));
		return null;
	}
	parser.cursor.advance();
	TypeExpr* expression = alloc::new(parser.allocator, TypeExpr, {
		.kind = TYPE_EXPR_NAMED,
		.name = name.text.copy(parser.allocator),
		.span = mitos_span(name.span),
	});
	if (!parser.cursor.match("OF")) return expression;
	List{TypeArgument} arguments;
	arguments.init(parser.allocator);
	SourcePos end;
	if (parser.cursor.match("LPAREN"))
	{
		Token* open = parser.cursor.peek(-1);
		if (parser.cursor.check("RPAREN"))
		{
			mitos_add_error(parser, "type argument group cannot be empty", mitos_span(open.span));
			expression.deinit(parser.allocator);
			alloc::free(parser.allocator, expression);
			arguments.free();
			return null;
		}
		while (true)
		{
			if (arguments.len() >= MITOS_MAX_TYPE_ARGUMENTS)
			{
				mitos_add_error(parser, "type application cannot contain more than 256 arguments", mitos_current_span(parser));
				expression.deinit(parser.allocator);
				alloc::free(parser.allocator, expression);
				mitos_free_type_arguments(parser.allocator, &arguments);
				return null;
			}
			TypeExpr* argument = mitos_parse_type_expr(parser);
			if (!argument)
			{
				expression.deinit(parser.allocator);
				alloc::free(parser.allocator, expression);
				mitos_free_type_arguments(parser.allocator, &arguments);
				return null;
			}
			arguments.push({ .value = argument, .span = argument.span });
			if (!parser.cursor.match("COMMA")) break;
		}
		Token* close = mitos_expect(parser, "RPAREN", "expected ')' after grouped type arguments");
		if (!close)
		{
			expression.deinit(parser.allocator);
			alloc::free(parser.allocator, expression);
			mitos_free_type_arguments(parser.allocator, &arguments);
			return null;
		}
		end = close.span.end;
	}
	else
	{
		TypeExpr* argument = mitos_parse_type_expr(parser);
		if (!argument)
		{
			expression.deinit(parser.allocator);
			alloc::free(parser.allocator, expression);
			arguments.free();
			return null;
		}
		end = { .offset = argument.span.end.offset, .row = argument.span.end.row, .column = argument.span.end.column };
		arguments.push({ .value = argument, .span = argument.span });
	}
	expression.kind = TYPE_EXPR_APPLICATION;
	expression.arguments = arguments.to_array(parser.allocator);
	expression.span.end = mitos_position(end);
	arguments.free();
	return expression;
}

fn bool mitos_reject_forbidden_type_suffix(MitosSourceParser* parser) @private
{
	Token* token = parser.cursor.peek();
	if (!token) return false;
	if (token.is("DOUBLE_COLON"))
	{
		mitos_add_error(parser, "'::' type qualification is forbidden; use nominal names and 'of'", mitos_span(token.span));
		return true;
	}
	if (token.is("LBRACKET") || token.is("RBRACKET"))
	{
		mitos_add_error(parser, "square-bracket generic syntax is forbidden; use 'of'", mitos_span(token.span));
		return true;
	}
	if (token.is("LESS") || token.is("SUBTYPE"))
	{
		mitos_add_error(parser, "angle-bracket and '<:' type syntax is forbidden; use 'of' and type-header 'is'", mitos_span(token.span));
		return true;
	}
	if (token.is("WHERE"))
	{
		mitos_add_error(parser, "'where' clauses are forbidden", mitos_span(token.span));
		return true;
	}
	if (token.is("PIPE"))
	{
		mitos_add_error(parser, "union types are not supported", mitos_span(token.span));
		return true;
	}
	return false;
}

fn bool mitos_parse_optional_annotation(MitosSourceParser* parser, TypeAnnotation* annotation) @private
{
	*annotation = { };
	if (!parser.cursor.match("OF")) return true;
	Token* of = parser.cursor.peek(-1);
	TypeExpr* value = mitos_parse_type_expr(parser);
	if (!value) return false;
	*annotation = {
		.value = value,
		.span = mitos_span_between(of.span.start, {
			.offset = value.span.end.offset,
			.row = value.span.end.row,
			.column = value.span.end.column,
		}),
	};
	return true;
}

fn bool mitos_parse_typed_parameters(
	MitosSourceParser* parser,
	List{String}* names,
	List{TypeAnnotation}* annotations,
	String subject
) @private
{
	if (parser.cursor.check("RPAREN")) return true;
	while (true)
	{
		Token* parameter = mitos_expect(parser, "IDENTIFIER", "expected a parameter name");
		if (!parameter) return false;
		if (names.len() >= MITOS_MAX_PARAMETERS)
		{
			mitos_add_error(parser, "parameter list cannot contain more than 256 parameters", mitos_span(parameter.span));
			return false;
		}
		if (mitos_name_exists(names, parameter.text))
		{
			mitos_add_error(parser, subject, mitos_span(parameter.span));
			return false;
		}
		names.push(parameter.text.copy(parser.allocator));
		TypeAnnotation annotation;
		if (!mitos_parse_optional_annotation(parser, &annotation)) return false;
		annotations.push(annotation);
		if (parser.cursor.check("RPAREN")) return true;
		if (!mitos_expect(parser, "COMMA", "expected ',' between parameters")) return false;
	}
}


fn bool mitos_looks_like_match_arm(MitosSourceParser* parser) @private
{
	Token* first = parser.cursor.peek();
	if (!first || !first.is("IDENTIFIER")) return false;
	int depth = 0;
	for (sz distance = 1; ; distance++)
	{
		Token* token = parser.cursor.peek(distance);
		if (!token || token.is("NEWLINE") || token.is("END")) return false;
		if (token.is("LPAREN")) { depth++; continue; }
		if (token.is("RPAREN"))
		{
			if (depth == 0) return false;
			depth--;
			continue;
		}
		if (token.is("COLON") && depth == 0) return true;
		if (!token.is("IDENTIFIER") && !token.is("COMMA")) return false;
	}
}

fn bool mitos_looks_like_handler_clause(MitosSourceParser* parser) @private
{
	Token* first = parser.cursor.peek();
	if (!first || (!first.is("RETURN") && !first.is("IDENTIFIER"))) return false;
	bool qualified = first.is("RETURN");
	int depth = 0;
	for (sz distance = 1; ; distance++)
	{
		Token* token = parser.cursor.peek(distance);
		if (!token || token.is("NEWLINE") || token.is("END")) return false;
		if (token.is("DOT") && depth == 0) { qualified = true; continue; }
		if (token.is("LPAREN")) { depth++; continue; }
		if (token.is("RPAREN"))
		{
			if (depth == 0) return false;
			depth--;
			continue;
		}
		if (token.is("COLON") && depth == 0) return qualified;
	}
}

fn bool mitos_at_stop(MitosSourceParser* parser, MitosParseStop stop) @private
{
	if (parser.cursor.check("END")) return true;
	if (stop == MITOS_STOP_MATCH_ARM) return mitos_looks_like_match_arm(parser);
	if (stop == MITOS_STOP_HANDLER_CLAUSE) return mitos_looks_like_handler_clause(parser);
	return false;
}

fn bool mitos_parse_effect_row(MitosSourceParser* parser, EffectRow** row) @private
{
	*row = null;
	if (!parser.cursor.match("DOES")) return true;
	Token* start = parser.cursor.peek(-1);
	List{TypeExpr*} effects;
	effects.init(parser.allocator);
	SourcePos end;
	if (parser.cursor.match("LPAREN"))
	{
		if (parser.cursor.check("RPAREN"))
		{
			mitos_add_error(parser, "effect row cannot be empty", mitos_current_span(parser));
			effects.free();
			return false;
		}
		while (true)
		{
			TypeExpr* effect = mitos_parse_type_expr(parser);
			if (!effect)
			{
				foreach (owned : effects) { owned.deinit(parser.allocator); alloc::free(parser.allocator, owned); }
				effects.free();
				return false;
			}
			effects.push(effect);
			if (effects.len() > MITOS_MAX_TYPE_ARGUMENTS)
			{
				mitos_add_error(parser, "effect row cannot contain more than 256 effects", effect.span);
				foreach (owned : effects) { owned.deinit(parser.allocator); alloc::free(parser.allocator, owned); }
				effects.free();
				return false;
			}
			if (!parser.cursor.match("COMMA")) break;
		}
		Token* close = mitos_expect(parser, "RPAREN", "expected ')' after the effect row");
		if (!close)
		{
			foreach (owned : effects) { owned.deinit(parser.allocator); alloc::free(parser.allocator, owned); }
			effects.free();
			return false;
		}
		end = close.span.end;
	}
	else
	{
		TypeExpr* effect = mitos_parse_type_expr(parser);
		if (!effect)
		{
			effects.free();
			return false;
		}
		effects.push(effect);
		end = { .offset = effect.span.end.offset, .row = effect.span.end.row, .column = effect.span.end.column };
	}
	*row = alloc::new(parser.allocator, EffectRow, {
		.effects = effects.to_array(parser.allocator),
		.span = mitos_span_between(start.span.start, end),
	});
	effects.free();
	return true;
}

fn SurfaceExpr* mitos_parse_lambda(MitosSourceParser* parser) @private
{
	Token* start = mitos_expect(parser, "DO", "expected 'do'");
	if (!start || !mitos_expect(parser, "LPAREN", "expected '(' after 'do'")) return null;
	List{String} parameters;
	List{TypeAnnotation} annotations;
	parameters.init(parser.allocator);
	annotations.init(parser.allocator);
	if (!mitos_parse_typed_parameters(parser, &parameters, &annotations, "duplicate lambda parameter")
		|| !mitos_expect(parser, "RPAREN", "expected ')' after lambda parameters"))
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		return null;
	}
	TypeAnnotation result;
	if (!mitos_parse_optional_annotation(parser, &result))
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		return null;
	}
	EffectRow* effect_row;
	if (!mitos_parse_effect_row(parser, &effect_row)
		|| !mitos_expect(parser, "COLON", "expected ':' before the lambda body"))
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		result.deinit(parser.allocator);
		if (effect_row) { effect_row.deinit(parser.allocator); alloc::free(parser.allocator, effect_row); }
		return null;
	}
	SurfaceExpr* body = mitos_parse_sequence(parser, MITOS_STOP_END);
	if (!body)
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		result.deinit(parser.allocator);
		if (effect_row) { effect_row.deinit(parser.allocator); alloc::free(parser.allocator, effect_row); }
		return null;
	}
	Token* end = mitos_expect(parser, "END", "expected 'end' after the lambda body");
	if (!end)
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		result.deinit(parser.allocator);
		if (effect_row) { effect_row.deinit(parser.allocator); alloc::free(parser.allocator, effect_row); }
		mitos_free_expression(parser.allocator, body);
		return null;
	}
	MitosSpan span = mitos_span_between(start.span.start, end.span.end);
	if (!mitos_check_expression_height(parser, body.structural_height, span))
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		result.deinit(parser.allocator);
		if (effect_row) { effect_row.deinit(parser.allocator); alloc::free(parser.allocator, effect_row); }
		mitos_free_expression(parser.allocator, body);
		return null;
	}
	String[] owned_parameters = parameters.to_array(parser.allocator);
	TypeAnnotation[] owned_annotations = annotations.to_array(parser.allocator);
	parameters.free();
	annotations.free();
	return alloc::new(parser.allocator, SurfaceExpr, {
		.kind = SURFACE_LAMBDA,
		.span = span,
		.structural_height = body.structural_height + 1,
		.data = { .lambda = {
			.parameters = owned_parameters,
			.parameter_annotations = owned_annotations,
			.result = result,
			.effect_row = effect_row,
			.body = body,
		} },
	});
}
fn bool mitos_parse_pattern(MitosSourceParser* parser, Pattern* pattern) @private
{
	Token* start = mitos_expect(parser, "IDENTIFIER", "expected a constructor pattern or '_'");
	if (!start) return false;
	*pattern = { .span = mitos_span(start.span) };
	if (start.text == "_")
	{
		pattern.kind = PATTERN_WILDCARD;
		return true;
	}
	pattern.kind = PATTERN_CONSTRUCTOR;
	pattern.constructor = start.text.copy(parser.allocator);
	if (!parser.cursor.match("LPAREN")) return true;
	if (parser.cursor.check("RPAREN"))
	{
		mitos_add_error(parser, "nullary constructor patterns must omit parentheses", mitos_current_span(parser));
		alloc::free(parser.allocator, pattern.constructor);
		*pattern = {};
		return false;
	}
	List{String} bindings;
	bindings.init(parser.allocator);
	while (true)
	{
		Token* binding = mitos_expect(parser, "IDENTIFIER", "expected a pattern binding");
		if (!binding)
		{
			mitos_free_names(parser.allocator, &bindings);
			alloc::free(parser.allocator, pattern.constructor);
			*pattern = {};
			return false;
		}
		if (bindings.len() >= MITOS_MAX_PARAMETERS)
		{
			mitos_add_error(parser, "pattern cannot bind more than 256 values", mitos_span(binding.span));
			mitos_free_names(parser.allocator, &bindings);
			alloc::free(parser.allocator, pattern.constructor);
			*pattern = {};
			return false;
		}
		if (mitos_name_exists(&bindings, binding.text))
		{
			mitos_add_error(parser, "duplicate binding in constructor pattern", mitos_span(binding.span));
			mitos_free_names(parser.allocator, &bindings);
			alloc::free(parser.allocator, pattern.constructor);
			*pattern = {};
			return false;
		}
		bindings.push(binding.text.copy(parser.allocator));
		if (parser.cursor.check("RPAREN")) break;
		if (!mitos_expect(parser, "COMMA", "expected ',' between pattern bindings"))
		{
			mitos_free_names(parser.allocator, &bindings);
			alloc::free(parser.allocator, pattern.constructor);
			*pattern = {};
			return false;
		}
	}
	Token* end = parser.cursor.advance();
	pattern.span.end = mitos_position(end.span.end);
	pattern.bindings = bindings.to_array(parser.allocator);
	bindings.free();
	return true;
}

fn void mitos_free_match_arms(Allocator allocator, List{MatchArm}* arms) @private
{
	foreach (&arm : *arms)
	{
		arm.pattern.deinit(allocator);
		mitos_free_expression(allocator, arm.body);
	}
	arms.free();
}

fn SurfaceExpr* mitos_parse_match(MitosSourceParser* parser) @private
{
	Token* start = mitos_expect(parser, "MATCH", "expected 'match'");
	if (!start) return null;
	SurfaceExpr* scrutinee = mitos_parse_expression(parser);
	if (!scrutinee) return null;
	if (!mitos_expect(parser, "COLON", "expected ':' after the match value"))
	{
		mitos_free_expression(parser.allocator, scrutinee);
		return null;
	}
	mitos_skip_newlines(parser);
	List{MatchArm} arms;
	arms.init(parser.allocator);
	while (!parser.cursor.check("END"))
	{
		if (arms.len() >= MITOS_MAX_MATCH_ARMS)
		{
			mitos_add_error(parser, "match cannot contain more than 512 arms", mitos_current_span(parser));
			mitos_free_expression(parser.allocator, scrutinee);
			mitos_free_match_arms(parser.allocator, &arms);
			return null;
		}
		Pattern pattern;
		if (!mitos_parse_pattern(parser, &pattern))
		{
			mitos_free_expression(parser.allocator, scrutinee);
			mitos_free_match_arms(parser.allocator, &arms);
			return null;
		}
		if (!mitos_expect(parser, "COLON", "expected ':' after the match pattern"))
		{
			pattern.deinit(parser.allocator);
			mitos_free_expression(parser.allocator, scrutinee);
			mitos_free_match_arms(parser.allocator, &arms);
			return null;
		}
		SurfaceExpr* body = mitos_parse_sequence(parser, MITOS_STOP_MATCH_ARM);
		if (!body)
		{
			pattern.deinit(parser.allocator);
			mitos_free_expression(parser.allocator, scrutinee);
			mitos_free_match_arms(parser.allocator, &arms);
			return null;
		}
		arms.push({
			.pattern = pattern,
			.body = body,
			.span = { .start = pattern.span.start, .end = body.span.end },
		});
		mitos_skip_newlines(parser);
		if (!parser.cursor.check("END") && !mitos_looks_like_match_arm(parser))
		{
			mitos_add_error(parser, "expected another match arm or 'end'", mitos_current_span(parser));
			mitos_free_expression(parser.allocator, scrutinee);
			mitos_free_match_arms(parser.allocator, &arms);
			return null;
		}
	}
	if (arms.len() == 0)
	{
		mitos_add_error(parser, "match must contain at least one arm", mitos_current_span(parser));
		mitos_free_expression(parser.allocator, scrutinee);
		arms.free();
		return null;
	}
	Token* end = parser.cursor.advance();
	usz child_height = scrutinee.structural_height;
	foreach (&arm : arms)
	{
		if (arm.body.structural_height > child_height) child_height = arm.body.structural_height;
	}
	MitosSpan span = mitos_span_between(start.span.start, end.span.end);
	if (!mitos_check_expression_height(parser, child_height, span))
	{
		mitos_free_expression(parser.allocator, scrutinee);
		mitos_free_match_arms(parser.allocator, &arms);
		return null;
	}
	MatchArm[] owned_arms = arms.to_array(parser.allocator);
	arms.free();
	return alloc::new(parser.allocator, SurfaceExpr, {
		.kind = SURFACE_MATCH,
		.span = span,
		.structural_height = child_height + 1,
		.data = { .match_expr = { .scrutinee = scrutinee, .arms = owned_arms } },
	});
}

fn void mitos_free_parallel_bindings(Allocator allocator, List{ParallelBinding}* bindings) @private
{
	foreach (&binding : *bindings)
	{
		alloc::free(allocator, binding.name);
		binding.annotation.deinit(allocator);
		mitos_free_expression(allocator, binding.value);
	}
	bindings.free();
}

fn bool mitos_starts_definition(MitosSourceParser* parser) @private
{
	Token* name = parser.cursor.peek();
	if (!name || !name.is("IDENTIFIER")) return false;
	Token* next = parser.cursor.peek(1);
	if (next && next.is("DEFINE")) return true;
	if (!next || !next.is("OF")) return false;
	int depth = 0;
	for (sz distance = 2; ; distance++)
	{
		Token* token = parser.cursor.peek(distance);
		if (!token || token.is("NEWLINE")) return false;
		if (token.is("LPAREN"))
		{
			depth++;
		}
		else if (token.is("RPAREN"))
		{
			if (depth == 0) return false;
			depth--;
		}
		else if (token.is("DEFINE") && depth == 0)
		{
			return true;
		}
	}
}

fn SurfaceExpr* mitos_parse_parallel(MitosSourceParser* parser) @private
{
	Token* start = mitos_expect(parser, "PARALLEL", "expected 'parallel'");
	if (!start) return null;
	if (!mitos_expect(parser, "COLON", "expected ':' after 'parallel'")) return null;
	if (!parser.cursor.check("NEWLINE"))
	{
		mitos_add_error(parser, "expected a line break after 'parallel:'", mitos_current_span(parser));
		return null;
	}
	mitos_skip_newlines(parser);
	List{ParallelBinding} bindings;
	bindings.init(parser.allocator);
	while (mitos_starts_definition(parser))
	{
		if (bindings.len() >= MITOS_MAX_PARALLEL_BINDINGS)
		{
			mitos_add_error(parser, "parallel cannot contain more than 256 bindings", mitos_current_span(parser));
			mitos_free_parallel_bindings(parser.allocator, &bindings);
			return null;
		}
		Token* name = parser.cursor.advance();
		TypeAnnotation annotation;
		if (!mitos_parse_optional_annotation(parser, &annotation)
			|| !mitos_expect(parser, "DEFINE", "expected ':=' after the parallel binding annotation"))
		{
			annotation.deinit(parser.allocator);
			mitos_free_parallel_bindings(parser.allocator, &bindings);
			return null;
		}
		bool duplicate = false;
		foreach (&binding : bindings) if (binding.name == name.text) duplicate = true;
		if (duplicate)
		{
			mitos_add_error(parser, "duplicate parallel binding", mitos_span(name.span));
			annotation.deinit(parser.allocator);
			mitos_free_parallel_bindings(parser.allocator, &bindings);
			return null;
		}
		SurfaceExpr* value = mitos_parse_expression(parser);
		if (!value)
		{
			annotation.deinit(parser.allocator);
			mitos_free_parallel_bindings(parser.allocator, &bindings);
			return null;
		}
		bindings.push({
			.name = name.text.copy(parser.allocator),
			.annotation = annotation,
			.value = value,
			.span = { .start = mitos_position(name.span.start), .end = value.span.end },
		});
		if (!parser.cursor.check("NEWLINE"))
		{
			mitos_add_error(parser, "expected a line break after a parallel binding", mitos_current_span(parser));
			mitos_free_parallel_bindings(parser.allocator, &bindings);
			return null;
		}
		mitos_skip_newlines(parser);
	}
	if (bindings.len() < 2)
	{
		mitos_add_error(parser, "parallel requires at least two bindings", mitos_current_span(parser));
		mitos_free_parallel_bindings(parser.allocator, &bindings);
		return null;
	}
	if (parser.cursor.check("END"))
	{
		mitos_add_error(parser, "parallel requires a final result expression", mitos_current_span(parser));
		mitos_free_parallel_bindings(parser.allocator, &bindings);
		return null;
	}
	SurfaceExpr* result = mitos_parse_expression(parser);
	if (!result)
	{
		mitos_free_parallel_bindings(parser.allocator, &bindings);
		return null;
	}
	if (parser.cursor.check("NEWLINE")) mitos_skip_newlines(parser);
	if (!parser.cursor.check("END"))
	{
		mitos_add_error(parser, "expected 'end' after the parallel result", mitos_current_span(parser));
		mitos_free_expression(parser.allocator, result);
		mitos_free_parallel_bindings(parser.allocator, &bindings);
		return null;
	}
	Token* end = parser.cursor.advance();
	usz child_height = result.structural_height;
	foreach (&binding : bindings)
	{
		if (binding.value.structural_height > child_height) child_height = binding.value.structural_height;
	}
	MitosSpan span = mitos_span_between(start.span.start, end.span.end);
	if (!mitos_check_expression_height(parser, child_height, span))
	{
		mitos_free_expression(parser.allocator, result);
		mitos_free_parallel_bindings(parser.allocator, &bindings);
		return null;
	}
	ParallelBinding[] owned_bindings = bindings.to_array(parser.allocator);
	bindings.free();
	return alloc::new(parser.allocator, SurfaceExpr, {
		.kind = SURFACE_PARALLEL,
		.span = span,
		.structural_height = child_height + 1,
		.data = { .parallel = { .bindings = owned_bindings, .result = result } },
	});
}

fn void mitos_free_handler_clauses(Allocator allocator, List{HandlerClause}* clauses) @private
{
	foreach (&clause : *clauses)
	{
		alloc::free(allocator, clause.effect_name);
		alloc::free(allocator, clause.operation_name);
		foreach (parameter : clause.parameters) alloc::free(allocator, parameter);
		alloc::free(allocator, clause.parameters);
		foreach (&annotation : clause.parameter_annotations) annotation.deinit(allocator);
		alloc::free(allocator, clause.parameter_annotations);
		mitos_free_expression(allocator, clause.body);
	}
	clauses.free();
}

fn SurfaceExpr* mitos_parse_handler(MitosSourceParser* parser) @private
{
	Token* start = mitos_expect(parser, "HANDLE", "expected 'handle'");
	if (!start) return null;
	SurfaceExpr* handled = mitos_parse_expression(parser);
	if (!handled || !mitos_expect(parser, "COLON", "expected ':' after the handled expression"))
	{
		mitos_free_expression(parser.allocator, handled);
		return null;
	}
	if (!parser.cursor.check("NEWLINE"))
	{
		mitos_add_error(parser, "expected a line break after the handler header", mitos_current_span(parser));
		mitos_free_expression(parser.allocator, handled);
		return null;
	}
	mitos_skip_newlines(parser);
	List{HandlerClause} clauses;
	clauses.init(parser.allocator);
	HandlerReturnClause return_clause = { };
	bool found_return = false;
	while (!parser.cursor.check("END"))
	{
		if (parser.cursor.check("RETURN"))
		{
			Token* clause_start = parser.cursor.advance();
			if (found_return)
			{
				mitos_add_error(parser, "handler may contain exactly one return clause", mitos_span(clause_start.span));
				alloc::free(parser.allocator, return_clause.parameter);
				return_clause.annotation.deinit(parser.allocator);
				mitos_free_expression(parser.allocator, return_clause.body);
				mitos_free_handler_clauses(parser.allocator, &clauses);
				mitos_free_expression(parser.allocator, handled);
				return null;
			}
			if (!mitos_expect(parser, "LPAREN", "expected '(' after handler 'return'"))
			{
				mitos_free_handler_clauses(parser.allocator, &clauses);
				mitos_free_expression(parser.allocator, handled);
				return null;
			}
			Token* parameter = mitos_expect(parser, "IDENTIFIER", "expected the handler return value name");
			TypeAnnotation annotation = { };
			if (!parameter || !mitos_parse_optional_annotation(parser, &annotation)
				|| !mitos_expect(parser, "RPAREN", "expected ')' after the handler return value")
				|| !mitos_expect(parser, "COLON", "expected ':' after the handler return clause"))
			{
				annotation.deinit(parser.allocator);
				mitos_free_handler_clauses(parser.allocator, &clauses);
				mitos_free_expression(parser.allocator, handled);
				return null;
			}
			SurfaceExpr* body = mitos_parse_sequence(parser, MITOS_STOP_HANDLER_CLAUSE);
			if (!body)
			{
				annotation.deinit(parser.allocator);
				mitos_free_handler_clauses(parser.allocator, &clauses);
				mitos_free_expression(parser.allocator, handled);
				return null;
			}
			return_clause = {
				.parameter = parameter.text.copy(parser.allocator),
				.annotation = annotation,
				.body = body,
				.span = { .start = mitos_position(clause_start.span.start), .end = body.span.end },
			};
			found_return = true;
		}
		else
		{
			if (found_return)
			{
				mitos_add_error(parser, "handler return clause must be final", mitos_current_span(parser));
				alloc::free(parser.allocator, return_clause.parameter);
				return_clause.annotation.deinit(parser.allocator);
				mitos_free_expression(parser.allocator, return_clause.body);
				mitos_free_handler_clauses(parser.allocator, &clauses);
				mitos_free_expression(parser.allocator, handled);
				return null;
			}
			if (clauses.len() >= MITOS_MAX_HANDLER_CLAUSES)
			{
				mitos_add_error(parser, "handler cannot contain more than 512 operation clauses", mitos_current_span(parser));
				mitos_free_handler_clauses(parser.allocator, &clauses);
				mitos_free_expression(parser.allocator, handled);
				return_clause.annotation.deinit(parser.allocator);
				alloc::free(parser.allocator, return_clause.parameter);
				mitos_free_expression(parser.allocator, return_clause.body);
				return null;
			}
			Token* effect = mitos_expect(parser, "IDENTIFIER", "expected an effect-qualified handler clause or 'return'");
			if (!effect || !mitos_expect(parser, "DOT", "expected '.' between the effect and operation names"))
			{
				mitos_free_handler_clauses(parser.allocator, &clauses);
				mitos_free_expression(parser.allocator, handled);
				return null;
			}
			Token* operation = mitos_expect(parser, "IDENTIFIER", "expected an effect operation name");
			if (!operation || !mitos_expect(parser, "LPAREN", "expected '(' after the effect operation name"))
			{
				mitos_free_handler_clauses(parser.allocator, &clauses);
				mitos_free_expression(parser.allocator, handled);
				return null;
			}
			List{String} parameters;
			List{TypeAnnotation} annotations;
			parameters.init(parser.allocator);
			annotations.init(parser.allocator);
			if (!mitos_parse_typed_parameters(parser, &parameters, &annotations, "duplicate handler clause parameter")
				|| !mitos_expect(parser, "RPAREN", "expected ')' after handler clause parameters")
				|| !mitos_expect(parser, "COLON", "expected ':' after the handler operation clause"))
			{
				mitos_free_names(parser.allocator, &parameters);
				mitos_free_annotations(parser.allocator, &annotations);
				mitos_free_handler_clauses(parser.allocator, &clauses);
				mitos_free_expression(parser.allocator, handled);
				return null;
			}
			foreach (&existing : clauses)
			{
				if (existing.effect_name == effect.text && existing.operation_name == operation.text)
				{
					mitos_add_error(parser, "duplicate handler operation clause", mitos_span(effect.span));
					mitos_free_names(parser.allocator, &parameters);
					mitos_free_annotations(parser.allocator, &annotations);
					mitos_free_handler_clauses(parser.allocator, &clauses);
					mitos_free_expression(parser.allocator, handled);
					return null;
				}
			}
			parser.handler_clause_depth++;
			SurfaceExpr* body = mitos_parse_sequence(parser, MITOS_STOP_HANDLER_CLAUSE);
			parser.handler_clause_depth--;
			if (!body)
			{
				mitos_free_names(parser.allocator, &parameters);
				mitos_free_annotations(parser.allocator, &annotations);
				mitos_free_handler_clauses(parser.allocator, &clauses);
				mitos_free_expression(parser.allocator, handled);
				return null;
			}
			clauses.push({
				.effect_name = effect.text.copy(parser.allocator),
				.operation_name = operation.text.copy(parser.allocator),
				.parameters = parameters.to_array(parser.allocator),
				.parameter_annotations = annotations.to_array(parser.allocator),
				.body = body,
				.span = { .start = mitos_position(effect.span.start), .end = body.span.end },
			});
			parameters.free();
			annotations.free();
		}
		if (parser.cursor.check("NEWLINE")) mitos_skip_newlines(parser);
	}
	if (!found_return)
	{
		mitos_add_error(parser, "handler requires exactly one return clause", mitos_current_span(parser));
		mitos_free_handler_clauses(parser.allocator, &clauses);
		mitos_free_expression(parser.allocator, handled);
		return null;
	}
	Token* end = parser.cursor.advance();
	usz child_height = handled.structural_height;
	if (return_clause.body.structural_height > child_height)
	{
		child_height = return_clause.body.structural_height;
	}
	foreach (&clause : clauses)
	{
		if (clause.body.structural_height > child_height) child_height = clause.body.structural_height;
	}
	MitosSpan span = mitos_span_between(start.span.start, end.span.end);
	if (!mitos_check_expression_height(parser, child_height, span))
	{
		alloc::free(parser.allocator, return_clause.parameter);
		return_clause.annotation.deinit(parser.allocator);
		mitos_free_expression(parser.allocator, return_clause.body);
		mitos_free_handler_clauses(parser.allocator, &clauses);
		mitos_free_expression(parser.allocator, handled);
		return null;
	}
	HandlerClause[] owned_clauses = clauses.to_array(parser.allocator);
	clauses.free();
	return alloc::new(parser.allocator, SurfaceExpr, {
		.kind = SURFACE_HANDLER,
		.span = span,
		.structural_height = child_height + 1,
		.data = { .handler = {
			.handled = handled,
			.clauses = owned_clauses,
			.return_clause = return_clause,
		} },
	});
}

fn SurfaceExpr* mitos_parse_resume(MitosSourceParser* parser) @private
{
	Token* start = mitos_expect(parser, "RESUME", "expected 'resume'");
	if (!start) return null;
	if (!parser.handler_clause_depth)
	{
		mitos_add_error(parser, "'resume' is valid only inside a handler operation clause", mitos_span(start.span));
		return null;
	}
	if (!mitos_expect(parser, "LPAREN", "expected '(' after 'resume'")) return null;
	SurfaceExpr* value = mitos_parse_expression(parser);
	if (!value) return null;
	Token* close = mitos_expect(parser, "RPAREN", "expected ')' after the resumed value");
	if (!close)
	{
		mitos_free_expression(parser.allocator, value);
		return null;
	}
	MitosSpan span = mitos_span_between(start.span.start, close.span.end);
	if (!mitos_check_expression_height(parser, value.structural_height, span))
	{
		mitos_free_expression(parser.allocator, value);
		return null;
	}
	return alloc::new(parser.allocator, SurfaceExpr, {
		.kind = SURFACE_RESUME,
		.span = span,
		.structural_height = value.structural_height + 1,
		.data = { .resume = { .value = value } },
	});
}

fn SurfaceExpr* mitos_parse_effect_operation(MitosSourceParser* parser) @private
{
	Token* effect = mitos_expect(parser, "IDENTIFIER", "expected an effect name");
	if (!effect || !mitos_expect(parser, "DOT", "expected '.' after the effect name")) return null;
	Token* operation = mitos_expect(parser, "IDENTIFIER", "expected an effect operation name");
	if (!operation || !mitos_expect(parser, "LPAREN", "expected '(' after the effect operation name")) return null;
	List{SurfaceExpr*} arguments;
	arguments.init(parser.allocator);
	if (!parser.cursor.check("RPAREN"))
	{
		while (true)
		{
			if (arguments.len() >= MITOS_MAX_PARAMETERS)
			{
				mitos_add_error(parser, "effect operation call cannot contain more than 256 arguments", mitos_current_span(parser));
				mitos_free_expressions(parser.allocator, &arguments);
				return null;
			}
			SurfaceExpr* argument = mitos_parse_expression(parser);
			if (!argument)
			{
				mitos_free_expressions(parser.allocator, &arguments);
				return null;
			}
			arguments.push(argument);
			if (!parser.cursor.match("COMMA")) break;
		}
	}
	Token* close = mitos_expect(parser, "RPAREN", "expected ')' after effect operation arguments");
	if (!close)
	{
		mitos_free_expressions(parser.allocator, &arguments);
		return null;
	}
	usz child_height = 0;
	foreach (argument : arguments)
	{
		if (argument.structural_height > child_height) child_height = argument.structural_height;
	}
	MitosSpan span = mitos_span_between(effect.span.start, close.span.end);
	if (!mitos_check_expression_height(parser, child_height, span))
	{
		mitos_free_expressions(parser.allocator, &arguments);
		return null;
	}
	SurfaceExpr*[] owned_arguments = arguments.to_array(parser.allocator);
	arguments.free();
	return alloc::new(parser.allocator, SurfaceExpr, {
		.kind = SURFACE_EFFECT_OPERATION,
		.span = span,
		.structural_height = child_height + 1,
		.data = { .effect_operation = {
			.effect_name = effect.text.copy(parser.allocator),
			.operation_name = operation.text.copy(parser.allocator),
			.arguments = owned_arguments,
		} },
	});
}

fn SurfaceExpr* mitos_parse_atom(MitosSourceParser* parser) @private
{
	Token* token = parser.cursor.peek();
	if (!token)
	{
		mitos_add_error(parser, "expected an expression", mitos_current_span(parser));
		return null;
	}
	if (token.is("INTEGER"))
	{
		parser.cursor.advance();
		return mitos_new_integer(parser, token);
	}
	if (token.is("STRING"))
	{
		parser.cursor.advance();
		return mitos_new_string(parser, token);
	}
	if (token.is("IDENTIFIER"))
	{
		Token* next = parser.cursor.peek(1);
		if (next && next.is("DOT")) return mitos_parse_effect_operation(parser);
		parser.cursor.advance();
		return mitos_new_variable(parser, token);
	}
	if (token.is("LPAREN"))
	{
		parser.cursor.advance();
		mitos_skip_newlines(parser);
		SurfaceExpr* expression = mitos_parse_expression(parser);
		if (!expression) return null;
		mitos_skip_newlines(parser);
		Token* end = mitos_expect(parser, "RPAREN", "expected ')' after the expression");
		if (!end)
		{
			mitos_free_expression(parser.allocator, expression);
			return null;
		}
		expression.span = mitos_span_between(token.span.start, end.span.end);
		return expression;
	}
	if (token.is("DO")) return mitos_parse_lambda(parser);
	if (token.is("MATCH")) return mitos_parse_match(parser);
	if (token.is("PARALLEL")) return mitos_parse_parallel(parser);
	if (token.is("HANDLE")) return mitos_parse_handler(parser);
	if (token.is("RESUME")) return mitos_parse_resume(parser);
	if (token.is("IS"))
	{
		mitos_add_error(parser, "'is' is valid only in abstract/type headers", mitos_span(token.span));
		return null;
	}
	if (token.is("RETURN"))
	{
		mitos_add_error(parser, "'return' is reserved for handler return clauses", mitos_span(token.span));
		return null;
	}
	if (token.is("WHERE") || token.is("DOUBLE_COLON") || token.is("LBRACKET")
		|| token.is("RBRACKET") || token.is("SUBTYPE") || token.is("PIPE"))
	{
		mitos_add_error(parser, "forbidden compatibility type syntax; use nominal 'of' annotations", mitos_span(token.span));
		return null;
	}
	mitos_add_error(parser, "expected an expression", mitos_span(token.span));
	return null;
}

fn SurfaceExpr* mitos_parse_parenthesized_calls(MitosSourceParser* parser, SurfaceExpr* callee) @private
{
	while (parser.cursor.match("LPAREN"))
	{
		List{SurfaceExpr*} arguments;
		arguments.init(parser.allocator);
		mitos_skip_newlines(parser);
		if (!parser.cursor.check("RPAREN"))
		{
			while (true)
			{
				SurfaceExpr* argument = mitos_parse_expression(parser);
				if (!argument)
				{
					mitos_free_expression(parser.allocator, callee);
					mitos_free_expressions(parser.allocator, &arguments);
					return null;
				}
				arguments.push(argument);
				mitos_skip_newlines(parser);
				if (parser.cursor.check("RPAREN")) break;
				if (!mitos_expect(parser, "COMMA", "expected ',' between call arguments"))
				{
					mitos_free_expression(parser.allocator, callee);
					mitos_free_expressions(parser.allocator, &arguments);
					return null;
				}
				mitos_skip_newlines(parser);
			}
		}
		Token* end = mitos_expect(parser, "RPAREN", "expected ')' after call arguments");
		if (!end)
		{
			mitos_free_expression(parser.allocator, callee);
			mitos_free_expressions(parser.allocator, &arguments);
			return null;
		}
		callee = mitos_new_application(parser, callee, &arguments, end.span.end);
		if (!callee) return null;
	}
	return callee;
}

fn SurfaceExpr* mitos_parse_call(MitosSourceParser* parser) @private
{
	SurfaceExpr* callee = mitos_parse_atom(parser);
	if (!callee) return null;
	return mitos_parse_parenthesized_calls(parser, callee);
}

fn int mitos_binary_precedence(Token* token) @private
{
	if (!token) return -1;
	if (token.is("EQUAL") || token.is("LESS") || token.is("LESS_EQUAL") ||
		token.is("GREATER") || token.is("GREATER_EQUAL")) return 10;
	if (token.is("PLUS") || token.is("MINUS")) return 20;
	if (token.is("STAR") || token.is("SLASH") || token.is("PERCENT")) return 30;
	return -1;
}

fn BinaryOperator mitos_binary_operator(Token* token) @private
{
	if (token.is("PLUS")) return BINARY_ADD;
	if (token.is("MINUS")) return BINARY_SUBTRACT;
	if (token.is("STAR")) return BINARY_MULTIPLY;
	if (token.is("SLASH")) return BINARY_DIVIDE;
	if (token.is("PERCENT")) return BINARY_REMAINDER;
	if (token.is("EQUAL")) return BINARY_EQUAL;
	if (token.is("LESS")) return BINARY_LESS;
	if (token.is("LESS_EQUAL")) return BINARY_LESS_EQUAL;
	if (token.is("GREATER")) return BINARY_GREATER;
	return BINARY_GREATER_EQUAL;
}

fn SurfaceExpr* mitos_parse_expression(MitosSourceParser* parser, int minimum_precedence = 0) @private
{
	if (parser.expression_depth >= MITOS_MAX_EXPRESSION_DEPTH)
	{
		mitos_add_error(parser, "expression nesting exceeds the maximum depth of 256", mitos_current_span(parser));
		return null;
	}
	parser.expression_depth++;
	defer parser.expression_depth--;
	SurfaceExpr* left;
	if (parser.cursor.match("MINUS"))
	{
		Token* minus = parser.cursor.peek(-1);
		Token* magnitude = parser.cursor.peek();
		if (magnitude && magnitude.is("INTEGER") && magnitude.text == "9223372036854775808")
		{
			parser.cursor.advance();
			left = alloc::new(parser.allocator, SurfaceExpr, {
				.kind = SURFACE_INTEGER,
				.structural_height = 1,
				.span = mitos_span_between(minus.span.start, magnitude.span.end),
				.data = { .integer = { .value = long::min } },
			});
		}
		else
		{
			SurfaceExpr* right = mitos_parse_expression(parser, 31);
			if (!right) return null;
			SurfaceExpr* zero = alloc::new(parser.allocator, SurfaceExpr, {
				.kind = SURFACE_INTEGER,
				.structural_height = 1,
				.span = mitos_span(minus.span),
				.data = { .integer = { .value = 0 } },
			});
			MitosSpan span = { .start = mitos_position(minus.span.start), .end = right.span.end };
			if (!mitos_check_expression_height(parser, right.structural_height, span))
			{
				mitos_free_expression(parser.allocator, zero);
				mitos_free_expression(parser.allocator, right);
				return null;
			}
			left = alloc::new(parser.allocator, SurfaceExpr, {
				.kind = SURFACE_BINARY,
				.span = span,
				.structural_height = right.structural_height + 1,
				.data = { .binary = { .operator = BINARY_SUBTRACT, .left = zero, .right = right } },
			});
		}
	}
	else
	{
		left = mitos_parse_call(parser);
	}
	if (!left) return null;
	while (true)
	{
		Token* operator = parser.cursor.peek();
		int precedence = mitos_binary_precedence(operator);
		if (precedence < minimum_precedence) break;
		parser.cursor.advance();
		SurfaceExpr* right = mitos_parse_expression(parser, precedence + 1);
		if (!right)
		{
			mitos_free_expression(parser.allocator, left);
			return null;
		}
		usz child_height = left.structural_height > right.structural_height
			? left.structural_height : right.structural_height;
		MitosSpan span = { .start = left.span.start, .end = right.span.end };
		if (!mitos_check_expression_height(parser, child_height, span))
		{
			mitos_free_expression(parser.allocator, left);
			mitos_free_expression(parser.allocator, right);
			return null;
		}
		left = alloc::new(parser.allocator, SurfaceExpr, {
			.kind = SURFACE_BINARY,
			.span = span,
			.structural_height = child_height + 1,
			.data = { .binary = { .operator = mitos_binary_operator(operator), .left = left, .right = right } },
		});
	}
	return left;
}

fn SurfaceExpr* mitos_parse_sequence(MitosSourceParser* parser, MitosParseStop stop) @private
{
	mitos_skip_newlines(parser);
	List{MitosPendingDefinition} definitions;
	definitions.init(parser.allocator);
	while (mitos_starts_definition(parser))
	{
		if (definitions.len() >= MITOS_MAX_SEQUENTIAL_DEFINITIONS)
		{
			mitos_add_error(parser, "block cannot contain more than 256 sequential definitions", mitos_current_span(parser));
			mitos_free_pending_definitions(parser.allocator, &definitions);
			return null;
		}
		Token* name = parser.cursor.advance();
		TypeAnnotation annotation;
		if (!mitos_parse_optional_annotation(parser, &annotation)
			|| !mitos_expect(parser, "DEFINE", "expected ':=' after the definition annotation"))
		{
			annotation.deinit(parser.allocator);
			mitos_free_pending_definitions(parser.allocator, &definitions);
			return null;
		}
		bool duplicate = false;
		foreach (&definition : definitions) if (definition.name == name.text) duplicate = true;
		if (duplicate)
		{
			mitos_add_error(parser, "duplicate definition in the same block", mitos_span(name.span));
			annotation.deinit(parser.allocator);
			mitos_free_pending_definitions(parser.allocator, &definitions);
			return null;
		}
		SurfaceExpr* value = mitos_parse_expression(parser);
		if (!value)
		{
			annotation.deinit(parser.allocator);
			mitos_free_pending_definitions(parser.allocator, &definitions);
			return null;
		}
		definitions.push({
			.name = name.text.copy(parser.allocator),
			.annotation = annotation,
			.value = value,
			.span = { .start = mitos_position(name.span.start), .end = value.span.end },
		});
		if (!parser.cursor.check("NEWLINE"))
		{
			mitos_add_error(parser, "expected a line break after an immutable definition", mitos_current_span(parser));
			mitos_free_pending_definitions(parser.allocator, &definitions);
			return null;
		}
		mitos_skip_newlines(parser);
	}
	if (mitos_at_stop(parser, stop))
	{
		mitos_add_error(parser, "block requires a final result expression", mitos_current_span(parser));
		mitos_free_pending_definitions(parser.allocator, &definitions);
		return null;
	}
	SurfaceExpr* body = mitos_parse_expression(parser);
	if (!body)
	{
		mitos_free_pending_definitions(parser.allocator, &definitions);
		return null;
	}
	if (parser.cursor.check("NEWLINE")) mitos_skip_newlines(parser);
	if (!mitos_at_stop(parser, stop))
	{
		String message = "expected 'end' after the block result";
		if (stop == MITOS_STOP_MATCH_ARM)
		{
			message = "expected another match arm or 'end'";
		}
		else if (stop == MITOS_STOP_HANDLER_CLAUSE)
		{
			message = "expected another handler clause or 'end'";
		}
		mitos_add_error(parser, message, mitos_current_span(parser));
		mitos_free_expression(parser.allocator, body);
		mitos_free_pending_definitions(parser.allocator, &definitions);
		return null;
	}
	for (sz index = definitions.len() - 1; index >= 0; index--)
	{
		MitosPendingDefinition* definition = &definitions[(usz)index];
		usz child_height = definition.value.structural_height > body.structural_height
			? definition.value.structural_height : body.structural_height;
		MitosSpan span = { .start = definition.span.start, .end = body.span.end };
		if (!mitos_check_expression_height(parser, child_height, span))
		{
			mitos_free_expression(parser.allocator, body);
			mitos_free_pending_definitions(parser.allocator, &definitions);
			return null;
		}
		body = alloc::new(parser.allocator, SurfaceExpr, {
			.kind = SURFACE_DEFINITION,
			.span = span,
			.structural_height = child_height + 1,
			.data = {
				.definition = {
					.name = definition.name,
					.annotation = definition.annotation,
					.value = definition.value,
					.body = body,
				}
			},
		});
		definition.name = "";
		definition.annotation = { };
		definition.value = null;
	}
	definitions.free();
	return body;
}

fn void mitos_free_variants(Allocator allocator, List{VariantDecl}* variants) @private
{
	foreach (&variant : *variants)
	{
		alloc::free(allocator, variant.name);
		foreach (parameter : variant.parameters) alloc::free(allocator, parameter);
		alloc::free(allocator, variant.parameters);
		foreach (&annotation : variant.parameter_annotations) annotation.deinit(allocator);
		alloc::free(allocator, variant.parameter_annotations);
	}
	variants.free();
}

fn bool mitos_parse_header_parameters(
	MitosSourceParser* parser,
	List{TypeParameterDecl}* parameters,
	SourcePos* end,
	String duplicate_subject
) @private
{
	if (!parser.cursor.match("OF")) return true;
	bool grouped = parser.cursor.match("LPAREN");
	while (true)
	{
		Token* parameter = mitos_expect(parser, "IDENTIFIER", "expected a type parameter after 'of'");
		if (!parameter) return false;
		if (parameters.len() >= MITOS_MAX_TYPE_ARGUMENTS)
		{
			mitos_add_error(parser, "type header cannot contain more than 256 parameters", mitos_span(parameter.span));
			return false;
		}
		foreach (&existing : *parameters)
		{
			if (existing.name != parameter.text) continue;
			mitos_add_error(parser, duplicate_subject, mitos_span(parameter.span));
			return false;
		}
		parameters.push({ .name = parameter.text.copy(parser.allocator), .span = mitos_span(parameter.span) });
		*end = parameter.span.end;
		if (!grouped) return true;
		if (!parser.cursor.match("COMMA")) break;
	}
	Token* close = mitos_expect(parser, "RPAREN", "expected ')' after grouped type parameters");
	if (!close) return false;
	*end = close.span.end;
	return true;
}

fn bool mitos_parse_enum(MitosSourceParser* parser, EnumDecl* declaration) @private
{
	Token* start = mitos_expect(parser, "ENUM", "expected 'enum'");
	Token* name = mitos_expect(parser, "IDENTIFIER", "expected an enum name");
	if (!start || !name) return false;
	if (mitos_reject_forbidden_type_suffix(parser)) return false;
	List{TypeParameterDecl} type_parameters;
	type_parameters.init(parser.allocator);
	SourcePos header_end = name.span.end;
	if (!mitos_parse_header_parameters(
		parser, &type_parameters, &header_end, "duplicate enum type parameter"
	)
		|| !mitos_expect(parser, "COLON", "expected ':' after the enum header"))
	{
		mitos_free_type_parameters(parser.allocator, &type_parameters);
		return false;
	}
	mitos_skip_newlines(parser);
	List{VariantDecl} variants;
	variants.init(parser.allocator);
	while (!parser.cursor.check("END"))
	{
		if (variants.len() >= MITOS_MAX_ENUM_VARIANTS)
		{
			mitos_add_error(parser, "enum cannot declare more than 512 variants", mitos_current_span(parser));
			mitos_free_variants(parser.allocator, &variants);
			mitos_free_type_parameters(parser.allocator, &type_parameters);
			return false;
		}
		Token* variant_name = mitos_expect(parser, "IDENTIFIER", "expected an enum variant or 'end'");
		if (!variant_name)
		{
			mitos_free_variants(parser.allocator, &variants);
			mitos_free_type_parameters(parser.allocator, &type_parameters);
			return false;
		}
		List{String} parameters;
		List{TypeAnnotation} annotations;
		parameters.init(parser.allocator);
		annotations.init(parser.allocator);
		SourcePos variant_end = variant_name.span.end;
		if (parser.cursor.match("LPAREN"))
		{
			if (!mitos_parse_typed_parameters(parser, &parameters, &annotations, "duplicate constructor payload name"))
			{
				mitos_free_names(parser.allocator, &parameters);
				mitos_free_annotations(parser.allocator, &annotations);
				mitos_free_variants(parser.allocator, &variants);
				mitos_free_type_parameters(parser.allocator, &type_parameters);
				return false;
			}
			Token* close = mitos_expect(parser, "RPAREN", "expected ')' after constructor payloads");
			if (!close)
			{
				mitos_free_names(parser.allocator, &parameters);
				mitos_free_annotations(parser.allocator, &annotations);
				mitos_free_variants(parser.allocator, &variants);
				mitos_free_type_parameters(parser.allocator, &type_parameters);
				return false;
			}
			variant_end = close.span.end;
		}
		variants.push({
			.name = variant_name.text.copy(parser.allocator),
			.parameters = parameters.to_array(parser.allocator),
			.parameter_annotations = annotations.to_array(parser.allocator),
			.span = mitos_span_between(variant_name.span.start, variant_end),
		});
		parameters.free();
		annotations.free();
		if (!parser.cursor.check("NEWLINE") && !parser.cursor.check("END"))
		{
			mitos_add_error(parser, "expected a line break after the enum variant", mitos_current_span(parser));
			mitos_free_variants(parser.allocator, &variants);
			mitos_free_type_parameters(parser.allocator, &type_parameters);
			return false;
		}
		mitos_skip_newlines(parser);
	}
	if (!variants.len())
	{
		mitos_add_error(parser, "enum must declare at least one variant", mitos_current_span(parser));
		variants.free();
		mitos_free_type_parameters(parser.allocator, &type_parameters);
		return false;
	}
	Token* end = parser.cursor.advance();
	*declaration = {
		.name = name.text.copy(parser.allocator),
		.parameters = type_parameters.to_array(parser.allocator),
		.variants = variants.to_array(parser.allocator),
		.span = mitos_span_between(start.span.start, end.span.end),
	};
	type_parameters.free();
	variants.free();
	return true;
}

fn void mitos_free_fields(Allocator allocator, List{FieldDecl}* fields) @private
{
	foreach (&field : *fields)
	{
		alloc::free(allocator, field.name);
		field.annotation.deinit(allocator);
	}
	fields.free();
}

fn bool mitos_parse_type_declaration(MitosSourceParser* parser, TypeDecl* declaration) @private
{
	Token* start = parser.cursor.advance();
	bool abstract = start.is("ABSTRACT");
	Token* name = mitos_expect(parser, "IDENTIFIER", "expected a nominal type name");
	if (!name) return false;
	if (mitos_reject_forbidden_type_suffix(parser)) return false;
	List{TypeParameterDecl} parameters;
	parameters.init(parser.allocator);
	SourcePos end_position = name.span.end;
	if (!mitos_parse_header_parameters(
		parser, &parameters, &end_position, "duplicate type parameter"
	))
	{
		mitos_free_type_parameters(parser.allocator, &parameters);
		return false;
	}
	TypeExpr* supertype = null;
	if (parser.cursor.match("IS"))
	{
		supertype = mitos_parse_type_expr(parser);
		if (!supertype)
		{
			mitos_free_type_parameters(parser.allocator, &parameters);
			return false;
		}
		end_position = {
			.offset = supertype.span.end.offset,
			.row = supertype.span.end.row,
			.column = supertype.span.end.column,
		};
	}
	List{FieldDecl} fields;
	fields.init(parser.allocator);
	if (parser.cursor.match("COLON"))
	{
		if (abstract)
		{
			mitos_add_error(parser, "abstract type declarations cannot open a field block", mitos_span(start.span));
			mitos_free_type_parameters(parser.allocator, &parameters);
			if (supertype) { supertype.deinit(parser.allocator); alloc::free(parser.allocator, supertype); }
			fields.free();
			return false;
		}
		mitos_skip_newlines(parser);
		while (!parser.cursor.check("END"))
		{
			if (fields.len() >= MITOS_MAX_TYPE_FIELDS)
			{
				mitos_add_error(parser, "type cannot declare more than 512 fields", mitos_current_span(parser));
				mitos_free_fields(parser.allocator, &fields);
				mitos_free_type_parameters(parser.allocator, &parameters);
				if (supertype) { supertype.deinit(parser.allocator); alloc::free(parser.allocator, supertype); }
				return false;
			}
			Token* field_name = mitos_expect(parser, "IDENTIFIER", "expected a field name or 'end'");
			TypeAnnotation annotation = { };
			if (!field_name || !parser.cursor.check("OF")
				|| !mitos_parse_optional_annotation(parser, &annotation) || !annotation.value)
			{
				if (field_name && !parser.cursor.check("OF"))
				{
					mitos_add_error(parser, "type fields require an 'of Type' annotation", mitos_span(field_name.span));
				}
				annotation.deinit(parser.allocator);
				mitos_free_fields(parser.allocator, &fields);
				mitos_free_type_parameters(parser.allocator, &parameters);
				if (supertype) { supertype.deinit(parser.allocator); alloc::free(parser.allocator, supertype); }
				return false;
			}
			fields.push({
				.name = field_name.text.copy(parser.allocator),
				.annotation = annotation,
				.span = { .start = mitos_position(field_name.span.start), .end = annotation.span.end },
			});
			if (!parser.cursor.check("NEWLINE") && !parser.cursor.check("END"))
			{
				mitos_add_error(parser, "expected a line break after the type field", mitos_current_span(parser));
				mitos_free_fields(parser.allocator, &fields);
				mitos_free_type_parameters(parser.allocator, &parameters);
				if (supertype) { supertype.deinit(parser.allocator); alloc::free(parser.allocator, supertype); }
				return false;
			}
			mitos_skip_newlines(parser);
		}
		Token* end = parser.cursor.advance();
		end_position = end.span.end;
	}
	*declaration = {
		.kind = abstract ? TYPE_DECL_ABSTRACT : TYPE_DECL_CONCRETE,
		.name = name.text.copy(parser.allocator),
		.parameters = parameters.to_array(parser.allocator),
		.supertype = supertype,
		.fields = fields.to_array(parser.allocator),
		.span = mitos_span_between(start.span.start, end_position),
	};
	parameters.free();
	fields.free();
	return true;

}

fn void mitos_free_effect_operations(Allocator allocator, List{EffectOperationDecl}* operations) @private
{
	foreach (&operation : *operations)
	{
		alloc::free(allocator, operation.name);
		foreach (parameter : operation.parameters) alloc::free(allocator, parameter);
		alloc::free(allocator, operation.parameters);
		foreach (&annotation : operation.parameter_annotations) annotation.deinit(allocator);
		alloc::free(allocator, operation.parameter_annotations);
		operation.result.deinit(allocator);
	}
	operations.free();
}

fn bool mitos_parse_effect(MitosSourceParser* parser, EffectDecl* declaration) @private
{
	bool multi = parser.cursor.match("MULTI");
	Token* start = multi ? parser.cursor.peek(-1) : parser.cursor.peek();
	if (!mitos_expect(parser, "EFFECT", "expected 'effect'")) return false;
	Token* name = mitos_expect(parser, "IDENTIFIER", "expected an effect name");
	if (!name) return false;
	if (mitos_reject_forbidden_type_suffix(parser)) return false;
	List{TypeParameterDecl} parameters;
	parameters.init(parser.allocator);
	SourcePos header_end = name.span.end;
	if (!mitos_parse_header_parameters(
		parser, &parameters, &header_end, "duplicate effect type parameter"
	)
		|| !mitos_expect(parser, "COLON", "expected ':' after the effect header"))
	{
		mitos_free_type_parameters(parser.allocator, &parameters);
		return false;
	}
	mitos_skip_newlines(parser);
	List{EffectOperationDecl} operations;
	operations.init(parser.allocator);
	while (!parser.cursor.check("END"))
	{
		if (operations.len() >= MITOS_MAX_EFFECT_OPERATIONS)
		{
			mitos_add_error(parser, "effect cannot declare more than 512 operations", mitos_current_span(parser));
			mitos_free_type_parameters(parser.allocator, &parameters);
			mitos_free_effect_operations(parser.allocator, &operations);
			return false;
		}
		Token* operation_name = mitos_expect(parser, "IDENTIFIER", "expected an effect operation or 'end'");
		if (!operation_name || !mitos_expect(parser, "LPAREN", "expected '(' after the effect operation name"))
		{
			mitos_free_type_parameters(parser.allocator, &parameters);
			mitos_free_effect_operations(parser.allocator, &operations);
			return false;
		}
		foreach (&existing : operations)
		{
			if (existing.name == operation_name.text)
			{
				mitos_add_error(parser, "duplicate effect operation", mitos_span(operation_name.span));
				mitos_free_type_parameters(parser.allocator, &parameters);
				mitos_free_effect_operations(parser.allocator, &operations);
				return false;
			}
		}
		List{String} names;
		List{TypeAnnotation} annotations;
		names.init(parser.allocator);
		annotations.init(parser.allocator);
		if (!mitos_parse_typed_parameters(parser, &names, &annotations, "duplicate effect operation parameter")
			|| !mitos_expect(parser, "RPAREN", "expected ')' after effect operation parameters"))
		{
			mitos_free_names(parser.allocator, &names);
			mitos_free_annotations(parser.allocator, &annotations);
			mitos_free_type_parameters(parser.allocator, &parameters);
			mitos_free_effect_operations(parser.allocator, &operations);
			return false;
		}
		TypeAnnotation result;
		if (!mitos_parse_optional_annotation(parser, &result))
		{
			mitos_free_names(parser.allocator, &names);
			mitos_free_annotations(parser.allocator, &annotations);
			mitos_free_type_parameters(parser.allocator, &parameters);
			mitos_free_effect_operations(parser.allocator, &operations);
			return false;
		}
		MitosPosition operation_end = result.value ? result.span.end : mitos_position(parser.cursor.peek(-1).span.end);
		operations.push({
			.name = operation_name.text.copy(parser.allocator),
			.parameters = names.to_array(parser.allocator),
			.parameter_annotations = annotations.to_array(parser.allocator),
			.result = result,
			.span = { .start = mitos_position(operation_name.span.start), .end = operation_end },
		});
		names.free();
		annotations.free();
		if (!parser.cursor.check("NEWLINE") && !parser.cursor.check("END"))
		{
			mitos_add_error(parser, "expected a line break after the effect operation", mitos_current_span(parser));
			mitos_free_type_parameters(parser.allocator, &parameters);
			mitos_free_effect_operations(parser.allocator, &operations);
			return false;
		}
		mitos_skip_newlines(parser);
	}
	if (!operations.len())
	{
		mitos_add_error(parser, "effect must declare at least one operation", mitos_current_span(parser));
		mitos_free_type_parameters(parser.allocator, &parameters);
		operations.free();
		return false;
	}
	Token* end = parser.cursor.advance();
	*declaration = {
		.multi = multi,
		.name = name.text.copy(parser.allocator),
		.parameters = parameters.to_array(parser.allocator),
		.operations = operations.to_array(parser.allocator),
		.span = mitos_span_between(start.span.start, end.span.end),
	};
	parameters.free();
	operations.free();
	return true;
}

fn bool mitos_parse_function(MitosSourceParser* parser, FunctionDecl* declaration) @private
{
	Token* name = mitos_expect(parser, "IDENTIFIER", "expected a function name");
	if (!name || mitos_reject_forbidden_type_suffix(parser)
		|| !mitos_expect(parser, "LPAREN", "expected '(' after the function name")) return false;
	List{String} parameters;
	List{TypeAnnotation} annotations;
	parameters.init(parser.allocator);
	annotations.init(parser.allocator);
	if (!mitos_parse_typed_parameters(parser, &parameters, &annotations, "duplicate function parameter")
		|| !mitos_expect(parser, "RPAREN", "expected ')' after function parameters"))
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		return false;
	}
	TypeAnnotation result;
	if (!mitos_parse_optional_annotation(parser, &result))
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		return false;
	}
	EffectRow* effect_row;
	if (!mitos_parse_effect_row(parser, &effect_row))
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		result.deinit(parser.allocator);
		return false;
	}
	if (parser.cursor.check("WHERE"))
	{
		mitos_add_error(parser, "'where' clauses are forbidden; use implicit single-uppercase method variables", mitos_current_span(parser));
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		result.deinit(parser.allocator);
		if (effect_row) { effect_row.deinit(parser.allocator); alloc::free(parser.allocator, effect_row); }
		return false;
	}
	if (!mitos_expect(parser, "COLON", "expected ':' before the function body"))
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		result.deinit(parser.allocator);
		if (effect_row) { effect_row.deinit(parser.allocator); alloc::free(parser.allocator, effect_row); }
		return false;
	}
	SurfaceExpr* body = mitos_parse_sequence(parser, MITOS_STOP_END);
	if (!body)
	{
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		result.deinit(parser.allocator);
		if (effect_row) { effect_row.deinit(parser.allocator); alloc::free(parser.allocator, effect_row); }
		return false;
	}
	Token* end = mitos_expect(parser, "END", "expected 'end' after the function body");
	if (!end)
	{
		mitos_free_expression(parser.allocator, body);
		mitos_free_names(parser.allocator, &parameters);
		mitos_free_annotations(parser.allocator, &annotations);
		result.deinit(parser.allocator);
		if (effect_row) { effect_row.deinit(parser.allocator); alloc::free(parser.allocator, effect_row); }
		return false;
	}
	*declaration = {
		.name = name.text.copy(parser.allocator),
		.parameters = parameters.to_array(parser.allocator),
		.parameter_annotations = annotations.to_array(parser.allocator),
		.result = result,
		.effect_row = effect_row,
		.body = body,
		.span = mitos_span_between(name.span.start, end.span.end),
	};
	parameters.free();
	annotations.free();
	return true;
}

fn usz mitos_identity_variable(List{String}* variables, String name) @private
{
	foreach (index, variable : *variables) if (variable == name) return (usz)index;
	variables.push(name);
	return (usz)variables.len() - 1;
}

fn bool mitos_builtin_type_name(String name) @private
{
	return name == "Any" || name == "Never" || name == "Type" || name == "I64"
		|| name == "Bool" || name == "Unit" || name == "String" || name == "Array"
		|| name == "Function" || name == "Superposition";
}

fn SymbolKey* mitos_declared_nominal_key(Program* program, String name) @private
{
	foreach (&type_decl : program.types) if (type_decl.name == name) return &type_decl.key;
	foreach (&enum_decl : program.enums) if (enum_decl.name == name) return &enum_decl.key;
	return null;
}

fn void mitos_append_identity_component(DString* signature, String component) @private
{
	char[32] length;
	signature.append_string((String)io::bprintf(&length, "%d:", (long)component.len)!!);
	signature.append_string(component);
}

fn void mitos_append_identity_nominal(
	DString* signature,
	Program* program,
	ModuleKey* source_module,
	String name
) @private
{
	if (mitos_builtin_type_name(name))
	{
		mitos_append_identity_component(signature, MITOS_CORE_MODULE_CANONICAL);
		mitos_append_identity_component(signature, name);
		mitos_append_identity_component(signature, "");
		return;
	}
	SymbolKey* declared = mitos_declared_nominal_key(program, name);
	if (declared)
	{
		mitos_append_identity_component(signature, declared.owner.canonical);
		mitos_append_identity_component(signature, declared.name);
		mitos_append_identity_component(signature, declared.canonical_signature);
		return;
	}
	mitos_append_identity_component(signature, source_module.canonical);
	mitos_append_identity_component(signature, name);
	mitos_append_identity_component(signature, "");
}

fn void mitos_append_identity_type(
	DString* signature,
	Program* program,
	ModuleKey* source_module,
	TypeExpr* expression,
	List{String}* variables
) @private
{
	if (!expression || (expression.kind == TYPE_EXPR_NAMED && expression.name == "Any"))
	{
		signature.append_char('*');
		return;
	}
	bool declared_nominal = mitos_builtin_type_name(expression.name)
		|| mitos_declared_nominal_key(program, expression.name);
	if (expression.kind == TYPE_EXPR_NAMED && !declared_nominal
		&& expression.name.len == 1
		&& expression.name[0] >= 'A' && expression.name[0] <= 'Z')
	{
		char[32] ordinal;
		usz variable = mitos_identity_variable(variables, expression.name);
		signature.append_string((String)io::bprintf(&ordinal, "$%d", (long)variable)!!);
		return;
	}
	signature.append_char(expression.kind == TYPE_EXPR_APPLICATION ? '@' : '=');
	mitos_append_identity_nominal(signature, program, source_module, expression.name);
	if (expression.kind != TYPE_EXPR_APPLICATION) return;
	signature.append_char('[');
	foreach (&argument : expression.arguments)
	{
		mitos_append_identity_type(signature, program, source_module, argument.value, variables);
		signature.append_char(';');
	}
	signature.append_char(']');
}

fn String mitos_method_identity_signature(
	Program* program,
	ModuleKey* source_module,
	FunctionDecl* function,
	Allocator allocator
) @private
{
	DString signature;
	signature.init(allocator);
	List{String} variables;
	variables.init(allocator);
	signature.append_char('(');
	foreach (index, &annotation : function.parameter_annotations)
	{
		if (index) signature.append_char(',');
		mitos_append_identity_type(
			&signature, program, source_module, annotation.value, &variables
		);
	}
	signature.append_char(')');
	String result = signature.copy_str(allocator);
	signature.free();
	variables.free();
	return result;
}


fn String mitos_parent_identity_signature(
	SymbolKey* parent,
	Allocator allocator
) @private
{
	DString signature;
	signature.init(allocator);
	char[32] buffer;
	mitos_append_identity_component(&signature, parent.owner.canonical);
	signature.append_char('/');
	signature.append_string((String)io::bprintf(
		&buffer, "%d/", (long)parent.kind
	)!!);
	mitos_append_identity_component(&signature, parent.name);
	signature.append_char('/');
	signature.append_string((String)io::bprintf(
		&buffer, "%d/", (long)parent.arity
	)!!);
	mitos_append_identity_component(&signature, parent.canonical_signature);
	String result = signature.copy_str(allocator);
	signature.free();
	return result;
}

fn void mitos_stamp_program_identity(Program* program, ModuleKey* source_module) @private
{
	foreach (&enum_decl : program.enums)
	{
		enum_decl.key = symbol_key(
			source_module, SYMBOL_ENUM, enum_decl.name, enum_decl.parameters.len, "", program.allocator
		);
		String parent_signature = mitos_parent_identity_signature(
			&enum_decl.key, program.allocator
		);
		foreach (&variant : enum_decl.variants)
		{
			variant.key = symbol_key(
				source_module, SYMBOL_VARIANT, variant.name, variant.parameters.len,
				parent_signature, program.allocator
			);
		}
		alloc::free(program.allocator, parent_signature);
	}
	foreach (&type_decl : program.types)
	{
		type_decl.key = symbol_key(
			source_module, SYMBOL_TYPE, type_decl.name, type_decl.parameters.len, "", program.allocator
		);
	}
	foreach (&effect : program.effects)
	{
		effect.key = symbol_key(
			source_module, SYMBOL_EFFECT, effect.name, effect.parameters.len, "", program.allocator
		);
		String parent_signature = mitos_parent_identity_signature(
			&effect.key, program.allocator
		);
		foreach (&operation : effect.operations)
		{
			operation.key = symbol_key(
				source_module, SYMBOL_EFFECT_OPERATION, operation.name, operation.parameters.len,
				parent_signature, program.allocator
			);
		}
		alloc::free(program.allocator, parent_signature);
	}
	foreach (&function : program.functions)
	{
		function.generic_key = symbol_key(
			source_module, SYMBOL_GENERIC, function.name, function.parameters.len, "", program.allocator
		);
		String signature = mitos_method_identity_signature(
			program, source_module, function, program.allocator
		);
		function.key = symbol_key(
			source_module, SYMBOL_METHOD, function.name, function.parameters.len,
			signature, program.allocator
		);
		alloc::free(program.allocator, signature);
	}
}

fn void mitos_free_top_level(
	Allocator allocator,
	List{EnumDecl}* enums,
	List{TypeDecl}* types,
	List{EffectDecl}* effects,
	List{FunctionDecl}* functions
) @private
{
	Program partial = {
		.allocator = allocator,
		.enums = enums.to_array(allocator),
		.types = types.to_array(allocator),
		.effects = effects.to_array(allocator),
		.functions = functions.to_array(allocator),
	};
	enums.free();
	types.free();
	effects.free();
	functions.free();
	partial.deinit();
}

fn bool mitos_validate_bare_constructor_namespace(
	MitosSourceParser* parser,
	List{EnumDecl}* enums,
	List{TypeDecl}* types
) @private
{
	usz variant_count = 0;
	foreach (&enum_decl : *enums)
	{
		if (enum_decl.variants.len > usz::max - variant_count)
		{
			mitos_add_error(
				parser,
				"value constructor namespace exceeds its size bound",
				enum_decl.span
			);
			return false;
		}
		variant_count += enum_decl.variants.len;
	}
	ValidationNameIndex constructors;
	constructors.init(parser.allocator, variant_count);
	defer constructors.deinit();
	foreach (&enum_decl : *enums)
	{
		foreach (&variant : enum_decl.variants)
		{
			if (!constructors.insert(variant.name)) continue;
		}
	}
	bool valid = true;
	foreach (&type_decl : *types)
	{
		if (type_decl.kind != TYPE_DECL_CONCRETE
			|| !constructors.contains(type_decl.name)) continue;
		mitos_add_error(
			parser,
			"concrete type constructor name collides with an enum variant",
			type_decl.span
		);
		valid = false;
	}
	return valid;
}

fn bool mitos_parse_top_level(
	MitosSourceParser* parser,
	ModuleKey* source_module,
	Program* program
) @private
{
	List{EnumDecl} enums;
	List{TypeDecl} types;
	List{EffectDecl} effects;
	List{FunctionDecl} functions;
	enums.init(parser.allocator);
	types.init(parser.allocator);
	effects.init(parser.allocator);
	functions.init(parser.allocator);
	bool failed = false;
	mitos_skip_newlines(parser);
	while (!parser.cursor.at_end())
	{
		if (enums.len() + types.len() + effects.len() + functions.len() >= MITOS_MAX_TOP_LEVEL_DECLARATIONS)
		{
			mitos_add_error(parser, "program cannot declare more than 2048 top-level declarations", mitos_current_span(parser));
			failed = true;
			break;
		}
		if (parser.cursor.check("ENUM"))
		{
			EnumDecl declaration;
			if (!mitos_parse_enum(parser, &declaration))
			{
				failed = true;
			}
			else
			{
				enums.push(declaration);
			}
		}
		else if (parser.cursor.check("ABSTRACT") || parser.cursor.check("TYPE"))
		{
			TypeDecl declaration;
			if (!mitos_parse_type_declaration(parser, &declaration))
			{
				failed = true;
			}
			else
			{
				types.push(declaration);
			}
		}
		else if (parser.cursor.check("EFFECT") || parser.cursor.check("MULTI"))
		{
			EffectDecl declaration;
			if (!mitos_parse_effect(parser, &declaration))
			{
				failed = true;
			}
			else
			{
				effects.push(declaration);
			}
		}
		else if (parser.cursor.check("IDENTIFIER"))
		{
			FunctionDecl declaration;
			if (!mitos_parse_function(parser, &declaration))
			{
				failed = true;
			}
			else
			{
				functions.push(declaration);
			}
		}
		else
		{
			Token* forbidden = parser.cursor.peek();
			if (forbidden && forbidden.is("DOUBLE_COLON"))
			{
				mitos_add_error(parser, "'::' type qualification is forbidden; use nominal names and 'of'", mitos_span(forbidden.span));
			}
			else if (forbidden && (forbidden.is("LBRACKET") || forbidden.is("RBRACKET")))
			{
				mitos_add_error(parser, "square-bracket generic syntax is forbidden; use 'of'", mitos_span(forbidden.span));
			}
			else if (forbidden && forbidden.is("WHERE"))
			{
				mitos_add_error(parser, "'where' clauses are forbidden", mitos_span(forbidden.span));
			}
			else if (forbidden && forbidden.is("IS"))
			{
				mitos_add_error(parser, "'is' is valid only in abstract/type headers", mitos_span(forbidden.span));
			}
			else
			{
				mitos_add_error(parser, "expected an enum, type, effect, or named function declaration", mitos_current_span(parser));
			}
			failed = true;
		}
		if (failed) break;
		if (!parser.cursor.at_end() && !parser.cursor.check("NEWLINE"))
		{
			mitos_add_error(parser, "expected a line break between declarations", mitos_current_span(parser));
			failed = true;
			break;
		}
		mitos_skip_newlines(parser);
	}
	if (!failed && !mitos_validate_bare_constructor_namespace(parser, &enums, &types))
	{
		failed = true;
	}
	if (failed)
	{
		mitos_free_top_level(parser.allocator, &enums, &types, &effects, &functions);
		return false;
	}
	*program = {
		.allocator = parser.allocator,
		.module_key = clone_module_key(source_module, parser.allocator),
		.feature_manifest = delta_feature_manifest(
			DELTA_V4_CORE_REQUIRED_FEATURES, (DeltaFeatureBits)0
		),
		.enums = enums.to_array(parser.allocator),
		.types = types.to_array(parser.allocator),
		.effects = effects.to_array(parser.allocator),
		.functions = functions.to_array(parser.allocator),
	};
	mitos_stamp_program_identity(program, source_module);
	enums.free();
	types.free();
	effects.free();
	functions.free();
	return true;
}

fn MitosParseResult parse_program(
	String source,
	Allocator allocator = mem,
	ModuleKey* canonical_module = null
)
{
	ModuleKey fallback = { .canonical = MITOS_DEFAULT_MODULE_CANONICAL };
	ModuleKey* effective_module = canonical_module && canonical_module.canonical.len
		? canonical_module : &fallback;
	MitosParseResult result = {
		.allocator = allocator,
		.program = {
			.allocator = allocator,
			.module_key = clone_module_key(effective_module, allocator),
			.feature_manifest = delta_feature_manifest(
				DELTA_V4_CORE_REQUIRED_FEATURES, (DeltaFeatureBits)0
			),
		},
	};
	List{MitosDiagnostic} diagnostics;
	diagnostics.init(allocator);

	ParserArena arena;
	arena.init(allocator);
	LexerRule[43] rules = {
		mpc::regex_token("TRIVIA", `[ \t\f\v\r]+`, ignored: true),
		mpc::regex_token("COMMENT", `//[^\r\n]*`, ignored: true),
		mpc::regex_token("NEWLINE", `\n+`),
		mpc::keyword_token("ENUM", "enum"),
		mpc::keyword_token("DO", "do"),
		mpc::keyword_token("MATCH", "match"),
		mpc::keyword_token("END", "end"),
		mpc::keyword_token("PARALLEL", "parallel"),
		mpc::keyword_token("OF", "of"),
		mpc::keyword_token("IS", "is"),
		mpc::keyword_token("ABSTRACT", "abstract"),
		mpc::keyword_token("TYPE", "type"),
		mpc::keyword_token("EFFECT", "effect"),
		mpc::keyword_token("MULTI", "multi"),
		mpc::keyword_token("DOES", "does"),
		mpc::keyword_token("HANDLE", "handle"),
		mpc::keyword_token("RESUME", "resume"),
		mpc::keyword_token("RETURN", "return"),
		mpc::keyword_token("WHERE", "where"),
		mpc::literal_token("LESS_EQUAL", "<="),
		mpc::literal_token("GREATER_EQUAL", ">="),
		mpc::literal_token("DEFINE", ":="),
		mpc::literal_token("DOUBLE_COLON", "::"),
		mpc::literal_token("SUBTYPE", "<:"),
		mpc::literal_token("PLUS", "+"),
		mpc::literal_token("MINUS", "-"),
		mpc::literal_token("STAR", "*"),
		mpc::literal_token("SLASH", "/"),
		mpc::literal_token("PERCENT", "%"),
		mpc::literal_token("EQUAL", "="),
		mpc::literal_token("LESS", "<"),
		mpc::literal_token("GREATER", ">"),
		mpc::literal_token("COLON", ":"),
		mpc::literal_token("COMMA", ","),
		mpc::literal_token("LPAREN", "("),
		mpc::literal_token("RPAREN", ")"),
		mpc::literal_token("DOT", "."),
		mpc::literal_token("LBRACKET", "["),
		mpc::literal_token("RBRACKET", "]"),
		mpc::literal_token("PIPE", "|"),
		mpc::regex_token("STRING", `"([^"\\\r\n]|\\[^\r\n])*"`),
		mpc::regex_token("INTEGER", `[0-9]+`),
		mpc::regex_token("IDENTIFIER", `[A-Za-z_][A-Za-z0-9_]*`),
	};
	LexerCompileResult compiled = mpc::compile_lexer(&arena, rules[..], allocator);
	if (!compiled.ok())
	{
		foreach (&diagnostic : compiled.diagnostics) mitos_copy_mpc_diagnostic(&diagnostics, allocator, diagnostic);
		result.diagnostics = diagnostics.to_array(allocator);
		diagnostics.free();
		compiled.deinit();
		arena.deinit();
		return result;
	}

	LexResult lexed = mitos_lex_bounded(
		&compiled.lexer, source, MITOS_MAX_TOKENS, MITOS_MAX_LEXER_MATCHES
	);
	if (!lexed.ok())
	{
		foreach (&diagnostic : lexed.diagnostics) mitos_copy_mpc_diagnostic(&diagnostics, allocator, diagnostic);
		result.diagnostics = diagnostics.to_array(allocator);
		diagnostics.free();
		lexed.deinit();
		compiled.deinit();
		arena.deinit();
		return result;
	}

	TokenCursor cursor;
	cursor.init(lexed.tokens.array_view(), mitos_source_end(source), allocator);
	MitosSourceParser parser = {
		.allocator = allocator,
		.cursor = &cursor,
		.diagnostics = &diagnostics,
	};
	Program parsed_program;
	bool parsed = mitos_parse_top_level(&parser, effective_module, &parsed_program);
	foreach (&diagnostic : cursor.diagnostics) mitos_copy_mpc_diagnostic(&diagnostics, allocator, diagnostic);
	if (parsed && diagnostics.len() == 0)
	{
		result.program.deinit();
		result.program = parsed_program;
		MitosDiagnostic[] validation = validate_program(&result.program, allocator);
		foreach (diagnostic : validation) diagnostics.push(diagnostic);
		alloc::free(allocator, validation);
	}
	else if (parsed)
	{
		parsed_program.deinit();
	}
	result.diagnostics = diagnostics.to_array(allocator);
	diagnostics.free();
	cursor.deinit();
	lexed.deinit();
	compiled.deinit();
	arena.deinit();
	return result;
}
