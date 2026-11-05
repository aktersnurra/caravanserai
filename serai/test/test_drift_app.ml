(* Drift_app: an app's drift state from what the host runs and what its
   repository says should run. Pure: the host and the mirror are answers. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let live = String.make 40 'a'
let target = String.make 40 'b'
let identity = String.make 64 'c'
let release ?source active : Release_probe.t = { active; source; previous = None }

let decide ?(descends = Ok true) probe =
  let asked = ref false in
  let state = Drift_app.decide probe ~target ~descends:(fun () -> asked := true; descends) in
  state, !asked

let () =
  check "no active release: not deployed, ancestry not asked"
    (decide (release None) = (Ok Drift_app.Not_deployed, false));
  check "an active release without a source record: unknown, ancestry not asked"
    (decide (release (Some identity)) = (Ok Drift_app.Unknown, false));
  check "the live commit is the target: current, ancestry not asked"
    (Drift_app.decide (release ~source:target (Some identity)) ~target
       ~descends:(fun () -> failwith "asked") = Ok Drift_app.Current);
  check "the target descends from the live commit: behind"
    (decide ~descends:(Ok true) (release ~source:live (Some identity)) = (Ok Drift_app.Behind, true));
  check "the target does not descend from it: diverged"
    (decide ~descends:(Ok false) (release ~source:live (Some identity)) = (Ok Drift_app.Diverged, true));
  check "an ancestry error is the error, not a state"
    (decide ~descends:(Error "jj failed") (release ~source:live (Some identity)) = (Error "jj failed", true))

let () =
  let names = List.map Drift_app.state_to_string
      Drift_app.[ Current; Behind; Diverged; Not_deployed; Unknown ] in
  check "state names as the JSON spells them"
    (names = [ "current"; "behind"; "diverged"; "not_deployed"; "unknown" ]);
  check "drifted: behind, diverged and not deployed only"
    (List.filter Drift_app.drifted Drift_app.[ Current; Behind; Diverged; Not_deployed; Unknown ]
     = Drift_app.[ Behind; Diverged; Not_deployed ])

let () =
  let default_branch = lazy (Ok ("master", target)) in
  check "target: the deploy bookmark when there is one, without the default branch"
    (Drift_app.target ~deploy:(Some live) ~default_branch:(lazy (failwith "resolved"))
     = Ok { Drift_app.revision = "deploy"; commit = live });
  check "target: otherwise the default branch, named"
    (Drift_app.target ~deploy:None ~default_branch = Ok { Drift_app.revision = "master"; commit = target });
  check "target: a default branch that can't be found is the error"
    (Drift_app.target ~deploy:None ~default_branch:(lazy (Error "none recorded")) = Error "none recorded")
