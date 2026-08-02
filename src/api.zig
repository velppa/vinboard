const std = @import("std");
const httpz = @import("httpz");
const server = @import("server.zig");
const db_mod = @import("db.zig");
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

pub fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const body = (try req.json(CreateBody)) orelse return badRequest(res, "invalid json");
    const now = db_mod.nowUnix();
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    if (apiUserId(app, req) == null) return unauthorized(res);
    const id = db_mod.insertBookmark(app.db, .{
        .url = body.url,
        .title = body.title,
        .notes = body.notes,
        .toread = body.toread,
        .shared = body.shared,
        .tags = body.tags,
    }, now) catch |e| return dbError(res, e);
    db_mod.setArchive(app.db, id, "", "", .pending, now) catch {};
    res.status = 201;
    try res.json(.{ .id = id }, .{});
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
    if (apiUserId(app, req) == null) return unauthorized(res);
    const ids = db_mod.listBookmarkIds(app.db, res.arena, f) catch |e| return dbError(res, e);
    try writeBookmarkArray(app, res, ids);
}

fn isTrue(v: []const u8) bool {
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
}

fn writeBookmarkArray(app: *App, res: *httpz.Response, ids: []const i64) !void {
    var arr: std.ArrayList(models.Bookmark) = .empty;
    for (ids) |id| {
        if (try db_mod.getBookmark(app.db, res.arena, id)) |bm| try arr.append(res.arena, bm);
    }
    res.status = 200;
    try res.json(arr.items, .{});
}

pub fn get(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = idParam(req) orelse return badRequest(res, "bad id");
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    if (apiUserId(app, req) == null) return unauthorized(res);
    const bm = (db_mod.getBookmark(app.db, res.arena, id) catch |e| return dbError(res, e)) orelse return notFound(res);
    res.status = 200;
    try res.json(bm, .{});
}

const PatchBody = struct {
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
    if (apiUserId(app, req) == null) return unauthorized(res);
    db_mod.updateBookmark(app.db, id, .{
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
    if (apiUserId(app, req) == null) return unauthorized(res);
    db_mod.deleteBookmark(app.db, id) catch |e| return dbError(res, e);
    res.status = 204;
}

pub fn searchH(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const qs = try req.query();
    const term = qs.get("q") orelse return badRequest(res, "missing q");
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    if (apiUserId(app, req) == null) return unauthorized(res);
    const ids = db_mod.search(app.db, res.arena, term, 100) catch |e| return dbError(res, e);
    try writeBookmarkArray(app, res, ids);
}

pub fn tags(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    if (apiUserId(app, req) == null) return unauthorized(res);
    const TagCount = struct { tag: []const u8, count: i64 };
    var arr: std.ArrayList(TagCount) = .empty;
    var st = db_mod.prepareTagCounts(app.db) catch |e| return dbError(res, e);
    defer st.finalize();
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
    if (apiUserId(app, req) == null) return unauthorized(res);
    const n = importer.importInto(app.db, imp) catch |e| return dbError(res, e);
    res.status = 200;
    try res.json(.{ .imported = n }, .{});
}

pub fn getArchive(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = idParam(req) orelse return badRequest(res, "bad id");
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    if (apiUserId(app, req) == null) return unauthorized(res);
    var q = app.db.prepare("SELECT html,status FROM archive WHERE bookmark_id=?;") catch |e| return dbError(res, e);
    defer q.finalize();
    q.bindInt(1, id);
    const has_row = q.step() catch |e| return dbError(res, e);
    if (!has_row) return notFound(res);
    const html = q.columnText(0);
    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.body = try res.arena.dupe(u8, html);
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
