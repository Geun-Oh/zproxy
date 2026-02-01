const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Test 1: ArrayList init and writer
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try list.writer().print("Hello from ArrayList.writer()\n", .{});
    const result = list.items;

    // Test 2: Stdout
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Stdout says: {s}", .{result});

    // Test 3: Check if .empty works and if .print exists
    // Uncommenting this to check compilation:
    // var list2: std.ArrayList(u8) = .empty; // Is this valid for ArrayList?
    // try list2.print(allocator, "Test", .{}); // Does this exist?
}
