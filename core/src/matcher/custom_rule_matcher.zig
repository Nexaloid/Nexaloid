const types = @import("../types.zig");
const defs = @import("custom_rule_types.zig");

const Boundary = defs.Boundary;
const CustomRule = defs.CustomRule;
const SequencePart = defs.SequencePart;
const max_rule_len = defs.max_rule_len;

pub fn emitAll(chars: []const types.NxChar, rules: []const CustomRule, start: usize, ctx: anytype, comptime emit: anytype) !void {
    for (rules, 0..) |*rule, index| {
        if (!rule.enabled) continue;
        const end = switch (rule.kind) {
            .prefixed_number => prefixedNumberEnd(chars, start, rule),
            .charset_span => charsetSpanEnd(chars, start, rule),
            .ascii_chain => asciiChainEnd(chars, start, rule),
            .number_unit => numberUnitCustomEnd(chars, start, rule),
            .literal_sequence => literalSequenceEnd(chars, start, rule),
            .contains_span => containsSpanEnd(chars, start, rule),
        } orelse continue;
        if (!boundaryOk(chars, start, end, rule.boundary)) continue;
        try emitRuleFlags(ctx, emit, chars, start, end, rule.score, @intCast(index + 1));
    }
}

fn prefixedNumberEnd(chars: []const types.NxChar, start: usize, rule: *const CustomRule) ?usize {
    if (start > 0 and isAlnum(chars[start - 1])) return null;
    for (rule.prefixes.items) |prefix| {
        if (!startsWithBytes(chars, start, prefix)) continue;
        var end = start + prefix.len;
        var digits: u32 = 0;
        while (end < chars.len and chars[end].char_class == .digit) : (end += 1) digits += 1;
        if (digits < rule.digit_min or digits > rule.digit_max) continue;
        if (end < chars.len and isAlnum(chars[end])) continue;
        return end;
    }
    return null;
}

fn charsetSpanEnd(chars: []const types.NxChar, start: usize, rule: *const CustomRule) ?usize {
    if (start > 0 and inCharset(rule, chars[start - 1])) return null;
    var end = start;
    while (end < chars.len and end - start < rule.max_len and inCharset(rule, chars[end])) : (end += 1) {}
    const len = end - start;
    if (len < rule.min_len) return null;
    if (end < chars.len and inCharset(rule, chars[end])) return null;
    return end;
}

fn asciiChainEnd(chars: []const types.NxChar, start: usize, rule: *const CustomRule) ?usize {
    const end = charsetSpanEnd(chars, start, rule) orelse return null;
    for (rule.must_contain.items) |needle| {
        if (!containsBytes(chars, start, end, needle)) return null;
    }
    return end;
}

fn numberUnitCustomEnd(chars: []const types.NxChar, start: usize, rule: *const CustomRule) ?usize {
    if (chars[start].char_class != .digit) return null;
    var end = start;
    while (end < chars.len and chars[end].char_class == .digit) : (end += 1) {}
    if (rule.allow_decimal and end + 1 < chars.len and chars[end].codepoint == '.' and chars[end + 1].char_class == .digit) {
        end += 1;
        while (end < chars.len and chars[end].char_class == .digit) : (end += 1) {}
    }

    var best: ?usize = null;
    for (rule.units.items) |unit| {
        if (!startsWithBytes(chars, end, unit)) continue;
        const candidate = end + unit.len;
        if (best == null or candidate > best.?) best = candidate;
    }
    return best;
}

fn literalSequenceEnd(chars: []const types.NxChar, start: usize, rule: *const CustomRule) ?usize {
    const end = matchSequenceFrom(chars, start, rule.parts.items, 0) orelse return null;
    if (end <= start or end - start > max_rule_len) return null;
    return end;
}

fn matchSequenceFrom(chars: []const types.NxChar, pos: usize, parts: []const SequencePart, index: usize) ?usize {
    if (index == parts.len) return pos;
    const part = parts[index];
    switch (part.kind) {
        .literal => {
            if (!startsWithCodepoints(chars, pos, part.literal)) return null;
            return matchSequenceFrom(chars, pos + part.literal.len, parts, index + 1);
        },
        .digits => {
            var end = pos;
            while (end < chars.len and end - pos < part.max_len and chars[end].char_class == .digit) : (end += 1) {}
            const len = end - pos;
            if (len < part.min_len) return null;
            return matchSequenceFrom(chars, end, parts, index + 1);
        },
        .charset => {
            var max_end = pos;
            while (max_end < chars.len and max_end - pos < part.max_len and partInCharset(&part, chars[max_end])) : (max_end += 1) {}
            if (max_end - pos < part.min_len) return null;
            var len = max_end - pos;
            while (len >= part.min_len) {
                if (matchSequenceFrom(chars, pos + len, parts, index + 1)) |end| return end;
                if (len == part.min_len) break;
                len -= 1;
            }
            return null;
        },
    }
}

fn containsSpanEnd(chars: []const types.NxChar, start: usize, rule: *const CustomRule) ?usize {
    if (!startsWithCodepoints(chars, start, rule.left)) return null;
    const inner_start = start + rule.left.len;
    var end = inner_start;
    while (end < chars.len and end - inner_start < rule.max_len and inCharset(rule, chars[end])) : (end += 1) {}
    const inner_len = end - inner_start;
    if (inner_len < rule.min_len) return null;
    if (end < chars.len and inCharset(rule, chars[end])) return null;
    if (!startsWithCodepoints(chars, end, rule.right)) return null;
    return end + rule.right.len;
}

fn boundaryOk(chars: []const types.NxChar, start: usize, end: usize, boundary: Boundary) bool {
    if (boundary == .none) return true;
    if (start > 0 and boundaryBlocked(chars[start - 1], boundary)) return false;
    if (end < chars.len and boundaryBlocked(chars[end], boundary)) return false;
    return true;
}

fn boundaryBlocked(ch: types.NxChar, boundary: Boundary) bool {
    const ascii_alnum = ch.codepoint < 128 and isAlnum(ch);
    return switch (boundary) {
        .none => false,
        .ascii => ascii_alnum,
        .ascii_or_han => ascii_alnum or ch.char_class == .han,
    };
}

fn emitRuleFlags(ctx: anytype, comptime emit: anytype, chars: []const types.NxChar, start: usize, end: usize, score: f32, flags: u16) !void {
    try emit(ctx, types.NxEdge{
        .start_char = @intCast(start),
        .end_char = @intCast(end),
        .start_byte = chars[start].start_byte,
        .end_byte = chars[end - 1].end_byte,
        .word_id = 0,
        .score = score,
        .pos_id = 0,
        .source = .rule,
        .flags = flags,
    });
}

fn isAlnum(ch: types.NxChar) bool {
    return ch.char_class == .latin or ch.char_class == .digit;
}

fn inCharset(rule: *const CustomRule, ch: types.NxChar) bool {
    return ch.codepoint < 128 and rule.charset[@intCast(ch.codepoint)];
}

fn partInCharset(part: *const SequencePart, ch: types.NxChar) bool {
    return ch.codepoint < 128 and part.charset[@intCast(ch.codepoint)];
}

fn startsWithBytes(chars: []const types.NxChar, start: usize, literal: []const u8) bool {
    if (start + literal.len > chars.len) return false;
    for (literal, 0..) |c, i| {
        if (chars[start + i].codepoint != c) return false;
    }
    return true;
}

fn startsWithCodepoints(chars: []const types.NxChar, start: usize, literal: []const u32) bool {
    if (start + literal.len > chars.len) return false;
    for (literal, 0..) |cp, i| {
        if (chars[start + i].codepoint != cp) return false;
    }
    return true;
}

fn containsBytes(chars: []const types.NxChar, start: usize, end: usize, needle: []const u8) bool {
    if (needle.len == 0 or end - start < needle.len) return false;
    var i = start;
    while (i + needle.len <= end) : (i += 1) {
        if (startsWithBytes(chars, i, needle)) return true;
    }
    return false;
}
