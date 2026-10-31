open Serai
let parse text = Topology.of_sexp (Sexplib.Sexp.of_string text)
let check name value = if value then Printf.printf "ok - %s\n%!" name else failwith name
let config = {|((hosts ((entry (os linux) (ssh gateway))
 (west (os freebsd) (ssh west-box) (via entry)
  (network (subnet 10.40.0.0/24) (gateway 10.40.0.1) (guest_bridge 10.40.0.254)))
 (east (os freebsd) (ssh east-box) (network (subnet 10.8.0.0/16) (gateway 10.8.0.1)))))
 (jails ((hello east) (counter west)))
 (guests ((ledger (host west) (via west))))
 (edge entry) (proxy (hello ledger)))|}
let replace a b s = Caddy_render.substitute ~placeholders:[a,b] s
let () =
 let t = parse config in
 check "jail placement selects configured second host" ((Topology.jail_host t "hello").ssh = "east-box");
 check "edge identity is configured" ((Topology.edge t).id = "entry");
 check "guest route follows explicit transport rather than exposure"
   (Topology.guest_jumps t "ledger" = ["gateway"; "west-box"]);
 check "host membership scopes host-side rules" (Topology.workloads_on t "east" = ["hello"]);
 check "proxy relationship does not add a host route" (Topology.host_jumps t (Topology.jail_host t "hello") = []);
 let direct = parse (replace "(host west) (via west)" "(host west) (via direct)" config) in
 check "guest direct connection is independent of containment" (Topology.guest_jumps direct "ledger" = []);
 check "exact workload declarations validate"
   (Topology.validate_workloads t ~apps:["hello";"counter"] ~guests:["ledger"] = Ok ());
 check "missing declared workload rejected"
   (Result.is_error (Topology.validate_workloads t ~apps:["hello";"counter";"plain"] ~guests:["ledger"]));
 check "unknown workload placement rejected"
   (Result.is_error (Topology.validate_workloads t ~apps:["hello"] ~guests:["ledger"]));
 check "proxy matches the workloads with tailnet ports"
   (Topology.validate_proxy t ~exposed:["hello"; "ledger"] = Ok ());
 check "workload with tailnet ports missing from proxy rejected"
   (Result.is_error (Topology.validate_proxy t ~exposed:["hello"; "ledger"; "counter"]));
 check "proxied workload without tailnet ports rejected"
   (Result.is_error (Topology.validate_proxy t ~exposed:["hello"]));
 check "build settings are optional" ((Topology.host t "east").build = None);
 let base = "(build (ip 10.8.0.11) (base (url https://download.freebsd.org/base.txz) (sha256 " ^ String.make 64 'a' ^ ")))" in
 let built = parse (replace "(ssh east-box)" ("(ssh east-box) " ^ base) config) in
 check "compute host declares builder IP and base archive"
   (match (Topology.host built "east").build with
    | Some { ip; base_url; base_sha256 } ->
        ip = "10.8.0.11" && base_url = "https://download.freebsd.org/base.txz"
        && base_sha256 = String.make 64 'a'
    | None -> false);
 let refuses name text = check name (try ignore (parse text); false with Failure _ -> true) in
 List.iter (fun (name,a,b) -> refuses name (replace a b config)) [
  "unknown host", "(hello east)", "(hello missing)";
  "jail on Linux", "(hello east)", "(hello entry)";
  "guest on Linux", "(host west)", "(host entry)";
  "non Linux edge", "(edge entry)", "(edge west)";
  "unknown proxy workload", "(proxy (hello ledger))", "(proxy (missing))";
  "duplicate placement", "(counter west)", "(hello west)";
  "duplicate host", "(east (os", "(west (os";
  "duplicate SSH destination", "(ssh east-box)", "(ssh west-box)";
  "unsafe SSH options", "(ssh gateway)", "(ssh -oProxyCommand=x)";
  "unknown guest route", "(host west) (via west)", "(host west) (via absent)";
  "self cycle", "(ssh gateway)", "(ssh gateway) (via entry)";
  "multi host cycle", "(ssh gateway)", "(ssh gateway) (via west)";
  "duplicate field", "(edge entry)", "(edge entry) (edge entry)";
  "unknown field", "(edge entry)", "(edeg entry)";
  "build on Linux", "(ssh gateway)", "(ssh gateway) (build (ip 10.40.0.11) (base (url https://x/base.txz) (sha256 " ^ String.make 64 'a' ^ ")))";
  "builder IP outside the jail network", "(ssh east-box)", "(ssh east-box) (build (ip 10.40.0.11) (base (url https://x/base.txz) (sha256 " ^ String.make 64 'a' ^ ")))";
  "builder IP at the gateway", "(ssh east-box)", "(ssh east-box) (build (ip 10.8.0.1) (base (url https://x/base.txz) (sha256 " ^ String.make 64 'a' ^ ")))";
  "a FreeBSD host without a network", " (network (subnet 10.8.0.0/16) (gateway 10.8.0.1))", "";
  "a network on a Linux host", "(ssh gateway)", "(ssh gateway) (network (subnet 10.9.0.0/16) (gateway 10.9.0.1))";
  "a guest host without a guest bridge", " (guest_bridge 10.40.0.254)", "";
  "a gateway outside the subnet", "(gateway 10.8.0.1)", "(gateway 10.9.0.1)";
  "the network address as gateway", "(gateway 10.8.0.1)", "(gateway 10.8.0.0)";
  "a guest bridge at the gateway", "(guest_bridge 10.40.0.254)", "(guest_bridge 10.40.0.1)";
  "a subnet with host bits", "(subnet 10.8.0.0/16)", "(subnet 10.8.0.1/16)";
  "an unknown network field", "(gateway 10.8.0.1)", "(gateway 10.8.0.1) (bridge 10.8.0.2)";
  "plain http base", "(ssh east-box)", "(ssh east-box) (build (ip 10.8.0.11) (base (url http://x/base.txz) (sha256 " ^ String.make 64 'a' ^ ")))";
  "short base digest", "(ssh east-box)", "(ssh east-box) (build (ip 10.8.0.11) (base (url https://x/base.txz) (sha256 abc)))";
 ];
 check "a host declares its network"
   (match (Topology.host t "west").network with
    | Some n -> Ipv4.subnet_to_string n.subnet = "10.40.0.0/24" && n.gateway = "10.40.0.1"
                && n.guest_bridge = Some "10.40.0.254"
    | None -> false);
 check "a Linux host has no network" ((Topology.host t "entry").network = None);
 let west = Topology.host t "west" in
 check "a workload may take a host address on its host's network"
   (Topology.check_workload_ip west "10.40.0.5" = Ok ());
 List.iter (fun ip -> check ("a workload may not take " ^ ip)
   (Result.is_error (Topology.check_workload_ip west ip)))
   [ "10.40.0.1"; "10.40.0.254"; "10.40.0.0"; "10.40.0.255"; "10.8.0.5"; "10.40.0.05" ];
 let built = parse (replace "(ssh east-box)" ("(ssh east-box) " ^ base) config) in
 check "declared addresses on their hosts' networks validate"
   (Topology.validate_addresses built ~ips:[ "hello", "10.8.0.2"; "counter", "10.40.0.6"; "ledger", "10.40.0.10" ] = Ok ());
 List.iter (fun (label, ips) -> check ("declared addresses refused: " ^ label)
   (Result.is_error (Topology.validate_addresses built ~ips)))
   [ "a jail on another host's network", [ "hello", "10.40.0.2" ];
     "a jail at its host's gateway", [ "hello", "10.8.0.1" ];
     "a jail at its host's build address", [ "hello", "10.8.0.11" ];
     "a guest at its host's bridge", [ "ledger", "10.40.0.254" ];
     "an unplaced workload", [ "plain", "10.40.0.9" ] ];
 let loaded = Declaration.load ~layout:(Repo_root.example ()) in
 check "example declarations load required topology" (match loaded with Ok d -> Option.is_some d.topology | Error _ -> false);
 let d = Result.get_ok loaded in
 let env : Dispatcher.env = {
   layout=d.layout; topology=Some t;
   compute_target="wrong-host"; edge_target="gateway"; remote_stage="/tmp/serai-topology-test";
   ssh_bin="ssh"; rsync_bin="rsync"; curl_bin="curl"; config=d.apps;
   endpoints=d.endpoints; edge=d.edge; edge_ts_ip=None; edge_peer_match=None;
   caddy_force_build=false; confirm=(fun _ -> true); operator="test"; lock_token="topology-test";
   jj_bin="jj"; now_utc=(fun () -> "2026-10-18T00:00:00Z"); guests=d.guests;
   ops_control_path="/tmp/test-%C"; ssh_multiplex=false; source_checkout_override=None;
 } in
 let mock = Proc.Mock.create () in
 Proc.Mock.run mock (fun () -> Dispatcher.bootstrap env "hello");
 let calls = Proc.Mock.calls mock in
 check "bootstrap SSH including lock uses placement, not global compute host"
   (List.for_all (fun (r : Proc.request) -> r.prog <> "ssh" || List.mem "east-box" r.args) calls);
 let via = {env with topology=Some (parse (replace "(hello east)" "(hello west)" config))} in
 let mock = Proc.Mock.create () in
 Proc.Mock.run mock (fun () -> Dispatcher.bootstrap via "hello");
 let calls = Proc.Mock.calls mock in
 check "host SSH route is used for execution and locking"
   (List.for_all (fun (r : Proc.request) -> r.prog <> "ssh" ||
     (List.mem "-J" r.args && List.mem "gateway" r.args && List.mem "west-box" r.args)) calls);
 check "host transfer follows the same jump route"
   (List.for_all (fun (r : Proc.request) -> r.prog <> "rsync" || List.mem "ssh -J gateway" r.args) calls);
 let mock = Proc.Mock.create () in
 Proc.Mock.run mock (fun () -> Dispatcher.provision_guest env "ledger");
 let autostart = ["-J"; "gateway"; "west-box"; "doas sysrc vm_list+='ledger'"] in
 check "guest execution follows its explicit multihop route"
   (List.for_all (fun (r : Proc.request) -> r.prog <> "ssh" || r.args = autostart
     || List.mem "gateway,west-box" r.args) (Proc.Mock.calls mock));
 check "guest autostart runs on the guest's host, over that host's route"
   (List.exists (fun (r : Proc.request) -> r.prog = "ssh" && r.args = autostart) (Proc.Mock.calls mock));
 let mock = Proc.Mock.create () in
 Proc.Mock.run mock (fun () -> Dispatcher.unlock env "east");
 check "unlock resolves configured host ID" (List.for_all (fun (r : Proc.request) -> List.mem "east-box" r.args) (Proc.Mock.calls mock));
 let registry = Pipeline.{default=["route", Script ("seed-videos", [Compute_target; Edge_target])]; apps=[]} in
 let mock = Proc.Mock.create () in
 Proc.Mock.run mock (fun () -> Pipeline.run env registry "hello" "route");
 check "pipeline compatibility variables use app placement and edge"
   (List.exists (fun (r : Proc.request) -> r.args = ["east-box"; "gateway"]) (Proc.Mock.calls mock));
 let mock = Proc.Mock.create () in
 let refused = try Proc.Mock.run mock (fun () -> Dispatcher.deploy via "hello"); false with Failure _ -> true in
 check "legacy hook refuses an unrepresentable route before effects" (refused && Proc.Mock.calls mock = []);
 let real = In_channel.with_open_bin (Layout.topology d.layout) In_channel.input_all in
 let multi = real |> replace "(edge (os linux)" "(secondary (os freebsd) (ssh second-box) (network (subnet 10.20.0.0/24) (gateway 10.20.0.1)))\n   (edge (os linux)"
   |> replace "(hello worker)" "(hello secondary)" |> parse in
 let multi_env = {env with topology=Some multi} in
 let files = Result.get_ok (Dispatcher.render_edge multi_env) in
 let contains needle text = replace needle "" text <> text in
 check "host firewall render contains only hosted workloads"
   (contains "10.20.0.2 port" (List.assoc "hosts/secondary/service-rules.conf" files)
    && not (contains "10.20.0.3 port" (List.assoc "hosts/secondary/service-rules.conf" files))
    && not (contains "10.20.0.2 port" (List.assoc "hosts/worker/service-rules.conf" files)));
 let mock = Proc.Mock.create ~outputs:(fun (r : Proc.request) ->
   if r.prog = "jj" then "c0ffee00c0ffee00 changeid1 published\n" else "") () in
 Proc.Mock.run mock (fun () -> ignore (Dispatcher.plan_edge multi_env));
 let locks = Proc.Mock.calls mock |> List.filter (fun (r : Proc.request) ->
   r.prog = "ssh" && List.exists (contains "mkdir \"$lock\"") r.args) in
 check "edge locks every participating physical host once in stable order"
   (List.map (fun (r : Proc.request) -> List.hd r.args) locks = ["edge"; "second-box"; "worker"]);
 let private_env = {env with topology=Some (parse (replace "(proxy (hello " "(proxy (" real))} in
 let files = Result.get_ok (Dispatcher.render_edge private_env) in
 check "proxy selection omits private workload Caddy configuration"
   (not (List.mem_assoc "edge/caddy/conf.d/40-hello.caddy" files));
 check "proxy selection omits private workload edge grants and firewall rules"
   (not (contains "10.20.0.2:" (List.assoc "edge/acls.hujson" files))
    && not (contains "10.20.0.2 port" (List.assoc "compute/service-rules.conf" files)))
