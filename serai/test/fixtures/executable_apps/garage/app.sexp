; A package whose rc status checks cluster RPC and whose unsigned S3
; requests answer 403: the strategies the example configuration lacks.
(
(name garage)
(ip 10.20.0.4)
(hostname s3.example.org)
(tailnet_ports ((s3 3900)))
(operator_ports ())
(strategy freebsd_package)
(hooks (bootstrap check))
(extra_steps ())
(strategy_config (
  (packages (garage))
  (check_path /)
  (check_status 403)
  (service_status process)
))
)
