type hook = Bootstrap | Deploy | Check | Update_version
val hook_of_sexp : Sexplib.Sexp.t -> hook

type t = private {
  endpoint : Network_endpoint.t;
  strategy : Strategy_config.t;
  hooks : hook list;
  extra_steps : string list;
  env_names : string list;
      (** the variables the app's env.template declares; none without one *)
}

(** Refuses any extra step that is not a plain file name beside the script. *)
val create : ?env_names:string list -> endpoint:Network_endpoint.t ->
  strategy:Strategy_config.t -> hooks:hook list -> extra_steps:string list -> unit ->
  (t, Strategy_config.error) result

(** The same app with another (validated) endpoint; used by Jail_test to
    move an app to its test jail's ip. *)
val with_endpoint : t -> Network_endpoint.t -> t

(** Sexplib adapter: malformed fields, unknown or malformed strategies and
    invalid extra steps raise Of_sexp_error at load. *)
val of_sexp : Sexplib.Sexp.t -> t

(** [of_sexp] on the file, plus the names of the [env.template] beside it;
    a malformed template raises [Failure]. *)
val load : string -> t
val load_all : string -> t list
val endpoint : t -> Network_endpoint.t
val supports : t -> hook -> bool
val find : t list -> string -> t option
val names : t list -> string list
