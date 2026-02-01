const std = @import("std");

pub const Config = struct {
    frontends: std.ArrayList(Frontend),
    backends: std.ArrayList(Backend),

    pub fn deinit(self: *Config) void {
        self.frontends.deinit();
        self.backends.deinit();
    }
};

pub const Frontend = struct {
    name: []const u8,
    bind_address: []const u8 = "0.0.0.0",
    bind_port: u16,
    backend_name: []const u8,
};

pub const Backend = struct {
    name: []const u8,
    servers: std.ArrayList(Server),

    pub fn deinit(self: *Backend) void {
        self.servers.deinit();
    }
};

pub const Server = struct {
    host: []const u8,
    port: u16,
    weight: u8 = 1,
};
