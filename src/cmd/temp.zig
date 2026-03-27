const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const log = std.log.scoped(.ackit);
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArgIterator = std.process.ArgIterator;
const temp_text = @embedFile("temp.txt");
const io_impl = @embedFile("../io.zig");
const dp_impl = @embedFile("../dp.zig");
const Dir = fs.Dir;
const clap = @import("clap");

pub const TempCmdError = error{
    NoOutputPathSpecified,
    OutputDirectoryPathUnidentified,
};

fn minifyOwned(allocator: Allocator, content: []const u8) ![]u8 {
    const replaced = try mem.replaceOwned(u8, allocator, content, "\n", "");
    return mem.collapseRepeats(u8, replaced, ' ');
}

fn appendImport(allocator: Allocator, arr: *std.ArrayList(u8), lib_name: []const u8, impl: []const u8) !void {
    const import_temp =
        \\const {s} = struct {{ {s} }}; 
    ;
    const import_off_index = mem.indexOf(u8, impl, "// ackit import: off").?;
    const impl_content = impl[0..import_off_index];
    const tmp1 = try mem.replaceOwned(u8, allocator, impl_content,
        \\const std = @import("std");
    , "");
    defer allocator.free(tmp1);
    const tmp2 = try minifyOwned(allocator, tmp1);
    defer allocator.free(tmp2);
    const tmp3 = try fmt.allocPrint(allocator, import_temp, .{ lib_name, tmp2 });
    defer allocator.free(tmp3);
    try arr.appendSlice(allocator, tmp3);
}

fn createOutput(allocator: Allocator, import_dp: bool) ![]u8 {
    var arr = std.ArrayList(u8).empty;
    errdefer arr.deinit(allocator);
    try arr.print(allocator, "{s}\n{s}", .{ temp_text, "const ackit = struct {" });
    try appendImport(allocator, &arr, "io", io_impl);

    if (import_dp) {
        try appendImport(allocator, &arr, "dp", dp_impl);
    }
    try arr.appendSlice(allocator, "};");
    return arr.toOwnedSlice(allocator);
}

pub const TempCmd = struct {
    arena: ArenaAllocator,
    output_path: []const u8,
    import_dp: bool,

    fn init(allocator: Allocator, output_path: []const u8, import_dp: bool) TempCmd {
        return .{
            .arena = heap.ArenaAllocator.init(allocator),
            .output_path = output_path,
            .import_dp = import_dp,
        };
    }

    pub fn deinit(self: TempCmd) void {
        self.arena.deinit();
    }

    pub fn run(self: *TempCmd) !void {
        const allocator = self.arena.allocator();
        const cwd = fs.cwd();

        const out_file_path = if (fs.path.isAbsolute(self.output_path))
            try fs.path.resolve(allocator, &[_][]const u8{self.output_path})
        else blk: {
            const current = try cwd.realpathAlloc(allocator, ".");
            log.debug("current=`{s}`", .{current});
            break :blk try fs.path.join(allocator, &[_][]const u8{ current, self.output_path });
        };
        log.debug("out_file_path=`{s}`", .{out_file_path});

        if (fs.path.dirname(out_file_path)) |dir_path|
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

        const out_file = try fs.createFileAbsolute(out_file_path, .{});
        defer out_file.close();
        var buf: [4096]u8 = undefined;
        var out_file_writer = out_file.writer(&buf);
        const writer = &out_file_writer.interface;
        const output = try createOutput(allocator, self.import_dp);
        errdefer allocator.free(output);
        try writer.writeAll(output);
        try writer.flush();
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
    var buf: [4096]u8 = undefined;
    const stderr = fs.File.stderr();
    var stderr_writer = stderr.writer(&buf);
    const writer = &stderr_writer.interface;
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &params,
        clap.parsers.default,
        args,
        .{ .diagnostic = &diag, .allocator = allocator },
    ) catch |err| {
        try printUsage();
        try diag.report(writer, err);
        return null;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try printUsage();
        return null;
    }

    if (res.positionals.len <= 0 or res.positionals[0] == null) {
        try printUsage();
        log.err("The output parameter is required.", .{});
        return TempCmdError.NoOutputPathSpecified;
    }

    const import_db = res.args.dp == 1;
    return TempCmd.init(allocator, res.positionals[0].?, import_db);
}
