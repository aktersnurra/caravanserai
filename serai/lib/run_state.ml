type approval = Ask | Granted | Plan_only | Expect of Plan_id.t
type planned = { operation : string; id : Plan_id.t; question : string; facts : (string * string) list }
type retained = { host : string; stage : string; context : string }

exception Planned of planned

let approval = ref Ask
let changed = ref false
let kept = ref []

let cause = ref None
let steps = ref []
let hosts = ref []

let reset () = approval := Ask; changed := false; kept := []; cause := None; steps := []; hosts := []

let fail ~cause:code message = cause := Some (code, message); failwith message
let cause_of message = match !cause with Some (code, m) when m = message -> Some code | _ -> None
let ran step = steps := step :: !steps
let steps_ran () = List.rev !steps
let locked host = if not (List.mem host !hosts) then hosts := host :: !hosts
let hosts_locked () = List.rev !hosts

let with_approval mode f =
  let previous = !approval in
  approval := mode;
  Fun.protect ~finally:(fun () -> approval := previous) f

let changing () = changed := true
let has_changed () = !changed
let retain stage = kept := stage :: !kept
let retained () = List.rev !kept
