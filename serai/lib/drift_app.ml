type state = Current | Behind | Diverged | Not_deployed | Unknown

let state_to_string = function
  | Current -> "current"
  | Behind -> "behind"
  | Diverged -> "diverged"
  | Not_deployed -> "not_deployed"
  | Unknown -> "unknown"

let drifted = function Behind | Diverged | Not_deployed -> true | Current | Unknown -> false

type target = { revision : string; commit : string }

let target ~deploy ~default_branch =
  match deploy with
  | Some commit -> Ok { revision = "deploy"; commit }
  | None -> Result.map (fun (revision, commit) -> { revision; commit }) (Lazy.force default_branch)

let decide (probe : Release_probe.t) ~target ~descends =
  match probe.active, probe.source with
  | None, _ -> Ok Not_deployed
  | Some _, None -> Ok Unknown
  | Some _, Some live when live = target -> Ok Current
  | Some _, Some _ -> Result.map (fun descends -> if descends then Behind else Diverged) (descends ())
