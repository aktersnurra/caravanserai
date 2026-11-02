# Example configuration

A complete configuration for this engine, on example.org and 10.20.0.0/24:

- `hello`, a Phoenix app, and `counter`, an OCaml app, each in a FreeBSD jail
  on the `worker` host; `counter` forwards its log file to central logging.
- `logs`, the VictoriaLogs receiver, and its pipelines (`serai run logs
  rollout-edge`, `forwarding`, `replace-forwarding`, `recover`).
- `ledger`, an OCaml service in a Linux bhyve guest on `worker`.
- `idp.sexp`, the identity provider's groups, users, OIDC clients and an
  API, which `serai idp` keeps a Pocket ID in line with.
- `edge`, the Linux host running Caddy and Headscale in front of them, and
  oauth2-proxy in front of the logs UI (`edge/oauth2-proxy/`; its client
  credentials are entered by hand on the host).

Run serai from inside this directory and it reads this configuration on the
engine above it:

    cd example && serai validate

The engine's tests render it against `serai/test/golden/example/`.
