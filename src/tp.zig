const std = @import("std");
const builtin = std.builtin;
const Allocator = std.mem.Allocator;
const StructField = builtin.Type.StructField;
const ArrayList = std.ArrayList;
const SplitIterator = std.mem.SplitIterator;

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
    input: []const u8,
    line_iter: SplitIterator(u8, .scalar),
    word_iter: SplitIterator(u8, .scalar),

    fn init(input: []const u8) Cursor {
        return Cursor{
            .input = input,
            .line_iter = std.mem.splitScalar(u8, input, '\n'),
            .word_iter = std.mem.splitScalar(u8, input, ' '),
        };
    }

    fn next(self: *Cursor) ?[]const u8 {
        if (self.word_iter.next()) |w|
            w
        else if (self.line_iter.next()) |l| {
            self.word_iter = std.mem.splitScalar(u8, l, ' ');
            return self.next();
        }
        return null;
    }

    fn nextLine(self: *Cursor) ?SplitIterator(u8, .scalar) {
        if (self.line_iter.next()) |l|
            std.mem.splitScalar(u8, l, ' ')
        else
            return null;
    }
};

const Scanner = struct {
    arena: *std.heap.ArenaAllocator,
    cur: *Cursor,

    fn init(arena: *std.heap.ArenaAllocator, input: []const u8) Scanner {
        return .{
            .arena = arena,
            .cur = Cursor.init(input),
        };
    }

    fn parse(comptime T: type, s: []const u8) !T {
        switch (@typeInfo(T)) {
            inline .Bool => if (std.mem.eql(u8, s, "true"))
                true
            else if (std.mem.eql(u8, s, "false"))
                false
            else
                error{ParseBoolError},
            inline .Int => |i| try std.fmt.parseInt(i.type, s, 10),
            inline .Float => |f| try std.fmt.parseFloat(f.type, s),
            _ => @compileError("Word parsing failed. Unsupported type."),
        }
    }

    fn parseNext(self: Scanner, comptime T: type) !T {
        const w = if (self.cur.next()) |w| w else {
            return error{ParseNextError};
        };
        return self.parse(T, w);
    }

    fn parseNextLine(self: Scanner, comptime T: type) ![]T {
        var arr = ArrayList(T).init(self.arena.allocator());
        const li =
            if (self.cur.nextLine()) |l|
            l
        else {
            return arr;
        };
        for (li) |w| {
            const v = try self.parse(T, w);
            arr.append(v);
        }
        return try arr.toOwnedSlice();
    }

    fn parseNextLineArray(self: Scanner, comptime T: type, comptime len: usize) !?[len]T {
        var arr: [len]T = undefined;
        const li =
            if (self.cur.nextLine()) |l|
            l
        else {
            return null;
        };
        for (li, 0..) |w, i| {
            const v = try self.parse(T, w);
            arr[i] = v;
        }
        return arr;
    }
};

fn parseField(comptime T: type, scanner: Scanner) !T {
    switch (@typeInfo(T)) {
        .Bool, .Int, .Float => try scanner.parseNext(T),
        .Slice => |sl| try scanner.parseNextLine(sl.child),
        .Array => |arr| try scanner.parseNextLineArray(arr.child, arr.len),
        else => @compileError("Failed to parse input field. Unsupported field types."),
    }
}

pub fn parse(comptime T: type, allocator: Allocator, input: []const u8) !Parsed(T) {
    // std.json.parseFree();
    var arena = try allocator.create(std.heap.ArenaAllocator);
    var arena_allocator = arena.allocator();
    var scanner = Scanner.init(arena, input);
    const v = switch (@typeInfo(T)) {
        inline .Struct => |s| {
            const v: T = undefined;
            inline for (0..s.fields.len) |i| {
                const field_type = s.fields[i].type;
                const field = s.fields[i];
                _ = field;
                @field(v, s.fields[i].name) = try parseField(field_type, scanner);
            }
            v;
        },
        inline else => @compileError("Failed to parse input. No support for non-structures."),
    };
    return Parsed(T).init(v, arena_allocator);
}
