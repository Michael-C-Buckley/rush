//! Completion runtime bridge.
//!
//! This module is the app-facing owner for completion query state while the
//! legacy executor still hosts dynamic provider execution internals.

const std = @import("std");
const compat = @import("compat.zig");
const completion = @import("completion.zig");
const executor_impl = @import("exec.zig");
const ir = @import("ir.zig");
const runtime = @import("runtime.zig");

const Self = @This();

allocator: std.mem.Allocator,
executor: executor_impl.Executor,

pub const Options = struct {
    io: ?std.Io = null,
    allow_external: bool = false,
    features: compat.Features = .{},
    external_stdio: runtime.ExternalStdio = .capture,
    interactive: bool = false,
    foreground_terminal: bool = true,
    cancel: ?*completion.CancellationToken = null,
    arg_zero: []const u8 = "rush",
    source_path: ?[]const u8 = null,
    suppress_functions: bool = false,
    suppress_special_builtin_properties: bool = false,
    suppress_errexit: bool = false,
    ignore_errexit: bool = false,
    force_noninteractive_error_consequences: bool = false,
    default_path_lookup: bool = false,
    verbose_input_echo: bool = true,
    alias_timing_chunks: bool = true,
    top_level_parse_diagnostics: bool = false,
    completion_provider_only: bool = false,
    completion_function_sink: ?*completion.State = null,
    stdin_script_file: ?std.Io.File = null,
    stdin_script_source_offset: usize = 0,
    completion_loader: ?*const fn (*anyopaque, *Self, []const u8, completion.ScriptLoaderOptions) anyerror!void = null,
    completion_loader_context: ?*anyopaque = null,
    abort_on_output_write_failure: bool = false,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    status: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator, .executor = executor_impl.Executor.init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.executor.deinit();
    self.* = undefined;
}

pub fn state(self: *Self) *completion.State {
    return &self.executor.completion_session.state;
}

pub fn stateConst(self: *const Self) *const completion.State {
    return &self.executor.completion_session.state;
}

pub fn generation(self: *const Self) u64 {
    return self.stateConst().generationValue();
}

pub fn copyStateFrom(self: *Self, other: *const Self) !void {
    try self.executor.copyCompletionStateFrom(&other.executor);
}

pub fn copyStateFromLegacyExecutor(self: *Self, other: *const executor_impl.Executor) !void {
    try self.executor.copyCompletionStateFrom(other);
}

pub fn setEnv(self: *Self, name: []const u8, value: []const u8) !void {
    try self.executor.setEnv(name, value);
}

pub fn getEnv(self: *const Self, name: []const u8) ?[]const u8 {
    return self.executor.getEnv(name);
}

pub fn setFunction(self: *Self, name: []const u8, body: []const u8, redirections: []const ir.Redirection) !void {
    try self.executor.setFunction(name, body, redirections);
}

pub fn hasFunction(self: *const Self, name: []const u8) bool {
    return self.executor.hasFunction(name);
}

pub fn registerRule(self: *Self, rule: completion.Rule) !void {
    try self.state().registerRule(rule);
}

pub fn registerManifestCommandState(self: *Self, manifest_state: completion.ManifestCommandState) !void {
    try self.state().registerManifestCommandState(manifest_state);
}

pub fn registerVariantProbe(self: *Self, command: []const u8, args: []const []const u8, patterns: []const completion.VariantPattern) !void {
    try self.state().registerVariantProbe(command, args, patterns);
}

pub fn setVariantProbeMock(self: *Self, command: []const u8, stdout: []const u8) !void {
    try self.state().setVariantProbeMock(command, stdout);
}

pub fn clearProviderDiagnostics(self: *Self) void {
    self.state().clearProviderDiagnostics();
}

pub fn providerDiagnostics(self: *const Self) []const completion.ProviderDiagnostic {
    return self.stateConst().providerDiagnostics();
}

pub fn lastContext(self: *const Self) ?completion.EvalContext {
    return self.stateConst().lastContext();
}

pub fn lastSemantic(self: *const Self) ?completion.SemanticContext {
    return self.stateConst().last_semantic;
}

pub fn lastTracePath(self: *const Self) ?[]const []const u8 {
    return self.stateConst().last_trace_path;
}

pub fn lastPrecommandDepthLimited(self: *const Self) bool {
    return self.stateConst().last_precommand_depth_limited;
}

pub fn analyze(self: *Self, source: []const u8, cursor: usize) !completion.SemanticContext {
    return self.executor.analyzeCompletionsForInput(source, cursor);
}

pub fn diagnostics(self: *Self, source: []const u8, cursor: usize, options: Options) ![]completion.Diagnostic {
    return self.executor.completionDiagnosticsForInputOptions(source, cursor, legacyOptions(options));
}

pub fn freeDiagnostics(self: *Self, diagnostics_value: []completion.Diagnostic) void {
    self.executor.freeCompletionDiagnostics(diagnostics_value);
}

pub fn collect(self: *Self, source: []const u8, cursor: usize, options: Options) ![]completion.Candidate {
    var adapter_context: CompletionLoaderAdapterContext = .{
        .runtime = self,
        .loader = options.completion_loader,
        .context = options.completion_loader_context,
    };
    var options_legacy = legacyOptions(options);
    if (options.completion_loader != null) {
        options_legacy.completion_loader = completionLoaderAdapter;
        options_legacy.completion_loader_context = &adapter_context;
    }
    return self.executor.collectCompletionsForInput(source, cursor, options_legacy);
}

pub fn freeCandidates(self: *Self, candidates: []completion.Candidate) void {
    self.executor.freeCompletions(candidates);
}

pub fn executeScriptSlice(self: *Self, script: []const u8, options: Options) !Result {
    var adapter_context: CompletionLoaderAdapterContext = .{
        .runtime = self,
        .loader = options.completion_loader,
        .context = options.completion_loader_context,
    };
    var options_legacy = legacyOptions(options);
    if (options.completion_loader != null) {
        options_legacy.completion_loader = completionLoaderAdapter;
        options_legacy.completion_loader_context = &adapter_context;
    }
    const result = try self.executor.executeScriptSlice(script, options_legacy);
    return .{ .allocator = result.allocator, .status = result.status, .stdout = result.stdout, .stderr = result.stderr };
}

pub fn expandViPathnamePattern(self: *Self, allocator: std.mem.Allocator, io: std.Io, word: []const u8) !@import("expand.zig").ExpansionPattern {
    return self.executor.expandViPathnamePattern(allocator, io, word);
}

pub fn expandViPathnamePatterns(self: *Self, allocator: std.mem.Allocator, io: std.Io, word: []const u8) !@import("expand.zig").ExpansionPatterns {
    return self.executor.expandViPathnamePatterns(allocator, io, word);
}

pub fn expandAbbreviationForInput(self: *Self, allocator: std.mem.Allocator, source: []const u8, cursor: usize, append_space: bool) !?completion.Edit {
    return self.executor.expandAbbreviationForInput(allocator, source, cursor, append_space);
}

pub fn evalContextForInput(allocator: std.mem.Allocator, source: []const u8, cursor: usize) !completion.EvalContext {
    return executor_impl.completionEvalContextForInput(allocator, source, cursor);
}

pub fn optionSuppressionForOption(context: completion.SemanticContext, option: completion.Option) ?completion.OptionSuppression {
    return executor_impl.completionOptionSuppressionForOption(context, option);
}

const CompletionLoaderAdapterContext = struct {
    runtime: *Self,
    loader: ?*const fn (*anyopaque, *Self, []const u8, completion.ScriptLoaderOptions) anyerror!void,
    context: ?*anyopaque,
};

fn completionLoaderAdapter(context: *anyopaque, executor: *executor_impl.Executor, command: []const u8, loader_options: completion.ScriptLoaderOptions) anyerror!void {
    const adapter: *CompletionLoaderAdapterContext = @ptrCast(@alignCast(context));
    std.debug.assert(executor == &adapter.runtime.executor);
    const loader = adapter.loader orelse return;
    const loader_context = adapter.context orelse return;
    return loader(loader_context, adapter.runtime, command, loader_options);
}

fn legacyOptions(options: Options) executor_impl.ExecuteOptions {
    return .{
        .io = options.io,
        .allow_external = options.allow_external,
        .features = options.features,
        .external_stdio = options.external_stdio,
        .interactive = options.interactive,
        .foreground_terminal = options.foreground_terminal,
        .cancel = options.cancel,
        .arg_zero = options.arg_zero,
        .source_path = options.source_path,
        .suppress_functions = options.suppress_functions,
        .suppress_special_builtin_properties = options.suppress_special_builtin_properties,
        .suppress_errexit = options.suppress_errexit,
        .ignore_errexit = options.ignore_errexit,
        .force_noninteractive_error_consequences = options.force_noninteractive_error_consequences,
        .default_path_lookup = options.default_path_lookup,
        .verbose_input_echo = options.verbose_input_echo,
        .alias_timing_chunks = options.alias_timing_chunks,
        .top_level_parse_diagnostics = options.top_level_parse_diagnostics,
        .completion_provider_only = options.completion_provider_only,
        .completion_function_sink = options.completion_function_sink,
        .stdin_script_file = options.stdin_script_file,
        .stdin_script_source_offset = options.stdin_script_source_offset,
        .completion_loader = null,
        .completion_loader_context = null,
        .abort_on_output_write_failure = options.abort_on_output_write_failure,
    };
}
