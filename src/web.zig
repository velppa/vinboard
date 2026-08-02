const std = @import("std");
const httpz = @import("httpz");
const server = @import("server.zig");
const db_mod = @import("db.zig");
const models = @import("models.zig");
const html = @import("html.zig");

const App = server.App;

const page_size: i64 = 50;

pub fn registerRoutes(router: anytype) void {
    router.*.get("/", index, .{});
    router.*.get("/ui/list", listFragment, .{});
    router.*.get("/ui/edit/:id", editForm, .{});
    router.*.get("/ui/item/:id", itemFragment, .{});
    router.*.post("/ui/edit/:id", editSubmit, .{});
    router.*.post("/ui/delete/:id", deleteSubmit, .{});
    router.*.get("/add", addPage, .{});
    router.*.post("/ui/add", addSubmit, .{});
    router.*.get("/setup", setupPage, .{});
    router.*.get("/static/style.css", styleCss, .{});
}

// Pinboard look: condensed from pinboard.in basic/skeleton/bookmarks stylesheets.
const css =
    \\body { color:#333; margin:0; font-size:13px; font-family:helvetica,sans-serif; word-wrap:break-word; text-align:center; }
    \\p { margin-top:2px; margin-bottom:12px; }
    \\a { text-decoration:none; color:#11a; }
    \\a:visited { color:#51a; }
    \\h1 { font-size:1.8em; font-weight:normal; margin-top:10px; }
    \\input, textarea { font-size:90%; border:1px solid #ddd; }
    \\#content { max-width:1050px; margin:0 auto; min-height:400px; padding-left:10px; text-align:left; }
    \\#banner { border-bottom:1px dotted #aaa; margin-bottom:0.7em; max-width:980px; padding-bottom:9px; text-align:left; }
    \\#logo { float:left; height:24px; }
    \\#pinboard_name { font-size:1.4em; color:#aaa; }
    \\#pinboard_name:hover { color:red; }
    \\#top_menu { margin-top:2px; float:right; }
    \\#main_column { max-width:700px; float:left; width:100%; text-align:left; position:relative; }
    \\#bookmarks { margin-top:1em; margin-left:6px; }
    \\#right_bar { float:left; margin-left:10px; text-align:left; width:320px; }
    \\#nextprev { margin-bottom:1em; }
    \\a.next_prev { color:#777; }
    \\.bookmark { padding:3px; width:95%; float:left; margin-bottom:1.3em; }
    \\.bookmark_title { line-height:130%; font-size:110%; overflow-wrap:anywhere; }
    \\.private a { padding:1px; border:0; }
    \\.private { background:#f2f2f2; border:1px solid #ddd; }
    \\.unread { color:#a41; }
    \\.description { line-height:120%; margin-top:2px; color:#555; }
    \\a.tag { color:#a51; line-height:190%; }
    \\a.edit, a.edit:visited { color:#aaa; }
    \\a.edit:hover { color:#44d; }
    \\a.delete, a.delete:visited { color:#aaa; }
    \\a.delete:hover { color:#44d; }
    \\.cached, .cached:visited { color:#aaa; }
    \\.when { font-size:90%; color:#777; }
    \\.faint { color:#aaa; }
    \\.edit_form { color:#888; padding:4px; }
    \\.edit_form p { line-height:100%; margin-bottom:0; color:#888; }
    \\.edit_form input[type=text], .edit_form textarea { width:490px; max-width:95%; margin-bottom:3px; }
    \\#footer { margin-top:3em; color:#888; clear:both; }
;

pub fn styleCss(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.content_type = httpz.ContentType.CSS;
    res.body = css;
}

fn esc(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    return html.escape(arena, s);
}

fn urlEncode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const hex = "0123456789ABCDEF";
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(a, c),
        else => try out.appendSlice(a, &[3]u8{ '%', hex[c >> 4], hex[c & 15] }),
    };
    return out.toOwnedSlice(a);
}

// Howard Hinnant's civil_from_days.
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
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

fn fmtDate(a: std.mem.Allocator, unix: i64) ![]u8 {
    const c = civilFromDays(@divFloor(unix, 86400));
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u64, @intCast(c.y)), @as(u64, @intCast(c.m)), @as(u64, @intCast(c.d)),
    });
}

const Filter = struct {
    q: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    toread: bool = false,
    offset: i64 = 0,
};

fn parseFilter(req: *httpz.Request) !Filter {
    const qs = try req.query();
    var f = Filter{};
    if (qs.get("q")) |v| {
        if (v.len > 0) f.q = v;
    }
    if (qs.get("tag")) |v| {
        if (v.len > 0) f.tag = v;
    }
    if (qs.get("toread")) |v| f.toread = std.mem.eql(u8, v, "1");
    if (qs.get("offset")) |v| f.offset = std.fmt.parseInt(i64, v, 10) catch 0;
    return f;
}

/// Query-string suffix ("&tag=...&toread=1") carrying the filter, minus offset.
fn filterParams(a: std.mem.Allocator, f: Filter) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (f.q) |q| {
        try out.appendSlice(a, "&q=");
        try out.appendSlice(a, try urlEncode(a, q));
    }
    if (f.tag) |t| {
        try out.appendSlice(a, "&tag=");
        try out.appendSlice(a, try urlEncode(a, t));
    }
    if (f.toread) try out.appendSlice(a, "&toread=1");
    return out.toOwnedSlice(a);
}

/// One bookmark's inner display fragment (lives inside div.bookmark).
fn renderDisplay(app: *App, a: std.mem.Allocator, bm: models.Bookmark) ![]u8 {
    const base = app.base_path;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    const title = if (bm.title.len > 0) bm.title else bm.url;
    const title_cls: []const u8 = if (bm.toread) " unread" else "";
    try out.appendSlice(a, try std.fmt.allocPrint(a,
        \\<div class="display">
        \\<a class="bookmark_title{s}" href="{s}">{s}</a>
    , .{ title_cls, try esc(a, bm.url), try esc(a, title) }));

    if (bm.notes.len > 0) {
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\<div class="description">{s}</div>
        , .{try esc(a, bm.notes)}));
    }

    try out.appendSlice(a, "<div>");
    for (bm.tags) |t| {
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\<a class="tag" href="{s}/?tag={s}">{s}</a>
        , .{ base, try urlEncode(a, t), try esc(a, t) }));
        try out.append(a, ' ');
    }
    try out.appendSlice(a, try std.fmt.allocPrint(a,
        \\<span class="when">{s}</span> &nbsp;
        \\<a class="edit" href="#" hx-get="{s}/ui/edit/{d}" hx-target="closest .bookmark" hx-swap="innerHTML">edit</a> &nbsp;
        \\<a class="delete" href="#" hx-post="{s}/ui/delete/{d}" hx-confirm="Delete this bookmark?" hx-target="closest .bookmark" hx-swap="delete">delete</a> &nbsp;
        \\<a class="cached" href="{s}/api/bookmarks/{d}/archive">cached</a>
        \\</div></div>
    , .{ try fmtDate(a, bm.created_at), base, bm.id, base, bm.id, base, bm.id }));
    return out.toOwnedSlice(a);
}

fn renderItem(app: *App, a: std.mem.Allocator, bm: models.Bookmark) ![]u8 {
    const cls: []const u8 = if (bm.shared) "bookmark" else "bookmark private";
    return std.fmt.allocPrint(a,
        \\<div class="{s}" id="bm-{d}">{s}</div>
    , .{ cls, bm.id, try renderDisplay(app, a, bm) });
}

/// Bookmark list + earlier/later nav. Caller holds the db lock.
fn renderList(app: *App, a: std.mem.Allocator, f: Filter) ![]u8 {
    const ids = blk: {
        if (f.q) |term| break :blk try db_mod.search(app.db, a, term, 100);
        break :blk try db_mod.listBookmarkIds(app.db, a, .{
            .tag = f.tag,
            .toread = if (f.toread) true else null,
            .limit = page_size,
            .offset = f.offset,
        });
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    if (ids.len == 0) {
        try out.appendSlice(a, "<p class=\"faint\">no bookmarks</p>");
    } else {
        for (ids) |id| {
            const bm = (try db_mod.getBookmark(app.db, a, id)) orelse continue;
            try out.appendSlice(a, try renderItem(app, a, bm));
        }
    }

    // Search results are a single page; list pages get earlier/later nav.
    if (f.q == null) {
        const params = try filterParams(a, f);
        try out.appendSlice(a, "<div style=\"clear:both\"></div><div id=\"nextprev\">");
        if (f.offset > 0) {
            const later = @max(f.offset - page_size, 0);
            try out.appendSlice(a, try std.fmt.allocPrint(a,
                \\<a class="next_prev" href="{s}/?offset={d}{s}">&laquo; later</a>
            , .{ app.base_path, later, params }));
        }
        if (ids.len == page_size) {
            try out.appendSlice(a, try std.fmt.allocPrint(a,
                \\<a class="next_prev" href="{s}/?offset={d}{s}">earlier &raquo;</a>
            , .{ app.base_path, f.offset + page_size, params }));
        }
        try out.appendSlice(a, "</div>");
    }
    return out.toOwnedSlice(a);
}

/// Caller holds the db lock.
fn renderTagCloud(app: *App, a: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var st = try db_mod.prepareTagCounts(app.db);
    defer st.finalize();
    while (try st.step()) {
        const tag = try a.dupe(u8, st.columnText(0));
        try out.appendSlice(a, try std.fmt.allocPrint(a,
            \\<a class="tag" href="{s}/?tag={s}">{s}</a>&nbsp;<span class="faint">{d}</span>
            \\
        , .{ app.base_path, try urlEncode(a, tag), try esc(a, tag), st.columnInt(1) }));
    }
    return out.toOwnedSlice(a);
}

fn countBookmarks(app: *App) !i64 {
    var st = try app.db.prepare("SELECT count(*) FROM bookmarks;");
    defer st.finalize();
    _ = try st.step();
    return st.columnInt(0);
}

fn pageShell(a: std.mem.Allocator, base: []const u8, main_html: []const u8, right_html: []const u8, search_q: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<title>vinboard</title>
        \\<link rel="stylesheet" href="{s}/static/style.css">
        \\<script src="https://unpkg.com/htmx.org@2.0.3"></script>
        \\</head>
        \\<body>
        \\<div id="content">
        \\<div id="banner">
        \\<div id="logo">&#128204; <a id="pinboard_name" href="{s}/">vinboard</a></div>
        \\<div id="top_menu">
        \\<form style="display:inline" action="{s}/" method="get"><input type="search" name="q" placeholder="search" value="{s}"
        \\  hx-get="{s}/ui/list" hx-trigger="keyup changed delay:300ms" hx-target="#bookmarks"></form> &nbsp;
        \\<a href="{s}/">all</a> &#8231;
        \\<a href="{s}/?toread=1">unread</a> &#8231;
        \\<a href="{s}/add">add</a> &#8231;
        \\<a href="{s}/setup">setup</a>
        \\</div>
        \\<div style="clear:both"></div>
        \\</div>
        \\<div id="main_column"><div id="bookmarks">{s}</div></div>
        \\<div id="right_bar">{s}</div>
        \\<div id="footer"></div>
        \\</div>
        \\</body>
        \\</html>
    , .{ base, base, base, search_q, base, base, base, base, base, main_html, right_html });
}

pub fn index(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const f = try parseFilter(req);

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);

    const list_html = renderList(app, a, f) catch |e| return serverError(res, e);
    const cloud = renderTagCloud(app, a) catch |e| return serverError(res, e);
    const total = countBookmarks(app) catch |e| return serverError(res, e);

    const right = try std.fmt.allocPrint(a,
        \\<p><b>{d} bookmarks</b></p>
        \\{s}
    , .{ total, cloud });

    const search_q = if (f.q) |q| try esc(a, q) else "";
    res.content_type = httpz.ContentType.HTML;
    res.body = try pageShell(a, app.base_path, list_html, right, search_q);
}

pub fn listFragment(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const f = try parseFilter(req);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const body = renderList(app, res.arena, f) catch |e| return serverError(res, e);
    res.content_type = httpz.ContentType.HTML;
    res.body = body;
}

pub fn itemFragment(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = idParam(req) orelse return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const bm = (db_mod.getBookmark(app.db, res.arena, id) catch |e| return serverError(res, e)) orelse return notFound(res);
    res.content_type = httpz.ContentType.HTML;
    res.body = try renderDisplay(app, res.arena, bm);
}

pub fn editForm(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const id = idParam(req) orelse return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const bm = (db_mod.getBookmark(app.db, a, id) catch |e| return serverError(res, e)) orelse return notFound(res);

    var tags_str: std.ArrayList(u8) = .empty;
    for (bm.tags, 0..) |t, i| {
        if (i > 0) try tags_str.append(a, ' ');
        try tags_str.appendSlice(a, t);
    }

    res.content_type = httpz.ContentType.HTML;
    res.body = try std.fmt.allocPrint(a,
        \\<form class="edit_form" hx-post="{s}/ui/edit/{d}" hx-target="closest .bookmark" hx-swap="innerHTML">
        \\<p><span class="faint">{s}</span></p>
        \\<p>title<br><input type="text" name="title" value="{s}"></p>
        \\<p>description<br><textarea name="notes" rows="3">{s}</textarea></p>
        \\<p>tags<br><input type="text" name="tags" value="{s}"></p>
        \\<p><label><input type="checkbox" name="private"{s}> private</label>
        \\   <label><input type="checkbox" name="toread"{s}> read later</label></p>
        \\<p><button type="submit">save</button>
        \\   <a class="edit" href="#" hx-get="{s}/ui/item/{d}" hx-target="closest .bookmark" hx-swap="innerHTML">cancel</a></p>
        \\</form>
    , .{
        app.base_path,        id,
        try esc(a, bm.url),   try esc(a, bm.title),
        try esc(a, bm.notes), try esc(a, tags_str.items),
        checked(!bm.shared),  checked(bm.toread),
        app.base_path,        id,
    });
}

fn checked(on: bool) []const u8 {
    return if (on) " checked" else "";
}

fn splitTags(a: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |t| try list.append(a, t);
    return list.toOwnedSlice(a);
}

pub fn editSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const id = idParam(req) orelse return badRequest(res);
    const fd = try req.formData();

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    db_mod.updateBookmark(app.db, id, .{
        .title = fd.get("title") orelse "",
        .notes = fd.get("notes") orelse "",
        .tags = try splitTags(a, fd.get("tags") orelse ""),
        .shared = fd.get("private") == null,
        .toread = fd.get("toread") != null,
    }, db_mod.nowUnix()) catch |e| return serverError(res, e);

    const bm = (db_mod.getBookmark(app.db, a, id) catch |e| return serverError(res, e)) orelse return notFound(res);
    res.content_type = httpz.ContentType.HTML;
    res.body = try renderDisplay(app, a, bm);
}

pub fn deleteSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = idParam(req) orelse return badRequest(res);
    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    db_mod.deleteBookmark(app.db, id) catch |e| return serverError(res, e);
    res.status = 200;
    res.body = "";
}

pub fn addPage(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const qs = try req.query();
    const url = qs.get("url") orelse "";
    const title = qs.get("title") orelse "";
    const notes = qs.get("notes") orelse "";
    const popup = qs.get("popup") != null;

    const form = try std.fmt.allocPrint(a,
        \\<h1>add bookmark</h1>
        \\<form class="edit_form" method="post" action="{s}/ui/add">
        \\<input type="hidden" name="popup" value="{s}">
        \\<p>url<br><input type="text" name="url" value="{s}" required></p>
        \\<p>title<br><input type="text" name="title" value="{s}"></p>
        \\<p>description<br><textarea name="notes" rows="3">{s}</textarea></p>
        \\<p>tags<br><input type="text" name="tags"></p>
        \\<p><label><input type="checkbox" name="private" checked> private</label>
        \\   <label><input type="checkbox" name="toread"> read later</label></p>
        \\<p><button type="submit">add</button></p>
        \\</form>
    , .{ app.base_path, if (popup) "1" else "", try esc(a, url), try esc(a, title), try esc(a, notes) });

    res.content_type = httpz.ContentType.HTML;
    if (popup) {
        // Bookmarklet popup: bare page, no banner or sidebar.
        res.body = try std.fmt.allocPrint(a,
            \\<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>add to vinboard</title>
            \\<link rel="stylesheet" href="{s}/static/style.css"></head>
            \\<body><div id="content">{s}</div></body></html>
        , .{ app.base_path, form });
    } else {
        res.body = try pageShell(a, app.base_path, form, "", "");
    }
}

pub fn addSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const fd = try req.formData();
    const url = fd.get("url") orelse return badRequest(res);
    if (url.len == 0) return badRequest(res);
    const patch = db_mod.Patch{
        .title = fd.get("title") orelse "",
        .notes = fd.get("notes") orelse "",
        .tags = try splitTags(a, fd.get("tags") orelse ""),
        .shared = fd.get("private") == null,
        .toread = fd.get("toread") != null,
    };

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);
    const now = db_mod.nowUnix();
    // Re-adding an existing url updates it, matching Pinboard.
    if (db_mod.findIdByUrl(app.db, url) catch |e| return serverError(res, e)) |id| {
        db_mod.updateBookmark(app.db, id, patch, now) catch |e| return serverError(res, e);
    } else {
        const id = db_mod.insertBookmark(app.db, .{
            .url = url,
            .title = patch.title.?,
            .notes = patch.notes.?,
            .tags = patch.tags.?,
            .shared = patch.shared.?,
            .toread = patch.toread.?,
        }, now) catch |e| return serverError(res, e);
        db_mod.setArchive(app.db, id, "", "", .pending, now) catch {};
    }

    if (fd.get("popup")) |p| {
        if (p.len > 0) {
            res.content_type = httpz.ContentType.HTML;
            res.body = "<script>window.close()</script>saved.";
            return;
        }
    }
    res.status = 302;
    res.header("Location", try std.fmt.allocPrint(a, "{s}/", .{app.base_path}));
}

pub fn setupPage(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const a = res.arena;
    const host = req.header("host") orelse "localhost:4670";
    const scheme: []const u8 = if (std.mem.startsWith(u8, host, "localhost") or std.mem.startsWith(u8, host, "127.")) "http" else "https";
    const add_url = try std.fmt.allocPrint(a, "{s}://{s}{s}/add", .{ scheme, host, app.base_path });

    const bookmarklet = try std.fmt.allocPrint(a,
        \\javascript:q=location.href;p=document.title;void(open('{s}?popup=1&url='+encodeURIComponent(q)+'&title='+encodeURIComponent(p),'vinboard','toolbar=no,width=700,height=400'));
    , .{add_url});

    const main_html = try std.fmt.allocPrint(a,
        \\<h1>setup</h1>
        \\<p>Drag this link to your bookmarks bar:</p>
        \\<p><a href="{s}">add to vinboard</a></p>
        \\<p class="faint">It opens a popup with the current page's url and title prefilled.</p>
    , .{try esc(a, bookmarklet)});

    res.content_type = httpz.ContentType.HTML;
    res.body = try pageShell(a, app.base_path, main_html, "", "");
}

fn idParam(req: *httpz.Request) ?i64 {
    const s = req.param("id") orelse return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn badRequest(res: *httpz.Response) !void {
    res.status = 400;
    res.body = "bad request";
}

fn notFound(res: *httpz.Response) !void {
    res.status = 404;
    res.body = "not found";
}

fn serverError(res: *httpz.Response, e: anyerror) !void {
    res.status = 500;
    try res.json(.{ .@"error" = @errorName(e) }, .{});
}

test "urlEncode escapes reserved chars" {
    const a = std.testing.allocator;
    const e = try urlEncode(a, "a b/c");
    defer a.free(e);
    try std.testing.expectEqualStrings("a%20b%2Fc", e);
}

test "fmtDate" {
    const a = std.testing.allocator;
    const s = try fmtDate(a, 1754121600);
    defer a.free(s);
    try std.testing.expectEqualStrings("2025-08-02", s);
}

test "civilFromDays epoch" {
    const c = civilFromDays(0);
    try std.testing.expectEqual(@as(i64, 1970), c.y);
    try std.testing.expectEqual(@as(i64, 1), c.m);
    try std.testing.expectEqual(@as(i64, 1), c.d);
}
