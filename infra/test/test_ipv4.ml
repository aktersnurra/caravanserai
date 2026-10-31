open Infra

let failures = ref 0
let check name cond =
  if cond then Printf.printf "ok - %s\n" name
  else (incr failures; Printf.printf "FAIL - %s\n" name)

let address s = Option.get (Ipv4.address s)
let subnet s = Result.get_ok (Ipv4.subnet s)

let () =
  check "address: canonical dotted decimal round-trips"
    (Ipv4.to_string (address "10.40.0.20") = "10.40.0.20");
  List.iter (fun s -> check ("address: refused " ^ s) (Ipv4.address s = None))
    [ ""; "10.40.0"; "10.40.0.256"; "10.40.0.020"; "10.40.0.-1"; "10.40.0.1.2"; "a.b.c.d"; "10.40.0. 1" ];
  let net = subnet "10.40.0.0/24" in
  check "subnet: round-trips" (Ipv4.subnet_to_string net = "10.40.0.0/24");
  check "subnet: a host address is in it" (Ipv4.is_host net (address "10.40.0.10"));
  check "subnet: the network and broadcast are not hosts"
    (not (Ipv4.is_host net (address "10.40.0.0")) && not (Ipv4.is_host net (address "10.40.0.255")));
  check "subnet: an address outside is not a host" (not (Ipv4.is_host net (address "10.40.1.10")));
  check "subnet: hosts run from .1 to .254"
    (let hosts = List.of_seq (Ipv4.hosts net) in
     List.length hosts = 254
     && Ipv4.to_string (List.hd hosts) = "10.40.0.1"
     && Ipv4.to_string (List.nth hosts 253) = "10.40.0.254");
  check "subnet: a wider prefix spans octets"
    (let wide = subnet "10.8.0.0/16" in
     Ipv4.is_host wide (address "10.8.3.4") && not (Ipv4.is_host wide (address "10.9.0.1")));
  List.iter (fun s -> check ("subnet: refused " ^ s) (Result.is_error (Ipv4.subnet s)))
    [ "10.40.0.0"; "10.40.0.1/24"; "10.40.0.0/31"; "10.0.0.0/7"; "10.40.0.0/"; "10.40.0.0/024x"; "/24" ];
  if !failures <> 0 then exit 1
