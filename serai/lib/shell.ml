(* Single-quotes [s] for POSIX sh, including embedded single quotes. Every
   remote command string built in OCaml goes through this. *)
let quote s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"
