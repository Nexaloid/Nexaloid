const std = @import("std");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("windows.h");
}) else @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
});
const tokenizer_mod = @import("tokenizer.zig");
const rule_matcher = @import("matcher/rule_matcher.zig");
const plugin_mod = @import("plugin/loader.zig");
const scanner = @import("scanner/utf8.zig");
const types = @import("types.zig");
const trie_mod = @import("lexicon/trie.zig");

const allocator = std.heap.c_allocator;
const dict_magic_v4 = "NXDICT1\x00";
const runtime_version = "0.0.0-dev.0";

const NxStatus = enum(c_int) {
    ok = 0,
    invalid_utf8 = 1,
    out_of_memory = 2,
    invalid_config = 3,
    io = 4,
    plugin = 5,
    internal = 255,
};

const NxMode = enum(c_int) {
    accurate = 0,
    full = 1,
    search = 2,
    recall_search = 3,
};

const NxConfig = extern struct {
    dict_path: ?[*:0]const u8,
    user_dict_path: ?[*:0]const u8,
    enable_hmm: u32,
    enable_normalization: u32,
    enable_plugins: u32,
    preserve_whitespace: u32,
    reserved: [7]u32,
};

const NxToken = extern struct {
    start_byte: u32,
    end_byte: u32,
    start_char: u32,
    end_char: u32,
    word_id: u32,
    pos_id: u16,
    source: u16,
    flags: u16,
    score: f32,
};

const NxTokenCallback = *const fn (*const NxToken, [*]const u8, usize, ?*anyopaque) callconv(.c) void;
const NxBatchTokenCallback = *const fn (u32, *const NxToken, [*]const u8, usize, ?*anyopaque) callconv(.c) void;
const max_segment_chars = 512;
const max_batch_workers = 64;
const max_rules_json_bytes = 1024 * 1024;
const max_dict_file_bytes = 512 * 1024 * 1024;
const max_dict_line_bytes = 1024 * 1024;
const max_dict_word_bytes = std.math.maxInt(u16);
const max_dict_codepoints = 0x110000;
const max_dict_states = 16 * 1024 * 1024;
const max_dict_entries = 4 * 1024 * 1024;

pub const NxEngine = struct {
    allocator: std.mem.Allocator,
    tokenizer: tokenizer_mod.Tokenizer,
    dict_mapping: ?MappedFile = null,
    plugins: std.ArrayListUnmanaged(plugin_mod.LoadedPlugin) = .empty,
    // Runtime-added words get stable non-zero ids inside this engine instance.
    next_word_id: u32 = 1,
};

export fn nx_runtime_version() callconv(.c) [*:0]const u8 {
    return runtime_version;
}

export fn nx_engine_new(config: ?*const NxConfig, out_engine: ?*?*NxEngine) callconv(.c) NxStatus {
    const out = out_engine orelse return .invalid_config;
    out.* = null;
    out.* = createEngine(allocator, config) catch |err| return statusFromError(err);
    return .ok;
}

export fn nx_engine_free(engine: ?*NxEngine) callconv(.c) void {
    if (engine) |ptr| destroyEngine(ptr);
}

fn createEngine(engine_allocator: std.mem.Allocator, config: ?*const NxConfig) !*NxEngine {
    const engine = try engine_allocator.create(NxEngine);
    const tokenizer = tokenizer_mod.Tokenizer.init(engine_allocator) catch |err| {
        engine_allocator.destroy(engine);
        return err;
    };

    engine.* = .{
        .allocator = engine_allocator,
        .tokenizer = tokenizer,
    };
    errdefer destroyEngine(engine);

    if (config) |cfg| {
        engine.tokenizer.preserve_whitespace = cfg.preserve_whitespace != 0;
        if (cfg.dict_path) |path| try loadDictFile(engine, path, .base);
        if (cfg.user_dict_path) |path| try loadDictFile(engine, path, .user);
    }
    return engine;
}

fn destroyEngine(engine: *NxEngine) void {
    const engine_allocator = engine.allocator;
    for (engine.plugins.items) |*plugin| plugin.close();
    engine.plugins.deinit(engine_allocator);
    engine.tokenizer.deinit();
    if (engine.dict_mapping) |mapping| mapping.close();
    engine_allocator.destroy(engine);
}

export fn nx_load_plugin(
    engine: ?*NxEngine,
    plugin_path: ?[*:0]const u8,
    config_json: ?[*:0]const u8,
) callconv(.c) NxStatus {
    const ptr = engine orelse return .invalid_config;
    const path = plugin_path orelse return .invalid_config;
    const plugin = plugin_mod.load(ptr.allocator, path, config_json) catch return .plugin;
    ptr.plugins.append(ptr.allocator, plugin) catch |err| {
        var owned = plugin;
        owned.close();
        return statusFromError(err);
    };
    return .ok;
}

export fn nx_set_rule_config(
    engine: ?*NxEngine,
    enabled_mask: u32,
    scores: ?[*]const f32,
    score_count: usize,
) callconv(.c) NxStatus {
    const ptr = engine orelse return .invalid_config;
    var config = rule_matcher.RuleConfig{
        .enabled_mask = enabled_mask & rule_matcher.all_rules_mask,
    };
    if (scores) |items| {
        const count = @min(score_count, rule_matcher.rule_count);
        for (0..count) |i| {
            if (!std.math.isFinite(items[i])) return .invalid_config;
            config.scores[i] = items[i];
        }
    }
    ptr.tokenizer.rule_config = config;
    return .ok;
}

export fn nx_load_rules_json(
    engine: ?*NxEngine,
    json: ?[*]const u8,
    json_len: usize,
) callconv(.c) NxStatus {
    const ptr = engine orelse return .invalid_config;
    if (json_len > max_rules_json_bytes) return .invalid_config;
    const bytes = (json orelse return .invalid_config)[0..json_len];
    ptr.tokenizer.loadRulesJson(bytes) catch |err| return statusFromError(err);
    return .ok;
}

export fn nx_clear_rules(engine: ?*NxEngine) callconv(.c) NxStatus {
    const ptr = engine orelse return .invalid_config;
    ptr.tokenizer.clearRules();
    return .ok;
}

export fn nx_tokenize(
    engine: ?*NxEngine,
    text: ?[*]const u8,
    text_len: usize,
    mode: c_int,
    callback: ?NxTokenCallback,
    user_data: ?*anyopaque,
) callconv(.c) NxStatus {
    const ptr = engine orelse return .invalid_config;
    if (!abiLengthValid(text_len)) return .invalid_config;
    const bytes = (text orelse return .invalid_config)[0..text_len];
    const cb = callback orelse return .invalid_config;

    const checked_mode = modeFromAbi(mode) orelse return .invalid_config;
    return tokenizeSegmented(ptr, bytes, checked_mode, cb, user_data);
}

export fn nx_tokenize_batch(
    engine: ?*NxEngine,
    texts: ?[*]const ?[*]const u8,
    text_lens: ?[*]const usize,
    text_count: usize,
    mode: c_int,
    thread_count: u32,
    callback: ?NxBatchTokenCallback,
    user_data: ?*anyopaque,
) callconv(.c) NxStatus {
    const ptr = engine orelse return .invalid_config;
    const text_ptrs = texts orelse return .invalid_config;
    const lens = text_lens orelse return .invalid_config;
    const cb = callback orelse return .invalid_config;

    if (text_count == 0) return .ok;
    if (!abiLengthValid(text_count)) return .invalid_config;
    for (0..text_count) |i| {
        if (text_ptrs[i] == null or !abiLengthValid(lens[i])) return .invalid_config;
    }
    const checked_mode = modeFromAbi(mode) orelse return .invalid_config;

    // Workers fill per-input result slots; callbacks are emitted later in input order.
    const results = ptr.allocator.alloc(BatchResult, text_count) catch return .out_of_memory;
    defer {
        for (results) |*result| result.tokens.deinit(ptr.allocator);
        ptr.allocator.free(results);
    }
    for (results) |*result| result.* = .{};

    // ponytail: plugin batch calls are serialized until plugin thread-safety is part of the ABI.
    const workers = if (ptr.plugins.items.len == 0) workerCount(thread_count, text_count) else 1;
    if (workers == 1) {
        batchWorker(ptr, text_ptrs, lens, results, 0, text_count, checked_mode);
    } else {
        var threads = ptr.allocator.alloc(std.Thread, workers) catch return .out_of_memory;
        defer ptr.allocator.free(threads);

        var spawned: usize = 0;
        var joined: usize = 0;
        defer for (threads[joined..spawned]) |thread| thread.join();

        while (spawned < workers) : (spawned += 1) {
            const start = text_count * spawned / workers;
            const end = text_count * (spawned + 1) / workers;
            threads[spawned] = spawnBatchWorker(.{
                .engine = ptr,
                .texts = text_ptrs,
                .lens = lens,
                .results = results,
                .start = start,
                .end = end,
                .mode = checked_mode,
            }) catch return .internal;
        }
        for (threads[0..spawned]) |thread| {
            thread.join();
            joined += 1;
        }
    }

    for (results, 0..) |*result, i| {
        if (result.status != .ok) return result.status;
        const text = text_ptrs[i] orelse return .invalid_config;
        const bytes = text[0..lens[i]];
        for (result.tokens.items) |token| {
            cb(@intCast(i), &token, bytes.ptr, bytes.len, user_data);
        }
    }
    return .ok;
}

export fn nx_reload_user_dict(engine: ?*NxEngine, user_dict_path: ?[*:0]const u8) callconv(.c) NxStatus {
    const ptr = engine orelse return .invalid_config;
    const path = user_dict_path orelse return .invalid_config;
    loadDictFile(ptr, path, .user) catch |err| return statusFromError(err);
    return .ok;
}

export fn nx_add_word(
    engine: ?*NxEngine,
    word: ?[*]const u8,
    word_len: usize,
    word_id: u32,
    score: f32,
    pos_id: u16,
) callconv(.c) NxStatus {
    const ptr = engine orelse return .invalid_config;
    if (word_len > max_dict_word_bytes or !std.math.isFinite(score)) return .invalid_config;
    const bytes = (word orelse return .invalid_config)[0..word_len];
    validateDictionaryWord(bytes, score) catch |err| return statusFromError(err);
    const id = if (word_id == 0) nextWordId(&ptr.next_word_id) catch return .invalid_config else word_id;
    ptr.tokenizer.addWord(bytes, id, score, pos_id) catch |err| return statusFromError(err);
    return .ok;
}

export fn nx_status_message(status: NxStatus) callconv(.c) [*:0]const u8 {
    return switch (status) {
        .ok => "ok",
        .invalid_utf8 => "invalid utf-8",
        .out_of_memory => "out of memory",
        .invalid_config => "invalid config",
        .io => "io error",
        .plugin => "plugin error",
        .internal => "internal error",
    };
}

fn nextWordId(next_id: *u32) !u32 {
    if (next_id.* == 0 or next_id.* == std.math.maxInt(u32)) return error.InputTooLarge;
    const id = next_id.*;
    next_id.* += 1;
    return id;
}

fn statusFromError(err: anyerror) NxStatus {
    return switch (err) {
        error.InvalidUtf8 => .invalid_utf8,
        error.OutOfMemory => .out_of_memory,
        error.InvalidRules,
        error.InvalidDictionary,
        error.InputTooLarge,
        error.RuleMatchBudgetExceeded,
        => .invalid_config,
        error.Io,
        error.FileNotFound,
        error.AccessDenied,
        => .io,
        error.Plugin,
        error.PluginOpenFailed,
        error.PluginSymbolMissing,
        error.PluginInitFailed,
        error.PluginInfoFailed,
        error.PluginAbiMismatch,
        error.PluginKindMismatch,
        error.PluginProvideFailed,
        error.PluginCandidateInvalid,
        error.PluginInputTooLarge,
        => .plugin,
        else => .internal,
    };
}

fn tokenizeSegmented(
    engine: *NxEngine,
    bytes: []const u8,
    mode: tokenizer_mod.Mode,
    cb: NxTokenCallback,
    user_data: ?*anyopaque,
) NxStatus {
    var iter = SegmentIter.init(bytes);
    while (iter.next() catch |err| return statusFromError(err)) |segment| {
        var edges = tokenizeWithPlugins(engine, segment.bytes, mode) catch |err| return statusFromError(err);
        defer edges.deinit(engine.allocator);
        for (edges.items) |edge| {
            const token = toAbiToken(edge, segment.start_byte, segment.start_char);
            cb(&token, bytes.ptr, bytes.len, user_data);
        }
    }
    return .ok;
}

fn collectSegmentedTokens(
    engine: *NxEngine,
    bytes: []const u8,
    mode: tokenizer_mod.Mode,
    out: *std.ArrayListUnmanaged(NxToken),
) NxStatus {
    var iter = SegmentIter.init(bytes);
    while (iter.next() catch |err| return statusFromError(err)) |segment| {
        var edges = tokenizeWithPlugins(engine, segment.bytes, mode) catch |err| return statusFromError(err);
        defer edges.deinit(engine.allocator);
        for (edges.items) |edge| {
            out.append(engine.allocator, toAbiToken(edge, segment.start_byte, segment.start_char)) catch return .out_of_memory;
        }
    }
    return .ok;
}

fn toAbiToken(edge: types.NxEdge, byte_base: u32, char_base: u32) NxToken {
    return .{
        .start_byte = byte_base + edge.start_byte,
        .end_byte = byte_base + edge.end_byte,
        .start_char = char_base + edge.start_char,
        .end_char = char_base + edge.end_char,
        .word_id = edge.word_id,
        .pos_id = edge.pos_id,
        .source = @intFromEnum(edge.source),
        .flags = edge.flags,
        .score = edge.score,
    };
}

fn tokenizeWithPlugins(engine: *NxEngine, bytes: []const u8, mode: tokenizer_mod.Mode) !std.ArrayListUnmanaged(types.NxEdge) {
    if (engine.plugins.items.len == 0) return engine.tokenizer.tokenizeMode(bytes, mode);
    return engine.tokenizer.tokenizeModeWithCandidates(bytes, mode, engine, struct {
        fn add(
            ptr: *NxEngine,
            alloc: std.mem.Allocator,
            text: []const u8,
            chars: []const types.NxChar,
            lattice: *@import("lattice/lattice.zig").Lattice,
        ) !void {
            for (ptr.plugins.items) |*plugin| {
                try plugin.addCandidates(alloc, text, chars, lattice);
            }
        }
    }.add);
}

const Segment = struct {
    bytes: []const u8,
    start_byte: u32,
    start_char: u32,
};

const SegmentIter = struct {
    bytes: []const u8,
    byte_pos: usize = 0,
    char_pos: u32 = 0,

    fn init(bytes: []const u8) SegmentIter {
        return .{ .bytes = bytes };
    }

    fn next(self: *SegmentIter) scanner.ScanError!?Segment {
        while (self.byte_pos < self.bytes.len) {
            const start_byte = self.byte_pos;
            const start_char = self.char_pos;
            var i = start_byte;
            var chars: u32 = 0;
            while (i < self.bytes.len) {
                const cp, _ = try scanner.nextCodepoint(self.bytes, &i);
                chars += 1;
                if (isSegmentBoundary(cp) or chars >= max_segment_chars) break;
            }
            self.byte_pos = i;
            self.char_pos += chars;
            if (i > start_byte) {
                return .{
                    .bytes = self.bytes[start_byte..i],
                    .start_byte = @intCast(start_byte),
                    .start_char = start_char,
                };
            }
        }
        return null;
    }
};

fn abiLengthValid(length: usize) bool {
    return length <= std.math.maxInt(u32);
}

fn isSegmentBoundary(cp: u32) bool {
    return switch (cp) {
        '\n', '\r', '!', ';', 0x3002, 0xFF01, 0xFF1F, 0xFF1B => true,
        else => false,
    };
}

const DictTarget = enum { base, user };

fn loadDictFile(engine: *NxEngine, path: [*:0]const u8, target: DictTarget) !void {
    if (target == .base and builtin.os.tag == .windows and engine.tokenizer.isDictEmpty()) {
        if (try loadMappedDat(engine, path)) return;
    }
    if (try isBinaryDict(path)) return loadBinaryDictFile(engine, path, target);
    return loadTextDictFile(engine, path, target);
}

const MappedFile = struct {
    data: []const u8,
    file: if (builtin.os.tag == .windows) c.HANDLE else void,
    mapping: if (builtin.os.tag == .windows) c.HANDLE else void,

    fn close(self: MappedFile) void {
        if (builtin.os.tag == .windows) {
            _ = c.UnmapViewOfFile(self.data.ptr);
            _ = c.CloseHandle(self.mapping);
            _ = c.CloseHandle(self.file);
        }
    }
};

fn mapFileReadOnly(path: [*:0]const u8) !MappedFile {
    if (builtin.os.tag != .windows) return error.Io;
    const file = c.CreateFileA(path, c.GENERIC_READ, c.FILE_SHARE_READ, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) return error.Io;
    errdefer _ = c.CloseHandle(file);

    var high: c.DWORD = 0;
    const low = c.GetFileSize(file, &high);
    if (low == c.INVALID_FILE_SIZE and c.GetLastError() != c.NO_ERROR) return error.Io;
    if (high != 0 or low > max_dict_file_bytes) return error.InputTooLarge;

    const mapping = c.CreateFileMappingA(file, null, c.PAGE_READONLY, 0, 0, null);
    if (mapping == null) return error.Io;
    errdefer _ = c.CloseHandle(mapping);

    const view = c.MapViewOfFile(mapping, c.FILE_MAP_READ, 0, 0, 0) orelse return error.Io;
    return .{
        .data = @as([*]const u8, @ptrCast(view))[0..low],
        .file = file,
        .mapping = mapping,
    };
}

fn loadMappedDat(engine: *NxEngine, path: [*:0]const u8) !bool {
    var mapping = try mapFileReadOnly(path);
    errdefer mapping.close();
    const data = mapping.data;
    if (data.len < dict_magic_v4.len + 12 or !std.mem.eql(u8, data[0..dict_magic_v4.len], dict_magic_v4)) return false;

    const layout = try parseBinaryDict(data);
    engine.tokenizer.loadDatDictBorrowed(layout.nodes, layout.codepoints, layout.base, layout.check);
    engine.next_word_id = layout.max_word_id + 1;
    engine.dict_mapping = mapping;
    return true;
}

fn sliceAs(comptime T: type, data: []const u8, offset: *usize, count: u32) ![]const T {
    const byte_len = std.math.mul(usize, @as(usize, count), @sizeOf(T)) catch return error.InvalidDictionary;
    const end = std.math.add(usize, offset.*, byte_len) catch return error.InvalidDictionary;
    if (end > data.len) return error.InvalidDictionary;
    const aligned: []align(@alignOf(T)) const u8 = @alignCast(data[offset.*..end]);
    const out = std.mem.bytesAsSlice(T, aligned);
    offset.* = end;
    return out;
}

fn isBinaryDict(path: [*:0]const u8) !bool {
    const file = c.fopen(path, "rb") orelse return error.Io;
    defer _ = c.fclose(file);
    var header: [dict_magic_v4.len]u8 = undefined;
    const n = c.fread(&header, 1, header.len, file);
    return n == header.len and std.mem.eql(u8, &header, dict_magic_v4);
}

fn loadTextDictFile(engine: *NxEngine, path: [*:0]const u8, target: DictTarget) !void {
    const data = try readFileAlloc(engine.allocator, path);
    defer engine.allocator.free(data);
    try loadTextDict(engine, data, target);
}

fn loadTextDict(engine: *NxEngine, data: []const u8, target: DictTarget) !void {
    var staged_user: ?trie_mod.TempTrie = if (target == .user) try engine.tokenizer.cloneUserTrie() else null;
    defer if (staged_user) |*trie| trie.deinit();
    var next_id = engine.next_word_id;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len > max_dict_line_bytes) return error.InputTooLarge;
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const word_end = std.mem.indexOfAny(u8, line, "\t ") orelse line.len;
        const word = line[0..word_end];
        line = std.mem.trim(u8, line[word_end..], " \t");
        const score_end = std.mem.indexOfAny(u8, line, "\t ") orelse line.len;
        const score = if (score_end == 0) 1.0 else std.fmt.parseFloat(f32, line[0..score_end]) catch 1.0;
        try validateDictionaryWord(word, score);
        const word_id = try nextWordId(&next_id);
        if (target == .base) {
            try engine.tokenizer.addBaseWord(word, word_id, score, 0);
        } else {
            try staged_user.?.insert(word, word_id, score, 0);
        }
    }

    if (staged_user) |*trie| engine.tokenizer.swapUserTrie(trie);
    engine.next_word_id = next_id;
}

fn loadBinaryDictFile(engine: *NxEngine, path: [*:0]const u8, target: DictTarget) !void {
    const data = try readFileAlloc(engine.allocator, path);
    defer engine.allocator.free(data);
    try loadBinaryDict(engine, data, target);
}

fn loadBinaryDict(engine: *NxEngine, data: []const u8, target: DictTarget) !void {
    const layout = try parseBinaryDict(data);

    if (target == .base and engine.tokenizer.isDictEmpty()) {
        try engine.tokenizer.loadDatDict(layout.nodes, layout.codepoints, layout.base, layout.check);
        engine.next_word_id = layout.max_word_id + 1;
        return;
    }

    var staged_user = try engine.tokenizer.cloneUserTrie();
    defer staged_user.deinit();
    var next_id = engine.next_word_id;
    var apply_ctx = BinaryEntryApplyContext{ .trie = &staged_user, .next_id = &next_id };
    _ = try walkBinaryEntries(data, layout.entries_offset, layout.entry_count, &apply_ctx, applyBinaryEntry);
    engine.tokenizer.swapUserTrie(&staged_user);
    engine.next_word_id = next_id;
}

const BinaryDictLayout = struct {
    codepoints: []const u32,
    base: []const u32,
    check: []const u32,
    nodes: []const tokenizer_mod.Tokenizer.DatNode,
    entries_offset: usize,
    entry_count: u32,
    max_word_id: u32,
};

const BinaryEntryApplyContext = struct {
    trie: *trie_mod.TempTrie,
    next_id: *u32,
};

fn applyBinaryEntry(ctx: *BinaryEntryApplyContext, word: []const u8, score: f32, pos_id: u16) !void {
    try ctx.trie.insert(word, try nextWordId(ctx.next_id), score, pos_id);
}

fn parseBinaryDict(data: []const u8) !BinaryDictLayout {
    if (data.len > max_dict_file_bytes or data.len < dict_magic_v4.len + 12) return error.InvalidDictionary;
    if (!std.mem.eql(u8, data[0..dict_magic_v4.len], dict_magic_v4)) return error.InvalidDictionary;

    var offset: usize = dict_magic_v4.len;
    const code_count = readU32(data, &offset) orelse return error.InvalidDictionary;
    const state_count = readU32(data, &offset) orelse return error.InvalidDictionary;
    const entry_count = readU32(data, &offset) orelse return error.InvalidDictionary;
    if (code_count > max_dict_codepoints or state_count == 0 or state_count > max_dict_states or entry_count > max_dict_entries) {
        return error.InputTooLarge;
    }

    const codepoints = try sliceAs(u32, data, &offset, code_count);
    const base = try sliceAs(u32, data, &offset, state_count);
    const check = try sliceAs(u32, data, &offset, state_count);
    const nodes = try sliceAs(tokenizer_mod.Tokenizer.DatNode, data, &offset, state_count);
    const max_word_id = try validateDat(codepoints, base, check, nodes, entry_count);
    const end = try walkBinaryEntries(data, offset, entry_count, {}, struct {
        fn validate(_: void, _: []const u8, _: f32, _: u16) !void {}
    }.validate);
    if (end != data.len) return error.InvalidDictionary;

    return .{
        .codepoints = codepoints,
        .base = base,
        .check = check,
        .nodes = nodes,
        .entries_offset = offset,
        .entry_count = entry_count,
        .max_word_id = max_word_id,
    };
}

fn validateDat(codepoints: []const u32, base: []const u32, check: []const u32, nodes: []const tokenizer_mod.Tokenizer.DatNode, entry_count: u32) !u32 {
    var previous: ?u32 = null;
    for (codepoints) |codepoint| {
        if (!validUnicodeScalar(codepoint) or (previous != null and codepoint <= previous.?)) return error.InvalidDictionary;
        previous = codepoint;
    }

    const code_count: u32 = @intCast(codepoints.len);
    const max_base = std.math.maxInt(u32) - code_count;
    for (base) |item| if (item > max_base) return error.InvalidDictionary;
    for (check, 0..) |parent_marker, child_index| {
        if (parent_marker == 0) continue;
        const parent = parent_marker - 1;
        if (parent >= base.len) return error.InvalidDictionary;
        const parent_base = base[parent];
        if (child_index <= parent_base) return error.InvalidDictionary;
        const code_id = child_index - parent_base;
        if (code_id == 0 or code_id > codepoints.len) return error.InvalidDictionary;
    }

    var max_word_id: u32 = 0;
    for (nodes) |node| {
        if (!std.math.isFinite(node.score) or node.word_id > entry_count) return error.InvalidDictionary;
        max_word_id = @max(max_word_id, node.word_id);
    }
    if (max_word_id == std.math.maxInt(u32)) return error.InputTooLarge;
    return max_word_id;
}

fn walkBinaryEntries(data: []const u8, start: usize, entry_count: u32, ctx: anytype, comptime visit: anytype) !usize {
    var offset = start;
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const word_len = readU16(data, &offset) orelse return error.InvalidDictionary;
        const pos_id = readU16(data, &offset) orelse return error.InvalidDictionary;
        const score_bits = readU32(data, &offset) orelse return error.InvalidDictionary;
        const score: f32 = @bitCast(score_bits);
        const end = std.math.add(usize, offset, word_len) catch return error.InvalidDictionary;
        if (end > data.len) return error.InvalidDictionary;
        const word = data[offset..end];
        try validateDictionaryWord(word, score);
        try visit(ctx, word, score, pos_id);
        offset = end;
    }
    return offset;
}

fn readFileAlloc(file_allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const file = c.fopen(path, "rb") orelse return error.Io;
    defer _ = c.fclose(file);
    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.Io;
    const raw_size = c.ftell(file);
    if (raw_size < 0) return error.Io;
    const size = std.math.cast(usize, raw_size) orelse return error.InputTooLarge;
    if (size > max_dict_file_bytes) return error.InputTooLarge;
    if (c.fseek(file, 0, c.SEEK_SET) != 0) return error.Io;

    const data = try file_allocator.alloc(u8, size);
    errdefer file_allocator.free(data);
    if (data.len != 0 and c.fread(data.ptr, 1, data.len, file) != data.len) return error.Io;
    return data;
}

fn validateDictionaryWord(word: []const u8, score: f32) !void {
    if (word.len == 0 or word.len > max_dict_word_bytes or !std.math.isFinite(score)) return error.InvalidDictionary;
    if (!std.unicode.utf8ValidateSlice(word)) return error.InvalidUtf8;
}

fn validUnicodeScalar(codepoint: u32) bool {
    return codepoint <= 0x10FFFF and !(codepoint >= 0xD800 and codepoint <= 0xDFFF);
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

const BatchResult = struct {
    status: NxStatus = .ok,
    tokens: std.ArrayListUnmanaged(NxToken) = .empty,
};

fn workerCount(requested: u32, text_count: usize) usize {
    if (text_count < 2) return 1;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const wanted = if (requested == 0) cpu_count else @as(usize, requested);
    return @max(1, @min(wanted, text_count, max_batch_workers));
}

const BatchWorkerArgs = struct {
    engine: *NxEngine,
    texts: [*]const ?[*]const u8,
    lens: [*]const usize,
    results: []BatchResult,
    start: usize,
    end: usize,
    mode: tokenizer_mod.Mode,
};

var test_spawn_fail_after: ?usize = null;
var test_spawn_count: usize = 0;

fn spawnBatchWorker(args: BatchWorkerArgs) !std.Thread {
    if (builtin.is_test) {
        if (test_spawn_fail_after) |limit| {
            if (test_spawn_count >= limit) return error.TestSpawnFailure;
            test_spawn_count += 1;
        }
    }
    return std.Thread.spawn(.{}, batchWorker, .{
        args.engine,
        args.texts,
        args.lens,
        args.results,
        args.start,
        args.end,
        args.mode,
    });
}

fn batchWorker(
    engine: *NxEngine,
    texts: [*]const ?[*]const u8,
    lens: [*]const usize,
    results: []BatchResult,
    start: usize,
    end: usize,
    mode: tokenizer_mod.Mode,
) void {
    var i = start;
    while (i < end) : (i += 1) {
        const text = texts[i] orelse {
            results[i].status = .invalid_config;
            continue;
        };
        const bytes = text[0..lens[i]];
        results[i].status = collectSegmentedTokens(engine, bytes, mode, &results[i].tokens);
    }
}

fn modeFromAbi(mode: c_int) ?tokenizer_mod.Mode {
    return switch (mode) {
        @intFromEnum(NxMode.accurate) => .accurate,
        @intFromEnum(NxMode.full) => .full,
        @intFromEnum(NxMode.search) => .search,
        @intFromEnum(NxMode.recall_search) => .recall_search,
        else => null,
    };
}

test "engine construction releases allocations after dictionary failure" {
    const missing: [:0]const u8 = "nexaloid-test-missing-dictionary";
    var config = std.mem.zeroes(NxConfig);
    config.dict_path = missing.ptr;
    try std.testing.expectError(error.Io, createEngine(std.testing.allocator, &config));
}

test "batch joins started workers when a later spawn fails" {
    const engine = try createEngine(std.testing.allocator, null);
    defer destroyEngine(engine);

    const first: []const u8 = "first";
    const second: []const u8 = "second";
    const texts = [_]?[*]const u8{ first.ptr, second.ptr };
    const lengths = [_]usize{ first.len, second.len };

    test_spawn_count = 0;
    test_spawn_fail_after = 1;
    defer {
        test_spawn_fail_after = null;
        test_spawn_count = 0;
    }

    const status = nx_tokenize_batch(engine, &texts, &lengths, texts.len, @intFromEnum(NxMode.accurate), 2, struct {
        fn callback(_: u32, _: *const NxToken, _: [*]const u8, _: usize, _: ?*anyopaque) callconv(.c) void {}
    }.callback, null);
    try std.testing.expectEqual(NxStatus.internal, status);
}

test "ABI lengths are limited to u32 offsets" {
    try std.testing.expect(abiLengthValid(std.math.maxInt(u32)));
    if (@sizeOf(usize) > @sizeOf(u32)) {
        try std.testing.expect(!abiLengthValid(@as(usize, std.math.maxInt(u32)) + 1));
    }
}

test "text dictionary failure does not partially update user trie" {
    const engine = try createEngine(std.testing.allocator, null);
    defer destroyEngine(engine);
    try engine.tokenizer.addWord("keep", 1, 10.0, 0);
    engine.next_word_id = 2;

    try std.testing.expectError(error.InvalidDictionary, loadTextDict(engine, "new 2\nbroken nan\n", .user));
    try std.testing.expect(try tokenizationHasSource(engine, "keep", .user_dict));
    try std.testing.expect(!try tokenizationHasSource(engine, "new", .user_dict));
    try std.testing.expectEqual(@as(u32, 2), engine.next_word_id);
}

test "text dictionary rejects overlong lines" {
    const engine = try createEngine(std.testing.allocator, null);
    defer destroyEngine(engine);
    const line = try std.testing.allocator.alloc(u8, max_dict_line_bytes + 1);
    defer std.testing.allocator.free(line);
    @memset(line, 'a');
    try std.testing.expectError(error.InputTooLarge, loadTextDict(engine, line, .user));
}

test "dictionary words reject empty and non-finite scores" {
    try std.testing.expectError(error.InvalidDictionary, validateDictionaryWord("", 1.0));
    const nan_score: f32 = @bitCast(@as(u32, 0x7fc00000));
    try std.testing.expectError(error.InvalidDictionary, validateDictionaryWord("word", nan_score));
}

test "binary dictionary rejects excessive counts before slicing" {
    var data = [_]u8{0} ** (dict_magic_v4.len + 12);
    @memcpy(data[0..dict_magic_v4.len], dict_magic_v4);
    std.mem.writeInt(u32, data[8..12], 0, .little);
    std.mem.writeInt(u32, data[12..16], max_dict_states + 1, .little);
    std.mem.writeInt(u32, data[16..20], 0, .little);
    try std.testing.expectError(error.InputTooLarge, parseBinaryDict(&data));
}

fn tokenizationHasSource(engine: *NxEngine, text: []const u8, source: types.NxSource) !bool {
    var edges = try engine.tokenizer.tokenize(text);
    defer edges.deinit(engine.allocator);
    for (edges.items) |edge| if (edge.source == source) return true;
    return false;
}
