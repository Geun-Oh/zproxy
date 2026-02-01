const std = @import("std");
const Config = @import("../config.zig").Config;
const Server = @import("../config.zig").Server;
const Backend = @import("../config.zig").Backend;

pub const Loadbalancer = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    // Maps backend_name -> current_server_index
    backend_indicies: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator, config: *const Config) !Loadbalancer {
        var self = Loadbalancer{
            .allocator = allocator,
            .config = config,
            .backend_indicies = std.StringHashMap(usize).init(allocator),
        };

        for (config.backends) |b| {
            try self.backend_indicies.put(b.name, 0);
        }
        return self;
    }

    pub fn deinit(self: *Loadbalancer) void {
        self.backend_indicies.deinit();
    }

    /// Decide backend based on Host headeer, otherwise use default
    pub fn route(self: *Loadbalancer, default_backend: []const u8, host_header: []const u8) ?Server {
        _ = host_header;

        return self.get_next_server(default_backend);
    }

    pub fn get_next_server(self: *Loadbalancer, backend_name: []const u8) ?Server {
        // 1. Find backend
        var backend: ?Backend = null;
        for (self.config.backends) |b| {
            if (std.mem.eql(u8, b.name, backend_name)) {
                backend = b;
                break;
            }
        }

        const bk = backend orelse return null;
        if (bk.servers.len == 0) return null;

        // 2. Get & Update Index (Round Robin)
        // Use getPtr so it can mod the value in the map
        if (self.backend_indicies.getPtr(backend_name)) |idx_ptr| {
            const current = idx_ptr.*;
            idx_ptr.* = (current + 1) % bk.servers.len;
            return bk.servers[current];
        } else {
            // Should verify in init, but safe fallback
            return bk.servers[0];
        }
    }
};
