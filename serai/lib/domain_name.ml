open Base

type t = string
type error = Invalid_domain_name of string

let parse value =
  let is_alphanumeric c = Char.is_alpha c || Char.is_digit c in
  let is_label label =
    let length = String.length label in
    length > 0 && length <= 63
    && is_alphanumeric label.[0] && is_alphanumeric label.[length - 1]
    && String.for_all label ~f:(fun c -> is_alphanumeric c || Char.equal c '-')
  in
  if String.length value <= 253 && List.for_all (String.split value ~on:'.') ~f:is_label
  then Ok value else Error (Invalid_domain_name value)

let to_string value = value
let error_message (Invalid_domain_name value) = Printf.sprintf "invalid domain name %S" value
