const std = @import("std");
const httpz = @import("httpz");
const sqlite = @import("sqlite.zig");

pub const App = struct {
    gpa: std.mem.Allocator,
    db: *sqlite.Db,
    db_mutex: *std.Io.Mutex,
    base_path: []const u8,
    io: std.Io,
};

pub fn health(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    try res.json(.{ .ok = true }, .{});
}

pub fn start(app: *App, io: std.Io, port: u16) !void {
    var server = try httpz.Server(*App).init(io, app.gpa, .{
        .address = .localhost(port),
        // default is 1 MiB; bookmark imports (Pinboard posts/all) can exceed that.
        .request = .{ .max_body_size = 32 * 1024 * 1024, .max_form_count = 16 },
    }, app);
    defer server.stop();
    defer server.deinit();
    var router = try server.router(.{});
    router.get("/api/health", health, .{});
    @import("api.zig").registerRoutes(&router);
    @import("web.zig").registerRoutes(&router);
    @import("pinboard_compat.zig").registerRoutes(&router);
    // Pages emit base_path-prefixed urls; a reverse proxy strips the prefix,
    // but direct access needs the same routes at the prefixed paths too.
    if (app.base_path.len > 0) {
        var group = router.group(app.base_path, .{});
        group.get("/api/health", health, .{});
        @import("api.zig").registerRoutes(&group);
        @import("web.zig").registerRoutes(&group);
        @import("pinboard_compat.zig").registerRoutes(&group);
    }
    std.log.info("vinboard listening on :{d}", .{port});
    try server.listen();
}
