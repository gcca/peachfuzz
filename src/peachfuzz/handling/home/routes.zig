const httplib = @import("httplib");

pub fn initRoutes(server: httplib.Server) void {
    _ = server.Get("/peachfuzz/home", @import("handlers/home-get.zig").homeGet);
}
