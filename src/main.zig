const std = @import("std");
const build_options = @import("build_options");
const Config = @import("Config.zig");
const Tf = @import("Tf.zig");

pub const std_options = std.Options{
    .log_level = switch (build_options.log_level) {
        inline else => |tag| @field(std.log.Level, @tagName(tag)),
    },
};
const term_signals_as_mask = [_]u32{ 1, 2, 3, 15 } ++ ([_]u32{0} ** 28);

const BackendState = enum { running, interrupted };

var server: std.http.Server = undefined;
var threads: []std.Thread = undefined;
var backend_state = BackendState.running;

pub fn main() !void {
    std.log.info("starting", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const gpallocator = gpa.allocator();
    try Tf.init(gpallocator);
    defer Tf.deinit();
    const cfg = try Config.init(gpallocator);

    server = std.http.Server.init(.{ .reuse_address = true, .reuse_port = false });
    defer server.deinit();

    for (std.mem.sliceTo(&term_signals_as_mask, 0)) |sig| {
        try std.os.sigaction(@intCast(sig), &std.os.Sigaction{
            .mask = term_signals_as_mask,
            .flags = 0,
            .handler = .{ .handler = handleSig },
        }, null);
    }

    threads = try gpallocator.alloc(std.Thread, cfg.pool_size);
    defer for (threads) |thread| thread.join();
    std.log.info("allocated {} threads", .{threads.len});

    try server.listen(cfg.address);
    std.log.info("server.listen on address {}", .{cfg.address});

    for (0..threads.len) |i| threads[i] = try std.Thread.spawn(
        .{},
        handleServer,
        .{ gpallocator, i },
    );
}

fn handleServer(allocator: std.mem.Allocator, i: usize) void {
    while (backend_state != .interrupted) {
        std.log.debug("thread {} awaiting connection", .{i});
        var res = server.accept(.{ .allocator = allocator }) catch |err| {
            std.log.err("server.accept failed with {}", .{err});
            continue;
        };
        defer res.deinit();
        std.log.debug("thread {} got connection ptr {}", .{ i, @intFromPtr(&res.connection) });

        while (res.reset() != .closing and backend_state != .interrupted) {
            res.wait() catch |err| {
                std.log.err("res.wait failed with {}", .{err});
                switch (err) {
                    error.HttpHeadersInvalid => break,
                    error.HttpHeadersExceededSizeLimit => {
                        res.status = .request_header_fields_too_large;
                        res.send() catch break;
                        break;
                    },
                    else => {
                        res.status = .bad_request;
                        res.send() catch break;
                        break;
                    },
                }
            };
            std.log.info("{}: {s}", .{ res.request.method, res.request.target });

            Tf.handle(res) catch |err| {
                std.log.err("Tf.handle failed with {}", .{err});
                sendErr(res, err) catch |cerr| {
                    std.log.err("sendErr failed with {} {?}", .{ cerr, @errorReturnTrace() });
                };
            };
        }
    }
}

fn sendErr(response: std.http.Server.Response, err: anyerror) !void {
    var res = response;
    switch (err) {
        Tf.HandlerError.InvalidTarget,
        Tf.HandlerError.UnsupportedMethod,
        Tf.HandlerError.InvalidMD5,
        Tf.HandlerError.InvalidID,
        Tf.HandlerError.MissingID,
        => {
            res.status = std.http.Status.bad_request;
            res.reason = @errorName(err);
        },
        Tf.HandlerError.NotFound => res.status = std.http.Status.not_found,
        Tf.HandlerError.Locked => res.status = std.http.Status.locked,
        Tf.HandlerError.Conflict => res.status = std.http.Status.conflict,
        Tf.HandlerError.MalformedState => res.status = std.http.Status.internal_server_error,
        else => {
            std.log.err("unexpected error {} {?}", .{ err, @errorReturnTrace() });
            res.status = std.http.Status.internal_server_error;
            res.reason = @errorName(err);
        },
    }

    try switch (res.state) {
        .waited => {
            try res.send();
            try res.finish();
        },
        .responded => res.finish(),
        else => |state| {
            std.log.warn("sendErr res.state {}", .{state});
        },
    };
}

fn handleSig(sig: c_int) callconv(.C) void {
    std.log.info("received SIGNAL {}, shutting down", .{sig});
    backend_state = .interrupted;
    // for (threads) |thread| thread.join(); // accept blocks the thread so backend_state is never checked
    server.deinit();
    Tf.deinit();
    std.process.exit(1);
}

test "main" {
    _ = Tf;
}
