type t = string

let version = "plan-v1"

let make ~operation parts =
  let buffer = Buffer.create 256 in
  List.iter (fun part ->
      Buffer.add_string buffer (string_of_int (String.length part));
      Buffer.add_char buffer ':';
      Buffer.add_string buffer part)
    (operation :: version :: parts);
  String.sub (Digest.BLAKE256.to_hex (Digest.BLAKE256.string (Buffer.contents buffer))) 0 16

let parse text =
  if String.length text = 16 && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) text
  then Ok text
  else Error (Printf.sprintf "%S is not a plan id: 16 lowercase hex characters, as --plan prints them" text)

let to_string t = t
