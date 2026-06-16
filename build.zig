const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite(b, exe_module);
    exe_module.addImport("httpz", httpz.module("httpz"));

    const exe = b.addExecutable(.{
        .name = "vinboard",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run vinboard").dependOn(&run.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite(b, test_module);
    test_module.addImport("httpz", httpz.module("httpz"));

    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}

fn addSqlite(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("vendor"));
    m.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{ "-DSQLITE_ENABLE_FTS5", "-DSQLITE_THREADSAFE=1" },
    });
    m.addCSourceFile(.{
        .file = b.path("vendor/sqlite3_helpers.c"),
        .flags = &.{ "-DSQLITE_ENABLE_FTS5", "-DSQLITE_THREADSAFE=1" },
    });
    m.link_libc = true;
}
