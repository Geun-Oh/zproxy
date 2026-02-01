const std = @import("std");
const posix = std.posix;
const Connection = @import("connection.zig").Connection;
const Poller = @import("poller.zig").Poller;

pub const Session = struct {
    const BufferSize = 16 * 1024;

    allocator: std.mem.Allocator,
    client: Connection,
    server: ?Connection = null,

    // Simple state
    connected: bool = false,

    // Buffers
    // Ideally these should be in a memory pool
    buf: [BufferSize]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, client_fd: posix.fd_t) !*Session {
        const self = try allocator.create(Session);
        self.* = Session{
            .allocator = allocator,
            .client = Connection.init(client_fd, allocator),
            .server = null,
            .connected = false,
        };
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.client.close();
        if (self.server) |*s| s.close();
        self.allocator.destroy(self);
    }

    // Connect to backend
    pub fn connect_backend(self: *Session, poller: *Poller, host: []const u8, port: u16) !void {
        // Resolve host? For now assume IPv4 literal or localhost
        // For simplicity, let's hardcode connecting to 127.0.0.1 for the test backend
        // or parse the host if it's an IP.

        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        const svr = Connection.init(fd, self.allocator);
        self.server = svr;

        const addr = try std.net.Address.parseIp4(host, port);

        // Non-blocking connect usually
        // But for blocking simplicity first:
        try posix.connect(fd, &addr.any, addr.getOsSockLen());
        self.connected = true;

        // Register both for reading
        try poller.register(self.client.fd, .{ .readable = true }, self);
        try poller.register(self.server.?.fd, .{ .readable = true }, self);
    }

    pub fn handle_event(self: *Session, fd: posix.fd_t, readable: bool, writable: bool) !void {
        _ = writable; // TODO handle buffering and writing later (flow control)

        if (readable) {
            if (fd == self.client.fd) {
                // Read from client, write to server
                const n = try self.client.read(&self.buf);
                if (n == 0) {
                    // Client closed
                    // TODO: Close session or half-close
                    return error.ClientClosed;
                }

                if (self.server) |*s| {
                    _ = try s.write(self.buf[0..n]);
                }
            } else if (self.server != null and fd == self.server.?.fd) {
                // Read from server, write to client
                const n = try self.server.?.read(&self.buf);
                if (n == 0) {
                    return error.ServerClosed;
                }
                _ = try self.client.write(self.buf[0..n]);
            }
        }
    }
};
