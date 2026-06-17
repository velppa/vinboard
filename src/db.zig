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
    \\  title, notes, url, tags, body, content='', contentless_delete=1
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

pub fn testDbPub() !sqlite.Db {
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

fn reindex(db: *sqlite.Db, id: i64) !void {
    try unindex(db, id);
    var ins = try db.prepare(
        \\INSERT INTO bookmarks_fts(rowid,title,notes,url,tags,body)
        \\SELECT b.id, b.title, b.notes, b.url,
        \\  COALESCE((SELECT group_concat(tag,' ') FROM tags WHERE bookmark_id=b.id),''),
        \\  COALESCE((SELECT text FROM archive WHERE bookmark_id=b.id),'')
        \\FROM bookmarks b WHERE b.id=?;
    );
    defer ins.finalize();
    ins.bindInt(1, id);
    _ = try ins.step();
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

pub const ListFilter = struct {
    tag: ?[]const u8 = null,
    toread: ?bool = null,
    shared: ?bool = null,
    limit: i64 = 100,
    offset: i64 = 0,
};

/// Returns ids most-recent-first. Caller frees the slice.
pub fn listBookmarkIds(db: *sqlite.Db, alloc: std.mem.Allocator, f: ListFilter) ![]i64 {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(alloc);
    try sql.appendSlice(alloc, "SELECT DISTINCT b.id FROM bookmarks b");
    if (f.tag != null) try sql.appendSlice(alloc, " JOIN tags t ON t.bookmark_id=b.id");
    try sql.appendSlice(alloc, " WHERE 1=1");
    if (f.tag != null) try sql.appendSlice(alloc, " AND t.tag=?1");
    if (f.toread != null) try sql.appendSlice(alloc, " AND b.toread=?2");
    if (f.shared != null) try sql.appendSlice(alloc, " AND b.shared=?3");
    try sql.appendSlice(alloc, " ORDER BY b.created_at DESC LIMIT ?4 OFFSET ?5;");
    const sqlz = try alloc.dupeZ(u8, sql.items);
    defer alloc.free(sqlz);

    var q = try db.prepare(sqlz);
    defer q.finalize();
    if (f.tag) |t| q.bindText(1, t);
    if (f.toread) |v| q.bindInt(2, @intFromBool(v));
    if (f.shared) |v| q.bindInt(3, @intFromBool(v));
    q.bindInt(4, f.limit);
    q.bindInt(5, f.offset);

    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(alloc);
    while (try q.step()) try ids.append(alloc, q.columnInt(0));
    return ids.toOwnedSlice(alloc);
}

test "list filters by tag" {
    var db = try testDb();
    defer db.close();
    _ = try insertBookmark(&db, .{ .url = "https://1", .tags = &.{"work"} }, 10);
    _ = try insertBookmark(&db, .{ .url = "https://2", .tags = &.{"home"} }, 20);
    const ids = try listBookmarkIds(&db, testing.allocator, .{ .tag = "work" });
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
}

pub const Patch = struct {
    title: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    toread: ?bool = null,
    shared: ?bool = null,
    tags: ?[]const []const u8 = null,
};

pub fn updateBookmark(db: *sqlite.Db, id: i64, p: Patch, now: i64) !void {
    if (p.title) |v| try setText(db, id, "title", v);
    if (p.notes) |v| try setText(db, id, "notes", v);
    if (p.toread) |v| try setInt(db, id, "toread", @intFromBool(v));
    if (p.shared) |v| try setInt(db, id, "shared", @intFromBool(v));
    if (p.tags) |tg| try replaceTags(db, id, tg);
    try setInt(db, id, "updated_at", now);
    try reindex(db, id);
}

fn setText(db: *sqlite.Db, id: i64, col: []const u8, v: []const u8) !void {
    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&buf, "UPDATE bookmarks SET {s}=? WHERE id=?;", .{col});
    var s = try db.prepare(sql);
    defer s.finalize();
    s.bindText(1, v);
    s.bindInt(2, id);
    _ = try s.step();
}

fn setInt(db: *sqlite.Db, id: i64, col: []const u8, v: i64) !void {
    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&buf, "UPDATE bookmarks SET {s}=? WHERE id=?;", .{col});
    var s = try db.prepare(sql);
    defer s.finalize();
    s.bindInt(1, v);
    s.bindInt(2, id);
    _ = try s.step();
}

/// Returns the id of a bookmark with the given url, or null if not found.
pub fn findIdByUrl(db: *sqlite.Db, url: []const u8) !?i64 {
    var q = try db.prepare("SELECT id FROM bookmarks WHERE url=? LIMIT 1;");
    defer q.finalize();
    q.bindText(1, url);
    if (!try q.step()) return null;
    return q.columnInt(0);
}

pub fn deleteBookmark(db: *sqlite.Db, id: i64) !void {
    try unindex(db, id);
    var s = try db.prepare("DELETE FROM bookmarks WHERE id=?;");
    defer s.finalize();
    s.bindInt(1, id);
    _ = try s.step();
}

fn unindex(db: *sqlite.Db, id: i64) !void {
    var del = try db.prepare("DELETE FROM bookmarks_fts WHERE rowid=?;");
    defer del.finalize();
    del.bindInt(1, id);
    _ = try del.step();
}

test "update then delete" {
    var db = try testDb();
    defer db.close();
    const id = try insertBookmark(&db, .{ .url = "https://u", .title = "old" }, 1);
    try updateBookmark(&db, id, .{ .title = "new", .toread = true }, 2);
    const bm = (try getBookmark(&db, testing.allocator, id)).?;
    defer freeBookmark(testing.allocator, bm);
    try testing.expectEqualStrings("new", bm.title);
    try testing.expect(bm.toread);

    try deleteBookmark(&db, id);
    try testing.expect((try getBookmark(&db, testing.allocator, id)) == null);
}

/// FTS search; returns matching ids best-match-first. Caller frees.
pub fn search(db: *sqlite.Db, alloc: std.mem.Allocator, query: []const u8, limit: i64) ![]i64 {
    var q = try db.prepare("SELECT rowid FROM bookmarks_fts WHERE bookmarks_fts MATCH ? ORDER BY rank LIMIT ?;");
    defer q.finalize();
    q.bindText(1, query);
    q.bindInt(2, limit);
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(alloc);
    while (try q.step()) try ids.append(alloc, q.columnInt(0));
    return ids.toOwnedSlice(alloc);
}

test "search finds by title and tag" {
    var db = try testDb();
    defer db.close();
    _ = try insertBookmark(&db, .{ .url = "https://zig", .title = "Zig language", .tags = &.{"programming"} }, 1);
    _ = try insertBookmark(&db, .{ .url = "https://cook", .title = "Cooking", .tags = &.{"food"} }, 2);

    const a = try search(&db, testing.allocator, "zig", 10);
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 1), a.len);

    const b = try search(&db, testing.allocator, "programming", 10);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 1), b.len);
}

/// Returns a prepared statement that yields (tag, count) rows ordered by count desc.
pub fn prepareTagCounts(db: *sqlite.Db) !sqlite.Stmt {
    return db.prepare("SELECT tag, count(*) c FROM tags GROUP BY tag ORDER BY c DESC, tag;");
}

/// Returns current Unix time in seconds.
pub fn nowUnix() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// Store archived text + status, then refresh FTS so body becomes searchable.
pub fn setArchive(db: *sqlite.Db, id: i64, html: []const u8, text: []const u8, status: models.ArchiveStatus, now: i64) !void {
    var s = try db.prepare(
        "INSERT INTO archive(bookmark_id,html,text,fetched_at,status) VALUES (?,?,?,?,?) " ++
        "ON CONFLICT(bookmark_id) DO UPDATE SET html=excluded.html,text=excluded.text,fetched_at=excluded.fetched_at,status=excluded.status;",
    );
    defer s.finalize();
    s.bindInt(1, id);
    s.bindText(2, html);
    s.bindText(3, text);
    s.bindInt(4, now);
    s.bindText(5, @tagName(status));
    _ = try s.step();
    try reindex(db, id);
}

test "archived text becomes searchable" {
    var db = try testDb();
    defer db.close();
    const id = try insertBookmark(&db, .{ .url = "https://p", .title = "Plain" }, 1);
    try setArchive(&db, id, "<html>x</html>", "elephant zebra", .done, 2);
    const hits = try search(&db, testing.allocator, "zebra", 10);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
}
