# Changelog

## 2026-11-16: Operator access to edge-host ports

- `edge.sexp` takes an optional `operator_edge_ports`, e.g.
  `((imaps 993) (submission 587))`: ports on the edge host itself that the
  operator's devices may reach over the tailnet. The ACL renders them as one
  operator rule to `tag:vps`, and omits it when none are declared, so
  existing policies render unchanged.

## 2026-11-15: Every command for agents

- `serai commands [--json]` lists every command, its arguments and flags
  and what it may change. The parser and the usage text come from the same
  table, and every command takes `--json` and its flags in any order.
- Under `--json`, a command that changes a host applies only an approved
  plan: `--plan` returns a `plan_id` (exit 2), `--yes --expect-plan <id>`
  applies that plan and no other. In a terminal, `--plan` and
  `--expect-plan` work the same and every prompt is preceded by its
  `plan <id>`. `serai artifact build` of a source app now asks before it
  builds.
- A result is `refused` (nothing changed), `failed` (`apply_failed`: a host
  may have changed) or `unknown` (`outcome_unknown`, exit 3: a stage and
  lock were left, named in `data.retained`).
- An approved `serai up` plan no longer applies pending edge changes: it
  plans them and stops for the operator with their plan id.
- A result says what ran: `changed`, `hosts` and `ran`, on success and on a
  failure after a change. `error.cause` names why in a word, for every
  failure serai raises (the agent interface lists them); `up` gives
  `next_command` beside `next`. No plan is issued for an undeclared
  workload or host.
- `serai locks` shows who holds each host's lock and for how long;
  `serai status` shows each app's jail and releases. `serai revert <app>`
  is a command of its own.
- CI runs `scripts/lint.sh` on every push.

## 2026-11-15: Review fixes

- Host scripts fail whole or not at all: `compute/01-pf-rules` refuses a
  BEGIN marker without its END, `artifact_activate.sh` puts `.previous`
  back when the active switch fails, `compute/01-base` keeps the generated
  service rules on a re-run and loads `pf.conf` for real, and
  `edge/02-caddy` rolls back on a signal.
- `edge/02-caddy` requires the secrets its staged tree references
  (`{$NAME}` without a default) instead of one named secret.
- `edge/00-headscale` installs by rename, verifies `HEADSCALE_SHA256` when
  set and mints keys for the operator's own user.
- `serai up` takes its flags in any order. A step that raises is reported
  as that step's failure in `up --json`.
- A pipeline's `(script name)` must be a plain file name; ports are decimal.
- A lock older than 30 minutes says to check its holder before
  `serai unlock`.
- `scripts/lint.sh` shellchecks every script it finds.
- Inside: `Dispatcher` is split into the modules it includes, and the
  artifact operations share one retained-stage protocol.

## 2026-11-05: `serai drift`

- `serai drift [--json]` shows in one read-only call where the live system
  differs from the declaration: the edge's and Pocket ID's pending plans,
  and each app's live commit against its `deploy` bookmark or default
  branch, with the plan id that fixes each part. A part that can't be
  checked says why; exit 2 when drifted, 1 when incomplete.

## 2026-11-03: Plan binding

- `serai up`, `serai edge` and `serai idp` name each plan with a plan id,
  printed as `plan <id>` and returned as `plan_id`. An apply given
  `--expect-plan <id>` plans again and refuses, before changing anything,
  any other plan: code `stale_plan` in JSON. A JSON apply requires it, so
  `serai up --yes --json` now needs `--expect-plan`.
- New JSON operations: `edge.plan`, `edge` (the apply) and `idp.apply`.
- The edge diffs print the same for the same change: labelled sides, no
  temporary paths or file times, and Caddy's `conf.d` file by file.

## 2026-11-03: The identity provider as configuration, `serai idp`

- `idp.sexp` declares Pocket ID's groups, users, OIDC clients and APIs,
  with memberships, custom claims, allowed groups, token lifetimes, API
  permissions, CIMD access and client grants. `serai validate` checks it.
- `serai idp --plan [--json]` shows how the live Pocket ID differs, and
  `serai idp [--yes]` applies it over HTTPS with the admin API key in
  `SERAI_IDP_API_KEY`, which never reaches a command line. Undeclared
  resources are reported and never deleted; passkeys and client secrets are
  never touched. `serai idp --export` prints a running instance as
  `idp.sexp`. Pocket ID 2.19.x only.
- No new dependency: `Json` parses and prints JSON, and requests go
  through curl.
- `serai idp` refuses a plan that removes `(admin)` from the API key's
  owner or disables them: Pocket ID would refuse the key, and `serai idp`
  could not undo it.

## 2026-11-01: `serai update` leaves controller-built apps alone

- An app that declares a `web_bundle` is no longer updated unattended. Only
  the controller builds its bundle, so a build on the compute host could
  only fail. `serai update` doesn't fetch its repository, and reports it as
  `built_on_controller` (`--plan`: "built on the controller (web bundle);
  deploy it with serai up"). A run prints nothing for it and marks nothing
  handled.

## 2026-11-01: Tests run on FreeBSD too

- The shell and unit tests pass on FreeBSD 15.1 as well as Linux.
  `tests/stat-field` reads one file attribute from GNU or BSD `stat`, and
  the tests and their fakes use it instead of `stat -c`. The `mv` fakes use
  `-fh` or `-fT`, whichever the system's `mv` has. Native source
  verification uses each system's own `sha256` and `stat`.
- Tests that run a script found only in the Linux guest (guest build,
  install, activation, logging) report `skip` off Linux.
- Test dependencies, on either system: `python3`, `caddy`, `elixir` with
  Erlang, `node` and `jj`.

## 2026-10-31: Unattended updates, `serai update`

- `serai update` deploys a newer version of a source-built app that is
  already running, once CI has moved its repository's `deploy` bookmark.
  The commit must be signed by a key in `~/.config/serai/update.sexp` and
  newer than the live release. It runs from cron on the compute host,
  reads the configuration from a signed commit of its own remote, and
  never creates a jail, writes an env or touches the edge. A run with
  nothing new prints nothing, so cron mails only news. `--plan` and
  `--json` are supported. Setup is in `serai/README.md`.
- BREAKING for host helpers: `artifact_install.sh` takes a 6th argument,
  `artifact_apply.sh` a 12th: the source commit, or `-`. Install records it
  beside the release as `.infra-source`, so the host can tell which commit
  is live whoever deployed it. Releases installed before this have no
  record until their next `serai up`.
- `artifact_apply.sh revert` and `Dispatcher.revert` reactivate the release
  kept in `.previous` where it is installed, without its archive, for apps
  that declare no `migrate`.
- `serai up` has an update target (used by `serai update`) that refuses a
  missing jail or env and skips the edge.
- `Source_mirror` reports a commit's signature verdict, ancestry and remote
  bookmarks. `Release_probe` reads a jail's live release, its source record
  and the retained previous release.

## 2026-10-31 — One name: serai

- BREAKING: the CLI is only `serai`; `scripts/install.sh` (was
  `install-infra.sh`) no longer installs the `infra` alias. Help, hints,
  errors and docs say `serai`.
- BREAKING: every `INFRA_*` variable is `SERAI_*` (`SERAI_CACHE`,
  `SERAI_STORE`, `SERAI_ARTIFACT_HOST_TEST`, ...), and progress events are
  `serai.progress`, `serai.phase_duration` and
  `serai.phase_timing_unavailable`.
- The default cache and store are `~/.cache/serai` and
  `~/.local/share/serai/store`; move the `infra` ones there to keep them.
- The source directory is `serai/`, the dune package and library `serai`,
  and the configuration's skill `serai-operations`.
- Names on the hosts and in the store keep `infra` so nothing deployed
  changes: `/opt/.infra-releases`, `.infra-sha256`, `/var/lib/infra/applied`,
  `<stage>/locks/infra`, `infra-build-*` jails and the `infra-*-v1` format
  tags. The builder scripts did change, so every artifact's recipe identity
  is new and each app rebuilds once on its next `serai up`.

## 2026-10-31 — Publishable: no deployment's names in the engine

- BREAKING: `fetch_binary` takes `(env_values ((NAME value) ...))` and
  `(generated_secrets (NAME ...))` in place of `app_url`, `db_path`,
  `upload_dir` and `geolite_db`. Each env value fills `__NAME__` in the
  app's env template; each generated secret is 32 random bytes (base64),
  made only when the env file is first written. `__JAIL_IP__` and
  `__PORT__` are always filled. The strategy no longer creates an uploads
  directory: the app creates what it needs under its `data_dir`, or an
  extra step does.
- BREAKING: `logging.sexp` names its receiver, `(receiver <app>)`, in
  place of the hard-coded `logs` app; the compute host installer is
  `bootstrap.sh <receiver> [--replace]`.
- The host-test harness runs only with `INFRA_ARTIFACT_HOST_TEST=1` and
  `--app <name>`; the legacy single-app mode is gone.
- Tests, fixtures and docs use generic app names, `example.org` and
  `10.0.0.0/8` addresses; a guard refuses private addresses in host scripts.

## 2026-10-28 — Hosts named by role

- `nuc/` is `compute/` and `vps/` is `edge/`, matching the roles in
  `serai.sexp`; the hosts' stage follows (`<stage>/compute/`,
  `<stage>/edge/`), and the default stage is `/tmp/serai-stage`.
- Configuration-facing names change with them: the pipeline arguments
  `$COMPUTE_TARGET`/`$EDGE_TARGET`, the logging steps `compute-logging`,
  `compute-logging-replace`, `edge-logging` and `recover-edge[-check|-health]`,
  the hook variables `COMPUTE_TARGET`/`EDGE_TARGET`, and the overrides
  `EDGE_TS_IP`/`EDGE_PEER_MATCH`. Prompts name hosts from the topology.
- Unchanged, because the hosts hold them: the tailnet tags
  `tag:nuc`/`tag:vps`, the peer names and pf's `^vps$` default, the pf.conf
  block marker and syslog-ng's `vps-oauth-safe-event` persist name.

## 2026-10-28 — Imported from nuc-setup

The engine split out of the nuc-setup repository, which keeps its own
configuration (now mirbad). The CLI installs as `serai`, with `infra` as an
alias, and the files it runs on the hosts under
`~/.local/share/caravanserai`. Its tests run on `example/` and fixtures.
`serai validate` checks each app's and guest's shell `config` against its
declaration and reads `pipelines.sexp`.
