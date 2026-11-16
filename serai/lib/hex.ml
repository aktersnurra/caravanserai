let is_lower value = String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value
let is_sha256 value = String.length value = 64 && is_lower value
let is_commit value = String.length value = 40 && is_lower value
let is_object_id value = (String.length value = 40 || String.length value = 64) && is_lower value
let short value = if String.length value > 12 then String.sub value 0 12 else value
