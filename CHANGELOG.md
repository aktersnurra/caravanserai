# Changelog

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
