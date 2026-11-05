(** serai drift: where the live system differs from the declaration. *)

(** One workload's drift. A checked app that drifted carries the up plan
    for its target commit, the plan serai up --plan gives. *)
type app_drift =
  | App_checked of {
      app : string;
      state : Drift_app.state;
      live : string option;  (** the commit the host records for the active release *)
      target : Drift_app.target;
      plan : Dispatcher.up_plan option;
    }
  | App_unavailable of { app : string; message : string }
  | App_not_covered of string  (** no source commit to compare *)

(** Checks one app: its releases probed read-only on the compute host, its
    mirror synced, the target resolved ([deploy], else the default branch),
    ancestry asked when they differ, and an up plan when it drifted. A live
    commit the mirror lacks is [Diverged]. Any failure is [App_unavailable].
    Package, pinned-binary and package-service workloads, and source-built
    apps that declare no source, are not covered. *)
val app : Dispatcher.env -> string -> cache:string -> store:string -> app_drift

(** A section checked, one that couldn't be (with the reason), or one the
    configuration doesn't declare. *)
type 'a section = Checked of 'a | Unavailable of string | Not_declared

type t = {
  edge : Dispatcher.edge_plan section;
  idp : Idp_plan.t section;
  apps : app_drift list;  (** declared apps in order, then guests (not covered) *)
}

(** Plans the edge (staging and diffing under the hosts' locks), the
    identity provider (without SERAI_IDP_API_KEY, no request is made) and
    every app, each on its own: one that fails is [Unavailable] and the rest
    still run. Installs nothing. An idp plan that would lock out the key's
    owner stays [Checked] with its [lockout]. *)
val run : Dispatcher.env -> cache:string -> store:string -> t

(** An edge or idp plan is pending, or an app is behind, diverged or not
    deployed. *)
val drifted : t -> bool

(** Nothing is [Unavailable]. *)
val complete : t -> bool

(** 2 when drifted, else 1 when incomplete, else 0. *)
val exit_code : t -> int
