const std = @import("std");

const c = @cImport({
    @cInclude("backend.hpp");
});

pub const Engine = enum(i64) {
    native = 0,
    chai = 1,
    eta = 2,
    python = 3,
    nodejs = 4,
    lua = 5,
};

const EngineFn = *const fn (allocator: std.mem.Allocator, body: [:0]const u8, args: []const [:0]const u8) [:0]const u8;

fn RunEmpty(allocator: std.mem.Allocator, body: [:0]const u8, args: []const [:0]const u8) [:0]const u8 {
    _ = allocator;
    _ = body;
    _ = args;
    return "";
}

fn RunPython(allocator: std.mem.Allocator, body: [:0]const u8, args: []const [:0]const u8) [:0]const u8 {
    const c_args = allocator.alloc([*c]const u8, args.len) catch return "";
    defer allocator.free(c_args);
    for (args, 0..) |arg, i| c_args[i] = arg.ptr;

    const args_ptr: [*c]const [*c]const u8 = if (args.len == 0) null else c_args.ptr;
    const ptr = c.engine_python_run(body.ptr, args_ptr, args.len) orelse return "";
    defer c.engine_python_free(ptr);
    return allocator.dupeZ(u8, std.mem.span(ptr)) catch "";
}

const EngineMap = std.EnumArray(Engine, EngineFn).init(.{
    .native = RunEmpty,
    .chai = RunEmpty,
    .eta = RunEmpty,
    .python = RunPython,
    .nodejs = RunEmpty,
    .lua = RunEmpty,
});

fn engineFromId(engine_id: i64) ?Engine {
    inline for (std.meta.fields(Engine)) |field| {
        if (field.value == engine_id) return @enumFromInt(engine_id);
    }
    return null;
}

pub fn Run(allocator: std.mem.Allocator, engine_id: i64, body: [:0]const u8, args: []const [:0]const u8) [:0]const u8 {
    const engine = engineFromId(engine_id) orelse {
        std.debug.print("unknown engine id: {d}\n", .{engine_id});
        return "";
    };

    return EngineMap.get(engine)(allocator, body, args);
}

test "unknown engine returns empty" {
    const out = Run(std.testing.allocator, 99, "print(1)", &.{});
    try std.testing.expectEqualStrings("", out);
}

test "empty engines return empty" {
    inline for (.{ Engine.native, Engine.chai, Engine.eta, Engine.nodejs, Engine.lua }) |engine| {
        const out = Run(std.testing.allocator, @intFromEnum(engine), "print(1)", &.{});
        try std.testing.expectEqualStrings("", out);
    }
}

test "python returns stdout" {
    const out = Run(std.testing.allocator, @intFromEnum(Engine.python), "print('hello')", &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "python receives command args as sys.argv" {
    const out = Run(
        std.testing.allocator,
        @intFromEnum(Engine.python),
        "import sys; print(' '.join(sys.argv[1:]))",
        &.{ "region=north", "days=30" },
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("region=north days=30\n", out);
}

test "python non-zero exit returns empty" {
    const out = Run(std.testing.allocator, @intFromEnum(Engine.python), "raise SystemExit(1)", &.{});
    try std.testing.expectEqualStrings("", out);
}

test "python syntax error returns empty" {
    const out = Run(std.testing.allocator, @intFromEnum(Engine.python), "def", &.{});
    try std.testing.expectEqualStrings("", out);
}
