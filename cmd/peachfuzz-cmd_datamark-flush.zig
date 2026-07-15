const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const duckdb = @cImport({
    @cInclude("duckdb.h");
});

const sqlite_path = "data/peachfuzz.db";
const duckdb_path = "data/datamark.db";
const source_base = "data/datamark/source";

fn sqliteErrorMessage(db: ?*c.sqlite3) []const u8 {
    if (db) |handle| return std.mem.span(c.sqlite3_errmsg(handle));
    return "unknown sqlite error";
}

const SourceInfo = struct {
    name: []u8,
    parquet_path: []u8,

    fn deinit(self: SourceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.parquet_path);
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sqlite_db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(sqlite_path, &sqlite_db) != c.SQLITE_OK) {
        const message = sqliteErrorMessage(sqlite_db);
        if (sqlite_db) |handle| _ = c.sqlite3_close(handle);
        std.debug.print("open {s} err: {s}\n", .{ sqlite_path, message });
        return error.Failure;
    }
    defer _ = c.sqlite3_close(sqlite_db.?);

    const gh_sources = try loadGithubSources(allocator, sqlite_db.?);
    defer {
        for (gh_sources) |s| s.deinit(allocator);
        allocator.free(gh_sources);
    }

    const s3_sources = try loadS3Sources(allocator, sqlite_db.?);
    defer {
        for (s3_sources) |s| s.deinit(allocator);
        allocator.free(s3_sources);
    }

    const drive_names = try loadDriveSourceNames(allocator, sqlite_db.?);
    defer {
        for (drive_names) |n| allocator.free(n);
        allocator.free(drive_names);
    }

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try std.Io.Dir.cwd().createDirPath(io, "data");

    const duckdb_path_z = try allocator.dupeZ(u8, duckdb_path);
    defer allocator.free(duckdb_path_z);

    var duck_db: duckdb.duckdb_database = null;
    if (duckdb.duckdb_open(duckdb_path_z.ptr, &duck_db) == duckdb.DuckDBError) {
        std.debug.print("duckdb open {s} err\n", .{duckdb_path});
        return error.DuckDBOpenFailed;
    }
    defer duckdb.duckdb_close(&duck_db);

    var conn: duckdb.duckdb_connection = null;
    if (duckdb.duckdb_connect(duck_db, &conn) == duckdb.DuckDBError) {
        std.debug.print("duckdb connect err\n", .{});
        return error.DuckDBConnectFailed;
    }
    defer duckdb.duckdb_disconnect(&conn);

    var s3_ready = s3_sources.len > 0;
    if (s3_ready) {
        configureS3(allocator, conn) catch |err| {
            std.debug.print("s3 configuration err: {}\n", .{err});
            s3_ready = false;
        };
    }

    for (gh_sources) |source| {
        flushSource(allocator, conn, source) catch |err| {
            std.debug.print("source '{s}' err: {}\n", .{ source.name, err });
        };
    }

    if (s3_ready) {
        for (s3_sources) |source| {
            flushSource(allocator, conn, source) catch |err| {
                std.debug.print("source '{s}' err: {}\n", .{ source.name, err });
            };
        }
    }

    for (drive_names) |name| {
        std.debug.print("drive source '{s}': not implemented\n", .{name});
    }
}

fn loadGithubSources(allocator: std.mem.Allocator, db: *c.sqlite3) ![]SourceInfo {
    const sql =
        \\SELECT ds.name, gh.asset
        \\FROM datamark_source ds
        \\JOIN datamark_source_github gh ON gh.source_name = ds.name
        \\ORDER BY ds.name
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("prepare query err: {s}\n", .{sqliteErrorMessage(db)});
        return error.SqlitePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    var list: std.ArrayList(SourceInfo) = .empty;
    errdefer {
        for (list.items) |s| s.deinit(allocator);
        list.deinit(allocator);
    }

    while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
        const name_ptr = c.sqlite3_column_text(stmt.?, 0);
        const asset_ptr = c.sqlite3_column_text(stmt.?, 1);

        if (name_ptr == null or asset_ptr == null) continue;

        const name = std.mem.span(name_ptr);
        const asset = std.mem.span(asset_ptr);

        const parquet_path = try std.fs.path.join(
            allocator,
            &[_][]const u8{ source_base, name, asset },
        );

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .parquet_path = parquet_path,
        });
    }

    return list.toOwnedSlice(allocator);
}

fn loadS3Sources(allocator: std.mem.Allocator, db: *c.sqlite3) ![]SourceInfo {
    const sql =
        \\SELECT ds.name, s3.bucket_name, s3.medallion_tier, s3.pattern
        \\FROM datamark_source ds
        \\JOIN datamark_source_s3 s3 ON s3.source_name = ds.name
        \\ORDER BY ds.name, s3.medallion_tier
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("prepare query err: {s}\n", .{sqliteErrorMessage(db)});
        return error.SqlitePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    var list: std.ArrayList(SourceInfo) = .empty;
    errdefer {
        for (list.items) |s| s.deinit(allocator);
        list.deinit(allocator);
    }

    while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
        const name_ptr = c.sqlite3_column_text(stmt.?, 0);
        const bucket_ptr = c.sqlite3_column_text(stmt.?, 1);
        const tier_ptr = c.sqlite3_column_text(stmt.?, 2);
        const pattern_ptr = c.sqlite3_column_text(stmt.?, 3);

        if (name_ptr == null or bucket_ptr == null or tier_ptr == null or pattern_ptr == null) continue;

        const name = std.mem.span(name_ptr);
        const bucket = std.mem.span(bucket_ptr);
        const tier = std.mem.span(tier_ptr);
        const pattern = std.mem.span(pattern_ptr);

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .parquet_path = try std.fmt.allocPrint(allocator, "s3://{s}/{s}/{s}", .{ bucket, tier, pattern }),
        });
    }

    return list.toOwnedSlice(allocator);
}

fn configureS3(allocator: std.mem.Allocator, conn: duckdb.duckdb_connection) !void {
    const access_key_id = std.mem.span(std.c.getenv("AWS_ACCESS_KEY_ID") orelse {
        std.debug.print("AWS_ACCESS_KEY_ID must be set\n", .{});
        return error.Failure;
    });
    const secret_access_key = std.mem.span(std.c.getenv("AWS_SECRET_ACCESS_KEY") orelse {
        std.debug.print("AWS_SECRET_ACCESS_KEY must be set\n", .{});
        return error.Failure;
    });
    const region: []const u8 = if (std.c.getenv("AWS_DEFAULT_REGION")) |r| std.mem.span(r) else "us-east-1";

    try execSql(allocator, conn, "INSTALL httpfs;");
    try execSql(allocator, conn, "LOAD httpfs;");

    var secret_sql: std.Io.Writer.Allocating = .init(allocator);
    defer secret_sql.deinit();

    try secret_sql.writer.writeAll("CREATE OR REPLACE SECRET s3_secret (TYPE S3, KEY_ID ");
    try writeSqlString(&secret_sql.writer, access_key_id);
    try secret_sql.writer.writeAll(", SECRET ");
    try writeSqlString(&secret_sql.writer, secret_access_key);
    try secret_sql.writer.writeAll(", REGION ");
    try writeSqlString(&secret_sql.writer, region);
    try secret_sql.writer.writeAll(")");

    try execSql(allocator, conn, secret_sql.written());
}

fn loadDriveSourceNames(allocator: std.mem.Allocator, db: *c.sqlite3) ![][]u8 {
    const sql =
        \\SELECT ds.name
        \\FROM datamark_source ds
        \\JOIN datamark_source_drive dr ON dr.source_name = ds.name
        \\ORDER BY ds.name
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("prepare query err: {s}\n", .{sqliteErrorMessage(db)});
        return error.SqlitePrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |n| allocator.free(n);
        list.deinit(allocator);
    }

    while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
        const name_ptr = c.sqlite3_column_text(stmt.?, 0);
        if (name_ptr == null) continue;
        try list.append(allocator, try allocator.dupe(u8, std.mem.span(name_ptr)));
    }

    return list.toOwnedSlice(allocator);
}

fn flushSource(
    allocator: std.mem.Allocator,
    conn: duckdb.duckdb_connection,
    source: SourceInfo,
) !void {
    var sql: std.Io.Writer.Allocating = .init(allocator);
    defer sql.deinit();

    try sql.writer.writeAll("CREATE OR REPLACE TABLE ");
    try writeSqlIdentifier(&sql.writer, source.name);
    try sql.writer.writeAll(" AS FROM read_parquet(");
    try writeSqlString(&sql.writer, source.parquet_path);
    try sql.writer.writeByte(')');

    try execSql(allocator, conn, sql.written());
    std.debug.print("flushed: {s}\n", .{source.name});
}

fn execSql(
    allocator: std.mem.Allocator,
    conn: duckdb.duckdb_connection,
    sql: []const u8,
) !void {
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);

    var result: duckdb.duckdb_result = undefined;
    if (duckdb.duckdb_query(conn, sql_z.ptr, &result) == duckdb.DuckDBError) {
        defer duckdb.duckdb_destroy_result(&result);
        const err_msg = duckdb.duckdb_result_error(&result);
        if (err_msg) |msg| {
            std.debug.print("duckdb err: {s}\n", .{msg});
        }
        return error.DuckDBQueryFailed;
    }
    duckdb.duckdb_destroy_result(&result);
}

fn writeSqlIdentifier(writer: *std.Io.Writer, identifier: []const u8) !void {
    try writer.writeByte('"');
    for (identifier) |byte| {
        if (byte == '"') try writer.writeByte('"');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

fn writeSqlString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') try writer.writeByte('\'');
        try writer.writeByte(byte);
    }
    try writer.writeByte('\'');
}
