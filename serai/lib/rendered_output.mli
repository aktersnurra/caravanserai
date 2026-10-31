type error =
  | Destination_not_empty of string
  | Destination_not_directory of string
  | Io_error of string

(** Writes into an absent or empty directory. A nonempty destination, regular
    file or destination symlink is refused before writing any output.
    Paths are relative paths produced by Validation.render_all. *)
val write : dir:string -> (string * string) list -> (unit, error) result
val error_message : error -> string
