module delta_net_abstract_machine;
import std::core::main_stub;

fn int main(String[] args)
{
 (void)args;
 Net net;
 net.init();
 defer net.free();
 lambda_ast::init();
return 0;
}
