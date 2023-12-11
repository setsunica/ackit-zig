const std = @import("std");
const builtin = std.builtin;
const Allocator = std.mem.Allocator;
const StructField = builtin.Type.StructField;
const ArrayList = std.ArrayList;

const Input = std.json.ArrayHashMap([]u8);
// const Input = struct { a: []u8 };

pub fn Parse(comptime T: type, comptime content: []const u8) !type {
    _ = T;
    var allocator = std.heap.page_allocator;
    var parsed = try std.json.parseFromSlice(Input, allocator, content, .{});
    defer parsed.deinit();
    var iter = parsed.value.map.iterator();
    var writer = std.io.getStdOut().writer();
    _ = writer;
    // const fields = ArrayList(StructField).init(allocator);
    // fields.deinit();
    const fields: [1]StructField = undefined;
    var i: u8 = 0;
    while (iter.next()) |f| : (i += 1) {
        const t = if (std.mem.eql(u8, f.value_ptr.*, "i32")) {
            return i32;
        } else {
            unreachable;
        };
        fields[i] = .{ .name = f.key_ptr.*, .field_type = t, .default_value = null, .is_comptime = false, .alignment = 0 };
        // fields.append(.{ .name = f.key_ptr.*, .field_type = t, .default_value = null, .is_comptime = false, .alignment = 0 });
        // try writer.print("key: {s}, value: {s}", .{ f.key_ptr.*, f.value_ptr.* });
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = fields,
            //     &[_]builtin.TypeInfo.StructField{
            //     .{ .name = "one", .field_type = i32, .default_value = null, .is_comptime = false, .alignment = 0 },
            // },
            .decls = &[_]builtin.TypeInfo.Declaration{},
            .is_tuple = false,
        },
    });
}

pub fn hoge() !void {
    const content =
        \\{"a": "b"}
    ;
    var parsed = try std.json.parseFromSlice(Input, std.heap.page_allocator, content, .{});
    defer parsed.deinit();
    try std.io.getStdOut().writer().print("{any}\n", .{parsed.value.map.get("a").?});
}
