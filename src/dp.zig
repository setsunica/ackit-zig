const std = @import("std");

pub const GraphOptions = struct {
    expand_nodes_prealloc_item_count: usize = 4,
};

pub fn Graph(comptime T: type, comptime W: type, comptime graph_opts: GraphOptions) type {
    const NodeAdj = struct { node: T, weight: W };
    const ExpandNodes = std.SegmentedList(NodeAdj, graph_opts.expand_nodes_prealloc_item_count);
    const ExpandNodesMap = if (T == []const u8) std.StringHashMap(ExpandNodes) else std.AutoHashMap(T, ExpandNodes);

    return struct {
        allocator: std.mem.Allocator,
        expand: ExpandNodesMap,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .expand = ExpandNodesMap.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var iter = self.expand.valueIterator();
            while (iter.next()) |nodes| nodes.deinit(self.allocator);
            self.expand.deinit();
        }

        pub fn put(self: *Self, src: T, dest: T, weight: W) !void {
            const nodes = try self.expand.getOrPut(src);
            if (!nodes.found_existing) {
                nodes.value_ptr.* = ExpandNodes{};
            }
            try nodes.value_ptr.append(self.allocator, .{ .node = dest, .weight = weight });
        }

        pub const Breadcrumb = struct { prev: T, eval: W };
        pub const Visited = if (T == []const u8) std.StringHashMap(Breadcrumb) else std.AutoHashMap(T, Breadcrumb);

        pub const Path = struct {
            start: T,
            goal: T,
            eval: W,
            visited: Visited,

            pub fn deinit(self: *@This()) void {
                self.visited.deinit();
            }

            pub fn nodes(self: @This(), allocator: std.mem.Allocator) ![]T {
                var rev_path = std.ArrayList(T).init(allocator);
                var cur = self.visited.get(self.goal).?;
                if (self.start != self.goal) {
                    try rev_path.append(self.goal);
                    while (cur.prev != self.start) : (cur = self.visited.get(cur.prev).?) {
                        try rev_path.append(cur.prev);
                    }
                }
                try rev_path.append(self.start);
                const result = rev_path.toOwnedSlice();
                std.mem.reverse(T, result);
                return result;
            }
        };

        pub const BfsOptions = struct {
            queue_prealloc_item_count: usize = 128,
        };

        pub fn bfs(
            self: Self,
            start: T,
            goal: T,
            comptime opts: BfsOptions,
        ) !?Path {
            if (!self.expand.contains(start)) return null;

            var visited = Visited.init(self.allocator);
            errdefer visited.deinit();
            try visited.putNoClobber(start, undefined);

            var queue = std.SegmentedList(T, opts.queue_prealloc_item_count){};
            defer queue.deinit(self.allocator);
            try queue.append(self.allocator, start);
            var i: usize = 0;

            return search: while (i < queue.len) : (i += 1) {
                const cur = queue.uncheckedAt(i).*;
                if (cur == goal) {
                    break :search .{
                        .start = start,
                        .goal = goal,
                        .eval = undefined,
                        .visited = visited,
                    };
                }
                var nexts = self.expand.get(cur) orelse continue;
                var iter = nexts.iterator(0);
                while (iter.next()) |next| {
                    const breadcrumb = try visited.getOrPut(next.node);
                    if (breadcrumb.found_existing) continue;
                    breadcrumb.value_ptr.* = .{ .prev = cur, .eval = undefined };
                    try queue.append(self.allocator, next.node);
                }
            } else {
                visited.deinit();
                break :search null;
            };
        }

        pub const DfsOptions = struct {
            stack_prealloc_item_count: usize = 128,
        };

        pub fn dfs(
            self: Self,
            start: T,
            goal: T,
            comptime opts: DfsOptions,
        ) !?Path {
            if (!self.expand.contains(start)) return null;

            var visited = Visited.init(self.allocator);
            errdefer visited.deinit();
            try visited.putNoClobber(start, undefined);

            var stack = std.SegmentedList(T, opts.stack_prealloc_item_count){};
            defer stack.deinit(self.allocator);
            try stack.append(self.allocator, start);

            return search: while (stack.pop()) |cur| {
                if (cur == goal) {
                    break :search .{
                        .start = start,
                        .goal = goal,
                        .eval = undefined,
                        .visited = visited,
                    };
                }
                var nexts = self.expand.get(cur) orelse continue;
                var iter = nexts.iterator(0);
                while (iter.next()) |next| {
                    const breadcrumb = try visited.getOrPut(next.node);
                    if (breadcrumb.found_existing) continue;
                    breadcrumb.value_ptr.* = .{ .prev = cur, .eval = undefined };
                    try stack.append(self.allocator, next.node);
                }
            } else {
                visited.deinit();
                break :search null;
            };
        }

        pub const DijkstraOptions = struct {};

        pub fn dijkstra(
            self: Self,
            start: T,
            goal: T,
            opts: DijkstraOptions,
        ) !?Path {
            _ = opts;
            if (!self.expand.contains(start)) return null;

            var visited = Visited.init(self.allocator);
            errdefer visited.deinit();
            try visited.putNoClobber(start, undefined);

            const Eval = struct { node: T, value: W };
            const local = struct {
                fn compareEvalFn(_: void, a: Eval, b: Eval) std.math.Order {
                    return std.math.order(a.value, b.value);
                }
            };

            var queue = std.PriorityQueue(Eval, void, local.compareEvalFn).init(self.allocator, {});
            defer queue.deinit();
            try queue.add(.{ .node = start, .value = 0 });

            return search: while (queue.removeOrNull()) |cur| {
                if (cur.node == goal) {
                    break :search .{
                        .start = start,
                        .goal = goal,
                        .eval = visited.get(cur.node).?.eval,
                        .visited = visited,
                    };
                }
                var nexts = self.expand.get(cur.node) orelse continue;
                var iter = nexts.iterator(0);
                while (iter.next()) |next| {
                    const breadcrumb = try visited.getOrPut(next.node);
                    const next_eval = cur.value + next.weight;
                    if (breadcrumb.found_existing) {
                        if (next_eval < breadcrumb.value_ptr.*.eval) {
                            breadcrumb.value_ptr.* = .{ .prev = cur.node, .eval = next_eval };
                        }
                    } else breadcrumb.value_ptr.* = .{ .prev = cur.node, .eval = next_eval };
                    try queue.add(.{ .node = next.node, .value = next_eval });
                }
            } else {
                visited.deinit();
                break :search null;
            };
        }
    };
}

pub fn main() !void {
    std.debug.print("hogehoge", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const V = u32;
    var graph = Graph(V, void, .{}).init(allocator);
    defer graph.deinit();
    try graph.put(1, 2, {});
    try graph.put(2, 3, {});
    try graph.put(2, 4, {});
    try graph.put(4, 5, {});
    var path = try graph.bfs(1, 5, .{});
    defer path.?.deinit();
    const nodes = try path.?.nodes(allocator);
    defer allocator.free(nodes);
    std.log.info("{}", .{std.mem.eql(V, &.{ 1, 2, 4, 5 }, nodes)});
}

// ackit import: off
const testing = std.testing;

test "bfs: simple" {
    const allocator = testing.allocator;
    const V = u32;
    var graph = Graph(V, void, .{}).init(allocator);
    defer graph.deinit();
    try graph.put(1, 2, {});
    try graph.put(2, 3, {});
    try graph.put(2, 4, {});
    try graph.put(4, 5, {});
    var path = try graph.bfs(1, 5, .{});
    try testing.expect(path != null);
    defer path.?.deinit();
    const nodes = try path.?.nodes(allocator);
    defer allocator.free(nodes);
    try testing.expectEqualSlices(V, &.{ 1, 2, 4, 5 }, nodes);
}

test "bfs: start is goal" {
    const allocator = testing.allocator;
    const V = u32;
    var graph = Graph(V, void, .{}).init(allocator);
    defer graph.deinit();
    try graph.put(1, 2, {});
    try graph.put(2, 3, {});
    try graph.put(2, 4, {});
    try graph.put(4, 5, {});
    var path = try graph.bfs(1, 1, .{});
    try testing.expect(path != null);
    defer path.?.deinit();
    const nodes = try path.?.nodes(allocator);
    defer allocator.free(nodes);
    try testing.expectEqualSlices(V, &.{1}, nodes);
}

test "bfs: there is no start or goal" {
    const allocator = testing.allocator;
    const V = u32;
    var graph = Graph(V, void, .{}).init(allocator);
    defer graph.deinit();
    try graph.put(1, 2, {});
    try graph.put(2, 3, {});
    try graph.put(2, 4, {});
    try graph.put(4, 5, {});
    const no_start_path = try graph.bfs(99, 5, .{});
    try testing.expect(no_start_path == null);
    const no_goal_path = try graph.bfs(1, 99, .{});
    try testing.expect(no_goal_path == null);
    const no_start_and_goal_path = try graph.bfs(99, 99, .{});
    try testing.expect(no_start_and_goal_path == null);
}

test "dfs: simple" {
    const allocator = testing.allocator;
    const V = u32;
    var graph = Graph(V, void, .{}).init(allocator);
    defer graph.deinit();
    try graph.put(1, 2, {});
    try graph.put(2, 3, {});
    try graph.put(2, 4, {});
    try graph.put(4, 5, {});
    var path = try graph.dfs(1, 5, .{});
    try testing.expect(path != null);
    defer path.?.deinit();
    const nodes = try path.?.nodes(allocator);
    defer allocator.free(nodes);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 4, 5 }, nodes);
}

test "dfs: start is goal" {
    const allocator = testing.allocator;
    const V = u32;
    var graph = Graph(V, void, .{}).init(allocator);
    defer graph.deinit();
    try graph.put(1, 2, {});
    try graph.put(2, 3, {});
    try graph.put(2, 4, {});
    try graph.put(4, 5, {});
    var path = try graph.dfs(1, 1, .{});
    try testing.expect(path != null);
    defer path.?.deinit();
    const nodes = try path.?.nodes(allocator);
    defer allocator.free(nodes);
    try testing.expectEqualSlices(V, &.{1}, nodes);
}

test "dfs: there is no start or goal" {
    const allocator = testing.allocator;
    const V = u32;
    var graph = Graph(V, void, .{}).init(allocator);
    defer graph.deinit();
    try graph.put(1, 2, {});
    try graph.put(2, 3, {});
    try graph.put(2, 4, {});
    try graph.put(4, 5, {});
    const no_start_path = try graph.dfs(99, 5, .{});
    try testing.expect(no_start_path == null);
    const no_goal_path = try graph.dfs(1, 99, .{});
    try testing.expect(no_goal_path == null);
    const no_start_and_goal_path = try graph.dfs(99, 99, .{});
    try testing.expect(no_start_and_goal_path == null);
}

test "dijkstra: simple" {
    const allocator = testing.allocator;
    const V = u32;
    const W = u32;
    var graph = Graph(V, W, .{}).init(allocator);
    defer graph.deinit();
    try graph.put(1, 2, 10);
    try graph.put(2, 3, 11);
    try graph.put(2, 4, 12);
    try graph.put(3, 5, 13);
    try graph.put(4, 5, 14);
    var path = try graph.dijkstra(1, 5, .{});
    try testing.expect(path != null);
    defer path.?.deinit();
    const nodes = try path.?.nodes(allocator);
    defer allocator.free(nodes);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 5 }, nodes);
    try testing.expectEqual(@as(V, 34), path.?.eval);
}

test "dijkstra: start is goal" {
    const allocator = testing.allocator;
    const V = u32;
    const W = u32;
    var graph = Graph(V, W, .{}).init(allocator);
    defer graph.deinit();
    try graph.put(1, 2, 11);
    try graph.put(2, 3, 12);
    try graph.put(2, 4, 13);
    try graph.put(4, 5, 14);
    var path = try graph.dijkstra(1, 1, .{});
    try testing.expect(path != null);
    defer path.?.deinit();
    const nodes = try path.?.nodes(allocator);
    defer allocator.free(nodes);
    try testing.expectEqualSlices(V, &.{1}, nodes);
}

test "dijkstra: there is no start or goal" {
    const allocator = testing.allocator;
    const V = u32;
    const W = u32;
    var graph = Graph(V, W, .{}).init(allocator);
    defer graph.deinit();
    try graph.put(1, 2, 11);
    try graph.put(2, 3, 12);
    try graph.put(2, 4, 13);
    try graph.put(4, 5, 14);
    const no_start_path = try graph.dijkstra(99, 5, .{});
    try testing.expect(no_start_path == null);
    const no_goal_path = try graph.dijkstra(1, 99, .{});
    try testing.expect(no_goal_path == null);
    const no_start_and_goal_path = try graph.dijkstra(99, 99, .{});
    try testing.expect(no_start_and_goal_path == null);
}
