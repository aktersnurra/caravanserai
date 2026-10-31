(
(name counter)
(ip 10.20.0.3)
(hostname counter.example.org)
(tailnet_ports ((http 4010)))
(operator_ports ())
(strategy freebsd_native_ocaml)
(hooks (bootstrap check))
(extra_steps ())
(strategy_config (
  (ocaml_switch 5.5.1)
  (repo_path /home/ops/src/counter)
  (source (git https://git.example.org/counter.git))
  ; One opam-repository snapshot, known to solve on FreeBSD.
  (opam_repository (git https://github.com/ocaml/opam-repository.git)
   (commit 4b3c9153f191701aa5da18d2f5ab5da796ce2133))
  (zfs_dataset zroot/counter)
  (data_dir /var/db/counter)
  (packages (ocaml-opam bash gmake pkgconf sqlite3 gmp ca_root_nss git))
  ; The service runs bin/counter.exe with these arguments.
  (serve_args (serve))
  ; Runs bin/counter.exe migrate between stop and start.
  (migrate (command migrate))
  (check_path /health)
))
)
