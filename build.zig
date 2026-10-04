const std = @import("std");
const Translator = @import("translate_c").Translator;

fn translateHeader(
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: std.Build.LazyPath,
) Translator {
    return .init(translate_c, .{
        .name = name,
        .c_source_file = source,
        .target = target,
        .optimize = optimize,
    });
}

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

fn translateSqlite(
    b: *std.Build,
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Translator {
    const header = b.addWriteFiles().add("sqlite3-import.h",
        \\#include <sqlite3.h>
        \\
    );
    const translated: Translator = .init(translate_c, .{
        .name = "sqlite3",
        .c_source_file = header,
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{.{ .name = "sqlite3" }},
    });
    if (target.result.os.tag == .linux) {
        translated.mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        translated.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    }
    return translated;
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

inline fn buildHttplib(
    b: *std.Build,
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const httplib = b.addModule("httplib", .{
        .root_source_file = b.path("src/httplib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const c = translateHeader(translate_c, target, optimize, "httplib", b.path("src/httplibshim.hpp"));
    httplib.addImport("c", c.mod);

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

inline fn buildMustache(
    b: *std.Build,
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const mustache = b.addModule("mustache", .{
        .root_source_file = b.path("src/mustache.zig"),
        .target = target,
        .optimize = optimize,
    });
    const c = translateHeader(translate_c, target, optimize, "mustache", b.path("src/mustacheshim.hpp"));
    mustache.addImport("c", c.mod);

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

inline fn buildSqlite3(
    b: *std.Build,
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const sqlite3 = b.addModule("sqlite3", .{
        .root_source_file = b.path("src/sqlite3.zig"),
        .target = target,
        .optimize = optimize,
    });
    const c = translateSqlite(b, translate_c, target, optimize);
    sqlite3.addImport("c", c.mod);

    return sqlite3;
}

inline fn buildGrpc(
    b: *std.Build,
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const grpc = b.addModule("grpc", .{
        .root_source_file = b.path("src/grpc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const c = translateHeader(translate_c, target, optimize, "grpc", b.path("src/grpcshim.hpp"));
    grpc.addImport("c", c.mod);

    grpc.addIncludePath(b.path("src"));
    addGrpcShim(b, grpc, target);
    linkGrpc(b, grpc);

    return grpc;
}

inline fn buildPeachfuzz(
    b: *std.Build,
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    httplib: *std.Build.Module,
    mustache: *std.Build.Module,
    sqlite3: *std.Build.Module,
    grpc: *std.Build.Module,
) *std.Build.Module {
    const peachfuzz = b.addModule("peachfuzz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httplib", .module = httplib },
            .{ .name = "mustache", .module = mustache },
            .{ .name = "sqlite3", .module = sqlite3 },
            .{ .name = "grpc", .module = grpc },
        },
    });
    const c = translateHeader(translate_c, target, optimize, "engine", b.path("src/peachfuzz/engine/backend.hpp"));
    peachfuzz.addImport("c", c.mod);
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

    const translate_c = b.dependency("translate_c", .{});
    const httplib = buildHttplib(b, translate_c, target, optimize);
    const mustache = buildMustache(b, translate_c, target, optimize);
    const sqlite3 = buildSqlite3(b, translate_c, target, optimize);
    const grpc = buildGrpc(b, translate_c, target, optimize);
    const peachfuzz = buildPeachfuzz(b, translate_c, target, optimize, httplib, mustache, sqlite3, grpc);

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

    const check_step = b.step("check", "Check if it compiles");
    check_step.dependOn(&exe.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

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
