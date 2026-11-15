let replace_all ~pattern ~with_ text =
  if pattern = "" then invalid_arg "Template.replace_all: empty pattern";
  let pattern_length = String.length pattern in
  let buffer = Buffer.create (String.length text) in
  let rec go i =
    if i > String.length text - pattern_length then
      Buffer.add_string buffer (String.sub text i (String.length text - i))
    else if String.sub text i pattern_length = pattern then begin
      Buffer.add_string buffer with_;
      go (i + pattern_length)
    end
    else begin
      Buffer.add_char buffer text.[i];
      go (i + 1)
    end
  in
  go 0;
  Buffer.contents buffer

let substitute ~placeholders text =
  List.fold_left (fun text (pattern, with_) -> replace_all ~pattern ~with_ text) text placeholders
