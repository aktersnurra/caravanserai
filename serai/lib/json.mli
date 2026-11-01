(** JSON as Pocket ID's admin API speaks it: parsing responses and printing
    request bodies. Not a general JSON library. *)

(** A number keeps its text until a decoder asks for an [int], so nothing is
    lost to floats. An object keeps its order and any repeated keys. *)
type t = Null | Bool of bool | Number of string | String of string
       | Array of t list | Object of (string * t) list

(** The whole input as one value. The error names the byte offset. *)
val parse : string -> (t, string) result

(** Compact. Escapes quotes, backslashes and control characters; other
    text, UTF-8 included, is written as it is. *)
val to_string : t -> string

(** {1 Decoding} Each returns an error naming what it expected. *)

(** The first value under [key], or [None]. An error unless an object. *)
val member : string -> t -> (t option, string) result
val string : t -> (string, string) result
val bool : t -> (bool, string) result

(** A number with no fraction or exponent that fits an [int]. *)
val int : t -> (int, string) result

(** Each item of an array, stopping at the first error. *)
val list : (t -> ('a, string) result) -> t -> ('a list, string) result
