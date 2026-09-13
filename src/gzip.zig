//! Gzip helpers for the archived page copies.
//!
//! Page copies dominate the database - a few hundred kilobytes of HTML
//! per bookmark, which are only ever handed back whole - so they are
//! stored compressed.

const std = @import("std");
const flate = std.compress.flate;

pub const magic = [2]u8{ 0x1f, 0x8b };

/// Reports whether the blob carries a gzip header.  Page copies stored
/// before compression are kept as they are, so both forms are read back.
pub fn isGzip(data: []const u8) bool {
    return data.len >= 2 and std.mem.eql(u8, data[0..2], &magic);
}

/// Caller owns the returned slice.
pub fn compress(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    // The deflate writer writes through to this one, which it requires
    // to hold more than the gzip header it starts with.
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, 4096);
    errdefer out.deinit();
    var c = try flate.Compress.init(&out.writer, window, .gzip, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

/// Caller owns the returned slice.
pub fn decompress(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var in: std.Io.Reader = .fixed(data);
    var d: flate.Decompress = .init(&in, .gzip, window);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    _ = try d.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

/// The page copy as stored: compressed blobs are expanded, older plain
/// ones are duped so the caller frees either the same way.
pub fn decode(alloc: std.mem.Allocator, stored: []const u8) ![]u8 {
    if (isGzip(stored)) return decompress(alloc, stored);
    return alloc.dupe(u8, stored);
}

test "roundtrip" {
    const alloc = std.testing.allocator;
    const html = "<html><body>" ++ ("elephant zebra " ** 500) ++ "</body></html>";
    const packed_bytes = try compress(alloc, html);
    defer alloc.free(packed_bytes);
    try std.testing.expect(isGzip(packed_bytes));
    try std.testing.expect(packed_bytes.len < html.len / 4);
    const back = try decode(alloc, packed_bytes);
    defer alloc.free(back);
    try std.testing.expectEqualStrings(html, back);
}

test "plain bytes pass through decode" {
    const alloc = std.testing.allocator;
    const back = try decode(alloc, "<html>plain</html>");
    defer alloc.free(back);
    try std.testing.expectEqualStrings("<html>plain</html>", back);
}

test "empty input" {
    const alloc = std.testing.allocator;
    const packed_bytes = try compress(alloc, "");
    defer alloc.free(packed_bytes);
    const back = try decode(alloc, packed_bytes);
    defer alloc.free(back);
    try std.testing.expectEqualStrings("", back);
}
