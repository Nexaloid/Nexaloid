const std = @import("std");
const types = @import("../types.zig");
const trie_mod = @import("../lexicon/trie.zig");

pub fn matchAll(chars: []const types.NxChar, trie: *const trie_mod.TempTrie, ctx: anytype, comptime emit: anytype) !void {
    return matchAllSource(chars, trie, .base_dict, ctx, emit);
}

pub fn matchAllSource(chars: []const types.NxChar, trie: *const trie_mod.TempTrie, source: types.NxSource, ctx: anytype, comptime emit: anytype) !void {
    var start: usize = 0;
    while (start < chars.len) : (start += 1) {
        var node_index: u32 = 0;
        var end = start;
        // Walk the trie from each char position and emit every terminal prefix as a candidate edge.
        while (end < chars.len) : (end += 1) {
            node_index = trie.child(node_index, chars[end].codepoint) orelse break;
            const word_id = trie.wordId(node_index);
            if (word_id != 0) {
                try emit(ctx, types.NxEdge{
                    .start_char = @intCast(start),
                    .end_char = @intCast(end + 1),
                    .start_byte = chars[start].start_byte,
                    .end_byte = chars[end].end_byte,
                    .word_id = word_id,
                    .score = trie.score(node_index),
                    .pos_id = trie.posId(node_index),
                    .source = source,
                });
            }
        }
    }
}

test "matcher emits dictionary edges with original offsets" {
    var trie = try trie_mod.TempTrie.init(std.testing.allocator);
    defer trie.deinit();
    try trie.insert("南京", 1, -2.0, 0);
    try trie.insert("南京市", 2, -1.0, 0);
    try trie.insert("长江大桥", 3, -0.5, 0);

    const CharCtx = struct {
        chars: [7]types.NxChar = undefined,
        count: usize = 0,
    };
    var char_ctx = CharCtx{};
    try @import("../scanner/utf8.zig").scan("南京市长江大桥", &char_ctx, struct {
        fn emit(ctx: *CharCtx, ch: types.NxChar) !void {
            ctx.chars[ctx.count] = ch;
            ctx.count += 1;
        }
    }.emit);

    const EdgeCtx = struct {
        edges: [3]types.NxEdge = undefined,
        count: usize = 0,
    };
    var edge_ctx = EdgeCtx{};
    try matchAll(char_ctx.chars[0..char_ctx.count], &trie, &edge_ctx, struct {
        fn emit(ctx: *EdgeCtx, edge: types.NxEdge) !void {
            ctx.edges[ctx.count] = edge;
            ctx.count += 1;
        }
    }.emit);

    try std.testing.expectEqual(@as(usize, 3), edge_ctx.count);
    try std.testing.expectEqual(@as(u32, 1), edge_ctx.edges[0].word_id);
    try std.testing.expectEqual(@as(u32, 2), edge_ctx.edges[1].word_id);
    try std.testing.expectEqual(@as(u32, 0), edge_ctx.edges[1].start_char);
    try std.testing.expectEqual(@as(u32, 3), edge_ctx.edges[1].end_char);
    try std.testing.expectEqual(@as(u32, 0), edge_ctx.edges[1].start_byte);
    try std.testing.expectEqual(@as(u32, 9), edge_ctx.edges[1].end_byte);
    try std.testing.expectEqual(@as(u32, 3), edge_ctx.edges[2].start_char);
    try std.testing.expectEqual(@as(u32, 7), edge_ctx.edges[2].end_char);
    try std.testing.expectEqual(@as(u32, 9), edge_ctx.edges[2].start_byte);
    try std.testing.expectEqual(@as(u32, 21), edge_ctx.edges[2].end_byte);
}
