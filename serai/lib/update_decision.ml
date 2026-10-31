type triage = Not_enrolled | Already_handled | Examine of string

let triage ~desired ~handled =
  match desired, handled with
  | None, _ -> Not_enrolled
  | Some desired, Some handled when desired = handled -> Already_handled
  | Some desired, _ -> Examine desired

type refusal =
  | Unsigned
  | Bad_signature of Source_mirror.signature_status
  | Key_not_allowed of string
  | No_deployed_record
  | Not_newer of { deployed : string }

type verdict = Current | Deploy | Refuse of refusal

let check_signature ~allowed = function
  | Source_mirror.Unsigned -> Error Unsigned
  | Signed { status = Good; key } when key <> "" && List.mem key allowed -> Ok ()
  | Signed { status = Good; key } -> Error (Key_not_allowed key)
  | Signed { status; _ } -> Error (Bad_signature status)

let examine ~desired ~deployed ~signature ~allowed ~descends =
  if deployed = Some desired then Current
  else
    match check_signature ~allowed signature, deployed with
    | Error refusal, _ -> Refuse refusal
    | Ok (), None -> Refuse No_deployed_record
    | Ok (), Some _ when descends -> Deploy
    | Ok (), Some deployed -> Refuse (Not_newer { deployed })

let should_revert ~step ~migrate ~active_is_desired =
  step = Dispatcher.Release && (not migrate) && active_is_desired

let should_report ~last ~current = last <> Some current

let short commit = if String.length commit > 12 then String.sub commit 0 12 else commit

let refusal_message = function
  | Unsigned -> "not signed"
  | Bad_signature status ->
      Printf.sprintf "signature %s"
        (match status with
         | Source_mirror.Good -> "good" | Bad -> "bad" | Unknown_key -> "by an unknown key"
         | Invalid -> "invalid")
  | Key_not_allowed key -> Printf.sprintf "signed by %s, which is not an allowed signer" key
  | No_deployed_record -> "the host has no source record; deploy it once with serai up"
  | Not_newer { deployed } -> Printf.sprintf "not newer than the deployed %s" (short deployed)
