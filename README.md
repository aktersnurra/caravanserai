# caravanserai

Infrastructure for FreeBSD jails and bhyve Linux guests on one or more
compute hosts, behind a Linux edge host running Caddy and Headscale. You
declare apps, guests and the edge as sexp files; `serai` renders each jail's
script and the whole edge (pf rules, the Headscale ACL, the Caddy tree) from
them, and builds, ships and checks the apps over ssh.

This repository is the engine. A configuration lives in its own repository
and names the hosts, apps and domain; [`example/`](example/) is a complete
one on example.org.

## Install

```sh
./scripts/install.sh    # builds, tests, installs ~/.local/bin/serai
```

It also installs the files `serai` runs on the hosts (`compute/apps/_lib`,
`compute/01-pf-rules`, the `edge/` scripts) under `~/.local/share/caravanserai`.
Re-run it after pulling changes: the installed copy does not rebuild itself.

## A configuration

`serai` reads the configuration it is run inside: the nearest directory
above it holding `serai.sexp`.

```
serai.sexp              hosts, where each workload runs, what the edge proxies
logging.sexp            which apps forward which logs
pipelines.sexp          named sequences of steps (serai run <app> <pipeline>)
apps/<app>/app.sexp     an app: address, ports, strategy, hooks
guests/<guest>/         a bhyve guest: guest.sexp and its own scripts
edge/edge.sexp          the domain and the operator
edge/caddy/             the Caddyfile and a sites/<nn>-<app>.caddy.template per site
```

Try it on the example:

```sh
cd example && serai validate
```

[`serai/README.md`](serai/README.md) covers every command.

## Repository layout

```
serai/                  serai, the OCaml CLI
compute/01-base         first-run setup of a FreeBSD compute host
compute/02-bhyve        bhyve and the guest bridge on a compute host
compute/01-pf-rules     installs the pf rules serai renders
compute/apps/_lib/      what serai runs on a compute host: build, install, check, logging
edge/                   first-run setup and installers for the edge host
example/                a complete configuration
tests/                  shell tests of the host scripts and the CLI
```

## Development

```sh
./scripts/lint.sh       # shellcheck, dune build and test, the example's render, tests/*.sh
```
