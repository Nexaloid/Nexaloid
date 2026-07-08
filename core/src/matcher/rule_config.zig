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

pub fn ruleBit(rule: RuleId) u32 {
    return @as(u32, 1) << @intCast(@intFromEnum(rule));
}
