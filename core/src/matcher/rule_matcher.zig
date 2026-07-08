const std = @import("std");
const types = @import("../types.zig");
const utf8_scanner = @import("../scanner/utf8.zig");

pub const RuleId = enum(u5) {
    url,
    email,
    timestamp,
    windows_path,
    ipv6,
    number_unit,
    market_day,
    ascii_term,
};

pub const rule_count = @typeInfo(RuleId).@"enum".fields.len;
pub const all_rules_mask: u32 = (1 << rule_count) - 1;
pub const default_scores = [_]f32{ 300.0, 300.0, 300.0, 300.0, 300.0, 300.0, 300.0, 3.0 };

pub const RuleConfig = struct {
    enabled_mask: u32 = all_rules_mask,
    scores: [rule_count]f32 = default_scores,

    pub fn isEnabled(self: *const RuleConfig, rule: RuleId) bool {
        return (self.enabled_mask & ruleBit(rule)) != 0;
    }

    pub fn score(self: *const RuleConfig, rule: RuleId) f32 {
        return self.scores[@intFromEnum(rule)];
    }
};

const max_custom_rules = 64;
const max_prefixes = 32;
const max_prefix_len = 32;
const max_rule_len = 256;

pub const CustomRuleKind = enum {
    prefixed_number,
    charset_span,
    ascii_chain,
    number_unit,
    literal_sequence,
    contains_span,
};

const Boundary = enum {
    none,
    ascii,
    ascii_or_han,
};

const SequencePartKind = enum {
    literal,
    digits,
    charset,
};

const SequencePart = struct {
    kind: SequencePartKind,
    literal: []u32 = &.{},
    min_len: u32 = 1,
    max_len: u32 = 1,
    charset: [128]bool = [_]bool{false} ** 128,

    fn deinit(self: *SequencePart, allocator: std.mem.Allocator) void {
        allocator.free(self.literal);
    }
};

pub const CustomRule = struct {
    name: []u8 = &.{},
    kind: CustomRuleKind,
    enabled: bool = true,
    boundary: Boundary = .ascii,
    score: f32,
    min_len: u32 = 1,
    max_len: u32 = max_rule_len,
    digit_min: u32 = 1,
    digit_max: u32 = 16,
    allow_decimal: bool = true,
    prefixes: std.ArrayListUnmanaged([]u8) = .empty,
    must_contain: std.ArrayListUnmanaged([]u8) = .empty,
    units: std.ArrayListUnmanaged([]u8) = .empty,
    parts: std.ArrayListUnmanaged(SequencePart) = .empty,
    charset: [128]bool = [_]bool{false} ** 128,
    left: []u32 = &.{},
    right: []u32 = &.{},

    fn deinit(self: *CustomRule, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.prefixes.items) |prefix| allocator.free(prefix);
        self.prefixes.deinit(allocator);
        for (self.must_contain.items) |needle| allocator.free(needle);
        self.must_contain.deinit(allocator);
        for (self.units.items) |unit| allocator.free(unit);
        self.units.deinit(allocator);
        for (self.parts.items) |*part| part.deinit(allocator);
        self.parts.deinit(allocator);
        allocator.free(self.left);
        allocator.free(self.right);
    }
};

pub const CustomRules = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayListUnmanaged(CustomRule) = .empty,

    pub fn init(allocator: std.mem.Allocator) CustomRules {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CustomRules) void {
        self.clear();
        self.rules.deinit(self.allocator);
    }

    pub fn clear(self: *CustomRules) void {
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.clearRetainingCapacity();
    }

    pub fn loadJson(self: *CustomRules, json: []const u8) !void {
        if (json.len > 1024 * 1024) return error.InvalidRules;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json, .{}) catch return error.InvalidRules;
        defer parsed.deinit();

        var next = CustomRules.init(self.allocator);
        errdefer next.deinit();

        const root = objectValue(parsed.value) catch return error.InvalidRules;
        if (root.get("version")) |version| {
            if ((intValue(version) orelse return error.InvalidRules) != 1) return error.InvalidRules;
        }
        const rules_value = root.get("rules") orelse return error.InvalidRules;
        const rule_items = switch (rules_value) {
            .array => |array| array.items,
            else => return error.InvalidRules,
        };
        if (rule_items.len > max_custom_rules) return error.InvalidRules;

        for (rule_items) |value| {
            const object = objectValue(value) catch return error.InvalidRules;
            var rule = try parseRule(self.allocator, object);
            errdefer rule.deinit(self.allocator);
            try next.rules.append(self.allocator, rule);
        }

        self.deinit();
        self.* = next;
    }
};

pub fn ruleBit(rule: RuleId) u32 {
    return @as(u32, 1) << @intCast(@intFromEnum(rule));
}

pub fn matchAll(chars: []const types.NxChar, ctx: anytype, comptime emit: anytype) !void {
    const config = RuleConfig{};
    return matchAllConfig(chars, &config, ctx, emit);
}

pub fn matchAllConfig(chars: []const types.NxChar, config: *const RuleConfig, ctx: anytype, comptime emit: anytype) !void {
    return matchAllConfigCustom(chars, config, null, ctx, emit);
}

pub fn matchAllConfigCustom(chars: []const types.NxChar, config: *const RuleConfig, custom_rules: ?*const CustomRules, ctx: anytype, comptime emit: anytype) !void {
    var i: usize = 0;
    while (i < chars.len) {
        if (structuredMatch(chars, i)) |matched| {
            if (config.isEnabled(matched.rule)) {
                try emitRule(ctx, emit, chars, i, matched.end, config.score(matched.rule));
                i = matched.end;
                continue;
            }
        }

        if (custom_rules) |rules| {
            try emitCustomRules(chars, rules, i, ctx, emit);
        }

        if (!config.isEnabled(.ascii_term) or !isAsciiTermChar(chars[i])) {
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
            try emitRule(ctx, emit, chars, start, end, config.score(.ascii_term));
        }
        i = end;
    }
}

fn parseRule(allocator: std.mem.Allocator, object: std.json.ObjectMap) !CustomRule {
    const kind_text = stringField(object, "kind") orelse return error.InvalidRules;
    const score: f32 = @floatCast(numberField(object, "score") orelse 30.0);
    if (!std.math.isFinite(score)) return error.InvalidRules;
    if (std.mem.eql(u8, kind_text, "prefixed_number")) {
        var rule = try initRule(allocator, object, .prefixed_number, score);
        errdefer rule.deinit(allocator);
        const digits = objectValue(object.get("digits") orelse return error.InvalidRules) catch return error.InvalidRules;
        rule.digit_min = try optionalU32Field(digits, "min") orelse 1;
        rule.digit_max = try optionalU32Field(digits, "max") orelse rule.digit_min;
        if (rule.digit_min == 0 or rule.digit_max < rule.digit_min or rule.digit_max > max_rule_len) return error.InvalidRules;
        try parseStringList(allocator, object, "prefixes", &rule.prefixes);
        return rule;
    }
    if (std.mem.eql(u8, kind_text, "charset_span")) {
        var rule = try initRule(allocator, object, .charset_span, score);
        errdefer rule.deinit(allocator);
        try parseLenFields(object, &rule);
        try parseCharset(stringField(object, "charset") orelse return error.InvalidRules, &rule.charset);
        return rule;
    }
    if (std.mem.eql(u8, kind_text, "ascii_chain")) {
        var rule = try initRule(allocator, object, .ascii_chain, score);
        errdefer rule.deinit(allocator);
        try parseLenFields(object, &rule);
        try parseCharset(stringField(object, "charset") orelse return error.InvalidRules, &rule.charset);
        if (object.get("must_contain")) |_| try parseStringList(allocator, object, "must_contain", &rule.must_contain);
        return rule;
    }
    if (std.mem.eql(u8, kind_text, "number_unit")) {
        var rule = try initRule(allocator, object, .number_unit, score);
        errdefer rule.deinit(allocator);
        rule.allow_decimal = boolField(object, "allow_decimal") orelse true;
        try parseStringList(allocator, object, "units", &rule.units);
        return rule;
    }
    if (std.mem.eql(u8, kind_text, "literal_sequence")) {
        var rule = try initRule(allocator, object, .literal_sequence, score);
        errdefer rule.deinit(allocator);
        try parseSequenceParts(allocator, object, &rule.parts);
        return rule;
    }
    if (std.mem.eql(u8, kind_text, "contains_span")) {
        var rule = try initRule(allocator, object, .contains_span, score);
        errdefer rule.deinit(allocator);
        try parseLenFields(object, &rule);
        try parseCharset(stringField(object, "charset") orelse return error.InvalidRules, &rule.charset);
        rule.left = try utf8Codepoints(allocator, stringField(object, "left") orelse return error.InvalidRules);
        rule.right = try utf8Codepoints(allocator, stringField(object, "right") orelse return error.InvalidRules);
        if (rule.left.len == 0 or rule.right.len == 0) return error.InvalidRules;
        return rule;
    }
    return error.InvalidRules;
}

fn initRule(allocator: std.mem.Allocator, object: std.json.ObjectMap, kind: CustomRuleKind, score: f32) !CustomRule {
    var rule = CustomRule{
        .kind = kind,
        .score = score,
        .enabled = boolField(object, "enabled") orelse true,
        .boundary = try parseBoundary(stringField(object, "boundary") orelse "ascii"),
    };
    if (stringField(object, "name")) |name| {
        if (name.len > 64) return error.InvalidRules;
        rule.name = try allocator.dupe(u8, name);
    }
    return rule;
}

fn parseLenFields(object: std.json.ObjectMap, rule: *CustomRule) !void {
    rule.min_len = try optionalU32Field(object, "min_len") orelse 1;
    rule.max_len = try optionalU32Field(object, "max_len") orelse max_rule_len;
    if (rule.min_len == 0 or rule.max_len < rule.min_len or rule.max_len > max_rule_len) return error.InvalidRules;
}

fn parseStringList(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, out: *std.ArrayListUnmanaged([]u8)) !void {
    const items = switch (object.get(key) orelse return error.InvalidRules) {
        .array => |array| array.items,
        else => return error.InvalidRules,
    };
    if (items.len == 0 or items.len > max_prefixes) return error.InvalidRules;
    try out.ensureTotalCapacity(allocator, items.len);
    for (items) |item| {
        const value = switch (item) {
            .string => |text| text,
            else => return error.InvalidRules,
        };
        if (value.len == 0 or value.len > max_prefix_len or !isAsciiBytes(value)) return error.InvalidRules;
        out.appendAssumeCapacity(try allocator.dupe(u8, value));
    }
}

fn parseSequenceParts(allocator: std.mem.Allocator, object: std.json.ObjectMap, out: *std.ArrayListUnmanaged(SequencePart)) !void {
    const items = switch (object.get("parts") orelse return error.InvalidRules) {
        .array => |array| array.items,
        else => return error.InvalidRules,
    };
    if (items.len == 0 or items.len > 32) return error.InvalidRules;
    try out.ensureTotalCapacity(allocator, items.len);
    for (items) |item| {
        const part_obj = objectValue(item) catch return error.InvalidRules;
        var part = SequencePart{ .kind = .digits };
        errdefer part.deinit(allocator);
        if (stringField(part_obj, "literal")) |literal| {
            part.kind = .literal;
            part.literal = try utf8Codepoints(allocator, literal);
            if (part.literal.len == 0) return error.InvalidRules;
        } else if (part_obj.get("digits")) |digits_value| {
            part.kind = .digits;
            if (intValue(digits_value)) |count| {
                if (count <= 0 or count > max_rule_len) return error.InvalidRules;
                part.min_len = @intCast(count);
                part.max_len = @intCast(count);
            } else {
                const digits = objectValue(digits_value) catch return error.InvalidRules;
                part.min_len = try optionalU32Field(digits, "min") orelse 1;
                part.max_len = try optionalU32Field(digits, "max") orelse part.min_len;
                if (part.min_len == 0 or part.max_len < part.min_len or part.max_len > max_rule_len) return error.InvalidRules;
            }
        } else if (stringField(part_obj, "charset")) |charset| {
            part.kind = .charset;
            part.min_len = try optionalU32Field(part_obj, "min") orelse 1;
            part.max_len = try optionalU32Field(part_obj, "max") orelse part.min_len;
            if (part.min_len == 0 or part.max_len < part.min_len or part.max_len > max_rule_len) return error.InvalidRules;
            try parseCharset(charset, &part.charset);
        } else {
            return error.InvalidRules;
        }
        out.appendAssumeCapacity(part);
    }
}

fn emitCustomRules(chars: []const types.NxChar, rules: *const CustomRules, start: usize, ctx: anytype, comptime emit: anytype) !void {
    for (rules.rules.items, 0..) |*rule, index| {
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

fn objectValue(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidRules,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, key: []const u8) ?bool {
    return switch (object.get(key) orelse return null) {
        .bool => |value| value,
        else => null,
    };
}

fn parseBoundary(text: []const u8) !Boundary {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "ascii")) return .ascii;
    if (std.mem.eql(u8, text, "ascii_or_han")) return .ascii_or_han;
    return error.InvalidRules;
}

fn numberField(object: std.json.ObjectMap, key: []const u8) ?f64 {
    return numberValue(object.get(key) orelse return null);
}

fn optionalU32Field(object: std.json.ObjectMap, key: []const u8) !?u32 {
    const raw = object.get(key) orelse return null;
    const value = intValue(raw) orelse return error.InvalidRules;
    if (value < 0 or value > std.math.maxInt(u32)) return error.InvalidRules;
    return @intCast(value);
}

fn numberValue(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        .number_string => |v| std.fmt.parseFloat(f64, v) catch null,
        else => null,
    };
}

fn intValue(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |v| v,
        .number_string => |v| std.fmt.parseInt(i64, v, 10) catch null,
        else => null,
    };
}

fn emitRule(ctx: anytype, comptime emit: anytype, chars: []const types.NxChar, start: usize, end: usize, score: f32) !void {
    try emitRuleFlags(ctx, emit, chars, start, end, score, 0);
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

const StructuredMatch = struct {
    rule: RuleId,
    end: usize,
};

fn structuredMatch(chars: []const types.NxChar, start: usize) ?StructuredMatch {
    if (urlEnd(chars, start)) |end| return .{ .rule = .url, .end = end };
    if (emailEnd(chars, start)) |end| return .{ .rule = .email, .end = end };
    if (timestampEnd(chars, start)) |end| return .{ .rule = .timestamp, .end = end };
    if (windowsPathEnd(chars, start)) |end| return .{ .rule = .windows_path, .end = end };
    if (ipv6End(chars, start)) |end| return .{ .rule = .ipv6, .end = end };
    if (numberUnitEnd(chars, start)) |end| return .{ .rule = .number_unit, .end = end };
    if (marketDayEnd(chars, start)) |end| return .{ .rule = .market_day, .end = end };
    return null;
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

fn inCharset(rule: *const CustomRule, ch: types.NxChar) bool {
    return ch.codepoint < 128 and rule.charset[@intCast(ch.codepoint)];
}

fn partInCharset(part: *const SequencePart, ch: types.NxChar) bool {
    return ch.codepoint < 128 and part.charset[@intCast(ch.codepoint)];
}

fn parseCharset(text: []const u8, out: *[128]bool) !void {
    if (text.len == 0) return error.InvalidRules;
    @memset(out, false);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] >= 128) return error.InvalidRules;
        if (i + 2 < text.len and text[i + 1] == '-') {
            const first = text[i];
            const last = text[i + 2];
            if (first > last or last >= 128) return error.InvalidRules;
            var ch = first;
            while (ch <= last) : (ch += 1) out[ch] = true;
            i += 3;
        } else {
            out[text[i]] = true;
            i += 1;
        }
    }
}

fn isAsciiBytes(text: []const u8) bool {
    for (text) |ch| if (ch >= 128) return false;
    return true;
}

fn utf8Codepoints(allocator: std.mem.Allocator, text: []const u8) ![]u32 {
    if (text.len == 0) return error.InvalidRules;
    var out: std.ArrayListUnmanaged(u32) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const cp, _ = utf8_scanner.nextCodepoint(text, &i) catch return error.InvalidRules;
        try out.append(allocator, cp);
        if (out.items.len > max_rule_len) return error.InvalidRules;
    }
    return out.toOwnedSlice(allocator);
}

fn startsWith(chars: []const types.NxChar, start: usize, comptime literal: []const u8) bool {
    if (start + literal.len > chars.len) return false;
    for (literal, 0..) |c, i| {
        if (chars[start + i].codepoint != c) return false;
    }
    return true;
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

test "rule matcher gives market day enough score to win" {
    const scanner = @import("../scanner/utf8.zig");
    const CharCtx = struct {
        chars: [8]types.NxChar = undefined,
        count: usize = 0,
    };
    var char_ctx = CharCtx{};
    try scanner.scan("T+3日内", &char_ctx, struct {
        fn emit(ctx: *CharCtx, ch: types.NxChar) !void {
            ctx.chars[ctx.count] = ch;
            ctx.count += 1;
        }
    }.emit);

    const EdgeCtx = struct {
        edges: [4]types.NxEdge = undefined,
        count: usize = 0,
    };
    var edge_ctx = EdgeCtx{};
    try matchAll(char_ctx.chars[0..char_ctx.count], &edge_ctx, struct {
        fn emit(ctx: *EdgeCtx, edge: types.NxEdge) !void {
            ctx.edges[ctx.count] = edge;
            ctx.count += 1;
        }
    }.emit);

    try std.testing.expectEqual(@as(usize, 1), edge_ctx.count);
    try std.testing.expectEqual(@as(u32, 0), edge_ctx.edges[0].start_char);
    try std.testing.expectEqual(@as(u32, 5), edge_ctx.edges[0].end_char);
    try std.testing.expect(edge_ctx.edges[0].score > 100.0);
}
