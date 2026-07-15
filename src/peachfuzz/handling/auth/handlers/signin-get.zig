const std = @import("std");

const httplib = @import("httplib");

const utils = @import("../utils.zig");

pub fn signInGet(req: httplib.Request, res: httplib.Response) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (utils.hasSession(allocator, req)) {
        res.set_redirect(utils.home_path);
        return;
    }

    utils.renderSignIn(allocator, res, null, "");
}
