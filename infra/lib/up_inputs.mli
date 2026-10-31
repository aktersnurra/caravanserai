(** Everything [infra up] needs for one app, derived from the declarations
    alone: no host, network or repository is consulted here. *)

type kind = Phoenix | Ocaml

type t = private {
  app : App_config.t;
  kind : kind;
  host : Topology.host;              (** where the jail runs and the build jail is made *)
  build : Topology.build;            (** that host's builder address and base archive *)
  source_url : string;               (** the app's git remote *)
  opam_repository : Strategy_config.pinned_git option;  (** [Some] exactly for [Ocaml] *)
  public_url : string;               (** https://<hostname><check_path> through the edge *)
}

val of_app : topology:Topology.t -> App_config.t -> (t, string) result
