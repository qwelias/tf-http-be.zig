const std = @import("std");

address: std.net.Address,
pool_size: usize,

const Config = @This();
pub fn init(allocator: std.mem.Allocator) !Config {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const host: []const u8 = if (env_map.get("HOST")) |str| str else "0.0.0.0";
    const port: []const u8 = if (env_map.get("PORT")) |str| str else "3030";

    return .{
        .address = try std.net.Address.resolveIp(host, try std.fmt.parseUnsigned(u16, port, 10)),
        .pool_size = if (env_map.get("POOL_SIZE")) |str| try std.fmt.parseUnsigned(usize, str, 10) else try std.Thread.getCpuCount(),
    };
}
