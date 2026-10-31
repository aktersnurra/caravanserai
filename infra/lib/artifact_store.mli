(** Local candidate store. Requires a syntactically complete manifest, but
    does not attest its source or dependency provenance. An offline plan's MD5
    preview path is not a store identity. The root must already exist, be
    owned by this process and inaccessible to others. *)

(** Validate store ownership/privacy before starting expensive remote work. *)
val validate_root : string -> (unit, string) result

(** Return the archive path only after comparing the canonical manifest and
    rehashing the archive. Refuses missing, unsafe, or corrupted entries. *)
val reuse : root:string -> manifest:Artifact_manifest.t -> (string, string) result

(** Select an identity only inside a private owned store, decode its canonical
    manifest, require identity agreement and rehash its archive. Store population
    still needs trusted adapter provenance; parsing alone does not grant it. *)
val load : root:string -> identity:string ->
  (Artifact_manifest.t * string, string) result

(** The first entry whose manifest satisfies [f], in identity order. Only
    manifests are read while searching; the match then gets the full [load]
    verification, and failing it is an error, not a miss. Unreadable or
    non-identity entries are skipped. *)
val find : root:string -> f:(Artifact_manifest.t -> bool) -> (string option, string) result

(** Verify the source archive, then publish it and the canonical manifest as a
    single renamed directory. An existing entry is reused only after full
    verification; corrupted entries are never overwritten. *)
val publish : root:string -> manifest:Artifact_manifest.t -> archive:string ->
  (string, string) result
