const std = @import("std");
const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;

const f_max_size = 512 * 1024 * 1024;
const l_delim = '\n';
const l_token = "\n";
const w_delim = ' ';
const w_token = " ";
const scan_fn_decl_name = "scanAlloc";
const scan_fixed_size_fn_decl_name = "scanFixedSizeAlloc";
const print_fn_decl_name = "print";
const size_field_name_decl_name = "size_field_name";

pub const ScanError = error{
    NoNextWord,
    NoNextLine,
    InvalidArraySize,
};

fn Parsed(comptime T: type) type {
    return struct {
        arena: heap.ArenaAllocator,
        value: T,

        fn init(arena: heap.ArenaAllocator, value: T) Parsed(T) {
            return .{ .arena = arena, .value = value };
        }

        pub fn deinit(self: Parsed(T)) void {
            self.arena.deinit();
        }
    };
}

const Cursor = struct {
    const Iter = mem.TokenIterator(u8, .scalar);
    l_iter: Iter,
    w_iter: Iter,

    fn init(source: []const u8) Cursor {
        var l_iter = mem.tokenizeScalar(u8, source, l_delim);
        const w_iter = mem.tokenizeScalar(u8, l_iter.next() orelse "", w_delim);
        return .{
            .l_iter = l_iter,
            .w_iter = w_iter,
        };
    }

    fn setSource(self: *Cursor, source: []const u8) void {
        self.l_iter = mem.tokenizeScalar(u8, source, l_delim);
        self.w_iter = mem.tokenizeScalar(u8, self.l_iter.next() orelse "", w_delim);
    }

    fn nextW(self: *Cursor) ?[]const u8 {
        return if (self.w_iter.next()) |w|
            w
        else if (self.l_iter.next()) |l| blk: {
            self.w_iter = mem.tokenizeScalar(u8, l, w_delim);
            break :blk self.nextW();
        } else null;
    }

    fn nextL(self: *Cursor) ?Iter {
        return if (self.w_iter.peek()) |_| blk: {
            const ws = self.w_iter;
            self.w_iter = mem.tokenizeScalar(u8, self.l_iter.next() orelse "", w_delim);
            break :blk ws;
        } else if (self.l_iter.next()) |l| blk: {
            const ws = mem.tokenizeScalar(u8, l, w_delim);
            self.w_iter = mem.tokenizeScalar(u8, self.l_iter.next() orelse "", w_delim);
            break :blk ws;
        } else null;
    }

    fn countRestW(self: *Cursor) usize {
        if (self.w_iter.peek() == null) {
            const l = self.l_iter.next() orelse return 0;
            self.w_iter = mem.tokenizeScalar(u8, l, w_delim);
        }
        const rest = self.w_iter.rest();
        if (rest.len == 0) return 0;
        return mem.count(u8, rest, w_token) + 1;
    }
};

pub const Scanner = struct {
    const Self = @This();
    reader: *std.io.Reader,
    cursor: Cursor,

    fn init(reader: *std.io.Reader) Self {
        return .{
            .reader = reader,
            .cursor = Cursor.init(""),
        };
    }

    inline fn hasScanAllocFn(comptime T: type) bool {
        return @hasDecl(T, scan_fn_decl_name) and !@hasDecl(T, size_field_name_decl_name);
    }

    inline fn hasScanFixedSizeAllocFn(comptime T: type) bool {
        return @hasDecl(T, scan_fixed_size_fn_decl_name) and @hasDecl(T, size_field_name_decl_name);
    }

    fn scanRaw(self: *Self, comptime T: type, allocator: ?mem.Allocator) !T {
        return switch (@typeInfo(T)) {
            .int => |i| blk: {
                const w = self.cursor.nextW() orelse return ScanError.NoNextWord;
                break :blk if (i.bits == 8 and i.signedness == .unsigned)
                    w[0]
                else
                    std.fmt.parseInt(@Type(.{ .int = i }), w, 10);
            },
            .float => |f| blk: {
                const w = self.cursor.nextW() orelse return ScanError.NoNextWord;
                break :blk try std.fmt.parseFloat(@Type(.{ .float = f }), w);
            },
            .pointer => |p| blk: {
                if (p.size != .slice) @compileError("invalid type " ++ @typeName(T) ++ ", non-slice pointers are not supported for scanning");
                if (p.child == u8) return self.cursor.nextW() orelse return ScanError.NoNextWord;
                break :blk switch (@typeInfo(p.child)) {
                    .pointer => |pp| if (pp.size == .slice)
                        try self.scanSlices(pp.child, allocator.?)
                    else
                        @compileError("invalid type " ++ @typeName(p.child) ++ ", non-slice pointers are not supported for scanning"),
                    .array => try self.scanArrays(p.child, allocator.?),
                    else => try self.scanSlice(p.child, allocator.?) orelse ScanError.NoNextLine,
                };
            },
            .array => try self.scanArray(T, allocator) orelse ScanError.NoNextWord,
            .@"struct" => |s| blk: {
                if (hasScanAllocFn(T)) {
                    break :blk try T.scanAlloc(allocator.?, self);
                }
                var v: T = undefined;
                inline for (s.fields) |field| {
                    const is_struct = @typeInfo(field.type) == .@"struct";
                    if (is_struct and hasScanFixedSizeAllocFn(field.type)) {
                        const size = @field(v, field.type.size_field_name);
                        @field(v, field.name) = try field.type.scanFixedSizeAlloc(allocator.?, self, size);
                    } else {
                        @field(v, field.name) = try self.scanRaw(field.type, allocator);
                    }
                }
                break :blk v;
            },
            .optional => |o| self.scanRaw(o.child, allocator) catch return null,
            else => @compileError("invalid type " ++ @typeName(T) ++ ", unsupported types for scanning"),
        };
    }

    fn scanSlice(self: *Self, comptime T: type, allocator: mem.Allocator) !?[]T {
        const restCount = self.cursor.countRestW();
        if (restCount == 0) return null;
        var arr = std.ArrayList(T).empty;
        errdefer arr.deinit(allocator);
        var i: usize = 0;
        while (i < restCount) : (i += 1) {
            const v = try self.scanRaw(T, allocator);
            try arr.append(allocator, v);
        }
        return try arr.toOwnedSlice(allocator);
    }

    fn scanSlices(self: *Self, comptime T: type, allocator: mem.Allocator) ![][]T {
        var arr = std.ArrayList([]T).empty;
        errdefer arr.deinit(allocator);
        while (try self.scanSlice(T, allocator)) |vs| {
            try arr.append(allocator, vs);
        }
        return arr.toOwnedSlice(allocator);
    }

    fn scanArray(self: *Self, comptime Array: type, allocator: ?mem.Allocator) !?Array {
        const restCount = self.cursor.countRestW();
        if (restCount == 0) return null;
        const a = @typeInfo(Array).array;
        if (a.child == u8) {
            const s = self.cursor.nextW().?;
            if (s.len < a.len) {
                return ScanError.InvalidArraySize;
            }
            return s[0..a.len].*;
        }
        var r: [a.len]a.child = undefined;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            r[i] = try self.scanRaw(a.child, allocator);
        }
        return r;
    }

    fn scanArrays(self: *Self, comptime Array: type, allocator: mem.Allocator) ![]Array {
        var arrs = std.ArrayList(Array).empty;
        errdefer arrs.deinit(allocator);
        while (try self.scanArray(Array, allocator)) |arr| {
            try arrs.append(allocator, arr);
        }
        return arrs.toOwnedSlice(allocator);
    }

    fn isAllocatorRequired(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .int, .float => false,
            .pointer => true,
            .array => |arr| isAllocatorRequired(arr.child),
            .@"struct" => |s| blk: {
                if (hasScanAllocFn(T)) break :blk true;
                inline for (s.fields) |field| {
                    const is_struct = @typeInfo(field.type) == .@"struct";
                    if ((is_struct and hasScanFixedSizeAllocFn(field.type)) or
                        isAllocatorRequired(field.type)) break :blk true;
                }
                break :blk false;
            },
            .optional => |o| isAllocatorRequired(o.child),
            else => @compileError("invalid type " ++ @typeName(T) ++ ", unsupported types for scanning"),
        };
    }

    pub fn scanAllAlloc(self: *Self, comptime T: type, allocator: mem.Allocator) !Parsed(T) {
        var arena = heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const source = try self.reader.allocRemaining(arena_allocator, .limited(f_max_size));
        self.cursor.setSource(source);
        const v = try self.scanRaw(T, arena_allocator);
        return Parsed(T).init(arena, v);
    }

    pub fn scanLineAlloc(self: *Self, comptime T: type, allocator: mem.Allocator) !Parsed(T) {
        var arena = heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const source = self.reader.takeDelimiter(l_delim) catch |err| switch (err) {
            error.StreamTooLong => self.reader.buffered(),
            else => return err,
        } orelse return ScanError.NoNextWord;
        self.cursor.setSource(source);
        const v = try self.scanRaw(T, arena_allocator);
        return Parsed(T).init(arena, v);
    }

    pub fn scanLine(self: *Self, comptime T: type) !T {
        comptime if (isAllocatorRequired(T)) @compileError("invalid type " ++ @typeName(T) ++ " for scanLine, use scanLineAlloc instead");
        const source = self.reader.takeDelimiter(l_delim) catch |err| switch (err) {
            error.StreamTooLong => self.reader.buffered(),
            else => return err,
        } orelse return ScanError.NoNextWord;
        self.cursor.setSource(source);
        return try self.scanRaw(T, null);
    }
};

pub const Printer = struct {
    const Self = @This();
    writer: *std.io.Writer,

    fn init(writer: *std.io.Writer) Printer {
        return .{ .writer = writer };
    }

    fn Packet(comptime T: type) type {
        return struct {
            printer: *Self,
            value: T,

            pub fn format(self: @This(), writer: *std.io.Writer) !void {
                _ = writer;
                try self.printer.printRaw(self.value);
            }
        };
    }

    pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const fields = meta.fields(@TypeOf(args));
        comptime var packet_types: [fields.len]type = undefined;

        const Runtime = struct {
            fn Type(comptime T: type) type {
                return switch (@typeInfo(T)) {
                    .comptime_int => isize,
                    .comptime_float => f64,
                    else => T,
                };
            }
        };

        comptime var i: usize = 0;

        inline while (i < fields.len) : (i += 1) {
            packet_types[i] = Packet(Runtime.Type(fields[i].type));
        }

        const Packets = meta.Tuple(&packet_types);
        var packets: Packets = undefined;

        inline for (fields) |field| {
            @field(packets, field.name) = Packet(Runtime.Type(field.type)){
                .printer = self,
                .value = @field(args, field.name),
            };
        }

        try self.writer.print(fmt, packets);
    }

    fn printRaw(self: *Self, value: anytype) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .int => |i| {
                if (i.bits == 8 and i.signedness == .unsigned) {
                    _ = try self.writer.writeByte(value);
                } else {
                    try self.writer.print("{d}", .{value});
                }
            },
            .float => try self.writer.print("{d}", .{value}),
            .pointer => |p| {
                switch (p.size) {
                    .one => {
                        switch (@typeInfo(p.child)) {
                            .array => |a| try self.printRaw(@as([]const a.child, value)),
                            else => try self.printRaw(@as(p.child, value.*)),
                        }
                    },
                    .slice => {
                        switch (@typeInfo(p.child)) {
                            .pointer => |pp| {
                                switch (pp.size) {
                                    .one => try self.printRaw(@as([]const p.child, value)),
                                    .slice => try self.printLs(p.child, value),
                                    else => @compileError("invalid type " ++ @typeName(p.child) ++ ", not one or slice size pointers are not supported for printing"),
                                }
                            },
                            .array => try self.printLs(p.child, value),
                            else => if (p.child == u8)
                                try self.writer.print("{s}", .{value})
                            else
                                try self.printWs(p.child, value),
                        }
                    },
                    else => @compileError("invalid type " ++ @typeName(T) ++ ", not one or slice size pointers are not supported for printing"),
                }
            },
            .array => |a| try self.printRaw(@as([]const a.child, &value)),
            .@"struct" => |s| {
                if (@hasDecl(T, print_fn_decl_name)) {
                    return try value.print(self);
                }
                comptime var i: usize = 0;
                const sep = if (s.is_tuple) w_delim else l_delim;
                inline while (i < s.fields.len) : (i += 1) {
                    const field = s.fields[i];
                    try self.printRaw(@field(value, field.name));
                    if (i != s.fields.len - 1) try self.writer.writeByte(sep);
                }
            },
            .comptime_int => try self.printRaw(@as(isize, value)),
            .comptime_float => try self.printRaw(@as(f64, value)),
            else => @compileError("invalid type " ++ @typeName(T) ++ ", unsupported types for printing"),
        }
    }

    fn printChildren(self: *Self, comptime Child: type, value: []const Child, sep: u8) !void {
        var i: usize = 0;
        while (i < value.len) : (i += 1) {
            try self.printRaw(value[i]);
            if (i != value.len - 1) {
                try self.writer.writeByte(sep);
            }
        }
    }

    inline fn printWs(self: *Self, comptime Child: type, value: []const Child) !void {
        try self.printChildren(Child, value, w_delim);
    }

    inline fn printLs(self: *Self, comptime Child: type, value: []const Child) !void {
        try self.printChildren(Child, value, l_delim);
    }
};

pub fn interact(
    allocator: mem.Allocator,
    reader: *std.io.Reader,
    writer: *std.io.Writer,
    comptime solver: fn (mem.Allocator, *Scanner, *Printer) anyerror!void,
) !void {
    var scanner = Scanner.init(reader);
    var printer = Printer.init(writer);
    try solver(allocator, &scanner, &printer);
    try printer.printRaw(l_token);
    try writer.flush();
}

pub fn interactStdio(
    allocator: mem.Allocator,
    comptime solver: fn (
        mem.Allocator,
        *Scanner,
        *Printer,
    ) anyerror!void,
) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = fs.File.stdin().readerStreaming(&stdin_buf);
    const reader = &stdin.interface;
    var stdout = fs.File.stdout().writer(&stdout_buf);
    const writer = &stdout.interface;
    try interact(allocator, reader, writer, solver);
}

pub fn DependencySizeSlice(comptime T: type, comptime field_name: []const u8) type {
    return struct {
        const Self = @This();
        const size_field_name = field_name;
        slice: []const T,

        fn scanFixedSizeAlloc(allocator: mem.Allocator, scanner: *Scanner, size: usize) !Self {
            const s = try allocator.alloc(T, size);
            for (s) |*e| {
                e.* = try scanner.scanRaw(T, allocator);
            }
            return Self{ .slice = s };
        }
    };
}

pub fn VerticalSlice(comptime T: type) type {
    return struct {
        const Self = @This();
        slice: []const T,

        fn init(slice: []const T) Self {
            return Self{ .slice = slice };
        }

        fn scanAlloc(allocator: mem.Allocator, scanner: *Scanner) !Self {
            var arr = std.ArrayList(T).empty;
            errdefer arr.deinit(allocator);
            while (true) {
                const v = scanner.scanRaw(T, allocator) catch break;
                try arr.append(allocator, v);
            }
            return Self{ .slice = try arr.toOwnedSlice(allocator) };
        }

        fn print(self: Self, printer: *Printer) std.io.Writer.Error!void {
            try printer.printLs(T, self.slice);
        }
    };
}

// ackit import: off
const testing = std.testing;

test "read words" {
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

test "read lines" {
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

test "scan custom input" {
    const allocator = testing.allocator;
    const s =
        \\a
        \\-10
        \\12.3
        \\abc
        \\-11 22 33.3
        \\defghijklm
        \\1 2 3
        \\4 5 6
        \\7 8 9
        \\
    ;
    const Input = struct {
        c: u8,
        i: i32,
        f: f64,
        s: []const u8,
        t: struct { i: i32, u: u32, f: f64 },
        sa: [10]u8,
        s2: [][]i32,
    };
    var reader = std.io.Reader.fixed(s);
    var scanner = Scanner.init(&reader);
    const parsed = try scanner.scanAllAlloc(Input, allocator);
    const s2: []const []const i32 = &.{
        &.{ 1, 2, 3 },
        &.{ 4, 5, 6 },
        &.{ 7, 8, 9 },
    };
    defer parsed.deinit();
    try testing.expectEqual(@as(u8, 'a'), parsed.value.c);
    try testing.expectEqual(@as(i32, -10), parsed.value.i);
    try testing.expectEqual(@as(f64, 12.3), parsed.value.f);
    try testing.expectEqualStrings("abc", parsed.value.s);
    try testing.expectEqual(@as(@TypeOf(parsed.value.t), .{ .i = -11, .u = 22, .f = 33.3 }), parsed.value.t);
    try testing.expectEqualStrings("defghijklm", &parsed.value.sa);
    var i: usize = 0;
    while (i < s2.len) : (i += 1) {
        try testing.expectEqualSlices(i32, s2[i], parsed.value.s2[i]);
    }
}

test "scan 2d array" {
    const allocator = testing.allocator;
    const s =
        \\1 2 3
        \\-4 -5 -6
        \\7 8 9
        \\
    ;
    const Input = struct { a2: [3][3]i32 };
    const a2: [3][3]i32 = .{
        .{ 1, 2, 3 },
        .{ -4, -5, -6 },
        .{ 7, 8, 9 },
    };
    var reader = std.io.Reader.fixed(s);
    var scanner = Scanner.init(&reader);
    const parsed = try scanner.scanAllAlloc(Input, allocator);
    defer parsed.deinit();
    var i: usize = 0;
    while (i < a2.len) : (i += 1) {
        try testing.expectEqualSlices(i32, &a2[i], &parsed.value.a2[i]);
    }
}

test "scan array slices" {
    const allocator = testing.allocator;
    const s =
        \\1 2 3
        \\-4 -5 -6
        \\7 8 9
        \\
    ;
    const Input = struct { a2: [][3]i32 };
    const as: []const [3]i32 = &.{
        .{ 1, 2, 3 },
        .{ -4, -5, -6 },
        .{ 7, 8, 9 },
    };
    var reader = std.io.Reader.fixed(s);
    var scanner = Scanner.init(&reader);
    const parsed = try scanner.scanAllAlloc(Input, allocator);
    defer parsed.deinit();
    var i: usize = 0;
    while (i < as.len) : (i += 1) {
        try testing.expectEqualSlices(i32, &as[i], &parsed.value.a2[i]);
    }
}

test "scan slice arrays" {
    const allocator = testing.allocator;
    const s =
        \\1 2 3
        \\-4 -5 -6
        \\7 8 9
        \\
    ;
    const Input = struct { a2: [3][]i32 };
    const as: [3][]const i32 = .{
        &.{ 1, 2, 3 },
        &.{ -4, -5, -6 },
        &.{ 7, 8, 9 },
    };
    var reader = std.io.Reader.fixed(s);
    var scanner = Scanner.init(&reader);
    const parsed = try scanner.scanAllAlloc(Input, allocator);
    defer parsed.deinit();
    var i: usize = 0;
    while (i < as.len) : (i += 1) {
        try testing.expectEqualSlices(i32, as[i], parsed.value.a2[i]);
    }
}

test "scan optional words" {
    const s =
        \\1 a
        \\2 b 2.2
        \\3
        \\
    ;
    const Row = struct { i: u32, c: ?u8, f: ?f64 };
    const expected: [3]Row = .{
        .{ .i = 1, .c = 'a', .f = null },
        .{ .i = 2, .c = 'b', .f = 2.2 },
        .{ .i = 3, .c = null, .f = null },
    };
    var reader = std.io.Reader.fixed(s);
    var scanner = Scanner.init(&reader);
    var i: u32 = 0;
    while (i < expected.len) : (i += 1) {
        const actual = try scanner.scanLine(Row);
        try testing.expectEqual(expected[i], actual);
    }
}

test "scan dependency size slice" {
    const allocator = testing.allocator;
    const s =
        \\3
        \\10
        \\11
        \\12
        \\5
        \\13 a
        \\14 b
        \\15 c
        \\16 d
        \\17 e
    ;
    const Input = struct {
        n: u32,
        s1: DependencySizeSlice(u32, "n"),
        m: u32,
        s2: DependencySizeSlice(meta.Tuple(&.{ u32, u8 }), "m"),
    };
    const expected_s1 = [_]u32{ 10, 11, 12 };
    const expected_s2 = [_]meta.Tuple(&.{ u32, u8 }){
        .{ 13, 'a' },
        .{ 14, 'b' },
        .{ 15, 'c' },
        .{ 16, 'd' },
        .{ 17, 'e' },
    };
    var reader = std.io.Reader.fixed(s);
    var scanner = Scanner.init(&reader);
    const parsed = try scanner.scanAllAlloc(Input, allocator);
    defer parsed.deinit();
    try testing.expectEqualSlices(u32, &expected_s1, parsed.value.s1.slice);
    try testing.expectEqualSlices(meta.Tuple(&.{ u32, u8 }), &expected_s2, parsed.value.s2.slice);
}

test "scan vertical slice" {
    const allocator = testing.allocator;
    const s =
        \\1
        \\2
        \\3
        \\4
        \\5
    ;
    const Input = struct { vs: VerticalSlice(u32) };
    const expected = [_]u32{ 1, 2, 3, 4, 5 };
    var reader = std.io.Reader.fixed(s);
    var scanner = Scanner.init(&reader);
    const parsed = try scanner.scanAllAlloc(Input, allocator);
    defer parsed.deinit();
    try testing.expectEqualSlices(u32, &expected, parsed.value.vs.slice);
}

test "scan multiple lines with alloc" {
    const allocator = testing.allocator;
    const s =
        \\1 a
        \\2 b
        \\3 c
        \\4 d
        \\5 e
    ;
    const Row = struct { i: u32, c: []const u8 };
    const expected = [_]Row{
        .{ .i = 1, .c = "a" },
        .{ .i = 2, .c = "b" },
        .{ .i = 3, .c = "c" },
        .{ .i = 4, .c = "d" },
        .{ .i = 5, .c = "e" },
    };
    var reader = std.io.Reader.fixed(s);
    var scanner = Scanner.init(&reader);
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        const parsed = try scanner.scanLineAlloc(Row, allocator);
        defer parsed.deinit();
        const actual = parsed.value;
        try testing.expectEqual(expected[i].i, actual.i);
        try testing.expectEqualStrings(expected[i].c, actual.c);
    }
}

test "scan multiple lines without alloc" {
    const s =
        \\1 a
        \\2 b
        \\3 c
        \\4 d
        \\5 e
    ;
    const Row = struct { i: u32, c: u8 };
    const expected = [_]Row{
        .{ .i = 1, .c = 'a' },
        .{ .i = 2, .c = 'b' },
        .{ .i = 3, .c = 'c' },
        .{ .i = 4, .c = 'd' },
        .{ .i = 5, .c = 'e' },
    };
    var actual: [5]Row = undefined;
    var reader = std.io.Reader.fixed(s);
    var scanner = Scanner.init(&reader);
    for (&actual) |*e| {
        e.* = try scanner.scanLine(Row);
    }
    try testing.expectEqualSlices(Row, &expected, &actual);
}

test "print custom output" {
    const expected =
        \\c
        \\-1
        \\2.3
        \\abc
        \\x -2 3.3
        \\0123456789
        \\1 2 3
        \\4 5 6
        \\7 8 9
    ;
    const Output = struct {
        c: u8,
        i: i32,
        f: f64,
        s: []const u8,
        t: meta.Tuple(&.{ u8, i32, f64 }),
        a: [10]u8,
        s2: []const []const i32,
    };
    var a: [10]u8 = undefined;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        a[i] = @as(u8, @intCast(i)) + '0';
    }
    const s2 = &.{
        &.{ 1, 2, 3 },
        &.{ 4, 5, 6 },
        &.{ 7, 8, 9 },
    };
    const output = Output{
        .c = 'c',
        .i = -1,
        .f = 2.3,
        .s = "abc",
        .t = .{ 'x', -2, 3.3 },
        .a = a,
        .s2 = s2,
    };
    var buf: [4092]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    var printer = Printer.init(&writer);
    try printer.printRaw(output);
    try writer.flush();
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "print comptime value" {
    const expected =
        \\-1 2.3 hello
    ;
    var buf: [4092]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    var printer = Printer.init(&writer);
    try printer.printRaw(.{ -1, 2.3, "hello" });
    try writer.flush();
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "print pointer of pointer" {
    const expected =
        \\-1
        \\2.3
        \\a
    ;
    const Output = struct { i: i32, f: f64, c: u8 };
    const output = Output{ .i = -1, .f = 2.3, .c = 'a' };
    var buf: [4092]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    var printer = Printer.init(&writer);
    try printer.printRaw(&&output);
    try writer.flush();
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "print with format" {
    const expected =
        \\-1
        \\2.3
        \\4 5 6
        \\abc
        \\x
        \\y
        \\z
    ;
    var buf: [4092]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    var printer = Printer.init(&writer);
    try printer.print("{f}\n{f}\n{f}\n{f}\n{f}", .{
        -1,
        2.3,
        &.{ 4, 5, 6 },
        "abc",
        struct { x: u8, y: u8, z: u8 }{
            .x = 'x',
            .y = 'y',
            .z = 'z',
        },
    });
    try writer.flush();
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "print 2d array" {
    const expected =
        \\1 2 3
        \\-4 -5 -6
        \\7 8 9
    ;
    const Output = struct { a2: [3][3]i32 };
    const a2 = .{
        .{ 1, 2, 3 },
        .{ -4, -5, -6 },
        .{ 7, 8, 9 },
    };
    const output = Output{ .a2 = a2 };
    var buf: [4092]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    var printer = Printer.init(&writer);
    try printer.printRaw(output);
    try writer.flush();
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "print array slices" {
    const expected =
        \\1 2 3
        \\-4 -5 -6
        \\7 8 9
    ;
    const Output = struct { as: []const [3]i32 };
    const as = &.{
        .{ 1, 2, 3 },
        .{ -4, -5, -6 },
        .{ 7, 8, 9 },
    };
    const output = Output{ .as = as };
    var buf: [4092]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    var printer = Printer.init(&writer);
    try printer.printRaw(output);
    try writer.flush();
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "print slice arrays" {
    const expected =
        \\1 2 3
        \\-4 -5 -6
        \\7 8 9
    ;
    const Output = struct { sa: [3][]const i32 };
    const sa = .{
        &.{ 1, 2, 3 },
        &.{ -4, -5, -6 },
        &.{ 7, 8, 9 },
    };
    const output = Output{ .sa = sa };
    var buf: [4092]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    var printer = Printer.init(&writer);
    try printer.printRaw(output);
    try writer.flush();
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "print vertical slice" {
    const expected =
        \\1
        \\2
        \\3
        \\4
        \\5
    ;
    const Output = struct { vs: VerticalSlice(u32) };
    const vs = VerticalSlice(u32).init(&[_]u32{ 1, 2, 3, 4, 5 });
    const output = Output{ .vs = vs };
    var buf: [4096]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    var printer = Printer.init(&writer);
    try printer.printRaw(output);
    try writer.flush();
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "interact like an echo" {
    const Input = struct { s: []const u8 };
    const Output = struct { s: []const u8 };
    const input_buf = "Hello\n";
    var output_buf: [input_buf.len + 1]u8 = undefined;
    var reader = std.io.Reader.fixed(input_buf);
    var writer = std.io.Writer.fixed(&output_buf);
    const s = struct {
        fn echo(
            allocator: mem.Allocator,
            scanner: *Scanner,
            printer: *Printer,
        ) !void {
            const parsed = try scanner.scanAllAlloc(Input, allocator);
            defer parsed.deinit();
            const input = parsed.value;
            const output = Output{ .s = input.s };
            try printer.printRaw(output);
        }
    };

    try interact(
        testing.allocator,
        &reader,
        &writer,
        s.echo,
    );
    try testing.expectEqualStrings(input_buf, output_buf[0..input_buf.len]);
}
