const std = @import("std");
const types = @import("../types.zig");
const lattice_mod = @import("../lattice/lattice.zig");

pub fn decode(allocator: std.mem.Allocator, lattice: *const lattice_mod.Lattice) !std.ArrayListUnmanaged(types.NxEdge) {
    const n: usize = lattice.char_len;
    // scores[i] is the best score for a complete path ending at char position i.
    const scores = try allocator.alloc(f32, n + 1);
    defer allocator.free(scores);
    const prev = try allocator.alloc(?types.NxEdge, n + 1);
    defer allocator.free(prev);

    @memset(scores, -std.math.inf(f32));
    @memset(prev, null);
    scores[0] = 0;

    var pos: usize = 0;
    while (pos < n) : (pos += 1) {
        if (scores[pos] == -std.math.inf(f32)) continue;
        const Ctx = struct {
            scores: []f32,
            prev: []?types.NxEdge,
            base_score: f32,
        };
        var ctx = Ctx{
            .scores = scores,
            .prev = prev,
            .base_score = scores[pos],
        };
        try lattice.edgesFrom(@intCast(pos), &ctx, struct {
            fn emit(state: *Ctx, edge: types.NxEdge) !void {
                const end: usize = @intCast(edge.end_char);
                const candidate = state.base_score + edge.score;
                // Higher scores win; prev keeps the edge needed to reconstruct the best path.
                if (candidate > state.scores[end]) {
                    state.scores[end] = candidate;
                    state.prev[end] = edge;
                }
            }
        }.emit);
    }

    var path: std.ArrayListUnmanaged(types.NxEdge) = .empty;
    errdefer path.deinit(allocator);

    var cursor = n;
    while (cursor > 0) {
        // Missing prev means the lattice has no complete path, which should only happen if fallback is broken.
        const edge = prev[cursor] orelse return error.NoPath;
        try path.append(allocator, edge);
        cursor = edge.start_char;
    }
    std.mem.reverse(types.NxEdge, path.items);
    return path;
}

test "viterbi chooses best complete path" {
    var lattice = lattice_mod.Lattice.init(std.testing.allocator, 3);
    defer lattice.deinit();

    try lattice.addEdge(.{ .start_char = 0, .end_char = 1, .start_byte = 0, .end_byte = 3, .word_id = 1, .score = -1.0, .pos_id = 0, .source = .base_dict });
    try lattice.addEdge(.{ .start_char = 1, .end_char = 3, .start_byte = 3, .end_byte = 9, .word_id = 2, .score = -1.0, .pos_id = 0, .source = .base_dict });
    try lattice.addEdge(.{ .start_char = 0, .end_char = 3, .start_byte = 0, .end_byte = 9, .word_id = 3, .score = -1.5, .pos_id = 0, .source = .base_dict });

    var path = try decode(std.testing.allocator, &lattice);
    defer path.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), path.items.len);
    try std.testing.expectEqual(@as(u32, 3), path.items[0].word_id);
}

test "viterbi uses unknown fallback from built lattice" {
    const trie_mod = @import("../lexicon/trie.zig");
    var trie = try trie_mod.TempTrie.init(std.testing.allocator);
    defer trie.deinit();
    var user_trie = try trie_mod.TempTrie.init(std.testing.allocator);
    defer user_trie.deinit();
    try trie.insert("南京市", 1, -1.0, 0);

    const scanner = @import("../scanner/utf8.zig");
    const CharCtx = struct {
        chars: [4]types.NxChar = undefined,
        count: usize = 0,
    };
    var char_ctx = CharCtx{};
    try scanner.scan("南京市长", &char_ctx, struct {
        fn emit(ctx: *CharCtx, ch: types.NxChar) !void {
            ctx.chars[ctx.count] = ch;
            ctx.count += 1;
        }
    }.emit);

    var lattice = try lattice_mod.buildFromMatcher(std.testing.allocator, char_ctx.chars[0..char_ctx.count], &trie, &user_trie);
    defer lattice.deinit();
    var path = try decode(std.testing.allocator, &lattice);
    defer path.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), path.items.len);
    try std.testing.expectEqual(@as(u32, 1), path.items[0].word_id);
    try std.testing.expectEqual(types.NxSource.unknown, path.items[1].source);
}
