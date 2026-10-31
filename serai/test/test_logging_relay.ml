open Serai

let failures = ref 0
let check name cond =
  if cond then Printf.printf "ok - %s\n" name
  else (incr failures; Printf.printf "FAIL - %s\n" name)

let contains text needle =
  let n = String.length needle and t = String.length text in
  let rec at i = i + n <= t && (String.sub text i n = needle || at (i + 1)) in
  at 0

let endpoint ?(ports = []) name ip =
  Result.get_ok (Network_endpoint.create ~name ~ip ~hostname:(name ^ ".example.org")
    ~tailnet_ports:(List.map (fun (port_name, port) -> { Network_endpoint.port_name; port }) ports)
    ~operator_ports:[])

let receiver = Result.get_ok (Logging_relay.receiver
  (endpoint "logs" "10.40.0.20" ~ports:[ ("http", 9428); ("syslog", 29514) ]))
let compute = Topology.jail_host (Test_declaration.topology ~jails:[ "logs" ] ~guests:[] ()) "logs"
let relay guests = Result.get_ok (Logging_relay.v ~receiver ~host:compute ~guests)

let () =
  let relay = relay [ endpoint "ledger" "10.40.0.10"; endpoint "journal" "10.40.0.11" ] in
  check "host: the declared guests through the bridge, then host files, to the receiver"
    (Logging_relay.render_host relay = {|@version: 4.12

# Read copies of existing FreeBSD syslogd files; never claim /var/run/log
# or turn off syslogd on the host. Only the guest bridge is a listener, and
# only for the declared guests' addresses.
source s_host_files {
    file("/var/log/messages" flags(no-parse) read-old-records(no));
    file("/var/log/auth.log" flags(no-parse) read-old-records(no));
};
destination d_victoria {
    network("10.40.0.20"
        port(29514)
        transport("tcp")
        flags(syslog-protocol)
        time-reopen(10)
        disk-buffer(reliable(yes) capacity-bytes(134217728)
                    flow-control-window-bytes(1048576)
                    dir("/var/db/central-logging")));
};
log { source(s_host_files); destination(d_victoria); flags(flow-control); };
source s_guest_bridge {
    network(ip("10.40.0.254") port(29514) transport("tcp") flags(syslog-protocol));
};
filter f_guest_peers { "${SOURCEIP}" eq "10.40.0.10" or "${SOURCEIP}" eq "10.40.0.11"; };
log { source(s_guest_bridge); filter(f_guest_peers); destination(d_victoria); flags(flow-control); };
|});
  check "jail: the local socket kept on disk, and the receiver"
    (Logging_relay.render_jail relay = {|@version: 4.12

# Each jail's base script disables syslogd. Own its local socket and retain
# syslog messages on local disk regardless of receiver or queue health.
source s_local_syslog { unix-dgram("/var/run/log"); };
destination d_local_messages { file("/var/log/messages" create-dirs(yes)); };
log { source(s_local_syslog); destination(d_local_messages); };

# This base alone does not forward any source. The installer appends only
# reviewed jail-specific source paths and log statements. The logs receiver
# jail never gets a sender, so it cannot send its own output back to itself.
destination d_victoria {
    network("10.40.0.20"
        port(29514)
        transport("tcp")
        flags(syslog-protocol)
        time-reopen(10)
        disk-buffer(reliable(yes) capacity-bytes(67108864)
                    flow-control-window-bytes(1048576)
                    dir("/var/db/central-logging")));
};
|});
  check "bridge: the host's guest bridge" (Logging_relay.render_bridge relay = "10.40.0.254\n")

let () =
  let relay = relay [] in
  let host = Logging_relay.render_host relay in
  check "host: without guests, no listener at all"
    (not (contains host "s_guest_bridge") && not (contains host "network(ip(")
     && contains host "log { source(s_host_files); destination(d_victoria)");
  check "bridge: empty without guests" (Logging_relay.render_bridge relay = "")

let () =
  let port = Result.get_ok (Logging_relay.receiver (endpoint "logs" "10.40.0.20" ~ports:[ ("syslog", 5514) ])) in
  check "the receiver's own syslog port, wherever it is declared"
    (contains (Logging_relay.render_jail (Result.get_ok (Logging_relay.v ~receiver:port ~host:compute ~guests:[])))
       "port(5514)");
  check "a receiver without a syslog port is refused"
    (match Logging_relay.receiver (endpoint "logs" "10.40.0.20" ~ports:[ ("http", 9428) ]) with
     | Error (No_syslog_port "logs") -> true | _ -> false);
  let bare = Topology.host (Topology.of_sexp (Sexplib.Sexp.of_string
    "((hosts ((compute (os freebsd) (ssh compute-test) (network (subnet 10.0.0.0/24) (gateway 10.0.0.1)))\n\
    \  (edge (os linux) (ssh edge-test)))) (jails ((logs compute))) (guests ()) (edge edge) (proxy ()))")) "compute" in
  check "guests on a host without a guest bridge are refused"
    (match Logging_relay.v ~receiver ~host:bare ~guests:[ endpoint "ledger" "10.0.0.10" ] with
     | Error (No_guest_bridge "compute") -> true | _ -> false);
  check "a host without a guest bridge and no guests renders"
    (Result.is_ok (Logging_relay.v ~receiver ~host:bare ~guests:[]))

(* The edge sender: the repo's template, every placeholder filled. *)
let () =
  let template = In_channel.with_open_bin
    (Layout.edge_sender_template (Repo_root.example ())) In_channel.input_all in
  let rendered = Logging_relay.render_edge_sender receiver ~template in
  let count needle =
    let n = String.length needle in
    let rec go i acc = if i + n > String.length rendered then acc
      else go (i + 1) (if String.sub rendered i n = needle then acc + 1 else acc) in
    go 0 0 in
  check "edge: both destinations reach the receiver"
    (count {|"10.40.0.20"|} = 2 && count "port(29514)" = 2);
  check "edge: no placeholder left" (not (contains rendered "__"));
  check "edge: only the placeholders change"
    (String.length rendered - String.length template
     = 2 * (String.length "10.40.0.20" - String.length "__LOGS_IP__")
       + 2 * (String.length "29514" - String.length "__LOGS_SYSLOG_PORT__"));
  check "edge: the receiver for the installer's checks"
    (Logging_relay.render_receiver receiver = "10.40.0.20 29514\n")

(* What the shell contract used to grep for, as properties of every render. *)
let () =
  let relay = relay [ endpoint "ledger" "10.40.0.10" ] in
  let host = Logging_relay.render_host relay and jail = Logging_relay.render_jail relay in
  List.iter (fun (name, config) ->
    List.iter (fun needle -> check (Printf.sprintf "%s: has %s" name needle) (contains config needle))
      [ "transport(\"tcp\")"; "flags(syslog-protocol)"; "reliable(yes)"; "capacity-bytes("; "time-reopen(" ];
    List.iter (fun needle -> check (Printf.sprintf "%s: no %s" name needle) (not (contains config needle)))
      [ "0.0.0.0"; "ip(\"*\")"; "wildcard-file("; "file(\"/var/log/*" ])
    [ ("host", host); ("jail", jail) ];
  check "host: never competes with host syslogd"
    (not (contains host "system(") && not (contains host "unix-dgram("))

let () = if !failures > 0 then exit 1
