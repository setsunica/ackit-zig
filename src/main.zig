const std = @import("std");
const io = @import("io.zig");

const Input = struct { s: []const u8 };
const Output = struct { s: []const u8 };

fn solve(input: Input, printer: *io.StdOutPrinter) !void {
    const output = .{ .s = input.s };
    try printer.print(output);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const input_max_size = 1024 * 1024 * 512;
    try io.interactStdIO(Input, gpa.allocator(), input_max_size, solve);
}
