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
