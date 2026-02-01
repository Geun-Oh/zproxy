const std = @import("std");

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpRequest = struct {
    method: []const u8,
    uri: []const u8,
    version: []const u8,
    headers: []HttpHeader,
};

pub const ParseError = error{
    Incomplete,
    InvalidFormat,
};

/// Simple Zero-Copy HTTP/1.1 Request parser
/// Returns parsed request slices pointing to the input buffer.
/// If headers are not fully received, returns error.Incomplete
pub fn parse_request(allocator: std.mem.Allocator, buffer: []const u8) !HttpRequest {
    // 1. Check for double CRLF (End of Headers)
    const end_of_headers = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse return ParseError.Incomplete;

    const header_part = buffer[0..end_of_headers];

    var iter = std.mem.splitSequence(u8, header_part, "\r\n");

    const request_line = iter.next() orelse return ParseError.InvalidFormat;
    var req_line_iter = std.mem.splitSequence(u8, request_line, " ");

    const method = req_line_iter.next() orelse return ParseError.InvalidFormat;
    const uri = req_line_iter.next() orelse return ParseError.InvalidFormat;
    const version = req_line_iter.next() orelse return ParseError.InvalidFormat;

    var headers: std.ArrayList(HttpHeader) = .{};

    while (iter.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.indexOfScalar(u8, line, ':')) |colon_idx| {
            const name = std.mem.trim(u8, line[0..colon_idx], " ");
            const value = std.mem.trim(u8, line[colon_idx + 1 ..], " ");
            try headers.append(allocator, .{ .name = name, .value = value });
        }
    }

    return HttpRequest{
        .method = method,
        .uri = uri,
        .version = version,
        .headers = try headers.toOwnedSlice(allocator),
    };
}
