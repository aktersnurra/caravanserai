type receiver = { receiver_ip : string; port : int }
type t = { receiver : receiver; guests : (string * string list) option }

type error = No_syslog_port of string | No_guest_bridge of string

let receiver (endpoint : Network_endpoint.t) =
  match List.find_opt (fun (p : Network_endpoint.named_port) -> p.port_name = "syslog") endpoint.tailnet_ports with
  | None -> Error (No_syslog_port endpoint.name)
  | Some { port; _ } -> Ok { receiver_ip = endpoint.ip; port }

let v ~receiver ~(host : Topology.host) ~(guests : Network_endpoint.t list) =
  let ips = List.map (fun (g : Network_endpoint.t) -> g.ip) guests in
  match ips, Option.bind host.network (fun (n : Topology.network) -> n.guest_bridge) with
  | [], _ -> Ok { receiver; guests = None }
  | _, Some bridge -> Ok { receiver; guests = Some (bridge, ips) }
  | _, None -> Error (No_guest_bridge host.id)

let error_message = function
  | No_syslog_port name -> Printf.sprintf "logging receiver %s declares no syslog tailnet port" name
  | No_guest_bridge host -> Printf.sprintf "host %s runs guests but declares no guest_bridge" host

(* The package's own config version, so syslog-ng runs without
   compatibility mode. *)
let version = "@version: 4.12\n"

let destination t ~capacity = Printf.sprintf {|destination d_victoria {
    network("%s"
        port(%d)
        transport("tcp")
        flags(syslog-protocol)
        time-reopen(10)
        disk-buffer(reliable(yes) capacity-bytes(%d)
                    flow-control-window-bytes(1048576)
                    dir("/var/db/central-logging")));
};
|} t.receiver.receiver_ip t.receiver.port capacity

let render_host t =
  let guests = match t.guests with
    | None -> ""
    | Some (bridge, ips) ->
        let peers = List.map (Printf.sprintf {|"${SOURCEIP}" eq "%s"|}) ips |> String.concat " or " in
        Printf.sprintf {|source s_guest_bridge {
    network(ip("%s") port(%d) transport("tcp") flags(syslog-protocol));
};
filter f_guest_peers { %s; };
log { source(s_guest_bridge); filter(f_guest_peers); destination(d_victoria); flags(flow-control); };
|} bridge t.receiver.port peers in
  version ^ {|
# Read copies of existing FreeBSD syslogd files; never claim /var/run/log
# or turn off syslogd on the host. Only the guest bridge is a listener, and
# only for the declared guests' addresses.
source s_host_files {
    file("/var/log/messages" flags(no-parse) read-old-records(no));
    file("/var/log/auth.log" flags(no-parse) read-old-records(no));
};
|} ^ destination t ~capacity:134217728
  ^ "log { source(s_host_files); destination(d_victoria); flags(flow-control); };\n" ^ guests

let render_jail t =
  version ^ {|
# Each jail's base script disables syslogd. Own its local socket and retain
# syslog messages on local disk regardless of receiver or queue health.
source s_local_syslog { unix-dgram("/var/run/log"); };
destination d_local_messages { file("/var/log/messages" create-dirs(yes)); };
log { source(s_local_syslog); destination(d_local_messages); };

# This base alone does not forward any source. The installer appends only
# reviewed jail-specific source paths and log statements. The logs receiver
# jail never gets a sender, so it cannot send its own output back to itself.
|} ^ destination t ~capacity:67108864

let render_bridge t = match t.guests with None -> "" | Some (bridge, _) -> bridge ^ "\n"

let render_edge_sender r ~template =
  Caddy_render.substitute
    ~placeholders:[ ("__LOGS_IP__", r.receiver_ip); ("__LOGS_SYSLOG_PORT__", string_of_int r.port) ] template

let render_receiver r = Printf.sprintf "%s %d\n" r.receiver_ip r.port
