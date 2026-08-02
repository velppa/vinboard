const std = @import("std");
const bcrypt = std.crypto.pwhash.bcrypt;

pub const hash_buf_len = 128;

/// Hash a password into `buf` (PHC string). Returns the slice within `buf`.
pub fn hashPassword(password: []const u8, buf: []u8, io: std.Io) ![]const u8 {
    return bcrypt.strHash(password, .{
        .params = bcrypt.Params.owasp,
        .encoding = .phc,
    }, buf, io);
}

pub fn verifyPassword(hash: []const u8, password: []const u8) bool {
    if (hash.len == 0) return false; // password never set
    bcrypt.strVerify(hash, password, .{ .silently_truncate_password = false }) catch return false;
    return true;
}

/// Random 64-hex-char session token.
pub fn newSessionToken(buf: *[64]u8, io: std.Io) []const u8 {
    var raw: [32]u8 = undefined;
    io.random(&raw);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 15];
    }
    return buf[0..];
}

/// Random 20-char uppercase-hex API token (Pinboard style).
pub fn newApiToken(buf: *[20]u8, io: std.Io) []const u8 {
    var raw: [10]u8 = undefined;
    io.random(&raw);
    const hex = "0123456789ABCDEF";
    for (raw, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 15];
    }
    return buf[0..];
}

/// Extract a cookie value from a Cookie header line.
pub fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, header, "; ");
    while (it.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, std.mem.trim(u8, pair[0..eq], " "), name)) return pair[eq + 1 ..];
        }
    }
    return null;
}

test "hash and verify roundtrip" {
    var buf: [hash_buf_len]u8 = undefined;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const h = try hashPassword("hunter2", &buf, threaded.io());
    try std.testing.expect(verifyPassword(h, "hunter2"));
    try std.testing.expect(!verifyPassword(h, "hunter3"));
    try std.testing.expect(!verifyPassword("", "anything"));
}

test "cookieValue" {
    try std.testing.expectEqualStrings("abc", cookieValue("foo=1; vb_session=abc; bar=2", "vb_session").?);
    try std.testing.expect(cookieValue("foo=1", "vb_session") == null);
}
