const types = @import("../types.zig");
const rule_config = @import("rule_config.zig");

const RuleId = rule_config.RuleId;

pub const StructuredMatch = struct {
    rule: RuleId,
    end: usize,
};

pub fn structuredMatch(chars: []const types.NxChar, start: usize) ?StructuredMatch {
    if (urlEnd(chars, start)) |end| return .{ .rule = .url, .end = end };
    if (emailEnd(chars, start)) |end| return .{ .rule = .email, .end = end };
    if (timestampEnd(chars, start)) |end| return .{ .rule = .timestamp, .end = end };
    if (windowsPathEnd(chars, start)) |end| return .{ .rule = .windows_path, .end = end };
    if (ipv6End(chars, start)) |end| return .{ .rule = .ipv6, .end = end };
    if (numberUnitEnd(chars, start)) |end| return .{ .rule = .number_unit, .end = end };
    if (marketDayEnd(chars, start)) |end| return .{ .rule = .market_day, .end = end };
    return null;
}

pub fn isAsciiTermChar(ch: types.NxChar) bool {
    return isAlnum(ch) or switch (ch.codepoint) {
        '.', '-', '_', '+', '#', '/' => true,
        else => false,
    };
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
