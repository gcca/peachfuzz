const httplib = @import("httplib");

const indexGet = @import("handlers/index-get.zig").indexGet;
const signInGet = @import("handlers/signin-get.zig").signInGet;
const signInPost = @import("handlers/signin-post.zig").signInPost;
const signOut = @import("handlers/signout.zig").signOut;
const o365SignInGet = @import("handlers/o365-signin-get.zig").o365SignInGet;
const o365ValidatePost = @import("handlers/o365-validate-post.zig").o365ValidatePost;

pub fn initRoutes(server: httplib.Server) void {
    _ = server
        .Get("/peachfuzz/auth/signin", signInGet)
        .Post("/peachfuzz/auth/signin", signInPost)
        .Get("/peachfuzz/auth/signout", signOut)
        .Get("/peachfuzz/auth/o365/signin", o365SignInGet)
        .Post("/peachfuzz/auth/o365/validate", o365ValidatePost)
        .Get("/peachfuzz/auth", indexGet);
}
