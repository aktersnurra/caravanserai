(* Renders the hand-written Caddy templates under edge/caddy from the
   endpoint list. The templates stay the source of each vhost's shape --
   an X-Accel video proxy, rate limits, security headers are bespoke
   Caddyfile, not something to model in OCaml -- and this fills in
   the network facts they reference, so no IP, port or app hostname is
   written in two places.

   Placeholders, derived uniformly (names are [a-z0-9]+, see
   Network_endpoint.validate_all, so these cannot collide):
     __BASE_DOMAIN__                  edge/edge.sexp
     __<NAME>_IP__, __<NAME>_HOSTNAME__
     __<NAME>_<PORT_NAME>_PORT__      one per tailnet port
   Operator ports get none: Caddy never proxies to them.

   Reading the template files is this module's input boundary; placeholder
   derivation and substitution are pure functions over strings. *)

let placeholders ~(edge : Edge_config.t) endpoints =
  ("__BASE_DOMAIN__", edge.base_domain)
  :: List.concat_map
       (fun (endpoint : Network_endpoint.t) ->
         let name = String.uppercase_ascii endpoint.name in
         (Printf.sprintf "__%s_IP__" name, endpoint.ip)
         :: (Printf.sprintf "__%s_HOSTNAME__" name, endpoint.hostname)
         :: List.map
              (fun (named : Network_endpoint.named_port) ->
                ( Printf.sprintf "__%s_%s_PORT__" name
                    (String.uppercase_ascii named.port_name),
                  string_of_int named.port ))
              endpoint.tailnet_ports)
       (Network_endpoint.to_list endpoints)

let replace_all ~pattern ~with_ text =
  if pattern = "" then invalid_arg "Caddy_render.replace_all: empty pattern";
  let pattern_length = String.length pattern in
  let buffer = Buffer.create (String.length text) in
  let rec go i =
    if i > String.length text - pattern_length then
      Buffer.add_string buffer (String.sub text i (String.length text - i))
    else if String.sub text i pattern_length = pattern then begin
      Buffer.add_string buffer with_;
      go (i + pattern_length)
    end
    else begin
      Buffer.add_char buffer text.[i];
      go (i + 1)
    end
  in
  go 0;
  Buffer.contents buffer

let substitute ~placeholders text =
  List.fold_left
    (fun text (pattern, with_) -> replace_all ~pattern ~with_ text)
    text placeholders

(* Digits included: port names may carry them (an s3 port gives
   __STORE_S3_PORT__), and a leftover one must be caught too. *)
let is_placeholder_char c = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_'

(* The first __[A-Z0-9_]+__ left in [text], after edge/02-caddy's own
   `grep '__[A-Z0-9_]\+__'` gate: at each "__", the longest stretch of
   placeholder characters that ends in "__" -- so "__FOO__X" still reports
   "__FOO__". Intentionally narrower than that grep: a run of bare
   underscores is not treated as a placeholder here, though the grep matches
   it, so 02-caddy's remote gate still rejects such a tree. Caddy's runtime
   {$ENV} placeholders never match: they use braces, not double underscores. *)
let find_unsubstituted text =
  let length = String.length text in
  let is_placeholder_at ~start ~stop =
    stop - start >= 5
    && text.[stop - 1] = '_'
    && text.[stop - 2] = '_'
    && String.exists (fun c -> c <> '_') (String.sub text (start + 2) (stop - start - 4))
  in
  let rec longest ~start stop =
    if stop - start < 5 then None
    else if is_placeholder_at ~start ~stop then Some (String.sub text start (stop - start))
    else longest ~start (stop - 1)
  in
  let rec scan i =
    if i + 1 >= length then None
    else if text.[i] = '_' && text.[i + 1] = '_' then begin
      let run_end = ref (i + 2) in
      while !run_end < length && is_placeholder_char text.[!run_end] do incr run_end done;
      match longest ~start:i !run_end with Some _ as found -> found | None -> scan (i + 1)
    end
    else scan (i + 1)
  in
  scan 0

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* Dotfiles are skipped, as the former bash render's *.template glob
   skipped them, so an editor's swap or backup file never renders. *)
let template_names sites_dir =
  Sys.readdir sites_dir |> Array.to_list
  |> List.filter (fun name ->
         String.ends_with ~suffix:".template" name
         && (not (String.starts_with ~prefix:"." name))
         && not (Sys.is_directory (Filename.concat sites_dir name)))
  |> List.sort compare

let render_source ~placeholders rendered (relative_path, source) =
  match rendered with
  | Error _ as error -> error
  | Ok files -> (
      let contents = substitute ~placeholders (read_file source) in
      match find_unsubstituted contents with
      | Some placeholder ->
          Error (Printf.sprintf "%s: unknown placeholder %s" relative_path placeholder)
      | None -> Ok ((relative_path, contents) :: files))

let render ?proxy ~edge ~root_template ~sites:sites_dir endpoints =
  let placeholders = placeholders ~edge endpoints in
  if not (Sys.file_exists root_template && Sys.file_exists sites_dir && Sys.is_directory sites_dir)
  then Error (Printf.sprintf "missing Caddy template tree: %s and %s/" root_template sites_dir)
  else
    match template_names sites_dir with
    | [] -> Error (Printf.sprintf "no Caddy templates in %s" sites_dir)
    | templates ->
        let mentions = List.map (fun template ->
          let source = read_file (Filename.concat sites_dir template) in
          template, Network_endpoint.to_list endpoints |> List.filter (fun (e : Network_endpoint.t) ->
            let pattern = "__" ^ String.uppercase_ascii e.name ^ "_" in
            replace_all ~pattern ~with_:"" source <> source)) templates in
        (* Each proxied workload has exactly one site: none would leave it
           unreachable without an error, two would be two sites for one name. *)
        let one_site_each = match proxy with
          | None -> Ok ()
          | Some names ->
              List.fold_left (fun acc name -> Result.bind acc (fun () ->
                let mentioning = List.filter_map (fun (template, mentioned) ->
                  if List.exists (fun (e : Network_endpoint.t) -> e.name = name) mentioned
                  then Some template else None) mentions in
                match mentioning with
                | [ _ ] -> Ok ()
                | [] -> Error (Printf.sprintf "%s is proxied but no template in %s mentions it" name sites_dir)
                | many -> Error (Printf.sprintf "%s is mentioned by more than one template: %s"
                                   name (String.concat ", " many))))
                (Ok ()) names in
        let selected = Result.bind one_site_each (fun () -> List.fold_left (fun acc (template, mentioned) ->
          Result.bind acc (fun selected ->
            match proxy with
            | None -> Ok (template :: selected)
            | Some names ->
                let exposed, hidden = List.partition (fun (e : Network_endpoint.t) -> List.mem e.name names) mentioned in
                if exposed <> [] && hidden <> [] then Error (template ^ ": mixes exposed and unexposed workloads")
                else if hidden <> [] then Ok selected else Ok (template :: selected))) (Ok []) mentions) in
        Result.bind selected (fun templates ->
        ("Caddyfile", root_template)
        :: List.map
             (fun template ->
               ( "conf.d/" ^ Filename.chop_suffix template ".template",
                 Filename.concat sites_dir template ))
             (List.rev templates)
        |> List.fold_left (render_source ~placeholders) (Ok [])
        |> Result.map List.rev)
