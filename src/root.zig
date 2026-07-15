pub const handling = struct {
    pub const auth = struct {
        pub const routes = @import("peachfuzz/handling/auth/routes.zig");
        pub const session = @import("peachfuzz/handling/auth/session.zig");
        pub const accessly = @import("peachfuzz/handling/auth/accessly.zig");
    };
    pub const home = struct {
        pub const routes = @import("peachfuzz/handling/home/routes.zig");
    };
    pub const analyst = struct {
        pub const routes = @import("peachfuzz/handling/analyst/routes.zig");
    };
};

pub const engine = struct {
    pub const runtime = @import("peachfuzz/engine/runtime.zig");
};

pub const sqlite3 = @import("sqlite3");
