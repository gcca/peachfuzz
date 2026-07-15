type item = {
  bucket : string;
  medallion : string;
  pattern : string;
}

let parse_uri uri =
  if not (String.starts_with ~prefix:"s3://" uri) then (
    prerr_endline "Bad URI";
    exit 1
  );

  let path = String.sub uri 5 (String.length uri - 5) in
  match String.split_on_char '/' path with
  | bucket :: medallion :: rest ->
    { bucket; medallion; pattern = String.concat "/" rest }
  | _ -> failwith "invalid uri"

let add db name bucket medallion pattern =
  Sqlite3.exec db "BEGIN" |> ignore;

  let stmt_a = Sqlite3.prepare db "INSERT INTO datamark_source (name, kind, description) VALUES (?, 3, '')" in
  Sqlite3.bind_text stmt_a 1 name |> ignore;
  let rc = Sqlite3.step stmt_a in Sqlite3.finalize stmt_a |> ignore;
  if rc <> Sqlite3.Rc.DONE then (
    prerr_endline (Sqlite3.errmsg db);
    exit 1);

  let stmt_s = Sqlite3.prepare db "INSERT INTO datamark_source_s3 (source_name, bucket, medallion, pattern) VALUES (?, ?, ?, ?)" in
  Sqlite3.bind_text stmt_s 1 name |> ignore;
  Sqlite3.bind_text stmt_s 2 bucket |> ignore;
  Sqlite3.bind_text stmt_s 3 medallion |> ignore;
  Sqlite3.bind_text stmt_s 4 pattern |> ignore;
  let rc = Sqlite3.step stmt_s in Sqlite3.finalize stmt_s |> ignore;
  if rc <> Sqlite3.Rc.DONE then (
    prerr_endline (Sqlite3.errmsg db);
    exit 1);

  Sqlite3.exec db "COMMIT" |> ignore

let () =
  if Array.length Sys.argv <> 3 then (
    prerr_endline "Usage peachfuzz-add_s3_source <URI> <source-name> <description>"; exit 1);

  let {bucket; medallion; pattern} = parse_uri Sys.argv.(1) in
  let db = Sqlite3.db_open ~mode:`NO_CREATE "data/peachfuzz.db" in
  add db Sys.argv.(2) bucket medallion pattern;
  Sqlite3.db_close db |> ignore
