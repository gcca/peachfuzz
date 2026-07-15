const httplib = @import("httplib");

pub fn initRoutes(server: httplib.Server) void {
    _ = server
        .Get("/peachfuzz/auth/signin", @import("handlers/signin-get.zig").signInGet)
        .Post("/peachfuzz/auth/signin", @import("handlers/signin-post.zig").signInPost)
        .Get("/peachfuzz/auth/signout", @import("handlers/signout.zig").signOut)
        .Get("/peachfuzz/auth/o365/signin", @import("handlers/o365-signin-get.zig").o365SignInGet)
        .Post("/peachfuzz/auth/o365/validate", @import("handlers/o365-validate-post.zig").o365ValidatePost)
        .Get("/peachfuzz/auth", @import("handlers/index-get.zig").indexGet);
}
