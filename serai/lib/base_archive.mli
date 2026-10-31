(** The declared FreeBSD base archive for build jails, cached by digest. *)

(** Return the cached archive for [sha256], downloading [url] on first use.
    The digest is checked on every call, cached or fresh; a mismatching
    download is discarded, a mismatching cached file is refused (not replaced). *)
val ensure : curl_bin:string -> cache:string -> url:string -> sha256:string -> (string, string) result
