const std = @import("std");

fn cppFlags(comptime standard: []const u8, target: std.Build.ResolvedTarget) []const []const u8 {
    _ = target;
    return &.{standard};
}

fn linkCpp(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    _ = target;
    module.link_libcpp = true;
}

inline fn buildHttplib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const httplib = b.addModule("httplib", .{
        .root_source_file = b.path("src/httplib.zig"),
        .target = target,
        .optimize = optimize,
    });

    httplib.addIncludePath(b.path("3rdparty"));
    httplib.addIncludePath(b.path("src"));
    httplib.addCSourceFile(.{
        .file = b.path("src/httplibshim.cpp"),
        .flags = cppFlags("-std=c++23", target),
        .language = .cpp,
    });
    linkCpp(httplib, target);

    return httplib;
}

inline fn buildMustache(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const mustache = b.addModule("mustache", .{
        .root_source_file = b.path("src/mustache.zig"),
        .target = target,
        .optimize = optimize,
    });

    mustache.addIncludePath(b.path("3rdparty"));
    mustache.addIncludePath(b.path("src"));
    mustache.addCSourceFile(.{
        .file = b.path("src/mustacheshim.cpp"),
        .flags = cppFlags("-std=c++23", target),
        .language = .cpp,
    });
    linkCpp(mustache, target);

    return mustache;
}

inline fn buildSqlite3(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const sqlite3 = b.addModule("sqlite3", .{
        .root_source_file = b.path("src/sqlite3.zig"),
        .target = target,
        .optimize = optimize,
    });

    sqlite3.link_libc = true;
    sqlite3.linkSystemLibrary("sqlite3", .{});

    return sqlite3;
}

inline fn buildPeachfuzz(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    httplib: *std.Build.Module,
    mustache: *std.Build.Module,
    sqlite3: *std.Build.Module,
) *std.Build.Module {
    const peachfuzz = b.addModule("peachfuzz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "httplib", .module = httplib },
            .{ .name = "mustache", .module = mustache },
            .{ .name = "sqlite3", .module = sqlite3 },
        },
    });
    peachfuzz.addImport("peachfuzz", peachfuzz);
    peachfuzz.addIncludePath(b.path("src/peachfuzz/engine"));
    peachfuzz.addCSourceFile(.{
        .file = b.path("src/peachfuzz/engine/backend.cpp"),
        .flags = cppFlags("-std=c++23", target),
        .language = .cpp,
    });
    linkCpp(peachfuzz, target);
    peachfuzz.link_libc = true;
    return peachfuzz;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const duckdb_prefix = b.option([]const u8, "duckdb-prefix", "Path to DuckDB installation prefix") orelse "/opt/homebrew";

    const httplib = buildHttplib(b, target, optimize);
    const mustache = buildMustache(b, target, optimize);
    const sqlite3 = buildSqlite3(b, target, optimize);
    const peachfuzz = buildPeachfuzz(b, target, httplib, mustache, sqlite3);

    const exe = b.addExecutable(.{
        .name = "peachfuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "peachfuzz", .module = peachfuzz },
                .{ .name = "httplib", .module = httplib },
            },
        }),
    });

    b.installArtifact(exe);

    const cmd_datamark_clone = b.addExecutable(.{
        .name = "peachfuzz-cmd_datamark-clone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/peachfuzz-cmd_datamark-clone.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cmd_datamark_clone.root_module.link_libc = true;
    cmd_datamark_clone.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(cmd_datamark_clone);

    const cmd_datamark_flush = b.addExecutable(.{
        .name = "peachfuzz-cmd_datamark-flush",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/peachfuzz-cmd_datamark-flush.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cmd_datamark_flush.root_module.link_libc = true;
    cmd_datamark_flush.root_module.linkSystemLibrary("sqlite3", .{});
    cmd_datamark_flush.root_module.linkSystemLibrary("duckdb", .{});
    cmd_datamark_flush.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{duckdb_prefix}) });
    cmd_datamark_flush.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{duckdb_prefix}) });
    b.installArtifact(cmd_datamark_flush);

    const check_step = b.step("check", "Check if it compiles");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&cmd_datamark_clone.step);
    check_step.dependOn(&cmd_datamark_flush.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = peachfuzz,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const httplib_tests = b.addTest(.{
        .root_module = httplib,
    });

    const run_httplib_tests = b.addRunArtifact(httplib_tests);

    const mustache_tests = b.addTest(.{
        .root_module = mustache,
    });

    const run_mustache_tests = b.addRunArtifact(mustache_tests);

    const sqlite3_tests = b.addTest(.{
        .root_module = sqlite3,
    });

    const run_sqlite3_tests = b.addRunArtifact(sqlite3_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_httplib_tests.step);
    test_step.dependOn(&run_mustache_tests.step);
    test_step.dependOn(&run_sqlite3_tests.step);
}
