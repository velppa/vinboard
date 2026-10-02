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
