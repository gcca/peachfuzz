const std = @import("std");

fn cppFlags(comptime standard: []const u8, target: std.Build.ResolvedTarget) []const []const u8 {
    _ = target;
    return &.{standard};
}

fn linkCpp(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    _ = target;
    module.link_libcpp = true;
}

// Resolve grpc++ and protobuf in a single pkg-config pass so their overlapping
// abseil libraries are deduplicated: two separate pkg-config expansions emit the
// same dylib twice, which macOS dyld rejects as a duplicate load command.
fn linkGrpc(b: *std.Build, module: *std.Build.Module) void {
    var includes = std.mem.tokenizeScalar(u8, b.run(&.{ "pkg-config", "--cflags", "grpc++", "protobuf" }), ' ');
    while (includes.next()) |token| {
        const flag = std.mem.trim(u8, token, " \r\n\t");
        if (std.mem.startsWith(u8, flag, "-I")) module.addSystemIncludePath(.{ .cwd_relative = flag[2..] });
    }

    var libs = std.mem.tokenizeScalar(u8, b.run(&.{ "pkg-config", "--libs", "grpc++", "protobuf" }), ' ');
    while (libs.next()) |token| {
        const flag = std.mem.trim(u8, token, " \r\n\t");
        if (std.mem.startsWith(u8, flag, "-L")) {
            module.addLibraryPath(.{ .cwd_relative = flag[2..] });
        } else if (std.mem.startsWith(u8, flag, "-l")) {
            module.linkSystemLibrary(flag[2..], .{ .use_pkg_config = .no });
        } else if (std.mem.eql(u8, flag, "-framework")) {
            if (libs.next()) |name| module.linkFramework(std.mem.trim(u8, name, " \r\n\t"), .{});
        }
    }
}

fn linkSqlite3(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .linux) {
        module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    }
    module.linkSystemLibrary("sqlite3", .{});
}

fn generateProto(b: *std.Build) std.Build.LazyPath {
    const generate = b.addSystemCommand(&.{
        "sh",
        "-c",
        "protoc -I protos --cpp_out=\"$1\" --grpc_out=\"$1\" --plugin=protoc-gen-grpc=$(command -v grpc_cpp_plugin) protos/auth.proto",
        "generate-proto",
    });
    generate.addFileInput(b.path("protos/auth.proto"));
    return generate.addOutputDirectoryArg("proto");
}

fn addGrpcObject(
    b: *std.Build,
    grpc: *std.Build.Module,
    gendir: std.Build.LazyPath,
    source: std.Build.LazyPath,
    name: []const u8,
    header: ?std.Build.LazyPath,
) void {
    const compile = b.addSystemCommand(&.{
        "sh",
        "-c",
        "g++ -std=c++20 $(pkg-config --cflags grpc++ protobuf) -I src -I \"$1\" -c \"$2\" -o \"$3\"",
        "compile-grpc-object",
    });
    compile.addDirectoryArg(gendir);
    compile.addFileArg(source);
    if (header) |path| compile.addFileInput(path);
    grpc.addObjectFile(compile.addOutputFileArg(name));
}

fn addGrpcShim(b: *std.Build, grpc: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const gendir = generateProto(b);
    grpc.addIncludePath(gendir);

    if (target.result.os.tag == .linux) {
        addGrpcObject(b, grpc, gendir, b.path("src/grpcshim.cpp"), "grpcshim.o", b.path("src/grpcshim.hpp"));
        addGrpcObject(b, grpc, gendir, gendir.path(b, "auth.pb.cc"), "auth.pb.o", null);
        addGrpcObject(b, grpc, gendir, gendir.path(b, "auth.grpc.pb.cc"), "auth.grpc.pb.o", null);

        const libstdcxx = std.mem.trim(u8, b.run(&.{
            "g++",
            "-print-file-name=libstdc++.so.6",
        }), " \r\n\t");
        if (!std.fs.path.isAbsolute(libstdcxx)) @panic("g++ could not locate libstdc++.so.6");
        grpc.addObjectFile(.{ .cwd_relative = libstdcxx });
    } else {
        for ([_]std.Build.LazyPath{
            b.path("src/grpcshim.cpp"),
            gendir.path(b, "auth.pb.cc"),
            gendir.path(b, "auth.grpc.pb.cc"),
        }) |source| {
            grpc.addCSourceFile(.{
                .file = source,
                .flags = cppFlags("-std=c++20", target),
                .language = .cpp,
            });
        }
        linkCpp(grpc, target);
    }
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
    linkSqlite3(sqlite3, target);

    return sqlite3;
}

inline fn buildGrpc(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const grpc = b.addModule("grpc", .{
        .root_source_file = b.path("src/grpc.zig"),
        .target = target,
        .optimize = optimize,
    });

    grpc.addIncludePath(b.path("src"));
    addGrpcShim(b, grpc, target);
    linkGrpc(b, grpc);

    return grpc;
}

inline fn buildPeachfuzz(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    httplib: *std.Build.Module,
    mustache: *std.Build.Module,
    sqlite3: *std.Build.Module,
    grpc: *std.Build.Module,
) *std.Build.Module {
    const peachfuzz = b.addModule("peachfuzz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "httplib", .module = httplib },
            .{ .name = "mustache", .module = mustache },
            .{ .name = "sqlite3", .module = sqlite3 },
            .{ .name = "grpc", .module = grpc },
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
    const grpc = buildGrpc(b, target, optimize);
    const peachfuzz = buildPeachfuzz(b, target, httplib, mustache, sqlite3, grpc);

    const exe = b.addExecutable(.{
        .name = "peachfuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "peachfuzz", .module = peachfuzz },
                .{ .name = "httplib", .module = httplib },
                .{ .name = "sqlite3", .module = sqlite3 },
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
    linkSqlite3(cmd_datamark_clone.root_module, target);
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
    linkSqlite3(cmd_datamark_flush.root_module, target);
    cmd_datamark_flush.root_module.linkSystemLibrary("duckdb", .{});
    cmd_datamark_flush.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{duckdb_prefix}) });
    cmd_datamark_flush.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{duckdb_prefix}) });
    b.installArtifact(cmd_datamark_flush);

    const cmd_datamark_update = b.addExecutable(.{
        .name = "peachfuzz-cmd_datamark-update",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/peachfuzz-cmd_datamark-update.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cmd_datamark_update.root_module.link_libc = true;
    linkSqlite3(cmd_datamark_update.root_module, target);
    cmd_datamark_update.root_module.linkSystemLibrary("duckdb", .{});
    cmd_datamark_update.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{duckdb_prefix}) });
    cmd_datamark_update.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{duckdb_prefix}) });
    b.installArtifact(cmd_datamark_update);

    const check_step = b.step("check", "Check if it compiles");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&cmd_datamark_clone.step);
    check_step.dependOn(&cmd_datamark_flush.step);
    check_step.dependOn(&cmd_datamark_update.step);

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
