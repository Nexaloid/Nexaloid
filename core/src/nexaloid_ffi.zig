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
const scanner = @import("scanner/utf8.zig");
const types = @import("types.zig");

const allocator = std.heap.c_allocator;
const dict_magic_v4 = "NXDICT1\x00";

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
};

const NxConfig = extern struct {
    dict_path: ?[*:0]const u8,
    user_dict_path: ?[*:0]const u8,
    enable_hmm: u32,
    enable_normalization: u32,
    enable_plugins: u32,
    reserved: [8]u32,
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

pub const NxEngine = struct {
    tokenizer: tokenizer_mod.Tokenizer,
    dict_mapping: ?MappedFile = null,
    // Runtime-added words get stable non-zero ids inside this engine instance.
    next_word_id: u32 = 1,
};

export fn nx_engine_new(config: ?*const NxConfig, out_engine: ?*?*NxEngine) callconv(.c) NxStatus {
    const out = out_engine orelse return .invalid_config;
    out.* = null;

    const engine = allocator.create(NxEngine) catch return .out_of_memory;
    engine.* = .{ .tokenizer = tokenizer_mod.Tokenizer.init(allocator) catch {
        allocator.destroy(engine);
        return .out_of_memory;
    } };
    errdefer {
        engine.tokenizer.deinit();
        allocator.destroy(engine);
    }

    if (config) |cfg| {
        if (cfg.dict_path) |path| loadDictFile(engine, path, .base) catch return .io;
        if (cfg.user_dict_path) |path| loadDictFile(engine, path, .user) catch return .io;
    }

    out.* = engine;
    return .ok;
}

export fn nx_engine_free(engine: ?*NxEngine) callconv(.c) void {
    if (engine) |ptr| {
        ptr.tokenizer.deinit();
        if (ptr.dict_mapping) |mapping| mapping.close();
        allocator.destroy(ptr);
    }
}

export fn nx_tokenize(
    engine: ?*NxEngine,
    text: ?[*]const u8,
    text_len: usize,
    mode: NxMode,
    callback: ?NxTokenCallback,
    user_data: ?*anyopaque,
) callconv(.c) NxStatus {
    const ptr = engine orelse return .invalid_config;
    const bytes = (text orelse return .invalid_config)[0..text_len];
    const cb = callback orelse return .invalid_config;

    return tokenizeSegmented(ptr, bytes, modeFromAbi(mode), cb, user_data);
}

export fn nx_tokenize_batch(
    engine: ?*NxEngine,
    texts: ?[*]const ?[*]const u8,
    text_lens: ?[*]const usize,
    text_count: usize,
    mode: NxMode,
    thread_count: u32,
    callback: ?NxBatchTokenCallback,
    user_data: ?*anyopaque,
) callconv(.c) NxStatus {
    const ptr = engine orelse return .invalid_config;
    const text_ptrs = texts orelse return .invalid_config;
    const lens = text_lens orelse return .invalid_config;
    const cb = callback orelse return .invalid_config;

    if (text_count == 0) return .ok;

    // Workers fill per-input result slots; callbacks are emitted later in input order.
    const results = allocator.alloc(BatchResult, text_count) catch return .out_of_memory;
    defer {
        for (results) |*result| result.tokens.deinit(allocator);
        allocator.free(results);
    }
    for (results) |*result| result.* = .{};

    const workers = workerCount(thread_count, text_count);
    if (workers == 1) {
        batchWorker(ptr, text_ptrs, lens, results, 0, text_count, modeFromAbi(mode));
    } else {
        var threads = allocator.alloc(std.Thread, workers) catch return .out_of_memory;
        defer allocator.free(threads);

        var worker_index: usize = 0;
        while (worker_index < workers) : (worker_index += 1) {
            const start = text_count * worker_index / workers;
            const end = text_count * (worker_index + 1) / workers;
            threads[worker_index] = std.Thread.spawn(.{}, batchWorker, .{ ptr, text_ptrs, lens, results, start, end, modeFromAbi(mode) }) catch return .internal;
        }
        for (threads) |thread| thread.join();
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
    loadDictFile(ptr, path, .user) catch return .io;
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
    const bytes = (word orelse return .invalid_config)[0..word_len];
    const id = if (word_id == 0) allocWordId(ptr) else word_id;
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

fn allocWordId(engine: *NxEngine) u32 {
    const id = engine.next_word_id;
    engine.next_word_id += 1;
    if (engine.next_word_id == 0) engine.next_word_id = 1;
    return id;
}

fn statusFromError(err: anyerror) NxStatus {
    return switch (err) {
        error.InvalidUtf8 => .invalid_utf8,
        error.OutOfMemory => .out_of_memory,
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
        var edges = engine.tokenizer.tokenizeMode(segment.bytes, mode) catch |err| return statusFromError(err);
        defer edges.deinit(allocator);
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
        var edges = engine.tokenizer.tokenizeMode(segment.bytes, mode) catch |err| return statusFromError(err);
        defer edges.deinit(allocator);
        for (edges.items) |edge| {
            out.append(allocator, toAbiToken(edge, segment.start_byte, segment.start_char)) catch return .out_of_memory;
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

fn isSegmentBoundary(cp: u32) bool {
    return switch (cp) {
        '\n', '\r', '!', '?', ';', 0x3002, 0xFF01, 0xFF1F, 0xFF1B => true,
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
    if (high != 0) return error.Io;

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

    var offset: usize = dict_magic_v4.len;
    const code_count = readU32(data, &offset) orelse return error.Io;
    const state_count = readU32(data, &offset) orelse return error.Io;
    _ = readU32(data, &offset) orelse return error.Io;

    const codepoints = sliceAs(u32, data, &offset, code_count) orelse return error.Io;
    const base = sliceAs(u32, data, &offset, state_count) orelse return error.Io;
    const check = sliceAs(u32, data, &offset, state_count) orelse return error.Io;
    const nodes = sliceAs(tokenizer_mod.Tokenizer.DatNode, data, &offset, state_count) orelse return error.Io;

    var max_word_id: u32 = 0;
    for (nodes) |node| max_word_id = @max(max_word_id, node.word_id);
    engine.tokenizer.loadDatDictBorrowed(nodes, codepoints, base, check);
    engine.next_word_id = max_word_id + 1;
    engine.dict_mapping = mapping;
    return true;
}

fn sliceAs(comptime T: type, data: []const u8, offset: *usize, count: u32) ?[]const T {
    const byte_len = @as(usize, count) * @sizeOf(T);
    const end = offset.* + byte_len;
    if (end > data.len) return null;
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
    const file = c.fopen(path, "rb") orelse return error.Io;
    defer _ = c.fclose(file);

    var buffer: [4096]u8 = undefined;
    while (c.fgets(&buffer, buffer.len, file) != null) {
        const len = c.strlen(&buffer);
        var line = std.mem.trim(u8, buffer[0..len], " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;

        const word_end = std.mem.indexOfAny(u8, line, "\t ") orelse line.len;
        const word = line[0..word_end];
        line = std.mem.trim(u8, line[word_end..], " \t");
        const score_end = std.mem.indexOfAny(u8, line, "\t ") orelse line.len;
        // The alpha loader accepts jieba-style "word freq tag" lines and ignores tags for now.
        const score = if (score_end == 0) 1.0 else std.fmt.parseFloat(f32, line[0..score_end]) catch 1.0;
        if (target == .base) {
            try engine.tokenizer.addBaseWord(word, allocWordId(engine), score, 0);
        } else {
            try engine.tokenizer.addWord(word, allocWordId(engine), score, 0);
        }
    }
}

fn loadBinaryDictFile(engine: *NxEngine, path: [*:0]const u8, target: DictTarget) !void {
    const file = c.fopen(path, "rb") orelse return error.Io;
    defer _ = c.fclose(file);
    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.Io;
    const size = c.ftell(file);
    if (size < 0) return error.Io;
    if (c.fseek(file, 0, c.SEEK_SET) != 0) return error.Io;

    const data = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(data);
    if (c.fread(data.ptr, 1, data.len, file) != data.len) return error.Io;
    if (data.len < dict_magic_v4.len + 12) return error.Io;
    if (std.mem.eql(u8, data[0..dict_magic_v4.len], dict_magic_v4)) return loadBinaryDict(engine, data, target);
    return error.Io;
}

fn loadBinaryDict(engine: *NxEngine, data: []const u8, target: DictTarget) !void {
    var offset: usize = dict_magic_v4.len;
    const code_count = readU32(data, &offset) orelse return error.Io;
    const state_count = readU32(data, &offset) orelse return error.Io;
    const entry_count = readU32(data, &offset) orelse return error.Io;

    if (target == .base and engine.tokenizer.isDictEmpty()) {
        const codepoints = try allocator.alloc(u32, code_count);
        defer allocator.free(codepoints);
        const base = try allocator.alloc(u32, state_count);
        defer allocator.free(base);
        const check = try allocator.alloc(u32, state_count);
        defer allocator.free(check);
        const nodes = try allocator.alloc(tokenizer_mod.Tokenizer.DatNode, state_count);
        defer allocator.free(nodes);

        for (codepoints) |*cp| cp.* = readU32(data, &offset) orelse return error.Io;
        for (base) |*item| item.* = readU32(data, &offset) orelse return error.Io;
        for (check) |*item| item.* = readU32(data, &offset) orelse return error.Io;
        var max_word_id: u32 = 0;
        for (nodes) |*node| {
            const word_id = readU32(data, &offset) orelse return error.Io;
            const score_bits = readU32(data, &offset) orelse return error.Io;
            node.* = .{ .word_id = word_id, .score = @bitCast(score_bits) };
            max_word_id = @max(max_word_id, word_id);
        }
        try engine.tokenizer.loadDatDict(nodes, codepoints, base, check);
        engine.next_word_id = max_word_id + 1;
        return;
    }

    try skipDat(data, &offset, code_count, state_count);
    try loadV2Entries(engine, data, &offset, entry_count);
}

fn skipDat(data: []const u8, offset: *usize, code_count: u32, state_count: u32) !void {
    const bytes = @as(usize, code_count) * 4 + @as(usize, state_count) * (@sizeOf(tokenizer_mod.Tokenizer.DatNode) + 8);
    if (offset.* + bytes > data.len) return error.Io;
    offset.* += bytes;
}

fn loadV2Entries(engine: *NxEngine, data: []const u8, offset: *usize, entry_count: u32) !void {
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const word_len = readU16(data, offset) orelse return error.Io;
        const pos_id = readU16(data, offset) orelse return error.Io;
        const score_bits = readU32(data, offset) orelse return error.Io;
        const end = offset.* + word_len;
        if (end > data.len) return error.Io;
        try engine.tokenizer.addWord(data[offset.*..end], allocWordId(engine), @bitCast(score_bits), pos_id);
        offset.* = end;
    }
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
    return @max(1, @min(wanted, text_count));
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

fn modeFromAbi(mode: NxMode) tokenizer_mod.Mode {
    return switch (mode) {
        .accurate => .accurate,
        .full => .full,
        .search => .search,
    };
}
