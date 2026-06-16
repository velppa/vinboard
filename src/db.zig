const std = @import("std");
const sqlite = @import("sqlite.zig");

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
