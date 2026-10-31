open Serai

let failures = ref 0
let check name condition =
  Printf.printf "%s - %s\n%!" (if condition then "ok  " else "FAIL") name;
  if not condition then incr failures

let () =
  List.iter (fun name ->
    check ("domain round-trip: " ^ name)
      (match Domain_name.parse name with
       | Ok domain -> String.equal name (Domain_name.to_string domain)
       | Error _ -> false))
    [ "example.org"; "EXAMPLE.org"; "a"; "a-b.example"; "s3.example";
      String.make 63 'a' ^ ".example";
      String.concat "." [String.make 63 'a'; String.make 63 'b'; String.make 63 'c'; String.make 61 'd'] ];
  List.iter (fun name ->
    check ("domain refuses invalid input: " ^ String.escaped name)
      (match Domain_name.parse name with
       | Error (Domain_name.Invalid_domain_name value) -> String.equal value name
       | Ok _ -> false))
    [ ""; "example.org."; "*.example"; "a..b"; "a_b.example"; "-a.example";
      "a-.example"; "example\n.org"; "é.example"; "example.org {";
      String.make 64 'a' ^ ".example";
      String.concat "." [String.make 63 'a'; String.make 63 'b'; String.make 63 'c'; String.make 62 'd'] ];
  if !failures > 0 then exit 1
