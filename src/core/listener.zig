const std = @import("std");
const posix = std.posix;
const Poller = @import("poller.zig").Poller;

pub const Listener = struct {
    fd: posix.fd_t,
    port: u16,

    pub fn init(port: u16) !Listener {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        errdefer posix.close(fd);

        // SO_REUSEADDR is crucial for restarting quickly
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        // Generic bind to 0.0.0.0
        const addr = try std.net.Address.parseIp4("0.0.0.0", port);
        try posix.bind(fd, &addr.any, addr.getOsSockLen());

        try posix.listen(fd, 128); // backlog

        return Listener{
            .fd = fd,
            .port = port,
        };
    }

    pub fn register(self: *Listener, poller: *Poller) !void {
        try poller.register(self.fd, .{ .readable = true }, self);
    }

    pub fn accept(self: *Listener) !struct { fd: posix.fd_t, address: std.net.Address } {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const client_fd = try posix.accept(self.fd, &addr, &addr_len, 0);

        const address = std.net.Address.initPosix(@alignCast(&addr));

        return .{ .fd = client_fd, .address = address };
    }

    pub fn deinit(self: *Listener) void {
        posix.close(self.fd);
    }
};
