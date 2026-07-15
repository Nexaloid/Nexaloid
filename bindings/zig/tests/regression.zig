const std = @import("std");
const nx = @import("nexaloid");

fn expect(tokenizer: *nx.Tokenizer, text: []const u8, expected: []const []const u8) !void {
    var tokens = try tokenizer.tokenize(std.heap.page_allocator, text, .accurate);
    defer tokens.deinit(std.heap.page_allocator);
    try std.testing.expectEqual(expected.len, tokens.items.len);
    for (expected, 0..) |word, i| {
        try std.testing.expectEqualStrings(word, tokens.items[i].text);
    }
}

pub fn main() !void {
    var tokenizer = try nx.Tokenizer.init("../../data/dict/nexaloid.tsv");
    defer tokenizer.deinit();

    try expect(&tokenizer, "南京市长江大桥", &.{ "南京市", "长江大桥" });
    try expect(&tokenizer, "我们在日本东京做RAG中文检索实验", &.{ "我们", "在", "日本", "东京", "做", "RAG", "中文", "检索", "实验" });
    try expect(&tokenizer, "我爱北京天安门", &.{ "我", "爱", "北京", "天安门" });
    try expect(&tokenizer, "长春市长春节前发表讲话", &.{ "长春", "市长", "春节前", "发表", "讲话" });
    try expect(&tokenizer, "文档 秒", &.{ "文档", "秒" });

    var preserve_tokenizer = try nx.Tokenizer.initOptions("../../data/dict/nexaloid.tsv", true);
    defer preserve_tokenizer.deinit();
    try expect(&preserve_tokenizer, "文档 秒", &.{ "文档", " ", "秒" });

    var search = try tokenizer.tokenize(std.heap.page_allocator, "研究生命起源", .search);
    defer search.deinit(std.heap.page_allocator);
    for (search.items) |token| {
        try std.testing.expect(!std.mem.eql(u8, token.text, "研究生"));
    }
    var recall = try tokenizer.tokenize(std.heap.page_allocator, "研究生命起源", .recall_search);
    defer recall.deinit(std.heap.page_allocator);
    var saw_student = false;
    for (recall.items) |token| {
        if (std.mem.eql(u8, token.text, "研究生")) saw_student = true;
    }
    try std.testing.expect(saw_student);

    try tokenizer.loadRulesJson(
        \\{"version":1,"rules":[{"name":"stock","kind":"prefixed_number","prefixes":["SH"],"digits":{"min":6,"max":6},"score":80}]}
    );
    var tokens = try tokenizer.tokenize(std.heap.page_allocator, "买SH600519", .accurate);
    defer tokens.deinit(std.heap.page_allocator);
    var saw_stock = false;
    for (tokens.items) |token| {
        if (std.mem.eql(u8, token.text, "SH600519") and
            token.source == .rule and
            std.mem.eql(u8, token.source.name(), "rule") and
            token.customRuleIndex() == 1)
        {
            saw_stock = true;
        }
    }
    try std.testing.expect(saw_stock);

    std.debug.print("zig regression passed\n", .{});
}
