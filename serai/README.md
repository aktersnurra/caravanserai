# serai — the estate's operations CLI

`serai` is how every app, guest and edge change is made: it reads the sexp
declaration (`apps/*/app.sexp`, `guests/*/guest.sexp`,
`edge/edge.sexp`), renders the jail scripts and the edge config from it, and
runs the per-app hooks over ssh under a per-host lock. It replaced the bash
`./ops` dispatcher, which has been retired.

Today, only local orchestration is OCaml; remote-side app hooks still run
as shell on FreeBSD and Linux. The artifact migration will move their shared
build, install, activation and health lifecycle into `serai`, while keeping
the generated remote operations in POSIX sh. No OCaml binary needs to run
inside a jail.

Local development uses the OCaml5.5.1 opam switch explicitly, so an inherited
PATH cannot select an unrelated old test compiler:

```sh
opam exec --switch=5.5.1 -- ./scripts/lint.sh
opam exec --switch=5.5.1 -- ./scripts/install.sh
```

The local switch also requires `mtime` (`mtime.clock.os`) for monotonic controller
phase durations.

Application build compilers remain declared separately; a guest may use OxCaml.

## Declaring an app: `serai new`

```sh
serai new hello --kind phoenix --repo ~/projects/hello [--hostname <fqdn>]
```

Writes a new app's declaration and touches no host: `apps/hello/app.sexp`,
`env.template` and `edge/caddy/sites/<NN>-hello.caddy.template`, and places
and proxies it in `serai.sexp`, comments kept. It takes the lowest
address on its host's declared `network` that no declaration, build jail,
gateway or guest bridge uses (test jails conventionally take the top of the
range), the next http port in
`4000-4999` in steps of 10, `hello.<base_domain>` and the next site number in
`40-49`. The source is the checkout's origin. A Phoenix app's release name
comes from `mix.exs` and its migrate from `lib/<release>/release.ex`; an
OCaml app takes the other OCaml apps' switch and opam pin, and serves
`bin/<app>.exe serve` with its health at `/health`. It refuses a taken name,
hostname or file, and removes what it wrote unless the whole declaration
still renders. Review the files, then commit them before `serai up`.

## Deploying an app: `serai up`

```sh
serai up hello --revision main
```

Everything else comes from the declarations. The app's `strategy_config`
names its git remote (`(source (git <url>))`) and, for OCaml, a pinned
opam repository; the compute host in `serai.sexp` names the builder
jail address and the FreeBSD base archive with its SHA-256. `serai up`:

1. reads the compute host: does the app's jail exist at its address, is the address
   held by any other jail (declared or not, running or in `/etc/jail.conf`),
   and is `/jails/<app>/etc/<app>/env` owned `root:<app>` `0640`. A held
   address or a jail without its env is refused before anything changes; a
   missing jail is created after the question, from the generated script,
   and the run stops for the operator to write the env;
2. fetches the app's mirror (`~/.cache/serai/sources/<app>`) and resolves the
   revision on the remote; unpushed commits are refused;
3. downloads the base archive once (`~/.cache/serai/base/`) and checks its
   digest on every use; an OCaml app's pinned opam repository is exported
   once per commit (`~/.cache/serai/opam-snapshots/<commit>`) and hashed on
   every use;
4. reuses a stored artifact (`~/.local/share/serai/store`) with the same
   commit and recipe, or builds one in a disposable jail;
5. prints the plan and asks once (`--yes` skips the question);
6. installs and activates the release, runs `serai edge`, and checks the
   public URL (`https://<hostname><check_path>`).

`--plan` stops after printing the plan, without asking: it changes no host
(the jail probe and the source fetch only read). `--plan --json` returns it
in the agent envelope.

A build that fails (compile error, package or network trouble) but removes
its build jail releases the lock and the remote stage by itself. Only an
incomplete teardown, an interrupt or a lost SSH connection keeps both, for
inspection before `serai unlock`.

`--source <checkout>` builds from a local jj checkout instead of the mirror,
for trying unpushed work; the plan says so. `SERAI_CACHE` and `SERAI_STORE`
override the two directories. Phoenix and OCaml apps only.

### Rehearsal: `--rehearse --ip <addr>`

```sh
serai up counter --revision master --rehearse --ip 10.40.0.200
```

The same build and release into the disposable jail `<app>test` at a free
address, with no edge step and no public URL: activation checks health at the
jail address. Inside the jail every name is the app's (`/opt/counter`,
`/etc/counter/env`, the `counter` service). It reads the compute host first and changes
nothing until the jail and its env are in place:

1. No `<app>test` yet: it is created from the generated jail script (its own
   confirmation, as `serai jail-test`), and the run stops.
2. Write `/jails/<app>test/etc/<app>/env` from the app's `env.template`, with
   the test jail's own address and database, owned `root:<app>` `0640`; the
   stop message gives the exact `chown`/`chmod`. serai never copies an env.
3. Run the same command again: it builds or reuses, installs and starts.
   Later runs upgrade the test instance, migrate included.

Destroy it when done: `serai jail-test <app> --destroy`.

## Native OCaml and guest artifacts

An OCaml app uses its declared compiler in the disposable FreeBSD builder.
A guest builds the `workload` its `guest.sexp` declares (dune project,
executable target, release name and service group) in the existing Linux
guest, unprivileged, with an explicitly selected OxCaml variant—not the
controller's compiler. Both require a committed opam
repository snapshot containing the requested compiler and dependencies:

```sh
serai artifact build <ocaml-app> --revision <rev> --ip <builder-ip> \
  --base <txz> --sha256 <base-digest> --store <private-dir> \
  --opam-repository <checkout> --opam-revision <rev>
serai artifact build <guest> --revision <rev> \
  --opam-repository <checkout> --opam-revision <rev> \
  --compiler <exact-ocaml-variants-package> --store <private-dir>
```

Add `--reuse <identity>` for explicit, locally verified selection of stored code.
Changed source/compiler/repository/helper inputs refuse reuse without host work
or a fallback build. Default builds remain fresh. Workers use private opam roots,
require source checksums, record installed package versions/linkage in the archive,
and refuse missing or temporary-build-root library providers. Source/repository
inventories are verified with native FreeBSD or Linux hash/stat tools.

A guest accepts the same `artifact upgrade|rollback|convert <guest> --identity <id>
--store <dir>` interface. It checks the actual Linux architecture/glibc ABI before
installing root-private verified inputs, preserves the unit/config/state, uses
versioned code with previous-only rollback, and holds one guest lock through
restart/readiness. Root `su` needs a real terminal/password handoff to the operator;
normal unprivileged build/reuse operations do not. Uncertain work or failed build
cleanup retains stage/lock and refuses publication.

**These paths are locally fixture-tested, not native OCaml/guest acceptance.** The
recorded repository identity, package versions and linkage are not full immutable
materials/runtime-closure attestation or proof of offline compilation. Actual
compiler/bootstrap/runtime closure and production byte equivalence remain open.
No native build, root activation or production conversion is authorized by these
examples.

## Agent-facing results and skill

Agents use the existing CLI plus
the serai-operations skill a configuration carries in `.agents/skills/`, not MCP.
Read-only commands `inspect --json`, `validate --json`, and
`artifact plan <workload> [--revision <revision>] --json` return a versioned JSON
result on stdout, and so do `new ... --json` (writes the declaration only),
`up ... --plan --json` (reads the compute host, changes nothing) and `up ... --yes
--json` (deploys, reporting each step's outcome). See [the contract](../docs/AGENT-INTERFACE.md) for fields,
error codes and limits. Inventory is declared configuration, not live state;
artifact plans are design previews, not immutable identities or apply approvals.
Other operations with `--json` refuse before host work. Structured mutation
contracts and the remaining lifecycle work are not complete.

## Agent-facing progress

Add `--progress=jsonl` to a command to stream JSON-line progress events on
stderr. Existing stdout, exit codes, confirmations and tool output are unchanged.
Events identify `event: "serai.progress"`, operation, workload, current phase,
UTC timestamp, elapsed seconds and status. Agent consumers select these events;
stderr can also contain ordinary diagnostics. No secrets or raw command arguments
are added to the progress stream.

Phase events mean `running`, not an estimated percentage. The terminal status is
`succeeded`, `failed`, `interrupted`, `changes_pending` (edge preview exit 2), or
`unknown` when the existing execution policy retains an uncertain remote outcome.
The terminal phase is the last reported phase; the terminal status describes the
whole operation. Artifact build/reuse/apply paths report their actual local
boundaries; `apply` includes the remote install/switch/restart/health transaction.
Underlying tool output remains the activity feed during a long build. A quiet
compiler is not evidence of failure or permission to retry.

This is opt-in command output, not an observer service, recovery journal or new
permission mechanism. Inspect retained stages/locks before retrying an unknown
operation. Example: `serai validate --progress=jsonl`.

For Phoenix workloads, `strategy_config.release_name` declares the release
directory and executable name independently of the jail name (an app
`drill` may ship `drill_trainer`). The parser restricts it to lowercase letters, digits and
underscores before it can reach a build worker. Existing deploy hooks still
read their shell `config` during this transition.

## Artifact migration (offline preview)

`serai artifact plan <name> [--revision <rev>]` derives an artifact recipe
from the existing `app.sexp` or `guest.sexp`. Source builds require an
explicit revision; this command neither checks that revision out nor contacts
a host. By strategy, an app is a FreeBSD Phoenix build, a FreeBSD OCaml
build, a verified upstream binary or a FreeBSD package that still needs exact
version resolution; a guest is a Linux guest build. Example:

```sh
serai artifact plan hello --revision abc123
serai artifact plan logs
```

The planned store is `/var/db/serai/artifacts/<name>/<preview-namespace>/`
on the compute host. This revision-plus-MD5 namespace is only a preview, not a
verified artifact identity or permission to reuse it. The `Artifact_manifest`
library validates a complete source manifest (commit, target ABI, resolved
dependencies, recipe digest, release name, archive SHA-256), and computes its
SHA-256 identity. The Phoenix build/store command below connects it to a
staged checkout and verified archive. Nothing is reused or activated on the
strength of the preview. `serai artifact source-stage <name> --revision <rev> --out <dir>` is the
separate local jj checkout boundary: it resolves one full source commit and
exports only its tracked regular files into a new private tree. Dirty working
copies are not exported; tracked `.env`, `.env.*` and `.env~*` paths are omitted
using metadata before any body is requested. Symlinks, conflicts and unsafe
filenames are refused. Literal `~` in opam prerelease paths is supported.
Example: `serai artifact source-stage
hello --revision <commit> --out /tmp/hello-source`. This does not transfer
or attest the snapshot inside a build jail, and does not build or deploy.
The output parent must be an existing directory you control. The
`Source_inventory` library can hash that private tree into a sorted,
versioned file/mode/SHA-256 inventory. The separate POSIX
`compute/apps/_lib/artifact_verify_source.sh <tree> <inventory> <inventory-sha256>`
checks transferred bytes and refuses missing, extra, symlinked or wrongly
moded entries. Its FreeBSD defaults use `sha256 -q` and full `stat -f %p` permissions masked to `07777`, including special bits.
**Historical candidate notes (superseded integration status):** the following
paragraphs preserve early boundary/failure observations, before the public CLI
build/store path below was proven on a disposable FreeBSD host.

The internal `Dispatcher.artifact_build_candidate` path now creates this
inventory from a committed Phoenix snapshot before taking the compute host operation
lock. It stages the snapshot, inventory, trusted digest, base archive and
shell adapters, then calls the verifier through the build-jail adapter. Mocked
serai tests cover command order, lock release and refusal paths. **No CLI
apply command invokes it**: it has not been exercised on FreeBSD. A future
operator must check the builder IP and trusted base archive before any live
run. `Artifact_recipe` copies the three builder scripts into a private local
snapshot before transfer and hashes those exact bytes, the trusted base
SHA-256, declared package arguments in order, and the release name into a
versioned recipe digest. In the same remote shell that invokes the adapter,
it checks all three transferred script hashes before execution. The candidate
downloads an archive, verifies its checksum locally, and validates the ABI
reported by `pkg config abi` inside the build jail. This guarded shell has
only been mocked, not run on FreeBSD; it does not attest a hostile host or
resolved package bytes. The candidate still does not resolve package archive
checksums, produce a
complete artifact manifest, or publish to the store.
Under the compute host lock, the internal path now removes its private remote
staging tree after a completed or failed transfer/build. If cleanup fails,
no candidate is published and the private stage is left for inspection.
This cleanup has only been exercised with mocked SSH, not on FreeBSD.
The opt-in, terminal-only executable `serai/test/host_artifact_build_candidate.ml`
is a candidate-only host-test harness (not an `serai` CLI apply command): it runs
only with `SERAI_ARTIFACT_HOST_TEST=1` and `--app <name>`, against a disposable
builder address the operator has checked.

`Artifact_store` is a separate local library for complete validated
`Artifact_manifest` values. It requires an existing private, owned store
root; publication copies and verifies the archive, writes the canonical
manifest, and renames both into the manifest identity directory. Every
reuse compares the manifest bytes and rehashes the archive. Corrupted
entries are refused, not overwritten. Identity selection through
`Artifact_store.load` also decodes canonical bytes, checks the directory identity
and rehashes the archive; parsing alone does not attest provenance.

The public **Phoenix build/store-only** command connects the verified disposable
candidate controller to this local store:

```sh
mkdir -m 700 /absolute/private/store
serai artifact build hello --revision <immutable-revision> \
  --ip <unused-builder-ip> --base /absolute/trusted/base.txz \
  --sha256 <trusted-base-sha256> --store /absolute/private/store
```

Store ownership/privacy and the trusted base are checked before host work.
Publication happens only after target/package/archive verification and confirmed
cleanup. It does not activate or convert legacy layouts. No raw manifest can
be supplied to this command. OCaml/guest controller reconciliation remains pending.

Package and pinned-executable builds are now locally wired through the same
private-store boundary, without inventing source commits:

```sh
serai artifact build logs --ip <unused-builder-ip> --base <txz> \
  --sha256 <trusted-base-sha256> --store <private-dir>
serai artifact build <binary-app> --ip <unused-builder-ip> --base <txz> \
  --sha256 <trusted-base-sha256> --store <private-dir> --reuse <verified-identity>
```

These select the declaration's package or checksum-pinned upstream origin,
snapshot its helper recipe, resolve/install verified package archives inside a
disposable jail, and run the actual FreeBSD-amd64 ELF-checking executable worker
as `builder`. No source checkout or jj revision is fabricated. Explicit identity
reuse verifies the typed origin, workload, release and base/helper/package recipe
locally and pins the recorded dependency closure; it never silently rebuilds.
Interrupted/failed transfers, a failed worker or stage cleanup retain stage/lock
for inspection. Publication requires confirmed cleanup and locally rehashed
output. These new package/binary paths have fixture/CLI proof only: no additional
native build or activation approval is implied. Package/pinned-binary lifecycle and
approved readiness are locally wired below; native runtime/deployment proof and
OCaml/guest lifecycle wiring remain incomplete.

Append `--reuse <artifact-identity>` to the same command to select an existing
artifact explicitly. This is local only: it rehashes the stored archive, resolves
the requested committed source, and matches workload, release and the recipe
covering base bytes, helper bytes and declared packages. It pins that identity's
recorded dependency versions/checksums, not the latest package repository state.
Missing, corrupt or mismatched entries refuse without a fallback build. Omit
`--reuse` to resolve dependencies and build fresh. Reuse does not establish a
live target's ABI compatibility; that must be checked before installation.
The legacy prepare-only install command is not a store-backed ABI gate.

`compute/apps/_lib/artifact_build_jail.sh` is a fixture-tested, host-side declared
Phoenix/package/pinned-binary adapter, used by build/store and the internal host-test harness. It
requires an unused builder IP, trusted base archive and digest, declared
package arguments, and for Phoenix transferred source plus inventory and trusted digest.
Only Phoenix inputs require OTP/runtime links; package/binary inputs use explicit
source/inventory `-` sentinels and the declared executable worker. The adapter
verifies the copied source tree before starting a temporary jail, runs
the Phoenix worker via `jexec -U builder`, records the jail's `pkg config abi`,
verifies output, removes the jail before publishing to a staging directory,
and preserves the root if jail removal or subsequent mount/IP/flag cleanup
cannot be confirmed. The first controlled FreeBSD attempt failed at `pkg`
bootstrap because the copied host resolver was loopback-only. The candidate
adapter now uses the operator-approved `1.1.1.1` only inside the disposable
jail (direct external DNS, not Tailscale) and explicitly unmounts devfs,
removes its lo1 alias and clears immutable base flags before deleting its
root. The second FreeBSD attempt installed packages and cleaned up fully,
but failed at `jexec sh`. The third also installed packages and cleaned up,
then failed at `jexec /bin/sh`; using an absolute path was not the remedy.
The fourth attempt proved static `/rescue/sh` can launch dynamic `/bin/sh`
both before and after packages, while direct `jexec /bin/sh` still failed.
Its cleanup was confirmed clean. The fifth attempt failed at direct
`jexec /rescue/sh` after packages, also cleaning up; the launch workaround
is not reliable. A fixture-tested guard now records the presence and modes
of `/bin/sh`, `/rescue/sh` and the ELF loader before and after package
installation. The sixth host run found all three present and executable
both times, yet direct `jexec /rescue/sh` failed again; cleanup was verified.
Later boundary markers isolated the failure to the unprivileged worker,
not the root-run shell probes. A separate network-disabled FreeBSD test
reproduced the exact ENOENT with the jail root at `0700` and passed at
`0755`, while its private parent stayed `0700`; the test reported cleanup
complete. FreeBSD libc hides directory-search EACCES as ENOENT when stat
also fails. The adapter now sets root `0755` before `jexec -U builder`, and
the fixture checks root and parent modes. This verifies worker shell launch,
not a complete candidate build; another build requires fresh approval.
The host pf baseline skips `lo1`, so this is not strong lateral jail isolation.

The shared `compute/apps/_lib/artifact_build_phoenix.sh` can run as an
unprivileged user inside a disposable FreeBSD build jail: it builds assets
and the release there, then emits an archive and checksum for `serai` to
collect. Actual FreeBSD provisioning, transfer integrity, ABI and dependency
resolution, and cleanup still require an approved disposable host test. The shared `compute/apps/_lib/artifact_install.sh` verifies a
release archive and places it in a versioned path under the jail's `/opt`.
It requires the host lock, refuses a conflicting identity, and deliberately
does not switch the active release or touch secrets. It is not called by
`deploy` yet. `serai artifact install <app> --identity <identity> --archive <tar>
--sha256 <digest>` stages the archive and installer under the compute host lock and
prepares a Phoenix release only; it does not start or switch the service.
The current `deploy`/`rollout` commands still use the old hooks.
The next cutover moves builds out of permanent jails, installs versioned
releases, and keeps data and runtime secrets outside them. A binary rollback
does not reverse a database migration.

### Other strategy workers (integration pending)

- `artifact_build_ocaml.sh` builds privately staged OCaml app or guest source against
  a caller-verified immutable opam repository snapshot. It creates a fresh
  private `OPAMROOT`, requires an exact compiler package, and uses an explicit
  switch through `opam exec`, never a global `opam env`/switch mutation. A
  guest's dune project is the one its `workload` declares. Outputs are an executable payload tar, its digest,
  observed package versions and runtime linkage. Neither worker installs,
  starts a service, runs migrations, or reads runtime configuration. Caller-side
  repository snapshots and guest transport are now wired into the controllers;
  complete materials/runtime-closure acceptance remains unproven. See the native
  OCaml/guest limits above before attempting an approved native test.
- `artifact_build_executable.sh` packages a checksum-pinned downloaded binary
  or a caller-verified package executable. It checks actual FreeBSD amd64 ELF
  bytes before archiving; a static binary does not need a successful `ldd`.
  A package's signed closure/runtime integration remains caller work.
- Manifests now represent package archive and pinned upstream binary inputs
  explicitly, without fabricated source commits. These use canonical v2;
  source-built v1 identities remain unchanged. This is input validation,
  not a substitute for trusted build/target provenance.

### Store-backed application and guest lifecycle

The following generic commands apply to managed-pointer layouts (`serai up`
uses the same upgrade). They remain separate from old hooks:

```sh
serai artifact upgrade hello --identity <verified-identity> --store /absolute/private/store
serai artifact rollback hello --identity <retained-previous-identity> --store /absolute/private/store
serai artifact convert logs --identity <byte-equivalent-identity> --store /absolute/private/store
# The same commands accept every app and guest; convert only executables
# (packages, pinned binaries and guests). A guest uses the guest
# lock/terminal root boundary described above.
```

These commands require confirmation (`--yes` for an approved noninteractive run).
They reverify the private store, workload and declared release, snapshot/hash the
helpers, and hold one compute host lock through target ABI probing, archive verification,
versioned installation, atomic pointer switch, service restart and bounded health
check. A mismatched ABI refuses before installation. Selecting the active identity
checks status/readiness without restarting or changing the previous pointer.
Rollback selects only the retained previous identity, not an arbitrary release.
Stop acknowledgement is followed by at most ten one-second stopped-status waits
before switching/conversion; timeout or unknown status retains the old pointer/code,
without force-kill.
Failed start/readiness leaves the selected and previous code available for explicit
rollback; it does not automatically reverse database migrations.

`convert` is deliberately strict: legacy public code must match the selected
artifact byte for byte, and only an executable converts (a Phoenix release
is refused). Runtime configuration, SQLite and operator-managed secrets remain
external and untouched. For a package or pinned binary, conversion requires a
root-owned, single-link executable matching the selected artifact, retains a
root-private binary backup/receipt and replaces only `/usr/local/bin/<binary>`
with the stable managed anchor. The rc name is the app's, which may differ from
its executable's.

A package app can declare a status-code readiness check: running rc status plus
an exact HTTP status from an unsigned GET of its endpoint, with six bounded
attempts. This checks process and endpoint responsiveness, not an authenticated
roundtrip, and reads no tokens. Other apps retain curl-success health semantics;
a shared snapshotted helper implements the HTTP policies.

An uncertain SSH outcome, interrupted operation, failed transfer or failed stage
cleanup retains the stage/compute host lock for inspection. Check the service and stage
before manually running `serai unlock compute` (the configured host ID); do not blindly retry or delete a stage
that may still have a writer. Known completed failures clean the stage and release
the lock. A separately approved fresh Phoenix public-CLI disposable compute host
test passed build/store/reuse, activation, upgrade, failed-health rollback and
legacy conversion. That is not renewed production authority: each live
deployment still requires approval. Package/pinned-binary lifecycle is locally
controller/CLI/real-archive fixture-tested, not native runtime/deployment proof.
OCaml/guest strategies are not yet connected; this is not native OCaml/guest proof.

## What changed, and why

**Config: filesystem duck-typing → `apps/<name>/app.sexp`.** The bash
`./ops` decided whether an app supports `deploy` by checking
`[ -x compute/apps/$app/deploy ]` at runtime. Each app's `app.sexp` says so up
front, as data, next to its jail IP, hostname, ports and strategy:

```lisp
(name hello)
(hooks (bootstrap check update-version))
```

`lib/app_config.ml` (`App_config`) parses this into a typed record per app —
an unknown hook name, an unknown or repeated field, or a non-integer port is
a parse error, not a silently-ignored typo.

The same declarations, combined with `guests/*/guest.sexp` and
`edge/edge.sexp`, feed `Caddy_render`, `Headscale_acl` and `Pf_rules`, which
render the Caddy vhosts, Headscale ACL and pf rules. `serai edge` renders
all three locally and installs them through their scripts' existing
validated modes -- see "Network edge" below.

**Orchestration: effect handlers for the one thing that talks to the
network.** Every function in `lib/dispatcher.ml` (`bootstrap`, `deploy`,
`check`, `edge`, ...) is ordinary direct-style OCaml — no monad,
no dependency-injected "executor" object threaded through every call. When
a function needs to actually run `ssh`/`rsync`/an app hook, it calls
`Proc.run_checked prog args`, which performs a `Proc.Run` effect. What that
effect *means* is decided entirely at the call site that installs the
handler:

- `Proc.live` (used by `bin/main.ml`) spawns the process with stdio
  inherited from the terminal — the same behavior as bash invoking
  `"$SSH_BIN" ...` directly, so you still see rsync progress and ssh
  prompts live.
- `Proc.Mock` (used by `test/test_dispatcher.ml`) records the command
  instead of running it, and hands back a scripted exit code.

That's the whole point of reaching for effects here: the bash test suite
for the retired `./ops` (`tests/test_ops.sh`) faked `ssh`/`rsync`/`curl` as shell scripts on
`$PATH` to keep tests offline — it worked, but the fakes lived in a different
language, at a process boundary, matched against argv by shell case
patterns. The OCaml version gets the same isolation from a `match_with`
around the entry point, with the recorded calls as a typed value in the
same process:

```ocaml
let mock = Proc.Mock.create () in
Proc.Mock.run mock (fun () -> Dispatcher.bootstrap env "hello");
Proc.Mock.calls mock
(* [ {prog="ssh"; args=["compute-test"; "set -eu\n..."]; extra_env=[]};
     {prog="rsync"; args=[...]; extra_env=[]};
     {prog="ssh"; args=["compute-test"; "doas sh .../bootstrap"]; extra_env=[]} ] *)
```

No fake binaries, no `$PATH` manipulation, no subprocess at all in the test
run — see `test/test_dispatcher.ml` for the full suite (naming validation,
per-hook support checks, the `/tmp` staging-path guard).

The remote staging safety check (`secure_remote_stage_script` in
`dispatcher.ml`) is kept as a verbatim POSIX sh string, not reimplemented in
OCaml — it has to run *on the remote box* being staged, so this is the one
place OCaml is just generating shell text, the same way the bash `./ops` did.

## Pipelines: a small DSL over the same effect

`rollout` isn't a hardcoded OCaml function any more — it's data, read from
`pipelines.sexp` and interpreted by `lib/pipeline.ml`:

```lisp
(default (
  (rollout      (sequence (prefer deploy bootstrap) check))
  (rollout-edge (sequence (prefer deploy bootstrap) edge check))
))
```

`prefer deploy bootstrap` means "run `deploy` if the app's `app.sexp`
supports it, else run `bootstrap`" — the same branch `rollout` always made,
now spelled out instead of buried in a function only the compiler can
extend. Every app gets `rollout`/`rollout-edge` for free from `default`; an
app only needs an entry under `(apps ...)` when it genuinely has something
extra, such as operator-invoked scripts beside its hooks:

```lisp
(apps (
  (hello (
    (assets
      (sequence (script sync-assets $COMPUTE_TARGET) (script seed-assets $COMPUTE_TARGET)))
  ))
))
```

run it with `serai run hello assets`.

Deliberately **not** folded in: app-private scripts that run via cron
*inside* a jail. They are not something the operator's machine ever invokes,
so they have no business in a pipeline that runs from here. The DSL only
reaches as far as the bash `./ops` reached.

The evaluator (`Pipeline.eval`) is `Dispatcher`'s own effectful functions
called under `List.iter`/pattern-match, so `test/test_pipeline.ml` gets the
same mock-based testing as `test_dispatcher.ml` for free — including that a
failing step stops a `sequence` before the next one runs, which is just
OCaml's ordinary exception propagation, not anything the DSL had to
implement.

Grammar (see the comment atop `lib/pipeline.ml` for the authoritative
version):

```
step := hook-name               ; bootstrap | deploy | check | update-version
      | edge
      | (sequence step ...)
      | (prefer hook-name step) ; hook-name if supported, else the fallback step
      | (script name arg ...)   ; run apps/<app>/<name>
arg  := $COMPUTE_TARGET | $EDGE_TARGET | <literal>
```

## Layout

```
serai/
  lib/layout.ml            the engine and configuration roots, and every path under them
  lib/proc.ml              the Run effect, live handler, mock handler
  lib/app_config.ml        sexp parsing for apps/<name>/app.sexp
  lib/strategy.ml          jail sh generation per app strategy
  lib/network_endpoint.ml  the shared endpoint type (name, ip, hostname, named ports)
  lib/sexp_fields.ml       shared (key value) field-list parsing
  lib/guest_config.ml      sexp parsing for guests/<name>/guest.sexp (endpoint, login user, source checkout)
  lib/edge_config.ml       sexp parsing for edge/edge.sexp (base_domain, operator)
  lib/headscale_acl.ml     Headscale ACL rendering
  lib/pf_rules.ml          compute host pf rule rendering
  lib/caddy_render.ml      fills the hand-written edge/caddy templates
  lib/dispatcher.ml        bootstrap/deploy/check/edge/update-version and the guest lifecycle
  lib/jail_test.ml         serai jail-test: test-jail rules and the destroy script
  lib/pipeline.ml          the DSL: step type, sexp parser, effectful evaluator
  bin/main.ml              CLI parsing + wires Proc.live around Dispatcher/Pipeline
  test/test_dispatcher.ml  effect-mocked unit tests, no network/subprocess
  test/test_pipeline.ml    DSL parsing, registry fallback, evaluation order
  test/fixtures/           fixture trees (e.g. a template edge_root) used by tests
  test/golden/             golden output files compared against rendered output;
                           golden/example/ is everything ../example renders
```

## Network edge

`serai edge` renders the Headscale ACL, the compute host pf rules and the edge host Caddy
config from `apps/*/app.sexp`, `guests/*/guest.sexp` and
`edge/edge.sexp`, entirely on this machine, and aborts before touching any
host if a render fails. It then installs each through its script's
existing validated mode: `PF_SOURCE` (`compute/01-pf-rules`), `POLICY_SOURCE`
(`edge/01-headscale-policy`) and `CADDY_SOURCE` (`edge/02-caddy`).

`serai edge --plan` stages the rendered files and has each script print a
diff of its live config against them, changing nothing. It exits 2 when
changes are pending, so it doubles as a drift check. `serai edge` runs the
same plan, asks before applying, and installs only the pieces that changed;
`--yes` skips the question. Declining exits 1, so in a `rollout-edge`
pipeline it stops the rollout before `check` runs.

Every `serai edge` and `serai edge --plan` run takes a per-host lock
(`<stage>/locks/infra`, compute then edge) so two runs cannot overwrite each
other's staged files; a run that finds the lock held names the holder and
waits for it, on the host and over the same ssh connection, for up to 30
minutes. An interrupted waiter never takes the lock afterwards. A lock left
by a killed run is reported stale after 30 minutes;
clear it with `serai unlock <compute|edge>`. `bootstrap` locks the compute host; the
guest commands lock the guest (`serai unlock <guest>`).

`serai edge` needs `jj`: it records the commit from
`coalesce(@ ~ empty(), @-)`, the working-copy commit when it has changes,
else its parent. After an apply in which every pending install succeeded,
each host it installed on records that commit in `/var/lib/infra/applied`
(commit, change id, whether it was pushed, when, by whom, what was
installed); a partially failed apply leaves no record. `edge` and
`edge --plan` print each host's last record before diffing. This is
provenance, not state: the live files are still what `--plan` diffs
against.

Each run opens several ssh connections per host, and each may need a
hardware-key touch. Connection sharing in `~/.ssh/config` for the `compute`
and `edge` hosts turns those into one touch per host:

```
Host compute edge
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 5m
```

(`ControlPath` is needed too: its default, `none`, turns sharing off.)

`serai rollout <app> --edge` runs the same edge between deploy (or
bootstrap) and check. Both need `jj` on `PATH` for the applied record. The
bash renderers are gone: `compute/01-pf-rules`, `edge/01-headscale-policy` and `edge/02-caddy` now
only install what serai rendered, and each fails without its `*_SOURCE`.

`serai edge` converges config only. `edge/02-caddy` runs only when its
config diff is pending, and its diff mode skips the build and module check
and ignores the systemd unit. So `serai edge` does not bootstrap Caddy on a
fresh edge host, rebuild the binary, apply unit changes or start a stopped
caddy. `serai caddy-install` does: under the edge lock it renders and
stages the Caddy tree and runs `edge/02-caddy` with `CADDY_SOURCE`
unconditionally, which builds the binary if it is missing or lacks
caddy-ratelimit (always, under `CADDY_FORCE_BUILD=1`), sets up the user
and directories, writes the unit, validates, installs and reloads. It asks
first; `--yes` skips the question. Use it for a first install, a binary
rebuild or a unit change. Under `serai edge`, `CADDY_FORCE_BUILD=1` reaches
the Caddy install only when the Caddy config itself changed.

`serai validate [--out <dir>]` renders the whole declaration offline (no
ssh, lock or jj) and fails on any parse or render error. With `--out` it
writes `acls.hujson`, `service-rules.conf`, `caddy/` and `jails/<app>.sh`
(one per app) to `<dir>`; `scripts/lint.sh` checks the first three. It also
loads `logging.sexp`, and `serai render-logging-targets` prints the
`<jail> <source>` list central logging's compute host installer (the `compute-logging`
pipeline step) forwards from. A source is `local_only` or a reviewed sender
the jail's app ships in `apps/<app>/logging/<source>/`: `sender.conf`
(the jail's syslog-ng sources), files under `etc/` and `libexec/` that it
installs into the jail, and an optional `preflight` run against the jail
root first. The engine names no app's logs. The compute host installer's syslog-ng
configs are rendered at install time from the declarations: every sender
forwards to the address and `syslog` tailnet port of the app `logging.sexp`
names as its `receiver`, and the host
relay listens on its host's `guest_bridge` for exactly the guests placed on
that host, and not at all when there are none.

Adding a service: declare it in `app.sexp` (or `guest.sexp` for a VM) with
named `tailnet_ports`, and if it is public, add a
`edge/caddy/sites/NN-<name>.caddy.template` that uses `__<NAME>_HOSTNAME__`,
`__<NAME>_IP__` and `__<NAME>_<PORT>_PORT__`. No script edits.

The sexp files are what serai renders the edge from. Until part C moves
the host-side jail, service, deploy and check scripts onto them, each
service's shell `config` still carries the same facts for those scripts:
`JAIL_IP` (a guest's `GUEST_IP`), `PORT`, a `<NAME>_PORT` per other named
port (e.g. a `VIDEO_PORT` or `S3_PORT`) and `PUBLIC_HOST` or
`PHX_HOST`, and a guest's `GUEST_USER` and `SOURCE_CHECKOUT` default.
`serai validate` sources every `apps/*/config` and `guests/*/config`
(with `SOURCE_CHECKOUT` unset) and fails if any of those disagrees with
the sexp's `ip`, ports, `hostname`, `login_user` or `source_checkout`, so
change both together. The engine's tests run on `example/`, and
`test_example_render` holds its whole render to `test/golden/example/`. A
configuration holds its own render to goldens the same way through the CLI:
`tests/test_config_render.sh` diffs `serai validate --out` against
`tests/golden/`, so any change to the output shows up as a diff to review.

## Configurable topology

`serai.sexp` is required. It separates physical host identity (`id`,
`os`, SSH alias and optional `via`) from jail/guest placement and the one edge's
`proxy` workload list. Guest `via`/`direct` describes transport, not containment.
The checked-in declaration preserves the current compute host/edge host deployment.

Each FreeBSD host declares its workload `network`: the `subnet` its jails and
guests share, its own `gateway` address on it, and, when it runs bhyve
guests, the `guest_bridge` address. Every jail's, guest's and build jail's
address must be a host address on its host's network other than those two,
and `jail-test --ip` and `artifact build --ip` are checked the same way.

App execution, artifact operations, SSH/rsync routes, locks, unlock and pipeline
placeholders resolve through this declaration. `serai unlock` takes a configured
host ID (`compute` or `edge` today), or a guest name. Guest-only operations lock
the guest, not its jump host. Edge operations lock participating hosts in stable
order and render/stage separate pf rules for each host's workloads. Proxy selection
controls Caddy fragments and edge service grants; operator access stays separate.

Duplicate/missing placements, unknown references, unsafe destinations, route
cycles and unsupported OS placements fail offline. Distinct hosts cannot declare
the same SSH destination; physical equivalence of different SSH aliases cannot be
inferred. Existing safety guards still refuse an empty policy or host ruleset.
Legacy deploy/check/extra-script hooks cannot express explicit jump chains and refuse
those routes before execution; artifact operations support them. Existing overlay
tags and native backends remain unchanged—this is not host/network provisioning.

`COMPUTE_TARGET` and `EDGE_TARGET` CLI environment overrides are refused. Their names
remain compatibility arguments inside hooks/pipelines, resolved from placement.
For alternate targets, edit the topology in a test checkout, not production.

## Bhyve guests

A guest (the example's ledger) is a Linux VM under bhyve, not a jail. Its `guest.sexp`
declares, next to its network fields, `login_user` (the account ssh reaches
it as, `[a-z_][a-z0-9_-]*`) and `source_checkout` (the checkout on this
machine that `build` pushes, relative to the repository root unless
absolute). `serai guests` lists them; `serai provision|build|deploy <guest>`
run the guest lifecycle:

- Every connection goes to `<login_user>@<ip>` using the explicit `via` route
  from `serai.sexp` (or no jump for `direct`), through a shared control socket (`-o ControlMaster=auto -o
  ControlPath=$OPS_CONTROL_PATH -o ControlPersist=60`, default path
  `${TMPDIR:-/tmp}/ops-ssh-%C`; `OPS_SSH_MULTIPLEX=0` drops the three
  options). The calls that run a guest script add `-t`, so `su` can prompt
  for the guest's root password.
- `provision`: the staging guard over the guest ssh (subtree
  `compute/guests`), `rsync -az --delete -e "ssh <opts> -J <compute>"` of
  `guests/<guest>` to `<stage>/compute/guests/` on the guest, then
  `su -c 'sh <stage>/compute/guests/<guest>/provision'`, then on the compute host
  `doas sysrc vm_list+=<guest>`, so vm-bhyve starts the guest at boot (`deploy`
  ends the same way). Not earlier: an uninstalled guest boots to an empty UEFI
  menu.
- `build`: the checkout (`SOURCE_CHECKOUT` overrides `source_checkout`) must
  exist or nothing runs. Stages as `provision` does, pushes the checkout
  with `--exclude _build/ --exclude .git/ --exclude .jj/` to `<guest>/` in
  the login user's home, then runs `sh <stage>/compute/guests/<guest>/build`
  unprivileged.
- `deploy`: `build`, then `su -c 'sh .../install'`, then
  `su -c 'sh .../provision'` (reusing the tree `build` staged), stopping at
  the first failure. Install restarts the service on the new binary with the
  config it has; provision then rewrites the config and restarts only if it
  changed. The other order could hand a new config section to the old
  binary, whose parser rejects unknown fields.
- Each command holds the guest's lock (`<stage>/locks/infra` on the guest)
  for its whole run. `serai deploy <name>` deploys a guest when `<name>` is
  a declared guest and an app otherwise.

`test/test_dispatcher.ml` holds the exact
argv of every guest call.

## Generated jail scripts

`lib/strategy.ml` renders each app's jail script from its `app.sexp`
(`serai validate --out` writes them to `jails/<app>.sh`, and lint
shellchecks them there). There is no hand-written jail script: `serai
bootstrap <app>` renders the script, stages it as `compute/apps/<app>/jail`
beside the app directory under the compute host lock, and runs the app's `bootstrap`
hook, which runs it.

`serai jail-test <app> --ip <addr>` tries the script on a throwaway jail,
`<app>test`, without touching the real one: use it before bootstrapping
after a change to a strategy, an `app.sexp` or an extra step. The address must be
a host address on the app's host `network`, other than its `gateway` and
`guest_bridge`, and not any declared app's or guest's ip. The script is rendered under the jail name `<app>test`,
so every host-side resource uses that name: the `jail.conf` block,
`/jails/<app>test`, the `jail_list` entry, every `jexec` target and, for an
app with a ZFS dataset, `zroot/<app>test`. Everything inside the jail (the
service user, `/opt/<app>`, `/etc/<app>`, the rc.d service) keeps the real
app name. Under the compute host lock, it stages the app directory and the rendered
script as `jail` to `<stage>/jail-test/<app>test/`. The same ssh that guards the stage also reads whether
`/jails/<app>test` exists and, if so, its `ip4.addr` in `jail.conf`. It
refuses an existing test jail at another ip (or with none), since the script
never rewrites an existing block; re-running at the same ip is allowed. It
prints what will be created, asks, then runs
`doas sh <stage>/jail-test/<app>test/jail`. `--yes` skips the question.

`serai jail-test <app> --destroy` removes the test jail. Under the compute host lock,
after asking, it stops the jail and refuses, changing nothing, if the jail
is still running or its `jail.conf` block is on one line. It then removes
its `jail.conf` block through a temp file and `mv` (the old file is kept as
`/etc/jail.conf.before-<app>test-destroy.<timestamp>`) and its `jail_list`
entry. For an app with a dataset it runs `zfs destroy -r zroot/<app>test`. It then removes
`/jails/<app>test` with `rm -rfx`, but refuses if anything is still mounted
under its resolved path. It refuses any jail name or dataset that does not
end in `test`, and any `<app>test` that is a declared app or guest. It
checks the name and dataset both in serai and in the script it runs on the
compute host.

Operator notes before the first run:

- Pick an ip no other test jail uses. The ip check covers only declared
  apps and guests, not other test jails.
- The test jail persists: it joins `jail_list` and autostarts on reboot,
  serving a fresh instance (an identity provider with an open first-admin
  page, a storage service on its real port). Destroy it promptly.
- Never copy a backup credential into a test jail, and never schedule its
  backup.
- Destroy the test jail before changing `--ip`.
- jail-test runs only the `jail` script, not the `bootstrap` hook.
- Check that its data directory has the same ownership and mode as in the
  real jail.
- For an app with a dataset, check `zfs list zroot/<app>test` and its
  mountpoint.
- After the first destroy, confirm that `sysrc jail_list` still lists the
  real jail.

Extra steps get `JAIL`, `JAIL_IP`, `JROOT` and `APP` on their own command
line; the script never exports them. An exported `JAIL` would reach every
later `jexec`, and FreeBSD's `service(8)` inside the jail reads it as its
`-j` option and fails with `jail "<app>test" not found`. A step that runs
anything through `jexec` unsets them and keeps them shell-local.

## Declaration boundaries and offline exports

`lib/` stays flat; each module has an explicit `.mli`. Endpoint and declaration
records are private, and the collection accepted by the network renderers is
abstract:

- `Network_endpoint.create` checks a single endpoint. IPs must be canonical
  dotted-decimal IPv4 host addresses, not CIDRs, IPv6 or shorthand. Names and
  port names follow the placeholder grammar; ports are in 1–65535 and unique
  within each access class. Hostnames and `Edge_config` base domains use ASCII
  DNS labels, without wildcards, trailing dots or configuration syntax.
- `Network_endpoint.validate_all` returns an abstract `validated` collection
  after checking name/IP uniqueness. ACL, pf and Caddy renderers accept this
  type, not arbitrary endpoint lists.
- `Declaration.create` combines validated app and guest declarations; its
  private record cannot be constructed with inconsistent endpoint lists.
- `App_config` stores `Strategy_config.t`, parsed once during loading. Unknown
  strategies, malformed strategy fields (including empty `packages`) and
  `extra_steps` entries that are not plain file names beside the script fail
  before dispatch; its record is private and `App_config.create` applies the
  same extra-step check. Jail rendering does not parse again.
- `Jail_test.retarget` rebuilds the app's endpoint through
  `Network_endpoint.create`, so a test ip passes the same IPv4 check as a
  declared one. `Jail_test.destroy_script` accepts only the abstract
  `destroy_target` that `validate_destroy_target` returns (a name, and any
  dataset, ending in `test`); the script still refuses both again in sh.

Smart constructors return named error variants. Sexplib conversion adapters
still raise `Of_sexp_error`; `Declaration.load` converts those input-boundary
exceptions to a result naming the offending file. This is not a wholesale
conversion of existing command failures and renderer diagnostics to typed errors.

`serai validate --out <dir>` accepts an absent or empty directory only. It
refuses nonempty directories, files and destination symlinks before writing
output, preserving existing files rather than leaving obsolete generated
vhosts alongside new ones. Use a fresh directory for each export. A write-time
I/O failure may leave partial output; inspect it and use a fresh destination
for the next attempt.

Subprocess environment overrides replace inherited keys; the last explicit
value wins, with exactly one entry per variable name.

## Build, run, test

Requires OCaml ≥ 5.1 (effect handlers, `Filename.temp_dir`), `dune`, `base`,
`sexplib`, `digestif` (SHA-256), and `ocamlfind` (for compiler-boundary tests) from opam:

```sh
opam install dune base sexplib digestif ocamlfind
```

```sh
./scripts/install.sh         # from the repository root
```

It builds, runs the tests (no ssh/rsync; see below), and only then installs
`serai` to `~/.local/bin`, and the engine's host
scripts to `~/.local/share/caravanserai` (`PREFIX=/usr/local` to change
that).

Then, from anywhere inside a configuration: it finds the configuration by
walking up to `serai.sexp`, and the engine in a checkout above it
(this repository) or else in the installed share:

```sh
serai apps
serai check hello                  # targets come from serai.sexp
serai run logs forwarding
serai edge --plan
```

The installed copy does not rebuild itself: re-run
`./scripts/install.sh` after pulling changes to `serai/`.
`dune exec serai -- …` from `serai/` always runs the current source instead.

The real-repo tests read `compute/` and `edge/`, which sit outside the dune
project, so the test stanza depends on `(universe)` and a plain `dune
runtest` re-runs every test each time. No `--force` needed.

Environment variables (`OPS_REMOTE_STAGE`, `SSH_BIN`, `RSYNC_BIN`, `CURL_BIN`, for `edge`
`EDGE_TS_IP`, `EDGE_PEER_MATCH`, `CADDY_FORCE_BUILD` and `JJ_BIN`, and for the
guest commands `SOURCE_CHECKOUT`, `OPS_CONTROL_PATH` and
`OPS_SSH_MULTIPLEX`). Every failure exits nonzero with a message on
stderr.

## Known gaps

- `test_dispatcher.ml` and `test_pipeline.ml` hold every command's argv
  through the mock handler, and the stage guard runs for real there;
  `tests/test_hooks.sh` holds the hooks serai runs. Nothing runs the
  compiled binary end to end against fake `ssh`/`rsync` on `$PATH`, as the
  retired `tests/test_ops.sh` did for `./ops`.
- The DSL has no way to fail loudly on a step that references a script file
  which doesn't exist until it actually runs — `(script typo-name ...)` in
  `pipelines.sexp` only surfaces as an `ENOENT` when that pipeline executes,
  not at load time the way an unknown hook name does.
