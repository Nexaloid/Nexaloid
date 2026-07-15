# Nexaloid Zig SDK

Minimal Zig wrapper over the stable C ABI. Rule JSON is still parsed by core.

```zig
const std = @import("std");
const nx = @import("nexaloid");

var tokenizer = try nx.Tokenizer.init("data/dict/nexaloid.tsv");
defer tokenizer.deinit();

try tokenizer.loadRulesJson(
    \\{"version":1,"rules":[{"name":"stock","kind":"prefixed_number","prefixes":["SH"],"digits":{"min":6,"max":6},"score":80}]}
);

var tokens = try tokenizer.tokenize(std.heap.page_allocator, "买SH600519", .accurate);
defer tokens.deinit(std.heap.page_allocator);

for (tokens.items) |token| {
    std.debug.print("{s} source={s} flags={}\n", .{ token.text, token.source.name(), token.flags });
}
```

## Token Contract

`.search` preserves every non-whitespace token on the Accurate path, including single-character and repeated-position tokens, and adds in-boundary Han 2-gram / 3-gram expansions. `.recall_search` also adds explicit lattice candidates.

`Token.source` uses the public `Source` enum and `Source.name()` returns its stable name. `Token.customRuleIndex()` returns the custom rule's 1-based JSON array index when the source is `.rule` and `flags` is nonzero.

Whitespace tokens are filtered by default; call `Tokenizer.initOptions(dict_path, true)` to preserve them.

## Development

```powershell
cd bindings/zig
$env:PATH = "$PWD\..\..\core\zig-out\bin;$env:PATH"
zig build regression
```
