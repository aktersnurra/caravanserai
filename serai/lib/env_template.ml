type error = Invalid_line of int | Placeholder of int | Duplicate of string
type filled_by = Operator | Jail_script

let error_message = function
  | Invalid_line line ->
      Printf.sprintf "env.template line %d: expected a comment or NAME=value" line
  | Placeholder line ->
      Printf.sprintf
        "env.template line %d: nothing fills in ${...} or __NAME__; use a literal value or REPLACE_ME" line
  | Duplicate name -> Printf.sprintf "env.template declares %s twice" name

let is_name name =
  name <> ""
  && String.for_all (function 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false) name
  && not (match name.[0] with '0' .. '9' -> true | _ -> false)

(* ${ anywhere, or __ followed by an uppercase name and __. *)
let has_placeholder value =
  let n = String.length value in
  let rec closing i = i + 1 < n && (if value.[i] = '_' && value.[i + 1] = '_' then true
                                    else match value.[i] with
                                      | 'A' .. 'Z' | '0' .. '9' | '_' -> closing (i + 1)
                                      | _ -> false) in
  let rec scan i =
    i + 1 < n
    && ((value.[i] = '$' && value.[i + 1] = '{')
        || (value.[i] = '_' && value.[i + 1] = '_' && i + 2 < n
            && (match value.[i + 2] with 'A' .. 'Z' -> closing (i + 3) | _ -> false))
        || scan (i + 1)) in
  scan 0

let names ~filled_by text =
  let ( let* ) = Result.bind in
  let rec go line acc = function
    | [] -> Ok (List.rev acc)
    | raw :: rest ->
        let trimmed = String.trim raw in
        if trimmed = "" || trimmed.[0] = '#' then go (line + 1) acc rest
        else
          let* name =
            match String.index_opt raw '=' with
            | Some i when is_name (String.sub raw 0 i) ->
                if filled_by = Operator
                   && has_placeholder (String.sub raw (i + 1) (String.length raw - i - 1))
                then Error (Placeholder line) else Ok (String.sub raw 0 i)
            | _ -> Error (Invalid_line line) in
          if List.mem name acc then Error (Duplicate name)
          else go (line + 1) (name :: acc) rest in
  go 1 [] (String.split_on_char '\n' text)
