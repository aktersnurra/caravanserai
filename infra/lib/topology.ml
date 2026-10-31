type os = Freebsd | Linux
type build = { ip : string; base_url : string; base_sha256 : string }
type network = { subnet : Ipv4.subnet; gateway : string; guest_bridge : string option }
type host = { id : string; os : os; ssh : string; via : string option; build : build option;
              network : network option }
type guest = { name : string; host : string; via : string option }
type t = { hosts : host list; jails : (string * string) list; guests : guest list;
           edge_id : string; proxy : string list }

let fail message = failwith ("topology: " ^ message)
let safe_id s = s <> "" && String.for_all (function 'a'..'z' | '0'..'9' | '-' | '_' -> true | _ -> false) s
let safe_ssh s = s <> "" && s.[0] <> '-' && String.for_all
  (function 'a'..'z' | 'A'..'Z' | '0'..'9' | '.' | '-' | '_' | '@' -> true | _ -> false) s
let atom = function Sexplib.Sexp.Atom s -> s | _ -> fail "expected atom"
let list = function Sexplib.Sexp.List xs -> xs | _ -> fail "expected list"
let unique label xs =
  let rec loop seen = function
    | [] -> ()
    | x :: rest -> if List.mem x seen then fail ("duplicate " ^ label ^ " " ^ x) else loop (x :: seen) rest
  in loop [] xs
let fields allowed sexp =
  let rows = list sexp |> List.map (function
    | Sexplib.Sexp.List [Atom key; value] when List.mem key allowed -> key, value
    (* A record-valued field: (build (ip ...) (base ...)). *)
    | Sexplib.Sexp.List (Atom key :: (_ :: _ :: _ as rest)) when List.mem key allowed ->
        key, Sexplib.Sexp.List rest
    | Sexplib.Sexp.List (Atom key :: _) -> fail ("unknown or malformed field " ^ key)
    | _ -> fail "malformed field") in
  unique "field" (List.map fst rows); rows
let required rows key = match List.assoc_opt key rows with
  | Some value -> value | None -> fail ("missing field " ^ key)
let id value = let s = atom value in if not (safe_id s) || s = "direct" then fail ("invalid identifier " ^ s); s
let route value = match atom value with "direct" -> None | _ -> Some (id value)
let host t name = match List.find_opt (fun (h : host) -> h.id = name) t.hosts with
  | Some h -> h | None -> fail ("unknown host " ^ name)
let edge t = host t t.edge_id
let jail_host t name = match List.assoc_opt name t.jails with
  | Some target -> host t target | None -> fail ("missing jail placement " ^ name)
let guest t name = match List.find_opt (fun (g : guest) -> g.name = name) t.guests with
  | Some g -> g | None -> fail ("missing guest placement " ^ name)
let guest_host t name = host t (guest t name).host
let hosts t = t.hosts
let proxy_workloads t = t.proxy
let workloads_on t target = List.filter_map (fun (name, h) -> if h = target then Some name else None) t.jails
  @ List.filter_map (fun (g : guest) -> if g.host = target then Some g.name else None) t.guests
let compute_hosts t = List.filter (fun (h : host) -> workloads_on t h.id <> []) t.hosts
let host_jumps t (h : host) =
  let rec resolve seen (h : host) =
    if List.mem h.id seen then fail ("SSH route cycle at " ^ h.id);
    match h.via with
    | None -> []
    | Some name -> let parent = host t name in resolve (h.id :: seen) parent @ [parent.ssh]
  in resolve [] h
let guest_jumps t name = match (guest t name).via with
  | None -> []
  | Some name -> let jump = host t name in host_jumps t jump @ [jump.ssh]

let check_workload_ip (h : host) ip =
  match h.network, Ipv4.address ip with
  | None, _ -> Error (Printf.sprintf "host %s has no workload network for %s" h.id ip)
  | Some _, None -> Error ("not a canonical IPv4 address: " ^ ip)
  | Some n, Some address ->
      if not (Ipv4.is_host n.subnet address) then
        Error (Printf.sprintf "%s is not a host address in %s's %s" ip h.id (Ipv4.subnet_to_string n.subnet))
      else if ip = n.gateway || Some ip = n.guest_bridge then
        Error (Printf.sprintf "%s is %s's own address on its network" ip h.id)
      else Ok ()

(* The host's lo1 subnet, the address it takes on it, and the bhyve bridge's. *)
let network_of_sexp sexp =
  let rows = fields ["subnet"; "gateway"; "guest_bridge"] sexp in
  let subnet = match Ipv4.subnet (required rows "subnet" |> atom) with
    | Ok subnet -> subnet | Error message -> fail message in
  let on_subnet label value =
    match Ipv4.address value with
    | Some address when Ipv4.is_host subnet address -> value
    | _ -> fail (Printf.sprintf "%s %s is not a host address in %s" label value (Ipv4.subnet_to_string subnet)) in
  let gateway = on_subnet "gateway" (required rows "gateway" |> atom) in
  let guest_bridge = Option.map (fun value -> on_subnet "guest_bridge" (atom value))
      (List.assoc_opt "guest_bridge" rows) in
  if guest_bridge = Some gateway then fail "guest_bridge must differ from gateway";
  { subnet; gateway; guest_bridge }

(* The builder jail joins the host's jail network; its address is checked
   against declared workloads when a build runs. *)
let build_of_sexp sexp =
  let rows = fields ["ip"; "base"] sexp in
  let ip = required rows "ip" |> atom in
  let base = fields ["url"; "sha256"] (required rows "base") in
  let base_url = required base "url" |> atom and base_sha256 = required base "sha256" |> atom in
  if not (String.starts_with ~prefix:"https://" base_url)
     || not (String.for_all (function
          | 'a'..'z' | 'A'..'Z' | '0'..'9' | ':' | '/' | '.' | '_' | '-' -> true | _ -> false) base_url)
  then fail ("base url must be a plain https URL: " ^ base_url);
  if String.length base_sha256 <> 64
     || not (String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) base_sha256)
  then fail "base sha256 must be 64 lowercase hex digits";
  { ip; base_url; base_sha256 }

let of_sexp sexp =
  let rows = fields ["hosts"; "jails"; "guests"; "edge"; "proxy"] sexp in
  let hosts = required rows "hosts" |> list |> List.map (function
    | Sexplib.Sexp.List (name :: entries) ->
        let rows = fields ["os"; "ssh"; "via"; "build"; "network"] (Sexplib.Sexp.List entries) in
        let os = match required rows "os" |> atom with
          | "freebsd" -> Freebsd | "linux" -> Linux | value -> fail ("unsupported OS " ^ value) in
        let ssh = required rows "ssh" |> atom in
        if not (safe_ssh ssh) then fail "unsafe SSH target";
        let build = Option.map build_of_sexp (List.assoc_opt "build" rows) in
        if os <> Freebsd && build <> None then fail "build settings require a FreeBSD host";
        let network = Option.map network_of_sexp (List.assoc_opt "network" rows) in
        (match os, network with
         | Freebsd, None -> fail ("FreeBSD host needs a network: " ^ atom name)
         | Linux, Some _ -> fail ("a network requires a FreeBSD host: " ^ atom name)
         | _ -> ());
        let host = { id = id name; os; ssh; via = Option.bind (List.assoc_opt "via" rows) route; build; network } in
        Option.iter (fun (b : build) -> match check_workload_ip host b.ip with
          | Ok () -> () | Error message -> fail ("builder ip: " ^ message)) build;
        host
    | _ -> fail "malformed host") in
  let jails = required rows "jails" |> list |> List.map (function
    | Sexplib.Sexp.List [name; target] -> id name, id target
    | _ -> fail "malformed jail placement") in
  let guests = required rows "guests" |> list |> List.map (function
    | Sexplib.Sexp.List (name :: entries) ->
        let rows = fields ["host"; "via"] (Sexplib.Sexp.List entries) in
        { name = id name; host = id (required rows "host"); via = route (required rows "via") }
    | _ -> fail "malformed guest placement") in
  let edge_id = id (required rows "edge") in
  let proxy = required rows "proxy" |> list |> List.map id in
  let t = { hosts; jails; guests; edge_id; proxy } in
  unique "host" (List.map (fun (h : host) -> h.id) hosts);
  unique "SSH destination" (List.map (fun (h : host) -> h.ssh) hosts);
  unique "workload placement" (List.map fst jails @ List.map (fun (g : guest) -> g.name) guests);
  unique "proxy workload" proxy;
  List.iter (fun (h : host) -> ignore (host_jumps t h)) hosts;
  if (edge t).os <> Linux then fail "edge requires a Linux host";
  List.iter (fun (name, _) -> if (jail_host t name).os <> Freebsd then fail ("jail requires FreeBSD host: " ^ name)) jails;
  List.iter (fun (g : guest) ->
    if (guest_host t g.name).os <> Freebsd then fail ("bhyve guest requires FreeBSD host: " ^ g.name);
    (match (guest_host t g.name).network with
     | Some { guest_bridge = Some _; _ } -> ()
     | _ -> fail ("bhyve guest's host needs a guest_bridge: " ^ g.name));
    ignore (guest_jumps t g.name)) guests;
  List.iter (fun name ->
    if not (List.mem_assoc name jails || List.exists (fun (g : guest) -> g.name = name) guests)
    then fail ("unknown proxy workload " ^ name)) proxy;
  t

let validate_workloads t ~apps ~guests =
  let placed_apps = List.map fst t.jails and placed_guests = List.map (fun (g : guest) -> g.name) t.guests in
  let compare label expected actual =
    List.iter (fun name -> if not (List.mem name actual) then fail ("missing " ^ label ^ " placement " ^ name)) expected;
    List.iter (fun name -> if not (List.mem name expected) then fail ("unknown " ^ label ^ " " ^ name)) actual in
  try
    compare "jail" apps placed_apps; compare "guest" guests placed_guests;
    List.iter (fun (h : host) -> if List.mem h.id (apps @ guests) then fail ("host/workload identifier collision " ^ h.id)) t.hosts;
    Ok ()
  with Failure message -> Error message
let validate_addresses t ~ips =
  try
    List.iter (fun (name, ip) ->
      let h = if List.mem_assoc name t.jails then jail_host t name else guest_host t name in
      (match check_workload_ip h ip with Ok () -> () | Error message -> fail (name ^ ": " ^ message));
      match h.build with
      | Some b when b.ip = ip -> fail (Printf.sprintf "%s: %s is %s's build address" name ip h.id)
      | _ -> ()) ips;
    Ok ()
  with Failure message -> Error message

(* The edge routes exactly the workloads that expose tailnet ports; listing one
   without the other would silently drop or invent routing. *)
let validate_proxy t ~exposed =
  let unproxied = List.filter (fun name -> not (List.mem name t.proxy)) exposed
  and unexposed = List.filter (fun name -> not (List.mem name exposed)) t.proxy in
  match unproxied, unexposed with
  | [], [] -> Ok ()
  | name :: _, _ -> Error ("workload " ^ name ^ " declares tailnet_ports but is not in proxy")
  | [], name :: _ -> Error ("proxied workload " ^ name ^ " declares no tailnet_ports")
let load path = Sexplib.Sexp.load_sexp path |> of_sexp
