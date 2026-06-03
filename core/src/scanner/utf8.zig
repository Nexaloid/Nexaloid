const std = @import("std");
const types = @import("../types.zig");

pub const ScanError = error{InvalidUtf8};

// Scan UTF-8 bytes into codepoints while preserving both byte and char offsets.
pub fn scan(text: []const u8, ctx: anytype, comptime emit: anytype) !void {
    var i: usize = 0;
    var char_index: u32 = 0;

    while (i < text.len) {
        const start = i;
        const cp, const width = try nextCodepoint(text, &i);
        try emit(ctx, types.NxChar{
            .codepoint = cp,
            .start_byte = @intCast(start),
            .end_byte = @intCast(i),
            .char_index = char_index,
            .char_class = classify(cp),
        });
        char_index += 1;
        std.debug.assert(width == i - start);
    }
}

// Decode one UTF-8 codepoint and reject malformed, overlong, and surrogate encodings.
pub fn nextCodepoint(text: []const u8, index: *usize) ScanError!struct { u32, usize } {
    const b0 = text[index.*];

    if (b0 < 0x80) {
        index.* += 1;
        return .{ b0, 1 };
    }

    const width: usize = if (b0 & 0xE0 == 0xC0) 2 else if (b0 & 0xF0 == 0xE0) 3 else if (b0 & 0xF8 == 0xF0) 4 else return ScanError.InvalidUtf8;
    if (index.* + width > text.len) return ScanError.InvalidUtf8;

    var cp: u32 = b0 & masks[width];
    var j: usize = 1;
    while (j < width) : (j += 1) {
        const b = text[index.* + j];
        if (b & 0xC0 != 0x80) return ScanError.InvalidUtf8;
        cp = (cp << 6) | (b & 0x3F);
    }

    if (isOverlong(cp, width) or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) {
        return ScanError.InvalidUtf8;
    }

    index.* += width;
    return .{ cp, width };
}

const masks = [_]u8{ 0, 0, 0x1F, 0x0F, 0x07 };

fn isOverlong(cp: u32, width: usize) bool {
    return switch (width) {
        2 => cp < 0x80,
        3 => cp < 0x800,
        4 => cp < 0x10000,
        else => false,
    };
}

pub fn classify(cp: u32) types.NxCharClass {
    // Keep the first-pass classifier small; domain-specific grouping belongs in rule matchers.
    if ((cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x20000 and cp <= 0x2EBEF))
    {
        return .han;
    }
    if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z')) return .latin;
    if (cp >= '0' and cp <= '9') return .digit;
    if (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r') return .space;
    if ((cp >= 0x3000 and cp <= 0x303F) or (cp < 0x80 and std.ascii.isPunctuation(@intCast(cp)))) return .punct;
    if (cp >= 0x1F300 and cp <= 0x1FAFF) return .emoji;
    return .other;
}

test "scan preserves byte and char offsets" {
    const input = "A中🙂";
    var out: [3]types.NxChar = undefined;

    const Ctx = struct {
        out: *[3]types.NxChar,
        n: usize = 0,
    };
    var ctx = Ctx{ .out = &out };

    try scan(input, &ctx, struct {
        fn emit(state: *Ctx, ch: types.NxChar) !void {
            state.out[state.n] = ch;
            state.n += 1;
        }
    }.emit);

    try std.testing.expectEqual(@as(usize, 3), ctx.n);
    try std.testing.expectEqual(@as(u32, 0), out[0].start_byte);
    try std.testing.expectEqual(@as(u32, 1), out[1].start_byte);
    try std.testing.expectEqual(@as(u32, 4), out[2].start_byte);
    try std.testing.expectEqual(types.NxCharClass.latin, out[0].char_class);
    try std.testing.expectEqual(types.NxCharClass.han, out[1].char_class);
    try std.testing.expectEqual(types.NxCharClass.emoji, out[2].char_class);
}

test "scan rejects invalid utf8" {
    const bad = [_]u8{ 0xE4, 0xB8 };
    try std.testing.expectError(ScanError.InvalidUtf8, scan(&bad, {}, struct {
        fn emit(_: void, _: types.NxChar) !void {}
    }.emit));
}
