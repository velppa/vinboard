const std = @import("std");
const server = @import("server.zig");
const db_mod = @import("db.zig");
const strip = @import("strip.zig");

pub const Worker = struct {
    app: *server.App,
    archiver_cmd: []const u8, // "single-file" in prod; a fixture script in tests
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

    /// Process one pending row, if any. Public so tests can call it directly.
    pub fn tick(self: *Worker) !void {
        const job = (try self.nextPending()) orelse return;
        defer self.app.gpa.free(job.url);
        const html = self.fetch(job.url) catch {
            try self.markFailed(job.id);
            return;
        };
        defer self.app.gpa.free(html);
        const text = try strip.toText(self.app.gpa, html);
        defer self.app.gpa.free(text);
        self.app.db_mutex.lockUncancelable(self.app.io);
        defer self.app.db_mutex.unlock(self.app.io);
        try db_mod.setArchive(self.app.db, job.id, html, text, .done, db_mod.nowUnix());
    }

    const Job = struct { id: i64, url: []u8 };

    fn nextPending(self: *Worker) !?Job {
        self.app.db_mutex.lockUncancelable(self.app.io);
        defer self.app.db_mutex.unlock(self.app.io);
        var q = try self.app.db.prepare(
            "SELECT a.bookmark_id, b.url FROM archive a JOIN bookmarks b ON b.id=a.bookmark_id WHERE a.status='pending' LIMIT 1;",
        );
        defer q.finalize();
        if (!try q.step()) return null;
        return .{ .id = q.columnInt(0), .url = try self.app.gpa.dupe(u8, q.columnText(1)) };
    }

    fn markFailed(self: *Worker, id: i64) !void {
        self.app.db_mutex.lockUncancelable(self.app.io);
        defer self.app.db_mutex.unlock(self.app.io);
        try db_mod.setArchive(self.app.db, id, "", "", .failed, db_mod.nowUnix());
    }

    /// Run the archiver, capture stdout HTML. Caller frees.
    fn fetch(self: *Worker, url: []const u8) ![]u8 {
        const result = try std.process.run(self.app.gpa, self.app.io, .{
            .argv = &.{ self.archiver_cmd, url },
            .stdout_limit = .limited(32 * 1024 * 1024),
            .stderr_limit = .limited(1024),
        });
        // Always free stderr; we don't use it.
        self.app.gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| {
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

    const id = try db_mod.insertBookmark(&db, .{ .url = "https://w.test", .title = "W" }, 1);
    try db_mod.setArchive(&db, id, "", "", .pending, 1);

    var w = Worker{ .app = &app, .archiver_cmd = "tests/fixtures/fake-archiver.sh" };
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

    const id = try db_mod.insertBookmark(&db, .{ .url = "https://fail.test", .title = "F" }, 1);
    try db_mod.setArchive(&db, id, "", "", .pending, 1);

    // The fixture writes to stdout then exits 1. tick() must complete without
    // crashing (no double-free) and record the failure.
    var w = Worker{ .app = &app, .archiver_cmd = "tests/fixtures/fail-archiver.sh" };
    try w.tick();

    var q = try db.prepare("SELECT status FROM archive WHERE bookmark_id=?;");
    defer q.finalize();
    q.bindInt(1, id);
    try testing.expect(try q.step());
    try testing.expectEqualStrings("failed", q.columnText(0));

    // No pending rows should remain, so a second tick is a no-op.
    try w.tick();
}
