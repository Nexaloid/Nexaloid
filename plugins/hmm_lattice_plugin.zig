const std = @import("std");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("windows.h");
}) else @cImport({
    @cInclude("fcntl.h");
    @cInclude("string.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

const abi_version = 1;
const candidate_provider_kind = 1;
const artifact_magic = "NXHMM001";
const header_len = 44;
const default_hmm_score: f32 = -14.0;
const allocator = std.heap.c_allocator;

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
    model: *Model,
    hmm_score: f32,
};

const Model = struct {
    path: []u8,
    mapping: MappedFile,
    start: [4]f64,
    transition: [4][4]f64,
    unknown: [4]f64,
    emissions: []Emission,
    lexicon_blob: []u8,
    lexicon: LexiconTrie,
    max_unknown_len: u32,
    refs: usize = 1,

    fn deinit(self: *Model) void {
        self.lexicon.deinit();
        allocator.free(self.lexicon_blob);
        allocator.free(self.emissions);
        self.mapping.close();
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

const Emission = struct {
    codepoint: u32,
    scores: [4]f64,
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
        for (word) |byte| node_index = try self.childOrAdd(node_index, byte);
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

const State = enum(usize) { B = 0, M = 1, E = 2, S = 3 };

var cache_mutex: std.atomic.Mutex = .unlocked;
var cached_model: ?*Model = null;

export fn nx_plugin_init(config_json: ?[*:0]const u8, out_plugin: *?*anyopaque) c_int {
    const config_z = config_json orelse return 1;
    const config = parseConfig(config_z) catch return 1;
    defer if (config.owned_artifact_path) |path| allocator.free(path);

    const model = acquireModel(std.mem.span(config.artifact_path)) catch return 1;
    errdefer releaseModel(model);

    const plugin = allocator.create(Plugin) catch return 1;
    plugin.* = .{ .model = model, .hmm_score = config.hmm_score };
    out_plugin.* = @ptrCast(plugin);
    return 0;
}

export fn nx_plugin_free(plugin_ptr: ?*anyopaque) void {
    const plugin: *Plugin = @ptrCast(@alignCast(plugin_ptr orelse return));
    releaseModel(plugin.model);
    allocator.destroy(plugin);
}

export fn nx_plugin_get_info(plugin_ptr: ?*anyopaque, out_info: ?*NxPluginInfo) c_int {
    _ = plugin_ptr;
    const info = out_info orelse return 1;
    info.* = .{
        .abi_version = abi_version,
        .name = "hmm_lattice_plugin",
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
    const text = in_data.text[0..in_data.text_len];
    provideLexiconCandidates(plugin.model, text, in_data.char_len, cb, user_data);
    provideHmmCandidates(plugin, text, cb, user_data) catch return 1;
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

fn acquireModel(path: []const u8) !*Model {
    if (!std.mem.endsWith(u8, path, ".nxhmm")) return error.BadArtifact;
    lockCache();
    defer cache_mutex.unlock();

    if (cached_model) |model| {
        if (!std.mem.eql(u8, model.path, path)) return error.BadArtifact;
        model.refs += 1;
        return model;
    }

    const model = try loadModel(path);
    cached_model = model;
    return model;
}

fn releaseModel(model: *Model) void {
    lockCache();
    defer cache_mutex.unlock();
    model.refs -= 1;
    if (model.refs == 0) {
        if (cached_model == model) cached_model = null;
        model.deinit();
    }
}

fn lockCache() void {
    // ponytail: spin lock is enough for plugin init/free; use a blocking mutex if this becomes hot.
    while (!cache_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn loadModel(path: []const u8) !*Model {
    const path_z = try allocator.dupeZ(u8, path);
    errdefer allocator.free(path_z);

    var mapping = try mapFileReadOnly(path_z.ptr);
    errdefer mapping.close();

    const data = mapping.data;
    if (data.len < header_len or !std.mem.eql(u8, data[0..8], artifact_magic)) return error.BadArtifact;
    var offset: usize = 8;
    const version = readU32(data, &offset) orelse return error.BadArtifact;
    if (version != 1) return error.BadArtifact;
    const emission_count = readU32(data, &offset) orelse return error.BadArtifact;
    const lexicon_count = readU32(data, &offset) orelse return error.BadArtifact;
    const raw_lexicon_len = readU32(data, &offset) orelse return error.BadArtifact;
    const compressed_lexicon_len = readU32(data, &offset) orelse return error.BadArtifact;
    _ = readU32(data, &offset) orelse return error.BadArtifact;
    const max_unknown_len = readU32(data, &offset) orelse return error.BadArtifact;
    _ = readF32(data, &offset) orelse return error.BadArtifact;
    _ = readF32(data, &offset) orelse return error.BadArtifact;

    var start: [4]f64 = undefined;
    for (&start) |*score| score.* = readF64(data, &offset) orelse return error.BadArtifact;

    var transition: [4][4]f64 = undefined;
    for (&transition) |*row| {
        for (row) |*score| score.* = readF64(data, &offset) orelse return error.BadArtifact;
    }

    var unknown: [4]f64 = undefined;
    for (&unknown) |*score| score.* = readF64(data, &offset) orelse return error.BadArtifact;

    const emissions = try allocator.alloc(Emission, emission_count);
    errdefer allocator.free(emissions);
    for (emissions) |*emission| {
        emission.codepoint = readU32(data, &offset) orelse return error.BadArtifact;
        for (&emission.scores) |*score| score.* = readF64(data, &offset) orelse return error.BadArtifact;
    }

    const compressed_end = offset + @as(usize, compressed_lexicon_len);
    if (compressed_end > data.len) return error.BadArtifact;
    const lexicon_blob = try decompressZlib(data[offset..compressed_end], raw_lexicon_len);
    errdefer allocator.free(lexicon_blob);

    var lexicon = LexiconTrie.init();
    errdefer lexicon.deinit();
    try buildLexiconTrie(&lexicon, lexicon_blob, lexicon_count);

    const model = try allocator.create(Model);
    model.* = .{
        .path = path_z,
        .mapping = mapping,
        .start = start,
        .transition = transition,
        .unknown = unknown,
        .emissions = emissions,
        .lexicon_blob = lexicon_blob,
        .lexicon = lexicon,
        .max_unknown_len = max_unknown_len,
    };
    return model;
}

fn mapFileReadOnly(path_z: [*:0]const u8) !MappedFile {
    if (builtin.os.tag == .windows) {
        const file = c.CreateFileA(path_z, c.GENERIC_READ, c.FILE_SHARE_READ, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
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
        return .{
            .data = @as([*]const u8, @ptrCast(view))[0..low],
            .file = file,
            .mapping = mapping,
        };
    } else {
        const fd = c.open(path_z, c.O_RDONLY);
        if (fd < 0) return error.OpenFailed;
        errdefer _ = c.close(fd);

        const end = c.lseek(fd, 0, c.SEEK_END);
        if (end <= 0) return error.OpenFailed;
        const end_u: u64 = @intCast(end);
        if (end_u > std.math.maxInt(usize)) return error.BadArtifact;
        const size: usize = @intCast(end_u);
        const view = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (view == c.MAP_FAILED) return error.OpenFailed;
        return .{
            .data = @as([*]const u8, @ptrCast(view))[0..size],
            .file = fd,
            .mapping = {},
        };
    }
}

fn decompressZlib(compressed: []const u8, expected_len: u32) ![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = .init(&input, .zlib, &buffer);
    _ = try dec.reader.streamRemaining(&output.writer);
    const raw = try output.toOwnedSlice();
    if (raw.len != expected_len) {
        allocator.free(raw);
        return error.BadArtifact;
    }
    return raw;
}

fn buildLexiconTrie(trie: *LexiconTrie, blob: []const u8, expected_count: u32) !void {
    var offset: usize = 0;
    var count: u32 = 0;
    while (offset < blob.len) : (count += 1) {
        const len = readU16(blob, &offset) orelse return error.BadArtifact;
        const end = offset + len;
        if (end > blob.len) return error.BadArtifact;
        try trie.insert(blob[offset..end]);
        offset = end;
    }
    if (count != expected_count) return error.BadArtifact;
}

fn provideLexiconCandidates(model: *Model, text: []const u8, char_len: u32, cb: NxPluginCandidateCallback, user_data: ?*anyopaque) void {
    if (model.lexicon.nodes.items.len == 0) return;
    var byte_start: usize = 0;
    var start_char: u32 = 0;
    while (byte_start < text.len) {
        const start_len = std.unicode.utf8ByteSequenceLength(text[byte_start]) catch return;
        if (byte_start + start_len > text.len) return;
        var node_index: usize = 0;
        var byte_end = byte_start;
        var end_char = start_char;
        scan: while (byte_end < text.len) {
            const codepoint_len = std.unicode.utf8ByteSequenceLength(text[byte_end]) catch break;
            const next_end = byte_end + codepoint_len;
            if (next_end > text.len) break;
            for (text[byte_end..next_end]) |byte| {
                node_index = model.lexicon.child(node_index, byte) orelse break :scan;
            }
            byte_end = next_end;
            end_char += 1;
            if (model.lexicon.nodes.items[node_index].terminal) {
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
        byte_start += start_len;
        start_char += 1;
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
        if (run_end - run_start >= 2) try decodeHmmRun(plugin, chars.items, run_start, run_end, cb, user_data);
        run_start = run_end + 1;
    }
}

fn decodeHmmRun(
    plugin: *Plugin,
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

    const first_emissions = emissionScores(plugin.model, chars[start].codepoint);
    inline for (.{ State.B, State.S }) |state| {
        scores[0][@intFromEnum(state)] = plugin.model.start[@intFromEnum(state)] + first_emissions.*[@intFromEnum(state)];
    }

    var i: usize = 1;
    while (i < n) : (i += 1) {
        const emissions = emissionScores(plugin.model, chars[start + i].codepoint);
        inline for (.{ State.B, State.M, State.E, State.S }) |state| {
            const emission = emissions.*[@intFromEnum(state)];
            inline for (.{ State.B, State.M, State.E, State.S }) |from| {
                const trans = plugin.model.transition[@intFromEnum(from)][@intFromEnum(state)];
                if (std.math.isFinite(trans)) {
                    const candidate = scores[i - 1][@intFromEnum(from)] + trans + emission;
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
            .E => try emitHmmCandidate(word_start, start + i + 1, plugin.hmm_score, cb, user_data),
            .S => word_start = start + i + 1,
            .M => {},
        }
    }
}

fn emitHmmCandidate(start: usize, end: usize, score: f32, cb: NxPluginCandidateCallback, user_data: ?*anyopaque) !void {
    if (end <= start + 1) return;
    var candidate = NxPluginCandidate{
        .start_char = @intCast(start),
        .end_char = @intCast(end),
        .score = score,
        .source = 0,
        .flags = 2,
    };
    cb(&candidate, user_data);
}

fn emissionScores(model: *Model, codepoint: u21) *const [4]f64 {
    var lo: usize = 0;
    var hi: usize = model.emissions.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const item = &model.emissions[mid];
        if (item.codepoint == codepoint) return &item.scores;
        if (item.codepoint < codepoint) lo = mid + 1 else hi = mid;
    }
    return &model.unknown;
}

fn numberValue(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        .number_string => |v| std.fmt.parseFloat(f64, v) catch null,
        else => null,
    };
}

fn readU16(data: []const u8, offset: *usize) ?u16 {
    if (offset.* + 2 > data.len) return null;
    const out = std.mem.readInt(u16, data[offset.*..][0..2], .little);
    offset.* += 2;
    return out;
}

fn readU32(data: []const u8, offset: *usize) ?u32 {
    if (offset.* + 4 > data.len) return null;
    const out = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    return out;
}

fn readF32(data: []const u8, offset: *usize) ?f32 {
    return @bitCast(readU32(data, offset) orelse return null);
}

fn readF64(data: []const u8, offset: *usize) ?f64 {
    if (offset.* + 8 > data.len) return null;
    const bits = std.mem.readInt(u64, data[offset.*..][0..8], .little);
    offset.* += 8;
    return @bitCast(bits);
}

fn isHan(cp: u21) bool {
    return (cp >= 0x3400 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0x20000 and cp <= 0x2A6DF);
}
