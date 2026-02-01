const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn FixedSizePool(comptime T: type) type {
    return struct {
        const Self = @This();
        const ChunkSize = 64;

        allocator: Allocator,
        free_list: std.ArrayList(*T),
        chunks: std.ArrayList([]T),

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .free_list = std.ArrayList(*T).init(allocator),
                .chunks = std.ArrayList([]T).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.free_list.deinit();
            for (self.chunks.items) |chunk| {
                self.allocator.free(chunk);
            }
            self.chunks.deinit();
        }

        pub fn create(self: *Self) !*T {
            if (self.free_list.items.len > 0) {
                return self.free_list.pop();
            }
            try self.grow();
            return self.free_list.pop();
        }

        pub fn destroy(self: *Self, ptr: *T) void {
            self.free_list.append(ptr) catch {
                @panic("OOM is FixedSizePool.destroy");
            };
        }

        fn grow(self: *Self) !void {
            const chunk = try self.allocator.alloc(T, ChunkSize);
            try self.chunks.append(chunk);

            try self.free_list.ensureTotalCapacity(self.free_list.items.len + ChunkSize);
            var i: usize = 0;
            while (i < ChunkSize) : (i += 1) {
                self.free_list.appendAssumeCapacity(&chunk[i]);
            }
        }
    };
}

pub const SlabAllocator = struct {
    allocator: Allocator,
    pools: [12]FixedSizePool([]u8),
};
