(** Pocket ID's admin API over HTTPS, through curl: the version check, the
    live state and applying a plan. The API key never reaches a command
    line: each request is [sh -c] printing it with the shell's built-in
    [printf] into [curl --config -], from the child's environment. *)

type session

(** Reads [SERAI_IDP_API_KEY] once. The error says how to set it, or why the
    value cannot be used. *)
val session : url:string -> (session, string) result

(** [request] is the method and path ("GET /api/users"): never a header or a
    response body, so no error carries a key or a secret. *)
type error = { request : string; status : int option; code : string option; message : string }

val error_message : error -> string

(** The Pocket ID minor version serai idp was tested against: "2.19". *)
val supported : string

(** Checks the server's version first and refuses anything but
    {!supported}.x before another request; then the key's owner, every page
    of groups, users, clients and APIs, and each API's grants. *)
val fetch : ?curl_bin:string -> session -> (Idp_live.t, error) result

type applied = { completed : Idp_plan.action list; failed : (Idp_plan.action * error) option }

(** The plan's actions in order, stopping at the first failure; there is no
    rollback, and a rerun plans afresh from the live state. Ids come from the
    live state and from creates earlier in the run. A new user's groups and
    claims are set explicitly, overriding Pocket ID's defaults for new users.
    A new confidential client's auto-created secret is deleted, reading only
    its id. A client update sends back what idp.sexp does not declare, and
    an omitted token lifetime as it is live. *)
val apply : ?curl_bin:string -> session -> Idp_live.t -> Idp_plan.t -> applied
