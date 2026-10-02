const std = @import("std");
const httpz = @import("httpz");
const server = @import("server.zig");
const api = @import("api.zig");
const db_mod = @import("db.zig");
const trackers = @import("trackers.zig");
const suggest_mod = @import("suggest.zig");
const import_mod = @import("import.zig");

const App = server.App;

pub fn registerRoutes(router: anytype) void {
    router.*.get("/v1/posts/update", postsUpdate, .{});
    router.*.get("/v1/posts/all", postsAll, .{});
    router.*.get("/v1/posts/add", postsAdd, .{});
    router.*.post("/v1/posts/add", postsAdd, .{});
    router.*.get("/v1/posts/delete", postsDelete, .{});
    router.*.get("/v1/user/api_token", userApiToken, .{});
}

// GET /v1/user/api_token → {"result":"<TOKEN>"} (connectivity test for clients)
fn userApiToken(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = api.apiUserId(app, req) orelse return api.unauthorized(res);
    res.header("Access-Control-Allow-Origin", "*");
    const token = (db_mod.getApiToken(app.db, res.arena, auth_uid) catch |e| {
        res.status = 500;
        try res.json(.{ .@"error" = @errorName(e) }, .{});
        return;
    }) orelse "";
    res.status = 200;
    try res.json(.{ .result = token }, .{});
}

// GET /v1/posts/update → {"update_time":"<ISO8601>"}
fn postsUpdate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = api.apiUserId(app, req) orelse return api.unauthorized(res);
    // Browser clients (HN Legible) call /v1 cross-origin with auth_token in
    // the query, so a permissive origin header is enough - no preflight.
    res.header("Access-Control-Allow-Origin", "*");

    var q = try app.db.prepare("SELECT MAX(updated_at) FROM bookmark WHERE user_id=?;");
    defer q.finalize();
    q.bindInt(1, auth_uid);
    const has_row = try q.step();
    const unix: i64 = if (has_row) q.columnInt(0) else db_mod.nowUnix();

    var buf: [32]u8 = undefined;
    const iso = try formatIso(&buf, unix);
    const iso_owned = try res.arena.dupe(u8, iso);

    res.status = 200;
    try res.json(.{ .update_time = iso_owned }, .{});
}

// GET /v1/posts/all?tag=X → JSON array of Pinboard posts
fn postsAll(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const qs = try req.query();
    const tag = qs.get("tag");

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = api.apiUserId(app, req) orelse return api.unauthorized(res);
    // Browser clients (HN Legible) call /v1 cross-origin with auth_token in
    // the query, so a permissive origin header is enough - no preflight.
    res.header("Access-Control-Allow-Origin", "*");

    const ids = try db_mod.listBookmarkIds(app.db, res.arena, .{
        .user_id = auth_uid,
        .tag = tag,
        .limit = 100000,
    });

    const PbPost = struct {
        href: []const u8,
        description: []const u8,
        extended: []const u8,
        meta: []const u8,
        hash: []const u8,
        time: []const u8,
        shared: []const u8,
        toread: []const u8,
        tags: []const u8,
    };

    var posts: std.ArrayList(PbPost) = .empty;
    for (ids) |id| {
        const bm = (try db_mod.getBookmark(app.db, res.arena, id)) orelse continue;

        var time_buf: [32]u8 = undefined;
        const time_iso = try formatIso(&time_buf, bm.created_at);
        const time_owned = try res.arena.dupe(u8, time_iso);

        // Join tags with spaces
        var tags_str: []const u8 = "";
        if (bm.tags.len > 0) {
            var tb: std.ArrayList(u8) = .empty;
            for (bm.tags, 0..) |t, i| {
                if (i > 0) try tb.append(res.arena, ' ');
                try tb.appendSlice(res.arena, t);
            }
            tags_str = try tb.toOwnedSlice(res.arena);
        }

        try posts.append(res.arena, .{
            .href = bm.url,
            .description = bm.title,
            .extended = bm.notes,
            .meta = "",
            .hash = "",
            .time = time_owned,
            .shared = if (bm.shared) "yes" else "no",
            .toread = if (bm.toread) "yes" else "no",
            .tags = tags_str,
        });
    }

    res.status = 200;
    try res.json(posts.items, .{});
}

// GET /v1/posts/add → {"result_code":"done"} or {"result_code":"item already exists"}
fn postsAdd(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const qs = try req.query();
    const url = try trackers.clean(res.arena, qs.get("url") orelse {
        res.status = 400;
        try res.json(.{ .result_code = "missing url" }, .{});
        return;
    });
    const description = qs.get("description") orelse "";
    const extended = qs.get("extended") orelse "";
    const tags_str = qs.get("tags") orelse "";
    const dt_str = qs.get("dt");
    const replace = qs.get("replace") orelse "yes";
    const shared_str = qs.get("shared") orelse "yes";
    const toread_str = qs.get("toread") orelse "no";

    // Parse tags (space-separated)
    var tag_list: std.ArrayList([]const u8) = .empty;
    var tag_it = std.mem.tokenizeScalar(u8, tags_str, ' ');
    while (tag_it.next()) |t| try tag_list.append(res.arena, t);
    var tags: []const []const u8 = try tag_list.toOwnedSlice(res.arena);
    // Pinboard clients that post a new url without tags, or with only tags
    // naming where it came from, get the model's.
    if (suggest_mod.wantsSuggestions(app.suggest, tags)) {
        app.db_mutex.lockUncancelable(app.io);
        const uid = api.apiUserId(app, req);
        const saved_before = if (uid) |u|
            (db_mod.findIdByUrlFor(app.db, url, u) catch null) != null
        else
            false;
        app.db_mutex.unlock(app.io);
        if (uid) |u| if (!saved_before) {
            tags = try suggest_mod.withSuggested(res.arena, tags, suggest_mod.forBookmark(res.arena, app.io, app.suggest, app.db, app.db_mutex, u, description, url, extended));
        };
    }

    // Parse created_at
    const created_at: i64 = if (dt_str) |dt| import_mod.parseIso(dt) else db_mod.nowUnix();

    const shared = std.mem.eql(u8, shared_str, "yes");
    const toread = std.mem.eql(u8, toread_str, "yes");
    const now = db_mod.nowUnix();

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = api.apiUserId(app, req) orelse return api.unauthorized(res);
    // Browser clients (HN Legible) call /v1 cross-origin with auth_token in
    // the query, so a permissive origin header is enough - no preflight.
    res.header("Access-Control-Allow-Origin", "*");

    if (try db_mod.findIdByUrlFor(app.db, url, auth_uid)) |existing_id| {
        // URL exists
        if (std.mem.eql(u8, replace, "no")) {
            res.status = 200;
            try res.json(.{ .result_code = "item already exists" }, .{});
            return;
        }
        // Update
        try db_mod.resaveBookmark(app.db, existing_id, .{
            .title = description,
            .notes = extended,
            .tags = tags,
            .shared = if (qs.get("shared") != null) shared else null,
            .toread = if (qs.get("toread") != null) toread else null,
        }, now);
    } else {
        // Insert
        _ = try db_mod.insertBookmark(app.db, .{
            .url = url,
            .title = description,
            .notes = extended,
            .toread = toread,
            .shared = shared,
            .tags = tags,
        }, created_at, auth_uid);
    }
    db_mod.enqueueArchive(app.db, url) catch {};

    res.status = 200;
    try res.json(.{ .result_code = "done" }, .{});
}

// GET /v1/posts/delete?url=X → {"result_code":"done"} or {"result_code":"item not found"}
fn postsDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const qs = try req.query();
    const url = try trackers.clean(res.arena, qs.get("url") orelse {
        res.status = 400;
        try res.json(.{ .result_code = "missing url" }, .{});
        return;
    });

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const auth_uid = api.apiUserId(app, req) orelse return api.unauthorized(res);
    // Browser clients (HN Legible) call /v1 cross-origin with auth_token in
    // the query, so a permissive origin header is enough - no preflight.
    res.header("Access-Control-Allow-Origin", "*");

    if (try db_mod.findIdByUrlFor(app.db, url, auth_uid)) |id| {
        try db_mod.deleteBookmark(app.db, id);
        res.status = 200;
        try res.json(.{ .result_code = "done" }, .{});
    } else {
        res.status = 200;
        try res.json(.{ .result_code = "item not found" }, .{});
    }
}

// --- Date helpers ---

fn civilFromDays(z_in: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = y + @as(i64, if (m <= 2) 1 else 0), .m = m, .d = d };
}

pub fn formatIso(buf: []u8, unix: i64) ![]const u8 {
    const days = @divFloor(unix, 86400);
    const secs = unix - days * 86400;
    const c = civilFromDays(days);
    return std.fmt.bufPrint(buf, "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}Z", .{
        @as(u64, @intCast(c.y)), @as(u64, @intCast(c.m)), @as(u64, @intCast(c.d)),
        @as(u64, @intCast(@divFloor(secs, 3600))),
        @as(u64, @intCast(@divFloor(@mod(secs, 3600), 60))),
        @as(u64, @intCast(@mod(secs, 60))),
    });
}

test "formatIso known value" {
    var buf: [32]u8 = undefined;
    // 2024-01-15T11:34:56Z = 1705318496
    const result = try formatIso(&buf, 1705318496);
    try std.testing.expectEqualStrings("2024-01-15T11:34:56Z", result);
}

test "formatIso round-trip with parseIso" {
    var buf: [32]u8 = undefined;
    const unix: i64 = 1700000000; // 2023-11-14T22:13:20Z
    const iso = try formatIso(&buf, unix);
    const back = import_mod.parseIso(iso);
    try std.testing.expectEqual(unix, back);
}
