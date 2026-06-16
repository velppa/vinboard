const std = @import("std");
const httpz = @import("httpz");
const server = @import("server.zig");
const db_mod = @import("db.zig");
const html = @import("html.zig");

const App = server.App;

pub fn registerRoutes(router: anytype) void {
    router.*.get("/", index, .{});
    router.*.get("/ui/list", listFragment, .{});
}

pub fn index(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const base = app.base_path;
    const page = try std.fmt.allocPrint(res.arena,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<title>vinboard</title>
        \\<script src="https://unpkg.com/htmx.org@2.0.3"></script>
        \\<script src="https://unpkg.com/htmx-ext-json-enc@2.0.1/json-enc.js"></script>
        \\<script src="https://cdn.tailwindcss.com"></script>
        \\</head>
        \\<body class="max-w-2xl mx-auto p-4 font-sans">
        \\<h1 class="text-2xl font-bold mb-4">vinboard</h1>
        \\<form class="mb-4 flex gap-2"
        \\      hx-post="{s}/api/bookmarks"
        \\      hx-ext="json-enc"
        \\      hx-on::after-request="this.reset(); htmx.trigger('#list','refresh')">
        \\  <input class="border p-1 flex-1" name="url" placeholder="URL" required>
        \\  <input class="border p-1 flex-1" name="title" placeholder="Title">
        \\  <button class="bg-blue-500 text-white px-3 py-1 rounded" type="submit">Add</button>
        \\</form>
        \\<input class="border p-1 w-full mb-4"
        \\       placeholder="Search..."
        \\       hx-get="{s}/ui/list"
        \\       name="q"
        \\       hx-trigger="keyup changed delay:300ms"
        \\       hx-target="#list">
        \\<div id="list"
        \\     hx-get="{s}/ui/list"
        \\     hx-trigger="load,refresh">loading...</div>
        \\</body>
        \\</html>
    , .{ base, base, base });
    res.content_type = httpz.ContentType.HTML;
    res.body = page;
}

pub fn listFragment(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const qs = try req.query();
    const q = qs.get("q");

    app.db_mutex.lockUncancelable(app.io);
    defer app.db_mutex.unlock(app.io);

    const ids = blk: {
        if (q) |term| {
            if (term.len > 0) {
                break :blk db_mod.search(app.db, res.arena, term, 100) catch |e| return serverError(res, e);
            }
        }
        break :blk db_mod.listBookmarkIds(app.db, res.arena, .{}) catch |e| return serverError(res, e);
    };

    var buf: std.ArrayList(u8) = .empty;
    if (ids.len == 0) {
        try buf.appendSlice(res.arena, "<p class=\"text-gray-500\">no bookmarks</p>");
    } else {
        try buf.appendSlice(res.arena, "<ul class=\"space-y-1\">");
        for (ids) |id| {
            const bm = (db_mod.getBookmark(app.db, res.arena, id) catch |e| return serverError(res, e)) orelse continue;

            const display = if (bm.title.len > 0) bm.title else bm.url;
            const esc_title = try html.escape(res.arena, display);
            const esc_url = try html.escape(res.arena, bm.url);

            const li = try std.fmt.allocPrint(res.arena,
                \\<li><a class="text-blue-600 hover:underline" href="{s}">{s}</a> <a class="text-xs text-gray-400 hover:underline" href="{s}/api/bookmarks/{d}/archive">[archived]</a></li>
            , .{ esc_url, esc_title, app.base_path, id });
            try buf.appendSlice(res.arena, li);
        }
        try buf.appendSlice(res.arena, "</ul>");
    }

    res.content_type = httpz.ContentType.HTML;
    res.body = buf.items;
}

fn serverError(res: *httpz.Response, e: anyerror) !void {
    res.status = 500;
    try res.json(.{ .@"error" = @errorName(e) }, .{});
}
