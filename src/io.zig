const std = @import("std");
pub const StdoutWriter = std.io.BufferedWriter(4096, std.fs.File.Writer).Writer;

const scan_fn_decl_name = "scan";
const print_fn_decl_name = "print";
const size_field_name_decl_name = "size_field_name";

pub const ScanError = error{
    NoNextWord,
    NoNextLine,
    InvalidArraySize,
};

fn Parsed(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        fn init(arena: std.heap.ArenaAllocator, value: T) Parsed(T) {
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
    l_iter: std.mem.TokenIterator(u8),
    w_iter: std.mem.TokenIterator(u8),

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

    fn readL(self: *Cursor) ?std.mem.TokenIterator(u8) {
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

    fn countRestW(self: *Cursor) usize {
        if (self.w_iter.peek() == null) {
            const l = self.l_iter.next() orelse return 0;
            self.w_iter = std.mem.tokenize(u8, l, w_token);
        }
        const rest = self.w_iter.rest();
        if (rest.len == 0) return 0;
        return std.mem.count(u8, rest, w_token) + 1;
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
        return switch (@typeInfo(T)) {
            .Int => |i| blk: {
                const w = self.cursor.readW() orelse return error.NoNextWord;
                break :blk if (i.bits == 8 and i.signedness == .unsigned)
                    w[0]
                else
                    std.fmt.parseInt(@Type(.{ .Int = i }), w, 10);
            },
            .Float => |f| blk: {
                const w = self.cursor.readW() orelse return error.NoNextWord;
                break :blk try std.fmt.parseFloat(@Type(.{ .Float = f }), w);
            },
            .Pointer => |p| blk: {
                if (p.size != .Slice) @compileError("invalid type " ++ @typeName(T) ++ ", non-slice pointers are not supported for scanning");
                if (p.child == u8) return self.cursor.readW() orelse return error.NoNextWord;
                break :blk switch (@typeInfo(p.child)) {
                    .Pointer => |pp| if (pp.size == .Slice)
                        try self.scanLs(pp.child)
                    else
                        @compileError("invalid type " ++ @typeName(p.child) ++ ", non-slice pointers are not supported for scanning"),
                    .Array => try self.scanArrays(p.child),
                    else => try self.scanWs(p.child) orelse error.NoNextLine,
                };
            },
            .Array => try self.scanArray(T) orelse error.NoNextWord,
            .Struct => |s| blk: {
                if (@hasDecl(T, scan_fn_decl_name) and !@hasDecl(T, size_field_name_decl_name)) {
                    break :blk try T.scan(self.arena.allocator(), self);
                }
                var v: T = undefined;
                inline for (s.fields) |field| {
                    const field_type = field.field_type;
                    const is_struct = @typeInfo(field_type) == .Struct;
                    if (is_struct and @hasDecl(field_type, scan_fn_decl_name) and @hasDecl(field_type, size_field_name_decl_name)) {
                        const size = @field(v, field_type.size_field_name);
                        @field(v, field.name) = try field_type.scan(self.arena.allocator(), self, size);
                    } else {
                        @field(v, field.name) = try self.scan(field_type);
                    }
                }
                break :blk v;
            },
            else => @compileError("invalid type " ++ @typeName(T) ++ ", unsupported types for scanning"),
        };
    }

    fn scanWs(self: *Scanner, comptime Child: type) !?[]Child {
        const restCount = self.cursor.countRestW();
        if (restCount == 0) return null;
        var arr = std.ArrayList(Child).init(self.arena.allocator());
        var i: usize = 0;
        while (i < restCount) : (i += 1) {
            const v = try self.scan(Child);
            try arr.append(v);
        }
        return arr.toOwnedSlice();
    }

    fn scanLs(self: *Scanner, comptime Child: type) ![][]Child {
        var arr = std.ArrayList([]Child).init(self.arena.allocator());
        while (try self.scanWs(Child)) |vs| {
            try arr.append(vs);
        }
        return arr.toOwnedSlice();
    }

    fn scanArray(self: *Scanner, comptime Array: type) !?Array {
        const restCount = self.cursor.countRestW();
        if (restCount == 0) return null;
        const a = @typeInfo(Array).Array;
        if (a.child == u8) {
            const s = (self.cursor.readW().?);
            if (s.len < a.len) {
                return error.InvalidArraySize;
            }
            return s[0..a.len].*;
        }
        var r: [a.len]a.child = undefined;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            r[i] = try self.scan(a.child);
        }
        return r;
    }

    fn scanArrays(self: *Scanner, comptime Array: type) ![]Array {
        var arrs = std.ArrayList(Array).init(self.arena.allocator());
        while (try self.scanArray(Array)) |arr| {
            try arrs.append(arr);
        }
        return arrs.toOwnedSlice();
    }
};

fn parse(comptime T: type, allocator: std.mem.Allocator, reader: anytype, max_size: usize) !Parsed(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const source = try reader.readAllAlloc(arena.allocator(), max_size);
    var scanner = Scanner.init(&arena, source);
    const v = try scanner.scan(T);
    return Parsed(T).init(arena, v);
}

pub fn Printer(comptime WriterType: type) type {
    return struct {
        const Self = @This();
        writer: WriterType,

        fn init(writer: WriterType) Printer(WriterType) {
            return .{ .writer = writer };
        }

        pub fn print(self: *Self, value: anytype) WriterType.Error!void {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .Int => |i| {
                    if (i.bits == 8 and i.signedness == .unsigned) {
                        _ = try self.writer.writeByte(value);
                    } else {
                        try self.writer.print("{d}", .{value});
                    }
                },
                .Float => try self.writer.print("{d}", .{value}),
                .Pointer => |p| {
                    if (p.size != .Slice) @compileError("invalid type " ++ @typeName(T) ++ ", non-slice pointers are not supported for printing");
                    switch (@typeInfo(p.child)) {
                        .Pointer => |pp| {
                            if (pp.size == .Slice)
                                try self.printLs(p.child, value)
                            else
                                @compileError("invalid type " ++ @typeName(p.child) ++ ", non-slice pointers are not supported for printing");
                        },
                        .Array => try self.printLs(p.child, value),
                        else => if (p.child == u8)
                            try self.writer.print("{s}", .{value})
                        else
                            try self.printWs(p.child, value),
                    }
                },
                .Array => |a| try self.print(@as([]const a.child, &value)),
                .Struct => |s| {
                    if (@hasDecl(T, print_fn_decl_name)) {
                        return try value.print(WriterType, self);
                    }
                    comptime var i: usize = 0;
                    const sep = if (s.is_tuple) w_token else l_token;
                    inline while (i < s.fields.len) : (i += 1) {
                        const field = s.fields[i];
                        try self.print(@field(value, field.name));
                        if (i != s.fields.len - 1) _ = try self.writer.write(sep);
                    }
                },
                else => @compileError("invalid type " ++ @typeName(T) ++ ", unsupported types for printing"),
            }
        }

        fn printChildren(self: *Self, comptime Child: type, value: []const Child, sep: []const u8) !void {
            var i: usize = 0;
            while (i < value.len) : (i += 1) {
                try self.print(value[i]);
                if (i != value.len - 1) {
                    _ = try self.writer.write(sep);
                }
            }
        }

        inline fn printWs(self: *Self, comptime Child: type, value: []const Child) !void {
            try self.printChildren(Child, value, w_token);
        }

        inline fn printLs(self: *Self, comptime Child: type, value: []const Child) !void {
            try self.printChildren(Child, value, l_token);
        }
    };
}

pub fn interact(
    comptime InputType: type,
    allocator: std.mem.Allocator,
    reader: anytype,
    writer: anytype,
    input_max_size: usize,
    solver: fn (InputType, *Printer(@TypeOf(writer))) anyerror!void,
) !void {
    const input = try parse(InputType, allocator, reader, input_max_size);
    defer input.deinit();
    var printer = Printer(@TypeOf(writer)).init(writer);
    try solver(input.value, &printer);
    try printer.print(@as([]const u8, l_token));
}

pub fn interactStdio(
    comptime InputType: type,
    allocator: std.mem.Allocator,
    input_max_size: usize,
    solver: fn (InputType, *Printer(StdoutWriter)) anyerror!void,
) !void {
    const sr = std.io.getStdIn().reader();
    const sw = std.io.getStdOut().writer();
    var br = std.io.bufferedReader(sr);
    var bw = std.io.bufferedWriter(sw);
    const stdin = br.reader();
    const stdout = bw.writer();
    try interact(
        InputType,
        allocator,
        stdin,
        stdout,
        input_max_size,
        solver,
    );
    try bw.flush();
}

pub fn DependSizedSlice(comptime T: type, comptime field_name: []const u8) type {
    return struct {
        const Self = @This();
        const size_field_name = field_name;
        slice: []const T,

        fn scan(allocator: std.mem.Allocator, scanner: *Scanner, size: usize) !Self {
            var s = try allocator.alloc(T, size);
            for (s) |*e| {
                e.* = try scanner.scan(T);
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
            return Self{.slice = slice};
        }

        fn scan(allocator: std.mem.Allocator, scanner: *Scanner) !Self {
            var arr = std.ArrayList(T).init(allocator);
            while (true) {
                const v = scanner.scan(T) catch break;
                try arr.append(v);
            }
            return Self{ .slice = arr.toOwnedSlice() };
        }

        fn print(self: Self, comptime WriterType: type, printer: *Printer(WriterType)) WriterType.Error!void {
            try printer.printLs(T, self.slice);
        }
    };
}

// Below is the test code.
const testing = std.testing;

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
    var allocator = testing.allocator;
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
    var stream = std.io.fixedBufferStream(s);
    const parsed = try parse(Input, allocator, stream.reader(), 4092);
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
    try testing.expectEqual(parsed.value.t, .{ .i = -11, .u = 22, .f = 33.3 });
    try testing.expectEqualStrings("defghijklm", &parsed.value.sa);
    var i: usize = 0;
    while (i < s2.len) : (i += 1) {
        try testing.expectEqualSlices(i32, s2[i], parsed.value.s2[i]);
    }
}

test "parse 2d array" {
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
    var stream = std.io.fixedBufferStream(s);
    const parsed = try parse(Input, allocator, stream.reader(), 4096);
    defer parsed.deinit();
    var i: usize = 0;
    while (i < a2.len) : (i += 1) {
        try testing.expectEqualSlices(i32, &a2[i], &parsed.value.a2[i]);
    }
}

test "parse array slices" {
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
    var stream = std.io.fixedBufferStream(s);
    const parsed = try parse(Input, allocator, stream.reader(), 4096);
    defer parsed.deinit();
    var i: usize = 0;
    while (i < as.len) : (i += 1) {
        try testing.expectEqualSlices(i32, &as[i], &parsed.value.a2[i]);
    }
}

test "parse slice arrays" {
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
    var stream = std.io.fixedBufferStream(s);
    const parsed = try parse(Input, allocator, stream.reader(), 4096);
    defer parsed.deinit();
    var i: usize = 0;
    while (i < as.len) : (i += 1) {
        try testing.expectEqualSlices(i32, as[i], parsed.value.a2[i]);
    }
}

test "parse depend sized slice" {
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
        s1: DependSizedSlice(u32, "n"),
        m: u32,
        s2: DependSizedSlice(std.meta.Tuple(&.{ u32, u8 }), "m"),
    };
    const expected_s1 = [_]u32{ 10, 11, 12 };
    const expected_s2 = [_]std.meta.Tuple(&.{ u32, u8 }){
        .{ 13, 'a' },
        .{ 14, 'b' },
        .{ 15, 'c' },
        .{ 16, 'd' },
        .{ 17, 'e' },
    };
    var stream = std.io.fixedBufferStream(s);
    const parsed = try parse(Input, allocator, stream.reader(), 4096);
    defer parsed.deinit();
    try testing.expectEqualSlices(u32, &expected_s1, parsed.value.s1.slice);
    try testing.expectEqualSlices(std.meta.Tuple(&.{ u32, u8 }), &expected_s2, parsed.value.s2.slice);
}

test "parse vertical slice" {
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
    var stream = std.io.fixedBufferStream(s);
    const parsed = try parse(Input, allocator, stream.reader(), 4096);
    defer parsed.deinit();
    try testing.expectEqualSlices(u32, &expected, parsed.value.vs.slice);
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
        t: std.meta.Tuple(&.{ u8, i32, f64 }),
        a: [10]u8,
        s2: []const []const i32,
    };
    var a: [10]u8 = undefined;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        a[i] = @intCast(u8, i) + '0';
    }
    var s2 = &.{
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
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    var printer = Printer(@TypeOf(writer)).init(writer);
    try printer.print(output);
    try testing.expectEqualStrings(expected, stream.getWritten());
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
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    var printer = Printer(@TypeOf(writer)).init(writer);
    try printer.print(output);
    try testing.expectEqualStrings(expected, stream.getWritten());
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
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    var printer = Printer(@TypeOf(writer)).init(writer);
    try printer.print(output);
    try testing.expectEqualStrings(expected, stream.getWritten());
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
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    var printer = Printer(@TypeOf(writer)).init(writer);
    try printer.print(output);
    try testing.expectEqualStrings(expected, stream.getWritten());
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
    const vs = VerticalSlice(u32).init(&[_]u32{1, 2, 3, 4, 5});
    const output = Output{.vs = vs};
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    var printer = Printer(@TypeOf(writer)).init(writer);
    try printer.print(output);
    try testing.expectEqualSlices(u8, expected, stream.getWritten());
}

test "interact like an echo" {
    const allocator = testing.allocator;
    const Input = struct { s: []const u8 };
    const Output = struct { s: []const u8 };
    const s = struct {
        fn echo(input: Input, printer: *Printer(std.io.FixedBufferStream([]u8).Writer)) !void {
            const output = Output{ .s = input.s };
            try printer.print(output);
        }
    };
    var input_buf = "Hello\n";
    var output_buf: [input_buf.len]u8 = undefined;
    var input_stream = std.io.fixedBufferStream(input_buf);
    var output_stream = std.io.fixedBufferStream(&output_buf);
    try interact(
        Input,
        allocator,
        input_stream.reader(),
        output_stream.writer(),
        4096,
        s.echo,
    );
    try testing.expectEqualStrings(input_buf, &output_buf);
}
