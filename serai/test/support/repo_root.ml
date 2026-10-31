(* Tests run from serai/_build/default/test; they
   need the workspace root that holds compute/ and edge/. Walks upward to the
   first directory containing edge/01-headscale-policy. *)
let find () =
  let marker dir = Sys.file_exists (Filename.concat dir "edge/01-headscale-policy") in
  let rec go dir =
    if marker dir then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then failwith "Repo_root.find: no edge/01-headscale-policy above cwd"
      else go parent
  in
  go (Sys.getcwd ())

(* The example configuration on this engine: the engine tests read it. *)
let example () =
  let root = find () in
  Serai.Layout.v ~engine:root ~config:(Filename.concat root "example")
