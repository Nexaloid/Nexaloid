const std = @import("std");
const types = @import("../types.zig");
const matcher = @import("../matcher/matcher.zig");
const rule_matcher = @import("../matcher/rule_matcher.zig");
const trie_mod = @import("../lexicon/trie.zig");

pub const Lattice = struct {
    allocator: std.mem.Allocator,
    char_len: u32,
    edges: std.ArrayListUnmanaged(types.NxEdge) = .empty,
    buckets: []std.ArrayListUnmanaged(types.NxEdge) = &.{},

    pub fn init(allocator: std.mem.Allocator, char_len: u32) Lattice {
        return .{
            .allocator = allocator,
            .char_len = char_len,
        };
    }

    pub fn deinit(self: *Lattice) void {
        self.edges.deinit(self.allocator);
        for (self.buckets) |*bucket| bucket.deinit(self.allocator);
        self.allocator.free(self.buckets);
    }

    pub fn addEdge(self: *Lattice, edge: types.NxEdge) !void {
        std.debug.assert(edge.start_char < edge.end_char);
        std.debug.assert(edge.end_char <= self.char_len);
        try self.ensureBuckets();
        try self.edges.append(self.allocator, edge);
        try self.buckets[edge.start_char].append(self.allocator, edge);
    }

    pub fn edgeCount(self: *const Lattice) usize {
        return self.edges.items.len;
    }

    pub fn edgesFrom(self: *const Lattice, start_char: u32, ctx: anytype, comptime emit: anytype) !void {
        if (start_char >= self.buckets.len) return;
        for (self.buckets[start_char].items) |edge| try emit(ctx, edge);
    }

    fn ensureBuckets(self: *Lattice) !void {
        if (self.buckets.len != 0) return;
        self.buckets = try self.allocator.alloc(std.ArrayListUnmanaged(types.NxEdge), self.char_len);
        for (self.buckets) |*bucket| bucket.* = .empty;
    }
};

pub fn buildFromMatcher(
    allocator: std.mem.Allocator,
    chars: []const types.NxChar,
    trie: *const trie_mod.TempTrie,
    user_trie: *const trie_mod.TempTrie,
) !Lattice {
    var lattice = Lattice.init(allocator, @intCast(chars.len));
    errdefer lattice.deinit();

    // Core owns the graph: dictionary, rule, plugin, and unknown edges all become the same NxEdge shape.
    try matcher.matchAll(chars, trie, &lattice, struct {
        fn emit(out: *Lattice, edge: types.NxEdge) !void {
            try out.addEdge(edge);
        }
    }.emit);
    try matcher.matchAllSource(chars, user_trie, .user_dict, &lattice, struct {
        fn emit(out: *Lattice, edge: types.NxEdge) !void {
            try out.addEdge(edge);
        }
    }.emit);
    try rule_matcher.matchAll(chars, &lattice, struct {
        fn emit(out: *Lattice, edge: types.NxEdge) !void {
            try out.addEdge(edge);
        }
    }.emit);
    try addUnknownFallback(&lattice, chars);

    return lattice;
}

fn addUnknownFallback(lattice: *Lattice, chars: []const types.NxChar) !void {
    // Every char must have a path so Viterbi can always produce a complete token stream.
    for (chars) |ch| {
        try lattice.addEdge(.{
            .start_char = ch.char_index,
            .end_char = ch.char_index + 1,
            .start_byte = ch.start_byte,
            .end_byte = ch.end_byte,
            .word_id = 0,
            .score = -10.0,
            .pos_id = 0,
            .source = .unknown,
        });
    }
}

test "lattice stores and filters edges by start char" {
    var lattice = Lattice.init(std.testing.allocator, 4);
    defer lattice.deinit();

    try lattice.addEdge(.{
        .start_char = 0,
        .end_char = 2,
        .start_byte = 0,
        .end_byte = 6,
        .word_id = 1,
        .score = -1.0,
        .pos_id = 0,
        .source = .base_dict,
    });
    try lattice.addEdge(.{
        .start_char = 2,
        .end_char = 4,
        .start_byte = 6,
        .end_byte = 12,
        .word_id = 2,
        .score = -2.0,
        .pos_id = 0,
        .source = .base_dict,
    });

    const Ctx = struct {
        count: usize = 0,
        last_word_id: u32 = 0,
    };
    var ctx = Ctx{};
    try lattice.edgesFrom(2, &ctx, struct {
        fn emit(state: *Ctx, edge: types.NxEdge) !void {
            state.count += 1;
            state.last_word_id = edge.word_id;
        }
    }.emit);

    try std.testing.expectEqual(@as(usize, 2), lattice.edgeCount());
    try std.testing.expectEqual(@as(usize, 1), ctx.count);
    try std.testing.expectEqual(@as(u32, 2), ctx.last_word_id);
}

test "build lattice from matcher" {
    var trie = try trie_mod.TempTrie.init(std.testing.allocator);
    defer trie.deinit();
    try trie.insert("南京市", 10, -1.0, 0);
    try trie.insert("长江大桥", 20, -2.0, 0);

    const scanner = @import("../scanner/utf8.zig");
    const CharCtx = struct {
        chars: [7]types.NxChar = undefined,
        count: usize = 0,
    };
    var char_ctx = CharCtx{};
    try scanner.scan("南京市长江大桥", &char_ctx, struct {
        fn emit(ctx: *CharCtx, ch: types.NxChar) !void {
            ctx.chars[ctx.count] = ch;
            ctx.count += 1;
        }
    }.emit);

    var user_trie = try trie_mod.TempTrie.init(std.testing.allocator);
    defer user_trie.deinit();
    var lattice = try buildFromMatcher(std.testing.allocator, char_ctx.chars[0..char_ctx.count], &trie, &user_trie);
    defer lattice.deinit();

    try std.testing.expectEqual(@as(usize, 9), lattice.edgeCount());

    const Ctx = struct {
        saw_word_20: bool = false,
    };
    var ctx = Ctx{};
    try lattice.edgesFrom(3, &ctx, struct {
        fn emit(state: *Ctx, edge: types.NxEdge) !void {
            if (edge.word_id == 20) state.saw_word_20 = true;
        }
    }.emit);

    try std.testing.expect(ctx.saw_word_20);
}
