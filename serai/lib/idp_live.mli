(** Pocket ID's live resources, decoded from its admin API's responses into
    {!Idp_declaration}'s record types so a plan compares like with like.
    Pure: the HTTP is {!Pocket_id}'s. *)

type 'a with_id = { id : string; value : 'a }

(** What a client has live that idp.sexp does not declare. Pocket ID's update
    replaces the whole client, so these are sent back as they came. *)
type client_extra = {
  has_logo : bool;
  has_dark_logo : bool;
  requires_reauthentication : bool;
  pushed_authorization_requests : bool;
  federated_identities : Json.t;  (** as received; [Null] or an array *)
}

(** The same for a user: an update must not unverify an address. *)
type user_extra = { email_verified : bool }

type api = {
  api : Idp_declaration.api;
  permission_ids : (string * string) list;  (** key -> Pocket ID's id *)
}

type t = {
  version : string;
  key_owner : string;  (** the id of the user the API key acts as *)
  groups : Idp_declaration.group with_id list;
  users : (Idp_declaration.user * user_extra) with_id list;  (** without the static API key user *)
  clients : (Idp_declaration.client * client_extra) with_id list;
  apis : api with_id list;
}

(** The user Pocket ID makes for [STATIC_API_KEY]; never live state. *)
val static_api_key_user : string

(** A list page's items, and whether another page follows. *)
val page : Json.t -> (Json.t list * [ `More | `Last ], string) result

(** [GET /api/version/current]: ["2.19.1"]. *)
val version : Json.t -> (string, string) result

(** The live state from every page's items: [/user-groups], [/users],
    [/oidc/clients], and each of [/apis] with its [/apis/:id/clients].
    CIMD clients ([clientType "cimd"]) are left out: their vendors register
    them. An error names the resource and the field. A client restricted to no
    groups is an error: idp.sexp cannot declare it, and reading it as
    unrestricted would open it to everyone. A token lifetime of 0 is
    [None]. [key_owner] is [GET /api/users/me]'s response. *)
val assemble :
  version:string -> key_owner:Json.t -> groups:Json.t list -> users:Json.t list -> clients:Json.t list ->
  apis:(Json.t * Json.t list) list -> (t, string) result
