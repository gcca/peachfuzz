const std = @import("std");

const httplib = @import("httplib");

const utils = @import("../utils.zig");

pub fn o365SignInGet(req: httplib.Request, res: httplib.Response) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (utils.hasSession(allocator, req)) {
        res.set_redirect(utils.home_path);
        return;
    }

    const config = utils.loadO365Config() orelse {
        utils.renderO365SignIn(allocator, res, "O365 sign-in is not configured on this server.", null, null, null);
        return;
    };

    const url = std.fmt.allocPrint(
        allocator,
        "https://login.microsoftonline.com/{s}/oauth2/v2.0/devicecode",
        .{config.tenant_id},
    ) catch {
        utils.renderO365SignIn(allocator, res, "Could not reach Microsoft. Try again.", null, null, null);
        return;
    };
    const body = std.fmt.allocPrint(
        allocator,
        "client_id={s}&scope=openid+profile+User.Read",
        .{config.client_id},
    ) catch {
        utils.renderO365SignIn(allocator, res, "Could not reach Microsoft. Try again.", null, null, null);
        return;
    };

    const outcome = utils.postForm(allocator, url, body) catch {
        utils.renderO365SignIn(allocator, res, "Could not reach Microsoft. Try again.", null, null, null);
        return;
    };

    if (!outcome.status_ok) {
        utils.renderO365SignIn(allocator, res, "Microsoft returned an error. Try again.", null, null, null);
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, outcome.body, .{}) catch {
        utils.renderO365SignIn(allocator, res, "Unexpected response from Microsoft.", null, null, null);
        return;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const user_code = utils.jsonString(obj, "user_code") orelse {
        utils.renderO365SignIn(allocator, res, "Unexpected response from Microsoft.", null, null, null);
        return;
    };
    const verification_uri = utils.jsonString(obj, "verification_uri") orelse {
        utils.renderO365SignIn(allocator, res, "Unexpected response from Microsoft.", null, null, null);
        return;
    };
    const device_code = utils.jsonString(obj, "device_code") orelse {
        utils.renderO365SignIn(allocator, res, "Unexpected response from Microsoft.", null, null, null);
        return;
    };

    utils.renderO365SignIn(allocator, res, null, user_code, verification_uri, device_code);
}
