(* code generation: translate takes semantically checked AST and produces LLVM IR.
 * Authored by Tim Goodwin-tlg2132@columbia.edu *)

open Ast
open Llvm
open Exceptions

module L = Llvm
module A = Ast

module StringMap = Map.Make(String)

let translate (globals, functions) use_stdLib =
    let context = L.global_context() in
    let the_module = L.create_module context "Blur" in
    
    let i32_t = L.i32_type context
    and iFl_t = L.double_type context
    and i8_t = L.i8_type context
    and i1_t = L.i1_type context
    and void_t = L.void_type context in


    let string_t = L.pointer_type i8_t in
    let int_ptr_t = L.pointer_type i32_t in
    let array_t = L.array_type in
    let zero_t = L.const_int i32_t 0 in

    (* UnsizedArray types *)
    let img_t = L.struct_type context [| i32_t; i32_t; i32_t; int_ptr_t |] in
    let char_struct = L.struct_type context [| i32_t; i32_t; i32_t; string_t |] in
    let float_struct = L.struct_type context [| i32_t; i32_t; i32_t; (L.pointer_type iFl_t) |] in


    let rec ltype_of_sized_array t el =
        match (List.length el) with
            3 -> array_t (array_t (array_t (ltype_of_typ (Datatype(t))) (List.nth el 2)) (List.nth el 1)) (List.nth el 0)
          | 2 -> array_t (array_t (ltype_of_typ (Datatype(t))) (List.nth el 1)) (List.nth el 0)
          | 1 -> array_t (ltype_of_typ (Datatype(t))) (List.hd el)
          | _ -> raise (Exceptions.NotADatatype)
    
    and ltype_of_typ (d: A.datatype) = match d with
        Datatype(A.Int) -> i32_t
      | Datatype(A.Double) -> iFl_t
      | Datatype(A.Char) -> i8_t
      | Datatype(A.String) -> string_t
      | Datatype(A.Bool) -> i1_t
      | Datatype(A.Void) -> void_t
      | UnsizedArray(t, d) -> ltype_to_struct t (* wow can u believe it lol *)
      | SizedArray(t, el)  -> ltype_of_sized_array t el
      | _            -> raise (Exceptions.NotADatatype)

    and get_struct_type ptrTyp = match ptrTyp with
      i32_t    -> img_t
    | i8_t   -> char_struct
    | iFl_t   -> float_struct

    and ltype_to_struct (p: A.primitive) = match p with
      A.Int     -> img_t
    | A.Double  -> float_struct
    | A.Char    -> char_struct
    in

    let global_vars =
        let global_var map (vdecl : A.vardecl) =
            let typ = vdecl.declTyp in
            let name = vdecl.declID in

            let init = L.const_int (ltype_of_typ typ) 0
            in StringMap.add name (L.define_global name init the_module) map in
        List.fold_left global_var StringMap.empty globals in

    let builtin_decls = StringMap.empty in

    (* DECLARE EXTERNAL C LIBRARY FUNCTIONS *)
    let printf_t = L.var_arg_function_type i32_t [| L.pointer_type i8_t |] in
    let printf_func = L.declare_function "printf" printf_t the_module in
    let builtin_decls = StringMap.add "printf" printf_func builtin_decls in

    let getimg_t = L.var_arg_function_type img_t [| L.pointer_type i8_t |] in
    let getimg_func = L.declare_function "readGrayscaleImage" getimg_t the_module in
    let builtin_decls = StringMap.add "readGrayscaleImage" getimg_func builtin_decls in

    let canvas_t = L.var_arg_function_type char_struct [| string_t |] in
    let canvas_func = L.declare_function "canvas" canvas_t the_module in
    let builtin_decls = StringMap.add "canvas" canvas_func builtin_decls in

    (* DECLARE BLUR BUILT-INS *)
    let charToInt_t = L.var_arg_function_type i32_t [| i8_t |] in
    let charToInt_f = L.declare_function "charToIntensity" charToInt_t the_module in
    let builtin_decls = StringMap.add "charToIntensity" charToInt_f builtin_decls in

    let intensityToChar_t = L.var_arg_function_type i8_t [| i32_t |] in
    let intensityToChar_f = L.declare_function "intensityToChar" intensityToChar_t the_module in
    let builtin_decls = StringMap.add "intensityToChar" intensityToChar_f builtin_decls in

    let adjust_px_t = L.var_arg_function_type i8_t [| i8_t; i32_t |] in
    let adjust_px_f = L.declare_function "adjustPX" adjust_px_t the_module in
    let builtin_decls = StringMap.add "adjustPX" adjust_px_f builtin_decls in

    let builtin_decls =
        (* CONDITIONALLY DECLARE BLUR STANDARD LIBRARY FUCTIONS *)
        if use_stdLib then
            let edgeDetect_t = L.var_arg_function_type img_t [| string_t; i32_t |] in
            let edgeDetect_f = L.declare_function "edgeDetect" edgeDetect_t the_module in
            let builtin_decls = StringMap.add "edgeDetect" edgeDetect_f builtin_decls in

            let pixelDistance_t = L.var_arg_function_type i32_t [| i32_t; i32_t |] in
            let pixelDistance_f = L.declare_function "pixelDistance" pixelDistance_t the_module in
            let builtin_decls = StringMap.add "pixelDistance" pixelDistance_f builtin_decls in

            let dither_t = L.var_arg_function_type char_struct [| string_t |] in
            let dither_f = L.declare_function "dither" dither_t the_module in
            let builtin_decls = StringMap.add "dither" dither_f builtin_decls in

            let impose_t = L.var_arg_function_type char_struct [| char_struct; img_t; i8_t |] in
            let impose_f = L.declare_function "impose" impose_t the_module in
            StringMap.add "impose" impose_f builtin_decls
        else builtin_decls
    in

    (* define each function w/ args and return type so we can call it *)
    let function_decls =
        let function_decl map fdecl =
            let name = fdecl.A.fname
            and formal_types = Array.of_list (List.map (fun (typ) -> ltype_of_typ typ.argdeclType) fdecl.A.args) in
            let ftype = L.function_type (ltype_of_typ fdecl.A.typ) formal_types in
            StringMap.add name (L.define_function name ftype the_module, fdecl) map in

        List.fold_left function_decl StringMap.empty functions in

    let codegen_func func_decl =
        let (f, _) = StringMap.find func_decl.A.fname function_decls in

        let llbuilder = L.builder_at_end context (L.entry_block f) in


        (* format strings for println() *)
        let int_format_str = L.build_global_stringptr "%d\n" "int_fmt" llbuilder
        and str_format_str = L.build_global_stringptr "%s\n" "str_fmt" llbuilder
        and chr_format_str = L.build_global_stringptr "%c\n" "chr_fmt" llbuilder
        and flt_format_str = L.build_global_stringptr "%f\n" "flt_fmt" llbuilder

        in

        let local_vars = StringMap.empty in
        let arr_dims = StringMap.empty in

        let add_formal map (typ, name) fml =
            L.set_value_name name fml;
            let local = L.build_alloca (ltype_of_typ typ) name llbuilder in
            ignore (L.build_store fml local llbuilder);
            StringMap.add name local map
        in
        let add_local (vdecl: A.vardecl) local_vars =
            let typ = vdecl.declTyp in
            let name = vdecl.declID in
            let local_var = L.build_alloca (ltype_of_typ typ) name llbuilder in
            StringMap.add name local_var local_vars
        in

        (* Only add each function's args for now, will add to map when we encounter a varDecl in the functions body,
         * which is a statement list *)

        let local_vars = List.fold_left2 add_formal local_vars (List.map (fun (t) -> (t.argdeclType, t.argdeclID)) func_decl.A.args) (Array.to_list (L.params f)) in

        let maps = (local_vars, arr_dims) in

        (* see if a variable has been declared already *)
        let rec lookup name locals =
            try StringMap.find name locals
            with Not_found -> try StringMap.find name global_vars
            with Not_found -> raise (Exceptions.UnknownVariable name)
        in

         let rec codegen_binop e1 op e2 maps llbuilder =
            let int_ops lh op rh  =
                match op with
                A.Add   -> L.build_add lh rh "tmp" llbuilder
              | A.Sub   -> L.build_sub lh rh "tmp" llbuilder
              | A.Mult  -> L.build_mul lh rh "tmp" llbuilder
              | A.Div   -> L.build_sdiv lh rh "tmp" llbuilder
              | A.Mod   -> L.build_srem lh rh "whocares" llbuilder
              | A.And   -> L.build_and lh rh "tmp" llbuilder
              | A.Or    -> L.build_or lh rh "tmp" llbuilder
              | A.Eq    -> L.build_icmp Icmp.Eq lh rh "tmp" llbuilder
              | A.Neq   -> L.build_icmp Icmp.Ne lh rh "tmp" llbuilder
              | A.Lt    -> L.build_icmp Icmp.Slt lh rh "tmp" llbuilder
              | A.Leq   -> L.build_icmp Icmp.Sle lh rh "tmp" llbuilder
              | A.Gt    -> L.build_icmp Icmp.Sgt lh rh "tmp" llbuilder
              | A.Geq   -> L.build_icmp Icmp.Sge lh rh "tmp" llbuilder

            in

            let float_ops lh op rh =
                match op with
                A.Add   -> L.build_fadd lh rh "flt_addtmp" llbuilder
              | A.Sub   -> L.build_fsub lh rh "flt_subtmp" llbuilder
              | A.Mult  -> L.build_fmul lh rh "flt_multmp" llbuilder
              | A.Div   -> L.build_fdiv lh rh "flt_divtmp" llbuilder
              | A.Mod   -> L.build_frem lh rh "frem" llbuilder
              | A.Eq    -> L.build_fcmp Fcmp.Oeq lh rh "flt_eqtmp" llbuilder
              | A.Neq   -> L.build_fcmp Fcmp.One lh rh "flt_neqtmp" llbuilder
              | A.Lt    -> L.build_fcmp Fcmp.Ult lh rh "flt_lesstmp" llbuilder
              | A.Leq   -> L.build_fcmp Fcmp.Ole lh rh "flt_leqtmp" llbuilder
              | A.Gt    -> L.build_fcmp Fcmp.Ogt lh rh "flt_sgttmp" llbuilder
              | A.Geq   -> L.build_fcmp Fcmp.Oge lh rh  "flt_sgetmp" llbuilder
              | _       -> raise (Exceptions.FloatOpNotSupported)
            in
            
            let arith_binop e1 op e2 =
                let lh = codegen_expr (maps, llbuilder) e1
                and rh = codegen_expr (maps, llbuilder) e2
                in
                (* peanut brittle! *)
                let op_typ = L.string_of_lltype (L.type_of lh) in match op_typ with
                  "i32" -> int_ops lh op rh
                | "double" -> float_ops lh op rh
                | "i8"     -> int_ops lh op rh (* chars are treated as ints *)
                | "i1"     -> int_ops lh op rh
                | _        -> raise (Exceptions.NotSupported)
            in
            let assign_binop e1 e2 =
                (* if the assignment involves array dimensions, update the arr_dims map *)
                let maps = ((fst maps), arr_dims) in
                match e1 with
                  A.Id s        -> codegen_asn s (codegen_expr (maps, llbuilder) e2) maps llbuilder
                | A.ArrayAccess(n, dl) -> codegen_asn_arr e1 e2 maps llbuilder
                | _                    -> raise (Exceptions.NotAssignable)
            in

            let handle_binop e1 op e2 =
                match op with
                A.Asn         -> assign_binop e1 e2
              | _             -> arith_binop e1 op e2

            in
            handle_binop e1 op e2
                
        and codegen_unop op e maps llbuilder =
            let exp = (codegen_expr (maps, llbuilder)) e in
            if (L.type_of exp) = iFl_t then
                L.build_fneg exp "flt_unoptmp" llbuilder
            else
            match op with
            A.Neg       -> L.build_neg exp "int_unoptmp" llbuilder
          | A.Not       -> L.build_not exp "bool_unoptmp" llbuilder
          | A.Mag       -> (match (L.string_of_lltype (L.type_of exp)) with
                            "i32" -> L.build_call intensityToChar_f [| exp |] "mag_call" llbuilder
                          | "i8"  -> L.build_call charToInt_f [| exp |] "mag_callchar" llbuilder)
          | _           -> raise (Exceptions.NotSupported)

        (* helper to get the raw string from an ID expression type. MOVE TO A UTILS FILE *)
        and id_to_str id = match id with
            A.Id s      -> s
          | A.ArrayAccess(n, dl) -> n
          | _           -> raise Exceptions.NotAnId


        and codegen_asn_arr e1 e2 maps llbuilder =
            let gen_e1 = (match e1 with
              A.ArrayAccess(n, dl)    -> build_array_access n dl maps llbuilder true
              | _                       -> raise Exceptions.IllegalAssignment)
            in 
            let gen_e2 = codegen_expr (maps, llbuilder) e2 in
            ignore(L.build_store gen_e2 gen_e1 llbuilder); gen_e2

        and codegen_asn n gen_e maps llbuilder =
            let locals = fst maps in
            ignore(L.build_store gen_e (lookup n locals) llbuilder); gen_e

        and codegen_print e maps llbuilder newLine =
            let param = (codegen_expr (maps, llbuilder) e) in
            let theType = L.string_of_lltype (L.type_of param) in
            if newLine then
                let fmt_str = match theType with
                  "i32"     -> int_format_str
                | "double"  -> flt_format_str
                | "i8"      -> chr_format_str
                | "i8*"     -> str_format_str
                | "i1"      -> int_format_str
                | _         -> raise (Exceptions.NotSupported)

                in
                L.build_call printf_func [| fmt_str; param |] "println" llbuilder
            else
                let fmt_str = match theType with
                  "i32"    -> "%d"
                | "double" -> "%f"
                | "i8"     -> "%c"
                | "i8*"    -> "%s"
                | "i1"     -> "%d"
                | _        -> "%d" (* default *)

                in
                let str_ptr = L.build_global_stringptr fmt_str "print_fmt" llbuilder in
                L.build_call printf_func [| str_ptr; param |] "print" llbuilder

        and codegen_call f el (maps, llbuilder) =
            let args = List.rev (List.map (codegen_expr (maps, llbuilder)) (List.rev el)) in
            if StringMap.mem f builtin_decls then
                let func = StringMap.find f builtin_decls in
                L.build_call func (Array.of_list args) "" llbuilder
            else
                let (fdef, fdecl) = StringMap.find f function_decls in
                L.build_call fdef (Array.of_list args) "" llbuilder

        and get_img_handler e (maps, llbuilder) =
            let img_name = codegen_expr (maps, llbuilder) e in
            let img_loc = L.build_alloca (img_t) "imgloc" llbuilder in
            let res = L.build_call getimg_func [| img_name |] "grayScaleImgfunccall" llbuilder in
            ignore(L.build_store res img_loc llbuilder); res

        and get_canvas_handler e (maps, llbuilder) =
            let img_name = codegen_expr (maps, llbuilder) e in
            let img_loc = L.build_alloca (char_struct) "canvasloc" llbuilder in
            let res = L.build_call canvas_func [| img_name |] "canvasFuncCall" llbuilder in
            ignore(L.build_store res img_loc llbuilder); res

        and arr_len_handler arr (maps, llbuilder) =

            if (StringMap.mem (id_to_str arr) (snd maps)) then
                let exp = codegen_expr (maps, llbuilder) arr in
                L.const_int i32_t (L.array_length (L.type_of exp))
            else
                let arr_ref = lookup (id_to_str arr) (fst maps) in
                match arr with
                  A.Id s ->
                    let width_ptr = L.build_gep arr_ref [| zero_t; zero_t |] "width" llbuilder in
                    let width = L.build_load width_ptr "widthval" llbuilder in
                    width
                | A.ArrayAccess(n, dl) ->
                        (match (List.length dl) with
                          1 ->
                            let height_ptr = L.build_gep arr_ref [| zero_t; L.const_int i32_t 1 |] "height" llbuilder in
                            let height = L.build_load height_ptr "heightval" llbuilder in
                            height
                        (* this case should never be allowed *)
                        | _ -> raise (Exceptions.UnsupportedDimensions))
                | _ -> raise (Exceptions.NotAnArray)

        and codegen_expr (maps, llbuilder) e =
            match e with 
            A.IntLit i                  -> L.const_int i32_t i
          | A.DoubleLit i               -> L.const_float iFl_t i
          | A.StrLit s                  -> L.build_global_stringptr s "tmp" llbuilder
          | A.CharLit c                 -> L.const_int i8_t (Char.code c)
          | A.BoolLit b                 -> if b then L.const_int i1_t 1 else L.const_int i1_t 0
          | A.Id id                     -> L.build_load (lookup id (fst maps)) id llbuilder
          | A.Binop(e1, op, e2)         -> codegen_binop e1 op e2 maps llbuilder
          | A.Unop(op, e)               -> codegen_unop op e maps llbuilder
          (* --- built in functions --- *)
          | A.FuncCall ("print", [e])   -> codegen_print e maps llbuilder false
          | A.FuncCall ("println", [e]) -> codegen_print e maps llbuilder true
          | A.FuncCall ("len", [arr])   -> arr_len_handler arr (maps, llbuilder)
          | A.FuncCall ("readGrayscaleImage", [e])   -> get_img_handler e (maps, llbuilder)
          | A.FuncCall ("canvas", [e])  -> get_canvas_handler e (maps, llbuilder)
          | A.FuncCall ("intcast", [e])              -> L.build_fptosi (codegen_expr (maps, llbuilder) e) i32_t "intcast" llbuilder
          | A.FuncCall ("doublecast", [e])           -> L.build_sitofp (codegen_expr (maps, llbuilder) e) iFl_t "doublecast" llbuilder
          (* --- end built-ins --- *)
          | A.FuncCall (n, el)          -> codegen_call n el (maps, llbuilder)
          | A.ArrayListInit el          -> build_array_of_list el (maps, llbuilder)
          | A.ArrayAccess(n, dl)        -> build_array_access n dl maps llbuilder false
          | A.Noexpr                    -> L.const_int i32_t 0

        (* codegen_vdecl: handle variable declarations *)
        and codegen_vdecl (vdecl: A.vardecl) (maps, llbuilder) =

            let local_vars = (fst maps) in
            match vdecl.declTyp with
              A.UnsizedArray(p, d) ->

                let gen_exp = codegen_expr (maps, llbuilder) vdecl.declInit in
                let local_vars, arr_src  =
                let typ = L.type_of gen_exp in

                (* determine if array is of a heap allocated type or not *)
                if ((typ = img_t) || (typ = char_struct) || (typ = float_struct)) then

                    let local_img_var = L.build_alloca typ vdecl.declID llbuilder in
                    let arr_ptr = L.build_gep local_img_var [| zero_t |] "arr_ptr" llbuilder in
                    let arr_ptr_a = L.build_alloca (L.type_of arr_ptr) vdecl.declID llbuilder in

                    ignore(L.build_store arr_ptr arr_ptr_a llbuilder);
                    let local_vars = StringMap.add vdecl.declID local_img_var local_vars in
                    ignore(codegen_asn vdecl.declID gen_exp (local_vars, (snd maps)) llbuilder); local_vars, (snd maps)

                (* normal case, i.e. int[] a = [1,2]; *)
                else
                    let exp_typ = (L.type_of gen_exp) in (* a LLVM array type, i.e. [3 x i32] *)
                    let local_var = L.build_malloc exp_typ vdecl.declID llbuilder in

                    let struct_typ = ltype_to_struct p in
                    let pointer_typ = L.pointer_type (ltype_of_typ (Datatype(p))) in
                    
                    let arr_ptr = L.build_gep local_var [| zero_t |] "arr_ptr2" llbuilder in
                    let arr_ptr = L.build_pointercast arr_ptr pointer_typ "idk" llbuilder in
                    let arr_ptr_a = L.build_alloca (struct_typ) vdecl.declID llbuilder in
                    ignore(L.build_store gen_exp local_var llbuilder);

                    (* use LLVM to measure cost_array dimensions, then store them in the array struct type *)
                    let width = L.const_int i32_t (L.array_length exp_typ) in
                    let height = if d = 2 then
                        L.const_int i32_t (L.array_length exp_typ)
                    else
                        zero_t
                    in
                    (*ignore(L.build_store arr_ptr arr_ptr_a llbuilder); *)
                    let arr_struct = L.const_named_struct struct_typ [| width; height; zero_t; (L.undef pointer_typ) |] in
                    let arr_struct1 = L.build_insertvalue arr_struct arr_ptr 3 "pls" llbuilder in
                    let local_vars = StringMap.add vdecl.declID arr_ptr_a local_vars in (* adding struct type *)
                    ignore(codegen_asn vdecl.declID arr_struct1 (local_vars, (snd maps)) llbuilder); local_vars, (snd maps)
                in
                let maps = (local_vars, arr_src) in maps, llbuilder

            (* cannot be initialized, only declared *)
            | A.SizedArray(p, d) ->
                    let local_vars = add_local vdecl local_vars in
                    (local_vars, (snd maps)),  llbuilder

            | _         ->
                let local_vars = add_local vdecl local_vars in
                let maps = (local_vars, (snd maps)) in
                match vdecl.declInit with
                  A.Noexpr      -> maps, llbuilder
                | e             -> let exp = (codegen_expr (maps, llbuilder) e) in ignore(codegen_asn vdecl.declID exp maps llbuilder); maps, llbuilder


        (* BUILD 1-dimensional array from Literal *)
        and build_array_of_list el (maps, llbuilder) =
            let llvalues = List.map (codegen_expr (maps, llbuilder)) el in
            let typ = (L.type_of (List.hd llvalues)) in
            let cool_array = Array.of_list llvalues in
            let res = L.const_array typ cool_array in res

        (* BUILD ARRAY ACCESS *)    
        and build_array_access name idx_list maps llbuilder isAssign =

            let arr_handle = (lookup name (fst maps)) in
            let typ = L.type_of arr_handle in
            if ((typ = L.pointer_type img_t) || (typ = L.pointer_type char_struct) || (typ = L.pointer_type float_struct)) then
                (let idx_list = List.map (codegen_expr (maps, llbuilder)) idx_list in
                let depth_ptr = L.build_gep arr_handle [| zero_t; L.const_int i32_t 2 |] "depth" llbuilder in
                let depth = L.build_load depth_ptr "depthval" llbuilder in

                if depth = zero_t then (* Unsized Array initialized within a Blur program. *)

                    let data_ptr = L.build_gep arr_handle [| zero_t; L.const_int i32_t 3 |] "data" llbuilder in
                    let data = L.build_load data_ptr "dataval" llbuilder in (* actual dataptr *)
                    let datatyp = L.type_of (L.build_load data "val" llbuilder) in
                    let struct_typ = get_struct_type datatyp in
                    let data = L.build_pointercast data (L.pointer_type (struct_typ)) "datacast" llbuilder in

                    let idx_list = (L.const_int i32_t 0)::[]@idx_list in
                    let idx_arr = Array.of_list idx_list in
                    let gep = L.build_gep data idx_arr name llbuilder in
                    if isAssign then
                        gep
                    else
                        L.build_load gep name llbuilder

                else (* UnsizedArray type returned from the C-Backend (follows depth > 0 standard) *)

                    let the_arr_pointer = arr_handle in

                    let width_ptr = L.build_gep the_arr_pointer [| zero_t; zero_t |] "width" llbuilder in
                    let data_ptr = L.build_gep the_arr_pointer [| zero_t; L.const_int i32_t 3 |] "data" llbuilder in
                    let width = L.build_load width_ptr "widthval" llbuilder in
                    let data = L.build_load data_ptr "dataval" llbuilder in

                    let gep = 
                    if List.length idx_list = 2 then
                        let offset = L.build_mul width (List.hd idx_list) "base" llbuilder in
                        let offset = L.build_add offset (List.nth idx_list 1) "offset" llbuilder in
                        let idx_ptr = L.build_gep data [| offset |] "idx_ptr" llbuilder in idx_ptr

                    else
                        let idx_ptr = L.build_in_bounds_gep data [| (List.hd idx_list) |] "idx_ptr" llbuilder in idx_ptr
                    in
                    if isAssign then
                        gep
                    else
                        let load = L.build_load gep name llbuilder in load)
            else
                (let idx_list = List.map (codegen_expr (maps, llbuilder)) idx_list in
                ignore(print_endline("; ok"));
                let idx_list = (L.const_int i32_t 0)::[]@idx_list in
                let idx_arr = Array.of_list idx_list in
                let gep = L.build_gep arr_handle idx_arr name llbuilder in
                if isAssign then
                    gep
                else
                    L.build_load gep name llbuilder)

        (* used to add a branch instruction to a basic block only if one doesn't already exist *)
        and codegen_conditional pred then_stmt else_stmt (maps, llbuilder) =
            let bool_val = (codegen_expr (maps, llbuilder) pred) in

            let merge_bb = L.append_block context "merge" f in
            let then_bb = L.append_block context "then" f in
            let then_builder = (L.builder_at_end context then_bb) in
            let then_tup = (codegen_stmt (maps, then_builder) then_stmt) in
            add_terminal (snd then_tup) (L.build_br merge_bb);

            let else_bb = L.append_block context "else" f in
            let else_builder = (L.builder_at_end context else_bb) in
            let else_tup = (codegen_stmt (maps, else_builder) else_stmt) in
            add_terminal (snd else_tup) (L.build_br merge_bb);
            ignore (L.build_cond_br bool_val then_bb else_bb llbuilder);
            L.builder_at_end context merge_bb

        (* WHILE LOOP *)
        and codegen_while pred body (maps, llbuilder) =
            let pred_bb = L.append_block context "while" f in
            ignore (L.build_br pred_bb llbuilder);

            let body_bb = L.append_block context "while_body" f in
            add_terminal (snd (codegen_stmt (maps, (L.builder_at_end context body_bb)) body)) (L.build_br pred_bb);

            let pred_builder = L.builder_at_end context pred_bb in
            let bool_val = (codegen_expr (maps, pred_builder) pred) in
            
            let merge_bb = L.append_block context "merge" f in
            ignore (L.build_cond_br bool_val body_bb merge_bb pred_builder);
            L.builder_at_end context merge_bb

        (* FOR LOOP *)
        and codegen_for e1 e2 e3 body (maps, llbuilder) =
            codegen_stmt (maps, llbuilder) (A.Block [A.Expr e1; A.While (e2, A.Block [body; A.Expr e3])])

        and add_terminal llbuilder f =
            match L.block_terminator (L.insertion_block llbuilder) with
              Some _ -> ()
            | None      -> ignore (f llbuilder)

        and codegen_return ret_e (maps, llbuilder) =
            match func_decl.A.typ with
              A.Datatype(A.Void)        -> L.build_ret_void llbuilder
            | _                         -> L.build_ret (codegen_expr (maps, llbuilder) ret_e) llbuilder
           
        (* build instructions in the given builder for the statement,
         * return the builder for where the next instruction should be placed *)
        and codegen_stmt (maps, llbuilder) = function
            A.Block sl              -> List.fold_left codegen_stmt (maps, llbuilder) sl
          | A.Decl e                -> codegen_vdecl e (maps, llbuilder)
          | A.Expr e                -> ignore (codegen_expr (maps, llbuilder) e); maps, llbuilder
          | A.Return e              -> ignore (codegen_return e (maps, llbuilder)); maps, llbuilder
          | A.If(p, s1, s2)         -> let builder = (codegen_conditional p s1 s2 (maps, llbuilder)) in maps, builder
          | A.While(p, body)        -> let builder = (codegen_while p body (maps, llbuilder)) in maps, builder
          | A.For(e1, e2, e3, body) -> codegen_for e1 e2 e3 body (maps, llbuilder)

        (* build the code for each statement in the function *)
        in
        let tuple = codegen_stmt (maps, llbuilder) (A.Block func_decl.A.body) in
        let llbuilder = (snd tuple) in
        add_terminal llbuilder (match func_decl.A.typ with
                A.Datatype(A.Void) -> L.build_ret_void
              | typ -> L.build_ret (L.const_int (ltype_of_typ typ) 0))
    in
    List.iter codegen_func functions;
    the_module
