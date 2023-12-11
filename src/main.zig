const std = @import("std");
const tp = @import("tp.zig");

pub fn main() !void {
    const content =
        \\{"a": "b"}
    ;

    const A = comptime {
        try tp.Parse(u8, content);
    };
    _ = A;
    const stdin_file = std.io.getStdIn().reader();
    const stdout_file = std.io.getStdOut().writer();
    var br = std.io.bufferedReader(stdin_file);
    var bw = std.io.bufferedWriter(stdout_file);
    const stdin = br.reader();
    const stdout = bw.writer();
    const line_max_bytes = 128;

    var line_buf: [line_max_bytes]u8 = undefined;
    const line = try stdin.readUntilDelimiter(&line_buf, '\n');
    const trimed_line = std.mem.trimRight(u8, line, &[_]u8{13});
    var iter = std.mem.split(u8, trimed_line, " ");
    var i: u32 = 0;
    while (iter.next()) |c| : (i += 1) {
        // if (c.len <= 0) {
        //     break;
        // }
        try stdout.print("i = {}, c = {any}\n", .{ i, c });
    }

    try bw.flush();
}
