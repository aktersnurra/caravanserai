type t = { engine : string; config : string }

let v ~engine ~config = { engine; config }

let engine_marker = "compute/apps/_lib"

module Relative = struct
  let topology = "serai.sexp"
  let pipelines = "pipelines.sexp"
  let logging = "logging.sexp"
  let apps_dir = "apps"
  let app_file ~app name = String.concat "/" [ apps_dir; app; name ]
  let guests_dir = "guests"
  let edge_dir = "edge"
  let edge = "edge/edge.sexp"
  let caddy_root_template = "edge/caddy/Caddyfile"
  let caddy_sites = "edge/caddy/sites"
  let caddy_site name = caddy_sites ^ "/" ^ name
end

let discover ~from ~installed =
  let holds marker dir = Sys.file_exists (Filename.concat dir marker) in
  let rec nearest marker dir =
    if holds marker dir then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else nearest marker parent in
  match nearest Relative.topology from with
  | None -> Error ("could not locate " ^ Relative.topology ^ ": run from within a configuration")
  | Some config -> (
      match nearest engine_marker config with
      | Some engine -> Ok { engine; config }
      | None when holds engine_marker installed -> Ok { engine = installed; config }
      | None ->
          Error (Printf.sprintf "no engine: neither an engine checkout above %s nor %s" config installed))
let engine t = t.engine
let config t = t.config

let in_config t path = Filename.concat t.config path
let in_engine t path = Filename.concat t.engine path

let topology t = in_config t Relative.topology
let pipelines t = in_config t Relative.pipelines
let logging t = in_config t Relative.logging
let apps_dir t = in_config t Relative.apps_dir
let app_dir t name = Filename.concat (apps_dir t) name
let guests_dir t = in_config t Relative.guests_dir
let edge t = in_config t Relative.edge
let caddy_root_template t = in_config t Relative.caddy_root_template
let caddy_sites t = in_config t Relative.caddy_sites
let config_path t path = if Filename.is_relative path then in_config t path else path

let lib_dir t = in_engine t "compute/apps/_lib"
let lib_file t name = Filename.concat (lib_dir t) name
let pf_rules t = in_engine t "compute/01-pf-rules"
let edge_sender_template t = in_engine t "edge/syslog-ng-victoria.conf.template"

let edge_sources t = [ in_engine t "edge"; in_config t Relative.edge_dir ]
