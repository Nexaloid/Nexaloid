pub const scanner = @import("scanner/utf8.zig");
pub const types = @import("types.zig");
pub const trie = @import("lexicon/trie.zig");
pub const matcher = @import("matcher/matcher.zig");
pub const rule_matcher = @import("matcher/rule_matcher.zig");
pub const lattice = @import("lattice/lattice.zig");
pub const decoder = @import("decoder/viterbi.zig");
pub const plugin = @import("plugin/loader.zig");
pub const tokenizer = @import("tokenizer.zig");

test {
    _ = scanner;
    _ = types;
    _ = trie;
    _ = matcher;
    _ = rule_matcher;
    _ = lattice;
    _ = decoder;
    _ = plugin;
    _ = tokenizer;
}
