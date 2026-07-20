const std = @import("std");

pub const Settings = struct {
    appname: [:0]const u8,
    dbname: [:0]const u8,
};

pub var settings: Settings = .{
    .appname = "Peachfuzz",
    .dbname = "data/peachfuzz.db",
};

pub fn load() void {
    settings = .{
        .appname = envAppName(),
        .dbname = envDbName(),
    };
}

fn envAppName() [:0]const u8 {
    const env = std.c.getenv("PEACHFUZZ_APPNAME") orelse return "Peachfuzz";
    const name = std.mem.span(env);
    if (name.len == 0) return "Peachfuzz";
    return name;
}

fn envDbName() [:0]const u8 {
    const env = std.c.getenv("PEACHFUZZ_DBNAME") orelse return "data/peachfuzz.db";
    const name = std.mem.span(env);
    if (name.len == 0) return "data/peachfuzz.db";
    return name;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "load defaults appname to Peachfuzz when PEACHFUZZ_APPNAME is unset" {
    _ = unsetenv("PEACHFUZZ_APPNAME");
    load();
    try std.testing.expectEqualStrings("Peachfuzz", settings.appname);
}

test "load reads appname from PEACHFUZZ_APPNAME when set" {
    _ = setenv("PEACHFUZZ_APPNAME", "Acme Corp", 1);
    defer _ = unsetenv("PEACHFUZZ_APPNAME");
    load();
    try std.testing.expectEqualStrings("Acme Corp", settings.appname);
}

test "load falls back to Peachfuzz when PEACHFUZZ_APPNAME is empty" {
    _ = setenv("PEACHFUZZ_APPNAME", "", 1);
    defer _ = unsetenv("PEACHFUZZ_APPNAME");
    load();
    try std.testing.expectEqualStrings("Peachfuzz", settings.appname);
}

test "load defaults dbname when PEACHFUZZ_DBNAME is unset" {
    _ = unsetenv("PEACHFUZZ_DBNAME");
    load();
    try std.testing.expectEqualStrings("data/peachfuzz.db", settings.dbname);
}

test "load reads dbname from PEACHFUZZ_DBNAME when set" {
    _ = setenv("PEACHFUZZ_DBNAME", "data/custom.db", 1);
    defer _ = unsetenv("PEACHFUZZ_DBNAME");
    load();
    try std.testing.expectEqualStrings("data/custom.db", settings.dbname);
}

test "load falls back to default dbname when PEACHFUZZ_DBNAME is empty" {
    _ = setenv("PEACHFUZZ_DBNAME", "", 1);
    defer _ = unsetenv("PEACHFUZZ_DBNAME");
    load();
    try std.testing.expectEqualStrings("data/peachfuzz.db", settings.dbname);
}
