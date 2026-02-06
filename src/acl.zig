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
};

/// *.json need to parse union(enum) with special parsing format in Zig.
pub const Action = struct {
    action_type: ActionType,
    backend: ?[]const u8 = null, // Only used when action_type == .use_backend
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
                .exact, .ip => if (std.mem.eql(u8, target, pattern)) return true,
                .beg => if (std.mem.startsWith(u8, target, pattern)) return true,
                .end => if (std.mem.endsWith(u8, target, pattern)) return true,
                .sub => if (std.mem.indexOf(u8, target, pattern) != null) return true,
                .reg => return false, // Regex TODO
            }
        }

        return false;
    }
};
