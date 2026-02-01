const std = @import("std");
const os = std.os;
const posix = std.posix;
const assert = std.debug.assert;

pub const EventMask = struct {
    readable: bool = false,
    writable: bool = false,
};

pub const Event = struct {
    fd: posix.fd_t,
    readable: bool,
    writable: bool,
    context: ?*anyopaque,
};

pub const Poller = struct {
    kq: posix.fd_t,
    allocator: std.mem.Allocator,
    changes: std.ArrayList(posix.Kevent) = .{},
    events: [1024]posix.Kevent,
    out_events: [1024]Event = undefined,

    pub fn init(allocator: std.mem.Allocator) !Poller {
        const kq = try posix.kqueue();
        return Poller{
            .kq = kq,
            .allocator = allocator,
            .changes = .{},
            .events = undefined,
        };
    }

    pub fn deinit(self: *Poller) void {
        self.changes.deinit(self.allocator);
        posix.close(self.kq);
    }

    pub fn register(self: *Poller, fd: posix.fd_t, mask: EventMask, context: ?*anyopaque) !void {
        const flags: u16 = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.CLEAR;

        if (mask.readable) {
            try self.changes.append(self.allocator, .{
                .ident = @intCast(fd),
                .filter = posix.system.EVFILT.READ,
                .flags = flags,
                .fflags = 0,
                .data = 0,
                .udata = @intFromPtr(context),
            });
        }

        if (mask.writable) {
            try self.changes.append(self.allocator, .{
                .ident = @intCast(fd),
                .filter = posix.system.EVFILT.WRITE,
                .flags = flags,
                .fflags = 0,
                .data = 0,
                .udata = @intFromPtr(context),
            });
        }
    }

    pub fn poll(self: *Poller, timeout_ns: ?u64) ![]const Event {
        var ts: posix.timespec = undefined;
        var ts_ptr: ?*posix.timespec = null;

        if (timeout_ns) |ns| {
            ts.sec = @intCast(ns / 1_000_000_000);
            ts.nsec = @intCast(ns % 1_000_000_000);
            ts_ptr = &ts;
        }

        const events_count = try posix.kevent(self.kq, self.changes.items, &self.events, ts_ptr);
        self.changes.clearRetainingCapacity();

        var out_idx: usize = 0;
        for (self.events[0..events_count]) |ev| {
            const is_read = (ev.filter == posix.system.EVFILT.READ);
            const is_write = (ev.filter == posix.system.EVFILT.WRITE);

            self.out_events[out_idx] = Event{
                .fd = @intCast(ev.ident),
                .readable = is_read,
                .writable = is_write,
                .context = @ptrFromInt(ev.udata),
            };
            out_idx += 1;
        }

        return self.out_events[0..out_idx];
    }
};
