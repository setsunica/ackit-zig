# ackit
`ackit` is a console application that generates templates for the Zig language that can be used when submitting code to AtCoder. It also includes a Zig language library to handle the input and output of AtCoder questions.


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

### Defining Input/Output Types
Modify the definition of the Input structure within the template. Supported types include:

* Integer types (e.g. i32, u32)
* Floating-point types (e.g. f32, f64)
* Arrays and slices (up to 2D)
* Structures (including tuples)
* Example Input Type Definition:

### Example Input Type Definition
```
A B
S
```

* A is an integer
* B is a floating-point number
* S is a string

```zig
const Input = struct { a: i32, b: f64, s: []const u8 };
```

### Example Output Type Definition
```
A B
S
```

* A is an integer
* B is a floating-point number
* S is a string

```zig
const Output = struct { t: std.meta.Tuple(&.{i32, f64}), s: []const u8 }
```
Since the output will have a new line for each field, you must use `std.meta.Tuple` to output multiple types of elements on a single line.
If the type can be resolved by inference, an anonymous structure may be used to omit the definition of the `Output` structure.

### Implementing the `solve` Function
Implement the solve function within the template to solve the problem:

```zig
fn solve(input: Input, printer: *io.Printer(io.StdoutWriter)) !void {
    // Implement your solution here.
    const output = ...
    try printer.print(output);
}
```


## Testing Input and Output
You can use the `ackit.io.interact` function to test input and output using custom `std.io.Reader` and `std.io.Writer`.
Note that Zig version 0.10.1 is required to run the test. This equals the version used by AtCoder as of January 2, 2024.


### Example Test
Here's an example test:

```zig
test "interact like an echo" {
    const allocator = std.testing.allocator;
    const Input = struct { s: []const u8 };
    const Output = struct { s: []const u8 };
    const s = struct {
        fn solve(input: Input, printer: *ackit.io.Printer(std.io.FixedBufferStream([]u8).Writer)) !void {
            const output = Output{ .s = input.s };
            try printer.print(output);
        }
    };
    var input_buf = "Hello\n";
    var output_buf: [input_buf.len]u8 = undefined;
    var input_stream = std.io.fixedBufferStream(input_buf);
    var output_stream = std.io.fixedBufferStream(&output_buf);
    try ackit.io.interact(
        Input,
        allocator,
        input_stream.reader(),
        output_stream.writer(),
        4096,
        s.solve,
    );
    try std.testing.expectEqualStrings(input_buf, &output_buf);
}
```
