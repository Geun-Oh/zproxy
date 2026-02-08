const std = @import("std");
const net = std.net;
const posix = std.posix;

pub const FetchMethod = enum {
    src,
    path,
    method,
    hdr,
};

pub const MatchMethod = enum {
    exact,
    beg, // prefix
    end, // suffix
    sub, // substring
    reg, // regex
    ip, // CIDR
};

pub const ActionType = enum {
    allow,
    deny,
    use_backend,
    set_path,
};

/// *.json need to parse union(enum) with special parsing format in Zig.
pub const Action = struct {
    action_type: ActionType,
    backend: ?[]const u8 = null, // Only used when action_type == .use_backend
    value: ?[]const u8 = null, // Used for set-path
};

pub const Rule = struct {
    action: Action,

    /// Name of the ACL to check.
    /// If null, the rule applies unconditionally (unless we support AND/OR later).
    condition: ?[]const u8 = null,
};

pub const HeaderMapContext = struct {
    ptr: *const anyopaque,
    get_fn: *const fn (ptr: *const anyopaque, name: []const u8) ?[]const u8,

    /// Pass by value to allow calling on const Context
    pub fn get(self: HeaderMapContext, name: []const u8) ?[]const u8 {
        return self.get_fn(self.ptr, name);
    }
};

pub const Context = struct {
    client_ip: net.Address,
    path: []const u8,
    method: []const u8,
    headers: HeaderMapContext,
};

pub const ACL = struct {
    name: []const u8,
    fetch: FetchMethod,
    fetch_arg: ?[]const u8 = null,
    match_method: MatchMethod,
    values: []const []const u8,

    pub fn match(self: *const ACL, ctx: *const Context) bool {
        var buf: [64]u8 = undefined;

        const val: []const u8 = switch (self.fetch) {
            .src => blk: {
                switch (ctx.client_ip.any.family) {
                    posix.AF.INET => {
                        // Extract IP bytes directly (network byte order)
                        const addr_bytes = @as(*const [4]u8, @ptrCast(&ctx.client_ip.in.sa.addr));
                        const written = std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{
                            addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3],
                        }) catch return false;
                        break :blk written;
                    },
                    else => return false, // IPv6 TODO
                }
            },
            .path => ctx.path,
            .method => ctx.method,
            .hdr => if (self.fetch_arg) |arg| ctx.headers.get(arg) orelse return false else return false,
        };

        return self.matchString(val);
    }

    fn matchString(self: *const ACL, target: []const u8) bool {
        for (self.values) |pattern| {
            switch (self.match_method) {
                .exact => if (std.mem.eql(u8, target, pattern)) return true,
                .ip => {
                    // Parse target IP to u32
                    const target_ip = parseIpToU32(target) orelse continue;
                    // Check if pattern is CIDR or exact IP
                    if (std.mem.indexOfScalar(u8, pattern, '/') != null) {
                        // CIDR matching
                        if (Cidr.parse(pattern)) |cidr| {
                            if (cidr.contains(target_ip)) return true;
                        }
                    } else {
                        // Exact IP match
                        if (parseIpToU32(pattern)) |pattern_ip| {
                            if (target_ip == pattern_ip) return true;
                        }
                    }
                },
                .beg => if (std.mem.startsWith(u8, target, pattern)) return true,
                .end => if (std.mem.endsWith(u8, target, pattern)) return true,
                .sub => if (std.mem.indexOf(u8, target, pattern) != null) return true,
                .reg => return false, // Regex TODO
            }
        }

        return false;
    }
};

pub const Cidr = struct {
    addr: u32, // Network Address
    mask: u32, // Subnet Mask

    pub fn parse(s: []const u8) ?Cidr {
        const slash_idx = std.mem.indexOfScalar(u8, s, '/') orelse return null;

        const ip_str = s[0..slash_idx];
        const prefix_str = s[slash_idx + 1 ..];

        const prefix_len = std.fmt.parseInt(u5, prefix_str, 10) catch return null;

        var parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, ip_str, '.');
        var i: usize = 0;
        while (iter.next()) |part| : (i += 1) {
            if (i >= 4) return null;
            parts[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        }

        if (i != 4) return null;

        const addr: u32 = (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) | (@as(u32, parts[2]) << 8) | @as(u32, parts[3]);
        const mask: u32 = if (prefix_len == 0) 0 else (@as(u32, 0) >> @intCast(prefix_len));

        return Cidr{ .addr = addr & mask, .mask = mask };
    }

    pub fn contains(self: Cidr, ip: u32) bool {
        return (ip & self.mask) == self.addr;
    }
};

fn parseIpToU32(s: []const u8) ?u32 {
    var parts: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;

    while (iter.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        parts[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }

    if (i != 4) return null;

    return (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) | (@as(u32, parts[2]) << 8) | @as(u32, parts[3]);
}

pub fn evaluateCondition(
    condition: []const u8,
    acls: []const ACL,
    ctx: *const Context,
) bool {
    var iter = std.mem.tokenizeScalar(u8, condition, ' ');

    while (iter.next()) |token| {
        const negated = token[0] == '!';
        const acl_name = if (negated) token[1..] else token;

        // Find and eval ACL
        var acl_matched = false;
        for (acls) |*a| {
            if (std.mem.eql(u8, a.name, acl_name)) {
                acl_matched = a.match(ctx);
                break;
            }
        }

        if (negated) acl_matched = !acl_matched;

        if (!acl_matched) return false;
    }

    return true;
}
