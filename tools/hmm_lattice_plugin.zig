const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
});

const abi_version = 1;
const candidate_provider_kind = 1;

const NxPluginInfo = extern struct {
    abi_version: u32,
    name: ?[*:0]const u8,
    version: ?[*:0]const u8,
    kind: u32,
};

const NxPluginInput = extern struct {
    text: [*]const u8,
    text_len: usize,
    char_len: u32,
};

const NxPluginCandidate = extern struct {
    start_char: u32,
    end_char: u32,
    score: f32,
    source: u16,
    flags: u16,
};

const NxPluginCandidateCallback = *const fn (*const NxPluginCandidate, ?*anyopaque) callconv(.c) void;

const Plugin = struct {
    artifact: []u8,
    parsed: std.json.Parsed(std.json.Value),
    lexicon: LexiconTrie,
    hmm_score: f32,
};

const LexiconTrie = struct {
    nodes: std.ArrayListUnmanaged(TrieNode) = .empty,

    fn init() LexiconTrie {
        return .{};
    }

    fn deinit(self: *LexiconTrie) void {
        for (self.nodes.items) |*node| node.edges.deinit(allocator);
        self.nodes.deinit(allocator);
    }

    fn ensureRoot(self: *LexiconTrie) !void {
        if (self.nodes.items.len == 0) try self.nodes.append(allocator, .{});
    }

    fn insert(self: *LexiconTrie, word: []const u8) !void {
        if (word.len == 0) return;
        try self.ensureRoot();
        var node_index: usize = 0;
        for (word) |byte| {
            node_index = try self.childOrAdd(node_index, byte);
        }
        self.nodes.items[node_index].terminal = true;
    }

    fn childOrAdd(self: *LexiconTrie, node_index: usize, byte: u8) !usize {
        for (self.nodes.items[node_index].edges.items) |edge| {
            if (edge.byte == byte) return edge.next;
        }
        const next = self.nodes.items.len;
        try self.nodes.append(allocator, .{});
        try self.nodes.items[node_index].edges.append(allocator, .{ .byte = byte, .next = next });
        return next;
    }

    fn child(self: *const LexiconTrie, node_index: usize, byte: u8) ?usize {
        for (self.nodes.items[node_index].edges.items) |edge| {
            if (edge.byte == byte) return edge.next;
        }
        return null;
    }
};

const TrieNode = struct {
    edges: std.ArrayListUnmanaged(TrieEdge) = .empty,
    terminal: bool = false,
};

const TrieEdge = struct {
    byte: u8,
    next: usize,
};

const Char = struct {
    start_byte: usize,
    end_byte: usize,
    codepoint: u21,
};

const State = enum(usize) {
    B = 0,
    M = 1,
    E = 2,
    S = 3,

    fn name(self: State) []const u8 {
        return switch (self) {
            .B => "B",
            .M => "M",
            .E => "E",
            .S => "S",
        };
    }
};

const allocator = std.heap.page_allocator;
const default_hmm_score: f32 = -14.0;

export fn nx_plugin_init(config_json: ?[*:0]const u8, out_plugin: *?*anyopaque) c_int {
    const config_z = config_json orelse return 1;
    const config = parseConfig(config_z) catch return 1;
    defer if (config.owned_artifact_path) |path| allocator.free(path);
    const artifact = readFile(config.artifact_path) catch return 1;
    errdefer allocator.free(artifact);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, artifact, .{}) catch return 1;
    errdefer parsed.deinit();
    var lexicon = LexiconTrie.init();
    errdefer lexicon.deinit();
    buildLexiconTrie(&lexicon, parsed.value) catch return 1;

    const plugin = allocator.create(Plugin) catch return 1;
    plugin.* = .{
        .artifact = artifact,
        .parsed = parsed,
        .lexicon = lexicon,
        .hmm_score = config.hmm_score,
    };
    out_plugin.* = @ptrCast(plugin);
    return 0;
}

const Config = struct {
    artifact_path: [*:0]const u8,
    owned_artifact_path: ?[:0]u8 = null,
    hmm_score: f32,
};

fn parseConfig(config_z: [*:0]const u8) !Config {
    const config = std.mem.span(config_z);
    if (config.len == 0 or config[0] != '{') return .{
        .artifact_path = config_z,
        .hmm_score = default_hmm_score,
    };

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, config, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const artifact = (object.get("artifact") orelse return error.BadConfig).string;
    const artifact_z = try allocator.dupeZ(u8, artifact);
    return .{
        .artifact_path = artifact_z,
        .owned_artifact_path = artifact_z,
        .hmm_score = if (object.get("hmm_score")) |value| @floatCast(numberValue(value) orelse default_hmm_score) else default_hmm_score,
    };
}

fn readFile(path_z: [*:0]const u8) ![]u8 {
    const file = c.fopen(path_z, "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(file);
    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.ReadFailed;
    const size_raw = c.ftell(file);
    if (size_raw < 0 or size_raw > 16 * 1024 * 1024) return error.ReadFailed;
    if (c.fseek(file, 0, c.SEEK_SET) != 0) return error.ReadFailed;
    const size: usize = @intCast(size_raw);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    if (c.fread(buf.ptr, 1, size, file) != size) return error.ReadFailed;
    return buf;
}

export fn nx_plugin_free(plugin_ptr: ?*anyopaque) void {
    const plugin: *Plugin = @ptrCast(@alignCast(plugin_ptr orelse return));
    plugin.lexicon.deinit();
    plugin.parsed.deinit();
    allocator.free(plugin.artifact);
    allocator.destroy(plugin);
}

export fn nx_plugin_get_info(plugin_ptr: ?*anyopaque, out_info: ?*NxPluginInfo) c_int {
    _ = plugin_ptr;
    const info = out_info orelse return 1;
    info.* = .{
        .abi_version = abi_version,
        .name = "hmm_lattice_plugin",
        .version = "0.1.0",
        .kind = candidate_provider_kind,
    };
    return 0;
}

export fn nx_plugin_provide_candidates(
    plugin_ptr: ?*anyopaque,
    input: ?*const NxPluginInput,
    callback: ?NxPluginCandidateCallback,
    user_data: ?*anyopaque,
) c_int {
    const plugin: *Plugin = @ptrCast(@alignCast(plugin_ptr orelse return 1));
    const in_data = input orelse return 1;
    const cb = callback orelse return 1;
    const text = in_data.text[0..in_data.text_len];
    provideLexiconCandidates(plugin, text, in_data.char_len, cb, user_data);
    provideHmmCandidates(plugin, text, cb, user_data) catch return 1;
    return 0;
}

fn buildLexiconTrie(trie: *LexiconTrie, root: std.json.Value) !void {
    const lexicon = (((root.object.get("lexicon") orelse return error.BadArtifact).array).items);
    for (lexicon) |entry| {
        if (entry == .string) try trie.insert(entry.string);
    }
}

fn provideLexiconCandidates(plugin: *Plugin, text: []const u8, char_len: u32, cb: NxPluginCandidateCallback, user_data: ?*anyopaque) void {
    if (plugin.lexicon.nodes.items.len == 0) return;
    var byte_start: usize = 0;
    while (byte_start < text.len) : (byte_start += 1) {
        var node_index: usize = 0;
        var byte_end = byte_start;
        while (byte_end < text.len) : (byte_end += 1) {
            node_index = plugin.lexicon.child(node_index, text[byte_end]) orelse break;
            if (plugin.lexicon.nodes.items[node_index].terminal) {
                const end = byte_end + 1;
                const start_char = byteToChar(text, byte_start) orelse continue;
                const end_char = byteToChar(text, end) orelse continue;
                const len = end_char - start_char;
                if (end_char <= char_len and len >= 2) {
                    var candidate = NxPluginCandidate{
                        .start_char = start_char,
                        .end_char = end_char,
                        .score = 60.0 * @as(f32, @floatFromInt(len)) - 20.0,
                        .source = 0,
                        .flags = 1,
                    };
                    cb(&candidate, user_data);
                }
            }
        }
    }
}

fn provideHmmCandidates(plugin: *Plugin, text: []const u8, cb: NxPluginCandidateCallback, user_data: ?*anyopaque) !void {
    var chars: std.ArrayListUnmanaged(Char) = .empty;
    defer chars.deinit(allocator);
    var byte_pos: usize = 0;
    while (byte_pos < text.len) {
        const len = try std.unicode.utf8ByteSequenceLength(text[byte_pos]);
        const cp = try std.unicode.utf8Decode(text[byte_pos .. byte_pos + len]);
        try chars.append(allocator, .{
            .start_byte = byte_pos,
            .end_byte = byte_pos + len,
            .codepoint = cp,
        });
        byte_pos += len;
    }

    var run_start: usize = 0;
    while (run_start < chars.items.len) {
        while (run_start < chars.items.len and !isHan(chars.items[run_start].codepoint)) : (run_start += 1) {}
        var run_end = run_start;
        while (run_end < chars.items.len and isHan(chars.items[run_end].codepoint)) : (run_end += 1) {}
        if (run_end - run_start >= 2) try decodeHmmRun(plugin, text, chars.items, run_start, run_end, cb, user_data);
        run_start = run_end + 1;
    }
}

fn decodeHmmRun(
    plugin: *Plugin,
    text: []const u8,
    chars: []const Char,
    start: usize,
    end: usize,
    cb: NxPluginCandidateCallback,
    user_data: ?*anyopaque,
) !void {
    const n = end - start;
    if (n == 0 or n > 256) return;
    const scores = try allocator.alloc([4]f64, n);
    defer allocator.free(scores);
    const prev = try allocator.alloc([4]?State, n);
    defer allocator.free(prev);
    for (scores) |*row| row.* = .{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (prev) |*row| row.* = .{ null, null, null, null };

    inline for (.{ State.B, State.S }) |state| {
        scores[0][@intFromEnum(state)] = modelScore(plugin, "start", state.name(), null) + emissionScore(plugin, state, text[chars[start].start_byte..chars[start].end_byte]);
    }

    var i: usize = 1;
    while (i < n) : (i += 1) {
        inline for (.{ State.B, State.M, State.E, State.S }) |state| {
            inline for (.{ State.B, State.M, State.E, State.S }) |from| {
                if (transitionScore(plugin, from, state)) |trans| {
                    const candidate = scores[i - 1][@intFromEnum(from)] + trans + emissionScore(plugin, state, text[chars[start + i].start_byte..chars[start + i].end_byte]);
                    if (candidate > scores[i][@intFromEnum(state)]) {
                        scores[i][@intFromEnum(state)] = candidate;
                        prev[i][@intFromEnum(state)] = from;
                    }
                }
            }
        }
    }

    var state: State = if (scores[n - 1][@intFromEnum(State.E)] >= scores[n - 1][@intFromEnum(State.S)]) .E else .S;
    const states = try allocator.alloc(State, n);
    defer allocator.free(states);
    var cursor = n;
    while (cursor > 0) {
        cursor -= 1;
        states[cursor] = state;
        state = prev[cursor][@intFromEnum(state)] orelse state;
    }

    var word_start = start;
    i = 0;
    while (i < n) : (i += 1) {
        switch (states[i]) {
            .B => word_start = start + i,
            .E => {
                try emitHmmCandidate(chars, word_start, start + i + 1, plugin.hmm_score, cb, user_data);
            },
            .S => word_start = start + i + 1,
            .M => {},
        }
    }
}

fn emitHmmCandidate(chars: []const Char, start: usize, end: usize, score: f32, cb: NxPluginCandidateCallback, user_data: ?*anyopaque) !void {
    if (end <= start + 1) return;
    var candidate = NxPluginCandidate{
        .start_char = @intCast(start),
        .end_char = @intCast(end),
        .score = score,
        .source = 0,
        .flags = 2,
    };
    _ = chars;
    cb(&candidate, user_data);
}

fn transitionScore(plugin: *Plugin, from: State, to: State) ?f64 {
    const transition = ((plugin.parsed.value.object.get("model") orelse return null).object.get("transition") orelse return null).object;
    const from_map = (transition.get(from.name()) orelse return null).object;
    return numberValue(from_map.get(to.name()) orelse return null);
}

fn emissionScore(plugin: *Plugin, state: State, ch: []const u8) f64 {
    const model = (plugin.parsed.value.object.get("model") orelse return -20.0).object;
    if (model.get("emission")) |emission_value| {
        const state_map = (emission_value.object.get(state.name()) orelse return unknownEmission(plugin, state)).object;
        if (state_map.get(ch)) |value| return numberValue(value) orelse unknownEmission(plugin, state);
    }
    return unknownEmission(plugin, state);
}

fn unknownEmission(plugin: *Plugin, state: State) f64 {
    const model = (plugin.parsed.value.object.get("model") orelse return -20.0).object;
    const unknown = (model.get("unknown_emission") orelse return -20.0).object;
    return numberValue(unknown.get(state.name()) orelse return -20.0) orelse -20.0;
}

fn modelScore(plugin: *Plugin, field: []const u8, key: []const u8, fallback: ?f64) f64 {
    const model = (plugin.parsed.value.object.get("model") orelse return fallback orelse -20.0).object;
    const object = (model.get(field) orelse return fallback orelse -20.0).object;
    return numberValue(object.get(key) orelse return fallback orelse -20.0) orelse fallback orelse -20.0;
}

fn numberValue(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        .number_string => |v| std.fmt.parseFloat(f64, v) catch null,
        else => null,
    };
}

fn isHan(cp: u21) bool {
    return (cp >= 0x3400 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0x20000 and cp <= 0x2A6DF);
}

fn byteToChar(text: []const u8, byte_pos: usize) ?u32 {
    if (byte_pos > text.len) return null;
    var i: usize = 0;
    var chars: u32 = 0;
    while (i < byte_pos) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return null;
        if (i + len > byte_pos) return null;
        i += len;
        chars += 1;
    }
    return chars;
}
