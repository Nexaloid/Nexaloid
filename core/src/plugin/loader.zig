const std = @import("std");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("windows.h");
}) else struct {};
const lattice_mod = @import("../lattice/lattice.zig");
const types = @import("../types.zig");

const abi_version = 1;
const candidate_provider_kind = 1;

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
        var ctx = CandidateCtx{
            .allocator = allocator,
            .chars = chars,
            .lattice = lattice,
        };
        const input = NxPluginInput{
            .text = text.ptr,
            .text_len = text.len,
            .char_len = @intCast(chars.len),
        };

        if (self.provide_candidates_fn(self.instance, &input, onCandidate, &ctx) != 0) return error.Plugin;
        if (ctx.invalid) return error.Plugin;
    }
};

pub fn load(path: [*:0]const u8, config_json: ?[*:0]const u8) !LoadedPlugin {
    var lib = try DynamicLibrary.open(path);
    errdefer lib.close();

    const init_fn = lib.lookup(NxPluginInitFn, "nx_plugin_init") orelse return error.Plugin;
    const free_fn = lib.lookup(NxPluginFreeFn, "nx_plugin_free") orelse return error.Plugin;
    const get_info_fn = lib.lookup(NxPluginGetInfoFn, "nx_plugin_get_info") orelse return error.Plugin;
    const provide_fn = lib.lookup(NxPluginProvideCandidatesFn, "nx_plugin_provide_candidates") orelse return error.Plugin;

    var instance: ?*NxPlugin = null;
    if (init_fn(config_json, &instance) != 0 or instance == null) return error.Plugin;
    errdefer free_fn(instance);

    var info = NxPluginInfo{
        .abi_version = 0,
        .name = null,
        .version = null,
        .kind = 0,
    };
    if (get_info_fn(instance, &info) != 0) return error.Plugin;
    if (info.abi_version != abi_version or info.kind != candidate_provider_kind) return error.Plugin;

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
        const handle = c.LoadLibraryA(path) orelse return error.Plugin;
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
    allocator: std.mem.Allocator,
    chars: []const types.NxChar,
    lattice: *lattice_mod.Lattice,
    invalid: bool = false,
};

fn onCandidate(candidate: *const NxPluginCandidate, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *CandidateCtx = @ptrCast(@alignCast(user_data orelse return));
    const start: usize = candidate.start_char;
    const end: usize = candidate.end_char;
    if (start >= end or end > ctx.chars.len) {
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
