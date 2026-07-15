const std = @import("std");

const c = @cImport({
    @cInclude("mustacheshim.hpp");
});

const RenderCtx = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
};

fn RenderHandler(p: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const ctx: *RenderCtx = @ptrCast(@alignCast(p.?));
    ctx.buf.appendSlice(ctx.allocator, data[0..len]) catch @panic("OOM");
}

pub const Mustache = struct {
    mustache: *c.Mustache,
    allocator: std.mem.Allocator,
    mem: []u8,
    memalign: std.mem.Alignment,

    pub fn init(allocator: std.mem.Allocator, s: [:0]const u8) Mustache {
        const memlen: usize = c.MustacheSize;
        const memalign = std.mem.Alignment.fromByteUnits(c.MustacheAlign);
        const memptr = allocator.rawAlloc(memlen, memalign, @returnAddress()) orelse @panic("OOM");
        const mem = memptr[0..memlen];
        return .{
            .mustache = c.mustache_init(mem.ptr, s.ptr).?,
            .allocator = allocator,
            .mem = mem,
            .memalign = memalign,
        };
    }

    pub fn deinit(self: *Mustache) void {
        c.mustache_deinit(self.mustache);
        self.allocator.rawFree(self.mem, self.memalign, @returnAddress());
    }

    pub fn Render(self: *Mustache, data: Data) [:0]u8 {
        var ctx: RenderCtx = .{ .allocator = self.allocator, .buf = .empty };
        c.mustache_render(self.mustache, data.data, RenderHandler, &ctx);
        return ctx.buf.toOwnedSliceSentinel(self.allocator, 0) catch @panic("OOM");
    }
};

pub const Data = struct {
    data: *c.Data,
    allocator: std.mem.Allocator,
    mem: []u8,
    memalign: std.mem.Alignment,

    pub fn init(allocator: std.mem.Allocator) Data {
        const memlen: usize = c.DataSize;
        const memalign = std.mem.Alignment.fromByteUnits(c.DataAlign);
        const memptr = allocator.rawAlloc(memlen, memalign, @returnAddress()) orelse @panic("OOM");
        const mem = memptr[0..memlen];
        return .{
            .data = c.data_init(mem.ptr).?,
            .allocator = allocator,
            .mem = mem,
            .memalign = memalign,
        };
    }

    pub fn deinit(self: Data) void {
        c.data_deinit(self.data);
        self.allocator.rawFree(self.mem, self.memalign, @returnAddress());
    }

    pub fn setString(self: Data, s: [:0]const u8, v: [:0]const u8) void {
        c.data_setstring(self.data, s.ptr, v.ptr);
    }

    pub fn setBool(self: Data, s: [:0]const u8, v: bool) void {
        c.data_setbool(self.data, s.ptr, v);
    }

    pub fn setData(self: Data, s: [:0]const u8, v: Data) void {
        c.data_setdata(self.data, s.ptr, v.data);
    }
};

test "data single string" {
    var m = Mustache.init(std.testing.allocator, "hello {{ test }}world");
    defer m.deinit();

    var d = Data.init(std.testing.allocator);
    defer d.deinit();

    d.setString("test", "outer");

    const rendered = m.Render(d);

    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("hello outerworld", rendered);
}

test "data single boolean:true" {
    var m = Mustache.init(std.testing.allocator, "hello {{# test }}world{{/ test }}");
    defer m.deinit();

    var d = Data.init(std.testing.allocator);
    defer d.deinit();

    d.setBool("test", true);

    const rendered = m.Render(d);

    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("hello world", rendered);
}

test "data single boolean:false" {
    var m = Mustache.init(std.testing.allocator, "hello {{# test }}world{{/ test }}");
    defer m.deinit();

    var d = Data.init(std.testing.allocator);
    defer d.deinit();

    d.setBool("test", false);

    const rendered = m.Render(d);

    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("hello ", rendered);
}

test "data nested object" {
    var m = Mustache.init(std.testing.allocator, "hello {{ user.name }}");
    defer m.deinit();

    var outer = Data.init(std.testing.allocator);
    defer outer.deinit();

    var user = Data.init(std.testing.allocator);
    defer user.deinit();

    user.setString("name", "peach");
    outer.setData("user", user);

    const rendered = m.Render(outer);

    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("hello peach", rendered);
}
