# Agent-first infrastructure interface

The execution boundary is the existing deterministic `serai` CLI. The portable
procedure is the serai-operations skill a configuration carries in
`.agents/skills/`.
There is no MCP server, separate agent executor or implicit permission layer.

## Version 1: read-only results

```sh
serai inspect --json
serai validate --json
serai artifact plan hello --revision master --json
serai artifact plan logs --json
```

Exactly one JSON object is written to stdout. Optional `--progress=jsonl` emits
progress to stderr, never mixed into the result. Plain command output remains
unchanged. These operations read declarations and, for validation, public Caddy
templates. They do not invoke SSH, rsync, curl, jj, a builder or host mutation.

The envelope is:

```json
{"schema_version":1,"operation":"validate","status":"succeeded","data":{"apps":5,"guests":1,"rendered_files":[],"host_inspected":false},"error":null}
```

`rendered_files` in a real validation result contains generated relative paths;
validation renders in memory without writing them. The illustration omits them.

| Field | Contract |
| --- | --- |
| `schema_version` | Integer 1. Reject unsupported versions. |
| `operation` | `inspect`, `validate`, `artifact.plan`, or the refused requested operation. |
| `status` | `succeeded`, `refused`, `failed`, or `interrupted`. |
| `data` | Operation result on success; null otherwise. |
| `error` | Null on success; `{code, message}` otherwise. Branch on code, not message. |

Exit codes: 0 for success, 1 for refusal/failure, 130 for interruption. Require both
exit zero and `status=succeeded`. Consumers may tolerate additional fields but
must not treat unknown status values as success. Output transport failure can
prevent a result from being delivered; missing/invalid JSON is not success.

Stable error codes are `invalid_request`, `unsupported_operation`,
`input_unavailable`, `invalid_declaration`, `unknown_workload`, `invalid_plan`,
`render_failed`, `internal_error`, `interrupted`, `not_applied`,
`step_failed` and `stale_plan`.

### Inspect

`data.scope` is `declaration`; `host_inspected` is false. Hosts expose ID, OS,
configured SSH destination, optional jump-host ID and resolved jump chain.
Workloads expose kind, containing host ID, SSH route, declared IP/hostname,
proxy membership and mutation lock domain. These are configuration facts, not
observations of running services, held locks or reachable machines. The edge
host is identified separately. No runtime env file is read.

### Validate

Returns app/guest counts and the relative paths rendered successfully in memory.
It uses the same declaration and rendering validation as plain `serai validate`.
`--out` is deliberately unsupported with `--json`; plain `validate --out` remains
available for an explicitly requested local render.

### Artifact plan

Returns `kind=design_preview`, the topology-resolved target and declared origin.
Source origins carry `requested_revision`, not a claimed resolved commit.
Package origins carry unresolved package names. Pinned binaries carry their
configured version/hash, not proof of retrieval or packaging.

`artifact_identity` is null, `source_verified` and `host_inspected` are false,
and `authorized_to_apply` and `database_rollback` are false. The old preview's
cache-directory hint is intentionally not promoted into an immutable identity.
This is **not** a live apply plan, an approval token or a build receipt.

## Declaring and planning

```sh
serai new hello --kind phoenix --repo ~/projects/hello --json
serai up hello --revision master --plan --json
```

`new` (operation `new`) writes the app's declaration in the repository and
touches no host; `data` names the `app`, its `ip`, `port`, `hostname` and the
`files` written or edited, with `host_inspected` false. `up --plan` (operation
`up.plan`) fetches the source mirror and reads the compute host (the jail, the
addresses other jails hold, the env file's owner, never its contents), then
returns the `commit`, `jail.action` (`none`, `create`, or `refused` with a
`message`), `release.action` (`reuse` with an `identity`, or `build` with the
`builder_ip` and `base_sha256`), `public_url` and `plan_id` (see "Plan
binding"), with `host_inspected` true and `applied` false. Either refused or failed means nothing was written or changed:
`not_applied`, with the reason as the message.

## Deploying

```sh
serai up hello --revision master --yes --json --expect-plan <plan_id>
```

Operation `up`. It applies only with `--yes`, because there is no terminal
to ask in: without it the request is refused as unsupported, and `--yes` is
the operator's approval, never the agent's. It applies only the plan the
operator approved: `--expect-plan` is required, in this order after
`--yes`, and a plan that changed since is `stale_plan` (see "Plan
binding"). Everything the run prints goes
to stderr; stdout holds the one result. A refusal before anything changed
(the plan's checks, a held address, a jail without its env) is `not_applied`
with null data. Otherwise `data` holds the `app`, `commit`, `local_source`,
`outcome` and `steps`: `jail`, `build`, `release`, `edge` and `check` in
order, each `done`, `skipped`, `not_run` or `failed` with a `message`.

| `outcome` | Status | Meaning |
| --- | --- | --- |
| `deployed` | `succeeded` | `identity` is active and the public check passed. |
| `stopped_for_operator` | `succeeded` | The jail was created; `next` says how to write its env, then run `up` again. Nothing is deployed yet. |
| `failed` | `failed`, code `step_failed` | The failed step's message is the error; earlier steps stay done and later ones did not run. `next` is the command to run next. Nothing is undone automatically. |

## Updating

```sh
serai update --plan --json
serai update --json
```

These are operations `update.plan` and `update`. `update` applies without
`--yes`: its approval is the operator's signature on each commit it
deploys, checked against `update.sexp`, never the caller's. Everything a
run prints goes to stderr, and stdout holds the one result. If the settings
can't be read, the result is `not_applied` with null data.

`data.configuration` is one of:

- `{status: verified, commit}`
- `{status: refused, commit, message}`
- `{status: unavailable, message}`

Only `verified` examines apps. `data.apps` lists each source-built app as
`{app, outcome, ...}`:

| `outcome` | Fields | Meaning |
| --- | --- | --- |
| `not_enrolled` | | No `deploy` bookmark, or no declared source. |
| `built_on_controller` | | It declares a `web_bundle`, which only the controller builds. Its repository is not fetched; deploy it with `serai up`. |
| `already_handled` | `commit` | This `deploy` commit's outcome was final. Not looked at again. |
| `current` | `commit` | The host already runs it. |
| `would_deploy` | `commit` | `update.plan` only. |
| `deployed` | `commit`, `identity` | Active and the public check passed. |
| `refused` | `commit`, `message` | Signature, key, missing host record or not newer. Final. |
| `failed` | `commit`, `step`, `message`, `revert` | `revert.outcome` is `reverted`, `failed` or `not_attempted`, with a `message` for the last two. Final. |
| `not_applied` | `commit` (may be null), `message` | Nothing changed on the host. Tried again next run. |

`update.plan` adds `applied: false`; it takes no lock and writes no state.
`update` adds `ran` and `reported`:

- `ran` is false when another run held the lock, and the data then holds
  nothing else.
- `reported` holds the lines this run reported for the first time.

The status is `failed` with code `step_failed` when one of those lines is
a refusal or failure. `update.plan` fails the same way when the
configuration isn't verified.

## The identity provider

```sh
serai idp --plan --json
```

Operation `idp.plan`, read-only, with the key in `SERAI_IDP_API_KEY` (see
`serai/README.md`). It exits 2 when `data.pending` is true. Without
`idp.sexp`, without a usable key, or when Pocket ID refuses or is
unreachable, the result is `not_applied` with the reason. So is a plan
that would remove `(admin)` from the API key's owner or disable them, which
`serai idp` refuses to apply.

`data` holds:

- `pending`: whether there are actions. Undeclared resources alone are not.
- `plan_id`: the plan's id, or null when there are no actions.
- `actions`: in apply order, each `{action, kind, name, ...}`, where `kind`
  is `group`, `user`, `client` or `api` and `name` is its group name,
  username, client ID or audience:

| `action` | Fields | Meaning |
| --- | --- | --- |
| `create` | | Declared, not live. |
| `update` | `changes` | Each `{field}`, or `{field, added, removed}` for memberships, callback URLs, claims (`key=value`) and permission keys. |
| `set_cimd` | `permissions` | CIMD access for the API: the permission keys, or null for off. |
| `set_grant` | `client`, `user_delegated`, `client_credentials` | A client's access to the API: permission keys, or null for none. |
| `remove_grant` | `client` | A grant the declaration leaves out. |

- `undeclared`: each `{kind, name}` live and not declared. Reported only.
- `secrets_needed`: confidential clients the plan creates; each needs a
  secret made in the UI.

```sh
serai idp --yes --json --expect-plan <plan_id>
```

Operation `idp.apply`, applying only the approved plan. `data` holds
`completed` (the actions applied, as in `idp.plan`), `failed` (null, or
`{action, request, status, code, message}` with Pocket ID's status and
error code) and `secrets_needed`. A failure partway is `failed` with code
`step_failed` and the data; nothing is rolled back, and `idp.plan` shows
what remains.

## The edge

```sh
serai edge --plan --json
serai edge --yes --json --expect-plan <plan_id>
```

Operation `edge.plan` stages the rendered pf rules, Headscale policy and
Caddy tree on the hosts, under their locks, and diffs each against what is
live, changing nothing. The diffs go to stderr. `data` holds `pending`,
`plan_id` (null when nothing is pending) and `components`, each
`{component, host}` with `component` `pf`, `acl` or `caddy`, in apply
order. It exits 2 when pending.

Operation `edge` installs only the approved plan. `data` holds `applied`
(the components installed) and `failed` (null, or `{component, host,
message}`). A failure partway is `failed` with code `step_failed`; the
components before it stay installed and no applied record is written.
Every other `serai edge --json` form is `invalid_request`.

## Plan binding

An agent's plan and its apply are separate runs, and anything can change
between them: a moved bookmark, a change made in a UI, a host edited by
hand. So every plan has a `plan_id`, 16 lowercase hex characters, and a
JSON apply must name the id of the plan the operator approved:

1. Run the plan (`up ... --plan --json`, `edge --plan --json`,
   `idp --plan --json`) and show it to the operator with its `plan_id`.
2. On approval, apply with `--expect-plan <plan_id>`.
3. The apply plans again and, before changing anything, compares. Any other
   plan, or nothing left to do, is refused: status `refused`, code
   `stale_plan`, exit 1, nothing changed. Plan again and have the new plan
   approved; never apply it on the old approval.

What an id covers: for `up`, the app, compute host, source, commit, local or
pushed, release (reused identity, or builder and base), jail action,
rehearsal and public URL; for `edge`, each pending component's name, host
and exact diff; for `idp`, the server and each action with the record it
sends, its changes and the live record it targets. `edge` compares under
the hosts' locks, on what it just staged; `up` compares where it plans,
before the prompt. Without `--expect-plan`, or with a malformed id, a JSON
apply is `invalid_request` before the repository is loaded. Plain-text
runs print `plan <id>` after the plan and take `--expect-plan` optionally.

## Mutation boundary remains explicit

JSON result mode refuses every other operation, including an `up` without
`--yes` and any JSON apply without `--expect-plan`, **before repository
loading or remote work**. `update` is the one
exception, because its authority is the signed commit, as above. `--yes`,
extra arguments and duplicate `--json` are not silently accepted by the
supported read-only requests. Do not automatically remove a
rejected flag and retry a mutating command.

This read-only request contract is **not a security sandbox**: it does not revoke
shell/SSH credentials or prevent calling non-JSON operations. Tool and host
permissions remain separate controls; procedural approval guidance is not access
control.

The JSON applies (`up`, `edge`, `idp`) are each bound to an approved plan
id, as above. Further structured outcomes and reconciliation will be
attached to verified lifecycle operations, not implemented as a wrapper
that treats every caught exception as safe to retry. The procedural skill does
not grant authority or replace enforcement. A Phoenix app's rc-pointer upgrade now has
a fixture-tested `--expect-current <active-identity>` precondition under its host
lock. It is not yet a JSON mutation API or native proof. Roll-forward is the
default; polished rollback is deferred, and database recovery stays separate.
Native OCaml/guest acceptance and obsolete-hook retirement remain unfinished. Native and production actions retain their explicit
approval requirements.

## Evidence handoff

Keep reviews short and auditable with four fields; these are reporting guidance,
not a new JSON schema or authorization mechanism:

| Field | Include |
| --- | --- |
| Declared fact | Workload, target/lock domain and requested identity or revision; distinguish declarations from observed state. |
| Command result | Exact command, exit code, JSON schema/status when available, and receipt/log path. |
| Tested boundary | Fixture, native diagnostic, full native lifecycle or production check; identity/precondition, lock and failure behavior actually exercised. |
| Remaining gap | What was not tested, retained/uncertain resources, and the next action requiring approval. |

For example, a builder permission fixture passing is not evidence that opam
completed a native build; a successful plan is still only a design preview.
Record why a rejected fix failed when that fact prevents repeating it. Encode
repeated, stable stack assumptions in tested CLI/native preconditions rather than
adding a generic execution framework or expanding the skill indefinitely.
