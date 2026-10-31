open Serai

let failures = ref 0
let check name condition =
  Printf.printf "%s - %s\n%!" (if condition then "ok  " else "FAIL") name;
  if not condition then incr failures

let () =
  check "names in template order, skipping blanks and comments"
    (Env_template.names ~filled_by:Env_template.Operator
       "# header\nDATABASE_PATH=/var/db/app/app.db\n\n  # indented comment\nSECRET=REPLACE_ME\nLANG=C.UTF-8\n"
     = Ok [ "DATABASE_PATH"; "SECRET"; "LANG" ]);
  check "a commented-out assignment is not declared"
    (Env_template.names ~filled_by:Env_template.Operator "# OLD=1\nNEW=2" = Ok [ "NEW" ]);
  check "an empty template declares nothing" (Env_template.names ~filled_by:Env_template.Operator "" = Ok []);
  check "an empty value is still a declaration" (Env_template.names ~filled_by:Env_template.Operator "A=" = Ok [ "A" ]);
  List.iter
    (fun (label, text, line) ->
      check ("refused, naming only the line: " ^ label)
        (Env_template.names ~filled_by:Env_template.Operator text = Error (Env_template.Invalid_line line)))
    [ ("no assignment", "A=1\nnot an assignment\n", 2);
      ("lowercase name", "lower=1", 1);
      ("leading digit", "1A=1", 1);
      ("export prefix", "export A=1", 1);
      ("blank before the name", " A=1", 1);
      ("empty name", "=1", 1) ];
  List.iter
    (fun (label, text) ->
      check ("a placeholder nothing fills in is refused: " ^ label)
        (Env_template.names ~filled_by:Env_template.Operator text = Error (Env_template.Placeholder 2)))
    [ ("${NAME}", "A=1\nPHX_HOST=${PHX_HOST}"); ("in a path", "A=1\nDB=/var/db/${JAIL}/app.db");
      ("__NAME__", "A=1\nMEALS_DATABASE_PATH=__DB_PATH__"); ("inside a URL", "A=1\nURL=https://__PUBLIC_HOST__") ];
  check "a template the jail script renders keeps its placeholders"
    (Env_template.names ~filled_by:Env_template.Jail_script "A=1\nURL=https://__PUBLIC_HOST__" = Ok [ "A"; "URL" ]);
  check "literal underscores and dollars are values, not placeholders"
    (Env_template.names ~filled_by:Env_template.Operator "A=__init__\nB=a__b\nC=$HOME\nD=__x__\nE=REPLACE_ME" = Ok [ "A"; "B"; "C"; "D"; "E" ]);
  check "a name declared twice is refused"
    (Env_template.names ~filled_by:Env_template.Operator "A=1\nB=2\nA=3" = Error (Env_template.Duplicate "A"));
  check "errors never carry a value"
    (Env_template.error_message (Env_template.Invalid_line 4)
     = "env.template line 4: expected a comment or NAME=value");
  if !failures > 0 then exit 1
