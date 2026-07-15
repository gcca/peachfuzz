const std = @import("std");

const sqlite3 = @import("sqlite3");
const httplib = @import("httplib");
const peachfuzz = @import("peachfuzz");

const datamark_update_bin = "peachfuzz-cmd_datamark-update";
const datamark_update_interval_seconds = 5 * 60;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    sqlite3.initdb(peachfuzz.handling.auth.session.dbPath) catch |err| {
        std.log.warn("could not initialize SQLite: {s}", .{@errorName(err)});
    };
    peachfuzz.conf.load();

    if (std.Thread.spawn(.{}, datamarkUpdateLoop, .{init.environ_map})) |thread| {
        thread.detach();
    } else |err| {
        std.log.warn("could not start datamark-update loop: {s}", .{@errorName(err)});
    }

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

fn datamarkUpdateLoop(environ_map: *const std.process.Environ.Map) void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    while (true) {
        runDatamarkUpdate(io, environ_map) catch |err| {
            std.log.warn("datamark-update: run failed: {s}", .{@errorName(err)});
        };
        io.sleep(std.Io.Duration.fromSeconds(datamark_update_interval_seconds), .awake) catch {};
    }
}

fn runDatamarkUpdate(io: std.Io, environ_map: *const std.process.Environ.Map) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{datamark_update_bin},
        .environ_map = environ_map,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0)
            std.log.warn("datamark-update: exited with code {d}", .{code}),
        else => std.log.warn("datamark-update: terminated abnormally", .{}),
    }
}
