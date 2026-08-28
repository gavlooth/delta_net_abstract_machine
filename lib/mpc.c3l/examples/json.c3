// SPDX-License-Identifier: BSD-2-Clause-FreeBSD
// Copyright (c) 2013 Daniel Holden
// C3 port modifications copyright (c) 2026 mpc contributors

module json_example;

import mpc;
import std::io;

fn void count_node(AstNode* node, void* context)
{
    sz* count = (sz*)context;
    (*count)++;
}

fn int main()
{
    String grammar = `
        json ["JSON value"]: <value>;
        value: <object> | <array> | <string> | <number>
             | "true" | "false" | "null";
        object: "{" (<member> ("," <member>)*)? "}";
        member: <string> ":" <value>;
        array: "[" (<value> ("," <value>)*)? "]";
        string ["string"]: /"([^"\\]|\\.)*"/;
        number ["number"]: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/;
    `;

    LanguageCompileResult compiled = mpc::compile_language(grammar, mem);
    defer compiled.deinit();
    if (!compiled.ok())
    {
        foreach (&diagnostic : compiled.diagnostics)
        {
            DString rendered = mpc::render_diagnostic(diagnostic, "json grammar", grammar);
            io::print(rendered.str_view());
            rendered.free();
        }
        return 1;
    }

    String input = `{"project":"mpc","ready":true,"values":[1,2,3]}`;
    ParseResult parsed = compiled.language.parse(input, mem, "json", "example.json");
    defer parsed.deinit();
    if (!parsed.ok)
    {
        DString rendered = mpc::render_diagnostic(&parsed.diagnostic,
                                                  "example.json", input);
        io::print(rendered.str_view());
        rendered.free();
        return 1;
    }

    sz node_count = 0;
    mpc::walk_ast(parsed.root, PREORDER, &count_node, &node_count);
    io::print("parsed JSON-like document; AST nodes: ");
    io::printfn("%d", (long)node_count);
    return 0;
}
