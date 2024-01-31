# ackit
`ackit` is a console application that generates templates for the Zig language that can be used when submitting code to AtCoder. It also includes a Zig language library to handle the input and output of AtCoder problems.


## Installation
To install ackit, you'll need Zig version 0.11.0. You can install it with the following commands:

```bash
git clone https://github.com/setsunica/ackit-zig.git
cd ackit-zig
zig build -Doptimize=ReleaseSafe
```
The executable will be generated in the zig-out/bin directory.


## Generating Templates
To generate templates, use the following command:

```bash
ackit temp <output_path>
```

## Implementing Templates
To use the generated template, you'll need to implement the following:

### Input with scanner / Output with printer
Modify the definition of the input type and output type within the template. Supported types include:

* Integer types (e.g. i32, u32)
* Floating-point types (e.g. f32, f64)
* Arrays and slices (up to 2D)
* Structures (including tuples)
* Optional (is null if parsing fails, used with input only)
* ackitio.DependencySizeSlice (contains a slice with sizes dependent on other field values, used with input only)
* ackitio.VerticalSlice (contains a slice with vertically variable length elements)

### Example of scanning input
```
A B
S
```

* A is an integer
* B is a floating-point number
* S is a string

```zig
const Input = struct { a: i32, b: f64, s: []const u8 };
const parsed = try scanner.scanAllAlloc(Input, allocator);
defer parsed.deinit();
const input = parsed.value;
```

### Example of printing output
```
A B
S
```

* A is an integer
* B is a floating-point number
* S is a string

```zig
const Output = struct { t: std.meta.Tuple(&.{i32, f64}), s: []const u8 };
const output = Output{ .t = .{ 1, 2.3 }, .s = "abc" };
try printer.print(output);
```
Since the output will have a new line for each field, you must use `std.meta.Tuple` to output multiple types of elements on a single line.
If the type can be resolved by inference, an anonymous structure may be used to omit the definition of the `Output` structure.

### Implementing the `solve` Function
Implement the solve function within the template to solve the problem:

```zig
fn solve(
    allocator: std.mem.Allocator,
    scanner: *ackitio.Scanner(ackitio.StdinReader),
    printer: *ackitio.Printer(ackitio.StdoutWriter),
) !void {
    const parsed = try scanner.scanAllAlloc(Input, allocator);
    defer parsed.deinit();
    const input = input.value;
    // Implement your solution here.
    const output = ...
    try printer.print(output);
}
```


## Testing Input and Output
You can use the `ackitio.interact` function to test input and output using custom `std.io.Reader` and `std.io.Writer`.
Note that Zig version 0.10.1 is required to run the test. This equals the version used by AtCoder as of January 2, 2024.


### Example Test
Here's an example test:

```zig
test "interact like an echo" {
    const Input = struct { s: []const u8 };
    const Output = struct { s: []const u8 };
    var input_buf = "Hello\n";
    var output_buf: [input_buf.len]u8 = undefined;
    var input_stream = std.io.fixedBufferStream(input_buf);
    var output_stream = std.io.fixedBufferStream(&output_buf);
    const reader = input_stream.reader();
    const writer = output_stream.writer();

    const s = struct {
        fn echo(
            allocator: std.mem.Allocator,
            scanner: *ackitio.Scanner(@TypeOf(reader)),
            printer: *ackitio.Printer(@TypeOf(writer)),
        ) !void {
            const parsed = try scanner.scanAllAlloc(Input, allocator);
            defer parsed.deinit();
            const input = parsed.value;
            const output = Output{ .s = input.s };
            try printer.print(output);
        }
    };

    try ackitio.interact(
        std.testing.allocator,
        reader,
        writer,
        s.echo,
    );

    try std.testing.expectEqualStrings(input_buf, &output_buf);
}
```
