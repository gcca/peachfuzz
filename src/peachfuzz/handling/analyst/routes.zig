const httplib = @import("httplib");

pub fn initRoutes(server: httplib.Server) void {
    _ = server
        .Get("/peachfuzz/analyst", @import("handlers/analyst-get.zig").analystGet)
        .Get("/peachfuzz/analyst/pages/:name", @import("handlers/page-get.zig").pageGet);
}
