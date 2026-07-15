const std = @import("std");

const httplib = @import("httplib");

const render = @import("../render.zig");

pub fn analystGet(req: httplib.Request, res: httplib.Response) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const user = render.currentUser(allocator, req) orelse {
        res.set_redirect("/peachfuzz/auth/signin");
        return;
    };

    const rendered = render.renderAnalyst(allocator, null, user);
    res.set_content(rendered, "text/html");
}
