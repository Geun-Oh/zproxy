const std = @import("std");
const acl = @import("acl.zig");

pub const Config = struct {
    frontends: []const Frontend,
    backends: []const Backend,
};

pub const Frontend = struct {
    name: []const u8,
    bind_address: []const u8 = "0.0.0.0",
    bind_port: u16,
    backend_name: []const u8,

    // ACL Definitions
    acls: []const acl.ACL = &[_]acl.ACL{},

    // Request Rules (evaluated in order)
    http_request_rules: []const acl.Rule = &[_]acl.Rule{},
};

pub const Backend = struct {
    name: []const u8,
    servers: []const Server,
};

pub const Server = struct {
    host: []const u8,
    port: u16,
    weight: u8 = 1,
};

/// Loads config from file.
/// Returns a Parsed config wrapper using an internal Arena.
/// Caller must call .deinit() on the result.
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Config) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buf);

    _ = try file.readAll(buf);

    return std.json.parseFromSlice(Config, allocator, buf, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}
