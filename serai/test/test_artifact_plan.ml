open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name
  else (Printf.eprintf "FAIL - %s\n%!" name; exit 1)

let contains ~needle haystack =
  let n = String.length needle in
  let rec go i = i + n <= String.length haystack
    && (String.sub haystack i n = needle || go (i + 1)) in
  go 0

let layout = Repo_root.example ()
let app name = App_config.load (Filename.concat (Layout.app_dir layout name) "app.sexp")
let guest name = Guest_config.load (Filename.concat (Layout.guests_dir layout) (name ^ "/guest.sexp"))
let declared text = App_config.of_sexp (Sexplib.Sexp.of_string text)
let ok = function Ok value -> value | Error message -> failwith message

(* The strategies the example does not use, declared inline. *)
let binary = declared
  {|((name idp) (ip 10.20.0.5) (hostname id.example.org) (tailnet_ports ((http 1411)))
     (operator_ports ()) (strategy fetch_binary) (hooks (bootstrap check)) (extra_steps ())
     (strategy_config ((version v2.16.0)
       (binary_sha256 942e6ceff2a87f12011a776551758245889250ffa5039034f130347921d9940b)
       (binary_url_template https://example.org/releases/${VERSION}/idp_freebsd_amd64)
       (binary_name idp) (port 1411)
       (env_values ((APP_URL https://id.example.org))) (data_dir /var/db/idp)
       (packages (sqlite3)) (env_template_path env.template)
       (rc_template_path idp.rc.template) (check_path /))))|}
let package = declared
  {|((name store) (ip 10.20.0.4) (hostname store.example.org) (tailnet_ports ((s3 3900)))
     (operator_ports ()) (strategy freebsd_package) (hooks (bootstrap check)) (extra_steps ())
     (strategy_config ((packages (garage)) (check_path /))))|}

let () =
  List.iter
    (fun name ->
      let plan = ok (Artifact_plan.of_app ~revision:"abc123" (app name)) in
      let text = Artifact_plan.render plan in
      check (name ^ " builds natively for a FreeBSD jail")
        (contains ~needle:("runtime: FreeBSD jail " ^ name) text
        && contains ~needle:"disposable FreeBSD build jail" text);
      check (name ^ " keeps release under the host artifact store")
        (contains ~needle:("/var/db/serai/artifacts/" ^ name ^ "/abc123-") text))
    [ "hello"; "counter" ];
  check "Phoenix release names come from typed declarations"
    (contains ~needle:"Phoenix release hello"
       (Artifact_plan.render (ok (Artifact_plan.of_app ~revision:"abc123" (app "hello")))));
  check "an upstream binary uses its pinned version and checksum"
    (contains ~needle:"upstream binary v2.16.0 sha256" (Artifact_plan.render (ok (Artifact_plan.of_app binary))));
  let package = ok (Artifact_plan.of_app package) in
  check "a package reports unresolved package identity"
    (package.artifact_dir = None
    && contains ~needle:"pending package resolution" (Artifact_plan.render package));
  let ledger = ok (Artifact_plan.of_guest ~revision:"abc123" (guest "ledger")) in
  check "a guest builds for its Linux guest"
    (contains ~needle:"runtime: Linux guest ledger" (Artifact_plan.render ledger));
  check "source revision is required"
    (match Artifact_plan.of_app (app "hello") with Error _ -> true | Ok _ -> false);
  check "unsafe revision is refused before becoming a path"
    (match Artifact_plan.of_app ~revision:"../../other" (app "hello") with
    | Error _ -> true | Ok _ -> false);
  check "binary release ignores no supplied revision"
    (match Artifact_plan.of_app ~revision:"abc123" binary with
    | Error _ -> true | Ok _ -> false)
