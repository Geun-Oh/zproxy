const std = @import("std");
const ebtree = @import("core/ebtree.zig");
const SchedulerContext = @import("core/scheduler.zig").Context(ebtree.EB64Tree);
const Scheduler = SchedulerContext.Scheduler;
const Task = SchedulerContext.Task;

var tasks_completed: usize = 0;

fn benchTask(ctx: ?*anyopaque) void {
    _ = ctx;
    tasks_completed += 1;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);

    const task_count = 1_000_000;
    fprint("Running benchmark with {d} tasks...\n", .{task_count});

    // Pre-allocate tasks to measure pure scheduling/execution performance
    // and not allocation overhead, although allocation is part of the cost usually.
    // For this bench, we want to separate them.
    const tasks = try allocator.alloc(Task, task_count);
    defer allocator.free(tasks);

    // 1. Benchmark Scheduling
    const start_schedule = std.time.nanoTimestamp();
    for (tasks) |*t| {
        t.* = Task{
            .node = undefined,
            .callback = benchTask,
            .context = null,
        };
        // Schedule for immediate execution (0ms)
        scheduler.schedule(t, 0);
    }
    const end_schedule = std.time.nanoTimestamp();
    const schedule_duration = @as(f64, @floatFromInt(end_schedule - start_schedule)) / 1_000_000.0;

    fprint("Scheduling took: {d:.2} ms ({d:.2} ops/sec)\n", .{ schedule_duration, @as(f64, @floatFromInt(task_count)) / (schedule_duration / 1000.0) });

    // 2. Benchmark Execution
    const start_exec = std.time.nanoTimestamp();

    // Process until all done
    while (tasks_completed < task_count) {
        scheduler.tick();
    }

    const end_exec = std.time.nanoTimestamp();
    const exec_duration = @as(f64, @floatFromInt(end_exec - start_exec)) / 1_000_000.0;

    fprint("Execution took: {d:.2} ms ({d:.2} ops/sec)\n", .{ exec_duration, @as(f64, @floatFromInt(task_count)) / (exec_duration / 1000.0) });
}

fn fprint(comptime fmt: []const u8, args: anytype) void {
    const Holder = struct {
        var buffer: [4096]u8 = undefined;
    };

    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&Holder.buffer);
    const stdout = &stdout_writer.interface;

    stdout.print(fmt, args) catch {};

    stdout.flush() catch {};
}
