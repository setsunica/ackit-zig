const std = @import("std");
const log = std.log.scoped(.ackit);
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArgIterator = std.process.ArgIterator;
const io_impl = @embedFile("../io.zig");
const temp_text = @embedFile("temp.txt");
const Dir = std.fs.Dir;
const clap = @import("clap");

pub const TempCmdError = error{
    NoOutputPathSpecified,
    OutputDirectoryPathUnidentified,
};

pub const TempCmd = struct {
    arena: ArenaAllocator,
    output_path: []const u8,

    fn init(allocator: Allocator, output_path: []const u8) TempCmd {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .output_path = output_path,
        };
    }

    pub fn deinit(self: TempCmd) void {
        self.arena.deinit();
    }

    pub fn run(self: *TempCmd) !void {
        var allocator = self.arena.allocator();
        const cwd = std.fs.cwd();

        const out_file_path = if (std.fs.path.isAbsolute(self.output_path))
            try std.fs.path.resolve(allocator, &[_][]const u8{self.output_path})
        else blk: {
            const current = try cwd.realpathAlloc(allocator, "");
            break :blk try std.fs.path.join(allocator, &[_][]const u8{ current, self.output_path });
        };

        if (std.fs.path.dirname(out_file_path)) |dir_path|
            std.fs.makeDirAbsolute(dir_path) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            }
        else {
            log.err(
                "The directory path for the specified file [{s}] could not be identified.",
                .{self.output_path},
            );
            return error.OutputDirectoryPathUnidentified;
        }

        const out_file = try std.fs.createFileAbsolute(out_file_path, .{});
        defer out_file.close();
        var out_buffer = std.io.bufferedWriter(out_file.writer());
        const out_writer = out_buffer.writer();
        const io_test_index = std.mem.indexOf(u8, io_impl, "// Below is the test code.").?;
        var io_impl_trimed = io_impl[0..io_test_index];
        io_impl_trimed = try std.mem.replaceOwned(u8, allocator, io_impl_trimed,
            \\const std = @import("std");
        , "");
        io_impl_trimed = try std.mem.replaceOwned(u8, allocator, io_impl_trimed, "\n", "");
        io_impl_trimed = try std.mem.replaceOwned(u8, allocator, io_impl_trimed, "  ", " ");
        io_impl_trimed = try std.mem.replaceOwned(u8, allocator, io_impl_trimed, "  ", " ");
        const output = try std.mem.replaceOwned(u8, allocator, temp_text, "{{IO_IMPL}}", io_impl_trimed);
        try out_writer.writeAll(output);
        try out_buffer.flush();
        log.info("Template file `{s}` has been created.", .{out_file_path});
        return;
    }
};

const options =
    \\-h, --help    Display this help.
;

const params = clap.parseParamsComptime(options ++
    \\<str>
    \\
);

fn printUsage() !void {
    log.info(
        \\Usage: ackit temp <output_path> [option]
        \\
        \\Options:
        \\    {s}
        \\
    , .{options});
}

pub fn parse(allocator: Allocator, args: *ArgIterator) !?TempCmd {
    const stderr = std.io.getStdErr().writer();
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &params,
        clap.parsers.default,
        args,
        .{ .diagnostic = &diag, .allocator = allocator },
    ) catch |err| {
        try printUsage();
        try diag.report(stderr, err);
        return null;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printUsage();
        return null;
    }

    if (res.positionals.len <= 0) {
        try printUsage();
        log.err("The output parameter is required.", .{});
        return TempCmdError.NoOutputPathSpecified;
    }
    return TempCmd.init(allocator, res.positionals[0]);
}
