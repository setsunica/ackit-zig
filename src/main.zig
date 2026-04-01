const std = @import("std");
const builtin = @import("builtin");
const heap = std.heap;
const log = std.log.scoped(.ackit);
const Allocator = std.mem.Allocator;
const ArgIterator = std.process.ArgIterator;
const cmd = @import("cmd.zig");

pub fn main() !void {
    var da: heap.DebugAllocator(.{}) = .init;
    var sfa = heap.stackFallback(4096, heap.page_allocator);

    const allocator, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ da.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ sfa.get(), false },
    };

    defer {
        if (is_debug) _ = da.deinit();
    }

    var args = try ArgIterator.initWithAllocator(allocator);
    defer args.deinit();

    if (!args.skip()) {
        @panic("0th argument should have been the executable file path, but none was passed");
    }

    var c = cmd.parse(allocator, &args) catch |err| {
        switch (err) {
            error.NoCmd => {
                try cmd.printUsage();
                return log.err("Please specify what the command is.", .{});
            },
            error.InvalidCmd => {
                try cmd.printUsage();
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
