const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;
const ArgIterator = std.process.ArgIterator;
const cmd = @import("cmd.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const stderr = std.io.getStdErr().writer();
    var args = try ArgIterator.initWithAllocator(allocator);
    defer args.deinit();

    if (!args.skip()) {
        @panic("0th argument should have been the executable file path, but none was passed");
    }

    var c = cmd.parse(allocator, &args) catch |err| {
        switch (err) {
            error.NoCmd => {
                try cmd.printUsage(stderr);
                return log.err("Please specify what the command is.", .{});
            },
            error.InvalidCmd => {
                try cmd.printUsage(stderr);
                return log.err("The specified command is invalid.", .{});
            },
            else => return log.err("Failed to parse args: {}", .{err}),
        }
    } orelse return;

    defer c.deinit();

    c.run() catch |err| {
        log.err("Failed to command `{s}`: {}", .{ c.name, err });
    };
}
