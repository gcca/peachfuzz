const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const OpenError = error{
    OpenFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    ExecFailed,
    WalFailed,
};

pub const Step = enum {
    row,
    done,
};

pub const Sqlite3 = struct {
    sqlite3: *c.sqlite3,

    pub fn deinit(self: *Sqlite3) void {
        _ = c.sqlite3_close(self.sqlite3);
    }

    pub fn stmt(self: *Sqlite3, sql: [:0]const u8) OpenError!Stmt {
        return Stmt.init(self.sqlite3, sql);
    }

    pub fn errmsg(self: *Sqlite3) [:0]const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.sqlite3));
    }
};

const connection_pragmas = "PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL; PRAGMA wal_autocheckpoint = 500; PRAGMA journal_size_limit = 8388608;";

fn exec(handle: *c.sqlite3, sql: [:0]const u8) OpenError!void {
    if (c.sqlite3_exec(handle, sql.ptr, null, null, null) != c.SQLITE_OK) {
        return OpenError.ExecFailed;
    }
}

fn tune(handle: *c.sqlite3) OpenError!void {
    _ = c.sqlite3_busy_timeout(handle, 5000);
    try exec(handle, connection_pragmas);
}

pub fn initRO(filename: [:0]const u8) OpenError!Sqlite3 {
    var sqlite3: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(filename.ptr, &sqlite3, c.SQLITE_OPEN_READWRITE, null) != c.SQLITE_OK or sqlite3 == null) {
        if (sqlite3) |handle| _ = c.sqlite3_close(handle);
        return OpenError.OpenFailed;
    }
    const handle = sqlite3.?;
    tune(handle) catch |err| {
        _ = c.sqlite3_close(handle);
        return err;
    };
    exec(handle, "PRAGMA query_only = ON;") catch |err| {
        _ = c.sqlite3_close(handle);
        return err;
    };
    return .{ .sqlite3 = handle };
}

pub fn initRW(filename: [:0]const u8) OpenError!Sqlite3 {
    var sqlite3: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(filename.ptr, &sqlite3, c.SQLITE_OPEN_READWRITE, null) != c.SQLITE_OK or sqlite3 == null) {
        if (sqlite3) |handle| _ = c.sqlite3_close(handle);
        return OpenError.OpenFailed;
    }
    const handle = sqlite3.?;
    tune(handle) catch |err| {
        _ = c.sqlite3_close(handle);
        return err;
    };
    return .{ .sqlite3 = handle };
}

pub fn initdb(filename: [:0]const u8) OpenError!void {
    var db = try initRW(filename);
    defer db.deinit();

    var stmt = try db.stmt("PRAGMA journal_mode = WAL;");
    defer stmt.deinit();

    if ((try stmt.step()) != .row) {
        std.log.warn("could not enable SQLite WAL journal mode (on stmt.step): filename={s}", .{filename});
        return OpenError.WalFailed;
    }
    if (!std.ascii.eqlIgnoreCase(stmt.columnText(0), "wal")) {
        std.log.warn("could not enable SQLite WAL journal mode (on stmt.columnText): filename={s}", .{filename});
        return OpenError.WalFailed;
    }
}

pub const Stmt = struct {
    sqlite3: *c.sqlite3,
    stmt: *c.sqlite3_stmt,

    pub fn init(sqlite3: *c.sqlite3, sql: [:0]const u8) OpenError!Stmt {
        var stmt_: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(sqlite3, sql.ptr, -1, &stmt_, null) != c.SQLITE_OK) {
            return OpenError.PrepareFailed;
        }
        return .{ .sqlite3 = sqlite3, .stmt = stmt_.? };
    }

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn errmsg(self: *Stmt) [:0]const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.sqlite3));
    }

    pub fn bindText(self: *Stmt, i: c_int, data: [:0]const u8) OpenError!void {
        if (c.sqlite3_bind_text(self.stmt, i, data.ptr, -1, c.SQLITE_STATIC) != c.SQLITE_OK) {
            return OpenError.BindFailed;
        }
    }

    pub fn bindBlob(self: *Stmt, i: c_int, data: []const u8) OpenError!void {
        if (c.sqlite3_bind_blob(self.stmt, i, data.ptr, @intCast(data.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
            return OpenError.BindFailed;
        }
    }

    pub fn bindInt64(self: *Stmt, i: c_int, value: i64) OpenError!void {
        if (c.sqlite3_bind_int64(self.stmt, i, value) != c.SQLITE_OK) {
            return OpenError.BindFailed;
        }
    }

    pub fn step(self: *Stmt) OpenError!Step {
        return switch (c.sqlite3_step(self.stmt)) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => OpenError.StepFailed,
        };
    }

    pub fn columnText(self: *Stmt, i: c_int) [:0]const u8 {
        const text = c.sqlite3_column_text(self.stmt, i) orelse return "";
        return std.mem.span(text);
    }

    pub fn columnInt(self: *Stmt, i: c_int) i64 {
        return c.sqlite3_column_int64(self.stmt, i);
    }

    pub fn columnBlob(self: *Stmt, i: c_int) []const u8 {
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, i));
        if (len == 0) return "";
        const ptr = c.sqlite3_column_blob(self.stmt, i) orelse return "";
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }
};

test "initRO opens an existing database read only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.joinZ(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "test.db",
    });
    defer std.testing.allocator.free(path);

    var raw: ?*c.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open_v2(path.ptr, &raw, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    try std.testing.expect(raw != null);
    defer {
        if (raw) |handle| _ = c.sqlite3_close(handle);
    }

    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(raw.?,
        \\CREATE TABLE home_app (
        \\  name TEXT NOT NULL PRIMARY KEY,
        \\  title TEXT NOT NULL,
        \\  description TEXT NOT NULL,
        \\  icon TEXT NOT NULL,
        \\  caption TEXT NOT NULL,
        \\  link TEXT NOT NULL
        \\);
        \\INSERT INTO home_app (name, title, description, icon, caption, link)
        \\VALUES ('tickets', 'Tickets', 'Internal support requests.', 'fa-solid fa-ticket', 'Open', '#');
    , null, null, null));
    _ = c.sqlite3_close(raw.?);
    raw = null;

    var db = try initRO(path);
    defer db.deinit();

    var statement = try db.stmt("SELECT name, title, description, icon, caption, link FROM home_app");
    defer statement.deinit();
    try std.testing.expectEqual(Step.row, try statement.step());
    try std.testing.expectEqualStrings("tickets", statement.columnText(0));
    try std.testing.expectEqualStrings("Tickets", statement.columnText(1));
    try std.testing.expectEqualStrings("Internal support requests.", statement.columnText(2));
    try std.testing.expectEqualStrings("fa-solid fa-ticket", statement.columnText(3));
    try std.testing.expectEqualStrings("Open", statement.columnText(4));
    try std.testing.expectEqualStrings("#", statement.columnText(5));
    try std.testing.expectEqual(Step.done, try statement.step());
}

test "initdb enables WAL journal mode and connections still open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.joinZ(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "wal.db",
    });
    defer std.testing.allocator.free(path);

    var raw: ?*c.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open_v2(path.ptr, &raw, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(raw.?, "CREATE TABLE t (id INTEGER PRIMARY KEY);", null, null, null));
    _ = c.sqlite3_close(raw.?);
    raw = null;

    try initdb(path);

    // A fresh read-only connection (which now runs the tuning PRAGMAs) opens
    // cleanly against the WAL database and observes WAL journal mode.
    var db = try initRO(path);
    defer db.deinit();

    var stmt = try db.stmt("PRAGMA journal_mode;");
    defer stmt.deinit();
    try std.testing.expectEqual(Step.row, try stmt.step());
    try std.testing.expectEqualStrings("wal", stmt.columnText(0));
}
