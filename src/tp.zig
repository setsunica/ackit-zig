const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const builtin = std.builtin;
const StructField = builtin.Type.StructField;
const SplitIterator = std.mem.SplitIterator;
const Type = builtin.Type;
const testing = std.testing;

const ScanError = error{
    NoNextWord,
    NoNextLine,
};

pub fn Parsed(comptime T: type) type {
    return struct {
        arena: ArenaAllocator,
        value: T,

        fn init(value: T, arena: ArenaAllocator) Parsed(T) {
            return .{ .arena = arena, .value = value };
        }

        fn deinit(self: Parsed(T)) void {
            // var alloc = self.arena.child_allocator;
            self.arena.deinit();
            // alloc.destroy(self.arena);
        }
    };
}

const Cursor = struct {
    input: []const u8,
    line_iter: SplitIterator(u8, .scalar),
    word_iter: SplitIterator(u8, .scalar),

    fn init(input: []const u8) Cursor {
        return .{
            .input = input,
            .line_iter = std.mem.splitScalar(u8, input, '\n'),
            .word_iter = std.mem.splitScalar(u8, input, ' '),
        };
    }

    fn next(self: *Cursor) ?[]const u8 {
        return if (self.word_iter.next()) |w|
            w
        else if (self.line_iter.next()) |l| blk: {
            self.word_iter = std.mem.splitScalar(u8, l, ' ');
            break :blk self.next();
        } else null;
    }

    fn nextLine(self: *Cursor) ?SplitIterator(u8, .scalar) {
        return if (self.line_iter.next()) |l|
            std.mem.splitScalar(u8, l, ' ')
        else
            null;
    }
};

const Scanner = struct {
    arena: *std.heap.ArenaAllocator,
    cur: Cursor,

    fn init(arena: *std.heap.ArenaAllocator, input: []const u8) Scanner {
        return .{
            .arena = arena,
            .cur = Cursor.init(input),
        };
    }

    fn parse(comptime T: type, s: []const u8) !T {
        return switch (@typeInfo(T)) {
            .Bool => if (std.mem.eql(u8, s, "true"))
                true
            else if (std.mem.eql(u8, s, "false"))
                false
            else
                error.ParseBoolError,
            .Int => |i| std.fmt.parseInt(@Type(.{ .Int = i }), s, 10),
            .Float => |f| try std.fmt.parseFloat(@Type(.{ .Float = f }), s),
            else => @compileError("invalid type for parsing"),
        };
    }

    fn parseNext(self: *Scanner, comptime T: type) !T {
        const w = self.cur.next() orelse return error.NoNextWord;
        return try Scanner.parse(T, w);
    }

    fn parseNextLine(self: *Scanner, comptime T: type) ![]T {
        var arr = ArrayList(T).init(self.arena.allocator());
        var li = self.cur.nextLine() orelse return error.NoNextLine;
        while (li.next()) |w| {
            const v = try Scanner.parse(T, w);
            try arr.append(v);
        }
        return try arr.toOwnedSlice();
    }

    fn parseNextLineArray(self: *Scanner, comptime T: type, comptime len: usize) !?[len]T {
        var arr: [len]T = undefined;
        const li = if (self.cur.nextLine()) |l| l else return null;
        for (li, 0..) |w, i| {
            const v = try self.parse(T, w);
            arr[i] = v;
        }
        return arr;
    }

    fn parseField(self: *Scanner, comptime T: type) !T {
        return switch (@typeInfo(T)) {
            .Bool, .Int, .Float => try self.parseNext(T),
            .Pointer => |p| if (p.size == .Slice)
                try self.parseNextLine(p.child)
            else
                @compileError("invalid field, non-slice pointers are not supported"),
            .Array => |arr| try self.parseNextLineArray(arr.child, arr.len),
            else => @compileError("invalid field, unsupported field types"),
        };
    }
};

pub fn parse(comptime T: type, allocator: Allocator, input: []const u8) !Parsed(T) {
    // std.json.parseFree();
    var arena = ArenaAllocator.init(allocator);
    var scanner = Scanner.init(&arena, input);
    switch (@typeInfo(T)) {
        .Struct => |s| {
            var v: T = undefined;
            inline for (0..s.fields.len) |i| {
                const field = comptime s.fields[i];
                @field(v, field.name) = try scanner.parseField(field.type);
            }
            return Parsed(T).init(v, arena);
        },
        else => @compileError("invalid input type, no support for non-structures"),
    }
}

test "parse custom input" {
    const s = "11 12 13.5";
    const A = struct { x: u32, y: i32, z: f32 };
    var allocator = std.testing.allocator;
    var parsed = try parse(A, allocator, s);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 11), parsed.value.x);
    try testing.expectEqual(@as(i32, 12), parsed.value.y);
    try testing.expectEqual(@as(f32, 13.5), parsed.value.z);
    try testing.expectEqualDeep(A{ .x = 11, .y = 12, .z = 13.5 }, parsed.value);
}
