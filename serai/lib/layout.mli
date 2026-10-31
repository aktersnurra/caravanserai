(** Where serai finds its own files (the engine: build, install and host
    scripts) and the operator's declarations (the configuration: apps,
    guests, edge, topology). Every path serai reads goes through here, so
    the two can live in separate repositories. *)

type t

val v : engine:string -> config:string -> t

(** From [from] upward, the configuration is the nearest directory holding
    serai.sexp. The engine is the nearest directory above it
    holding compute/apps/_lib (an engine checkout), else [installed] when it
    holds one (the engine installed beside the binary). *)
val discover : from:string -> installed:string -> (t, string) result
val engine : t -> string
val config : t -> string

(** {1 Configuration}

    {v
    serai.sexp          hosts, compute and proxy; the configuration's anchor
    logging.sexp
    pipelines.sexp
    apps/<app>/         app.sexp, config, env.template, hooks, extra steps
    guests/<guest>/     guest.sexp, ...
    edge/edge.sexp
    edge/caddy/         Caddyfile and sites/<nn>-<app>.caddy.template
    edge/...            other files the edge host scripts read (oauth2-proxy/)
    v} *)

val topology : t -> string
val pipelines : t -> string
val logging : t -> string
val apps_dir : t -> string
val app_dir : t -> string -> string
val guests_dir : t -> string
val edge : t -> string
val caddy_root_template : t -> string
val caddy_sites : t -> string

(** The same paths relative to the configuration root, for files serai
    writes and names to the operator. *)
module Relative : sig
  val topology : string
  val app_file : app:string -> string -> string
  val caddy_sites : string
  val caddy_site : string -> string
end

(** A path a declaration names relative to the configuration, such as a
    source checkout; absolute paths are returned unchanged. *)
val config_path : t -> string -> string

(** {1 Engine} *)

val lib_dir : t -> string
val lib_file : t -> string -> string
val pf_rules : t -> string

(** The edge host log sender's syslog-ng config, the receiver left as placeholders. *)
val edge_sender_template : t -> string

(** The directories whose contents make up the edge host stage's [edge/]: the
    engine's host scripts and the configuration's edge files. *)
val edge_sources : t -> string list
