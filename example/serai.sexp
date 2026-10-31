; Machine identity and workload placement. SSH targets are ssh config aliases
; on the operator's machine.
((hosts
  ((worker (os freebsd) (ssh worker)
    ; lo1's jail subnet, the host's own address on it, and the bhyve guest
    ; bridge's address, which guests use as their gateway and log relay.
    (network (subnet 10.20.0.0/24) (gateway 10.20.0.1) (guest_bridge 10.20.0.254))
    ; Disposable build jails: a free address and FreeBSD's official base,
    ; digest from its MANIFEST.
    (build (ip 10.20.0.200)
     (base (url https://download.freebsd.org/releases/amd64/amd64/15.1-RELEASE/base.txz)
      (sha256 3768988b151c20f965679062b065c63a977d6bbb9f47fd83695ec2c40790c18f))))
   (edge (os linux) (ssh edge))))
 (jails ((hello worker) (counter worker) (logs worker)))
 (guests ((ledger (host worker) (via worker))))
 (edge edge)
 ; Every workload with tailnet_ports, routed from the edge.
 (proxy (hello counter logs ledger)))
