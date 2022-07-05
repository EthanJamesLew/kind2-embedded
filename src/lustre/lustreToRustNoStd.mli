(** Compiles a lustre node to Rust as a project in the directory given as first
argument. *)
val implem_to_rust_no_std :
  string -> (Scope.t -> LustreNode.t) -> LustreNode.t -> unit