const std = @import("std");

const httplib = @import("httplib");
const sqlite3 = @import("sqlite3");
const peachfuzz = @import("peachfuzz");

const session = peachfuzz.handling.auth.session;

pub fn homeGet(req: httplib.Request, res: httplib.Response) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const user = currentUser(allocator, req) orelse {
        res.set_redirect("/peachfuzz/auth/signin");
        return;
    };

    const path = std.fmt.allocPrintSentinel(
        allocator,
        "/peachfuzz/{s}",
        .{@tagName(user.role)},
        0,
    ) catch @panic("OOM");

    res.set_redirect(path);
}

fn currentUser(allocator: std.mem.Allocator, req: httplib.Request) ?session.User {
    const token = req.cookie("session") orelse return null;
    const token_z = allocator.dupeZ(u8, token) catch return null;

    var db = sqlite3.initRO(session.dbPath) catch return null;
    defer db.deinit();

    return session.currentUser(allocator, &db, token_z) catch null;
}
