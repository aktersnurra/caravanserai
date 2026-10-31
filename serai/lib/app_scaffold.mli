(** serai new's pure part: the declaration a new Phoenix or OCaml app starts
    from. It reads nothing: the caller supplies the repo's facts, the current
    declaration and topology text, and writes the files.

    The app gets the lowest free address on its host's network (test jails
    conventionally take the top of the range), the next free http port in
    4000-4999 in steps of 10,
    a hostname under the base domain, and the next Caddy site number in
    40-49. Everything is checked by parsing it back before it is returned. *)

type kind =
  | Phoenix of { release_name : string; migrate : string option }
      (** [migrate]: the [Release.migrate] function to [release_eval] *)
  | Ocaml

(** The release name from mix.exs's [app: :name], and [<Module>.migrate]
    when lib/<name>/release.ex defines [<Module>] with a [migrate] function. *)
val phoenix : mix_exs:string -> release_ex:(string -> string option) -> (kind, string) result

type request = {
  name : string;  (** [a-z0-9]+, not ending in [test] (reserved for test jails) *)
  kind : kind;
  repo_path : string;  (** the local checkout *)
  source : string;  (** its origin, which builds fetch *)
  hostname : string option;  (** default: <name>.<base domain> *)
}

type file = { path : string; contents : string }  (** [path] relative to the configuration *)

type t = private {
  ip : string;
  port : int;
  hostname : string;
  files : file list;  (** app.sexp, env.template and the Caddy site: all new *)
  topology : string;  (** serai.sexp with the app placed and proxied *)
}

(** [topology] is serai.sexp's text and [templates] the file names in
    edge/caddy/sites. The app is placed on the only compute host. *)
val plan : Declaration.t -> topology:string -> templates:string list -> request -> (t, string) result
