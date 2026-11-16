(* Single-quotes [s] for POSIX sh, including embedded single quotes. Every
   remote command string built in OCaml goes through this. *)
(* The answers a remote probe printed: the rest of each line of [output]
   that starts with [marker], in order. *)
let answers ~marker output =
  String.split_on_char '\n' output
  |> List.filter_map (fun line ->
         if String.starts_with ~prefix:marker line then
           Some (String.sub line (String.length marker) (String.length line - String.length marker))
         else None)

let quote s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"
