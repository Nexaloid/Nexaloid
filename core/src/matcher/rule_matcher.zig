const std = @import("std");
const types = @import("../types.zig");
const builtin_rules = @import("builtin_rules.zig");
const custom_rules = @import("custom_rules.zig");
const rule_config = @import("rule_config.zig");

pub const RuleId = rule_config.RuleId;
pub const RuleConfig = rule_config.RuleConfig;
pub const rule_count = rule_config.rule_count;
pub const all_rules_mask = rule_config.all_rules_mask;
pub const default_scores = rule_config.default_scores;
pub const ruleBit = rule_config.ruleBit;

pub const CustomRule = custom_rules.CustomRule;
pub const CustomRuleKind = custom_rules.CustomRuleKind;
pub const CustomRules = custom_rules.CustomRules;

pub fn matchAll(chars: []const types.NxChar, ctx: anytype, comptime emit: anytype) !void {
    const config = RuleConfig{};
    return matchAllConfig(chars, &config, ctx, emit);
}

pub fn matchAllConfig(chars: []const types.NxChar, config: *const RuleConfig, ctx: anytype, comptime emit: anytype) !void {
    return matchAllConfigCustom(chars, config, null, ctx, emit);
}

pub fn matchAllConfigCustom(chars: []const types.NxChar, config: *const RuleConfig, custom_rules_config: ?*const CustomRules, ctx: anytype, comptime emit: anytype) !void {
    var i: usize = 0;
    while (i < chars.len) {
        if (builtin_rules.structuredMatch(chars, i)) |matched| {
            if (config.isEnabled(matched.rule)) {
                try emitRule(ctx, emit, chars, i, matched.end, config.score(matched.rule));
                i = matched.end;
                continue;
            }
        }

        if (custom_rules_config) |rules| {
            try custom_rules.emitAll(chars, rules, i, ctx, emit);
        }

        if (!config.isEnabled(.ascii_term) or !builtin_rules.isAsciiTermChar(chars[i])) {
            i += 1;
            continue;
        }

        const start = i;
        var end = i;
        var saw_alnum = false;
        // Keep mixed ASCII terms such as GPT-5.5, C++, and onnxruntime-gpu together.
        while (end < chars.len and builtin_rules.isAsciiTermChar(chars[end])) : (end += 1) {
            saw_alnum = saw_alnum or isAlnum(chars[end]);
        }

        if (saw_alnum) {
            try emitRule(ctx, emit, chars, start, end, config.score(.ascii_term));
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
        .flags = 0,
    });
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
