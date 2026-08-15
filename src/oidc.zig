const std = @import("std");

/// OIDC provider settings, admin-configured (stored in sysconf).
pub const Config = struct {
    /// "builtin" (default), "oidc", or "both".
    mode: []const u8 = "builtin",
    /// Issuer base, e.g. https://auth.example.com/oidc (no trailing slash).
    issuer: []const u8 = "",
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    /// Full public callback URL, e.g. https://host/vinboard/oidc/callback.
    redirect_uri: []const u8 = "",

    pub fn enabled(c: Config) bool {
        if (std.mem.eql(u8, c.mode, "builtin")) return false;
        return c.issuer.len > 0 and c.client_id.len > 0 and
            c.client_secret.len > 0 and c.redirect_uri.len > 0;
    }

    pub fn builtinAllowed(c: Config) bool {
        return !c.enabled() or !std.mem.eql(u8, c.mode, "oidc");
    }
};

/// Identity claims from the id_token.
pub const Claims = struct {
    sub: []const u8,
    username: ?[]const u8 = null,
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

fn percentEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(alloc, c),
        else => try out.print(alloc, "%{X:0>2}", .{c}),
    };
    return out.items;
}

/// Authorization-endpoint URL for the code flow.
pub fn authUrl(alloc: std.mem.Allocator, cfg: Config, state: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "{s}/auth?response_type=code&client_id={s}&redirect_uri={s}&scope=openid+profile+email&state={s}",
        .{ cfg.issuer, try percentEncode(alloc, cfg.client_id), try percentEncode(alloc, cfg.redirect_uri), state });
}

pub const ExchangeError = error{TokenEndpointFailed, BadIdToken} ||
    std.mem.Allocator.Error;

/// Exchange an authorization code for identity claims.  Talks to the
/// issuer's /token endpoint; the id_token payload is trusted as-is
/// because it arrives over TLS directly from the issuer.
/// All returned strings are allocated from `alloc`.
pub fn exchangeCode(alloc: std.mem.Allocator, io: std.Io, cfg: Config, code: []const u8) ExchangeError!Claims {
    const body = try std.fmt.allocPrint(alloc,
        "grant_type=authorization_code&code={s}&redirect_uri={s}&client_id={s}&client_secret={s}",
        .{
            try percentEncode(alloc, code),
            try percentEncode(alloc, cfg.redirect_uri),
            try percentEncode(alloc, cfg.client_id),
            try percentEncode(alloc, cfg.client_secret),
        });
    const token_url = try std.fmt.allocPrint(alloc, "{s}/token", .{cfg.issuer});

    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    var resp: std.Io.Writer.Allocating = .init(alloc);
    defer resp.deinit();
    const result = client.fetch(.{
        .location = .{ .url = token_url },
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .response_writer = &resp.writer,
    }) catch return error.TokenEndpointFailed;
    if (result.status != .ok) return error.TokenEndpointFailed;

    const parsed = std.json.parseFromSliceLeaky(struct { id_token: []const u8 }, alloc, resp.written(), .{
        .ignore_unknown_fields = true,
    }) catch return error.TokenEndpointFailed;
    return parseIdToken(alloc, parsed.id_token);
}

/// Decode the JWT payload (middle segment) into Claims.
pub fn parseIdToken(alloc: std.mem.Allocator, jwt: []const u8) ExchangeError!Claims {
    var it = std.mem.splitScalar(u8, jwt, '.');
    _ = it.next() orelse return error.BadIdToken; // header
    const payload_b64 = it.next() orelse return error.BadIdToken;
    const dec = std.base64.url_safe_no_pad.Decoder;
    const len = dec.calcSizeForSlice(payload_b64) catch return error.BadIdToken;
    const payload = try alloc.alloc(u8, len);
    dec.decode(payload, payload_b64) catch return error.BadIdToken;
    const claims = std.json.parseFromSliceLeaky(struct {
        sub: []const u8,
        username: ?[]const u8 = null,
        email: ?[]const u8 = null,
        name: ?[]const u8 = null,
    }, alloc, payload, .{ .ignore_unknown_fields = true }) catch return error.BadIdToken;
    if (claims.sub.len == 0) return error.BadIdToken;
    return .{
        .sub = claims.sub,
        .username = claims.username,
        .email = claims.email,
        .name = claims.name,
    };
}

/// Handle proposal from claims: username, else email local part, else
/// "u-" + sub. Lowercased; disallowed characters become '-'.
pub fn proposeHandle(claims: Claims, buf_out: *[32]u8) []const u8 {
    var src: []const u8 = "";
    if (claims.username) |u| {
        if (u.len > 0) src = u;
    }
    if (src.len == 0) {
        if (claims.email) |e| {
            if (std.mem.indexOfScalar(u8, e, '@')) |at| src = e[0..at] else src = e;
        }
    }
    var n: usize = 0;
    if (src.len == 0) {
        const prefix = "u-";
        @memcpy(buf_out[0..prefix.len], prefix);
        n = prefix.len;
        src = claims.sub;
    }
    for (src) |c| {
        if (n >= buf_out.len) break;
        buf_out[n] = switch (std.ascii.toLower(c)) {
            'a'...'z', '0'...'9', '-', '_' => |l| l,
            else => '-',
        };
        n += 1;
    }
    return buf_out[0..n];
}

const testing = std.testing;

test "authUrl encodes parts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const url = try authUrl(arena.allocator(), .{
        .issuer = "https://auth.example.com/oidc",
        .client_id = "abc123",
        .client_secret = "s",
        .redirect_uri = "https://host/vinboard/oidc/callback",
        .mode = "both",
    }, "st4te");
    try testing.expectEqualStrings(
        "https://auth.example.com/oidc/auth?response_type=code&client_id=abc123&redirect_uri=https%3A%2F%2Fhost%2Fvinboard%2Foidc%2Fcallback&scope=openid+profile+email&state=st4te",
        url,
    );
}

test "parseIdToken decodes payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // {"sub":"user1","username":"pavel","email":"p@example.com"}
    const payload = "{\"sub\":\"user1\",\"username\":\"pavel\",\"email\":\"p@example.com\"}";
    var buf: [256]u8 = undefined;
    const enc = std.base64.url_safe_no_pad.Encoder;
    const b64 = enc.encode(buf[0..], payload);
    const jwt = try std.fmt.allocPrint(a, "eyJhbGciOiJSUzI1NiJ9.{s}.sig", .{b64});
    const claims = try parseIdToken(a, jwt);
    try testing.expectEqualStrings("user1", claims.sub);
    try testing.expectEqualStrings("pavel", claims.username.?);
    try testing.expectEqualStrings("p@example.com", claims.email.?);
}

test "parseIdToken rejects garbage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadIdToken, parseIdToken(arena.allocator(), "nonsense"));
}

test "config gating" {
    const off: Config = .{};
    try testing.expect(!off.enabled());
    try testing.expect(off.builtinAllowed());
    const full: Config = .{
        .mode = "oidc",
        .issuer = "https://x/oidc",
        .client_id = "i",
        .client_secret = "s",
        .redirect_uri = "https://y/cb",
    };
    try testing.expect(full.enabled());
    try testing.expect(!full.builtinAllowed());
    const both: Config = .{
        .mode = "both",
        .issuer = "https://x/oidc",
        .client_id = "i",
        .client_secret = "s",
        .redirect_uri = "https://y/cb",
    };
    try testing.expect(both.enabled());
    try testing.expect(both.builtinAllowed());
}

test "proposeHandle" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("pavel", proposeHandle(.{ .sub = "x", .username = "Pavel" }, &buf));
    var buf2: [32]u8 = undefined;
    try testing.expectEqualStrings("p-p", proposeHandle(.{ .sub = "x", .email = "P.p@example.com" }, &buf2));
    var buf3: [32]u8 = undefined;
    try testing.expectEqualStrings("u-abc", proposeHandle(.{ .sub = "ABC" }, &buf3));
}
