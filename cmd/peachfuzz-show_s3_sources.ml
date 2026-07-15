let text = function Some value -> value | None -> ""
let () =
  let db = Sqlite3.db_open ~mode:`NO_CREATE "data/peachfuzz.db" in

  Printf.printf "%-29s %-17s %-10s %s\n" "Source" "Bucket" "Medallion" "Pattern";

  let rc = Sqlite3.exec db
    "SELECT
      source_name, bucket, medallion,
      CASE WHEN length(pattern) > 20 THEN substr(pattern, 1, 20) || '…'
      ELSE pattern END AS pattern
    FROM datamark_source_s3" ~cb:(fun row _h -> match row with
    | [| source; bucket; medallion; pattern |] ->
      Printf.printf "%-29s %-17s %-10s %s\n" (text source) (text bucket) (text medallion) (text pattern)
    | _ -> prerr_endline "Unexpected row"
    ) in if rc <> Sqlite3.Rc.DONE then
      prerr_endline ("Query failed: " ^ Sqlite3.Rc.to_string rc)
