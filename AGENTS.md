# AGENTS.md

The engine behind `serai`: FreeBSD jails and bhyve Linux guests behind a
Linux edge (Caddy, Headscale). `README.md` covers the layout,
`infra/README.md` the CLI and `docs/AGENT-INTERFACE.md` its JSON results.

## Layout

- `infra/` is the OCaml CLI. It renders jail scripts and the edge from a
  configuration's sexp declaration and runs the hooks over ssh.
- `compute/` and `edge/` are the POSIX sh it runs on compute and edge
  hosts. Compute host scripts run under FreeBSD `/bin/sh` and BSD awk.
- `example/` is a complete configuration; the engine's tests run on it and
  on the fixtures in `infra/test/fixtures/`, never on a real deployment's.

## Workflow

- Use jj, not git. Commit directly on `master`; do not create jj
  workspaces (they break the tests and strand the checkout).
- Do not push. The operator pushes with `jj push --bookmark master`, which
  runs lint first.
- Before claiming a change works, run the checks it touches:
  - `./scripts/lint.sh`: shellcheck, `dune build` and `dune test`, the
    example's render and every `tests/*.sh`
  - while iterating, `cd infra && dune test` or `bash tests/<name>.sh`
- After changing `infra/`, `compute/` or `edge/`, reinstall:
  `./scripts/install-infra.sh`.

## Rules

- The engine names no deployment: no real app, guest, host, domain, user
  or subnet in code, comments or tests. The tailnet's `tag:nuc`/`tag:vps`,
  its peer names and the pf anchor are live identifiers: renaming them
  needs a migration on the hosts. Use `example/` or a fixture.
- Never read, print, copy or interpolate secrets: jail env files, Caddy's
  `/etc/caddy/secrets.env`, oauth2-proxy's `secrets.env`. The operator
  enters them by hand.
- Do not change a live host without the operator's go-ahead.
- A jail config file is `root:<jail-gid>` `0640`, never `root:root 0600`,
  or the service cannot read it.
- Extra steps get `JAIL`, `JAIL_IP`, `JROOT` and `APP` on their command
  line and must not leave them exported: FreeBSD's `service(8)` reads an
  inherited `JAIL`.
