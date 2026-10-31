; A Linux bhyve guest running an OCaml service, for a workload that cannot
; run in a FreeBSD jail. The network fields feed the ACL, pf and Caddy;
; login_user and source_checkout are how serai reaches and builds it.
(
(name ledger)
(ip 10.20.0.10)
(hostname ledger.example.org)
(tailnet_ports ((http 4020)))
; A guest runs its own kernel, so the operator reaches it over SSH.
(operator_ports ((ssh 22)))
; The account serai reaches the guest as, through a ProxyJump via its host.
(login_user ledger)
; The checkout on the operator's machine, relative to the configuration root.
(source_checkout ../src/ledger)
; What serai artifact build makes and artifact upgrade installs: the dune
; project in the source and its executable, released as ledger, readable by
; the service's ledger-svc group.
(workload (
  (project service)
  (target bin/main.exe)
  (release ledger)
  (service_group ledger-svc)
))
)
