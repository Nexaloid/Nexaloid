const std = @import("std");

pub const max_custom_rules = 64;
pub const max_prefixes = 32;
pub const max_prefix_len = 32;
pub const max_rule_len = 256;

pub const CustomRuleKind = enum {
    prefixed_number,
    charset_span,
    ascii_chain,
    number_unit,
    literal_sequence,
    contains_span,
};

pub const Boundary = enum {
    none,
    ascii,
    ascii_or_han,
};

pub const SequencePartKind = enum {
    literal,
    digits,
    charset,
};

pub const SequencePart = struct {
    kind: SequencePartKind,
    literal: []u32 = &.{},
    min_len: u32 = 1,
    max_len: u32 = 1,
    charset: [128]bool = [_]bool{false} ** 128,

    pub fn deinit(self: *SequencePart, allocator: std.mem.Allocator) void {
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

    pub fn deinit(self: *CustomRule, allocator: std.mem.Allocator) void {
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
