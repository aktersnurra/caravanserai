(* Up_inputs: everything `infra up` needs, derived from declarations alone. *)
open Infra

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let () =
  let d = Result.get_ok (Declaration.load ~layout:(Repo_root.example ())) in
  let topology = Option.get d.topology in
  let inputs name = Up_inputs.of_app ~topology (Option.get (App_config.find d.apps name)) in
  (match inputs "hello" with
   | Ok i ->
       check "hello builds on its placed host" (i.host.id = "worker");
       check "builder address and base come from the host" (i.build.ip = "10.20.0.200");
       check "hello is a phoenix build from its declared remote"
         (i.kind = Up_inputs.Phoenix
          && i.source_url = "https://git.example.org/hello.git"
          && i.opam_repository = None);
       check "public check uses hostname and check path"
         (i.public_url = "https://hello.example.org/")
   | Error e -> failwith e);
  (match inputs "counter" with
   | Ok i ->
       check "counter is an ocaml build with a pinned opam repository"
         (i.kind = Up_inputs.Ocaml
          && i.source_url = "https://git.example.org/counter.git"
          && (match i.opam_repository with
              | Some r -> r.commit = "4b3c9153f191701aa5da18d2f5ab5da796ce2133"
              | None -> false));
       check "counter public check uses its health path"
         (i.public_url = "https://counter.example.org/health")
   | Error e -> failwith e);
  check "an app without a declared source is refused with the reason"
    (let plain = Test_declaration.app ~hooks:[]
       ~endpoint:(Test_declaration.endpoint ~name:"plain" ~ip:"10.20.0.9"
                    ~hostname:"plain.example.org" ~tailnet_ports:[] ~operator_ports:[]) in
     match Up_inputs.of_app ~topology plain with
     | Error e -> e = "plain: declare (source (git <url>)) in its app.sexp to use infra up"
     | Ok _ -> false);
  check "a package app is not handled by up" (Result.is_error (inputs "logs"));
  let without_build = Topology.of_sexp (Sexplib.Sexp.of_string
    {|((hosts ((worker (os freebsd) (ssh worker) (network (subnet 10.20.0.0/24) (gateway 10.20.0.1) (guest_bridge 10.20.0.254))) (edge (os linux) (ssh edge))))
       (jails ((hello worker) (counter worker) (logs worker)))
       (guests ((ledger (host worker) (via worker)))) (edge edge)
       (proxy (hello counter logs ledger)))|}) in
  check "a host without build settings is refused"
    (Result.is_error (Up_inputs.of_app ~topology:without_build (Option.get (App_config.find d.apps "hello"))))
