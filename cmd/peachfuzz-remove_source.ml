let validate db source =
  let stmt = Sqlite3.prepare db "SELECT COUNT(*) FROM datamark_source WHERE name = ?" in
  Sqlite3.bind_text stmt 1 source |> ignore;

  let rc = Sqlite3.step stmt in
  if rc <> Sqlite3.Rc.ROW then (
    Sqlite3.finalize stmt |> ignore;
    failwith "Failed to execute query");

  let count = Sqlite3.column_int stmt 0 in
  Sqlite3.finalize stmt |> ignore;

  count == 0

let rem db source =
  let stmt = Sqlite3.prepare db "DELETE FROM datamark_source WHERE name = ?" in
  Sqlite3.bind_text stmt 1 source |> ignore;

  let rc = Sqlite3.step stmt in
  if rc <> Sqlite3.Rc.DONE then (
    Sqlite3.finalize stmt |> ignore;
    failwith "Failed to execute delete query");

  Printf.printf "Source '%s' removed from the database.\n" source;
  stmt

let rem_s3 db source =
  let stmt = Sqlite3.prepare db "DELETE FROM datamark_source_s3 WHERE source_name = ?" in
  Sqlite3.bind_text stmt 1 source |> ignore;

  let rc = Sqlite3.step stmt in
  if rc <> Sqlite3.Rc.DONE then (
    Sqlite3.finalize stmt |> ignore;
    failwith "Failed to execute delete query for S3");

  Printf.printf "S3 source '%s' removed from the database.\n" source;
  stmt

let doq_s3 db source =
  let stmt = Sqlite3.prepare db "SELECT bucket, medallion, pattern FROM datamark_source_s3 WHERE source_name = ?" in
  Sqlite3.bind_text stmt 1 source |> ignore;

  let rc = Sqlite3.step stmt in
  if rc <> Sqlite3.Rc.ROW then (
  Sqlite3.finalize stmt |> ignore;
  failwith "Failed to execute query");

  let bucket = Sqlite3.column_text stmt 0 in
  let medallion = Sqlite3.column_text stmt 1 in
  let pattern = Sqlite3.column_text stmt 2 in

  Printf.printf "\nBucket: %s\nMedallion: %s\nPattern: %s\n\n" bucket medallion pattern;
  [rem db source; rem_s3 db source]

let doq db source =
  let stmt = Sqlite3.prepare db "SELECT kind, description FROM datamark_source WHERE name = ?" in
  Sqlite3.bind_text stmt 1 source |> ignore;

  let rc = Sqlite3.step stmt in
  if rc <> Sqlite3.Rc.ROW then (
    Sqlite3.finalize stmt |> ignore;
    failwith "Failed to execute query");

  let kind = Sqlite3.column_text stmt 0 in
  let description = Sqlite3.column_text stmt 1 in
  Printf.printf "Name: %s\nKind: %s\nDescription: %s\n" source kind description;

  Sqlite3.finalize stmt |> ignore;

  Sqlite3.exec db "BEGIN" |> ignore;
  let stmts =
    match kind with
    | "3" -> doq_s3 db source;
    | _ -> (Printf.printf "No additional information for kind: %s\n" kind; exit 1)
  in
  Sqlite3.exec db "COMMIT" |> ignore;
  List.iter (fun stmt -> Sqlite3.finalize stmt |> ignore) stmts

let () =
  if Array.length Sys.argv <> 2 then (
    prerr_endline "Usage: peachfuzz-remove_source <source>"; exit 1);

  let source = Sys.argv.(1) in
  let db = Sqlite3.db_open ~mode:`NO_CREATE "data/peachfuzz.db" in
  if validate db source then (
    Printf.printf "No source named '%s' found in the database.\n" Sys.argv.(1); exit 1);

  doq db source |> ignore;

  Sqlite3.db_close db |> ignore
