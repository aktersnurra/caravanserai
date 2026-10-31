(** A validated artifact record. Construction checks syntax, not provenance:
    adapters must attest the immutable input and observed target dependencies. *)

type dependency = { name : string; version : string; sha256 : string }
type input =
  | Source_commit of string
  | Package_archives of string
  | Upstream_binary of { version : string; url : string; sha256 : string }
type t = private {
  name : string;
  input : input;
  target_abi : string;
  dependencies : dependency list;
  recipe_sha256 : string;
  release_name : string;
  archive_sha256 : string;
}

(** Package input names the principal package in the resolved archive closure.
    Binary input pins the downloaded bytes independently of the payload archive.
    Source input preserves the existing v1 canonical encoding/identity. *)
val create_input :
  name:string -> input:input -> target_abi:string ->
  dependencies:dependency list -> recipe_sha256:string ->
  release_name:string -> archive_sha256:string -> (t, string) result

(** Parse newline-terminated name/version/archive-SHA256 TSV records.
    Checks syntax and uniqueness, not provenance. *)
val dependencies_of_inventory : string -> (dependency list, string) result

val create :
  name:string -> source_commit:string -> target_abi:string ->
  dependencies:dependency list -> recipe_sha256:string ->
  release_name:string -> archive_sha256:string -> (t, string) result

(** Versioned binary encoding; dependency order is canonical. *)
val canonical : t -> string

(** Read only canonical, validated bytes. This checks syntax and uniqueness,
    not provenance or permission to reuse a stored artifact. *)
val of_canonical : string -> (t, string) result
val identity : t -> string

(** Checks a regular archive's bytes against the recorded SHA-256.
    Store adapters must secure the containing directory against concurrent edits. *)
val verify_archive : t -> archive:string -> (unit, string) result
