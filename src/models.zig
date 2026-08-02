pub const Bookmark = struct {
    id: i64,
    url: []const u8,
    title: []const u8,
    notes: []const u8,
    created_at: i64,
    updated_at: i64,
    toread: bool,
    shared: bool,
    starred: bool = false,
    user_id: i64 = 1,
    tags: [][]const u8 = &.{},
};

pub const NewBookmark = struct {
    url: []const u8,
    title: []const u8 = "",
    notes: []const u8 = "",
    toread: bool = false,
    shared: bool = false,
    tags: []const []const u8 = &.{},
};

pub const ArchiveStatus = enum { pending, done, failed, dead };
