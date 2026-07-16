const std = @import("std");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("windows.h");
}) else @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

const abi_version = 2;
const candidate_provider_kind = 1;
const artifact_magic = "NXBMES01";
const dict_magic = "NXDICT1\x00";
const state_count = 5;
const state_names = [_][]const u8{ "O", "B", "M", "E", "S" };
const Weights = [state_count]f32;
const zero_weights = [_]f32{0.0} ** state_count;
const default_score_per_char: f32 = 3.0;
const default_edge_penalty: f32 = 10.0;
const default_min_margin: f32 = 35.0;
const max_candidate_score: f32 = 400.0;
const default_min_chars: u32 = 2;
const default_max_chars: u32 = 64;
const default_flags: u16 = 4;
const inference_gate_min_lexicon_chars: u32 = 3;
const inference_gate_min_signal: f32 = 30.0;
const inference_gate_fallback_max_chars: usize = 17;
const allocator = std.heap.c_allocator;

const NxPluginInfo = extern struct {
    abi_version: u32,
    name: ?[*:0]const u8,
    version: ?[*:0]const u8,
    kind: u32,
};

const NxPluginChar = extern struct {
    codepoint: u32,
    start_byte: u32,
    end_byte: u32,
    char_index: u32,
    char_class: u16,
    flags: u16,
};

const NxPluginInput = extern struct {
    text: [*]const u8,
    text_len: usize,
    char_len: u32,
    chars: ?[*]const NxPluginChar,
};

const NxPluginCandidate = extern struct {
    start_char: u32,
    end_char: u32,
    score: f32,
    source: u16,
    flags: u16,
};

const NxPluginCandidateCallback = *const fn (*const NxPluginCandidate, ?*anyopaque) callconv(.c) void;

const FeatureRecord = extern struct {
    hash: u64,
    weights: [state_count]f32,
    reserved: u32,
};

const char_feature_count = 5;
const missing_feature = std.math.maxInt(u32);
const missing_char_features = [_]u32{missing_feature} ** char_feature_count;
const CharFeatures = [char_feature_count]u32;

const FeatureIndex = struct {
    const Slot = struct {
        hash: u64 = 0,
        index: u32 = missing_feature,
    };

    slots: []Slot,
    mask: usize,

    fn init(features: []const FeatureRecord) !FeatureIndex {
        if (features.len == 0 or features.len > std.math.maxInt(usize) / 2) return error.BadArtifact;
        var capacity: usize = 1;
        while (capacity < features.len * 2) capacity *= 2;
        const slots = try allocator.alloc(Slot, capacity);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        const mask = capacity - 1;
        for (features, 0..) |record, index| {
            var slot = @as(usize, @truncate(record.hash)) & mask;
            while (slots[slot].index != missing_feature) slot = (slot + 1) & mask;
            slots[slot] = .{ .hash = record.hash, .index = @intCast(index) };
        }
        return .{ .slots = slots, .mask = mask };
    }

    fn deinit(self: *FeatureIndex) void {
        allocator.free(self.slots);
    }

    fn get(self: FeatureIndex, hash: u64) ?u32 {
        var slot = @as(usize, @truncate(hash)) & self.mask;
        while (self.slots[slot].index != missing_feature) : (slot = (slot + 1) & self.mask) {
            if (self.slots[slot].hash == hash) return self.slots[slot].index;
        }
        return null;
    }
};

const CodepointIndexContext = struct {
    pub fn hash(_: @This(), key: u32) u64 {
        return @as(u64, key) *% 0x9e3779b97f4a7c15;
    }

    pub fn eql(_: @This(), left: u32, right: u32) bool {
        return left == right;
    }
};

const CharFeatureIndex = std.HashMapUnmanaged(
    u32,
    CharFeatures,
    CodepointIndexContext,
    std.hash_map.default_max_load_percentage,
);

const CharFeatureTable = struct {
    bmp: []CharFeatures,
    non_bmp: CharFeatureIndex,

    fn deinit(self: *CharFeatureTable) void {
        self.non_bmp.deinit(allocator);
        allocator.free(self.bmp);
    }

    fn get(self: CharFeatureTable, codepoint: u32) CharFeatures {
        if (codepoint < self.bmp.len) return self.bmp[codepoint];
        return self.non_bmp.get(codepoint) orelse missing_char_features;
    }
};

const LexiconWeights = struct {
    roles: [4]Weights,
    buckets: [4][4]Weights,
};

const CharClass = enum(u8) {
    han,
    digit,
    latin,
    space,
    other,
    punct,
    bos1,
    bos2,
    eos1,
    eos2,
};

const char_class_count = @typeInfo(CharClass).@"enum".fields.len;
const char_class_names = [_][]const u8{ "HAN", "DIGIT", "LATIN", "SPACE", "OTHER", "PUNCT", "<BOS1>", "<BOS2>", "<EOS1>", "<EOS2>" };

const FixedFeatures = struct {
    bias: Weights,
    transitions: [state_count + 1]Weights,
    general_lexicon: LexiconWeights,
    entity_lexicon: LexiconWeights,
    class_unigrams: [3][char_class_count]Weights,
    class_bigrams: [2][char_class_count][char_class_count]Weights,
    boundary_chars: [4]CharFeatures,
};

const DatNode = extern struct {
    word_id: u32,
    score: f32,
};

const Dict = struct {
    code_ids: []u16,
    base: []const u32,
    check: []const u32,
    nodes: []const DatNode,

    fn deinit(self: *Dict) void {
        allocator.free(self.code_ids);
    }

    fn child(self: Dict, state: u32, codepoint: u32) ?u32 {
        if (state >= self.base.len) return null;
        if (codepoint >= self.code_ids.len) return null;
        const code_id = self.code_ids[codepoint];
        if (code_id == 0) return null;
        const next = @as(u64, self.base[state]) + code_id;
        if (next >= self.check.len) return null;
        const index: usize = @intCast(next);
        if (self.check[index] != state + 1) return null;
        return @intCast(index);
    }

    fn contains(self: Dict, chars: []const Char, start: usize, end: usize) bool {
        var state: u32 = 0;
        for (chars[start..end]) |char| state = self.child(state, char.codepoint) orelse return false;
        return self.nodes[state].word_id != 0;
    }
};

const Model = struct {
    mapping: MappedFile,
    features: []const FeatureRecord,
    feature_index: FeatureIndex,
    char_features: CharFeatureTable,
    fixed: FixedFeatures,
    max_word_len: u32,
    general: Dict,
    entity: Dict,

    fn deinit(self: *Model) void {
        self.entity.deinit();
        self.general.deinit();
        self.char_features.deinit();
        self.feature_index.deinit();
        self.mapping.close();
    }

    fn weights(self: *const Model, hash: u64) ?[state_count]f32 {
        const index = self.featureRecordIndex(hash) orelse return null;
        return self.features[index].weights;
    }

    fn featureRecordIndex(self: *const Model, hash: u64) ?u32 {
        return self.feature_index.get(hash);
    }
};

fn initFixedFeatures(model: *const Model) FixedFeatures {
    var fixed: FixedFeatures = std.mem.zeroes(FixedFeatures);
    fixed.bias = model.weights(featureHash("bias")) orelse zero_weights;
    const transition_names = [_][]const u8{ "T=<START>", "T=O", "T=B", "T=M", "T=E", "T=S" };
    for (transition_names, 0..) |name, index| {
        fixed.transitions[index] = model.weights(featureHash(name)) orelse zero_weights;
    }
    fixed.general_lexicon = initLexiconWeights(model, "lx");
    fixed.entity_lexicon = initLexiconWeights(model, "ex");
    const unigram_prefixes = [_][]const u8{ "k0=", "k-1=", "k+1=" };
    for (unigram_prefixes, 0..) |prefix, prefix_index| {
        for (char_class_names, 0..) |name, class_index| {
            fixed.class_unigrams[prefix_index][class_index] = model.weights(hashParts(&.{ prefix, name })) orelse zero_weights;
        }
    }
    const bigram_prefixes = [_][]const u8{ "k-1k0=", "k0k+1=" };
    for (bigram_prefixes, 0..) |prefix, prefix_index| {
        for (char_class_names, 0..) |left, left_index| {
            for (char_class_names, 0..) |right, right_index| {
                fixed.class_bigrams[prefix_index][left_index][right_index] = model.weights(hashParts(&.{ prefix, left, ":", right })) orelse zero_weights;
            }
        }
    }
    const char_prefixes = [_][]const u8{ "c0=", "c-1=", "c+1=", "c-2=", "c+2=" };
    const boundary_names = [_][]const u8{ "<BOS1>", "<BOS2>", "<EOS1>", "<EOS2>" };
    for (boundary_names, 0..) |name, boundary_index| {
        fixed.boundary_chars[boundary_index] = featureIndices(model, char_prefixes, name);
    }
    return fixed;
}

fn initCharFeatureIndex(model: *const Model) !CharFeatureTable {
    const bmp = try allocator.alloc(CharFeatures, 0x10000);
    errdefer allocator.free(bmp);
    @memset(bmp, missing_char_features);
    var non_bmp: CharFeatureIndex = .empty;
    errdefer non_bmp.deinit(allocator);
    const prefixes = [_][]const u8{ "c0=", "c-1=", "c+1=", "c-2=", "c+2=" };
    var codepoint: u32 = 0;
    while (codepoint <= 0x10ffff) : (codepoint += 1) {
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch continue;
        const features = featureIndices(model, prefixes, encoded[0..len]);
        if (!std.mem.eql(u32, &features, &missing_char_features)) {
            if (codepoint < bmp.len) {
                bmp[codepoint] = features;
            } else {
                try non_bmp.put(allocator, codepoint, features);
            }
        }
    }
    return .{ .bmp = bmp, .non_bmp = non_bmp };
}

fn featureIndices(model: *const Model, prefixes: [char_feature_count][]const u8, value: []const u8) CharFeatures {
    var features = missing_char_features;
    for (prefixes, 0..) |prefix, index| {
        features[index] = model.featureRecordIndex(hashParts(&.{ prefix, value })) orelse missing_feature;
    }
    return features;
}

fn initLexiconWeights(model: *const Model, prefix: []const u8) LexiconWeights {
    var weights: LexiconWeights = std.mem.zeroes(LexiconWeights);
    const role_names = [_][]const u8{ "B", "M", "E", "S" };
    const bucket_names = [_][]const u8{ "2", "3", "4", "5+" };
    for (role_names, 0..) |role, role_index| {
        weights.roles[role_index] = model.weights(hashParts(&.{ prefix, "=", role })) orelse zero_weights;
        for (bucket_names, 0..) |bucket, bucket_index| {
            weights.buckets[role_index][bucket_index] = model.weights(hashParts(&.{ prefix, "=", role, ":", bucket })) orelse zero_weights;
        }
    }
    return weights;
}

const Plugin = struct {
    model: Model,
    score_per_char: f32,
    edge_penalty: f32,
    min_margin: f32,
    min_chars: u32,
    max_chars: u32,
    flags: u16,
};

const MappedFile = struct {
    data: []const u8,
    file: if (builtin.os.tag == .windows) c.HANDLE else c_int,
    mapping: if (builtin.os.tag == .windows) c.HANDLE else void,

    fn close(self: MappedFile) void {
        if (builtin.os.tag == .windows) {
            _ = c.UnmapViewOfFile(self.data.ptr);
            _ = c.CloseHandle(self.mapping);
            _ = c.CloseHandle(self.file);
        } else {
            _ = c.munmap(@constCast(self.data.ptr), self.data.len);
            _ = c.close(self.file);
        }
    }
};

const Char = NxPluginChar;

const Config = struct {
    artifact_path: [*:0]const u8,
    owned_artifact_path: ?[:0]u8 = null,
    score_per_char: f32 = default_score_per_char,
    edge_penalty: f32 = default_edge_penalty,
    min_margin: f32 = default_min_margin,
    min_chars: u32 = default_min_chars,
    max_chars: u32 = default_max_chars,
    flags: u16 = default_flags,
};

export fn nx_plugin_init(config_json: ?[*:0]const u8, out_plugin: *?*anyopaque) c_int {
    const config_z = config_json orelse return 1;
    const plugin = initPlugin(config_z) catch return 1;
    out_plugin.* = @ptrCast(plugin);
    return 0;
}

export fn nx_plugin_free(plugin_ptr: ?*anyopaque) void {
    const plugin: *Plugin = @ptrCast(@alignCast(plugin_ptr orelse return));
    plugin.model.deinit();
    allocator.destroy(plugin);
}

export fn nx_plugin_get_info(plugin_ptr: ?*anyopaque, out_info: ?*NxPluginInfo) c_int {
    _ = plugin_ptr;
    const info = out_info orelse return 1;
    info.* = .{
        .abi_version = abi_version,
        .name = "entity_bmes_plugin",
        .version = "0.2.0",
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
    const chars = in_data.chars orelse return 1;
    provideCandidates(plugin, in_data.text[0..in_data.text_len], chars[0..in_data.char_len], cb, user_data) catch return 1;
    return 0;
}

fn initPlugin(config_z: [*:0]const u8) !*Plugin {
    const config = try parseConfig(config_z);
    defer if (config.owned_artifact_path) |path| allocator.free(path);
    var model = try loadModel(config.artifact_path);
    errdefer model.deinit();
    const plugin = try allocator.create(Plugin);
    plugin.* = .{
        .model = model,
        .score_per_char = config.score_per_char,
        .edge_penalty = config.edge_penalty,
        .min_margin = config.min_margin,
        .min_chars = config.min_chars,
        .max_chars = config.max_chars,
        .flags = config.flags,
    };
    return plugin;
}

fn parseConfig(config_z: [*:0]const u8) !Config {
    const config = std.mem.span(config_z);
    if (config.len == 0) return error.BadConfig;
    if (config[0] != '{') return .{ .artifact_path = config_z };
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, config, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.BadConfig,
    };
    const artifact = switch (object.get("artifact") orelse return error.BadConfig) {
        .string => |value| value,
        else => return error.BadConfig,
    };
    const artifact_z = try allocator.dupeZ(u8, artifact);
    errdefer allocator.free(artifact_z);
    var out = Config{ .artifact_path = artifact_z, .owned_artifact_path = artifact_z };
    if (object.get("score_per_char")) |value| out.score_per_char = @floatCast(numberValue(value) orelse return error.BadConfig);
    if (object.get("edge_penalty")) |value| out.edge_penalty = @floatCast(numberValue(value) orelse return error.BadConfig);
    if (object.get("min_margin")) |value| out.min_margin = @floatCast(numberValue(value) orelse return error.BadConfig);
    if (!std.math.isFinite(out.score_per_char) or !std.math.isFinite(out.edge_penalty) or !std.math.isFinite(out.min_margin)) return error.BadConfig;
    if (object.get("min_chars")) |value| out.min_chars = u32Value(value) orelse return error.BadConfig;
    if (object.get("max_chars")) |value| out.max_chars = u32Value(value) orelse return error.BadConfig;
    if (object.get("flags")) |value| {
        const flags = u32Value(value) orelse return error.BadConfig;
        if (flags > std.math.maxInt(u16)) return error.BadConfig;
        out.flags = @intCast(flags);
    }
    if (out.min_chars == 0 or out.max_chars < out.min_chars or out.max_chars > default_max_chars) return error.BadConfig;
    return out;
}

fn loadModel(path_z: [*:0]const u8) !Model {
    var mapping = try mapFileReadOnly(path_z);
    errdefer mapping.close();
    const data = mapping.data;
    if (data.len < 32 or !std.mem.eql(u8, data[0..8], artifact_magic)) return error.BadArtifact;
    var offset: usize = 8;
    const version = readU32(data, &offset) orelse return error.BadArtifact;
    const feature_count = readU32(data, &offset) orelse return error.BadArtifact;
    const max_word_len = readU32(data, &offset) orelse return error.BadArtifact;
    const general_len = readU32(data, &offset) orelse return error.BadArtifact;
    const entity_len = readU32(data, &offset) orelse return error.BadArtifact;
    const record_size = readU32(data, &offset) orelse return error.BadArtifact;
    if (version != 1 or record_size != @sizeOf(FeatureRecord) or max_word_len < 2) return error.BadArtifact;
    const features = sliceAs(FeatureRecord, data, &offset, feature_count) orelse return error.BadArtifact;
    const general_data = sliceBytes(data, &offset, general_len) orelse return error.BadArtifact;
    const entity_data = sliceBytes(data, &offset, entity_len) orelse return error.BadArtifact;
    if (offset != data.len) return error.BadArtifact;
    for (features[1..], 1..) |record, index| {
        if (record.hash <= features[index - 1].hash) return error.BadArtifact;
    }
    var feature_index = try FeatureIndex.init(features);
    errdefer feature_index.deinit();
    var general = try parseDict(general_data);
    errdefer general.deinit();
    var entity = try parseDict(entity_data);
    errdefer entity.deinit();
    var model = Model{
        .mapping = mapping,
        .features = features,
        .feature_index = feature_index,
        .char_features = undefined,
        .fixed = std.mem.zeroes(FixedFeatures),
        .max_word_len = max_word_len,
        .general = general,
        .entity = entity,
    };
    model.fixed = initFixedFeatures(&model);
    model.char_features = try initCharFeatureIndex(&model);
    return model;
}

fn parseDict(data: []const u8) !Dict {
    if (data.len < 20 or !std.mem.eql(u8, data[0..8], dict_magic)) return error.BadArtifact;
    var offset: usize = 8;
    const code_count = readU32(data, &offset) orelse return error.BadArtifact;
    const state_count_value = readU32(data, &offset) orelse return error.BadArtifact;
    _ = readU32(data, &offset) orelse return error.BadArtifact;
    const codepoints = sliceAs(u32, data, &offset, code_count) orelse return error.BadArtifact;
    const base = sliceAs(u32, data, &offset, state_count_value) orelse return error.BadArtifact;
    const check = sliceAs(u32, data, &offset, state_count_value) orelse return error.BadArtifact;
    const nodes = sliceAs(DatNode, data, &offset, state_count_value) orelse return error.BadArtifact;
    if (base.len == 0 or base.len != check.len or base.len != nodes.len) return error.BadArtifact;
    if (codepoints.len == 0 or codepoints.len > std.math.maxInt(u16)) return error.BadArtifact;
    const max_codepoint = codepoints[codepoints.len - 1];
    if (max_codepoint > 0x10ffff) return error.BadArtifact;
    const code_ids = try allocator.alloc(u16, @as(usize, max_codepoint) + 1);
    errdefer allocator.free(code_ids);
    @memset(code_ids, 0);
    for (codepoints, 0..) |codepoint, index| {
        if (index > 0 and codepoint <= codepoints[index - 1]) return error.BadArtifact;
        code_ids[codepoint] = @intCast(index + 1);
    }
    return .{ .code_ids = code_ids, .base = base, .check = check, .nodes = nodes };
}

fn provideCandidates(
    plugin: *const Plugin,
    text: []const u8,
    input_chars: []const NxPluginChar,
    cb: NxPluginCandidateCallback,
    user_data: ?*anyopaque,
) !void {
    if (input_chars.len < plugin.min_chars) return;
    const chars = input_chars;
    if (chars.len == 0) return;
    if (chars[0].start_byte != 0 or chars[chars.len - 1].end_byte != text.len) return error.InvalidInput;
    if (!hasLexiconMatch(&plugin.model, plugin.model.entity, chars, inference_gate_min_lexicon_chars) and
        !hasEntitySignal(&plugin.model, chars, 0, chars.len, inference_gate_min_signal)) return;

    var segment_start: usize = 0;
    while (segment_start < chars.len) {
        while (segment_start < chars.len and isHardBoundary(chars, segment_start)) segment_start += 1;
        var segment_end = segment_start;
        while (segment_end < chars.len and !isHardBoundary(chars, segment_end)) segment_end += 1;
        if (segment_end - segment_start >= plugin.min_chars) {
            const force = segment_end - segment_start <= inference_gate_fallback_max_chars;
            try provideSegment(plugin, text, chars, segment_start, segment_end, force, cb, user_data);
        }
        segment_start = segment_end + @intFromBool(segment_end < chars.len);
    }
}

fn provideSegment(
    plugin: *const Plugin,
    text: []const u8,
    chars: []const Char,
    segment_start: usize,
    segment_end: usize,
    force: bool,
    cb: NxPluginCandidateCallback,
    user_data: ?*anyopaque,
) !void {
    const segment = chars[segment_start..segment_end];
    if (!force and !hasLexiconMatch(&plugin.model, plugin.model.entity, segment, inference_gate_min_lexicon_chars) and
        !hasEntitySignal(&plugin.model, chars, segment_start, segment_end, inference_gate_min_signal)) return;

    const emissions = try allocator.alloc([state_count]f32, segment.len);
    defer allocator.free(emissions);
    const back = try allocator.alloc([state_count]u8, segment.len);
    defer allocator.free(back);
    for (emissions, 0..) |*scores, local_index| {
        scores.* = [_]f32{0.0} ** state_count;
        addWeights(scores, plugin.model.fixed.bias);
        addBaseFeatures(&plugin.model, text, chars, segment_start + local_index, scores);
    }
    addLexiconFeaturesAll(&plugin.model, plugin.model.general, plugin.model.fixed.general_lexicon, segment, emissions, back);
    addLexiconFeaturesAll(&plugin.model, plugin.model.entity, plugin.model.fixed.entity_lexicon, segment, emissions, back);
    const transitions = plugin.model.fixed.transitions;

    // Lexicon extraction reuses the backpointer allocation as scratch; clear it before Viterbi.
    @memset(back, [_]u8{0} ** state_count);
    var previous = [_]f32{-std.math.inf(f32)} ** state_count;
    const initial_transition = if (segment_start == 0) transitions[0] else transitions[1];
    for ([_]usize{ 0, 1, 4 }) |state| previous[state] = emissions[0][state] + initial_transition[state];
    back[0] = [_]u8{0} ** state_count;
    for (1..segment.len) |position| {
        var current = [_]f32{-std.math.inf(f32)} ** state_count;
        for (0..state_count) |to| {
            for (0..state_count) |from| {
                if (!allowedTransition(from, to) or !std.math.isFinite(previous[from])) continue;
                const score = previous[from] + transitions[from + 1][to] + emissions[position][to];
                if (score > current[to]) {
                    current[to] = score;
                    back[position][to] = @intCast(from);
                }
            }
        }
        previous = current;
    }
    const has_trailing_boundary = segment_end < chars.len;
    var final_state: usize = 0;
    var final_score = previous[0] + if (has_trailing_boundary) transitions[1][0] else 0.0;
    for ([_]usize{ 3, 4 }) |state| {
        const score = previous[state] + if (has_trailing_boundary) transitions[state + 1][0] else 0.0;
        if (score > final_score) {
            final_state = state;
            final_score = score;
        }
    }
    const tags = try allocator.alloc(u8, segment.len);
    defer allocator.free(tags);
    tags[tags.len - 1] = @intCast(final_state);
    var position = tags.len - 1;
    while (position > 0) : (position -= 1) tags[position - 1] = back[position][tags[position]];

    var index: usize = 0;
    while (index < tags.len) {
        var end = index + 1;
        if (tags[index] == 1) {
            while (end < tags.len and tags[end] == 2) : (end += 1) {}
            if (end >= tags.len or tags[end] != 3) {
                index += 1;
                continue;
            }
            end += 1;
        } else if (tags[index] != 4) {
            index += 1;
            continue;
        }
        const length = end - index;
        const absolute_index = segment_start + index;
        const absolute_end = segment_start + end;
        if (length >= plugin.min_chars and length <= plugin.max_chars and
            asciiBoundaryOk(chars, absolute_index, absolute_end) and !plugin.model.general.contains(chars, absolute_index, absolute_end))
        {
            const margin = candidateMargin(emissions, tags, index, end);
            const score = @min(max_candidate_score, plugin.score_per_char * margin - plugin.edge_penalty);
            if (std.math.isFinite(margin) and margin >= plugin.min_margin and std.math.isFinite(score)) {
                var candidate = NxPluginCandidate{
                    .start_char = @intCast(absolute_index),
                    .end_char = @intCast(absolute_end),
                    .score = score,
                    .source = 0,
                    .flags = plugin.flags,
                };
                cb(&candidate, user_data);
            }
        }
        index = end;
    }
}

fn hasLexiconMatch(model: *const Model, dict: Dict, chars: []const Char, minimum: u32) bool {
    const max_len: usize = model.max_word_len;
    for (0..chars.len) |start| {
        var state: u32 = 0;
        var end = start;
        while (end < chars.len and end - start < max_len) : (end += 1) {
            state = dict.child(state, chars[end].codepoint) orelse break;
            if (dict.nodes[state].word_id != 0 and end - start + 1 >= minimum) return true;
        }
    }
    return false;
}

fn hasEntitySignal(model: *const Model, chars: []const Char, start: usize, end: usize, minimum: f32) bool {
    for (start..end) |index| {
        var begin = model.fixed.bias[1] - model.fixed.bias[0];
        var single = model.fixed.bias[4] - model.fixed.bias[0];
        for (0..char_feature_count) |template| {
            const position = switch (template) {
                0 => @as(isize, @intCast(index)),
                1 => @as(isize, @intCast(index)) - 1,
                2 => @as(isize, @intCast(index)) + 1,
                3 => @as(isize, @intCast(index)) - 2,
                else => @as(isize, @intCast(index)) + 2,
            };
            const feature_index = charFeatureAt(model, chars, position, template);
            if (feature_index == missing_feature) continue;
            const weights = model.features[feature_index].weights;
            begin += weights[1] - weights[0];
            single += weights[4] - weights[0];
        }
        const left: usize = @intFromEnum(charClass(chars, @as(isize, @intCast(index)) - 1));
        const current: usize = @intFromEnum(charClass(chars, @intCast(index)));
        const right: usize = @intFromEnum(charClass(chars, @as(isize, @intCast(index)) + 1));
        for ([_]Weights{
            model.fixed.class_unigrams[0][current],
            model.fixed.class_unigrams[1][left],
            model.fixed.class_unigrams[2][right],
            model.fixed.class_bigrams[0][left][current],
            model.fixed.class_bigrams[1][current][right],
        }) |weights| {
            begin += weights[1] - weights[0];
            single += weights[4] - weights[0];
        }
        if (begin >= minimum or single >= minimum) return true;
    }
    return false;
}

fn candidateMargin(emissions: []const [state_count]f32, tags: []const u8, start: usize, end: usize) f32 {
    var total: f32 = 0.0;
    for (start..end) |index| {
        const chosen: usize = tags[index];
        var alternative = -std.math.inf(f32);
        for (0..state_count) |state| {
            if (state != chosen) alternative = @max(alternative, emissions[index][state]);
        }
        total += emissions[index][chosen] - alternative;
    }
    return total / @as(f32, @floatFromInt(end - start));
}

fn addBaseFeatures(model: *const Model, text: []const u8, chars: []const Char, index: usize, scores: *[state_count]f32) void {
    const c2l = charAt(text, chars, @as(isize, @intCast(index)) - 2);
    const c1l = charAt(text, chars, @as(isize, @intCast(index)) - 1);
    const c0 = charAt(text, chars, @intCast(index));
    const c1r = charAt(text, chars, @as(isize, @intCast(index)) + 1);
    const c2r = charAt(text, chars, @as(isize, @intCast(index)) + 2);
    const k1l = charClass(chars, @as(isize, @intCast(index)) - 1);
    const k0 = charClass(chars, @intCast(index));
    const k1r = charClass(chars, @as(isize, @intCast(index)) + 1);
    addFeature(model, scores, charFeatureAt(model, chars, @intCast(index), 0));
    addFeature(model, scores, charFeatureAt(model, chars, @as(isize, @intCast(index)) - 1, 1));
    addFeature(model, scores, charFeatureAt(model, chars, @as(isize, @intCast(index)) + 1, 2));
    addFeature(model, scores, charFeatureAt(model, chars, @as(isize, @intCast(index)) - 2, 3));
    addFeature(model, scores, charFeatureAt(model, chars, @as(isize, @intCast(index)) + 2, 4));
    addHash(model, scores, hashFeature("c-1c0=", .{ c1l, c0 }));
    addHash(model, scores, hashFeature("c0c+1=", .{ c0, c1r }));
    addHash(model, scores, hashFeature("c-2c-1c0=", .{ c2l, c1l, c0 }));
    addHash(model, scores, hashFeature("c0c+1c+2=", .{ c0, c1r, c2r }));
    const left: usize = @intFromEnum(k1l);
    const current: usize = @intFromEnum(k0);
    const right: usize = @intFromEnum(k1r);
    addWeights(scores, model.fixed.class_unigrams[0][current]);
    addWeights(scores, model.fixed.class_unigrams[1][left]);
    addWeights(scores, model.fixed.class_unigrams[2][right]);
    addWeights(scores, model.fixed.class_bigrams[0][left][current]);
    addWeights(scores, model.fixed.class_bigrams[1][current][right]);
}

fn charFeatureAt(model: *const Model, chars: []const Char, index: isize, template: usize) u32 {
    if (index < 0) return model.fixed.boundary_chars[if (index == -1) 0 else 1][template];
    if (index >= chars.len) return model.fixed.boundary_chars[if (index == chars.len) 2 else 3][template];
    return model.char_features.get(chars[@intCast(index)].codepoint)[template];
}

fn addLexiconFeaturesAll(
    model: *const Model,
    dict: Dict,
    weights: LexiconWeights,
    chars: []const Char,
    emissions: [][state_count]f32,
    scratch: [][state_count]u8,
) void {
    @memset(scratch, [_]u8{0} ** state_count);
    const max_len: usize = model.max_word_len;
    for (0..chars.len) |start| {
        var state: u32 = 0;
        var end = start;
        while (end < chars.len and end - start < max_len) : (end += 1) {
            state = dict.child(state, chars[end].codepoint) orelse break;
            const match_end = end + 1;
            const length = match_end - start;
            if (dict.nodes[state].word_id == 0 or length < 2) continue;
            const bucket: usize = if (length == 2) 0 else if (length == 3) 1 else if (length == 4) 2 else 3;
            for (start..match_end) |index| {
                const role: usize = if (index == start) 0 else if (index + 1 == match_end) 2 else 1;
                scratch[index][0] |= @as(u8, 1) << @intCast(role);
                const bit = role * 4 + bucket;
                scratch[index][1 + bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
            }
        }
    }

    for (scratch, 0..) |mask, index| {
        const buckets = @as(u16, mask[1]) | (@as(u16, mask[2]) << 8);
        for (0..4) |role_index| {
            if (mask[0] & (@as(u8, 1) << @intCast(role_index)) != 0) {
                addWeights(&emissions[index], weights.roles[role_index]);
            }
            for (0..4) |bucket_index| {
                const bit: u4 = @intCast(role_index * 4 + bucket_index);
                if (buckets & (@as(u16, 1) << bit) != 0) {
                    addWeights(&emissions[index], weights.buckets[role_index][bucket_index]);
                }
            }
        }
    }
}

fn addHash(model: *const Model, scores: *[state_count]f32, hash: u64) void {
    const weights = model.weights(hash) orelse return;
    addWeights(scores, weights);
}

fn addFeature(model: *const Model, scores: *[state_count]f32, index: u32) void {
    if (index != missing_feature) addWeights(scores, model.features[index].weights);
}

fn addWeights(scores: *[state_count]f32, weights: Weights) void {
    for (0..state_count) |index| scores[index] += weights[index];
}

fn featureHash(value: []const u8) u64 {
    return hashParts(&.{value});
}

fn hashFeature(comptime prefix: []const u8, parts: anytype) u64 {
    var hash = comptime featureHash(prefix);
    inline for (parts) |part| for (part) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    };
    return hash;
}

fn hashParts(parts: []const []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (parts) |part| for (part) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    };
    return hash;
}

fn charAt(text: []const u8, chars: []const Char, index: isize) []const u8 {
    if (index < 0) return if (index == -1) "<BOS1>" else "<BOS2>";
    const value: usize = @intCast(index);
    if (value >= chars.len) return if (value == chars.len) "<EOS1>" else "<EOS2>";
    return text[chars[value].start_byte..chars[value].end_byte];
}

fn charClass(chars: []const Char, index: isize) CharClass {
    if (index < 0) return if (index == -1) .bos1 else .bos2;
    if (index >= chars.len) return if (index == chars.len) .eos1 else .eos2;
    const cp = chars[@intCast(index)].codepoint;
    if ((cp >= 0x3400 and cp <= 0x9fff) or (cp >= 0x20000 and cp <= 0x2ebef)) return .han;
    if (isDigit(cp)) return .digit;
    if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z')) return .latin;
    if (isWhitespace(cp)) return .space;
    if (isCommonUnicodeLetter(cp)) return .other;
    return .punct;
}

fn isDigit(cp: u32) bool {
    return (cp >= '0' and cp <= '9') or (cp >= 0xff10 and cp <= 0xff19) or
        (cp >= 0x2460 and cp <= 0x249b) or (cp >= 0x2070 and cp <= 0x2079) or
        (cp >= 0x2080 and cp <= 0x2089) or cp == 0x00b2 or cp == 0x00b3 or cp == 0x00b9;
}

fn isCommonUnicodeLetter(cp: u32) bool {
    return (cp >= 0x00c0 and cp <= 0x02af) or (cp >= 0x0370 and cp <= 0x052f) or
        (cp >= 0xff21 and cp <= 0xff3a) or (cp >= 0xff41 and cp <= 0xff5a);
}

fn isHardBoundary(chars: []const Char, index: usize) bool {
    const cp = chars[index].codepoint;
    if (isWhitespace(cp)) return true;
    if (isAllowedConnector(cp)) {
        return index == 0 or index + 1 == chars.len or
            !isEntityBody(chars[index - 1].codepoint) or !isEntityBody(chars[index + 1].codepoint);
    }
    return !isEntityBody(cp);
}

fn isAllowedConnector(cp: u32) bool {
    return cp == 0x00b7 or cp == '-' or cp == 0x2010 or cp == 0x2011 or cp == '&' or cp == '/';
}

fn isEntityBody(cp: u32) bool {
    return (cp >= 0x3400 and cp <= 0x9fff) or (cp >= 0x20000 and cp <= 0x2ebef) or
        isDigit(cp) or (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or isCommonUnicodeLetter(cp);
}

fn isWhitespace(cp: u32) bool {
    return cp == ' ' or (cp >= 0x09 and cp <= 0x0d) or cp == 0x85 or cp == 0xa0 or cp == 0x1680 or
        (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000;
}

fn allowedTransition(from: usize, to: usize) bool {
    return switch (from) {
        0, 3, 4 => to == 0 or to == 1 or to == 4,
        1, 2 => to == 2 or to == 3,
        else => false,
    };
}

fn asciiBoundaryOk(chars: []const Char, start: usize, end: usize) bool {
    if (start > 0 and isAsciiAlnum(chars[start - 1].codepoint) and isAsciiAlnum(chars[start].codepoint)) return false;
    if (end < chars.len and isAsciiAlnum(chars[end - 1].codepoint) and isAsciiAlnum(chars[end].codepoint)) return false;
    return true;
}

fn isAsciiAlnum(codepoint: u32) bool {
    return (codepoint >= '0' and codepoint <= '9') or
        (codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z');
}

fn mapFileReadOnly(path_z: [*:0]const u8) !MappedFile {
    if (builtin.os.tag == .windows) {
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, std.mem.span(path_z));
        defer allocator.free(path_w);
        const file = c.CreateFileW(path_w.ptr, c.GENERIC_READ, c.FILE_SHARE_READ, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
        if (file == c.INVALID_HANDLE_VALUE) return error.OpenFailed;
        errdefer _ = c.CloseHandle(file);
        var high: c.DWORD = 0;
        const low = c.GetFileSize(file, &high);
        if (low == c.INVALID_FILE_SIZE and c.GetLastError() != c.NO_ERROR) return error.OpenFailed;
        if (high != 0 or low == 0) return error.BadArtifact;
        const mapping = c.CreateFileMappingA(file, null, c.PAGE_READONLY, 0, 0, null);
        if (mapping == null) return error.OpenFailed;
        errdefer _ = c.CloseHandle(mapping);
        const view = c.MapViewOfFile(mapping, c.FILE_MAP_READ, 0, 0, 0) orelse return error.OpenFailed;
        return .{ .data = @as([*]const u8, @ptrCast(view))[0..low], .file = file, .mapping = mapping };
    }
    const fd = c.open(path_z, c.O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    errdefer _ = c.close(fd);
    const end = c.lseek(fd, 0, c.SEEK_END);
    if (end <= 0) return error.OpenFailed;
    const size: usize = @intCast(end);
    const view = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    if (view == c.MAP_FAILED) return error.OpenFailed;
    return .{ .data = @as([*]const u8, @ptrCast(view))[0..size], .file = fd, .mapping = {} };
}

fn sliceAs(comptime T: type, data: []const u8, offset: *usize, count: u32) ?[]const T {
    if (offset.* > data.len) return null;
    const item_count: usize = count;
    if (item_count > (data.len - offset.*) / @sizeOf(T)) return null;
    const end = offset.* + item_count * @sizeOf(T);
    const aligned: []align(@alignOf(T)) const u8 = @alignCast(data[offset.*..end]);
    offset.* = end;
    return std.mem.bytesAsSlice(T, aligned);
}

fn sliceBytes(data: []const u8, offset: *usize, count: u32) ?[]const u8 {
    if (offset.* > data.len or count > data.len - offset.*) return null;
    const end = offset.* + count;
    const out = data[offset.*..end];
    offset.* = end;
    return out;
}

fn readU32(data: []const u8, offset: *usize) ?u32 {
    if (offset.* + 4 > data.len) return null;
    const out = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    return out;
}

fn numberValue(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        .number_string => |number| std.fmt.parseFloat(f64, number) catch null,
        else => null,
    };
}

fn u32Value(value: std.json.Value) ?u32 {
    const number: i64 = switch (value) {
        .integer => |item| item,
        .number_string => |item| std.fmt.parseInt(i64, item, 10) catch return null,
        else => return null,
    };
    if (number < 0 or number > std.math.maxInt(u32)) return null;
    return @intCast(number);
}
