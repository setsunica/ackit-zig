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
    allocator: Allocator,
    cursor: Cursor,

    fn init(allocator: Allocator, source: []const u8) Scanner {
        return .{
            .allocator = allocator,
            .cursor = Cursor.init(source),
        };
    }

    fn scan(self: *Scanner, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .Bool => {
                const w = self.cursor.readW() orelse return error.NoNextWord;
                return if (std.mem.eql(u8, w, "true"))
                    true
                else if (std.mem.eql(u8, w, "false"))
                    false
                else
                    error.ParseBoolError;
            },
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
                        var arr = ArrayList(p.child).init(self.allocator);
                        var li = self.cursor.readL() orelse return error.NoNextLine;
                        while (li.next()) |w| {
                            _ = w;
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
    var scanner = Scanner.init(arena.allocator(), input);
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
    is_head_line: bool,
    dest: ArrayList(u8),

    fn init(allocator: Allocator, num: usize) !Accumulator {
        return .{
            .is_head_line = true,
            .dest = try ArrayList(u8).initCapacity(allocator, num),
        };
    }

    fn writeW(self: *Accumulator, v: []const u8) !void {
        if (self.is_head_line) {
            try self.dest.appendSlice(v);
        } else {
            try self.dest.writer().print("{s}{s}", .{ w_token, v });
        }
        self.is_head_line = false;
    }

    fn writeL(self: *Accumulator, v: []const u8) !void {
        if (self.is_head_line) {
            try self.dest.writer().print("{s}{s}", .{ v, l_token });
        } else {
            try self.dest.writer().print("{s}{s}{s}", .{ l_token, v, l_token });
        }
        self.is_head_line = true;
    }
};

const Printer = struct {
    allocator: Allocator,
    acc: Accumulator,

    fn init(allocator: Allocator) !Printer {
        return .{
            .allocator = allocator,
            .acc = try Accumulator.init(allocator, 4096),
        };
    }

    fn print(self: *Printer, comptime T: type, value: T) !void {
        _ = value;
        _ = self;
        switch (@typeInfo(T)) {
            .Bool, .Int, .Float => {
                // TODO: Implement string accumulation.
            },
            .Pointer => |p| switch (p.size) {
                .Slice => if (p.child == u8) {
                    // TODO: Implement string accumulation.
                },
                else => @compileError("invalid type, non-slice pointers are not supported"),
            },
            else => @compileError("unsupported types for composing"),
        }
    }
};

pub fn compose(comptime T: type, allocator: Allocator, output: T) !Composed {
    var arena = ArenaAllocator.init(allocator);
    var printer = try Printer.init(arena.allocator());
    try printer.print(T, output);
    const value = printer.acc.dest.toOwnedSlice();
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
        \\true
        \\false
        \\a
        \\-10
        \\12.3
        \\abc
        \\defghijklm
        \\ghi
    ;
    const A = struct { bt: bool, bf: bool, c: u8, i: i32, f: f64, s: []const u8, sa: [10]u8 };
    var allocator = testing.allocator;
    var parsed = try parse(A, allocator, s);
    defer parsed.deinit();
    try testing.expectEqual(true, parsed.value.bt);
    try testing.expectEqual(false, parsed.value.bf);
    try testing.expectEqual(@as(u8, 'a'), parsed.value.c);
    try testing.expectEqual(@as(i32, -10), parsed.value.i);
    try testing.expectEqual(@as(f64, 12.3), parsed.value.f);
    try testing.expectEqualStrings("abc", parsed.value.s);
    try testing.expectEqualStrings("defghijklm", &parsed.value.sa);
}

test "write words" {
    const allocator = testing.allocator;
    var acc = try Accumulator.init(allocator, 4096);
    defer acc.dest.deinit();
    try acc.writeW("1");
    try acc.writeW("2.0");
    try acc.writeW("a");
    try testing.expectEqualStrings("1 2.0 a", acc.dest.items);
}

test "write lines" {
    const allocator = testing.allocator;
    var acc = try Accumulator.init(allocator, 4096);
    defer acc.dest.deinit();
    try acc.writeL("1 2");
    try acc.writeL("3.3");
    try acc.writeL("a b c");
    try acc.writeL("def ghi jkl");
    try testing.expectEqualStrings("1 2\n3.3\na b c\ndef ghi jkl\n", acc.dest.items);
}

test "write lines after word" {
    const allocator = testing.allocator;
    var acc = try Accumulator.init(allocator, 4096);
    defer acc.dest.deinit();
    try acc.writeW("1");
    try acc.writeL("2.0 3.3");
    try acc.writeW("abc");
    try acc.writeL("def ghi jkl");
    try testing.expectEqualStrings("1\n2.0 3.3\nabc\ndef ghi jkl\n", acc.dest.items);
}

test "compose custom output" {
    const a: []const u8 = "abc";
    const allocator = testing.allocator;
    const composed = try compose([]const u8, allocator, a);
    defer composed.deinit();
    try testing.expectEqualStrings("abc", composed.value);
}
