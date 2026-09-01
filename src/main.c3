module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_jit;
import delta_net_abstract_machine::mitos_mir;
import std::core::main_stub;
import std::io;
import std::io::file;

const usz MAX_SOURCE_BYTES = 16 * 1024 * 1024;
const usz MAX_THREADS = 256;
const String CLI_USAGE = `usage:
  mitos run FILE [--threads N]
  mitos jit FILE
  mitos check FILE
  mitos eval SOURCE
  mitos repl
  mitos aot FILE OUTPUT
  mitos aot-run ARTIFACT`;

enum CliMode : char
{
	CLI_RUN,
	CLI_JIT,
	CLI_CHECK,
	CLI_AOT,
}

fn int usage()
{
	io::eprintn(CLI_USAGE);
	return 2;
}

fn bool parse_thread_count(String text, usz* result)
{
	if (!text.len) return false;
	usz value = 0;
	foreach (character : text)
	{
		if (character < '0' || character > '9') return false;
		usz digit = (usz)(character - '0');
		if (value > (MAX_THREADS - digit) / 10) return false;
		value = value * 10 + digit;
	}
	if (!value || value > MAX_THREADS) return false;
	*result = value;
	return true;
}

fn void print_diagnostic(
	String source_name,
	String message,
	MitosSpan span = { }
)
{
	usz row = span.start.row > 0 ? (usz)span.start.row : 1;
	usz column = span.start.column > 0 ? (usz)span.start.column : 1;
	io::eprintfn(
		"%s:%d:%d: %s",
		source_name, (long)row, (long)column, message
	);
}

fn MitosSpan operation_span(
	DeltaProgram* program,
	OperationId operation_id
)
{
	foreach (&operation : program.effects.operations)
	{
		if (operation.id != operation_id || !operation.span
			|| (usz)operation.span > program.spans.len) continue;
		return program.spans[(usz)operation.span - 1];
	}
	return { };
}

fn void print_diagnostics(String source_name, MitosDiagnostic[] diagnostics)
{
	foreach (&diagnostic : diagnostics)
	{
		print_diagnostic(source_name, diagnostic.message, diagnostic.span);
	}
}

fn int run_delta(String source_name, DeltaProgram* program, usz threads)
{
	DeltaRuntime runtime;
	runtime.init((int)threads);
	defer runtime.free();
 if (!runtime.register_standard_host_handlers(program))
 {
  io::eprintfn("%s:1:1: failed to register standard external effect helpers", source_name);
  return 1;
 }
	TypedDeltaExecutionResult execution = runtime.run(program);
	defer execution.deinit();
	if (execution.status == TYPED_DELTA_SUSPENDED)
	{
		DeltaTokenActionResult cancelled = runtime.cancel(execution.token, mem);
		defer cancelled.deinit();
		String message = cancelled.ok
			? "unexpected external effect suspension was cancelled"
			: cancelled.diagnostic;
		print_diagnostic(
			source_name, message,
			operation_span(program, execution.request.operation)
		);
		return 1;
	}
	if (execution.status == TYPED_DELTA_FAILED)
	{
		foreach (&diagnostic : execution.diagnostics)
		{
			print_diagnostic(source_name, diagnostic.message, diagnostic.span);
		}
		return 1;
	}
	io::printn(execution.formatted);
	return 0;
}

fn int run_jit(String source_name, DeltaProgram* program)
{
	mitos_mir::MirRuntime runtime;
	runtime.init();
	defer (void)runtime.free();
	if (!runtime.ready())
	{
		io::eprintfn("%s:1:1: MIR runtime initialization failed", source_name);
		return 1;
	}
	MitosJitResult native = mitos_jit::jit_delta_program(
		program, mem, &runtime
	);
	defer native.free();
	if (native.status != NATIVE)
	{
		String message = native.diagnostic.len ? native.diagnostic : "MIR Delta JIT failed without a diagnostic";
		print_diagnostic(source_name, message, native.diagnostic_span);
		return 1;
	}
	io::printn(native.result);
	return 0;
}

fn int write_aot_program(String source_name, DeltaProgram* program, String output)
{
	MitosAotResult artifact = write_mitos_aot(program, output, mem);
	defer artifact.free();
	if (artifact.status != NATIVE)
	{
		String message = artifact.diagnostic.len ? artifact.diagnostic : "DeltaProgram AOT v4 serialization failed without a diagnostic";
		print_diagnostic(source_name, message, artifact.diagnostic_span);
		return 1;
	}
	return 0;
}

fn int process_source(
	CliMode mode,
	String source_name,
	String source,
	usz threads = 0,
	String output = ""
)
{
	mitos::ModuleKey source_module = mitos::default_module_key(mem);
	defer source_module.deinit(mem);
	MitosParseResult parsed = mitos::parse_program(source, mem, &source_module);
	defer parsed.deinit();
	if (!parsed.ok())
	{
		print_diagnostics(source_name, parsed.diagnostics);
		return 1;
	}
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	if (!lowered.ok())
	{
		print_diagnostics(source_name, lowered.diagnostics);
		return 1;
	}
	switch (mode)
	{
		case CLI_RUN: return run_delta(source_name, &lowered.program, threads);
		case CLI_JIT: return run_jit(source_name, &lowered.program);
		case CLI_CHECK: return 0;
		case CLI_AOT: return write_aot_program(source_name, &lowered.program, output);
		default: return 1;
	}
}

fn int process_file(CliMode mode, String path, usz threads = 0, String output = "")
{
	long? size_result = file::get_size(path);
	if (catch err = size_result)
	{
		(void)err;
		io::eprintfn("%s:1:1: unable to inspect source file", path);
		return 1;
	}
	long size = size_result;
	if (size < 0 || (ulong)size > (ulong)MAX_SOURCE_BYTES)
	{
		io::eprintfn("%s:1:1: source exceeds the 16 MiB limit", path);
		return 1;
	}
	char[] buffer = alloc::new_array(mem, char, (usz)size + 1);
	defer alloc::free(mem, buffer);
	char[]? load_result = file::load_buffer(path, buffer);
	if (catch err = load_result)
	{
		(void)err;
		io::eprintfn("%s:1:1: unable to read source file", path);
		return 1;
	}
	char[] source = load_result;
	if (source.len > MAX_SOURCE_BYTES)
	{
		io::eprintfn("%s:1:1: source exceeds the 16 MiB limit", path);
		return 1;
	}
	return process_source(mode, path, (String)source, threads, output);
}

fn int eval_expression(String source)
{
	if (source.len > MAX_SOURCE_BYTES - 24)
	{
		io::eprintn("<eval>:1:1: source exceeds the 16 MiB limit");
		return 1;
	}
	DString program;
	program.init(mem);
	defer program.free();
	program.append_string("main():\n  ");
	program.append_string(source);
	program.append_string("\nend\n");
	return process_source(CLI_RUN, "<eval>", program.str_view());
}

fn int run_aot_artifact(String path)
{
	MitosAotResult execution = execute_mitos_aot(path, mem);
	defer execution.free();
	if (execution.status != NATIVE)
	{
		String message = execution.diagnostic.len ? execution.diagnostic : "AOT execution failed without a diagnostic";
		print_diagnostic(path, message, execution.diagnostic_span);
		return 1;
	}
	io::printn(execution.result);
	return 0;
}

fn int main(String[] args)
{
	if (args.len < 2) return usage();
	String command = args[1];
	if (command == "run")
	{
		if (args.len != 3 && args.len != 5) return usage();
		usz threads = 0;
		if (args.len == 5 && (args[3] != "--threads" || !parse_thread_count(args[4], &threads))) return usage();
		return process_file(CLI_RUN, args[2], threads);
	}
	if (command == "jit")
	{
		if (args.len != 3) return usage();
		return process_file(CLI_JIT, args[2]);
	}
	if (command == "check")
	{
		if (args.len != 3) return usage();
		return process_file(CLI_CHECK, args[2]);
	}
	if (command == "eval")
	{
		if (args.len != 3) return usage();
		return eval_expression(args[2]);
	}
	if (command == "repl")
	{
		if (args.len != 2) return usage();
		return run_mitos_repl();
	}
	if (command == "aot")
	{
		if (args.len != 4) return usage();
		return process_file(CLI_AOT, args[2], 0, args[3]);
	}
	if (command == "aot-run")
	{
		if (args.len != 3) return usage();
		return run_aot_artifact(args[2]);
	}
	return usage();
}
