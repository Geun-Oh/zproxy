const std = @import("std");
const posix = std.posix;
const Connection = @import("connection.zig").Connection;
const Poller = @import("poller.zig").Poller;
const http1 = @import("proto/http1.zig");
const LoadBalancer = @import("load_balancer.zig").Loadbalancer;

pub const Session = struct {
    const BufferSize = 16 * 1024;
    const State = enum {
        Init, // Created, waiting for next step
        Handshake, // L7 mode, Buffering & Parsing HTTP
        Pipe, // L4 Mode, Streaming data bidirectionally
        Closed,
    };

    allocator: std.mem.Allocator,
    client: Connection,
    server: ?Connection = null,

    // Buffer for parsing or forwarding
    buf: [BufferSize]u8 = undefined,
    buf_len: usize = 0, // Used during handshake buffering

    // Initialize state
    state: State = .Init,

    pub fn init(allocator: std.mem.Allocator, client_fd: posix.fd_t) !*Session {
        const self = try allocator.create(Session);
        self.* = Session{
            .allocator = allocator,
            .client = Connection.init(client_fd, allocator),
            .server = null,
            .buf_len = 0,
            // Initialize state
            .state = .Init,
        };
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.client.close();
        if (self.server) |*s| s.close();
        self.allocator.destroy(self);
        // Change state to closed
        self.state = .Closed;
    }

    /// L4 Mode Entry: Connect immediately.
    /// State becomes Pipe.
    pub fn connect_backend_l4(self: *Session, poller: *Poller, host: []const u8, port: u16) !void {
        try self.connect_backend_raw(poller, host, port);

        // Start piping immediately
        // Change state to pipe
        self.state = .Pipe;
    }

    /// Internal Helper: Just established TCP connection
    fn connect_backend_raw(self: *Session, poller: *Poller, host: []const u8, port: u16) !void {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        const svr = Connection.init(fd, self.allocator);
        self.server = svr;

        const addr = try std.net.Address.parseIp4(host, port);

        // Blocking connect for now (Should be non-blocking in production)
        try posix.connect(fd, &addr.any, addr.getOsSockLen());

        // Register both
        try poller.register(self.client.fd, .{ .readable = true }, self);
        // Note: Client might be already registered by main.zig, but duplications are usually handled or init logic needs care.
        // Usually main.zig registers LISTENER. When accepted, new FD is NOT registered until here or explicitly.

        try poller.register(self.server.?.fd, .{ .readable = true }, self);
    }

    // Main Event Handler
    pub fn handle_event(self: *Session, fd: posix.fd_t, readable: bool, writable: bool, poller: *Poller, lb: *LoadBalancer) !void {
        _ = writable;

        // If we are in Init state (L7 mode started but not data yet), switch to Handshake
        if (self.state == .Init) {
            // Change state to Handshake
            self.state = .Handshake;
        }

        if (self.state == .Handshake) {
            // L7 Logic: Read Client -> Parse -> Conn Server -> Switch to Pipe
            if (readable and fd == self.client.fd) {
                // 1. Read into buffer
                const n = try self.client.read(self.buf[self.buf_len..]);
                if (n == 0) return error.ClientClosed;
                self.buf_len += n;

                // 2. Try Parse
                const req = http1.parse_request(self.allocator, self.buf[0..self.buf_len]) catch |err| {
                    if (err == error.Incomplete) {
                        if (self.buf_len == BufferSize) return error.HeaderTooLarge;
                        return; // Wait for more data
                    }

                    return err;
                };
                defer self.allocator.free(req.headers);

                // 3. Routing (Parse Host header later)
                const backend_name: []const u8 = "web_back"; // Default fallback

                for (req.headers) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "host")) {
                        // Extract Host (remove port if exists)
                        const host_val = if (std.mem.indexOfScalar(u8, h.value, ':')) |colon| h.value[0..colon] else h.value;

                        std.debug.print("[Session] Host: {s}\n", .{host_val});

                        if (std.mem.eql(u8, host_val, "127.0.0.1")) {}
                        break;
                    }
                }

                if (lb.get_next_server(backend_name)) |server| {
                    try self.connect_backend_raw(poller, server.host, server.port);

                    // 4. Flush buffered request to server
                    if (self.server) |*s| {
                        _ = try s.write(self.buf[0..self.buf_len]);
                    }

                    // Change state to Pipe
                    self.state = .Pipe;
                } else {
                    return error.NoBackend;
                }
            }
        } else if (self.state == .Pipe) {
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
    }
};
