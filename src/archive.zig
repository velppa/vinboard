const std = @import("std");
const server = @import("server.zig");

pub const Worker = struct {
    app: *server.App,
    archiver_cmd: []const u8,

    pub fn run(self: *Worker) void {
        _ = self; // real loop in Task 10
    }
};
