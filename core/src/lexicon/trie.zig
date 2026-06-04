const std = @import("std");
const scanner = @import("../scanner/utf8.zig");

pub const TempTrie = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    dat_codepoints: std.ArrayListUnmanaged(u32) = .empty,
    dat_base: std.ArrayListUnmanaged(u32) = .empty,
    dat_check: std.ArrayListUnmanaged(u32) = .empty,
    dat_nodes: []const DatNode = &.{},
    dat_codepoints_view: []const u32 = &.{},
    dat_base_view: []const u32 = &.{},
    dat_check_view: []const u32 = &.{},

    pub const Child = struct {
        codepoint: u32,
        node: u32,
    };

    // A terminal node stores word metadata; non-terminal nodes keep word_id as 0.
    const Node = struct {
        word_id: u32 = 0,
        score: f32 = 0,
        pos_id: u16 = 0,
        children: std.ArrayListUnmanaged(Child) = .empty,
    };

    pub const DatNode = extern struct {
        word_id: u32,
        score: f32,
    };

    pub fn init(allocator: std.mem.Allocator) !TempTrie {
        var trie = TempTrie{ .allocator = allocator };
        try trie.nodes.append(allocator, .{});
        return trie;
    }

    pub fn deinit(self: *TempTrie) void {
        for (self.nodes.items) |*node| node.children.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.dat_codepoints.deinit(self.allocator);
        self.dat_base.deinit(self.allocator);
        self.dat_check.deinit(self.allocator);
    }

    pub fn isEmpty(self: *const TempTrie) bool {
        return self.nodes.items.len == 1 and self.nodes.items[0].children.items.len == 0 and self.datBase().len == 0;
    }

    pub fn loadDat(self: *TempTrie, dat_nodes: []const DatNode, codepoints: []const u32, base: []const u32, check: []const u32) !void {
        try self.loadDatNodes(dat_nodes);
        try self.dat_codepoints.appendSlice(self.allocator, codepoints);
        try self.dat_base.appendSlice(self.allocator, base);
        try self.dat_check.appendSlice(self.allocator, check);
    }

    pub fn loadDatBorrowed(self: *TempTrie, dat_nodes: []const DatNode, codepoints: []const u32, base: []const u32, check: []const u32) void {
        for (self.nodes.items) |*node| node.children.deinit(self.allocator);
        self.nodes.clearRetainingCapacity();
        self.dat_nodes = dat_nodes;
        self.dat_codepoints_view = codepoints;
        self.dat_base_view = base;
        self.dat_check_view = check;
    }

    pub fn insert(self: *TempTrie, word: []const u8, word_id: u32, word_score: f32, pos_id: u16) !void {
        var node_index: u32 = 0;
        var i: usize = 0;
        // Dictionary keys are UTF-8 words, but trie transitions are Unicode codepoints.
        while (i < word.len) {
            const cp, _ = try scanner.nextCodepoint(word, &i);
            node_index = try self.childOrCreate(node_index, cp);
        }

        const node = &self.nodes.items[node_index];
        node.word_id = word_id;
        node.score = word_score;
        node.pos_id = pos_id;
    }

    pub fn child(self: *const TempTrie, node_index: u32, codepoint: u32) ?u32 {
        if (self.datChild(node_index, codepoint)) |found| return found;
        if (node_index >= self.nodes.items.len) return null;
        const node = self.nodes.items[node_index];
        for (node.children.items) |entry| {
            if (entry.codepoint == codepoint) return entry.node;
        }
        return null;
    }

    fn datChild(self: *const TempTrie, node_index: u32, codepoint: u32) ?u32 {
        const base = self.datBase();
        const check = self.datCheck();
        if (node_index >= base.len) return null;
        const code_id = findCodeId(self.datCodepoints(), codepoint) orelse return null;
        const next = base[node_index] + code_id;
        if (next >= check.len) return null;
        if (check[next] == node_index + 1) return next;
        return null;
    }

    pub fn wordId(self: *const TempTrie, node_index: u32) u32 {
        if (node_index < self.dat_nodes.len) return self.dat_nodes[node_index].word_id;
        return self.nodes.items[node_index].word_id;
    }

    pub fn score(self: *const TempTrie, node_index: u32) f32 {
        if (node_index < self.dat_nodes.len) return self.dat_nodes[node_index].score;
        return self.nodes.items[node_index].score;
    }

    pub fn posId(self: *const TempTrie, node_index: u32) u16 {
        if (node_index < self.dat_nodes.len) return 0;
        return self.nodes.items[node_index].pos_id;
    }

    fn childOrCreate(self: *TempTrie, node_index: u32, codepoint: u32) !u32 {
        if (self.child(node_index, codepoint)) |found| return found;
        try self.materializeDatNodes();

        const new_index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{});
        try self.nodes.items[node_index].children.append(self.allocator, .{
            .codepoint = codepoint,
            .node = new_index,
        });
        return new_index;
    }

    fn materializeDatNodes(self: *TempTrie) !void {
        if (self.dat_nodes.len == 0 or self.nodes.items.len >= self.dat_nodes.len) return;
        try self.loadDatNodes(self.dat_nodes);
    }

    fn loadDatNodes(self: *TempTrie, dat_nodes: []const DatNode) !void {
        for (self.nodes.items) |*node| node.children.deinit(self.allocator);
        self.nodes.clearRetainingCapacity();
        try self.nodes.ensureTotalCapacity(self.allocator, dat_nodes.len);
        for (dat_nodes) |node| {
            self.nodes.appendAssumeCapacity(.{
                .word_id = node.word_id,
                .score = node.score,
            });
        }
    }

    fn datCodepoints(self: *const TempTrie) []const u32 {
        return if (self.dat_codepoints_view.len != 0) self.dat_codepoints_view else self.dat_codepoints.items;
    }

    fn datBase(self: *const TempTrie) []const u32 {
        return if (self.dat_base_view.len != 0) self.dat_base_view else self.dat_base.items;
    }

    fn datCheck(self: *const TempTrie) []const u32 {
        return if (self.dat_check_view.len != 0) self.dat_check_view else self.dat_check.items;
    }
};

fn findCodeId(codepoints: []const u32, codepoint: u32) ?u32 {
    var lo: usize = 0;
    var hi: usize = codepoints.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cp = codepoints[mid];
        if (cp == codepoint) return @intCast(mid + 1);
        if (cp < codepoint) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

test "temp trie stores utf8 words" {
    var trie = try TempTrie.init(std.testing.allocator);
    defer trie.deinit();

    try trie.insert("南京市", 7, -1.5, 2);
    const n1 = trie.child(0, '南').?;
    const n2 = trie.child(n1, '京').?;
    const n3 = trie.child(n2, '市').?;

    try std.testing.expectEqual(@as(u32, 7), trie.wordId(n3));
    try std.testing.expectEqual(@as(u16, 2), trie.posId(n3));
}
