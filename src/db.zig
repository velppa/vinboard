const std = @import("std");
const sqlite = @import("sqlite.zig");
const gzip = @import("gzip.zig");
const models = @import("models.zig");
const trackers = @import("trackers.zig");

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
    \\CREATE VIRTUAL TABLE IF NOT EXISTS bookmark_fts USING fts5(
    \\  title, notes, url, tags, body, content='', contentless_delete=1
    \\);
    \\CREATE TABLE IF NOT EXISTS sysconf(
    \\  key TEXT PRIMARY KEY,
    \\  value TEXT NOT NULL
    \\);
;

/// Page copies live in their own database file, attached as `arc`, so the
/// bookmarks database stays small.  Unqualified `archive` resolves there.
const ARCHIVE_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS arc.archive(
    \\  url TEXT PRIMARY KEY,
    \\  html BLOB,
    \\  text TEXT,
    \\  fetched_at INTEGER,
    \\  status TEXT NOT NULL DEFAULT 'pending'
    \\);
;

/// Attach the database holding archived pages as `arc`.  Call before
/// `migrate`.
pub fn attachArchive(db: *sqlite.Db, path: [:0]const u8) !void {
    var q = try db.prepare("ATTACH DATABASE ? AS arc;");
    defer q.finalize();
    q.bindText(1, path);
    _ = try q.step();
    try db.exec("PRAGMA arc.journal_mode=WAL;");
}

/// Move page copies the bookmarks database still holds into the archive
/// database.  One-way: an older binary no longer finds them.
fn moveArchive(db: *sqlite.Db) !void {
    try db.exec(ARCHIVE_SCHEMA);
    if (!try tableExists(db, "archive")) return;
    try db.exec(
        \\BEGIN;
        \\INSERT OR IGNORE INTO arc.archive(url,html,text,fetched_at,status)
        \\  SELECT url,html,text,fetched_at,status FROM main.archive;
        \\DROP TABLE main.archive;
        \\COMMIT;
    );
    try db.exec("VACUUM main;");
    std.log.info("moved archived pages into the archive database", .{});
}

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
    if (!try hasColumn(db, "bookmark", "edited")) {
        try db.exec("ALTER TABLE bookmark ADD COLUMN edited INTEGER NOT NULL DEFAULT 0;");
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
    try moveArchive(db);
    try compressStoredPages(db);
    try cleanTrackedUrls(db);
}

/// Strip tracking parameters from every saved url.  A bookmark whose clean
/// url its owner already has is folded into that one: its tags join it, and
/// it goes.  Only urls that change are touched, so running on every start
/// costs one scan.
fn cleanTrackedUrls(db: *sqlite.Db) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = struct { id: i64, user_id: i64, url: []const u8, clean: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    {
        var q = try db.prepare("SELECT id, user_id, url FROM bookmark WHERE url LIKE '%?%' OR url LIKE '%#%';");
        defer q.finalize();
        while (try q.step()) {
            const url = try a.dupe(u8, q.columnText(2));
            const clean = try trackers.clean(a, url);
            if (clean.ptr != url.ptr) try rows.append(a, .{
                .id = q.columnInt(0),
                .user_id = q.columnInt(1),
                .url = url,
                .clean = clean,
            });
        }
    }
    if (rows.items.len == 0) return;

    try db.exec("BEGIN;");
    errdefer db.exec("ROLLBACK;") catch {};
    var merged: usize = 0;
    for (rows.items) |r| {
        if (try rehome(db, r.id, r.user_id, r.clean)) merged += 1;
        try moveArchiveRow(db, r.url, r.clean);
    }
    try db.exec("COMMIT;");
    std.log.info("cleaned tracking parameters from {d} urls ({d} merged into bookmarks already saved)", .{ rows.items.len, merged });
}

/// Point bookmark ID, owned by USER_ID, at URL.  When the user already has
/// a bookmark there, ID is folded into it instead: its tags join that one,
/// and it goes.  Returns whether it was folded.
fn rehome(db: *sqlite.Db, id: i64, user_id: i64, url: []const u8) !bool {
    if (try findIdByUrlFor(db, url, user_id)) |keep| {
        if (keep == id) return false;
        var tags = try db.prepare("INSERT OR IGNORE INTO tag(bookmark_id, tag) SELECT ?1, tag FROM tag WHERE bookmark_id=?2;");
        defer tags.finalize();
        tags.bindInt(1, keep);
        tags.bindInt(2, id);
        _ = try tags.step();
        var drop = try db.prepare("DELETE FROM tag WHERE bookmark_id=?;");
        defer drop.finalize();
        drop.bindInt(1, id);
        _ = try drop.step();
        try deleteBookmark(db, id);
        try reindex(db, keep);
        return true;
    }
    try setText(db, id, "url", url);
    try reindex(db, id);
    return false;
}

/// Move the archived copy of OLD to NEW, unless NEW has one already.
fn moveArchiveRow(db: *sqlite.Db, old: []const u8, new: []const u8) !void {
    var move = try db.prepare("UPDATE OR IGNORE archive SET url=?1 WHERE url=?2;");
    defer move.finalize();
    move.bindText(1, new);
    move.bindText(2, old);
    _ = try move.step();
    var stale = try db.prepare("DELETE FROM archive WHERE url=?;");
    defer stale.finalize();
    stale.bindText(1, old);
    _ = try stale.step();
}

/// Move every bookmark saved as OLD to NEW, with its archived copy,
/// folding it into the bookmark its owner already has at NEW.  Returns how
/// many were folded.
pub fn moveUrl(db: *sqlite.Db, alloc: std.mem.Allocator, old: []const u8, new: []const u8) !usize {
    var rows: std.ArrayList([2]i64) = .empty;
    defer rows.deinit(alloc);
    {
        var q = try db.prepare("SELECT id, user_id FROM bookmark WHERE url=?;");
        defer q.finalize();
        q.bindText(1, old);
        while (try q.step()) try rows.append(alloc, .{ q.columnInt(0), q.columnInt(1) });
    }
    try db.exec("BEGIN;");
    errdefer db.exec("ROLLBACK;") catch {};
    var merged: usize = 0;
    for (rows.items) |r| {
        if (try rehome(db, r[0], r[1], new)) merged += 1;
    }
    try moveArchiveRow(db, old, new);
    try db.exec("COMMIT;");
    return merged;
}

test "moveUrl folds a share link into the post already saved" {
    var db = try testDb();
    defer db.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const post = try insertBookmark(&db, .{ .url = "https://r.test/comments/1/", .tags = &.{"lisp"} }, 1, 1);
    const share = try insertBookmark(&db, .{ .url = "https://r.test/s/abc", .tags = &.{"clojure"} }, 2, 1);
    try db.exec("INSERT INTO archive(url,html,text,status) VALUES ('https://r.test/s/abc','p','t','done');");
    try testing.expectEqual(@as(usize, 1), try moveUrl(&db, a, "https://r.test/s/abc", "https://r.test/comments/1/"));
    try testing.expect((try getBookmark(&db, a, share)) == null);
    try testing.expectEqual(@as(usize, 2), (try getBookmark(&db, a, post)).?.tags.len);
    var q = try db.prepare("SELECT count(*) FROM archive WHERE url='https://r.test/comments/1/';");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 1), q.columnInt(0));
}

test "migrate strips tracking parameters and folds duplicates" {
    var db = try testDb();
    defer db.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kept = try insertBookmark(&db, .{ .url = "https://x.test/a", .tags = &.{"mine"} }, 1, 1);
    const dup = try insertBookmark(&db, .{ .url = "https://x.test/a?utm_source=hn", .tags = &.{"hn"} }, 2, 1);
    const lone = try insertBookmark(&db, .{ .url = "https://x.test/b?id=1&fbclid=z" }, 3, 1);
    const other = try insertBookmark(&db, .{ .url = "https://x.test/a?utm_source=hn" }, 4, 2);
    try db.exec("INSERT INTO archive(url,html,text,status) VALUES ('https://x.test/b?id=1&fbclid=z','p','t','done');");
    try migrate(&db);

    try testing.expect((try getBookmark(&db, a, dup)) == null);
    try testing.expectEqual(@as(usize, 2), (try getBookmark(&db, a, kept)).?.tags.len);
    try testing.expectEqualStrings("https://x.test/b?id=1", (try getBookmark(&db, a, lone)).?.url);
    try testing.expectEqualStrings("https://x.test/a", (try getBookmark(&db, a, other)).?.url);
    var q = try db.prepare("SELECT count(*) FROM archive WHERE url='https://x.test/b?id=1';");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 1), q.columnInt(0));
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
    try attachArchive(&db, ":memory:");
    try migrate(&db);
    return db;
}

pub fn testDbPub() !sqlite.Db {
    var db = try sqlite.Db.openMemory();
    try attachArchive(&db, ":memory:");
    try migrate(&db);
    return db;
}

test "migrate creates tables" {
    var db = try testDb();
    defer db.close();
    var q = try db.prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('bookmark','tag','archive');");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqual(@as(i64, 2), q.columnInt(0));
    var a = try db.prepare("SELECT count(*) FROM arc.sqlite_master WHERE type='table' AND name='archive';");
    defer a.finalize();
    try testing.expect(try a.step());
    try testing.expectEqual(@as(i64, 1), a.columnInt(0));
}

test "migrate moves archived pages out of the bookmarks database" {
    var db = try sqlite.Db.openMemory();
    defer db.close();
    try db.exec(
        \\CREATE TABLE archive(url TEXT PRIMARY KEY, html BLOB, text TEXT, fetched_at INTEGER,
        \\  status TEXT NOT NULL DEFAULT 'pending');
        \\INSERT INTO archive VALUES ('https://kept', 'page', 'text', 1, 'done');
    );
    try attachArchive(&db, ":memory:");
    try migrate(&db);
    try testing.expect(!try tableExists(&db, "archive"));
    var q = try db.prepare("SELECT status FROM arc.archive WHERE url='https://kept';");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("done", q.columnText(0));
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

/// Fields of a bookmark a person has set by hand, as bits of its `edited`
/// column.  A client saving the url again leaves them alone.
pub const Edited = struct {
    pub const title: i64 = 1;
    pub const notes: i64 = 2;
    pub const tags: i64 = 4;
    pub const toread: i64 = 8;
    pub const shared: i64 = 16;
};

/// Apply a person's edit, remembering which fields it changed.
pub fn editBookmark(db: *sqlite.Db, alloc: std.mem.Allocator, id: i64, p: Patch, now: i64) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cur = (try getBookmark(db, arena.allocator(), id)) orelse return;
    var mask: i64 = 0;
    if (p.title) |v| if (!std.mem.eql(u8, v, cur.title)) {
        mask |= Edited.title;
    };
    if (p.notes) |v| if (!std.mem.eql(u8, v, cur.notes)) {
        mask |= Edited.notes;
    };
    if (p.tags) |v| if (!sameTags(v, cur.tags)) {
        mask |= Edited.tags;
    };
    if (p.toread) |v| if (v != cur.toread) {
        mask |= Edited.toread;
    };
    if (p.shared) |v| if (v != cur.shared) {
        mask |= Edited.shared;
    };
    if (mask != 0) {
        var q = try db.prepare("UPDATE bookmark SET edited = edited | ? WHERE id=?;");
        defer q.finalize();
        q.bindInt(1, mask);
        q.bindInt(2, id);
        _ = try q.step();
    }
    try updateBookmark(db, id, p, now);
}

/// Apply what a client sent when saving a url again: fields a person edited
/// by hand stay as they are, and empty values never blank a field.
pub fn resaveBookmark(db: *sqlite.Db, id: i64, p: Patch, now: i64) !void {
    var q = try db.prepare("SELECT edited FROM bookmark WHERE id=?;");
    defer q.finalize();
    q.bindInt(1, id);
    if (!try q.step()) return;
    const mask = q.columnInt(0);
    var r = p;
    if (mask & Edited.title != 0 or (r.title != null and r.title.?.len == 0)) r.title = null;
    if (mask & Edited.notes != 0 or (r.notes != null and r.notes.?.len == 0)) r.notes = null;
    if (mask & Edited.tags != 0 or (r.tags != null and r.tags.?.len == 0)) r.tags = null;
    if (mask & Edited.toread != 0) r.toread = null;
    if (mask & Edited.shared != 0) r.shared = null;
    try updateBookmark(db, id, r, now);
}

fn sameTags(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    outer: for (a) |x| {
        for (b) |y| if (std.mem.eql(u8, x, y)) continue :outer;
        return false;
    }
    return true;
}

test "resave keeps hand-edited fields" {
    var db = try testDb();
    defer db.close();
    const id = try insertBookmark(&db, .{ .url = "https://e", .title = "Browser", .tags = &.{"auto"} }, 1, 1);
    try editBookmark(&db, testing.allocator, id, .{ .title = "Mine", .tags = &.{ "auto", "kept" }, .notes = "" }, 2);
    try resaveBookmark(&db, id, .{ .title = "Browser again", .notes = "from client", .tags = &.{"other"}, .toread = true }, 3);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bm = (try getBookmark(&db, arena.allocator(), id)).?;
    try testing.expectEqualStrings("Mine", bm.title);
    try testing.expectEqual(@as(usize, 2), bm.tags.len);
    // Notes were submitted unchanged, so they are not marked and the client's win.
    try testing.expectEqualStrings("from client", bm.notes);
    try testing.expect(bm.toread);
}

test "resave never blanks a field" {
    var db = try testDb();
    defer db.close();
    const id = try insertBookmark(&db, .{ .url = "https://f", .title = "Kept", .tags = &.{"t"} }, 1, 1);
    try resaveBookmark(&db, id, .{ .title = "", .tags = &.{} }, 2);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bm = (try getBookmark(&db, arena.allocator(), id)).?;
    try testing.expectEqualStrings("Kept", bm.title);
    try testing.expectEqual(@as(usize, 1), bm.tags.len);
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
pub const ArchiveState = enum { none, pending, done, failed };

/// Where bookmark ID's page copy stands: none queued, waiting, saved, or
/// given up on (failed or dead link).
pub fn archiveState(db: *sqlite.Db, id: i64) !ArchiveState {
    var q = try db.prepare("SELECT a.status FROM archive a JOIN bookmark b ON a.url=b.url WHERE b.id=?;");
    defer q.finalize();
    q.bindInt(1, id);
    if (!try q.step()) return .none;
    const status = q.columnText(0);
    if (std.mem.eql(u8, status, "done")) return .done;
    if (std.mem.eql(u8, status, "pending")) return .pending;
    return .failed;
}

test "archiveState follows the archive row" {
    var db = try testDb();
    defer db.close();
    const id = try insertBookmark(&db, .{ .url = "https://s" }, 1, 1);
    try testing.expectEqual(ArchiveState.none, try archiveState(&db, id));
    try enqueueArchive(&db, "https://s");
    try testing.expectEqual(ArchiveState.pending, try archiveState(&db, id));
    try db.exec("UPDATE archive SET status='dead' WHERE url='https://s';");
    try testing.expectEqual(ArchiveState.failed, try archiveState(&db, id));
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

/// A user's most recently used tags, most recent first, at most `limit` of
/// them.  A tag is as recent as the newest bookmark carrying it.
pub fn recentTags(db: *sqlite.Db, alloc: std.mem.Allocator, user_id: i64, limit: usize) ![][]const u8 {
    var q = try db.prepare(
        \\SELECT t.tag FROM tag t JOIN bookmark b ON b.id=t.bookmark_id
        \\WHERE b.user_id=?1 GROUP BY t.tag ORDER BY max(b.created_at) DESC, t.tag LIMIT ?2;
    );
    defer q.finalize();
    q.bindInt(1, user_id);
    q.bindInt(2, @intCast(limit));
    var tags: std.ArrayList([]const u8) = .empty;
    errdefer tags.deinit(alloc);
    while (try q.step()) try tags.append(alloc, try alloc.dupe(u8, q.columnText(0)));
    return tags.toOwnedSlice(alloc);
}

pub const Link = struct { title: []const u8, url: []const u8 };

/// A user's newest bookmarks carrying `tag`, newest first, at most `limit`.
pub fn recentLinks(db: *sqlite.Db, alloc: std.mem.Allocator, user_id: i64, tag: []const u8, limit: usize) ![]Link {
    var q = try db.prepare(
        \\SELECT b.title, b.url FROM bookmark b JOIN tag t ON t.bookmark_id=b.id
        \\WHERE b.user_id=?1 AND t.tag=?2 ORDER BY b.created_at DESC, b.id DESC LIMIT ?3;
    );
    defer q.finalize();
    q.bindInt(1, user_id);
    q.bindText(2, tag);
    q.bindInt(3, @intCast(limit));
    var links: std.ArrayList(Link) = .empty;
    errdefer links.deinit(alloc);
    while (try q.step()) try links.append(alloc, .{
        .title = try alloc.dupe(u8, q.columnText(0)),
        .url = try alloc.dupe(u8, q.columnText(1)),
    });
    return links.toOwnedSlice(alloc);
}

test "recentTags ranks by the newest bookmark and stops at the limit" {
    var db = try testDb();
    defer db.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try insertBookmark(&db, .{ .url = "https://a", .tags = &.{"hn"} }, 1, 1);
    _ = try insertBookmark(&db, .{ .url = "https://b", .tags = &.{"hn"} }, 2, 1);
    _ = try insertBookmark(&db, .{ .url = "https://c", .tags = &.{"zig"} }, 3, 1);
    _ = try insertBookmark(&db, .{ .url = "https://d", .tags = &.{"food"} }, 4, 2);

    const tags = try recentTags(&db, a, 1, 10);
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("zig", tags[0]);
    try testing.expectEqualStrings("hn", tags[1]);
    try testing.expectEqual(@as(usize, 1), (try recentTags(&db, a, 1, 1)).len);
}

test "recentLinks lists a tag's newest bookmarks first" {
    var db = try testDb();
    defer db.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try insertBookmark(&db, .{ .url = "https://old", .title = "Old", .tags = &.{"hn"} }, 1, 1);
    _ = try insertBookmark(&db, .{ .url = "https://new", .title = "New", .tags = &.{"hn"} }, 2, 1);
    _ = try insertBookmark(&db, .{ .url = "https://other", .tags = &.{"zig"} }, 3, 1);

    const links = try recentLinks(&db, a, 1, "hn", 5);
    try testing.expectEqual(@as(usize, 2), links.len);
    try testing.expectEqualStrings("https://new", links[0].url);
    try testing.expectEqualStrings("New", links[0].title);
    try testing.expectEqual(@as(usize, 1), (try recentLinks(&db, a, 1, "hn", 1)).len);
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
/// Queue URL to be archived again, keeping the current copy until the new
/// one replaces it.
pub fn requeueArchive(db: *sqlite.Db, url: []const u8) !void {
    var s = try db.prepare("INSERT INTO archive(url) VALUES (?) ON CONFLICT(url) DO UPDATE SET status='pending';");
    defer s.finalize();
    s.bindText(1, url);
    _ = try s.step();
}

test "requeueArchive puts an archived url back in the queue" {
    var db = try testDb();
    defer db.close();
    try db.exec("INSERT INTO archive(url,html,text,status) VALUES ('https://a','x','y','done');");
    try requeueArchive(&db, "https://a");
    var q = try db.prepare("SELECT status, html FROM archive WHERE url='https://a';");
    defer q.finalize();
    try testing.expect(try q.step());
    try testing.expectEqualStrings("pending", q.columnText(0));
    try testing.expectEqualStrings("x", q.columnText(1));
}

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
