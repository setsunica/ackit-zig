const std = @import("std");
const log = std.log;
const Dir = std.fs.Dir;
const ArgIterator = std.process.ArgIterator;

const io_lib = @embedFile("io.zig");
const temp_text = @embedFile("temp.txt");

const Error = error{
    NoOutputPathSpecified,
    OutputDirectoryPathUnidentified,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) @panic("gpa memory leaked");
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var allocator = arena.allocator();

    var args = try ArgIterator.initWithAllocator(allocator);
    defer args.deinit();
    if (!args.skip()) {
        @panic("the first argument should have been the executable file path, but none was passed");
    }

    const path = args.next() orelse {
        log.err("specify the path to create the template file as the first argument", .{});
        return error.OutputPathNotFound;
    };
    log.debug("output file path is {s}", .{path});

    const cwd = std.fs.cwd();
    const out_file_path = if (std.fs.path.isAbsolute(path))
        try std.fs.path.resolve(allocator, &[_][]const u8{path})
    else blk: {
        const current = try cwd.realpathAlloc(allocator, "");
        break :blk try std.fs.path.join(allocator, &[_][]const u8{ current, path });
    };
    log.debug("output file absolute path is {s}", .{out_file_path});

    if (std.fs.path.dirname(out_file_path)) |dir_path|
        std.fs.makeDirAbsolute(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        }
    else {
        log.err("The directory path for the specified file could not be identified.", .{});
        return error.OutputDirectoryPathUnidentified;
    }

    const out_file = try std.fs.createFileAbsolute(out_file_path, .{});
    defer out_file.close();
    var out_buffer = std.io.bufferedWriter(out_file.writer());
    const out_writer = out_buffer.writer();
    const io_test_index = std.mem.indexOf(u8, io_lib, "// Below is the test code.").?;
    var io_impl = io_lib[0..io_test_index];
    io_impl = try std.mem.replaceOwned(u8, allocator, io_impl,
        \\const std = @import("std");
    , "");
    io_impl = try std.mem.replaceOwned(u8, allocator, io_impl, "const testing = std.testing;", "");
    io_impl = try std.mem.replaceOwned(u8, allocator, io_impl, "\n", "");
    io_impl = try std.mem.replaceOwned(u8, allocator, io_impl, "  ", " ");
    io_impl = try std.mem.replaceOwned(u8, allocator, io_impl, "  ", " ");
    const output = try std.mem.replaceOwned(u8, allocator, temp_text, "{{IO_IMPL}}", io_impl);
    try out_writer.writeAll(output);
    try out_buffer.flush();
}
