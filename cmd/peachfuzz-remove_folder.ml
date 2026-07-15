let is_digits s =
  String.length s > 0
  && String.for_all (function '0' .. '9' -> true | _ -> false) s

let parent_str = function
  | None -> "NULL"
  | Some p -> string_of_int p

let resolve_by_key db key =
  let stmt =
    Sqlite3.prepare db
      "SELECT key, name, COALESCE(description, ''), parent, parent IS NULL \
       FROM pages_folder WHERE key = ?"
  in
  Sqlite3.bind_int stmt 1 key |> ignore;
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
      let key = Sqlite3.column_int stmt 0 in
      let name = Sqlite3.column_text stmt 1 in
      let description = Sqlite3.column_text stmt 2 in
      let parent =
        if Sqlite3.column_int stmt 4 <> 0 then None
        else Some (Sqlite3.column_int stmt 3)
      in
      Sqlite3.finalize stmt |> ignore;
      Some (key, name, description, parent)
  | Sqlite3.Rc.DONE ->
      Sqlite3.finalize stmt |> ignore;
      None
  | rc ->
      Sqlite3.finalize stmt |> ignore;
      prerr_endline ("Query failed: " ^ Sqlite3.Rc.to_string rc);
      exit 1

let resolve_by_name db name =
  let stmt =
    Sqlite3.prepare db
      "SELECT key, name, COALESCE(description, ''), parent, parent IS NULL \
       FROM pages_folder WHERE name = ? ORDER BY key"
  in
  Sqlite3.bind_text stmt 1 name |> ignore;
  let rec loop acc =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
        let key = Sqlite3.column_int stmt 0 in
        let name = Sqlite3.column_text stmt 1 in
        let description = Sqlite3.column_text stmt 2 in
        let parent =
          if Sqlite3.column_int stmt 4 <> 0 then None
          else Some (Sqlite3.column_int stmt 3)
        in
        loop ((key, name, description, parent) :: acc)
    | Sqlite3.Rc.DONE -> List.rev acc
    | rc ->
        Sqlite3.finalize stmt |> ignore;
        prerr_endline ("Query failed: " ^ Sqlite3.Rc.to_string rc);
        exit 1
  in
  let rows = loop [] in
  Sqlite3.finalize stmt |> ignore;
  rows

let subtree_counts db key =
  let sql =
    "WITH RECURSIVE subtree(key) AS ( \
       SELECT key FROM pages_folder WHERE key = ? \
       UNION ALL \
       SELECT f.key FROM pages_folder f \
       JOIN subtree s ON f.parent = s.key \
     ) \
     SELECT \
       (SELECT COUNT(*) FROM subtree), \
       (SELECT COUNT(*) FROM pages_view WHERE folder IN (SELECT key FROM subtree))"
  in
  let stmt = Sqlite3.prepare db sql in
  Sqlite3.bind_int stmt 1 key |> ignore;
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW ->
      let folders = Sqlite3.column_int stmt 0 in
      let views = Sqlite3.column_int stmt 1 in
      Sqlite3.finalize stmt |> ignore;
      (folders, views)
  | rc ->
      Sqlite3.finalize stmt |> ignore;
      prerr_endline ("Query failed: " ^ Sqlite3.Rc.to_string rc);
      exit 1

let delete_folder db key =
  let stmt = Sqlite3.prepare db "DELETE FROM pages_folder WHERE key = ?" in
  Sqlite3.bind_int stmt 1 key |> ignore;
  let rc = Sqlite3.step stmt in
  Sqlite3.finalize stmt |> ignore;
  if rc <> Sqlite3.Rc.DONE then (
    prerr_endline (Sqlite3.errmsg db);
    exit 1);
  if Sqlite3.changes db < 1 then (
    prerr_endline "DELETE affected 0 rows";
    exit 1)

let () =
  if Array.length Sys.argv <> 2 then (
    prerr_endline "Usage: peachfuzz-remove_folder <key|name>";
    exit 1);

  let arg = Sys.argv.(1) in
  let db = Sqlite3.db_open ~mode:`NO_CREATE "data/peachfuzz.db" in
  (match Sqlite3.exec db "PRAGMA foreign_keys = ON" with
  | Sqlite3.Rc.OK -> ()
  | rc ->
      prerr_endline ("PRAGMA foreign_keys failed: " ^ Sqlite3.Rc.to_string rc);
      exit 1);

  let key, name, description, parent =
    if is_digits arg then
      match resolve_by_key db (int_of_string arg) with
      | Some row -> row
      | None ->
          Printf.eprintf "No folder with key %s found.\n" arg;
          exit 1
    else
      match resolve_by_name db arg with
      | [] ->
          Printf.eprintf "No folder named '%s' found.\n" arg;
          exit 1
      | [ row ] -> row
      | rows ->
          Printf.eprintf "Ambiguous folder name '%s':\n" arg;
          List.iter
            (fun (k, n, _, _) -> Printf.eprintf "  key=%d name=%s\n" k n)
            rows;
          exit 1
  in

  let folder_count, view_count = subtree_counts db key in
  Printf.printf "Key: %d\nName: %s\nDescription: %s\nParent: %s\n"
    key name description (parent_str parent);
  Printf.printf "Will remove %d folder(s), %d view(s).\n" folder_count
    view_count;

  (match Sqlite3.exec db "BEGIN" with
  | Sqlite3.Rc.OK -> ()
  | rc ->
      prerr_endline ("BEGIN failed: " ^ Sqlite3.Rc.to_string rc);
      exit 1);
  (try delete_folder db key
   with exn ->
     Sqlite3.exec db "ROLLBACK" |> ignore;
     prerr_endline (Printexc.to_string exn);
     exit 1);
  (match Sqlite3.exec db "COMMIT" with
  | Sqlite3.Rc.OK -> ()
  | rc ->
      Sqlite3.exec db "ROLLBACK" |> ignore;
      prerr_endline ("COMMIT failed: " ^ Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db);
      exit 1);

  Printf.printf "Folder %d '%s' removed (%d folders, %d views).\n" key name
    folder_count view_count;
  Sqlite3.db_close db |> ignore
