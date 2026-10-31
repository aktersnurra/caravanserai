(
(name logs)
(ip 10.20.0.20)
(hostname logs.example.org)
; http is VMUI, which the edge host serves behind oauth2-proxy; syslog is the
; private TCP receiver the senders reach. Neither is public.
(tailnet_ports ((http 9428) (syslog 29514)))
(operator_ports ())
(strategy freebsd_package_service)
(hooks (bootstrap check))
(extra_steps ())
(strategy_config (
  (packages (victoria-logs))
  (zfs_dataset zroot/logs)
  (data_dir /var/db/victoria-logs)
  (data_owner victoria-logs)
  (service victoria_logs)
  (service_args (--storageDataPath=/var/db/victoria-logs
                 --retentionPeriod=14d
                 --httpListenAddr=10.20.0.20:9428
                 --syslog.listenAddr.tcp=10.20.0.20:29514))
  (check_path /health)
))
)
