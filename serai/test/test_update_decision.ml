(* Update_decision: every judgement serai update makes, as pure functions
   over the facts the driver gathers. *)
open Serai
open Update_decision

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let desired = String.make 40 'd'
let older = String.make 40 'o'
let key = "2921DF701EE03394"
let allowed = [ key ]
let good = Source_mirror.Signed { status = Good; key }

let signatures =
  [ "unsigned", Source_mirror.Unsigned;
    "good, allowed", good;
    "good, another key", Source_mirror.Signed { status = Good; key = "0000000000000000" };
    "good, no key", Source_mirror.Signed { status = Good; key = "" };
    "bad", Source_mirror.Signed { status = Bad; key };
    "unknown key", Source_mirror.Signed { status = Unknown_key; key = "" };
    "invalid", Source_mirror.Signed { status = Invalid; key } ]

let () =
  (* triage: the cheap look before the host is touched. *)
  check "no deploy ref: not enrolled" (triage ~desired:None ~handled:(Some older) = Not_enrolled);
  check "the handled commit: skipped" (triage ~desired:(Some desired) ~handled:(Some desired) = Already_handled);
  check "a moved ref: examined" (triage ~desired:(Some desired) ~handled:(Some older) = Examine desired);
  check "never handled: examined" (triage ~desired:(Some desired) ~handled:None = Examine desired);

  (* check_signature: good, by an allowlisted key, or a refusal saying why. *)
  check "a good signature by an allowed key passes" (check_signature ~allowed good = Ok ());
  check "unsigned is refused" (check_signature ~allowed Source_mirror.Unsigned = Error Unsigned);
  check "another key is refused, naming it"
    (check_signature ~allowed (Source_mirror.Signed { status = Good; key = "0000000000000000" })
     = Error (Key_not_allowed "0000000000000000"));
  check "a good signature without a key never passes"
    (Result.is_error (check_signature ~allowed:("" :: allowed) (Source_mirror.Signed { status = Good; key = "" })));
  check "bad, unknown and invalid are refused with their status"
    (List.for_all (fun status ->
         check_signature ~allowed (Source_mirror.Signed { status; key }) = Error (Bad_signature status))
       [ Source_mirror.Bad; Unknown_key; Invalid ]);
  check "an empty allowlist passes nothing" (Result.is_error (check_signature ~allowed:[] good));

  (* examine over every combination of the facts. *)
  let cases =
    List.concat_map (fun deployed ->
        List.concat_map (fun (name, signature) ->
            List.map (fun descends -> deployed, name, signature, descends) [ true; false ])
          signatures)
      [ None; Some desired; Some older ] in
  let verdict (deployed, _, signature, descends) = examine ~desired ~deployed ~signature ~allowed ~descends in
  check "already deployed is current, whatever else holds"
    (List.for_all (fun ((deployed, _, _, _) as case) ->
         (verdict case = Current) = (deployed = Some desired)) cases);
  check "deploy only when signed by an allowed key and newer than a recorded release"
    (List.for_all (fun ((deployed, name, _, descends) as case) ->
         (verdict case = Deploy) = (deployed = Some older && name = "good, allowed" && descends)) cases);
  check "an untrusted signature is refused before anything about the host"
    (List.for_all (fun ((deployed, name, _, _) as case) ->
         deployed = Some desired || name = "good, allowed"
         || (match verdict case with Refuse (Unsigned | Bad_signature _ | Key_not_allowed _) -> true | _ -> false))
       cases);
  check "a trusted commit with no deployed record is refused: deploy once by hand"
    (examine ~desired ~deployed:None ~signature:good ~allowed ~descends:true = Refuse No_deployed_record);
  check "a trusted commit that is not newer is refused, naming what is deployed"
    (examine ~desired ~deployed:(Some older) ~signature:good ~allowed ~descends:false
     = Refuse (Not_newer { deployed = older }));
  check "an unsigned commit that is already deployed is current"
    (examine ~desired ~deployed:(Some desired) ~signature:Source_mirror.Unsigned ~allowed ~descends:false = Current);

  (* should_revert: only a release that failed after its switch, files only. *)
  let steps = Dispatcher.[ Jail; Build; Release; Edge; Check ] in
  check "revert only a failed release step, without migrate, with the new release active"
    (List.for_all (fun step ->
         List.for_all (fun migrate ->
             List.for_all (fun active_is_desired ->
                 should_revert ~step ~migrate ~active_is_desired
                 = (step = Dispatcher.Release && (not migrate) && active_is_desired))
               [ true; false ])
           [ true; false ])
       steps);

  (* should_report: a line goes out once, until it changes. *)
  check "a first line is reported" (should_report ~last:None ~current:"a");
  check "the same line again is not" (not (should_report ~last:(Some "a") ~current:"a"));
  check "a changed line is" (should_report ~last:(Some "a") ~current:"b");

  (* Refusals read as one line each. *)
  check "refusal lines name what to do"
    (List.for_all (fun (refusal, needle) ->
         let line = refusal_message refusal in
         let n = String.length needle in
         let rec has i = i + n <= String.length line && (String.sub line i n = needle || has (i + 1)) in
         has 0)
       [ Unsigned, "not signed";
         Key_not_allowed "ABCD", "ABCD";
         Bad_signature Source_mirror.Unknown_key, "unknown";
         No_deployed_record, "serai up";
         Not_newer { deployed = older }, String.sub older 0 12 ])
