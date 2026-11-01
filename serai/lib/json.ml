type t = Null | Bool of bool | Number of string | String of string
       | Array of t list | Object of (string * t) list

exception Parse_error of int * string

(* Deeper than any Pocket ID response; bounds the recursion. *)
let max_depth = 512

let parse text =
  let length = String.length text in
  let fail at what = raise (Parse_error (at, what)) in
  let rec skip_space i =
    if i < length && (match text.[i] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false)
    then skip_space (i + 1) else i in
  let expect_literal i word value =
    let n = String.length word in
    if i + n <= length && String.sub text i n = word then (value, i + n)
    else fail i ("expected " ^ word) in
  let is_digit c = c >= '0' && c <= '9' in
  let digits i =
    let rec go j = if j < length && is_digit text.[j] then go (j + 1) else j in
    let j = go i in
    if j = i then fail i "expected a digit" else j in
  let number i =
    let j = if i < length && text.[i] = '-' then i + 1 else i in
    let j =
      if j < length && text.[j] = '0' then j + 1
      else if j < length && is_digit text.[j] then digits j
      else fail j "expected a digit" in
    let j = if j < length && text.[j] = '.' then digits (j + 1) else j in
    let j =
      if j < length && (text.[j] = 'e' || text.[j] = 'E') then
        let k = j + 1 in
        let k = if k < length && (text.[k] = '+' || text.[k] = '-') then k + 1 else k in
        digits k
      else j in
    (Number (String.sub text i (j - i)), j) in
  let hex4 i =
    if i + 4 > length then fail i "expected four hex digits";
    match int_of_string_opt ("0x" ^ String.sub text i 4) with
    | Some code when String.for_all
                       (function '0'..'9' | 'a'..'f' | 'A'..'F' -> true | _ -> false)
                       (String.sub text i 4) -> code
    | _ -> fail i "expected four hex digits" in
  let string_body i =
    let buffer = Buffer.create 16 in
    let rec go i =
      if i >= length then fail i "unterminated string"
      else
        match text.[i] with
        | '"' -> (Buffer.contents buffer, i + 1)
        | '\\' ->
            if i + 1 >= length then fail (i + 1) "unterminated string";
            (match text.[i + 1] with
             | '"' -> Buffer.add_char buffer '"'; go (i + 2)
             | '\\' -> Buffer.add_char buffer '\\'; go (i + 2)
             | '/' -> Buffer.add_char buffer '/'; go (i + 2)
             | 'b' -> Buffer.add_char buffer '\b'; go (i + 2)
             | 'f' -> Buffer.add_char buffer '\012'; go (i + 2)
             | 'n' -> Buffer.add_char buffer '\n'; go (i + 2)
             | 'r' -> Buffer.add_char buffer '\r'; go (i + 2)
             | 't' -> Buffer.add_char buffer '\t'; go (i + 2)
             | 'u' ->
                 let code = hex4 (i + 2) in
                 if code >= 0xD800 && code <= 0xDBFF then begin
                   let j = i + 6 in
                   if j + 1 < length && text.[j] = '\\' && text.[j + 1] = 'u' then
                     let low = hex4 (j + 2) in
                     if low >= 0xDC00 && low <= 0xDFFF then begin
                       let point = 0x10000 + ((code - 0xD800) lsl 10) + (low - 0xDC00) in
                       Buffer.add_utf_8_uchar buffer (Uchar.of_int point);
                       go (j + 6)
                     end else fail j "a high surrogate not followed by a low one"
                   else fail j "a high surrogate not followed by a low one"
                 end
                 else if code >= 0xDC00 && code <= 0xDFFF then fail i "a lone low surrogate"
                 else begin
                   Buffer.add_utf_8_uchar buffer (Uchar.of_int code);
                   go (i + 6)
                 end
             | _ -> fail i "an unknown escape")
        | c when Char.code c < 0x20 -> fail i "a control character in a string"
        | c -> Buffer.add_char buffer c; go (i + 1) in
    go i in
  let rec value depth i =
    if depth > max_depth then fail i "nested too deeply";
    let i = skip_space i in
    if i >= length then fail i "unexpected end of input"
    else
      match text.[i] with
      | 'n' -> expect_literal i "null" Null
      | 't' -> expect_literal i "true" (Bool true)
      | 'f' -> expect_literal i "false" (Bool false)
      | '"' -> let s, j = string_body (i + 1) in (String s, j)
      | '[' -> array (depth + 1) (i + 1)
      | '{' -> obj (depth + 1) (i + 1)
      | '-' | '0'..'9' -> number i
      | _ -> fail i "unexpected character"
  and array depth i =
    let i = skip_space i in
    if i < length && text.[i] = ']' then (Array [], i + 1)
    else
      let rec items acc i =
        let item, j = value depth i in
        let j = skip_space j in
        if j >= length then fail j "unexpected end of input"
        else match text.[j] with
          | ',' -> items (item :: acc) (j + 1)
          | ']' -> (Array (List.rev (item :: acc)), j + 1)
          | _ -> fail j "expected , or ]" in
      items [] i
  and obj depth i =
    let i = skip_space i in
    if i < length && text.[i] = '}' then (Object [], i + 1)
    else
      let rec fields acc i =
        let i = skip_space i in
        if i >= length then fail i "unexpected end of input";
        if text.[i] <> '"' then fail i "expected a key";
        let key, j = string_body (i + 1) in
        let j = skip_space j in
        if j >= length then fail j "unexpected end of input";
        if text.[j] <> ':' then fail j "expected :";
        let item, k = value depth (j + 1) in
        let k = skip_space k in
        if k >= length then fail k "unexpected end of input"
        else match text.[k] with
          | ',' -> fields ((key, item) :: acc) (k + 1)
          | '}' -> (Object (List.rev ((key, item) :: acc)), k + 1)
          | _ -> fail k "expected , or }" in
      fields [] i in
  match value 0 0 with
  | result, i ->
      let i = skip_space i in
      if i = length then Ok result
      else Error (Printf.sprintf "Json: trailing input at offset %d" i)
  | exception Parse_error (at, what) -> Error (Printf.sprintf "Json: %s at offset %d" what at)

let escape buffer s =
  Buffer.add_char buffer '"';
  String.iter (function
    | '"' -> Buffer.add_string buffer "\\\""
    | '\\' -> Buffer.add_string buffer "\\\\"
    | '\n' -> Buffer.add_string buffer "\\n"
    | '\r' -> Buffer.add_string buffer "\\r"
    | '\t' -> Buffer.add_string buffer "\\t"
    | '\b' -> Buffer.add_string buffer "\\b"
    | '\012' -> Buffer.add_string buffer "\\f"
    | c when Char.code c < 0x20 -> Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buffer c) s;
  Buffer.add_char buffer '"'

let to_string value =
  let buffer = Buffer.create 256 in
  let rec go = function
    | Null -> Buffer.add_string buffer "null"
    | Bool b -> Buffer.add_string buffer (if b then "true" else "false")
    | Number n -> Buffer.add_string buffer n
    | String s -> escape buffer s
    | Array items ->
        Buffer.add_char buffer '[';
        List.iteri (fun i item -> if i > 0 then Buffer.add_char buffer ','; go item) items;
        Buffer.add_char buffer ']'
    | Object fields ->
        Buffer.add_char buffer '{';
        List.iteri (fun i (key, item) ->
            if i > 0 then Buffer.add_char buffer ',';
            escape buffer key; Buffer.add_char buffer ':'; go item) fields;
        Buffer.add_char buffer '}' in
  go value;
  Buffer.contents buffer

let kind = function
  | Null -> "null" | Bool _ -> "a boolean" | Number _ -> "a number" | String _ -> "a string"
  | Array _ -> "an array" | Object _ -> "an object"

let mistyped expected value = Error (Printf.sprintf "expected %s, got %s" expected (kind value))

let member key = function
  | Object fields -> Ok (List.assoc_opt key fields)
  | value -> mistyped "an object" value

let string = function String s -> Ok s | value -> mistyped "a string" value
let bool = function Bool b -> Ok b | value -> mistyped "a boolean" value

let int = function
  | Number n as value ->
      let integral =
        n <> "" && n <> "-"
        && String.for_all (function '0'..'9' -> true | _ -> false)
             (if n.[0] = '-' then String.sub n 1 (String.length n - 1) else n) in
      (match integral, int_of_string_opt n with
       | true, Some i -> Ok i
       | _ -> mistyped "an integer" value)
  | value -> mistyped "an integer" value

let list decode = function
  | Array items ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest -> (match decode item with Ok v -> go (v :: acc) rest | Error _ as e -> e) in
      go [] items
  | value -> mistyped "an array" value
