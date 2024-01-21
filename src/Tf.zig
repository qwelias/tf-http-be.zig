const std = @import("std");
const util = @import("util.zig");

var state_dir: std.fs.Dir = undefined;
const MAX_TARGET_LEN: usize = 128;
const BUF_SIZE: usize = 4096;
const EMPTY_CONTENT_MD5 = "1B2M2Y8AsgTpgAmY7PhCfg==";
const Files = struct {
    pub const lockinfo = "lockinfo.json";
    pub const counter = "counter";
    pub const tfstate = ".terraform.tfstate";
    pub const createOpts = std.fs.File.CreateFlags{ .exclusive = true, .lock = .exclusive, .lock_nonblocking = true };
    pub const writeOpts = std.fs.File.OpenFlags{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true };
    pub const readOpts = std.fs.File.OpenFlags{ .mode = .read_only, .lock = .shared, .lock_nonblocking = true };
};
pub const HandlerError = error{
    UnsupportedMethod,
    InvalidTarget,
    InvalidMD5,
    InvalidID,
    MissingID,
    NotFound,
    Locked,
    Conflict,

    MalformedState,
};
const ExtraMethod = struct {
    pub const UNLOCK = @as(std.http.Method, @enumFromInt(std.http.Method.parse("UNLOCK")));
    pub const LOCK = @as(std.http.Method, @enumFromInt(std.http.Method.parse("LOCK")));
};

pub fn init() !void {
    state_dir = try std.fs.cwd().makeOpenPath("state", .{});
}

pub fn handle(allocator: std.mem.Allocator, response: std.http.Server.Response) !void {
    const uri = try std.Uri.parseWithoutScheme(response.request.target);
    try checkTarget(uri.path);
    try switch (response.request.method) {
        std.http.Method.GET => handleGet(allocator, response, uri),
        std.http.Method.POST => handlePost(allocator, response, uri),
        std.http.Method.DELETE => handleDelete(allocator, response, uri),
        ExtraMethod.LOCK => handleLock(allocator, response, uri),
        ExtraMethod.UNLOCK => handleUnlock(allocator, response, uri),
        else => return HandlerError.UnsupportedMethod,
    };
}

fn checkTarget(target: []const u8) HandlerError!void {
    if (target.len < 2 or target.len > MAX_TARGET_LEN) return HandlerError.InvalidTarget;
    for (target[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') {
            return HandlerError.InvalidTarget;
        }
    }
}

fn handleGet(allocator: std.mem.Allocator, response: std.http.Server.Response, uri: std.Uri) !void {
    var res = response;
    var sm = try getMutexFor(allocator, uri.path);
    sm.lock();
    defer sm.unlock();

    var target_dir = state_dir.openDir(uri.path[1..], .{}) catch return HandlerError.NotFound;
    defer target_dir.close();

    var buf: [BUF_SIZE]u8 = undefined;

    const state_name = blk: {
        const counter_file = target_dir.openFile(Files.counter, Files.readOpts) catch return HandlerError.NotFound;
        defer counter_file.close();
        const amt = try counter_file.readAll(&buf);
        if (amt == 0) return HandlerError.NotFound;
        if (amt > 16) return HandlerError.MalformedState;
        @memcpy(buf[amt .. amt + Files.tfstate.len], Files.tfstate);
        break :blk buf[0 .. amt + Files.tfstate.len];
    };
    std.log.debug("state_name {s}", .{state_name});

    const state_stat = target_dir.statFile(state_name) catch return HandlerError.NotFound;
    const state_file = target_dir.openFile(state_name, Files.readOpts) catch return HandlerError.NotFound;
    defer state_file.close();

    res.transfer_encoding = .{ .content_length = state_stat.size };
    try res.send();

    while (true) {
        const amt = try state_file.readAll(&buf);
        if (amt == 0) break;
        try res.writeAll(buf[0..amt]);
    }
    try res.finish();
}

fn handleUnlock(allocator: std.mem.Allocator, response: std.http.Server.Response, uri: std.Uri) !void {
    var res = response;
    var sm = try getMutexFor(allocator, uri.path);
    sm.lock();
    defer sm.unlock();

    var target_dir = try state_dir.openDir(uri.path[1..], .{});
    defer target_dir.close();
    const lockfile = try target_dir.openFile(Files.lockinfo, Files.readOpts);
    defer lockfile.close();

    var req_buf: [BUF_SIZE]u8 = undefined;
    var file_buf: [BUF_SIZE]u8 = undefined;

    const md5 = res.request.headers.getFirstValue("content-md5");
    if (md5 != null and std.mem.eql(u8, EMPTY_CONTENT_MD5, md5.?)) {
        std.log.warn("skipping lock id check because https://github.com/hashicorp/terraform/pull/34517", .{});
    } else {
        var amt = try res.readAll(&req_buf);
        const req_id = if (util.findStringInJson(req_buf[0..amt], "ID")) |id| id else return HandlerError.MissingID;

        amt = try lockfile.readAll(&file_buf);
        const file_id = if (util.findStringInJson(file_buf[0..amt], "ID")) |id| id else return HandlerError.MalformedState;

        std.log.debug("req_id {s} vs file_id {s}", .{ req_id, file_id });
        if (!std.mem.eql(u8, req_id, file_id)) return HandlerError.InvalidID;
    }

    try target_dir.deleteFile(Files.lockinfo);
    try res.send();
    try res.finish();
}

fn handleLock(allocator: std.mem.Allocator, response: std.http.Server.Response, uri: std.Uri) !void {
    var res = response;
    var sm = try getMutexFor(allocator, uri.path);
    sm.lock();
    defer sm.unlock();

    var target_dir = try state_dir.makeOpenPath(uri.path[1..], .{});
    defer target_dir.close();
    var buf: [BUF_SIZE]u8 = undefined;

    if (target_dir.statFile(Files.lockinfo)) |stat| {
        const lockfile = try target_dir.openFile(Files.lockinfo, Files.readOpts);
        defer lockfile.close();

        res.transfer_encoding = .{ .content_length = stat.size };
        res.status = @enumFromInt(409);
        try res.send();

        while (true) {
            const amt = try lockfile.readAll(&buf);
            if (amt == 0) break;
            try res.writeAll(buf[0..amt]);
        }
    } else |_| {
        const lockfile = try target_dir.createFile(Files.lockinfo, Files.createOpts);
        defer lockfile.close();

        try res.send();
        while (true) {
            const amt = try res.readAll(&buf);
            if (amt == 0) break;
            try lockfile.writeAll(buf[0..amt]);
        }
    }

    try res.finish();
}

fn handleDelete(allocator: std.mem.Allocator, response: std.http.Server.Response, uri: std.Uri) !void {
    var res = response;
    var sm = try getMutexFor(allocator, uri.path);
    sm.lock();
    defer sm.unlock();

    var target_dir = try state_dir.makeOpenPath(uri.path[1..], .{});
    defer target_dir.close();

    if (target_dir.statFile(Files.lockinfo)) |_| {
        return HandlerError.Locked;
    } else |_| {
        try state_dir.deleteDir(uri.path[1..]);
        try res.send();
        try res.finish();
    }
}

fn handlePost(allocator: std.mem.Allocator, response: std.http.Server.Response, uri: std.Uri) !void {
    var res = response;
    var sm = try getMutexFor(allocator, uri.path);
    sm.lock();
    defer sm.unlock();

    var target_dir = try state_dir.openDir(uri.path[1..], .{});
    defer target_dir.close();

    var buf: [BUF_SIZE]u8 = undefined;

    const req_id: ?[]const u8 = if (uri.query) |q| util.findStringInQuery(q, "ID") else null;
    const lock_id: ?[]const u8 = blk: {
        const lockfile = target_dir.openFile(Files.lockinfo, Files.readOpts) catch break :blk null;
        defer lockfile.close();
        const amt = try lockfile.readAll(&buf);
        break :blk util.findStringInJson(buf[0..amt], "ID");
    };
    if (lock_id == null and req_id != null) return HandlerError.NotFound;
    if (lock_id != null and (req_id == null or !std.mem.eql(u8, lock_id.?, req_id.?))) return HandlerError.Conflict;

    const count: usize = blk: {
        const counter = target_dir.openFile(Files.counter, Files.readOpts) catch break :blk 0;
        defer counter.close();
        const amt = try counter.readAll(&buf);
        if (amt == 0 or amt > 16) return HandlerError.MalformedState;
        break :blk if (std.fmt.parseUnsigned(usize, buf[0..amt], 10)) |c| c + 1 else |_| return HandlerError.MalformedState;
    };

    const state_name = blk: {
        const amt = std.fmt.formatIntBuf(&buf, count, 10, .lower, .{});
        @memcpy(buf[amt .. amt + Files.tfstate.len], Files.tfstate);
        break :blk buf[0 .. amt + Files.tfstate.len];
    };
    std.log.debug("state_name {s}", .{state_name});

    const statefile = try target_dir.createFile(state_name, Files.createOpts);
    defer statefile.close();
    while (true) {
        const amt = try res.readAll(&buf);
        if (amt == 0) break;
        try statefile.writeAll(buf[0..amt]);
    }

    const counter = if (count == 0) try target_dir.createFile(Files.counter, Files.createOpts) else try target_dir.openFile(Files.counter, Files.writeOpts);
    defer counter.close();
    try std.fmt.formatInt(count, 10, .lower, .{}, counter.writer());

    try res.send();
    try res.finish();
}

// TODO should probably use LRU cache to avoid infinitely growing the hashmap
var sm_map = std.StringHashMapUnmanaged(std.Thread.Mutex){};
var m = std.Thread.Mutex{};
fn getMutexFor(allocator: std.mem.Allocator, key: []const u8) !std.Thread.Mutex {
    if (sm_map.get(key)) |sm| {
        std.log.debug("found mutex for {s}", .{key});
        return sm;
    } else {
        std.log.debug("missed mutex for {s}", .{key});

        m.lock();
        defer m.unlock();
        const e = try sm_map.getOrPut(allocator, key);
        if (!e.found_existing) {
            std.log.debug("creating mutex for {s}, current map size {}", .{ key, sm_map.size });

            // copy key because outer may get freed
            const key_copy = try allocator.alloc(u8, key.len);
            @memcpy(key_copy, key);
            e.key_ptr.* = key_copy;

            e.value_ptr.* = std.Thread.Mutex{};
        }

        return e.value_ptr.*;
    }
}

test "Tf" {
    _ = util;
}
