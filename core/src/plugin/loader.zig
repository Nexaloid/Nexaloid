const std = @import("std");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("windows.h");
}) else struct {};
const lattice_mod = @import("../lattice/lattice.zig");
const types = @import("../types.zig");

const abi_version = 1;
const candidate_provider_kind = 1;
const max_plugin_candidates_base = 1024;
const max_plugin_candidates_per_char = 64;

const NxPlugin = opaque {};

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
const NxPluginInitFn = *const fn (?[*:0]const u8, *?*NxPlugin) callconv(.c) c_int;
const NxPluginFreeFn = *const fn (?*NxPlugin) callconv(.c) void;
const NxPluginGetInfoFn = *const fn (?*NxPlugin, *NxPluginInfo) callconv(.c) c_int;
const NxPluginProvideCandidatesFn = *const fn (?*NxPlugin, *const NxPluginInput, NxPluginCandidateCallback, ?*anyopaque) callconv(.c) c_int;

pub const LoadedPlugin = struct {
    lib: DynamicLibrary,
    instance: ?*NxPlugin,
    free_fn: NxPluginFreeFn,
    provide_candidates_fn: NxPluginProvideCandidatesFn,

    pub fn close(self: *LoadedPlugin) void {
        self.free_fn(self.instance);
        self.lib.close();
    }

    pub fn addCandidates(
        self: *LoadedPlugin,
        allocator: std.mem.Allocator,
        text: []const u8,
        chars: []const types.NxChar,
        lattice: *lattice_mod.Lattice,
    ) !void {
        _ = allocator;
        if (chars.len > std.math.maxInt(u32)) return error.PluginInputTooLarge;
        var ctx = CandidateCtx{
            .chars = chars,
            .lattice = lattice,
            .max_candidates = maxCandidateCount(chars.len),
        };
        const input = NxPluginInput{
            .text = text.ptr,
            .text_len = text.len,
            .char_len = @intCast(chars.len),
        };

        if (self.provide_candidates_fn(self.instance, &input, onCandidate, &ctx) != 0) return error.PluginProvideFailed;
        if (ctx.invalid) return error.PluginCandidateInvalid;
    }
};

pub fn load(allocator: std.mem.Allocator, path: [*:0]const u8, config_json: ?[*:0]const u8) !LoadedPlugin {
    const abs_path = std.fs.path.resolve(allocator, &.{std.mem.span(path)}) catch return error.PluginOpenFailed;
    defer allocator.free(abs_path);
    const abs_path_z = allocator.dupeZ(u8, abs_path) catch return error.OutOfMemory;
    defer allocator.free(abs_path_z);

    var lib = DynamicLibrary.open(abs_path_z) catch return error.PluginOpenFailed;
    errdefer lib.close();

    const init_fn = lib.lookup(NxPluginInitFn, "nx_plugin_init") orelse return error.PluginSymbolMissing;
    const free_fn = lib.lookup(NxPluginFreeFn, "nx_plugin_free") orelse return error.PluginSymbolMissing;
    const get_info_fn = lib.lookup(NxPluginGetInfoFn, "nx_plugin_get_info") orelse return error.PluginSymbolMissing;
    const provide_fn = lib.lookup(NxPluginProvideCandidatesFn, "nx_plugin_provide_candidates") orelse return error.PluginSymbolMissing;

    var instance: ?*NxPlugin = null;
    if (init_fn(config_json, &instance) != 0 or instance == null) return error.PluginInitFailed;
    errdefer free_fn(instance);

    var info = NxPluginInfo{
        .abi_version = 0,
        .name = null,
        .version = null,
        .kind = 0,
    };
    if (get_info_fn(instance, &info) != 0) return error.PluginInfoFailed;
    if (info.abi_version != abi_version) return error.PluginAbiMismatch;
    if (info.kind != candidate_provider_kind) return error.PluginKindMismatch;

    return .{
        .lib = lib,
        .instance = instance,
        .free_fn = free_fn,
        .provide_candidates_fn = provide_fn,
    };
}

const DynamicLibrary = if (builtin.os.tag == .windows) struct {
    handle: c.HMODULE,

    fn open(path: [*:0]const u8) !DynamicLibrary {
        const handle = c.LoadLibraryA(path) orelse return error.PluginOpenFailed;
        return .{ .handle = handle };
    }

    fn close(self: *DynamicLibrary) void {
        _ = c.FreeLibrary(self.handle);
    }

    fn lookup(self: *DynamicLibrary, comptime T: type, name: [:0]const u8) ?T {
        const proc = c.GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(proc);
    }
} else struct {
    lib: std.DynLib,

    fn open(path: [*:0]const u8) !DynamicLibrary {
        return .{ .lib = try std.DynLib.openZ(path) };
    }

    fn close(self: *DynamicLibrary) void {
        self.lib.close();
    }

    fn lookup(self: *DynamicLibrary, comptime T: type, name: [:0]const u8) ?T {
        return self.lib.lookup(T, name);
    }
};

const CandidateCtx = struct {
    chars: []const types.NxChar,
    lattice: *lattice_mod.Lattice,
    max_candidates: usize,
    count: usize = 0,
    invalid: bool = false,
};

fn onCandidate(candidate: *const NxPluginCandidate, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *CandidateCtx = @ptrCast(@alignCast(user_data orelse return));
    ctx.count += 1;
    if (ctx.count > ctx.max_candidates) {
        ctx.invalid = true;
        return;
    }
    const start: usize = candidate.start_char;
    const end: usize = candidate.end_char;
    if (start >= end or end > ctx.chars.len) {
        ctx.invalid = true;
        return;
    }
    if (!std.math.isFinite(candidate.score)) {
        ctx.invalid = true;
        return;
    }
    ctx.lattice.addEdge(.{
        .start_char = candidate.start_char,
        .end_char = candidate.end_char,
        .start_byte = ctx.chars[start].start_byte,
        .end_byte = ctx.chars[end - 1].end_byte,
        .word_id = 0,
        .score = candidate.score,
        .pos_id = 0,
        .source = .plugin,
        .flags = candidate.flags,
    }) catch {
        ctx.invalid = true;
    };
}

fn maxCandidateCount(char_len: usize) usize {
    const max = std.math.maxInt(usize);
    if (char_len > (max - max_plugin_candidates_base) / max_plugin_candidates_per_char) return max;
    return char_len * max_plugin_candidates_per_char + max_plugin_candidates_base;
}
