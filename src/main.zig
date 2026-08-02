const std = @import("std");
const sqlite = @import("sqlite.zig");
const db_mod = @import("db.zig");
const server = @import("server.zig");
const archive = @import("archive.zig");

const Args = struct {
    db: [:0]const u8 = "vinboard.db",
    port: u16 = 4670,
    base_path: []const u8 = "",
};

fn parseArgs(alloc: std.mem.Allocator, args: std.process.Args) !Args {
    var a = Args{};
    var it = args.iterate();
    _ = it.next(); // exe name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--db")) {
            a.db = try alloc.dupeZ(u8, it.next().?);
        } else if (std.mem.eql(u8, arg, "--port")) {
            a.port = try std.fmt.parseInt(u16, it.next().?, 10);
        } else if (std.mem.eql(u8, arg, "--base-path")) {
            a.base_path = try alloc.dupe(u8, it.next().?);
        }
    }
    return a;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try parseArgs(gpa, init.minimal.args);

    var db = try sqlite.Db.open(args.db);
    defer db.close();
    try db_mod.migrate(&db);

    var mutex = std.Io.Mutex.init;
    var app = server.App{
        .gpa = gpa,
        .db = &db,
        .db_mutex = &mutex,
        .base_path = args.base_path,
        .io = init.io,
    };

    var worker = archive.Worker{ .app = &app, .archiver_cmd = "single-file" };
    const th = try std.Thread.spawn(.{}, archive.Worker.run, .{&worker});
    th.detach();

    try server.start(&app, init.io, args.port);
}

test {
    _ = @import("sqlite.zig");
    _ = @import("db.zig");
    _ = @import("strip.zig");
    _ = @import("import.zig");
    _ = @import("archive.zig");
    _ = @import("html.zig");
    _ = @import("pinboard_compat.zig");
    _ = @import("web.zig");
}
