const std = @import("std");
const types = @import("types.zig");
const scanner = @import("scanner/utf8.zig");
const trie_mod = @import("lexicon/trie.zig");
const lattice_mod = @import("lattice/lattice.zig");
const decoder = @import("decoder/viterbi.zig");

pub const Tokenizer = struct {
    pub const DatNode = trie_mod.TempTrie.DatNode;

    allocator: std.mem.Allocator,
    trie: trie_mod.TempTrie,
    user_trie: trie_mod.TempTrie,

    pub fn init(allocator: std.mem.Allocator) !Tokenizer {
        var trie = try trie_mod.TempTrie.init(allocator);
        errdefer trie.deinit();
        return .{
            .allocator = allocator,
            .trie = trie,
            .user_trie = try trie_mod.TempTrie.init(allocator),
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.user_trie.deinit();
        self.trie.deinit();
    }

    pub fn addBaseWord(self: *Tokenizer, word: []const u8, word_id: u32, score: f32, pos_id: u16) !void {
        try self.trie.insert(word, word_id, score, pos_id);
    }

    pub fn addWord(self: *Tokenizer, word: []const u8, word_id: u32, score: f32, pos_id: u16) !void {
        try self.user_trie.insert(word, word_id, score, pos_id);
    }

    pub fn isDictEmpty(self: *const Tokenizer) bool {
        return self.trie.isEmpty();
    }

    pub fn loadDatDict(self: *Tokenizer, nodes: []const DatNode, codepoints: []const u32, base: []const u32, check: []const u32) !void {
        try self.trie.loadDat(nodes, codepoints, base, check);
    }

    pub fn loadDatDictBorrowed(self: *Tokenizer, nodes: []const DatNode, codepoints: []const u32, base: []const u32, check: []const u32) void {
        self.trie.loadDatBorrowed(nodes, codepoints, base, check);
    }

    pub fn tokenize(self: *const Tokenizer, text: []const u8) !std.ArrayListUnmanaged(types.NxEdge) {
        return self.tokenizeMode(text, .accurate);
    }

    pub fn tokenizeMode(self: *const Tokenizer, text: []const u8, mode: Mode) !std.ArrayListUnmanaged(types.NxEdge) {
        return self.tokenizeModeWithCandidates(text, mode, {}, struct {
            fn add(_: void, _: std.mem.Allocator, _: []const u8, _: []const types.NxChar, _: *lattice_mod.Lattice) !void {}
        }.add);
    }

    pub fn tokenizeModeWithCandidates(self: *const Tokenizer, text: []const u8, mode: Mode, candidate_ctx: anytype, comptime addCandidates: anytype) !std.ArrayListUnmanaged(types.NxEdge) {
        const ScanCtx = struct {
            allocator: std.mem.Allocator,
            chars: std.ArrayListUnmanaged(types.NxChar) = .empty,
        };
        var scan_ctx = ScanCtx{ .allocator = self.allocator };
        defer scan_ctx.chars.deinit(self.allocator);

        // The runtime pipeline starts by converting UTF-8 bytes into offset-preserving chars.
        try scanner.scan(text, &scan_ctx, struct {
            fn emit(ctx: *ScanCtx, ch: types.NxChar) !void {
                try ctx.chars.append(ctx.allocator, ch);
            }
        }.emit);

        // Matcher output, rule terms, plugin candidates, and unknown fallback become one lattice.
        var lattice = try lattice_mod.buildCandidates(self.allocator, scan_ctx.chars.items, &self.trie, &self.user_trie);
        defer lattice.deinit();
        try addCandidates(candidate_ctx, self.allocator, text, scan_ctx.chars.items, &lattice);
        try lattice_mod.addUnknownFallback(&lattice, scan_ctx.chars.items);
        if (mode == .search) return searchTokens(self.allocator, &lattice, scan_ctx.chars.items);
        // Accurate mode chooses the globally best path, then drops pure whitespace tokens.
        var path = try decoder.decode(self.allocator, &lattice);
        defer path.deinit(self.allocator);
        try ensureCompletePath(path.items, @intCast(scan_ctx.chars.items.len));
        return filterSpaces(self.allocator, path.items, scan_ctx.chars.items);
    }
};

pub const Mode = enum {
    accurate,
    full,
    search,
};

fn searchTokens(allocator: std.mem.Allocator, lattice: *const lattice_mod.Lattice, chars: []const types.NxChar) !std.ArrayListUnmanaged(types.NxEdge) {
    var out: std.ArrayListUnmanaged(types.NxEdge) = .empty;
    errdefer out.deinit(allocator);
    for (lattice.edges.items) |edge| {
        // Search mode exposes all explicit candidates plus small ngrams for recall.
        if (edge.source != .unknown) try appendSearchToken(allocator, &out, edge, chars);
        try addSearchNgrams(allocator, &out, edge, chars);
    }
    std.mem.sort(types.NxEdge, out.items, {}, edgeLessThan);
    return out;
}

fn appendSearchToken(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(types.NxEdge), edge: types.NxEdge, chars: []const types.NxChar) !void {
    if (edge.end_char - edge.start_char < 2) return;
    for (out.items) |existing| {
        if (sameText(existing, edge, chars)) return;
    }
    try out.append(allocator, edge);
}

fn addSearchNgrams(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(types.NxEdge), edge: types.NxEdge, chars: []const types.NxChar) !void {
    const len = edge.end_char - edge.start_char;
    // Unknown edges are fallback safety nets, not useful search expansions.
    if (edge.source == .unknown or len <= 2) return;
    if (!isHanEdge(edge, chars)) return;
    try addNgrams(allocator, out, edge, chars, 2);
    try addNgrams(allocator, out, edge, chars, 3);
}

fn addNgrams(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(types.NxEdge), edge: types.NxEdge, chars: []const types.NxChar, n: u32) !void {
    const len = edge.end_char - edge.start_char;
    if (len <= n) return;
    var start = edge.start_char;
    while (start + n <= edge.end_char) : (start += 1) {
        try appendSearchToken(allocator, out, .{
            .start_char = start,
            .end_char = start + n,
            .start_byte = chars[start].start_byte,
            .end_byte = chars[start + n - 1].end_byte,
            .word_id = 0,
            .score = edge.score - 1.0,
            .pos_id = edge.pos_id,
            .source = .rule,
        }, chars);
    }
}

fn sameText(a: types.NxEdge, b: types.NxEdge, chars: []const types.NxChar) bool {
    const a_len = a.end_char - a.start_char;
    if (a_len != b.end_char - b.start_char) return false;
    var i: u32 = 0;
    while (i < a_len) : (i += 1) {
        if (chars[a.start_char + i].codepoint != chars[b.start_char + i].codepoint) return false;
    }
    return true;
}

fn isHanEdge(edge: types.NxEdge, chars: []const types.NxChar) bool {
    var i = edge.start_char;
    while (i < edge.end_char) : (i += 1) {
        if (chars[i].char_class != .han) return false;
    }
    return true;
}

fn edgeLessThan(_: void, a: types.NxEdge, b: types.NxEdge) bool {
    if (a.start_char != b.start_char) return a.start_char < b.start_char;
    if (a.end_char != b.end_char) return a.end_char < b.end_char;
    return a.word_id < b.word_id;
}

fn ensureCompletePath(edges: []const types.NxEdge, char_len: u32) !void {
    var cursor: u32 = 0;
    for (edges) |edge| {
        if (edge.start_char != cursor or edge.end_char <= edge.start_char) return error.NoPath;
        cursor = edge.end_char;
    }
    if (cursor != char_len) return error.NoPath;
}

fn filterSpaces(allocator: std.mem.Allocator, edges: []const types.NxEdge, chars: []const types.NxChar) !std.ArrayListUnmanaged(types.NxEdge) {
    var out: std.ArrayListUnmanaged(types.NxEdge) = .empty;
    errdefer out.deinit(allocator);
    for (edges) |edge| {
        if (!isSpaceEdge(edge, chars)) try out.append(allocator, edge);
    }
    return out;
}

fn isSpaceEdge(edge: types.NxEdge, chars: []const types.NxChar) bool {
    var i: usize = @intCast(edge.start_char);
    const end: usize = @intCast(edge.end_char);
    while (i < end) : (i += 1) {
        if (chars[i].char_class != .space) return false;
    }
    return true;
}

test "tokenizer returns viterbi path" {
    var tokenizer = try Tokenizer.init(std.testing.allocator);
    defer tokenizer.deinit();
    try tokenizer.addWord("南京市", 1, -1.0, 0);
    try tokenizer.addWord("长江大桥", 2, -1.0, 0);
    try tokenizer.addWord("长江", 3, -3.0, 0);

    var tokens = try tokenizer.tokenize("南京市长江大桥");
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqual(@as(u32, 1), tokens.items[0].word_id);
    try std.testing.expectEqual(@as(u32, 2), tokens.items[1].word_id);
    try std.testing.expectEqual(@as(u32, 0), tokens.items[0].start_byte);
    try std.testing.expectEqual(@as(u32, 9), tokens.items[0].end_byte);
    try std.testing.expectEqual(@as(u32, 9), tokens.items[1].start_byte);
    try std.testing.expectEqual(@as(u32, 21), tokens.items[1].end_byte);
}

test "tokenizer keeps mixed ascii terms as one token" {
    var tokenizer = try Tokenizer.init(std.testing.allocator);
    defer tokenizer.deinit();
    try tokenizer.addWord("我", 1, 2.0, 0);
    try tokenizer.addWord("在", 2, 2.0, 0);
    try tokenizer.addWord("使用", 3, 5.0, 0);
    try tokenizer.addWord("模型", 4, 5.0, 0);

    var tokens = try tokenizer.tokenize("我在使用GPT-5.5 Thinking模型");
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), tokens.items.len);
    try std.testing.expectEqual(@as(u32, 3), tokens.items[2].word_id);
    try std.testing.expectEqual(types.NxSource.rule, tokens.items[3].source);
    try std.testing.expectEqual(@as(u32, 12), tokens.items[3].start_byte);
    try std.testing.expectEqual(@as(u32, 19), tokens.items[3].end_byte);
    try std.testing.expectEqual(types.NxSource.rule, tokens.items[4].source);
    try std.testing.expectEqual(@as(u32, 20), tokens.items[4].start_byte);
    try std.testing.expectEqual(@as(u32, 28), tokens.items[4].end_byte);
    try std.testing.expectEqual(@as(u32, 4), tokens.items[5].word_id);
}

test "search mode emits sub token ngrams" {
    var tokenizer = try Tokenizer.init(std.testing.allocator);
    defer tokenizer.deinit();
    try tokenizer.addWord("中国科学院", 1, 10.0, 0);
    try tokenizer.addWord("计算技术", 2, 10.0, 0);

    var tokens = try tokenizer.tokenizeMode("中国科学院计算技术", .search);
    defer tokens.deinit(std.testing.allocator);

    var saw_science: bool = false;
    var saw_calc_tech: bool = false;
    for (tokens.items) |token| {
        if (token.start_char == 2 and token.end_char == 5) saw_science = true;
        if (token.word_id == 2) saw_calc_tech = true;
    }

    try std.testing.expect(saw_science);
    try std.testing.expect(saw_calc_tech);
}

test "search mode filters single char and duplicate spans" {
    var tokenizer = try Tokenizer.init(std.testing.allocator);
    defer tokenizer.deinit();
    try tokenizer.addWord("南京", 1, 8.0, 0);
    try tokenizer.addWord("南京市", 2, 20.0, 0);

    var tokens = try tokenizer.tokenizeMode("南京市", .search);
    defer tokens.deinit(std.testing.allocator);

    for (tokens.items, 0..) |token, i| {
        try std.testing.expect(token.end_char - token.start_char >= 2);
        for (tokens.items[0..i]) |prev| {
            try std.testing.expect(prev.start_char != token.start_char or prev.end_char != token.end_char);
        }
    }
}

test "search mode deduplicates text and skips ascii ngrams" {
    var tokenizer = try Tokenizer.init(std.testing.allocator);
    defer tokenizer.deinit();
    try tokenizer.addWord("长春", 1, 8.0, 0);
    try tokenizer.addWord("长春市", 2, 20.0, 0);
    try tokenizer.addWord("春节前", 3, 18.0, 0);

    var tokens = try tokenizer.tokenizeMode("长春市长春节前ChatGPT-5.5", .search);
    defer tokens.deinit(std.testing.allocator);

    var saw_ascii = false;
    for (tokens.items, 0..) |token, i| {
        const text = "长春市长春节前ChatGPT-5.5"[token.start_byte..token.end_byte];
        if (std.mem.eql(u8, text, "ChatGPT-5.5")) saw_ascii = true;
        try std.testing.expect(!std.mem.eql(u8, text, "Ch"));
        for (tokens.items[0..i]) |prev| {
            try std.testing.expect(!std.mem.eql(
                u8,
                text,
                "长春市长春节前ChatGPT-5.5"[prev.start_byte..prev.end_byte],
            ));
        }
    }
    try std.testing.expect(saw_ascii);
}

test "deleted base word falls back without dropping text" {
    var tokenizer = try Tokenizer.init(std.testing.allocator);
    defer tokenizer.deinit();
    try tokenizer.addBaseWord("火山", 1, 20.0, 0);
    try tokenizer.addWord("火山", 2, -1_000_000.0, 0);

    var tokens = try tokenizer.tokenize("A火山B");
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try std.testing.expectEqual(types.NxSource.base_dict, tokens.items[1].source);
    try std.testing.expectEqual(@as(u32, 1), tokens.items[1].start_char);
    try std.testing.expectEqual(@as(u32, 3), tokens.items[1].end_char);
}

test "complete path invariant rejects gaps" {
    const edges = [_]types.NxEdge{
        .{ .start_char = 0, .end_char = 1, .start_byte = 0, .end_byte = 1, .word_id = 0, .score = 0, .pos_id = 0, .source = .unknown },
        .{ .start_char = 2, .end_char = 3, .start_byte = 2, .end_byte = 3, .word_id = 0, .score = 0, .pos_id = 0, .source = .unknown },
    };
    try std.testing.expectError(error.NoPath, ensureCompletePath(&edges, 3));
}
