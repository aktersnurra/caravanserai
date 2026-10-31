val held_exit : int
val stale_exit : int
val stale_after_seconds : int
val no_record_marker : string
val lock_dir : stage:string -> string

(* Takes the lock, waiting up to [wait_seconds] while another run holds it.
   Exits [held_exit] if it is still held then or the caller is gone, and
   [stale_exit] for a lock older than [stale_after_seconds]. *)
val acquire_script :
  stage:string -> token:string -> holder:string -> record:string -> wait_seconds:int -> string
val release_script : stage:string -> token:string -> string
val unlock_script : stage:string -> string
