const std = @import("std");
const peachfuzz = @import("peachfuzz");

const httplib = @import("httplib");
const sqlite3 = @import("sqlite3");

const session = @import("../session.zig");
const utils = @import("../utils.zig");

pub fn signInPost(req: httplib.Request, res: httplib.Response) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const username = req.param("username") orelse "";
    const password = req.param("password") orelse "";

    if (username.len == 0 or password.len == 0) {
        res.set_status(400);
        utils.renderSignIn(allocator, res, "Username and password are required.", username);
        return;
    }

    var client = peachfuzz.urmom.AuthClient.init(allocator, peachfuzz.conf.settings.urmomTarget) catch {
        res.set_status(503);
        utils.renderSignIn(allocator, res, "Could not reach the authentication service.", username);
        return;
    };
    defer client.deinit();

    const auth_response = client.Authenticate(.{ .username = username, .password = password }) catch {
        res.set_status(503);
        utils.renderSignIn(allocator, res, "Could not reach the authentication service.", username);
        return;
    };
    defer auth_response.deinit(allocator);

    if (!auth_response.authenticated) {
        res.set_status(401);
        utils.renderSignIn(allocator, res, "Invalid username or password.", username);
        return;
    }

    const authorized = blk: {
        const userinfo = auth_response.userinfo orelse break :blk false;
        for (userinfo.apps) |app| {
            if (std.mem.eql(u8, app, "peachfuzz")) break :blk true;
        }
        break :blk false;
    };

    if (!authorized) {
        res.set_status(403);
        utils.renderSignIn(allocator, res, "Your account is not authorized to use Peachfuzz.", username);
        return;
    }

    var db = sqlite3.initRW(session.dbPath) catch {
        res.set_status(500);
        utils.renderSignIn(allocator, res, "Could not reach the database.", username);
        return;
    };
    defer db.deinit();

    const exists = utils.userExists(&db, username) catch {
        res.set_status(500);
        utils.renderSignIn(allocator, res, "Could not authenticate.", username);
        return;
    };

    if (!exists) {
        utils.provisionUser(&db, username) catch {
            res.set_status(500);
            utils.renderSignIn(allocator, res, "Could not create your account.", username);
            return;
        };
    }

    const token = session.createSession(allocator, &db, username) catch {
        res.set_status(500);
        utils.renderSignIn(allocator, res, "Could not create a session.", username);
        return;
    };

    res.set_cookie(utils.sessionCookie(token, session.session_lifetime_seconds));
    res.set_redirect(utils.home_path);
}
