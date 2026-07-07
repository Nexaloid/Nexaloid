const std = @import("std");
const types = @import("../types.zig");

pub fn matchAll(chars: []const types.NxChar, ctx: anytype, comptime emit: anytype) !void {
    var i: usize = 0;
    while (i < chars.len) {
        if (structuredEnd(chars, i)) |end| {
            try emitRule(ctx, emit, chars, i, end, 8.0);
            i = end;
            continue;
        }

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
            try emitRule(ctx, emit, chars, start, end, 3.0);
        }
        i = end;
    }
}

fn emitRule(ctx: anytype, comptime emit: anytype, chars: []const types.NxChar, start: usize, end: usize, score: f32) !void {
    try emit(ctx, types.NxEdge{
        .start_char = @intCast(start),
        .end_char = @intCast(end),
        .start_byte = chars[start].start_byte,
        .end_byte = chars[end - 1].end_byte,
        .word_id = 0,
        .score = score,
        .pos_id = 0,
        .source = .rule,
    });
}

fn structuredEnd(chars: []const types.NxChar, start: usize) ?usize {
    return urlEnd(chars, start) orelse
        emailEnd(chars, start) orelse
        timestampEnd(chars, start) orelse
        windowsPathEnd(chars, start) orelse
        ipv6End(chars, start) orelse
        numberUnitEnd(chars, start) orelse
        marketDayEnd(chars, start);
}

fn urlEnd(chars: []const types.NxChar, start: usize) ?usize {
    if (!startsWith(chars, start, "http://") and !startsWith(chars, start, "https://")) return null;
    var end = start;
    while (end < chars.len and isUrlChar(chars[end])) : (end += 1) {}
    return if (end > start + 8) end else null;
}

fn emailEnd(chars: []const types.NxChar, start: usize) ?usize {
    var end = start;
    var at: ?usize = null;
    var dot_after_at = false;
    while (end < chars.len and isEmailChar(chars[end])) : (end += 1) {
        if (chars[end].codepoint == '@') {
            if (at != null or end == start) return null;
            at = end;
        } else if (chars[end].codepoint == '.' and at != null and end > at.? + 1) {
            dot_after_at = true;
        }
    }
    if (at == null or !dot_after_at or end == start or chars[end - 1].codepoint == '.') return null;
    return end;
}

fn timestampEnd(chars: []const types.NxChar, start: usize) ?usize {
    if (!hasLiteral(chars, start, "0000-00-00T00:00:00")) return null;
    const checks = [_]struct { usize, u32 }{
        .{ 4, '-' }, .{ 7, '-' }, .{ 10, 'T' }, .{ 13, ':' }, .{ 16, ':' },
    };
    for (checks) |check| if (chars[start + check[0]].codepoint != check[1]) return null;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 }) |offset| {
        if (chars[start + offset].char_class != .digit) return null;
    }
    var end = start + 19;
    if (end + 6 <= chars.len and (chars[end].codepoint == '+' or chars[end].codepoint == '-')) {
        if (chars[end + 1].char_class == .digit and chars[end + 2].char_class == .digit and
            chars[end + 3].codepoint == ':' and chars[end + 4].char_class == .digit and chars[end + 5].char_class == .digit)
        {
            end += 6;
        }
    }
    return end;
}

fn windowsPathEnd(chars: []const types.NxChar, start: usize) ?usize {
    if (start + 3 > chars.len or chars[start].char_class != .latin or chars[start + 1].codepoint != ':' or chars[start + 2].codepoint != '\\') return null;
    var end = start + 3;
    while (end < chars.len and isWindowsPathChar(chars[end])) : (end += 1) {}
    return end;
}

fn ipv6End(chars: []const types.NxChar, start: usize) ?usize {
    var end = start;
    var colons: usize = 0;
    var hexes: usize = 0;
    while (end < chars.len and (isHex(chars[end]) or chars[end].codepoint == ':')) : (end += 1) {
        if (chars[end].codepoint == ':') colons += 1 else hexes += 1;
    }
    if (colons < 2 or hexes < 3 or end == start or chars[start].codepoint == ':' or chars[end - 1].codepoint == ':') return null;
    return end;
}

fn numberUnitEnd(chars: []const types.NxChar, start: usize) ?usize {
    if (chars[start].char_class != .digit) return null;
    var end = start;
    while (end < chars.len and (chars[end].char_class == .digit or chars[end].codepoint == '.')) : (end += 1) {}
    if (end == start) return null;
    if (end < chars.len and chars[end].codepoint == '%') return end + 1;
    const unit_start = end;
    while (end < chars.len and chars[end].char_class == .latin) : (end += 1) {}
    return if (end > unit_start) end else null;
}

fn marketDayEnd(chars: []const types.NxChar, start: usize) ?usize {
    if (start + 4 > chars.len) return null;
    if (chars[start].codepoint != 'T' or chars[start + 1].codepoint != '+' or chars[start + 2].char_class != .digit or chars[start + 3].codepoint != 0x65E5) return null;
    var end = start + 4;
    if (end < chars.len and chars[end].codepoint == 0x5185) end += 1;
    return end;
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

fn isUrlChar(ch: types.NxChar) bool {
    if (ch.char_class == .space or ch.char_class == .han) return false;
    return switch (ch.codepoint) {
        '"', '\'', '<', '>', 0x3002, 0xFF0C, 0xFF1B, 0xFF01, 0xFF1F => false,
        else => true,
    };
}

fn isEmailChar(ch: types.NxChar) bool {
    return isAlnum(ch) or switch (ch.codepoint) {
        '.', '_', '+', '-', '@' => true,
        else => false,
    };
}

fn isWindowsPathChar(ch: types.NxChar) bool {
    return isAlnum(ch) or switch (ch.codepoint) {
        '\\', '/', '.', '-', '_', ' ' => true,
        else => false,
    };
}

fn isHex(ch: types.NxChar) bool {
    return ch.char_class == .digit or
        (ch.codepoint >= 'a' and ch.codepoint <= 'f') or
        (ch.codepoint >= 'A' and ch.codepoint <= 'F');
}

fn startsWith(chars: []const types.NxChar, start: usize, comptime literal: []const u8) bool {
    if (start + literal.len > chars.len) return false;
    for (literal, 0..) |c, i| {
        if (chars[start + i].codepoint != c) return false;
    }
    return true;
}

fn hasLiteral(chars: []const types.NxChar, start: usize, comptime literal: []const u8) bool {
    return start + literal.len <= chars.len;
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
