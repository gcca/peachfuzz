const std = @import("std");

const c = @cImport({
    @cInclude("grpcshim.hpp");
});

const timeout_ms: c_int = 5000;

pub const UserInfo = struct {
    is_active: bool,
    apps: []const []const u8,

    pub fn deinit(self: UserInfo, allocator: std.mem.Allocator) void {
        for (self.apps) |app| allocator.free(app);
        allocator.free(self.apps);
    }
};

pub const UserInfoResponse = struct {
    userinfo: ?UserInfo,

    pub fn deinit(self: UserInfoResponse, allocator: std.mem.Allocator) void {
        if (self.userinfo) |info| info.deinit(allocator);
    }
};

pub const AuthenticateResponse = struct {
    authenticated: bool,
    userinfo: ?UserInfo,

    pub fn deinit(self: AuthenticateResponse, allocator: std.mem.Allocator) void {
        if (self.userinfo) |info| info.deinit(allocator);
    }
};

pub const Client = struct {
    handle: *c.GrpcClient,

    pub fn init(target: [:0]const u8) !Client {
        const handle = c.grpc_client_create(target.ptr) orelse return error.GrpcClientInitFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Client) void {
        c.grpc_client_destroy(self.handle);
    }

    pub fn userInfo(self: Client, allocator: std.mem.Allocator, username: [:0]const u8) !UserInfoResponse {
        const result = c.grpc_auth_user_info(self.handle, username.ptr, timeout_ms);
        defer c.grpc_user_info_result_destroy(result);

        if (result.status != 0) return callError(result.status);

        return .{
            .userinfo = if (result.has_userinfo != 0)
                try cloneUserInfo(allocator, result.userinfo)
            else
                null,
        };
    }

    pub fn authenticate(self: Client, allocator: std.mem.Allocator, username: [:0]const u8, password: [:0]const u8) !AuthenticateResponse {
        const result = c.grpc_auth_authenticate(self.handle, username.ptr, password.ptr, timeout_ms);
        defer c.grpc_authenticate_result_destroy(result);

        if (result.status != 0) return callError(result.status);

        return .{
            .authenticated = result.authenticated != 0,
            .userinfo = if (result.has_userinfo != 0)
                try cloneUserInfo(allocator, result.userinfo)
            else
                null,
        };
    }
};

fn cloneUserInfo(allocator: std.mem.Allocator, info: c.UrmomUserInfo) !UserInfo {
    const apps = try allocator.alloc([]const u8, info.apps_len);
    errdefer allocator.free(apps);

    var filled: usize = 0;
    errdefer for (apps[0..filled]) |app| allocator.free(app);

    while (filled < info.apps_len) : (filled += 1) {
        apps[filled] = try allocator.dupe(u8, std.mem.span(info.apps[filled]));
    }

    return .{
        .is_active = info.is_active != 0,
        .apps = apps,
    };
}

fn callError(status: c_int) anyerror {
    return switch (status) {
        3 => error.InvalidArgument,
        4 => error.DeadlineExceeded,
        5 => error.NotFound,
        13 => error.Internal,
        14 => error.Unavailable,
        16 => error.Unauthenticated,
        else => error.GrpcCallFailed,
    };
}
