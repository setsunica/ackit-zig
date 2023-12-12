const std = @import("std");
const builtin = std.builtin;
const Allocator = std.mem.Allocator;
const StructField = builtin.Type.StructField;
const ArrayList = std.ArrayList;

pub fn Parsed(comptime T: type) type {
    return struct {
        alloc: Allocator,
        value: T,

        fn init(value: T, allocator: Allocator) Parsed(T) {
            return .{ .alloc = allocator, .value = value };
        }
    };
}

const Cursor = struct {
    // arena: *std.heap.ArenaAllocator,
    input: []const u8,
    // pos: u32,
    line_iter: std.mem.SplitIterator(u8, std.mem.DelimiterType.scalar),
    word_iter: std.mem.SplitIterator(u8, std.mem.DelimiterType.scalar),

    fn init(arena: *std.heap.ArenaAllocator, input: []const u8) Cursor {
        _ = arena;
        return Cursor{
            // .arena = arena,
            .input = input,
            // .pos = 0,
            .line_iter = std.mem.splitScalar(u8, input, '\n'),
            .word_iter = std.mem.splitScalar(u8, input, ' '),
        };
    }

    fn next(self: *Cursor) ?[]const u8 {
        if (self.word_iter.next()) |w| {
            return w;
        } else if (self.line_iter.next()) |l| {
            self.word_iter = std.mem.splitScalar(u8, l, ' ');
            return self.next();
        }
        return null;
    }

    fn nextLine(self: *Cursor) ?[]const u8 {
        if (self.line_iter.next()) |l| {
            self.word_iter = std.mem.splitScalar(u8, l, ' ');
            return l;
        }
        return null;
    }
};

fn parseField(comptime T: type, field: StructField, cur: *Cursor) !T {
    switch (@typeInfo(field.type)) {
        .Bool => {
            var next = cur.next();
            return if (std.mem.eql(u8, next, "true")) {
                true;
            } else if (std.mem.eql(u8, next, "false")) {
                false;
            } else return {
                error{ParseBoolError};
            };
        },
        .Int => |i| try std.fmt.parseInt(i.type, cur.next(), 10),
        .Float => |f| try std.fmt.parseFloat(f.type, cur.next()),
        // .Array => |arr| unreachable,
        else => @compileError(""),
    }
}

pub fn parse(comptime T: type, allocator: Allocator, input: []const u8) !Parsed(T) {
    // std.json.parseFree();
    var arena = try allocator.create(std.heap.ArenaAllocator);
    var arena_allocator = arena.allocator();
    var cur = &Cursor.init(arena, input);
    const v = switch (@typeInfo(T)) {
        inline .Struct => |s| {
            const v: T = undefined;
            inline for (0..s.fields.len) |i| {
                const field_type = comptime {
                    return s.fields[i].type;
                };
                @field(v, s.fields[i].name) = try parseField(field_type, s.fields[i], cur);
            }
            return v;
        },
        inline else => @compileError("Failed to parse input. No support for non-structures."),
    };
    return Parsed(T).init(v, arena_allocator);
}
