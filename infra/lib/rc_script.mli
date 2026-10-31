(** The rc.d script of a native-kind app, rendered from its declaration.

    Layout it assumes, inside the jail, for app [a]: code through the
    [/opt/a] pointer the first activation creates, HOME and state in
    [/var/db/a], logs in [/var/log/a], runtime files in [/var/run/a], and the
    operator's [/etc/a/env] ([root:a 0640]). Every command refuses an env
    file that leaves a name its [env.template] declares unset, empty or
    [REPLACE_ME]. A declared migrate becomes the [migrate]
    extra command, which activation runs between stop and start. *)

type t = private {
  service : string;  (** rc.d name: the release name (phoenix) or app name (ocaml) *)
  script : string;
}

(** [app] is the app's name inside the jail; [env_names] are
    [Env_template.names]. *)
val phoenix : app:string -> env_names:string list -> Strategy_config.freebsd_native_elixir -> t
val ocaml : app:string -> env_names:string list -> Strategy_config.freebsd_native_ocaml -> t

(** The script for a native-kind app; [None] for any other strategy. *)
val render : App_config.t -> t option
