const std = @import("std");

pub fn main() !void {
    std.debug.print("vinboard\n", .{});
}

test "build sanity" {
    try std.testing.expect(1 + 1 == 2);
}

test {
    _ = @import("sqlite.zig");
    _ = @import("db.zig");
}
