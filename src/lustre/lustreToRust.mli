(* This file is part of the Kind 2 model checker.

   Copyright (c) 2015 by the Board of Trustees of the University of Iowa

   Licensed under the Apache License, Version 2.0 (the "License"); you
   may not use this file except in compliance with the License.  You
   may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0 

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
   implied. See the License for the specific language governing
   permissions and limitations under the License. 

*)

(** Compilation from [LustreNode.t] to Rust. *)

open Lib

module Id = LustreIdent

(** Compiles a lustre node to Rust as a project in the directory given as first
argument. *)
val implem_to_rust :
  string -> (Scope.t -> LustreNode.t) -> LustreNode.t -> unit

(** Compiles a lustre node as an oracle. *)
val oracle_to_rust: string -> (Scope.t -> LustreNode.t) -> LustreNode.t -> (
  string * (position * int) list * (string * position * int) list
)

(** add the Lustre -> Rust Functions so they can be reused in the NoStd version *)
(* Unsafe string representation of an ident, used for rust identifiers. *)
val mk_id_legal: 
  Id.t -> string

(* Same as [mk_id_legal] but capitalizes the first letter to fit rust
conventions for type naming. *)
val mk_id_type:
  Id.t -> string
