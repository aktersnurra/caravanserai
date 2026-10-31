type app = { handled : string option; reported : string option }
type t = { config_reported : string option; apps : (string * app) list }

let empty = { config_reported = None; apps = [] }
let no_record = { handled = None; reported = None }
let find t name = Option.value (List.assoc_opt name t.apps) ~default:no_record
let set t name app = { t with apps = (name, app) :: List.remove_assoc name t.apps |> List.sort compare }
let retain t ~apps = { t with apps = List.filter (fun (name, _) -> List.mem name apps) t.apps }

open Sexplib

let context = "update state"
let optional name = function None -> [] | Some value -> [ Sexp.List [ Atom name; Atom value ] ]

let to_string t =
  let app (name, { handled; reported }) =
    Sexp.List [ Atom name; Sexp.List (optional "handled" handled @ optional "reported" reported) ] in
  Sexp.to_string_hum
    (Sexp.List (optional "config_reported" t.config_reported
                @ [ Sexp.List [ Atom "apps"; Sexp.List (List.map app t.apps) ] ]))
  ^ "\n"

let is_commit value =
  String.length value = 40 && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let of_sexp sexp =
  let atom = Sexp_fields.atom ~context in
  let fields = Sexp_fields.fields_of_sexp ~context ~known:[ "config_reported"; "apps" ] sexp in
  let app = function
    | Sexp.List [ Atom name; record ] when name <> "" ->
        let fields = Sexp_fields.fields_of_sexp ~context ~known:[ "handled"; "reported" ] record in
        let handled = Option.map atom (List.assoc_opt "handled" fields) in
        (match handled with
         | Some commit when not (is_commit commit) ->
             Conv.of_sexp_error (context ^ ": handled must be a full commit id") record
         | _ -> ());
        name, { handled; reported = Option.map atom (List.assoc_opt "reported" fields) }
    | sexp -> Conv.of_sexp_error (context ^ ": expected (app (fields ...))") sexp in
  let apps = Sexp_fields.list ~context app (Sexp_fields.field ~context "apps" fields) in
  if List.length (List.sort_uniq compare (List.map fst apps)) <> List.length apps then
    Conv.of_sexp_error (context ^ ": an app is recorded twice") sexp;
  { config_reported = Option.map atom (List.assoc_opt "config_reported" fields);
    apps = List.sort compare apps }

let of_string text =
  match of_sexp (Sexp.of_string text) with
  | t -> Ok t
  | exception Conv.Of_sexp_error (exn, _) -> Error (Printexc.to_string exn)
  | exception Failure message -> Error (context ^ ": " ^ message)
  | exception Parsing.Parse_error -> Error (context ^ ": unreadable")

let ( let* ) = Result.bind

(* Missing directories are created private; an existing one must be this
   user's and closed to everyone else, as the store and caches are. *)
let rec private_directory path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; st_uid; st_perm; _ } when st_uid = Unix.geteuid () && st_perm land 0o077 = 0 ->
      Ok ()
  | _ -> Error (Printf.sprintf "%s: %s must be a private directory" context path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      let parent = Filename.dirname path in
      let* () =
        if parent = path || Sys.file_exists parent then Ok () else private_directory parent in
      Unix.mkdir path 0o700;
      Ok ()

let state_file dir = Filename.concat dir "state.sexp"

let load ~dir =
  let* () = private_directory dir in
  match In_channel.with_open_bin (state_file dir) In_channel.input_all with
  | text -> Result.map_error (fun message -> Printf.sprintf "%s (%s)" message (state_file dir)) (of_string text)
  | exception Sys_error _ when not (Sys.file_exists (state_file dir)) -> Ok empty
  | exception Sys_error message -> Error (context ^ ": " ^ message)

let save ~dir t =
  let* () = private_directory dir in
  let temporary = state_file dir ^ ".tmp" in
  match
    let fd = Unix.openfile temporary [ O_WRONLY; O_CREAT; O_TRUNC ] 0o600 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let text = to_string t in
      ignore (Unix.write_substring fd text 0 (String.length text)));
    Unix.rename temporary (state_file dir)
  with
  | () -> Ok ()
  | exception Unix.Unix_error (error, _, _) ->
      Error (Printf.sprintf "%s: writing %s: %s" context (state_file dir) (Unix.error_message error))

let with_run_lock ~dir f =
  match private_directory dir with
  | Error message -> failwith message
  | Ok () ->
      let fd = Unix.openfile (Filename.concat dir "lock") [ O_RDWR; O_CREAT ] 0o600 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        match Unix.lockf fd F_TLOCK 0 with
        | () -> Some (f ())
        | exception Unix.Unix_error ((EAGAIN | EACCES), _, _) -> None)
