// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module mpc;

import std::core::mem;

struct SourcePos
{
	sz offset;
	sz row;
	sz column;
}

fn SourcePos source_start() => { .offset = 0, .row = 1, .column = 1 };

struct Span
{
	SourcePos start;
	SourcePos end;
}

fn Span span_at(SourcePos position) => { .start = position, .end = position };
fn sz Span.length(&self) => self.end.offset - self.start.offset;
fn bool Span.is_empty(&self) => self.start.offset == self.end.offset;
fn bool Span.contains(&self, SourcePos position)
{
	return position.offset >= self.start.offset && position.offset < self.end.offset;
}

struct Diagnostic
{
	Allocator allocator;
	String message;
	String[] expected;
	Span span;
}

fn Diagnostic* Diagnostic.init(&self, Allocator allocator, String message, Span span)
{
	*self = {
		.allocator = allocator,
		.message = message.copy(allocator),
		.span = span,
	};
	return self;
}

fn void Diagnostic.add_expected(&self, String label)
{
	if (!label.len) return;
	foreach (item : self.expected)
	{
		if (item == label) return;
	}
	sz old_length = self.expected.len;
	self.expected = alloc::realloc_array(self.allocator, self.expected.ptr, String, old_length + 1);
	self.expected[old_length] = label.copy(self.allocator);
}

fn void Diagnostic.deinit(&self)
{
	if (!self.allocator) return;
	alloc::free(self.allocator, self.message);
	foreach (item : self.expected) alloc::free(self.allocator, item);
	alloc::free(self.allocator, self.expected);
	*self = {};
}

struct AstNode
{
	String tag;
	String text;
	Span span;
	AstNode*[] children;
}

fn sz AstNode.child_count(&self) => self.children.len;
fn bool AstNode.is_leaf(&self) => self.children.len == 0;
fn bool AstNode.text_is(&self, String text) => self.text == text;

fn AstNode* AstNode.child(&self, sz index)
{
	if (index >= self.children.len) return null;
	return self.children[index];
}

fn AstNode* AstNode.find(&self, String tag)
{
	if (self.tag == tag) return self;
	foreach (child : self.children)
	{
		AstNode* found = child.find(tag);
		if (found) return found;
	}
	return null;
}
