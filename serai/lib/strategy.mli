(** Total rendering over the parsed strategy stored in the app declaration.
    [jail_name] is the host-side jail name, the endpoint name by default;
    every in-jail name stays the app's. Raises [Invalid_argument] only when
    [jail_name] cannot namespace a ZFS dataset (see [zfs_dataset_for]). *)
val render_jail_script : ?jail_name:string -> App_config.t -> string

(** The dataset a jail named [jail] uses for [app]'s [dataset]: unchanged
    when [jail = app], suffixed with [jail]'s extension of [app] otherwise.
    Raises [Invalid_argument] when [jail] does not extend [app]. *)
val zfs_dataset_for : jail:string -> app:string -> string -> string
