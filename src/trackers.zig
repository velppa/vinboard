//! Ad and campaign tracking parameters in urls.
//!
//! Only parameters that exist to attribute a click - utm_* and the click
//! and campaign ids ad and mail platforms append - are dropped; anything
//! a page might need to show the right content stays.

const std = @import("std");

/// Parameter names that only track, compared ignoring case.  Any name
/// starting with "utm_" tracks too.
const tracking = [_][]const u8{
    "fbclid",   "gclid",  "gclsrc", "dclid",  "gbraid", "wbraid",
    "msclkid",  "yclid",  "twclid", "ttclid", "li_fat_id", "igshid",
    "mc_cid",   "mc_eid", "_hsenc", "_hsmi",  "mkt_tok", "_ga",
    "_gl",
};

fn isTracking(name: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(name, "utm_")) return true;
    for (tracking) |t| if (std.ascii.eqlIgnoreCase(name, t)) return true;
    return false;
}

/// URL without its tracking parameters, in the query and in a fragment
/// that carries parameters too.  Returns URL itself when it has none, so
/// callers can tell nothing changed by comparing pointers.
pub fn clean(alloc: std.mem.Allocator, url: []const u8) ![]const u8 {
    const hash = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
    const base = url[0..hash];
    const frag = url[hash..];
    const b = if (std.mem.indexOfScalar(u8, base, '?')) |q| try strip(alloc, base, q + 1) else base;
    const f = try cleanFragment(alloc, frag);
    if (b.ptr == base.ptr and f.ptr == frag.ptr) return url;
    return std.mem.concat(alloc, u8, &.{ b, f });
}

/// FRAG (with its "#") without tracking parameters: those of a query after
/// a "?" in it, or the fragment's own when it is all key=value pairs.
fn cleanFragment(alloc: std.mem.Allocator, frag: []const u8) ![]const u8 {
    if (frag.len <= 1) return frag;
    if (std.mem.indexOfScalar(u8, frag, '?')) |q| return strip(alloc, frag, q + 1);
    var it = std.mem.splitScalar(u8, frag[1..], '&');
    while (it.next()) |param| if (std.mem.indexOfScalar(u8, param, '=') == null) return frag;
    const out = try strip(alloc, frag, 1);
    return if (out.len == 1) "" else out;
}

/// S with the tracking parameters dropped from the "&"-separated list that
/// starts at FROM; the separator before FROM goes too when none remain.
/// Returns S itself when nothing is dropped.
fn strip(alloc: std.mem.Allocator, s: []const u8, from: usize) ![]const u8 {
    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(alloc);
    var dropped = false;
    var it = std.mem.splitScalar(u8, s[from..], '&');
    while (it.next()) |param| {
        if (param.len == 0) continue;
        const name = param[0 .. std.mem.indexOfScalar(u8, param, '=') orelse param.len];
        if (isTracking(name)) {
            dropped = true;
            continue;
        }
        if (kept.items.len > 0) try kept.append(alloc, '&');
        try kept.appendSlice(alloc, param);
    }
    if (!dropped) return s;
    const head = if (kept.items.len > 0) s[0..from] else s[0 .. from - 1];
    return std.mem.concat(alloc, u8, &.{ head, kept.items });
}

test "clean drops tracking parameters and keeps the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const eq = std.testing.expectEqualStrings;
    try eq("https://x.test/a", try clean(a, "https://x.test/a?utm_source=hn&utm_medium=social"));
    try eq("https://x.test/a?id=3#top", try clean(a, "https://x.test/a?utm_source=hn&id=3&fbclid=abc#top"));
    try eq("https://x.test/a?id=3", try clean(a, "https://x.test/a?id=3&UTM_Campaign=x&mc_eid=1"));
    try eq("https://x.test/a", try clean(a, "https://x.test/a?gclid=1#utm_source=x"));
    try eq("https://youtu.be/v?si=abc", try clean(a, "https://youtu.be/v?si=abc"));
    try eq("https://x.test/p/", try clean(a, "https://x.test/p/#utm_source=rss&utm_medium=rss"));
    try eq("https://x.test/p#ixzz5", try clean(a, "https://x.test/p#ixzz5?utm_campaign=c"));
    try eq("https://x.test/p?m=1#ixzz5", try clean(a, "https://x.test/p?m=1#ixzz5?utm_campaign=c"));
    try eq("https://x.test/p#_=_", try clean(a, "https://x.test/p#_=_?utm_medium=social"));
    try eq("https://x.test/app#/route?tab=2", try clean(a, "https://x.test/app#/route?tab=2&gclid=9"));
}

test "clean returns the url itself when nothing tracks" {
    const url = "https://news.ycombinator.com/item?id=1";
    try std.testing.expect((try clean(std.testing.allocator, url)).ptr == url.ptr);
    const bare = "https://x.test/";
    try std.testing.expect((try clean(std.testing.allocator, bare)).ptr == bare.ptr);
}

/// The post a Reddit share link (reddit.com/r/SUB/s/CODE) led to, given
/// FINAL, the url the browser ended on: the permalink without its query,
/// which only carries share and tracking ids.  Null when URL is not a share
/// link or FINAL is not a post.
pub fn redditPost(alloc: std.mem.Allocator, url: []const u8, final: []const u8) !?[]const u8 {
    const share_path = redditPath(url) orelse return null;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, share_path, "/"), '/');
    if (!std.mem.eql(u8, parts.next() orelse "", "r")) return null;
    _ = parts.next() orelse return null;
    if (!std.mem.eql(u8, parts.next() orelse "", "s")) return null;
    const code: []const u8 = parts.next() orelse "";
    if (code.len == 0 or parts.next() != null) return null;

    const post_path = redditPath(final) orelse return null;
    if (std.mem.indexOf(u8, post_path, "/comments/") == null) return null;
    return try std.mem.concat(alloc, u8, &.{ "https://www.reddit.com", post_path });
}

/// The path of a reddit.com url, without query or fragment; null for other
/// hosts.
fn redditPath(url: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, url, "https://")) url[8..] else if (std.mem.startsWith(u8, url, "http://")) url[7..] else return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    if (!(std.ascii.eqlIgnoreCase(host, "reddit.com") or std.ascii.endsWithIgnoreCase(host, ".reddit.com"))) return null;
    const path = rest[slash..];
    const end = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    return path[0..end];
}

test "redditPost follows a share link to its post" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "https://www.reddit.com/r/Clojure/comments/1wwav8e/stuart_halloway/",
        (try redditPost(a, "https://www.reddit.com/r/Clojure/s/eG2JBkQIRI",
            "https://www.reddit.com/r/Clojure/comments/1wwav8e/stuart_halloway/?share_id=x&utm_medium=ios_app")).?,
    );
    try std.testing.expect((try redditPost(a, "https://www.reddit.com/r/Clojure/comments/1/x/", "https://www.reddit.com/r/Clojure/comments/1/x/")) == null);
    try std.testing.expect((try redditPost(a, "https://www.reddit.com/r/Clojure/s/eG2", "https://www.reddit.com/login/")) == null);
    try std.testing.expect((try redditPost(a, "https://example.com/r/x/s/y", "https://www.reddit.com/r/x/comments/1/z/")) == null);
}
