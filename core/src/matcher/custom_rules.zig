const std = @import("std");
const types = @import("../types.zig");
const defs = @import("custom_rule_types.zig");
const matcher = @import("custom_rule_matcher.zig");
const parser = @import("custom_rule_parser.zig");

pub const CustomRule = defs.CustomRule;
pub const CustomRuleKind = defs.CustomRuleKind;

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
        var next = CustomRules.init(self.allocator);
        errdefer next.deinit();
        next.rules = try parser.parseJson(self.allocator, json);

        self.deinit();
        self.* = next;
    }
};

pub fn emitAll(chars: []const types.NxChar, rules: *const CustomRules, start: usize, budget: *usize, ctx: anytype, comptime emit: anytype) !void {
    return matcher.emitAll(chars, rules.rules.items, start, budget, ctx, emit);
}
