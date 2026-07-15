const httplib = @import("httplib");

const analystGet = @import("handlers/analyst-get.zig").analystGet;
const pageGet = @import("handlers/page-get.zig").pageGet;

pub fn initRoutes(server: httplib.Server) void {
    _ = server
        .Get("/peachfuzz/analyst", analystGet)
        .Get("/peachfuzz/analyst/pages/:name", pageGet);
}
