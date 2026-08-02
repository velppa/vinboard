const std = @import("std");
const server = @import("server.zig");
const db_mod = @import("db.zig");
const strip = @import("strip.zig");

pub const Worker = struct {
    app: *server.App,
    archiver_cmd: []const u8, // "single-file" in prod; a fixture script in tests
    // Hard cap on one archiver run; 0 disables the `timeout` wrapper (tests).
    // Some pages hang the archiver past its own deadlines, which would stall
    // the whole queue (nextPending always picks the same row).
    timeout_secs: u32 = 180,
    poll_ms: u64 = 2000,
    stop: bool = false,

    pub fn run(self: *Worker) void {
        while (!self.stop) {
            self.tick() catch |e| std.log.err("archive tick: {s}", .{@errorName(e)});
            // Sleep between polls using the io-based sleep API.
            const duration = std.Io.Duration.fromMilliseconds(@intCast(self.poll_ms));
            std.Io.sleep(self.app.io, duration, .awake) catch {};
        }
    }

    /// Process one pending url, if any. Public so tests can call it directly.
    pub fn tick(self: *Worker) !void {
        const url = (try self.nextPending()) orelse return;
        defer self.app.gpa.free(url);
        const html = self.fetch(url) catch |e| {
            try self.markFailed(url, if (e == error.DeadLink) .dead else .failed);
            return;
        };
        defer self.app.gpa.free(html);
        const text = try strip.toText(self.app.gpa, html);
        defer self.app.gpa.free(text);
        self.app.db_mutex.lockUncancelable(self.app.io);
        defer self.app.db_mutex.unlock(self.app.io);
        try db_mod.setArchive(self.app.db, url, html, text, .done, db_mod.nowUnix());
        try self.backfillTitles(url, html);
    }

    /// Bookmarks saved without a title get one from the archived page.
    fn backfillTitles(self: *Worker, url: []const u8, html: []const u8) !void {
        const title = extractTitle(html) orelse return;
        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(self.app.gpa);
        {
            var q = try self.app.db.prepare("SELECT id FROM bookmark WHERE url=? AND title='';");
            defer q.finalize();
            q.bindText(1, url);
            while (try q.step()) try ids.append(self.app.gpa, q.columnInt(0));
        }
        for (ids.items) |id| {
            try db_mod.updateBookmark(self.app.db, id, .{ .title = title }, db_mod.nowUnix());
        }
    }

    fn nextPending(self: *Worker) !?[]u8 {
        self.app.db_mutex.lockUncancelable(self.app.io);
        defer self.app.db_mutex.unlock(self.app.io);
        var q = try self.app.db.prepare("SELECT url FROM archive WHERE status='pending' LIMIT 1;");
        defer q.finalize();
        if (!try q.step()) return null;
        return try self.app.gpa.dupe(u8, q.columnText(0));
    }

    fn markFailed(self: *Worker, url: []const u8, status: @import("models.zig").ArchiveStatus) !void {
        self.app.db_mutex.lockUncancelable(self.app.io);
        defer self.app.db_mutex.unlock(self.app.io);
        try db_mod.setArchive(self.app.db, url, "", "", status, db_mod.nowUnix());
    }

    /// Run the archiver, capture stdout HTML. Caller frees.
    fn fetch(self: *Worker, url: []const u8) ![]u8 {
        var secs_buf: [16]u8 = undefined;
        const secs = try std.fmt.bufPrint(&secs_buf, "{d}", .{self.timeout_secs});
        const argv: []const []const u8 = if (self.timeout_secs > 0)
            &.{ "timeout", secs, self.archiver_cmd, url, "--dump-content" }
        else
            &.{ self.archiver_cmd, url, "--dump-content" };
        const result = try std.process.run(self.app.gpa, self.app.io, .{
            .argv = argv,
            .stdout_limit = .limited(32 * 1024 * 1024),
            .stderr_limit = .limited(1024),
        });
        // Always free stderr; we don't use it.
        self.app.gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| {
                if (code == 3) {
                    self.app.gpa.free(result.stdout);
                    return error.DeadLink;
                }
                if (code != 0) {
                    self.app.gpa.free(result.stdout);
                    return error.ArchiverFailed;
                }
            },
            else => {
                self.app.gpa.free(result.stdout);
                return error.ArchiverFailed;
            },
        }
        return result.stdout;
    }
};

fn extractTitle(html: []const u8) ?[]const u8 {
    const start_tag = std.ascii.indexOfIgnoreCase(html, "<title") orelse return null;
    const open_end = std.mem.indexOfScalarPos(u8, html, start_tag, '>') orelse return null;
    const close = std.ascii.indexOfIgnoreCasePos(html, open_end, "</title") orelse return null;
    const t = std.mem.trim(u8, html[open_end + 1 .. close], " \t\r\n");
    if (t.len == 0) return null;
    return t;
}

test "extractTitle" {
    try std.testing.expectEqualStrings("Hi", extractTitle("<html><TITLE>\n Hi </title>").?);
    try std.testing.expect(extractTitle("<p>no title</p>") == null);
}

const testing = std.testing;

test "worker archives a pending bookmark via stub" {
    var db = try db_mod.testDbPub();
    defer db.close();

    // Threaded.init gives a real io handle that can spawn subprocesses.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mutex: std.Io.Mutex = .init;
    var app = server.App{
        .gpa = testing.allocator,
        .db = &db,
        .db_mutex = &mutex,
        .io = io,
        .base_path = "",
    };

    _ = try db_mod.insertBookmark(&db, .{ .url = "https://w.test", .title = "W" }, 1, 1);
    try db_mod.enqueueArchive(&db, "https://w.test");

    var w = Worker{ .app = &app, .archiver_cmd = "tests/fixtures/fake-archiver.sh", .timeout_secs = 0 };
    try w.tick();

    const hits = try db_mod.search(&db, testing.allocator, "lorem", 10);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
}

test "worker marks a bookmark failed when archiver exits non-zero" {
    var db = try db_mod.testDbPub();
    defer db.close();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mutex: std.Io.Mutex = .init;
    var app = server.App{
        .gpa = testing.allocator,
        .db = &db,
        .db_mutex = &mutex,
        .io = io,
        .base_path = "",
    };

    _ = try db_mod.insertBookmark(&db, .{ .url = "https://fail.test", .title = "F" }, 1, 1);
    try db_mod.enqueueArchive(&db, "https://fail.test");

    // The fixture writes to stdout then exits 1. tick() must complete without
    // crashing (no double-free) and record the failure.
    var w = Worker{ .app = &app, .archiver_cmd = "tests/fixtures/fail-archiver.sh", .timeout_secs = 0 };
    try w.tick();

    var q = try db.prepare("SELECT status FROM archive WHERE url=?;");
    defer q.finalize();
    q.bindText(1, "https://fail.test");
    try testing.expect(try q.step());
    try testing.expectEqualStrings("failed", q.columnText(0));

    // No pending rows should remain, so a second tick is a no-op.
    try w.tick();
}
