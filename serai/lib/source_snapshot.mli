(** Export tracked source bytes from a resolved jj commit, never from the working tree.
    Environment paths (.env and .env.* at any depth) are omitted based only
    on metadata, before any file body is requested. Unsafe paths, symlinks,
    conflicts and duplicate entries are still refused, including excluded paths.
    The resulting directory is local input, not a remote build attestation. *)
val stage :
  jj_bin:string -> checkout:string -> revision:string -> out:string ->
  (string, string) result

(** [stage] at most once per commit: a commit's tracked bytes never change,
    so its tree is kept at [cache]/<commit> and a later call returns it
    without exporting a file. Returns the commit and the tree. [cache] is
    created private, or must already be; the tree is shared, so callers only
    read it. *)
val stage_cached :
  jj_bin:string -> checkout:string -> revision:string -> cache:string ->
  (string * string, string) result
