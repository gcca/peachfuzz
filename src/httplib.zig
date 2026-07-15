const std = @import("std");

const c = @cImport({
    @cInclude("httplibshim.hpp");
});

pub const Request = struct {
    handle: *const c.Request,

    pub fn path_param(self: Request, key: [:0]const u8) ?[:0]const u8 {
        const ptr = c.request_path_param(self.handle, key.ptr) orelse return null;
        return std.mem.span(ptr);
    }

    pub fn param(self: Request, key: [:0]const u8) ?[:0]const u8 {
        const ptr = c.request_param(self.handle, key.ptr) orelse return null;
        return std.mem.span(ptr);
    }

    pub const Param = struct {
        key: [:0]const u8,
        value: [:0]const u8,
    };

    pub fn param_count(self: Request) usize {
        return c.request_param_count(self.handle);
    }

    pub fn param_at(self: Request, index: usize) ?Param {
        const key = c.request_param_key_at(self.handle, index) orelse return null;
        const value = c.request_param_value_at(self.handle, index) orelse return null;
        return .{ .key = std.mem.span(key), .value = std.mem.span(value) };
    }

    pub fn cookie(self: Request, name: []const u8) ?[]const u8 {
        const ptr = c.request_header(self.handle, "Cookie") orelse return null;
        const header = std.mem.span(ptr);

        var it = std.mem.splitScalar(u8, header, ';');
        while (it.next()) |raw_pair| {
            const pair = std.mem.trim(u8, raw_pair, " ");
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }
};

pub const SameSite = enum {
    strict,
    lax,
    none,

    fn str(self: SameSite) [:0]const u8 {
        return switch (self) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        };
    }
};

pub const Cookie = struct {
    name: [:0]const u8,
    value: [:0]const u8,
    path: [:0]const u8 = "/",
    max_age_s: i32 = -1,
    http_only: bool = true,
    secure: bool = false,
    same_site: SameSite = .lax,
};

pub const Response = struct {
    handle: *c.Response,

    pub fn set_redirect(self: Response, url: [:0]const u8) void {
        c.response_set_redirect(self.handle, url.ptr);
    }

    pub fn set_content(self: Response, s: []const u8, content_type: [:0]const u8) void {
        c.response_set_content(self.handle, s.ptr, s.len, content_type.ptr);
    }

    pub fn set_status(self: Response, status: c_int) void {
        c.response_set_status(self.handle, status);
    }

    pub fn set_cookie(self: Response, cookie: Cookie) void {
        c.response_set_cookie(
            self.handle,
            cookie.name.ptr,
            cookie.value.ptr,
            cookie.path.ptr,
            cookie.max_age_s,
            @intFromBool(cookie.http_only),
            @intFromBool(cookie.secure),
            cookie.same_site.str().ptr,
        );
    }
};

pub const Handler = fn (Request, Response) void;

pub const Server = struct {
    handle: *c.Server,

    pub fn init() Server {
        return .{ .handle = c.server_create().? };
    }

    pub fn deinit(self: *Server) void {
        c.server_destroy(self.handle);
    }

    pub fn Get(self: Server, pattern: [:0]const u8, comptime handler: Handler) Server {
        c.server_get(self.handle, pattern.ptr, struct {
            fn call(req: ?*const c.Request, res: ?*c.Response) callconv(.c) void {
                handler(.{ .handle = req.? }, .{ .handle = res.? });
            }
        }.call);
        return self;
    }

    pub fn Post(self: Server, pattern: [:0]const u8, comptime handler: Handler) Server {
        c.server_post(self.handle, pattern.ptr, struct {
            fn call(req: ?*const c.Request, res: ?*c.Response) callconv(.c) void {
                handler(.{ .handle = req.? }, .{ .handle = res.? });
            }
        }.call);
        return self;
    }

    pub fn Put(self: Server, pattern: [:0]const u8, comptime handler: Handler) Server {
        c.server_put(self.handle, pattern.ptr, struct {
            fn call(req: ?*const c.Request, res: ?*c.Response) callconv(.c) void {
                handler(.{ .handle = req.? }, .{ .handle = res.? });
            }
        }.call);
        return self;
    }

    pub fn Delete(self: Server, pattern: [:0]const u8, comptime handler: Handler) Server {
        c.server_delete(self.handle, pattern.ptr, struct {
            fn call(req: ?*const c.Request, res: ?*c.Response) callconv(.c) void {
                handler(.{ .handle = req.? }, .{ .handle = res.? });
            }
        }.call);
        return self;
    }

    pub fn listen(self: Server, host: [:0]const u8, port: c_int) void {
        c.server_listen(self.handle, host.ptr, port);
    }

    pub fn bind_any(self: Server, host: [:0]const u8) error{BindFailed}!u16 {
        const port = c.server_bind_any(self.handle, host.ptr);
        if (port < 0) return error.BindFailed;
        return @intCast(port);
    }

    pub fn listen_after_bind(self: Server) void {
        c.server_listen_after_bind(self.handle);
    }

    pub fn stop(self: Server) void {
        c.server_stop(self.handle);
    }

    pub fn is_running(self: Server) bool {
        return c.server_is_running(self.handle) != 0;
    }
};

fn waitUntilRunning(server: Server) void {
    var i: usize = 0;
    while (!server.is_running()) : (i += 1) {
        if (i > 10_000_000) @panic("server failed to start");
        std.Thread.yield() catch {};
    }
}

const HttpResult = struct {
    status: std.http.Status,
    body: []u8,

    fn deinit(self: HttpResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

fn httpFetch(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
) !HttpResult {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = if (method.requestHasBody()) "" else null,
        .response_writer = &aw.writer,
        .redirect_behavior = .unhandled,
    });

    return .{
        .status = result.status,
        .body = try aw.toOwnedSlice(),
    };
}

fn httpFetchOpts(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) !HttpResult {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = extra_headers,
        .response_writer = &aw.writer,
        .redirect_behavior = .unhandled,
    });

    return .{
        .status = result.status,
        .body = try aw.toOwnedSlice(),
    };
}

fn urlFor(allocator: std.mem.Allocator, port: u16, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, path });
}

test "server init deinit" {
    var server = Server.init();
    defer server.deinit();
}

test "get set_content" {
    var server = Server.init();
    defer server.deinit();

    _ = server.Get("/hi", struct {
        fn handle(_: Request, res: Response) void {
            res.set_content("hello", "text/plain");
        }
    }.handle);

    const port = try server.bind_any("127.0.0.1");
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Server) void {
            s.listen_after_bind();
        }
    }.run, .{server});
    defer {
        server.stop();
        thread.join();
    }
    waitUntilRunning(server);

    const url = try urlFor(std.testing.allocator, port, "/hi");
    defer std.testing.allocator.free(url);

    const res = try httpFetch(std.testing.allocator, .GET, url);
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("hello", res.body);
}

test "get set_redirect" {
    var server = Server.init();
    defer server.deinit();

    _ = server.Get("/go", struct {
        fn handle(_: Request, res: Response) void {
            res.set_redirect("/there");
        }
    }.handle);

    const port = try server.bind_any("127.0.0.1");
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Server) void {
            s.listen_after_bind();
        }
    }.run, .{server});
    defer {
        server.stop();
        thread.join();
    }
    waitUntilRunning(server);

    const url = try urlFor(std.testing.allocator, port, "/go");
    defer std.testing.allocator.free(url);

    const res = try httpFetch(std.testing.allocator, .GET, url);
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.found, res.status);
}

test "get path_param" {
    var server = Server.init();
    defer server.deinit();

    _ = server.Get("/pages/:name", struct {
        fn handle(req: Request, res: Response) void {
            if (req.path_param("missing") != null) {
                res.set_content("unexpected", "text/plain");
                return;
            }
            const name = req.path_param("name") orelse {
                res.set_content("none", "text/plain");
                return;
            };
            res.set_content(name, "text/plain");
        }
    }.handle);

    const port = try server.bind_any("127.0.0.1");
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Server) void {
            s.listen_after_bind();
        }
    }.run, .{server});
    defer {
        server.stop();
        thread.join();
    }
    waitUntilRunning(server);

    const url = try urlFor(std.testing.allocator, port, "/pages/stars");
    defer std.testing.allocator.free(url);

    const res = try httpFetch(std.testing.allocator, .GET, url);
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("stars", res.body);
}

test "post put delete" {
    var server = Server.init();
    defer server.deinit();

    _ = server
        .Post("/m", struct {
            fn handle(_: Request, res: Response) void {
                res.set_content("post", "text/plain");
            }
        }.handle)
        .Put("/m", struct {
            fn handle(_: Request, res: Response) void {
                res.set_content("put", "text/plain");
            }
        }.handle)
        .Delete("/m", struct {
        fn handle(_: Request, res: Response) void {
            res.set_content("delete", "text/plain");
        }
    }.handle);

    const port = try server.bind_any("127.0.0.1");
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Server) void {
            s.listen_after_bind();
        }
    }.run, .{server});
    defer {
        server.stop();
        thread.join();
    }
    waitUntilRunning(server);

    const url = try urlFor(std.testing.allocator, port, "/m");
    defer std.testing.allocator.free(url);

    {
        const res = try httpFetch(std.testing.allocator, .POST, url);
        defer res.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, res.status);
        try std.testing.expectEqualStrings("post", res.body);
    }
    {
        const res = try httpFetch(std.testing.allocator, .PUT, url);
        defer res.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, res.status);
        try std.testing.expectEqualStrings("put", res.body);
    }
    {
        const res = try httpFetch(std.testing.allocator, .DELETE, url);
        defer res.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, res.status);
        try std.testing.expectEqualStrings("delete", res.body);
    }
}

test "get param from query string" {
    var server = Server.init();
    defer server.deinit();

    _ = server.Get("/echo", struct {
        fn handle(req: Request, res: Response) void {
            res.set_content(req.param("name") orelse "none", "text/plain");
        }
    }.handle);

    const port = try server.bind_any("127.0.0.1");
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Server) void {
            s.listen_after_bind();
        }
    }.run, .{server});
    defer {
        server.stop();
        thread.join();
    }
    waitUntilRunning(server);

    const url = try urlFor(std.testing.allocator, port, "/echo?name=zig");
    defer std.testing.allocator.free(url);

    const res = try httpFetch(std.testing.allocator, .GET, url);
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("zig", res.body);
}

test "enumerate all params" {
    var server = Server.init();
    defer server.deinit();

    _ = server.Get("/all", struct {
        fn handle(req: Request, res: Response) void {
            var buf: [256]u8 = undefined;
            var len: usize = 0;
            var i: usize = 0;
            while (i < req.param_count()) : (i += 1) {
                const p = req.param_at(i) orelse continue;
                const s = std.fmt.bufPrint(buf[len..], "{s}={s};", .{ p.key, p.value }) catch break;
                len += s.len;
            }
            res.set_content(buf[0..len], "text/plain");
        }
    }.handle);

    const port = try server.bind_any("127.0.0.1");
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Server) void {
            s.listen_after_bind();
        }
    }.run, .{server});
    defer {
        server.stop();
        thread.join();
    }
    waitUntilRunning(server);

    const url = try urlFor(std.testing.allocator, port, "/all?region=north&days=30");
    defer std.testing.allocator.free(url);

    const res = try httpFetch(std.testing.allocator, .GET, url);
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("days=30;region=north;", res.body);
}

test "repeated params surface every value" {
    var server = Server.init();
    defer server.deinit();

    _ = server.Get("/all", struct {
        fn handle(req: Request, res: Response) void {
            var buf: [256]u8 = undefined;
            var len: usize = 0;
            var i: usize = 0;
            while (i < req.param_count()) : (i += 1) {
                const p = req.param_at(i) orelse continue;
                const s = std.fmt.bufPrint(buf[len..], "{s}={s};", .{ p.key, p.value }) catch break;
                len += s.len;
            }
            res.set_content(buf[0..len], "text/plain");
        }
    }.handle);

    const port = try server.bind_any("127.0.0.1");
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Server) void {
            s.listen_after_bind();
        }
    }.run, .{server});
    defer {
        server.stop();
        thread.join();
    }
    waitUntilRunning(server);

    const url = try urlFor(std.testing.allocator, port, "/all?tag=a&tag=b&tag=c");
    defer std.testing.allocator.free(url);

    const res = try httpFetch(std.testing.allocator, .GET, url);
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("tag=a;tag=b;tag=c;", res.body);
}

test "post param from form body" {
    var server = Server.init();
    defer server.deinit();

    _ = server.Post("/echo", struct {
        fn handle(req: Request, res: Response) void {
            res.set_content(req.param("name") orelse "none", "text/plain");
        }
    }.handle);

    const port = try server.bind_any("127.0.0.1");
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Server) void {
            s.listen_after_bind();
        }
    }.run, .{server});
    defer {
        server.stop();
        thread.join();
    }
    waitUntilRunning(server);

    const url = try urlFor(std.testing.allocator, port, "/echo");
    defer std.testing.allocator.free(url);

    const res = try httpFetchOpts(std.testing.allocator, .POST, url, &.{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    }, "name=zig");
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("zig", res.body);
}

test "read cookie from request" {
    var server = Server.init();
    defer server.deinit();

    _ = server.Get("/whoami", struct {
        fn handle(req: Request, res: Response) void {
            res.set_content(req.cookie("session") orelse "none", "text/plain");
        }
    }.handle);

    const port = try server.bind_any("127.0.0.1");
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Server) void {
            s.listen_after_bind();
        }
    }.run, .{server});
    defer {
        server.stop();
        thread.join();
    }
    waitUntilRunning(server);

    const url = try urlFor(std.testing.allocator, port, "/whoami");
    defer std.testing.allocator.free(url);

    const res = try httpFetchOpts(std.testing.allocator, .GET, url, &.{
        .{ .name = "Cookie", .value = "other=1; session=abc123; third=2" },
    }, null);
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("abc123", res.body);
}

test "set_status and set_cookie" {
    var server = Server.init();
    defer server.deinit();

    _ = server.Get("/set", struct {
        fn handle(_: Request, res: Response) void {
            res.set_status(201);
            res.set_cookie(.{
                .name = "session",
                .value = "abc123",
                .path = "/peachfuzz",
                .max_age_s = 3600,
                .http_only = true,
                .secure = false,
                .same_site = .lax,
            });
            res.set_content("ok", "text/plain");
        }
    }.handle);

    const port = try server.bind_any("127.0.0.1");
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: Server) void {
            s.listen_after_bind();
        }
    }.run, .{server});
    defer {
        server.stop();
        thread.join();
    }
    waitUntilRunning(server);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();

    const url = try urlFor(std.testing.allocator, port, "/set");
    defer std.testing.allocator.free(url);
    const uri = try std.Uri.parse(url);

    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [1024]u8 = undefined;
    const response = try req.receiveHead(&redirect_buffer);

    try std.testing.expectEqual(@as(u16, 201), @intFromEnum(response.head.status));

    var found_cookie = false;
    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Set-Cookie") and
            std.mem.indexOf(u8, header.value, "session=abc123") != null and
            std.mem.indexOf(u8, header.value, "Path=/peachfuzz") != null and
            std.mem.indexOf(u8, header.value, "HttpOnly") != null and
            std.mem.indexOf(u8, header.value, "SameSite=Lax") != null)
        {
            found_cookie = true;
        }
    }
    try std.testing.expect(found_cookie);
}
