const std = @import("std");
const models = @import("models.zig");
const db_mod = @import("db.zig");
const sqlite = @import("sqlite.zig");

pub const Imported = struct {
    items: []models.NewBookmark,
    created_at: []i64, // parallel array: source timestamp per item
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Imported) void {
        self.arena.deinit();
    }
};

fn yesNo(s: []const u8) bool {
    return std.mem.eql(u8, s, "yes");
}

pub fn parsePinboard(gpa: std.mem.Allocator, json: []const u8) !Imported {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const arr = parsed.array;
    var items = try a.alloc(models.NewBookmark, arr.items.len);
    var times = try a.alloc(i64, arr.items.len);
    for (arr.items, 0..) |v, i| {
        const o = v.object;
        const tags_str = if (o.get("tags")) |t| t.string else "";
        var tag_list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, tags_str, ' ');
        while (it.next()) |tg| try tag_list.append(a, tg);
        items[i] = .{
            .url = (o.get("href") orelse return error.MissingHref).string,
            .title = if (o.get("description")) |d| d.string else "",
            .notes = if (o.get("extended")) |e| e.string else "",
            .toread = if (o.get("toread")) |t| yesNo(t.string) else false,
            .shared = if (o.get("shared")) |s| yesNo(s.string) else false,
            .tags = try tag_list.toOwnedSlice(a),
        };
        times[i] = if (o.get("time")) |t| parseIso(t.string) else 0;
    }
    return .{ .items = items, .created_at = times, .arena = arena };
}

/// Minimal ISO-8601 "YYYY-MM-DDThh:mm:ssZ" → unix seconds.
pub fn parseIso(s: []const u8) i64 {
    if (s.len < 20) return 0;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return 0;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return 0;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return 0;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return 0;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return 0;
    const se = std.fmt.parseInt(i64, s[17..19], 10) catch return 0;
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se;
}

// Howard Hinnant's days_from_civil.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn parseSafari(gpa: std.mem.Allocator, json: []const u8) !Imported {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const arr = parsed.array;
    var items = try a.alloc(models.NewBookmark, arr.items.len);
    var times = try a.alloc(i64, arr.items.len);
    for (arr.items, 0..) |v, i| {
        const o = v.object;
        items[i] = .{
            .url = (o.get("url") orelse return error.MissingUrl).string,
            .title = if (o.get("title")) |t| t.string else "",
            .tags = &.{},
        };
        times[i] = switch (o.get("time") orelse std.json.Value{ .integer = 0 }) {
            .integer => |n| n,
            .float => |f| @as(i64, @intFromFloat(f)),
            else => 0,
        };
    }
    return .{ .items = items, .created_at = times, .arena = arena };
}

/// Insert all imported items, skipping urls that already exist. Returns count inserted.
pub fn importInto(db: *sqlite.Db, imp: Imported) !usize {
    var n: usize = 0;
    for (imp.items, imp.created_at) |nb, t| {
        if (try urlExists(db, nb.url)) continue;
        _ = try db_mod.insertBookmark(db, nb, if (t == 0) unixNow() else t);
        n += 1;
    }
    return n;
}

fn unixNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

fn urlExists(db: *sqlite.Db, url: []const u8) !bool {
    var q = try db.prepare("SELECT 1 FROM bookmarks WHERE url=? LIMIT 1;");
    defer q.finalize();
    q.bindText(1, url);
    return try q.step();
}

test "parse pinboard fixture" {
    const json = @embedFile("tests/fixtures/pinboard.json");
    var imp = try parsePinboard(std.testing.allocator, json);
    defer imp.deinit();
    try std.testing.expectEqual(@as(usize, 2), imp.items.len);
    try std.testing.expectEqualStrings("https://a.test", imp.items[0].url);
    try std.testing.expectEqual(@as(usize, 2), imp.items[0].tags.len);
    try std.testing.expect(imp.items[0].shared);
    try std.testing.expect(imp.items[1].toread);
}

test "parse safari fixture" {
    const json = @embedFile("tests/fixtures/safari.json");
    var imp = try parseSafari(std.testing.allocator, json);
    defer imp.deinit();
    try std.testing.expectEqual(@as(usize, 2), imp.items.len);
    try std.testing.expectEqualStrings("https://s1.test", imp.items[0].url);
    try std.testing.expectEqual(@as(i64, 1700000000), imp.created_at[0]);
}

test "import skips duplicate urls" {
    var db = try db_mod.testDbPub();
    defer db.close();
    const json = @embedFile("tests/fixtures/pinboard.json");
    var imp = try parsePinboard(std.testing.allocator, json);
    defer imp.deinit();
    try std.testing.expectEqual(@as(usize, 2), try importInto(&db, imp));

    var imp2 = try parsePinboard(std.testing.allocator, json);
    defer imp2.deinit();
    try std.testing.expectEqual(@as(usize, 0), try importInto(&db, imp2)); // all dupes
}
