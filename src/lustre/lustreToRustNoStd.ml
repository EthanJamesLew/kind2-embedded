open Lib

module L2R = LustreToRust
module N = LustreNode

(* TODO: Compiles a node to rust without std, writes it to a Formatter *)
let to_rust_no_std oracle_info target find_sub top =
  (* Format.printf "node: @[<v>%a@]@.@." (N.pp_print_node false) top ; *)
  let top_name, top_type = L2R.mk_id_legal top.N.name, L2R.mk_id_type top.N.name in
  (* Creating project directory if necessary. *)
  mk_dir target ;
  (* Creating source dir. *)
  let src_dir = Format.sprintf "%s/src" target in
  mk_dir src_dir ;
  ()

let implem_to_rust_no_std = to_rust_no_std None