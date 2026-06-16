const std = @import("std");

/// HTML-escape into a caller-owned slice.
pub fn escape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |ch| switch (ch) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&quot;"),
        '\'' => try out.appendSlice(alloc, "&#39;"),
        else => try out.append(alloc, ch),
    };
    return out.toOwnedSlice(alloc);
}

test "escape" {
    const e = try escape(std.testing.allocator, "<a>&\"");
    defer std.testing.allocator.free(e);
    try std.testing.expectEqualStrings("&lt;a&gt;&amp;&quot;", e);
}
