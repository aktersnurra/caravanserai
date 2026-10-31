(* Pure function from every endpoint (apps and guests) to the Headscale ACL
   policy (HuJSON: JSON with comments) -- no Proc effect, no side effects,
   directly unit-testable. Ported from the shell renderer that
   edge/01-headscale-policy used to carry, and was byte-identical to it
   before it was deleted; that script's validate_and_install (headscale
   policy check, backup-before-install, systemctl reload) stays as shell,
   since it's remote/deploy-time behavior this project keeps out of OCaml by
   design.

   Installed by Dispatcher.edge through edge/01-headscale-policy's
   POLICY_SOURCE mode, which keeps validation, backup and reload in the
   shell script.

   Each endpoint declares two port sets, deliberately kept separate:

     tailnet_ports   what the edge host may reach, i.e. what Caddy proxies to
     operator_ports  what the operator may reach directly, e.g. a guest's sshd

   An app's strategy_config names every port it listens on, but the ACL
   must name only those that should be reachable -- deriving the policy from
   all listeners would silently widen it. *)

(* Rendered destinations as a comma-newline-joined list of quoted strings,
   the layout the former shell renderer produced, byte for byte. *)
let render_destinations rules =
  rules |> List.map (Printf.sprintf {|"%s"|}) |> String.concat ",\n                 "

let destinations_for endpoints ports_of =
  endpoints
  |> List.concat_map (fun (endpoint : Network_endpoint.t) ->
         ports_of endpoint
         |> List.map (fun (named : Network_endpoint.named_port) ->
                Printf.sprintf "%s:%d" endpoint.ip named.port))

(* A policy with no operator access is valid: an empty array would be too,
   but writing the rule out with nothing in it invites someone to "fix" it
   by widening the destination -- so the rule is omitted entirely rather
   than rendered empty. Returned without leading or trailing newline: the
   template splices it exactly as edge/01-headscale-policy splices
   ${operator_block}, which leaves one blank line when it is empty. *)
let operator_access_section ~operator operator_rules =
  match operator_rules with
  | [] -> ""
  | rules ->
      Printf.sprintf
        {|    // Operator -> the ports services declared for operator access, which in
    // practice means sshd on a bhyve guest: a jail is administered from the
    // compute host, but a guest runs its own kernel.
    {
      "action": "accept",
      "src":    ["%s"],
      "dst":    [%s]
    },|}
        operator (render_destinations rules)

let render ?proxy ~(edge : Edge_config.t) endpoints : (string, string) result =
  let operator = edge.operator ^ "@" in
  let endpoints = Network_endpoint.to_list endpoints in
  let exposed = match proxy with None -> endpoints | Some names ->
    List.filter (fun (e : Network_endpoint.t) -> List.mem e.name names) endpoints in
  match destinations_for exposed (fun e -> e.tailnet_ports) with
  | [] ->
      Error "no endpoint declared any tailnet_ports -- refusing to render an empty policy"
  | service_rules ->
      let operator_rules = destinations_for endpoints (fun e -> e.operator_ports) in
      let operator_section = operator_access_section ~operator operator_rules in
      Ok
        (Printf.sprintf
           {|{
  // GENERATED from each service's declared tailnet ports (apps/*,
  // guests/*). Do not edit here: the next deploy overwrites it. To
  // publish a port, declare it for that service and re-run.
  //
  // Default-deny. Only the flows listed below are allowed.
  "tagOwners": {
    "tag:vps":   ["%s"],
    "tag:nuc":   ["%s"],
    "tag:jails": ["%s"]
  },
  "acls": [
    // edge host -> the services that declared themselves reachable. A port missing
    // here fails silently: Caddy reports a gateway timeout and the compute host logs
    // nothing, because the packets never leave the edge host.
    {
      "action": "accept",
      "src":    ["tag:vps"],
      "dst":    [%s]
    },
    // Operator -> SSH to either host over Tailscale.
    {
      "action": "accept",
      "src":    ["%s"],
      "dst":    ["tag:vps:22", "tag:nuc:22"]
    },
%s
    // Nodes to themselves.
    {
      "action": "accept",
      "src":    ["tag:vps"],
      "dst":    ["tag:vps:*"]
    },
    {
      "action": "accept",
      "src":    ["tag:nuc"],
      "dst":    ["tag:nuc:*"]
    }
  ]
}
|}
           operator operator operator
           (render_destinations service_rules)
           operator operator_section)
