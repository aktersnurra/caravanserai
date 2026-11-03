(* Plan_id: naming a plan so an apply can refuse any other; and the
   stale_plan refusal agents branch on. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let contains text needle =
  let n = String.length needle in
  let rec at i = i + n <= String.length text && (String.sub text i n = needle || at (i + 1)) in
  at 0

let id operation parts = Plan_id.to_string (Plan_id.make ~operation parts)

let () =
  let base = id "idp" [ "https://id.example.org"; "create"; "group"; "admins" ] in
  check "16 lowercase hex characters"
    (String.length base = 16
     && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) base);
  check "the same parts give the same id"
    (base = id "idp" [ "https://id.example.org"; "create"; "group"; "admins" ]);
  check "any one part changed changes it"
    (List.for_all (fun parts -> id "idp" parts <> base) [
        [ "https://id.example.net"; "create"; "group"; "admins" ];
        [ "https://id.example.org"; "update"; "group"; "admins" ];
        [ "https://id.example.org"; "create"; "user"; "admins" ];
        [ "https://id.example.org"; "create"; "group"; "family" ];
        [ "https://id.example.org"; "create"; "group" ];
        [ "https://id.example.org"; "create"; "group"; "admins"; "" ] ]);
  check "another operation's plan never has the same id"
    (id "up" [ "https://id.example.org"; "create"; "group"; "admins" ] <> base);
  check "parts are delimited: [ab; c] is not [a; bc]" (id "x" [ "ab"; "c" ] <> id "x" [ "a"; "bc" ]);
  check "an operation is delimited from its parts" (id "x" [ "yz" ] <> id "xy" [ "z" ]);
  check "no parts is an id too" (String.length (id "edge" []) = 16);

  check "parse takes what make gives"
    (match Plan_id.parse base with Ok t -> Plan_id.to_string t = base | Error _ -> false);
  check "parse compares equal to make"
    (Plan_id.parse base = Ok (Plan_id.make ~operation:"idp" [ "https://id.example.org"; "create"; "group"; "admins" ]));
  List.iter (fun (name, bad) ->
      check ("parse refuses " ^ name)
        (match Plan_id.parse bad with Error m -> contains m "plan id" | Ok _ -> false))
    [ ("an empty string", ""); ("15 characters", String.sub base 0 15); ("17 characters", base ^ "0");
      ("uppercase", String.uppercase_ascii (String.map (function '0' .. '9' -> 'a' | c -> c) base));
      ("non-hex", "g" ^ String.sub base 1 15); ("whitespace", " " ^ String.sub base 1 15) ];

  (* The refusal. *)
  let response = Agent_cli.respond ~operation:"idp.apply" (fun () ->
      raise (Agent_cli.Stale_plan "idp: stale plan: approved 0000000000000000, now 1111111111111111")) in
  let json = Agent_cli.to_json response in
  check "Stale_plan is refused with code stale_plan"
    (contains json {|"status":"refused"|} && contains json {|"code":"stale_plan"|}
     && contains json {|"operation":"idp.apply"|} && contains json {|"data":null|}
     && contains json "approved 0000000000000000");
  check "and exits 1" (Agent_cli.exit_code response = 1)
