(* Json: parsing Pocket ID's responses and printing request bodies. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let parses text expected = Json.parse text = Ok expected

let error_mentions text fragment =
  match Json.parse text with
  | Ok _ -> false
  | Error message ->
      let n = String.length fragment and m = String.length message in
      let rec at i = i + n <= m && (String.sub message i n = fragment || at (i + 1)) in
      at 0

let () =
  let open Json in
  (* Scalars. *)
  check "null" (parses "null" Null);
  check "true and false" (parses "true" (Bool true) && parses "false" (Bool false));
  check "a number stays its text" (parses "1440" (Number "1440"));
  check "a negative, fractional, exponent number"
    (parses "-1.5e+3" (Number "-1.5e+3") && parses "0" (Number "0") && parses "2E-2" (Number "2E-2"));
  check "a string" (parses {|"hello"|} (String "hello"));

  (* Escapes. *)
  check "simple escapes"
    (parses {|"a\"b\\c\/d\b\f\n\r\t"|} (String "a\"b\\c/d\b\012\n\r\t"));
  check "a \\u escape decodes to UTF-8" (parses {|"å"|} (String "\xc3\xa5"));
  check "a surrogate pair decodes to one code point"
    (parses {|"😀"|} (String "\xf0\x9f\x98\x80"));
  check "raw UTF-8 passes through" (parses "\"\xc3\xa5\"" (String "\xc3\xa5"));
  check "a lone high surrogate is refused" (Result.is_error (parse {|"\ud83d"|}));
  check "a lone low surrogate is refused" (Result.is_error (parse {|"\ude00x"|}));
  check "an unknown escape is refused" (Result.is_error (parse {|"\x"|}));
  check "a raw control character is refused" (Result.is_error (parse "\"a\nb\""));

  (* Structure. *)
  check "nesting and whitespace"
    (parses " { \"a\" : [ 1 , { \"b\" : null } ] ,\n\t\"c\" : \"d\" } "
       (Object [ ("a", Array [ Number "1"; Object [ ("b", Null) ] ]); ("c", String "d") ]));
  check "empty array and object" (parses "[]" (Array []) && parses "{}" (Object []));
  check "objects keep order and duplicate keys"
    (parses {|{"b":1,"a":2,"b":3}|} (Object [ ("b", Number "1"); ("a", Number "2"); ("b", Number "3") ]));

  (* Errors name where they are. *)
  check "truncated input names its offset" (error_mentions {|{"a": [1, 2|} "offset 11");
  check "trailing garbage is refused" (error_mentions "true x" "offset 5");
  check "a trailing comma is refused" (Result.is_error (parse "[1,]"));
  check "a leading zero is refused" (Result.is_error (parse "01"));
  check "empty input is refused" (Result.is_error (parse ""));
  check "deep nesting is refused, not a stack overflow"
    (Result.is_error (parse (String.make 100_000 '[')));

  (* Printing. *)
  check "printing is compact"
    (to_string (Object [ ("a", Array [ Number "1"; Bool true; Null ]); ("b", String "x") ])
     = {|{"a":[1,true,null],"b":"x"}|});
  check "printing escapes quotes, backslashes and control characters"
    (to_string (String "a\"b\\c\n\001") = {|"a\"b\\c\n\u0001"|});
  check "printing keeps UTF-8 as it is" (to_string (String "\xc3\xa5") = "\"\xc3\xa5\"");
  let values =
    [ Null; Bool false; Number "-0.5"; String "tab\there \xf0\x9f\x98\x80 \"q\"";
      Array [ Object [ ("k", Array []) ]; Object [] ];
      Object [ ("dup", Number "1"); ("dup", Number "2"); ("", String "") ] ] in
  check "print then parse gives the value back"
    (List.for_all (fun value -> parse (to_string value) = Ok value) values);

  (* Accessors. *)
  let obj = Object [ ("n", Number "30"); ("s", String "x"); ("b", Bool true);
                     ("l", Array [ String "p"; String "q" ]); ("n", Number "99") ] in
  check "member takes the first match" (member "n" obj = Ok (Some (Number "30")));
  check "member of a missing key is None" (member "zz" obj = Ok None);
  check "member of a non-object is an error" (Result.is_error (member "a" (Array [])));
  check "string, bool, int" (string (String "x") = Ok "x" && bool (Bool true) = Ok true
                             && int (Number "30") = Ok 30 && int (Number "-4") = Ok (-4));
  check "int refuses a fraction or exponent"
    (Result.is_error (int (Number "1.5")) && Result.is_error (int (Number "1e3")));
  check "a mistyped value is an error" (Result.is_error (string (Number "1")) && Result.is_error (bool Null));
  check "list decodes each item" (list string (Array [ String "p"; String "q" ]) = Ok [ "p"; "q" ]);
  check "list stops at the first bad item" (Result.is_error (list string (Array [ String "p"; Null ])));

  (* A Pocket ID client list page, from v2.19.1's DTOs. *)
  let page = {|{"data":[{"id":"hello","name":"Hello","description":"","hasLogo":false,
    "hasDarkLogo":false,"launchURL":null,"requiresReauthentication":false,"clientType":"public",
    "callbackURLs":["https://hello.example.org/auth/callback"],"logoutCallbackURLs":[],
    "backchannelLogoutURL":"","isPublic":true,"pkceEnabled":true,
    "requiresPushedAuthorizationRequests":false,"skipConsent":false,
    "credentials":{"secrets":[]},"isGroupRestricted":true,
    "accessTokenDurationMinutes":60,"refreshTokenDurationMinutes":43200}],
    "pagination":{"totalPages":1,"totalItems":1,"currentPage":1,"itemsPerPage":100}}|} in
  check "a client list page parses"
    (match parse page with
     | Ok json ->
         (match member "data" json with
          | Ok (Some (Array [ client ])) ->
              member "id" client = Ok (Some (String "hello"))
              && member "accessTokenDurationMinutes" client = Ok (Some (Number "60"))
          | _ -> false)
     | Error _ -> false)
