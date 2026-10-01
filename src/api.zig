const std = @import("std");
const httpz = @import("httpz");
const server = @import("server.zig");
const db_mod = @import("db.zig");
const suggest_mod = @import("suggest.zig");
const gzip = @import("gzip.zig");
const models = @import("models.zig");

const App = server.App;
const auth = @import("auth.zig");

/// Authenticated api user: Bearer/auth_token "handle:TOKEN", or a web session
/// cookie. Caller holds the db lock. Null means unauthorized.
pub fn apiUserId(app: *App, req: *httpz.Request) ?i64 {
    if (req.header("authorization")) |h| {
        if (h.len > 7 and std.ascii.eqlIgnoreCase(h[0..7], "bearer ")) {
            if (credUser(app, std.mem.trim(u8, h[7..], " "))) |uid| return uid;
        }
    }
    if (req.query() catch null) |qs| {
        if (qs.get("auth_token")) |cred| {
            if (credUser(app, cred)) |uid| return uid;
        }
    }
    if (req.header("cookie")) |c| {
        if (auth.cookieValue(c, "vb_session")) |tok| {
            if (db_mod.sessionUser(app.db, tok, db_mod.nowUnix()) catch null) |uid| return uid;
        }
    }
    return null;
}

fn credUser(app: *App, cred: []const u8) ?i64 {
    const colon = std.mem.indexOfScalar(u8, cred, ':') orelse return null;
    return db_mod.userIdByToken(app.db, cred[0..colon], cred[colon + 1 ..]) catch null;
}

pub fn unauthorized(res: *httpz.Response) !void {
    res.status = 401;
    try res.json(.{ .@"error" = "unauthorized" }, .{});
}

pub fn registerRoutes(router: anytype) void {
    router.*.post("/api/bookmarks", create, .{});
    router.*.get("/api/bookmarks", list, .{});
    router.*.get("/api/bookmarks/:id", get, .{});
    router.*.patch("/api/bookmarks/:id", patch, .{});
    router.*.delete("/api/bookmarks/:id", remove, .{});
    router.*.get("/api/search", searchH, .{});
    router.*.get("/api/tags", tags, .{});
    router.*.post("/api/import", importH, .{});
    router.*.get("/api/bookmarks/:id/archive", getArchive, .{});
}

const CreateBody = struct {
    url: []const u8,
    title: []const u8 = "",
    notes: []const u8 = "",
    toread: bool = false,
    shared: bool = false,
    tags: []const []const u8 = &.{},
};

const Shared = struct { url: []const u8, title: []const u8 };

/// Untangle a url that arrived as shared text, "<title><url>" glued
/// together: the url is the first http(s) link in it, and the text before
/// that becomes the title unless TITLE is already set.  Text with no link
/// comes back as it is.
fn splitShared(url: []const u8, title: []const u8) Shared {
    const text = std.mem.trim(u8, url, &std.ascii.whitespace);
    const at = std.ascii.indexOfIgnoreCase(text, "https://") orelse
        std.ascii.indexOfIgnoreCase(text, "http://") orelse
        return .{ .url = text, .title = title };
    const end = std.mem.indexOfAnyPos(u8, text, at, &std.ascii.whitespace) orelse text.len;
    const prefix = std.mem.trim(u8, text[0..at], &std.ascii.whitespace);
    return .{ .url = text[at..end], .title = if (title.len > 0) title else prefix };
}

/// The longest prefix of S at most MAX bytes long that ends on a
/// character boundary.
fn prefixUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var cut = max;
    while (cut > 0 and s[cut] & 0xC0 == 0x80) cut -= 1;
    return s[0..cut];
}

test "prefixUtf8" {
    try std.testing.expectEqualStrings("abc", prefixUtf8("abc", 5));
    try std.testing.expectEqualStrings("ab", prefixUtf8("abc", 2));
    try std.testing.expectEqualStrings("a", prefixUtf8("a\xc3\xa9", 2));
}

fn isWebUrl(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");
}

test "isWebUrl" {
    try std.testing.expect(isWebUrl("https://example.com"));
    try std.testing.expect(isWebUrl("HTTP://example.com"));
    try std.testing.expect(!isWebUrl("no browser in front"));
    try std.testing.expect(!isWebUrl("mailto:me@example.com"));
}

test "splitShared" {
    const glued = splitShared("Same Content? : r/BeautyGuruChatterhttps://www.reddit.com/r/x/comments/1/y/", "");
    try std.testing.expectEqualStrings("https://www.reddit.com/r/x/comments/1/y/", glued.url);
    try std.testing.expectEqualStrings("Same Content? : r/BeautyGuruChatter", glued.title);

    const plain = splitShared(" https://example.com/a \n", "");
    try std.testing.expectEqualStrings("https://example.com/a", plain.url);
    try std.testing.expectEqualStrings("", plain.title);

    const titled = splitShared("Page\nhttp://example.com/b more", "Given");
    try std.testing.expectEqualStrings("http://example.com/b", titled.url);
    try std.testing.expectEqualStrings("Given", titled.title);

    const nolink = splitShared("not a link", "");
    try std.testing.expectEqualStrings("not a link", nolink.url);
}

pub fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    var body = (try req.json(CreateBody)) orelse return badRequest(res, "invalid json");
    // Share sheets often hand over the page as "<title><url>" text.
    const shared = splitShared(body.url, body.title);
    body.url = shared.url;
    body.title = shared.title;
    if (body.url.len == 0) return badRequest(res, "url is required");
    if (!isWebUrl(body.url)) return badRequest(res, try std.fmt.allocPrint(
        res.arena,
        "url must start with http:// or https://, got: {s}",
        .{prefixUtf8(body.url, 200)},
    ));
    const now = db_mod.nowUnix();
    // A caller that brought no tags gets the model's, decided before the
    // database lock is taken and held for the write.
    const bookmark_tags = if (body.tags.len > 0) body.tags else suggested: {
        app.db_mutex.lockUncancelable(app.io);
        const uid = apiUserId(app, req);
        app.db_mutex.unlock(app.io);
        break :suggested if (uid) |u| suggest_mod.forBookmark(
            res.arena,
            app.io,
            app.suggest,
            app.db,
            app.db_mutex,
            u,
            body.title,
            body.url,
            body.notes,
        ) else &.{};
    };
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = apiUserId(app, req) orelse return unauthorized(res);
    // Re-posting a url the user already saved updates it (Pinboard semantics).
    if (db_mod.findIdByUrlFor(app.db, body.url, auth_uid) catch |e| return dbError(res, e)) |existing| {
        db_mod.updateBookmark(app.db, existing, .{
            .title = body.title,
            .notes = body.notes,
            .toread = body.toread,
            .shared = body.shared,
            .tags = bookmark_tags,
        }, now) catch |e| return dbError(res, e);
        db_mod.enqueueArchive(app.db, body.url) catch {};
        res.status = 200;
        try res.json(.{ .id = existing, .status = "updated" }, .{});
        return;
    }
    const id = db_mod.insertBookmark(app.db, .{
        .url = body.url,
        .title = body.title,
        .notes = body.notes,
        .toread = body.toread,
        .shared = body.shared,
        .tags = bookmark_tags,
    }, now, auth_uid) catch |e| return dbError(res, e);
    db_mod.enqueueArchive(app.db, body.url) catch {};
    res.status = 201;
    try res.json(.{ .id = id, .status = "added" }, .{});
}

pub fn list(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    var f = db_mod.ListFilter{};
    const qs = try req.query();
    if (qs.get("tag")) |t| f.tag = t;
    if (qs.get("toread")) |v| f.toread = isTrue(v);
    if (qs.get("shared")) |v| f.shared = isTrue(v);
    if (qs.get("starred")) |v| f.starred = isTrue(v);
    if (qs.get("limit")) |v| f.limit = std.fmt.parseInt(i64, v, 10) catch 100;
    if (qs.get("offset")) |v| f.offset = std.fmt.parseInt(i64, v, 10) catch 0;
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = apiUserId(app, req) orelse return unauthorized(res);
    f.user_id = auth_uid;
    const ids = db_mod.listBookmarkIds(app.db, res.arena, f) catch |e| return dbError(res, e);
    try writeBookmarkArray(app, res, ids, null);
}

fn isTrue(v: []const u8) bool {
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
}

fn writeBookmarkArray(app: *App, res: *httpz.Response, ids: []const i64, only_user: ?i64) !void {
    var arr: std.ArrayList(models.Bookmark) = .empty;
    for (ids) |id| {
        if (try db_mod.getBookmark(app.db, res.arena, id)) |bm| {
            if (only_user) |u| {
                if (bm.user_id != u) continue;
            }
            try arr.append(res.arena, bm);
        }
    }
    res.status = 200;
    try res.json(arr.items, .{});
}

pub fn get(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = idParam(req) orelse return badRequest(res, "bad id");
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = apiUserId(app, req) orelse return unauthorized(res);
    const bm = (db_mod.getBookmark(app.db, res.arena, id) catch |e| return dbError(res, e)) orelse return notFound(res);
    if (bm.user_id != auth_uid) return notFound(res);
    res.status = 200;
    try res.json(bm, .{});
}

const PatchBody = struct {
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    toread: ?bool = null,
    shared: ?bool = null,
    starred: ?bool = null,
    tags: ?[]const []const u8 = null,
};

pub fn patch(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = idParam(req) orelse return badRequest(res, "bad id");
    const body = (try req.json(PatchBody)) orelse return badRequest(res, "invalid json");
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = apiUserId(app, req) orelse return unauthorized(res);
    const owned = (db_mod.getBookmark(app.db, res.arena, id) catch |e| return dbError(res, e)) orelse return notFound(res);
    if (owned.user_id != auth_uid) return notFound(res);
    db_mod.updateBookmark(app.db, id, .{
        .url = body.url,
        .title = body.title,
        .notes = body.notes,
        .toread = body.toread,
        .shared = body.shared,
        .starred = body.starred,
        .tags = body.tags,
    }, db_mod.nowUnix()) catch |e| return dbError(res, e);
    res.status = 204;
}

pub fn remove(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = idParam(req) orelse return badRequest(res, "bad id");
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = apiUserId(app, req) orelse return unauthorized(res);
    const owned = (db_mod.getBookmark(app.db, res.arena, id) catch |e| return dbError(res, e)) orelse return notFound(res);
    if (owned.user_id != auth_uid) return notFound(res);
    db_mod.deleteBookmark(app.db, id) catch |e| return dbError(res, e);
    res.status = 204;
}

pub fn searchH(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const qs = try req.query();
    const term = qs.get("q") orelse return badRequest(res, "missing q");
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = apiUserId(app, req) orelse return unauthorized(res);
    const ids = db_mod.search(app.db, res.arena, term, 100) catch |e| return dbError(res, e);
    try writeBookmarkArray(app, res, ids, auth_uid);
}

pub fn tags(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = apiUserId(app, req) orelse return unauthorized(res);
    const TagCount = struct { tag: []const u8, count: i64 };
    var arr: std.ArrayList(TagCount) = .empty;
    var st = db_mod.prepareTagCounts(app.db) catch |e| return dbError(res, e);
    defer st.finalize();
    st.bindInt(1, auth_uid);
    while (st.step() catch |e| return dbError(res, e)) {
        try arr.append(res.arena, .{
            .tag = try res.arena.dupe(u8, st.columnText(0)),
            .count = st.columnInt(1),
        });
    }
    res.status = 200;
    try res.json(arr.items, .{});
}

pub fn importH(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const importer = @import("import.zig");
    const qs = try req.query();
    const source = qs.get("source") orelse return badRequest(res, "missing source");
    const raw = req.body() orelse return badRequest(res, "empty body");
    var imp = if (std.mem.eql(u8, source, "pinboard"))
        importer.parsePinboard(app.gpa, raw) catch |e| return dbError(res, e)
    else if (std.mem.eql(u8, source, "safari"))
        importer.parseSafari(app.gpa, raw) catch |e| return dbError(res, e)
    else
        return badRequest(res, "unknown source");
    defer imp.deinit();
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = apiUserId(app, req) orelse return unauthorized(res);
    const n = importer.importInto(app.db, imp, auth_uid) catch |e| return dbError(res, e);
    res.status = 200;
    try res.json(.{ .imported = n }, .{});
}

pub fn getArchive(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = idParam(req) orelse return badRequest(res, "bad id");
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = apiUserId(app, req) orelse return unauthorized(res);
    const owned = (db_mod.getBookmark(app.db, res.arena, id) catch |e| return dbError(res, e)) orelse return notFound(res);
    if (owned.user_id != auth_uid) return notFound(res);
    var q = app.db.prepare("SELECT html,status FROM archive WHERE url=?;") catch |e| return dbError(res, e);
    defer q.finalize();
    q.bindText(1, owned.url);
    const has_row = q.step() catch |e| return dbError(res, e);
    if (!has_row) return notFound(res);
    const html = gzip.decode(res.arena, q.columnBlob(0)) catch |e| return dbError(res, e);
    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.body = html;
}

fn idParam(req: *httpz.Request) ?i64 {
    const s = req.param("id") orelse return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn badRequest(res: *httpz.Response, msg: []const u8) !void {
    res.status = 400;
    try res.json(.{ .@"error" = msg }, .{});
}

fn notFound(res: *httpz.Response) !void {
    res.status = 404;
    try res.json(.{ .@"error" = "not found" }, .{});
}

fn dbError(res: *httpz.Response, e: anyerror) !void {
    res.status = 500;
    try res.json(.{ .@"error" = @errorName(e) }, .{});
}
