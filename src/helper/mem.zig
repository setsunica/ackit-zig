const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub fn collapseScalarOwned(comptime T: type, allocator: Allocator, input: []const T, needle: T) ![]const T {
    var list = ArrayList(T).init(allocator);
    errdefer list.deinit();
    var is_cont_scalar = false;
    for (input[0..]) |c| {
        if (is_cont_scalar) {
            if (c == needle) continue;
            is_cont_scalar = false;
        } else if (c == needle) is_cont_scalar = true;

        try list.append(c);
    }
    return try list.toOwnedSlice();
}

const testing = std.testing;

test "collapse two or more spaces" {
    const allocator = testing.allocator;
    const input = "a b  c   \n  d   ";
    const expected = "a b c \n d ";
    const actual = try collapseScalarOwned(u8, allocator, input, ' ');
    defer allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}
