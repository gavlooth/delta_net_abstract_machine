module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_jit;
import delta_net_abstract_machine::mitos_mir;
import std::collections::list;
import std::io;

const usz MITOS_REPL_MAX_SOURCE_BYTES = 16 * 1024 * 1024;
const String MITOS_REPL_HELP = `commands:
  :help   show this help
  :clear  forget declarations, bindings, and semantic epochs
  :quit   exit the REPL`;

enum MitosReplRead : char
{
	REPL_ENTRY,
	REPL_EOF,
	REPL_ERROR,
}

struct ReplGenericEpoch
{
	mitos::SymbolKey key;
	String fingerprint;
	ulong epoch;
}

struct ReplGenericEpochUpdate
{
	sz record_index;
	mitos::SymbolKey key;
	String fingerprint;
	ulong epoch;
}

struct ReplEpochUpdate
{
	Allocator allocator;
	List{ReplGenericEpochUpdate} generics;
	String type_fingerprint;
	String effect_fingerprint;
	bool commit_type_fingerprint;
	bool commit_effect_fingerprint;
	ulong type_epoch;
	ulong effect_epoch;
}

fn void ReplEpochUpdate.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.generics.init(allocator);
}

fn void ReplEpochUpdate.deinit(&self)
{
	foreach (&generic : self.generics)
	{
		if (generic.record_index < 0) generic.key.deinit(self.allocator);
		alloc::free(self.allocator, generic.fingerprint);
	}
	self.generics.free();
	alloc::free(self.allocator, self.type_fingerprint);
	alloc::free(self.allocator, self.effect_fingerprint);
	*self = { };
}

fn bool repl_advance_epoch(ulong* epoch)
{
	if (*epoch && *epoch < ulong::max)
	{
		(*epoch)++;
		return false;
	}
	*epoch = 1;
	return true;
}

struct ReplDeclaration
{
	String source;
	mitos::SymbolKey method_key;
}

fn void ReplDeclaration.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.source);
	self.method_key.deinit(allocator);
	*self = { };
}

fn void repl_clear_declarations(List{ReplDeclaration}* declarations, Allocator allocator)
{
	foreach (&declaration : *declarations) declaration.deinit(allocator);
	declarations.clear();
}

fn void repl_deinit_declarations(List{ReplDeclaration}* declarations, Allocator allocator)
{
	repl_clear_declarations(declarations, allocator);
	declarations.free();
}

fn usz repl_declarations_size(List{ReplDeclaration}* declarations)
{
	usz size = 0;
	foreach (&declaration : *declarations) size += declaration.source.len + 1;
	return size;
}

struct ReplEpochs
{
	Allocator allocator;
	mitos::ModuleKey module_key;
	List{ReplGenericEpoch} generics;
	String type_fingerprint;
	String effect_fingerprint;
	ulong type_epoch;
	ulong effect_epoch;
}

fn void ReplEpochs.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.module_key = mitos::repl_module_key(allocator);
	self.generics.init(allocator);
	self.type_epoch = 1;
	self.effect_epoch = 1;
}

fn void ReplEpochs.deinit(&self)
{
	self.module_key.deinit(self.allocator);
	foreach (&generic : self.generics)
	{
		generic.key.deinit(self.allocator);
		alloc::free(self.allocator, generic.fingerprint);
	}
	self.generics.free();
	alloc::free(self.allocator, self.type_fingerprint);
	alloc::free(self.allocator, self.effect_fingerprint);
	*self = { };
}

fn void ReplEpochUpdate.commit(&self, ReplEpochs* epochs)
{
	epochs.type_epoch = self.type_epoch;
	epochs.effect_epoch = self.effect_epoch;
	if (self.commit_type_fingerprint)
	{
		alloc::free(epochs.allocator, epochs.type_fingerprint);
		epochs.type_fingerprint = self.type_fingerprint;
		self.type_fingerprint = { };
	}
	if (self.commit_effect_fingerprint)
	{
		alloc::free(epochs.allocator, epochs.effect_fingerprint);
		epochs.effect_fingerprint = self.effect_fingerprint;
		self.effect_fingerprint = { };
	}
	foreach (&update : self.generics)
	{
		if (update.record_index >= 0)
		{
			ReplGenericEpoch* record = &epochs.generics[update.record_index];
			alloc::free(epochs.allocator, record.fingerprint);
			record.fingerprint = update.fingerprint;
			record.epoch = update.epoch;
			update.fingerprint = { };
			continue;
		}
		epochs.generics.push({
			.key = update.key,
			.fingerprint = update.fingerprint,
			.epoch = update.epoch,
		});
		update.key = { };
		update.fingerprint = { };
	}
}

fn void ReplEpochs.clear(&self)
{
	foreach (&generic : self.generics)
	{
		generic.key.deinit(self.allocator);
		alloc::free(self.allocator, generic.fingerprint);
	}
	self.generics.clear();
	alloc::free(self.allocator, self.type_fingerprint);
	alloc::free(self.allocator, self.effect_fingerprint);
	self.type_fingerprint = { };
	self.effect_fingerprint = { };
	(void)repl_advance_epoch(&self.type_epoch);
	(void)repl_advance_epoch(&self.effect_epoch);
}


fn void repl_append_symbol_key(DString* output, mitos::SymbolKey* key)
{
	mitos::append_length_prefixed_component(output, key.owner.canonical);
	char[32] kind;
	output.append_string((String)io::bprintf(
		&kind, "%d/%d:", (long)key.kind, (long)key.arity
	)!!);
	mitos::append_length_prefixed_component(output, key.name);
	mitos::append_length_prefixed_component(output, key.canonical_signature);
}

fn void repl_append_effect_row(
	DString* output,
	mitos::ResolvedEffectRow* row
)
{
	char[32] metadata;
	output.append_string((String)io::bprintf(
		&metadata, "row:%d:%d:", (long)row.required.len, row.has_tail ? 1L : 0L
	)!!);
	foreach (effect : row.required)
		output.append_string((String)io::bprintf(
			&metadata, "%d,", (long)effect
		)!!);
	if (row.has_tail) repl_append_symbol_key(output, &row.tail);
	output.append_char(';');
}

fn String repl_type_fingerprint(mitos::DeltaProgram* program, Allocator allocator)
{
	DString output;
	output.init(allocator);
	foreach (&descriptor : program.types.descriptors)
	{
		repl_append_symbol_key(&output, &descriptor.key);
		char[96] metadata;
		output.append_string((String)io::bprintf(
			&metadata, "%d/%d/%d/%d/%d/%d;",
			(long)descriptor.kind, (long)descriptor.nominal_parent,
			(long)descriptor.layout.size, (long)descriptor.layout.alignment,
			(long)descriptor.layout.stride, (long)descriptor.layout.copy_policy
		)!!);
		foreach (&field : descriptor.fields)
		{
			mitos::append_length_prefixed_component(&output, field.name);
			mitos::append_length_prefixed_component(&output, field.type_pattern);
		}
		if (descriptor.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
		{
			repl_append_effect_row(&output, &descriptor.function_effects);
		}
	}
	String result = output.copy_str(allocator);
	output.free();
	return result;
}

fn String repl_effect_fingerprint(mitos::DeltaProgram* program, Allocator allocator)
{
	DString output;
	output.init(allocator);
	foreach (&effect : program.effects.effects)
	{
		repl_append_symbol_key(&output, &effect.key);
		char[64] effect_metadata;
		output.append_string((String)io::bprintf(
			&effect_metadata, "%d/%d;", (long)effect.id, effect.multi ? 1L : 0L
		)!!);
		foreach (operation_id : effect.operations)
			output.append_string((String)io::bprintf(
				&effect_metadata, "%d;", (long)operation_id
			)!!);
	}
	foreach (&operation : program.effects.operations)
	{
		repl_append_symbol_key(&output, &operation.key);
		char[96] operation_metadata;
		output.append_string((String)io::bprintf(
			&operation_metadata, "%d/%d/%d/%d;",
			(long)operation.id, (long)operation.effect,
			(long)operation.host_kind, operation.ordered ? 1L : 0L
		)!!);
		foreach (pattern : operation.parameter_patterns)
			mitos::append_length_prefixed_component(&output, pattern);
		mitos::append_length_prefixed_component(&output, operation.result_pattern);
	}
	foreach (&instance : program.effects.instances)
	{
		repl_append_symbol_key(&output, &instance.key);
		char[64] instance_metadata;
		output.append_string((String)io::bprintf(
			&instance_metadata, "%d/%d:", (long)instance.id, (long)instance.constructor
		)!!);
		foreach (argument : instance.arguments)
			output.append_string((String)io::bprintf(
				&instance_metadata, "%d,", (long)argument
			)!!);
	}
	foreach (&row : program.effects.rows)
	{
		repl_append_symbol_key(&output, &row.key);
		repl_append_effect_row(&output, &row.inferred);
		repl_append_effect_row(&output, &row.asserted);
		output.append_char(row.has_assertion ? '1' : '0');
	}
	String result = output.copy_str(allocator);
	output.free();
	return result;
}

fn String repl_generic_fingerprint(
	mitos::GenericFunction* generic,
	Allocator allocator
)
{
	DString output;
	output.init(allocator);
	repl_append_symbol_key(&output, &generic.key);
	foreach (&method : generic.methods) repl_append_symbol_key(&output, &method.key);
	String result = output.copy_str(allocator);
	output.free();
	return result;
}

fn void repl_prepare_epoch_update(
	ReplEpochUpdate* update,
	ReplEpochs* epochs,
	mitos::DeltaProgram* program,
	mitos::SymbolKey* replaced_generic = null
)
{
	update.init(epochs.allocator);
	update.type_epoch = epochs.type_epoch;
	update.effect_epoch = epochs.effect_epoch;

	String type_fingerprint = repl_type_fingerprint(program, epochs.allocator);
	if (epochs.type_fingerprint != type_fingerprint)
	{
		update.type_fingerprint = type_fingerprint;
		update.commit_type_fingerprint = true;
		if (epochs.type_fingerprint.len)
		{
			(void)repl_advance_epoch(&update.type_epoch);
		}
	}
	else
	{
		alloc::free(epochs.allocator, type_fingerprint);
	}
	program.types.epoch = update.type_epoch;

	String effect_fingerprint = repl_effect_fingerprint(program, epochs.allocator);
	if (epochs.effect_fingerprint != effect_fingerprint)
	{
		update.effect_fingerprint = effect_fingerprint;
		update.commit_effect_fingerprint = true;
		if (epochs.effect_fingerprint.len)
		{
			(void)repl_advance_epoch(&update.effect_epoch);
		}
	}
	else
	{
		alloc::free(epochs.allocator, effect_fingerprint);
	}
	program.effects.epoch = update.effect_epoch;
	foreach (&row : program.effects.rows) row.effect_epoch = update.effect_epoch;

	foreach (&generic : program.methods.generics)
	{
		sz record_index = -1;
		foreach (index, &candidate : epochs.generics)
		{
			if (mitos::symbol_key_equal(&candidate.key, &generic.key))
			{
				record_index = index;
				break;
			}
		}
		String fingerprint = repl_generic_fingerprint(generic, epochs.allocator);
		if (record_index < 0)
		{
			update.generics.push({
				.record_index = -1,
				.key = mitos::clone_symbol_key(&generic.key, epochs.allocator),
				.fingerprint = fingerprint,
				.epoch = 1,
			});
			generic.epoch = 1;
			continue;
		}
		ReplGenericEpoch* record = &epochs.generics[record_index];
		if (record.fingerprint != fingerprint
			|| (replaced_generic
				&& mitos::symbol_key_equal(replaced_generic, &generic.key)))
		{
			ulong epoch = record.epoch;
			(void)repl_advance_epoch(&epoch);
			update.generics.push({
				.record_index = record_index,
				.fingerprint = fingerprint,
				.epoch = epoch,
			});
			generic.epoch = epoch;
		}
		else
		{
			alloc::free(epochs.allocator, fingerprint);
			generic.epoch = record.epoch;
		}
	}
}

fn void repl_prompt(bool continuation)
{
	io::print(continuation ? "....> " : "mitos> ");
	(void)io::stdout().flush();
}

// Keep only the production lexer distinctions that affect entry boundaries.
// This scanner is incremental: each input byte is visited once and prefixes
// are never reparsed as a multiline entry grows.
enum ReplFrameToken : char
{
	REPL_FRAME_NONE,
	REPL_FRAME_IDENTIFIER,
	REPL_FRAME_KEYWORD,
	REPL_FRAME_ENUM,
	REPL_FRAME_DO,
	REPL_FRAME_MATCH,
	REPL_FRAME_END,
	REPL_FRAME_PARALLEL,
	REPL_FRAME_TYPE,
	REPL_FRAME_EFFECT,
	REPL_FRAME_MULTI,
	REPL_FRAME_HANDLE,
	REPL_FRAME_LPAREN,
	REPL_FRAME_COLON,
	REPL_FRAME_OTHER,
}

enum ReplFrameKind : char
{
	REPL_BLOCK_DECLARATION,
	REPL_BLOCK_FUNCTION,
	REPL_BLOCK_DO,
	REPL_BLOCK_MATCH,
	REPL_BLOCK_PARALLEL,
	REPL_BLOCK_HANDLE,
}

struct ReplFrame
{
	ReplFrameKind kind;
	bool open;
	bool ready;
}

const usz MITOS_REPL_MAX_FRAME_DEPTH = 257;

struct ReplFrameState
{
	ReplFrame[MITOS_REPL_MAX_FRAME_DEPTH] frames;
	usz depth;
	bool valid;
}

fn bool repl_frame_push(ReplFrameState* state, ReplFrameKind kind, bool ready)
{
	if (state.depth >= MITOS_REPL_MAX_FRAME_DEPTH)
	{
		state.valid = false;
		return false;
	}
	state.frames[state.depth++] = { .kind = kind, .ready = ready };
	return true;
}

fn ReplFrame* repl_frame_top(ReplFrameState* state)
{
	return state.depth ? &state.frames[state.depth - 1] : null;
}

fn ReplFrameToken repl_frame_identifier_token(String identifier)
{
	if (identifier == "enum") return REPL_FRAME_ENUM;
	if (identifier == "do") return REPL_FRAME_DO;
	if (identifier == "match") return REPL_FRAME_MATCH;
	if (identifier == "end") return REPL_FRAME_END;
	if (identifier == "parallel") return REPL_FRAME_PARALLEL;
	if (identifier == "type") return REPL_FRAME_TYPE;
	if (identifier == "effect") return REPL_FRAME_EFFECT;
	if (identifier == "multi") return REPL_FRAME_MULTI;
	if (identifier == "handle") return REPL_FRAME_HANDLE;
	if (identifier == "of" || identifier == "is" || identifier == "abstract"
		|| identifier == "does" || identifier == "resume" || identifier == "return"
		|| identifier == "where") return REPL_FRAME_KEYWORD;
	return REPL_FRAME_IDENTIFIER;
}

fn void repl_frame_accept_token(
	ReplFrameState* state,
	ReplFrameToken token,
	ReplFrameToken first,
	usz token_index,
	bool first_line
)
{
	if (!state.valid) return;
	ReplFrame* top = repl_frame_top(state);
	if (top && !top.open && !top.ready)
	{
		if (top.kind == REPL_BLOCK_DO)
		{
			if (token != REPL_FRAME_LPAREN)
			{
				state.depth--;
			}
			else
			{
				top.ready = true;
			}
		}
		else if (top.kind == REPL_BLOCK_PARALLEL)
		{
			if (token == REPL_FRAME_COLON)
			{
				top.ready = true;
				top.open = true;
				return;
			}
			state.depth--;
		}
		else if (top.kind == REPL_BLOCK_HANDLE || top.kind == REPL_BLOCK_MATCH)
		{
			if (token == REPL_FRAME_COLON || token == REPL_FRAME_END)
			{
				state.valid = false;
				return;
			}
			top.ready = true;
		}
	}

	if (first_line && token_index == 0)
	{
		if (token == REPL_FRAME_ENUM || token == REPL_FRAME_TYPE
			|| token == REPL_FRAME_EFFECT)
		{
			if (!repl_frame_push(state, REPL_BLOCK_DECLARATION, true)) return;
		}
	}
	else if (first_line && token_index == 1)
	{
		if (first == REPL_FRAME_MULTI && token == REPL_FRAME_EFFECT)
		{
			if (!repl_frame_push(state, REPL_BLOCK_DECLARATION, true)) return;
		}
		else if (first == REPL_FRAME_IDENTIFIER && token == REPL_FRAME_LPAREN)
		{
			if (!repl_frame_push(state, REPL_BLOCK_FUNCTION, true)) return;
		}
	}

	if (token == REPL_FRAME_END)
	{
		top = repl_frame_top(state);
		if (top && !top.open)
		{
			state.valid = false;
			return;
		}
		if (top) state.depth--;
		return;
	}
	if (token == REPL_FRAME_COLON)
	{
		top = repl_frame_top(state);
		if (top && !top.open)
		{
			if (!top.ready)
			{
				state.valid = false;
				return;
			}
			top.open = true;
		}
		return;
	}
	if (token == REPL_FRAME_DO)
	{
		(void)repl_frame_push(state, REPL_BLOCK_DO, false);
	}
	else if (token == REPL_FRAME_MATCH)
	{
		(void)repl_frame_push(state, REPL_BLOCK_MATCH, false);
	}
	else if (token == REPL_FRAME_PARALLEL)
	{
		(void)repl_frame_push(state, REPL_BLOCK_PARALLEL, false);
	}
	else if (token == REPL_FRAME_HANDLE)
	{
		(void)repl_frame_push(state, REPL_BLOCK_HANDLE, false);
	}
}

fn bool repl_frame_scan_line(ReplFrameState* state, String line, bool first_line)
{
	usz index = 0;
	usz token_index = 0;
	ReplFrameToken first = REPL_FRAME_NONE;
	while (index < line.len)
	{
		char character = line[index];
		if (character == ' ' || character == '\t' || character == '\f'
			|| character == '\v' || character == '\r' || character == '\n')
		{
			index++;
			continue;
		}
		if (character == '/' && index + 1 < line.len && line[index + 1] == '/')
		{
			break;
		}

		ReplFrameToken token = REPL_FRAME_OTHER;
		if (character == '"')
		{
			index++;
			bool closed = false;
			while (index < line.len)
			{
				character = line[index++];
				if (character == '\\')
				{
					if (index >= line.len) break;
					index++;
				}
				else if (character == '"')
				{
					closed = true;
					break;
				}
			}
			if (!closed) return false;
		}
		else if (character == '_' || (character >= 'a' && character <= 'z')
			|| (character >= 'A' && character <= 'Z'))
		{
			usz start = index++;
			while (index < line.len)
			{
				character = line[index];
				if (character != '_' && !(character >= 'a' && character <= 'z')
					&& !(character >= 'A' && character <= 'Z')
					&& !(character >= '0' && character <= '9')) break;
				index++;
			}
			token = repl_frame_identifier_token(line[start:index - start]);
		}
		else if (character >= '0' && character <= '9')
		{
			do { index++; } while (index < line.len && line[index] >= '0' && line[index] <= '9');
		}
		else
		{
			if (character == '(')
			{
				token = REPL_FRAME_LPAREN;
			}
			else if (character == ':')
			{
				if (index + 1 < line.len && (line[index + 1] == '=' || line[index + 1] == ':'))
				{
					index++;
				}
				else
				{
					token = REPL_FRAME_COLON;
				}
			}
			else if (character == '<' && index + 1 < line.len
				&& (line[index + 1] == '=' || line[index + 1] == ':'))
			{
				index++;
			}
			else if (character == '>' && index + 1 < line.len && line[index + 1] == '=')
			{
				index++;
			}
			else if (character != '+' && character != '-' && character != '*'
				&& character != '/' && character != '%' && character != '='
				&& character != '<' && character != '>' && character != ','
				&& character != ')' && character != '.' && character != '['
				&& character != ']' && character != '|')
			{
				return false;
			}
			index++;
		}
		if (token_index == 0) first = token;
		repl_frame_accept_token(state, token, first, token_index, first_line);
		if (!state.valid) return false;
		token_index++;
	}

	ReplFrame* top = repl_frame_top(state);
	while (top && !top.open)
	{
		state.depth--;
		top = repl_frame_top(state);
	}
	return true;
}

fn MitosReplRead repl_read_entry(DString* entry)
{
	entry.clear();
	ReplFrameState framing = { .valid = true };
	bool first_line = true;
	for (;;)
	{
		repl_prompt(!first_line);
		String? line_result = io::readline(mem, io::stdin(), (sz)MITOS_REPL_MAX_SOURCE_BYTES + 1);
		if (catch err = line_result)
		{
			if (err == io::EOF)
			{
				if (first_line) return REPL_EOF;
				io::eprintn("<repl>:1:1: unexpected end of input before balanced 'end'");
				return REPL_ERROR;
			}
			io::eprintn("<repl>:1:1: unable to read standard input");
			return REPL_ERROR;
		}
		String line = line_result;
		defer alloc::free(mem, line);
		if (line.len >= MITOS_REPL_MAX_SOURCE_BYTES
			|| entry.str_view().len > MITOS_REPL_MAX_SOURCE_BYTES - line.len - 1)
		{
			io::eprintn("<repl>:1:1: entry exceeds the 16 MiB source limit");
			return REPL_ERROR;
		}
		entry.append_string(line);
		entry.append_char('\n');
		bool framed = repl_frame_scan_line(&framing, line, first_line);
		first_line = false;
		if (!framed || framing.depth == 0) return REPL_ENTRY;
	}
}

fn void repl_print_diagnostic(String message, mitos::MitosSpan span = { })
{
	usz row = span.start.row > 0 ? (usz)span.start.row : 1;
	usz column = span.start.column > 0 ? (usz)span.start.column : 1;
	io::eprintf("<repl>:%d:%d: ", (long)row, (long)column);
	terminal_eprint_field(message);
	io::eprintn("");
}

fn void repl_print_diagnostics(mitos::MitosDiagnostic[] diagnostics)
{
	foreach (&diagnostic : diagnostics)
	{
		repl_print_diagnostic(diagnostic.message, diagnostic.span);
	}
}

fn bool repl_delta_jit(
	String source,
	bool print_value,
	ReplEpochs* epochs,
	mitos_mir::MirRuntime* mir_runtime,
	mitos::SymbolKey* replaced_generic = null
)
{
	mitos::MitosParseResult parsed = mitos::parse_program(
		source, mem, &epochs.module_key
	);
	defer parsed.deinit();
	if (!parsed.ok()) { repl_print_diagnostics(parsed.diagnostics); return false; }
	mitos::DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	if (!lowered.ok()) { repl_print_diagnostics(lowered.diagnostics); return false; }
	ReplEpochUpdate update;
	repl_prepare_epoch_update(
		&update, epochs, &lowered.program, replaced_generic
	);
	defer update.deinit();
	mitos_jit::MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem, mir_runtime
	);
	defer native.free();
	if (native.status != NATIVE)
	{
		String message = native.diagnostic.len ? native.diagnostic : "MIR Delta JIT failed without a diagnostic";
		repl_print_diagnostic(message, native.diagnostic_span);
		return false;
	}
	if (print_value) io::printn(native.result);
	update.commit(epochs);
	return true;
}

fn void repl_append_indented(DString* destination, String source)
{
	bool line_start = true;
	foreach (character : source)
	{
		if (line_start) { destination.append_string("  "); line_start = false; }
		destination.append_char(character);
		if (character == '\n') line_start = true;
	}
	if (!source.len || source[source.len - 1] != '\n') destination.append_char('\n');
}


fn bool repl_method_identity(
	String entry,
	mitos::ModuleKey* source_module,
	mitos::SymbolKey* method_key,
	mitos::SymbolKey* generic_key
)
{
	mitos::MitosParseResult parsed = mitos::parse_program(entry, mem, source_module);
	defer parsed.deinit();
	bool standalone_method = parsed.diagnostics.len == 1
		&& parsed.diagnostics[0].message == "program must declare main";
	if ((!parsed.ok() && !standalone_method)
		|| parsed.program.functions.len != 1) return false;
	mitos::FunctionDecl* method = &parsed.program.functions[0];
	if (!mitos::symbol_key_is_canonical(&method.key)
		|| !mitos::symbol_key_is_canonical(&method.generic_key)) return false;
	*method_key = mitos::clone_symbol_key(&method.key, mem);
	*generic_key = mitos::clone_symbol_key(&method.generic_key, mem);
	return true;
}

fn sz repl_replacement_index(
	List{ReplDeclaration}* declarations,
	mitos::SymbolKey* method_key
)
{
	if (!mitos::symbol_key_is_canonical(method_key)) return -1;
	foreach (index, &declaration : *declarations)
		if (mitos::symbol_key_equal(&declaration.method_key, method_key)) return index;
	return -1;
}

fn void repl_append_declarations(DString* destination, List{ReplDeclaration}* declarations)
{
	foreach (&declaration : *declarations)
	{
		destination.append_string(declaration.source);
		if (!declaration.source.ends_with("\n")) destination.append_char('\n');
	}
}

fn bool repl_binding(String entry, String* name)
{
	String first = entry;
	sz? newline = entry.index_of_char('\n');
	if (try position = newline) first = entry[:position];
	sz? delimiter_result = first.index_of(":=");
	if (catch err = delimiter_result) { (void)err; return false; }
	sz delimiter = delimiter_result;
	String candidate = first[:delimiter].trim();
	if (!candidate.len) return false;
	usz identifier_end = 0;
	foreach (index, character : candidate)
	{
		bool valid = character == '_' || (character >= 'a' && character <= 'z')
			|| (character >= 'A' && character <= 'Z') || (index > 0 && character >= '0' && character <= '9');
		if (!valid) break;
		if (index == 0 && character >= '0' && character <= '9') return false;
		identifier_end++;
	}
	if (!identifier_end) return false;
	String remainder = candidate[identifier_end..].trim();
	if (remainder.len)
	{
		if (!remainder.starts_with("of") || remainder.len == 2
			|| (remainder[2] != ' ' && remainder[2] != '\t')) return false;
		if (!remainder[2..].trim().len) return false;
	}
	*name = candidate[:identifier_end];
	return true;
}

fn String repl_line_code(String line)
{
	bool quoted = false;
	bool escaped = false;
	foreach (index, character : line)
	{
		if (quoted)
		{
			if (escaped)
			{
				escaped = false;
			}
			else if (character == '\\')
			{
				escaped = true;
			}
			else if (character == '"')
			{
				quoted = false;
			}
			continue;
		}
		if (character == '"')
		{
			quoted = true;
			continue;
		}
		if (character == '/' && index + 1 < line.len && line[index + 1] == '/')
		{
			return line[:index];
		}
	}
	return line;
}

fn bool repl_keyword_prefix(String source, String keyword)
{
	if (!source.starts_with(keyword)) return false;
	if (source.len == keyword.len) return true;
	char next = source[keyword.len];
	return next != '_' && !(next >= 'a' && next <= 'z')
		&& !(next >= 'A' && next <= 'Z') && !(next >= '0' && next <= '9');
}

fn bool repl_is_function_header(String source)
{
	if (!source.ends_with(":") || !source.len) return false;
	usz index = 0;
	char character = source[index];
	if (character != '_' && !(character >= 'a' && character <= 'z')
		&& !(character >= 'A' && character <= 'Z')) return false;
	do
	{
		index++;
		if (index >= source.len) return false;
		character = source[index];
	} while (character == '_' || (character >= 'a' && character <= 'z')
		|| (character >= 'A' && character <= 'Z')
		|| (character >= '0' && character <= '9'));
	while (index < source.len && (source[index] == ' ' || source[index] == '\t'
		|| source[index] == '\f' || source[index] == '\v' || source[index] == '\r'))
	{
		index++;
	}
	return index < source.len && source[index] == '(';
}

fn bool repl_is_declaration(String entry)
{
	String first = entry;
	sz? newline = entry.index_of_char('\n');
	if (try position = newline) first = entry[:position];
	first = repl_line_code(first).trim();
	if (repl_keyword_prefix(first, "abstract") || repl_keyword_prefix(first, "type"))
	{
		return true;
	}
	if (repl_keyword_prefix(first, "enum") || repl_keyword_prefix(first, "effect"))
	{
		return first.ends_with(":");
	}
	if (repl_keyword_prefix(first, "multi"))
	{
		String remainder = first[5..].trim();
		return repl_keyword_prefix(remainder, "effect") && first.ends_with(":");
	}
	return repl_is_function_header(first);
}

fn bool repl_build_and_jit(
	DString* scratch,
	List{ReplDeclaration}* declarations,
	DString* bindings,
	String entry,
	String binding_name,
	bool declaration,
	sz replacement,
	mitos::SymbolKey* replaced_generic,
	ReplEpochs* epochs,
	mitos_mir::MirRuntime* mir_runtime
)
{
	scratch.clear();
	if (declaration && replacement >= 0)
	{
		foreach (index, &retained : *declarations)
		{
			String source = index == replacement ? entry : retained.source;
			scratch.append_string(source);
			if (!source.ends_with("\n")) scratch.append_char('\n');
		}
	}
	else
	{
		repl_append_declarations(scratch, declarations);
		if (declaration)
		{
			scratch.append_string(entry);
			if (!entry.ends_with("\n")) scratch.append_char('\n');
		}
	}
	if (declaration)
	{
		if (!replaced_generic || replaced_generic.name != "main" || replaced_generic.arity != 0)
		{
			scratch.append_string("main():\n  0\nend\n");
		}
		return repl_delta_jit(
			scratch.str_view(), false, epochs, mir_runtime,
			replacement >= 0 ? replaced_generic : null
		);
	}
	scratch.append_string("main():\n"); scratch.append_string(bindings.str_view());
	repl_append_indented(scratch, entry);
	if (binding_name.len) { scratch.append_string("  "); scratch.append_string(binding_name); scratch.append_char('\n'); }
	scratch.append_string("end\n");
	return repl_delta_jit(
		scratch.str_view(), true, epochs, mir_runtime
	);
}

fn int run_mitos_repl()
{
	List{ReplDeclaration} declarations;
	declarations.init(mem);
	defer repl_deinit_declarations(&declarations, mem);
	DString bindings; DString entry; DString scratch;
	bindings.init(mem); entry.init(mem); scratch.init(mem);
	defer bindings.free(); defer entry.free(); defer scratch.free();
	ReplEpochs epochs; epochs.init(mem); defer epochs.deinit();
	mitos_mir::MirRuntime mir_runtime; mir_runtime.init();
	defer (void)mir_runtime.free();
	if (!mir_runtime.ready())
	{
		io::eprintn("<repl>:1:1: MIR runtime initialization failed");
		return 1;
	}
	for (;;)
	{
		MitosReplRead read_status = repl_read_entry(&entry);
		if (read_status == REPL_EOF) return 0;
		if (read_status == REPL_ERROR) return 1;
		String source = entry.str_view(); String trimmed = source.trim();
		if (!trimmed.len) continue;
		if (trimmed == ":quit") return 0;
		if (trimmed == ":help") { io::printn(MITOS_REPL_HELP); continue; }
		if (trimmed == ":clear")
		{
			repl_clear_declarations(&declarations, mem);
			bindings.clear(); epochs.clear(); continue;
		}
		if (trimmed.starts_with(":"))
		{
			io::eprint("<repl>:1:1: unknown command '");
			terminal_eprint_field(trimmed);
			io::eprintn("'");
			continue;
		}
		String binding_name;
		bool binding = repl_binding(source, &binding_name);
		bool declaration = !binding && repl_is_declaration(source);
		mitos::SymbolKey method_key;
		mitos::SymbolKey generic_key;
		if (declaration) (void)repl_method_identity(
			source, &epochs.module_key, &method_key, &generic_key
		);
		defer method_key.deinit(mem);
		defer generic_key.deinit(mem);
		sz replacement = repl_replacement_index(&declarations, &method_key);
		usz declarations_size = repl_declarations_size(&declarations);
		if (replacement >= 0) declarations_size -= declarations[replacement].source.len + 1;
		usz projected = declarations_size + bindings.str_view().len + source.len + 32;
		if (projected > MITOS_REPL_MAX_SOURCE_BYTES)
		{ io::eprintn("<repl>:1:1: accumulated source exceeds the 16 MiB limit; use :clear"); continue; }
		if (!repl_build_and_jit(
			&scratch, &declarations, &bindings, source, binding_name, declaration,
			replacement, &generic_key, &epochs, &mir_runtime
		)) continue;
		if (declaration)
		{
			ReplDeclaration retained = {
				.source = source.copy(mem),
				.method_key = mitos::clone_symbol_key(&method_key, mem),
			};
			if (replacement >= 0)
			{
				declarations[replacement].deinit(mem);
				declarations[replacement] = retained;
			}
			else
			{
				declarations.push(retained);
			}
		}
		else if (binding_name.len) repl_append_indented(&bindings, source);
	}
}
