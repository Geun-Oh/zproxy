const std = @import("std");
const net = std.net;
const posix = std.posix;

pub const Connection = struct {
    fd: posix.fd_t,
    allocator: std.mem.Allocator,
    address: net.Address,

    // Can use a fixed buffer or dynamic one.
    // For zero-copy, we might want to pass pointers, but for simple proxying,
    // Assume read into a buffer and write from it.
    // However, HAProxy uses "Zero-Copy" via splice or similar,
    // but in pure Zig userspace without splicing, it need a buffer.
    // Stick to a simple buffer for now.

    // Actually, Session will manage the buffer to move data Client->Server.
    // Connection just wraps the FD ops.

    pub fn init(fd: posix.fd_t, allocator: std.mem.Allocator, address: net.Address) Connection {
        return Connection{
            .fd = fd,
            .allocator = allocator,
            .address = address,
        };
    }

    pub fn close(self: *Connection) void {
        posix.close(self.fd);
    }

    pub fn read(self: *Connection, buffer: []u8) !usize {
        return posix.read(self.fd, buffer);
    }

    pub fn write(self: *Connection, buffer: []const u8) !usize {
        return posix.write(self.fd, buffer);
    }
};
