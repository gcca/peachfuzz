const std = @import("std");

pub const Settings = struct {
    appname: [:0]const u8,
    dbname: [:0]const u8,
    urmomTarget: [:0]const u8,
};

pub var settings: Settings = .{
    .appname = appname,
    .dbname = dbname,
    .urmomTarget = urmomTarget,
};

pub fn load() void {
    settings = .{
        .appname = envAppName(),
        .dbname = envDbName(),
        .urmomTarget = envUrmomTarget(),
    };
}

const appname: [:0]const u8 = "Peachfuzz";
const dbname: [:0]const u8 = "data/peachfuzz.db";
const urmomTarget: [:0]const u8 = "127.0.0.1:50051";

fn envAppName() [:0]const u8 {
    const env = std.c.getenv("PEACHFUZZ_APPNAME") orelse return appname;
    const name = std.mem.span(env);
    if (name.len == 0) return appname;
    return name;
}

fn envDbName() [:0]const u8 {
    const env = std.c.getenv("PEACHFUZZ_DBNAME") orelse return dbname;
    const name = std.mem.span(env);
    if (name.len == 0) return dbname;
    return name;
}

fn envUrmomTarget() [:0]const u8 {
    const env = std.c.getenv("PEACHFUZZ_URMOM_TARGET") orelse return urmomTarget;
    const name = std.mem.span(env);
    if (name.len == 0) return urmomTarget;
    return name;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "load defaults appname to Peachfuzz when PEACHFUZZ_APPNAME is unset" {
    _ = unsetenv("PEACHFUZZ_APPNAME");
    load();
    try std.testing.expectEqualStrings(appname, settings.appname);
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
    try std.testing.expectEqualStrings(appname, settings.appname);
}

test "load defaults dbname when PEACHFUZZ_DBNAME is unset" {
    _ = unsetenv("PEACHFUZZ_DBNAME");
    load();
    try std.testing.expectEqualStrings(dbname, settings.dbname);
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
    try std.testing.expectEqualStrings(dbname, settings.dbname);
}

test "load defaults urmomTarget when PEACHFUZZ_URMOM_TARGET is unset" {
    _ = unsetenv("PEACHFUZZ_URMOM_TARGET");
    load();
    try std.testing.expectEqualStrings(urmomTarget, settings.urmomTarget);
}

test "load reads urmomTarget from PEACHFUZZ_URMOM_TARGET when set" {
    _ = setenv("PEACHFUZZ_URMOM_TARGET", "urmom.internal:50051", 1);
    defer _ = unsetenv("PEACHFUZZ_URMOM_TARGET");
    load();
    try std.testing.expectEqualStrings("urmom.internal:50051", settings.urmomTarget);
}

test "load falls back to default urmomTarget when PEACHFUZZ_URMOM_TARGET is empty" {
    _ = setenv("PEACHFUZZ_URMOM_TARGET", "", 1);
    defer _ = unsetenv("PEACHFUZZ_URMOM_TARGET");
    load();
    try std.testing.expectEqualStrings(urmomTarget, settings.urmomTarget);
}
