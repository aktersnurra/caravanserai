(* Jail_probe.check against what the compute host answered to its script on
   2026-10-26 (meals live, hello not yet created; logs is a jail infra does
   not declare), and variations of it. *)
open Infra

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let jails = {|jail-probe-running: board 10.40.0.3
jail-probe-running: garage 10.40.0.4
jail-probe-running: idp 10.40.0.5
jail-probe-running: logs 10.40.0.20
jail-probe-running: meals 10.40.0.6
jail-probe-running: drill 10.40.0.2
jail-probe-configured: drill 10.40.0.2
jail-probe-configured: garage 10.40.0.4
jail-probe-configured: idp 10.40.0.5
jail-probe-configured: meals 10.40.0.6
jail-probe-configured: board 10.40.0.3
jail-probe-configured: logs 10.40.0.20
|}

let meals = "jail-probe-root: present\n" ^ jails ^ "jail-test-env: root:meals:640\n"
let hello = "jail-probe-root: absent\n" ^ jails ^ "jail-test-env: absent\n"

let error_with needle = function
  | Error message ->
      let n = String.length needle and h = String.length message in
      let rec go i = i + n <= h && (String.sub message i n = needle || go (i + 1)) in
      go 0
  | Ok _ -> false

let () =
  check "a live jail at its address with its env is ready"
    (Jail_probe.check ~app:"meals" ~ip:"10.40.0.6" meals = Ok (Jail_probe.Present (Ok ())));
  check "a new app at a free address is absent"
    (Jail_probe.check ~app:"hello" ~ip:"10.40.0.7" hello = Ok Jail_probe.Absent);
  check "an address an undeclared jail holds is refused, naming it"
    (error_with "held by jail logs" (Jail_probe.check ~app:"hello" ~ip:"10.40.0.20" hello));
  check "a live jail at another address is refused"
    (error_with "is at 10.40.0.6, not the declared 10.40.0.9" (Jail_probe.check ~app:"meals" ~ip:"10.40.0.9" meals));
  check "a live jail without its env says how to put it in place"
    (match Jail_probe.check ~app:"meals" ~ip:"10.40.0.6"
             ("jail-probe-root: present\n" ^ jails ^ "jail-test-env: absent\n") with
     | Ok (Jail_probe.Present (Error message)) ->
         error_with "/jails/meals/etc/meals/env" (Error message)
     | _ -> false);
  check "a jail.conf block without its root is refused"
    (error_with "/jails/meals is missing"
       (Jail_probe.check ~app:"meals" ~ip:"10.40.0.6" ("jail-probe-root: absent\n" ^ jails)));
  check "an unclear answer is refused"
    (error_with "could not tell" (Jail_probe.check ~app:"hello" ~ip:"10.40.0.7" "garbage\n"))

let () = if !failures > 0 then exit 1
