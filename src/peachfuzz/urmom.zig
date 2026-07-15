const std = @import("std");

const grpc = @import("grpc");

pub const UserInfo = grpc.UserInfo;
pub const UserInfoResponse = grpc.UserInfoResponse;
pub const AuthenticateResponse = grpc.AuthenticateResponse;

pub const UserInfoRequest = struct {
    username: []const u8,
};

pub const AuthenticateRequest = struct {
    username: []const u8,
    password: []const u8,
};

/// Returned responses own memory from this allocator and must be deinitialized with it.
pub const AuthClient = struct {
    allocator: std.mem.Allocator,
    client: grpc.Client,

    pub fn init(allocator: std.mem.Allocator, target: [:0]const u8) !AuthClient {
        return .{
            .allocator = allocator,
            .client = try grpc.Client.init(target),
        };
    }

    pub fn deinit(self: *AuthClient) void {
        self.client.deinit();
    }

    pub fn UserInfo(self: AuthClient, request: UserInfoRequest) !UserInfoResponse {
        const username = try self.allocator.dupeZ(u8, request.username);
        defer self.allocator.free(username);

        return self.client.userInfo(self.allocator, username);
    }

    pub fn Authenticate(self: AuthClient, request: AuthenticateRequest) !AuthenticateResponse {
        const username = try self.allocator.dupeZ(u8, request.username);
        defer self.allocator.free(username);

        const password = try self.allocator.dupeZ(u8, request.password);
        defer self.allocator.free(password);

        return self.client.authenticate(self.allocator, username, password);
    }
};

test "auth client constructs and tears down" {
    var client = try AuthClient.init(std.testing.allocator, "127.0.0.1:50051");
    client.deinit();
}
