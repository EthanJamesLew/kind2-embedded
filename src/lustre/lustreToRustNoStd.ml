open Lib

module N = LustreNode
module Id = LustreIdent
module I = LustreIndex
module E = LustreExpr
module C = LustreContract
module SVar = StateVar
module SVM = StateVar.StateVarMap
module SVS = StateVar.StateVarSet
module L2R = LustreToRust

(* Name of the parsing functions in the rust [parse] module. *)
let parse_bool_fun, parse_int_fun, parse_real_fun = "bool", "int", "real"

(* File name at the end of a path. *)
let file_name_of_path file_path =
  try (
    let last_slash = String.rindex file_path '/' in
    if last_slash = (String.length file_path) - 1 then (
      Format.sprintf "[fmt_cp_target] illegal argument \"%s\"" file_path
      |> failwith
    ) ;
    String.sub file_path (last_slash + 1) (
      (String.length file_path) - (last_slash + 1)
    )
  ) with Not_found -> file_path

(* Formats a position as a link to the rust doc of the lustre file. *)
let fmt_pos_as_link fmt pos =
  let name, line, _ = file_row_col_of_pos pos in
  let name =
    match name with
    | "" -> Flags.input_file ()
    | name -> file_name_of_path name
  in
  Format.fprintf fmt "[%s line %d](../src/lus/%s.html#%d)"
    name line name line

(* Formatter for types as rust expressions. *)
let fmt_type fmt t = match Type.node_of_type t with
| Type.Bool -> Format.fprintf fmt "Bool"
| Type.Int
| Type.IntRange _ -> Format.fprintf fmt "Int"
| Type.Real -> Format.fprintf fmt "Real"
| _ ->
  Format.asprintf "type %a is not supported" Type.pp_print_type t
  |> failwith

(* Unsafe string representation of an ident, used for rust identifiers. *)
let mk_id_legal = Id.string_of_ident false

(* Same as [mk_id_legal] but capitalizes the first letter to fit rust
conventions for type naming. *)
let mk_id_type id = mk_id_legal id |> String.capitalize_ascii

(* Crate entry point. *)
let fmt_main fmt () = Format.fprintf fmt "\
// No Entry point.
"

(* Crate documentation for implementation, lint attributes. For no std,
   we have to disable it as an attribute. *)
let fmt_prefix blah name fmt typ = Format.fprintf fmt "\
//! %s for lustre node `%s` (see [%s](struct.%s.html)).
//!
//! Code generated by the [Kind 2 model checker][kind 2].
//!
//! [kind 2]: http://kind2-mc.github.io/kind2/ (The Kind 2 model checker)

// Deactiving lint warnings the transformation does not respect.
#![no_std]
#![allow(
  non_upper_case_globals, non_snake_case, non_camel_case_types,
  unused_variables, unused_parens
)]

// TODO: [CODEGEN] don't dump this into module
use Lustre::*;
" blah name typ typ

(* Helpers modules: cla parsing, types, traits for systems and stdin
parsing. *)
let fmt_helpers fmt systems = Format.fprintf fmt "\
/// Lustre Language Traits
pub mod Lustre {
  /// Lustre Types
  pub type Int = i32;
  pub type Real = f32;
  pub type Bool = bool;

  /// Lustre System (Component)
  pub trait System: Sized {
    // component types
    type Input;
    type Output;

    /// get size of inputs
    fn arity() -> usize;

    /// run once to get the intial state
    fn init(inp: Self::Input) -> Result<Self, ()>;

    /// update function that will run in a loop
    fn next(&mut self, inp: Self::Input) -> Result<(), ()>;

    /// get output at this time
    fn output(&self) -> Self::Output;
  }
  
}
"

(* Specialization of [fmt_prefix] for implementation. *)
let fmt_prefix_implem = fmt_prefix "Implementation"

(* Specialization of [fmt_prefix] for oracles. *)
let fmt_prefix_oracle = fmt_prefix "Oracle"

(* Continuation type for the term-to-Rust printer.
Used to specify what should happen after the next step. *)
type continue =
| T of Term.t (* Next step is to print a term. *)
| S of string (* Next step is to print a string. *)


(* [wrap_with_sep e s [t1 ; ... ; tn]] creates the list
[[Ss ; T t1 ; S s ; ... ; S s ; tn ; e]]. *)
let wrap_with_sep ending sep kids =
  let ending = [ S ending ] in
  let rec loop kids lst = match kids with
    | [] -> List.rev_append lst ending
    | [kid] -> (S sep) :: (T kid) :: ending |> List.rev_append lst
    | kid :: kids -> (T kid) :: (S sep) :: lst |> loop kids
  in
  loop kids []

(* Prints a variable. Prefixes with ["self."] variables unrolled at 0 and
constant variables. *)
let fmt_var pref fmt var =
  if Var.is_state_var_instance var then (
    let off = Var.offset_of_state_var_instance var |> Numeral.to_int in
    let from = match off with
      | 0 -> "self."
      | 1 -> ""
      | _ ->
        Format.asprintf "unexpected var %a" Var.pp_print_var var
        |> failwith
    in
    Var.state_var_of_state_var_instance var
    |> SVar.name_of_state_var
    |> Format.fprintf fmt "%s%s%s" from pref
  ) else if Var.is_const_state_var var then (
    (* Constant input. Can't be just a constant, otherwise it would have been
    propagated. *)
    Var.state_var_of_state_var_instance var
    |> SVar.name_of_state_var
    |> Format.fprintf fmt "%s%s" pref
  ) else
    Format.asprintf "unexpected var %a" Var.pp_print_var var
    |> failwith

(* Goes down a term, printing what it can until it reaches a leaf. Then, calls
[fmt_term_up] on the continuation. *)
let rec fmt_term_down svar_pref next fmt term =
match Term.destruct term with
| Term.T.App (sym, kid :: kids) -> (
  let node = Symbol.node_of_symbol sym in
  match node with
  (* Unary. *)
  | `NOT ->
    Format.fprintf fmt "(! " ;
    assert (kids = []) ;
    fmt_term_down svar_pref ([ S ")" ] :: next) fmt kid
  (* Binary. *)
  | `EQ
  | `MOD
  | `LEQ
  | `LT
  | `GEQ
  | `GT -> (
    match kids with
    | [rhs] ->
      let op =
        match node with
        | `EQ -> " == "
        | `MOD -> " % "
        | `LEQ -> " <= "
        | `LT -> " < "
        | `GEQ -> " >= "
        | `GT -> " > "
        | _ -> failwith "unreachable"
      in
      Format.fprintf fmt "(" ;
      fmt_term_down svar_pref (
        [ S op ; T rhs ; S ")" ] :: next
      ) fmt kid
    | [] -> failwith "implication of one kid"
    | _ ->
      Format.sprintf "implication of %d kids" ((List.length kids) + 1)
      |> failwith
  )
  (* Binary but rewritten. *)
  | `IMPLIES ->
    Term.mk_not kid :: kids
    |> Term.mk_or
    |> fmt_term_down svar_pref next fmt 
  (* Ternary. *)
  | `ITE -> (
    let _, t, e = match kids with
      | [ t ; e ] -> kid, t, e
      | _ -> failwith "illegal ite"
    in
    Format.fprintf fmt "( if " ;
    fmt_term_down svar_pref (
      [ S " { " ; T t ; S " } else {" ; T e ; S " } )" ] :: next
    ) fmt kid
  )
  (* N-ary. *)
  | `MINUS when kids = [] ->
    Format.fprintf fmt "- " ;
    fmt_term_down svar_pref next fmt kid
  | `MINUS
  | `PLUS
  | `TIMES
  | `DIV
  | `OR
  | `XOR
  | `AND ->
    let op =
      match node with
      | `MINUS -> " - "
      | `PLUS -> " + "
      | `TIMES -> " * "
      | `DIV -> " / "
      | `OR -> " | "
      | `XOR -> " ^ "
      | `AND -> " & "
      | _ -> failwith "unreachable"
    in
    Format.fprintf fmt "(" ;
    fmt_term_down svar_pref (
      (wrap_with_sep ")" op kids) :: next
    ) fmt kid
  | `DISTINCT
  | `INTDIV
  | `ABS
  | _ ->
    Format.asprintf "unsupported symbol %a" Symbol.pp_print_symbol sym
    |> failwith
  (*
  | `TO_REAL
  | `TO_INT
  | `TO_UINT8
  | `TO_UINT16
  | `TO_UINT32
  | `TO_UINT64
  | `IS_INT
  (* Illegal. *)
  | `NUMERAL of Numeral.t
  | `DECIMAL of Decimal.t
  | `TRUE
  | `FALSE -> Format.fprintf fmt "illegal" *)
)
| Term.T.App (_, []) -> failwith "application with no kids"
| Term.T.Var var ->
  fmt_var svar_pref fmt var ;
  fmt_term_up svar_pref fmt next
| Term.T.Const sym ->
  ( match Symbol.node_of_symbol sym with
    | `NUMERAL n -> Format.fprintf fmt "%a" Numeral.pp_print_numeral n
    | `DECIMAL d -> Format.fprintf fmt "%a" Decimal.pp_print_decimal_as_float32 d
    | `TRUE -> Format.fprintf fmt "true"
    | `FALSE -> Format.fprintf fmt "false"
    | _ -> Format.asprintf "Const %a" Symbol.pp_print_symbol sym |> failwith
  ) ;
  fmt_term_up svar_pref fmt next
(* | Term.T.Attr (kid,_) -> fmt_term_down svar_pref [] fmt kid *)

(* Goes up a continuation. Prints the strings it finds and calls
[fmt_term_down] on terms. *)
and fmt_term_up svar_pref fmt = function
| (next :: nexts) :: tail -> (
  let tail = nexts :: tail in
  match next with
  | S str ->
    Format.fprintf fmt "%s" str ;
    fmt_term_up svar_pref fmt tail
  | T term ->
    fmt_term_down svar_pref tail fmt term
)
| [] :: tail -> fmt_term_up svar_pref fmt tail
| [] -> ()

(* Formatter for terms as rust expressions. *)
let fmt_term svar_pref = fmt_term_down svar_pref []


(* Rust-level parsing function for a type. *)
let parser_for t = match Type.node_of_type t with
| Type.Bool -> parse_bool_fun
| Type.Int
| Type.IntRange _ -> parse_int_fun
| Type.Real -> parse_real_fun
| _ ->
  Format.asprintf "type %a is not supported" Type.pp_print_type t
  |> failwith

(* Prefix for all state variables. *)
let svar_pref = "svar_"


(* Gathers [LustreNode.equation] with [LustreNode.node_call] for ordering. *)
type equation =
| Eq of N.equation (* An equation. *)
| Call of (int * N.node_call) (* A call with a uid local to the node. *)

(* Identifier refering to the current state of the system called. *)
let id_of_call cnt { N.call_node_name } =
  Format.sprintf "%s_%d" (mk_id_legal call_node_name) cnt

(* Pretty prints an equation or a call. *)
let pp_print_equation fmt = function
| Eq eq -> N.pp_print_node_equation false fmt eq
| Call (cnt, call) ->
  Format.fprintf fmt "%a (%d)" (N.pp_print_call false) call cnt


(* Orders equations topologicaly based on the [expr_init] or [expr_next]
expression of the right-hand side of the equation. *)
let order_equations init_or_expr inputs equations =
  (* Checks if [svar] is defined in the equations or is an input. *)
  let is_defined sorted svar =
    List.exists (fun (_, svar') -> svar == svar') inputs
    || List.exists (function
      | Eq ((svar', _), _) -> svar == svar'
      | Call (_, { N.call_outputs }) ->
        I.bindings call_outputs |> List.exists (
          fun (_, svar') -> svar == svar'
        )
    ) sorted
  in
  (* Sorts equations. *)
  let rec loop count later to_do sorted = match to_do with
    (* Equation. *)
    | (Eq ((_, _), rhs)) as eq :: to_do ->
      let later, sorted =
        if
          init_or_expr rhs
          |> E.cur_term_of_expr E.base_offset
          (* Extract svars. *)
          |> Term.state_vars_at_offset_of_term E.base_offset
          (* All svars must be defined. *)
          |> SVS.for_all (is_defined sorted)
        then later, eq :: sorted else eq :: later, sorted
      in
      loop count later to_do sorted
    (* Node call. *)
    | (
      Call (
        _, { N.call_inputs ; N.call_defaults }
      ) as eq
    ) :: to_do ->
      if call_defaults != None then (
        Format.printf "Compilating of condacts is not supported.@.@." ;
        failwith "could not compile system"
      ) ;
      let later, sorted =
        if
          I.bindings call_inputs
          (* All input svar must be defined. *)
          |> List.for_all (fun (_, svar) -> is_defined sorted svar)
        then later, eq :: sorted else eq :: later, sorted
      in
      loop count later to_do sorted
    (* Done. *)
    | [] -> (
      let count = count + 1 in
      if count <= (List.length equations) + 1 then
        match later with
        | [] -> List.rev sorted
        | _ -> loop count [] later sorted
      else (
        Format.printf
          "Some equations use undefined variables:@.  @[<v 2>%a@]@.@." (
            pp_print_list pp_print_equation "@ "
          ) later ;
        failwith "could not compile system"
      )
    )
  in
  loop 0 [] equations []



(* Pretty prints calls for struct documentation. *)
let fmt_calls_doc fmt = function
| [] -> Format.fprintf fmt "No subsystems for this system.@."
| calls -> Format.fprintf fmt "\
  | Lustre identifier | Struct | Inputs | Outputs | Position |@.\
  /// |:---:|:---:|:---:|:---:|:---:|@.\
  /// %a@.\
" ( pp_print_list
    ( fun fmt {
        N.call_pos ; N.call_node_name ; N.call_inputs ; N.call_outputs
      } ->
        Format.fprintf fmt
          "\
            | `%s` @?\
            | [%s](struct.%s.html) @?\
            | %a @?\
            | %a @?\
            | %a |\
          "
          (mk_id_legal call_node_name)
          (mk_id_type call_node_name)
          (mk_id_type call_node_name)
          (pp_print_list (fun fmt (_, svar) ->
              SVar.name_of_state_var svar
              |> Format.fprintf fmt "`%s`"
            ) ", "
          ) (I.bindings call_inputs)
          (pp_print_list (fun fmt (_, svar) ->
              SVar.name_of_state_var svar
              |> Format.fprintf fmt "`%s`"
            ) ", "
          ) (I.bindings call_outputs)
          fmt_pos_as_link call_pos
    ) "@./// "
  ) calls


(* Pretty prints assertions for struct documentation. *)
let fmt_asserts_doc fmt = function
| [] -> Format.fprintf fmt "/// No assertions for this system.@."
| asserts -> Format.fprintf fmt "%a@." (
  pp_print_list (fun fmt (pos,_) ->
    Format.fprintf fmt
      "- `%a`"
      fmt_pos_as_link pos
  ) "@ /// "
) asserts

(* Pretty prints assumptions for a struct documentation. *)
let fmt_assumes_doc fmt = function
| [] -> Format.fprintf fmt "/// No assumptions for this system.@."
| assumes -> Format.fprintf fmt "\
  /// | State variable | Position | Number |@.\
  /// |:------:|:-----:|:-----:|@.\
  /// %a@.\
" ( pp_print_list (fun fmt {
      LustreContract.pos ; LustreContract.num ; LustreContract.svar
    } ->
      Format.fprintf fmt
        "| `%s` @?| %a @?| %d |"
        (SVar.name_of_state_var svar)
        fmt_pos_as_link pos
        num
    ) "@ /// "
  ) assumes


(* Writes the documentation for a struct for the implementation of a node. *)
let implem_doc_of_struct is_top fmt (
  name, inputs, outputs, calls, asserts, contract
) =
  Format.fprintf fmt "\
      /// Stores the state for %s `%s`.@.\
      ///@.\
      /// # Inputs@.\
      ///@.\
      /// | Lustre identifier | Type |@.\
      /// |:---:|:---|@.\
      /// %a@.\
      ///@.\
      /// # Outputs@.\
      ///@.\
      /// | Lustre identifier | Type |@.\
      /// |:---:|:---|@.\
      /// %a@.\
      ///@.\
      /// # Sub systems@.\
      ///@.\
      /// %a\
      ///@.\
      /// # Assertions@.\
      ///@.\
      /// %a\
      ///@.\
      /// # Assumptions@.\
      ///@.\
      %a\
      ///@.\
    "
    (if is_top then "**top node**" else "sub-node") name
    ( pp_print_list (fun fmt (_, svar) ->
        Format.fprintf fmt "| `%s` | %a |"
          (SVar.name_of_state_var svar)
          fmt_type (SVar.type_of_state_var svar)
      ) "@./// "
    ) inputs
    ( pp_print_list (fun fmt (_, svar) ->
        Format.fprintf fmt "| `%s` | %a |"
          (SVar.name_of_state_var svar)
          fmt_type (SVar.type_of_state_var svar)
      ) "@./// "
    ) outputs
    fmt_calls_doc calls
    fmt_asserts_doc asserts
    ( fun fmt -> function
      | None -> fmt_assumes_doc fmt []
      | Some { C.assumes } -> fmt_assumes_doc fmt assumes
    ) contract


(* Writes the documentation for a struct for the test oracle of a node. *)
let oracle_doc_of_struct is_top fmt (
  name, inputs, outputs, assumes, guarantees, modes, svar_source_map
) =
  Format.fprintf fmt "\
      /// Stores the state for the oracle for %s `%s`.@.\
      ///@.\
      /// # Inputs@.\
      ///@.\
      /// | Lustre identifier | Type | Source |@.\
      /// |:---:|:---:|:---|@.\
      /// %a@.\
      ///@.\
      /// # Outputs@.\
      ///@.\
      /// The outputs of the oracle are the guarantees of the original@.\
      /// system and the implications for each require of each mode.
      ///@.\
      /// That is, if a mode has requires `req_1`, ..., `req_n` and ensures@.\
      /// `ens_1`, ..., `ens_m` this will generate `m` outputs:@.\
      ///@.\
      /// - `(req_1 && ... && req_n) => ens_1`
      /// - ...
      /// - `(req_1 && ... && req_n) => ens_m`
      ///@.\
      /// Hence, an ensure output is false iff the mode is active and the
      /// ensure is false.
      ///@.\
      /// | Lustre identifier | Type |@.\
      /// |:---:|:---|@.\
      /// %a@.\
      ///@.\
      /// ## Guarantees@.\
      ///@.\
      /// %a\
      ///@.\
      /// %a\
      ///@.\
      /// # Assumptions@.\
      ///@.\
      %a\
      ///@.\
    "
    (if is_top then "**top node**" else "sub-node") name
    ( pp_print_list (fun fmt (_, svar) ->
        Format.fprintf fmt "| `%s` | %a | %a |"
          (SVar.name_of_state_var svar)
          fmt_type (SVar.type_of_state_var svar)
          N.pp_print_state_var_source (
            try
              SVM.find svar svar_source_map
            with Not_found ->
              Format.asprintf
                "can't find source of svar %a"
                SVar.pp_print_state_var svar
              |> failwith
          )
      ) "@./// "
    ) inputs
    ( pp_print_list (fun fmt (_, svar) ->
        Format.fprintf fmt "| `%s` | %a |"
          (SVar.name_of_state_var svar)
          fmt_type (SVar.type_of_state_var svar)
      ) "@./// "
    ) outputs
    ( fun fmt -> function
      | [] -> Format.fprintf fmt "No guarantees for this system.@."
      | guarantees ->
        Format.fprintf fmt "\
            | Lustre identifier | Guarantee number | Position |@.\
            /// |:---:|:---:|:---|@.\
            /// %a@.
          "
          ( pp_print_list
            ( fun fmt ({ C.pos ; C.num ; C.svar }, _) ->
                Format.fprintf fmt "| `%s` | %d | %a |"
                  (SVar.name_of_state_var svar)
                  num
                  fmt_pos_as_link pos
            ) "@./// "
          ) guarantees
    ) guarantees
    ( fun fmt -> function
      | [] -> Format.fprintf fmt "No modes for this system."
      | modes ->
        Format.fprintf fmt "%a@." (pp_print_list
          ( fun fmt { C.name ; C.pos ; C.ensures } ->
            Format.fprintf fmt "\
                ## Mode **%s**@.\
                ///@.\
                /// Position: *%a*.@.\
                ///@.\
                /// | Lustre identifier | Mode require number | Position |@.\
                /// |:---:|:---:|:---|@.\
                /// %a@.
              "
              (Id.string_of_ident false name)
              fmt_pos_as_link pos
              ( pp_print_list
                (fun fmt { C.pos ; C.num ; C.svar } ->
                  Format.fprintf fmt "| `%s` | %d | %a |"
                    (SVar.name_of_state_var svar)
                    num
                    fmt_pos_as_link pos
                ) "@./// "
              ) ensures
          ) "@.///@./// "
        ) modes
    ) modes
    fmt_assumes_doc assumes


(* Compiles a node to rust, writes it to a formatter. *)
let node_to_rust oracle_info is_top fmt (
  { N.locals ; N.contract ; N.state_var_source_map } as node
) =

  (* Format.printf "node: %a@.@." (Id.pp_print_ident false) name ; *)

  let is_input svar =
    try (
      match SVM.find svar state_var_source_map with
      | N.Input ->
        (* Format.printf
          "input: %a@.@." SVar.pp_print_state_var svar ; *)
        true
      | _ ->
        (* Format.printf
          "not input: %a@.@." SVar.pp_print_state_var svar ; *)
        false
    ) with Not_found -> (
      (* Format.printf "dunno what dat is: %a@.@." SVar.pp_print_state_var svar ; *)
      false
    )
  in

  (* Remove inputs from locals, they're in the state anyways. *)
  let locals =
    locals |> List.filter (
      fun local ->
        match I.bindings local with
        | (_, svar) :: tail ->
          let local_is_input = is_input svar in
          if List.exists (
            fun (_, svar) -> (is_input svar) <> local_is_input
          ) tail then failwith "\
            unreachable: indexed state variable is partially an input\
          " else (
            if not local_is_input then (
              true
            ) else (
              Format.printf "filtering local %a out@.@." SVar.pp_print_state_var svar ;
              false
            )
          )
        | [] -> failwith "unreachable: empty indexed state variable"
    )
  in

  let {
    N.inputs ; N.outputs ; N.locals ;
    N.equations ; N.state_var_source_map ; N.calls = real_calls ;
    N.asserts ; N.contract
  } as node =
    (* If there's a contract, add all assume and requires to locals.

    We need to do this because assumptions may mention pre of the mode
    requirements. *)
    let locals = match contract with
      | None -> locals
      | Some { C.assumes ; C.modes } ->
        let known =
          locals |> List.fold_left (
            fun set local ->
              I.bindings local |> List.fold_left (
                fun set (_, svar) -> SVS.add svar set
              ) set
          ) SVS.empty
        in
        (* Format.printf "known:@." ;
        SVS.iter (
          fun svar -> Format.printf "  %a@." SVar.pp_print_state_var svar
        ) known ;
        Format.printf "@." ; *)
        let locals, known =
          assumes |> List.fold_left (
            fun (locals, known) { C.svar } ->
              if SVS.mem svar known || is_input svar
              then locals, known else (
                (I.singleton I.empty_index svar) :: locals, SVS.add svar known
              )
          ) (locals, known)
        in
        (* Format.printf "known:@." ;
        SVS.iter (
          fun svar -> Format.printf "  %a@." SVar.pp_print_state_var svar
        ) known ;
        Format.printf "@." ; *)
        modes |> List.fold_left (
          fun (locals, known) { C.requires } ->
            requires |> List.fold_left (
              fun (locals, known) { C.svar } ->
                if SVS.mem svar known || is_input svar
                then locals, known else (
                  (I.singleton I.empty_index svar) :: locals, SVS.add svar known
                )
            ) (locals, known)
        ) (locals, known)
        |> fst
    in
    { node with N.locals = locals }
  in

  let calls, _ =
    real_calls |> List.fold_left (
      fun (l,cpt) c -> Call (cpt, c) :: l, cpt + 1
    ) ([], 0)
  in
  let equations =
    equations |> List.fold_left (fun eqs ( ((_ (* svar *), _), _) as eq ) ->
      (* if SVM.mem svar state_var_source_map
      then (Eq eq) :: eqs else eqs *)
      Eq eq :: eqs
    ) calls
  in
  let name = mk_id_legal node.N.name in
  let typ = mk_id_type node.N.name in

  let inputs, outputs, locals =
    I.bindings inputs, I.bindings outputs,
    locals |> List.map I.bindings |> List.flatten
    (* |> List.fold_left (fun locs index ->
      ( I.bindings index |> List.filter (fun (_, svar) ->
        SVM.mem svar state_var_source_map
        ) |> List.rev_append
      ) locs
    ) [] *)
  in

  (* Struct documentation for this system. *)
  ( match oracle_info with
    | None ->
      implem_doc_of_struct is_top fmt (
        name, inputs, outputs, real_calls, asserts, contract
      )
    | Some (assumes, guarantees, modes) ->
      oracle_doc_of_struct is_top fmt (
        name, inputs, outputs, assumes, guarantees, modes, state_var_source_map
      )
  ) ;

  (* Struct header. *)
  Format.fprintf fmt "pub struct %s {" typ ;

  (* Fields. *)
  inputs |> List.iter (fun (_, svar) ->
    Format.fprintf fmt "@.  /// Input: `%a`@.  pub %s%s: %a,"
      SVar.pp_print_state_var svar
      svar_pref
      (SVar.name_of_state_var svar)
      fmt_type (SVar.type_of_state_var svar)
  ) ;

  Format.fprintf fmt "@." ;

  outputs |> List.iter (fun (_, svar) ->
    Format.fprintf fmt "@.  /// Output: `%a`@.  pub %s%s: %a,"
      SVar.pp_print_state_var svar
      svar_pref
      (SVar.name_of_state_var svar)
      fmt_type (SVar.type_of_state_var svar)
  ) ;

  Format.fprintf fmt "@." ;

  locals |> List.iter (fun (_, svar) ->
    let source =
      try
        Format.asprintf ", %a"
          N.pp_print_state_var_source (
            SVM.find svar state_var_source_map
          )
      with Not_found -> ""
    in
    Format.fprintf
      fmt "@.  /// Local%s: `%a`@.  pub %s%s: %a,"
      source
      SVar.pp_print_state_var svar
      svar_pref
      (SVar.name_of_state_var svar)
      fmt_type (SVar.type_of_state_var svar)
  ) ;

  Format.fprintf fmt "@." ;

  calls |> List.iter (function
    | Call (cnt, ({ N.call_pos ; N.call_node_name } as call)) ->
      Format.fprintf
        fmt "@.  /// Call to `%a` (%a).@.  pub %s: %s,"
        (Id.pp_print_ident false) call_node_name
        fmt_pos_as_link call_pos
        (id_of_call cnt call)
        (mk_id_type call_node_name)
    | _ -> failwith "unreachable"
  ) ;

  Format.fprintf fmt "@.}@.@.impl System for %s {@." typ ;

  (* Input type. *)
  inputs
  |> Format.fprintf fmt "  type Input = (@.    @[<v>%a@]@.  ) ;@." (
    pp_print_list (fun fmt (_, svar) ->
      Format.fprintf fmt "%a, // %s%s (%a)"
        fmt_type (SVar.type_of_state_var svar)
        svar_pref
        (SVar.name_of_state_var svar)
        SVar.pp_print_state_var svar
    ) "@ "
  ) ;

  (* Output type. *)
  outputs |> Format.fprintf fmt "  type Output = (@.    @[<v>%a@]@.  ) ;@." (
    pp_print_list (fun fmt (_, svar) ->
      Format.fprintf fmt "%a, // %s%s (%a)"
        fmt_type (SVar.type_of_state_var svar)
        svar_pref
        (SVar.name_of_state_var svar)
        SVar.pp_print_state_var svar
    ) "@ "
  ) ;

  (* Arity. *)
  List.length inputs
  |> Format.fprintf fmt "  fn arity() -> usize { %d }@." ;

  (* Init. *)
  let input_cpt = ref 0 in
  let eqs_init =
    order_equations (fun expr -> expr.E.expr_init) inputs equations
  in
  assert (
    (List.length eqs_init) == (List.length equations)
  ) ;

  Format.fprintf fmt "  \
      fn init(input: Self::Input) -> Result<Self, ()> {@.    \
        @[<v>\
          // |===| Retrieving inputs.@ \
          %a@ @ \
          // |===| Computing initial state.@ \
          %a@ @ \
          // |===| Checking assertions.@ \
          %a@ @ \
          %a\
          // |===| Returning initial state.@ \
          Ok( %s {@   \
            @[<v>\
              // |===| Inputs.@ %a@ @ \
              // |===| Outputs.@ %a@ @ \
              // |===| Locals.@ %a@ @ \
              // |===| Calls.@ %a\
            @]@ \
          } )\
        @]@.  \
      }@.@.\
    "

    ( pp_print_list (fun fmt (_, svar) ->
        Format.fprintf fmt "let %s%s = input.%d ;"
          svar_pref
          (SVar.name_of_state_var svar) !input_cpt ;
        input_cpt := 1 + !input_cpt
      ) "@ "
    ) inputs

    ( pp_print_list (fun fmt -> function
        | Eq ((svar, _), expr) ->
          expr.E.expr_init
          |> E.base_term_of_expr (Numeral.succ E.base_offset)
          |> Format.fprintf fmt "let %s%s = %a ;"
            svar_pref
            (SVar.name_of_state_var svar)
            (fmt_term svar_pref)
        | Call (
          cnt, ({ N.call_node_name ; N.call_inputs ; N.call_outputs } as call)
        ) ->
          Format.fprintf fmt
            "\
              let %s = try!( %s::init( (@   @[<v>%a,@]@ ) ) ) ;@ \
              let (@   @[<v>%a,@]@ ) = %s.output() ;@ \
            "
            (id_of_call cnt call)
            (mk_id_type call_node_name)
            ( pp_print_list (fun fmt (_, svar) ->
                Format.fprintf fmt "%s%s"
                  svar_pref (SVar.name_of_state_var svar)
              ) ",@ "
            ) (I.bindings call_inputs)
            ( pp_print_list (fun fmt (_, svar) ->
                Format.fprintf fmt "%s%s"
                  svar_pref (SVar.name_of_state_var svar)
              ) ",@ "
            ) (I.bindings call_outputs)
            (id_of_call cnt call)
      ) "@ "
    ) eqs_init

    ( fun fmt asserts ->
      if oracle_info = None
      then
        Format.fprintf fmt
          "%a@ @ "
          ( pp_print_list (fun fmt (pos, svar) ->
              Format.fprintf fmt
                "// Assertion at %a@ if ! %s%s {@   \
                  @[<v>\
                    return Err(@   \
                      \"assertion failure in system `%s`: %a\".to_string()@ \
                    )\
                  @]@ \
                } ;"
                fmt_pos_as_link pos
                svar_pref (SVar.name_of_state_var svar)
                name
                fmt_pos_as_link pos
            ) "@ "
          ) asserts
    ) asserts

    ( fun fmt -> function
      | _ when oracle_info = None -> ()
      | None -> ()
      | Some { LustreContract.assumes } ->
        ( pp_print_list (fun fmt {
            LustreContract.pos ; LustreContract.num ; LustreContract.svar
          } ->
            Format.fprintf fmt
              "// Assumption number %d at %a@ if ! %s%s {@   \
                @[<v>\
                  return Err(@   \
                    \"assumption failure: \
                      %a (assumption number %d)\".to_string()@ \
                  )\
                @]@ \
              } ;"
              num
              fmt_pos_as_link pos
              svar_pref (SVar.name_of_state_var svar)
              fmt_pos_as_link pos
              num
          ) "@ "
        ) fmt assumes
    ) contract

    typ

    ( pp_print_list (fun fmt (_, svar) ->
        let name = svar_pref ^ SVar.name_of_state_var svar in
        Format.fprintf fmt "%s: %s," name name
      ) "@ "
    ) inputs

    ( pp_print_list (fun fmt (_, svar) ->
        let name = svar_pref ^ SVar.name_of_state_var svar in
        Format.fprintf fmt "%s: %s," name name
      ) "@ "
    ) outputs

    ( pp_print_list (fun fmt (_, svar) ->
        let name = svar_pref ^ SVar.name_of_state_var svar in
        Format.fprintf fmt "%s: %s," name name
      ) "@ "
    ) locals

    ( pp_print_list (fun fmt -> function
        | Call (cpt, call) ->
          let name = id_of_call cpt call in
          Format.fprintf fmt "%s: %s," name name
        | _ -> failwith "unreachable"
      ) "@ "
    ) calls ;

  (* Next. *)
  let input_cpt = ref 0 in
  let eqs_next =
    order_equations (fun expr -> expr.E.expr_step) inputs equations
  in
  assert (
    (List.length eqs_next) == (List.length equations)
  ) ;

  Format.fprintf fmt "  \
      fn next(&mut self, input: Self::Input) -> Result<(), ()> {@.    \
        @[<v>\
          // |===| Retrieving inputs.@ \
          %a@ @ \
          // |===| Computing next state.@ \
          %a@ @ \
          // |===| Checking assertions.@ \
          %a@ @ \
          // |===| Checking assumptions.@ \
          %a@ @ \
          // |===| Updating next state.@ \
          // |===| Inputs.@ %a@ @ \
          // |===| Outputs.@ %a@ @ \
          // |===| Locals.@ %a@ @ \
          // |===| Calls.@ %a@ @ \
          // |===| Return new state.@ Ok( () )\
        @]@.  \
      }@.@.\
    "

    ( pp_print_list (fun fmt (_, svar) ->
        Format.fprintf fmt "let %s%s = input.%d ;"
          svar_pref
          (SVar.name_of_state_var svar) !input_cpt ;
        input_cpt := 1 + !input_cpt
      ) "@ "
    ) inputs

    ( pp_print_list (fun fmt -> function
        | Eq ((svar, _), expr) ->
          (* Format.printf "eq: %a@.@." pp_print_equation eq ; *)
          expr.E.expr_step
          |> E.cur_term_of_expr (Numeral.succ E.base_offset)
          |> Format.fprintf fmt "let %s%s = %a ;"
            svar_pref
            (SVar.name_of_state_var svar)
            (fmt_term svar_pref)
        | Call (
          cnt, ({ N.call_inputs ; N.call_outputs } as call)
        ) ->
          Format.fprintf fmt
            "\
              let %s = try!( self.%s.next( (@   @[<v>%a,@]@ ) ) ) ;@ \
              let (@   @[<v>%a,@]@ ) = %s.output() ;\
            "
            (id_of_call cnt call)
            (id_of_call cnt call)
            ( pp_print_list (fun fmt (_, svar) ->
                Format.fprintf fmt "%s%s"
                  svar_pref (SVar.name_of_state_var svar)
              ) ",@ "
            ) (I.bindings call_inputs)
            ( pp_print_list (fun fmt (_, svar) ->
                Format.fprintf fmt "%s%s"
                  svar_pref (SVar.name_of_state_var svar)
              ) ",@ "
            ) (I.bindings call_outputs)
            (id_of_call cnt call)
      ) "@ "
    ) eqs_next

    ( pp_print_list (fun fmt (pos, svar) ->
        Format.fprintf fmt
          "// Assertion at %a@ if ! %s%s {@   \
            @[<v>\
              return Err(@   \
                \"assertion failure in system `%s`: %a\".to_string()@ \
              )\
            @]@ \
          } ;"
          fmt_pos_as_link pos
          svar_pref (SVar.name_of_state_var svar)
          name
          fmt_pos_as_link pos
      ) "@ "
    ) asserts

    ( fun fmt -> function
      | None -> ()
      | Some { LustreContract.assumes } ->
        ( pp_print_list (fun fmt {
            LustreContract.pos ; LustreContract.num ; LustreContract.svar
          } ->
            Format.fprintf fmt
              "// Assumption number %d at %a@ if ! %s%s {@   \
                @[<v>\
                  return Err(@   \
                    \"assumption failure: \
                      %a (assumption number %d)\".to_string()@ \
                  )\
                @]@ \
              } ;"
              num
              fmt_pos_as_link pos
              svar_pref (SVar.name_of_state_var svar)
              fmt_pos_as_link pos
              num
          ) "@ "
        ) fmt assumes
    ) contract

    ( pp_print_list (fun fmt (_, svar) ->
        let name = svar_pref ^ SVar.name_of_state_var svar in
        Format.fprintf fmt "self.%s = %s ;" name name
      ) "@ "
    ) inputs

    ( pp_print_list (fun fmt (_, svar) ->
        let name = svar_pref ^ SVar.name_of_state_var svar in
        Format.fprintf fmt "self.%s = %s ;" name name
      ) "@ "
    ) outputs

    ( pp_print_list (fun fmt (_, svar) ->
        let name = svar_pref ^ SVar.name_of_state_var svar in
        Format.fprintf fmt "self.%s = %s ;" name name
      ) "@ "
    ) locals

    ( pp_print_list (fun fmt -> function
        | Call (cpt, call) ->
          let name = id_of_call cpt call in
          Format.fprintf fmt "self.%s = %s ;" name name
        | _ -> failwith "unreachable"
      ) "@ "
    ) calls ;

  (* Output. *)
  outputs
  |> Format.fprintf fmt "  \
    fn output(&self) -> Self::Output {(@.    \
      @[<v>%a@],@.  \
    )}@.\
  " (
    pp_print_list (fun fmt (_, svar) ->
      Format.fprintf fmt "self.%s%s" svar_pref (SVar.name_of_state_var svar)
    ) ",@ "
  ) ;

  Format.fprintf fmt "}@.@." ;

  calls |> List.map (
    function
    | Call (_, { N.call_node_name } ) -> call_node_name
    | _ -> failwith "unreachable"
  )

(* Dumps the default [Cargo.toml] file in a directory. *)
let dump_toml is_oracle name dir =
  let rsc_dir = "rsc" in
  let build_file = Format.sprintf "%s/build.rs" rsc_dir in

  (* Generate cargo configuration file. *)
  let out_channel = Format.sprintf "%s/Cargo.toml" dir |> open_out in
  let fmt = Format.formatter_of_out_channel out_channel in
  Format.fprintf fmt
    "\
      [package]@.\
      name = \"%s_%s\"@.\
      version = \"0.1.0\"@.\
      authors = [\"Kind 2 <elew@galois.com>\"]@.\
      edition = \"2021\"@.\
      @.\
      # See more keys and their definitions at https://doc.rust-lang.org/cargo/reference/manifest.html@.\
      @.\
      [dependencies]@.\
    "
    name (if is_oracle then "oracle" else "implem");

  close_out out_channel 

(* TODO: Compiles a node to rust without std, writes it to a Formatter *)
let to_rust_no_std oracle_info target find_sub top =
  (* Format.printf "node: @[<v>%a@]@.@." (N.pp_print_node false) top ; *)
  let top_name, top_type = L2R.mk_id_legal top.N.name, L2R.mk_id_type top.N.name in
  (* Creating project directory if necessary. *)
  mk_dir target ;
  (* Creating source dir. *)
  let src_dir = Format.sprintf "%s/src" target in
  mk_dir src_dir ;
  (* Dump toml configuration file. *)
  dump_toml (oracle_info <> None) top_name target ;
  (* Opening writer to file. *)
  let file = Format.sprintf "%s/lib.rs" src_dir in
  let out_channel = open_out file in
  let fmt = Format.formatter_of_out_channel out_channel in
  Format.pp_set_margin fmt max_int ;

  (* Write prefix and static stuff. *)
  Format.fprintf
    fmt "%a@.%a@.@."
    ( match oracle_info with
      | None -> fmt_prefix_implem top_name
      | _    -> fmt_prefix_oracle top_name
    ) top_type
    fmt_main ()
    (* (consts "unimplemented" "unimplemented" "unimplemented") *) ;
  
  let rec compile is_top systems compiled = function
    | node :: nodes ->
      let systems, compiled, nodes =
        if Id.Set.mem node.N.name compiled |> not then (
          (* Oracle info only makes sense for the top node. *)
          let oracle_info = if not is_top then None else oracle_info in
          (* Remembering we compiled this node. *)
          let compiled = Id.Set.add node.N.name compiled in
          
          node :: systems,
          compiled,
          nodes @ (
            (* Compiling nodes, getting subnodes back. *)
            node_to_rust oracle_info is_top fmt node
            (* Discarding subnodes we already compiled. *)
            |> List.fold_left (fun l call_id ->
              if Id.Set.mem call_id compiled |> not
              then (Id.to_scope call_id |> find_sub) :: l else l
            ) []
          )
        ) else systems, compiled, nodes
      in
      compile false systems compiled nodes
    | [] -> systems
  in

  let systems = compile true [] Id.Set.empty [ top ] in

  Format.fprintf fmt "@.@." ;

  (* we will deal with the helpers later... and in another workspace *)
  Format.fprintf fmt "%a@.@." fmt_helpers systems ;

  (* Flush and close file writer. *)
  close_out out_channel

let implem_to_rust_no_std = to_rust_no_std None