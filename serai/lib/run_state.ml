type approval = Ask | Granted | Plan_only | Expect of Plan_id.t
type planned = { operation : string; id : Plan_id.t; question : string; facts : (string * string) list }
type retained = { host : string; stage : string; context : string }

exception Planned of planned

let approval = ref Ask
let changed = ref false
let kept = ref []

let reset () = approval := Ask; changed := false; kept := []

let with_approval mode f =
  let previous = !approval in
  approval := mode;
  Fun.protect ~finally:(fun () -> approval := previous) f

let changing () = changed := true
let has_changed () = !changed
let retain stage = kept := stage :: !kept
let retained () = List.rev !kept
