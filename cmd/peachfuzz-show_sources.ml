let text = function Some value -> value | None -> ""

let print_row row =
  match row with
  | [| name; kind; description |] ->
      Printf.printf "%-29s %-7s %s\n" (text name) (text kind) (text description)
  | _ -> prerr_endline "Unexpected row"

let () =
  let db = Sqlite3.db_open ~mode:`NO_CREATE "data/peachfuzz.db" in
  let rc =
    Printf.printf "%-29s %-7s %s\n" "NAME" "KIND" "DESCRIPTION";
    Sqlite3.exec db
      "SELECT name,
              CASE WHEN kind = 0 THEN 'storage'
                   WHEN kind = 1 THEN 'github'
                   WHEN kind = 2 THEN 'drive'
                   WHEN kind = 3 THEN 's3'
                   ELSE NULL END AS kind,
              CASE WHEN length(description) > 40 THEN substr(description, 1, 40) || '…'
                   ELSE description END AS description
       FROM datamark_source
       ORDER BY name"
      ~cb:(fun row _headers -> print_row row) in
  if rc <> Sqlite3.Rc.OK then prerr_endline (Sqlite3.errmsg db);
  Sqlite3.db_close db |> ignore;
