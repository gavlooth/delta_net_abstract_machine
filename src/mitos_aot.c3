module delta_net_abstract_machine;

import delta_net_abstract_machine::mitos;
import delta_net_abstract_machine::mitos_jit;
import delta_net_abstract_machine::mitos_mir;
import libc;
import std::collections::list;
import std::io::file;

const String MITOS_AOT_MAGIC = "MITOSAOT";
const uint MITOS_AOT_VERSION = 3;
const uint MITOS_AOT_ENDIAN_MARKER = 0x01020304;
const usz MITOS_AOT_MAX_BYTES = 64 * 1024 * 1024;
const uint MITOS_AOT_SECTION_COUNT = 10;
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

enum MitosAotSection : uint
{
	AOT_INVALID,
	AOT_TYPES,
	AOT_METHODS,
	AOT_CONSTRUCTORS,
	AOT_PRIMITIVES,
	AOT_NODES,
	AOT_GRAPH,
	AOT_ROOTS,
	AOT_SPANS,
	AOT_EFFECTS,
	AOT_HELPER_ABI,
}

struct MitosAotResult
{
	mitos_mir::MirStatus status;
	String result;
	String diagnostic;
	Allocator allocator;
}

fn void MitosAotResult.free(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.result);
	alloc::free(self.allocator, self.diagnostic);
	*self = { };
}

fn MitosAotResult aot_error(Allocator allocator, String message)
{
	return { .status = ERROR, .diagnostic = message.copy(allocator), .allocator = allocator };
}

struct AotWriter
{
	Allocator allocator;
	List{char} bytes;
	bool failed;
}

fn void AotWriter.init(&self, Allocator allocator)
{
	self.allocator = allocator;
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

fn void AotWriter.string(&self, String value)
{
	if (value.len > (usz)uint::max || self.bytes.size > (sz)MITOS_AOT_MAX_BYTES - (sz)value.len - 4)
	{
		self.failed = true;
		return;
	}
	self.u32((uint)value.len);
	foreach (character : value) self.u8(character);
}

fn void AotWriter.section(&self, MitosAotSection tag, AotWriter* section)
{
	if (section.failed || section.bytes.size > (sz)uint::max
		|| self.bytes.size > (sz)MITOS_AOT_MAX_BYTES - section.bytes.size - 8)
	{
		self.failed = true;
		return;
	}
	self.u32((uint)tag);
	self.u32((uint)section.bytes.size);
	foreach (byte : section.bytes) self.u8(byte);
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
		self.fail("AOT v3 cumulative decode budget exceeds 64 MiB");
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
		self.fail("AOT v3 count exceeds production or section limits");
		return false;
	}
	return self.claim_bytes(count * allocation_item_size);
}

fn char AotReader.u8(&self)
{
	if (self.cursor >= self.bytes.len) { self.fail("truncated AOT v3 payload"); return 0; }
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

fn String AotReader.string(&self)
{
	uint length = self.u32();
	if (self.failed || (usz)length > self.bytes.len - self.cursor)
	{
		self.fail("AOT v3 string extends beyond its section");
		return { };
	}
	if (!self.claim_bytes((usz)length)) return { };
	String value = (String)self.bytes[self.cursor:length];
	self.cursor += length;
	return value.copy(self.allocator);
}

fn mitos::MitosSpan aot_read_span(AotReader* reader)
{
	return {
		.start = {
			.offset = (sz)reader.u64(), .row = (sz)reader.u64(), .column = (sz)reader.u64(),
		},
		.end = {
			.offset = (sz)reader.u64(), .row = (sz)reader.u64(), .column = (sz)reader.u64(),
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
	writer.u32((uint)values.len);
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
		reader.fail("AOT v3 superposition node has invalid type arity");
		return { };
	}
	if (!reader.count(count, mitos::MITOS_DEFAULT_MAX_TYPES, 4, mitos::TypeId::size)) return { };
	mitos::TypeId[] values = alloc::new_array(reader.allocator, mitos::TypeId, count);
	foreach (&value : values) *value = (mitos::TypeId)reader.u32();
	return values;
}

fn void aot_write_strings(AotWriter* writer, String[] values)
{
	writer.u32((uint)values.len);
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

fn void aot_write_pattern(AotWriter* writer, mitos::MethodTypePattern* pattern, uint depth = 0)
{
	if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH) { writer.failed = true; return; }
	writer.u32((uint)pattern.kind);
	writer.string(pattern.name);
	writer.u32((uint)pattern.type_id);
	aot_write_span(writer, pattern.span);
	writer.u32((uint)pattern.arguments.len);
	foreach (&argument : pattern.arguments) aot_write_pattern(writer, argument, depth + 1);
}

fn mitos::MethodTypePattern aot_read_pattern(AotReader* reader, uint depth = 0)
{
	mitos::MethodTypePattern pattern;
	if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH)
	{
		reader.fail("AOT v3 method pattern nesting is too deep");
		return pattern;
	}
	pattern.kind = (mitos::MethodTypePatternKind)reader.u32();
	pattern.name = reader.string();
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
	writer.u32((uint)pattern.arguments.len);
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
		reader.fail("AOT v3 type pattern nesting is too deep");
		return pattern;
	}
	pattern.kind = (mitos::TypePatternKind)reader.u32();
	pattern.variable = reader.string();
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
	writer.u64(program.types.epoch);
	writer.u64((ulong)program.types.max_types);
	writer.u32((uint)program.types.descriptors.len());
	foreach (&descriptor : program.types.descriptors)
	{
		writer.u32((uint)descriptor.id); writer.u32((uint)descriptor.kind); writer.string(descriptor.name);
		aot_write_strings(writer, descriptor.parameters);
		writer.u32((uint)descriptor.nominal_parent); writer.u32((uint)descriptor.constructor);
		aot_write_type_ids(writer, descriptor.arguments); writer.u64((ulong)descriptor.arity);
		aot_write_span(writer, descriptor.span); writer.u32((uint)descriptor.fields.len);
		foreach (&field : descriptor.fields)
		{
			writer.string(field.name); writer.string(field.type_pattern); writer.u32((uint)field.declared_type);
			aot_write_type_pattern(writer, &field.pattern);
			aot_write_span(writer, field.span);
		}
		aot_write_type_ids(writer, descriptor.function_parameters);
		writer.u32((uint)descriptor.function_result);
		aot_write_effect_ids(writer, descriptor.function_effects);
	}
}

fn void aot_read_types(AotReader* reader, mitos::DeltaProgram* program)
{
	program.types = { .allocator = reader.allocator, .epoch = reader.u64(), .max_types = (usz)reader.u64() };
	program.types.descriptors.init(reader.allocator);
	uint count = reader.u32();
	if (!count || !reader.count(count, mitos::MITOS_DEFAULT_MAX_TYPES, 84, mitos::TypeDescriptor::size))
	{
		reader.fail("AOT v3 type registry count is invalid");
		return;
	}
	for (uint index = 0; index < count; index++)
	{
		mitos::TypeId descriptor_id = (mitos::TypeId)reader.u32();
		uint descriptor_kind = reader.u32();
		if (descriptor_kind > (uint)mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
		{
			reader.fail("AOT v3 type descriptor kind is invalid");
			return;
		}
		mitos::TypeDescriptor descriptor = {
			.id = descriptor_id,
			.kind = (mitos::TypeDescriptorKind)descriptor_kind,
			.name = reader.string(),
		};
		descriptor.parameters = aot_read_strings(reader);
		descriptor.nominal_parent = (mitos::TypeId)reader.u32();
		descriptor.constructor = (mitos::TypeId)reader.u32();
		descriptor.arguments = aot_read_type_ids(reader);
		descriptor.arity = (usz)reader.u64();
		descriptor.span = aot_read_span(reader);
		uint field_count = reader.u32();
		if (!reader.count(field_count, mitos::MITOS_MAX_TYPE_FIELDS, 64, mitos::TypeFieldDescriptor::size))
		{
			return;
		}
		descriptor.fields = alloc::new_array(reader.allocator, mitos::TypeFieldDescriptor, field_count);
		foreach (&field : descriptor.fields)
		{
			field.name = reader.string();
			field.type_pattern = reader.string();
			field.declared_type = (mitos::TypeId)reader.u32();
			field.pattern = aot_read_type_pattern(reader);
			field.span = aot_read_span(reader);
		}
		descriptor.function_parameters = aot_read_type_ids(reader);
		descriptor.function_result = (mitos::TypeId)reader.u32();
		descriptor.function_effects = aot_read_effect_ids(reader);
		program.types.descriptors.push(descriptor);
	}
}

fn void aot_write_methods(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u64((ulong)program.methods.max_generics); writer.u64((ulong)program.methods.max_methods);
	writer.u64((ulong)program.methods.method_count); writer.u32((uint)program.methods.generics.len());
	foreach (&generic : program.methods.generics)
	{
		writer.string(generic.name); writer.u64((ulong)generic.arity); writer.u64(generic.epoch);
		writer.u32((uint)generic.methods.len());
		foreach (&method : generic.methods)
		{
			writer.u64((ulong)method.function_index); writer.u32((uint)method.parameters.len);
			foreach (&parameter : method.parameters) aot_write_pattern(writer, parameter);
			aot_write_pattern(writer, &method.result); aot_write_strings(writer, method.type_variables);
			writer.u64((ulong)method.source_order); aot_write_span(writer, method.span);
		}
	}
}

fn void aot_read_methods(AotReader* reader, mitos::DeltaProgram* program)
{
	program.methods = {
		.allocator = reader.allocator,
		.max_generics = (usz)reader.u64(), .max_methods = (usz)reader.u64(),
		.method_count = (usz)reader.u64(),
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
			.name = reader.string(), .arity = (usz)reader.u64(), .epoch = reader.u64(),
		};
		generic.methods.init(reader.allocator);
		uint method_count = reader.u32();
		if (!reader.count(method_count, mitos::MITOS_MAX_METHODS, 136, mitos::MethodDescriptor::size))
		{
			return;
		}
		for (uint method_index = 0; method_index < method_count; method_index++)
		{
			mitos::MethodDescriptor method = { .function_index = (usz)reader.u64() };
			uint parameter_count = reader.u32();
			if (!reader.count(
				parameter_count,
				mitos::MITOS_MAX_METHOD_VARIABLES,
				64,
				mitos::MethodTypePattern::size
			)) return;
			method.parameters = alloc::new_array(reader.allocator, mitos::MethodTypePattern, parameter_count);
			foreach (&parameter : method.parameters) *parameter = aot_read_pattern(reader);
			method.result = aot_read_pattern(reader); method.type_variables = aot_read_strings(reader);
			method.source_order = (usz)reader.u64(); method.span = aot_read_span(reader);
			generic.methods.push(method);
		}
		program.methods.generics.push(generic);
	}
}

fn void aot_write_constructors(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u32((uint)program.constructors.len);
	foreach (&constructor : program.constructors)
	{
		writer.u32(constructor.id); writer.string(constructor.name);
		writer.u32((uint)constructor.runtime_type); writer.u32((uint)constructor.type_constructor);
		aot_write_strings(writer, constructor.parameters);
		aot_write_strings(writer, constructor.fields); aot_write_type_ids(writer, constructor.field_types);
		writer.u32((uint)constructor.field_patterns.len);
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
		constructor.id = reader.u32(); constructor.name = reader.string();
		constructor.runtime_type = (mitos::TypeId)reader.u32();
		constructor.type_constructor = (mitos::TypeId)reader.u32();
		constructor.parameters = aot_read_strings(reader);
		constructor.fields = aot_read_strings(reader);
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
	writer.u32((uint)program.primitives.len);
	foreach (&primitive : program.primitives)
	{
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
		primitive.id = reader.u32(); primitive.operation = (mitos::DeltaPrimitiveOp)reader.u32();
		primitive.name = reader.string(); primitive.arity = (usz)reader.u64();
		primitive.parameters = aot_read_type_ids(reader); primitive.result = (mitos::TypeId)reader.u32();
	}
}

fn void aot_write_nodes(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u32((uint)program.image.nodes.len);
	foreach (&node : program.image.nodes)
	{
		writer.u32(node.stable_id); writer.u32((uint)node.kind); writer.u32((uint)node.static_type); writer.u32(node.span);
		writer.u64((ulong)node.integer); writer.string(node.string_value);
		writer.u64((ulong)node.descriptor); writer.string(node.name);
		aot_write_strings(writer, node.names); aot_write_type_ids(writer, node.types);
		writer.u32((uint)node.runtime_type); writer.u32((uint)node.result_type);
		aot_write_effect_ids(writer, node.effect_row);
		writer.u32((uint)node.inputs.len); foreach (input : node.inputs) writer.u32((uint)input);
		writer.u32((uint)node.branches.len);
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
		reader.fail("AOT v3 node count exceeds runtime limits");
		return;
	}
	program.image.nodes = alloc::new_array(reader.allocator, mitos::DeltaNode, count);
	foreach (&node : program.image.nodes)
	{
		node.stable_id = reader.u32();
		uint node_kind = reader.u32();
		if (node_kind > (uint)mitos::DeltaNodeKind.DELTA_COLLAPSE)
		{
			reader.fail("AOT v3 node kind is invalid");
			return;
		}
		node.kind = (mitos::DeltaNodeKind)node_kind;
		node.static_type = (mitos::TypeId)reader.u32(); node.span = reader.u32();
		node.integer = (long)reader.u64(); node.string_value = reader.string();
		node.descriptor = (usz)reader.u64(); node.name = reader.string();
		bool superposition_node = node.kind == mitos::DeltaNodeKind.DELTA_SUPERPOSE
			|| node.kind == mitos::DeltaNodeKind.DELTA_COLLAPSE;
		if (superposition_node && (!node.descriptor || node.descriptor > program.image.nodes.len))
		{
			reader.fail("AOT v3 superposition node origin is invalid");
			return;
		}
		node.names = aot_read_strings(reader);
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
			reader.fail("AOT v3 superposition node type metadata is invalid");
			return;
		}
		node.effect_row = aot_read_effect_ids(reader);
		uint input_count = reader.u32();
		if (superposition_node
			&& ((node.kind == mitos::DeltaNodeKind.DELTA_SUPERPOSE && !input_count)
				|| (node.kind == mitos::DeltaNodeKind.DELTA_COLLAPSE && input_count != 1)))
		{
			reader.fail("AOT v3 superposition node input arity is invalid");
			return;
		}
		if (!reader.count(input_count, MITOS_AOT_MAX_EDGES, 4, mitos::DeltaNodeId::size)) return;
		node.inputs = alloc::new_array(reader.allocator, mitos::DeltaNodeId, input_count);
		foreach (&input : node.inputs) *input = (mitos::DeltaNodeId)reader.u32();
		uint branch_count = reader.u32();
		if (superposition_node && branch_count)
		{
			reader.fail("AOT v3 superposition node cannot contain match branches");
			return;
		}
		if (!reader.count(branch_count, mitos::MITOS_MAX_MATCH_ARMS, 20, mitos::DeltaMatchBranch::size))
		{
			return;
		}
		node.branches = alloc::new_array(reader.allocator, mitos::DeltaMatchBranch, branch_count);
		foreach (&branch : node.branches)
		{
			branch.wildcard = reader.u32() != 0; branch.constructor = reader.u32();
			branch.bindings = aot_read_strings(reader); branch.body = (mitos::DeltaNodeId)reader.u32(); branch.span = reader.u32();
		}
	}
}

fn void aot_write_graph(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u32((uint)program.image.edges.len);
	foreach (&edge : program.image.edges) { writer.u32((uint)edge.producer); writer.u32((uint)edge.consumer); writer.u64((ulong)edge.input); }
	writer.u32((uint)program.image.interfaces.len);
	foreach (&boundary : program.image.interfaces)
	{
		writer.u32((uint)boundary.kind); writer.string(boundary.name); writer.u32((uint)boundary.root); writer.u64((ulong)boundary.source_order);
	}
	writer.u32((uint)program.image.parallel_regions.len);
	foreach (&region : program.image.parallel_regions)
	{
		writer.u32((uint)region.roots.len); foreach (root : region.roots) writer.u32((uint)root);
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
		edge.input = (usz)reader.u64();
	}
	uint interface_count = reader.u32();
	if (!reader.count(interface_count, MITOS_AOT_MAX_INTERFACES, 20, mitos::DeltaInterface::size)) return;
	program.image.interfaces = alloc::new_array(reader.allocator, mitos::DeltaInterface, interface_count);
	foreach (&boundary : program.image.interfaces)
	{
		boundary.kind = (mitos::DeltaInterfaceKind)reader.u32(); boundary.name = reader.string();
		boundary.root = (mitos::DeltaNodeId)reader.u32(); boundary.source_order = (usz)reader.u64();
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
		region.join = (mitos::DeltaNodeId)reader.u32(); region.source_order = (usz)reader.u64();
	}
}

fn void aot_write_roots(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u32((uint)program.entry); writer.u32((uint)program.method_roots.len);
	foreach (&root : program.method_roots)
	{
		writer.u64((ulong)root.function_index); writer.u64((ulong)root.generic_index); writer.u64((ulong)root.method_index);
		writer.u32((uint)root.root); aot_write_strings(writer, root.parameters); aot_write_type_ids(writer, root.parameter_types);
		writer.u32((uint)root.parameter_patterns.len);
		foreach (&pattern : root.parameter_patterns) aot_write_pattern(writer, pattern);
		writer.u32((uint)root.result_type); aot_write_pattern(writer, &root.result_pattern);
		aot_write_effect_ids(writer, root.effect_row); writer.u64((ulong)root.source_order);
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
		root.function_index = (usz)reader.u64(); root.generic_index = (usz)reader.u64(); root.method_index = (usz)reader.u64();
		root.root = (mitos::DeltaNodeId)reader.u32(); root.parameters = aot_read_strings(reader);
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
		root.effect_row = aot_read_effect_ids(reader);
		root.source_order = (usz)reader.u64();
	}
}

fn void aot_write_spans(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u32((uint)program.spans.len); foreach (span : program.spans) aot_write_span(writer, span);
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
	writer.u32((uint)values.len); foreach (value : values) writer.u32((uint)value);
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
	writer.u64(program.effects.epoch); writer.u32((uint)program.effects.effects.len);
	foreach (&effect : program.effects.effects)
	{
		writer.u32((uint)effect.id); writer.string(effect.name); writer.u32(effect.multi ? 1 : 0);
		aot_write_strings(writer, effect.parameters); writer.u32((uint)effect.operations.len);
		foreach (operation : effect.operations) writer.u32((uint)operation);
		writer.u32(effect.span);
	}
	writer.u32((uint)program.effects.operations.len);
	foreach (&operation : program.effects.operations)
	{
		writer.u32((uint)operation.id); writer.u32((uint)operation.effect); writer.string(operation.name);
		aot_write_strings(writer, operation.parameter_patterns);
		writer.u32((uint)operation.parameter_types.len);
		foreach (&pattern : operation.parameter_types) aot_write_type_pattern(writer, pattern);
		writer.string(operation.result_pattern); aot_write_type_pattern(writer, &operation.result_type);
		writer.u32(operation.span); writer.u32((uint)operation.host_kind); writer.u32(operation.ordered ? 1 : 0);
	}
	writer.u32((uint)program.effects.instances.len);
	foreach (&instance : program.effects.instances)
	{
		writer.u32((uint)instance.id); writer.u32((uint)instance.constructor);
		aot_write_type_ids(writer, instance.arguments);
	}
	writer.u32((uint)program.effects.rows.len);
	foreach (&row : program.effects.rows)
	{
		writer.u64((ulong)row.function_index); aot_write_effect_ids(writer, row.inferred);
		aot_write_effect_ids(writer, row.asserted); writer.u32(row.has_assertion ? 1 : 0); writer.u64(row.effect_epoch);
	}
	writer.u32((uint)program.effects.handlers.len);
	foreach (&handler : program.effects.handlers)
	{
		writer.u32(handler.stable_id); writer.u32((uint)handler.handled); writer.u32((uint)handler.clauses.len);
		foreach (&clause : handler.clauses)
		{
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
		effect.id = (mitos::EffectId)reader.u32(); effect.name = reader.string(); effect.multi = reader.u32() != 0;
		effect.parameters = aot_read_strings(reader);
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
		operation.id = (mitos::OperationId)reader.u32(); operation.effect = (mitos::EffectId)reader.u32();
		operation.name = reader.string(); operation.parameter_patterns = aot_read_strings(reader);
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
		operation.host_kind = (mitos::DeltaEffectHostKind)reader.u32(); operation.ordered = reader.u32() != 0;
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
		row.function_index = (usz)reader.u64(); row.inferred = aot_read_effect_ids(reader);
		row.asserted = aot_read_effect_ids(reader); row.has_assertion = reader.u32() != 0; row.effect_epoch = reader.u64();
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
			clause.stable_id = reader.u32(); clause.effect = (mitos::EffectId)reader.u32();
			clause.operation = (mitos::OperationId)reader.u32(); clause.parameters = aot_read_strings(reader);
			clause.parameter_types = aot_read_type_ids(reader);
			clause.result_type = (mitos::TypeId)reader.u32();
			clause.body = (mitos::DeltaNodeId)reader.u32();
			clause.span = reader.u32(); clause.resume_count = (usz)reader.u64();
			clause.multi = reader.u32() != 0;
		}
		handler.return_parameter = reader.string(); handler.return_type = (mitos::TypeId)reader.u32();
		handler.return_body = (mitos::DeltaNodeId)reader.u32(); handler.span = reader.u32();
		handler.source_order = (usz)reader.u64();
	}
}

fn void aot_write_helper_abi(AotWriter* writer, mitos::DeltaProgram* program)
{
	writer.u32(program.format_version); writer.u32(program.helper_abi.major); writer.u32(program.helper_abi.minor);
	writer.u64(program.helper_abi.feature_bits); writer.u32(program.helper_abi.effect_tag); writer.u32(program.helper_abi.handler_tag);
	writer.u32(program.helper_abi.resume_tag); writer.u32(program.helper_abi.abort_tag);
}

fn void aot_read_helper_abi(AotReader* reader, mitos::DeltaProgram* program)
{
	program.format_version = reader.u32(); program.helper_abi.major = reader.u32(); program.helper_abi.minor = reader.u32();
	program.helper_abi.feature_bits = reader.u64(); program.helper_abi.effect_tag = reader.u32();
	program.helper_abi.handler_tag = reader.u32(); program.helper_abi.resume_tag = reader.u32(); program.helper_abi.abort_tag = reader.u32();
}

fn MitosAotResult write_mitos_aot(mitos::DeltaProgram* program, String output, Allocator allocator = mem)
{
	if (!program || program.format_version != mitos::DELTA_PROGRAM_FORMAT_VERSION || !program.entry)
	{
		return aot_error(allocator, "AOT v3 requires a complete DeltaProgram");
	}
	if (!validate_aot_delta_program(program))
	{
		return aot_error(allocator, "AOT v3 rejected invalid typed Delta or helper metadata");
	}
	AotWriter artifact; artifact.init(allocator); defer artifact.deinit();
	foreach (character : MITOS_AOT_MAGIC) artifact.u8(character);
	artifact.u32(MITOS_AOT_VERSION); artifact.u32(MITOS_AOT_ENDIAN_MARKER); artifact.u32(MITOS_AOT_SECTION_COUNT); artifact.u32(0);
	AotWriter section; section.init(allocator);
	aot_write_types(&section, program); artifact.section(AOT_TYPES, &section); section.deinit(); section.init(allocator);
	aot_write_methods(&section, program); artifact.section(AOT_METHODS, &section); section.deinit(); section.init(allocator);
	aot_write_constructors(&section, program); artifact.section(AOT_CONSTRUCTORS, &section); section.deinit(); section.init(allocator);
	aot_write_primitives(&section, program); artifact.section(AOT_PRIMITIVES, &section); section.deinit(); section.init(allocator);
	aot_write_nodes(&section, program); artifact.section(AOT_NODES, &section); section.deinit(); section.init(allocator);
	aot_write_graph(&section, program); artifact.section(AOT_GRAPH, &section); section.deinit(); section.init(allocator);
	aot_write_roots(&section, program); artifact.section(AOT_ROOTS, &section); section.deinit(); section.init(allocator);
	aot_write_spans(&section, program); artifact.section(AOT_SPANS, &section); section.deinit(); section.init(allocator);
	aot_write_effects(&section, program); artifact.section(AOT_EFFECTS, &section); section.deinit(); section.init(allocator);
	aot_write_helper_abi(&section, program); artifact.section(AOT_HELPER_ABI, &section); section.deinit();
	if (artifact.failed || artifact.bytes.size > (sz)MITOS_AOT_MAX_BYTES) return aot_error(allocator, "AOT v3 artifact exceeds the 64 MiB format limit");
	char[] bytes = artifact.bytes.to_array(allocator); defer alloc::free(allocator, bytes);
	DString temporary; temporary.init(allocator); defer temporary.free(); temporary.append_string(output); temporary.append_string(".tmp");
	if (catch err = file::save(temporary.str_view(), bytes)) { (void)err; return aot_error(allocator, "unable to write temporary AOT v3 artifact"); }
	if (libc::rename(temporary.str_view().zstr_tcopy(), output.zstr_tcopy()) != 0)
	{ (void)file::delete(temporary.str_view()); return aot_error(allocator, "unable to atomically replace AOT v3 artifact"); }
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

fn bool aot_valid_effect_id(mitos::DeltaProgram* program, mitos::EffectId effect_id)
{
	if (!effect_id) return false;
	foreach (&effect : program.effects.effects) if (effect.id == effect_id) return true;
	foreach (&instance : program.effects.instances) if (instance.id == effect_id) return true;
	return false;
}

fn bool aot_valid_type_pattern(
	mitos::DeltaProgram* program,
	mitos::TypePattern* pattern,
	uint depth = 0
)
{
	if (depth >= mitos::MITOS_MAX_TYPE_FORMAT_DEPTH
		|| (uint)pattern.kind > (uint)mitos::TypePatternKind.TYPE_PATTERN_APPLICATION)
	{
		return false;
	}
	switch (pattern.kind)
	{
		case TYPE_PATTERN_ANY:
			return !pattern.variable.len && !pattern.constructor && !pattern.arguments.len;
		case TYPE_PATTERN_VARIABLE:
			return pattern.variable.len != 0 && !pattern.constructor && !pattern.arguments.len;
		case TYPE_PATTERN_EXACT:
			return aot_valid_type(program, pattern.constructor) && !pattern.arguments.len;
		case TYPE_PATTERN_APPLICATION:
			if (!aot_valid_type(program, pattern.constructor)) return false;
			foreach (&argument : pattern.arguments)
				if (!aot_valid_type_pattern(program, argument, depth + 1)) return false;
			return true;
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
	return descriptor != null
		&& descriptor.id == id
		&& descriptor.kind == kind
		&& descriptor.name == name
		&& descriptor.nominal_parent == parent
		&& descriptor.arity == arity
		&& !descriptor.parameters.len
		&& !descriptor.constructor
		&& !descriptor.arguments.len
		&& !descriptor.fields.len
		&& !descriptor.function_parameters.len
		&& !descriptor.function_result
		&& !descriptor.function_effects.len;
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
		if (!node.inputs.len || !aot_valid_unary_runtime_type(
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

fn bool validate_aot_delta_program(mitos::DeltaProgram* program)
{
	if (!program || program.format_version != mitos::DELTA_PROGRAM_FORMAT_VERSION
		|| program.helper_abi.major != mitos::DELTA_HELPER_ABI_MAJOR
		|| program.helper_abi.minor != mitos::DELTA_HELPER_ABI_MINOR
		|| (program.helper_abi.feature_bits & (ulong)0x1f) != program.helper_abi.feature_bits
		|| (program.helper_abi.feature_bits & (ulong)0x10) == 0
		|| program.helper_abi.effect_tag != 32 || program.helper_abi.handler_tag != 33
		|| program.helper_abi.resume_tag != 34 || program.helper_abi.abort_tag != 35
		|| !program.effects.epoch
		|| !aot_valid_node(program, program.entry)
		|| !program.types.epoch
		|| program.types.max_types < (usz)program.types.descriptors.len()
		|| program.types.max_types > mitos::MITOS_DEFAULT_MAX_TYPES
		|| !aot_valid_superposition_bootstrap(program)) return false;
	foreach (index, &type : program.types.descriptors)
	{
		if ((usz)type.id != (usz)index + 1 || !type.name.len
			|| (uint)type.kind > (uint)mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
			|| type.arity > mitos::MITOS_MAX_CONSTRUCTOR_FIELDS
			|| (type.nominal_parent && !aot_valid_type(program, type.nominal_parent))
			|| (type.constructor && !aot_valid_type(program, type.constructor))) return false;
		if (type.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE)
		{
			mitos::TypeDescriptor* constructor = mitos::type_descriptor(
				&program.types,
				type.constructor
			);
			if (!constructor
				|| constructor.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_INSTANCE
				|| constructor.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE
				|| type.arguments.len != constructor.arity) return false;
		}
		else if (type.kind == mitos::TypeDescriptorKind.TYPE_DESCRIPTOR_FUNCTION_INSTANCE)
		{
			if (type.constructor != mitos::TYPE_ID_FUNCTION
				|| !aot_valid_type(program, type.function_result)
				|| type.arguments.len) return false;
		}
		foreach (argument : type.arguments) if (!aot_valid_type(program, argument)) return false;
		foreach (parameter : type.function_parameters)
			if (!aot_valid_type(program, parameter)) return false;
		foreach (effect : type.function_effects)
			if (!aot_valid_effect_id(program, effect)) return false;
		if (type.function_result && !aot_valid_type(program, type.function_result)) return false;
		foreach (&field : type.fields)
			if (!field.name.len || !aot_valid_type(program, field.declared_type)
				|| !aot_valid_type_pattern(program, &field.pattern)) return false;
	}
	foreach (generic_index, &generic : program.methods.generics)
	{
		if (!generic.name.len || !generic.epoch || generic.arity > mitos::MITOS_MAX_METHOD_VARIABLES) return false;
		foreach (method_index, &method : generic.methods)
		{
			bool found_root = false;
			if (method.parameters.len != generic.arity) return false;
			foreach (&root : program.method_roots)
			{
				if (root.generic_index == (usz)generic_index && root.method_index == (usz)method_index
					&& root.function_index == method.function_index) { found_root = true; break; }
			}
			if (!found_root) return false;
		}
	}
	foreach (index, &constructor : program.constructors)
	{
		if (constructor.id != (uint)index + 1 || !constructor.name.len
			|| (!constructor.parameters.len && !aot_valid_type(program, constructor.runtime_type))
			|| (constructor.parameters.len && constructor.runtime_type != mitos::TYPE_ID_INVALID)
			|| !aot_valid_type(program, constructor.type_constructor)
			|| constructor.fields.len != constructor.field_types.len
			|| constructor.fields.len != constructor.field_patterns.len) return false;
		foreach (type_id : constructor.field_types) if (!aot_valid_type(program, type_id)) return false;
		foreach (&pattern : constructor.field_patterns)
			if (!aot_valid_type_pattern(program, pattern)) return false;
	}
	foreach (index, &primitive : program.primitives)
	{
		if (primitive.id != (uint)index + 1 || !primitive.name.len
			|| primitive.arity != primitive.parameters.len || !aot_valid_type(program, primitive.result)) return false;
		foreach (type_id : primitive.parameters) if (!aot_valid_type(program, type_id)) return false;
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
			if (!aot_valid_type(program, type_id)) return false;
		foreach (effect : node.effect_row)
			if (!aot_valid_effect_id(program, effect)) return false;
		foreach (input : node.inputs) if (!aot_valid_node(program, input)) return false;
		foreach (&branch : node.branches)
		{
			if (!aot_valid_node(program, branch.body)
				|| (branch.span && (usz)branch.span > program.spans.len)
				|| (!branch.wildcard && (usz)branch.constructor >= program.constructors.len)) return false;
		}
		switch (node.kind)
		{
			case DELTA_LOCAL:
				if (!node.name.len || node.inputs.len) return false;
			case DELTA_I64:
				if (node.static_type != mitos::TYPE_ID_I64 || node.inputs.len) return false;
			case DELTA_STRING:
				if (node.static_type != mitos::TYPE_ID_STRING || node.inputs.len) return false;
			case DELTA_LAMBDA:
				if (node.inputs.len != 1 || node.names.len != node.types.len
					|| !node.runtime_type || !node.result_type) return false;
			case DELTA_APPLY:
				if (!node.inputs.len) return false;
			case DELTA_LET:
				if (!node.names.len || node.inputs.len != node.names.len + 1) return false;
			case DELTA_CONSTRUCTOR:
				if (node.descriptor >= program.constructors.len) return false;
				mitos::DeltaConstructorDescriptor* constructor =
					&program.constructors[node.descriptor];
				if (node.inputs.len != constructor.fields.len
					|| (!constructor.parameters.len
						&& !aot_valid_type(program, node.runtime_type))
					|| (constructor.parameters.len && node.runtime_type
						&& !aot_valid_type(program, node.runtime_type))) return false;
			case DELTA_MATCH:
				if (node.inputs.len != 1 || !node.branches.len) return false;
			case DELTA_GENERIC_CALL:
				if (node.descriptor >= (usz)program.methods.generics.len()
					|| node.inputs.len != program.methods.generics[(sz)node.descriptor].arity
					|| node.name != program.methods.generics[(sz)node.descriptor].name) return false;
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
					|| node.inputs.len != program.primitives[node.descriptor].arity) return false;
			case DELTA_PARALLEL_ROOT:
				if (node.inputs.len != 1 || !node.name.len) return false;
			case DELTA_PARALLEL_JOIN:
				if (node.names.len != node.types.len
					|| node.inputs.len != node.names.len + 1) return false;
			case DELTA_EFFECT:
				if (node.descriptor >= program.effects.operations.len
					|| node.inputs.len != program.effects.operations[node.descriptor].parameter_types.len
					|| node.types.len != node.inputs.len + 1
					|| node.types[node.types.len - 1] != node.result_type) return false;
			case DELTA_HANDLER:
				if (node.descriptor >= program.effects.handlers.len
					|| node.inputs.len != program.effects.handlers[node.descriptor].clauses.len + 2) return false;
			case DELTA_RESUME:
				if (node.descriptor >= program.effects.handlers.len
					|| node.inputs.len != 1 || node.types.len != 1
					|| node.types[0] != node.result_type) return false;
			case DELTA_ABORT:
				if (node.descriptor >= program.effects.handlers.len || node.inputs.len != 1) return false;
			case DELTA_SUPERPOSE:
			case DELTA_COLLAPSE:
				if (!aot_valid_superposition_node(program, node)) return false;
			default:
		}
	}
	foreach (&edge : program.image.edges)
	{
		if (!aot_valid_node(program, edge.producer) || !aot_valid_node(program, edge.consumer)) return false;
	}
	foreach (&boundary : program.image.interfaces) if (!aot_valid_node(program, boundary.root)) return false;
	foreach (&region : program.image.parallel_regions)
	{
		if (!aot_valid_node(program, region.join)) return false;
		foreach (root : region.roots) if (!aot_valid_node(program, root)) return false;
	}
	foreach (&root : program.method_roots)
	{
		if (!aot_valid_node(program, root.root)
			|| root.parameters.len != root.parameter_types.len
			|| root.parameters.len != root.parameter_patterns.len
			|| root.generic_index >= (usz)program.methods.generics.len()
			|| !aot_valid_type(program, root.result_type)) return false;
		foreach (type_id : root.parameter_types) if (!aot_valid_type(program, type_id)) return false;
		foreach (effect : root.effect_row)
			if (!aot_valid_effect_id(program, effect)) return false;
	}
	foreach (&instance : program.effects.instances)
	{
		if (!instance.id || !instance.constructor
			|| instance.constructor >= program.effects.next_effect_id)
		{
			return false;
		}
		bool found_constructor = false;
		foreach (&effect : program.effects.effects)
			if (effect.id == instance.constructor) { found_constructor = true; break; }
		if (!found_constructor) return false;
		foreach (type_id : instance.arguments) if (!aot_valid_type(program, type_id)) return false;
	}
	foreach (&row : program.effects.rows)
	{
		if (row.effect_epoch != program.effects.epoch) return false;
		foreach (effect : row.inferred)
			if (!aot_valid_effect_id(program, effect)) return false;
		foreach (effect : row.asserted)
			if (!aot_valid_effect_id(program, effect)) return false;
	}
	foreach (effect_index, &effect : program.effects.effects)
	{
		if (!effect.id || effect.id >= program.effects.next_effect_id || !effect.name.len) return false;
		foreach (operation_id : effect.operations)
		{
			bool found_operation = false;
			foreach (&operation : program.effects.operations)
				if (operation.id == operation_id && operation.effect == effect.id)
				{ found_operation = true; break; }
			if (!found_operation) return false;
		}
		foreach (previous_index, &previous : program.effects.effects)
			if (previous_index < effect_index && previous.id == effect.id) return false;
	}
	foreach (&operation : program.effects.operations)
	{
		if (!operation.id || operation.id >= program.effects.next_operation_id
			|| !operation.effect || operation.effect >= program.effects.next_effect_id
			|| !operation.name.len
			|| (uint)operation.host_kind > (uint)mitos::DeltaEffectHostKind.DELTA_EFFECT_EXTERNAL)
		{
			return false;
		}
		bool found_effect = false;
		foreach (&effect : program.effects.effects)
			if (effect.id == operation.effect) { found_effect = true; break; }
		if (!found_effect) return false;
		if (operation.parameter_patterns.len != operation.parameter_types.len
			|| !aot_valid_type_pattern(program, &operation.result_type)) return false;
		foreach (&pattern : operation.parameter_types)
			if (!aot_valid_type_pattern(program, pattern)) return false;
	}
	foreach (handler_index, &handler : program.effects.handlers)
	{
		if (handler.stable_id != (uint)handler_index + 1
			|| !aot_valid_node(program, handler.handled)
			|| !aot_valid_node(program, handler.return_body)
			|| !aot_valid_type(program, handler.return_type)) return false;
		foreach (clause_index, &clause : handler.clauses)
		{
			if (clause.stable_id != (uint)clause_index + 1 || !clause.effect || !clause.operation
				|| !aot_valid_node(program, clause.body)
				|| !aot_valid_type(program, clause.result_type)
				|| clause.parameters.len != clause.parameter_types.len) return false;
			mitos::EffectId effect_constructor = clause.effect;
			foreach (&instance : program.effects.instances)
				if (instance.id == clause.effect) { effect_constructor = instance.constructor; break; }
			mitos::DeltaEffectDescriptor* clause_effect = null;
			foreach (&effect : program.effects.effects)
				if (effect.id == effect_constructor) { clause_effect = effect; break; }
			if (!clause_effect || clause.multi != clause_effect.multi) return false;
			bool found_operation = false;
			foreach (&operation : program.effects.operations)
				if (operation.id == clause.operation && operation.effect == effect_constructor)
				{ found_operation = true; break; }
			if (!found_operation) return false;
			foreach (type_id : clause.parameter_types) if (!aot_valid_type(program, type_id)) return false;
		}
	}
	return true;
}

fn MitosAotResult execute_mitos_aot(String path, Allocator allocator = mem)
{
	long? size_result = file::get_size(path);
	if (catch err = size_result) { (void)err; return aot_error(allocator, "unable to inspect AOT artifact"); }
	long size = size_result;
	if (size < 24 || (ulong)size > MITOS_AOT_MAX_BYTES) return aot_error(allocator, "AOT artifact size is outside the v3 range");
	char[] storage = alloc::new_array(allocator, char, (usz)size + 1); defer alloc::free(allocator, storage);
	char[]? loaded = file::load_buffer(path, storage);
	if (catch err = loaded) { (void)err; return aot_error(allocator, "unable to read AOT artifact"); }
	char[] bytes = loaded;
	if (bytes.len != (usz)size || (String)bytes[:MITOS_AOT_MAGIC.len] != MITOS_AOT_MAGIC) return aot_error(allocator, "invalid AOT artifact magic");
	usz decode_budget = MITOS_AOT_MAX_DECODE_BYTES;
	AotReader header = {
		.allocator = allocator,
		.bytes = bytes,
		.cursor = MITOS_AOT_MAGIC.len,
		.decode_budget = &decode_budget,
	};
	uint version = header.u32();
	if (version == 1) return aot_error(allocator, "AOT v1 artifacts are no longer supported; rebuild as AOT v3");
	if (version == 2) return aot_error(allocator, "AOT v2 artifacts are no longer supported; rebuild as AOT v3");
	if (version != MITOS_AOT_VERSION) return aot_error(allocator, "unsupported AOT artifact version; expected AOT v3");
	if (header.u32() != MITOS_AOT_ENDIAN_MARKER || header.u32() != MITOS_AOT_SECTION_COUNT || header.u32() != 0)
	{
		return aot_error(allocator, "AOT v3 header is invalid");
	}
	mitos::DeltaProgram program = { .allocator = allocator };
	defer program.deinit();
	for (uint expected = 1; expected <= MITOS_AOT_SECTION_COUNT; expected++)
	{
		uint tag = header.u32(); uint length = header.u32();
		if (header.failed || tag != expected || (usz)length > bytes.len - header.cursor)
		{
			return aot_error(allocator, "AOT v3 section table is invalid or out of order");
		}
		AotReader section = {
			.allocator = allocator,
			.bytes = bytes[header.cursor:length],
			.decode_budget = &decode_budget,
		};
		header.cursor += length;
		switch ((MitosAotSection)tag)
		{
			case AOT_TYPES: aot_read_types(&section, &program);
			case AOT_METHODS: aot_read_methods(&section, &program);
			case AOT_CONSTRUCTORS: aot_read_constructors(&section, &program);
			case AOT_PRIMITIVES: aot_read_primitives(&section, &program);
			case AOT_NODES: aot_read_nodes(&section, &program);
			case AOT_GRAPH: aot_read_graph(&section, &program);
			case AOT_ROOTS: aot_read_roots(&section, &program);
			case AOT_SPANS: aot_read_spans(&section, &program);
			case AOT_EFFECTS: aot_read_effects(&section, &program);
			case AOT_HELPER_ABI: aot_read_helper_abi(&section, &program);
			default: section.fail("unknown AOT v3 section");
		}
		if (section.failed || section.cursor != section.bytes.len)
		{
			return aot_error(allocator, section.failed ? section.diagnostic : "AOT v3 section has trailing bytes");
		}
	}
	if (header.cursor != bytes.len) return aot_error(allocator, "AOT v3 artifact has trailing bytes");
	if (!validate_aot_delta_program(&program))
	{
		return aot_error(allocator, "AOT v3 contains an invalid typed DeltaProgram");
	}
	MitosJitResult native = mitos_jit::jit_delta_program(&program, null, allocator);
	MitosAotResult result = {
		.status = native.status, .result = native.result, .diagnostic = native.diagnostic, .allocator = allocator,
	};
	native.result = { }; native.diagnostic = { }; native.allocator = { };
	return result;
}
