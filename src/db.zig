const std = @import("std");
const sqlite = @import("sqlite.zig");
const models = @import("models.zig");

pub const SCHEMA: [:0]const u8 =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA foreign_keys=ON;
    \\CREATE TABLE IF NOT EXISTS bookmarks(
    \\  id INTEGER PRIMARY KEY,
    \\  url TEXT UNIQUE NOT NULL,
    \\  title TEXT NOT NULL DEFAULT '',
    \\  notes TEXT NOT NULL DEFAULT '',
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL,
    \\  toread INTEGER NOT NULL DEFAULT 0,
    \\  shared INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE TABLE IF NOT EXISTS tags(
    \\  bookmark_id INTEGER NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,
    \\  tag TEXT NOT NULL,
    \\  PRIMARY KEY (bookmark_id, tag)
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_tags_tag ON tags(tag);
    \\CREATE TABLE IF NOT EXISTS archive(
    \\  bookmark_id INTEGER PRIMARY KEY REFERENCES bookmarks(id) ON DELETE CASCADE,
    \\  html BLOB,
    \\  text TEXT,
    \\  fetched_at INTEGER,
    \\  status TEXT NOT NULL DEFAULT 'pending'
    \\);
    \\CREATE VIRTUAL TABLE IF NOT EXISTS bookmarks_fts USING fts5(
    \\  title, notes, url, tags, body, content=''
    \\);
;

pub fn migrate(db: *sqlite.Db) !void {
    try db.exec(SCHEMA);
}

const testing = std.testing;
fn testDb() !sqlite.Db {
    var db = try sqlite.Db.openMemory();
    try migrate(&db);
    return db;
}

test "migrate creates tables" {
    var db = try testDb();
    defer db.close();
    var q = try db.prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('bookmarks','tags','archive');");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 3), q.columnInt(0));
}

test "migrate creates fts5 table" {
    var db = try testDb();
    defer db.close();
    var q = try db.prepare("SELECT count(*) FROM sqlite_master WHERE name='bookmarks_fts';");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 1), q.columnInt(0));
}

/// Insert a bookmark and its tags. Returns the new id. now = unix seconds.
pub fn insertBookmark(db: *sqlite.Db, nb: models.NewBookmark, now: i64) !i64 {
    var ins = try db.prepare(
        "INSERT INTO bookmarks(url,title,notes,created_at,updated_at,toread,shared) VALUES (?,?,?,?,?,?,?);",
    );
    defer ins.finalize();
    ins.bindText(1, nb.url);
    ins.bindText(2, nb.title);
    ins.bindText(3, nb.notes);
    ins.bindInt(4, now);
    ins.bindInt(5, now);
    ins.bindInt(6, @intFromBool(nb.toread));
    ins.bindInt(7, @intFromBool(nb.shared));
    _ = try ins.step();
    const id = sqlite.c.sqlite3_last_insert_rowid(db.handle);
    try replaceTags(db, id, nb.tags);
    try reindex(db, id);
    return id;
}

fn replaceTags(db: *sqlite.Db, id: i64, tags: []const []const u8) !void {
    var del = try db.prepare("DELETE FROM tags WHERE bookmark_id=?;");
    del.bindInt(1, id);
    _ = try del.step();
    del.finalize();
    for (tags) |t| {
        var ins = try db.prepare("INSERT OR IGNORE INTO tags(bookmark_id,tag) VALUES (?,?);");
        ins.bindInt(1, id);
        ins.bindText(2, t);
        _ = try ins.step();
        ins.finalize();
    }
}

// Temporary stub — real FTS sync body is added in a later task (Task 5).
fn reindex(db: *sqlite.Db, id: i64) !void {
    _ = db;
    _ = id;
}

test "insert and read back a bookmark" {
    var db = try testDb();
    defer db.close();
    const id = try insertBookmark(&db, .{
        .url = "https://x.test",
        .title = "X",
        .tags = &.{ "a", "b" },
    }, 1000);
    try testing.expect(id > 0);

    var q = try db.prepare("SELECT url,title FROM bookmarks WHERE id=?;");
    defer q.finalize();
    q.bindInt(1, id);
    try testing.expect(try q.step());
    try testing.expectEqualStrings("https://x.test", q.columnText(0));
    try testing.expectEqualStrings("X", q.columnText(1));

    var tq = try db.prepare("SELECT count(*) FROM tags WHERE bookmark_id=?;");
    defer tq.finalize();
    tq.bindInt(1, id);
    try testing.expect(try tq.step());
    try testing.expectEqual(@as(i64, 2), tq.columnInt(0));
}

/// Caller owns all returned memory; free with freeBookmark.
pub fn getBookmark(db: *sqlite.Db, alloc: std.mem.Allocator, id: i64) !?models.Bookmark {
    var q = try db.prepare("SELECT id,url,title,notes,created_at,updated_at,toread,shared FROM bookmarks WHERE id=?;");
    defer q.finalize();
    q.bindInt(1, id);
    if (!try q.step()) return null;
    var bm = models.Bookmark{
        .id = q.columnInt(0),
        .url = try alloc.dupe(u8, q.columnText(1)),
        .title = try alloc.dupe(u8, q.columnText(2)),
        .notes = try alloc.dupe(u8, q.columnText(3)),
        .created_at = q.columnInt(4),
        .updated_at = q.columnInt(5),
        .toread = q.columnInt(6) != 0,
        .shared = q.columnInt(7) != 0,
    };
    bm.tags = try tagsFor(db, alloc, id);
    return bm;
}

fn tagsFor(db: *sqlite.Db, alloc: std.mem.Allocator, id: i64) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    var q = try db.prepare("SELECT tag FROM tags WHERE bookmark_id=? ORDER BY tag;");
    defer q.finalize();
    q.bindInt(1, id);
    while (try q.step()) try list.append(alloc, try alloc.dupe(u8, q.columnText(0)));
    return list.toOwnedSlice(alloc);
}

pub fn freeBookmark(alloc: std.mem.Allocator, bm: models.Bookmark) void {
    alloc.free(bm.url);
    alloc.free(bm.title);
    alloc.free(bm.notes);
    for (bm.tags) |t| alloc.free(t);
    alloc.free(bm.tags);
}

test "getBookmark returns struct with tags" {
    var db = try testDb();
    defer db.close();
    const id = try insertBookmark(&db, .{ .url = "https://y.test", .title = "Y", .tags = &.{ "z", "a" } }, 5);
    const bm = (try getBookmark(&db, testing.allocator, id)).?;
    defer freeBookmark(testing.allocator, bm);
    try testing.expectEqualStrings("https://y.test", bm.url);
    try testing.expectEqual(@as(usize, 2), bm.tags.len);
    try testing.expectEqualStrings("a", bm.tags[0]); // ordered
}
