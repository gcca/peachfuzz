const httplib = @import("httplib");

pub fn indexGet(_: httplib.Request, res: httplib.Response) void {
    res.set_redirect("/peachfuzz/auth/signin");
}
