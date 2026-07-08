const std = @import("std");
const c = @cImport({
    @cInclude("nexaloid.h");
});

pub const Mode = enum(c.NxMode) {
    accurate = c.NX_MODE_ACCURATE,
    full = c.NX_MODE_FULL,
    search = c.NX_MODE_SEARCH,
};

pub const Token = struct {
    text: []const u8,
    start_byte: u32,
    end_byte: u32,
    start_char: u32,
    end_char: u32,
    source: u16,
    score: f32,
};

pub const Tokenizer = struct {
    engine: *c.NxEngine,

    pub fn init(dict_path: ?[*:0]const u8) !Tokenizer {
        var cfg: c.NxConfig = std.mem.zeroes(c.NxConfig);
        cfg.dict_path = dict_path;
        var engine: ?*c.NxEngine = null;
        if (c.nx_engine_new(&cfg, &engine) != c.NX_OK) return error.Nexaloid;
        return .{ .engine = engine.? };
    }

    pub fn deinit(self: *Tokenizer) void {
        c.nx_engine_free(self.engine);
    }

    pub fn loadRulesJson(self: *Tokenizer, json: []const u8) !void {
        if (c.nx_load_rules_json(self.engine, json.ptr, json.len) != c.NX_OK) return error.Nexaloid;
    }

    pub fn clearRules(self: *Tokenizer) !void {
        if (c.nx_clear_rules(self.engine) != c.NX_OK) return error.Nexaloid;
    }

    pub fn tokenize(self: *Tokenizer, allocator: std.mem.Allocator, text: []const u8, mode: Mode) !std.ArrayListUnmanaged(Token) {
        var out: std.ArrayListUnmanaged(Token) = .empty;
        errdefer out.deinit(allocator);
        var ctx = TokenCtx{ .allocator = allocator, .text = text, .out = &out };
        if (c.nx_tokenize(self.engine, text.ptr, text.len, @intFromEnum(mode), onToken, &ctx) != c.NX_OK) return error.Nexaloid;
        return out;
    }
};

const TokenCtx = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayListUnmanaged(Token),
};

fn onToken(token_ptr: [*c]const c.NxToken, _: [*c]const u8, _: usize, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *TokenCtx = @ptrCast(@alignCast(user_data.?));
    const token = token_ptr[0];
    ctx.out.append(ctx.allocator, .{
        .text = ctx.text[token.start_byte..token.end_byte],
        .start_byte = token.start_byte,
        .end_byte = token.end_byte,
        .start_char = token.start_char,
        .end_char = token.end_char,
        .source = token.source,
        .score = token.score,
    }) catch {};
}
