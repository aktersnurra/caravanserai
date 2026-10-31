(* Pf_rules.render tested against a golden file, matching
   test_headscale_acl.ml's style: no external test framework, just check
   helpers and a shared failure counter. *)
open Serai

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let golden name = read_file (Filename.concat "golden/pf_rules" name)

let board_app : Network_endpoint.t =
  Test_declaration.endpoint ~name:"board" ~ip:"10.40.0.3" ~hostname:"board.example.org"
    ~tailnet_ports:[ { port_name = "http"; port = 4001 } ] ~operator_ports:[]

(* operator_ports is deliberately non-empty here: pf rules must only ever
   come from tailnet_ports, so port 22's absence from expected.conf is what
   proves operator_ports doesn't leak into the generated ruleset. *)
let garage_app : Network_endpoint.t =
  Test_declaration.endpoint ~name:"garage" ~ip:"10.40.0.4" ~hostname:"s3.example.org"
    ~tailnet_ports:[ { port_name = "s3"; port = 3900 }; { port_name = "rpc"; port = 3901 } ]
    ~operator_ports:[ { port_name = "ssh"; port = 22 } ]

let render endpoints = Pf_rules.render (Test_declaration.endpoints endpoints)

let () =
  match render [ board_app; garage_app ] with
  | Error _ -> check "render matches golden output" false
  | Ok generated -> check "render matches golden output" (generated = golden "expected.conf")

let () =
  let no_ports_app = Test_declaration.endpoint ~name:board_app.name ~ip:board_app.ip
      ~hostname:board_app.hostname ~tailnet_ports:[] ~operator_ports:[] in
  match render [ no_ports_app ] with
  | Ok _ -> check "no tailnet_ports declared should be rejected" false
  | Error _ -> check "no tailnet_ports declared should be rejected" true

let () = if !failures > 0 then exit 1
