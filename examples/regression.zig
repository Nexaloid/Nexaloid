const std = @import("std");
const c = @cImport({
    @cInclude("nexaloid.h");
});

const Ctx = struct {
    expected: []const []const u8,
    count: usize = 0,
    failed: bool = false,
};

fn onToken(token_ptr: [*c]const c.NxToken, text: [*c]const u8, text_len: usize, user_data: ?*anyopaque) callconv(.c) void {
    _ = text_len;
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    const token = token_ptr[0];
    if (ctx.count >= ctx.expected.len) {
        ctx.failed = true;
        return;
    }
    const expected = ctx.expected[ctx.count];
    ctx.count += 1;
    const actual = text[token.start_byte..token.end_byte];
    if (!std.mem.eql(u8, actual, expected)) ctx.failed = true;
}

fn expect(engine: *c.NxEngine, text: [:0]const u8, expected: []const []const u8) !void {
    var ctx = Ctx{ .expected = expected };
    const status = c.nx_tokenize(engine, text.ptr, text.len, c.NX_MODE_ACCURATE, onToken, &ctx);
    if (status != c.NX_OK or ctx.failed or ctx.count != expected.len) return error.UnexpectedTokens;
}

pub fn main() !void {
    var cfg: c.NxConfig = std.mem.zeroes(c.NxConfig);
    cfg.dict_path = "data/dict/nexaloid.tsv";
    var engine: ?*c.NxEngine = null;
    if (c.nx_engine_new(&cfg, &engine) != c.NX_OK) return error.EngineNewFailed;
    defer c.nx_engine_free(engine);

    try expect(engine.?, "南京市长江大桥", &.{ "南京市", "长江大桥" });
    try expect(engine.?, "我们在日本东京做RAG中文检索实验", &.{ "我们", "在", "日本", "东京", "做", "RAG", "中文", "检索", "实验" });
    try expect(engine.?, "我爱北京天安门", &.{ "我", "爱", "北京", "天安门" });
    try expect(engine.?, "长春市长春节前发表讲话", &.{ "长春", "市长", "春节前", "发表", "讲话" });

    std.debug.print("zig regression passed\n", .{});
}
