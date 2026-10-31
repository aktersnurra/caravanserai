(** Where a workload's shell [config] disagrees with its declaration.

    app.sexp and guest.sexp are what serai renders from, but each service's
    shell [config] still carries the same network facts for the host-side
    jail, service, deploy and check scripts: JAIL_IP (a guest's GUEST_IP),
    PORT, a [<NAME>_PORT] per other named port, and PUBLIC_HOST or PHX_HOST;
    a Phoenix app's APP, when set, is its release_name. A guest's config also
    carries GUEST_USER and the default of SOURCE_CHECKOUT, which its
    guest.sexp declares as login_user and source_checkout.

    An app's bootstrap and check are generated from app.sexp, so an app
    without scripts of its own has no config; a guest's scripts always read
    theirs. *)

type disagreement =
  | Missing of { config : string; declaration : string }
      (** A guest's config is absent. *)
  | Unreadable of { config : string; reason : string }
      (** /bin/sh could not source it. *)
  | Mismatch of {
      config : string;
      variable : string;
      actual : string option;  (** [None]: unset or empty. *)
      declaration : string;
      field : string;
      expected : string;
    }

val message : disagreement -> string

(** Every disagreement in the declaration's apps, then its guests; [] when
    they agree. Each config is sourced by /bin/sh in its own process, as the
    scripts do, with an environment holding only PATH, so nothing inherited
    can stand in for a value the file does not set. *)
val check : Declaration.t -> disagreement list
