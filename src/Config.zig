const std = @import("std");

const Config = @This();
host: []const u8,
port: []const u8,
pool_size: ?[]const u8,

pub fn init(alocator: std.mem.Allocator) !Config {
    return .{
        .host = std.process.getEnvVarOwned(alocator, "HOST") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => "0.0.0.0",
            else => return err,
        },
        .port = std.process.getEnvVarOwned(alocator, "PORT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => "3030",
            else => return err,
        },
        .pool_size = std.process.getEnvVarOwned(alocator, "POOL_SIZE") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        },
    };
}
