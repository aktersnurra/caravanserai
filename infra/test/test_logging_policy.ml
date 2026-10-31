open Infra

let failures = ref 0
let check name cond =
  if cond then Printf.printf "ok - %s\n" name
  else (incr failures; Printf.printf "FAIL - %s\n" name)

(* The example's apps; counter ships a reviewed sender, as Layout finds it. *)
let apps = App_config.load_all (Layout.apps_dir (Repo_root.example ()))
let shipped = [ ("counter", "counter_service") ]
let reviewed ~jail ~source = List.mem (jail, source) shipped
let parse text = Logging_policy.parse ~apps ~reviewed (Sexplib.Sexp.of_string text)

let () =
  let policy = {|((receiver logs) (jails ((hello local_only) (counter counter_service))))|} in
  check "approved typed policy parses and renders in declared order"
    (match parse policy with
    | Ok policy ->
        Logging_policy.render_targets policy = "hello local_only\ncounter counter_service\n"
    | Error _ -> false);
  check "reviewed senders are listed for staging"
    (match parse policy with
     | Ok policy -> Logging_policy.reviewed policy = shipped
     | Error _ -> false);
  check "the receiver is the declared app"
    (match parse policy with
     | Ok policy -> Logging_policy.receiver policy = "logs"
     | Error _ -> false);
  check "any declared app can receive"
    (match parse {|((receiver hello) (jails ((counter counter_service))))|} with
     | Ok policy -> Logging_policy.receiver policy = "hello"
     | Error _ -> false);
  List.iter (fun (label, text, needle) ->
    check label
      (match parse text with
       | Ok _ -> false
       | Error message -> needle = "" || String.equal needle message))
    [ "duplicate jail refused", {|((receiver logs) (jails ((counter counter_service) (counter local_only))))|}, "";
      "unknown jail refused", {|((receiver logs) (jails ((future local_only))))|}, "";
      "receiver cannot forward itself", {|((receiver logs) (jails ((logs local_only))))|},
      "the receiver logs cannot forward itself";
      "another receiver cannot forward itself either", {|((receiver hello) (jails ((hello local_only))))|},
      "the receiver hello cannot forward itself";
      "a receiver that is not an app is refused", {|((receiver future) (jails ((hello local_only))))|},
      "undeclared logging receiver: future";
      "missing receiver refused", {|((jails ((hello local_only))))|}, "";
      "a sender the app does not ship is refused", {|((receiver logs) (jails ((hello hello_release))))|}, "";
      "another app's sender is refused", {|((receiver logs) (jails ((hello counter_service))))|}, "";
      "raw file path unsupported", {|((receiver logs) (jails ((hello /var/log/hello/hello.log))))|}, "";
      "unknown field refused", {|((receiver logs) (jails ((counter counter_service))) (all_jails yes))|}, "";
      "missing jail field refused", {|((receiver logs))|}, "";
      "malformed target refused", {|((receiver logs) (jails ((counter counter_service extra))))|}, "";
      "empty policy refused", {|((receiver logs) (jails ()))|}, "" ];
  check "the example policy's senders ship with their apps"
    (Logging_policy.reviewed (Logging_policy.load ~layout:(Repo_root.example ()) ~apps) = shipped);
  if !failures <> 0 then exit 1
