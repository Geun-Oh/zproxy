const std = @import("std");
const builtin = @import("builtin");
const Poller = @import("core/poller.zig").Poller;
const ebtree = @import("core/ebtree.zig");
const SchedulerContext = @import("core/scheduler.zig").Context(ebtree.EB64Tree);
const Scheduler = SchedulerContext.Scheduler;
const Task = SchedulerContext.Task;
const Memory = @import("core/memory.zig");

const Listener = @import("core/listener.zig").Listener;
const Session = @import("core/session.zig").Session;
const Config = @import("config.zig").Config;
const Loadbalancer = @import("core/load_balancer.zig").Loadbalancer;

const CONFIG_FILE_PATH = "zproxy.json";

const Engine = struct {
    poller: Poller,
    scheduler: Scheduler,
    listener: Listener,
    config: std.json.Parsed(Config),
    load_balancer: Loadbalancer,
    running: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        const parsed_config = try @import("config.zig").loadFromFile(allocator, CONFIG_FILE_PATH);

        const lb = try Loadbalancer.init(allocator, &parsed_config.value);

        return Engine{
            .poller = try Poller.init(allocator),
            .scheduler = Scheduler.init(allocator),
            .listener = try Listener.init(8080),
            .config = parsed_config,
            .load_balancer = lb,
            .running = true,
            .allocator = allocator,
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

                        const session = try Session.init(self.allocator, client_fd);
                        const backend_name = "web_back"; // TODO: Dynamic from frontend config
                        if (self.load_balancer.get_next_server(backend_name)) |server| {
                            session.connect_backend(&self.poller, server.host, server.port) catch |err| {
                                fprint("[Session] Connect backend error: {}\n", .{err});
                                session.deinit();
                                continue;
                            };
                        } else {
                            fprint("[Engine] No backend server available", .{});
                            session.deinit();
                            continue;
                        }
                    }
                } else {
                    if (ev.context) |ctx| {
                        const session: *Session = @ptrCast(@alignCast(ctx));
                        session.handle_event(ev.fd, ev.readable, ev.writable) catch |err| {
                            switch (err) {
                                error.ClientClosed, error.ServerClosed => {
                                    fprint("[Session] Closed gracefully: {}\n", .{err});
                                },
                                else => {
                                    fprint("[Session] Closed/Error: {}\n", .{err});
                                },
                            }
                            session.deinit();
                        };
                    }
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
