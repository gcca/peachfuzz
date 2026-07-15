type folder = {
  key : int;
  fname : string;
  fdescription : string;
  parent : int option;
}

type view = {
  vname : string;
  title : string;
  vdescription : string;
  engine : int;
  vfolder : int option;
}

let engine_name = function
  | 0 -> "native"
  | 1 -> "chai"
  | 2 -> "eta"
  | 3 -> "python"
  | 4 -> "nodejs"
  | 5 -> "lua"
  | 6 -> "xa6"
  | id -> Printf.sprintf "engine:%d" id

let rows db sql of_stmt =
  let stmt = Sqlite3.prepare db sql in
  let rec loop acc =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> loop (of_stmt stmt :: acc)
    | Sqlite3.Rc.DONE -> List.rev acc
    | rc ->
        Sqlite3.finalize stmt |> ignore;
        failwith ("Query failed: " ^ Sqlite3.Rc.to_string rc)
  in
  let result = loop [] in
  Sqlite3.finalize stmt |> ignore;
  result

let optional_int stmt value_index null_index =
  if Sqlite3.column_int stmt null_index <> 0 then None
  else Some (Sqlite3.column_int stmt value_index)

let folders db =
  rows db
    "SELECT key, name,
            CASE WHEN length(description) > 40 THEN substr(description, 1, 40) || '…'
                 ELSE COALESCE(description, '') END AS description,
            COALESCE(parent, 0), parent IS NULL
     FROM pages_folder
     ORDER BY name, key"
    (fun stmt ->
      {
        key = Sqlite3.column_int stmt 0;
        fname = Sqlite3.column_text stmt 1;
        fdescription = Sqlite3.column_text stmt 2;
        parent = optional_int stmt 3 4;
      })

let views db =
  rows db
    "SELECT name, title,
            CASE WHEN length(description) > 40 THEN substr(description, 1, 40) || '…'
                 ELSE COALESCE(description, '') END AS description,
            engine, COALESCE(folder, 0), folder IS NULL
     FROM pages_view
     ORDER BY title, name"
    (fun stmt ->
      {
        vname = Sqlite3.column_text stmt 0;
        title = Sqlite3.column_text stmt 1;
        vdescription = Sqlite3.column_text stmt 2;
        engine = Sqlite3.column_int stmt 3;
        vfolder = optional_int stmt 4 5;
      })

let usage = "Usage: peachfuzz-tree [-d|--description]"

let show_description =
  let flagged = ref false in
  Array.iteri
    (fun index arg ->
      if index > 0 then
        match arg with
        | "-d" | "--description" -> flagged := true
        | _ ->
            prerr_endline usage;
            exit 1)
    Sys.argv;
  !flagged

let comment description =
  if (not show_description) || description = "" then "" else " · " ^ description

let branch last = if last then "└── " else "├── "
let indent last = if last then "    " else "│   "

let () =
  let db = Sqlite3.db_open ~mode:`NO_CREATE "data/peachfuzz.db" in
  let folders = folders db in
  let views = views db in

  let seen_folders = Hashtbl.create 16 in
  let seen_views = Hashtbl.create 16 in

  let print_view line_prefix view =
    Hashtbl.replace seen_views view.vname ();
    Printf.printf "%s%s (%s)  %s%s\n" line_prefix view.vname
      (engine_name view.engine) view.title (comment view.vdescription)
  in

  let rec print_folder line_prefix child_prefix folder =
    Hashtbl.replace seen_folders folder.key ();
    Printf.printf "%s%s/%s\n" line_prefix folder.fname
      (comment folder.fdescription);

    let subfolders =
      List.filter
        (fun other ->
          other.parent = Some folder.key
          && not (Hashtbl.mem seen_folders other.key))
        folders
    in
    let subviews =
      List.filter (fun view -> view.vfolder = Some folder.key) views in
    let count = List.length subfolders + List.length subviews in

    List.iteri
      (fun index subfolder ->
        let last = index = count - 1 in
        print_folder
          (child_prefix ^ branch last)
          (child_prefix ^ indent last)
          subfolder)
      subfolders;
    List.iteri
      (fun index view ->
        let last = List.length subfolders + index = count - 1 in
        print_view (child_prefix ^ branch last) view)
      subviews
  in

  List.iter
    (fun folder -> if folder.parent = None then print_folder "" "" folder)
    folders;
  List.iter (fun view -> if view.vfolder = None then print_view "" view) views;

  List.iter
    (fun folder ->
      if not (Hashtbl.mem seen_folders folder.key) then
        print_folder "" "" folder)
    folders;
  List.iter
    (fun view -> if not (Hashtbl.mem seen_views view.vname) then print_view "" view)
    views;

  Printf.printf "\n%d folders, %d views\n" (List.length folders)
    (List.length views);

  Sqlite3.db_close db |> ignore
