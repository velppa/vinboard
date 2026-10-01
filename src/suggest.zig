//! Tag suggestions from a System One decision model.
//!
//! Two passes over the same bookmark text. A choice question ranks the tags
//! the user already uses, and a yes/no question per shortlisted tag then says
//! how likely each one is on its own. Only tags both passes like are
//! suggested: the ranking spreads its probability over the whole vocabulary,
//! so it orders well but cannot be compared against a fixed threshold, while
//! the yes/no answers can.
//!
//! Nothing here is required. With no endpoint configured, or with the server
//! down, suggestion returns nothing and the caller carries on.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const db_mod = @import("db.zig");
const html = @import("html.zig");

pub const Config = struct {
    /// Full url of a System One endpoint. Empty disables suggestions.
    endpoint: []const u8 = "",
    /// Model to ask for, as the endpoint names it.
    model: []const u8 = "jev",
    /// Bearer token, for an endpoint that wants one.
    api_key: []const u8 = "",
    /// How many of the user's most recently used tags the ranking pass
    /// considers.
    vocabulary: usize = 60,
    /// How many of a tag's newest bookmarks describe it to the model.
    examples: usize = 5,
    /// How many of those go on to the yes/no pass.
    shortlist: usize = 5,
    /// Lowest yes/no probability worth suggesting.
    threshold: f64 = 0.5,
    /// Ranking probability above which a tag is suggested whatever the
    /// yes/no pass says.
    trust: f64 = 0.8,
    /// Most tags to suggest.
    limit: usize = 3,
};

/// The text the model decides on. Enough to recognise a page by, in the
/// order a reader would meet it.
pub fn state(alloc: std.mem.Allocator, title: []const u8, url: []const u8, notes: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ title, url, notes });
}

/// Tags for a bookmark the user has not tagged, best first.
///
/// Holds the database lock only to read the vocabulary, never for the round
/// trip to the model, which takes about as long as a page load.
pub fn forBookmark(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    db: *sqlite.Db,
    db_mutex: *std.Io.Mutex,
    user_id: i64,
    title: []const u8,
    url: []const u8,
    notes: []const u8,
) []const []const u8 {
    if (cfg.endpoint.len == 0) return &.{};

    db_mutex.lockUncancelable(io);
    const vocabulary = vocabularyFor(alloc, db, user_id, cfg) catch &.{};
    db_mutex.unlock(io);

    const st = state(alloc, title, url, notes) catch return &.{};
    return suggest(alloc, io, cfg, st, vocabulary);
}

/// A tag the model may suggest, with what tells it apart: the user's newest
/// bookmarks carrying it.
pub const Tag = struct {
    name: []const u8,
    about: []const u8 = "",
};

fn vocabularyFor(alloc: std.mem.Allocator, db: *sqlite.Db, user_id: i64, cfg: Config) ![]Tag {
    const names = try db_mod.recentTags(db, alloc, user_id, cfg.vocabulary);
    const tags = try alloc.alloc(Tag, names.len);
    for (names, tags) |name, *t| t.* = .{
        .name = name,
        .about = try describe(alloc, name, try db_mod.recentLinks(db, alloc, user_id, name, cfg.examples)),
    };
    return tags;
}

/// Lines of "title | url", one per link, each part kept short.
fn describe(alloc: std.mem.Allocator, name: []const u8, links: []const db_mod.Link) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(alloc, "Recent bookmarks tagged {s}:", .{name});
    for (links) |l| try out.print(alloc, "\n{s} | {s}", .{ html.prefixUtf8(l.title, 100), html.prefixUtf8(l.url, 150) });
    return out.toOwnedSlice(alloc);
}

/// Tags for a bookmark, best first. Empty when suggestion is off, when the
/// user has no tags yet, or when anything at all goes wrong.
pub fn suggest(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    st: []const u8,
    vocabulary: []const Tag,
) []const []const u8 {
    if (cfg.endpoint.len == 0 or vocabulary.len == 0) return &.{};
    return attempt(alloc, io, cfg, st, vocabulary) catch |e| {
        std.log.debug("tag suggestion failed: {t}", .{e});
        return &.{};
    };
}

fn attempt(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    st: []const u8,
    vocabulary: []const Tag,
) ![]const []const u8 {
    const vocab = vocabulary[0..@min(vocabulary.len, cfg.vocabulary)];
    const ranked = try rank(alloc, try post(alloc, io, cfg, try rankBody(alloc, cfg, st, vocab)), vocab);
    if (ranked.len == 0) return &.{};
    const short = ranked[0..@min(ranked.len, cfg.shortlist)];
    return confirm(alloc, try post(alloc, io, cfg, try confirmBody(alloc, cfg, st, short)), short, cfg);
}

// --- requests ---------------------------------------------------------------

/// One choice question over the vocabulary. The options are the tags
/// themselves, so the answer comes back keyed by tag.
fn rankBody(alloc: std.mem.Allocator, cfg: Config, st: []const u8, vocab: []const Tag) ![]u8 {
    var criteria: std.json.ObjectMap = .empty;
    for (vocab) |tag| try criteria.put(alloc, tag.name, if (tag.about.len > 0) .{ .string = tag.about } else .null);

    var question: std.json.ObjectMap = .empty;
    try question.put(alloc, "type", .{ .string = "choice" });
    try question.put(alloc, "instructions", .{ .string = "Which tag best describes this bookmark?" });
    try question.put(alloc, "criteria", .{ .object = criteria });

    var questions: std.json.ObjectMap = .empty;
    try questions.put(alloc, "tag", .{ .object = question });
    return body(alloc, cfg, st, questions);
}

/// A yes/no question per shortlisted tag, all in one request. The questions
/// are numbered rather than named after the tag, because a question name is
/// part of the request schema and a tag is arbitrary user text.
fn confirmBody(alloc: std.mem.Allocator, cfg: Config, st: []const u8, short: []const Scored) ![]u8 {
    var questions: std.json.ObjectMap = .empty;
    for (short, 0..) |cand, i| {
        var question: std.json.ObjectMap = .empty;
        try question.put(alloc, "type", .{ .string = "noul" });
        const instructions = try std.fmt.allocPrint(alloc, "Is this bookmark about {s}?", .{cand.tag});
        try question.put(alloc, "instructions", .{ .string = instructions });
        if (cand.about.len > 0) {
            var criteria: std.json.ObjectMap = .empty;
            const yes = try std.fmt.allocPrint(alloc, "It belongs with these. {s}", .{cand.about});
            try criteria.put(alloc, "true", .{ .string = yes });
            try criteria.put(alloc, "false", .{ .string = "It is unlike them." });
            try question.put(alloc, "criteria", .{ .object = criteria });
        }
        try questions.put(alloc, try key(alloc, i), .{ .object = question });
    }
    return body(alloc, cfg, st, questions);
}

fn body(alloc: std.mem.Allocator, cfg: Config, st: []const u8, questions: std.json.ObjectMap) ![]u8 {
    var root: std.json.ObjectMap = .empty;
    try root.put(alloc, "state", .{ .string = st });
    try root.put(alloc, "model", .{ .string = cfg.model });
    try root.put(alloc, "questions", .{ .object = questions });
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
}

fn key(alloc: std.mem.Allocator, i: usize) ![]u8 {
    return std.fmt.allocPrint(alloc, "q{d}", .{i});
}

fn post(alloc: std.mem.Allocator, io: std.Io, cfg: Config, payload: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    var resp: std.Io.Writer.Allocating = .init(alloc);
    const authorization: std.http.Client.Request.Headers.Value = if (cfg.api_key.len > 0)
        .{ .override = try std.fmt.allocPrint(alloc, "Bearer {s}", .{cfg.api_key}) }
    else
        .default;
    const result = try client.fetch(.{
        .location = .{ .url = cfg.endpoint },
        .payload = payload,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = authorization,
        },
        .response_writer = &resp.writer,
    });
    if (result.status != .ok) return error.DecisionServerFailed;
    return resp.written();
}

// --- answers ----------------------------------------------------------------

const Scored = struct {
    tag: []const u8,
    p: f64,
    about: []const u8 = "",
};

fn byProbability(_: void, a: Scored, b: Scored) bool {
    return a.p > b.p;
}

/// The vocabulary ordered by the ranking pass. Tags the answer does not
/// mention are dropped; a served model is free to return fewer.
fn rank(alloc: std.mem.Allocator, json: []const u8, vocab: []const Tag) ![]Scored {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    const probabilities = (answer(parsed, "tag") orelse return error.MalformedAnswer)
        .object.get("probabilities") orelse return error.MalformedAnswer;

    var out: std.ArrayList(Scored) = .empty;
    for (vocab) |tag| {
        const p = probabilities.object.get(tag.name) orelse continue;
        try out.append(alloc, .{ .tag = tag.name, .p = number(p), .about = tag.about });
    }
    std.mem.sort(Scored, out.items, {}, byProbability);
    return out.items;
}

/// The shortlisted tags the yes/no pass was confident about, best first.
fn confirm(
    alloc: std.mem.Allocator,
    json: []const u8,
    short: []const Scored,
    cfg: Config,
) ![]const []const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});

    var kept: std.ArrayList(Scored) = .empty;
    for (short, 0..) |cand, i| {
        const yes: f64 = if (answer(parsed, try key(alloc, i))) |a|
            if (a.object.get("noul")) |v| number(v) else 0
        else
            0;
        if (yes >= cfg.threshold or cand.p >= cfg.trust)
            try kept.append(alloc, .{ .tag = cand.tag, .p = @max(yes, cand.p) });
    }
    std.mem.sort(Scored, kept.items, {}, byProbability);

    const n = @min(kept.items.len, cfg.limit);
    const tags = try alloc.alloc([]const u8, n);
    for (kept.items[0..n], tags) |cand, *slot| slot.* = cand.tag;
    return tags;
}

fn answer(parsed: std.json.Value, name: []const u8) ?std.json.Value {
    const answers = switch (parsed) {
        .object => |o| o.get("answers") orelse return null,
        else => return null,
    };
    const found = switch (answers) {
        .object => |o| o.get(name) orelse return null,
        else => return null,
    };
    return switch (found) {
        .object => found,
        else => null,
    };
}

/// Probabilities arrive as floats, but a certain answer can serialise as an
/// integer.
fn number(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

test "ranking orders the vocabulary and ignores tags the model skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json =
        \\{"answers":{"tag":{"type":"choice","choice":"ml",
        \\ "probabilities":{"ml":0.2,"hn":0.07,"ai":0.14}}}}
    ;
    const vocab = [_]Tag{ .{ .name = "hn" }, .{ .name = "ml" }, .{ .name = "ai" }, .{ .name = "vim" } };
    const ranked = try rank(a, json, &vocab);

    try testing.expectEqual(@as(usize, 3), ranked.len);
    try testing.expectEqualStrings("ml", ranked[0].tag);
    try testing.expectEqualStrings("ai", ranked[1].tag);
    try testing.expectEqualStrings("hn", ranked[2].tag);
}

test "confirmation keeps what clears the threshold, best first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json =
        \\{"answers":{"q0":{"type":"noul","noul":0.6},
        \\ "q1":{"type":"noul","noul":0.91},
        \\ "q2":{"type":"noul","noul":0.2}}}
    ;
    const short = [_]Scored{
        .{ .tag = "ml", .p = 0.2 },
        .{ .tag = "ai", .p = 0.14 },
        .{ .tag = "hn", .p = 0.07 },
    };
    const tags = try confirm(a, json, &short, .{ .threshold = 0.5, .limit = 3 });

    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("ai", tags[0]);
    try testing.expectEqualStrings("ml", tags[1]);
}

test "a confident ranking survives an unconvinced yes/no" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json =
        \\{"answers":{"q0":{"type":"noul","noul":0.26},
        \\ "q1":{"type":"noul","noul":0.27}}}
    ;
    const short = [_]Scored{
        .{ .tag = "u/someone", .p = 0.95 },
        .{ .tag = "photo", .p = 0.03 },
    };
    const tags = try confirm(a, json, &short, .{ .threshold = 0.5, .trust = 0.8 });
    try testing.expectEqual(@as(usize, 1), tags.len);
    try testing.expectEqualStrings("u/someone", tags[0]);
}

test "confirmation returns nothing when the model is unconvinced" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const short = [_]Scored{.{ .tag = "ml", .p = 0.2 }};
    const tags = try confirm(a, "{\"answers\":{\"q0\":{\"noul\":0.49}}}", &short, .{ .threshold = 0.5 });
    try testing.expectEqual(@as(usize, 0), tags.len);
}

test "the limit caps how many tags a bookmark collects" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json =
        \\{"answers":{"q0":{"noul":0.9},"q1":{"noul":0.8},"q2":{"noul":0.7}}}
    ;
    const short = [_]Scored{
        .{ .tag = "ml", .p = 0.2 },
        .{ .tag = "ai", .p = 0.1 },
        .{ .tag = "hn", .p = 0.05 },
    };
    const tags = try confirm(a, json, &short, .{ .threshold = 0.5, .limit = 2 });
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("ml", tags[0]);
}

test "a malformed answer is an error, not a guess" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vocab = [_]Tag{.{ .name = "ml" }};
    try testing.expectError(error.MalformedAnswer, rank(a, "{\"answers\":{}}", &vocab));
    try testing.expectError(error.MalformedAnswer, rank(a, "{}", &vocab));
}

test "the request carries the state and every tag as an option" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vocab = [_]Tag{ .{ .name = "ml", .about = "Recent bookmarks tagged ml:\nA | https://a" }, .{ .name = "quote\"tag" } };
    const json = try rankBody(a, .{ .model = "jev-test" }, "a title\nhttps://example.com\n", &vocab);

    // Round-trips, so the tag carrying a quote is escaped rather than broken.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const criteria = parsed.object.get("questions").?.object
        .get("tag").?.object.get("criteria").?.object;
    try testing.expectEqual(@as(usize, 2), criteria.count());
    try testing.expect(criteria.contains("quote\"tag"));
    try testing.expectEqualStrings("Recent bookmarks tagged ml:\nA | https://a", criteria.get("ml").?.string);
    try testing.expectEqualStrings("a title\nhttps://example.com\n", parsed.object.get("state").?.string);
    try testing.expectEqualStrings("jev-test", parsed.object.get("model").?.string);
}
