(** A local jj clone of a declared git remote, kept only as build input.
    Builds read it through {!Source_snapshot}; nothing is ever committed in it. *)
type t

val path : t -> string

(** The origin URL a jj checkout records, before any git insteadOf rewrite. *)
val origin_url : jj_bin:string -> string -> (string, string) result

(** Clone [url] into [cache]/sources/[name] on first use, otherwise check the
    mirror still points at [url] and fetch. Cache directories are private. *)
val sync : jj_bin:string -> cache:string -> name:string -> url:string -> (t, string) result

(** Resolve a bookmark name or full commit id to a commit id. Bookmarks are
    read from the remote ([name@origin]), and the commit must be reachable
    from a remote bookmark: unpushed work is never built from a mirror. *)
val resolve : jj_bin:string -> t -> revision:string -> (string, string) result

type signature_status = Good | Bad | Unknown_key | Invalid

type signature =
  | Unsigned
  | Signed of { status : signature_status; key : string }
      (** [key] as jj reports it: a gpg long key id, an ssh key fingerprint,
          or empty when jj could not tell. *)

(** jj's verdict on [commit]'s signature, verified with the setup the
    caller puts in [extra_env] (GNUPGHOME, JJ_CONFIG). [commit] must be a
    full commit id. Deciding whether the verdict is trusted is the caller's. *)
val signature :
  jj_bin:string -> ?extra_env:(string * string) list -> t -> commit:string ->
  (signature, string) result

(** The verdict [signature] reads from jj's output, exposed for its tests.
    Anything but the template's exact shape is an error. *)
val parse_signature : string -> (signature, string) result

(** Whether [ancestor] is [descendant] or one of its ancestors. Both must
    be full commit ids. *)
val is_ancestor : jj_bin:string -> t -> ancestor:string -> descendant:string -> (bool, string) result

(** The commit the remote bookmark [name]@origin points at, [None] when
    there is no such bookmark. *)
val remote_bookmark : jj_bin:string -> t -> string -> (string option, string) result
