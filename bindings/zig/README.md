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
```
