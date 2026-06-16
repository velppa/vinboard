const std = @import("std");

/// Remove <script>/<style> blocks and all tags, collapse whitespace.
/// Caller frees the result.
pub fn toText(alloc: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    var last_space = true; // suppress leading space
    while (i < html.len) {
        if (html[i] == '<') {
            // skip <script>...</script> and <style>...</style> wholesale
            if (matchTag(html, i, "script")) { i = skipBlock(html, i, "</script>"); continue; }
            if (matchTag(html, i, "style")) { i = skipBlock(html, i, "</style>"); continue; }
            // skip to '>'
            while (i < html.len and html[i] != '>') i += 1;
            if (i < html.len) i += 1;
            if (!last_space) { try out.append(alloc, ' '); last_space = true; }
            continue;
        }
        const ch = html[i];
        i += 1;
        if (ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r') {
            if (!last_space) { try out.append(alloc, ' '); last_space = true; }
        } else {
            try out.append(alloc, ch);
            last_space = false;
        }
    }
    // trim trailing space and dupe, then free the ArrayList buffer
    const items = blk: {
        var s = out.items;
        if (s.len > 0 and s[s.len - 1] == ' ') s = s[0 .. s.len - 1];
        break :blk s;
    };
    const result = try alloc.dupe(u8, items);
    out.deinit(alloc);
    return result;
}

fn matchTag(html: []const u8, at: usize, name: []const u8) bool {
    if (at + 1 + name.len > html.len) return false;
    if (html[at] != '<') return false;
    return std.ascii.eqlIgnoreCase(html[at + 1 .. at + 1 + name.len], name);
}

fn skipBlock(html: []const u8, at: usize, close: []const u8) usize {
    const idx = std.ascii.indexOfIgnoreCase(html[at..], close) orelse return html.len;
    return at + idx + close.len;
}

test "strip tags and scripts" {
    const t = try toText(std.testing.allocator,
        "<html><head><style>.a{}</style></head><body><p>Hello</p><script>x()</script> world</body></html>");
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("Hello world", t);
}
