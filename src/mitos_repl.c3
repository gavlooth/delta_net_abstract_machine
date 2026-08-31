module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_jit;
import delta_net_abstract_machine::mitos_specialization;
import std::collections::list;
import std::io;

const usz MITOS_REPL_MAX_SOURCE_BYTES = 16 * 1024 * 1024;
const String MITOS_REPL_HELP = `commands:
  :help   show this help
  :clear  forget declarations, bindings, epochs, and native specializations
  :quit   exit the REPL`;

enum MitosReplRead : char
{
	REPL_ENTRY,
	REPL_EOF,
	REPL_ERROR,
}

struct ReplGenericEpoch
{
	String name;
	usz arity;
	usz method_count;
	ulong epoch;
}

struct ReplDeclaration
{
	String source;
	String method_signature;
}

fn void ReplDeclaration.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.source);
	alloc::free(allocator, self.method_signature);
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
	List{ReplGenericEpoch} generics;
	usz type_count;
	usz effect_count;
	ulong type_epoch;
	ulong effect_epoch;
	uint delta_format_version;
	uint helper_abi_major;
	uint helper_abi_minor;
	ulong helper_feature_bits;
	uint helper_effect_tag;
	uint helper_handler_tag;
	uint helper_resume_tag;
	uint helper_abort_tag;
}

fn void ReplEpochs.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.generics.init(allocator);
	self.type_epoch = 1;
	self.effect_epoch = 1;
}

fn void ReplEpochs.deinit(&self)
{
	foreach (&generic : self.generics) alloc::free(self.allocator, generic.name);
	self.generics.free();
	*self = { };
}

fn void ReplEpochs.clear(&self)
{
	foreach (&generic : self.generics) alloc::free(self.allocator, generic.name);
	self.generics.clear();
	self.type_count = 0;
	self.effect_count = 0;
	self.type_epoch++;
	self.effect_epoch++;
	self.delta_format_version = 0;
	self.helper_abi_major = 0;
	self.helper_abi_minor = 0;
	self.helper_feature_bits = 0;
	self.helper_effect_tag = 0;
	self.helper_handler_tag = 0;
	self.helper_resume_tag = 0;
	self.helper_abort_tag = 0;
}

fn bool repl_update_epochs(
	ReplEpochs* epochs,
	mitos::DeltaProgram* program,
	mitos_specialization::SpecializationCache* cache,
	String replaced_generic = "",
	usz replaced_arity = 0
)
{
	bool invalidate_all = false;
	bool intrinsic_abi_changed = epochs.delta_format_version
		&& (epochs.delta_format_version != program.format_version
			|| epochs.helper_abi_major != program.helper_abi.major
			|| epochs.helper_abi_minor != program.helper_abi.minor
			|| epochs.helper_feature_bits != program.helper_abi.feature_bits
			|| epochs.helper_effect_tag != program.helper_abi.effect_tag
			|| epochs.helper_handler_tag != program.helper_abi.handler_tag
			|| epochs.helper_resume_tag != program.helper_abi.resume_tag
			|| epochs.helper_abort_tag != program.helper_abi.abort_tag);
	epochs.delta_format_version = program.format_version;
	epochs.helper_abi_major = program.helper_abi.major;
	epochs.helper_abi_minor = program.helper_abi.minor;
	epochs.helper_feature_bits = program.helper_abi.feature_bits;
	epochs.helper_effect_tag = program.helper_abi.effect_tag;
	epochs.helper_handler_tag = program.helper_abi.handler_tag;
	epochs.helper_resume_tag = program.helper_abi.resume_tag;
	epochs.helper_abort_tag = program.helper_abi.abort_tag;
	if (intrinsic_abi_changed) invalidate_all = true;
	usz type_count = (usz)program.types.descriptors.len();
	if (epochs.type_count && epochs.type_count != type_count)
	{
		epochs.type_epoch++;
		invalidate_all = true;
	}
	epochs.type_count = type_count;
	program.types.epoch = epochs.type_epoch;
	usz effect_count = program.effects.effects.len + program.effects.operations.len;
	if (epochs.effect_count && epochs.effect_count != effect_count)
	{
		epochs.effect_epoch++;
		invalidate_all = true;
	}
	epochs.effect_count = effect_count;
	program.effects.epoch = epochs.effect_epoch;
	foreach (&row : program.effects.rows) row.effect_epoch = epochs.effect_epoch;
	cache.invalidate_effect_epoch(epochs.effect_epoch);
	if ((usz)epochs.generics.len() > (usz)program.methods.generics.len()) invalidate_all = true;
	foreach (generic_index, &generic : program.methods.generics)
	{
		ReplGenericEpoch* record = null;
		foreach (&candidate : epochs.generics)
		{
			if (candidate.name == generic.name && candidate.arity == generic.arity) { record = candidate; break; }
		}
		usz method_count = (usz)generic.methods.len();
		if (!record)
		{
			epochs.generics.push({
				.name = generic.name.copy(epochs.allocator), .arity = generic.arity,
				.method_count = method_count, .epoch = 1,
			});
			record = &epochs.generics[epochs.generics.len() - 1];
			if (epochs.generics.len() > 1) cache.invalidate_generic((usz)generic_index);
		}
		else if (record.method_count != method_count
			|| (replaced_generic.len && replaced_generic == generic.name && replaced_arity == generic.arity))
		{
			record.method_count = method_count;
			record.epoch++;
			cache.invalidate_generic((usz)generic_index);
		}
		generic.epoch = record.epoch;
	}
	if (invalidate_all) cache.invalidate_all();
	return invalidate_all;
}

fn void repl_prompt(bool continuation)
{
	io::print(continuation ? "....> " : "mitos> ");
	(void)io::stdout().flush();
}

fn int repl_block_delta(String line, bool first_line)
{
	String trimmed = line.trim();
	if (trimmed == "end") return -1;
	if ((trimmed.starts_with("enum ") || trimmed.starts_with("abstract ")
		|| trimmed.starts_with("type ") || trimmed.starts_with("effect ")
		|| trimmed.starts_with("multi effect "))
		&& trimmed.ends_with(":")) return 1;
	String block = trimmed;
	sz? definition = trimmed.index_of(":=");
	if (try position = definition)
	{
		block = trimmed[position + 2..].trim();
	}
	sz? arm_body = block.index_of(": ");
	if (try position = arm_body)
	{
		block = block[position + 2..].trim();
	}
	if (block.starts_with("match ") && block.ends_with(":")) return 1;
	if (block == "parallel:") return 1;
	if (block.starts_with("do(") && block.ends_with(":")) return 1;
	if (first_line && trimmed.ends_with(":") && trimmed.contains("(")) return 1;
	return 0;
}

fn MitosReplRead repl_read_entry(DString* entry)
{
	entry.clear();
	int balance = 0;
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
		balance += repl_block_delta(line, first_line);
		first_line = false;
		if (balance <= 0) return REPL_ENTRY;
	}
}

fn void repl_print_diagnostics(mitos::MitosDiagnostic[] diagnostics)
{
	foreach (&diagnostic : diagnostics)
	{
		usz row = diagnostic.span.start.row > 0 ? (usz)diagnostic.span.start.row : 1;
		usz column = diagnostic.span.start.column > 0 ? (usz)diagnostic.span.start.column : 1;
		io::eprintfn("<repl>:%d:%d: %s", (long)row, (long)column, diagnostic.message);
	}
}

fn bool repl_delta_jit(
	String source,
	bool print_value,
	ReplEpochs* epochs,
	mitos_specialization::SpecializationCache* cache,
	String replaced_generic = "",
	usz replaced_arity = 0
)
{
	mitos::MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	if (!parsed.ok()) { repl_print_diagnostics(parsed.diagnostics); return false; }
	mitos::DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	if (!lowered.ok()) { repl_print_diagnostics(lowered.diagnostics); return false; }
	(void)repl_update_epochs(epochs, &lowered.program, cache, replaced_generic, replaced_arity);
	mitos_jit::MitosJitResult native = mitos_jit::jit_delta_program(&lowered.program, cache, mem);
	defer native.free();
	if (native.status != NATIVE)
	{
		String message = native.diagnostic.len ? native.diagnostic : "MIR Delta JIT failed without a diagnostic";
		io::eprintfn("<repl>:1:1: %s", message);
		cache.invalidate_all();
		return false;
	}
	if (print_value) io::printn(native.result);
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

fn usz repl_signature_variable(List{String}* variables, String name)
{
	foreach (index, variable : *variables) if (variable == name) return (usz)index;
	variables.push(name);
	return (usz)variables.len() - 1;
}

fn void repl_append_signature_type(DString* signature, mitos::TypeExpr* expression, List{String}* variables)
{
	if (!expression)
	{
		signature.append_string("Any");
		return;
	}
	if (expression.kind == mitos::TypeExprKind.TYPE_EXPR_NAMED && expression.name.len == 1
		&& expression.name[0] >= 'A' && expression.name[0] <= 'Z')
	{
		char[32] buffer;
		usz variable = repl_signature_variable(variables, expression.name);
		signature.append_string((String)io::bprintf(&buffer, "$%d", (long)variable)!!);
		return;
	}
	signature.append_string(expression.name);
	if (expression.kind != mitos::TypeExprKind.TYPE_EXPR_APPLICATION) return;
	signature.append_char('<');
	foreach (index, &argument : expression.arguments)
	{
		if (index) signature.append_char(',');
		repl_append_signature_type(signature, argument.value, variables);
	}
	signature.append_char('>');
}

fn bool repl_method_identity(String entry, String* signature, String* generic_name, usz* arity)
{
	mitos::MitosParseResult parsed = mitos::parse_program(entry, mem);
	defer parsed.deinit();
	if (!parsed.ok() || parsed.program.functions.len != 1) return false;
	mitos::FunctionDecl* method = &parsed.program.functions[0];
	DString key;
	key.init(mem);
	defer key.free();
	List{String} variables;
	variables.init(mem);
	defer variables.free();
	key.append_string(method.name);
	key.append_char('(');
	foreach (index, &annotation : method.parameter_annotations)
	{
		if (index) key.append_char(',');
		repl_append_signature_type(&key, annotation.value, &variables);
	}
	key.append_char(')');
	*signature = key.copy_str(mem);
	*generic_name = method.name.copy(mem);
	*arity = (usz)method.parameters.len;
	return true;
}

fn sz repl_replacement_index(List{ReplDeclaration}* declarations, String signature)
{
	if (!signature.len) return -1;
	foreach (index, &declaration : *declarations)
		if (declaration.method_signature == signature) return index;
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
	sz? delimiter_result = entry.index_of(":=");
	if (catch err = delimiter_result) { (void)err; return false; }
	sz delimiter = delimiter_result;
	String candidate = entry[:delimiter].trim();
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

fn bool repl_is_declaration(String entry)
{
	String first = entry;
	sz? newline = entry.index_of_char('\n');
	if (try position = newline)
	{
		first = entry[:position];
	}
	first = first.trim();
	if (first.starts_with("abstract ") || first.starts_with("type ")) return true;
	if ((first.starts_with("enum ") || first.starts_with("effect ")
		|| first.starts_with("multi effect ")) && first.ends_with(":")) return true;
	return first.ends_with(":") && first.contains("(")
		&& !first.starts_with("match ") && !first.starts_with("handle ")
		&& !first.starts_with("do(");
}

fn bool repl_build_and_jit(
	DString* scratch,
	List{ReplDeclaration}* declarations,
	DString* bindings,
	String entry,
	String binding_name,
	bool declaration,
	sz replacement,
	String replaced_generic,
	usz replaced_arity,
	ReplEpochs* epochs,
	mitos_specialization::SpecializationCache* cache
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
		if (replaced_generic != "main" || replaced_arity != 0)
		{
			scratch.append_string("main():\n  0\nend\n");
		}
		return repl_delta_jit(
			scratch.str_view(), false, epochs, cache,
			replacement >= 0 ? replaced_generic : "", replaced_arity
		);
	}
	scratch.append_string("main():\n"); scratch.append_string(bindings.str_view());
	repl_append_indented(scratch, entry);
	if (binding_name.len) { scratch.append_string("  "); scratch.append_string(binding_name); scratch.append_char('\n'); }
	scratch.append_string("end\n");
	bool succeeded = repl_delta_jit(scratch.str_view(), true, epochs, cache, "main", 0);
	if (succeeded && !binding_name.len) cache.invalidate_all();
	return succeeded;
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
	mitos_specialization::SpecializationCache cache; cache.init(mem); defer cache.deinit();
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
			bindings.clear(); epochs.clear(); cache.invalidate_all(); continue;
		}
		if (trimmed.starts_with(":")) { io::eprintfn("<repl>:1:1: unknown command '%s'", trimmed); continue; }
		bool declaration = repl_is_declaration(source); String binding_name;
		if (!declaration) (void)repl_binding(source, &binding_name);
		String method_signature;
		String generic_name;
		usz generic_arity = 0;
		if (declaration) (void)repl_method_identity(source, &method_signature, &generic_name, &generic_arity);
		defer alloc::free(mem, method_signature);
		defer alloc::free(mem, generic_name);
		sz replacement = repl_replacement_index(&declarations, method_signature);
		usz declarations_size = repl_declarations_size(&declarations);
		if (replacement >= 0) declarations_size -= declarations[replacement].source.len + 1;
		usz projected = declarations_size + bindings.str_view().len + source.len + 32;
		if (projected > MITOS_REPL_MAX_SOURCE_BYTES)
		{ io::eprintn("<repl>:1:1: accumulated source exceeds the 16 MiB limit; use :clear"); continue; }
		if (!repl_build_and_jit(
			&scratch, &declarations, &bindings, source, binding_name, declaration,
			replacement, generic_name, generic_arity, &epochs, &cache
		)) continue;
		if (declaration)
		{
			ReplDeclaration retained = {
				.source = source.copy(mem),
				.method_signature = method_signature.copy(mem),
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
