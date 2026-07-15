const std = @import("std");

const httplib = @import("httplib");
const sqlite3 = @import("sqlite3");

const session = @import("../session.zig");
const utils = @import("../utils.zig");

pub fn o365ValidatePost(req: httplib.Request, res: httplib.Response) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const device_code = req.param("device_code") orelse {
        res.set_status(400);
        res.set_content("{\"status\":\"error\",\"message\":\"Missing device_code\"}", "application/json");
        return;
    };

    const config = utils.loadO365Config() orelse {
        res.set_status(500);
        res.set_content("{\"status\":\"error\",\"message\":\"O365 sign-in is not configured\"}", "application/json");
        return;
    };

    const url = std.fmt.allocPrint(
        allocator,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/token",
        .{config.tenant_id},
    ) catch {
        res.set_content("{\"status\":\"error\",\"message\":\"Could not reach Microsoft\"}", "application/json");
        return;
    };
    const body = std.fmt.allocPrint(
        allocator,
        "client_id={s}&client_secret={s}&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&device_code={s}",
        .{ config.client_id, config.client_secret, device_code },
    ) catch {
        res.set_content("{\"status\":\"error\",\"message\":\"Could not reach Microsoft\"}", "application/json");
        return;
    };

    const outcome = utils.postForm(allocator, url, body) catch {
        res.set_content("{\"status\":\"error\",\"message\":\"Could not reach Microsoft\"}", "application/json");
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, outcome.body, .{}) catch {
        res.set_content("{\"status\":\"error\",\"message\":\"Unexpected response from Microsoft\"}", "application/json");
        return;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    if (utils.jsonString(obj, "error")) |code| {
        if (std.mem.eql(u8, code, "authorization_pending") or std.mem.eql(u8, code, "slow_down")) {
            res.set_content("{\"status\":\"pending\"}", "application/json");
            return;
        }
        const msg = std.fmt.allocPrint(
            allocator,
            "{{\"status\":\"error\",\"message\":\"Sign-in error: {s}\"}}",
            .{code},
        ) catch "{\"status\":\"error\",\"message\":\"Sign-in error\"}";
        res.set_content(msg, "application/json");
        return;
    }

    const token_for_claims = blk: {
        if (utils.jsonString(obj, "id_token")) |t| break :blk t;
        break :blk utils.jsonString(obj, "access_token") orelse {
            res.set_content("{\"status\":\"pending\"}", "application/json");
            return;
        };
    };

    const username = utils.jwtStringClaim(allocator, token_for_claims, "preferred_username") catch
        utils.jwtStringClaim(allocator, token_for_claims, "upn") catch {
        res.set_content("{\"status\":\"error\",\"message\":\"Could not determine your identity\"}", "application/json");
        return;
    };

    const username_z = allocator.dupeZ(u8, username) catch {
        res.set_content("{\"status\":\"error\",\"message\":\"Could not create your account\"}", "application/json");
        return;
    };

    var db = sqlite3.initRW(session.dbPath) catch {
        res.set_content("{\"status\":\"error\",\"message\":\"Database error\"}", "application/json");
        return;
    };
    defer db.deinit();

    const exists = utils.userExists(&db, username_z) catch {
        res.set_content("{\"status\":\"error\",\"message\":\"Database error\"}", "application/json");
        return;
    };

    if (!exists) {
        utils.provisionUser(allocator, &db, username_z) catch {
            res.set_content("{\"status\":\"error\",\"message\":\"Could not create your account\"}", "application/json");
            return;
        };
    }

    const token = session.createSession(allocator, &db, username_z) catch {
        res.set_content("{\"status\":\"error\",\"message\":\"Could not create a session\"}", "application/json");
        return;
    };

    res.set_cookie(utils.sessionCookie(token, session.session_lifetime_seconds));
    res.set_content("{\"status\":\"ok\",\"redirect\":\"/peachfuzz/home\"}", "application/json");
}
