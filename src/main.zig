const std = @import("std");
const builtin = @import("builtin");
const Poller = @import("core/poller.zig").Poller;
const ebtree = @import("core/ebtree.zig");
const SchedulerContext = @import("core/scheduler.zig").Context(ebtree.EB64Tree);
const Scheduler = SchedulerContext.Scheduler;
const Task = SchedulerContext.Task;
const Memory = @import("core/memory.zig");

const Listener = @import("core/listener.zig").Listener;

const Engine = struct {
    poller: Poller,
    scheduler: Scheduler,
    listener: Listener,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        return Engine{
            .poller = try Poller.init(allocator),
            .scheduler = Scheduler.init(allocator),
            .listener = try Listener.init(8080),
            .running = true,
        };
    }

    pub fn run(self: *Engine) !void {
        fprint("[Engine] Start Loop...\n", .{});

        // Register listener
        try self.listener.register(&self.poller);

        while (self.running) {
            const timeout_ns = self.scheduler.next_timeout_ns();

            const effective_timeout = timeout_ns orelse 1_000_000_000;

            const events = try self.poller.poll(effective_timeout);

            for (events) |ev| {
                if (ev.context == @as(?*anyopaque, @ptrCast(&self.listener))) {
                    if (ev.readable) {
                        const client_fd = self.listener.accept() catch |err| {
                            fprint("[Listener] Accept error: {}\n", .{err});
                            continue;
                        };
                        fprint("[Listener] Accepted connection fd={}\n", .{client_fd});
                        std.posix.close(client_fd); // Echo/Close for now
                    }
                } else {
                    fprint("[Event] fd={} r={} w={} ctx={any}\n", .{ ev.fd, ev.readable, ev.writable, ev.context });
                }
            }

            self.scheduler.tick();
        }
    }
};

fn myTask(ctx: ?*anyopaque) void {
    fprint("[Task] Executed! Context: {any}\n", .{ctx});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator);
    // defer engine.deinit(); // Listener needs deinit, strictly speaking

    const task_ptr = try allocator.create(Task);
    task_ptr.* = Task{
        .node = undefined,
        .callback = myTask,
        .context = null,
    };

    engine.scheduler.schedule(task_ptr, 2000);

    fprint("[Main] Scheduled task for 2s later. Listening on 8080...\n", .{});

    try engine.run();
}

pub fn fprint(comptime fmt: []const u8, args: anytype) void {
    const Holder = struct {
        var buffer: [4096]u8 = undefined;
    };

    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&Holder.buffer);
    const stdout = &stdout_writer.interface;

    stdout.print(fmt, args) catch {};

    stdout.flush() catch {};
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
