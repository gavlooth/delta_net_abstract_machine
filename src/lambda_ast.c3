module delta_net_abstract_machine::lambda_ast;
import mpc;
import std::io;

// io::print("Starting the Delta Net Abstract Machine with Lambda AST support");
// │const String LAMBDA_GRAMMAR = `                                                                                                                           │
// │    term: <abstraction> | <application>;                                                                                                                  │
// │    abstraction: ("λ" | "\\") <ident> "." <term>;                                                                                                         │
// │    application: <atom> <atom>*;                                                                                                                          │
// │    atom: <ident> | "(" <term> ")" | <abstraction>;                                                                                                       │
// │    ident: /[A-Za-z_][A-Za-z0-9_]*/;                                                                                                                      │
// │`;

const String LAMBDA_AST_STRING = `

term : <abstraction> | <application>;
abstraction : ("λ" | "\\") <ident> "." <term> ;
application : <atom> <atom>* ;
atom : <ident> | "(" <term> ")" | <abstraction> ;
ident : /[A-Za-z_][A-Za-z0-9_]*/ ;

` ;




fn void init(){
 LanguageCompileResult compiled = mpc::compile_language(LAMBDA_AST_STRING, mem);
 defer compiled.deinit();  
 assert(compiled.ok(),"Lambda grammar failed") ;
 String source = `λx.λy.y`;
 ParseResult  parsed = compiled.language.parse(source, mem, "term", "<lambda>");
 defer parsed.deinit();

 assert(parsed.ok, "Parsing failed")  ;
 assert(parsed.root.tag == "term");
 io::printfn("%s: %s", parsed.root.tag, parsed.root.text);
 // io::printn(LAMBDA_AST_STRING);
}


