const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const builtin = std.builtin;
const StructField = builtin.Type.StructField;
const TokenIterator = std.mem.TokenIterator;
const Type = builtin.Type;
const testing = std.testing;

const ScanError = error{
    NoNextWord,
    NoNextLine,
    InvalidArraySize,
};

pub fn Parsed(comptime T: type) type {
    return struct {
        arena: ArenaAllocator,
        value: T,

        fn init(arena: ArenaAllocator, value: T) Parsed(T) {
            return .{ .arena = arena, .value = value };
        }

        pub fn deinit(self: Parsed(T)) void {
            self.arena.deinit();
        }
    };
}

const w_token = " ";
const l_token = "\n";

const Cursor = struct {
    source: []const u8,
    l_iter: TokenIterator(u8),
    w_iter: TokenIterator(u8),

    fn init(source: []const u8) Cursor {
        var l_iter = std.mem.tokenize(u8, source, l_token);
        var w_iter = std.mem.tokenize(u8, l_iter.next() orelse "", w_token);
        return .{
            .source = source,
            .l_iter = l_iter,
            .w_iter = w_iter,
        };
    }

    fn nextW(self: *Cursor) ?[]const u8 {
        return if (self.w_iter.next()) |w|
            w
        else if (self.l_iter.next()) |l| blk: {
            self.w_iter = std.mem.tokenize(u8, l, w_token);
            break :blk self.nextW();
        } else null;
    }

    fn nextL(self: *Cursor) ?TokenIterator(u8) {
        return if (self.w_iter.peek()) |_| blk: {
            var ws = self.w_iter;
            self.w_iter = std.mem.tokenize(u8, self.l_iter.next() orelse "", w_token);
            break :blk ws;
        } else if (self.l_iter.next()) |l| blk: {
            var ws = std.mem.tokenize(u8, l, w_token);
            self.w_iter = std.mem.tokenize(u8, self.l_iter.next() orelse "", w_token);
            break :blk ws;
        } else null;
    }
};

const Scanner = struct {
    arena: *std.heap.ArenaAllocator,
    cursor: Cursor,

    fn init(arena: *std.heap.ArenaAllocator, source: []const u8) Scanner {
        return .{
            .arena = arena,
            .cursor = Cursor.init(source),
        };
    }

    fn scan(self: *Scanner, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .Bool => {
                const w = self.cursor.nextW() orelse return error.NoNextWord;
                return if (std.mem.eql(u8, w, "true"))
                    true
                else if (std.mem.eql(u8, w, "false"))
                    false
                else
                    error.ParseBoolError;
            },
            .Int => |i| {
                const w = self.cursor.nextW() orelse return error.NoNextWord;
                return if (i.bits == 8 and i.signedness == .unsigned)
                    w[0]
                else
                    std.fmt.parseInt(@Type(.{ .Int = i }), w, 10);
            },
            .Float => |f| {
                const w = self.cursor.nextW() orelse return error.NoNextWord;
                return try std.fmt.parseFloat(@Type(.{ .Float = f }), w);
            },
            .Pointer => |p| {
                switch (p.size) {
                    .Slice => {
                        if (p.child == u8) {
                            return self.cursor.nextW() orelse return error.NoNextWord;
                        }
                        var arr = ArrayList(p.child).init(self.arena.allocator());
                        var li = self.cursor.nextL() orelse return error.NoNextLine;
                        while (li.next()) |w| {
                            _ = w;
                            const v = try self.scan(p.child);
                            try arr.append(v);
                        }
                        return try arr.toOwnedSlice();
                    },
                    else => @compileError("invalid field, non-slice pointers are not supported"),
                }
            },
            .Array => |a| {
                if (a.child == u8) {
                    const s = (self.cursor.nextW() orelse return error.NoNextWord);
                    if (s.len < a.len) {
                        return error.InvalidArraySize;
                    }
                    return s[0..a.len].*;
                }
                var r: [a.len]a.child = undefined;
                comptime var i: usize = 0;
                inline while (i < a.len) : (i += 1) {
                    const v = try self.scan(a.child);
                    r[i] = v;
                }
                return r;
            },
            .Struct => |s| {
                var v: T = undefined;
                comptime var i: usize = 0;
                inline while (i < s.fields.len) : (i += 1) {
                    const field = s.fields[i];
                    @field(v, field.name) = try self.scan(field.field_type);
                }
                return v;
            },
            else => @compileError("invalid field, unsupported field types"),
        }
    }
};

pub fn parse(comptime T: type, allocator: Allocator, input: []const u8) !Parsed(T) {
    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var scanner = Scanner.init(&arena, input);
    const v = try scanner.scan(T);
    return Parsed(T).init(arena, v);
}

const Printer = struct {
    alloc: Allocator,
    dest: []const u8,

    fn init(allocator: Allocator) Printer {
        return .{ .alloc = allocator, .output = undefined };
    }

    fn print(comptime T: type, value: T) !void {
        _ = value;
        switch (@typeInfo(T)) {}
    }
};

pub fn compose(comptime T: type, allocator: Allocator, output: T) ![]const u8 {
    _ = output;
    _ = allocator;
}

test "read next one" {
    const s =
        \\11 12
        \\13.5
        \\abc
        \\x y z
    ;
    var cursor = Cursor.init(s);
    try testing.expectEqualStrings("11", cursor.nextW().?);
    try testing.expectEqualStrings("12", cursor.nextW().?);
    try testing.expectEqualStrings("13.5", cursor.nextW().?);
    try testing.expectEqualStrings("abc", cursor.nextW().?);
    try testing.expectEqualStrings("x", cursor.nextW().?);
    try testing.expectEqualStrings("y", cursor.nextW().?);
    try testing.expectEqualStrings("z", cursor.nextW().?);
}

test "read next line" {
    const s =
        \\11 12
        \\13.5
        \\abc
        \\x y z
    ;
    var cursor = Cursor.init(s);
    try testing.expectEqualStrings("11 12", cursor.nextL().?.rest());
    try testing.expectEqualStrings("13.5", cursor.nextL().?.rest());
    try testing.expectEqualStrings("abc", cursor.nextL().?.rest());
    try testing.expectEqualStrings("x y z", cursor.nextL().?.rest());
}

test "read rest" {
    const s =
        \\11 12
        \\13.5
        \\abc
        \\x y z
    ;
    var cursor = Cursor.init(s);
    try testing.expectEqualStrings("11", cursor.nextW().?);
    try testing.expectEqualStrings("12", cursor.nextL().?.rest());
    try testing.expectEqualStrings("13.5", cursor.nextW().?);
    try testing.expectEqualStrings("abc", cursor.nextL().?.rest());
    try testing.expectEqualStrings("x", cursor.nextW().?);
    try testing.expectEqualStrings("y", cursor.nextW().?);
    try testing.expectEqualStrings("z", cursor.nextL().?.rest());
}

test "parse custom input" {
    const s =
        \\true
        \\false
        \\a
        \\-10
        \\12.3
        \\abc
        \\defghijklm
        \\ghi
    ;
    // const A = struct { b: bool, c: u8, i: i32, f: f64, s: []const u8, sa: [10]u8, sp: [*]const u8 };
    const A = struct { bt: bool, bf: bool, c: u8, i: i32, f: f64, s: []const u8, sa: [10]u8 };
    var allocator = std.testing.allocator;
    var parsed = try parse(A, allocator, s);
    defer parsed.deinit();
    try testing.expectEqual(true, parsed.value.bt);
    try testing.expectEqual(false, parsed.value.bf);
    try testing.expectEqual(@as(u8, 'a'), parsed.value.c);
    try testing.expectEqual(@as(i32, -10), parsed.value.i);
    try testing.expectEqual(@as(f64, 12.3), parsed.value.f);
    try testing.expectEqualStrings("abc", parsed.value.s);
    try testing.expectEqualStrings("defghijklm", &parsed.value.sa);
    // try testing.expectEqualDeep(A{ .x = 11, .y = 12, .z = 13.5 }, parsed.value);
}
