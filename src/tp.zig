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

pub const Composed = struct {
    arena: ArenaAllocator,
    value: []const u8,

    fn init(arena: ArenaAllocator, value: []const u8) Composed {
        return .{ .arena = arena, .value = value };
    }

    pub fn deinit(self: Composed) void {
        self.arena.deinit();
    }
};

const Accumulator = struct {
    allocator: Allocator,
    is_head_line: bool,
    current_line: usize,
    dest: ArrayList(ArrayList([]const u8)),

    fn init(allocator: Allocator) !Accumulator {
        return .{
            .allocator = allocator,
            .is_head_line = true,
            .current_line = 0,
            .dest = ArrayList(ArrayList([]const u8)).init(allocator),
        };
    }

    fn deinit(self: Accumulator) void {
        for (self.dest.items) |l| {
            l.deinit();
        }
        self.dest.deinit();
    }

    fn writeW(self: *Accumulator, v: []const u8) !void {
        if (self.is_head_line) {
            var arr = ArrayList([]const u8).init(self.allocator);
            try arr.append(v);
            try self.dest.append(arr);
        } else {
            try self.dest.items[self.current_line].append(v);
        }
        self.is_head_line = false;
    }

    fn writeL(self: *Accumulator, v: []const u8) !void {
        if (self.is_head_line) {
            var arr = ArrayList([]const u8).init(self.allocator);
            try arr.append(v);
            try self.dest.append(arr);
        } else {
            try self.dest.items[self.current_line].append(v);
        }
        self.current_line += 1;
        self.is_head_line = true;
    }

    fn newLine(self: *Accumulator) !void {
        if (self.is_head_line) {
            var arr = ArrayList([]const u8).init(self.allocator);
            try self.dest.append(arr);
        }
        self.current_line += 1;
        self.is_head_line = true;
    }

    fn toOwnedSlice(self: *Accumulator) ![]u8 {
        var lines = try self.allocator.alloc([]const u8, self.dest.items.len);
        defer self.allocator.free(lines);
        var i: usize = 0;
        while (i < lines.len) : (i += 1) {
            const line = try std.mem.join(self.allocator, w_token, self.dest.items[i].items);
            lines[i] = line;
        }
        const r = try std.mem.join(self.allocator, l_token, lines);
        for (lines) |l| {
            self.allocator.free(l);
        }
        return r;
    }
};

const Printer = struct {
    arena: *ArenaAllocator,
    acc: Accumulator,

    fn init(arena: *ArenaAllocator) !Printer {
        const allocator = arena.allocator();
        return .{
            .arena = arena,
            .acc = try Accumulator.init(allocator),
        };
    }

    fn deinit(self: Printer) void {
        self.acc.deinit();
    }

    fn print(self: *Printer, comptime T: type, value: T) !void {
        switch (@typeInfo(T)) {
            .Int => |i| {
                if (i.bits == 8 and i.signedness == .unsigned) {
                    const c = [_]u8{value};
                    try self.acc.writeW(&c);
                } else {
                    try self.acc.writeW(try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{value}));
                }
            },
            .Float => try self.acc.writeW(try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{value})),
            .Pointer => |p| switch (p.size) {
                .Slice => {
                    if (p.child == u8) {
                        try self.acc.writeL(value);
                    } else {
                        for (value) |v| {
                            try self.print(p.child, v);
                        }
                    }
                },
                else => @compileError("invalid type, non-slice pointers are not supported"),
            },
            .Array => |a| {
                if (a.child == u8) {
                    try self.acc.writeL(value[0..]);
                } else {
                    for (value) |v| {
                        try self.print(a.child, v);
                    }
                }
            },
            .Struct => |s| {
                comptime var i: usize = 0;
                inline while (i < s.fields.len) : (i += 1) {
                    const field = s.fields[i];
                    try self.print(field.field_type, @field(value, field.name));
                    try self.acc.newLine();
                }
            },
            else => @compileError("unsupported types for composing"),
        }
    }
};

pub fn compose(comptime T: type, allocator: Allocator, output: T) !Composed {
    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var printer = try Printer.init(&arena);
    defer printer.deinit();
    try printer.print(T, output);
    const value = try printer.acc.toOwnedSlice();
    return Composed.init(arena, value);
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

test "write words" {
    const allocator = testing.allocator;
    var acc = try Accumulator.init(allocator);
    defer acc.deinit();
    try acc.writeW("1");
    try acc.writeW("2.0");
    try acc.writeW("a");
    const actual = try acc.toOwnedSlice();
    defer allocator.free(actual);
    try testing.expectEqualStrings("1 2.0 a", actual);
}

test "write lines" {
    const allocator = testing.allocator;
    var acc = try Accumulator.init(allocator);
    defer acc.deinit();
    try acc.writeL("1 2");
    try acc.writeL("3.3");
    try acc.writeL("a b c");
    try acc.writeL("def ghi jkl");
    const actual = try acc.toOwnedSlice();
    defer allocator.free(actual);
    try testing.expectEqualStrings("1 2\n3.3\na b c\ndef ghi jkl", actual);
}

test "write lines after word" {
    const allocator = testing.allocator;
    var acc = try Accumulator.init(allocator);
    defer acc.deinit();
    try acc.writeW("1");
    try acc.writeL("2.0 3.3");
    try acc.writeW("abc");
    try acc.writeL("def ghi jkl");
    var actual = try acc.toOwnedSlice();
    defer allocator.free(actual);
    try testing.expectEqualStrings("1 2.0 3.3\nabc def ghi jkl", actual);
}

test "compose custom output" {
    const expected =
        \\c
        \\-1
        \\2.3
        \\abc
        \\9999999999
    ;
    const A = struct { c: u8, i: i32, f: f64, s: []const u8, sa: [10]u8 };
    var sa: [10]u8 = ("9" ** 10)[0..].*;
    const a: A = .{ .c = 'c', .i = -1, .f = 2.3, .s = "abc", .sa = sa };
    const allocator = testing.allocator;
    const composed = try compose(A, allocator, a);
    defer composed.deinit();
    try testing.expectEqualStrings(expected, composed.value);
}
