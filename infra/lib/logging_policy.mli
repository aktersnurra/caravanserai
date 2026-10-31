type t

(** Rejects unknown/duplicate jails, undeclared apps, and a source that is
    neither local_only nor a reviewed sender the jail's app ships
    ([reviewed ~jail ~source]). *)
val parse :
  apps:App_config.t list -> reviewed:(jail:string -> source:string -> bool) -> Sexplib.Sexp.t ->
  (t, string) result

(** Reads the configuration's logging policy; an app ships a reviewed
    sender as [<app dir>/logging/<source>/sender.conf]. *)
val load : layout:Layout.t -> apps:App_config.t list -> t

val render_targets : t -> string

(** The app every sender forwards to: [(receiver <app>)], a declared app
    that is not itself one of the jails. *)
val receiver : t -> string

(** The (jail, source) of every reviewed sender, in declared order. *)
val reviewed : t -> (string * string) list

(** Where an app keeps a reviewed sender. *)
val sender_dir : Layout.t -> jail:string -> source:string -> string
