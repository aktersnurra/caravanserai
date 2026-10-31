open Serai

let rec remove_tree path =
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let endpoint ~name ~ip ~hostname ~tailnet_ports ~operator_ports =
  match Network_endpoint.create ~name ~ip ~hostname ~tailnet_ports ~operator_ports with
  | Ok endpoint -> endpoint
  | Error errors -> failwith (Network_endpoint.errors_message errors)

let endpoints endpoints =
  match Network_endpoint.validate_all endpoints with
  | Ok endpoints -> endpoints
  | Error errors -> failwith (Network_endpoint.errors_message errors)

let guest ?(login_user = "builder") ?(source_checkout = "../src") endpoint =
  match Guest_config.create ~endpoint ~login_user ~source_checkout () with
  | Ok guest -> guest
  | Error error -> failwith (Guest_config.error_message error)

let app ~endpoint ~hooks =
  let strategy = match Strategy_config.parse
    ~strategy:(Sexplib.Sexp.Atom "freebsd_native_elixir")
    ~config:(Sexplib.Sexp.of_string "((packages (sqlite3)) (repo_path /repo) (release_name example) (check_path /))") with
    | Ok strategy -> strategy
    | Error error -> failwith (Strategy_config.error_message error)
  in
  match App_config.create ~endpoint ~strategy ~hooks ~extra_steps:[] () with
  | Ok app -> app
  | Error error -> failwith (Strategy_config.error_message error)

let edge ?(operator = "ops") base_domain =
  match Edge_config.create ~base_domain ~operator with
  | Ok edge -> edge
  | Error error -> failwith (Edge_config.error_message error)


(* One compute host, compute-test, on [network] (by default a /24 with the
   gateway at .1 and the guest bridge at .254), with edge-test as the edge:
   what a dispatcher fixture needs to place [jails] and [guests] and check
   their addresses. *)
let topology ?(proxy = [])
    ?(network = "(subnet 10.40.0.0/24) (gateway 10.40.0.1) (guest_bridge 10.40.0.254)")
    ~jails ~guests () =
  let placed format names = String.concat " " (List.map (Printf.sprintf format) names) in
  Topology.of_sexp (Sexplib.Sexp.of_string (Printf.sprintf
    "((hosts ((compute (os freebsd) (ssh compute-test)\n\
    \   (network %s))\n\
    \  (edge (os linux) (ssh edge-test))))\n\
    \ (jails (%s)) (guests (%s)) (edge edge) (proxy (%s)))"
    network (placed "(%s compute)" jails) (placed "(%s (host compute) (via compute))" guests) (String.concat " " proxy)))
