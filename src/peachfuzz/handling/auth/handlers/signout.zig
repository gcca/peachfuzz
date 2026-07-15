const std = @import("std");

const httplib = @import("httplib");
const sqlite3 = @import("sqlite3");

const session = @import("../session.zig");
const utils = @import("../utils.zig");

pub fn signOut(req: httplib.Request, res: httplib.Response) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (req.cookie("session")) |token| blk: {
        const token_z = allocator.dupeZ(u8, token) catch break :blk;
        var db = sqlite3.initRW(session.dbPath) catch break :blk;
        defer db.deinit();
        session.revokeSession(&db, token_z) catch {};
    }

    res.set_cookie(utils.sessionCookie("invalid", -1));
    res.set_redirect("/peachfuzz/auth/signin");
}
