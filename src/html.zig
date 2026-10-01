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

/// The longest prefix of S at most MAX bytes long that ends on a
/// character boundary.
pub fn prefixUtf8(s: []const u8, max: usize) []const u8 {
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
