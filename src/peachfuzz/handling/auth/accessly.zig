pub const Role = enum(i64) {
    root = 0,
    admin = 1,
    staff = 2,
    analyst = 3,
};

pub fn roleLabel(role: Role) []const u8 {
    return switch (role) {
        .root => "root",
        .admin => "admin",
        .staff => "staff",
        .analyst => "analyst",
    };
}

pub fn roleFromInt(value: i64) ?Role {
    return switch (value) {
        0 => .root,
        1 => .admin,
        2 => .staff,
        3 => .analyst,
        else => null,
    };
}
