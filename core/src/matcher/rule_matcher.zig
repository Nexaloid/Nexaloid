const std = @import("std");
const types = @import("../types.zig");

pub fn matchAll(chars: []const types.NxChar, ctx: anytype, comptime emit: anytype) !void {
    var i: usize = 0;
    while (i < chars.len) {
        if (!isAsciiTermChar(chars[i])) {
            i += 1;
            continue;
        }

        const start = i;
        var end = i;
        var saw_alnum = false;
        // Keep mixed ASCII terms such as GPT-5.5, C++, and onnxruntime-gpu together.
        while (end < chars.len and isAsciiTermChar(chars[end])) : (end += 1) {
            saw_alnum = saw_alnum or isAlnum(chars[end]);
        }

        if (saw_alnum) {
            try emit(ctx, types.NxEdge{
                .start_char = @intCast(start),
                .end_char = @intCast(end),
                .start_byte = chars[start].start_byte,
                .end_byte = chars[end - 1].end_byte,
                .word_id = 0,
                .score = 3.0,
                .pos_id = 0,
                .source = .rule,
            });
        }
        i = end;
    }
}

fn isAsciiTermChar(ch: types.NxChar) bool {
    return isAlnum(ch) or switch (ch.codepoint) {
        '.', '-', '_', '+', '#', '/' => true,
        else => false,
    };
}

fn isAlnum(ch: types.NxChar) bool {
    return ch.char_class == .latin or ch.char_class == .digit;
}

test "rule matcher groups mixed ascii model names" {
    const scanner = @import("../scanner/utf8.zig");
    const CharCtx = struct {
        chars: [20]types.NxChar = undefined,
        count: usize = 0,
    };
    var char_ctx = CharCtx{};
    try scanner.scan("GPT-5.5 Thinking", &char_ctx, struct {
        fn emit(ctx: *CharCtx, ch: types.NxChar) !void {
            ctx.chars[ctx.count] = ch;
            ctx.count += 1;
        }
    }.emit);

    const EdgeCtx = struct {
        edges: [2]types.NxEdge = undefined,
        count: usize = 0,
    };
    var edge_ctx = EdgeCtx{};
    try matchAll(char_ctx.chars[0..char_ctx.count], &edge_ctx, struct {
        fn emit(ctx: *EdgeCtx, edge: types.NxEdge) !void {
            ctx.edges[ctx.count] = edge;
            ctx.count += 1;
        }
    }.emit);

    try std.testing.expectEqual(@as(usize, 2), edge_ctx.count);
    try std.testing.expectEqual(@as(u32, 0), edge_ctx.edges[0].start_byte);
    try std.testing.expectEqual(@as(u32, 7), edge_ctx.edges[0].end_byte);
    try std.testing.expectEqual(@as(u32, 8), edge_ctx.edges[1].start_byte);
    try std.testing.expectEqual(@as(u32, 16), edge_ctx.edges[1].end_byte);
}
