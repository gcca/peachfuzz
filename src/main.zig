const std = @import("std");

const sqlite3 = @import("sqlite3");
const httplib = @import("httplib");
const peachfuzz = @import("peachfuzz");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    sqlite3.initdb(peachfuzz.handling.auth.session.dbPath) catch |err| {
        std.log.warn("could not enable SQLite WAL journal mode: {s}", .{@errorName(err)});
    };
    peachfuzz.conf.load();

    var server = httplib.Server.init();
    defer server.deinit();

    peachfuzz.handling.auth.routes.initRoutes(server);
    peachfuzz.handling.home.routes.initRoutes(server);
    peachfuzz.handling.analyst.routes.initRoutes(server);
    server
        .Get("/", index)
        .Get("/peachfuzz/healthcheck", healthcheck)
        .listen("0.0.0.0", 8000);
}

fn index(_: httplib.Request, res: httplib.Response) void {
    res.set_redirect("/peachfuzz/auth");
}

fn healthcheck(_: httplib.Request, res: httplib.Response) void {
    res.set_content("🍻", "text/plain");
}
