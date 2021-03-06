(* blur.ml *)

open Prettyprint
open Ast
open Generator

type action = Pretty | Llvm | Checked_Llvm | StdLib_Llvm

let _ =
	let action = if Array.length Sys.argv > 1 then
		List.assoc Sys.argv.(1) [ ("-p", Pretty);
			("-l", Llvm);
                        ("-c", Checked_Llvm); ("-ls", StdLib_Llvm) ]
		else Checked_Llvm in
	let lexbuf = Lexing.from_channel stdin in
	let ast = Parser.program Scanner.token lexbuf in 
	Semantic_analyzer.check_prog ast; 
	match action with
	Pretty -> print_endline (Prettyprint.string_of_prog ast)
	| Llvm -> print_string (Llvm.string_of_llmodule (Generator.translate ast false))
        | StdLib_Llvm -> print_string (Llvm.string_of_llmodule (Generator.translate ast true))
	| Checked_Llvm -> let m = Generator.translate ast false in
		Llvm_analysis.assert_valid_module m;
		print_string (Llvm.string_of_llmodule m)
