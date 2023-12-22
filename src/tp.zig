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

    fn readW(self: *Cursor) ?[]const u8 {
        return if (self.w_iter.next()) |w|
            w
        else if (self.l_iter.next()) |l| blk: {
            self.w_iter = std.mem.tokenize(u8, l, w_token);
            break :blk self.readW();
        } else null;
    }

    fn readL(self: *Cursor) ?TokenIterator(u8) {
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
    arena: ArenaAllocator,
    cursor: Cursor,

    fn init(arena: ArenaAllocator, source: []const u8) Scanner {
        return .{
            .arena = arena,
            .cursor = Cursor.init(source),
        };
    }

    fn scan(self: *Scanner, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .Int => |i| {
                const w = self.cursor.readW() orelse return error.NoNextWord;
                return if (i.bits == 8 and i.signedness == .unsigned)
                    w[0]
                else
                    std.fmt.parseInt(@Type(.{ .Int = i }), w, 10);
            },
            .Float => |f| {
                const w = self.cursor.readW() orelse return error.NoNextWord;
                return try std.fmt.parseFloat(@Type(.{ .Float = f }), w);
            },
            .Pointer => |p| {
                switch (p.size) {
                    .Slice => {
                        if (p.child == u8) {
                            return self.cursor.readW() orelse return error.NoNextWord;
                        }
                        var arr = ArrayList(p.child).init(self.arena);
                        var li = self.cursor.readL() orelse return error.NoNextLine;
                        while (li.next()) |_| {
                            const v = try self.scan(p.child);
                            try arr.append(v);
                        }
                        return try arr.toOwnedSlice();
                    },
                    else => @compileError("invalid type, non-slice pointers are not supported"),
                }
            },
            .Array => |a| {
                if (a.child == u8) {
                    const s = (self.cursor.readW() orelse return error.NoNextWord);
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
            else => @compileError("unsupported types for parsing"),
        }
    }
};

pub fn parse(comptime T: type, allocator: Allocator, input: []const u8) !Parsed(T) {
    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var scanner = Scanner.init(arena, input);
    const v = try scanner.scan(T);
    return Parsed(T).init(arena, v);
}

fn Printer(comptime Writer: type) type {
    return struct {
        const Self = @This();
        writer: Writer,

        fn init(writer: Writer) Printer(Writer) {
            return .{ .writer = writer };
        }

        fn print(self: *Self, comptime T: type, value: T) !void {
            switch (@typeInfo(T)) {
                .Int => |i| {
                    if (i.bits == 8 and i.signedness == .unsigned) {
                        _ = try self.writer.writeByte(value);
                    } else {
                        try self.writer.print("{d}", .{value});
                    }
                },
                .Float => try self.writer.print("{d}", .{value}),
                .Pointer => |p| switch (p.size) {
                    .Slice => {
                        switch (@typeInfo(p.child)) {
                            .Pointer => |pp| {
                                if (pp.size == .Slice)
                                    try self.printLines(p.child, value)
                                else
                                    @compileError("invalid type, non-slice pointers are not supported");
                            },
                            .Array => try self.printLines(p.child, value[0..]),
                            else => if (p.child == u8)
                                try self.writer.print("{s}", .{value})
                            else
                                try self.printWords(p.child, value),
                        }
                    },
                    else => @compileError("invalid type, non-slice pointers are not supported"),
                },
                .Array => |a| try self.print([]const a.child, value[0..]),
                .Struct => |s| {
                    comptime var i: usize = 0;
                    inline while (i < s.fields.len) : (i += 1) {
                        const field = s.fields[i];
                        try self.print(field.field_type, @field(value, field.name));
                        _ = try self.writer.write(l_token);
                    }
                },
                else => @compileError(@typeName(T) ++ " is an unsupported type for composing"),
            }
        }

        fn printChildren(self: *Self, comptime Child: type, value: []const Child, sep: []const u8) !void {
            var i: usize = 0;
            while (i < value.len) : (i += 1) {
                try self.print(Child, value[i]);
                if (i != value.len) {
                    try self.writer.write(sep);
                }
            }
        }

        inline fn printWords(self: *Self, comptime Child: type, value: []const Child) !void {
            try self.printChildren(Child, value, w_token);
        }

        inline fn printLines(self: *Self, comptime Child: type, value: []const Child) !void {
            try self.printChildren(Child, value, l_token);
        }
    };
}

pub fn compose(comptime T: type, comptime Writer: type, output: T, writer: Writer) !void {
    var printer = Printer(Writer).init(writer);
    try printer.print(T, output);
}

test "read words" {
    const s =
        \\11 12
        \\13.5
        \\abc
        \\x y z
    ;
    var cursor = Cursor.init(s);
    try testing.expectEqualStrings("11", cursor.readW().?);
    try testing.expectEqualStrings("12", cursor.readW().?);
    try testing.expectEqualStrings("13.5", cursor.readW().?);
    try testing.expectEqualStrings("abc", cursor.readW().?);
    try testing.expectEqualStrings("x", cursor.readW().?);
    try testing.expectEqualStrings("y", cursor.readW().?);
    try testing.expectEqualStrings("z", cursor.readW().?);
}

test "read lines" {
    const s =
        \\11 12
        \\13.5
        \\abc
        \\x y z
    ;
    var cursor = Cursor.init(s);
    try testing.expectEqualStrings("11 12", cursor.readL().?.rest());
    try testing.expectEqualStrings("13.5", cursor.readL().?.rest());
    try testing.expectEqualStrings("abc", cursor.readL().?.rest());
    try testing.expectEqualStrings("x y z", cursor.readL().?.rest());
}

test "read rest" {
    const s =
        \\11 12
        \\13.5
        \\abc
        \\x y z
    ;
    var cursor = Cursor.init(s);
    try testing.expectEqualStrings("11", cursor.readW().?);
    try testing.expectEqualStrings("12", cursor.readL().?.rest());
    try testing.expectEqualStrings("13.5", cursor.readW().?);
    try testing.expectEqualStrings("abc", cursor.readL().?.rest());
    try testing.expectEqualStrings("x", cursor.readW().?);
    try testing.expectEqualStrings("y", cursor.readW().?);
    try testing.expectEqualStrings("z", cursor.readL().?.rest());
}

test "parse custom input" {
    const s =
        \\a
        \\-10
        \\12.3
        \\abc
        \\defghijklm
        \\ghi
    ;
    const A = struct { c: u8, i: i32, f: f64, s: []const u8, sa: [10]u8 };
    var allocator = testing.allocator;
    var parsed = try parse(A, allocator, s);
    defer parsed.deinit();
    try testing.expectEqual(@as(u8, 'a'), parsed.value.c);
    try testing.expectEqual(@as(i32, -10), parsed.value.i);
    try testing.expectEqual(@as(f64, 12.3), parsed.value.f);
    try testing.expectEqualStrings("abc", parsed.value.s);
    try testing.expectEqualStrings("defghijklm", &parsed.value.sa);
}

test "compose custom output" {
    const expected =
        \\c
        \\-1
        \\2.3
        \\abc
        \\0123456789
        \\
    ;
    const Output = struct { c: u8, i: i32, f: f64, s: []const u8, a: [10]u8 };
    var a: [10]u8 = undefined;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        a[i] = @intCast(u8, i) + '0';
    }
    const o = Output{ .c = 'c', .i = -1, .f = 2.3, .s = "abc", .a = a };
    var buf: [4092]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var writer = stream.writer();
    try compose(Output, @TypeOf(writer), o, writer);
    try testing.expectEqualStrings(expected, stream.getWritten());
}
