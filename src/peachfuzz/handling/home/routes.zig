const httplib = @import("httplib");

const homeGet = @import("handlers/home-get.zig").homeGet;

pub fn initRoutes(server: httplib.Server) void {
    _ = server.Get("/peachfuzz/home", homeGet);
}
