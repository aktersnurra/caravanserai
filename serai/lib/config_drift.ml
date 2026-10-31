(* The shell configs' copies of the declaration's network facts, read back by
   sourcing each one under `set -a` and printing `env`. *)

type disagreement =
  | Missing of { config : string; declaration : string }
  | Unreadable of { config : string; reason : string }
  | Mismatch of {
      config : string;
      variable : string;
      actual : string option;
      declaration : string;
      field : string;
      expected : string;
    }

let message = function
  | Missing { config; declaration } -> Printf.sprintf "%s: missing, but %s declares it" config declaration
  | Unreadable { config; reason } -> Printf.sprintf "%s: cannot be sourced: %s" config reason
  | Mismatch { config; variable; actual; declaration; field; expected } ->
      Printf.sprintf "%s: %s is %s but %s's %s is %s" config variable
        (Option.value actual ~default:"unset") declaration field expected

(* Every variable the config sets, or what /bin/sh said when it could not
   source it. *)
let config_variables path =
  let stdout, stdin, stderr =
    Unix.open_process_args_full "/bin/sh"
      [| "/bin/sh"; "-c"; {|set -a; . "$1"; exec env|}; "sh"; path |]
      [| "PATH=/usr/bin:/bin" |]
  in
  let output = In_channel.input_all stdout in
  let errors = In_channel.input_all stderr in
  match Unix.close_process_full (stdout, stdin, stderr) with
  | Unix.WEXITED 0 ->
      Ok
        (String.split_on_char '\n' output
        |> List.filter_map (fun line ->
               match String.index_opt line '=' with
               | Some i -> Some (String.sub line 0 i, String.sub line (i + 1) (String.length line - i - 1))
               | None -> None))
  | _ -> Error (String.trim errors)

(* The port PORT must carry: the one named http, or for an endpoint
   without one (an s3-only store) its only tailnet port. *)
let primary_port (endpoint : Network_endpoint.t) =
  match
    List.find_opt
      (fun (p : Network_endpoint.named_port) -> String.equal p.port_name "http")
      endpoint.tailnet_ports
  with
  | Some p -> Some p.port
  | None -> ( match endpoint.tailnet_ports with [ p ] -> Some p.port | _ -> None)

let drift ?guest ?release_name ~declaration ~config (endpoint : Network_endpoint.t) =
  match config_variables config with
  | Error reason -> [ Unreadable { config; reason } ]
  | Ok vars ->
      let var name =
        match Option.map String.trim (List.assoc_opt name vars) with Some "" -> None | value -> value
      in
      let expect variable field expected =
        let actual = var variable in
        if Option.equal String.equal actual (Some expected) then []
        else [ Mismatch { config; variable; actual; declaration; field; expected } ]
      in
      let if_set variable field expected =
        match var variable with Some _ -> expect variable field expected | None -> []
      in
      List.concat
        [
          (match var "JAIL_IP" with
          | Some _ -> expect "JAIL_IP" "ip" endpoint.ip
          | None -> expect "GUEST_IP" "ip" endpoint.ip);
          (match primary_port endpoint with
          | Some port -> expect "PORT" "primary tailnet port" (string_of_int port)
          | None -> []);
          List.concat_map
            (fun (p : Network_endpoint.named_port) ->
              if String.equal p.port_name "http" then []
              else
                expect (String.uppercase_ascii p.port_name ^ "_PORT") (p.port_name ^ " port")
                  (string_of_int p.port))
            endpoint.tailnet_ports;
          if_set "PUBLIC_HOST" "hostname" endpoint.hostname;
          if_set "PHX_HOST" "hostname" endpoint.hostname;
          (match release_name with Some name -> if_set "APP" "release_name" name | None -> []);
          (match guest with
          | Some (guest : Guest_config.t) ->
              expect "GUEST_USER" "login_user" guest.login_user
              @ expect "SOURCE_CHECKOUT" "source_checkout" guest.source_checkout
          | None -> []);
        ]

let check (declaration : Declaration.t) =
  let entry dir name file = Filename.concat (Filename.concat dir name) file in
  let apps_dir = Layout.apps_dir declaration.layout in
  let guests_dir = Layout.guests_dir declaration.layout in
  List.concat_map
    (fun (app : App_config.t) ->
      let name = app.endpoint.name in
      let config = entry apps_dir name "config" in
      let release_name =
        match app.strategy with
        | Strategy_config.Freebsd_native_elixir strategy -> Some strategy.release_name
        | _ -> None
      in
      if Sys.file_exists config then
        drift ?release_name ~declaration:(entry apps_dir name "app.sexp") ~config app.endpoint
      else [])
    declaration.apps
  @ List.concat_map
      (fun guest ->
        let name = Guest_config.name guest in
        let config = entry guests_dir name "config" and sexp = entry guests_dir name "guest.sexp" in
        if Sys.file_exists config then
          drift ~guest ~declaration:sexp ~config (Guest_config.endpoint guest)
        else [ Missing { config; declaration = sexp } ])
      declaration.guests
