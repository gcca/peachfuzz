const std = @import("std");

const sqlite3 = @import("sqlite3");

const accessly = @import("accessly.zig");
const securing = @import("securing.zig");

pub const User = struct {
    username: [:0]const u8,
    role: accessly.Role,
};

pub const AuthenticateError = error{
    InvalidCredentials,
    DatabaseError,
};

pub const LogInError = error{
    DatabaseError,
};

pub const dbPath: [:0]const u8 = "data/peachfuzz.db";
pub const session_lifetime_seconds: i64 = 7 * 24 * 60 * 60;
const random_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~";

pub fn randomToken(allocator: std.mem.Allocator, len: usize) ![:0]u8 {
    const out = try allocator.allocSentinel(u8, len, 0);
    errdefer allocator.free(out);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    for (out) |*ch| {
        ch.* = random_chars[random.uintLessThan(usize, random_chars.len)];
    }

    return out;
}

fn nowUnix(allocator: std.mem.Allocator) i64 {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    return std.Io.Clock.real.now(threaded.io()).toSeconds();
}

pub fn authenticate(
    allocator: std.mem.Allocator,
    db: *sqlite3.Sqlite3,
    username: [:0]const u8,
    password: []const u8,
) AuthenticateError!bool {
    var stmt = db.stmt("SELECT password, is_active FROM auth_user WHERE username = ?") catch return AuthenticateError.DatabaseError;
    defer stmt.deinit();
    stmt.bindText(1, username) catch return AuthenticateError.DatabaseError;

    const step = stmt.step() catch return AuthenticateError.DatabaseError;
    if (step == .done) return AuthenticateError.InvalidCredentials;

    if (stmt.columnInt(1) == 0) return AuthenticateError.InvalidCredentials;

    const stored = stmt.columnBlob(0);
    return securing.checkPassword(allocator, username, password, stored) catch AuthenticateError.InvalidCredentials;
}

pub fn createSession(
    allocator: std.mem.Allocator,
    db: *sqlite3.Sqlite3,
    username: [:0]const u8,
) LogInError![:0]u8 {
    const token = randomToken(allocator, 40) catch return LogInError.DatabaseError;
    const expires_at = nowUnix(allocator) + session_lifetime_seconds;

    {
        var stmt = db.stmt("INSERT INTO auth_session (token, username, expires_at) VALUES (?, ?, ?)") catch return LogInError.DatabaseError;
        defer stmt.deinit();
        stmt.bindText(1, token) catch return LogInError.DatabaseError;
        stmt.bindText(2, username) catch return LogInError.DatabaseError;
        stmt.bindInt64(3, expires_at) catch return LogInError.DatabaseError;
        _ = stmt.step() catch return LogInError.DatabaseError;
    }

    {
        var stmt = db.stmt("UPDATE auth_user SET last_logged_at = unixepoch() WHERE username = ?") catch return LogInError.DatabaseError;
        defer stmt.deinit();
        stmt.bindText(1, username) catch return LogInError.DatabaseError;
        _ = stmt.step() catch return LogInError.DatabaseError;
    }

    return token;
}

pub fn revokeSession(db: *sqlite3.Sqlite3, token: [:0]const u8) LogInError!void {
    var stmt = db.stmt("UPDATE auth_session SET revoked = 1 WHERE token = ?") catch return LogInError.DatabaseError;
    defer stmt.deinit();
    stmt.bindText(1, token) catch return LogInError.DatabaseError;
    _ = stmt.step() catch return LogInError.DatabaseError;
}

pub fn currentUser(
    allocator: std.mem.Allocator,
    db: *sqlite3.Sqlite3,
    token: [:0]const u8,
) LogInError!?User {
    var stmt = db.stmt(
        \\SELECT s.username, u.role
        \\FROM auth_session s
        \\JOIN auth_user u ON u.username = s.username
        \\WHERE s.token = ? AND s.revoked = 0 AND s.expires_at > unixepoch()
        \\LIMIT 1
    ) catch return LogInError.DatabaseError;
    defer stmt.deinit();
    stmt.bindText(1, token) catch return LogInError.DatabaseError;

    const step = stmt.step() catch return LogInError.DatabaseError;
    if (step == .done) return null;

    const username = allocator.dupeZ(u8, stmt.columnText(0)) catch return LogInError.DatabaseError;
    const role = accessly.roleFromInt(stmt.columnInt(1)) orelse return LogInError.DatabaseError;
    return .{ .username = username, .role = role };
}
