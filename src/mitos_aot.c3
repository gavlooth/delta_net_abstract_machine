module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_jit;
import delta_net_abstract_machine::mitos_mir;
import libc;
import std::collections::list;
import std::io::file;
import std::io;

extern fn int mitos_aot_mkstemp(ZString template) @cname("mkstemp") @private;

const String MITOS_AOT_MAGIC = "MITOSAOT";
const uint MITOS_AOT_HEADER_LENGTH = 28;
const usz MITOS_AOT_MAX_BYTES = 64 * 1024 * 1024;
const usz MITOS_AOT_MAX_RECORDS = 256;
const usz MITOS_AOT_MAX_NODES = (usz)mitos_jit::JIT_MAX_INSTRUCTIONS;
const usz MITOS_AOT_MAX_EDGES = (usz)mitos_jit::JIT_MAX_OPERANDS;
const usz MITOS_AOT_MAX_INTERFACES = (usz)mitos_jit::JIT_MAX_INSTRUCTIONS;
const usz MITOS_AOT_MAX_PARALLEL_REGIONS = 100_000;
const usz MITOS_AOT_MAX_CONSTRUCTORS = mitos::MITOS_DEFAULT_MAX_TYPES;
const usz MITOS_AOT_MAX_PRIMITIVES = 64;
const usz MITOS_AOT_MAX_SPANS = (usz)mitos_jit::JIT_MAX_INSTRUCTIONS;
const usz MITOS_AOT_MAX_EFFECT_OPERATIONS = (usz)mitos_jit::JIT_MAX_INSTRUCTIONS;
const usz MITOS_AOT_MAX_HANDLERS = (usz)mitos_jit::JIT_MAX_INSTRUCTIONS;
const usz MITOS_AOT_MAX_DECODE_BYTES = 64 * 1024 * 1024;

const mitos::DeltaRecordTag AOT_MANIFEST = mitos::DELTA_RECORD_MANIFEST;
const mitos::DeltaRecordTag AOT_MODULE = mitos::DELTA_RECORD_MODULE;
const mitos::DeltaRecordTag AOT_TYPES = mitos::DELTA_RECORD_TYPES;
const mitos::DeltaRecordTag AOT_METHODS = mitos::DELTA_RECORD_METHODS;
const mitos::DeltaRecordTag AOT_CONSTRUCTORS = mitos::DELTA_RECORD_CONSTRUCTORS;
const mitos::DeltaRecordTag AOT_PRIMITIVES = mitos::DELTA_RECORD_PRIMITIVES;
const mitos::DeltaRecordTag AOT_NODES = mitos::DELTA_RECORD_NODES;
const mitos::DeltaRecordTag AOT_GRAPH = mitos::DELTA_RECORD_GRAPH;
const mitos::DeltaRecordTag AOT_ROOTS = mitos::DELTA_RECORD_ROOTS;
const mitos::DeltaRecordTag AOT_SPANS = mitos::DELTA_RECORD_SPANS;
const mitos::DeltaRecordTag AOT_EFFECTS = mitos::DELTA_RECORD_EFFECTS;
const mitos::DeltaRecordTag AOT_HELPER_ABI = mitos::DELTA_RECORD_HELPER_ABI;

struct AotManifest
{
	mitos::DeltaSchemaVersion schema;
	mitos::DeltaFeatureManifest features;
	uint[] required_records;
	uint[] optional_records;
}

fn void AotManifest.deinit(&self, Allocator allocator)
{
	alloc::free(allocator, self.required_records);
	alloc::free(allocator, self.optional_records);
	*self = { };
}

struct MitosAotResult
{
	mitos_mir::MirStatus status;
	String result;
	String diagnostic;
	mitos::MitosSpan diagnostic_span;
	Allocator allocator;
}

fn void MitosAotResult.free(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.result);
	alloc::free(self.allocator, self.diagnostic);
	*self = { };
}

fn MitosAotResult aot_error_at(
	Allocator allocator,
	String message,
	mitos::MitosSpan span = { }
)
{
	return {
		.status = ERROR,
		.diagnostic = message.copy(allocator),
		.diagnostic_span = span,
		.allocator = allocator,
	};
}

fn MitosAotResult aot_error(Allocator allocator, String message)
{
	return aot_error_at(allocator, message);
}

struct AotWriter
{
	List{char} bytes;
	usz* decode_budget;
	bool failed;
}

fn void AotWriter.init(
	&self,
	Allocator allocator,
	usz* decode_budget = null
)
{
	self.decode_budget = decode_budget;
	self.bytes.init(allocator);
}

fn void AotWriter.deinit(&self)
{
	self.bytes.free();
	*self = { };
}

fn void AotWriter.u8(&self, char value)
{
	if (!self.failed) self.bytes.push(value);
}

fn void AotWriter.u32(&self, uint value)
{
	for (uint shift = 0; shift < 32; shift += 8) self.u8((char)((value >> shift) & 0xff));
}

fn void AotWriter.u64(&self, ulong value)
{
	for (uint shift = 0; shift < 64; shift += 8) self.u8((char)((value >> shift) & 0xff));
}

fn bool AotWriter.claim_decode_bytes(&self, usz bytes)
{
	if (self.failed) return false;
	if (self.decode_budget && bytes > *self.decode_budget)
	{
		self.failed = true;
		return false;
	}
	if (self.decode_budget) *self.decode_budget -= bytes;
	return true;
}

fn void AotWriter.count(
	&self,
	usz value,
	usz maximum,
	usz allocation_item_size
)
{
	if (value > (usz)uint::max || value > maximum
		|| (allocation_item_size && value > usz::max / allocation_item_size)
		|| !self.claim_decode_bytes(value * allocation_item_size))
	{
		self.failed = true;
		return;
	}
	self.u32((uint)value);
}

fn void AotWriter.patch_u64(&self, usz offset, ulong value)
{
	if (self.failed || offset > (usz)self.bytes.size
		|| (usz)self.bytes.size - offset < 8)
	{
		self.failed = true;
		return;
	}
	for (uint shift = 0; shift < 64; shift += 8)
	{
		self.bytes[(sz)(offset + shift / 8)] = (char)((value >> shift) & 0xff);
	}
}

fn void AotWriter.string(&self, String value)
{
	if (value.len > (usz)uint::max
		|| self.bytes.size > (sz)MITOS_AOT_MAX_BYTES - (sz)value.len - 4
		|| !self.claim_decode_bytes(value.len))
	{
		self.failed = true;
		return;
	}
	self.u32((uint)value.len);
	foreach (character : value) self.u8(character);
}

fn void AotWriter.record(
	&self,
	mitos::DeltaRecordTag tag,
	mitos::DeltaRecordFlags flags,
	AotWriter* record
)
{
	if (record.failed || record.bytes.size < 0
		|| self.bytes.size > (sz)MITOS_AOT_MAX_BYTES - record.bytes.size - 16)
	{
		self.failed = true;
		return;
	}
	self.u32((uint)tag);
	self.u32((uint)flags);
	self.u64((ulong)record.bytes.size);
	foreach (byte : record.bytes) self.u8(byte);
}

struct AotReader
{
	Allocator allocator;
	char[] bytes;
	usz cursor;
	bool failed;
	String diagnostic;
	usz* decode_budget;
}

fn void AotReader.fail(&self, String message)
{
	if (self.failed) return;
	self.failed = true;
	self.diagnostic = message;
}

fn bool AotReader.claim_bytes(&self, usz bytes)
{
	if (self.failed || !self.decode_budget) return false;
	if (bytes > *self.decode_budget)
	{
		self.fail("AOT v4 cumulative decode budget exceeds 64 MiB");
		return false;
	}
	*self.decode_budget -= bytes;
	return true;
}

fn bool AotReader.count(
	&self,
	uint encoded,
	usz maximum,
	usz minimum_encoded_bytes,
	usz allocation_item_size
)
{
	if (self.failed || self.cursor > self.bytes.len) return false;
	usz count = (usz)encoded;
	usz remaining = self.bytes.len - self.cursor;
	if (count > maximum
		|| (minimum_encoded_bytes && count > remaining / minimum_encoded_bytes)
		|| (allocation_item_size && count > usz::max / allocation_item_size))
	{
		self.fail("AOT v4 count exceeds production or record limits");
		return false;
	}
	return self.claim_bytes(count * allocation_item_size);
}

fn char AotReader.u8(&self)
{
	if (self.cursor >= self.bytes.len) { self.fail("truncated AOT v4 payload"); return 0; }
	return self.bytes[self.cursor++];
}

fn uint AotReader.u32(&self)
{
	uint value = 0;
	for (uint shift = 0; shift < 32; shift += 8) value |= (uint)self.u8() << shift;
	return value;
}

fn ulong AotReader.u64(&self)
{
	ulong value = 0;
	for (uint shift = 0; shift < 64; shift += 8) value |= (ulong)self.u8() << shift;
	return value;
}

fn uint AotReader.enum_u32(&self, uint maximum, String diagnostic)
{
	uint value = self.u32();
	if (value <= maximum) return value;
	self.fail(diagnostic);
	return 0;
}

fn usz AotReader.usize(&self)
{
	ulong value = self.u64();
	if (value > (ulong)usz::max)
	{
		self.fail("AOT v4 integer cannot be represented by this runtime");
		return 0;
	}
	return (usz)value;
}

fn sz AotReader.ssize(&self)
{
	ulong value = self.u64();
	if (value > (ulong)sz::max)
	{
		self.fail("AOT v4 source position overflows this runtime");
		return 0;
	}
	return (sz)value;
}

fn bool AotReader.boolean(&self)
{
	uint value = self.u32();
	if (value > 1)
	{
		self.fail("AOT v4 boolean domain is invalid");
		return false;
	}
	return value != 0;
}

fn bool AotReader.bounded_length(&self, ulong encoded, usz* length)
{
	if (self.failed || encoded > (ulong)usz::max)
	{
		self.fail("AOT v4 record length overflows this runtime");
		return false;
	}
	usz converted = (usz)encoded;
	if (self.cursor > self.bytes.len || converted > self.bytes.len - self.cursor)
	{
		self.fail("AOT v4 record extends beyond the artifact");
		return false;
	}
	*length = converted;
	return true;
}

fn String AotReader.string(&self)
{
	uint length = self.u32();
	if (self.failed || (usz)length > self.bytes.len - self.cursor)
	{
		self.fail("AOT v4 string extends beyond its bounded record");
		return { };
	}
	if (!self.claim_bytes((usz)length)) return { };
	String value = (String)self.bytes[self.cursor:length];
	self.cursor += length;
	return value.copy(self.allocator);
}

fn String AotReader.bounded_string(&self, usz maximum, String diagnostic)
{
	uint length = self.u32();
	if (self.failed || (usz)length > self.bytes.len - self.cursor)
	{
		self.fail("AOT v4 string extends beyond its bounded record");
		return { };
	}
	if ((usz)length > maximum)
	{
		self.fail(diagnostic);
		return { };
	}
	if (!self.claim_bytes((usz)length)) return { };
	String value = (String)self.bytes[self.cursor:length];
	self.cursor += length;
	return value.copy(self.allocator);
}

fn String AotReader.identifier(&self, bool allow_empty = false)
{
	uint length = self.u32();
	if (self.failed || (usz)length > self.bytes.len - self.cursor)
	{
		self.fail("AOT v4 identifier extends beyond its bounded record");
		return { };
	}
	String value = (String)self.bytes[self.cursor:length];
	if ((!value.len && !allow_empty)
		|| (value.len && !mitos::source_identifier_is_valid(value)))
	{
		self.fail("AOT v4 name is not a source identifier");
		return { };
	}
	if (!self.claim_bytes((usz)length)) return { };
	self.cursor += length;
	return value.copy(self.allocator);
}

fn mitos::MitosSpan aot_read_span(AotReader* reader)
{
	return {
		.start = {
			.offset = reader.ssize(), .row = reader.ssize(), .column = reader.ssize(),
		},
		.end = {
			.offset = reader.ssize(), .row = reader.ssize(), .column = reader.ssize(),
		},
	};
}

fn void aot_write_span(AotWriter* writer, mitos::MitosSpan span)
{
	writer.u64((ulong)span.start.offset); writer.u64((ulong)span.start.row); writer.u64((ulong)span.start.column);
	writer.u64((ulong)span.end.offset); writer.u64((ulong)span.end.row); writer.u64((ulong)span.end.column);
}

fn void aot_write_type_ids(AotWriter* writer, mitos::TypeId[] values)
{
	writer.count(values.len, mitos::MITOS_DEFAULT_MAX_TYPES, mitos::TypeId::size);
	foreach (value : values) writer.u32((uint)value);
}

fn mitos::TypeId[] aot_read_type_ids(AotReader* reader)
{
	uint count = reader.u32();
	if (!reader.count(count, mitos::MITOS_DEFAULT_MAX_TYPES, 4, mitos::TypeId::size)) return { };
	mitos::TypeId[] values = alloc::new_array(reader.allocator, mitos::TypeId, count);
	foreach (&value : values) *value = (mitos::TypeId)reader.u32();
	return values;
}

fn mitos::TypeId[] aot_read_node_type_ids(
	AotReader* reader,
	mitos::DeltaNodeKind kind
)
{
	uint count = reader.u32();
	if ((kind == mitos::DeltaNodeKind.DELTA_SUPERPOSE
			|| kind == mitos::DeltaNodeKind.DELTA_COLLAPSE)
		&& count != 1)
	{
		reader.fail("AOT v4 superposition node has invalid type arity");
		return { };
	}
	if (!reader.count(count, mitos::MITOS_DEFAULT_MAX_TYPES, 4, mitos::TypeId::size)) return { };
	mitos::TypeId[] values = alloc::new_array(reader.allocator, mitos::TypeId, count);
	foreach (&value : values) *value = (mitos::TypeId)reader.u32();
	return values;
}

fn void aot_write_strings(AotWriter* writer, String[] values)
{
	writer.count(values.len, mitos::MITOS_MAX_METHODS, String::size);
	foreach (value : values) writer.string(value);
}

fn String[] aot_read_strings(AotReader* reader)
{
	uint count = reader.u32();
	if (!reader.count(count, mitos::MITOS_MAX_METHODS, 4, String::size)) return { };
	String[] values = alloc::new_array(reader.allocator, String, count);
	foreach (&value : values) *value = reader.string();
	return values;
}

fn String[] aot_read_identifiers(AotReader* reader)
{
	uint count = reader.u32();
	if (!reader.count(count, mitos::MITOS_MAX_METHODS, 4, String::size)) return { };
	String[] values = alloc::new_array(reader.allocator, String, count);
	foreach (&value : values) *value = reader.identifier();
	return values;
}

fn void aot_write_module_key(AotWriter* writer, mitos::ModuleKey* key)
{
	writer.string(key.canonical);
}

fn mitos::ModuleKey aot_read_module_key(AotReader* reader)
{
	return { .canonical = reader.string() };
}

fn void aot_write_symbol_key(AotWriter* writer, mitos::SymbolKey* key)
{
	aot_write_module_key(writer, &key.owner);
	writer.u32((uint)key.kind);
	writer.string(key.name);
	writer.u32(key.arity);
	writer.string(key.canonical_signature);
}

fn mitos::SymbolKey aot_read_symbol_key(AotReader* reader)
{
	mitos::ModuleKey owner = aot_read_module_key(reader);
	uint kind = reader.enum_u32(
		(uint)mitos::SymbolKind.SYMBOL_METHOD,
		"AOT v4 symbol kind is invalid"
	);
	return {
		.owner = owner,
		.kind = (mitos::SymbolKind)kind,
		.name = reader.identifier(true),
		.arity = reader.u32(),
		.canonical_signature = reader.bounded_string(
			mitos::MITOS_MAX_TYPE_FORMAT_BYTES,
			"AOT v4 canonical signature exceeds its rendering limit"
		),
	};
}

fn void aot_write_layout(AotWriter* writer, mitos::LayoutDescriptor* layout)
{
	writer.u32((uint)layout.kind);
	writer.u32((uint)layout.copy_policy);
	writer.u32(layout.sized ? 1 : 0);
	writer.u64(layout.size);
	writer.u64(layout.alignment);
	writer.u64(layout.stride);
	writer.u32((uint)layout.element_type);
	aot_write_symbol_key(writer, &layout.stable_key);
}

fn mitos::LayoutDescriptor aot_read_layout(AotReader* reader)
{
	uint kind = reader.enum_u32(
		(uint)mitos::LayoutKind.LAYOUT_CALLABLE,
		"AOT v4 layout kind is invalid"
	);
	uint copy_policy = reader.enum_u32(
		(uint)mitos::CopyPolicy.COPY_BORROWED,
		"AOT v4 copy policy is invalid"
	);
	return {
		.kind = (mitos::LayoutKind)kind,
		.copy_policy = (mitos::CopyPolicy)copy_policy,
		.sized = reader.boolean(),
		.size = reader.u64(),
		.alignment = reader.u64(),
		.stride = reader.u64(),
		.element_type = (mitos::TypeId)reader.u32(),
		.stable_key = aot_read_symbol_key(reader),
	};
}

fn void aot_write_effect_row(AotWriter* writer, mitos::ResolvedEffectRow* row)
{
	aot_write_effect_ids(writer, row.required);
	writer.u32(row.has_tail ? 1 : 0);
	if (row.has_tail) aot_write_symbol_key(writer, &row.tail);
}

fn mitos::ResolvedEffectRow aot_read_effect_row(AotReader* reader)
{
	mitos::ResolvedEffectRow row = {
		.required = aot_read_effect_ids(reader),
		.has_tail = reader.boolean(),
	};
	if (row.has_tail) row.tail = aot_read_symbol_key(reader);
	return row;
}

fn void aot_write_pattern(AotWriter* writer, mitos::MethodTypePattern* pattern, uint depth = 0)
{
	if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH) { writer.failed = true; return; }
	writer.u32((uint)pattern.kind);
	writer.string(pattern.name);
	writer.u32((uint)pattern.type_id);
	aot_write_span(writer, pattern.span);
	writer.count(
		pattern.arguments.len,
		mitos::MITOS_MAX_METHOD_VARIABLES,
		mitos::MethodTypePattern::size
	);
	foreach (&argument : pattern.arguments) aot_write_pattern(writer, argument, depth + 1);
}

fn mitos::MethodTypePattern aot_read_pattern(AotReader* reader, uint depth = 0)
{
	mitos::MethodTypePattern pattern;
	if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH)
	{
		reader.fail("AOT v4 method pattern nesting is too deep");
		return pattern;
	}
	pattern.kind = (mitos::MethodTypePatternKind)reader.enum_u32(
		(uint)mitos::MethodTypePatternKind.METHOD_PATTERN_APPLICATION,
		"AOT v4 method pattern kind is invalid"
	);
	pattern.name = reader.identifier(true);
	pattern.type_id = (mitos::TypeId)reader.u32();
	pattern.span = aot_read_span(reader);
	uint count = reader.u32();
	if (!reader.count(count, mitos::MITOS_MAX_METHOD_VARIABLES, 64, mitos::MethodTypePattern::size))
	{
		return pattern;
	}
	pattern.arguments = alloc::new_array(reader.allocator, mitos::MethodTypePattern, count);
	foreach (&argument : pattern.arguments) *argument = aot_read_pattern(reader, depth + 1);
	return pattern;
}

fn void aot_write_type_pattern(AotWriter* writer, mitos::TypePattern* pattern, uint depth = 0)
{
	if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH)
	{
		writer.failed = true;
		return;
	}
	writer.u32((uint)pattern.kind);
	writer.string(pattern.variable);
	writer.u32((uint)pattern.constructor);
	aot_write_span(writer, pattern.span);
	writer.count(
		pattern.arguments.len,
		mitos::MITOS_MAX_METHOD_VARIABLES,
		mitos::TypePattern::size
	);
	foreach (&argument : pattern.arguments)
	{
		aot_write_type_pattern(writer, argument, depth + 1);
	}
}

fn mitos::TypePattern aot_read_type_pattern(AotReader* reader, uint depth = 0)
{
	mitos::TypePattern pattern;
	if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH)
	{
		reader.fail("AOT v4 type pattern nesting is too deep");
		return pattern;
	}
	pattern.kind = (mitos::TypePatternKind)reader.enum_u32(
		(uint)mitos::TypePatternKind.TYPE_PATTERN_APPLICATION,
		"AOT v4 type pattern kind is invalid"
	);
	pattern.variable = reader.identifier(true);
	pattern.constructor = (mitos::TypeId)reader.u32();
	pattern.span = aot_read_span(reader);
	uint count = reader.u32();
	if (!reader.count(count, mitos::MITOS_MAX_METHOD_VARIABLES, 64, mitos::TypePattern::size))
	{
		return pattern;
	}
	pattern.arguments = alloc::new_array(reader.allocator, mitos::TypePattern, count);
	foreach (&argument : pattern.arguments)
	{
		*argument = aot_read_type_pattern(reader, depth + 1);
	}
	return pattern;
}

fn void aot_write_types(AotWriter* writer, mitos::DeltaProgram* program)
{
	aot_write_module_key(writer, &program.types.module_key);
	writer.u64(program.types.epoch);
	writer.u64((ulong)program.types.max_types);
	writer.count(
		(usz)program.types.descriptors.len(),
		mitos::MITOS_DEFAULT_MAX_TYPES,
		mitos::TypeDescriptor::size
	);
	foreach (&descriptor : program.types.descriptors)
	{
		aot_write_symbol_key(writer, &descriptor.key);
		aot_write_layout(writer, &descriptor.layout);
		writer.u32((uint)descriptor.id); writer.u32((uint)descriptor.kind); writer.string(descriptor.name);
		aot_write_strings(writer, descriptor.parameters);
		writer.u32((uint)descriptor.nominal_parent); writer.u32((uint)descriptor.constructor);
		aot_write_type_ids(writer, descriptor.arguments); writer.u64((ulong)descriptor.arity);
		aot_write_span(writer, descriptor.span);
		writer.count(
			descriptor.fields.len,
			mitos::MITOS_MAX_TYPE_FIELDS,
			mitos::TypeFieldDescriptor::size
		);
		foreach (&field : descriptor.fields)
		{
			writer.string(field.name); writer.string(field.type_pattern); writer.u32((uint)field.declared_type);
			aot_write_type_pattern(writer, &field.pattern);
			aot_write_span(writer, field.span);
		}
		aot_write_type_ids(writer, descriptor.function_parameters);
		writer.u32((uint)descriptor.function_result);
		aot_write_effect_row(writer, &descriptor.function_effects);
	}
}

fn void aot_read_types(AotReader* reader, mitos::DeltaProgram* program)
{
	program.types = {
		.allocator = reader.allocator,
		.module_key = aot_read_module_key(reader),
		.epoch = reader.u64(),
		.max_types = reader.usize(),
	};
	program.types.descriptors.init(reader.allocator);
	uint count = reader.u32();
	if (!count || !reader.count(count, mitos::MITOS_DEFAULT_MAX_TYPES, 84, mitos::TypeDescriptor::size))
	{
		reader.fail("AOT v4 type registry count is invalid");
		return;
	}
	for (uint index = 0; index < count; index++)
	{
		mitos::TypeDescriptor descriptor = {
			.key = aot_read_symbol_key(reader),
			.layout = aot_read_layout(reader),
			.id = (mitos::TypeId)reader.u32(),
		};
		bool descriptor_owned = true;
		defer if (descriptor_owned) descriptor.deinit(reader.allocator);
		uint descriptor_kind = reader.enum_u32(
			(uint)mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE,
			"AOT v4 type descriptor kind is invalid"
		);
		descriptor.kind = (mitos::TypeDescriptorKind)descriptor_kind;
		descriptor.name = reader.identifier();
		descriptor.parameters = aot_read_identifiers(reader);
		descriptor.nominal_parent = (mitos::TypeId)reader.u32();
		descriptor.constructor = (mitos::TypeId)reader.u32();
		descriptor.arguments = aot_read_type_ids(reader);
		descriptor.arity = reader.usize();
		descriptor.span = aot_read_span(reader);
		uint field_count = reader.u32();
		if (!reader.count(field_count, mitos::MITOS_MAX_TYPE_FIELDS, 64, mitos::TypeFieldDescriptor::size))
		{
			return;
		}
		descriptor.fields = alloc::new_array(reader.allocator, mitos::TypeFieldDescriptor, field_count);
		foreach (&field : descriptor.fields)
		{
			field.name = reader.identifier();
			field.type_pattern = reader.string();
			field.declared_type = (mitos::TypeId)reader.u32();
			field.pattern = aot_read_type_pattern(reader);
			field.span = aot_read_span(reader);
		}
		descriptor.function_parameters = aot_read_type_ids(reader);
		descriptor.function_result = (mitos::TypeId)reader.u32();
		descriptor.function_effects = aot_read_effect_row(reader);
		if (reader.failed) return;
		program.types.descriptors.push(descriptor);
		descriptor_owned = false;
	}
}

fn void aot_write_methods(AotWriter* writer, mitos::DeltaProgram* program)
{
	aot_write_module_key(writer, &program.methods.module_key);
	writer.u64((ulong)program.methods.max_generics); writer.u64((ulong)program.methods.max_methods);
	writer.u64((ulong)program.methods.method_count);
	writer.count(
		(usz)program.methods.generics.len(),
		mitos::MITOS_MAX_GENERIC_FUNCTIONS,
		mitos::GenericFunction::size
	);
	foreach (&generic : program.methods.generics)
	{
		aot_write_symbol_key(writer, &generic.key);
		aot_write_module_key(writer, &generic.owner);
		writer.string(generic.name); writer.u64((ulong)generic.arity); writer.u64(generic.epoch);
		writer.count(
			(usz)generic.methods.len(),
			mitos::MITOS_MAX_METHODS,
			mitos::MethodDescriptor::size
		);
		foreach (&method : generic.methods)
		{
			aot_write_symbol_key(writer, &method.key);
			aot_write_symbol_key(writer, &method.generic_key);
			aot_write_module_key(writer, &method.owner);
			writer.u64((ulong)method.function_index);
			writer.count(
				method.parameters.len,
				mitos::MITOS_MAX_METHOD_VARIABLES,
				mitos::MethodTypePattern::size
			);
			foreach (&parameter : method.parameters) aot_write_pattern(writer, parameter);
			aot_write_pattern(writer, &method.result); aot_write_strings(writer, method.type_variables);
			writer.u64((ulong)method.source_order); aot_write_span(writer, method.span);
		}
	}
}

fn void aot_deinit_generic(
	mitos::GenericFunction* generic,
	Allocator allocator
)
{
	generic.key.deinit(allocator);
	generic.owner.deinit(allocator);
	alloc::free(allocator, generic.name);
	foreach (&method : generic.methods) method.deinit(allocator);
	generic.methods.free();
	*generic = { };
}

fn void aot_read_methods(AotReader* reader, mitos::DeltaProgram* program)
{
	program.methods = {
		.allocator = reader.allocator,
		.module_key = aot_read_module_key(reader),
		.max_generics = reader.usize(), .max_methods = reader.usize(),
		.method_count = reader.usize(),
	};
	program.methods.generics.init(reader.allocator);
	uint generic_count = reader.u32();
	if (!reader.count(generic_count, mitos::MITOS_MAX_GENERIC_FUNCTIONS, 24, mitos::GenericFunction::size))
	{
		return;
	}
	for (uint generic_index = 0; generic_index < generic_count; generic_index++)
	{
		mitos::GenericFunction generic = {
			.key = aot_read_symbol_key(reader),
			.owner = aot_read_module_key(reader),
			.name = reader.identifier(), .arity = reader.usize(), .epoch = reader.u64(),
		};
		generic.methods.init(reader.allocator);
		bool generic_owned = true;
		defer if (generic_owned) aot_deinit_generic(&generic, reader.allocator);
		uint method_count = reader.u32();
		if (!reader.count(method_count, mitos::MITOS_MAX_METHODS, 136, mitos::MethodDescriptor::size))
		{
			return;
		}
		for (uint method_index = 0; method_index < method_count; method_index++)
		{
			mitos::MethodDescriptor method = {
				.key = aot_read_symbol_key(reader),
				.generic_key = aot_read_symbol_key(reader),
				.owner = aot_read_module_key(reader),
				.function_index = reader.usize(),
			};
			bool method_owned = true;
			defer if (method_owned) method.deinit(reader.allocator);
			uint parameter_count = reader.u32();
			if (!reader.count(
				parameter_count,
				mitos::MITOS_MAX_METHOD_VARIABLES,
				64,
				mitos::MethodTypePattern::size
			)) return;
			method.parameters = alloc::new_array(reader.allocator, mitos::MethodTypePattern, parameter_count);
			foreach (&parameter : method.parameters) *parameter = aot_read_pattern(reader);
			method.result = aot_read_pattern(reader);
			method.type_variables = aot_read_identifiers(reader);
			method.source_order = reader.usize();
			method.span = aot_read_span(reader);
			if (reader.failed) return;
			generic.methods.push(method);
			method_owned = false;
		}
		program.methods.generics.push(generic);
		generic_owned = false;
	}
}

fn void aot_write_constructors(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.count(
		program.constructors.len,
		MITOS_AOT_MAX_CONSTRUCTORS,
		mitos::DeltaConstructorDescriptor::size
	);
	foreach (&constructor : program.constructors)
	{
		aot_write_symbol_key(writer, &constructor.key);
		writer.u32(constructor.id); writer.string(constructor.name);
		writer.u32((uint)constructor.runtime_type); writer.u32((uint)constructor.type_constructor);
		aot_write_strings(writer, constructor.parameters);
		aot_write_strings(writer, constructor.fields); aot_write_type_ids(writer, constructor.field_types);
		writer.count(
			constructor.field_patterns.len,
			mitos::MITOS_MAX_TYPE_FIELDS,
			mitos::TypePattern::size
		);
		foreach (&pattern : constructor.field_patterns) aot_write_type_pattern(writer, pattern);
		aot_write_span(writer, constructor.span);
	}
}

fn void aot_read_constructors(AotReader* reader, mitos::DeltaProgram* program)
{
	uint count = reader.u32();
	if (!reader.count(count, MITOS_AOT_MAX_CONSTRUCTORS, 68, mitos::DeltaConstructorDescriptor::size))
	{
		return;
	}
	program.constructors = alloc::new_array(reader.allocator, mitos::DeltaConstructorDescriptor, count);
	foreach (&constructor : program.constructors)
	{
		constructor.key = aot_read_symbol_key(reader);
		constructor.id = reader.u32(); constructor.name = reader.identifier();
		constructor.runtime_type = (mitos::TypeId)reader.u32();
		constructor.type_constructor = (mitos::TypeId)reader.u32();
		constructor.parameters = aot_read_identifiers(reader);
		constructor.fields = aot_read_identifiers(reader);
		constructor.field_types = aot_read_type_ids(reader);
		uint pattern_count = reader.u32();
		if (!reader.count(
			pattern_count,
			mitos::MITOS_MAX_TYPE_FIELDS,
			64,
			mitos::TypePattern::size
		)) return;
		constructor.field_patterns = alloc::new_array(
			reader.allocator,
			mitos::TypePattern,
			pattern_count
		);
		foreach (&pattern : constructor.field_patterns)
		{
			*pattern = aot_read_type_pattern(reader);
		}
		constructor.span = aot_read_span(reader);
	}
}

fn void aot_write_primitives(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.count(
		program.primitives.len,
		MITOS_AOT_MAX_PRIMITIVES,
		mitos::DeltaPrimitiveDescriptor::size
	);
	foreach (&primitive : program.primitives)
	{
		aot_write_symbol_key(writer, &primitive.key);
		writer.u32(primitive.id); writer.u32((uint)primitive.operation); writer.string(primitive.name);
		writer.u64((ulong)primitive.arity); aot_write_type_ids(writer, primitive.parameters); writer.u32((uint)primitive.result);
	}
}

fn void aot_read_primitives(AotReader* reader, mitos::DeltaProgram* program)
{
	uint count = reader.u32();
	if (!reader.count(count, MITOS_AOT_MAX_PRIMITIVES, 28, mitos::DeltaPrimitiveDescriptor::size))
	{
		return;
	}
	program.primitives = alloc::new_array(reader.allocator, mitos::DeltaPrimitiveDescriptor, count);
	foreach (&primitive : program.primitives)
	{
		primitive.key = aot_read_symbol_key(reader);
		primitive.id = reader.u32();
		primitive.operation = (mitos::DeltaPrimitiveOp)reader.enum_u32(
			(uint)mitos::DeltaPrimitiveOp.DELTA_PRIMITIVE_GREATER_EQUAL,
			"AOT v4 primitive operation is invalid"
		);
		primitive.name = reader.identifier(); primitive.arity = reader.usize();
		primitive.parameters = aot_read_type_ids(reader); primitive.result = (mitos::TypeId)reader.u32();
	}
}

fn void aot_write_nodes(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.count(
		program.image.nodes.len,
		MITOS_AOT_MAX_NODES,
		mitos::DeltaNode::size
	);
	foreach (&node : program.image.nodes)
	{
		aot_write_symbol_key(writer, &node.key);
		writer.u32(node.stable_id); writer.u32((uint)node.kind); writer.u32((uint)node.static_type); writer.u32(node.span);
		writer.u64((ulong)node.integer); writer.string(node.string_value);
		writer.u64((ulong)node.descriptor); writer.string(node.name);
		aot_write_strings(writer, node.names); aot_write_type_ids(writer, node.types);
		writer.u32((uint)node.runtime_type); writer.u32((uint)node.result_type);
		aot_write_effect_row(writer, &node.effect_row);
		writer.count(
			node.inputs.len,
			MITOS_AOT_MAX_EDGES,
			mitos::DeltaNodeId::size
		);
		foreach (input : node.inputs) writer.u32((uint)input);
		writer.count(
			node.branches.len,
			mitos::MITOS_MAX_MATCH_ARMS,
			mitos::DeltaMatchBranch::size
		);
		foreach (&branch : node.branches)
		{
			writer.u32(branch.wildcard ? 1 : 0); writer.u32(branch.constructor);
			aot_write_strings(writer, branch.bindings); writer.u32((uint)branch.body); writer.u32(branch.span);
		}
	}
}

fn void aot_read_nodes(AotReader* reader, mitos::DeltaProgram* program)
{
	uint count = reader.u32();
	if (!count || !reader.count(count, MITOS_AOT_MAX_NODES, 52, mitos::DeltaNode::size))
	{
		reader.fail("AOT v4 node count exceeds runtime limits");
		return;
	}
	program.image.nodes = alloc::new_array(reader.allocator, mitos::DeltaNode, count);
	foreach (&node : program.image.nodes)
	{
		node.key = aot_read_symbol_key(reader);
		node.stable_id = reader.u32();
		uint node_kind = reader.u32();
		if (node_kind > (uint)mitos::DeltaNodeKind.DELTA_COLLAPSE)
		{
			reader.fail("AOT v4 node kind is invalid");
			return;
		}
		node.kind = (mitos::DeltaNodeKind)node_kind;
		node.static_type = (mitos::TypeId)reader.u32(); node.span = reader.u32();
		node.integer = (long)reader.u64(); node.string_value = reader.string();
		node.descriptor = reader.usize(); node.name = reader.identifier(true);
		bool superposition_node = node.kind == mitos::DeltaNodeKind.DELTA_SUPERPOSE
			|| node.kind == mitos::DeltaNodeKind.DELTA_COLLAPSE;
		if (superposition_node && (!node.descriptor || node.descriptor > program.image.nodes.len))
		{
			reader.fail("AOT v4 superposition node origin is invalid");
			return;
		}
		node.names = aot_read_identifiers(reader);
		node.types = aot_read_node_type_ids(reader, node.kind);
		node.runtime_type = (mitos::TypeId)reader.u32();
		node.result_type = (mitos::TypeId)reader.u32();
		if (superposition_node
			&& (reader.failed
				|| node.types[0] != node.result_type
				|| !aot_valid_type(program, node.result_type)
				|| node.static_type != node.runtime_type
				|| !aot_valid_unary_runtime_type(
					program,
					node.runtime_type,
					node.kind == mitos::DeltaNodeKind.DELTA_SUPERPOSE
						? mitos::TYPE_ID_SUPERPOSITION : mitos::TYPE_ID_ARRAY,
					node.result_type
				)))
		{
			reader.fail("AOT v4 superposition node type metadata is invalid");
			return;
		}
		node.effect_row = aot_read_effect_row(reader);
		uint input_count = reader.u32();
		if (superposition_node
			&& ((node.kind == mitos::DeltaNodeKind.DELTA_SUPERPOSE && !input_count)
				|| (node.kind == mitos::DeltaNodeKind.DELTA_COLLAPSE && input_count != 1)))
		{
			reader.fail("AOT v4 superposition node input arity is invalid");
			return;
		}
		if (!reader.count(input_count, MITOS_AOT_MAX_EDGES, 4, mitos::DeltaNodeId::size)) return;
		node.inputs = alloc::new_array(reader.allocator, mitos::DeltaNodeId, input_count);
		foreach (&input : node.inputs) *input = (mitos::DeltaNodeId)reader.u32();
		uint branch_count = reader.u32();
		if (superposition_node && branch_count)
		{
			reader.fail("AOT v4 superposition node cannot contain match branches");
			return;
		}
		if (!reader.count(branch_count, mitos::MITOS_MAX_MATCH_ARMS, 20, mitos::DeltaMatchBranch::size))
		{
			return;
		}
		node.branches = alloc::new_array(reader.allocator, mitos::DeltaMatchBranch, branch_count);
		foreach (&branch : node.branches)
		{
			branch.wildcard = reader.boolean(); branch.constructor = reader.u32();
			branch.bindings = aot_read_identifiers(reader); branch.body = (mitos::DeltaNodeId)reader.u32(); branch.span = reader.u32();
		}
	}
}

fn void aot_write_graph(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.count(
		program.image.edges.len,
		MITOS_AOT_MAX_EDGES,
		mitos::DeltaEdge::size
	);
	foreach (&edge : program.image.edges) { writer.u32((uint)edge.producer); writer.u32((uint)edge.consumer); writer.u64((ulong)edge.input); }
	writer.count(
		program.image.interfaces.len,
		MITOS_AOT_MAX_INTERFACES,
		mitos::DeltaInterface::size
	);
	foreach (&boundary : program.image.interfaces)
	{
		aot_write_symbol_key(writer, &boundary.key);
		writer.u32((uint)boundary.kind); writer.string(boundary.name); writer.u32((uint)boundary.root); writer.u64((ulong)boundary.source_order);
	}
	writer.count(
		program.image.parallel_regions.len,
		MITOS_AOT_MAX_PARALLEL_REGIONS,
		mitos::DeltaParallelRegion::size
	);
	foreach (&region : program.image.parallel_regions)
	{
		writer.count(
			region.roots.len,
			mitos::MITOS_MAX_PARALLEL_BINDINGS,
			mitos::DeltaNodeId::size
		);
		foreach (root : region.roots) writer.u32((uint)root);
		writer.u32((uint)region.join); writer.u64((ulong)region.source_order);
	}
}

fn void aot_read_graph(AotReader* reader, mitos::DeltaProgram* program)
{
	uint edge_count = reader.u32();
	if (!reader.count(edge_count, MITOS_AOT_MAX_EDGES, 16, mitos::DeltaEdge::size)) return;
	program.image.edges = alloc::new_array(reader.allocator, mitos::DeltaEdge, edge_count);
	foreach (&edge : program.image.edges)
	{
		edge.producer = (mitos::DeltaNodeId)reader.u32();
		edge.consumer = (mitos::DeltaNodeId)reader.u32();
		edge.input = reader.usize();
	}
	uint interface_count = reader.u32();
	if (!reader.count(interface_count, MITOS_AOT_MAX_INTERFACES, 20, mitos::DeltaInterface::size)) return;
	program.image.interfaces = alloc::new_array(reader.allocator, mitos::DeltaInterface, interface_count);
	foreach (&boundary : program.image.interfaces)
	{
		boundary.key = aot_read_symbol_key(reader);
		boundary.kind = (mitos::DeltaInterfaceKind)reader.enum_u32(
			(uint)mitos::DeltaInterfaceKind.DELTA_INTERFACE_METHOD,
			"AOT v4 interface kind is invalid"
		);
		boundary.name = reader.identifier();
		boundary.root = (mitos::DeltaNodeId)reader.u32(); boundary.source_order = reader.usize();
	}
	uint region_count = reader.u32();
	if (!reader.count(
		region_count,
		MITOS_AOT_MAX_PARALLEL_REGIONS,
		16,
		mitos::DeltaParallelRegion::size
	)) return;
	program.image.parallel_regions = alloc::new_array(reader.allocator, mitos::DeltaParallelRegion, region_count);
	foreach (&region : program.image.parallel_regions)
	{
		uint root_count = reader.u32();
		if (!reader.count(
			root_count,
			mitos::MITOS_MAX_PARALLEL_BINDINGS,
			4,
			mitos::DeltaNodeId::size
		)) return;
		region.roots = alloc::new_array(reader.allocator, mitos::DeltaNodeId, root_count);
		foreach (&root : region.roots) *root = (mitos::DeltaNodeId)reader.u32();
		region.join = (mitos::DeltaNodeId)reader.u32(); region.source_order = reader.usize();
	}
}

fn void aot_write_roots(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u32((uint)program.entry);
	writer.count(
		program.method_roots.len,
		mitos::MITOS_MAX_METHODS,
		mitos::DeltaMethodRoot::size
	);
	foreach (&root : program.method_roots)
	{
		aot_write_symbol_key(writer, &root.key);
		aot_write_symbol_key(writer, &root.generic_key);
		writer.u64((ulong)root.function_index); writer.u64((ulong)root.generic_index); writer.u64((ulong)root.method_index);
		writer.u32((uint)root.root); aot_write_strings(writer, root.parameters); aot_write_type_ids(writer, root.parameter_types);
		writer.count(
			root.parameter_patterns.len,
			mitos::MITOS_MAX_METHOD_VARIABLES,
			mitos::MethodTypePattern::size
		);
		foreach (&pattern : root.parameter_patterns) aot_write_pattern(writer, pattern);
		writer.u32((uint)root.result_type); aot_write_pattern(writer, &root.result_pattern);
		aot_write_effect_row(writer, &root.effect_row); writer.u64((ulong)root.source_order);
	}
}

fn void aot_read_roots(AotReader* reader, mitos::DeltaProgram* program)
{
	program.entry = (mitos::DeltaNodeId)reader.u32();
	uint count = reader.u32();
	if (!reader.count(count, mitos::MITOS_MAX_METHODS, 48, mitos::DeltaMethodRoot::size)) return;
	program.method_roots = alloc::new_array(reader.allocator, mitos::DeltaMethodRoot, count);
	foreach (&root : program.method_roots)
	{
		root.key = aot_read_symbol_key(reader);
		root.generic_key = aot_read_symbol_key(reader);
		root.function_index = reader.usize(); root.generic_index = reader.usize(); root.method_index = reader.usize();
		root.root = (mitos::DeltaNodeId)reader.u32(); root.parameters = aot_read_identifiers(reader);
		root.parameter_types = aot_read_type_ids(reader);
		uint pattern_count = reader.u32();
		if (!reader.count(
			pattern_count,
			mitos::MITOS_MAX_METHOD_VARIABLES,
			64,
			mitos::MethodTypePattern::size
		)) return;
		root.parameter_patterns = alloc::new_array(
			reader.allocator,
			mitos::MethodTypePattern,
			pattern_count
		);
		foreach (&pattern : root.parameter_patterns) *pattern = aot_read_pattern(reader);
		root.result_type = (mitos::TypeId)reader.u32();
		root.result_pattern = aot_read_pattern(reader);
		root.effect_row = aot_read_effect_row(reader);
		root.source_order = reader.usize();
	}
}

fn void aot_write_spans(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.count(
		program.spans.len,
		MITOS_AOT_MAX_SPANS,
		mitos::MitosSpan::size
	);
	foreach (span : program.spans) aot_write_span(writer, span);
}

fn void aot_read_spans(AotReader* reader, mitos::DeltaProgram* program)
{
	uint count = reader.u32();
	if (!reader.count(count, MITOS_AOT_MAX_SPANS, 48, mitos::MitosSpan::size)) return;
	program.spans = alloc::new_array(reader.allocator, mitos::MitosSpan, count);
	foreach (&span : program.spans) *span = aot_read_span(reader);
}

fn void aot_write_effect_ids(AotWriter* writer, mitos::EffectId[] values)
{
	writer.count(
		values.len,
		mitos::MITOS_MAX_EFFECT_INSTANCES,
		mitos::EffectId::size
	);
	foreach (value : values) writer.u32((uint)value);
}

fn mitos::EffectId[] aot_read_effect_ids(AotReader* reader)
{
	uint count = reader.u32();
	if (!reader.count(count, mitos::MITOS_MAX_EFFECT_INSTANCES, 4, mitos::EffectId::size)) return { };
	mitos::EffectId[] values = alloc::new_array(reader.allocator, mitos::EffectId, count);
	foreach (&value : values) *value = (mitos::EffectId)reader.u32();
	return values;
}

fn void aot_write_effects(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u32((uint)program.effects.next_effect_id); writer.u32((uint)program.effects.next_operation_id);
	writer.u64(program.effects.epoch);
	writer.count(
		program.effects.effects.len,
		mitos::MITOS_MAX_EFFECTS,
		mitos::DeltaEffectDescriptor::size
	);
	foreach (&effect : program.effects.effects)
	{
		aot_write_symbol_key(writer, &effect.key);
		writer.u32((uint)effect.id); writer.string(effect.name); writer.u32(effect.multi ? 1 : 0);
		aot_write_strings(writer, effect.parameters);
		writer.count(
			effect.operations.len,
			mitos::MITOS_MAX_EFFECT_OPERATIONS,
			mitos::OperationId::size
		);
		foreach (operation : effect.operations) writer.u32((uint)operation);
		writer.u32(effect.span);
	}
	writer.count(
		program.effects.operations.len,
		MITOS_AOT_MAX_EFFECT_OPERATIONS,
		mitos::DeltaOperationDescriptor::size
	);
	foreach (&operation : program.effects.operations)
	{
		aot_write_symbol_key(writer, &operation.key);
		writer.u32((uint)operation.id); writer.u32((uint)operation.effect); writer.string(operation.name);
		aot_write_strings(writer, operation.parameter_patterns);
		writer.count(
			operation.parameter_types.len,
			mitos::MITOS_MAX_EFFECT_OPERATIONS,
			mitos::TypePattern::size
		);
		foreach (&pattern : operation.parameter_types) aot_write_type_pattern(writer, pattern);
		writer.string(operation.result_pattern); aot_write_type_pattern(writer, &operation.result_type);
		writer.u32(operation.span); writer.u32((uint)operation.host_kind); writer.u32(operation.ordered ? 1 : 0);
	}
	writer.count(
		program.effects.instances.len,
		mitos::MITOS_MAX_EFFECT_INSTANCES,
		mitos::DeltaEffectInstanceDescriptor::size
	);
	foreach (&instance : program.effects.instances)
	{
		aot_write_symbol_key(writer, &instance.key);
		writer.u32((uint)instance.id); writer.u32((uint)instance.constructor);
		aot_write_type_ids(writer, instance.arguments);
	}
	writer.count(
		program.effects.rows.len,
		mitos::MITOS_MAX_METHODS,
		mitos::DeltaEffectRowDescriptor::size
	);
	foreach (&row : program.effects.rows)
	{
		aot_write_symbol_key(writer, &row.key);
		writer.u64((ulong)row.function_index); aot_write_effect_row(writer, &row.inferred);
		aot_write_effect_row(writer, &row.asserted);
		writer.u32(row.has_assertion ? 1 : 0); writer.u64(row.effect_epoch);
	}
	writer.count(
		program.effects.handlers.len,
		MITOS_AOT_MAX_HANDLERS,
		mitos::DeltaHandlerDescriptor::size
	);
	foreach (&handler : program.effects.handlers)
	{
		writer.u32(handler.stable_id);
		writer.u32((uint)handler.handled);
		writer.count(
			handler.clauses.len,
			mitos::MITOS_MAX_HANDLER_CLAUSES,
			mitos::DeltaHandlerClauseDescriptor::size
		);
		foreach (&clause : handler.clauses)
		{
			aot_write_symbol_key(writer, &clause.key);
			writer.u32(clause.stable_id); writer.u32((uint)clause.effect); writer.u32((uint)clause.operation);
			aot_write_strings(writer, clause.parameters); aot_write_type_ids(writer, clause.parameter_types);
			writer.u32((uint)clause.result_type); writer.u32((uint)clause.body);
			writer.u32(clause.span); writer.u64((ulong)clause.resume_count);
			writer.u32(clause.multi ? 1 : 0);
		}
		writer.string(handler.return_parameter); writer.u32((uint)handler.return_type);
		writer.u32((uint)handler.return_body); writer.u32(handler.span); writer.u64((ulong)handler.source_order);
	}
}

fn void aot_read_effects(AotReader* reader, mitos::DeltaProgram* program)
{
	program.effects.next_effect_id = (mitos::EffectId)reader.u32();
	program.effects.next_operation_id = (mitos::OperationId)reader.u32();
	program.effects.epoch = reader.u64();
	uint effect_count = reader.u32();
	if (!reader.count(effect_count, mitos::MITOS_MAX_EFFECTS, 24, mitos::DeltaEffectDescriptor::size))
	{
		return;
	}
	program.effects.effects = alloc::new_array(reader.allocator, mitos::DeltaEffectDescriptor, effect_count);
	foreach (&effect : program.effects.effects)
	{
		effect.key = aot_read_symbol_key(reader);
		effect.id = (mitos::EffectId)reader.u32(); effect.name = reader.identifier(); effect.multi = reader.boolean();
		effect.parameters = aot_read_identifiers(reader);
		uint operation_count = reader.u32();
		if (!reader.count(
			operation_count,
			mitos::MITOS_MAX_EFFECT_OPERATIONS,
			4,
			mitos::OperationId::size
		)) return;
		effect.operations = alloc::new_array(reader.allocator, mitos::OperationId, operation_count);
		foreach (&operation : effect.operations) *operation = (mitos::OperationId)reader.u32();
		effect.span = reader.u32();
	}
	uint operation_count = reader.u32();
	if (!reader.count(
		operation_count,
		MITOS_AOT_MAX_EFFECT_OPERATIONS,
		36,
		mitos::DeltaOperationDescriptor::size
	)) return;
	program.effects.operations = alloc::new_array(reader.allocator, mitos::DeltaOperationDescriptor, operation_count);
	foreach (&operation : program.effects.operations)
	{
		operation.key = aot_read_symbol_key(reader);
		operation.id = (mitos::OperationId)reader.u32(); operation.effect = (mitos::EffectId)reader.u32();
		operation.name = reader.identifier(); operation.parameter_patterns = aot_read_strings(reader);
		uint pattern_count = reader.u32();
		if (!reader.count(
			pattern_count,
			mitos::MITOS_MAX_EFFECT_OPERATIONS,
			64,
			mitos::TypePattern::size
		)) return;
		operation.parameter_types = alloc::new_array(
			reader.allocator,
			mitos::TypePattern,
			pattern_count
		);
		foreach (&pattern : operation.parameter_types) *pattern = aot_read_type_pattern(reader);
		operation.result_pattern = reader.string();
		operation.result_type = aot_read_type_pattern(reader);
		operation.span = reader.u32();
		operation.host_kind = (mitos::DeltaEffectHostKind)reader.enum_u32(
			(uint)mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL,
			"AOT v4 effect host kind is invalid"
		);
		operation.ordered = reader.boolean();
	}
	uint instance_count = reader.u32();
	if (!reader.count(
		instance_count,
		mitos::MITOS_MAX_EFFECT_INSTANCES,
		12,
		mitos::DeltaEffectInstanceDescriptor::size
	)) return;
	program.effects.instances = alloc::new_array(
		reader.allocator, mitos::DeltaEffectInstanceDescriptor, instance_count
	);
	foreach (&instance : program.effects.instances)
	{
		instance.key = aot_read_symbol_key(reader);
		instance.id = (mitos::EffectId)reader.u32();
		instance.constructor = (mitos::EffectId)reader.u32();
		instance.arguments = aot_read_type_ids(reader);
	}
	uint row_count = reader.u32();
	if (!reader.count(row_count, mitos::MITOS_MAX_METHODS, 28, mitos::DeltaEffectRowDescriptor::size))
	{
		return;
	}
	program.effects.rows = alloc::new_array(reader.allocator, mitos::DeltaEffectRowDescriptor, row_count);
	foreach (&row : program.effects.rows)
	{
		row.key = aot_read_symbol_key(reader);
		row.function_index = reader.usize(); row.inferred = aot_read_effect_row(reader);
		row.asserted = aot_read_effect_row(reader);
		row.has_assertion = reader.boolean(); row.effect_epoch = reader.u64();
	}
	uint handler_count = reader.u32();
	if (!reader.count(
		handler_count,
		MITOS_AOT_MAX_HANDLERS,
		40,
		mitos::DeltaHandlerDescriptor::size
	)) return;
	program.effects.handlers = alloc::new_array(reader.allocator, mitos::DeltaHandlerDescriptor, handler_count);
	foreach (&handler : program.effects.handlers)
	{
		handler.stable_id = reader.u32(); handler.handled = (mitos::DeltaNodeId)reader.u32();
		uint clause_count = reader.u32();
		if (!reader.count(
			clause_count,
			mitos::MITOS_MAX_HANDLER_CLAUSES,
			40,
			mitos::DeltaHandlerClauseDescriptor::size
		)) return;
		handler.clauses = alloc::new_array(reader.allocator, mitos::DeltaHandlerClauseDescriptor, clause_count);
		foreach (&clause : handler.clauses)
		{
			clause.key = aot_read_symbol_key(reader);
			clause.stable_id = reader.u32(); clause.effect = (mitos::EffectId)reader.u32();
			clause.operation = (mitos::OperationId)reader.u32(); clause.parameters = aot_read_identifiers(reader);
			clause.parameter_types = aot_read_type_ids(reader);
			clause.result_type = (mitos::TypeId)reader.u32();
			clause.body = (mitos::DeltaNodeId)reader.u32();
			clause.span = reader.u32(); clause.resume_count = reader.usize();
			clause.multi = reader.boolean();
		}
		handler.return_parameter = reader.identifier(); handler.return_type = (mitos::TypeId)reader.u32();
		handler.return_body = (mitos::DeltaNodeId)reader.u32(); handler.span = reader.u32();
		handler.source_order = reader.usize();
	}
}

fn void aot_write_helper_abi(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u32(program.helper_abi.major); writer.u32(program.helper_abi.minor);
	writer.u64((ulong)program.helper_abi.features.required);
	writer.u64((ulong)program.helper_abi.features.optional);
	writer.u32(program.helper_abi.effect_tag); writer.u32(program.helper_abi.handler_tag);
	writer.u32(program.helper_abi.resume_tag); writer.u32(program.helper_abi.abort_tag);
}

fn void aot_read_helper_abi(AotReader* reader, mitos::DeltaProgram* program)
{
	program.helper_abi.major = reader.u32(); program.helper_abi.minor = reader.u32();
	program.helper_abi.features.required = (mitos::DeltaFeatureBits)reader.u64();
	program.helper_abi.features.optional = (mitos::DeltaFeatureBits)reader.u64();
	program.helper_abi.effect_tag = reader.u32();
	program.helper_abi.handler_tag = reader.u32();
	program.helper_abi.resume_tag = reader.u32(); program.helper_abi.abort_tag = reader.u32();
}

fn void aot_write_module(AotWriter* writer, mitos::DeltaProgram* program)
{
	aot_write_module_key(writer, &program.module_key);
}

fn void aot_read_module(AotReader* reader, mitos::DeltaProgram* program)
{
	program.module_key = aot_read_module_key(reader);
}

fn void aot_write_manifest(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u32(program.schema.major);
	writer.u32(program.schema.minor);
	writer.u64((ulong)program.feature_manifest.required);
	writer.u64((ulong)program.feature_manifest.optional);
	writer.count(
		(usz)mitos::DELTA_RECORD_LAST_CORE,
		MITOS_AOT_MAX_RECORDS,
		uint::size
	);
	for (uint tag = (uint)mitos::DELTA_RECORD_MANIFEST;
		tag <= (uint)mitos::DELTA_RECORD_LAST_CORE; tag++)
	{
		writer.u32(tag);
	}
	writer.count(0, MITOS_AOT_MAX_RECORDS, uint::size);
}

fn uint[] aot_read_manifest_tags(AotReader* reader)
{
	uint count = reader.u32();
	if (!reader.count(count, MITOS_AOT_MAX_RECORDS, 4, uint::size)) return { };
	uint[] tags = alloc::new_array(reader.allocator, uint, count);
	uint previous = 0;
	foreach (&tag : tags)
	{
		*tag = reader.u32();
		if (!*tag || *tag <= previous)
		{
			reader.fail("AOT v4 manifest record tags are not canonical");
			return tags;
		}
		previous = *tag;
	}
	return tags;
}

fn AotManifest aot_read_manifest(AotReader* reader)
{
	AotManifest manifest = {
		.schema = { .major = reader.u32(), .minor = reader.u32() },
		.features = {
			.required = (mitos::DeltaFeatureBits)reader.u64(),
			.optional = (mitos::DeltaFeatureBits)reader.u64(),
		},
	};
	manifest.required_records = aot_read_manifest_tags(reader);
	manifest.optional_records = aot_read_manifest_tags(reader);
	return manifest;
}

fn bool aot_known_record(uint tag)
{
	return tag >= (uint)mitos::DELTA_RECORD_MANIFEST
		&& tag <= (uint)mitos::DELTA_RECORD_LAST_CORE;
}

fn bool aot_manifest_record_flags(
	AotManifest* manifest,
	uint tag,
	mitos::DeltaRecordFlags* flags
)
{
	foreach (required : manifest.required_records)
	{
		if (required == tag)
		{
			*flags = mitos::DELTA_RECORD_REQUIRED;
			return true;
		}
	}
	foreach (optional : manifest.optional_records)
	{
		if (optional == tag)
		{
			*flags = mitos::DELTA_RECORD_OPTIONAL;
			return true;
		}
	}
	return false;
}

fn mitos::DeltaFeatureBits aot_record_prerequisites(uint tag)
{
	switch (tag)
	{
		case (uint)AOT_MANIFEST: return mitos::DELTA_FEATURE_TAGGED_RECORDS;
		case (uint)AOT_MODULE: return mitos::DELTA_FEATURE_IDENTITY_KEYS;
		case (uint)AOT_TYPES:
			return mitos::DELTA_FEATURE_IDENTITY_KEYS
				| mitos::DELTA_FEATURE_EFFECT_ROWS | mitos::DELTA_FEATURE_LAYOUTS;
		case (uint)AOT_METHODS:
		case (uint)AOT_ROOTS:
			return mitos::DELTA_FEATURE_IDENTITY_KEYS | mitos::DELTA_FEATURE_EFFECT_ROWS;
		case (uint)AOT_CONSTRUCTORS:
		case (uint)AOT_PRIMITIVES:
		case (uint)AOT_NODES:
		case (uint)AOT_GRAPH:
		case (uint)AOT_EFFECTS:
			return mitos::DELTA_FEATURE_IDENTITY_KEYS;
		case (uint)AOT_SPANS: return (mitos::DeltaFeatureBits)0;
		case (uint)AOT_HELPER_ABI: return mitos::DELTA_FEATURE_TAGGED_RECORDS;
		default: return (mitos::DeltaFeatureBits)0;
	}
}

fn bool aot_manifest_is_supported(AotManifest* manifest)
{
	if (!manifest
		|| !mitos::delta_schema_is_supported(manifest.schema, manifest.features)
		|| (manifest.features.required & mitos::DELTA_V4_CORE_REQUIRED_FEATURES)
			!= mitos::DELTA_V4_CORE_REQUIRED_FEATURES
		|| manifest.required_records.len != (usz)mitos::DELTA_RECORD_LAST_CORE)
	{
		return false;
	}
	foreach (index, required : manifest.required_records)
	{
		if (required != (uint)index + 1) return false;
	}
	foreach (required : manifest.required_records)
	{
		if (!aot_known_record(required)) return false;
		mitos::DeltaFeatureBits prerequisites = aot_record_prerequisites(required);
		if (prerequisites & ~manifest.features.required) return false;
	}
	foreach (optional : manifest.optional_records)
	{
		foreach (required : manifest.required_records)
		{
			if (optional == required) return false;
		}
		if (aot_known_record(optional)) return false;
	}
	return true;
}

fn MitosAotResult write_mitos_aot(
	mitos::DeltaProgram* program,
	String output,
	Allocator allocator = mem
)
{
	if (!program || !program.entry || !validate_aot_delta_program(program))
	{
		return aot_error(allocator, "AOT v4 requires a valid complete DeltaProgram");
	}

	usz decode_budget = MITOS_AOT_MAX_DECODE_BYTES;
	AotWriter artifact; artifact.init(allocator, &decode_budget); defer artifact.deinit();
	foreach (character : MITOS_AOT_MAGIC) artifact.u8(character);
	artifact.u32(mitos::DELTA_AOT_CONTAINER_MAJOR);
	artifact.u32(mitos::DELTA_AOT_CONTAINER_MINOR);
	artifact.u32(MITOS_AOT_HEADER_LENGTH);
	artifact.u64(0);

	AotWriter record; record.init(allocator, &decode_budget);
	aot_write_manifest(&record, program);
	artifact.record(AOT_MANIFEST, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_module(&record, program);
	artifact.record(AOT_MODULE, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_types(&record, program);
	artifact.record(AOT_TYPES, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_methods(&record, program);
	artifact.record(AOT_METHODS, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_constructors(&record, program);
	artifact.record(AOT_CONSTRUCTORS, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_primitives(&record, program);
	artifact.record(AOT_PRIMITIVES, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_nodes(&record, program);
	artifact.record(AOT_NODES, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_graph(&record, program);
	artifact.record(AOT_GRAPH, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_roots(&record, program);
	artifact.record(AOT_ROOTS, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_spans(&record, program);
	artifact.record(AOT_SPANS, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_effects(&record, program);
	artifact.record(AOT_EFFECTS, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit(); record.init(allocator, &decode_budget);
	aot_write_helper_abi(&record, program);
	artifact.record(AOT_HELPER_ABI, mitos::DELTA_RECORD_REQUIRED, &record);
	record.deinit();

	if (artifact.failed || artifact.bytes.size < (sz)MITOS_AOT_HEADER_LENGTH
		|| artifact.bytes.size > (sz)MITOS_AOT_MAX_BYTES)
	{
		return aot_error(
			allocator,
			"AOT v4 artifact exceeds its paired 64 MiB encode/decode limits"
		);
	}
	ulong artifact_length = (ulong)artifact.bytes.size;
	artifact.patch_u64(20, artifact_length);
	if (artifact.failed)
	{
		return aot_error(allocator, "AOT v4 writer length accounting failed");
	}

	DString temporary; temporary.init(allocator); defer temporary.free();
	temporary.append_string(output);
	temporary.append_string(".tmp.XXXXXX");
	ZString temporary_path = temporary.copy_zstr(allocator);
	defer alloc::free(allocator, temporary_path);
	int descriptor = mitos_aot_mkstemp(temporary_path);
	if (descriptor < 0)
	{
		return aot_error(allocator, "unable to create temporary AOT v4 artifact");
	}
	bool temporary_exists = true;
	defer if (temporary_exists) (void)libc::remove(temporary_path);
	CFile stream = libc::fdopen(descriptor, "wb");
	if (!stream)
	{
		(void)libc::close(descriptor);
		return aot_error(allocator, "unable to open temporary AOT v4 artifact");
	}
	char[] bytes = artifact.bytes.array_view();
	usz written = 0;
	while (written < bytes.len)
	{
		usz count = libc::fwrite(bytes[written..].ptr, 1u, bytes.len - written, stream);
		if (!count)
		{
			(void)libc::fclose(stream);
			return aot_error(allocator, "unable to write temporary AOT v4 artifact");
		}
		written += count;
	}
	if (libc::fclose(stream) != 0)
	{
		return aot_error(allocator, "unable to finish temporary AOT v4 artifact");
	}
	if (libc::rename(temporary_path, output.zstr_tcopy()) != 0)
	{
		return aot_error(allocator, "unable to atomically replace AOT v4 artifact");
	}
	temporary_exists = false;
	return { .status = NATIVE, .allocator = allocator };
}

fn bool aot_valid_type(mitos::DeltaProgram* program, mitos::TypeId type_id)
{
	return type_id != mitos::TYPE_ID_INVALID
		&& (usz)type_id <= (usz)program.types.descriptors.len();
}

fn bool aot_valid_node(mitos::DeltaProgram* program, mitos::DeltaNodeId node_id)
{
	return node_id != mitos::DELTA_NODE_INVALID && (usz)node_id <= program.image.nodes.len;
}

fn mitos::DeltaEffectDescriptor* aot_effect_descriptor(
	mitos::DeltaProgram* program,
	mitos::EffectId effect_id
)
{
	if (!effect_id || (usz)effect_id > program.effects.effects.len) return null;
	mitos::DeltaEffectDescriptor* effect = &program.effects.effects[(usz)effect_id - 1];
	return effect.id == effect_id ? effect : null;
}

fn mitos::DeltaEffectInstanceDescriptor* aot_effect_instance(
	mitos::DeltaProgram* program,
	mitos::EffectId effect_id
)
{
	if ((usz)effect_id <= program.effects.effects.len) return null;
	usz index = (usz)effect_id - program.effects.effects.len - 1;
	if (index >= program.effects.instances.len) return null;
	mitos::DeltaEffectInstanceDescriptor* instance = &program.effects.instances[index];
	return instance.id == effect_id ? instance : null;
}

fn mitos::DeltaOperationDescriptor* aot_operation_descriptor(
	mitos::DeltaProgram* program,
	mitos::OperationId operation_id
)
{
	if (!operation_id || (usz)operation_id > program.effects.operations.len) return null;
	mitos::DeltaOperationDescriptor* operation =
		&program.effects.operations[(usz)operation_id - 1];
	return operation.id == operation_id ? operation : null;
}

fn bool aot_valid_effect_id(mitos::DeltaProgram* program, mitos::EffectId effect_id)
{
	return aot_effect_descriptor(program, effect_id) != null
		|| aot_effect_instance(program, effect_id) != null;
}
fn mitos::SymbolKey* aot_effect_key(
	mitos::DeltaProgram* program,
	mitos::EffectId effect_id
)
{
	mitos::DeltaEffectDescriptor* descriptor = aot_effect_descriptor(
		program, effect_id
	);
	if (descriptor) return &descriptor.key;
	mitos::DeltaEffectInstanceDescriptor* instance = aot_effect_instance(
		program, effect_id
	);
	return instance ? &instance.key : null;
}


fn bool aot_valid_span(mitos::MitosSpan span)
{
	if (span.start.offset < 0 || span.start.row < 0 || span.start.column < 0
		|| span.end.offset < 0 || span.end.row < 0 || span.end.column < 0
		|| span.start.offset > span.end.offset || span.start.row > span.end.row)
	{
		return false;
	}
	return span.start.row != span.end.row
		|| span.start.column <= span.end.column;
}

fn bool aot_valid_type_pattern(
	mitos::DeltaProgram* program,
	mitos::TypePattern* pattern,
	uint depth = 0
)
{
	if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH || !aot_valid_span(pattern.span)
		|| (uint)pattern.kind > (uint)mitos::TypePatternKind.TYPE_PATTERN_APPLICATION)
	{
		return false;
	}
	switch (pattern.kind)
	{
		case TYPE_PATTERN_ANY:
			return !pattern.variable.len
				&& pattern.constructor == mitos::TYPE_ID_ANY
				&& !pattern.arguments.len;
		case TYPE_PATTERN_VARIABLE:
			return mitos::source_identifier_is_valid(pattern.variable)
				&& !pattern.constructor && !pattern.arguments.len;
		case TYPE_PATTERN_EXACT:
			mitos::TypeDescriptor* exact = mitos::type_descriptor(
				&program.types, pattern.constructor
			);
			return !pattern.variable.len && exact
				&& pattern.constructor != mitos::TYPE_ID_ANY
				&& exact.kind != mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
				&& exact.kind
					!= mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
				&& !exact.arity && !pattern.arguments.len;
		case TYPE_PATTERN_APPLICATION:
			mitos::TypeDescriptor* application = mitos::type_descriptor(
				&program.types, pattern.constructor
			);
			if (pattern.variable.len || !application
				|| application.arity != pattern.arguments.len) return false;
			foreach (&argument : pattern.arguments)
			{
				if (!aot_valid_type_pattern(program, argument, depth + 1)) return false;
			}
			return true;
	}

}

fn bool aot_valid_key(mitos::DeltaProgram* program, mitos::SymbolKey* key)
{
	if (!program || !mitos::symbol_key_is_canonical(key)
		|| !mitos::source_identifier_is_valid(key.name)
		|| key.canonical_signature.len > mitos::MITOS_MAX_TYPE_FORMAT_BYTES)
	{
		return false;
	}
	mitos::ModuleKey core = { .canonical = mitos::MITOS_CORE_MODULE_CANONICAL };
	return mitos::module_key_equal(&key.owner, &program.module_key)
		|| mitos::module_key_equal(&key.owner, &core);
}

fn bool aot_valid_effect_row(
	mitos::DeltaProgram* program,
	mitos::ResolvedEffectRow* row
)
{
	if (!mitos::resolved_effect_row_is_canonical(row)) return false;
	foreach (effect : row.required)
	{
		if (!aot_valid_effect_id(program, effect)) return false;
	}
	return !row.has_tail
		|| (row.tail.kind == mitos::SymbolKind.SYMBOL_EFFECT_ROW_TAIL
			&& aot_valid_key(program, &row.tail));
}

fn bool aot_valid_method_pattern(
	mitos::DeltaProgram* program,
	mitos::MethodTypePattern* pattern,
	uint depth = 0
)
{
	if (!pattern || depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH
		|| !aot_valid_span(pattern.span)
		|| (uint)pattern.kind
			> (uint)mitos::MethodTypePatternKind.METHOD_PATTERN_APPLICATION)
	{
		return false;
	}
	switch (pattern.kind)
	{
		case METHOD_PATTERN_ANY:
			return !pattern.name.len
				&& pattern.type_id == mitos::TYPE_ID_ANY
				&& !pattern.arguments.len;
		case METHOD_PATTERN_EXACT:
			mitos::TypeDescriptor* exact = mitos::type_descriptor(
				&program.types, pattern.type_id
			);
			return !pattern.name.len && exact
				&& pattern.type_id != mitos::TYPE_ID_ANY
				&& exact.kind != mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
				&& exact.kind
					!= mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
				&& !exact.arity && !pattern.arguments.len;
		case METHOD_PATTERN_VARIABLE:
			return pattern.name.len == 1
				&& pattern.name[0] >= 'A' && pattern.name[0] <= 'Z'
				&& !pattern.type_id && !pattern.arguments.len;
		case METHOD_PATTERN_APPLICATION:
			mitos::TypeDescriptor* application = mitos::type_descriptor(
				&program.types, pattern.type_id
			);
			if (pattern.name.len || !application
				|| application.arity != pattern.arguments.len
				|| !pattern.arguments.len)
			{
				return false;
			}
			foreach (&argument : pattern.arguments)
			{
				if (!aot_valid_method_pattern(program, argument, depth + 1)) return false;
			}
			return true;
	}
}

fn int aot_compare_strings(String left, String right)
{
	usz common = left.len < right.len ? left.len : right.len;
	for (usz index = 0; index < common; index++)
	{
		uint left_character = (uint)left[index];
		uint right_character = (uint)right[index];
		if (left_character < right_character) return -1;
		if (left_character > right_character) return 1;
	}
	if (left.len < right.len) return -1;
	if (left.len > right.len) return 1;
	return 0;
}

fn int aot_compare_keys(mitos::SymbolKey* left, mitos::SymbolKey* right)
{
	int order = aot_compare_strings(left.owner.canonical, right.owner.canonical);
	if (order) return order;
	if ((uint)left.kind < (uint)right.kind) return -1;
	if ((uint)left.kind > (uint)right.kind) return 1;
	order = aot_compare_strings(left.name, right.name);
	if (order) return order;
	if (left.arity < right.arity) return -1;
	if (left.arity > right.arity) return 1;
	return aot_compare_strings(left.canonical_signature, right.canonical_signature);
}

fn void aot_sort_keys(
	mitos::SymbolKey*[] keys,
	mitos::SymbolKey*[] scratch,
	usz begin,
	usz end
)
{
	if (end - begin < 2) return;
	usz middle = begin + (end - begin) / 2;
	aot_sort_keys(keys, scratch, begin, middle);
	aot_sort_keys(keys, scratch, middle, end);
	usz left = begin;
	usz right = middle;
	usz output = begin;
	while (left < middle || right < end)
	{
		if (right >= end
			|| (left < middle && aot_compare_keys(keys[left], keys[right]) <= 0))
		{
			scratch[output++] = keys[left++];
		}
		else
		{
			scratch[output++] = keys[right++];
		}
	}
	for (usz index = begin; index < end; index++) keys[index] = scratch[index];
}

fn bool aot_keys_are_unique(
	mitos::SymbolKey*[] keys,
	Allocator allocator
)
{
	if (keys.len < 2) return true;
	mitos::SymbolKey*[] scratch = alloc::new_array(
		allocator, mitos::SymbolKey*, (sz)keys.len
	);
	defer alloc::free(allocator, scratch);
	aot_sort_keys(keys, scratch, 0, keys.len);
	for (usz index = 1; index < keys.len; index++)
	{
		if (mitos::symbol_key_equal(keys[index - 1], keys[index])) return false;
	}
	return true;
}

struct AotSignatureRenderer
{
	DString* output;
	usz length;
}

fn bool aot_signature_append(
	AotSignatureRenderer* renderer,
	String text
)
{
	if (!renderer || renderer.length > mitos::MITOS_MAX_TYPE_FORMAT_BYTES
		|| text.len > mitos::MITOS_MAX_TYPE_FORMAT_BYTES - renderer.length)
	{
		return false;
	}
	renderer.length += text.len;
	if (renderer.output) renderer.output.append_string(text);
	return true;
}

fn bool aot_signature_append_char(
	AotSignatureRenderer* renderer,
	char character
)
{
	if (!renderer
		|| renderer.length >= mitos::MITOS_MAX_TYPE_FORMAT_BYTES) return false;
	renderer.length++;
	if (renderer.output) renderer.output.append_char(character);
	return true;
}

fn bool aot_signature_append_escaped(
	AotSignatureRenderer* renderer,
	String component
)
{
	foreach (character : component)
	{
		if ((character == '\\' || character == '|' || character == ';'
				|| character == '!' || character == ',')
			&& !aot_signature_append_char(renderer, '\\')) return false;
		if (!aot_signature_append_char(renderer, character)) return false;
	}
	return true;
}

fn bool aot_signature_append_number(
	AotSignatureRenderer* renderer,
	long value
)
{
	char[32] buffer;
	return aot_signature_append(
		renderer, (String)io::bprintf(&buffer, "%d", value)!!
	);
}

fn bool aot_signature_append_length_prefixed(
	AotSignatureRenderer* renderer,
	String component
)
{
	return aot_signature_append_number(renderer, (long)component.len)
		&& aot_signature_append_char(renderer, ':')
		&& aot_signature_append(renderer, component);
}

fn bool aot_render_type_key(
	AotSignatureRenderer* renderer,
	mitos::SymbolKey* key
)
{
	return key
		&& aot_signature_append_escaped(renderer, key.owner.canonical)
		&& aot_signature_append_char(renderer, '|')
		&& aot_signature_append_escaped(renderer, key.name)
		&& aot_signature_append_char(renderer, '|')
		&& aot_signature_append_number(renderer, (long)key.arity)
		&& aot_signature_append_char(renderer, '|')
		&& aot_signature_append_escaped(renderer, key.canonical_signature);
}

fn bool aot_render_type_tuple_signature(
	mitos::DeltaProgram* program,
	mitos::TypeId[] types,
	AotSignatureRenderer* renderer
)
{
	foreach (index, type_id : types)
	{
		mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
			&program.types, type_id
		);
		if (!descriptor || (index
				&& !aot_signature_append_char(renderer, ';'))
			|| !aot_render_type_key(renderer, &descriptor.key))
		{
			return false;
		}
	}
	return true;
}

fn bool aot_type_tuple_key_is_coherent(
	mitos::DeltaProgram* program,
	mitos::TypeId[] types,
	String persisted
)
{
	AotSignatureRenderer sizing = { };
	if (!aot_render_type_tuple_signature(program, types, &sizing)
		|| sizing.length != persisted.len) return false;
	DString output;
	output.init(program.allocator);
	defer output.free();
	AotSignatureRenderer rendering = { .output = &output };
	return aot_render_type_tuple_signature(program, types, &rendering)
		&& rendering.length == sizing.length
		&& output.str_view() == persisted;
}

fn bool aot_type_tuple_key_signature(
	mitos::DeltaProgram* program,
	mitos::TypeId[] types,
	String* result
)
{
	AotSignatureRenderer sizing = { };
	if (!aot_render_type_tuple_signature(program, types, &sizing)) return false;
	DString output;
	output.init(program.allocator);
	defer output.free();
	AotSignatureRenderer rendering = { .output = &output };
	if (!aot_render_type_tuple_signature(program, types, &rendering)
		|| rendering.length != sizing.length) return false;
	*result = output.copy_str(program.allocator);
	return true;
}

fn bool aot_render_full_key_identity(
	AotSignatureRenderer* renderer,
	mitos::SymbolKey* key
)
{
	return key
		&& aot_signature_append_length_prefixed(renderer, key.owner.canonical)
		&& aot_signature_append_char(renderer, '/')
		&& aot_signature_append_number(renderer, (long)key.kind)
		&& aot_signature_append_char(renderer, '/')
		&& aot_signature_append_length_prefixed(renderer, key.name)
		&& aot_signature_append_char(renderer, '/')
		&& aot_signature_append_number(renderer, (long)key.arity)
		&& aot_signature_append_char(renderer, '/')
		&& aot_signature_append_length_prefixed(
			renderer, key.canonical_signature
		);
}

fn bool aot_full_key_identity_is_equal(
	mitos::SymbolKey* key,
	String persisted,
	Allocator allocator
)
{
	AotSignatureRenderer sizing = { };
	if (!aot_render_full_key_identity(&sizing, key)
		|| sizing.length != persisted.len) return false;
	DString output;
	output.init(allocator);
	defer output.free();
	AotSignatureRenderer rendering = { .output = &output };
	return aot_render_full_key_identity(&rendering, key)
		&& rendering.length == sizing.length
		&& output.str_view() == persisted;
}

fn bool aot_render_function_type_signature(
	mitos::DeltaProgram* program,
	mitos::TypeDescriptor* descriptor,
	mitos::SymbolKey*[] effect_keys,
	AotSignatureRenderer* renderer
)
{
	foreach (index, parameter : descriptor.function_parameters)
	{
		mitos::TypeDescriptor* type = mitos::type_descriptor(
			&program.types, parameter
		);
		if (!type || (index && !aot_signature_append_char(renderer, ';'))
			|| !aot_render_type_key(renderer, &type.key)) return false;
	}
	mitos::TypeDescriptor* result = mitos::type_descriptor(
		&program.types, descriptor.function_result
	);
	if (!result
		|| (descriptor.function_parameters.len
			&& !aot_signature_append_char(renderer, ';'))
		|| !aot_render_type_key(renderer, &result.key)
		|| !aot_signature_append_char(renderer, '!')) return false;
	foreach (index, key : effect_keys)
	{
		if ((index && !aot_signature_append_char(renderer, ','))
			|| !aot_render_full_key_identity(renderer, key)) return false;
	}
	if (descriptor.function_effects.has_tail)
	{
		return aot_signature_append(renderer, "|tail:")
			&& aot_render_full_key_identity(
				renderer, &descriptor.function_effects.tail
			);
	}
	return true;
}

fn bool aot_function_type_key_is_coherent(
	mitos::DeltaProgram* program,
	mitos::TypeDescriptor* descriptor
)
{
	mitos::SymbolKey*[] effect_keys = alloc::new_array(
		program.allocator,
		mitos::SymbolKey*,
		descriptor.function_effects.required.len
	);
	defer alloc::free(program.allocator, effect_keys);
	foreach (index, effect : descriptor.function_effects.required)
	{
		effect_keys[index] = aot_effect_key(program, effect);
		if (!effect_keys[index]) return false;
	}
	if (effect_keys.len > 1)
	{
		mitos::SymbolKey*[] scratch = alloc::new_array(
			program.allocator, mitos::SymbolKey*, (sz)effect_keys.len
		);
		defer alloc::free(program.allocator, scratch);
		aot_sort_keys(effect_keys, scratch, 0, effect_keys.len);
	}
	AotSignatureRenderer sizing = { };
	if (!aot_render_function_type_signature(
			program, descriptor, effect_keys, &sizing
		) || sizing.length != descriptor.key.canonical_signature.len)
	{
		return false;
	}
	DString output;
	output.init(program.allocator);
	defer output.free();
	AotSignatureRenderer rendering = { .output = &output };
	return aot_render_function_type_signature(
		program, descriptor, effect_keys, &rendering
	) && rendering.length == sizing.length
		&& output.str_view() == descriptor.key.canonical_signature;
}

fn usz aot_method_variable_ordinal(
	String[] variables,
	usz count,
	String name
)
{
	foreach (index, variable : variables[:(sz)count])
	{
		if (variable == name) return (usz)index;
	}
	return usz::max;
}

fn bool aot_collect_method_variables(
	mitos::MethodTypePattern* pattern,
	String[] variables,
	usz* count,
	bool allow_new,
	uint depth = 0
)
{
	if (!pattern || !count || depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH)
	{
		return false;
	}
	if (pattern.kind == mitos::MethodTypePatternKind.METHOD_PATTERN_VARIABLE)
	{
		if (aot_method_variable_ordinal(variables, *count, pattern.name)
			!= usz::max) return true;
		if (!allow_new || *count >= variables.len) return false;
		variables[*count] = pattern.name;
		(*count)++;
		return true;
	}
	foreach (&argument : pattern.arguments)
	{
		if (!aot_collect_method_variables(
			argument, variables, count, allow_new, depth + 1
		)) return false;
	}
	return true;
}

fn bool aot_render_method_pattern(
	mitos::DeltaProgram* program,
	AotSignatureRenderer* renderer,
	mitos::MethodTypePattern* pattern,
	String[] variables,
	usz variable_count,
	uint depth = 0
)
{
	if (!pattern || depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH) return false;
	switch (pattern.kind)
	{
		case METHOD_PATTERN_ANY:
			return aot_signature_append_char(renderer, '*');
		case METHOD_PATTERN_VARIABLE:
			usz ordinal = aot_method_variable_ordinal(
				variables, variable_count, pattern.name
			);
			return ordinal != usz::max
				&& aot_signature_append_char(renderer, '$')
				&& aot_signature_append_number(renderer, (long)ordinal);
		case METHOD_PATTERN_EXACT:
			mitos::TypeDescriptor* exact = mitos::type_descriptor(
				&program.types, pattern.type_id
			);
			return exact
				&& aot_signature_append_char(renderer, '=')
				&& aot_signature_append_length_prefixed(
					renderer, exact.key.owner.canonical
				)
				&& aot_signature_append_length_prefixed(
					renderer, exact.key.name
				)
				&& aot_signature_append_length_prefixed(
					renderer, exact.key.canonical_signature
				);
		case METHOD_PATTERN_APPLICATION:
			mitos::TypeDescriptor* application = mitos::type_descriptor(
				&program.types, pattern.type_id
			);
			if (!application
				|| !aot_signature_append_char(renderer, '@')
				|| !aot_signature_append_length_prefixed(
					renderer, application.key.owner.canonical
				)
				|| !aot_signature_append_length_prefixed(
					renderer, application.key.name
				)
				|| !aot_signature_append_length_prefixed(
					renderer, application.key.canonical_signature
				)
				|| !aot_signature_append_char(renderer, '[')) return false;
			foreach (&argument : pattern.arguments)
			{
				if (!aot_render_method_pattern(
						program, renderer, argument, variables,
						variable_count, depth + 1
					)
					|| !aot_signature_append_char(renderer, ';'))
				{
					return false;
				}
			}
			return aot_signature_append_char(renderer, ']');
	}
}

fn bool aot_render_method_signature(
	mitos::DeltaProgram* program,
	AotSignatureRenderer* renderer,
	mitos::MethodTypePattern[] parameters,
	String[] variables,
	usz variable_count
)
{
	if (!aot_signature_append_char(renderer, '(')) return false;
	foreach (index, &parameter : parameters)
	{
		if ((index && !aot_signature_append_char(renderer, ','))
			|| !aot_render_method_pattern(
				program, renderer, parameter, variables, variable_count
			)) return false;
	}
	return aot_signature_append_char(renderer, ')');
}

fn bool aot_method_pattern_equal(
	mitos::MethodTypePattern* left,
	mitos::MethodTypePattern* right,
	uint depth = 0
)
{
	if (!left || !right || depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH
		|| left.kind != right.kind || left.name != right.name
		|| left.type_id != right.type_id
		|| left.arguments.len != right.arguments.len) return false;
	foreach (index, &argument : left.arguments)
	{
		if (!aot_method_pattern_equal(
			argument, &right.arguments[index], depth + 1
		)) return false;
	}
	return true;
}

fn bool aot_method_metadata_is_coherent(
	mitos::DeltaProgram* program,
	mitos::GenericFunction* generic,
	mitos::MethodDescriptor* method
)
{
	if (!method || !generic
		|| method.key.kind != mitos::SymbolKind.SYMBOL_METHOD
		|| method.key.name != generic.name
		|| method.key.arity != (uint)method.parameters.len
		|| !mitos::module_key_equal(&method.key.owner, &generic.key.owner)
		|| method.type_variables.len > mitos::MITOS_MAX_METHOD_VARIABLES)
	{
		return false;
	}
	String[mitos::MITOS_MAX_METHOD_VARIABLES] variables;
	usz variable_count = 0;
	foreach (&parameter : method.parameters)
	{
		if (!aot_collect_method_variables(
			parameter, variables[..], &variable_count, true
		)) return false;
	}
	if (method.type_variables.len != variable_count) return false;
	foreach (index, variable : method.type_variables)
	{
		if (variable != variables[(usz)index]) return false;
	}
	if (!aot_collect_method_variables(
		&method.result, variables[..], &variable_count, false
	)) return false;
	AotSignatureRenderer sizing = { };
	if (!aot_render_method_signature(
			program, &sizing, method.parameters, variables[..], variable_count
		) || sizing.length != method.key.canonical_signature.len)
	{
		return false;
	}
	DString output;
	output.init(program.allocator);
	defer output.free();
	AotSignatureRenderer rendering = { .output = &output };
	return aot_render_method_signature(
		program, &rendering, method.parameters, variables[..], variable_count
	) && rendering.length == sizing.length
		&& output.str_view() == method.key.canonical_signature;
}

fn bool aot_operation_key_signature_is_coherent(
	mitos::DeltaProgram* program,
	mitos::DeltaEffectDescriptor* effect,
	mitos::DeltaOperationDescriptor* operation
)
{
	return effect && operation && aot_full_key_identity_is_equal(
		&effect.key, operation.key.canonical_signature, program.allocator
	);
}

fn bool aot_render_effect_instance_signature(
	mitos::DeltaProgram* program,
	mitos::TypeId[] arguments,
	AotSignatureRenderer* renderer
)
{
	foreach (argument : arguments)
	{
		mitos::TypeDescriptor* type = mitos::type_descriptor(
			&program.types, argument
		);
		if (!type
			|| !aot_signature_append_length_prefixed(
				renderer, type.key.owner.canonical
			)
			|| !aot_signature_append_length_prefixed(
				renderer, type.key.name
			)
			|| !aot_signature_append_length_prefixed(
				renderer, type.key.canonical_signature
			)) return false;
	}
	return true;
}

fn bool aot_effect_instance_key_signature_is_coherent(
	mitos::DeltaProgram* program,
	mitos::DeltaEffectInstanceDescriptor* instance
)
{
	AotSignatureRenderer sizing = { };
	if (!aot_render_effect_instance_signature(
			program, instance.arguments, &sizing
		) || sizing.length != instance.key.canonical_signature.len)
	{
		return false;
	}
	DString output;
	output.init(program.allocator);
	defer output.free();
	AotSignatureRenderer rendering = { .output = &output };
	return aot_render_effect_instance_signature(
		program, instance.arguments, &rendering
	) && rendering.length == sizing.length
		&& output.str_view() == instance.key.canonical_signature;
}

fn bool aot_constructor_key_is_coherent(
	mitos::DeltaProgram* program,
	mitos::DeltaConstructorDescriptor* constructor
)
{
	mitos::TypeDescriptor* parent = mitos::type_descriptor(
		&program.types, constructor.type_constructor
	);
	if (!parent
		|| !mitos::module_key_equal(&constructor.key.owner, &parent.key.owner)
		|| constructor.key.name != constructor.name
		|| constructor.parameters.len != parent.parameters.len
		|| (constructor.parameters.len
			? constructor.runtime_type != mitos::TYPE_ID_INVALID
			: constructor.runtime_type != constructor.type_constructor))
	{
		return false;
	}
	foreach (index, parameter : constructor.parameters)
	{
		if (!parameter.len || parameter != parent.parameters[index]) return false;
	}
	if (parent.key.kind == mitos::SymbolKind.SYMBOL_ENUM)
	{
		if (constructor.key.kind != mitos::SymbolKind.SYMBOL_VARIANT
			|| constructor.key.arity != (uint)constructor.fields.len)
		{
			return false;
		}
		return aot_full_key_identity_is_equal(
			&parent.key, constructor.key.canonical_signature, program.allocator
		);
	}
	if (parent.key.kind != mitos::SymbolKind.SYMBOL_TYPE
		|| !mitos::symbol_key_equal(&constructor.key, &parent.key)
		|| constructor.fields.len != parent.fields.len)
	{
		return false;
	}
	foreach (index, field : constructor.fields)
	{
		if (!field.len || field != parent.fields[index].name
			|| constructor.field_types[index] != parent.fields[index].declared_type
			|| !aot_type_patterns_equal(
				&constructor.field_patterns[index],
				&parent.fields[index].pattern
			))
		{
			return false;
		}
	}
	return true;
}

fn bool aot_type_descriptor_key_is_coherent(
	mitos::DeltaProgram* program,
	mitos::TypeDescriptor* descriptor
)
{
	if (descriptor.key.name != descriptor.name) return false;
	switch (descriptor.kind)
	{
		case TYPE_DESCRIPTOR_ABSTRACT:
		case TYPE_DESCRIPTOR_CONCRETE:
			return (descriptor.key.kind == mitos::SymbolKind.SYMBOL_TYPE
					|| descriptor.key.kind == mitos::SymbolKind.SYMBOL_ENUM)
				&& descriptor.key.arity == (uint)descriptor.arity
				&& !descriptor.key.canonical_signature.len
				&& (descriptor.id <= mitos::TYPE_ID_SUPERPOSITION
					? !descriptor.parameters.len
					: descriptor.parameters.len == descriptor.arity)
				&& !descriptor.constructor && !descriptor.arguments.len
				&& !descriptor.function_parameters.len
				&& !descriptor.function_result
				&& !descriptor.function_effects.required.len
				&& !descriptor.function_effects.has_tail;
		case TYPE_DESCRIPTOR_INSTANCE:
			mitos::TypeDescriptor* constructor = mitos::type_descriptor(
				&program.types, descriptor.constructor
			);
			if (!constructor
				|| descriptor.key.kind != mitos::SymbolKind.SYMBOL_TYPE
				|| !mitos::module_key_equal(
					&descriptor.key.owner, &constructor.key.owner
				)
				|| descriptor.name != constructor.name
				|| descriptor.nominal_parent != constructor.nominal_parent
				|| descriptor.key.arity != (uint)descriptor.arguments.len
				|| descriptor.parameters.len || descriptor.arity
				|| descriptor.fields.len
				|| descriptor.function_parameters.len
				|| descriptor.function_result
				|| descriptor.function_effects.required.len
				|| descriptor.function_effects.has_tail) return false;
			return aot_type_tuple_key_is_coherent(
				program, descriptor.arguments,
				descriptor.key.canonical_signature
			);
		case TYPE_DESCRIPTOR_FUNCTION_INSTANCE:
			mitos::TypeDescriptor* function = mitos::type_descriptor(
				&program.types, mitos::TYPE_ID_FUNCTION
			);
			if (!function
				|| descriptor.key.kind != mitos::SymbolKind.SYMBOL_TYPE
				|| !mitos::module_key_equal(
					&descriptor.key.owner, &function.key.owner
				)
				|| descriptor.name != function.name
				|| descriptor.key.arity
					!= (uint)descriptor.function_parameters.len) return false;
			return aot_function_type_key_is_coherent(program, descriptor);
	}
}

fn void aot_sort_strings(
	String*[] values,
	String*[] scratch,
	usz begin,
	usz end
)
{
	if (end - begin < 2) return;
	usz middle = begin + (end - begin) / 2;
	aot_sort_strings(values, scratch, begin, middle);
	aot_sort_strings(values, scratch, middle, end);
	usz left = begin;
	usz right = middle;
	usz output = begin;
	while (left < middle || right < end)
	{
		if (right >= end || (left < middle
				&& aot_compare_strings(*values[left], *values[right]) <= 0))
		{
			scratch[output++] = values[left++];
		}
		else
		{
			scratch[output++] = values[right++];
		}
	}
	for (usz index = begin; index < end; index++) values[index] = scratch[index];
}

fn bool aot_strings_are_unique_nonempty(
	String[] values,
	Allocator allocator
)
{
	if (!values.len) return true;
	String*[] pointers = alloc::new_array(allocator, String*, (sz)values.len);
	defer alloc::free(allocator, pointers);
	String*[] scratch = alloc::new_array(allocator, String*, (sz)values.len);
	defer alloc::free(allocator, scratch);
	foreach (index, &value : values)
	{
		if (!mitos::source_identifier_is_valid(*value)) return false;
		pointers[(usz)index] = value;
	}
	aot_sort_strings(pointers, scratch, 0, pointers.len);
	for (usz index = 1; index < pointers.len; index++)
	{
		if (*pointers[index - 1] == *pointers[index]) return false;
	}
	return true;
}

fn bool aot_type_patterns_equal(
	mitos::TypePattern* left,
	mitos::TypePattern* right,
	uint depth = 0
)
{
	if (!left || !right || depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH
		|| left.kind != right.kind || left.variable != right.variable
		|| left.constructor != right.constructor
		|| left.span.start.offset != right.span.start.offset
		|| left.span.start.row != right.span.start.row
		|| left.span.start.column != right.span.start.column
		|| left.span.end.offset != right.span.end.offset
		|| left.span.end.row != right.span.end.row
		|| left.span.end.column != right.span.end.column
		|| left.arguments.len != right.arguments.len)
	{
		return false;
	}
	foreach (index, &argument : left.arguments)
	{
		if (!aot_type_patterns_equal(
			argument, &right.arguments[index], depth + 1
		)) return false;
	}
	return true;
}

fn int aot_compare_nominal_types(
	mitos::TypeDescriptor* left,
	mitos::TypeDescriptor* right
)
{
	int order = aot_compare_strings(
		left.key.owner.canonical, right.key.owner.canonical
	);
	return order ? order : aot_compare_strings(left.name, right.name);
}

fn void aot_sort_nominal_types(
	mitos::TypeDescriptor*[] values,
	mitos::TypeDescriptor*[] scratch,
	usz begin,
	usz end
)
{
	if (end - begin < 2) return;
	usz middle = begin + (end - begin) / 2;
	aot_sort_nominal_types(values, scratch, begin, middle);
	aot_sort_nominal_types(values, scratch, middle, end);
	usz left = begin;
	usz right = middle;
	usz output = begin;
	while (left < middle || right < end)
	{
		if (right >= end || (left < middle
				&& aot_compare_nominal_types(values[left], values[right]) <= 0))
		{
			scratch[output++] = values[left++];
		}
		else
		{
			scratch[output++] = values[right++];
		}
	}
	for (usz index = begin; index < end; index++) values[index] = scratch[index];
}

fn bool aot_nominal_type_names_are_unique(
	mitos::TypeRegistry* registry,
	Allocator allocator
)
{
	usz count = 0;
	foreach (&descriptor : registry.descriptors)
	{
		if (descriptor.kind != mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
			&& descriptor.kind
				!= mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
		{
			count++;
		}
	}
	mitos::TypeDescriptor*[] values = alloc::new_array(
		allocator, mitos::TypeDescriptor*, (sz)count
	);
	defer alloc::free(allocator, values);
	mitos::TypeDescriptor*[] scratch = alloc::new_array(
		allocator, mitos::TypeDescriptor*, (sz)count
	);
	defer alloc::free(allocator, scratch);
	usz cursor = 0;
	foreach (&descriptor : registry.descriptors)
	{
		if (descriptor.kind != mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
			&& descriptor.kind
				!= mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
		{
			values[cursor++] = descriptor;
		}
	}
	aot_sort_nominal_types(values, scratch, 0, values.len);
	for (usz index = 1; index < values.len; index++)
	{
		if (mitos::module_key_equal(
				&values[index - 1].key.owner, &values[index].key.owner
			) && values[index - 1].name == values[index].name) return false;
	}
	return true;
}

fn bool aot_nominal_hierarchy_is_valid(
	mitos::TypeRegistry* registry,
	Allocator allocator
)
{
	usz count = (usz)registry.descriptors.len();
	char[] colors = alloc::new_array(allocator, char, (sz)(count + 1));
	defer alloc::free(allocator, colors);
	mitos::TypeId[] path = alloc::new_array(
		allocator, mitos::TypeId, (sz)count
	);
	defer alloc::free(allocator, path);
	foreach (&color : colors) *color = 0;
	for (mitos::TypeId start = (mitos::TypeId)1;
		(usz)start <= count; start++)
	{
		if (colors[(usz)start] == 2) continue;
		usz path_length = 0;
		mitos::TypeId current = start;
		while (current)
		{
			if ((usz)current > count || colors[(usz)current] == 1) return false;
			if (colors[(usz)current] == 2) break;
			colors[(usz)current] = 1;
			path[path_length++] = current;
			mitos::TypeDescriptor* descriptor =
				mitos::type_descriptor(registry, current);
			if (!descriptor) return false;
			current = descriptor.nominal_parent;
		}
		foreach (visited : path[:(sz)path_length])
			colors[(usz)visited] = 2;
	}
	return true;
}

fn bool aot_checked_layout_add(ulong left, ulong right, ulong* result)
{
	if (right > ulong::max - left) return false;
	*result = left + right;
	return true;
}

fn bool aot_checked_layout_align(
	ulong value,
	ulong alignment,
	ulong* result
)
{
	if (!alignment || (alignment & (alignment - 1))) return false;
	ulong remainder = value & (alignment - 1);
	if (!remainder)
	{
		*result = value;
		return true;
	}
	return aot_checked_layout_add(value, alignment - remainder, result);
}

fn mitos::CopyPolicy aot_combined_copy_policy(
	mitos::CopyPolicy current,
	mitos::CopyPolicy field
)
{
	if (current == mitos::CopyPolicy.COPY_BORROWED
		|| field == mitos::CopyPolicy.COPY_BORROWED)
	{
		return mitos::CopyPolicy.COPY_BORROWED;
	}
	if (current == mitos::CopyPolicy.COPY_AFFINE
		|| field == mitos::CopyPolicy.COPY_AFFINE)
	{
		return mitos::CopyPolicy.COPY_AFFINE;
	}
	if (current == mitos::CopyPolicy.COPY_SHARED_IMMUTABLE
		|| field == mitos::CopyPolicy.COPY_SHARED_IMMUTABLE)
	{
		return mitos::CopyPolicy.COPY_SHARED_IMMUTABLE;
	}
	return mitos::CopyPolicy.COPY_TRIVIAL;
}

fn bool aot_layout_pattern_type(
	mitos::DeltaProgram* program,
	mitos::TypeDescriptor* base,
	mitos::TypeId[] arguments,
	mitos::TypePattern* pattern,
	mitos::TypeId* result,
	uint depth = 0
)
{
	if (!pattern || depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH) return false;
	switch (pattern.kind)
	{
		case TYPE_PATTERN_ANY:
			*result = mitos::TYPE_ID_ANY;
			return true;
		case TYPE_PATTERN_EXACT:
			*result = pattern.constructor;
			return aot_valid_type(program, *result);
		case TYPE_PATTERN_VARIABLE:
			foreach (index, parameter : base.parameters)
			{
				if (parameter == pattern.variable)
				{
					if ((usz)index >= arguments.len) return false;
					*result = arguments[(usz)index];
					return aot_valid_type(program, *result);
				}
			}
			return false;
		case TYPE_PATTERN_APPLICATION:
			mitos::TypeId[] resolved_arguments = alloc::new_array(
				program.allocator, mitos::TypeId, pattern.arguments.len
			);
			defer alloc::free(program.allocator, resolved_arguments);
			foreach (index, &argument : pattern.arguments)
			{
				if (!aot_layout_pattern_type(
					program, base, arguments, argument,
					&resolved_arguments[index], depth + 1
				)) return false;
			}
			mitos::TypeDescriptor* constructor = mitos::type_descriptor(
				&program.types, pattern.constructor
			);
			if (!constructor
				|| constructor.kind
					== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
				|| constructor.kind
					== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
				|| constructor.arity != resolved_arguments.len) return false;
			String signature;
			if (!aot_type_tuple_key_signature(
				program, resolved_arguments, &signature
			)) return false;
			defer alloc::free(program.allocator, signature);
			mitos::SymbolKey key = mitos::symbol_key(
				&constructor.key.owner,
				mitos::SymbolKind.SYMBOL_TYPE,
				constructor.name,
				resolved_arguments.len,
				signature,
				program.allocator
			);
			defer key.deinit(program.allocator);
			mitos::TypeId resolved = mitos::find_type_by_key(
				&program.types, &key
			);
			mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
				&program.types, resolved
			);
			if (!descriptor
				|| descriptor.kind
					!= mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
				|| descriptor.constructor != pattern.constructor
				|| descriptor.arguments.len != resolved_arguments.len)
			{
				return false;
			}
			foreach (index, argument : descriptor.arguments)
			{
				if (argument != resolved_arguments[(usz)index]) return false;
			}
			*result = resolved;
			return true;
	}
}

fn void aot_make_expected_unsized(
	mitos::LayoutDescriptor* layout,
	mitos::CopyPolicy policy
)
{
	layout.kind = mitos::LayoutKind.LAYOUT_UNSIZED;
	layout.copy_policy = policy;
	layout.sized = false;
	layout.size = 0;
	layout.alignment = 1;
	layout.stride = 0;
	layout.element_type = mitos::TYPE_ID_INVALID;
}

fn bool aot_derive_expected_tagged_layout(
	mitos::DeltaProgram* program,
	mitos::TypeDescriptor* base,
	mitos::TypeId[] arguments,
	mitos::CopyPolicy blocked_policy,
	mitos::LayoutDescriptor* result
)
{
	if (!base || base.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_ABSTRACT
		|| base.parameters.len != arguments.len) return false;
	ulong size = 4;
	ulong alignment = 4;
	mitos::CopyPolicy policy = mitos::CopyPolicy.COPY_TRIVIAL;
	bool blocked = false;
	foreach (&field : base.fields)
	{
		mitos::TypeId field_type = field.declared_type;
		if (!field_type || field_type == mitos::TYPE_ID_ANY)
		{
			if (!aot_layout_pattern_type(
				program, base, arguments, &field.pattern, &field_type
			)) return false;
		}
		mitos::TypeDescriptor* field_descriptor =
			mitos::type_descriptor(&program.types, field_type);
		if (!field_descriptor
			|| !mitos::layout_descriptor_is_valid(&field_descriptor.layout))
		{
			return false;
		}
		if (!field_descriptor.layout.sized)
		{
			blocked = true;
			continue;
		}
		if (blocked) continue;
		ulong field_offset;
		if (!aot_checked_layout_align(
				size, field_descriptor.layout.alignment, &field_offset
			) || !aot_checked_layout_add(
				field_offset, field_descriptor.layout.size, &size
			)) return false;
		if (field_descriptor.layout.alignment > alignment)
		{
			alignment = field_descriptor.layout.alignment;
		}
		policy = aot_combined_copy_policy(
			policy, field_descriptor.layout.copy_policy
		);
	}
	if (blocked)
	{
		aot_make_expected_unsized(result, blocked_policy);
		return true;
	}
	ulong stride;
	if (!aot_checked_layout_align(size, alignment, &stride)) return false;
	result.kind = mitos::LayoutKind.LAYOUT_TAGGED_RECORD;
	result.copy_policy = policy;
	result.sized = true;
	result.size = size;
	result.alignment = alignment;
	result.stride = stride ? stride : alignment;
	result.element_type = mitos::TYPE_ID_INVALID;
	return true;
}

fn bool aot_layout_shape_equal(
	mitos::LayoutDescriptor* left,
	mitos::LayoutDescriptor* right
)
{
	return left.kind == right.kind
		&& left.copy_policy == right.copy_policy
		&& left.sized == right.sized
		&& left.size == right.size
		&& left.alignment == right.alignment
		&& left.stride == right.stride
		&& left.element_type == right.element_type;
}

fn bool aot_custom_layout_is_coherent(
	mitos::DeltaProgram* program,
	mitos::TypeDescriptor* descriptor
)
{
	if (descriptor.id <= mitos::TYPE_ID_SUPERPOSITION) return true;
	mitos::LayoutDescriptor expected = { };
	switch (descriptor.kind)
	{
		case TYPE_DESCRIPTOR_ABSTRACT:
			aot_make_expected_unsized(
				&expected, mitos::CopyPolicy.COPY_BORROWED
			);
		case TYPE_DESCRIPTOR_CONCRETE:
			if (descriptor.key.kind == mitos::SymbolKind.SYMBOL_ENUM)
			{
				if (descriptor.fields.len) return false;
				aot_make_expected_unsized(
					&expected, mitos::CopyPolicy.COPY_AFFINE
				);
			}
			else if (descriptor.parameters.len)
			{
				aot_make_expected_unsized(
					&expected, mitos::CopyPolicy.COPY_AFFINE
				);
			}
			else if (!aot_derive_expected_tagged_layout(
				program, descriptor, { }, mitos::CopyPolicy.COPY_AFFINE,
				&expected
			)) return false;
		case TYPE_DESCRIPTOR_INSTANCE:
			mitos::TypeDescriptor* base = mitos::type_descriptor(
				&program.types, descriptor.constructor
			);
			if (!base) return false;
			expected = base.layout;
			if (base.layout.kind == mitos::LayoutKind.LAYOUT_SEQUENCE
				&& descriptor.arguments.len)
			{
				expected.element_type = descriptor.arguments[0];
			}
			else if (base.fields.len)
			{
				if (!aot_derive_expected_tagged_layout(
					program, base, descriptor.arguments,
					base.layout.copy_policy, &expected
				)) return false;
			}
		case TYPE_DESCRIPTOR_FUNCTION_INSTANCE:
			mitos::TypeDescriptor* function = mitos::type_descriptor(
				&program.types, mitos::TYPE_ID_FUNCTION
			);
			if (!function) return false;
			expected = function.layout;
	}
	return aot_layout_shape_equal(&descriptor.layout, &expected);
}

fn bool aot_append_bounded_type_text(DString* output, String text)
{
	usz length = output.str_view().len;
	if (length > mitos::MITOS_MAX_TYPE_FORMAT_BYTES
		|| text.len > mitos::MITOS_MAX_TYPE_FORMAT_BYTES - length)
	{
		return false;
	}
	output.append_string(text);
	return true;
}

fn bool aot_append_resolved_type_pattern(
	mitos::DeltaProgram* program,
	DString* output,
	mitos::TypePattern* pattern,
	uint depth = 0
)
{
	if (!pattern || depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH) return false;
	if (pattern.kind == mitos::TypePatternKind.TYPE_PATTERN_VARIABLE)
	{
		return aot_append_bounded_type_text(output, pattern.variable);
	}
	mitos::TypeId constructor = pattern.kind
		== mitos::TypePatternKind.TYPE_PATTERN_ANY
		? mitos::TYPE_ID_ANY : pattern.constructor;
	mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
		&program.types, constructor
	);
	if (!descriptor
		|| !aot_append_bounded_type_text(output, descriptor.name)) return false;
	if (pattern.kind != mitos::TypePatternKind.TYPE_PATTERN_APPLICATION)
	{
		return true;
	}
	if (!aot_append_bounded_type_text(output, " of ")) return false;
	if (pattern.arguments.len > 1
		&& !aot_append_bounded_type_text(output, "(")) return false;
	foreach (index, &argument : pattern.arguments)
	{
		if (index && !aot_append_bounded_type_text(output, ", ")) return false;
		if (!aot_append_resolved_type_pattern(
			program, output, argument, depth + 1
		)) return false;
	}
	return pattern.arguments.len <= 1
		|| aot_append_bounded_type_text(output, ")");
}

fn bool aot_effect_pattern_text_is_coherent(
	mitos::DeltaProgram* program,
	String text,
	mitos::TypePattern* pattern
)
{
	DString formatted;
	formatted.init(program.allocator);
	defer formatted.free();
	return aot_append_resolved_type_pattern(
		program, &formatted, pattern
	) && text == formatted.str_view();
}

fn void aot_sort_u64(ulong[] values, ulong[] scratch, usz begin, usz end)
{
	if (end - begin < 2) return;
	usz middle = begin + (end - begin) / 2;
	aot_sort_u64(values, scratch, begin, middle);
	aot_sort_u64(values, scratch, middle, end);
	usz left = begin;
	usz right = middle;
	usz output = begin;
	while (left < middle || right < end)
	{
		if (right >= end || (left < middle && values[left] <= values[right]))
		{
			scratch[output++] = values[left++];
		}
		else
		{
			scratch[output++] = values[right++];
		}
	}
	for (usz index = begin; index < end; index++) values[index] = scratch[index];
}

fn bool aot_effect_type_matches(
	mitos::DeltaProgram* program,
	mitos::DeltaEffectDescriptor* effect,
	mitos::DeltaEffectInstanceDescriptor* instance,
	mitos::TypePattern* pattern,
	mitos::TypeId actual,
	uint depth = 0
)
{
	if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH
		|| (uint)pattern.kind > (uint)mitos::TypePatternKind.TYPE_PATTERN_APPLICATION
		|| !aot_valid_type(program, actual)) return false;
	switch (pattern.kind)
	{
		case TYPE_PATTERN_ANY: return actual == mitos::TYPE_ID_ANY;
		case TYPE_PATTERN_EXACT: return actual == pattern.constructor;
		case TYPE_PATTERN_VARIABLE:
			foreach (index, parameter : effect.parameters)
			{
				if (parameter == pattern.variable)
				{
					return instance && index < instance.arguments.len
						&& actual == instance.arguments[index];
				}
			}
			return false;
		case TYPE_PATTERN_APPLICATION:
			mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
				&program.types, actual
			);
			if (!descriptor
				|| descriptor.kind != mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
				|| descriptor.constructor != pattern.constructor
				|| descriptor.arguments.len != pattern.arguments.len) return false;
			foreach (index, &argument : pattern.arguments)
			{
				if (!aot_effect_type_matches(
					program, effect, instance, argument,
					descriptor.arguments[index], depth + 1
				)) return false;
			}
			return true;
	}

}
fn mitos::DeltaEffectHostKind aot_expected_host_kind(
	mitos::DeltaEffectDescriptor* effect
)
{
	if (effect.name == "Console" || effect.name == "IO")
	{
		return mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL;
	}
	if (effect.name == "State")
	{
		return mitos::DeltaEffectHostKind.DELTA_EFFECT_ORDERED;
	}
	return mitos::DeltaEffectHostKind.DELTA_EFFECT_PURE;
}

fn bool aot_valid_abort_node(
	mitos::DeltaProgram* program,
	mitos::DeltaNode* node
)
{
	if (node.descriptor >= program.effects.handlers.len
		|| node.inputs.len != 1 || node.integer <= 0
		|| (ulong)node.integer > (ulong)uint::max)
	{
		return false;
	}
	mitos::DeltaHandlerDescriptor* handler =
		&program.effects.handlers[node.descriptor];
	foreach (&clause : handler.clauses)
	{
		if ((uint)clause.body == node.stable_id
			&& clause.operation == (mitos::OperationId)node.integer
			&& mitos::symbol_key_equal(&node.key, &clause.key))
		{
			return true;
		}
	}
	return false;
}

fn bool aot_valid_effect_node(
	mitos::DeltaProgram* program,
	mitos::DeltaNode* node
)
{
	if (node.descriptor >= program.effects.operations.len
		|| node.integer <= 0 || (ulong)node.integer > (ulong)uint::max)
	{
		return false;
	}
	mitos::DeltaOperationDescriptor* operation =
		&program.effects.operations[node.descriptor];
	mitos::DeltaEffectDescriptor* effect =
		aot_effect_descriptor(program, operation.effect);
	mitos::EffectId concrete = (mitos::EffectId)node.integer;
	mitos::DeltaEffectInstanceDescriptor* instance =
		aot_effect_instance(program, concrete);
	if (!effect || node.inputs.len != operation.parameter_types.len
		|| node.types.len != node.inputs.len + 1
		|| !mitos::symbol_key_equal(&node.key, &operation.key)
		|| node.name != operation.name
		|| node.static_type != node.result_type)
	{
		return false;
	}
	if (effect.parameters.len)
	{
		if (!instance || instance.constructor != effect.id
			|| instance.arguments.len != effect.parameters.len) return false;
	}
	else if (concrete != effect.id || instance)
	{
		return false;
	}
	foreach (index, &pattern : operation.parameter_types)
	{
		if (!aot_effect_type_matches(
			program, effect, instance, pattern, node.types[index]
		)) return false;
	}
	return aot_effect_type_matches(
		program, effect, instance, &operation.result_type,
		node.types[node.types.len - 1]
	) && node.types[node.types.len - 1] == node.result_type;
}

fn bool aot_builtin_layout_exact(
	mitos::TypeId id,
	mitos::LayoutDescriptor* layout
)
{
	if (!layout || layout.element_type != mitos::TYPE_ID_INVALID) return false;
	switch (id)
	{
		case mitos::TYPE_ID_ANY:
			return layout.kind == mitos::LayoutKind.LAYOUT_UNSIZED
				&& layout.copy_policy == mitos::CopyPolicy.COPY_BORROWED
				&& !layout.sized && !layout.size && layout.alignment == 1 && !layout.stride;
		case mitos::TYPE_ID_NEVER:
			return layout.kind == mitos::LayoutKind.LAYOUT_UNSIZED
				&& layout.copy_policy == mitos::CopyPolicy.COPY_TRIVIAL
				&& !layout.sized && !layout.size && layout.alignment == 1 && !layout.stride;
		case mitos::TYPE_ID_TYPE:
			return layout.kind == mitos::LayoutKind.LAYOUT_SCALAR
				&& layout.copy_policy == mitos::CopyPolicy.COPY_TRIVIAL
				&& layout.sized && layout.size == 4 && layout.alignment == 4
				&& layout.stride == 4;
		case mitos::TYPE_ID_I64:
			return layout.kind == mitos::LayoutKind.LAYOUT_SCALAR
				&& layout.copy_policy == mitos::CopyPolicy.COPY_TRIVIAL
				&& layout.sized && layout.size == 8 && layout.alignment == 8
				&& layout.stride == 8;
		case mitos::TYPE_ID_BOOL:
			return layout.kind == mitos::LayoutKind.LAYOUT_SCALAR
				&& layout.copy_policy == mitos::CopyPolicy.COPY_TRIVIAL
				&& layout.sized && layout.size == 1 && layout.alignment == 1
				&& layout.stride == 1;
		case mitos::TYPE_ID_UNIT:
			return layout.kind == mitos::LayoutKind.LAYOUT_SCALAR
				&& layout.copy_policy == mitos::CopyPolicy.COPY_TRIVIAL
				&& layout.sized && !layout.size && layout.alignment == 1
				&& layout.stride == 1;
		case mitos::TYPE_ID_STRING:
		case mitos::TYPE_ID_ARRAY:
		case mitos::TYPE_ID_SUPERPOSITION:
			return layout.kind == mitos::LayoutKind.LAYOUT_SEQUENCE
				&& layout.copy_policy == mitos::CopyPolicy.COPY_SHARED_IMMUTABLE
				&& !layout.sized && !layout.size && layout.alignment == 1 && !layout.stride;
		case mitos::TYPE_ID_FUNCTION:
			return layout.kind == mitos::LayoutKind.LAYOUT_CALLABLE
				&& layout.copy_policy == mitos::CopyPolicy.COPY_AFFINE
				&& !layout.sized && !layout.size && layout.alignment == 1 && !layout.stride;
		default: return false;
	}
}

fn bool aot_valid_builtin_descriptor(
	mitos::DeltaProgram* program,
	mitos::TypeId id,
	String name,
	mitos::TypeDescriptorKind kind,
	mitos::TypeId parent,
	usz arity
)
{
	mitos::TypeDescriptor* descriptor = mitos::type_descriptor(&program.types, id);
	mitos::ModuleKey core = { .canonical = mitos::MITOS_CORE_MODULE_CANONICAL };
	return descriptor != null
		&& descriptor.id == id
		&& descriptor.kind == kind
		&& descriptor.name == name
		&& descriptor.nominal_parent == parent
		&& descriptor.arity == arity
		&& descriptor.key.kind == mitos::SymbolKind.SYMBOL_TYPE
		&& mitos::module_key_equal(&descriptor.key.owner, &core)
		&& descriptor.key.name == name
		&& descriptor.key.arity == (uint)arity
		&& !descriptor.key.canonical_signature.len
		&& aot_builtin_layout_exact(id, &descriptor.layout)
		&& mitos::symbol_key_equal(&descriptor.layout.stable_key, &descriptor.key)
		&& !descriptor.parameters.len
		&& !descriptor.constructor
		&& !descriptor.arguments.len
		&& !descriptor.fields.len
		&& !descriptor.function_parameters.len
		&& !descriptor.function_result
		&& !descriptor.function_effects.required.len
		&& !descriptor.function_effects.has_tail;
}

fn bool aot_valid_superposition_bootstrap(mitos::DeltaProgram* program)
{
	return (usz)program.types.descriptors.len() >= (usz)mitos::TYPE_ID_SUPERPOSITION
		&& aot_valid_builtin_descriptor(program, mitos::TYPE_ID_ANY, "Any", mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_ABSTRACT, mitos::TYPE_ID_INVALID, 0)
		&& aot_valid_builtin_descriptor(program, mitos::TYPE_ID_NEVER, "Never", mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_CONCRETE, mitos::TYPE_ID_ANY, 0)
		&& aot_valid_builtin_descriptor(program, mitos::TYPE_ID_TYPE, "Type", mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_CONCRETE, mitos::TYPE_ID_ANY, 1)
		&& aot_valid_builtin_descriptor(program, mitos::TYPE_ID_I64, "I64", mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_CONCRETE, mitos::TYPE_ID_ANY, 0)
		&& aot_valid_builtin_descriptor(program, mitos::TYPE_ID_BOOL, "Bool", mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_CONCRETE, mitos::TYPE_ID_ANY, 0)
		&& aot_valid_builtin_descriptor(program, mitos::TYPE_ID_UNIT, "Unit", mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_CONCRETE, mitos::TYPE_ID_ANY, 0)
		&& aot_valid_builtin_descriptor(program, mitos::TYPE_ID_STRING, "String", mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_CONCRETE, mitos::TYPE_ID_ANY, 0)
		&& aot_valid_builtin_descriptor(program, mitos::TYPE_ID_ARRAY, "Array", mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_CONCRETE, mitos::TYPE_ID_ANY, 1)
		&& aot_valid_builtin_descriptor(program, mitos::TYPE_ID_FUNCTION, "Function", mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_CONCRETE, mitos::TYPE_ID_ANY, 0)
		&& aot_valid_builtin_descriptor(program, mitos::TYPE_ID_SUPERPOSITION, "Superposition", mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_CONCRETE, mitos::TYPE_ID_ANY, 1);
}

fn bool aot_valid_unary_runtime_type(
	mitos::DeltaProgram* program,
	mitos::TypeId runtime_type,
	mitos::TypeId constructor,
	mitos::TypeId argument
)
{
	mitos::TypeDescriptor* descriptor = mitos::type_descriptor(&program.types, runtime_type);
	return descriptor != null
		&& descriptor.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
		&& descriptor.constructor == constructor
		&& descriptor.arguments.len == 1
		&& descriptor.arguments[0] == argument;
}

fn mitos::TypeId aot_node_metadata_type(
	mitos::DeltaProgram* program,
	mitos::DeltaNodeId node_id
)
{
	if (!aot_valid_node(program, node_id)) return mitos::TYPE_ID_INVALID;
	mitos::DeltaNode* node = &program.image.nodes[(usz)node_id - 1];
	return node.kind == mitos::DeltaNodeKind.DELTA_SUPERPOSE
		? node.result_type
		: (node.runtime_type ? node.runtime_type : node.static_type);
}
fn bool aot_match_scrutinee_type_is_compatible(
	mitos::DeltaProgram* program,
	mitos::DeltaNodeId scrutinee,
	mitos::TypeId match_type
)
{
	mitos::TypeId actual = aot_node_metadata_type(program, scrutinee);
	if (actual == mitos::TYPE_ID_ANY) return true;
	mitos::TypeDescriptor* descriptor = mitos::type_descriptor(
		&program.types, actual
	);
	if (!descriptor) return false;
	if (descriptor.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE)
	{
		return descriptor.constructor == match_type;
	}
	if (descriptor.kind
		== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
	{
		return false;
	}
	if (descriptor.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_ABSTRACT)
	{
		return mitos::type_is_subtype(&program.types, match_type, actual);
	}
	return actual == match_type;
}


fn bool aot_constructor_pattern_matches(
	mitos::DeltaProgram* program,
	mitos::DeltaConstructorDescriptor* constructor,
	mitos::TypeDescriptor* instance,
	mitos::TypePattern* pattern,
	mitos::TypeId actual,
	uint depth = 0
)
{
	if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH
		|| !aot_valid_type(program, actual)) return false;
	switch (pattern.kind)
	{
		case TYPE_PATTERN_ANY: return true;
		case TYPE_PATTERN_EXACT:
			return mitos::type_is_subtype(
				&program.types, actual, pattern.constructor
			);
		case TYPE_PATTERN_VARIABLE:
			foreach (index, parameter : constructor.parameters)
			{
				if (parameter == pattern.variable)
				{
					return instance && index < instance.arguments.len
						&& actual == instance.arguments[index];
				}
			}
			return false;
		case TYPE_PATTERN_APPLICATION:
			mitos::TypeDescriptor* actual_descriptor = mitos::type_descriptor(
				&program.types, actual
			);
			if (!actual_descriptor
				|| actual_descriptor.kind
					!= mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
				|| actual_descriptor.constructor != pattern.constructor
				|| actual_descriptor.arguments.len != pattern.arguments.len)
			{
				return false;
			}
			foreach (index, &argument : pattern.arguments)
			{
				if (!aot_constructor_pattern_matches(
					program,
					constructor,
					instance,
					argument,
					actual_descriptor.arguments[index],
					depth + 1
				)) return false;
			}
			return true;
	}
}

fn bool aot_constructor_node_type_is_exact(
	mitos::DeltaProgram* program,
	mitos::DeltaConstructorDescriptor* constructor,
	mitos::DeltaNode* node
)
{
	if (!constructor.parameters.len)
	{
		if (node.runtime_type != constructor.runtime_type
			|| node.static_type != constructor.runtime_type
			|| (node.result_type
				&& node.result_type != constructor.runtime_type)) return false;
		foreach (index, input : node.inputs)
		{
			mitos::TypeId actual = aot_node_metadata_type(program, input);
			mitos::TypeId expected = constructor.field_types[index];
			if (actual != mitos::TYPE_ID_ANY && expected != mitos::TYPE_ID_ANY
				&& !mitos::type_is_subtype(
					&program.types, actual, expected
				)) return false;
		}
		return true;
	}

	bool concrete = true;
	foreach (input : node.inputs)
	{
		mitos::TypeId actual = aot_node_metadata_type(program, input);
		if (!aot_valid_type(program, actual)) return false;
		if (actual == mitos::TYPE_ID_ANY) concrete = false;
	}
	if (!concrete)
	{
		return !node.runtime_type && node.static_type == mitos::TYPE_ID_ANY
			&& !node.result_type;
	}
	if (!node.runtime_type || node.static_type != node.runtime_type
		|| (node.result_type && node.result_type != node.runtime_type))
	{
		return false;
	}
	mitos::TypeDescriptor* instance = mitos::type_descriptor(
		&program.types, node.runtime_type
	);
	if (!instance
		|| instance.kind != mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
		|| instance.constructor != constructor.type_constructor
		|| instance.arguments.len != constructor.parameters.len) return false;
	foreach (index, &pattern : constructor.field_patterns)
	{
		if (!aot_constructor_pattern_matches(
			program,
			constructor,
			instance,
			pattern,
			aot_node_metadata_type(program, node.inputs[index])
		)) return false;
	}
	return true;
}

fn bool aot_valid_superposition_node(
	mitos::DeltaProgram* program,
	mitos::DeltaNode* node
)
{
	if (!node.descriptor || node.descriptor != (usz)node.stable_id
		|| node.types.len != 1
		|| node.types[0] != node.result_type
		|| !aot_valid_type(program, node.result_type)
		|| node.static_type != node.runtime_type)
	{
		return false;
	}
	if (node.kind == mitos::DeltaNodeKind.DELTA_SUPERPOSE)
	{
		if (!node.inputs.len
			|| node.inputs.len > mitos_jit::JIT_MAX_SUPERPOSE_BRANCHES
			|| !aot_valid_unary_runtime_type(
				program,
				node.runtime_type,
				mitos::TYPE_ID_SUPERPOSITION,
				node.result_type
			)) return false;
		foreach (input_id : node.inputs)
		{
			mitos::DeltaNode* input = &program.image.nodes[(usz)input_id - 1];
			mitos::TypeId input_type = input.kind == mitos::DeltaNodeKind.DELTA_SUPERPOSE
				? input.result_type
				: input.runtime_type ? input.runtime_type : input.static_type;
			if (node.result_type != mitos::TYPE_ID_ANY && input_type != node.result_type) return false;
		}
		return true;
	}
	if (node.kind != mitos::DeltaNodeKind.DELTA_COLLAPSE || node.inputs.len != 1
		|| !aot_valid_unary_runtime_type(
			program,
			node.runtime_type,
			mitos::TYPE_ID_ARRAY,
			node.result_type
		))
	{
		return false;
	}
	mitos::DeltaNode* input = &program.image.nodes[(usz)node.inputs[0] - 1];
	mitos::TypeId input_type = input.runtime_type ? input.runtime_type : input.static_type;
	mitos::TypeDescriptor* input_descriptor = mitos::type_descriptor(
		&program.types, input_type
	);
	if (!input_descriptor || input_descriptor.constructor != mitos::TYPE_ID_SUPERPOSITION
		|| input_descriptor.arguments.len != 1)
	{
		return node.result_type == mitos::TYPE_ID_ANY;
	}
	return node.result_type == mitos::TYPE_ID_ANY
		|| input_descriptor.arguments[0] == node.result_type;
}

fn bool aot_add_graph_reference(
	usz[] depths,
	usz[] work,
	usz current,
	mitos::DeltaNodeId reference,
	usz* depth,
	usz* expanded
)
{
	if (!reference || (usz)reference > current) return false;
	usz child = (usz)reference - 1;
	if (depths[child] >= mitos::DELTA_MAX_EVALUATION_DEPTH
		|| work[child] > MITOS_AOT_MAX_NODES - *expanded)
	{
		return false;
	}
	usz candidate_depth = depths[child] + 1;
	if (candidate_depth > *depth) *depth = candidate_depth;
	*expanded += work[child];
	return true;
}

fn bool aot_graph_work_is_bounded(
	mitos::DeltaProgram* program,
	Allocator allocator
)
{
	usz[] depths = alloc::new_array(
		allocator, usz, (sz)program.image.nodes.len
	);
	defer alloc::free(allocator, depths);
	usz[] work = alloc::new_array(
		allocator, usz, (sz)program.image.nodes.len
	);
	defer alloc::free(allocator, work);
	foreach (index, &node : program.image.nodes)
	{
		usz depth = 1;
		usz expanded = 1;
		foreach (input : node.inputs)
		{
			if (!aot_add_graph_reference(
				depths, work, (usz)index, input, &depth, &expanded
			)) return false;
		}
		foreach (&branch : node.branches)
		{
			if (!aot_add_graph_reference(
				depths, work, (usz)index, branch.body, &depth, &expanded
			)) return false;
		}
		if (depth > mitos::DELTA_MAX_EVALUATION_DEPTH) return false;
		depths[(usz)index] = depth;
		work[(usz)index] = expanded;
	}
	return true;
}

fn bool aot_function_type_graph_is_valid(
	mitos::TypeRegistry* registry,
	Allocator allocator
)
{
	usz descriptor_count = (usz)registry.descriptors.len();
	uint[] incoming = alloc::new_array(
		allocator, uint, (sz)descriptor_count
	);
	defer alloc::free(allocator, incoming);
	uint[] depths = alloc::new_array(
		allocator, uint, (sz)descriptor_count
	);
	defer alloc::free(allocator, depths);
	usz[] ready = alloc::new_array(
		allocator, usz, (sz)descriptor_count
	);
	defer alloc::free(allocator, ready);
	foreach (index, &count : incoming)
	{
		*count = 0;
		depths[(usz)index] = 0;
	}

	usz function_count = 0;
	foreach (&descriptor : registry.descriptors)
	{
		if (descriptor.kind
			!= mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
		{
			continue;
		}
		function_count++;
		depths[(usz)descriptor.id - 1] = 1;
		foreach (reference : descriptor.function_parameters)
		{
			mitos::TypeDescriptor* referenced = mitos::type_descriptor(
				registry, reference
			);
			if (referenced && referenced.kind
				== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
			{
				incoming[(usz)reference - 1]++;
			}
		}
		mitos::TypeDescriptor* result = mitos::type_descriptor(
			registry, descriptor.function_result
		);
		if (result && result.kind
			== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
		{
			incoming[(usz)descriptor.function_result - 1]++;
		}
	}

	usz ready_count = 0;
	foreach (index, &descriptor : registry.descriptors)
	{
		if (descriptor.kind
				== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
			&& !incoming[(usz)index])
		{
			ready[ready_count++] = (usz)index;
		}
	}
	usz processed = 0;
	for (usz cursor = 0; cursor < ready_count; cursor++)
	{
		usz current_index = ready[cursor];
		mitos::TypeDescriptor* descriptor =
			&registry.descriptors[(sz)current_index];
		processed++;
		foreach (reference : descriptor.function_parameters)
		{
			mitos::TypeDescriptor* referenced = mitos::type_descriptor(
				registry, reference
			);
			if (referenced && referenced.kind
				== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
			{
				usz index = (usz)reference - 1;
				if ((usz)depths[current_index]
					>= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH) return false;
				uint next_depth = depths[current_index] + 1;
				if (next_depth > depths[index]) depths[index] = next_depth;
				incoming[index]--;
				if (!incoming[index]) ready[ready_count++] = index;
			}
		}
		mitos::TypeDescriptor* result = mitos::type_descriptor(
			registry, descriptor.function_result
		);
		if (result && result.kind
			== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
		{
			usz index = (usz)descriptor.function_result - 1;
			if ((usz)depths[current_index]
				>= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH) return false;
			uint next_depth = depths[current_index] + 1;
			if (next_depth > depths[index]) depths[index] = next_depth;
			incoming[index]--;
			if (!incoming[index]) ready[ready_count++] = index;
		}
	}
	return processed == function_count;
}

fn bool aot_graph_edges_are_complete(
	mitos::DeltaProgram* program,
	Allocator allocator
)
{
	usz node_count = program.image.nodes.len;
	usz[] offsets = alloc::new_array(
		allocator, usz, (sz)node_count
	);
	defer alloc::free(allocator, offsets);
	usz expected_count = 0;
	foreach (index, &node : program.image.nodes)
	{
		offsets[(usz)index] = expected_count;
		usz input_count = node.inputs.len + node.branches.len;
		if (input_count > MITOS_AOT_MAX_EDGES - expected_count) return false;
		expected_count += input_count;
	}
	if (program.image.edges.len != expected_count) return false;

	foreach (edge_index, &edge : program.image.edges)
	{
		if (!aot_valid_node(program, edge.producer)
			|| !aot_valid_node(program, edge.consumer)) return false;
		usz consumer_index = (usz)edge.consumer - 1;
		mitos::DeltaNode* consumer = &program.image.nodes[consumer_index];
		usz input_count = consumer.inputs.len;
		usz slot_count = input_count + consumer.branches.len;
		if (edge.input >= slot_count) return false;
		mitos::DeltaNodeId expected = edge.input < input_count
			? consumer.inputs[edge.input]
			: consumer.branches[edge.input - input_count].body;
		usz canonical_slot = offsets[consumer_index] + edge.input;
		if (edge.producer != expected
			|| (usz)edge_index != canonical_slot) return false;
	}
	return true;
}

fn bool aot_routing_is_canonical(mitos::DeltaProgram* program)
{
	usz method_count = program.method_roots.len;
	if (method_count >= (usz)uint::max
		|| program.image.interfaces.len != method_count + 1)
	{
		return false;
	}
	foreach (interface_index, &boundary : program.image.interfaces)
	{
		if (boundary.source_order > (usz)uint::max) return false;
		if ((usz)interface_index < method_count)
		{
			mitos::DeltaMethodRoot* root =
				&program.method_roots[(usz)interface_index];
			if (root.generic_index >= (usz)program.methods.generics.len())
			{
				return false;
			}
			mitos::GenericFunction* generic =
				&program.methods.generics[(sz)root.generic_index];
			if (boundary.kind
					!= mitos::DeltaInterfaceKind.DELTA_INTERFACE_METHOD
				|| boundary.source_order != (usz)interface_index
				|| boundary.source_order != root.source_order
				|| boundary.root != root.root
				|| boundary.name != generic.name
				|| !mitos::symbol_key_equal(&boundary.key, &root.key))
			{
				return false;
			}
			continue;
		}
		mitos::DeltaNode* entry = mitos::delta_node(program, program.entry);
		if (boundary.kind
				!= mitos::DeltaInterfaceKind.DELTA_INTERFACE_ENTRY
			|| boundary.source_order != method_count
			|| boundary.root != program.entry || !entry
			|| boundary.name != entry.name
			|| !mitos::symbol_key_equal(&boundary.key, &entry.key))
		{
			return false;
		}
	}

	usz parallel_root_count = 0;
	usz parallel_join_count = 0;
	foreach (&node : program.image.nodes)
	{
		if (node.kind == mitos::DeltaNodeKind.DELTA_PARALLEL_ROOT)
		{
			if (node.descriptor > (usz)uint::max) return false;
			parallel_root_count++;
		}
		else if (node.kind == mitos::DeltaNodeKind.DELTA_PARALLEL_JOIN)
		{
			if (node.descriptor > (usz)uint::max) return false;
			parallel_join_count++;
		}
	}
	if (parallel_join_count != program.image.parallel_regions.len
		|| parallel_root_count > (usz)uint::max - program.image.interfaces.len)
	{
		return false;
	}
	bool[] root_nodes_seen = alloc::new_array(
		program.allocator, bool, (sz)program.image.nodes.len
	);
	defer alloc::free(program.allocator, root_nodes_seen);
	bool[] join_nodes_seen = alloc::new_array(
		program.allocator, bool, (sz)program.image.nodes.len
	);
	defer alloc::free(program.allocator, join_nodes_seen);
	bool[] root_orders_seen = alloc::new_array(
		program.allocator, bool, (sz)parallel_root_count
	);
	defer alloc::free(program.allocator, root_orders_seen);
	bool[] region_orders_seen = alloc::new_array(
		program.allocator, bool, (sz)program.image.parallel_regions.len
	);
	defer alloc::free(program.allocator, region_orders_seen);
	foreach (&seen : root_nodes_seen) *seen = false;
	foreach (&seen : join_nodes_seen) *seen = false;
	foreach (&seen : root_orders_seen) *seen = false;
	foreach (&seen : region_orders_seen) *seen = false;
	usz first_root_order = program.image.interfaces.len;
	foreach (&node : program.image.nodes)
	{
		if (node.kind != mitos::DeltaNodeKind.DELTA_PARALLEL_ROOT) continue;
		if (node.descriptor < first_root_order
			|| node.descriptor - first_root_order >= parallel_root_count
			|| root_orders_seen[node.descriptor - first_root_order])
		{
			return false;
		}
		root_orders_seen[node.descriptor - first_root_order] = true;
	}
	foreach (&region : program.image.parallel_regions)
	{
		if (region.source_order > (usz)uint::max
			|| region.source_order >= program.image.parallel_regions.len
			|| region_orders_seen[region.source_order])
		{
			return false;
		}
		region_orders_seen[region.source_order] = true;
		mitos::DeltaNode* join = mitos::delta_node(program, region.join);
		if (!join
			|| join.kind != mitos::DeltaNodeKind.DELTA_PARALLEL_JOIN
			|| join.descriptor != region.source_order
			|| join_nodes_seen[(usz)region.join - 1]
			|| region.roots.len != join.names.len
			|| region.roots.len != join.types.len
			|| join.inputs.len != region.roots.len + 1)
		{
			return false;
		}
		join_nodes_seen[(usz)region.join - 1] = true;
		usz previous_root_descriptor = 0;
		bool previous_root_descriptor_set = false;
		foreach (root_index, root_id : region.roots)
		{
			mitos::DeltaNode* root = mitos::delta_node(program, root_id);
			if (!root
				|| root.kind != mitos::DeltaNodeKind.DELTA_PARALLEL_ROOT
				|| root_nodes_seen[(usz)root_id - 1]
				|| (previous_root_descriptor_set
					&& root.descriptor <= previous_root_descriptor)
				|| join.inputs[(usz)root_index] != root_id
				|| root.name != join.names[(usz)root_index]
				|| root.static_type != join.types[(usz)root_index])
			{
				return false;
			}
			root_nodes_seen[(usz)root_id - 1] = true;
			previous_root_descriptor = root.descriptor;
			previous_root_descriptor_set = true;
		}
	}
	foreach (index, &node : program.image.nodes)
	{
		if (node.kind == mitos::DeltaNodeKind.DELTA_PARALLEL_ROOT
			&& !root_nodes_seen[(usz)index]) return false;
		if (node.kind == mitos::DeltaNodeKind.DELTA_PARALLEL_JOIN
			&& !join_nodes_seen[(usz)index]) return false;
	}
	return true;
}

fn bool validate_aot_delta_program(mitos::DeltaProgram* program)
{
	if (!program || !program.module_key.canonical.len
		|| !mitos::delta_program_is_compatible(program)
		|| !mitos::module_key_equal(&program.types.module_key, &program.module_key)
		|| !mitos::module_key_equal(&program.methods.module_key, &program.module_key)
		|| !program.effects.epoch
		|| !aot_valid_node(program, program.entry)
		|| !program.types.epoch
		|| program.types.max_types < (usz)program.types.descriptors.len()
		|| program.types.max_types > mitos::MITOS_DEFAULT_MAX_TYPES
		|| program.methods.max_generics < (usz)program.methods.generics.len()
		|| program.methods.max_generics > mitos::MITOS_MAX_GENERIC_FUNCTIONS
		|| program.methods.max_methods < program.methods.method_count
		|| program.methods.max_methods > mitos::MITOS_MAX_METHODS
		|| program.methods.method_count > mitos::MITOS_MAX_METHODS
		|| !mitos::type_registry_layouts_are_valid(&program.types)
		|| !aot_valid_superposition_bootstrap(program)) return false;
	foreach (index, &type : program.types.descriptors)
	{
		if ((usz)type.id != (usz)index + 1 || !type.name.len
			|| !aot_valid_span(type.span)
			|| !aot_valid_key(program, &type.key)
			|| !mitos::layout_descriptor_is_valid(&type.layout)
			|| !mitos::symbol_key_equal(&type.layout.stable_key, &type.key)
			|| (uint)type.layout.kind > (uint)mitos::LayoutKind.LAYOUT_CALLABLE
			|| (uint)type.layout.copy_policy > (uint)mitos::CopyPolicy.COPY_BORROWED
			|| (type.layout.element_type
				&& !aot_valid_type(program, type.layout.element_type))
			|| (uint)type.kind
				> (uint)mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
			|| type.arity > mitos::MITOS_MAX_CONSTRUCTOR_FIELDS
			|| !aot_strings_are_unique_nonempty(
				type.parameters, program.allocator
			)
			|| (type.nominal_parent && !aot_valid_type(program, type.nominal_parent))
			|| (type.constructor && !aot_valid_type(program, type.constructor)))
		{
			return false;
		}
		if (type.nominal_parent)
		{
			mitos::TypeDescriptor* parent = mitos::type_descriptor(
				&program.types, type.nominal_parent
			);
			if (!parent || parent.kind
				!= mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_ABSTRACT)
			{
				return false;
			}
		}
		if (type.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE)
		{
			mitos::TypeDescriptor* constructor = mitos::type_descriptor(
				&program.types, type.constructor
			);
			if (!constructor
				|| constructor.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
				|| constructor.kind
					== mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
				|| type.arguments.len != constructor.arity) return false;
		}
		else if (type.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
		{
			if (type.constructor != mitos::TYPE_ID_FUNCTION
				|| type.nominal_parent != mitos::TYPE_ID_ANY
				|| type.name != "Function"
				|| type.key.kind != mitos::SymbolKind.SYMBOL_TYPE
				|| type.key.name != type.name
				|| type.key.arity != (uint)type.function_parameters.len
				|| type.layout.kind != mitos::LayoutKind.LAYOUT_CALLABLE
				|| type.parameters.len || type.arguments.len || type.arity
				|| type.fields.len
				|| type.function_parameters.len
					> mitos::MITOS_MAX_FUNCTION_PARAMETERS
				|| !aot_valid_type(program, type.function_result)) return false;
		}
		foreach (argument : type.arguments)
		{
			if (!aot_valid_type(program, argument)) return false;
		}
		foreach (parameter : type.function_parameters)
		{
			if (!aot_valid_type(program, parameter)) return false;
		}
		if (!aot_valid_effect_row(program, &type.function_effects)) return false;
		if (type.function_result && !aot_valid_type(program, type.function_result))
		{
			return false;
		}
		foreach (&field : type.fields)
		{
			if (!mitos::source_identifier_is_valid(field.name)
				|| !aot_valid_span(field.span)
				|| !aot_valid_type(program, field.declared_type)
				|| !aot_valid_type_pattern(program, &field.pattern)) return false;
		}
		if (!aot_type_descriptor_key_is_coherent(program, type)
			|| !aot_custom_layout_is_coherent(program, type)) return false;
	}
	mitos::SymbolKey*[] type_keys = alloc::new_array(
		program.allocator,
		mitos::SymbolKey*,
		program.types.descriptors.len()
	);
	defer alloc::free(program.allocator, type_keys);
	foreach (index, &type : program.types.descriptors)
		type_keys[(usz)index] = &type.key;
	if (!aot_keys_are_unique(type_keys, program.allocator)
		|| !aot_nominal_type_names_are_unique(
			&program.types, program.allocator
		)
		|| !aot_nominal_hierarchy_is_valid(
			&program.types, program.allocator
		)) return false;
	if (!aot_function_type_graph_is_valid(&program.types, program.allocator))
	{
		return false;
	}
	usz actual_method_count = 0;
	foreach (generic_index, &generic : program.methods.generics)
	{
		if (!generic.name.len || !generic.epoch
			|| generic.arity > mitos::MITOS_MAX_METHOD_VARIABLES
			|| !aot_valid_key(program, &generic.key)
			|| generic.key.kind != mitos::SymbolKind.SYMBOL_GENERIC
			|| generic.key.name != generic.name
			|| generic.key.arity != (uint)generic.arity
			|| generic.key.canonical_signature.len
			|| !mitos::module_key_equal(&generic.owner, &generic.key.owner))
		{
			return false;
		}
		if ((usz)generic.methods.len() > usz::max - actual_method_count)
		{
			return false;
		}
		actual_method_count += (usz)generic.methods.len();
		foreach (method_index, &method : generic.methods)
		{
			if (method.parameters.len != generic.arity
				|| !aot_valid_span(method.span)
				|| !aot_valid_key(program, &method.key)
				|| method.key.kind != mitos::SymbolKind.SYMBOL_METHOD
				|| !mitos::symbol_key_equal(&method.generic_key, &generic.key)
				|| !mitos::module_key_equal(&method.owner, &method.key.owner)
				|| method.source_order != method.function_index
				|| !aot_valid_method_pattern(program, &method.result)
				|| method.function_index >= program.method_roots.len)
			{
				return false;
			}
			foreach (&parameter : method.parameters)
			{
				if (!aot_valid_method_pattern(program, parameter)) return false;
			}
			if (!aot_method_metadata_is_coherent(
				program, generic, method
			)) return false;
			mitos::DeltaMethodRoot* root =
				&program.method_roots[method.function_index];
			if (root.generic_index != (usz)generic_index
				|| root.method_index != (usz)method_index
				|| root.function_index != method.function_index
				|| !mitos::symbol_key_equal(&root.key, &method.key)
				|| !mitos::symbol_key_equal(&root.generic_key, &generic.key))
			{
				return false;
			}
		}
	}
	if (actual_method_count != program.methods.method_count
		|| actual_method_count != program.method_roots.len) return false;
	mitos::SymbolKey*[] generic_keys = alloc::new_array(
		program.allocator, mitos::SymbolKey*, program.methods.generics.len()
	);
	defer alloc::free(program.allocator, generic_keys);
	mitos::SymbolKey*[] method_keys = alloc::new_array(
		program.allocator, mitos::SymbolKey*, (sz)actual_method_count
	);
	defer alloc::free(program.allocator, method_keys);
	usz method_key_index = 0;
	foreach (generic_index, &generic : program.methods.generics)
	{
		generic_keys[(usz)generic_index] = &generic.key;
		foreach (&method : generic.methods)
		{
			method_keys[method_key_index++] = &method.key;
		}
	}
	if (!aot_keys_are_unique(generic_keys, program.allocator)
		|| !aot_keys_are_unique(method_keys, program.allocator)) return false;
	uint[] constructor_counts = alloc::new_array(
		program.allocator,
		uint,
		(sz)program.types.descriptors.len()
	);
	defer alloc::free(program.allocator, constructor_counts);
	foreach (&count : constructor_counts) *count = 0;
	foreach (index, &constructor : program.constructors)
	{
		if (constructor.id != (uint)index + 1 || !constructor.name.len
			|| !aot_valid_span(constructor.span)
			|| !aot_valid_key(program, &constructor.key)
			|| !aot_valid_type(program, constructor.type_constructor)
			|| constructor.fields.len != constructor.field_types.len
			|| constructor.fields.len != constructor.field_patterns.len
			|| !aot_strings_are_unique_nonempty(
				constructor.parameters, program.allocator
			)
			|| !aot_strings_are_unique_nonempty(
				constructor.fields, program.allocator
			)
			|| !aot_constructor_key_is_coherent(program, constructor))
		{
			return false;
		}
		foreach (type_id : constructor.field_types)
		{
			if (!aot_valid_type(program, type_id)) return false;
		}
		foreach (&pattern : constructor.field_patterns)
		{
			if (!aot_valid_type_pattern(program, pattern)) return false;
		}
		constructor_counts[(usz)constructor.type_constructor - 1]++;
	}
	mitos::SymbolKey*[] constructor_keys = alloc::new_array(
		program.allocator, mitos::SymbolKey*, program.constructors.len
	);
	defer alloc::free(program.allocator, constructor_keys);
	foreach (index, &constructor : program.constructors)
		constructor_keys[(usz)index] = &constructor.key;
	if (!aot_keys_are_unique(constructor_keys, program.allocator)) return false;
	uint[] match_constructor_owners;
	defer alloc::free(program.allocator, match_constructor_owners);
	String[10] primitive_names = {
		"add", "subtract", "multiply", "divide", "remainder",
		"equal", "less", "lessEqual", "greater", "greaterEqual",
	};
	if (program.primitives.len != primitive_names.len) return false;
	foreach (index, &primitive : program.primitives)
	{
		mitos::ModuleKey core = {
			.canonical = mitos::MITOS_CORE_MODULE_CANONICAL
		};
		if (primitive.id != (uint)index + 1 || !primitive.name.len
			|| primitive.name != primitive_names[(usz)index]
			|| !aot_valid_key(program, &primitive.key)
			|| primitive.key.kind != mitos::SymbolKind.SYMBOL_FUNCTION
			|| primitive.key.name != primitive.name
			|| primitive.key.arity != (uint)primitive.arity
			|| primitive.key.canonical_signature != "primitive"
			|| !mitos::module_key_equal(&primitive.key.owner, &core)
			|| primitive.operation
				!= (mitos::DeltaPrimitiveOp)index
			|| primitive.arity != 2
			|| primitive.parameters.len != 2
			|| !aot_valid_type(program, primitive.result)) return false;
		foreach (type_id : primitive.parameters)
			if (!aot_valid_type(program, type_id)) return false;
	}
	foreach (index, &node : program.image.nodes)
	{
		if (node.stable_id != (uint)index + 1 || (uint)node.kind > (uint)mitos::DeltaNodeKind.DELTA_COLLAPSE
			|| !aot_valid_type(program, node.static_type)
			|| (node.runtime_type && !aot_valid_type(program, node.runtime_type))
			|| (node.result_type && !aot_valid_type(program, node.result_type))
			|| (node.span && (usz)node.span > program.spans.len)
			|| (node.kind != mitos::DeltaNodeKind.DELTA_MATCH && node.branches.len)) return false;
		foreach (type_id : node.types)
		{
			if (!aot_valid_type(program, type_id)) return false;
		}
		bool keyed_node = false;
		switch (node.kind)
		{
			case DELTA_CONSTRUCTOR:
			case DELTA_GENERIC_CALL:
			case DELTA_PRIMITIVE:
			case DELTA_EFFECT:
			case DELTA_ABORT:
				keyed_node = true;
			default:
		}
		if (keyed_node)
		{
			if (!aot_valid_key(program, &node.key)) return false;
		}
		else if (node.key.owner.canonical.len || node.key.name.len
			|| node.key.arity || node.key.canonical_signature.len
			|| node.key.kind != mitos::SymbolKind.SYMBOL_TYPE)
		{
			return false;
		}
		if (!aot_valid_effect_row(program, &node.effect_row)) return false;
		foreach (input : node.inputs) if (!aot_valid_node(program, input)) return false;
		bool wildcard_seen = false;
		mitos::TypeId match_type = mitos::TYPE_ID_INVALID;
		usz explicit_branch_count = 0;
		foreach (branch_index, &branch : node.branches)
		{
			if (!aot_valid_node(program, branch.body)
				|| (branch.span && (usz)branch.span > program.spans.len))
			{
				return false;
			}
			if (branch.wildcard)
			{
				if (wildcard_seen || branch.bindings.len
					|| branch.constructor != uint::max
					|| (usz)branch_index + 1 != node.branches.len) return false;
				wildcard_seen = true;
				continue;
			}
			if ((usz)branch.constructor >= program.constructors.len) return false;
			if (!match_constructor_owners.len)
			{
				match_constructor_owners = alloc::new_array(
					program.allocator, uint, (sz)program.constructors.len
				);
				foreach (&owner : match_constructor_owners) *owner = 0;
			}
			mitos::DeltaConstructorDescriptor* constructor =
				&program.constructors[branch.constructor];
			if (branch.bindings.len != constructor.fields.len
				|| !aot_strings_are_unique_nonempty(
					branch.bindings, program.allocator
				)
				|| (match_type && match_type != constructor.type_constructor)
				|| match_constructor_owners[branch.constructor] == node.stable_id)
			{
				return false;
			}
			match_type = constructor.type_constructor;
			match_constructor_owners[branch.constructor] = node.stable_id;
			explicit_branch_count++;
		}
		if (node.branches.len
			&& (!match_type
				|| (!wildcard_seen
					&& explicit_branch_count
						!= (usz)constructor_counts[(usz)match_type - 1])))
		{
			return false;
		}
		switch (node.kind)
		{
			case DELTA_LOCAL:
				if (!mitos::source_identifier_is_valid(node.name)
					|| node.inputs.len) return false;
			case DELTA_I64:
				if (node.static_type != mitos::TYPE_ID_I64 || node.inputs.len
					|| (node.runtime_type
						&& node.runtime_type != mitos::TYPE_ID_I64)
					|| (node.result_type
						&& node.result_type != mitos::TYPE_ID_I64)) return false;
			case DELTA_STRING:
				if (node.static_type != mitos::TYPE_ID_STRING || node.inputs.len
					|| (node.runtime_type
						&& node.runtime_type != mitos::TYPE_ID_STRING)
					|| (node.result_type
						&& node.result_type != mitos::TYPE_ID_STRING)) return false;
			case DELTA_LAMBDA:
				if (node.inputs.len != 1 || node.names.len != node.types.len
					|| !aot_strings_are_unique_nonempty(
						node.names, program.allocator
					)
					|| !node.runtime_type || !node.result_type) return false;
			case DELTA_APPLY:
				if (!node.inputs.len) return false;
			case DELTA_LET:
				if (node.names.len != 1 || !node.names[0].len
					|| node.inputs.len != 2) return false;
			case DELTA_CONSTRUCTOR:
				if (node.descriptor >= program.constructors.len) return false;
				mitos::DeltaConstructorDescriptor* constructor =
					&program.constructors[node.descriptor];
				if (!mitos::symbol_key_equal(&node.key, &constructor.key)
					|| node.inputs.len != constructor.fields.len
					|| !aot_constructor_node_type_is_exact(
						program, constructor, node
					)) return false;
			case DELTA_MATCH:
				if (node.inputs.len != 1 || !node.branches.len
					|| !aot_match_scrutinee_type_is_compatible(
						program, node.inputs[0], match_type
					)) return false;
			case DELTA_GENERIC_CALL:
				if (!mitos::source_identifier_is_valid(node.name)) return false;
				if (node.descriptor >= (usz)program.methods.generics.len()
					|| !mitos::symbol_key_equal(
						&node.key,
						&program.methods.generics[(sz)node.descriptor].key
					)
					|| node.inputs.len
						!= program.methods.generics[(sz)node.descriptor].arity
					|| node.name
						!= program.methods.generics[(sz)node.descriptor].name)
				{
					return false;
				}
			case DELTA_TYPE_VALUE:
				if (node.inputs.len
					|| !aot_valid_type(program, (mitos::TypeId)node.descriptor)) return false;
			case DELTA_TYPE_ASSERT:
				if (node.inputs.len != 1
					|| node.static_type != (mitos::TypeId)node.descriptor
					|| !aot_valid_type(program, (mitos::TypeId)node.descriptor)) return false;
			case DELTA_TYPE_OF:
				if (node.inputs.len != 1 || node.static_type != mitos::TYPE_ID_TYPE) return false;
			case DELTA_PRIMITIVE:
				if (node.descriptor >= program.primitives.len
					|| !mitos::symbol_key_equal(
						&node.key, &program.primitives[node.descriptor].key
					)
					|| node.inputs.len
						!= program.primitives[node.descriptor].arity) return false;
			case DELTA_PARALLEL_ROOT:
				if (node.inputs.len != 1
					|| !mitos::source_identifier_is_valid(node.name)) return false;
			case DELTA_PARALLEL_JOIN:
				if (node.names.len != node.types.len
					|| !aot_strings_are_unique_nonempty(
						node.names, program.allocator
					)
					|| node.inputs.len != node.names.len + 1) return false;
			case DELTA_EFFECT:
				if (!aot_valid_effect_node(program, node)) return false;
			case DELTA_HANDLER:
				if (node.descriptor >= program.effects.handlers.len) return false;
				mitos::DeltaHandlerDescriptor* handler =
					&program.effects.handlers[node.descriptor];
				if (node.inputs.len != handler.clauses.len + 2
					|| node.inputs[0] != handler.handled
					|| node.inputs[node.inputs.len - 1] != handler.return_body)
				{
					return false;
				}
				foreach (clause_index, &clause : handler.clauses)
				{
					if (node.inputs[(usz)clause_index + 1] != clause.body) return false;
				}
			case DELTA_RESUME:
				if (node.descriptor >= program.effects.handlers.len
					|| node.inputs.len != 1 || node.types.len != 1
					|| node.types[0] != node.result_type) return false;
			case DELTA_ABORT:
				if (!aot_valid_abort_node(program, node)) return false;
			case DELTA_SUPERPOSE:
			case DELTA_COLLAPSE:
				if (!aot_valid_superposition_node(program, node)) return false;
		}
	}
	if (!aot_graph_work_is_bounded(program, program.allocator)
		|| !aot_graph_edges_are_complete(program, program.allocator)
		|| !aot_routing_is_canonical(program))
	{
		return false;
	}
	foreach (root_index, &root : program.method_roots)
	{
		if (!aot_valid_node(program, root.root)
			|| !aot_valid_key(program, &root.key)
			|| !aot_valid_key(program, &root.generic_key)
			|| root.parameters.len != root.parameter_types.len
			|| root.parameters.len != root.parameter_patterns.len
			|| !aot_strings_are_unique_nonempty(
				root.parameters, program.allocator
			)
			|| root.generic_index >= (usz)program.methods.generics.len()
			|| root.method_index >= (usz)program.methods.generics[
				(sz)root.generic_index
			].methods.len()
			|| root.function_index != (usz)root_index
			|| root.source_order != (usz)root_index
			|| !aot_valid_type(program, root.result_type)
			|| !aot_valid_method_pattern(program, &root.result_pattern))
		{
			return false;
		}
		foreach (type_id : root.parameter_types)
		{
			if (!aot_valid_type(program, type_id)) return false;
		}
		foreach (&pattern : root.parameter_patterns)
		{
			if (!aot_valid_method_pattern(program, pattern)) return false;
		}
		mitos::GenericFunction* generic =
			&program.methods.generics[(sz)root.generic_index];
		mitos::MethodDescriptor* method =
			&generic.methods[(sz)root.method_index];
		if (root.parameter_patterns.len != method.parameters.len
			|| !aot_method_pattern_equal(
				&root.result_pattern, &method.result
			))
		{
			return false;
		}
		foreach (pattern_index, &pattern : root.parameter_patterns)
		{
			if (!aot_method_pattern_equal(
				pattern, &method.parameters[(usz)pattern_index]
			)) return false;
		}
		if (!aot_valid_effect_row(program, &root.effect_row)) return false;
	}
	foreach (span : program.spans)
	{
		if (!aot_valid_span(span)) return false;
	}
	foreach (instance_index, &instance : program.effects.instances)
	{
		mitos::DeltaEffectDescriptor* constructor =
			aot_effect_descriptor(program, instance.constructor);
		if (instance.id != (mitos::EffectId)(
				program.effects.effects.len + (usz)instance_index + 1
			)
			|| !constructor
			|| !aot_valid_key(program, &instance.key)
			|| instance.key.kind != mitos::SymbolKind.SYMBOL_EFFECT
			|| instance.key.name != constructor.name
			|| instance.key.arity != (uint)instance.arguments.len
			|| !mitos::module_key_equal(&instance.key.owner, &constructor.key.owner)
			|| instance.arguments.len != constructor.parameters.len
			|| !aot_effect_instance_key_signature_is_coherent(
				program, instance
			))
		{
			return false;
		}
		foreach (type_id : instance.arguments)
		{
			if (!aot_valid_type(program, type_id)) return false;
		}
	}
	if (program.effects.next_effect_id
			!= (mitos::EffectId)(
				program.effects.effects.len + program.effects.instances.len + 1
			)
		|| program.effects.next_operation_id
			!= (mitos::OperationId)(program.effects.operations.len + 1)
		|| program.effects.rows.len != program.method_roots.len)
	{
		return false;
	}
	foreach (row_index, &row : program.effects.rows)
	{
		if (row.effect_epoch != program.effects.epoch
			|| !aot_valid_key(program, &row.key)
			|| row.function_index != (usz)row_index
			|| row.function_index >= program.method_roots.len
			|| !mitos::symbol_key_equal(
				&row.key, &program.method_roots[row.function_index].key
			)
			|| !aot_valid_effect_row(program, &row.inferred)
			|| !aot_valid_effect_row(program, &row.asserted)
			|| (!row.has_assertion
				&& (row.asserted.required.len || row.asserted.has_tail)))
		{
			return false;
		}
	}
	usz[] operation_counts = alloc::new_array(
		program.allocator, usz, (sz)program.effects.effects.len
	);
	defer alloc::free(program.allocator, operation_counts);
	foreach (operation_index, &operation : program.effects.operations)
	{
		mitos::DeltaEffectDescriptor* effect =
			aot_effect_descriptor(program, operation.effect);
		if (operation.id != (mitos::OperationId)((usz)operation_index + 1)
			|| operation.id >= program.effects.next_operation_id
			|| !effect
			|| !operation.name.len || !aot_valid_key(program, &operation.key)
			|| operation.key.kind != mitos::SymbolKind.SYMBOL_EFFECT_OPERATION
			|| operation.key.name != operation.name
			|| operation.key.arity != (uint)operation.parameter_types.len
			|| operation.parameter_types.len > (usz)mitos::MITOS_MAX_PARAMETERS
			|| !mitos::module_key_equal(&operation.key.owner, &effect.key.owner)
			|| !aot_operation_key_signature_is_coherent(
				program, effect, operation
			)
			|| (uint)operation.host_kind
				> (uint)mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL
			|| operation.host_kind != aot_expected_host_kind(effect)
			|| operation.ordered
				!= (operation.host_kind != mitos::DeltaEffectHostKind.DELTA_EFFECT_PURE)
			|| operation.parameter_patterns.len != operation.parameter_types.len
			|| !aot_valid_type_pattern(program, &operation.result_type)
			|| (operation.span && (usz)operation.span > program.spans.len))
		{
			return false;
		}
		foreach (pattern_index, &pattern : operation.parameter_types)
		{
			if (!aot_valid_type_pattern(program, pattern)
				|| !aot_effect_pattern_text_is_coherent(
					program,
					operation.parameter_patterns[(usz)pattern_index],
					pattern
				)) return false;
		}
		if (!aot_effect_pattern_text_is_coherent(
			program, operation.result_pattern, &operation.result_type
		)) return false;
		operation_counts[(usz)effect.id - 1]++;
	}
	bool[] operation_seen = alloc::new_array(
		program.allocator, bool, (sz)program.effects.operations.len
	);
	defer alloc::free(program.allocator, operation_seen);
	foreach (effect_index, &effect : program.effects.effects)
	{
		if (effect.id != (mitos::EffectId)((usz)effect_index + 1)
			|| effect.id >= program.effects.next_effect_id
			|| !effect.name.len || !aot_valid_key(program, &effect.key)
			|| effect.key.kind != mitos::SymbolKind.SYMBOL_EFFECT
			|| effect.key.name != effect.name
			|| effect.key.arity != (uint)effect.parameters.len
			|| effect.key.canonical_signature.len
			|| effect.parameters.len > (usz)mitos::MITOS_MAX_TYPE_ARGUMENTS
			|| !aot_strings_are_unique_nonempty(
				effect.parameters, program.allocator
			)
			|| !mitos::module_key_equal(&effect.key.owner, &program.module_key)
			|| (effect.span && (usz)effect.span > program.spans.len)
			|| operation_counts[(usz)effect_index] != effect.operations.len)
		{
			return false;
		}
		mitos::OperationId previous_operation = mitos::OPERATION_ID_INVALID;
		foreach (operation_id : effect.operations)
		{
			mitos::DeltaOperationDescriptor* operation =
				aot_operation_descriptor(program, operation_id);
			if (!operation || operation.effect != effect.id
				|| operation_seen[(usz)operation_id - 1]) return false;
			operation_seen[(usz)operation_id - 1] = true;
			if (operation_id <= previous_operation) return false;
			previous_operation = operation_id;
		}
	}
	foreach (seen : operation_seen) if (!seen) return false;
	mitos::SymbolKey*[] effect_keys = alloc::new_array(
		program.allocator, mitos::SymbolKey*, (sz)program.effects.effects.len
	);
	defer alloc::free(program.allocator, effect_keys);
	foreach (index, &effect : program.effects.effects)
	{
		effect_keys[(usz)index] = &effect.key;
	}
	mitos::SymbolKey*[] instance_keys = alloc::new_array(
		program.allocator, mitos::SymbolKey*, (sz)program.effects.instances.len
	);
	defer alloc::free(program.allocator, instance_keys);
	foreach (index, &instance : program.effects.instances)
	{
		instance_keys[(usz)index] = &instance.key;
	}
	mitos::SymbolKey*[] operation_keys = alloc::new_array(
		program.allocator, mitos::SymbolKey*, (sz)program.effects.operations.len
	);
	defer alloc::free(program.allocator, operation_keys);
	foreach (index, &operation : program.effects.operations)
	{
		operation_keys[(usz)index] = &operation.key;
	}
	if (!aot_keys_are_unique(effect_keys, program.allocator)
		|| !aot_keys_are_unique(instance_keys, program.allocator)
		|| !aot_keys_are_unique(operation_keys, program.allocator)) return false;
	foreach (handler_index, &handler : program.effects.handlers)
	{
		if (handler.stable_id != (uint)handler_index + 1
			|| handler.source_order != (usz)handler_index
			|| !mitos::source_identifier_is_valid(handler.return_parameter)
			|| !aot_valid_node(program, handler.handled)
			|| !aot_valid_node(program, handler.return_body)
			|| !aot_valid_type(program, handler.return_type)
			|| (handler.span && (usz)handler.span > program.spans.len))
		{
			return false;
		}
		ulong[] clause_pairs = alloc::new_array(
			program.allocator, ulong, (sz)handler.clauses.len
		);
		defer alloc::free(program.allocator, clause_pairs);
		foreach (clause_index, &clause : handler.clauses)
		{
			mitos::DeltaEffectInstanceDescriptor* instance =
				aot_effect_instance(program, clause.effect);
			mitos::EffectId constructor_id =
				instance ? instance.constructor : clause.effect;
			mitos::DeltaEffectDescriptor* effect =
				aot_effect_descriptor(program, constructor_id);
			mitos::DeltaOperationDescriptor* operation =
				aot_operation_descriptor(program, clause.operation);
			if (clause.stable_id != (uint)clause_index + 1
				|| !effect || !operation || operation.effect != constructor_id
				|| (effect.parameters.len
					&& (!instance
						|| instance.arguments.len != effect.parameters.len))
				|| (!effect.parameters.len && instance)
				|| !mitos::symbol_key_equal(&clause.key, &operation.key)
				|| clause.parameters.len != operation.parameter_types.len
				|| clause.parameter_types.len != operation.parameter_types.len
				|| !aot_strings_are_unique_nonempty(
					clause.parameters, program.allocator
				)
				|| !aot_valid_node(program, clause.body)
				|| !aot_valid_type(program, clause.result_type)
				|| clause.multi != effect.multi
				|| (clause.span && (usz)clause.span > program.spans.len))
			{
				return false;
			}
			foreach (type_index, &pattern : operation.parameter_types)
			{
				if (!aot_effect_type_matches(
					program, effect, instance, pattern,
					clause.parameter_types[(usz)type_index]
				)) return false;
			}
			if (!aot_effect_type_matches(
				program, effect, instance, &operation.result_type,
				clause.result_type
			)) return false;
			clause_pairs[(usz)clause_index] =
				((ulong)(uint)clause.effect << 32) | (ulong)(uint)clause.operation;
		}
		if (clause_pairs.len > 1)
		{
			ulong[] scratch = alloc::new_array(
				program.allocator, ulong, (sz)clause_pairs.len
			);
			defer alloc::free(program.allocator, scratch);
			aot_sort_u64(clause_pairs, scratch, 0, clause_pairs.len);
			for (usz index = 1; index < clause_pairs.len; index++)
			{
				if (clause_pairs[index - 1] == clause_pairs[index]) return false;
			}
		}
	}
	return true;
}

fn mitos::MitosSpan aot_operation_span(
	mitos::DeltaProgram* program,
	mitos::OperationId operation_id
)
{
	mitos::DeltaOperationDescriptor* operation = aot_operation_descriptor(
		program, operation_id
	);
	if (!operation || !operation.span
		|| (usz)operation.span > program.spans.len) return { };
	return program.spans[(usz)operation.span - 1];
}

fn MitosAotResult execute_mitos_aot(String path, Allocator allocator = mem)
{
	long? size_result = file::get_size(path);
	if (catch err = size_result)
	{
		(void)err;
		return aot_error(allocator, "unable to inspect AOT artifact");
	}
	long size = size_result;
	if (size < (long)(MITOS_AOT_MAGIC.len + 4) || (ulong)size > MITOS_AOT_MAX_BYTES)
	{
		return aot_error(allocator, "AOT artifact size is outside the supported range");
	}
	char[] storage = alloc::new_array(allocator, char, (sz)((usz)size + 1));
	defer alloc::free(allocator, storage);
	char[]? loaded = file::load_buffer(path, storage);
	if (catch err = loaded)
	{
		(void)err;
		return aot_error(allocator, "unable to read AOT artifact");
	}
	char[] bytes = loaded;
	if (bytes.len != (usz)size
		|| (String)bytes[:MITOS_AOT_MAGIC.len] != MITOS_AOT_MAGIC)
	{
		return aot_error(allocator, "invalid AOT artifact magic");
	}

	usz decode_budget = MITOS_AOT_MAX_DECODE_BYTES;
	AotReader header = {
		.allocator = allocator,
		.bytes = bytes,
		.cursor = MITOS_AOT_MAGIC.len,
		.decode_budget = &decode_budget,
	};
	uint container_major = header.u32();
	if (container_major >= 1 && container_major <= 3)
	{
		return aot_error(allocator, "AOT v1-v3 artifacts are unsupported; rebuild as AOT v4");
	}
	if (container_major != mitos::DELTA_AOT_CONTAINER_MAJOR)
	{
		return aot_error(allocator, "unsupported AOT artifact major version; expected AOT v4");
	}
	uint container_minor = header.u32();
	(void)container_minor;
	uint header_length = header.u32();
	ulong artifact_length = header.u64();
	if (header.failed || header_length != MITOS_AOT_HEADER_LENGTH
		|| artifact_length != (ulong)bytes.len
		|| header.cursor != (usz)header_length)
	{
		return aot_error(allocator, "AOT v4 header is invalid");
	}

	mitos::DeltaTaggedRecordHeader manifest_header = {
		.tag = (mitos::DeltaRecordTag)header.u32(),
		.flags = (mitos::DeltaRecordFlags)header.u32(),
		.byte_length = header.u64(),
	};
	usz manifest_length = 0;
	if (!mitos::delta_tagged_record_header_is_valid(manifest_header)
		|| manifest_header.tag != AOT_MANIFEST
		|| manifest_header.flags != mitos::DELTA_RECORD_REQUIRED
		|| !header.bounded_length(manifest_header.byte_length, &manifest_length))
	{
		return aot_error(allocator, "AOT v4 manifest must be the first required record");
	}
	AotReader manifest_reader = {
		.allocator = allocator,
		.bytes = bytes[header.cursor:manifest_length],
		.decode_budget = &decode_budget,
	};
	header.cursor += manifest_length;
	AotManifest manifest = aot_read_manifest(&manifest_reader);
	defer manifest.deinit(allocator);
	if (manifest_reader.failed || manifest_reader.cursor != manifest_reader.bytes.len
		|| !aot_manifest_is_supported(&manifest))
	{
		return aot_error(
			allocator,
			manifest_reader.failed
				? manifest_reader.diagnostic
				: "AOT v4 manifest is unsupported or noncanonical"
		);
	}

	AotReader scan = header;
	uint previous_tag = (uint)AOT_MANIFEST;
	usz record_count = 1;
	while (scan.cursor < scan.bytes.len)
	{
		mitos::DeltaTaggedRecordHeader record_header = {
			.tag = (mitos::DeltaRecordTag)scan.u32(),
			.flags = (mitos::DeltaRecordFlags)scan.u32(),
			.byte_length = scan.u64(),
		};
		usz record_length = 0;
		mitos::DeltaRecordFlags manifested_flags = (mitos::DeltaRecordFlags)0;
		if (!mitos::delta_tagged_record_header_is_valid(record_header)
			|| (uint)record_header.tag <= previous_tag
			|| !aot_manifest_record_flags(
				&manifest, (uint)record_header.tag, &manifested_flags
			)
			|| record_header.flags != manifested_flags
			|| !scan.bounded_length(record_header.byte_length, &record_length))
		{
			return aot_error(
				allocator,
				"AOT v4 record order, flags, manifest entry, or length is invalid"
			);
		}
		if (!aot_known_record((uint)record_header.tag)
			&& record_header.flags == mitos::DELTA_RECORD_REQUIRED)
		{
			return aot_error(allocator, "AOT v4 contains an unknown required record");
		}
		if (aot_known_record((uint)record_header.tag))
		{
			mitos::DeltaFeatureBits prerequisites =
				aot_record_prerequisites((uint)record_header.tag);
			if (prerequisites
				& ~(manifest.features.required | manifest.features.optional))
			{
				return aot_error(
					allocator, "AOT v4 record feature prerequisite is absent"
				);
			}
		}
		scan.cursor += record_length;
		previous_tag = (uint)record_header.tag;
		record_count++;
		if (record_count > MITOS_AOT_MAX_RECORDS)
		{
			return aot_error(allocator, "AOT v4 record count exceeds its limit");
		}
	}
	if (scan.failed || scan.cursor != scan.bytes.len
		|| record_count
			!= manifest.required_records.len + manifest.optional_records.len)
	{
		return aot_error(
			allocator, "AOT v4 has missing, duplicate, truncated, or trailing records"
		);
	}

	mitos::DeltaProgram program = {
		.allocator = allocator,
		.runtime_identity = mitos::new_runtime_identity(),
		.schema = manifest.schema,
		.feature_manifest = manifest.features,
	};
	defer program.deinit();
	while (header.cursor < header.bytes.len)
	{
		mitos::DeltaRecordTag tag = (mitos::DeltaRecordTag)header.u32();
		mitos::DeltaRecordFlags flags = (mitos::DeltaRecordFlags)header.u32();
		ulong encoded_length = header.u64();
		(void)flags;
		usz record_length = 0;
		if (!header.bounded_length(encoded_length, &record_length))
		{
			return aot_error(allocator, header.diagnostic);
		}
		AotReader record = {
			.allocator = allocator,
			.bytes = bytes[header.cursor:record_length],
			.decode_budget = &decode_budget,
		};
		header.cursor += record_length;
		switch ((uint)tag)
		{
			case (uint)AOT_MODULE: aot_read_module(&record, &program);
			case (uint)AOT_TYPES: aot_read_types(&record, &program);
			case (uint)AOT_METHODS: aot_read_methods(&record, &program);
			case (uint)AOT_CONSTRUCTORS: aot_read_constructors(&record, &program);
			case (uint)AOT_PRIMITIVES: aot_read_primitives(&record, &program);
			case (uint)AOT_NODES: aot_read_nodes(&record, &program);
			case (uint)AOT_GRAPH: aot_read_graph(&record, &program);
			case (uint)AOT_ROOTS: aot_read_roots(&record, &program);
			case (uint)AOT_SPANS: aot_read_spans(&record, &program);
			case (uint)AOT_EFFECTS: aot_read_effects(&record, &program);
			case (uint)AOT_HELPER_ABI: aot_read_helper_abi(&record, &program);
			default:
				record.cursor = record.bytes.len;
		}
		if (record.failed || record.cursor != record.bytes.len)
		{
			return aot_error(
				allocator,
				record.failed
					? record.diagnostic
					: "AOT v4 known record has trailing bytes"
			);
		}
	}
	if (header.failed || header.cursor != bytes.len
		|| !validate_aot_delta_program(&program))
	{
		return aot_error(
			allocator,
			header.failed
				? header.diagnostic
				: "AOT v4 contains an invalid typed DeltaProgram"
		);
	}
	if (!mitos_jit::mir_supports_required_features(&program))
	{
		DeltaRuntime runtime;
		runtime.init();
		if (!runtime.register_standard_host_handlers(&program))
		{
			(void)runtime.free();
			return aot_error(
				allocator, "AOT v4 generic Delta execution could not register host helpers"
			);
		}
		TypedDeltaExecutionResult execution = runtime.run(&program);
		MitosAotResult generic;
		if (execution.status == TYPED_DELTA_COMPLETE)
		{
			generic = {
				.status = NATIVE,
				.result = execution.formatted.copy(allocator),
				.allocator = allocator,
			};
		}
		else if (execution.status == TYPED_DELTA_SUSPENDED)
		{
			mitos::MitosSpan span = aot_operation_span(
				&program, execution.request.operation
			);
			DeltaTokenActionResult cancelled = runtime.cancel(execution.token, allocator);
			cancelled.deinit();
			generic = aot_error_at(
				allocator,
				"AOT v4 generic execution suspended without an embedding scheduler",
				span
			);
		}
		else
		{
			String message = execution.diagnostics.len
				? execution.diagnostics[0].message
				: "AOT v4 generic Delta execution failed without a diagnostic";
			mitos::MitosSpan span = execution.diagnostics.len
				? execution.diagnostics[0].span : (mitos::MitosSpan){ };
			generic = aot_error_at(allocator, message, span);
		}
		execution.deinit();
		if (!runtime.free() && generic.status == NATIVE)
		{
			generic.free();
			return aot_error(allocator, "AOT v4 generic Delta runtime did not quiesce");
		}
		return generic;
	}
	MitosJitResult native = mitos_jit::jit_delta_program(
		&program, allocator
	);
	MitosAotResult result = {
		.status = native.status,
		.result = native.result,
		.diagnostic = native.diagnostic,
		.diagnostic_span = native.diagnostic_span,
		.allocator = allocator,
	};
	native.result = { }; native.diagnostic = { }; native.allocator = { };
	return result;
}
