const std = @import("std");
const utf8_scanner = @import("../scanner/utf8.zig");
const defs = @import("custom_rule_types.zig");

const CustomRule = defs.CustomRule;
const CustomRuleKind = defs.CustomRuleKind;
const SequencePart = defs.SequencePart;
const max_custom_rules = defs.max_custom_rules;
const max_prefixes = defs.max_prefixes;
const max_prefix_len = defs.max_prefix_len;
const max_rule_len = defs.max_rule_len;
const max_sequence_parts = defs.max_sequence_parts;

pub fn parseJson(allocator: std.mem.Allocator, json: []const u8) !std.ArrayListUnmanaged(CustomRule) {
    if (json.len > 1024 * 1024) return error.InvalidRules;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidRules;
    defer parsed.deinit();

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

    var rules: std.ArrayListUnmanaged(CustomRule) = .empty;
    errdefer {
        for (rules.items) |*rule| rule.deinit(allocator);
        rules.deinit(allocator);
    }
    try rules.ensureTotalCapacity(allocator, rule_items.len);
    for (rule_items) |value| {
        const object = objectValue(value) catch return error.InvalidRules;
        var rule = try parseRule(allocator, object);
        errdefer rule.deinit(allocator);
        rules.appendAssumeCapacity(rule);
    }
    return rules;
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
    if (items.len == 0 or items.len > max_sequence_parts) return error.InvalidRules;
    try out.ensureTotalCapacity(allocator, items.len);
    var minimum_total: u32 = 0;
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
        minimum_total = std.math.add(u32, minimum_total, switch (part.kind) {
            .literal => @intCast(part.literal.len),
            .digits, .charset => part.min_len,
        }) catch return error.InvalidRules;
        if (minimum_total > max_rule_len) return error.InvalidRules;
        out.appendAssumeCapacity(part);
    }
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

fn parseBoundary(text: []const u8) !defs.Boundary {
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
