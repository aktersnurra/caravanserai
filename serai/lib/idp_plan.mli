(** What serai idp would change: the declaration against Pocket ID's live
    state, as actions in an order where each refers only to what exists or
    an earlier action creates. Pure. *)

type kind = Group | User | Client | Api

(** A field that differs: a value, or a set-like list with what is added
    and removed (memberships, callback URLs, claims as [key=value],
    permission keys). *)
type change =
  | Value of string
  | Set of { field : string; added : string list; removed : string list }

(** An action carries the whole declared resource: Pocket ID's updates
    replace a record, so the declared record is what is sent. *)
type action =
  | Create_group of Idp_declaration.group
  | Update_group of { group : Idp_declaration.group; changes : change list }
  | Create_user of Idp_declaration.user
  | Update_user of { user : Idp_declaration.user; changes : change list }
  | Create_client of Idp_declaration.client
  | Update_client of { client : Idp_declaration.client; changes : change list }
  | Create_api of Idp_declaration.api  (** with its permissions; CIMD and grants follow *)
  | Update_api of { api : Idp_declaration.api; changes : change list }  (** name, permissions *)
  | Set_cimd of { resource : string; permissions : string list option }
  | Set_grant of { resource : string; grant : Idp_declaration.grant }
  | Remove_grant of { resource : string; client : string }

type t = {
  actions : action list;
  undeclared : (kind * string) list;  (** live, not declared: reported, never acted on *)
  secrets_needed : string list;  (** confidential clients this plan creates *)
}

(** Within a declared resource the declaration is complete: a group, claim,
    callback URL, permission or grant it leaves out is removed. A token
    lifetime it leaves out is left as it is live. Set-like lists compare
    regardless of order. *)
val plan : Idp_declaration.t -> Idp_live.t -> t

(** Whether there are actions; undeclared resources alone are not. *)
val pending : t -> bool

(** One line per action, then one per undeclared resource; none in sync. *)
val lines : t -> string list

val to_json : t -> Agent_cli.json

(** The live state as a declaration, validated as idp.sexp is. *)
val export : url:string -> Idp_live.t -> (Idp_declaration.t, string) result
