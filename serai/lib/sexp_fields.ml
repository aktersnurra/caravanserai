(* The (key value) field-list shape every sexp config file here uses:
   app.sexp, guest.sexp, edge.sexp. Each field is its own pair rather than
   a positional record, so a missing field fails with its name. Unknown and
   repeated keys are errors too: a typo'd key would otherwise be silently
   ignored. [context] prefixes every error so it names the file kind. *)

let fields_of_sexp ~context ~known (sexp : Sexplib.Sexp.t) =
  match sexp with
  | List items ->
      List.fold_left
        (fun fields item ->
          let key, value =
            match item with
            | Sexplib.Sexp.List [ Atom key; value ] -> (key, value)
            | Sexplib.Sexp.List (Atom key :: rest) -> (key, Sexplib.Sexp.List rest)
            | sexp ->
                Sexplib.Conv.of_sexp_error
                  (context ^ ": expected (field value ...)") sexp
          in
          if not (List.mem key known) then
            Sexplib.Conv.of_sexp_error
              (Printf.sprintf "%s: unknown field %s" context key) item
          else if List.mem_assoc key fields then
            Sexplib.Conv.of_sexp_error
              (Printf.sprintf "%s: duplicate field %s" context key) item
          else (key, value) :: fields)
        [] items
      |> List.rev
  | sexp -> Sexplib.Conv.of_sexp_error (context ^ ": expected a list") sexp

let field ~context name fields =
  match List.assoc_opt name fields with
  | Some value -> value
  | None ->
      let sexp =
        Sexplib.Sexp.List
          (List.map (fun (k, v) -> Sexplib.Sexp.List [ Atom k; v ]) fields)
      in
      Sexplib.Conv.of_sexp_error
        (Printf.sprintf "%s: missing field %s" context name)
        sexp

let atom ~context = function
  | Sexplib.Sexp.Atom a -> a
  | sexp -> Sexplib.Conv.of_sexp_error (context ^ ": expected an atom") sexp

let list ~context of_item = function
  | Sexplib.Sexp.List items -> List.map of_item items
  | sexp -> Sexplib.Conv.of_sexp_error (context ^ ": expected a list") sexp
