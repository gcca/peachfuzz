open Ctypes

let duckdb_lib =
  let rec first = function
    | [] -> prerr_endline "cannot load libduckdb"; exit 1
    | name :: rest ->
      (try Dl.dlopen ~filename:name ~flags:[ Dl.RTLD_NOW ]
       with _ -> first rest)
  in
  first
    [ "libduckdb.dylib"; "libduckdb.so"; "/opt/homebrew/lib/libduckdb.dylib"; "/usr/local/lib/libduckdb.so" ]

let dk name typ = Foreign.foreign ~from:duckdb_lib name typ

let duckdb_open = dk "duckdb_open" (string @-> ptr (ptr void) @-> returning int)
let duckdb_connect = dk "duckdb_connect" (ptr void @-> ptr (ptr void) @-> returning int)
let duckdb_query = dk "duckdb_query" (ptr void @-> string @-> ptr void @-> returning int)
let duckdb_result_error = dk "duckdb_result_error" (ptr void @-> returning string_opt)
let duckdb_destroy_result = dk "duckdb_destroy_result" (ptr void @-> returning void)
let duckdb_disconnect = dk "duckdb_disconnect" (ptr (ptr void) @-> returning void)
let duckdb_close = dk "duckdb_close" (ptr (ptr void) @-> returning void)

let quote q s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b q;
  String.iter (fun ch -> if ch = q then Buffer.add_char b q; Buffer.add_char b ch) s;
  Buffer.add_char b q;
  Buffer.contents b

let ident = quote '"'
let str = quote '\''

let exec conn sql =
  let rp = to_voidp (allocate_n char ~count:64) in
  if duckdb_query conn sql rp <> 0 then begin
    let msg = match duckdb_result_error rp with Some m -> m | None -> "unknown error" in
    duckdb_destroy_result rp;
    Printf.eprintf "duckdb error: %s\n" msg;
    exit 1
  end;
  duckdb_destroy_result rp

let getenv_req name =
  match Sys.getenv_opt name with
  | Some v when v <> "" -> v
  | _ -> Printf.eprintf "%s must be set\n" name; exit 1

let () =
  if Array.length Sys.argv <> 2 then begin
    prerr_endline "Usage: peachfuzz-cor_s3_source <source-name>";
    exit 2
  end;
  let source = Sys.argv.(1) in

  let sdb = Sqlite3.db_open ~mode:`NO_CREATE "data/peachfuzz.db" in
  let stmt =
    Sqlite3.prepare sdb
      "SELECT bucket, medallion, pattern FROM datamark_source_s3 WHERE source_name = ?"
  in
  Sqlite3.bind_text stmt 1 source |> ignore;
  let bucket, medallion, pattern =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      (Sqlite3.column_text stmt 0, Sqlite3.column_text stmt 1, Sqlite3.column_text stmt 2)
    | _ -> Printf.eprintf "no S3 source named %s\n" source; exit 1
  in
  Sqlite3.finalize stmt |> ignore;
  Sqlite3.db_close sdb |> ignore;

  let url = Printf.sprintf "s3://%s/%s/%s" bucket medallion pattern in
  let key_id = getenv_req "AWS_ACCESS_KEY_ID" in
  let secret = getenv_req "AWS_SECRET_ACCESS_KEY" in
  let region =
    match Sys.getenv_opt "AWS_DEFAULT_REGION" with Some r when r <> "" -> r | _ -> "us-east-1"
  in

  let db_pp = allocate (ptr void) null in
  if duckdb_open "data/datamark.db" db_pp <> 0 then (prerr_endline "duckdb open failed"; exit 1);
  let db = !@db_pp in
  let conn_pp = allocate (ptr void) null in
  if duckdb_connect db conn_pp <> 0 then (prerr_endline "duckdb connect failed"; exit 1);
  let conn = !@conn_pp in

  exec conn "INSTALL httpfs";
  exec conn "LOAD httpfs";
  exec conn
    (Printf.sprintf
       "CREATE OR REPLACE SECRET s3_secret (TYPE S3, KEY_ID %s, SECRET %s, REGION %s)"
       (str key_id) (str secret) (str region));
  exec conn
    (Printf.sprintf "CREATE OR REPLACE TABLE %s AS FROM read_parquet(%s)" (ident source)
       (str url));

  duckdb_disconnect conn_pp;
  duckdb_close db_pp;
  Printf.printf "flushed: %s\n" source
