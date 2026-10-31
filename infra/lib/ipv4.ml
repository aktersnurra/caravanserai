type address = int
type subnet = { base : address; prefix : int }

let octet s =
  let length = String.length s in
  if length = 0 || length > 3 || (length > 1 && s.[0] = '0')
     || not (String.for_all (function '0' .. '9' -> true | _ -> false) s)
  then None
  else match int_of_string s with n when n <= 255 -> Some n | _ -> None

let address s =
  match List.map octet (String.split_on_char '.' s) with
  | [ Some a; Some b; Some c; Some d ] -> Some ((a lsl 24) lor (b lsl 16) lor (c lsl 8) lor d)
  | _ -> None

let to_string a =
  Printf.sprintf "%d.%d.%d.%d" ((a lsr 24) land 255) ((a lsr 16) land 255) ((a lsr 8) land 255) (a land 255)

let size subnet = 1 lsl (32 - subnet.prefix)

let subnet s =
  let invalid () = Error (Printf.sprintf "invalid subnet %S: a.b.c.d/8-30 with no host bits" s) in
  match String.split_on_char '/' s with
  | [ base; prefix ] -> (
      match address base, octet prefix with
      | Some base, Some prefix when prefix >= 8 && prefix <= 30 ->
          let subnet = { base; prefix } in
          if base land (size subnet - 1) = 0 then Ok subnet else invalid ()
      | _ -> invalid ())
  | _ -> invalid ()

let subnet_to_string subnet = Printf.sprintf "%s/%d" (to_string subnet.base) subnet.prefix

let is_host subnet a = a > subnet.base && a < subnet.base + size subnet - 1

let hosts subnet = Seq.init (size subnet - 2) (fun i -> subnet.base + 1 + i)
