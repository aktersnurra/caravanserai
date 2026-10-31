type kind = Phoenix | Ocaml

type t = {
  app : App_config.t;
  kind : kind;
  host : Topology.host;
  build : Topology.build;
  source_url : string;
  opam_repository : Strategy_config.pinned_git option;
  public_url : string;
}

let ( let* ) = Result.bind

let of_app ~topology (app : App_config.t) =
  let name = app.endpoint.name in
  let missing field = Error (Printf.sprintf "%s: declare %s in its app.sexp to use serai up" name field) in
  let* kind, source, opam_repository, check_path =
    match app.strategy with
    | Strategy_config.Freebsd_native_elixir s -> Ok (Phoenix, s.source, None, s.check_path)
    | Strategy_config.Freebsd_native_ocaml s ->
        (match s.opam_repository with
         | None -> missing "(opam_repository (git <url>) (commit <id>))"
         | Some _ as r -> Ok (Ocaml, s.source, r, s.check_path))
    | _ -> Error (name ^ ": serai up handles phoenix and ocaml apps only") in
  let* source_url = match source with Some url -> Ok url | None -> missing "(source (git <url>))" in
  let* host =
    match Topology.jail_host topology name with
    | host -> Ok host
    | exception Failure message -> Error message in
  let* build = match host.build with
    | Some build -> Ok build
    | None -> Error (Printf.sprintf "%s: host %s declares no (build ...) in topology.sexp" name host.id) in
  Ok { app; kind; host; build; source_url; opam_repository;
       public_url = "https://" ^ app.endpoint.hostname ^ check_path }
