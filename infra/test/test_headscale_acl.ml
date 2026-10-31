(* Headscale_acl.render tested against a golden file, matching
   test_dispatcher.ml's style: no external test framework, just check
   helpers and a shared failure counter. *)
open Infra

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

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let golden name = read_file (Filename.concat "golden/headscale_acl" name)

let board_app : Network_endpoint.t =
  Test_declaration.endpoint ~name:"board" ~ip:"10.40.0.3" ~hostname:"board.example.org"
    ~tailnet_ports:[ { port_name = "http"; port = 4001 } ] ~operator_ports:[]

let garage_app : Network_endpoint.t =
  Test_declaration.endpoint ~name:"garage" ~ip:"10.40.0.4" ~hostname:"s3.example.org"
    ~tailnet_ports:[ { port_name = "s3"; port = 3900 } ] ~operator_ports:[ { port_name = "ssh"; port = 22 } ]

let render ?operator endpoints =
  Headscale_acl.render ~edge:(Test_declaration.edge ?operator "example.org") (Test_declaration.endpoints endpoints)

let () =
  match render [ board_app; garage_app ] with
  | Error _ -> check "render matches golden output" false
  | Ok generated ->
      check "render matches golden output" (generated = golden "expected.yaml")

let () =
  let no_ports_app : Network_endpoint.t =
    Test_declaration.endpoint ~name:board_app.name ~ip:board_app.ip ~hostname:board_app.hostname
      ~tailnet_ports:[] ~operator_ports:[]
  in
  match render [ no_ports_app ] with
  | Ok _ -> check "no tailnet_ports declared should be rejected" false
  | Error _ -> check "no tailnet_ports declared should be rejected" true

let () =
  let no_operator_app = board_app in
  match render [ no_operator_app ] with
  | Error _ -> check "operator rule omission should still render" false
  | Ok generated ->
      let contains ~needle haystack =
        let nl = String.length needle and hl = String.length haystack in
        let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
        nl = 0 || go 0
      in
      check "operator rule is omitted, not an empty array, when no app has operator_ports"
        (not (contains ~needle:{|"dst":    []|} generated))

(* The operator is the edge's, in every rule that names one. *)
let () =
  match render ~operator:"someone" [ board_app; garage_app ] with
  | Error _ -> check "operator: rendered from the edge" false
  | Ok generated ->
      check "operator: rendered from the edge"
        (contains ~needle:{|"src":    ["someone@"]|} generated
        && contains ~needle:{|"tag:vps":   ["someone@"]|} generated
        && not (contains ~needle:"ops@" generated))

let () =
  if !failures > 0 then exit 1
