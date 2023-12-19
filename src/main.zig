const std = @import("std");
const tp = @import("tp.zig");

const Input = struct { s: []const u8 };

pub fn main() !void {
    var allocator = std.heap.page_allocator;
    const stdin_file = std.io.getStdIn().reader();
    const stdout_file = std.io.getStdOut().writer();
    var br = std.io.bufferedReader(stdin_file);
    var bw = std.io.bufferedWriter(stdout_file);
    const stdin = br.reader();
    const stdout = bw.writer();
    const s = try stdin.readAllAlloc(allocator, 1024 * 1024 * 512);
    var input = try tp.parse(Input, allocator, s);
    defer input.deinit();
    try stdout.print("{any}", .{input.value});
    try bw.flush();
}
