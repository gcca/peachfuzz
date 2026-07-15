const std = @import("std");

pub const SaltLen = 16;
pub const PasswordHashLen = 32;
pub const StoredPasswordLen = SaltLen + PasswordHashLen;

fn argon2Params(username: []const u8) std.crypto.pwhash.argon2.Params {
    return .{
        .t = 3,
        .m = 65536,
        .p = 1,
        .ad = username,
    };
}

pub fn hashPasswordInto(
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
    out: *[StoredPasswordLen]u8,
) !void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    io.random(out[0..SaltLen]);

    try std.crypto.pwhash.argon2.kdf(
        allocator,
        out[SaltLen..],
        password,
        out[0..SaltLen],
        argon2Params(username),
        .argon2id,
        io,
    );
}

pub fn checkPassword(
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
    stored: []const u8,
) !bool {
    if (stored.len != StoredPasswordLen) return error.InvalidLength;

    const salt = stored[0..SaltLen];
    const expected = stored[SaltLen..];

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var hash: [PasswordHashLen]u8 = undefined;
    try std.crypto.pwhash.argon2.kdf(
        allocator,
        &hash,
        password,
        salt,
        argon2Params(username),
        .argon2id,
        io,
    );

    return std.crypto.timing_safe.eql([PasswordHashLen]u8, hash, expected[0..PasswordHashLen].*);
}

test "hash and check password round trip" {
    var stored: [StoredPasswordLen]u8 = undefined;
    try hashPasswordInto(std.testing.allocator, "admin", "changeme", &stored);
    try std.testing.expect(try checkPassword(std.testing.allocator, "admin", "changeme", &stored));
    try std.testing.expect(!try checkPassword(std.testing.allocator, "admin", "wrong", &stored));
}
