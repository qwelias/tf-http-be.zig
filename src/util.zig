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
