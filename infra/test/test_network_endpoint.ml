(* Network_endpoint parsing and validation, in the style of
   test_app_config.ml: inline sexp, check helpers, shared failure counter. *)
open Infra

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let parse str =
  Network_endpoint.of_fields
    (Sexp_fields.fields_of_sexp ~context:"test" ~known:Network_endpoint.field_names
       (Sexplib.Sexp.List (Sexplib.Sexp.of_string_many str)))

let rejects_with ~needle str =
  match parse str with
  | _ -> false
  | exception Sexplib.Conv.Of_sexp_error (exn, _) ->
      contains ~needle (Printexc.to_string exn)

let drill_fields =
  {|(name drill) (ip 10.40.0.2) (hostname drill.example)
    (tailnet_ports ((http 4000) (video 4002))) (operator_ports ())|}

let () =
  let e = parse drill_fields in
  check "name" (e.name = "drill");
  check "ip" (e.ip = "10.40.0.2");
  check "hostname" (e.hostname = "drill.example");
  check "tailnet_ports are named, in declared order"
    (e.tailnet_ports
    = [ { port_name = "http"; port = 4000 }; { port_name = "video"; port = 4002 } ]);
  check "operator_ports empty" (e.operator_ports = [])

let () =
  check "unknown field rejected, naming it"
    (rejects_with ~needle:"jail_ip" (drill_fields ^ "(jail_ip 10.40.0.2)"));
  check "duplicate field rejected, naming it"
    (rejects_with ~needle:"duplicate field ip" (drill_fields ^ "(ip 10.40.0.9)"));
  check "missing field rejected, naming it"
    (rejects_with ~needle:"missing field hostname"
       {|(name a) (ip 1.2.3.4) (tailnet_ports ()) (operator_ports ())|});
  check "non-integer port rejected"
    (rejects_with ~needle:"expected an integer port"
       {|(name a) (ip 1.2.3.4) (hostname a.example)
         (tailnet_ports ((http 40x0))) (operator_ports ())|});
  check "bare port without a name rejected"
    (rejects_with ~needle:"expected (port_name port)"
       {|(name a) (ip 1.2.3.4) (hostname a.example)
         (tailnet_ports (4000)) (operator_ports ())|})

let endpoint ?(tailnet_ports = [ ("http", 4000) ]) ?(operator_ports = []) ?hostname ~name ~ip () =
  let named = List.map (fun (port_name, port) -> Network_endpoint.{ port_name; port }) in
  Network_endpoint.create ~name ~ip ~hostname:(Option.value hostname ~default:(name ^ ".example"))
    ~tailnet_ports:(named tailnet_ports) ~operator_ports:(named operator_ports)

let validate endpoints =
  let parsed = List.fold_right (fun endpoint result ->
    match endpoint, result with
    | Ok endpoint, Ok rest -> Ok (endpoint :: rest)
    | Error errors, Ok _ | Ok _, Error errors -> Error errors
    | Error left, Error right -> Error (left @ right)) endpoints (Ok []) in
  Result.bind parsed Network_endpoint.validate_all

let rejected ~needle endpoints =
  match validate endpoints with
  | Ok _ -> false
  | Error errors -> contains ~needle (Network_endpoint.errors_message errors)

let () =
  check "valid set accepted, same port on two different ips is fine"
    (Result.is_ok (validate
       [ endpoint ~name:"a" ~ip:"10.0.0.1" (); endpoint ~name:"b" ~ip:"10.0.0.2" () ]));
  check "duplicate name rejected"
    (rejected ~needle:"duplicate name a"
       [ endpoint ~name:"a" ~ip:"10.0.0.1" (); endpoint ~name:"a" ~ip:"10.0.0.2" () ]);
  check "duplicate ip rejected, naming both endpoints"
    (rejected ~needle:"duplicate ip 10.0.0.1: a and b"
       [ endpoint ~name:"a" ~ip:"10.0.0.1" (); endpoint ~name:"b" ~ip:"10.0.0.1" () ]);
  check "repeated port name within tailnet_ports rejected"
    (rejected ~needle:"a: duplicate tailnet port name http"
       [ endpoint ~name:"a" ~ip:"10.0.0.1" ~tailnet_ports:[ ("http", 1); ("http", 2) ] () ]);
  check "repeated port number within tailnet_ports rejected"
    (rejected ~needle:"a: duplicate tailnet port 4000"
       [ endpoint ~name:"a" ~ip:"10.0.0.1" ~tailnet_ports:[ ("http", 4000); ("alt", 4000) ] () ]);
  check "repeated port within operator_ports rejected"
    (rejected ~needle:"a: duplicate operator port name ssh"
       [ endpoint ~name:"a" ~ip:"10.0.0.1" ~operator_ports:[ ("ssh", 22); ("ssh", 2222) ] () ]);
  check "port out of range rejected"
    (rejected ~needle:"a: tailnet port http 70000 out of range"
       [ endpoint ~name:"a" ~ip:"10.0.0.1" ~tailnet_ports:[ ("http", 70000) ] () ]);
  check "port 0 rejected"
    (rejected ~needle:"a: tailnet port http 0 out of range"
       [ endpoint ~name:"a" ~ip:"10.0.0.1" ~tailnet_ports:[ ("http", 0) ] () ]);
  check "name outside [a-z0-9] rejected"
    (rejected ~needle:"name my-app"
       [ endpoint ~name:"my-app" ~ip:"10.0.0.1" () ]);
  check "port name outside [a-z0-9] rejected"
    (rejected ~needle:"port name Http"
       [ endpoint ~name:"a" ~ip:"10.0.0.1" ~tailnet_ports:[ ("Http", 1) ] () ]);
  check "every error reported, not just the first"
    (match
       endpoint ~name:"bad-name" ~ip:"invalid" ~tailnet_ports:[ ("http", 0) ] ()
     with
    | Ok _ -> false
    | Error errors ->
        let msg = Network_endpoint.errors_message errors in
        contains ~needle:"out of range" msg && contains ~needle:"name bad-name" msg
        && contains ~needle:"IPv4" msg)

let () =
  List.iter (fun ip ->
    check ("invalid IPv4 host rejected: " ^ String.escaped ip)
      (rejected ~needle:"IPv4" [ endpoint ~name:"a" ~ip () ]))
    [ "not-an-ip"; "0.0.0.0/0"; "127.1"; "256.1.2.3"; "01.2.3.4";
      "::1"; "1.2.3.4\npass in all"; "1.2.3.4 " ];
  List.iter (fun hostname ->
    check ("invalid hostname rejected: " ^ String.escaped hostname)
      (rejected ~needle:"hostname" [ endpoint ~name:"a" ~ip:"1.2.3.4" ~hostname () ]))
    [ ""; "*.example.org"; "-bad.example"; "bad-.example"; "a..example";
      "example.org {"; "a\nexample.org"; String.make 64 'a' ^ ".example" ]

let () =
  check "port range endpoints accepted"
    (Result.is_ok (endpoint ~name:"a" ~ip:"255.255.255.255"
      ~tailnet_ports:[ "first", 1; "last", 65535 ] ()));
  check "same port may belong to both access classes"
    (Result.is_ok (endpoint ~name:"a" ~ip:"10.0.0.1"
      ~tailnet_ports:[ "http", 4000 ] ~operator_ports:[ "http", 4000 ] ()));
  check "collection reports duplicate names, ips and hostnames together"
    (match validate [ endpoint ~name:"a" ~ip:"10.0.0.1" (); endpoint ~name:"a" ~ip:"10.0.0.1" () ] with
     | Error [ Network_endpoint.Duplicate_name _; Network_endpoint.Duplicate_ip _;
               Network_endpoint.Duplicate_hostname _ ] -> true
     | _ -> false);
  check "two workloads may not share a hostname"
    (match validate [ endpoint ~name:"a" ~ip:"10.0.0.1" ~hostname:"same.example" ();
                      endpoint ~name:"b" ~ip:"10.0.0.2" ~hostname:"same.example" () ] with
     | Error [ Network_endpoint.Duplicate_hostname ("same.example", "a", "b") ] -> true
     | _ -> false);
  let declaration = parse drill_fields in
  check "validated collection preserves declaration order"
    (match Network_endpoint.validate_all [ declaration ] with
     | Ok endpoints -> List.map (fun (endpoint : Network_endpoint.t) -> endpoint.name)
         (Network_endpoint.to_list endpoints) = [ "drill" ]
     | Error _ -> false)

let () = if !failures > 0 then exit 1
