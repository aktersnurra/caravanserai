(* Pure function from every endpoint (apps and guests) to the compute host pf.conf
   jail-port rules -- no Proc effect, no side effects, directly
   unit-testable. Ported from the shell renderer that compute/01-pf-rules used
   to carry, and was byte-identical to it before it was deleted; that
   script's install_rules (resolving the edge host's live Tailscale address,
   splicing the rendered rules into the anchored block of /etc/pf.conf,
   pfctl -nf validation, backup, pfctl -f reload) stays as shell, since
   it's remote/deploy-time behavior this project keeps out of OCaml by
   design.

   Rules carry a literal __EDGE__ placeholder rather than a resolved address:
   rendering can happen on the operator's machine, which need not be on the
   tailnet, while the real edge host Tailscale address is only resolvable from the
   compute host itself at install time. install_rules substitutes it there via
   sed "s|__EDGE__|${edge_address}|g".

   Installed by Dispatcher.edge through compute/01-pf-rules's PF_SOURCE mode,
   which keeps validation, backup and reload in the shell script. *)

let render_endpoint_rules (endpoint : Network_endpoint.t) =
  endpoint.tailnet_ports
  |> List.map (fun (named : Network_endpoint.named_port) ->
         Printf.sprintf
           "pass in on $ts_if proto tcp from __EDGE__ to %s port %d keep state  # %s"
           endpoint.ip named.port endpoint.name)

let render ?proxy endpoints : (string, string) result =
  let endpoints = Network_endpoint.to_list endpoints in
  let endpoints = match proxy with None -> endpoints | Some names ->
    List.filter (fun (e : Network_endpoint.t) -> List.mem e.name names) endpoints in
  match endpoints |> List.concat_map render_endpoint_rules with
  | [] -> Error "no endpoint declared any tailnet_ports -- refusing to render an empty ruleset"
  | rules -> Ok (rules |> List.map (fun line -> line ^ "\n") |> String.concat "")
