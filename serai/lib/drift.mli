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
    commit the mirror lacks is [Diverged]. Any failure is [App_unavailable];
    package, pinned-binary and package-service workloads are not covered. *)
val app : Dispatcher.env -> string -> cache:string -> store:string -> app_drift
