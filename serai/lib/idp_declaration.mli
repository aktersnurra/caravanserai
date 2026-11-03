(** The identity provider's resources as the configuration declares them in
    idp.sexp: Pocket ID's groups, users, OIDC clients and APIs. Parsed and
    validated once here; everything after trusts these values. *)

type claim = { key : string; value : string }

type group = { name : string; friendly_name : string; claims : claim list }

type user = {
  username : string;
  email : string option;
  first_name : string;
  last_name : string;
  display_name : string;
  admin : bool;
  disabled : bool;
  locale : string option;
  groups : string list;
  claims : claim list;
}

type client = {
  id : string;  (** the OIDC client ID, chosen here so it survives a rebuild *)
  name : string;
  description : string;
  callback_urls : string list;
  logout_callback_urls : string list;
  backchannel_logout_url : string option;
  launch_url : string option;
  public : bool;
  pkce : bool;
  skip_consent : bool;
  allowed_groups : string list;  (** [] = not group-restricted *)
  access_token_minutes : int option;  (** [None] = Pocket ID's default *)
  refresh_token_minutes : int option;
}

type permission = { key : string; name : string; description : string option }

(** A client's access to an API: [Some] grants it, with those permissions. *)
type grant = {
  client : string;
  user_delegated : string list option;
  client_credentials : string list option;
}

type api = {
  resource : string;  (** the audience; matched byte for byte *)
  name : string;
  permissions : permission list;
  cimd : string list option;  (** [Some] = CIMD clients allowed, with these permissions *)
  grants : grant list;
}

type t = private {
  url : string;  (** https, no trailing slash *)
  groups : group list;
  users : user list;
  clients : client list;
  apis : api list;
}

(** Refuses unknown or repeated fields, duplicates, references to anything
    undeclared, Pocket ID's reserved claim names, and values Pocket ID
    v2.19.1 would refuse (name lengths, username and client ID characters,
    an audience that is not an absolute URI). The error names the resource. *)
val parse : Sexplib.Sexp.t -> (t, string) result

(** A declaration from its parts, validated as [parse] validates a file. *)
val make :
  url:string -> groups:group list -> users:user list -> clients:client list -> apis:api list ->
  (t, string) result

(** The configuration's idp.sexp, or [None] when it has none. *)
val load : layout:Layout.t -> (t option, string) result

(** The declaration as idp.sexp writes it, leaving out defaults:
    [parse (to_sexp t) = Ok t]. *)
val to_sexp : t -> Sexplib.Sexp.t

(** One resource as [to_sexp] prints it, its key first: two different
    records never print the same. *)
val group_to_sexp : group -> Sexplib.Sexp.t
val user_to_sexp : user -> Sexplib.Sexp.t
val client_to_sexp : client -> Sexplib.Sexp.t
val api_to_sexp : api -> Sexplib.Sexp.t

(** [to_sexp], indented, with UTF-8 written as it is rather than as
    Sexplib's [\ddd] escapes; it reads back the same. *)
val to_string : t -> string
