module delta_net_abstract_machine::core_lock_test;

import delta_net_abstract_machine;
import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_jit;
import delta_net_abstract_machine::mitos_mir;
import delta_net_abstract_machine::mitos_storage;
import libc;
import std::io;

struct SuspendHostContext
{
	mitos::EffectId effect;
	mitos::OperationId operation;
	usz argument_count;
	bool expects_i64;
	long expected_i64;
	usz calls;
}


fn TypedDeltaHostDisposition suspend_host(TypedDeltaHostCall* call, void* context)
{
	assert(call != null && context != null);
	SuspendHostContext* expected = (SuspendHostContext*)context;
	assert(call.abi_major == delta_net_abstract_machine::TYPED_DELTA_HOST_ABI_MAJOR);
	assert(call.abi_minor == delta_net_abstract_machine::TYPED_DELTA_HOST_ABI_MINOR);
	assert(call.effect == expected.effect);
	assert(call.operation == expected.operation);
	assert(call.arguments.len == expected.argument_count);
	if (expected.expects_i64)
	{
		assert(call.arguments.len == 1);
		assert(call.arguments[0].kind == HOST_VALUE_I64);
		assert(call.arguments[0].type_id == mitos::TYPE_ID_I64);
		assert(call.arguments[0].integer == expected.expected_i64);
		assert(!call.arguments[0].boolean);
		assert(call.arguments[0].represented_type == mitos::TYPE_ID_INVALID);
		assert(call.arguments[0].string.len == 0);
	}
	expected.calls++;
	return HOST_SUSPEND;
}


struct FreeDuringHostContext
{
	DeltaRuntime* runtime;
	bool attempted;
	bool succeeded;
}

fn TypedDeltaHostDisposition free_during_host_call(
	TypedDeltaHostCall* call,
	void* context
)
{
	FreeDuringHostContext* state = (FreeDuringHostContext*)context;
	state.attempted = true;
	state.succeeded = state.runtime.free();
	call.result = {
		.kind = HOST_VALUE_I64,
		.type_id = mitos::TYPE_ID_I64,
		.integer = 42,
	};
	return HOST_READY;
}


fn TypedDeltaHostDisposition suspend_after_failed_free(
	TypedDeltaHostCall* call,
	void* context
)
{
	assert(call != null && context != null);
	FreeDuringHostContext* state = (FreeDuringHostContext*)context;
	state.attempted = true;
	state.succeeded = state.runtime.free();
	return HOST_SUSPEND;
}

struct MirFreeDuringHostContext
{
	MirRuntime* runtime;
	uint result_type;
	bool attempted;
	bool succeeded;
}


fn MirHostDisposition mir_free_during_host_call(
	MirHostCall* call,
	void* context
)
{
	assert(call != null && context != null);
	MirFreeDuringHostContext* state = (MirFreeDuringHostContext*)context;
	state.attempted = true;
	state.succeeded = state.runtime.free();
	call.result = {
		.kind = 0,
		.type_id = state.result_type,
		.integer = 42,
	};
	return HOST_READY;
}

struct ReadyHostContext
{
	mitos::EffectId effect;
	mitos::OperationId operation;
	long expected_argument;
	long result;
	usz calls;
}


fn TypedDeltaHostDisposition ready_host(TypedDeltaHostCall* call, void* context)
{
	assert(call != null && context != null);
	ReadyHostContext* expected = (ReadyHostContext*)context;
	assert(call.effect == expected.effect);
	assert(call.operation == expected.operation);
	assert(call.arguments.len == 1);
	assert(call.arguments[0].kind == HOST_VALUE_I64);
	assert(call.arguments[0].type_id == mitos::TYPE_ID_I64);
	assert(call.arguments[0].integer == expected.expected_argument);
	expected.calls++;
	call.result = {
		.kind = HOST_VALUE_I64,
		.type_id = mitos::TYPE_ID_I64,
		.integer = expected.result,
	};
	return HOST_READY;
}

struct HostResultContext
{
	TypedDeltaHostValue result;
	usz calls;
}

fn TypedDeltaHostDisposition return_configured_host_value(
	TypedDeltaHostCall* call,
	void* context
)
{
	assert(call != null && context != null);
	HostResultContext* configured = (HostResultContext*)context;
	configured.calls++;
	call.result = configured.result;
	return HOST_READY;
}

struct DeltaSourceOrderContext
{
	usz calls;
	usz source_order;
	usz[2] source_orders;
	usz[2] occurrence_orders;
	long result;
}


fn TypedDeltaHostDisposition record_delta_source_order(
	TypedDeltaHostCall* call,
	void* context
)
{
	assert(call != null && context != null);
	assert(call.arguments.len == 0);
	DeltaSourceOrderContext* state = (DeltaSourceOrderContext*)context;
	assert(state.calls < state.source_orders.len);
	state.source_orders[state.calls] = call.source_order;
	state.occurrence_orders[state.calls] = call.occurrence_order;
	state.calls++;
	state.source_order = call.source_order;
	call.result = {
		.kind = HOST_VALUE_I64,
		.type_id = mitos::TYPE_ID_I64,
		.integer = state.result,
	};
	return HOST_READY;
}


struct MirSourceOrderContext
{
	usz calls;
	ulong source_order;
	uint result_type;
	long result;
}


fn MirHostDisposition record_mir_source_order(
	MirHostCall* call,
	void* context
)
{
	assert(call != null && context != null);
	assert(call.argument_count == 0);
	MirSourceOrderContext* state = (MirSourceOrderContext*)context;
	state.calls++;
	state.source_order = call.source_order;
	call.result = {
		.kind = 0,
		.type_id = state.result_type,
		.integer = state.result,
	};
	return HOST_READY;
}


struct MirCallCountContext
{
	usz calls;
	uint result_type;
}


fn MirHostDisposition count_mir_host_calls(MirHostCall* call, void* context)
{
	assert(call != null && context != null);
	MirCallCountContext* state = (MirCallCountContext*)context;
	state.calls++;
	call.result = {
		.kind = 0,
		.type_id = state.result_type,
		.integer = 42,
	};
	return HOST_READY;
}

struct ReplayHostContext
{
	long[4] arguments;
	usz calls;
}


fn TypedDeltaHostDisposition record_replay_host_call(
	TypedDeltaHostCall* call,
	void* context
)
{
	assert(call != null && context != null);
	assert(call.arguments.len == 1);
	assert(call.arguments[0].kind == HOST_VALUE_I64);
	assert(call.arguments[0].type_id == mitos::TYPE_ID_I64);
	ReplayHostContext* state = (ReplayHostContext*)context;
	assert(state.calls < state.arguments.len);
	long argument = call.arguments[0].integer;
	state.arguments[state.calls++] = argument;
	call.result = {
		.kind = HOST_VALUE_I64,
		.type_id = mitos::TYPE_ID_I64,
		.integer = argument,
	};
	return HOST_READY;
}


struct AdversarialHostContext
{
	uint mode;
	usz calls;
}


fn TypedDeltaHostDisposition adversarial_host_call(
	TypedDeltaHostCall* call,
	void* context
)
{
	assert(call != null && context != null);
	assert(call.arguments.len == 1);
	assert(call.arguments[0].kind == HOST_VALUE_STRING);
	assert(call.arguments[0].type_id == mitos::TYPE_ID_STRING);
	assert(call.arguments[0].string == "payload");
	AdversarialHostContext* state = (AdversarialHostContext*)context;
	state.calls++;
	if (state.mode == 0)
	{
		call.arguments[0].kind = HOST_VALUE_STRING;
		call.arguments[0].string = (String)((char*)1)[0..1];
		call.result = {
			.kind = HOST_VALUE_I64,
			.type_id = mitos::TYPE_ID_I64,
			.integer = 42,
		};
		return HOST_READY;
	}
	call.diagnostic = state.mode == 1
		? (String)((char*)null)[0..1]
		: (String)((char*)1)[0..(64 * 1024 + 1)];
	return HOST_FAIL;
}


fn ulong test_u64_le(char[] bytes, usz offset)
{
	assert(offset <= bytes.len && bytes.len - offset >= 8);
	ulong value = 0;
	for (usz index = 0; index < 8; index++)
	{
		value |= (ulong)bytes[offset + index] << (uint)(index * 8);
	}
	return value;
}


fn void test_write_u32_le(char[] bytes, usz offset, uint value)
{
	assert(offset <= bytes.len && bytes.len - offset >= 4);
	for (usz index = 0; index < 4; index++)
	{
		bytes[offset + index] = (char)((value >> (uint)(index * 8)) & 0xff);
	}
}


fn void test_write_u64_le(char[] bytes, usz offset, ulong value)
{
	assert(offset <= bytes.len && bytes.len - offset >= 8);
	for (usz index = 0; index < 8; index++)
	{
		bytes[offset + index] =
			(char)((value >> (uint)(index * 8)) & 0xff);
	}
}


fn bool test_u32_le_equals(char[] bytes, usz offset, uint value)
{
	if (offset > bytes.len || bytes.len - offset < 4) return false;
	for (usz index = 0; index < 4; index++)
	{
		if (bytes[offset + index]
			!= (char)((value >> (uint)(index * 8)) & 0xff)) return false;
	}
	return true;
}


fn void require_suspension(mitos::DeltaProgram* program)
{
	program.feature_manifest.required |= mitos::DELTA_FEATURE_SUSPENSION;
	program.feature_manifest.optional &= ~mitos::DELTA_FEATURE_SUSPENSION;
	program.helper_abi.features = program.feature_manifest;
	assert(mitos::delta_program_feature_coherence(program));
}
fn String unique_aot_test_path(char[] buffer, String role)
{
	ulong identity = mitos::new_runtime_identity();
	assert(identity != 0);
	return (String)io::bprintf(
		buffer, "/tmp/mitos-core-lock-%s-%d.aot", role, (long)identity
	)!!;
}

fn void reserve_aot_test_path(String path)
{
	CFile reserved = libc::fopen(path.zstr_tcopy(), "wx");
	assert(reserved != null);
	assert(libc::fclose(reserved) == 0);
}

fn void assert_generic_and_jit_result(String source, String expected)
{
	MitosParseResult parsed = mitos::parse_program(source, mem);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());
	DeltaRuntime runtime;
	runtime.init(1);
	TypedDeltaExecutionResult generic = runtime.run(&lowered.program);
	assert(generic.status == TYPED_DELTA_COMPLETE);
	assert(generic.formatted == expected);
	MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem
	);
	assert(native.status == mitos_mir::MirStatus.NATIVE);
	assert(native.result == expected);
	native.free();
	generic.deinit();
	assert(runtime.free());
	lowered.deinit();
	parsed.deinit();
}

fn void assert_generic_and_jit_failure_parity(String source)
{
	MitosParseResult parsed = mitos::parse_program(source, mem);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());
	DeltaRuntime runtime;
	runtime.init(1);
	TypedDeltaExecutionResult generic = runtime.run(&lowered.program);
	assert(generic.status == TYPED_DELTA_FAILED);
	assert(generic.diagnostics.len == 1);
	MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem
	);
	assert(native.status == mitos_mir::MirStatus.ERROR);
	assert(native.diagnostic == generic.diagnostics[0].message);
	native.free();
	generic.deinit();
	assert(runtime.free());
	lowered.deinit();
	parsed.deinit();
}

fn void assert_generic_and_jit_failure_status(String source)
{
	MitosParseResult parsed = mitos::parse_program(source, mem);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());
	DeltaRuntime runtime;
	runtime.init(1);
	TypedDeltaExecutionResult generic = runtime.run(&lowered.program);
	assert(generic.status == TYPED_DELTA_FAILED);
	assert(generic.diagnostics.len > 0);
	MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem
	);
	assert(native.status == mitos_mir::MirStatus.ERROR);
	assert(native.diagnostic.len > 0);
	native.free();
	generic.deinit();
	assert(runtime.free());
	lowered.deinit();
	parsed.deinit();
}


fn void canonical_identity_and_effect_rows_are_structural() @test
{
	ModuleKey owner = mitos::default_module_key(mem);
	defer owner.deinit(mem);
	SymbolKey first = mitos::symbol_key(&owner, SYMBOL_GENERIC, "apply", 1, "", mem);
	defer first.deinit(mem);
	SymbolKey second = mitos::clone_symbol_key(&first, mem);
	defer second.deinit(mem);
	assert(mitos::symbol_key_equal(&first, &second));

	EffectId[4] unordered = { (EffectId)3, (EffectId)1, (EffectId)3, (EffectId)2 };
	SymbolKey tail = mitos::symbol_key(&owner, SYMBOL_EFFECT_ROW_TAIL, "E", 0, "", mem);
	defer tail.deinit(mem);
	ResolvedEffectRow row = mitos::normalize_effect_row(unordered[..], &tail, mem);
	defer row.deinit(mem);
	assert(row.required.len == 3);
	assert(row.required[0] == (EffectId)1
		&& row.required[1] == (EffectId)2
		&& row.required[2] == (EffectId)3);
	assert(row.has_tail && mitos::symbol_key_equal(&row.tail, &tail));
	assert(mitos::resolved_effect_row_is_canonical(&row));
	SymbolKey other_tail = mitos::symbol_key(
		&owner, SYMBOL_EFFECT_ROW_TAIL, "F", 0, "", mem
	);
	defer other_tail.deinit(mem);
	EffectId[] no_effects = { };
	ResolvedEffectRow other_row = mitos::normalize_effect_row(no_effects, &other_tail, mem);
	defer other_row.deinit(mem);
	assert(!mitos::resolved_effect_row_satisfies(&row, &other_row));
	SymbolKey wrong_kind = mitos::symbol_key(
		&owner, SYMBOL_GENERIC, "E", 0, "", mem
	);
	defer wrong_kind.deinit(mem);
	ResolvedEffectRow invalid_tail = mitos::normalize_effect_row(
		no_effects, &wrong_kind, mem
	);
	defer invalid_tail.deinit(mem);
	assert(!mitos::resolved_effect_row_is_canonical(&invalid_tail));

	EffectId[1] state_effect = { (EffectId)1 };
	EffectId[1] io_effect = { (EffectId)2 };
	ResolvedEffectRow state_row = mitos::normalize_effect_row(
		state_effect[..], &tail, mem
	);
	defer state_row.deinit(mem);
	ResolvedEffectRow io_row = mitos::normalize_effect_row(
		io_effect[..], &tail, mem
	);
	defer io_row.deinit(mem);
	ResolvedEffectRow identical_state_row = mitos::normalize_effect_row(
		state_effect[..], &tail, mem
	);
	defer identical_state_row.deinit(mem);
	assert(!mitos::resolved_effect_row_satisfies(&state_row, &io_row));
	assert(mitos::resolved_effect_row_satisfies(
		&state_row, &identical_state_row
	));
}


fn void invalid_function_effect_row_tail_rejects_before_interning() @test
{
	MitosParseResult parsed = mitos::parse_program(
		"main():\n  1\nend\n", mem
	);
	defer parsed.deinit();
	assert(parsed.ok());
	TypeRegistryBuildResult types =
		mitos::build_type_registry(&parsed.program, mem);
	defer types.deinit();
	assert(types.ok());
	EffectRegistryBuildResult effects = mitos::build_effect_registry(
		&parsed.program, &types.registry, mem
	);
	defer effects.deinit();
	assert(effects.ok());

	ModuleKey owner = mitos::default_module_key(mem);
	defer owner.deinit(mem);
	SymbolKey wrong_tail = mitos::symbol_key(
		&owner, SYMBOL_GENERIC, "Tail", 0, "", mem
	);
	defer wrong_tail.deinit(mem);
	ResolvedEffectRow invalid = {
		.has_tail = true,
		.tail = wrong_tail,
	};
	mitos::TypeId[] parameters = { };
	mitos::TypeId result = mitos::TYPE_ID_INVALID;
	usz descriptor_count = (usz)types.registry.descriptors.len();
	ulong epoch = types.registry.epoch;
	mitos::MitosDiagnostic diagnostic;
	assert(!mitos::intern_function_type(
		&types.registry,
		&effects.registry,
		parameters,
		mitos::TYPE_ID_I64,
		&invalid,
		&result,
		&diagnostic
	));
	defer diagnostic.deinit();
	assert(diagnostic.message
		== "function signature contains a noncanonical effect-row tail");
	assert(result == mitos::TYPE_ID_INVALID);
	assert((usz)types.registry.descriptors.len() == descriptor_count);
	assert(types.registry.epoch == epoch);
}

fn LayoutDescriptor test_layout(ModuleKey* owner, String name, CopyPolicy policy)
{
	SymbolKey key = mitos::symbol_key(owner, SYMBOL_TYPE, name, 0, "", mem);
	return {
		.kind = LAYOUT_SEQUENCE,
		.copy_policy = policy,
		.sized = false,
		.size = 0,
		.alignment = 8,
		.stride = 0,
		.stable_key = key,
	};
}

fn bool quota_accepts_second_layout(
	usz quota,
	LayoutDescriptor* seed,
	LayoutDescriptor* candidate
)
{
	StorageRuntime runtime;
	runtime.init(mem, 2, 8, quota);
	defer runtime.free();
	if (runtime.control_coordinate == 0) return false;
	if (mitos_storage::register_layout(
		&runtime, (TypeId)1, seed
	).error != STORAGE_OK) return false;
	return mitos_storage::register_layout(
		&runtime, (TypeId)2, candidate
	).error == STORAGE_OK;
}

fn void storage_views_freeze_and_copy_policies_are_generation_safe() @test
{
	StorageRuntime runtime;
	runtime.init(mem, 16, 32, 1024 * 1024);
	defer runtime.free();
	ModuleKey owner = mitos::core_module_key(mem);
	defer owner.deinit(mem);

	LayoutDescriptor shared_layout = test_layout(&owner, "SharedWords", COPY_SHARED_IMMUTABLE);
	defer shared_layout.deinit(mem);
	LayoutHandleResult shared_registered = mitos_storage::register_layout(&runtime, (TypeId)1, &shared_layout);
	assert(shared_registered.error == STORAGE_OK);
	char[16] shared_bytes;
	foreach (index, &byte : shared_bytes) *byte = (char)index;
	StorageHandleResult shared = mitos_storage::allocate_shared_bytes(
		&runtime, shared_registered.handle, shared_bytes[..], 8, 8, 8
	);
	assert(shared.error == STORAGE_OK);
	StorageHandleResult shared_copy = mitos_storage::replicate(&runtime, shared.handle);
	assert(shared_copy.error == STORAGE_OK && shared_copy.handle != shared.handle);
	StorageMetadata shared_metadata;
	assert(mitos_storage::storage_metadata(
		&runtime, shared.handle, &shared_metadata
	) == STORAGE_OK);
	assert(shared_metadata.owner_count == 2);
	assert(mitos_storage::release(&runtime, shared.handle) == STORAGE_OK);
	assert(mitos_storage::storage_metadata(
		&runtime, shared.handle, null
	) == STORAGE_INVALID_HANDLE);
	assert(mitos_storage::storage_metadata(
		&runtime, shared_copy.handle, &shared_metadata
	) == STORAGE_OK);
	assert(shared_metadata.owner_count == 1);
	assert(mitos_storage::release(&runtime, shared_copy.handle) == STORAGE_OK);

	LayoutDescriptor affine_layout = test_layout(&owner, "AffineWords", COPY_AFFINE);
	defer affine_layout.deinit(mem);
	LayoutHandleResult affine_registered = mitos_storage::register_layout(&runtime, (TypeId)2, &affine_layout);
	assert(affine_registered.error == STORAGE_OK);
	StorageHandleResult affine = mitos_storage::allocate_affine_bytes(
		&runtime, affine_registered.handle, 16, 8, 8, 8
	);
	assert(affine.error == STORAGE_OK);
	assert(mitos_storage::replicate(&runtime, affine.handle).error == STORAGE_POLICY_VIOLATION);
	StorageViewResult affine_view = mitos_storage::view(&runtime, affine.handle, 0, 2, 8, 8);
	assert(affine_view.error == STORAGE_OK);
	char[8] word;
	foreach (&byte : word) *byte = 0;
	word[0] = 42;
	assert(mitos_storage::store(&runtime, &affine_view.view, 1, word[..]) == STORAGE_OK);
	char[8] loaded;
	assert(mitos_storage::load(&runtime, &affine_view.view, 1, loaded[..]) == STORAGE_OK);
	assert(loaded[0] == 42);
	assert(mitos_storage::freeze(&runtime, affine.handle).error == STORAGE_BUSY);
	assert(mitos_storage::close_view(&runtime, &affine_view.view) == STORAGE_OK);
	assert(mitos_storage::load(
		&runtime, &affine_view.view, 1, loaded[..]
	) == STORAGE_STALE_VIEW);
	StorageHandleResult frozen = mitos_storage::freeze(&runtime, affine.handle);
	assert(frozen.error == STORAGE_OK);
	assert(mitos_storage::replicate(
		&runtime, affine.handle
	).error == STORAGE_INVALID_HANDLE);
	StorageHandleResult frozen_copy = mitos_storage::replicate(&runtime, frozen.handle);
	assert(frozen_copy.error == STORAGE_OK);
	assert(mitos_storage::release(&runtime, frozen.handle) == STORAGE_OK);
	assert(mitos_storage::release(&runtime, frozen_copy.handle) == STORAGE_OK);
	StorageRuntime isolated;
	isolated.init(mem, 16, 32, 1024 * 1024);
	defer isolated.free();
	LayoutDescriptor isolated_layout = test_layout(
		&owner, "IsolatedWords", COPY_SHARED_IMMUTABLE
	);
	defer isolated_layout.deinit(mem);
	LayoutHandleResult isolated_registered = mitos_storage::register_layout(
		&isolated, (TypeId)1, &isolated_layout
	);
	assert(isolated_registered.error == STORAGE_OK);
	StorageHandleResult isolated_storage = mitos_storage::allocate_shared_bytes(
		&isolated, isolated_registered.handle, shared_bytes[..], 8, 8, 8
	);
	assert(isolated_storage.error == STORAGE_OK);
	assert(mitos_storage::allocate_shared_bytes(
		&runtime, isolated_registered.handle, shared_bytes[..], 8, 8, 8
	).error == STORAGE_INVALID_LAYOUT);
	assert(mitos_storage::storage_metadata(
		&runtime, isolated_storage.handle, null
	) == STORAGE_INVALID_HANDLE);
	assert(mitos_storage::release(&isolated, isolated_storage.handle) == STORAGE_OK);
}


fn void storage_quota_and_recycled_runtime_aliases_fail_closed() @test
{
	ModuleKey owner = mitos::core_module_key(mem);
	defer owner.deinit(mem);
	LayoutDescriptor layout = test_layout(&owner, "QuotaWords", COPY_SHARED_IMMUTABLE);
	defer layout.deinit(mem);
	char[16] bytes;
	foreach (&byte : bytes) *byte = 0;

	StorageRuntime runtime;
	runtime.init(mem, 8, 3, 1024 * 1024);
	StorageRuntime stale_runtime = runtime;
	LayoutHandleResult registered = mitos_storage::register_layout(
		&runtime, (TypeId)1, &layout
	);
	assert(registered.error == STORAGE_OK);
	StorageHandleResult original = mitos_storage::allocate_shared_bytes(
		&runtime, registered.handle, bytes[..], 8, 8, 8
	);
	assert(original.error == STORAGE_OK);
	StorageHandleResult replica = mitos_storage::replicate(&runtime, original.handle);
	assert(replica.error == STORAGE_OK);
	assert(mitos_storage::replicate(
		&runtime, original.handle
	).error == STORAGE_LIMIT);
	assert(mitos_storage::view(
		&runtime, original.handle, 0, 2, 8, 8
	).error == STORAGE_LIMIT);
	assert(mitos_storage::release(&runtime, replica.handle) == STORAGE_OK);
	StorageViewResult view = mitos_storage::view(
		&runtime, original.handle, 0, 2, 8, 8
	);
	assert(view.error == STORAGE_OK);
	assert(mitos_storage::close_view(&runtime, &view.view) == STORAGE_OK);
	assert(mitos_storage::release(&runtime, original.handle) == STORAGE_OK);
	runtime.free();

	StorageRuntime recycled;
	recycled.init(mem, 8, 3, 1024 * 1024);
	defer recycled.free();
	assert(recycled.control_coordinate != 0 && recycled.identity != 0);
	assert(recycled.control_coordinate != stale_runtime.control_coordinate);
	assert((recycled.control_coordinate & 4_095UL)
		== (stale_runtime.control_coordinate & 4_095UL));
	assert(mitos_storage::register_layout(
		&stale_runtime, (TypeId)1, &layout
	).error == STORAGE_NOT_INITIALIZED);
	StorageRuntime forged_generation = recycled;
	forged_generation.control_coordinate = stale_runtime.control_coordinate;
	assert(mitos_storage::register_layout(
		&forged_generation, (TypeId)1, &layout
	).error == STORAGE_NOT_INITIALIZED);
	StorageRuntime forged_identity = recycled;
	forged_identity.identity = recycled.identity == 1 ? 2 : 1;
	assert(mitos_storage::register_layout(
		&forged_identity, (TypeId)1, &layout
	).error == STORAGE_NOT_INITIALIZED);
	forged_generation.free();
	forged_identity.free();
	stale_runtime.free();
	assert(stale_runtime.control_coordinate == 0 && stale_runtime.identity == 0);
	LayoutHandleResult after_stale_free = mitos_storage::register_layout(
		&recycled, (TypeId)1, &layout
	);
	assert(after_stale_free.error == STORAGE_OK);
}

fn void external_effect_suspension_is_affine_and_runtime_local() @test
{
	String source = `effect IO:
  wait() of I64
end

main():
  IO.wait()
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	require_suspension(&lowered.program);
	assert(lowered.program.effects.operations.len == 1);
	SuspendHostContext expected_call = {
		.effect = lowered.program.effects.operations[0].effect,
		.operation = lowered.program.effects.operations[0].id,
		.argument_count = 0,
	};


	DeltaRuntime draining;
	draining.init(1);
	assert(draining.register_host_handler(
		&lowered.program, 0, &suspend_host, &expected_call
	));
	TypedDeltaExecutionResult abandoned = draining.run(&lowered.program);
	assert(abandoned.status == TYPED_DELTA_SUSPENDED);
	assert(draining.active_suspension_count() == 1);
	assert(expected_call.calls == 1);

	abandoned.deinit();
	assert(draining.free());
	assert(draining.active_suspension_count() == 0);

	DeltaRuntime runtime;
	runtime.init(2);
	defer runtime.free();
	assert(!runtime.register_host_handler(
		&lowered.program, 0, &suspend_host, &expected_call,
		delta_net_abstract_machine::TYPED_DELTA_HOST_ABI_MAJOR + 1,
		delta_net_abstract_machine::TYPED_DELTA_HOST_ABI_MINOR
	));
	assert(!runtime.register_host_handler(
		&lowered.program, 0, &suspend_host, &expected_call,
		delta_net_abstract_machine::TYPED_DELTA_HOST_ABI_MAJOR,
		delta_net_abstract_machine::TYPED_DELTA_HOST_ABI_MINOR + 1
	));
	assert(runtime.register_host_handler(
		&lowered.program, 0, &suspend_host, &expected_call
	));
	assert(!runtime.register_host_handler(
		&lowered.program, 1, &suspend_host, &expected_call
	));
	DeltaProgramBuildResult isolated_program = mitos::lower_delta_program(&parsed.program, mem);
	defer isolated_program.deinit();
	assert(isolated_program.ok());
	assert(isolated_program.program.runtime_identity != lowered.program.runtime_identity);
	TypedDeltaExecutionResult wrong_program = runtime.run(&isolated_program.program);
	defer wrong_program.deinit();
	assert(wrong_program.status == TYPED_DELTA_FAILED);
	assert(wrong_program.diagnostics.len == 1);
	assert(wrong_program.diagnostics[0].message
		== "external effect has no compatible registered host ABI 2.0 handler");
	mitos::DeltaProgram forged_program = lowered.program;
	TypedDeltaExecutionResult forged = runtime.run(&forged_program);
	defer forged.deinit();
	assert(forged.status == TYPED_DELTA_FAILED);
	assert(forged.diagnostics.len == 1);
	assert(forged.diagnostics[0].message
		== "external effect has no compatible registered host ABI 2.0 handler");
	TypedDeltaExecutionResult suspended = runtime.run(&lowered.program);
	defer suspended.deinit();
	assert(suspended.status == TYPED_DELTA_SUSPENDED);
	assert(suspended.token.runtime_identity == runtime.runtime_identity());
	TypedDeltaHostValue malformed_value = {
		.kind = HOST_VALUE_BOOL,
		.type_id = mitos::TYPE_ID_I64,
		.boolean = true,
	};
	TypedDeltaExecutionResult malformed = runtime.resume(
		suspended.token, malformed_value
	);
	defer malformed.deinit();
	assert(malformed.status == TYPED_DELTA_FAILED);
	assert(malformed.diagnostics.len == 1);
	assert(malformed.diagnostics[0].message
		== "resumption result is not a valid host representation for its TypeId");
	assert(runtime.active_suspension_count() == 1);
	TypedDeltaHostValue resumed_value = {
		.kind = HOST_VALUE_I64,
		.type_id = mitos::TYPE_ID_I64,
		.integer = 42,
	};
	TypedDeltaExecutionResult resumed = runtime.resume(suspended.token, resumed_value);
	defer resumed.deinit();
	assert(resumed.status == TYPED_DELTA_COMPLETE);
	assert(resumed.formatted == "42");
	TypedDeltaExecutionResult repeated = runtime.resume(suspended.token, resumed_value);
	defer repeated.deinit();
	assert(repeated.status == TYPED_DELTA_FAILED);
	assert(repeated.diagnostics.len == 1);
	assert(repeated.diagnostics[0].message
		== "resumption token is invalid or belongs to another runtime");

	TypedDeltaExecutionResult cancellable = runtime.run(&lowered.program);
	defer cancellable.deinit();
	assert(cancellable.status == TYPED_DELTA_SUSPENDED);
	DeltaTokenActionResult cancelled = runtime.cancel(cancellable.token, mem);
	assert(cancelled.ok && cancelled.diagnostic.len == 0);
	DeltaTokenActionResult cancel_reuse = runtime.cancel(cancellable.token, mem);
	assert(!cancel_reuse.ok);
	assert(cancel_reuse.diagnostic
		== "resumption token is invalid or belongs to another runtime");
	cancel_reuse.deinit();

	TypedDeltaExecutionResult second_cancellable = runtime.run(&lowered.program);
	defer second_cancellable.deinit();
	assert(second_cancellable.status == TYPED_DELTA_SUSPENDED);
	assert(second_cancellable.token.slot_id == cancellable.token.slot_id);
	assert(second_cancellable.token.generation != cancellable.token.generation);
	DeltaResumptionToken tampered = second_cancellable.token;
	tampered.capability_low ^= 1;
	DeltaTokenActionResult rejected = runtime.cancel(tampered, mem);
	assert(!rejected.ok);
	assert(rejected.diagnostic
		== "resumption token is invalid or belongs to another runtime");
	rejected.deinit();
	assert(runtime.active_suspension_count() == 1);
	DeltaTokenActionResult second_cancelled =
		runtime.cancel(second_cancellable.token, mem);
	assert(second_cancelled.ok && second_cancelled.diagnostic.len == 0);
	DeltaTokenActionResult second_cancel_reuse =
		runtime.cancel(second_cancellable.token, mem);
	assert(!second_cancel_reuse.ok);
	assert(second_cancel_reuse.diagnostic
		== "resumption token is invalid or belongs to another runtime");
	second_cancel_reuse.deinit();
	assert(runtime.active_suspension_count() == 0);

	assert(runtime.unregister_host_handler(&lowered.program, 0));
	assert(!runtime.unregister_host_handler(&lowered.program, 0));
	assert(runtime.register_host_handler(
		&lowered.program, 0, &suspend_host, &expected_call
	));
	ulong prior_program_identity = lowered.program.runtime_identity;
	lowered.program.runtime_identity = mitos::new_runtime_identity();
	assert(lowered.program.runtime_identity != prior_program_identity);
	TypedDeltaExecutionResult rotated = runtime.run(&lowered.program);
	defer rotated.deinit();
	assert(rotated.status == TYPED_DELTA_FAILED);
	assert(rotated.diagnostics.len == 1);
	assert(rotated.diagnostics[0].message
		== "external effect has no compatible registered host ABI 2.0 handler");
	assert(runtime.register_host_handler(
		&lowered.program, 0, &suspend_host, &expected_call
	));
	TypedDeltaExecutionResult reenrolled = runtime.run(&lowered.program);
	defer reenrolled.deinit();
	assert(reenrolled.status == TYPED_DELTA_SUSPENDED);
	DeltaTokenActionResult reenrolled_cancel = runtime.cancel(reenrolled.token, mem);
	assert(reenrolled_cancel.ok && reenrolled_cancel.diagnostic.len == 0);

	DeltaRuntime isolated;
	isolated.init(1);
	defer isolated.free();
	TypedDeltaExecutionResult missing = isolated.run(&lowered.program);
	defer missing.deinit();
	assert(missing.status == TYPED_DELTA_FAILED);
	assert(runtime.free());
}

fn void runtime_aliases_share_one_tombstone_and_free_is_reentrant_safe() @test
{
	DeltaRuntime owned;
	owned.init(1);
	DeltaRuntime handle_copy = owned;
	ulong identity = owned.runtime_identity();
	assert(identity != 0);
	assert(handle_copy.runtime_identity() == identity);
	assert(handle_copy.free());
	assert(handle_copy.runtime_identity() == 0);
	assert(owned.runtime_identity() == 0);
	assert(owned.free());

	String source = `effect IO:
  ready() of I64
end
main():
  IO.ready()
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	DeltaRuntime runtime;
	runtime.init(1);
	FreeDuringHostContext context = { .runtime = &runtime };
	assert(runtime.register_host_handler(
		&lowered.program, 0, &free_during_host_call, &context
	));
	TypedDeltaExecutionResult first = runtime.run(&lowered.program);
	defer first.deinit();
	assert(first.status == TYPED_DELTA_COMPLETE);
	assert(first.formatted == "42");
	assert(context.attempted && !context.succeeded);
	context.attempted = false;
	TypedDeltaExecutionResult second = runtime.run(&lowered.program);
	defer second.deinit();
	assert(second.status == TYPED_DELTA_COMPLETE);
	assert(second.formatted == "42");
	assert(context.attempted && !context.succeeded);
	assert(runtime.free());
}


fn void failed_free_cannot_race_suspension_publication() @test
{
	String source = `effect IO:
  wait() of I64
end
main():
  IO.wait()
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(
		&parsed.program, mem
	);
	defer lowered.deinit();
	assert(lowered.ok());
	require_suspension(&lowered.program);
	DeltaRuntime runtime;
	runtime.init(1);
	FreeDuringHostContext context = { .runtime = &runtime };
	assert(runtime.register_host_handler(
		&lowered.program, 0, &suspend_after_failed_free, &context
	));
	TypedDeltaExecutionResult suspended = runtime.run(&lowered.program);
	assert(context.attempted && !context.succeeded);
	assert(suspended.status == TYPED_DELTA_SUSPENDED);
	assert(runtime.active_suspension_count() == 1);
	DeltaTokenActionResult cancelled = runtime.cancel(suspended.token, mem);
	assert(cancelled.ok && cancelled.diagnostic.len == 0);
	suspended.deinit();
	assert(runtime.active_suspension_count() == 0);
	assert(runtime.free());
}


fn void delta_runtime_coordinates_recycle_beyond_control_capacity() @test
{
	DeltaRuntime first;
	first.init(1);
	assert(first.runtime_identity() != 0);
	DeltaRuntime stale = first;
	assert(first.free());

	DeltaRuntime recycled;
	recycled.init(1);
	ulong recycled_identity = recycled.runtime_identity();
	assert(recycled_identity != 0);
	assert(recycled.slot == stale.slot);
	assert(recycled.generation != stale.generation);
	assert(recycled.identity != stale.identity);
	assert(stale.runtime_identity() == 0);
	assert(stale.free());
	assert(recycled.runtime_identity() == recycled_identity);

	DeltaRuntime forged_slot = recycled;
	forged_slot.slot = 4096;
	assert(forged_slot.runtime_identity() == 0);
	assert(forged_slot.free());
	DeltaRuntime forged_generation = recycled;
	forged_generation.generation = recycled.generation == 1 ? 2 : 1;
	assert(forged_generation.runtime_identity() == 0);
	assert(forged_generation.free());
	DeltaRuntime forged_identity = recycled;
	forged_identity.identity = recycled.identity == 1 ? 2 : 1;
	assert(forged_identity.runtime_identity() == 0);
	assert(forged_identity.free());
	assert(recycled.runtime_identity() == recycled_identity);
	assert(recycled.free());

	for (usz cycle = 0; cycle < 4_100; cycle++)
	{
		DeltaRuntime runtime;
		runtime.init(1);
		assert(runtime.runtime_identity() != 0);
		assert(runtime.free());
	}
}


fn void registry_index_handles_recover_from_forgery_and_recycling() @test
{
	String source = `type Box:
  value of I64
end
effect Reader:
  read() of I64
end
main():
  0
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	TypeRegistryBuildResult types = mitos::build_type_registry(&parsed.program, mem);
	defer types.deinit();
	assert(types.ok());
	assert(mitos::find_type(&types.registry, "Box") != mitos::TYPE_ID_INVALID);

	TypeRegistryIndexHandle stale_type = types.registry.runtime_indexes;
	types.registry.runtime_indexes.slot = 4_097;
	assert(mitos::find_type(&types.registry, "Box") != mitos::TYPE_ID_INVALID);
	TypeRegistryIndexHandle recycled_type = types.registry.runtime_indexes;
	assert(recycled_type.slot == stale_type.slot);
	assert(recycled_type.generation != stale_type.generation);
	types.registry.runtime_indexes.generation =
		recycled_type.generation == 1 ? 2 : 1;
	assert(mitos::find_type(&types.registry, "Box") != mitos::TYPE_ID_INVALID);
	types.registry.runtime_indexes.identity =
		types.registry.runtime_indexes.identity == 1 ? 2 : 1;
	assert(mitos::find_type(&types.registry, "Box") != mitos::TYPE_ID_INVALID);
	types.registry.runtime_indexes = stale_type;
	assert(mitos::find_type(&types.registry, "Box") != mitos::TYPE_ID_INVALID);
	assert(types.registry.runtime_indexes.generation != stale_type.generation);

	TypeRegistryBuildResult other_types = mitos::build_type_registry(
		&parsed.program, mem
	);
	defer other_types.deinit();
	assert(other_types.ok());
	types.registry.runtime_indexes = other_types.registry.runtime_indexes;
	assert(mitos::find_type(&types.registry, "Box") != mitos::TYPE_ID_INVALID);
	assert(mitos::find_type(
		&other_types.registry, "Box"
	) != mitos::TYPE_ID_INVALID);

	EffectRegistryBuildResult effects = mitos::build_effect_registry(
		&parsed.program, &types.registry, mem
	);
	defer effects.deinit();
	assert(effects.ok());
	assert(mitos::find_effect(&effects.registry, "Reader") != mitos::EFFECT_ID_INVALID);
	EffectRegistryIndexHandle stale_effect = effects.registry.index_state;
	effects.registry.index_state.slot = 4_097;
	assert(mitos::find_effect(
		&effects.registry, "Reader"
	) != mitos::EFFECT_ID_INVALID);
	EffectRegistryIndexHandle recycled_effect = effects.registry.index_state;
	assert(recycled_effect.slot == stale_effect.slot);
	assert(recycled_effect.generation != stale_effect.generation);
	effects.registry.index_state.generation =
		recycled_effect.generation == 1 ? 2 : 1;
	assert(mitos::find_effect(
		&effects.registry, "Reader"
	) != mitos::EFFECT_ID_INVALID);
	effects.registry.index_state.identity =
		effects.registry.index_state.identity == 1 ? 2 : 1;
	assert(mitos::find_effect(
		&effects.registry, "Reader"
	) != mitos::EFFECT_ID_INVALID);
	effects.registry.index_state = stale_effect;
	assert(mitos::find_effect(
		&effects.registry, "Reader"
	) != mitos::EFFECT_ID_INVALID);
	assert(effects.registry.index_state.generation != stale_effect.generation);
	EffectRegistryBuildResult other_effects = mitos::build_effect_registry(
		&parsed.program, &other_types.registry, mem
	);
	defer other_effects.deinit();
	assert(other_effects.ok());
	effects.registry.index_state = other_effects.registry.index_state;
	assert(mitos::find_effect(
		&effects.registry, "Reader"
	) != mitos::EFFECT_ID_INVALID);
	assert(mitos::find_effect(
		&other_effects.registry, "Reader"
	) != mitos::EFFECT_ID_INVALID);
}


fn void mir_runtime_aliases_are_stale_safe_idempotent_and_reinitializable() @test
{
	MirRuntime runtime;
	runtime.init();
	assert(runtime.ready());
	assert(runtime.capabilities() != 0);
	MirRegistrySnapshot initial_snapshot;
	assert(runtime.snapshot(&initial_snapshot));
	assert(initial_snapshot.generation != 0);
	assert(initial_snapshot.helper_count == 0);
	assert(initial_snapshot.capabilities == runtime.capabilities());
	MirRuntime genuine_alias = runtime;
	assert(genuine_alias.ready());
	MirRuntime forged_capability = runtime;
	forged_capability.capability_low ^= 1;
	assert(!forged_capability.ready());
	assert(forged_capability.capabilities() == 0);
	MirRegistrySnapshot forged_snapshot;
	assert(!forged_capability.snapshot(&forged_snapshot));
	assert(forged_capability.free());
	assert(runtime.ready());
	assert(genuine_alias.ready());
	MirRuntime stale = runtime;
	MirRuntime stale_after_reinit = runtime;
	assert(runtime.free());
	assert(!stale.ready());
	assert(stale.capabilities() == 0);
	MirExecutionResult execution = mitos_mir::execute(&stale, null, mem);
	defer execution.free();
	assert(execution.status == mitos_mir::MirStatus.ERROR);
	assert(execution.diagnostic == "MIR runtime is unavailable");
	assert(stale.free());
	assert(stale.free());

	runtime.init();
	assert(runtime.ready());
	assert(runtime.capabilities() != 0);
	MirRegistrySnapshot recycled_snapshot;
	assert(runtime.snapshot(&recycled_snapshot));
	assert(recycled_snapshot.generation != 0);
	assert(recycled_snapshot.helper_count == 0);
	assert(recycled_snapshot.capabilities == runtime.capabilities());
	assert(!stale_after_reinit.ready());
	assert(stale_after_reinit.capabilities() == 0);
	MirExecutionResult recycled_execution = mitos_mir::execute(
		&stale_after_reinit, null, mem
	);
	defer recycled_execution.free();
	assert(recycled_execution.status == mitos_mir::MirStatus.ERROR);
	assert(recycled_execution.diagnostic == "MIR runtime is unavailable");
	assert(stale_after_reinit.free());
	assert(runtime.ready());
	assert(runtime.free());
	assert(runtime.free());
}


fn void mir_runtime_free_during_host_callback_is_nonblocking() @test
{
	String source = `effect IO:
  ready() of I64
end
main():
  IO.ready()
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	MitosMirLowerResult native_program = mitos_jit::lower_delta_program_to_mir(
		&lowered.program, mem
	);
	defer native_program.free();
	assert(native_program.ok());
	MirProgram bridge_program = native_program.program.view();
	assert(bridge_program.effect_operation_count == 1);

	MirRuntime runtime;
	runtime.init();
	assert(runtime.ready());
	MirFreeDuringHostContext context = {
		.runtime = &runtime,
		.result_type = bridge_program.i64_type,
	};
	assert(runtime.register_host_helper(
		&bridge_program, 0, &mir_free_during_host_call, &context
	));
	MirRegistrySnapshot enrolled_snapshot;
	assert(runtime.snapshot(&enrolled_snapshot));
	assert(enrolled_snapshot.helper_count == 1);
	MirExecutionResult execution = mitos_mir::execute(
		&runtime, &bridge_program, mem
	);
	defer execution.free();
	assert(execution.status == mitos_mir::MirStatus.NATIVE);
	assert(execution.result == "42");
	assert(context.attempted);
	assert(!context.succeeded);
	assert(runtime.ready());
	assert(runtime.unregister_host_helper(&bridge_program, 0));
	MirRegistrySnapshot released_snapshot;
	assert(runtime.snapshot(&released_snapshot));
	assert(released_snapshot.helper_count == 0);
	assert(runtime.free());
}
fn void suspended_first_argument_is_borrowed_and_released() @test
{
	String source = `effect IO:
  wait(value of I64) of I64
end
main():
  IO.wait(41)
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	require_suspension(&lowered.program);
	assert(lowered.program.effects.operations.len == 1);
	SuspendHostContext expected = {
		.effect = lowered.program.effects.operations[0].effect,
		.operation = lowered.program.effects.operations[0].id,
		.argument_count = 1,
		.expects_i64 = true,
		.expected_i64 = 41,
	};
	DeltaRuntime runtime;
	runtime.init(1);
	assert(runtime.register_host_handler(
		&lowered.program, 0, &suspend_host, &expected
	));
	TypedDeltaExecutionResult suspended = runtime.run(&lowered.program);
	assert(suspended.status == TYPED_DELTA_SUSPENDED);
	assert(expected.calls == 1);
	assert(runtime.active_suspension_count() == 1);
	DeltaTokenActionResult cancelled = runtime.cancel(suspended.token, mem);
	assert(cancelled.ok && cancelled.diagnostic.len == 0);
	suspended.deinit();
	assert(runtime.active_suspension_count() == 0);
	assert(runtime.free());
}

fn void recursive_generic_layouts_terminate_as_unsized() @test
{
	String source = `type Self of T:
  next of Self of T
end
type Left of T:
  right of Right of T
end
type Right of T:
  left of Left of T
end
main():
  1
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	TypeRegistryBuildResult types = mitos::build_type_registry(&parsed.program, mem);
	defer types.deinit();
	assert(types.ok());
	String[2] names = { "Self", "Left" };
	mitos::TypeId[1] arguments = { mitos::TYPE_ID_I64 };
	foreach (name : names)
	{
		mitos::TypeId constructor = mitos::find_type(&types.registry, name);
		assert(constructor != mitos::TYPE_ID_INVALID);
		mitos::TypeId instance = mitos::TYPE_ID_INVALID;
		assert(mitos::intern_type(
			&types.registry, constructor, arguments[..], &instance
		));
		mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
			&types.registry, instance
		);
		assert(descriptor != null);
		assert(descriptor.layout.kind == mitos::LayoutKind.LAYOUT_UNSIZED);
		assert(!descriptor.layout.sized);
		assert(descriptor.layout.size == 0);
		assert(descriptor.layout.alignment == 1);
		mitos::TypeId repeated = mitos::TYPE_ID_INVALID;
		assert(mitos::intern_type(
			&types.registry, constructor, arguments[..], &repeated
		));
		assert(repeated == instance);
	}
}

fn void repeated_effect_calls_charge_only_unique_reverse_edges() @test
{
	String[2] sources = {
		`effect Reader:
  read() of I64
end
leaf():
  Reader.read()
end
repeat():
  first := leaf()
  second := leaf()
  third := leaf()
  first + second + third
end
main():
  handle repeat():
    Reader.read(): resume(1)
    return(value of I64): value
  end
end
`,
		`effect Reader:
  read() of I64
end
leaf1():
  Reader.read()
end
leaf2():
  Reader.read()
end
leaf3():
  Reader.read()
end
repeat():
  first := leaf1()
  second := leaf2()
  third := leaf3()
  first + second + third
end
main():
  handle repeat():
    Reader.read(): resume(1)
    return(value of I64): value
  end
end
`,
	};
	usz[2] steps;
	foreach (index, source : sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		TypeRegistryBuildResult types =
			mitos::build_type_registry(&parsed.program, mem);
		assert(types.ok());
		EffectRegistryBuildResult effects = mitos::build_effect_registry(
			&parsed.program, &types.registry, mem
		);
		assert(effects.ok());
		EffectAnalysis analysis = mitos::infer_effect_rows(
			&parsed.program, &effects.registry, &types.registry, mem
		);
		assert(analysis.ok());
		steps[index] = analysis.inference_steps;
		analysis.deinit();
		effects.deinit();
		types.deinit();
		parsed.deinit();
	}
	assert(steps[0] < steps[1]);

	foreach (index, source : sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		TypeRegistryBuildResult types =
			mitos::build_type_registry(&parsed.program, mem);
		assert(types.ok());
		EffectRegistryBuildResult effects = mitos::build_effect_registry(
			&parsed.program, &types.registry, mem
		);
		assert(effects.ok());
		EffectAnalysis bounded = mitos::infer_effect_rows(
			&parsed.program, &effects.registry, &types.registry, mem, steps[0]
		);
		assert(bounded.ok() == (index == 0));
		if (index)
		{
			assert(bounded.diagnostics.len == 1);
			assert(bounded.diagnostics[0].message
				== "effect-row inference exceeded its bounded graph-work budget");
		}
		bounded.deinit();
		effects.deinit();
		types.deinit();
		parsed.deinit();
	}
}

fn void unused_and_ready_console_programs_remain_mir_eligible() @test
{
	String[2] sources = {
		`effect Console:
  print(value of String) of Unit
end
main():
  42
end
`,
		`effect Console:
  print(value of String) of Unit
end
main():
  Console.print("")
end
`,
	};
	foreach (index, source : sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
		assert(lowered.ok());
		assert(lowered.program.feature_manifest.required & mitos::DELTA_FEATURE_HOST);
		assert(!(lowered.program.feature_manifest.required
			& mitos::DELTA_FEATURE_SUSPENSION));
		assert(lowered.program.feature_manifest.optional
			& mitos::DELTA_FEATURE_SUSPENSION);
		assert(mitos_jit::mir_supports_required_features(&lowered.program));
		MitosJitResult native = mitos_jit::jit_delta_program(
			&lowered.program, mem
		);
		assert(native.status == mitos_mir::MirStatus.NATIVE);
		assert(native.result == (index ? "()" : "42"));
		native.free();
		lowered.deinit();
		parsed.deinit();
	}
}


fn void bound_effectful_closure_preserves_lexical_handler_in_mir() @test
{
	String source = `effect Reader:
  read() of I64
end

main():
  f := do() of I64 does Reader:
    Reader.read()
  end
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());

	DeltaRuntime runtime;
	runtime.init(1);
	defer runtime.free();
	TypedDeltaExecutionResult interpreted = runtime.run(&lowered.program);
	defer interpreted.deinit();
	assert(interpreted.status == TYPED_DELTA_COMPLETE);
	assert(interpreted.formatted == "42");

	MitosJitResult native = mitos_jit::jit_delta_program(&lowered.program, mem);
	defer native.free();
	assert(native.status == mitos_mir::MirStatus.NATIVE);
	assert(native.result == "42");
}

fn void returned_and_stored_effectful_closures_preserve_handlers_in_mir() @test
{
	String[2] programs = {
		`effect Reader:
  read() of I64
end
make():
  do() of I64 does Reader:
    Reader.read()
  end
end
main():
  f := make()
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`,
		`effect Reader:
  read() of I64
end
enum Holder:
  Holder(value)
end
main():
  holder := Holder(do() of I64 does Reader:
    Reader.read()
  end)
  match holder:
    Holder(f):
      handle f():
        Reader.read(): resume(42)
        return(value of I64): value
      end
  end
end
`
	};
	bool[2] expected_generic = { false, false };
	String[2] expected_results = { "42", "42" };
	foreach (index, source : programs)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
		assert(lowered.ok());
		bool requires_generic = (lowered.program.feature_manifest.required
			& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES)
			!= (mitos::DeltaFeatureBits)0;
		assert(requires_generic == expected_generic[index]);
		DeltaRuntime runtime;
		runtime.init(1);
		TypedDeltaExecutionResult interpreted = runtime.run(&lowered.program);
		assert(interpreted.status == TYPED_DELTA_COMPLETE);
		assert(interpreted.formatted == expected_results[index]);
		MitosJitResult native = mitos_jit::jit_delta_program(
			&lowered.program, mem
		);
		if (expected_generic[index])
		{
			assert(native.status == mitos_mir::MirStatus.ERROR);
			assert(native.diagnostic
				== "MIR backend does not support dynamic effectful closures; use generic Delta execution");
		}
		else
		{
			assert(native.status == mitos_mir::MirStatus.NATIVE);
			assert(native.result == expected_results[index]);
		}
		native.free();
		interpreted.deinit();
		assert(runtime.free());
		lowered.deinit();
		parsed.deinit();
	}
}

fn void dynamic_effectful_closures_negotiate_generic_delta_backend() @test
{
	String source = `enum Choice:
  A
  B
end
effect Pick:
  choose() of Choice
end
effect Reader:
  read() of I64
end
main():
  choice := handle Pick.choose():
    Pick.choose(): resume(A)
    return(value of Choice): value
  end
  f := match choice:
    A:
      do() of I64 does Reader:
        Reader.read()
      end
    B:
      do() of I64 does Reader:
        Reader.read() + 1
      end
  end
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	assert(lowered.program.feature_manifest.required
		& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES);
	DeltaRuntime runtime;
	runtime.init(1);
	defer runtime.free();
	TypedDeltaExecutionResult interpreted = runtime.run(&lowered.program);
	defer interpreted.deinit();
	assert(interpreted.status == TYPED_DELTA_COMPLETE);
	assert(interpreted.formatted == "42");
	MitosJitResult native = mitos_jit::jit_delta_program(&lowered.program, mem);
	defer native.free();
	assert(native.status == mitos_mir::MirStatus.ERROR);
	assert(native.diagnostic
		== "MIR backend does not support dynamic effectful closures; use generic Delta execution");
}
fn void same_lambda_with_distinct_captures_requires_generic_backend() @test
{
	String source = `enum Choice:
  A
  B
end
effect Pick:
  choose() of Choice
end
effect Reader:
  read() of I64
end
make(offset of I64):
  do() of I64 does Reader:
    Reader.read() + offset
  end
end
main():
  choice := handle Pick.choose():
    Pick.choose(): resume(A)
    return(value of Choice): value
  end
  f := match choice:
    A: make(0)
    B: make(1)
  end
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	assert(lowered.program.feature_manifest.required
		& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES);
	DeltaRuntime runtime;
	runtime.init(1);
	TypedDeltaExecutionResult interpreted = runtime.run(&lowered.program);
	assert(interpreted.status == TYPED_DELTA_COMPLETE);
	assert(interpreted.formatted == "42");
	interpreted.deinit();
	assert(runtime.free());
}

fn void returned_lazy_closure_materializes_a_valid_register() @test
{
	String source = `make(value of I64):
  do() of I64:
    value
  end
end
main():
  f := make(42)
  f()
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem
	);
	defer native.free();
	assert(native.status == mitos_mir::MirStatus.NATIVE);
	assert(native.result == "42");
}


fn void alternate_match_arm_lazy_closure_matches_generic_execution() @test
{
	String source = `enum Choice:
  A
  B
end
main():
  f := match B:
    A:
      do() of I64:
        41
      end
    B:
      do() of I64:
        42
      end
  end
  f()
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	DeltaRuntime runtime;
	runtime.init(1);
	defer runtime.free();
	TypedDeltaExecutionResult interpreted = runtime.run(&lowered.program);
	defer interpreted.deinit();
	assert(interpreted.status == TYPED_DELTA_COMPLETE);
	assert(interpreted.formatted == "42");
	MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem
	);
	defer native.free();
	assert(native.status == mitos_mir::MirStatus.NATIVE);
	assert(native.result == interpreted.formatted);
}


fn void handler_request_closure_provenance_preserves_native_singletons() @test
{
	String singleton = `effect Reader:
  read() of I64
end
effect Relay:
  invoke(f of Function) of I64
end
main():
  handle handle Relay.invoke(do() of I64 does Reader:
    Reader.read()
  end):
    Relay.invoke(g of Function): g()
    return(value of I64): value
  end:
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`;
	String distinct = `enum Choice:
  A
  B
end
effect Pick:
  choose() of Choice
end
effect Reader:
  read() of I64
end
effect Relay:
  invoke(f of Function) of I64
end
main():
  choice := handle Pick.choose():
    Pick.choose(): resume(A)
    return(value of Choice): value
  end
  handle handle Relay.invoke(match choice:
    A:
      do() of I64 does Reader:
        Reader.read()
      end
    B:
      do() of I64 does Reader:
        Reader.read() + 1
      end
  end):
    Relay.invoke(g of Function): g()
    return(value of I64): value
  end:
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`;
	String[2] sources = { singleton, distinct };
	foreach (index, source : sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		DeltaProgramBuildResult lowered = mitos::lower_delta_program(
			&parsed.program, mem
		);
		assert(lowered.ok());
		bool dynamic = (lowered.program.feature_manifest.required
			& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES)
			!= (mitos::DeltaFeatureBits)0;
		assert(dynamic == (index == 1));
		MitosJitResult native = mitos_jit::jit_delta_program(
			&lowered.program, mem
		);
		if (!index)
		{
			assert(native.status == mitos_mir::MirStatus.NATIVE);
			assert(native.result == "42");
		}
		else
		{
			assert(native.status == mitos_mir::MirStatus.ERROR);
			assert(native.diagnostic
				== "MIR backend does not support dynamic effectful closures; use generic Delta execution");
		}
		native.free();
		lowered.deinit();
		parsed.deinit();
	}
}


fn void parser_identity_and_expression_bounds_fail_closed() @test
{
	String[2] duplicate_sources = {
		`same(left of T, right of T) of T:
  left
end
same(left of U, right of U) of U:
  left
end
main():
  1
end
`,
		`same(value):
  value
end
same(value of Any):
  value
end
main():
  1
end
`,
	};
	foreach (source : duplicate_sources)
	{
		MitosParseResult duplicate = mitos::parse_program(source, mem);
		assert(!duplicate.ok());
		assert(duplicate.diagnostics.len == 1);
		assert(duplicate.diagnostics[0].message == "duplicate method signature");
		duplicate.deinit();
	}

	DString source;
	source.init(mem);
	defer source.free();
	source.append_string("main():\n  ");
	for (usz depth = 0; depth < 257; depth++) source.append_char('-');
	source.append_string("1\nend\n");
	MitosParseResult bounded = mitos::parse_program(source.str_view(), mem);
	defer bounded.deinit();
	assert(!bounded.ok());
	assert(bounded.diagnostics.len == 1);
	assert(bounded.diagnostics[0].message
		== "expression nesting exceeds the maximum depth of 256");
}

fn void duplicate_nominal_type_names_are_rejected_across_arity() @test
{
	String duplicate_source = `type Foo
type Foo of T:
  value of T
end
main():
  1
end
`;
	MitosParseResult duplicate = mitos::parse_program(duplicate_source, mem);
	if (!duplicate.ok())
	{
		assert(duplicate.diagnostics.len == 1);
		assert(duplicate.diagnostics[0].message
			== "duplicate type declaration");
	}
	else
	{
		TypeRegistryBuildResult rejected =
			mitos::build_type_registry(&duplicate.program, mem);
		assert(!rejected.ok());
		assert(rejected.diagnostics.len == 1);
		assert(rejected.diagnostics[0].message
			== "duplicate nominal type name");
		rejected.deinit();
	}
	duplicate.deinit();

	MitosParseResult builtin = mitos::parse_program(
		"type I64\nmain():\n  1\nend\n", mem
	);
	assert(builtin.ok());
	TypeRegistryBuildResult compatible =
		mitos::build_type_registry(&builtin.program, mem);
	assert(compatible.ok());
	assert(mitos::find_type(&compatible.registry, "I64")
		== mitos::TYPE_ID_I64);
	compatible.deinit();
	builtin.deinit();
}

fn void reserved_superposition_is_rejected() @test
{
	MitosParseResult reserved = mitos::parse_program(
		"type Superposition\nmain():\n  1\nend\n", mem
	);
	defer reserved.deinit();
	assert(reserved.ok());
	DeltaProgramBuildResult rejected = mitos::lower_delta_program(&reserved.program, mem);
	defer rejected.deinit();
	assert(!rejected.ok());
	assert(rejected.diagnostics.len == 1);
	assert(rejected.diagnostics[0].message
		== "Superposition is a reserved type constructor and cannot be redeclared");
}

fn void aot_v4_round_trips_effects_and_rejects_negative_spans() @test
{
	char[160] artifact_buffer;
	char[160] invalid_buffer;
	char[160] fixture_buffer;
	String artifact_path = unique_aot_test_path(artifact_buffer[..], "roundtrip");
	String invalid_path = unique_aot_test_path(invalid_buffer[..], "invalid");
	String fixture_path = unique_aot_test_path(fixture_buffer[..], "fixture");
	assert(artifact_path != invalid_path && artifact_path != fixture_path
		&& invalid_path != fixture_path);
	reserve_aot_test_path(artifact_path);
	reserve_aot_test_path(invalid_path);
	reserve_aot_test_path(fixture_path);
	defer (void)libc::remove(artifact_path.zstr_tcopy());
	defer (void)libc::remove(invalid_path.zstr_tcopy());
	defer (void)libc::remove(fixture_path.zstr_tcopy());
	String source = `effect Reader:
  read() of I64
end
main():
  handle Reader.read():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	MitosAotResult written = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, artifact_path, mem
	);
	defer written.free();
	assert(written.status == mitos_mir::MirStatus.NATIVE);
	assert(written.diagnostic.len == 0);
	char[] emitted = file::load(mem, artifact_path)!!;
	defer alloc::free(mem, emitted);
	assert(emitted.len >= 12);
	assert((String)emitted[:8] == "MITOSAOT");
	assert(emitted[8] == 4 && emitted[9] == 0
		&& emitted[10] == 0 && emitted[11] == 0);

	assert(emitted.len > 28 + 16);
	usz manifest_offset = 28;
	assert(test_u32_le_equals(
		emitted, manifest_offset, (uint)mitos::DELTA_RECORD_MANIFEST
	));
	assert(test_u32_le_equals(
		emitted, manifest_offset + 4, (uint)mitos::DELTA_RECORD_REQUIRED
	));
	ulong manifest_payload_u64 = test_u64_le(emitted, manifest_offset + 8);
	assert(manifest_payload_u64 <= (ulong)usz::max);
	usz manifest_size = 16 + (usz)manifest_payload_u64;
	assert(manifest_size <= emitted.len - manifest_offset);
	usz module_offset = manifest_offset + manifest_size;
	assert(module_offset <= emitted.len && emitted.len - module_offset >= 16);
	assert(test_u32_le_equals(
		emitted, module_offset, (uint)mitos::DELTA_RECORD_MODULE
	));
	assert(test_u32_le_equals(
		emitted, module_offset + 4, (uint)mitos::DELTA_RECORD_REQUIRED
	));
	ulong module_payload_u64 = test_u64_le(emitted, module_offset + 8);
	assert(module_payload_u64 <= (ulong)usz::max);
	usz module_size = 16 + (usz)module_payload_u64;
	assert(module_size <= emitted.len - module_offset);
	char[] misordered = alloc::new_array(mem, char, (sz)emitted.len);
	defer alloc::free(mem, misordered);
	for (usz index = 0; index < manifest_offset; index++)
	{
		misordered[index] = emitted[index];
	}
	for (usz index = 0; index < module_size; index++)
	{
		misordered[manifest_offset + index] = emitted[module_offset + index];
	}
	for (usz index = 0; index < manifest_size; index++)
	{
		misordered[manifest_offset + module_size + index] =
			emitted[manifest_offset + index];
	}
	usz suffix_offset = module_offset + module_size;
	for (usz index = suffix_offset; index < emitted.len; index++)
	{
		misordered[index] = emitted[index];
	}
	file::save(fixture_path, misordered)!!;
	MitosAotResult fixed_fixture = delta_net_abstract_machine::execute_mitos_aot(
		fixture_path, mem
	);
	defer fixed_fixture.free();
	assert(fixed_fixture.status == mitos_mir::MirStatus.ERROR);
	assert(fixed_fixture.diagnostic
		== "AOT v4 manifest must be the first required record");
	MitosAotResult executed = delta_net_abstract_machine::execute_mitos_aot(
		artifact_path, mem
	);
	defer executed.free();
	assert(executed.status == mitos_mir::MirStatus.NATIVE);
	assert(executed.result == "42");

	assert(lowered.program.spans.len > 0);
	mitos::MitosSpan original = lowered.program.spans[0];
	lowered.program.spans[0].start.offset = -1;
	MitosAotResult invalid = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, invalid_path, mem
	);
	defer invalid.free();
	lowered.program.spans[0] = original;
	assert(invalid.status == mitos_mir::MirStatus.ERROR);
	assert(invalid.diagnostic == "AOT v4 requires a valid complete DeltaProgram");
}
fn void generic_aot_result_obeys_the_callers_allocator() @test
{
	char[160] artifact_buffer;
	String artifact_path = unique_aot_test_path(artifact_buffer[..], "allocator");
	reserve_aot_test_path(artifact_path);
	defer (void)libc::remove(artifact_path.zstr_tcopy());
	String source = `enum Choice:
  A
  B
end
effect Pick:
  choose() of Choice
end
effect Reader:
  read() of I64
end
main():
  choice := handle Pick.choose():
    Pick.choose(): resume(A)
    return(value of Choice): value
  end
  f := match choice:
    A:
      do() of I64 does Reader:
        Reader.read()
      end
    B:
      do() of I64 does Reader:
        Reader.read() + 1
      end
  end
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	assert(lowered.program.feature_manifest.required
		& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES);
	MitosAotResult written = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, artifact_path, mem
	);
	defer written.free();
	assert(written.status == mitos_mir::MirStatus.NATIVE);

	TrackingAllocator tracker;
	tracker.init(mem);
	MitosAotResult executed = delta_net_abstract_machine::execute_mitos_aot(
		artifact_path, &tracker
	);
	assert(executed.status == mitos_mir::MirStatus.NATIVE);
	assert(executed.result == "42");
	assert(tracker.allocation_count() > 0);
	executed.free();
	assert(tracker.allocation_count() == 0);
	assert(!tracker.has_leaks());
	tracker.free();
}


fn void generic_and_mir_aot_strings_share_canonical_rendering() @test
{
	char[160] generic_buffer;
	char[160] mir_buffer;
	String generic_path = unique_aot_test_path(
		generic_buffer[..], "string-generic"
	);
	String mir_path = unique_aot_test_path(mir_buffer[..], "string-mir");
	reserve_aot_test_path(generic_path);
	reserve_aot_test_path(mir_path);
	defer (void)libc::remove(generic_path.zstr_tcopy());
	defer (void)libc::remove(mir_path.zstr_tcopy());
	String[2] sources = {
		`enum Choice:
  A
  B
end
effect Pick:
  choose() of Choice
end
effect Reader:
  read() of I64
end
main():
  choice := handle Pick.choose():
    Pick.choose(): resume(A)
    return(value of Choice): value
  end
  f := match choice:
    A:
      do() of I64 does Reader:
        Reader.read()
      end
    B:
      do() of I64 does Reader:
        Reader.read() + 1
      end
  end
  ignored := handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
  "quote:\" slash:\\ line:\n carriage:\r tab:\t"
end
`,
		`main():
  "quote:\" slash:\\ line:\n carriage:\r tab:\t"
end
`,
	};
	String[2] paths = { generic_path, mir_path };
	String expected = `"quote:\" slash:\\ line:\n carriage:\r tab:\t"`;
	foreach (index, source : sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		DeltaProgramBuildResult lowered = mitos::lower_delta_program(
			&parsed.program, mem
		);
		assert(lowered.ok());
		bool requires_generic = (lowered.program.feature_manifest.required
			& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES)
			!= (mitos::DeltaFeatureBits)0;
		assert(requires_generic == (index == 0));
		DeltaRuntime runtime;
		runtime.init(1);
		TypedDeltaExecutionResult generic = runtime.run(&lowered.program);
		assert(generic.status == TYPED_DELTA_COMPLETE);
		assert(generic.formatted == expected);
		generic.deinit();
		assert(runtime.free());
		MitosAotResult written = delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, paths[index], mem
		);
		assert(written.status == mitos_mir::MirStatus.NATIVE);
		written.free();
		MitosAotResult executed = delta_net_abstract_machine::execute_mitos_aot(
			paths[index], mem
		);
		assert(executed.status == mitos_mir::MirStatus.NATIVE);
		assert(executed.result == expected);
		executed.free();
		lowered.deinit();
		parsed.deinit();
	}
}


fn void canonical_rendering_escapes_every_control_byte() @test
{
	MitosParseResult parsed = mitos::parse_program(
		"main():\n  \"aaaa\"\nend\n", mem
	);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());
	mitos::DeltaNode* string_node = null;
	foreach (&node : lowered.program.image.nodes)
		if (node.kind == mitos::DeltaNodeKind.DELTA_STRING
			&& node.string_value.len == 4)
		{
			string_node = node;
			break;
		}
	assert(string_node != null);
	char* bytes = string_node.string_value.ptr;
	bytes[0] = (char)0;
	bytes[1] = (char)0x01;
	bytes[2] = (char)0x1f;
	bytes[3] = (char)0x7f;
	String expected = "\"\\x00\\x01\\x1f\\x7f\"";
	DeltaRuntime runtime;
	runtime.init(1);
	TypedDeltaExecutionResult generic = runtime.run(&lowered.program);
	assert(generic.status == TYPED_DELTA_COMPLETE);
	assert(generic.formatted == expected);
	MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem
	);
	assert(native.status == mitos_mir::MirStatus.NATIVE);
	assert(native.result == expected);
	native.free();
	generic.deinit();
	assert(runtime.free());
	lowered.deinit();
	parsed.deinit();
}

fn void type_formatting_enforces_the_exact_one_mibibyte_limit() @test
{
	DString name;
	name.init(mem);
	defer name.free();
	for (usz index = 0; index < mitos::MITOS_MAX_TYPE_FORMAT_BYTES; index++)
	{
		name.append_char('x');
	}
	mitos::TypeExpr named = {
		.kind = mitos::TypeExprKind.TYPE_EXPR_NAMED,
		.name = name.str_view(),
	};
	String exact = mitos::format_type_expr(&named, mem);
	assert(exact.len == mitos::MITOS_MAX_TYPE_FORMAT_BYTES);
	alloc::free(mem, exact);
	name.append_char('x');
	named.name = name.str_view();
	String oversized = mitos::format_type_expr(&named, mem);
	assert(oversized == "<type expression exceeds formatting limit>");
	alloc::free(mem, oversized);

	DString child_name;
	child_name.init(mem);
	defer child_name.free();
	for (
		usz index = 0;
		index < mitos::MITOS_MAX_TYPE_FORMAT_BYTES - 5;
		index++
	) child_name.append_char('x');
	mitos::TypeExpr child = {
		.kind = mitos::TypeExprKind.TYPE_EXPR_NAMED,
		.name = child_name.str_view(),
	};
	mitos::TypeArgument[1] arguments = { { .value = &child } };
	mitos::TypeExpr application = {
		.kind = mitos::TypeExprKind.TYPE_EXPR_APPLICATION,
		.name = "P",
		.arguments = arguments[..],
	};
	String nested_exact = mitos::format_type_expr(&application, mem);
	assert(nested_exact.len == mitos::MITOS_MAX_TYPE_FORMAT_BYTES);
	alloc::free(mem, nested_exact);
	child_name.append_char('x');
	child.name = child_name.str_view();
	String nested_oversized = mitos::format_type_expr(&application, mem);
	assert(nested_oversized
		== "<type expression exceeds formatting limit>");
	alloc::free(mem, nested_oversized);
}

fn void storage_total_quota_and_capability_authenticators_fail_closed() @test
{
	DString oversized_name;
	oversized_name.init(mem);
	defer oversized_name.free();
	for (usz index = 0; index < 16 * 1024; index++) oversized_name.append_char('x');
	ModuleKey owner = mitos::core_module_key(mem);
	defer owner.deinit(mem);
	LayoutDescriptor oversized = test_layout(
		&owner, oversized_name.str_view(), COPY_SHARED_IMMUTABLE
	);
	defer oversized.deinit(mem);
	StorageRuntime tiny;
	tiny.init(mem, 2, 8, 8 * 1024);
	defer tiny.free();
	assert(tiny.control_coordinate != 0);
	usz before;
	assert(mitos_storage::retained_bytes(&tiny, &before) == STORAGE_OK);
	assert(before <= 8 * 1024);
	assert(mitos_storage::register_layout(
		&tiny, (TypeId)1, &oversized
	).error == STORAGE_LIMIT);
	usz after;
	assert(mitos_storage::retained_bytes(&tiny, &after) == STORAGE_OK);
	assert(after == before);

	LayoutDescriptor quota_seed = test_layout(
		&owner, "QuotaSeed", COPY_SHARED_IMMUTABLE
	);
	defer quota_seed.deinit(mem);
	LayoutDescriptor quota_boundary = test_layout(
		&owner, "QuotaBoundary", COPY_SHARED_IMMUTABLE
	);
	defer quota_boundary.deinit(mem);
	LayoutDescriptor quota_shorter = test_layout(
		&owner, "QuotaBoundar", COPY_SHARED_IMMUTABLE
	);
	defer quota_shorter.deinit(mem);
	usz boundary_low = 1;
	usz boundary_high = 1024 * 1024;
	while (boundary_low < boundary_high)
	{
		usz middle = boundary_low + (boundary_high - boundary_low) / 2;
		if (quota_accepts_second_layout(
			middle, &quota_seed, &quota_boundary
		))
		{
			boundary_high = middle;
		}
		else
		{
			boundary_low = middle + 1;
		}
	}
	usz boundary_threshold = boundary_low;
	assert(boundary_threshold > 1);
	assert(quota_accepts_second_layout(
		boundary_threshold, &quota_seed, &quota_boundary
	));
	assert(!quota_accepts_second_layout(
		boundary_threshold - 1, &quota_seed, &quota_boundary
	));

	usz shorter_low = 1;
	usz shorter_high = 1024 * 1024;
	while (shorter_low < shorter_high)
	{
		usz middle = shorter_low + (shorter_high - shorter_low) / 2;
		if (quota_accepts_second_layout(
			middle, &quota_seed, &quota_shorter
		))
		{
			shorter_high = middle;
		}
		else
		{
			shorter_low = middle + 1;
		}
	}
	usz shorter_threshold = shorter_low;
	assert(shorter_threshold + 1 == boundary_threshold);
	assert(quota_accepts_second_layout(
		shorter_threshold, &quota_seed, &quota_shorter
	));
	assert(!quota_accepts_second_layout(
		shorter_threshold - 1, &quota_seed, &quota_shorter
	));

	StorageRuntime quota_strict;
	quota_strict.init(mem, 2, 8, boundary_threshold - 1);
	defer quota_strict.free();
	assert(mitos_storage::register_layout(
		&quota_strict, (TypeId)1, &quota_seed
	).error == STORAGE_OK);
	assert(mitos_storage::register_layout(
		&quota_strict, (TypeId)2, &quota_boundary
	).error == STORAGE_LIMIT);
	assert(mitos_storage::register_layout(
		&quota_strict, (TypeId)2, &quota_shorter
	).error == STORAGE_OK);

	StorageRuntime runtime;
	runtime.init(mem, 2, 8, 1024 * 1024);
	defer runtime.free();
	LayoutDescriptor layout = test_layout(&owner, "AuthenticatedWords", COPY_AFFINE);
	defer layout.deinit(mem);
	LayoutHandleResult registered = mitos_storage::register_layout(
		&runtime, (TypeId)1, &layout
	);
	assert(registered.error == STORAGE_OK);
	StorageHandleResult storage = mitos_storage::allocate_affine_bytes(
		&runtime, registered.handle, 8, 8, 8, 8
	);
	assert(storage.error == STORAGE_OK);
	StorageHandle forged_owner = storage.handle;
	forged_owner.authentication_high ^= 1;
	assert(mitos_storage::storage_metadata(
		&runtime, forged_owner, null
	) == STORAGE_INVALID_HANDLE);
	assert(mitos_storage::view(
		&runtime, forged_owner, 0, 1, 8, 8
	).error == STORAGE_INVALID_HANDLE);
	assert(mitos_storage::replicate(
		&runtime, forged_owner
	).error == STORAGE_INVALID_HANDLE);

	StorageViewResult view = mitos_storage::view(
		&runtime, storage.handle, 0, 1, 8, 8
	);
	assert(view.error == STORAGE_OK);
	StorageView forged_view = view.view;
	forged_view.authentication_low ^= 1;
	char[8] word;
	foreach (&byte : word) *byte = 0;
	assert(mitos_storage::load(
		&runtime, &forged_view, 0, word[..]
	) == STORAGE_STALE_VIEW);
	assert(mitos_storage::store(
		&runtime, &forged_view, 0, word[..]
	) == STORAGE_STALE_VIEW);
	assert(mitos_storage::close_view(
		&runtime, &forged_view
	) == STORAGE_STALE_VIEW);
	assert(mitos_storage::store(&runtime, &view.view, 0, word[..]) == STORAGE_OK);
	assert(mitos_storage::close_view(&runtime, &view.view) == STORAGE_OK);
	assert(mitos_storage::release(&runtime, storage.handle) == STORAGE_OK);
}


fn void host_dispatch_routes_the_second_effect_operation() @test
{
	String source = `effect IO:
  ignored(value of I64) of I64
  selected(value of I64) of I64
end
main():
  IO.selected(41)
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	assert(lowered.program.effects.operations.len == 2);
	assert(lowered.program.effects.operations[0].id
		!= lowered.program.effects.operations[1].id);
	ReadyHostContext ignored = {
		.effect = lowered.program.effects.operations[0].effect,
		.operation = lowered.program.effects.operations[0].id,
		.expected_argument = -1,
		.result = -1,
	};
	ReadyHostContext selected = {
		.effect = lowered.program.effects.operations[1].effect,
		.operation = lowered.program.effects.operations[1].id,
		.expected_argument = 41,
		.result = 42,
	};
	DeltaRuntime runtime;
	runtime.init(1);
	defer runtime.free();
	assert(runtime.register_host_handler(
		&lowered.program, 0, &ready_host, &ignored
	));
	assert(runtime.register_host_handler(
		&lowered.program, 1, &ready_host, &selected
	));
	TypedDeltaExecutionResult execution = runtime.run(&lowered.program);
	defer execution.deinit();
	assert(execution.status == TYPED_DELTA_COMPLETE);
	assert(execution.formatted == "42");
	assert(ignored.calls == 0);
	assert(selected.calls == 1);
	assert(runtime.unregister_host_handler(&lowered.program, 1));
	assert(runtime.unregister_host_handler(&lowered.program, 0));
}


fn void missing_external_helper_is_rejected_before_execution() @test
{
	String source = `effect IO:
  unused() of I64
end
main():
  42
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(
		&parsed.program, mem
	);
	defer lowered.deinit();
	assert(lowered.ok());
	assert(lowered.program.effects.operations.len == 1);
	DeltaRuntime runtime;
	runtime.init(1);
	TypedDeltaExecutionResult generic = runtime.run(&lowered.program);
	defer generic.deinit();
	assert(generic.status == TYPED_DELTA_FAILED);
	assert(generic.diagnostics.len == 1);
	assert(generic.diagnostics[0].message
		== "external effect has no compatible registered host ABI 2.0 handler");
	assert(runtime.free());
	MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem
	);
	defer native.free();
	assert(native.status == mitos_mir::MirStatus.ERROR);
	assert(native.diagnostic
		== "standard MIR helpers require every external operation to be canonical Console.print");
}


fn void aggregate_mir_host_argument_is_rejected_before_callback() @test
{
	String source = `type Box:
  value of I64
end
effect IO:
  inspect(value of Box) of I64
end
main():
  IO.inspect(Box(41))
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(
		&parsed.program, mem
	);
	defer lowered.deinit();
	assert(lowered.ok());
	MitosMirLowerResult native_program = mitos_jit::lower_delta_program_to_mir(
		&lowered.program, mem
	);
	defer native_program.free();
	assert(native_program.ok());
	MirProgram bridge_program = native_program.program.view();
	assert(bridge_program.effect_operation_count == 1);
	MirCallCountContext context = { .result_type = bridge_program.i64_type };
	MirRuntime runtime;
	runtime.init();
	assert(runtime.register_host_helper(
		&bridge_program, 0, &count_mir_host_calls, &context
	));
	MirExecutionResult execution = mitos_mir::execute(
		&runtime, &bridge_program, mem
	);
	defer execution.free();
	assert(execution.status == mitos_mir::MirStatus.ERROR);
	assert(execution.diagnostic
		== "external effect arguments cannot contain aggregate values under host ABI 2.0");
	assert(context.calls == 0);
	assert(runtime.unregister_host_helper(&bridge_program, 0));
	assert(runtime.free());
}


fn void parallel_root_occurrence_order_resets_per_source() @test
{
	String source = `effect IO:
  ready() of I64
end
main():
  parallel:
    left := IO.ready()
    right := IO.ready()
    left + right
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(
		&parsed.program, mem
	);
	defer lowered.deinit();
	assert(lowered.ok());
	DeltaSourceOrderContext context = { .result = 21 };
	DeltaRuntime runtime;
	runtime.init(4);
	assert(runtime.register_host_handler(
		&lowered.program, 0, &record_delta_source_order, &context
	));
	for (usz repetition = 0; repetition < 16; repetition++)
	{
		context = { .result = 21 };
		TypedDeltaExecutionResult execution = runtime.run(&lowered.program);
		assert(execution.status == TYPED_DELTA_COMPLETE);
		assert(execution.formatted == "42");
		assert(context.calls == 2);
		assert(context.source_orders[0] < context.source_orders[1]);
		assert(context.occurrence_orders[0] == 0);
		assert(context.occurrence_orders[1] == 0);
		execution.deinit();
	}
	assert(runtime.unregister_host_handler(&lowered.program, 0));
	assert(runtime.free());
}


fn void repeated_multiworker_named_closure_and_effect_execution_matches_mir() @test
{
	String[2] sources = {
		`make():
  do():
    42
  end
end

main():
  parallel:
    f := make()
    x := 0
    f()
  end
end
`,
		`effect Reader:
  read() of I64
end

ask():
  Reader.read()
end

main():
  handle parallel:
    value of I64 := ask()
    zero := 0
    value
  end:
    Reader.read(): resume(41)
    return(value of I64): value
  end
end
`,
	};
	String[2] expected = { "42", "41" };
	foreach (source_index, source : sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		DeltaProgramBuildResult lowered = mitos::lower_delta_program(
			&parsed.program, mem
		);
		assert(lowered.ok());
		assert(lowered.program.feature_manifest.required
			& mitos::DELTA_FEATURE_PARALLEL);
		for (usz repetition = 0; repetition < 8; repetition++)
		{
			DeltaRuntime runtime;
			runtime.init(4);
			TypedDeltaExecutionResult generic = runtime.run(&lowered.program);
			assert(generic.status == TYPED_DELTA_COMPLETE);
			assert(generic.formatted == expected[source_index]);
			generic.deinit();
			assert(runtime.free());

			MitosJitResult native = mitos_jit::jit_delta_program(
				&lowered.program, mem
			);
			assert(native.status == mitos_mir::MirStatus.NATIVE);
			assert(native.result == expected[source_index]);
			native.free();
		}
		lowered.deinit();
		parsed.deinit();
	}
}


fn void handler_produced_closures_lower_and_escaped_resume_is_rejected() @test
{
	String[2] valid_sources = {
		`effect Reader:
  read() of I64
end

effect Make:
  get() of Function
end

main():
  f := handle Make.get():
    Make.get():
      do() of I64 does Reader:
        Reader.read()
      end
    return(value of Function): value
  end
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`,
		`effect Reader:
  read() of I64
end

effect Make:
  get() of Function
end

main():
  f := handle Make.get():
    Make.get():
      resume(do() of I64 does Reader:
        Reader.read()
      end)
    return(value of Function): value
  end
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`,
	};
	foreach (source : valid_sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		DeltaProgramBuildResult lowered = mitos::lower_delta_program(
			&parsed.program, mem
		);
		assert(lowered.ok());
		assert(!(lowered.program.feature_manifest.required
			& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES));
		DeltaRuntime runtime;
		runtime.init(1);
		TypedDeltaExecutionResult generic = runtime.run(&lowered.program);
		assert(generic.status == TYPED_DELTA_COMPLETE);
		assert(generic.formatted == "42");
		MitosJitResult native = mitos_jit::jit_delta_program(
			&lowered.program, mem
		);
		assert(native.status == mitos_mir::MirStatus.NATIVE);
		assert(native.result == "42");
		native.free();
		generic.deinit();
		assert(runtime.free());
		lowered.deinit();
		parsed.deinit();
	}

	String escaped_source = `effect Reader:
  read() of I64
end

main():
  handle Reader.read():
    Reader.read():
      do() of I64:
        resume(1)
      end
    return(value of I64): value
  end
end
`;
	MitosParseResult escaped = mitos::parse_program(escaped_source, mem);
	defer escaped.deinit();
	assert(escaped.ok());
	DeltaProgramBuildResult rejected = mitos::lower_delta_program(
		&escaped.program, mem
	);
	defer rejected.deinit();
	assert(!rejected.ok());
	assert(rejected.diagnostics.len == 1);
	assert(rejected.diagnostics[0].message
		== "resume cannot escape its operation handler clause through a lambda");
}


fn void aot_match_metadata_is_rejected_by_writer_and_loader() @test
{
	char[160] artifact_buffer;
	char[160] writer_buffer;
	char[160] forged_buffer;
	String artifact_path = unique_aot_test_path(artifact_buffer[..], "match-valid");
	String writer_path = unique_aot_test_path(writer_buffer[..], "match-writer");
	String forged_path = unique_aot_test_path(forged_buffer[..], "match-forged");
	assert(artifact_path != writer_path && artifact_path != forged_path
		&& writer_path != forged_path);
	reserve_aot_test_path(artifact_path);
	reserve_aot_test_path(writer_path);
	reserve_aot_test_path(forged_path);
	defer (void)libc::remove(artifact_path.zstr_tcopy());
	defer (void)libc::remove(writer_path.zstr_tcopy());
	defer (void)libc::remove(forged_path.zstr_tcopy());
	String source = `enum Choice:
  Pair(left of I64, rght of I64)
  Empty
end
enum Other:
  Foreign(left of I64, rght of I64)
end
type Box of T:
  value of T
end
classify(value of Box of T) of I64:
  0
end
main():
  identity := do(value of I64) of I64:
    value
  end
  ignored := identity(0)
  generic := classify(Box(0))
  match Pair(1, 2):
    Pair(left, rght): left + rght
    _: 0
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	mitos::DeltaNode* match_node = null;
	usz match_count = 0;
	foreach (&node : lowered.program.image.nodes)
	{
		if (node.kind != mitos::DeltaNodeKind.DELTA_MATCH) continue;
		match_node = node;
		match_count++;
	}
	assert(match_count == 1 && match_node != null);
	assert(match_node.branches.len == 2);
	assert(!match_node.branches[0].wildcard);
	assert(match_node.branches[0].bindings.len == 2);
	assert(match_node.branches[0].bindings[0] == "left");
	assert(match_node.branches[0].bindings[1] == "rght");
	assert(match_node.branches[1].wildcard);
	assert(match_node.branches[1].bindings.len == 0);

	MitosAotResult valid = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, artifact_path, mem
	);
	defer valid.free();
	assert(valid.status == mitos_mir::MirStatus.NATIVE);
	assert(valid.diagnostic.len == 0);
	char[] emitted = file::load(mem, artifact_path)!!;
	defer alloc::free(mem, emitted);
	assert(emitted.len >= 20);
	MitosAotResult canonical = delta_net_abstract_machine::execute_mitos_aot(
		artifact_path, mem
	);
	defer canonical.free();
	assert(canonical.status == mitos_mir::MirStatus.NATIVE);
	assert(canonical.result == "3");

	usz foreign_constructor = lowered.program.constructors.len;
	foreach (constructor_index, &constructor : lowered.program.constructors)
	{
		if (constructor.name == "Foreign")
		{
			foreign_constructor = (usz)constructor_index;
			break;
		}
	}
	assert(foreign_constructor < lowered.program.constructors.len);
	uint original_branch_constructor = match_node.branches[0].constructor;
	match_node.branches[0].constructor = (uint)foreign_constructor;
	MitosAotResult cross_type_write =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	match_node.branches[0].constructor = original_branch_constructor;
	defer cross_type_write.free();
	assert(cross_type_write.status == mitos_mir::MirStatus.ERROR);
	assert(cross_type_write.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	assert((usz)original_branch_constructor < lowered.program.constructors.len);
	mitos::DeltaConstructorDescriptor* pair_constructor =
		&lowered.program.constructors[(usz)original_branch_constructor];
	mitos::DeltaConstructorDescriptor* other_constructor =
		&lowered.program.constructors[foreign_constructor];
	mitos::SymbolKey original_other_constructor_key = other_constructor.key;
	other_constructor.key = mitos::clone_symbol_key(
		&pair_constructor.key, lowered.program.allocator
	);
	MitosAotResult duplicate_constructor_identity =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	other_constructor.key.deinit(lowered.program.allocator);
	other_constructor.key = original_other_constructor_key;
	defer duplicate_constructor_identity.free();
	assert(duplicate_constructor_identity.status == mitos_mir::MirStatus.ERROR);
	assert(duplicate_constructor_identity.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	mitos::DeltaNode* constructor_node = null;
	foreach (&node : lowered.program.image.nodes)
	{
		if (node.kind == mitos::DeltaNodeKind.DELTA_CONSTRUCTOR
			&& node.descriptor == (usz)original_branch_constructor)
		{
			constructor_node = node;
			break;
		}
	}
	assert(constructor_node != null);
	mitos::SymbolKey original_constructor_node_key = constructor_node.key;
	constructor_node.key = mitos::clone_symbol_key(
		&other_constructor.key, lowered.program.allocator
	);
	MitosAotResult misrouted_constructor_node =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	constructor_node.key.deinit(lowered.program.allocator);
	constructor_node.key = original_constructor_node_key;
	defer misrouted_constructor_node.free();
	assert(misrouted_constructor_node.status == mitos_mir::MirStatus.ERROR);
	assert(misrouted_constructor_node.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	mitos::TypePattern* inactive_type_pattern = null;
	foreach (&constructor : lowered.program.constructors)
	{
		foreach (&pattern : constructor.field_patterns)
		{
			if (pattern.kind == mitos::TypePatternKind.TYPE_PATTERN_EXACT
				|| pattern.kind
					== mitos::TypePatternKind.TYPE_PATTERN_APPLICATION)
			{
				inactive_type_pattern = pattern;
				break;
			}
		}
		if (inactive_type_pattern) break;
	}
	assert(inactive_type_pattern != null);
	String original_type_pattern_variable = inactive_type_pattern.variable;
	inactive_type_pattern.variable = "inactive".copy(lowered.program.allocator);
	MitosAotResult inactive_type_write =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	alloc::free(lowered.program.allocator, inactive_type_pattern.variable);
	inactive_type_pattern.variable = original_type_pattern_variable;
	defer inactive_type_write.free();
	assert(inactive_type_write.status == mitos_mir::MirStatus.ERROR);
	assert(inactive_type_write.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	mitos::MethodTypePattern* inactive_method_pattern = null;
	foreach (&root : lowered.program.method_roots)
	{
		foreach (&pattern : root.parameter_patterns)
		{
			if (pattern.kind
				== mitos::MethodTypePatternKind.METHOD_PATTERN_APPLICATION)
			{
				inactive_method_pattern = pattern;
				break;
			}
		}
		if (inactive_method_pattern) break;
	}
	assert(inactive_method_pattern != null);
	String original_method_pattern_name = inactive_method_pattern.name;
	inactive_method_pattern.name = "inactive".copy(lowered.program.allocator);
	MitosAotResult inactive_method_write =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	alloc::free(lowered.program.allocator, inactive_method_pattern.name);
	inactive_method_pattern.name = original_method_pattern_name;
	defer inactive_method_write.free();
	assert(inactive_method_write.status == mitos_mir::MirStatus.ERROR);
	assert(inactive_method_write.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	mitos::TypeDescriptor* choice_type = null;
	mitos::TypeDescriptor* other_type = null;
	mitos::TypeDescriptor* box_type = null;
	foreach (&descriptor : lowered.program.types.descriptors)
	{
		if (descriptor.name == "Choice") choice_type = descriptor;
		if (descriptor.name == "Other") other_type = descriptor;
		if (descriptor.name == "Box"
			&& descriptor.kind
				== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_CONCRETE)
		{
			box_type = descriptor;
		}
	}
	assert(choice_type != null && other_type != null && box_type != null);
	CopyPolicy original_copy_policy = choice_type.layout.copy_policy;
	choice_type.layout.copy_policy = original_copy_policy == COPY_TRIVIAL
		? COPY_AFFINE : COPY_TRIVIAL;
	MitosAotResult forged_copy_policy =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	choice_type.layout.copy_policy = original_copy_policy;
	assert(forged_copy_policy.status == mitos_mir::MirStatus.ERROR);
	assert(forged_copy_policy.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	forged_copy_policy.free();

	usz original_alignment = choice_type.layout.alignment;
	choice_type.layout.alignment = original_alignment == 1 ? 2 : 1;
	MitosAotResult forged_alignment =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	choice_type.layout.alignment = original_alignment;
	assert(forged_alignment.status == mitos_mir::MirStatus.ERROR);
	assert(forged_alignment.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	forged_alignment.free();
	assert(choice_type.key.arity == 0 && box_type.key.arity == 1);
	String original_box_name = box_type.name;
	String original_box_key_name = box_type.key.name;
	String original_box_layout_name = box_type.layout.stable_key.name;
	box_type.name = choice_type.name.copy(lowered.program.allocator);
	box_type.key.name = choice_type.name.copy(lowered.program.allocator);
	box_type.layout.stable_key.name =
		choice_type.name.copy(lowered.program.allocator);
	MitosAotResult duplicate_type_name_write =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	alloc::free(lowered.program.allocator, box_type.name);
	alloc::free(lowered.program.allocator, box_type.key.name);
	alloc::free(
		lowered.program.allocator, box_type.layout.stable_key.name
	);
	box_type.name = original_box_name;
	box_type.key.name = original_box_key_name;
	box_type.layout.stable_key.name = original_box_layout_name;
	assert(duplicate_type_name_write.status
		== mitos_mir::MirStatus.ERROR);
	assert(duplicate_type_name_write.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	duplicate_type_name_write.free();
	String original_other_name = other_type.name;
	mitos::SymbolKey original_other_key = other_type.key;
	mitos::SymbolKey original_other_stable_key = other_type.layout.stable_key;
	other_type.name = choice_type.name.copy(lowered.program.allocator);
	other_type.key = mitos::clone_symbol_key(
		&choice_type.key, lowered.program.allocator
	);
	other_type.layout.stable_key = mitos::clone_symbol_key(
		&choice_type.layout.stable_key, lowered.program.allocator
	);
	MitosAotResult duplicate_type_key_write =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	alloc::free(lowered.program.allocator, other_type.name);
	other_type.key.deinit(lowered.program.allocator);
	other_type.layout.stable_key.deinit(lowered.program.allocator);
	other_type.name = original_other_name;
	other_type.key = original_other_key;
	other_type.layout.stable_key = original_other_stable_key;
	defer duplicate_type_key_write.free();
	assert(duplicate_type_key_write.status == mitos_mir::MirStatus.ERROR);
	assert(duplicate_type_key_write.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	assert(lowered.program.image.edges.len >= 2);
	mitos::DeltaEdge first_edge = lowered.program.image.edges[0];
	lowered.program.image.edges[0] = lowered.program.image.edges[1];
	lowered.program.image.edges[1] = first_edge;
	MitosAotResult permuted_edge_write =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	first_edge = lowered.program.image.edges[0];
	lowered.program.image.edges[0] = lowered.program.image.edges[1];
	lowered.program.image.edges[1] = first_edge;
	defer permuted_edge_write.free();
	assert(permuted_edge_write.status == mitos_mir::MirStatus.ERROR);
	assert(permuted_edge_write.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	String[2] forged_bindings = { "left", "left" };
	String[] original_bindings = match_node.branches[0].bindings;
	match_node.branches[0].bindings = forged_bindings[..];
	MitosAotResult rejected_write = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, writer_path, mem
	);
	match_node.branches[0].bindings = original_bindings;
	defer rejected_write.free();
	assert(rejected_write.status == mitos_mir::MirStatus.ERROR);
	assert(rejected_write.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	usz binding_offset = 0;
	usz binding_matches = 0;
	for (usz offset = 0; offset <= emitted.len - 36; offset++)
	{
		if (!test_u32_le_equals(emitted, offset, 0)
			|| !test_u32_le_equals(
				emitted, offset + 4, match_node.branches[0].constructor
			)
			|| !test_u32_le_equals(emitted, offset + 8, 2)
			|| !test_u32_le_equals(emitted, offset + 12, 4)
			|| (String)emitted[(offset + 16)..(offset + 19)] != "left"
			|| !test_u32_le_equals(emitted, offset + 20, 4)
			|| (String)emitted[(offset + 24)..(offset + 27)] != "rght"
			|| !test_u32_le_equals(
				emitted, offset + 28, (uint)match_node.branches[0].body
			)
			|| !test_u32_le_equals(
				emitted, offset + 32, match_node.branches[0].span
			)) continue;
		binding_offset = offset;
		binding_matches++;
	}
	assert(binding_matches == 1);
	char[] duplicate_binding = alloc::new_array(mem, char, (sz)emitted.len);
	defer alloc::free(mem, duplicate_binding);
	foreach (index, byte : emitted) duplicate_binding[(usz)index] = byte;
	duplicate_binding[binding_offset + 24] = 'l';
	duplicate_binding[binding_offset + 25] = 'e';
	duplicate_binding[binding_offset + 26] = 'f';
	duplicate_binding[binding_offset + 27] = 't';
	file::save(forged_path, duplicate_binding)!!;
	MitosAotResult duplicate_load =
		delta_net_abstract_machine::execute_mitos_aot(forged_path, mem);
	defer duplicate_load.free();
	assert(duplicate_load.status == mitos_mir::MirStatus.ERROR);
	assert(duplicate_load.diagnostic
		== "AOT v4 contains an invalid typed DeltaProgram");

	mitos::TypeDescriptor* cyclic_function = null;
	foreach (&descriptor : lowered.program.types.descriptors)
	{
		if (descriptor.kind
			== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
		{
			cyclic_function = descriptor;
			break;
		}
	}
	assert(cyclic_function != null);
	mitos::TypeId original_result = cyclic_function.function_result;
	cyclic_function.function_result = cyclic_function.id;
	MitosAotResult cyclic_write =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	cyclic_function.function_result = original_result;
	defer cyclic_write.free();
	assert(cyclic_write.status == mitos_mir::MirStatus.ERROR);
	assert(cyclic_write.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	usz target_edge = lowered.program.image.edges.len;
	ulong duplicate_input = 0;
	foreach (edge_index, &edge : lowered.program.image.edges)
	{
		foreach (other_index, &other : lowered.program.image.edges)
		{
			if (edge_index != other_index && edge.consumer == other.consumer
				&& edge.input != other.input)
			{
				target_edge = (usz)edge_index;
				duplicate_input = (ulong)other.input;
				break;
			}
		}
		if (target_edge != lowered.program.image.edges.len) break;
	}
	assert(target_edge != lowered.program.image.edges.len);
	mitos::DeltaEdge[] original_edges = lowered.program.image.edges;
	assert(original_edges.len >= 2);
	lowered.program.image.edges = original_edges[..(original_edges.len - 2)];
	MitosAotResult incomplete_write =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	lowered.program.image.edges = original_edges;
	defer incomplete_write.free();
	assert(incomplete_write.status == mitos_mir::MirStatus.ERROR);
	assert(incomplete_write.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	usz graph_bytes = 4 + original_edges.len * 16;
	assert(emitted.len >= graph_bytes);
	usz graph_offset = 0;
	usz graph_matches = 0;
	for (usz offset = 0; offset <= emitted.len - graph_bytes; offset++)
	{
		if (!test_u32_le_equals(
			emitted, offset, (uint)original_edges.len
		)) continue;
		bool same = true;
		foreach (edge_index, &edge : original_edges)
		{
			usz edge_offset = offset + 4 + (usz)edge_index * 16;
			if (!test_u32_le_equals(
					emitted, edge_offset, (uint)edge.producer
				)
				|| !test_u32_le_equals(
					emitted, edge_offset + 4, (uint)edge.consumer
				)
				|| test_u64_le(emitted, edge_offset + 8) != (ulong)edge.input)
			{
				same = false;
				break;
			}
		}
		if (!same) continue;
		graph_offset = offset;
		graph_matches++;
	}
	assert(graph_matches == 1);
	char[] duplicate_edge = alloc::new_array(mem, char, (sz)emitted.len);
	defer alloc::free(mem, duplicate_edge);
	foreach (index, byte : emitted) duplicate_edge[(usz)index] = byte;
	test_write_u64_le(
		duplicate_edge,
		graph_offset + 4 + target_edge * 16 + 8,
		duplicate_input
	);
	file::save(forged_path, duplicate_edge)!!;
	MitosAotResult edge_load =
		delta_net_abstract_machine::execute_mitos_aot(forged_path, mem);
	defer edge_load.free();
	assert(edge_load.status == mitos_mir::MirStatus.ERROR);
	assert(edge_load.diagnostic
		== "AOT v4 contains an invalid typed DeltaProgram");

	char[] permuted_edge = alloc::new_array(mem, char, (sz)emitted.len);
	defer alloc::free(mem, permuted_edge);
	foreach (index, byte : emitted) permuted_edge[(usz)index] = byte;
	for (usz byte_index = 0; byte_index < 16; byte_index++)
	{
		usz first_offset = graph_offset + 4 + byte_index;
		usz second_offset = graph_offset + 20 + byte_index;
		char temporary = permuted_edge[first_offset];
		permuted_edge[first_offset] = permuted_edge[second_offset];
		permuted_edge[second_offset] = temporary;
	}
	file::save(forged_path, permuted_edge)!!;
	MitosAotResult permuted_edge_load =
		delta_net_abstract_machine::execute_mitos_aot(forged_path, mem);
	defer permuted_edge_load.free();
	assert(permuted_edge_load.status == mitos_mir::MirStatus.ERROR);
	assert(permuted_edge_load.diagnostic
		== "AOT v4 contains an invalid typed DeltaProgram");

	mitos::DeltaMatchBranch wildcard = match_node.branches[1];
	usz wildcard_offset = 0;
	usz wildcard_matches = 0;
	for (usz offset = 0; offset <= emitted.len - 20; offset++)
	{
		if (!test_u32_le_equals(emitted, offset, 1)
			|| !test_u32_le_equals(emitted, offset + 4, wildcard.constructor)
			|| !test_u32_le_equals(emitted, offset + 8, 0)
			|| !test_u32_le_equals(emitted, offset + 12, (uint)wildcard.body)
			|| !test_u32_le_equals(emitted, offset + 16, wildcard.span)) continue;
		wildcard_offset = offset;
		wildcard_matches++;
	}
	assert(wildcard_matches == 1);
	char[] forged = alloc::new_array(mem, char, (sz)emitted.len);
	defer alloc::free(mem, forged);
	foreach (index, byte : emitted) forged[(usz)index] = byte;
	test_write_u32_le(forged, wildcard_offset, 0);
	test_write_u32_le(
		forged, wildcard_offset + 4, match_node.branches[0].constructor
	);
	file::save(forged_path, forged)!!;
	MitosAotResult rejected_load = delta_net_abstract_machine::execute_mitos_aot(
		forged_path, mem
	);
	defer rejected_load.free();
	assert(rejected_load.status == mitos_mir::MirStatus.ERROR);
	assert(rejected_load.diagnostic
		== "AOT v4 contains an invalid typed DeltaProgram");
}


fn void aot_root_and_parallel_routing_mutations_fail_closed() @test
{
	char[160] artifact_buffer;
	String artifact_path = unique_aot_test_path(
		artifact_buffer[..], "routing-writer"
	);
	reserve_aot_test_path(artifact_path);
	defer (void)libc::remove(artifact_path.zstr_tcopy());
	String source = `worker() of I64:
  1
end
main():
  parallel:
    left := worker()
    right := 2
    left + right
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(
		&parsed.program, mem
	);
	defer lowered.deinit();
	assert(lowered.ok());
	MitosAotResult canonical = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, artifact_path, mem
	);
	defer canonical.free();
	assert(canonical.status == mitos_mir::MirStatus.NATIVE);

	mitos::DeltaInterface* entry = null;
	foreach (&boundary : lowered.program.image.interfaces)
	{
		if (boundary.kind == mitos::DeltaInterfaceKind.DELTA_INTERFACE_ENTRY)
		{
			entry = boundary;
			break;
		}
	}
	assert(entry != null);
	usz entry_source_order = entry.source_order;
	assert(entry_source_order != 0);
	entry.source_order = 0;
	MitosAotResult misordered_entry =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, artifact_path, mem
		);
	entry.source_order = entry_source_order;
	defer misordered_entry.free();
	assert(misordered_entry.status == mitos_mir::MirStatus.ERROR);
	assert(misordered_entry.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	assert(lowered.program.image.parallel_regions.len == 1);
	mitos::DeltaParallelRegion* region =
		&lowered.program.image.parallel_regions[0];
	usz region_source_order = region.source_order;
	region.source_order = region_source_order + 1;
	MitosAotResult misordered_region =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, artifact_path, mem
		);
	region.source_order = region_source_order;
	defer misordered_region.free();
	assert(misordered_region.status == mitos_mir::MirStatus.ERROR);
	assert(misordered_region.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");

	assert(region.roots.len == 2);
	mitos::DeltaNodeId first_root_id = region.roots[0];
	region.roots[0] = region.roots[1];
	region.roots[1] = first_root_id;
	MitosAotResult permuted_roots =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, artifact_path, mem
		);
	region.roots[1] = region.roots[0];
	region.roots[0] = first_root_id;
	defer permuted_roots.free();
	assert(permuted_roots.status == mitos_mir::MirStatus.ERROR);
	assert(permuted_roots.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	mitos::DeltaNode* first_root = mitos::delta_node(
		&lowered.program, region.roots[0]
	);
	mitos::DeltaNode* second_root = mitos::delta_node(
		&lowered.program, region.roots[1]
	);
	assert(first_root != null && second_root != null);
	usz second_descriptor = second_root.descriptor;
	assert(first_root.descriptor != second_descriptor);
	second_root.descriptor = first_root.descriptor;
	MitosAotResult duplicate_root_route =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, artifact_path, mem
		);
	second_root.descriptor = second_descriptor;
	defer duplicate_root_route.free();
	assert(duplicate_root_route.status == mitos_mir::MirStatus.ERROR);
	assert(duplicate_root_route.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
}


fn void static_match_effectful_closure_preserves_mir_handler() @test
{
	String source = `enum Choice:
  A
  B
end
effect Reader:
  read() of I64
end
main():
  choice := A
  f := match choice:
    A:
      do() of I64 does Reader:
        Reader.read()
      end
    B:
      do() of I64 does Reader:
        Reader.read() + 1
      end
  end
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(
		&parsed.program, mem
	);
	defer lowered.deinit();
	assert(lowered.ok());
	assert(!(lowered.program.feature_manifest.required
		& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES));

	DeltaRuntime runtime;
	runtime.init(2);
	defer runtime.free();
	TypedDeltaExecutionResult generic = runtime.run(&lowered.program);
	defer generic.deinit();
	assert(generic.status == TYPED_DELTA_COMPLETE);
	assert(generic.formatted == "42");

	MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem
	);
	defer native.free();
	assert(native.status == mitos_mir::MirStatus.NATIVE);
	assert(native.result == generic.formatted);
}


fn void nested_symbol_and_effectful_function_type_keys_are_stable() @test
{
	String ordered = `enum Noise:
  N
end
enum Target of T:
  Same
end
effect Other:
  skip() of I64
end
effect TargetEffect of T:
  op() of I64
end
main():
  0
end
`;
	String reordered = `effect TargetEffect of T:
  op() of I64
end
enum Target of T:
  Same
end
effect Other:
  skip() of I64
end
enum Noise:
  N
end
main():
  0
end
`;
	String unparameterized = `enum Target:
  Same
end
effect TargetEffect:
  op() of I64
end
main():
  0
end
`;
	MitosParseResult first = mitos::parse_program(ordered, mem);
	defer first.deinit();
	MitosParseResult second = mitos::parse_program(reordered, mem);
	defer second.deinit();
	MitosParseResult plain = mitos::parse_program(unparameterized, mem);
	defer plain.deinit();
	assert(first.ok() && second.ok() && plain.ok());
	assert(mitos::symbol_key_equal(
		&first.program.enums[1].variants[0].key,
		&second.program.enums[0].variants[0].key
	));
	assert(mitos::symbol_key_equal(
		&first.program.effects[1].operations[0].key,
		&second.program.effects[0].operations[0].key
	));
	assert(!mitos::symbol_key_equal(
		&first.program.enums[1].variants[0].key,
		&plain.program.enums[0].variants[0].key
	));
	assert(!mitos::symbol_key_equal(
		&first.program.effects[1].operations[0].key,
		&plain.program.effects[0].operations[0].key
	));

	String effect_order_one = `effect Noise:
  ignored() of I64
end
effect Reader:
  read() of I64
end
main():
  f := do() of I64 does Reader:
    Reader.read()
  end
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`;
	String effect_order_two = `effect Reader:
  read() of I64
end
effect Noise:
  ignored() of I64
end
main():
  f := do() of I64 does Reader:
    Reader.read()
  end
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`;
	MitosParseResult parsed_one = mitos::parse_program(effect_order_one, mem);
	defer parsed_one.deinit();
	MitosParseResult parsed_two = mitos::parse_program(effect_order_two, mem);
	defer parsed_two.deinit();
	assert(parsed_one.ok() && parsed_two.ok());
	DeltaProgramBuildResult lowered_one = mitos::lower_delta_program(
		&parsed_one.program, mem
	);
	defer lowered_one.deinit();
	DeltaProgramBuildResult lowered_two = mitos::lower_delta_program(
		&parsed_two.program, mem
	);
	defer lowered_two.deinit();
	assert(lowered_one.ok() && lowered_two.ok());
	mitos::TypeDescriptor* function_one = null;
	mitos::TypeDescriptor* function_two = null;
	foreach (&descriptor : lowered_one.program.types.descriptors)
	{
		if (descriptor.kind
			== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
			&& descriptor.function_effects.required.len == 1
			&& descriptor.function_result == mitos::TYPE_ID_I64)
		{
			function_one = descriptor;
			break;
		}
	}
	foreach (&descriptor : lowered_two.program.types.descriptors)
	{
		if (descriptor.kind
			== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
			&& descriptor.function_effects.required.len == 1
			&& descriptor.function_result == mitos::TYPE_ID_I64)
		{
			function_two = descriptor;
			break;
		}
	}
	assert(function_one != null && function_two != null);
	assert(mitos::symbol_key_equal(&function_one.key, &function_two.key));
}


fn void nested_multishot_handler_tracks_distinct_closure_environments() @test
{
	String source = `multi effect Choice:
  choose() of I64
end
effect Reader:
  read() of I64
end
make():
  selected := Choice.choose()
  do() of I64 does Reader:
    Reader.read() + selected
  end
end
main():
  f := handle make():
    Choice.choose(): superpose(resume(0), resume(1))
    return(value of Function): value
  end
  handle f():
    Reader.read(): resume(40)
    return(value of Superposition of I64): value
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(
		&parsed.program, mem
	);
	defer lowered.deinit();
	assert(lowered.ok());
	assert(lowered.program.feature_manifest.required
		& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES);
	mitos::TypeId superposition_i64 = mitos::TYPE_ID_INVALID;
	foreach (&descriptor : lowered.program.types.descriptors)
	{
		if (descriptor.name == "Superposition"
			&& descriptor.arguments.len == 1
			&& descriptor.arguments[0] == mitos::TYPE_ID_I64)
		{
			superposition_i64 = descriptor.id;
			break;
		}
	}
	assert(superposition_i64 != mitos::TYPE_ID_INVALID);
	DeltaRuntime runtime;
	runtime.init(1);
	TypedDeltaExecutionResult execution = runtime.run(&lowered.program);
	assert(execution.status == TYPED_DELTA_COMPLETE);
	assert(execution.type_id == superposition_i64);
	assert(execution.formatted == "superpose(40, 41)");
	execution.deinit();
	assert(runtime.free());
	MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem
	);
	defer native.free();
	assert(native.status == mitos_mir::MirStatus.ERROR);
	assert(native.diagnostic
		== "MIR backend does not support dynamic effectful closures; use generic Delta execution");

	String singleton_source = `multi effect Choice:
  choose() of I64
end
effect Reader:
  read() of I64
end
make():
  selected := Choice.choose()
  do() of I64 does Reader:
    Reader.read() + selected
  end
end
main():
  handle make():
    Choice.choose(): resume(0)
    return(value of Function): value
  end
end
`;
	MitosParseResult singleton = mitos::parse_program(singleton_source, mem);
	defer singleton.deinit();
	assert(singleton.ok());
	DeltaProgramBuildResult singleton_lowered = mitos::lower_delta_program(
		&singleton.program, mem
	);
	defer singleton_lowered.deinit();
	assert(singleton_lowered.ok());
	assert(!(singleton_lowered.program.feature_manifest.required
		& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES));

	String mixed_path_source = `enum Route:
  A
  B
end
multi effect Choice:
  choose() of I64
end
effect Reader:
  read() of I64
end
main():
  handle match superpose(A, B):
    A:
      selected := Choice.choose()
      do() of I64 does Reader:
        Reader.read() + selected
      end
    B:
      do() of I64 does Reader:
        Reader.read() + 10
      end
  end:
    Choice.choose(): resume(0)
    return(value of Superposition of Function): value
  end
end
`;
	MitosParseResult mixed_path = mitos::parse_program(mixed_path_source, mem);
	defer mixed_path.deinit();
	assert(mixed_path.ok());
	DeltaProgramBuildResult mixed_path_lowered = mitos::lower_delta_program(
		&mixed_path.program, mem
	);
	defer mixed_path_lowered.deinit();
	assert(mixed_path_lowered.ok());
	assert(mixed_path_lowered.program.feature_manifest.required
		& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES);
}


fn void generic_multishot_replay_preserves_its_handler_and_runs_host_work_per_branch() @test
{
	String source = `effect Console:
  work(value of I64) of I64
end
multi effect Choice:
  choose() of I64
end
multi effect Inner:
  work(value of I64) of I64
end
choose_work():
  first := Choice.choose()
  second := Choice.choose()
  Inner.work(first * 10 + second)
end
main():
  handle choose_work():
    Choice.choose(): superpose(resume(1), resume(2))
    Inner.work(value): resume(Console.work(value))
    return(value of I64): value
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(
		&parsed.program, mem
	);
	defer lowered.deinit();
	assert(lowered.ok());
	ReplayHostContext host = { };
	DeltaRuntime runtime;
	runtime.init(1);
	assert(runtime.register_host_handler(
		&lowered.program, 0, &record_replay_host_call, &host
	));
	TypedDeltaExecutionResult execution = runtime.run(&lowered.program);
	assert(execution.status == TYPED_DELTA_COMPLETE);
	assert(execution.formatted == "superpose(11, 22)");
	assert(host.calls == 4);
	long[4] expected = { 11, 12, 21, 22 };
	foreach (index, argument : host.arguments)
	{
		assert(argument == expected[index]);
	}
	execution.deinit();
	assert(runtime.unregister_host_handler(&lowered.program, 0));
	assert(runtime.free());
}


fn void recursive_parallel_mir_preserves_call_depth_budget() @test
{
	String source = `loop() of I64:
  parallel:
    value of I64 := loop()
    zero := 0
    value
  end
end
main():
  loop()
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(
		&parsed.program, mem
	);
	defer lowered.deinit();
	assert(lowered.ok());
	for (usz repetition = 0; repetition < 16; repetition++)
	{
		MitosJitResult native = mitos_jit::jit_delta_program(
			&lowered.program, mem
		);
		assert(native.status == mitos_mir::MirStatus.ERROR);
		assert(native.diagnostic == "native call-depth limit exceeded");
		native.free();
	}
}


fn void parallel_snapshots_preserve_closure_and_aggregate_alias_identity() @test
{
	assert_generic_and_jit_result(
		`enum Holder:
  Holder(value)
end
enum Result:
  Result(closure_same, aggregate_same)
end
make(offset of I64):
  do() of I64:
    offset
  end
end
main():
  f := make(42)
  closure_alias := f
  holder := Holder(f)
  aggregate_alias := holder
  parallel:
    closure_same := f = closure_alias
    aggregate_same := holder = aggregate_alias
    Result(closure_same, aggregate_same)
  end
end
`,
		"Result(True, True)"
	);
}


fn void nested_handlers_preserve_outer_resume_scope() @test
{
	String[2] sources = {
		`effect Outer:
  get() of I64
end

effect Inner:
  ping() of I64
end

main():
  handle Outer.get():
    Outer.get():
      handle resume(42):
        Inner.ping(): resume(99)
        return(value of I64): value
      end
    return(value of I64): value
  end
end
`,
		`effect Outer:
  get() of I64
end

effect Inner:
  ping() of I64
end

main():
  handle Outer.get():
    Outer.get():
      handle 1:
        Inner.ping(): resume(99)
        return(value of I64): resume(value + 41)
      end
    return(value of I64): value
  end
end
`,
	};
	foreach (source : sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		DeltaProgramBuildResult lowered = mitos::lower_delta_program(
			&parsed.program, mem
		);
		assert(lowered.ok());
		assert(lowered.program.effects.handlers.len == 2);
		assert(lowered.program.effects.handlers[0].clauses.len == 1);
		assert(lowered.program.effects.handlers[0].clauses[0].resume_count == 1);

		DeltaTranslationResult translated =
			delta_net_abstract_machine::translate_delta_program(
				&lowered.program, lowered.program.entry, mem
			);
		assert(translated.ok());
		assert(delta_net_abstract_machine::validate_net(&translated.net));

		DeltaRuntime runtime;
		runtime.init(1);
		TypedDeltaExecutionResult execution = runtime.run(&lowered.program);
		assert(execution.status == TYPED_DELTA_COMPLETE);
		assert(execution.formatted == "42");
		execution.deinit();
		assert(runtime.free());
		translated.deinit();
		lowered.deinit();
		parsed.deinit();
	}
}


fn void incompatible_standard_host_and_unrepresentable_suspension_fail_closed() @test
{
	String console_source = `effect Console:
  print(value of String) of I64
end
main():
  Console.print("must-not-print")
end
`;
	MitosParseResult console_parsed = mitos::parse_program(console_source, mem);
	assert(console_parsed.ok());
	DeltaProgramBuildResult console_lowered = mitos::lower_delta_program(
		&console_parsed.program, mem
	);
	assert(console_lowered.ok());
	DeltaRuntime console_runtime;
	console_runtime.init(1);
	assert(console_runtime.register_standard_host_handlers(
		&console_lowered.program
	));
	TypedDeltaExecutionResult console_result =
		console_runtime.run(&console_lowered.program);
	assert(console_result.status == TYPED_DELTA_FAILED);
	assert(console_result.diagnostics.len == 1);
	assert(console_result.diagnostics[0].message
		== "external effect has no compatible registered host ABI 2.0 handler");
	console_result.deinit();
	assert(console_runtime.free());
	console_lowered.deinit();
	console_parsed.deinit();

	String suspended_source = `type Box:
  value of I64
end
effect IO:
  wait() of Box
end
main():
  IO.wait()
end
`;
	MitosParseResult suspended_parsed = mitos::parse_program(
		suspended_source, mem
	);
	assert(suspended_parsed.ok());
	DeltaProgramBuildResult suspended_lowered = mitos::lower_delta_program(
		&suspended_parsed.program, mem
	);
	assert(suspended_lowered.ok());
	require_suspension(&suspended_lowered.program);
	SuspendHostContext host = {
		.effect = suspended_lowered.program.effects.operations[0].effect,
		.operation = suspended_lowered.program.effects.operations[0].id,
		.argument_count = 0,
	};
	DeltaRuntime suspended_runtime;
	suspended_runtime.init(1);
	assert(suspended_runtime.register_host_handler(
		&suspended_lowered.program, 0, &suspend_host, &host
	));
	TypedDeltaExecutionResult rejected =
		suspended_runtime.run(&suspended_lowered.program);
	assert(rejected.status == TYPED_DELTA_FAILED);
	assert(rejected.diagnostics.len == 1);
	assert(rejected.diagnostics[0].message
		== "host ABI 2.0 cannot resume the suspended operation result type");
	assert(host.calls == 1);
	assert(suspended_runtime.active_suspension_count() == 0);
	rejected.deinit();
	assert(suspended_runtime.unregister_host_handler(
		&suspended_lowered.program, 0
	));
	assert(suspended_runtime.free());
	suspended_lowered.deinit();
	suspended_parsed.deinit();
}


fn void captured_effectful_parallel_closure_preserves_source_order_in_mir() @test
{
	String captured_source = `effect Reader:
  read() of I64
end

make(offset of I64):
  do() of I64 does Reader:
    Reader.read() + offset
  end
end

main():
  handle parallel:
    f := make(1)
    zero := 0
    f()
  end:
    Reader.read(): resume(41)
    return(value of I64): value
  end
end
`;
	MitosParseResult captured_parsed = mitos::parse_program(
		captured_source, mem
	);
	assert(captured_parsed.ok());
	DeltaProgramBuildResult captured_lowered = mitos::lower_delta_program(
		&captured_parsed.program, mem
	);
	assert(captured_lowered.ok());
	assert(captured_lowered.program.feature_manifest.required
		& mitos::DELTA_FEATURE_PARALLEL);
	assert(!(captured_lowered.program.feature_manifest.required
		& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES));
	DeltaRuntime captured_runtime;
	captured_runtime.init(4);
	TypedDeltaExecutionResult captured_generic =
		captured_runtime.run(&captured_lowered.program);
	assert(captured_generic.status == TYPED_DELTA_COMPLETE);
	assert(captured_generic.formatted == "42");
	MitosJitResult captured_native = mitos_jit::jit_delta_program(
		&captured_lowered.program, mem
	);
	assert(captured_native.status == mitos_mir::MirStatus.NATIVE);
	assert(captured_native.result == "42");
	captured_native.free();
	captured_generic.deinit();
	assert(captured_runtime.free());
	captured_lowered.deinit();
	captured_parsed.deinit();

	String ordered_source = `effect IO:
  ready() of I64
end
emit() of I64:
  IO.ready()
end
main():
  emit()
end
`;
	MitosParseResult ordered_parsed = mitos::parse_program(
		ordered_source, mem
	);
	defer ordered_parsed.deinit();
	assert(ordered_parsed.ok());
	DeltaProgramBuildResult ordered_lowered = mitos::lower_delta_program(
		&ordered_parsed.program, mem
	);
	defer ordered_lowered.deinit();
	assert(ordered_lowered.ok());
	DeltaSourceOrderContext generic_host = { .result = 42 };
	DeltaRuntime generic_runtime;
	generic_runtime.init(1);
	assert(generic_runtime.register_host_handler(
		&ordered_lowered.program, 0, &record_delta_source_order, &generic_host
	));
	TypedDeltaExecutionResult generic =
		generic_runtime.run(&ordered_lowered.program);
	assert(generic.status == TYPED_DELTA_COMPLETE);
	assert(generic.formatted == "42");
	assert(generic_host.calls == 1);
	assert(generic_runtime.unregister_host_handler(
		&ordered_lowered.program, 0
	));
	generic.deinit();
	assert(generic_runtime.free());

	MitosMirLowerResult native_program =
		mitos_jit::lower_delta_program_to_mir(&ordered_lowered.program, mem);
	defer native_program.free();
	assert(native_program.ok());
	MirProgram bridge_program = native_program.program.view();
	assert(bridge_program.effect_operation_count == 1);
	MirSourceOrderContext native_host = {
		.result_type = bridge_program.i64_type,
		.result = 42,
	};
	MirRuntime native_runtime;
	native_runtime.init();
	assert(native_runtime.register_host_helper(
		&bridge_program, 0, &record_mir_source_order, &native_host
	));
	MirExecutionResult native = mitos_mir::execute(
		&native_runtime, &bridge_program, mem
	);
	assert(native.status == mitos_mir::MirStatus.NATIVE);
	assert(native.result == "42");
	assert(native_host.calls == 1);
	assert(native_host.source_order == (ulong)generic_host.source_order);
	assert(native_runtime.unregister_host_helper(&bridge_program, 0));
	native.free();
	assert(native_runtime.free());
}

fn void jit_preserves_nominal_widening_for_outer_dispatch() @test
{
	assert_generic_and_jit_result(
		`abstract Animal
type Dog is Animal
widen(value of Dog) of Animal:
  value
end
classify(value of Animal) of I64:
  0
end
classify(value of Dog) of I64:
  1
end
main():
  classify(widen(Dog()))
end
`,
		"1"
	);
}

fn void recursive_generic_with_captured_closure_is_bounded_and_executes() @test
{
	assert_generic_and_jit_result(
		`enum Nat:
  Zero
  Next(rest of Nat)
end
walk(value of Nat, f of Function) of I64:
  match value:
    Zero: f()
    Next(rest): walk(rest, f)
  end
end
main():
  captured := 42
  f := do() of I64:
    captured
  end
  walk(Next(Next(Next(Next(Next(Next(Next(Next(
    Next(Next(Next(Next(Next(Next(Next(Next(Zero())))))))))))))))), f)
end
`,
		"42"
	);
}

fn void effectful_known_closure_lifts_over_superposition_in_mir() @test
{
	assert_generic_and_jit_result(
		`effect Reader:
  read() of I64
end
main():
  f := do(value of I64) of I64 does Reader:
    Reader.read() + value
  end
  handle f(superpose(1, 2)):
    Reader.read(): resume(40)
    return(value of Superposition of I64): value
  end
end
`,
		"superpose(41, 42)"
	);
}

fn void lambda_and_aggregate_type_assertions_have_backend_parity() @test
{
	String[2] sources = {
		`main():
  f := do() of I64:
    "wrong"
  end
  f()
end
`,
		`main():
  assertType(superpose(1, 2), I64)
end
`,
	};
	foreach (source : sources)
		assert_generic_and_jit_failure_parity(source);
}

fn void mir_integer_remainder_and_ordered_comparisons_match_generic() @test
{
	String[5] sources = {
		`main():
  (-9223372036854775807 - 1) % -1
end
`,
		`main():
  -2 < -1
end
`,
		`main():
  -1 <= -1
end
`,
		`main():
  0 > -1
end
`,
		`main():
  0 >= 0
end
`,
	};
	String[5] expected = { "0", "True", "True", "True", "True" };
	foreach (index, source : sources)
	{
		assert_generic_and_jit_result(source, expected[index]);
	}
	assert_generic_and_jit_failure_status(
		`main():
  "left" < "right"
end
`
	);
}

fn void parametric_nominal_parent_preserves_instance_arguments() @test
{
	String source = `abstract Parent of T
type Child of T is Parent of T:
  value of T
end
classify(value of Parent of I64) of I64:
  1
end
classify(value of Any) of I64:
  0
end
main():
  classify(Child(42))
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	assert(parsed.ok());
	TypeRegistryBuildResult types =
		mitos::build_type_registry(&parsed.program, mem);
	assert(types.ok());
	mitos::TypeId parent = mitos::find_type(&types.registry, "Parent");
	mitos::TypeId child = mitos::find_type(&types.registry, "Child");
	assert(parent != mitos::TYPE_ID_INVALID
		&& child != mitos::TYPE_ID_INVALID);
	mitos::TypeId[1] i64_arguments = { mitos::TYPE_ID_I64 };
	mitos::TypeId[1] bool_arguments = { mitos::TYPE_ID_BOOL };
	mitos::TypeId parent_i64 = mitos::TYPE_ID_INVALID;
	mitos::TypeId parent_bool = mitos::TYPE_ID_INVALID;
	mitos::TypeId child_i64 = mitos::TYPE_ID_INVALID;
	assert(mitos::intern_type(

		&types.registry, parent, i64_arguments[..], &parent_i64
	));
	assert(mitos::intern_type(
		&types.registry, parent, bool_arguments[..], &parent_bool
	));
	assert(mitos::intern_type(
		&types.registry, child, i64_arguments[..], &child_i64
	));
	assert(mitos::type_is_subtype(&types.registry, child_i64, parent_i64));
	assert(!mitos::type_is_subtype(
		&types.registry, child_i64, parent_bool
	));
	types.deinit();
	parsed.deinit();
	assert_generic_and_jit_result(source, "1");
}
fn void aot_rejects_forged_lambda_function_metadata() @test
{
	char[160] path_buffer;
	String path = unique_aot_test_path(path_buffer[..], "lambda-metadata");
	reserve_aot_test_path(path);
	defer (void)libc::remove(path.zstr_tcopy());
	String source = `main():
  f := do(value of I64) of I64:
    value
  end
  f(42)
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());
	MitosAotResult canonical = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, path, mem
	);
	assert(canonical.status == mitos_mir::MirStatus.NATIVE);
	canonical.free();

	mitos::DeltaNode* lambda = null;
	foreach (&node : lowered.program.image.nodes)
	{
		if (node.kind == mitos::DeltaNodeKind.DELTA_LAMBDA)
		{
			lambda = node;
			break;
		}
	}
	assert(lambda != null);
	mitos::TypeId runtime_type = lambda.runtime_type;
	assert(runtime_type != mitos::TYPE_ID_I64);
	lambda.runtime_type = mitos::TYPE_ID_I64;
	MitosAotResult rejected = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, path, mem
	);
	lambda.runtime_type = runtime_type;
	assert(rejected.status == mitos_mir::MirStatus.ERROR);
	assert(rejected.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	rejected.free();
	lowered.deinit();
	parsed.deinit();
}


fn void aot_rejects_binder_hierarchy_and_layout_coherence_mutations() @test
{
	char[160] path_buffer;
	String path = unique_aot_test_path(path_buffer[..], "coherence-writer");
	reserve_aot_test_path(path);
	defer (void)libc::remove(path.zstr_tcopy());
	String source = `abstract Animal
abstract Mammal is Animal
type Dog is Mammal
pair(left of I64, right of I64) of I64:
  left + right
end
main():
  value := 1
  f := do(argument of I64) of I64:
    argument
  end
  parallel:
    left := f(value)
    right := pair(1, 2)
    left + right
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());
	MitosAotResult canonical = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, path, mem
	);
	assert(canonical.status == mitos_mir::MirStatus.NATIVE);
	canonical.free();

	mitos::DeltaMethodRoot* pair_root = null;
	foreach (&root : lowered.program.method_roots)
		if (root.parameters.len == 2) { pair_root = root; break; }
	assert(pair_root != null);
	String second_parameter = pair_root.parameters[1];
	pair_root.parameters[1] = pair_root.parameters[0];
	MitosAotResult duplicate_parameter =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, path, mem
		);
	pair_root.parameters[1] = second_parameter;
	assert(duplicate_parameter.status == mitos_mir::MirStatus.ERROR);
	assert(duplicate_parameter.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	duplicate_parameter.free();
	String first_parameter = pair_root.parameters[0];
	pair_root.parameters[0] = "";
	MitosAotResult empty_parameter =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, path, mem
		);
	pair_root.parameters[0] = first_parameter;
	assert(empty_parameter.status == mitos_mir::MirStatus.ERROR);
	assert(empty_parameter.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	empty_parameter.free();

	mitos::DeltaNodeKind[3] binder_kinds = {
		mitos::DeltaNodeKind.DELTA_LET,
		mitos::DeltaNodeKind.DELTA_LAMBDA,
		mitos::DeltaNodeKind.DELTA_PARALLEL_JOIN,
	};
	foreach (kind : binder_kinds)
	{
		mitos::DeltaNode* binder = null;
		foreach (&node : lowered.program.image.nodes)
			if (node.kind == kind && node.names.len
				&& node.names[0].len)
			{
				binder = node;
				break;
			}
		assert(binder != null);
		String original_name = binder.names[0];
		binder.names[0] = "";
		MitosAotResult empty_binder =
			delta_net_abstract_machine::write_mitos_aot(
				&lowered.program, path, mem
			);
		binder.names[0] = original_name;
		assert(empty_binder.status == mitos_mir::MirStatus.ERROR);
		assert(empty_binder.diagnostic
			== "AOT v4 requires a valid complete DeltaProgram");
		empty_binder.free();
	}

	mitos::TypeDescriptor* animal = null;
	mitos::TypeDescriptor* mammal = null;
	mitos::TypeDescriptor* dog = null;
	foreach (&descriptor : lowered.program.types.descriptors)
	{
		if (descriptor.name == "Animal") animal = descriptor;
		if (descriptor.name == "Mammal") mammal = descriptor;
		if (descriptor.name == "Dog") dog = descriptor;
	}
	assert(animal != null && mammal != null && dog != null);
	mitos::TypeId dog_parent = dog.nominal_parent;
	dog.nominal_parent = mitos::TYPE_ID_I64;
	MitosAotResult concrete_parent =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, path, mem
		);
	dog.nominal_parent = dog_parent;
	assert(concrete_parent.status == mitos_mir::MirStatus.ERROR);
	assert(concrete_parent.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	concrete_parent.free();
	mitos::TypeId animal_parent = animal.nominal_parent;
	animal.nominal_parent = mammal.id;
	MitosAotResult hierarchy_cycle =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, path, mem
		);
	animal.nominal_parent = animal_parent;
	assert(hierarchy_cycle.status == mitos_mir::MirStatus.ERROR);
	assert(hierarchy_cycle.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	hierarchy_cycle.free();

	lowered.deinit();
	parsed.deinit();
}

fn void resolved_effect_patterns_override_redundant_signature_text() @test
{
	char[160] path_buffer;
	String path = unique_aot_test_path(path_buffer[..], "signature-writer");
	reserve_aot_test_path(path);
	defer (void)libc::remove(path.zstr_tcopy());
	String source = `effect Console:
  print(value of String) of Unit
end
main():
  Console.print("x")
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());
	assert(lowered.program.effects.operations.len == 1);
	mitos::DeltaOperationDescriptor* operation =
		&lowered.program.effects.operations[0];
	assert(operation.parameter_patterns.len == 1);
	String parameter_text = operation.parameter_patterns[0];
	operation.parameter_patterns[0] =
		"Bool".copy(lowered.program.allocator);
	MitosAotResult parameter_rejected =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, path, mem
		);
	assert(parameter_rejected.status == mitos_mir::MirStatus.ERROR);
	assert(parameter_rejected.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	parameter_rejected.free();
	alloc::free(
		lowered.program.allocator, operation.parameter_patterns[0]
	);
	operation.parameter_patterns[0] = parameter_text;

	String result_text = operation.result_pattern;
	operation.result_pattern = "Bool".copy(lowered.program.allocator);
	MitosAotResult result_rejected =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, path, mem
		);
	assert(result_rejected.status == mitos_mir::MirStatus.ERROR);
	assert(result_rejected.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	result_rejected.free();

	operation.parameter_patterns[0] =
		"Bool".copy(lowered.program.allocator);
	MitosJitResult native = mitos_jit::jit_delta_program(
		&lowered.program, mem
	);
	assert(native.status == mitos_mir::MirStatus.NATIVE);
	assert(native.result == "()");
	native.free();
	alloc::free(
		lowered.program.allocator, operation.parameter_patterns[0]
	);
	alloc::free(lowered.program.allocator, operation.result_pattern);
	operation.parameter_patterns[0] = parameter_text;
	operation.result_pattern = result_text;
	lowered.deinit();
	parsed.deinit();
}

fn void host_cleanup_ignores_mutated_argument_metadata_and_failure_diagnostics_stay_bounded() @test
{
	String source = `effect IO:
  act(value of String) of I64
end
main():
  IO.act("payload")
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered = mitos::lower_delta_program(
		&parsed.program, mem
	);
	defer lowered.deinit();
	assert(lowered.ok());
	String[2] failures = {
		"external effect host handler returned a malformed failure diagnostic",
		"external effect host handler failure diagnostic exceeds its byte limit",
	};
	for (usz mode = 0; mode < 3; mode++)
	{
		AdversarialHostContext context = { .mode = (uint)mode };
		DeltaRuntime runtime;
		runtime.init(1);
		assert(runtime.register_host_handler(
			&lowered.program, 0, &adversarial_host_call, &context
		));
		TypedDeltaExecutionResult execution = runtime.run(&lowered.program);
		if (!mode)
		{
			assert(execution.status == TYPED_DELTA_COMPLETE);
			assert(execution.formatted == "42");
		}
		else
		{
			assert(execution.status == TYPED_DELTA_FAILED);
			assert(execution.diagnostics.len == 1);
			assert(execution.diagnostics[0].message == failures[mode - 1]);
		}
		assert(context.calls == 1);
		execution.deinit();
		assert(runtime.unregister_host_handler(&lowered.program, 0));
		assert(runtime.free());
	}
}


fn void ready_string_and_type_results_validate_the_full_host_shape() @test
{
	String string_source = `effect IO:
  text() of String
end
main():
  IO.text()
end
`;
	MitosParseResult string_parsed =
		mitos::parse_program(string_source, mem);
	assert(string_parsed.ok());
	DeltaProgramBuildResult string_lowered =
		mitos::lower_delta_program(&string_parsed.program, mem);
	assert(string_lowered.ok());
	String malformed_string = (String)((char*)null)[0..1];
	TypedDeltaHostValue[6] string_results = {
		{
			.kind = HOST_VALUE_STRING,
			.type_id = mitos::TYPE_ID_STRING,
			.string = "",
		},
		{
			.kind = HOST_VALUE_STRING,
			.type_id = mitos::TYPE_ID_STRING,
			.string = malformed_string,
		},
		{
			.kind = HOST_VALUE_STRING,
			.type_id = mitos::TYPE_ID_INVALID,
			.string = "",
		},
		{
			.kind = HOST_VALUE_I64,
			.type_id = mitos::TYPE_ID_STRING,
		},
		{
			.kind = HOST_VALUE_CONSTRUCTOR,
			.type_id = mitos::TYPE_ID_STRING,
		},
		{
			.kind = HOST_VALUE_FUNCTION,
			.type_id = mitos::TYPE_ID_STRING,
		},
	};
	foreach (index, result : string_results)
	{
		HostResultContext context = { .result = result };
		DeltaRuntime runtime;
		runtime.init(1);
		assert(runtime.register_host_handler(
			&string_lowered.program, 0,
			&return_configured_host_value, &context
		));
		TypedDeltaExecutionResult execution =
			runtime.run(&string_lowered.program);
		if (!index)
		{
			assert(execution.status == TYPED_DELTA_COMPLETE);
			assert(execution.formatted == "\"\"");
		}
		else
		{
			assert(execution.status == TYPED_DELTA_FAILED);
			assert(execution.diagnostics.len == 1);
			assert(execution.diagnostics[0].message.len > 0);
		}
		assert(context.calls == 1);
		execution.deinit();
		assert(runtime.unregister_host_handler(
			&string_lowered.program, 0
		));
		assert(runtime.free());
	}
	string_lowered.deinit();
	string_parsed.deinit();

	String type_source = `effect IO:
  reflected(marker of Type of Bool) of Type of I64
end
main():
  IO.reflected(typeOf(1 = 1))
end
`;
	MitosParseResult type_parsed = mitos::parse_program(type_source, mem);
	assert(type_parsed.ok());
	DeltaProgramBuildResult type_lowered =
		mitos::lower_delta_program(&type_parsed.program, mem);
	assert(type_lowered.ok());
	mitos::TypeId type_i64 = mitos::TYPE_ID_INVALID;
	mitos::TypeId type_bool = mitos::TYPE_ID_INVALID;
	foreach (&descriptor : type_lowered.program.types.descriptors)
	{
		if (descriptor.name != "Type" || descriptor.arguments.len != 1)
		{
			continue;
		}
		if (descriptor.arguments[0] == mitos::TYPE_ID_I64)
		{
			type_i64 = descriptor.id;
		}
		if (descriptor.arguments[0] == mitos::TYPE_ID_BOOL)
		{
			type_bool = descriptor.id;
		}
	}
	assert(type_i64 != mitos::TYPE_ID_INVALID);
	assert(type_bool != mitos::TYPE_ID_INVALID);
	TypedDeltaHostValue[6] type_results = {
		{
			.kind = HOST_VALUE_TYPE,
			.type_id = type_i64,
			.represented_type = mitos::TYPE_ID_I64,
		},
		{
			.kind = HOST_VALUE_TYPE,
			.type_id = type_i64,
			.represented_type = mitos::TYPE_ID_INVALID,
		},
		{
			.kind = HOST_VALUE_TYPE,
			.type_id = type_i64,
			.represented_type = (mitos::TypeId)0x7fff,
		},
		{
			.kind = HOST_VALUE_TYPE,
			.type_id = mitos::TYPE_ID_INVALID,
			.represented_type = mitos::TYPE_ID_I64,
		},
		{
			.kind = HOST_VALUE_TYPE,
			.type_id = mitos::TYPE_ID_I64,
			.represented_type = mitos::TYPE_ID_I64,
		},
		{
			.kind = HOST_VALUE_TYPE,
			.type_id = type_bool,
			.represented_type = mitos::TYPE_ID_I64,
		},
	};
	foreach (index, result : type_results)
	{
		HostResultContext context = { .result = result };
		DeltaRuntime runtime;
		runtime.init(1);
		assert(runtime.register_host_handler(
			&type_lowered.program, 0,
			&return_configured_host_value, &context
		));
		TypedDeltaExecutionResult execution =
			runtime.run(&type_lowered.program);
		if (!index)
		{
			assert(execution.status == TYPED_DELTA_COMPLETE);
			assert(execution.formatted == "Type of I64");
		}
		else
		{
			assert(execution.status == TYPED_DELTA_FAILED);
			assert(execution.diagnostics.len == 1);
			assert(execution.diagnostics[0].message.len > 0);
		}
		assert(context.calls == 1);
		execution.deinit();
		assert(runtime.unregister_host_handler(
			&type_lowered.program, 0
		));
		assert(runtime.free());
	}
	type_lowered.deinit();
	type_parsed.deinit();
}

fn void mir_rejects_backward_control_flow() @test
{
	String source = `enum Choice:
  A
  B
  C
end
main():
  match B:
    A: 1
    B: 2
    C: 3
  end
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());
	MitosMirLowerResult native_program =
		mitos_jit::lower_delta_program_to_mir(&lowered.program, mem);
	assert(native_program.ok());
	MirProgram program = native_program.program.view();
	MirRuntime runtime;
	runtime.init();
	MirExecutionResult forward =
		mitos_mir::execute(&runtime, &program, mem);
	assert(forward.status == mitos_mir::MirStatus.NATIVE);
	assert(forward.result == "2");
	forward.free();

	bool checked_jump = false;
	bool checked_branch = false;
	for (uint function_index = 0;
		function_index < program.function_count;
		function_index++)
	{
		MirFunction* function = &program.functions[function_index];
		uint prior_label = 0;
		bool has_prior_label = false;
		for (uint local_index = 0;
			local_index < function.instruction_count;
			local_index++)
		{
			MirInstruction* instruction =
				&program.instructions[
					function.instruction_start + local_index
				];
			if (instruction.opcode == mitos_mir::MirOpcode.LABEL)
			{
				prior_label = instruction.a;
				has_prior_label = true;
				continue;
			}
			if (has_prior_label && !checked_jump
				&& instruction.opcode == mitos_mir::MirOpcode.JUMP)
			{
				uint target = instruction.a;
				instruction.a = prior_label;
				MirExecutionResult rejected =
					mitos_mir::execute(&runtime, &program, mem);
				instruction.a = target;
				assert(rejected.status == mitos_mir::MirStatus.ERROR);
				rejected.free();
				checked_jump = true;
			}
			if (has_prior_label && !checked_branch
				&& instruction.opcode
					== mitos_mir::MirOpcode.BRANCH_FALSE)
			{
				uint target = instruction.b;
				instruction.b = prior_label;
				MirExecutionResult rejected =
					mitos_mir::execute(&runtime, &program, mem);
				instruction.b = target;
				assert(rejected.status == mitos_mir::MirStatus.ERROR);
				rejected.free();
				checked_branch = true;
			}
		}
	}
	assert(checked_jump && checked_branch);
	assert(runtime.free());
	native_program.free();
	lowered.deinit();
	parsed.deinit();
}

fn void parametric_nominal_parents_require_identity_forwarding() @test
{
	String[3] invalid_sources = {
		`abstract Wrapper of T
abstract Parent of T
type Child of T is Parent of Wrapper of T:
  value of T
end
main():
  1
end
`,
		`abstract Parent of T
type Child of T is Parent:
  value of T
end
main():
  1
end
`,
		`abstract Parent of (Left, Right)
type Child of (Left, Right) is Parent of (Right, Left):
  left of Left
  right of Right
end
main():
  1
end
`,
	};
	String[3] diagnostics = {
		"parametric nominal supertype arguments must forward child parameters in positional order",
		"parametric nominal supertype requires its declared 'of' arguments",
		"parametric nominal supertype arguments must forward child parameters in positional order",
	};
	foreach (index, source : invalid_sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		TypeRegistryBuildResult rejected =
			mitos::build_type_registry(&parsed.program, mem);
		assert(!rejected.ok());
		assert(rejected.diagnostics.len == 1);
		assert(rejected.diagnostics[0].message == diagnostics[index]);
		rejected.deinit();
		parsed.deinit();
	}

	MitosParseResult identity = mitos::parse_program(
		`abstract Parent of (Left, Right)
type Child of (Left, Right) is Parent of (Left, Right):
  left of Left
  right of Right
end
main():
  Child(1, True)
end
`,
		mem
	);
	assert(identity.ok());
	TypeRegistryBuildResult accepted =
		mitos::build_type_registry(&identity.program, mem);
	assert(accepted.ok());
	mitos::TypeId parent = mitos::find_type(&accepted.registry, "Parent");
	mitos::TypeId child = mitos::find_type(&accepted.registry, "Child");
	assert(parent != mitos::TYPE_ID_INVALID
		&& child != mitos::TYPE_ID_INVALID);
	mitos::TypeDescriptor* child_descriptor =
		mitos::type_descriptor(&accepted.registry, child);
	assert(child_descriptor != null);
	assert(child_descriptor.nominal_parent == parent);
	accepted.deinit();
	identity.deinit();
}


fn void declaration_binders_and_constructor_namespaces_are_unique() @test
{
	String[2] sources = {
		`effect State of (T, T):
  get() of T
end
main():
  1
end
`,
		`enum Token:
  Collision
end
type Collision
main():
  1
end
`,
	};
	String[2] diagnostics = {
		"duplicate effect type parameter",
		"concrete type constructor name collides with an enum variant",
	};
	foreach (index, source : sources)
	{
		MitosParseResult rejected = mitos::parse_program(source, mem);
		assert(!rejected.ok());
		assert(rejected.diagnostics.len == 1);
		assert(rejected.diagnostics[0].message == diagnostics[index]);
		rejected.deinit();
	}
}


fn void application_overloads_and_generic_type_values_match_jit() @test
{
	assert_generic_and_jit_result(
		`abstract Parent of T
type Child of T is Parent of T:
  value of T
end
classify(value of Parent of I64) of I64:
  1
end
classify(value of Child of T) of I64:
  2
end
main():
  classify(Child(42))
end
`,
		"2"
	);
	assert_generic_and_jit_result(
		`reflect(value of T) of Type of T:
  T
end
main():
  reflect(42)
end
`,
		"Type of I64"
	);
}


fn void mutually_exclusive_one_shot_match_arms_may_each_resume() @test
{
	assert_generic_and_jit_result(
		`enum Choice:
  A
  B
end
effect Reader:
  read(choice of Choice) of I64
end
main():
  handle Reader.read(A):
    Reader.read(choice):
      match choice:
        A: resume(41)
        B: resume(42)
      end
    return(value of I64): value
  end
end
`,
		"41"
	);
}


fn void mir_cfg_constructor_type_and_parallel_site_metadata_fail_closed() @test
{
	String match_source = `enum Choice:
  A
  B
end
main():
  match B:
    A: 1
    B: 2
  end
end
`;
	MitosParseResult match_parsed =
		mitos::parse_program(match_source, mem);
	assert(match_parsed.ok());
	DeltaProgramBuildResult match_lowered =
		mitos::lower_delta_program(&match_parsed.program, mem);
	assert(match_lowered.ok());
	MitosMirLowerResult match_native =
		mitos_jit::lower_delta_program_to_mir(&match_lowered.program, mem);
	assert(match_native.ok());
	MirProgram match_program = match_native.program.view();
	MirFunction* main_function =
		&match_program.functions[match_program.main_function];
	MirInstruction* branch = null;
	uint branch_local = 0;
	for (uint local = 0; local < main_function.instruction_count; local++)
	{
		MirInstruction* instruction =
			&match_program.instructions[main_function.instruction_start + local];
		if (instruction.opcode != mitos_mir::MirOpcode.BRANCH_FALSE)
		{
			continue;
		}
		branch = instruction;
		branch_local = local;
		break;
	}
	assert(branch != null);
	uint target_local = main_function.instruction_count;
	for (uint local = branch_local + 1;
		local < main_function.instruction_count;
		local++)
	{
		MirInstruction* instruction =
			&match_program.instructions[main_function.instruction_start + local];
		if (instruction.opcode == mitos_mir::MirOpcode.LABEL
			&& instruction.a == branch.b)
		{
			target_local = local;
			break;
		}
	}
	assert(target_local < main_function.instruction_count);
	MirInstruction* bypassed_definition = null;
	for (uint local = branch_local + 1; local < target_local; local++)
	{
		MirInstruction* instruction =
			&match_program.instructions[main_function.instruction_start + local];
		if (instruction.opcode == mitos_mir::MirOpcode.CONST)
		{
			bypassed_definition = instruction;
			break;
		}
	}
	MirInstruction* forged_use = null;
	for (uint local = target_local + 1;
		local < main_function.instruction_count;
		local++)
	{
		MirInstruction* instruction =
			&match_program.instructions[main_function.instruction_start + local];
		if (instruction.opcode == mitos_mir::MirOpcode.RETURN)
		{
			forged_use = instruction;
			break;
		}
	}
	assert(bypassed_definition != null && forged_use != null);
	uint original_return = forged_use.a;
	assert(original_return != bypassed_definition.destination);
	forged_use.a = bypassed_definition.destination;
	MirRuntime match_runtime;
	match_runtime.init();
	MirExecutionResult bypassed =
		mitos_mir::execute(&match_runtime, &match_program, mem);
	forged_use.a = original_return;
	assert(bypassed.status == mitos_mir::MirStatus.ERROR);
	assert(bypassed.diagnostic.len > 0);
	bypassed.free();
	MirInstruction* constructor = null;
	for (uint index = 0; index < match_program.instruction_count; index++)
	{
		MirInstruction* instruction = &match_program.instructions[index];
		if (instruction.opcode == mitos_mir::MirOpcode.MAKE_CONSTRUCTOR)
		{
			constructor = instruction;
			break;
		}
	}
	assert(constructor != null);
	uint runtime_type = constructor.b;
	assert(runtime_type != (uint)mitos::TYPE_ID_I64);
	constructor.b = (uint)mitos::TYPE_ID_I64;
	MirExecutionResult wrong_constructor_type =
		mitos_mir::execute(&match_runtime, &match_program, mem);
	constructor.b = runtime_type;
	assert(wrong_constructor_type.status == mitos_mir::MirStatus.ERROR);
	assert(wrong_constructor_type.diagnostic.len > 0);
	wrong_constructor_type.free();
	assert(match_runtime.free());
	match_native.free();
	match_lowered.deinit();
	match_parsed.deinit();

	String parallel_source = `effect Reader:
  read() of I64
end
make(offset of I64):
  do() of I64 does Reader:
    Reader.read() + offset
  end
end
main():
  handle parallel:
    f := make(1)
    zero := 0
    f()
  end:
    Reader.read(): resume(41)
    return(value of I64): value
  end
end
`;
	MitosParseResult parallel_parsed =
		mitos::parse_program(parallel_source, mem);
	assert(parallel_parsed.ok());
	DeltaProgramBuildResult parallel_lowered =
		mitos::lower_delta_program(&parallel_parsed.program, mem);
	assert(parallel_lowered.ok());
	MitosMirLowerResult parallel_native =
		mitos_jit::lower_delta_program_to_mir(&parallel_lowered.program, mem);
	assert(parallel_native.ok());
	MirProgram parallel_program = parallel_native.program.view();
	MirInstruction* parallel_call = null;
	usz call_count = 0;
	for (uint index = 0; index < parallel_program.instruction_count; index++)
	{
		MirInstruction* instruction = &parallel_program.instructions[index];
		if (instruction.opcode != mitos_mir::MirOpcode.PARALLEL_CALL)
		{
			continue;
		}
		assert(instruction.immediate == (long)index);
		if (!parallel_call) parallel_call = instruction;
		call_count++;
	}
	assert(call_count >= 1);
	long canonical_site = parallel_call.immediate;
	parallel_call.immediate = (long)parallel_program.instruction_count;
	MirRuntime parallel_runtime;
	parallel_runtime.init();
	MirExecutionResult noncanonical =
		mitos_mir::execute(&parallel_runtime, &parallel_program, mem);
	parallel_call.immediate = canonical_site;
	assert(noncanonical.status == mitos_mir::MirStatus.ERROR);
	assert(noncanonical.diagnostic
		== "function 0 parallel thunk site order is noncanonical");
	noncanonical.free();
	assert(parallel_runtime.free());
	parallel_native.free();
	parallel_lowered.deinit();
	parallel_parsed.deinit();
}


fn void aot_identifiers_and_canonical_method_signatures_fail_closed() @test
{
	char[160] artifact_buffer;
	char[160] forged_buffer;
	String artifact_path =
		unique_aot_test_path(artifact_buffer[..], "identifier-valid");
	String forged_path =
		unique_aot_test_path(forged_buffer[..], "identifier-forged");
	reserve_aot_test_path(artifact_path);
	reserve_aot_test_path(forged_path);
	defer (void)libc::remove(artifact_path.zstr_tcopy());
	defer (void)libc::remove(forged_path.zstr_tcopy());
	String unique_parameter = "Payload";
	String source = `type Payload:
  hostileFieldName of I64
end
identity(value of T) of T:
  value
end
main():
  identity(Payload(42))
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());
	MitosAotResult written = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, artifact_path, mem
	);
	assert(written.status == mitos_mir::MirStatus.NATIVE);
	written.free();
	MitosAotResult canonical =
		delta_net_abstract_machine::execute_mitos_aot(artifact_path, mem);
	assert(canonical.status == mitos_mir::MirStatus.NATIVE);
	assert(canonical.result == "Payload(42)");
	canonical.free();
	char[] emitted = file::load(mem, artifact_path)!!;
	assert(emitted.len >= unique_parameter.len + 4);
	char[] forged = alloc::new_array(mem, char, (sz)emitted.len);

	usz identifier_offset = emitted.len;
	for (usz offset = 0;
		offset <= emitted.len - unique_parameter.len - 4;
		offset++)
	{
		if (!test_u32_le_equals(
				emitted, offset, (uint)unique_parameter.len
			)
			|| (String)emitted[
				(offset + 4)..(offset + 3 + unique_parameter.len)
			] != unique_parameter) continue;
		foreach (index, byte : emitted) forged[(usz)index] = byte;
		forged[offset + 4] = '\n';
		file::save(forged_path, forged)!!;
		MitosAotResult control =
			delta_net_abstract_machine::execute_mitos_aot(forged_path, mem);
		bool rejected_identifier =
			control.status == mitos_mir::MirStatus.ERROR
			&& control.diagnostic
				== "AOT v4 name is not a source identifier";
		control.free();
		if (!rejected_identifier) continue;
		identifier_offset = offset + 4;
		break;
	}
	assert(identifier_offset < emitted.len);
	foreach (index, byte : emitted) forged[(usz)index] = byte;
	forged[identifier_offset] = (char)0x80;
	file::save(forged_path, forged)!!;
	MitosAotResult non_ascii =
		delta_net_abstract_machine::execute_mitos_aot(forged_path, mem);
	assert(non_ascii.status == mitos_mir::MirStatus.ERROR);
	assert(non_ascii.diagnostic
		== "AOT v4 name is not a source identifier");
	non_ascii.free();

	mitos::DeltaMethodRoot* identity = null;
	foreach (&root : lowered.program.method_roots)
	{
		if (root.key.name == "identity")
		{
			identity = root;
			break;
		}
	}
	assert(identity != null);
	String canonical_signature = identity.key.canonical_signature;
	identity.key.canonical_signature = "forged";
	MitosAotResult forged_signature =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, forged_path, mem
		);
	identity.key.canonical_signature = canonical_signature;
	assert(forged_signature.status == mitos_mir::MirStatus.ERROR);
	assert(forged_signature.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	forged_signature.free();

	alloc::free(mem, forged);
	alloc::free(mem, emitted);
	lowered.deinit();
	parsed.deinit();
}


fn void assert_test_spans_equal(
	mitos::MitosSpan left,
	mitos::MitosSpan right
)
{
	assert(left.start.offset == right.start.offset);
	assert(left.start.row == right.start.row);
	assert(left.start.column == right.start.column);
	assert(left.end.offset == right.end.offset);
	assert(left.end.row == right.end.row);
	assert(left.end.column == right.end.column);
}


fn void jit_and_aot_failures_preserve_nontrivial_source_spans() @test
{
	char[160] artifact_buffer;
	String artifact_path =
		unique_aot_test_path(artifact_buffer[..], "failure-span");
	reserve_aot_test_path(artifact_path);
	defer (void)libc::remove(artifact_path.zstr_tcopy());
	String source = `main():
  ignored := 0
  assertType("wrong", I64)
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());

	DeltaRuntime runtime;
	runtime.init(1);
	TypedDeltaExecutionResult generic = runtime.run(&lowered.program);
	assert(generic.status == TYPED_DELTA_FAILED);
	assert(generic.diagnostics.len == 1);
	mitos::MitosSpan expected = generic.diagnostics[0].span;
	assert(expected.start.offset != expected.start.row);
	assert(expected.end.offset != expected.end.row);

	MitosJitResult native =
		mitos_jit::jit_delta_program(&lowered.program, mem);
	assert(native.status == mitos_mir::MirStatus.ERROR);
	assert(native.diagnostic == generic.diagnostics[0].message);
	assert_test_spans_equal(native.diagnostic_span, expected);

	MitosAotResult written = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, artifact_path, mem
	);
	assert(written.status == mitos_mir::MirStatus.NATIVE);
	written.free();
	MitosAotResult persisted =
		delta_net_abstract_machine::execute_mitos_aot(artifact_path, mem);
	assert(persisted.status == mitos_mir::MirStatus.ERROR);
	assert(persisted.diagnostic == generic.diagnostics[0].message);
	assert_test_spans_equal(persisted.diagnostic_span, expected);

	persisted.free();
	native.free();
	generic.deinit();
	assert(runtime.free());
	lowered.deinit();
	parsed.deinit();
}


fn void repeated_builtin_registry_and_lowering_preserve_declaration_identity() @test
{
	MitosParseResult parsed = mitos::parse_program(
		"type I64\nmain():\n  1\nend\n", mem
	);
	defer parsed.deinit();
	assert(parsed.ok());
	assert(parsed.program.types.len == 1);
	mitos::SymbolKey original = mitos::clone_symbol_key(
		&parsed.program.types[0].key, mem
	);
	defer original.deinit(mem);

	for (usz iteration = 0; iteration < 2; iteration++)
	{
		TypeRegistryBuildResult types =
			mitos::build_type_registry(&parsed.program, mem);
		assert(types.ok());
		assert(mitos::find_type(&types.registry, "I64")
			== mitos::TYPE_ID_I64);
		assert(mitos::symbol_key_equal(
			&parsed.program.types[0].key, &original
		));
		types.deinit();

		DeltaProgramBuildResult lowered =
			mitos::lower_delta_program(&parsed.program, mem);
		assert(lowered.ok());
		assert(mitos::symbol_key_equal(
			&parsed.program.types[0].key, &original
		));
		lowered.deinit();
	}
}


fn void lexical_factories_and_patterns_preserve_closure_provenance() @test
{
	String[4] sources = {
		`enum Token:
  Box(value of I64)
end
main():
  Box := do(value of I64) of I64:
    value + 1
  end
  typeOf := do(value of I64) of I64:
    value + 2
  end
  Box(19) + typeOf(20)
end
`,
		`effect Reader:
  read() of I64
end
main():
  make := do(offset of I64):
    do() of I64 does Reader:
      Reader.read() + offset
    end
  end
  f := make(1)
  handle f():
    Reader.read(): resume(41)
    return(value of I64): value
  end
end
`,
		`enum Box:
  Box(value)
end
factory(value of T):
  Box(do() of T:
    value
  end)
end
main():
  match factory(42):
    Box(f): f()
  end
end
`,
		`enum Token:
  Box(value)
  Other(value)
end
effect Reader:
  read() of I64
end
main():
  Box := do(f of Function) of Token:
    Other(f)
  end
  token := Box(do() of I64 does Reader:
    Reader.read()
  end)
  match token:
    Other(f):
      handle f():
        Reader.read(): resume(42)
        return(value of I64): value
      end
    Box(f): 0
  end
end
`,
	};
	foreach (source : sources) assert_generic_and_jit_result(source, "42");
}


fn void unreachable_effectful_callsite_does_not_pollute_pure_higher_order_call() @test
{
	assert_generic_and_jit_result(
		`effect Reader:
  read() of I64
end
apply(f of Function) of I64:
  f()
end
pure() of I64:
  apply(do() of I64:
    42
  end)
end
impure() of I64:
  apply(do() of I64 does Reader:
    Reader.read()
  end)
end
main():
  pure()
end
`,
		"42"
	);
}


fn void closure_producers_reach_handler_completeness() @test
{
	String[4] sources = {
		`effect Reader:
  read() of I64
end
invoke(f of Function) of I64:
  handle f():
    return(value of I64): value
  end
end
main():
  f := do() of I64 does Reader:
    Reader.read()
  end
  invoke(f)
end
`,
		`effect Reader:
  read() of I64
end
make():
  do() of I64 does Reader:
    Reader.read()
  end
end
invoke(f of Function) of I64:
  handle f():
    return(value of I64): value
  end
end
main():
  invoke(make())
end
`,
		`effect Reader:
  read() of I64
end
invoke(f of Function) of I64:
  handle f():
    return(value of I64): value
  end
end
main():
  first := do() of I64 does Reader:
    Reader.read()
  end
  second := do() of I64 does Reader:
    Reader.read() + 1
  end
  invoke(superpose(first, second))
end
`,
		`effect Reader:
  read() of I64
end
make():
  parallel:
    f := do() of I64:
      leaf()
    end
    zero := 0
    f
  end
end
invoke(f of Function) of I64:
  handle f():
    return(value of I64): value
  end
end
main():
  invoke(make())
end
leaf() of I64:
  Reader.read()
end
`,
	};
	foreach (source : sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		DeltaProgramBuildResult rejected =
			mitos::lower_delta_program(&parsed.program, mem);
		assert(!rejected.ok());
		bool missing = false;
		foreach (&diagnostic : rejected.diagnostics)
		{
			if (diagnostic.message == "handler is missing an operation clause")
			{
				missing = true;
			}
		}
		assert(missing);
		rejected.deinit();
		parsed.deinit();
	}
}


fn void handler_parameter_annotations_are_validated() @test
{
	String[2] sources = {
		`effect Reader:
  read(value of I64) of I64
end
main():
  handle Reader.read(1):
    Reader.read(value of String): resume(42)
    return(value of I64): value
  end
end
`,
		`effect Reader:
  read(value of I64) of I64
end
main():
  handle Reader.read(1):
    Reader.read(value of MissingType): resume(42)
    return(value of I64): value
  end
end
`,
	};
	String[2] expected = {
		"type assertion failed: expected String, received I64",
		"unknown nominal type",
	};
	foreach (index, source : sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		DeltaProgramBuildResult rejected =
			mitos::lower_delta_program(&parsed.program, mem);
		assert(!rejected.ok());
		bool found = false;
		foreach (&diagnostic : rejected.diagnostics)
		{
			if (diagnostic.message == expected[index]) found = true;
		}
		assert(found);
		rejected.deinit();
		parsed.deinit();
	}
}


fn void mir_matches_concrete_parameterized_effect_instances() @test
{
	assert_generic_and_jit_result(
		`effect Echo of T:
  echo(value of T) of T
end
main() does Echo of I64:
  handle Echo.echo(1):
    Echo.echo(value of I64): resume(value + 41)
    return(value of I64): value
  end
end
`,
		"42"
	);
}


fn void aot_container_nested_decode_and_typed_metadata_fail_closed() @test
{
	char[160] artifact_buffer;
	char[160] writer_buffer;
	char[160] forged_buffer;
	String artifact_path = unique_aot_test_path(
		artifact_buffer[..], "typed-mutations-valid"
	);
	String writer_path = unique_aot_test_path(
		writer_buffer[..], "typed-mutations-writer"
	);
	String forged_path = unique_aot_test_path(
		forged_buffer[..], "typed-mutations-forged"
	);
	reserve_aot_test_path(artifact_path);
	reserve_aot_test_path(writer_path);
	reserve_aot_test_path(forged_path);
	defer (void)libc::remove(artifact_path.zstr_tcopy());
	defer (void)libc::remove(writer_path.zstr_tcopy());
	defer (void)libc::remove(forged_path.zstr_tcopy());

	String source = `type InnerDecode of T:
  value of T
end
type OuterDecode of T:
  value of T
end
effect Reader:
  read() of I64
end
ask() of I64:
  Reader.read()
end
combine(value of OuterDecode of InnerDecode of I64, spare of I64) of I64:
  spare + 1
end
main():
  ignored := handle ask():
    Reader.read(): resume(0)
    return(value of I64): value
  end
  combine(OuterDecode(InnerDecode(1)), 41)
end
`;
	MitosParseResult parsed = mitos::parse_program(source, mem);
	defer parsed.deinit();
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	defer lowered.deinit();
	assert(lowered.ok());
	MitosAotResult written = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, artifact_path, mem
	);
	assert(written.status == mitos_mir::MirStatus.NATIVE);
	written.free();
	MitosAotResult valid = delta_net_abstract_machine::execute_mitos_aot(
		artifact_path, mem
	);
	assert(valid.status == mitos_mir::MirStatus.NATIVE);
	assert(valid.result == "42");
	valid.free();

	char[] emitted = file::load(mem, artifact_path)!!;
	defer alloc::free(mem, emitted);
	char[] forged = alloc::new_array(mem, char, (sz)emitted.len);
	defer alloc::free(mem, forged);
	foreach (index, byte : emitted) forged[(usz)index] = byte;
	test_write_u32_le(forged, 12, 1);
	file::save(forged_path, forged)!!;
	MitosAotResult future_minor =
		delta_net_abstract_machine::execute_mitos_aot(forged_path, mem);
	assert(future_minor.status == mitos_mir::MirStatus.ERROR);
	assert(future_minor.diagnostic
		== "unsupported AOT artifact minor version; expected AOT v4.0");
	future_minor.free();

	usz types_record = 0;
	usz types_payload = 0;
	usz types_length = 0;
	usz record_offset = 28;
	while (record_offset <= emitted.len && emitted.len - record_offset >= 16)
	{
		ulong payload_u64 = test_u64_le(emitted, record_offset + 8);
		assert(payload_u64 <= (ulong)usz::max);
		usz payload_length = (usz)payload_u64;
		assert(payload_length <= emitted.len - record_offset - 16);
		if (test_u32_le_equals(
			emitted, record_offset, (uint)mitos::DELTA_RECORD_TYPES
		))
		{
			types_record = record_offset;
			types_payload = record_offset + 16;
			types_length = payload_length;
			break;
		}
		record_offset += 16 + payload_length;
	}
	assert(types_record != 0 && types_payload != 0 && types_length > 1);
	usz removed_byte = types_payload + types_length - 1;
	assert(removed_byte < emitted.len);
	char[] partial_bytes = alloc::new_array(
		mem, char, (sz)(emitted.len - 1)
	);
	defer alloc::free(mem, partial_bytes);
	for (usz index = 0; index < removed_byte; index++)
	{
		partial_bytes[index] = emitted[index];
	}
	for (usz index = removed_byte; index < partial_bytes.len; index++)
	{
		partial_bytes[index] = emitted[index + 1];
	}
	test_write_u64_le(partial_bytes, 20, (ulong)partial_bytes.len);
	test_write_u64_le(
		partial_bytes, types_record + 8, (ulong)(types_length - 1)
	);
	file::save(forged_path, partial_bytes)!!;
	TrackingAllocator tracker;
	tracker.init(mem);
	MitosAotResult partial =
		delta_net_abstract_machine::execute_mitos_aot(forged_path, &tracker);
	assert(partial.status == mitos_mir::MirStatus.ERROR);
	partial.free();
	assert(tracker.allocation_count() == 0);
	assert(!tracker.has_leaks());
	tracker.free();

	assert(lowered.program.primitives.len > 0);
	mitos::DeltaPrimitiveDescriptor* primitive =
		&lowered.program.primitives[0];
	assert(primitive.name == "add");
	assert(primitive.parameters.len == 2);
	mitos::TypeId original_parameter = primitive.parameters[0];
	primitive.parameters[0] = mitos::TYPE_ID_BOOL;
	MitosAotResult primitive_type =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	primitive.parameters[0] = original_parameter;
	assert(primitive_type.status == mitos_mir::MirStatus.ERROR);
	assert(primitive_type.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	primitive_type.free();

	mitos::DeltaNode* primitive_node = null;
	foreach (&node : lowered.program.image.nodes)
	{
		if (node.kind == mitos::DeltaNodeKind.DELTA_PRIMITIVE)
		{
			primitive_node = node;
			break;
		}
	}
	assert(primitive_node != null);
	mitos::TypeId original_static_type = primitive_node.static_type;
	assert(original_static_type != mitos::TYPE_ID_BOOL);
	primitive_node.static_type = mitos::TYPE_ID_BOOL;
	MitosAotResult primitive_node_type =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	primitive_node.static_type = original_static_type;
	assert(primitive_node_type.status == mitos_mir::MirStatus.ERROR);
	assert(primitive_node_type.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	primitive_node_type.free();

	mitos::DeltaMethodRoot* effectful_root = null;
	foreach (&root : lowered.program.method_roots)
	{
		if (root.effect_row.required.len)
		{
			effectful_root = root;
			break;
		}
	}
	assert(effectful_root != null);
	assert(effectful_root.function_index < lowered.program.effects.rows.len);
	mitos::DeltaEffectRowDescriptor* effect_row =
		&lowered.program.effects.rows[effectful_root.function_index];
	assert(!effect_row.has_assertion && effect_row.inferred.required.len);

	mitos::ResolvedEffectRow original_method_row = effectful_root.effect_row;
	effectful_root.effect_row = { };
	MitosAotResult method_row =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	effectful_root.effect_row = original_method_row;
	assert(method_row.status == mitos_mir::MirStatus.ERROR);
	assert(method_row.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	method_row.free();

	mitos::ResolvedEffectRow original_inferred = effect_row.inferred;
	effect_row.inferred = { };
	MitosAotResult forged_effect_row =
		delta_net_abstract_machine::write_mitos_aot(
			&lowered.program, writer_path, mem
		);
	effect_row.inferred = original_inferred;
	assert(forged_effect_row.status == mitos_mir::MirStatus.ERROR);
	assert(forged_effect_row.diagnostic
		== "AOT v4 requires a valid complete DeltaProgram");
	forged_effect_row.free();
}


fn void aot_roundtrips_static_apply_provenance_and_rejects_forged_rows() @test
{
	char[160] factory_buffer;
	char[160] parameter_buffer;
	String factory_path = unique_aot_test_path(
		factory_buffer[..], "apply-factory"
	);
	String parameter_path = unique_aot_test_path(
		parameter_buffer[..], "apply-parameter"
	);
	reserve_aot_test_path(factory_path);
	reserve_aot_test_path(parameter_path);
	defer (void)libc::remove(factory_path.zstr_tcopy());
	defer (void)libc::remove(parameter_path.zstr_tcopy());
	String[2] sources = {
		`effect Reader:
  read() of I64
end
make():
  do() of I64 does Reader:
    Reader.read()
  end
end
main():
  f := make()
  handle f():
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`,
		`effect Reader:
  read() of I64
end
run(f of Function) of I64:
  f()
end
main():
  handle run(do() of I64 does Reader:
    Reader.read()
  end):
    Reader.read(): resume(42)
    return(value of I64): value
  end
end
`,
	};
	String[2] paths = { factory_path, parameter_path };
	foreach (source_index, source : sources)
	{
		MitosParseResult parsed = mitos::parse_program(source, mem);
		assert(parsed.ok());
		DeltaProgramBuildResult lowered =
			mitos::lower_delta_program(&parsed.program, mem);
		assert(lowered.ok());
		assert(!(lowered.program.feature_manifest.required
			& mitos::DELTA_FEATURE_DYNAMIC_EFFECT_CLOSURES));
		MitosAotResult written =
			delta_net_abstract_machine::write_mitos_aot(
				&lowered.program, paths[source_index], mem
			);
		assert(written.status == mitos_mir::MirStatus.NATIVE);
		written.free();
		MitosAotResult executed =
			delta_net_abstract_machine::execute_mitos_aot(
				paths[source_index], mem
			);
		assert(executed.status == mitos_mir::MirStatus.NATIVE);
		assert(executed.result == "42");
		executed.free();

		if (source_index == 1)
		{
			mitos::DeltaMethodRoot* run_root = null;
			foreach (&root : lowered.program.method_roots)
			{
				if (root.key.name == "run")
				{
					run_root = root;
					break;
				}
			}
			assert(run_root != null);
			assert(run_root.function_index < lowered.program.effects.rows.len);
			assert(run_root.effect_row.required.len == 1);
			mitos::DeltaEffectRowDescriptor* row =
				&lowered.program.effects.rows[run_root.function_index];
			assert(row.inferred.required.len == 1);
			bool has_apply = false;
			foreach (&node : lowered.program.image.nodes)
			{
				if (node.kind == mitos::DeltaNodeKind.DELTA_APPLY)
				{
					has_apply = true;
					break;
				}
			}
			assert(has_apply);

			mitos::ResolvedEffectRow original_root_row =
				run_root.effect_row;
			mitos::DeltaEffectRowDescriptor original_descriptor = *row;
			run_root.effect_row = { };
			row.inferred = { };
			row.asserted = { };
			row.has_assertion = false;
			MitosAotResult forged =
				delta_net_abstract_machine::write_mitos_aot(
					&lowered.program, paths[source_index], mem
				);
			run_root.effect_row = original_root_row;
			*row = original_descriptor;
			assert(forged.status == mitos_mir::MirStatus.ERROR);
			assert(forged.diagnostic
				== "AOT v4 requires a valid complete DeltaProgram");
			forged.free();

			MitosAotResult retained =
				delta_net_abstract_machine::execute_mitos_aot(
					paths[source_index], mem
				);
			assert(retained.status == mitos_mir::MirStatus.NATIVE);
			assert(retained.result == "42");
			retained.free();
		}
		lowered.deinit();
		parsed.deinit();
	}
}


fn void aot_effect_operation_limit_is_symmetric_and_fail_closed() @test
{
	char[160] path_buffer;
	String path = unique_aot_test_path(
		path_buffer[..], "effect-operation-limit"
	);
	reserve_aot_test_path(path);
	defer (void)libc::remove(path.zstr_tcopy());

	DString source;
	source.init(mem);
	defer source.free();
	source.append_string("effect Many:\n");
	usz operation_limit = (usz)mitos::MITOS_MAX_EFFECT_OPERATIONS;
	for (usz index = 0; index < operation_limit; index++)
	{
		char[64] operation;
		source.append_string((String)io::bprintf(
			&operation, "  op%d() of I64\n", (long)index
		)!!);
	}
	source.append_string("end\nmain():\n  42\nend\n");

	MitosParseResult parsed = mitos::parse_program(source.str_view(), mem);
	assert(parsed.ok());
	DeltaProgramBuildResult lowered =
		mitos::lower_delta_program(&parsed.program, mem);
	assert(lowered.ok());
	assert(lowered.program.effects.effects.len == 1);
	mitos::DeltaEffectDescriptor* effect =
		&lowered.program.effects.effects[0];
	assert(effect.operations.len == operation_limit);

	MitosAotResult written = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, path, mem
	);
	assert(written.status == mitos_mir::MirStatus.NATIVE);
	written.free();
	MitosAotResult boundary = delta_net_abstract_machine::execute_mitos_aot(
		path, mem
	);
	assert(boundary.status == mitos_mir::MirStatus.NATIVE);
	assert(boundary.result == "42");
	boundary.free();
	char[] canonical = file::load(mem, path)!!;
	defer alloc::free(mem, canonical);

	mitos::OperationId[] original_operations = effect.operations;
	mitos::OperationId[] oversized = alloc::new_array(
		mem, mitos::OperationId, (sz)(operation_limit + 1)
	);
	defer alloc::free(mem, oversized);
	foreach (index, &operation : oversized)
	{
		*operation = original_operations[
			(usz)index < operation_limit ? (usz)index : operation_limit - 1
		];
	}
	effect.operations = oversized;
	MitosAotResult rejected = delta_net_abstract_machine::write_mitos_aot(
		&lowered.program, path, mem
	);
	effect.operations = original_operations;
	assert(rejected.status == mitos_mir::MirStatus.ERROR);
	assert(rejected.diagnostic
		== "AOT v4 program exceeds its cardinality, string, or cumulative byte limits");
	rejected.free();

	char[] retained = file::load(mem, path)!!;
	defer alloc::free(mem, retained);
	assert(retained.len == canonical.len);
	foreach (index, byte : retained) assert(byte == canonical[index]);
	lowered.deinit();
	parsed.deinit();
}
