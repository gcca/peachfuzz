const std = @import("std");

const httplib = @import("httplib");
const sqlite3 = @import("sqlite3");
const peachfuzz = @import("peachfuzz");

const render = @import("../render.zig");

pub fn pageGet(req: httplib.Request, res: httplib.Response) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const user = render.currentUser(allocator, req) orelse {
        res.set_redirect("/peachfuzz/auth/signin");
        return;
    };

    const name = req.path_param("name") orelse {
        res.set_content("Not found", "text/plain");
        return;
    };

    var db = sqlite3.initRO(render.dbPath) catch {
        res.set_content("Database unavailable", "text/plain");
        return;
    };
    defer db.deinit();

    var stmt = db.stmt("SELECT title, engine, body FROM pages_view WHERE name = ?") catch {
        res.set_content("Database unavailable", "text/plain");
        return;
    };
    defer stmt.deinit();

    stmt.bindText(1, name) catch {
        res.set_content("Database unavailable", "text/plain");
        return;
    };

    const step = stmt.step() catch {
        res.set_content("Database unavailable", "text/plain");
        return;
    };
    if (step == .done) {
        res.set_content("Page not found", "text/plain");
        return;
    }

    const title = allocator.dupeZ(u8, stmt.columnText(0)) catch @panic("OOM");
    const engine_id = stmt.columnInt(1);
    const body = allocator.dupeZ(u8, stmt.columnText(2)) catch @panic("OOM");

    var args: std.ArrayList([:0]const u8) = .empty;
    var i: usize = 0;
    while (i < req.param_count()) : (i += 1) {
        const p = req.param_at(i) orelse continue;
        const pair = std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ p.key, p.value }, 0) catch @panic("OOM");
        args.append(allocator, pair) catch @panic("OOM");
    }

    const output = peachfuzz.engine.runtime.Run(allocator, engine_id, body, args.items);

    const rendered = render.renderAnalyst(allocator, .{ .title = title, .content = output }, user);
    res.set_content(rendered, "text/html");
}
