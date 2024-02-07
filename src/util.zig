const std = @import("std");
const t = @import("std").testing;

/// naive value search in query string, no decoding
pub fn findStringInQuery(query: []const u8, comptime name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, query, name ++ "=") and query.len >= name.len + 1) {
        const start = name.len + 1;
        return if (std.mem.indexOfPos(u8, query, start, "&")) |end| query[start..end] else query[start..];
    }

    const amp = std.mem.indexOf(u8, query, "&");
    if (amp == null or amp.? + 1 >= query.len) return null;

    return findStringInQuery(query[amp.? + 1 ..], name);
}

test findStringInQuery {
    try t.expectEqualStrings(
        "asd",
        findStringInQuery("foo=asd", "foo").?,
    );
    try t.expectEqualStrings(
        "asd",
        findStringInQuery("bar=foo&foo=asd", "foo").?,
    );
    try t.expectEqualStrings(
        "asd",
        findStringInQuery("bar=foo&foo=asd&baz=aa", "foo").?,
    );
    try t.expectEqualStrings(
        "asd",
        findStringInQuery("bar=foo&foo=asd&baz=aa", "foo").?,
    );
    try t.expect(findStringInQuery("bar=foo&foo=asd&baz=aa", "asd") == null);
}

/// does not work with ecaped double-quotes
/// json should be compact (no whitespaces or newlines)
pub fn findStringInJson(json_buf: []const u8, comptime name: []const u8) ?[]const u8 {
    const s = if (std.mem.indexOf(u8, json_buf, "\"" ++ name ++ "\":\"")) |i| i + 4 + name.len else return null;
    if (s >= json_buf.len) return null;

    const e = if (std.mem.indexOfPos(u8, json_buf, s, "\"")) |i| i else return null;
    return json_buf[s..e];
}

test findStringInJson {
    try t.expectEqualStrings(
        "asd",
        findStringInJson("{\"foo\":\"asd\"}", "foo").?,
    );
    try t.expectEqualStrings(
        "asd",
        findStringInJson("{\"bar\":\"aaa\",\"foo\":\"asd\"", "foo").?,
    );
    try t.expect(findStringInJson("{\"bar\":\"aaa\",\"foo\":\"asd\"", "aaa") == null);
}

pub const MutexStore = struct {
    hm: std.StringHashMapUnmanaged(std.Thread.Mutex),
    allocator: std.mem.Allocator,
    m: std.Thread.Mutex = .{},
    kl: std.ArrayListUnmanaged([]const u8),

    const Self = @This();
    pub fn get(self: *Self, key: []const u8) !*std.Thread.Mutex {
        self.m.lock();
        defer self.m.unlock();
        const e = try self.hm.getOrPut(self.allocator, key);
        if (!e.found_existing) {
            std.log.debug("creating mutex for {s}, current map size {}", .{ key, self.hm.size });

            // copy key because outer may get freed
            const key_copy = try self.allocator.alloc(u8, key.len);
            try self.kl.append(self.allocator, key_copy);
            @memcpy(key_copy, key);
            e.key_ptr.* = key_copy;

            e.value_ptr.* = std.Thread.Mutex{};
        }

        return e.value_ptr;
    }
    pub fn init(allocator: std.mem.Allocator) MutexStore {
        return .{
            .allocator = allocator,
            .kl = .{},
            .hm = .{},
        };
    }
    pub fn deinit(self: *Self) void {
        self.hm.deinit(self.allocator);
        for (self.kl.items) |it| self.allocator.free(it);
        self.kl.deinit(self.allocator);
        self.* = undefined;
    }
};

test MutexStore {
    const allocator = std.testing.allocator;

    var ms = MutexStore.init(allocator);
    defer ms.deinit();

    const k = try allocator.alloc(u8, 3);
    @memcpy(k, "one");

    const m1 = try ms.get(k);
    allocator.free(k);
    m1.lock();

    const m2 = try ms.get("one");
    try std.testing.expect(!m2.tryLock());

    const another = try ms.get("another");
    try std.testing.expect(another.tryLock());

    try std.testing.expect(ms.hm.size == 2);
    try std.testing.expect(ms.kl.items.len == 2);
}
