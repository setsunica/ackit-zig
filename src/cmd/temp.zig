const std = @import("std");
const log = std.log.scoped(.ackit);
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArgIterator = std.process.ArgIterator;
const temp_text = @embedFile("temp.txt");
const io_impl = @embedFile("../io.zig");
const dp_impl = @embedFile("../dp.zig");
const Dir = std.fs.Dir;
const clap = @import("clap");

pub const TempCmdError = error{
    NoOutputPathSpecified,
    OutputDirectoryPathUnidentified,
};

fn minifyOwned(allocator: Allocator, content: []const u8) ![]u8 {
    const replaced = try std.mem.replaceOwned(u8, allocator, content, "\n", "");
    return std.mem.collapseRepeats(u8, replaced, ' ');
}

fn appendImport(allocator: Allocator, temp: []const u8, lib_name: []const u8, impl: []const u8) ![]u8 {
    const import_temp =
        \\const {s} = struct {{ {s} }};
    ;
    const import_off_index = std.mem.indexOf(u8, impl, "// ackit import: off").?;
    const impl_content = impl[0..import_off_index];
    var result = try std.mem.replaceOwned(u8, allocator, impl_content,
        \\const std = @import("std");
    , "");
    result = try minifyOwned(allocator, result);
    result = try std.fmt.allocPrint(allocator, import_temp, .{ lib_name, result });
    return try std.mem.concat(allocator, u8, &.{ temp, "\n", result });
}

pub const TempCmd = struct {
    arena: ArenaAllocator,
    output_path: []const u8,
    import_dp: bool,

    fn init(allocator: Allocator, output_path: []const u8, import_dp: bool) TempCmd {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .output_path = output_path,
            .import_dp = import_dp,
        };
    }

    pub fn deinit(self: TempCmd) void {
        self.arena.deinit();
    }

    pub fn run(self: *TempCmd) !void {
        const allocator = self.arena.allocator();
        const cwd = std.fs.cwd();

        const out_file_path = if (std.fs.path.isAbsolute(self.output_path))
            try std.fs.path.resolve(allocator, &[_][]const u8{self.output_path})
        else blk: {
            const current = try cwd.realpathAlloc(allocator, ".");
            log.debug("current=`{s}`", .{current});
            break :blk try std.fs.path.join(allocator, &[_][]const u8{ current, self.output_path });
        };
        log.debug("out_file_path=`{s}`", .{out_file_path});

        if (std.fs.path.dirname(out_file_path)) |dir_path|
            std.fs.makeDirAbsolute(dir_path) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            }
        else {
            log.err(
                "The directory path for the specified file `{s}` could not be identified.",
                .{self.output_path},
            );
            return error.OutputDirectoryPathUnidentified;
        }

        const out_file = try std.fs.createFileAbsolute(out_file_path, .{});
        defer out_file.close();
        var out_buffer = std.io.bufferedWriter(out_file.writer());
        const out_writer = out_buffer.writer();
        var output = try appendImport(allocator, temp_text, "ackitio", io_impl);

        if (self.import_dp) {
            output = try appendImport(allocator, output, "dp", dp_impl);
        }

        try out_writer.writeAll(output);
        try out_buffer.flush();
        log.info("Template file `{s}` has been created.", .{out_file_path});
    }
};

const options =
    \\    -h, --help    Display this help.
    \\        --dp      Imports dynamic planning libraries.
;

const params = clap.parseParamsComptime(options ++
    \\
    \\<str>
    \\
);

fn printUsage() !void {
    log.info(
        \\Usage: ackit temp <output_path> [option]
        \\
        \\Options:
        \\{s}
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

    const import_db = res.args.dp == 1;
    return TempCmd.init(allocator, res.positionals[0], import_db);
}
