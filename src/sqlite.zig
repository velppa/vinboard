const std = @import("std");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

// Declared in vendor/sqlite3_helpers.c — wraps sqlite3_bind_text with SQLITE_TRANSIENT.
// We use a C helper because Zig 0.16.0 cannot represent the sentinel value
// ((sqlite3_destructor_type)-1) as a typed pointer constant without triggering
// alignment safety checks in Debug mode.
extern fn zig_sqlite3_bind_text_transient(
    stmt: *c.sqlite3_stmt,
    i: c_int,
    text: [*]const u8,
    len: c_int,
) c_int;

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Db {
        var h: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &h) != c.SQLITE_OK) return error.OpenFailed;
        return .{ .handle = h.? };
    }

    pub fn openMemory() !Db {
        return open(":memory:");
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Run one or more statements with no result rows.
    pub fn exec(self: *Db, sql: [:0]const u8) !void {
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(self.handle, sql.ptr, null, null, &errmsg) != c.SQLITE_OK) {
            if (errmsg != null) {
                std.log.err("sqlite exec: {s}", .{errmsg});
                c.sqlite3_free(errmsg);
            }
            return error.ExecFailed;
        }
    }

    /// Last error message for logging.
    pub fn errMsg(self: *Db) [*:0]const u8 {
        return c.sqlite3_errmsg(self.handle);
    }

    pub fn prepare(self: *Db, sql: []const u8) !Stmt {
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &s, null) != c.SQLITE_OK) {
            std.log.err("prepare: {s}", .{self.errMsg()});
            return error.PrepareFailed;
        }
        return .{ .ptr = s.? };
    }
};

pub const Stmt = struct {
    ptr: *c.sqlite3_stmt,

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.ptr);
    }
    pub fn bindText(self: *Stmt, i: c_int, v: []const u8) void {
        _ = zig_sqlite3_bind_text_transient(self.ptr, i, v.ptr, @intCast(v.len));
    }
    pub fn bindInt(self: *Stmt, i: c_int, v: i64) void {
        _ = c.sqlite3_bind_int64(self.ptr, i, v);
    }
    pub fn bindNull(self: *Stmt, i: c_int) void {
        _ = c.sqlite3_bind_null(self.ptr, i);
    }
    /// Returns true if a row is available, false when done.
    pub fn step(self: *Stmt) !bool {
        return switch (c.sqlite3_step(self.ptr)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.StepFailed,
        };
    }
    pub fn columnInt(self: *Stmt, i: c_int) i64 {
        return c.sqlite3_column_int64(self.ptr, i);
    }
    /// Slice valid until the next step/finalize. Caller dupes if it must outlive.
    pub fn columnText(self: *Stmt, i: c_int) []const u8 {
        const p = c.sqlite3_column_text(self.ptr, i);
        if (p == null) return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.ptr, i));
        return @as([*]const u8, @ptrCast(p))[0..len];
    }
};

test "open in-memory and exec" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (1);");
}

test "prepare/bind/step roundtrip" {
    var db = try Db.openMemory();
    defer db.close();
    try db.exec("CREATE TABLE t(id INTEGER, name TEXT);");
    var ins = try db.prepare("INSERT INTO t(id,name) VALUES (?,?);");
    ins.bindInt(1, 7);
    ins.bindText(2, "hi");
    try std.testing.expect((try ins.step()) == false);
    ins.finalize();

    var q = try db.prepare("SELECT id,name FROM t;");
    defer q.finalize();
    try std.testing.expect(try q.step());
    try std.testing.expectEqual(@as(i64, 7), q.columnInt(0));
    try std.testing.expectEqualStrings("hi", q.columnText(1));
}
