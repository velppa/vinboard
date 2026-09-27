const std = @import("std");
const sqlite = @import("sqlite.zig");
const db_mod = @import("db.zig");
const server = @import("server.zig");
const archive = @import("archive.zig");
const auth = @import("auth.zig");

const suggest_key_name = "suggest_api_key";

const Args = struct {
    db: [:0]const u8 = "~/.local/state/vinboard/vinboard.db",
    port: u16 = 4670,
    base_path: []const u8 = "",
    archiver: []const u8 = "vinboard-archiver",
    shortcut_out: []const u8 = "",
    suggest_url: []const u8 = "",
    suggest_model: []const u8 = "typesafe/jev-1.13",
    set_suggest_key: ?[]const u8 = null,
    set_password: ?[2][]const u8 = null, // handle, password
};

const usage =
    \\vinboard — personal bookmark server
    \\
    \\usage: vinboard [options]
    \\
    \\options:
    \\  --db <path>         sqlite database file (default: ~/.local/state/vinboard/vinboard.db)
    \\  --port <port>       listen port (default: 4670)
    \\  --base-path <path>  url prefix emitted in pages, for reverse proxies (default: none)
    \\  --archiver <cmd>    page archiver command, must print html to stdout (default: single-file)
    \\  --shortcut-out <path>
    \\                      write the generated ios shortcut here and redirect to
    \\                      /vinboard.shortcut at the site root (default: serve inline)
    \\  --suggest-url <url> System One endpoint that suggests tags for untagged
    \\                      bookmarks, e.g.
    \\                      https://openrouter.ai/api/alpha/decisions (default: off)
    \\  --suggest-model <id>
    \\                      model to ask for (default: typesafe/jev-1.13)
    \\  --set-suggest-key <key>
    \\                      store the bearer token for that endpoint and exit
    \\  --set-password <handle> <password>
    \\                      set a user's password and exit
    \\  --help              show this help and exit
    \\
;

fn parseArgs(alloc: std.mem.Allocator, args: std.process.Args) !Args {
    var a = Args{};
    var it = args.iterate();
    _ = it.next(); // exe name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--db")) {
            a.db = try alloc.dupeZ(u8, it.next() orelse return error.MissingArgValue);
        } else if (std.mem.eql(u8, arg, "--port")) {
            a.port = try std.fmt.parseInt(u16, it.next() orelse return error.MissingArgValue, 10);
        } else if (std.mem.eql(u8, arg, "--base-path")) {
            a.base_path = try alloc.dupe(u8, it.next() orelse return error.MissingArgValue);
        } else if (std.mem.eql(u8, arg, "--archiver")) {
            a.archiver = try alloc.dupe(u8, it.next() orelse return error.MissingArgValue);
        } else if (std.mem.eql(u8, arg, "--shortcut-out")) {
            a.shortcut_out = try alloc.dupe(u8, it.next() orelse return error.MissingArgValue);
        } else if (std.mem.eql(u8, arg, "--suggest-url")) {
            a.suggest_url = try alloc.dupe(u8, it.next() orelse return error.MissingArgValue);
        } else if (std.mem.eql(u8, arg, "--suggest-model")) {
            a.suggest_model = try alloc.dupe(u8, it.next() orelse return error.MissingArgValue);
        } else if (std.mem.eql(u8, arg, "--set-suggest-key")) {
            a.set_suggest_key = try alloc.dupe(u8, it.next() orelse return error.MissingArgValue);
        } else if (std.mem.eql(u8, arg, "--set-password")) {
            const handle = try alloc.dupe(u8, it.next() orelse return error.MissingArgValue);
            const password = try alloc.dupe(u8, it.next() orelse return error.MissingArgValue);
            a.set_password = .{ handle, password };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else {
            std.debug.print("unknown option: {s}\n\n{s}", .{ arg, usage });
            std.process.exit(1);
        }
    }
    a.db = try expandTilde(alloc, a.db);
    return a;
}

// Expand a leading "~/" to $HOME; the path may reach sqlite3_open
// without ever passing through a shell.
fn expandTilde(alloc: std.mem.Allocator, path: [:0]const u8) ![:0]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return path;
    const home = std.mem.span(std.c.getenv("HOME") orelse return path);
    const buf = try alloc.allocSentinel(u8, home.len + path.len - 1, 0);
    @memcpy(buf[0..home.len], home);
    @memcpy(buf[home.len..], path[1..]);
    return buf;
}

test expandTilde {
    const alloc = std.testing.allocator;
    const home = std.mem.span(std.c.getenv("HOME").?);
    const expanded = try expandTilde(alloc, "~/x/y.db");
    defer alloc.free(expanded);
    try std.testing.expect(std.mem.startsWith(u8, expanded, home));
    try std.testing.expect(std.mem.endsWith(u8, expanded, "/x/y.db"));
    try std.testing.expectEqualStrings("/abs/y.db", try expandTilde(alloc, "/abs/y.db"));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try parseArgs(gpa, init.minimal.args);

    var db = try sqlite.Db.open(args.db);
    defer db.close();
    try db_mod.migrate(&db);

    if (args.set_suggest_key) |k| {
        try db_mod.setSysconf(&db, suggest_key_name, k);
        std.debug.print("tag suggestion key stored\n", .{});
        return;
    }

    if (args.set_password) |hp| {
        var buf: [auth.hash_buf_len]u8 = undefined;
        const hash = try auth.hashPassword(hp[1], &buf, init.io);
        try db_mod.setUserPassword(&db, hp[0], hash);
        std.debug.print("password set for {s}\n", .{hp[0]});
        return;
    }

    var mutex = std.Io.Mutex.init;
    var app = server.App{
        .gpa = gpa,
        .db = &db,
        .db_mutex = &mutex,
        .base_path = args.base_path,
        .shortcut_out = args.shortcut_out,
        .suggest = .{
            .endpoint = args.suggest_url,
            .model = args.suggest_model,
            // A key lives in the database rather than the command line,
            // where every `ps` would show it.
            .api_key = (try db_mod.getSysconf(&db, gpa, suggest_key_name)) orelse "",
        },
        .io = init.io,
    };

    var worker = archive.Worker{ .app = &app, .archiver_cmd = args.archiver };
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
    _ = @import("auth.zig");
    _ = @import("oidc.zig");
    _ = @import("suggest.zig");
}
