const std = @import("std");
const log = std.log.scoped(.ackit);
const Allocator = std.mem.Allocator;
const ArgIterator = std.process.ArgIterator;
const temp = @import("cmd/temp.zig");
const TempCmdError = temp.TempCmdError;
const TempCmd = temp.TempCmd;

const version = "0.1.0";

const CmdError = error{
    InvalidCmd,
    NoCmd,
} || TempCmdError;

const CmdType = union(enum) {
    help,
    version,
    temp: TempCmd,
};

const Cmd = struct {
    name: []const u8,
    cmd_type: CmdType,

    pub fn run(self: *Cmd) !void {
        switch (self.cmd_type) {
            .help => try printUsage(),
            .version => log.info("ackit: {s}", .{version}),
            inline else => |*c| try c.run(),
        }
    }

    pub fn deinit(self: Cmd) void {
        switch (self.cmd_type) {
            .temp => |c| c.deinit(),
            else => return,
        }
    }
};

pub fn printUsage() !void {
    log.info(
        \\Usage: ackit <command>
        \\
        \\Commands:
        \\  help                  Display this help.
        \\  version               Display version information.
        \\  temp <output_path>    Create a template file in the specified output path.
        \\
    , .{});
}

pub fn parse(allocator: Allocator, args: *ArgIterator) !?Cmd {
    return if (args.next()) |cmd|
        if (std.mem.eql(u8, cmd, "help"))
            .{ .name = "help", .cmd_type = .help }
        else if (std.mem.eql(u8, cmd, "version"))
            .{ .name = "version", .cmd_type = .version }
        else if (std.mem.eql(u8, cmd, "temp"))
            .{
                .name = "temp",
                .cmd_type = .{ .temp = try temp.parse(allocator, args) orelse return null },
            }
        else
            CmdError.InvalidCmd
    else
        CmdError.NoCmd;
}
