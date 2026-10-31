(** Versioned Phoenix build recipe. The digest commits to the exact staged
    adapter script bytes, trusted base archive SHA-256, release name, and
    declared package arguments in order. It does not attest remote execution
    or resolved package archive checksums. *)

type staged = { sha256 : string; scripts : (string * string) list }

(** Snapshot the executable builder and bind its typed package/binary origin,
    base and declared package recipe. Source-v1 recipe bytes remain unchanged. *)
val stage_executable : lib_dir:string -> out:string -> base_sha256:string ->
  release_name:string -> packages:string list -> input:Artifact_manifest.input ->
  (staged, string) result

(** Bind the declared compiler and immutable opam repository inventory to the
    OCaml worker, base, release and package inputs, and the declared web
    bundle script when there is one. Without one the recipe bytes are those
    of before web bundles, so stored artifacts stay reusable. *)
val stage_ocaml : lib_dir:string -> out:string -> base_sha256:string ->
  release_name:string -> packages:string list -> compiler:string ->
  repository_commit:string -> repository_sha256:string -> web_bundle:string option ->
  (staged, string) result

(** Bind a guest workload's declared project, target and release, the exact
    variant compiler, repository snapshot and Linux worker helper bytes. This
    does not attest the live guest's runtime. *)
val stage_guest : lib_dir:string -> out:string -> project:string -> target:string ->
  release_name:string -> compiler:string -> repository_commit:string ->
  repository_sha256:string -> (staged, string) result

(** Copy the five builder scripts into a fresh private [out] directory and
    return their per-file SHA-256s plus the complete recipe SHA-256. The caller
    transfers scripts from [out], never from the mutable originals. *)
val stage : lib_dir:string -> out:string -> base_sha256:string ->
  release_name:string -> packages:string list -> (staged, string) result
