const std = @import("std");
const io = @import("io.zig");

const Input = struct { s: []const u8 };
const Output = struct { s: []const u8 };

fn solve(input: Input) Output {
    return .{ .s = input.s };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const stdin_file = std.io.getStdIn().reader();
    const stdout_file = std.io.getStdOut().writer();
    var br = std.io.bufferedReader(stdin_file);
    var bw = std.io.bufferedWriter(stdout_file);
    const stdin = br.reader();
    const stdout = bw.writer();
    const input_max_size = 1024 * 1024 * 512;
    try io.interact(Input, Output, gpa.allocator(), stdin, stdout, input_max_size, solve);
    try bw.flush();
}
