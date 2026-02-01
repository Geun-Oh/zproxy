const std = @import("std");
const memory = @import("memory.zig");

pub fn Context(comptime TimerImpl: type) type {
    return struct {
        pub const Task = struct {
            node: TimerImpl.Node,

            callback: *const fn (ctx: ?*anyopaque) void,
            context: ?*anyopaque,

            pub fn fromNode(node: *TimerImpl.Node) *Task {
                return @fieldParentPtr("node", node);
            }
        };

        pub const Scheduler = struct {
            allocator: std.mem.Allocator,
            timers: TimerImpl,
            prng: std.Random.DefaultPrng,

            pub fn init(allocator: std.mem.Allocator) Scheduler {
                const prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
                return .{
                    .allocator = allocator,
                    .timers = .{},
                    .prng = prng,
                };
            }

            pub fn schedule(self: *Scheduler, task: *Task, delay_ms: u64) void {
                const now = std.time.milliTimestamp();

                task.node.key = @intCast(now + @as(i64, @intCast(delay_ms)));

                if (@hasField(TimerImpl.Node, "priority")) {
                    task.node.priority = self.prng.random().int(u64);
                }

                task.node.left = null;
                task.node.right = null;
                task.node.parent = null;

                self.timers.insert(&task.node);
            }

            pub fn next_timeout_ns(self: *Scheduler) ?u64 {
                const first = self.timers.first() orelse return null;
                const now = std.time.milliTimestamp();
                const deadline = @as(i64, @intCast(first.key));

                const diff = deadline - now;
                if (diff <= 0) return 0; // Expired
                return @as(u64, @intCast(diff)) * 1_000_000; // ms to ns
            }

            pub fn tick(self: *Scheduler) void {
                const now = std.time.milliTimestamp();

                while (self.timers.first()) |node| {
                    if (node.key > @as(u64, @intCast(now))) {
                        break; // not expired
                    }

                    self.timers.delete(node);

                    const task = Task.fromNode(node);
                    (task.callback)(task.context);
                }
            }
        };
    };
}
