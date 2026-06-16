const std = @import("std");
const httpz = @import("httpz");
const sqlite = @import("sqlite.zig");

pub const App = struct {
    gpa: std.mem.Allocator,
    db: *sqlite.Db,
    db_mutex: *std.Io.Mutex,
    base_path: []const u8,
};

pub fn health(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    try res.json(.{ .ok = true }, .{});
}

pub fn start(app: *App, io: std.Io, port: u16) !void {
    var server = try httpz.Server(*App).init(io, app.gpa, .{ .address = .localhost(port) }, app);
    defer server.stop();
    defer server.deinit();
    var router = try server.router(.{});
    router.get("/api/health", health, .{});
    @import("api.zig").registerRoutes(&router);
    @import("web.zig").registerRoutes(&router);
    std.log.info("vinboard listening on :{d}", .{port});
    try server.listen();
}
