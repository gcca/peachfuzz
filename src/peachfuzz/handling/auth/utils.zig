const std = @import("std");

const httplib = @import("httplib");
const mustache = @import("mustache");
const sqlite3 = @import("sqlite3");
const peachfuzz = @import("peachfuzz");

const accessly = @import("accessly.zig");
const securing = @import("securing.zig");
const session = @import("session.zig");

const signInTmpl = @embedFile("tmpl/signin.html");
const o365SignInTmpl = @embedFile("tmpl/o365-signin.html");

pub const home_path = "/peachfuzz/home";

pub fn hasSession(allocator: std.mem.Allocator, req: httplib.Request) bool {
    const token = req.cookie("session") orelse return false;
    const token_z = allocator.dupeZ(u8, token) catch return false;

    var db = sqlite3.initRO(session.dbPath) catch return false;
    defer db.deinit();

    const user = session.currentUser(allocator, &db, token_z) catch return false;
    return user != null;
}

pub const O365Config = struct {
    client_id: [:0]const u8,
    client_secret: [:0]const u8,
    tenant_id: [:0]const u8,
};

pub const FetchOutcome = struct {
    status_ok: bool = false,
    body: []u8 = &.{},
    failed: bool = false,
};

const FetchJob = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    outcome: FetchOutcome = .{},

    fn run(job: *FetchJob) void {
        var threaded = std.Io.Threaded.init(job.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var client: std.http.Client = .{ .allocator = job.allocator, .io = io };
        defer client.deinit();

        var response_writer: std.Io.Writer.Allocating = .init(job.allocator);

        const fetch_result = client.fetch(.{
            .location = .{ .url = job.url },
            .method = .POST,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
                .{ .name = "Accept", .value = "application/json" },
            },
            .payload = job.body,
            .response_writer = &response_writer.writer,
        }) catch {
            job.outcome.failed = true;
            return;
        };

        job.outcome.status_ok = fetch_result.status == .ok;
        job.outcome.body = response_writer.writer.buffer[0..response_writer.writer.end];
    }
};

// cpp-httplib's worker threads get the platform default pthread stack size
// (512KB on macOS), which a TLS handshake to a real HTTPS endpoint can
// overflow. Run the fetch on a freshly spawned thread with Zig's default
// 16MB stack instead of doing it directly on the request-handling thread.
pub fn postForm(allocator: std.mem.Allocator, url: []const u8, body: []const u8) !FetchOutcome {
    var job: FetchJob = .{ .allocator = allocator, .url = url, .body = body };
    const thread = try std.Thread.spawn(.{}, FetchJob.run, .{&job});
    thread.join();
    if (job.outcome.failed) return error.FetchFailed;
    return job.outcome;
}

pub fn loadO365Config() ?O365Config {
    return .{
        .client_id = std.mem.span(std.c.getenv("PEACHFUZZ_O365_CLIENT_ID") orelse return null),
        .client_secret = std.mem.span(std.c.getenv("PEACHFUZZ_O365_CLIENT_SECRET") orelse return null),
        .tenant_id = std.mem.span(std.c.getenv("PEACHFUZZ_O365_TENANT_ID") orelse return null),
    };
}

pub fn userExists(db: *sqlite3.Sqlite3, username: [:0]const u8) !bool {
    var stmt = try db.stmt("SELECT 1 FROM auth_user WHERE username = ? LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, username);
    return (try stmt.step()) == .row;
}

pub fn provisionUser(allocator: std.mem.Allocator, db: *sqlite3.Sqlite3, username: [:0]const u8) !void {
    const random_password = try session.randomToken(allocator, 32);

    var stored: [securing.StoredPasswordLen]u8 = undefined;
    try securing.hashPasswordInto(allocator, username, random_password, &stored);

    var stmt = try db.stmt("INSERT INTO auth_user (username, password, role) VALUES (?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, username);
    try stmt.bindBlob(2, &stored);
    try stmt.bindInt64(3, @intFromEnum(accessly.Role.analyst));
    _ = try stmt.step();
}

pub fn jwtStringClaim(allocator: std.mem.Allocator, token: []const u8, claim: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next();
    const payload_b64 = parts.next() orelse return error.InvalidToken;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return error.InvalidToken;
    const decoded = try allocator.alloc(u8, decoded_len);
    decoder.decode(decoded, payload_b64) catch return error.InvalidToken;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return error.InvalidToken;
    defer parsed.deinit();

    const val = parsed.value.object.get(claim) orelse return error.ClaimNotFound;
    return switch (val) {
        .string => |s| try allocator.dupe(u8, s),
        else => error.ClaimNotString,
    };
}

pub fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn sessionCookie(token: [:0]const u8, max_age_s: i64) httplib.Cookie {
    return .{
        .name = "session",
        .value = token,
        .path = "/peachfuzz",
        .max_age_s = @intCast(max_age_s),
        .http_only = true,
        .secure = false,
        .same_site = .lax,
    };
}

fn toZ(allocator: std.mem.Allocator, s: []const u8) [:0]const u8 {
    return allocator.dupeZ(u8, s) catch "";
}

pub fn renderSignIn(
    allocator: std.mem.Allocator,
    res: httplib.Response,
    error_message: ?[:0]const u8,
    username: [:0]const u8,
) void {
    var tmpl = mustache.Mustache.init(allocator, signInTmpl);
    defer tmpl.deinit();

    var data = mustache.Data.init(allocator);
    defer data.deinit();

    data.setString("app_name", peachfuzz.conf.settings.appname);
    data.setBool("has_error", error_message != null);
    data.setString("error_message", error_message orelse "");
    data.setString("username", username);

    const rendered = tmpl.Render(data);
    res.set_content(rendered, "text/html");
}

pub fn renderO365SignIn(
    allocator: std.mem.Allocator,
    res: httplib.Response,
    error_message: ?[]const u8,
    user_code: ?[]const u8,
    verification_uri: ?[]const u8,
    device_code: ?[]const u8,
) void {
    var tmpl = mustache.Mustache.init(allocator, o365SignInTmpl);
    defer tmpl.deinit();

    var data = mustache.Data.init(allocator);
    defer data.deinit();

    data.setString("app_name", peachfuzz.conf.settings.appname);
    data.setBool("has_error", error_message != null);
    data.setString("error_message", toZ(allocator, error_message orelse ""));
    data.setBool("has_code", user_code != null);
    data.setString("user_code", toZ(allocator, user_code orelse ""));
    data.setString("verification_uri", toZ(allocator, verification_uri orelse ""));
    data.setString("device_code", toZ(allocator, device_code orelse ""));

    const rendered = tmpl.Render(data);
    res.set_content(rendered, "text/html");
}
