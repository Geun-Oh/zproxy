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

const ListenerContext = struct {
    listener: Listener,
    default_backend: []const u8,
};

const Engine = struct {
    poller: Poller,
    scheduler: Scheduler,

    // Owns the listener contexts (for memory management)
    listeners: std.ArrayList(*ListenerContext),
    // Optimization: Fast lookup to distinguish Listener events for Session Events
    listener_map: std.AutoHashMap(?*anyopaque, *ListenerContext),

    config: std.json.Parsed(Config),
    load_balancer: Loadbalancer,
    running: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        const parsed_config = try @import("config.zig").loadFromFile(allocator, CONFIG_FILE_PATH);

        var lb = try Loadbalancer.init(allocator, &parsed_config.value);

        var listeners: std.ArrayList(*ListenerContext) = .{};
        var listener_map = std.AutoHashMap(?*anyopaque, *ListenerContext).init(allocator);

        errdefer {
            for (listeners.items) |ctx| {
                ctx.listener.deinit();
                allocator.destroy(ctx);
            }
            listeners.deinit(allocator);
            listener_map.deinit();
            lb.deinit();

            parsed_config.deinit();
        }

        for (parsed_config.value.frontends) |fe| {
            // Alloc ctx on heap
            const ctx = try allocator.create(ListenerContext);
            ctx.listener = try Listener.init(fe.bind_port);
            ctx.default_backend = fe.backend_name;

            try listeners.append(allocator, ctx);
            try listener_map.put(@ptrCast(ctx), ctx);
        }

        return Engine{
            .poller = try Poller.init(allocator),
            .scheduler = Scheduler.init(allocator),
            .listeners = listeners,
            .listener_map = listener_map,
            .config = parsed_config,
            .load_balancer = lb,
            .running = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Engine, gpa: std.mem.Allocator) void {
        self.poller.deinit();

        for (self.listeners.items) |ctx| {
            ctx.listener.deinit();
            self.allocator.destroy(ctx);
        }
        self.listeners.deinit(gpa);
        self.listener_map.deinit();

        self.load_balancer.deinit();
        self.config.deinit();
    }

    pub fn run(self: *Engine) !void {
        fprint("[Engine] Start Loop...\n", .{});

        // Register listener
        for (self.listeners.items) |ctx| {
            try self.poller.register(ctx.listener.fd, .{ .readable = true }, ctx);
            fprint("[Engine] Listening on port {} (backend: {s})\n", .{ ctx.listener.port, ctx.default_backend });
        }

        while (self.running) {
            const timeout_ns = self.scheduler.next_timeout_ns();
            const effective_timeout = timeout_ns orelse 1_000_000_000;
            const events = try self.poller.poll(effective_timeout);

            for (events) |ev| {
                fprint("[EventLoop] Event fd={} ctx={any}\n", .{ ev.fd, ev.context });

                // O(1) check if this event belongs to a Listener
                if (self.listener_map.get(ev.context)) |listener_ctx| {
                    if (ev.readable) {
                        // Case 1: New Connection on Listener
                        const client_fd = listener_ctx.listener.accept() catch |err| {
                            fprint("[Listener] Accept error: {}\n", .{err});
                            continue;
                        };
                        fprint("[Listener] Accepted connection fd={}\n", .{client_fd});

                        const session = try Session.init(self.allocator, client_fd);

                        // Inject default backend info from the listener context
                        session.default_backend = listener_ctx.default_backend;

                        // Wait until client sends data (L7 Lazy handshake)
                        try self.poller.register(client_fd, .{ .readable = true }, session);
                    }
                } else {
                    // Case 2: Existing Session Event (or somthing else)
                    if (ev.context) |ctx| {
                        fprint("[EventLoop] Dispatching to Session ctx={any}\n", .{ctx});
                        const session: *Session = @ptrCast(@alignCast(ctx));

                        session.handle_event(ev.fd, ev.readable, ev.writable, &self.poller, &self.load_balancer) catch |err| {
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

                // Deprecated
                // if (ev.context == @as(?*anyopaque, @ptrCast(&self.listener))) {
                //     if (ev.readable) {
                //         const client_fd = self.listener.accept() catch |err| {
                //             fprint("[Listener] Accept error: {}\n", .{err});
                //             continue;
                //         };
                //         fprint("[Listener] Accepted connection fd={}\n", .{client_fd});

                //         const session = try Session.init(self.allocator, client_fd);

                //         // Wait until client sends data for L7 Handshake
                //         try self.poller.register(client_fd, .{ .readable = true }, session);
                //     }
                // } else {
                //     if (ev.context) |ctx| {
                //         const session: *Session = @ptrCast(@alignCast(ctx));
                //         session.handle_event(ev.fd, ev.readable, ev.writable, &self.poller, &self.load_balancer) catch |err| {
                //             switch (err) {
                //                 error.ClientClosed, error.ServerClosed => {
                //                     fprint("[Session] Closed gracefully: {}\n", .{err});
                //                 },
                //                 else => {
                //                     fprint("[Session] Closed/Error: {}\n", .{err});
                //                 },
                //             }
                //             session.deinit();
                //         };
                //     }
                // }
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
    defer engine.deinit(allocator); // Listener needs deinit, strictly speaking

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
