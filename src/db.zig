const std = @import("std");
const sqlite = @import("sqlite.zig");
const gzip = @import("gzip.zig");
const models = @import("models.zig");

pub const SCHEMA: [:0]const u8 =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA foreign_keys=ON;
    \\CREATE TABLE IF NOT EXISTS bookmark(
    \\  id INTEGER PRIMARY KEY,
    \\  url TEXT NOT NULL,
    \\  title TEXT NOT NULL DEFAULT '',
    \\  notes TEXT NOT NULL DEFAULT '',
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL,
    \\  toread INTEGER NOT NULL DEFAULT 0,
    \\  shared INTEGER NOT NULL DEFAULT 0,
    \\  starred INTEGER NOT NULL DEFAULT 0,
    \\  user_id INTEGER NOT NULL DEFAULT 1,
    \\  UNIQUE(url, user_id)
    \\);
    \\CREATE TABLE IF NOT EXISTS user(
    \\  id INTEGER PRIMARY KEY,
    \\  handle TEXT UNIQUE NOT NULL,
    \\  password_hash TEXT NOT NULL DEFAULT '',
    \\  created_at INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE TABLE IF NOT EXISTS session(
    \\  token TEXT PRIMARY KEY,
    \\  user_id INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    \\  expires_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS tag(
    \\  bookmark_id INTEGER NOT NULL REFERENCES bookmark(id) ON DELETE CASCADE,
    \\  tag TEXT NOT NULL,
    \\  PRIMARY KEY (bookmark_id, tag)
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_tags_tag ON tag(tag);
    \\CREATE TABLE IF NOT EXISTS archive(
    \\  url TEXT PRIMARY KEY,
    \\  html BLOB,
    \\  text TEXT,
    \\  fetched_at INTEGER,
    \\  status TEXT NOT NULL DEFAULT 'pending'
    \\);
    \\CREATE VIRTUAL TABLE IF NOT EXISTS bookmark_fts USING fts5(
    \\  title, notes, url, tags, body, content='', contentless_delete=1
    \\);
    \\CREATE TABLE IF NOT EXISTS sysconf(
    \\  key TEXT PRIMARY KEY,
    \\  value TEXT NOT NULL
    \\);
;

pub fn migrate(db: *sqlite.Db) !void {
    // Tables were originally plural; rename before the schema creates
    // empty singular ones next to them.
    try renameTable(db, "bookmarks", "bookmark");
    try renameTable(db, "tags", "tag");
    try renameTable(db, "users", "user");
    try renameTable(db, "sessions", "session");
    try renameTable(db, "bookmarks_fts", "bookmark_fts");
    try rebuildForPerUserUrls(db);
    try db.exec(SCHEMA);
    // Columns added after the initial schema.
    if (!try hasColumn(db, "bookmark", "starred")) {
        try db.exec("ALTER TABLE bookmark ADD COLUMN starred INTEGER NOT NULL DEFAULT 0;");
    }
    if (!try hasColumn(db, "bookmark", "user_id")) {
        try db.exec("ALTER TABLE bookmark ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;");
    }
    if (!try hasColumn(db, "user", "api_token")) {
        try db.exec("ALTER TABLE user ADD COLUMN api_token TEXT NOT NULL DEFAULT '';");
    }
    if (!try hasColumn(db, "user", "settings")) {
        try db.exec("ALTER TABLE user ADD COLUMN settings TEXT NOT NULL DEFAULT '{}';");
    }
    if (!try hasColumn(db, "user", "oidc_sub")) {
        try db.exec("ALTER TABLE user ADD COLUMN oidc_sub TEXT NOT NULL DEFAULT '';");
    }
    try db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_user_oidc_sub ON user(oidc_sub) WHERE oidc_sub<>'';");
    // Seed the owner; login stays disabled until a password is set.
    try db.exec("INSERT OR IGNORE INTO user(id, handle) VALUES (1, 'velppa');");
    try compressStoredPages(db);
}

/// One-off pass: compress page copies stored before compression
/// existed.  Rows are converted one at a time so an interrupted run
/// simply resumes where it stopped.
fn compressStoredPages(db: *sqlite.Db) !void {
    const alloc = std.heap.page_allocator;
    if (try getSysconf(db, alloc, "archive_html_compressed")) |v| {
        alloc.free(v);
        return;
    }
    var converted: usize = 0;
    while (true) {
        var url: []u8 = undefined;
        var html: []u8 = undefined;
        {
            // hex() is how SQL tells a gzip header from page text.
            var q = try db.prepare(
                \\SELECT url, html FROM archive
                \\WHERE html IS NOT NULL AND length(html) > 0
                \\  AND hex(substr(html,1,2)) <> '1F8B' LIMIT 1;
            );
            defer q.finalize();
            if (!try q.step()) break;
            url = try alloc.dupe(u8, q.columnText(0));
            html = try alloc.dupe(u8, q.columnBlob(1));
        }
        defer alloc.free(url);
        defer alloc.free(html);

        const stored = try gzip.compress(alloc, html);
        defer alloc.free(stored);
        var up = try db.prepare("UPDATE archive SET html=? WHERE url=?;");
        defer up.finalize();
        up.bindBlob(1, stored);
        up.bindText(2, url);
        _ = try up.step();
        converted += 1;
    }
    if (converted > 0) std.log.info("compressed {d} archived pages", .{converted});
    try setSysconf(db, "archive_html_compressed", "1");
}

/// One-off rebuild: bookmark url unique per user, archive keyed by url
/// (the cached artifact is shared by everyone who saved the url).
fn rebuildForPerUserUrls(db: *sqlite.Db) !void {
    if (!try tableExists(db, "bookmark")) return;
    try db.exec("PRAGMA foreign_keys=OFF;");
    defer db.exec("PRAGMA foreign_keys=ON;") catch {};

    const bm_sql = try tableSqlContains(db, "bookmark", "UNIQUE(url, user_id)");
    if (!bm_sql) {
        try db.exec(
            \\CREATE TABLE bookmark_new(
            \\  id INTEGER PRIMARY KEY,
            \\  url TEXT NOT NULL,
            \\  title TEXT NOT NULL DEFAULT '',
            \\  notes TEXT NOT NULL DEFAULT '',
            \\  created_at INTEGER NOT NULL,
            \\  updated_at INTEGER NOT NULL,
            \\  toread INTEGER NOT NULL DEFAULT 0,
            \\  shared INTEGER NOT NULL DEFAULT 0,
            \\  starred INTEGER NOT NULL DEFAULT 0,
            \\  user_id INTEGER NOT NULL DEFAULT 1,
            \\  UNIQUE(url, user_id)
            \\);
            \\INSERT INTO bookmark_new SELECT id,url,title,notes,created_at,updated_at,toread,shared,starred,user_id FROM bookmark;
            \\DROP TABLE bookmark;
            \\ALTER TABLE bookmark_new RENAME TO bookmark;
        );
    }
    if (try tableExists(db, "archive") and try hasColumn(db, "archive", "bookmark_id")) {
        try db.exec(
            \\CREATE TABLE archive_new(
            \\  url TEXT PRIMARY KEY,
            \\  html BLOB,
            \\  text TEXT,
            \\  fetched_at INTEGER,
            \\  status TEXT NOT NULL DEFAULT 'pending'
            \\);
            \\INSERT OR IGNORE INTO archive_new
            \\  SELECT b.url, a.html, a.text, a.fetched_at, a.status FROM archive a
            \\  JOIN bookmark b ON b.id=a.bookmark_id
            \\  ORDER BY CASE a.status WHEN 'done' THEN 0 ELSE 1 END;
            \\DROP TABLE archive;
            \\ALTER TABLE archive_new RENAME TO archive;
        );
    }
}

fn tableSqlContains(db: *sqlite.Db, table: []const u8, needle: []const u8) !bool {
    var q = try db.prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name=?;");
    defer q.finalize();
    q.bindText(1, table);
    if (!try q.step()) return false;
    return std.mem.indexOf(u8, q.columnText(0), needle) != null;
}

fn tableExists(db: *sqlite.Db, name: []const u8) !bool {
    var q = try db.prepare("SELECT 1 FROM sqlite_master WHERE name=?;");
    defer q.finalize();
    q.bindText(1, name);
    return try q.step();
}

fn renameTable(db: *sqlite.Db, old: []const u8, new: []const u8) !void {
    if (!try tableExists(db, old) or try tableExists(db, new)) return;
    var buf: [128]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&buf, "ALTER TABLE {s} RENAME TO {s};", .{ old, new });
    try db.exec(sql);
}

fn hasColumn(db: *sqlite.Db, table: []const u8, col: []const u8) !bool {
    var q = try db.prepare("SELECT 1 FROM pragma_table_info(?) WHERE name=?;");
    defer q.finalize();
    q.bindText(1, table);
    q.bindText(2, col);
    return try q.step();
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
    var q = try db.prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('bookmark','tag','archive');");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 3), q.columnInt(0));
}

test "migrate creates fts5 table" {
    var db = try testDb();
    defer db.close();
    var q = try db.prepare("SELECT count(*) FROM sqlite_master WHERE name='bookmark_fts';");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 1), q.columnInt(0));
}

/// Insert a bookmark and its tags for a user. Returns the new id.
pub fn insertBookmark(db: *sqlite.Db, nb: models.NewBookmark, now: i64, user_id: i64) !i64 {
    var ins = try db.prepare(
        "INSERT INTO bookmark(url,title,notes,created_at,updated_at,toread,shared,user_id) VALUES (?,?,?,?,?,?,?,?);",
    );
    defer ins.finalize();
    ins.bindText(1, nb.url);
    ins.bindText(2, nb.title);
    ins.bindText(3, nb.notes);
    ins.bindInt(4, now);
    ins.bindInt(5, now);
    ins.bindInt(6, @intFromBool(nb.toread));
    ins.bindInt(7, @intFromBool(nb.shared));
    ins.bindInt(8, user_id);
    _ = try ins.step();
    const id = sqlite.c.sqlite3_last_insert_rowid(db.handle);
    try replaceTags(db, id, nb.tags);
    try reindex(db, id);
    return id;
}

fn replaceTags(db: *sqlite.Db, id: i64, tags: []const []const u8) !void {
    var del = try db.prepare("DELETE FROM tag WHERE bookmark_id=?;");
    del.bindInt(1, id);
    _ = try del.step();
    del.finalize();
    for (tags) |t| {
        var ins = try db.prepare("INSERT OR IGNORE INTO tag(bookmark_id,tag) VALUES (?,?);");
        ins.bindInt(1, id);
        ins.bindText(2, t);
        _ = try ins.step();
        ins.finalize();
    }
}

pub fn reindexBookmark(db: *sqlite.Db, id: i64) !void {
    return reindex(db, id);
}

fn reindex(db: *sqlite.Db, id: i64) !void {
    try unindex(db, id);
    var ins = try db.prepare(
        \\INSERT INTO bookmark_fts(rowid,title,notes,url,tags,body)
        \\SELECT b.id, b.title, b.notes, b.url,
        \\  COALESCE((SELECT group_concat(tag,' ') FROM tag WHERE bookmark_id=b.id),''),
        \\  COALESCE((SELECT text FROM archive WHERE url=b.url),'')
        \\FROM bookmark b WHERE b.id=?;
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
    }, 1000, 1);
    try testing.expect(id > 0);

    var q = try db.prepare("SELECT url,title FROM bookmark WHERE id=?;");
    defer q.finalize();
    q.bindInt(1, id);
    try testing.expect(try q.step());
    try testing.expectEqualStrings("https://x.test", q.columnText(0));
    try testing.expectEqualStrings("X", q.columnText(1));

    var tq = try db.prepare("SELECT count(*) FROM tag WHERE bookmark_id=?;");
    defer tq.finalize();
    tq.bindInt(1, id);
    try testing.expect(try tq.step());
    try testing.expectEqual(@as(i64, 2), tq.columnInt(0));
}

/// Caller owns all returned memory; free with freeBookmark.
pub fn getBookmark(db: *sqlite.Db, alloc: std.mem.Allocator, id: i64) !?models.Bookmark {
    var q = try db.prepare("SELECT id,url,title,notes,created_at,updated_at,toread,shared,starred,user_id FROM bookmark WHERE id=?;");
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
        .starred = q.columnInt(8) != 0,
        .user_id = q.columnInt(9),
    };
    bm.tags = try tagsFor(db, alloc, id);
    return bm;
}

fn tagsFor(db: *sqlite.Db, alloc: std.mem.Allocator, id: i64) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    var q = try db.prepare("SELECT tag FROM tag WHERE bookmark_id=? ORDER BY tag;");
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
    const id = try insertBookmark(&db, .{ .url = "https://y.test", .title = "Y", .tags = &.{ "z", "a" } }, 5, 1);
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
    starred: ?bool = null,
    untagged: bool = false,
    archived: bool = false,
    user_id: ?i64 = null,
    limit: i64 = 100,
    offset: i64 = 0,
};

/// Returns ids most-recent-first. Caller frees the slice.
pub fn listBookmarkIds(db: *sqlite.Db, alloc: std.mem.Allocator, f: ListFilter) ![]i64 {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(alloc);
    try sql.appendSlice(alloc, "SELECT DISTINCT b.id FROM bookmark b");
    if (f.tag != null) try sql.appendSlice(alloc, " JOIN tag t ON t.bookmark_id=b.id");
    try sql.appendSlice(alloc, " WHERE 1=1");
    if (f.tag != null) try sql.appendSlice(alloc, " AND t.tag=?1");
    if (f.toread != null) try sql.appendSlice(alloc, " AND b.toread=?2");
    if (f.shared != null) try sql.appendSlice(alloc, " AND b.shared=?3");
    if (f.starred != null) try sql.appendSlice(alloc, " AND b.starred=?6");
    if (f.user_id != null) try sql.appendSlice(alloc, " AND b.user_id=?7");
    if (f.untagged) try sql.appendSlice(alloc, " AND NOT EXISTS (SELECT 1 FROM tag tu WHERE tu.bookmark_id=b.id)");
    if (f.archived) try sql.appendSlice(alloc, " AND EXISTS (SELECT 1 FROM archive ar WHERE ar.url=b.url AND ar.status='done')");
    try sql.appendSlice(alloc, " ORDER BY b.created_at DESC LIMIT ?4 OFFSET ?5;");
    const sqlz = try alloc.dupeZ(u8, sql.items);
    defer alloc.free(sqlz);

    var q = try db.prepare(sqlz);
    defer q.finalize();
    if (f.tag) |t| q.bindText(1, t);
    if (f.toread) |v| q.bindInt(2, @intFromBool(v));
    if (f.shared) |v| q.bindInt(3, @intFromBool(v));
    if (f.starred) |v| q.bindInt(6, @intFromBool(v));
    if (f.user_id) |v| q.bindInt(7, v);
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
    _ = try insertBookmark(&db, .{ .url = "https://1", .tags = &.{"work"} }, 10, 1);
    _ = try insertBookmark(&db, .{ .url = "https://2", .tags = &.{"home"} }, 20, 1);
    const ids = try listBookmarkIds(&db, testing.allocator, .{ .tag = "work" });
    defer testing.allocator.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
}

/// Count of bookmarks matching the filter (limit/offset ignored).
pub fn countFiltered(db: *sqlite.Db, alloc: std.mem.Allocator, f: ListFilter) !i64 {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(alloc);
    try sql.appendSlice(alloc, "SELECT COUNT(DISTINCT b.id) FROM bookmark b");
    if (f.tag != null) try sql.appendSlice(alloc, " JOIN tag t ON t.bookmark_id=b.id");
    try sql.appendSlice(alloc, " WHERE 1=1");
    if (f.tag != null) try sql.appendSlice(alloc, " AND t.tag=?1");
    if (f.toread != null) try sql.appendSlice(alloc, " AND b.toread=?2");
    if (f.shared != null) try sql.appendSlice(alloc, " AND b.shared=?3");
    if (f.starred != null) try sql.appendSlice(alloc, " AND b.starred=?6");
    if (f.user_id != null) try sql.appendSlice(alloc, " AND b.user_id=?7");
    if (f.untagged) try sql.appendSlice(alloc, " AND NOT EXISTS (SELECT 1 FROM tag tu WHERE tu.bookmark_id=b.id)");
    if (f.archived) try sql.appendSlice(alloc, " AND EXISTS (SELECT 1 FROM archive ar WHERE ar.url=b.url AND ar.status='done')");
    try sql.appendSlice(alloc, ";");
    const sqlz = try alloc.dupeZ(u8, sql.items);
    defer alloc.free(sqlz);

    var q = try db.prepare(sqlz);
    defer q.finalize();
    if (f.tag) |t| q.bindText(1, t);
    if (f.toread) |v| q.bindInt(2, @intFromBool(v));
    if (f.shared) |v| q.bindInt(3, @intFromBool(v));
    if (f.starred) |v| q.bindInt(6, @intFromBool(v));
    if (f.user_id) |v| q.bindInt(7, v);
    _ = try q.step();
    return q.columnInt(0);
}

test "countFiltered by tag" {
    var db = try testDb();
    defer db.close();
    _ = try insertBookmark(&db, .{ .url = "https://1", .tags = &.{"work"} }, 10, 1);
    _ = try insertBookmark(&db, .{ .url = "https://2", .tags = &.{"home"} }, 20, 1);
    try testing.expectEqual(@as(i64, 1), try countFiltered(&db, testing.allocator, .{ .tag = "work" }));
    try testing.expectEqual(@as(i64, 2), try countFiltered(&db, testing.allocator, .{}));
}

pub const Patch = struct {
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    toread: ?bool = null,
    shared: ?bool = null,
    starred: ?bool = null,
    tags: ?[]const []const u8 = null,
};

pub fn updateBookmark(db: *sqlite.Db, id: i64, p: Patch, now: i64) !void {
    if (p.url) |v| try setText(db, id, "url", v);
    if (p.title) |v| try setText(db, id, "title", v);
    if (p.notes) |v| try setText(db, id, "notes", v);
    if (p.toread) |v| try setInt(db, id, "toread", @intFromBool(v));
    if (p.shared) |v| try setInt(db, id, "shared", @intFromBool(v));
    if (p.starred) |v| try setInt(db, id, "starred", @intFromBool(v));
    if (p.tags) |tg| try replaceTags(db, id, tg);
    try setInt(db, id, "updated_at", now);
    try reindex(db, id);
}

fn setText(db: *sqlite.Db, id: i64, col: []const u8, v: []const u8) !void {
    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&buf, "UPDATE bookmark SET {s}=? WHERE id=?;", .{col});
    var s = try db.prepare(sql);
    defer s.finalize();
    s.bindText(1, v);
    s.bindInt(2, id);
    _ = try s.step();
}

fn setInt(db: *sqlite.Db, id: i64, col: []const u8, v: i64) !void {
    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&buf, "UPDATE bookmark SET {s}=? WHERE id=?;", .{col});
    var s = try db.prepare(sql);
    defer s.finalize();
    s.bindInt(1, v);
    s.bindInt(2, id);
    _ = try s.step();
}

pub const User = struct { id: i64, handle: []const u8, password_hash: []const u8 };

/// Caller owns handle and password_hash (allocated from `alloc`).
pub fn getUserByHandle(db: *sqlite.Db, alloc: std.mem.Allocator, handle: []const u8) !?User {
    var q = try db.prepare("SELECT id, handle, password_hash FROM user WHERE handle=?;");
    defer q.finalize();
    q.bindText(1, handle);
    if (!try q.step()) return null;
    return .{
        .id = q.columnInt(0),
        .handle = try alloc.dupe(u8, q.columnText(1)),
        .password_hash = try alloc.dupe(u8, q.columnText(2)),
    };
}

/// Caller owns the returned handle.
pub fn getUserHandle(db: *sqlite.Db, alloc: std.mem.Allocator, id: i64) !?[]u8 {
    var q = try db.prepare("SELECT handle FROM user WHERE id=?;");
    defer q.finalize();
    q.bindInt(1, id);
    if (!try q.step()) return null;
    return try alloc.dupe(u8, q.columnText(0));
}

/// Caller owns the returned token.
pub fn getApiToken(db: *sqlite.Db, alloc: std.mem.Allocator, user_id: i64) !?[]u8 {
    var q = try db.prepare("SELECT api_token FROM user WHERE id=?;");
    defer q.finalize();
    q.bindInt(1, user_id);
    if (!try q.step()) return null;
    return try alloc.dupe(u8, q.columnText(0));
}

/// User id for an api credential; empty stored tokens never match.
pub fn userIdByToken(db: *sqlite.Db, handle: []const u8, token: []const u8) !?i64 {
    if (token.len == 0) return null;
    var q = try db.prepare("SELECT id FROM user WHERE handle=? AND api_token=? AND api_token<>'';");
    defer q.finalize();
    q.bindText(1, handle);
    q.bindText(2, token);
    if (!try q.step()) return null;
    return q.columnInt(0);
}

/// Raw settings JSON for a user. Caller owns the returned string.
pub fn getSettings(db: *sqlite.Db, alloc: std.mem.Allocator, user_id: i64) !?[]u8 {
    var q = try db.prepare("SELECT settings FROM user WHERE id=?;");
    defer q.finalize();
    q.bindInt(1, user_id);
    if (!try q.step()) return null;
    return try alloc.dupe(u8, q.columnText(0));
}

pub fn setSettings(db: *sqlite.Db, user_id: i64, json: []const u8) !void {
    var q = try db.prepare("UPDATE user SET settings=? WHERE id=?;");
    defer q.finalize();
    q.bindText(1, json);
    q.bindInt(2, user_id);
    _ = try q.step();
}

pub fn setApiToken(db: *sqlite.Db, user_id: i64, token: []const u8) !void {
    var q = try db.prepare("UPDATE user SET api_token=? WHERE id=?;");
    defer q.finalize();
    q.bindText(1, token);
    q.bindInt(2, user_id);
    _ = try q.step();
}

/// Create a user; returns the new id, or null when the handle is taken.
pub fn createUser(db: *sqlite.Db, handle: []const u8, hash: []const u8, now: i64) !?i64 {
    var q = try db.prepare("INSERT OR IGNORE INTO user(handle, password_hash, created_at) VALUES (?,?,?);");
    defer q.finalize();
    q.bindText(1, handle);
    q.bindText(2, hash);
    q.bindInt(3, now);
    _ = try q.step();
    return try (getUserByHandleId(db, handle));
}

fn getUserByHandleId(db: *sqlite.Db, handle: []const u8) !?i64 {
    var q = try db.prepare("SELECT id FROM user WHERE handle=? LIMIT 1;");
    defer q.finalize();
    q.bindText(1, handle);
    if (!try q.step()) return null;
    return q.columnInt(0);
}

pub fn setUserPassword(db: *sqlite.Db, handle: []const u8, hash: []const u8) !void {
    var q = try db.prepare("UPDATE user SET password_hash=? WHERE handle=?;");
    defer q.finalize();
    q.bindText(1, hash);
    q.bindText(2, handle);
    _ = try q.step();
}

/// System-wide config value. Caller owns the returned string.
pub fn getSysconf(db: *sqlite.Db, alloc: std.mem.Allocator, key: []const u8) !?[]u8 {
    var q = try db.prepare("SELECT value FROM sysconf WHERE key=?;");
    defer q.finalize();
    q.bindText(1, key);
    if (!try q.step()) return null;
    return try alloc.dupe(u8, q.columnText(0));
}

pub fn setSysconf(db: *sqlite.Db, key: []const u8, value: []const u8) !void {
    var q = try db.prepare("INSERT INTO sysconf(key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;");
    defer q.finalize();
    q.bindText(1, key);
    q.bindText(2, value);
    _ = try q.step();
}

/// User id linked to an OIDC subject, if any.
pub fn userIdByOidcSub(db: *sqlite.Db, sub: []const u8) !?i64 {
    if (sub.len == 0) return null;
    var q = try db.prepare("SELECT id FROM user WHERE oidc_sub=? AND oidc_sub<>'';");
    defer q.finalize();
    q.bindText(1, sub);
    if (!try q.step()) return null;
    return q.columnInt(0);
}

pub fn setUserOidcSub(db: *sqlite.Db, user_id: i64, sub: []const u8) !void {
    var q = try db.prepare("UPDATE user SET oidc_sub=? WHERE id=?;");
    defer q.finalize();
    q.bindText(1, sub);
    q.bindInt(2, user_id);
    _ = try q.step();
}

pub fn createSession(db: *sqlite.Db, token: []const u8, user_id: i64, expires_at: i64) !void {
    var q = try db.prepare("INSERT INTO session(token, user_id, expires_at) VALUES (?,?,?);");
    defer q.finalize();
    q.bindText(1, token);
    q.bindInt(2, user_id);
    q.bindInt(3, expires_at);
    _ = try q.step();
}

/// Returns the user id for a live session, null when missing or expired.
pub fn sessionUser(db: *sqlite.Db, token: []const u8, now: i64) !?i64 {
    var q = try db.prepare("SELECT user_id FROM session WHERE token=? AND expires_at>?;");
    defer q.finalize();
    q.bindText(1, token);
    q.bindInt(2, now);
    if (!try q.step()) return null;
    return q.columnInt(0);
}

pub fn deleteSession(db: *sqlite.Db, token: []const u8) !void {
    var q = try db.prepare("DELETE FROM session WHERE token=?;");
    defer q.finalize();
    q.bindText(1, token);
    _ = try q.step();
}

/// True when a fetched archive copy exists for the bookmark.
pub fn archiveDone(db: *sqlite.Db, id: i64) !bool {
    var q = try db.prepare("SELECT 1 FROM archive a JOIN bookmark b ON a.url=b.url WHERE b.id=? AND a.status='done';");
    defer q.finalize();
    q.bindInt(1, id);
    return try q.step();
}

/// Returns the id of a bookmark with the given url, or null if not found.
pub fn findIdByUrl(db: *sqlite.Db, url: []const u8) !?i64 {
    var q = try db.prepare("SELECT id FROM bookmark WHERE url=? LIMIT 1;");
    defer q.finalize();
    q.bindText(1, url);
    if (!try q.step()) return null;
    return q.columnInt(0);
}

/// Like findIdByUrl but only within one user's bookmarks.
pub fn findIdByUrlFor(db: *sqlite.Db, url: []const u8, user_id: i64) !?i64 {
    var q = try db.prepare("SELECT id FROM bookmark WHERE url=? AND user_id=? LIMIT 1;");
    defer q.finalize();
    q.bindText(1, url);
    q.bindInt(2, user_id);
    if (!try q.step()) return null;
    return q.columnInt(0);
}

pub fn deleteBookmark(db: *sqlite.Db, id: i64) !void {
    try unindex(db, id);
    var s = try db.prepare("DELETE FROM bookmark WHERE id=?;");
    defer s.finalize();
    s.bindInt(1, id);
    _ = try s.step();
}

fn unindex(db: *sqlite.Db, id: i64) !void {
    var del = try db.prepare("DELETE FROM bookmark_fts WHERE rowid=?;");
    defer del.finalize();
    del.bindInt(1, id);
    _ = try del.step();
}

test "update then delete" {
    var db = try testDb();
    defer db.close();
    const id = try insertBookmark(&db, .{ .url = "https://u", .title = "old" }, 1, 1);
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
    var q = try db.prepare("SELECT rowid FROM bookmark_fts WHERE bookmark_fts MATCH ? ORDER BY rank LIMIT ?;");
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
    _ = try insertBookmark(&db, .{ .url = "https://zig", .title = "Zig language", .tags = &.{"programming"} }, 1, 1);
    _ = try insertBookmark(&db, .{ .url = "https://cook", .title = "Cooking", .tags = &.{"food"} }, 2, 1);

    const a = try search(&db, testing.allocator, "zig", 10);
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 1), a.len);

    const b = try search(&db, testing.allocator, "programming", 10);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 1), b.len);
}

/// Returns a prepared statement that yields (tag, count) rows for one user,
/// ordered by count desc. Finalize after binding user_id to ?1 and stepping.
pub fn prepareTagCounts(db: *sqlite.Db) !sqlite.Stmt {
    return db.prepare(
        \\SELECT t.tag, count(*) c FROM tag t JOIN bookmark b ON b.id=t.bookmark_id
        \\WHERE b.user_id=?1 GROUP BY t.tag ORDER BY c DESC, t.tag;
    );
}

/// Returns current Unix time in seconds.
pub fn nowUnix() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// Store the archived page (html compressed) + status, then refresh
/// FTS so body becomes searchable.
pub fn setArchive(db: *sqlite.Db, url: []const u8, html: []const u8, text: []const u8, status: models.ArchiveStatus, now: i64) !void {
    // Only the html is compressed; text stays readable to SQL, which
    // reads it when building the fts body.
    const stored = try gzip.compress(std.heap.page_allocator, html);
    defer std.heap.page_allocator.free(stored);
    var s = try db.prepare(
        "INSERT INTO archive(url,html,text,fetched_at,status) VALUES (?,?,?,?,?) " ++
        "ON CONFLICT(url) DO UPDATE SET html=excluded.html,text=excluded.text,fetched_at=excluded.fetched_at,status=excluded.status;",
    );
    defer s.finalize();
    s.bindText(1, url);
    s.bindBlob(2, stored);
    s.bindText(3, text);
    s.bindInt(4, now);
    s.bindText(5, @tagName(status));
    _ = try s.step();
    // Everyone bookmarking the url shares the artifact; refresh their fts rows.
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(std.heap.page_allocator);
    {
        var q = try db.prepare("SELECT id FROM bookmark WHERE url=?;");
        defer q.finalize();
        q.bindText(1, url);
        while (try q.step()) try ids.append(std.heap.page_allocator, q.columnInt(0));
    }
    for (ids.items) |bid| try reindex(db, bid);
}

/// Queue a url for archiving unless an artifact (or attempt) already exists.
pub fn enqueueArchive(db: *sqlite.Db, url: []const u8) !void {
    var s = try db.prepare("INSERT OR IGNORE INTO archive(url) VALUES (?);");
    defer s.finalize();
    s.bindText(1, url);
    _ = try s.step();
}

test "stored pages are compressed on write and read back" {
    var db = try testDb();
    defer db.close();
    const html = "<html>" ++ ("zebra " ** 400) ++ "</html>";
    try setArchive(&db, "https://p", html, "zebra", .done, 2);

    var q = try db.prepare("SELECT hex(substr(html,1,2)), html FROM archive WHERE url=?;");
    defer q.finalize();
    q.bindText(1, "https://p");
    try testing.expect(try q.step());
    try testing.expectEqualStrings("1F8B", q.columnText(0));
    const back = try gzip.decode(testing.allocator, q.columnBlob(1));
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(html, back);
}

test "the one-off pass converts pages stored before compression" {
    var db = try testDb();
    defer db.close();
    var ins = try db.prepare("INSERT INTO archive(url,html,text,status) VALUES (?,?,'','done');");
    ins.bindText(1, "https://old");
    ins.bindText(2, "<html>plain</html>");
    _ = try ins.step();
    ins.finalize();

    // migrate() already marked this database converted; an older one
    // reaching the pass for the first time carries no such mark.
    try db.exec("DELETE FROM sysconf WHERE key='archive_html_compressed';");
    try compressStoredPages(&db);

    var q = try db.prepare("SELECT html FROM archive WHERE url='https://old';");
    defer q.finalize();
    try testing.expect(try q.step());
    const stored = q.columnBlob(0);
    try testing.expect(gzip.isGzip(stored));
    const back = try gzip.decode(testing.allocator, stored);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("<html>plain</html>", back);
}

test "archived text becomes searchable" {
    var db = try testDb();
    defer db.close();
    const id = try insertBookmark(&db, .{ .url = "https://p", .title = "Plain" }, 1, 1);
    _ = id;
    try setArchive(&db, "https://p", "<html>x</html>", "elephant zebra", .done, 2);
    const hits = try search(&db, testing.allocator, "zebra", 10);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
}
