module delta_net_abstract_machine::lambda_ast;
import mpc;
import std::io;

// io::print("Starting the Delta Net Abstract Machine with Lambda AST support");
│
// │const String LAMBDA_GRAMMAR = `                                                                                                                           │
// │    term: <abstraction> | <application>;                                                                                                                  │
// │    abstraction: ("λ" | "\\") <ident> "." <term>;                                                                                                         │
// │    application: <atom> <atom>*;                                                                                                                          │
// │    atom: <ident> | "(" <term> ")" | <abstraction>;                                                                                                       │
// │    ident: /[A-Za-z_][A-Za-z0-9_]*/;                                                                                                                      │
// │`;

const String lambda_ast_string = `(
LambdaAST: <LambdaExpr>
LambdaExpr: <Parameter> | <Abstraction> | <Application>
Parameter : 'a'-'z'
Abstraction: 'λ' <Parameter> '.' <LambdaExpr>
Application: '(' <LambdaExpr> <LambdaExpr>')
)` ;


fn void init(){
 io::printn(lambda_ast_string);
}


