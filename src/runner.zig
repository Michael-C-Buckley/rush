//! Script runner public types and result formatting helpers.

const std = @import("std");

const assets = @import("assets.zig");
const default_builtins = @import("builtins.zig");
const cli_invocation = @import("invocation.zig");
const extension_api = @import("extensions/api.zig");
const extension_handler_registry = @import("extensions/handlers.zig");
const runtime = @import("runtime.zig");
const shell = @import("shell.zig");
const compat = shell.compat;
const parser = shell.parser;
const ir = shell.ir;

pub const ExtensionHandlers = struct {
    context: ?*anyopaque = null,
    lookup: ?*const fn (?*anyopaque, []const u8) ?extension_api.HandlerSpec = null,
    function_autoload: shell.eval.FunctionAutoload = .{},

    fn apply(self: ExtensionHandlers, evaluator: *shell.eval.Evaluator) void {
        if (self.lookup) |lookup_fn| evaluator.setExtensionHandlerLookup(self.context, lookup_fn);
        if (self.function_autoload.lookup != null) {
            evaluator.function_autoload = self.function_autoload;
        } else {
            installDefaultFunctionAutoload(evaluator);
        }
    }
};

fn installDefaultFunctionAutoload(evaluator: *shell.eval.Evaluator) void {
    if (evaluator.function_autoload.lookup != null) return;
    if (!evaluator.features.isBash()) return;
    evaluator.function_autoload = assets.functionAutoload();
}

fn bundledExtensionLookup(_: ?*anyopaque, name: []const u8) ?extension_api.HandlerSpec {
    return extension_handler_registry.lookup(name);
}

pub const Options = struct {
    io: ?std.Io = null,
    allow_external: bool = true,
    features: compat.Features = .{},
    external_stdio: runtime.ExternalStdio = .capture,
    live_stdio: bool = false,
    interactive: bool = false,
    arg_zero: []const u8 = "rush",
    source_path: ?[]const u8 = null,
    command_string_line_diagnostics: bool = false,
    stdin_script_file: ?std.Io.File = null,
    stdin_script_source_offset: usize = 0,
};

pub fn invocationContext(options: Options) shell.InvocationContext {
    return shell.InvocationContext.init(.{
        .features = options.features,
        .arg_zero = options.arg_zero,
        .source = inputSource(options),
        .interactive = options.interactive,
        .stdin_script_file = options.stdin_script_file,
        .stdin_script_source_offset = options.stdin_script_source_offset,
    });
}

pub fn inputSource(options: Options) shell.InputSource {
    if (options.source_path != null) return .script_file;
    if (options.stdin_script_file != null) return .standard_input;
    return .command_string;
}

pub const LoadedInvocationScript = struct {
    allocator: std.mem.Allocator,
    script: []const u8,
    options: Options,
    owns_script: bool,

    pub fn deinit(self: *LoadedInvocationScript) void {
        if (self.owns_script) self.allocator.free(self.script);
        self.* = undefined;
    }
};

pub fn loadInvocationScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: cli_invocation.ShellInvocation,
    external_stdio: runtime.ExternalStdio,
) !LoadedInvocationScript {
    var options: Options = .{
        .io = io,
        .allow_external = true,
        .features = invocation.features,
        .external_stdio = external_stdio,
        .arg_zero = invocation.arg_zero,
    };
    switch (invocation.kind) {
        .command_string => {
            options.command_string_line_diagnostics = std.mem.indexOfScalar(u8, invocation.source, '\n') != null;
            return .{
                .allocator = allocator,
                .script = invocation.source,
                .options = options,
                .owns_script = false,
            };
        },
        .script_file => {
            const script = try std.Io.Dir.cwd().readFileAlloc(io, invocation.source, allocator, .unlimited);
            options.source_path = invocation.source;
            return .{
                .allocator = allocator,
                .script = script,
                .options = options,
                .owns_script = true,
            };
        },
        .standard_input => {
            const script = try readStandardInputScript(allocator, io);
            options.stdin_script_file = std.Io.File.stdin();
            return .{
                .allocator = allocator,
                .script = script,
                .options = options,
                .owns_script = true,
            };
        },
    }
}

fn readStandardInputScript(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

pub fn runScript(allocator: std.mem.Allocator, io: std.Io, script: []const u8) !CommandResult {
    return runScriptWithOptions(allocator, io, script, .{ .io = io, .allow_external = true });
}

pub fn runScriptWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    script: []const u8,
    options: Options,
) !CommandResult {
    return runScriptWithEnvironment(allocator, io, script, options, null);
}

pub fn runScriptWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    script: []const u8,
    options: Options,
    environ_map: ?*const std.process.Environ.Map,
) !CommandResult {
    return runCommandStringWithEnvironment(allocator, io, script, options, environ_map, &.{}, .{});
}

pub fn runCommandStringWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    script: []const u8,
    options: Options,
    environ_map: ?*const std.process.Environ.Map,
    positionals: []const []const u8,
    shell_options: shell.ShellOptions,
) !CommandResult {
    const invocation = invocationContext(options);
    if (invocation.interactive or !options.allow_external) {
        return unsupported(allocator, "non-interactive command strings must run through the semantic executor");
    }
    var execution = try runSemanticCommandStringInternal(
        allocator,
        io,
        script,
        invocation,
        options.source_path,
        options.command_string_line_diagnostics,
        options.external_stdio,
        options.live_stdio,
        environ_map,
        positionals,
        shell_options,
    );
    switch (execution) {
        .output => |output| {
            execution = undefined;
            return output;
        },
        .unsupported => |message| {
            execution = undefined;
            defer allocator.free(message);
            return unsupported(allocator, message);
        },
    }
}

pub const SemanticInvocationExecution = union(enum) {
    output: CommandResult,
    unsupported: []const u8,

    pub fn deinit(self: *SemanticInvocationExecution, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .output => |*output| output.deinit(),
            .unsupported => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

pub fn runSemanticCommandString(
    allocator: std.mem.Allocator,
    io: std.Io,
    script: []const u8,
    invocation: shell.InvocationContext,
    external_stdio: runtime.ExternalStdio,
    environ_map: ?*const std.process.Environ.Map,
    positionals: []const []const u8,
    shell_options: shell.ShellOptions,
) !SemanticInvocationExecution {
    return runSemanticCommandStringInternal(
        allocator,
        io,
        script,
        invocation,
        null,
        false,
        external_stdio,
        false,
        environ_map,
        positionals,
        shell_options,
    );
}

fn runSemanticCommandStringInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    script: []const u8,
    invocation: shell.InvocationContext,
    source_path: ?[]const u8,
    command_string_line_diagnostics: bool,
    external_stdio: runtime.ExternalStdio,
    live_stdio: bool,
    environ_map: ?*const std.process.Environ.Map,
    positionals: []const []const u8,
    shell_options: shell.ShellOptions,
) !SemanticInvocationExecution {
    assertSemanticStartupOptions(script, invocation, positionals);

    if (shell_options.verbose) {
        return semanticUnsupported(
            allocator,
            "semantic executor does not yet implement non-interactive verbose startup mode",
        );
    }
    if (environ_map) |map| {
        if (!semanticEnvironmentSupported(map)) {
            return semanticUnsupported(
                allocator,
                "semantic ShellState cannot yet preserve non-shell environment names",
            );
        }
    }

    if (semanticCommandStringNeedsChunkedExecution(script, command_string_line_diagnostics)) {
        return runSemanticAliasTimingCommandString(
            allocator,
            io,
            script,
            invocation,
            source_path,
            command_string_line_diagnostics,
            external_stdio,
            live_stdio,
            environ_map,
            positionals,
            shell_options,
        );
    }

    var invocation_arena = std.heap.ArenaAllocator.init(allocator);
    defer invocation_arena.deinit();
    const invocation_allocator = invocation_arena.allocator();

    const parsed = try parser.parse(invocation_allocator, script, .{
        .features = invocation.features.withStrictDiagnostics(),
        .collect_command_substitution_nodes = false,
    });
    if (parsed.diagnostics.len != 0) {
        return .{ .output = try parseDiagnosticsWithOptions(allocator, script, parsed.diagnostics, .{
            .source_path = source_path,
            .line_number_without_path = command_string_line_diagnostics,
        }) };
    }

    const program = try ir.lowerSimpleCommands(invocation_allocator, parsed);
    if (try semanticPreflightUnsupported(allocator, program, invocation.features)) |message| {
        return semanticUnsupported(allocator, message);
    }

    var shell_state = shell.ShellState.init(allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(allocator, io, &shell_state, environ_map, positionals, shell_options);
    configureCompatibilityShopts(&shell_state, invocation.features, invocation.interactive);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.command_string_line_diagnostics = command_string_line_diagnostics;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = true;
    evaluator.external_stdio = semanticEvaluatorExternalStdio(external_stdio, live_stdio);
    evaluator.commit_exec_redirections = live_stdio and external_stdio == .inherit;
    installDefaultFunctionAutoload(&evaluator);
    var parser_resolver = shell.ParserBackedSourceResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const eval_context = invocation.evalContext(.current_shell);

    return runSemanticLoweredProgram(
        allocator,
        script,
        program,
        &evaluator,
        &shell_state,
        eval_context,
        &parser_resolver,
        0,
        invocation.stdin_script_file,
        invocation.stdin_script_source_offset,
        true,
        null,
        .{},
    );
}

fn semanticEvaluatorExternalStdio(
    external_stdio: runtime.ExternalStdio,
    live_stdio: bool,
) runtime.ExternalStdio {
    if (live_stdio) return external_stdio;
    return switch (external_stdio) {
        .inherit => .capture,
        else => external_stdio,
    };
}

fn runSemanticAliasTimingCommandString(
    allocator: std.mem.Allocator,
    io: std.Io,
    script: []const u8,
    invocation: shell.InvocationContext,
    source_path: ?[]const u8,
    command_string_line_diagnostics: bool,
    external_stdio: runtime.ExternalStdio,
    live_stdio: bool,
    environ_map: ?*const std.process.Environ.Map,
    positionals: []const []const u8,
    shell_options: shell.ShellOptions,
) !SemanticInvocationExecution {
    var shell_state = shell.ShellState.init(allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(allocator, io, &shell_state, environ_map, positionals, shell_options);
    configureCompatibilityShopts(&shell_state, invocation.features, invocation.interactive);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.command_string_line_diagnostics = command_string_line_diagnostics;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = true;
    evaluator.external_stdio = semanticEvaluatorExternalStdio(external_stdio, live_stdio);
    evaluator.commit_exec_redirections = live_stdio and external_stdio == .inherit;
    installDefaultFunctionAutoload(&evaluator);
    var parser_resolver = shell.ParserBackedSourceResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const eval_context = invocation.evalContext(.current_shell);

    var output_frame = try shell.eval.RunnerOutputFrame.init(
        allocator,
        runnerOutputMode(evaluator.commit_exec_redirections),
        evaluator.fd_port,
    );
    defer output_frame.deinit();
    var status: shell.ExitStatus = 0;
    var start = skipSemanticChunkSeparators(script, 0);
    var stop_for_pending_exit = false;
    while (start < script.len) {
        var end = extendSemanticHereDocChunk(script, start, semanticLineEnd(script, start));
        while (true) {
            const source = std.mem.trim(u8, script[start..end], " \t\r\n;");
            if (source.len == 0) break;
            const aliased = try semanticExpandAliases(allocator, source, invocation.features, &shell_state);
            defer allocator.free(aliased);
            var parsed = try parser.parse(allocator, aliased, .{
                .features = invocation.features.withStrictDiagnostics(),
                .collect_command_substitution_nodes = false,
            });
            defer parsed.deinit();
            if (parsed.diagnostics.len == 0) {
                var program = try ir.lowerSimpleCommands(allocator, parsed);
                defer program.deinit();
                var alias_snapshot = shell_state.clone(allocator) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ReadonlyVariable => unreachable,
                };
                defer alias_snapshot.deinit();
                parser_resolver.expand_aliases = shell_state.shopts.enabled(.expand_aliases);
                parser_resolver.alias_state = &alias_snapshot;
                const previous_evaluator_alias_state = evaluator.alias_state;
                evaluator.alias_state = &alias_snapshot;
                defer evaluator.alias_state = previous_evaluator_alias_state;
                var execution = try runSemanticLoweredProgram(
                    allocator,
                    aliased,
                    program,
                    &evaluator,
                    &shell_state,
                    eval_context,
                    &parser_resolver,
                    semanticSourceLine(script, start),
                    invocation.stdin_script_file,
                    invocation.stdin_script_source_offset,
                    false,
                    &output_frame,
                    .{},
                );
                defer execution.deinit(allocator);
                parser_resolver.active_frame = null;
                switch (execution) {
                    .unsupported => |message| return semanticUnsupported(allocator, message),
                    .output => |output| {
                        _ = try output_frame.writeOutcome(output.stdout, output.stderr);
                        status = output.status;
                    },
                }
                parser_resolver.alias_state = null;
                parser_resolver.active_frame = null;
                parser_resolver.active_input = null;
                if (shell_state.pending_exit != null) stop_for_pending_exit = true;
                break;
            }
            if (!parsed.incomplete or end >= script.len) {
                return .{ .output = try parseDiagnosticsAfterChunkedOutput(
                    allocator,
                    &output_frame,
                    source,
                    parsed.diagnostics,
                    .{
                        .source_path = source_path,
                        .line_offset = semanticSourceLine(script, start),
                        .line_number_without_path = command_string_line_diagnostics,
                    },
                ) };
            }
            end = extendSemanticHereDocChunk(script, end, semanticLineEnd(script, end));
        }
        if (stop_for_pending_exit) break;
        start = skipSemanticChunkSeparators(script, end);
    }

    try appendSemanticExitTrap(
        &output_frame,
        &status,
        &evaluator,
        &shell_state,
        eval_context,
        parser_resolver.resolver(),
    );
    const runner_output = try output_frame.finish();
    return .{ .output = .{
        .allocator = allocator,
        .status = status,
        .stdout = runner_output.stdout,
        .stderr = runner_output.stderr,
    } };
}

pub fn runShellStateScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    script: []const u8,
    source_path: []const u8,
    arg_zero: []const u8,
    features: compat.Features,
    external_stdio: runtime.ExternalStdio,
) !CommandResult {
    return runShellStateScriptWithExtensionHandlers(
        allocator,
        io,
        shell_state,
        script,
        source_path,
        arg_zero,
        features,
        external_stdio,
        .{},
    );
}

pub fn runShellStateScriptWithExtensionHandlers(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    script: []const u8,
    source_path: []const u8,
    arg_zero: []const u8,
    features: compat.Features,
    external_stdio: runtime.ExternalStdio,
    extension_handlers: ExtensionHandlers,
) !CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    std.debug.assert(arg_zero.len != 0);
    std.debug.assert(source_path.len != 0);
    if (script.len == 0) return empty(allocator, shell_state.last_status);

    const invocation = shell.InvocationContext.init(.{
        .features = features,
        .arg_zero = arg_zero,
        .source = .script_file,
        .interactive = true,
    });
    var semantic_execution = if (semanticScriptNeedsAliasTiming(script))
        try runSemanticAliasTimingShellStateScript(
            allocator,
            io,
            shell_state,
            script,
            invocation,
            source_path,
            external_stdio,
            false,
            extension_handlers,
            false,
        )
    else
        try runSemanticShellStateScriptWithoutAliasTiming(
            allocator,
            io,
            shell_state,
            script,
            invocation,
            source_path,
            external_stdio,
            extension_handlers,
        );
    switch (semantic_execution) {
        .output => |output| {
            semantic_execution = undefined;
            return output;
        },
        .unsupported => |message| {
            semantic_execution = undefined;
            defer allocator.free(message);
            return unsupported(allocator, message);
        },
    }
}

pub fn runHiddenShellStateCommandWithExtensionHandlers(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    argv: []const []const u8,
    arg_zero: []const u8,
    features: compat.Features,
    external_stdio: runtime.ExternalStdio,
    extension_handlers: ExtensionHandlers,
) !CommandResult {
    return runHiddenShellStateCommandWithExtensionHandlersApplyOptions(
        allocator,
        io,
        shell_state,
        argv,
        arg_zero,
        features,
        external_stdio,
        extension_handlers,
        .{},
        0,
    );
}

pub fn runHiddenShellStateCommandWithExtensionHandlersApplyOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    argv: []const []const u8,
    arg_zero: []const u8,
    features: compat.Features,
    external_stdio: runtime.ExternalStdio,
    extension_handlers: ExtensionHandlers,
    apply_options: shell.CommandOutcome.ApplyOptions,
    event_dispatch_depth: u32,
) !CommandResult {
    return runHiddenShellStateCommandWithExtensionHandlersApplyOptionsAndAssignments(
        allocator,
        io,
        shell_state,
        argv,
        &.{},
        arg_zero,
        features,
        external_stdio,
        extension_handlers,
        apply_options,
        event_dispatch_depth,
    );
}

pub fn runHiddenShellStateCommandWithExtensionHandlersApplyOptionsAndAssignments(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    argv: []const []const u8,
    assignments: []const shell.command_plan.Assignment,
    arg_zero: []const u8,
    features: compat.Features,
    external_stdio: runtime.ExternalStdio,
    extension_handlers: ExtensionHandlers,
    apply_options: shell.CommandOutcome.ApplyOptions,
    event_dispatch_depth: u32,
) !CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    std.debug.assert(argv.len != 0);
    std.debug.assert(arg_zero.len != 0);
    for (assignments) |assignment| assignment.validate();

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = features;
    evaluator.arg_zero = arg_zero;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = false;
    evaluator.external_stdio = external_stdio;
    evaluator.command_substitution_execution = .parent_process_snapshot;
    evaluator.event_dispatch_depth = event_dispatch_depth;
    extension_handlers.apply(&evaluator);

    const command: shell.command_plan.ExpandedSimpleCommand = .{ .assignments = assignments, .argv = argv };
    var functions: std.ArrayList(shell.command_plan.FunctionDefinition) = .empty;
    defer functions.deinit(allocator);
    var function_iterator = shell_state.functions.iterator();
    while (function_iterator.next()) |entry| try functions.append(allocator, entry.value_ptr.*);

    const external = try shell.eval.resolveExternalForEvaluation(allocator, evaluator.fs_port, shell_state.*, command);
    defer if (external) |resolution| allocator.free(resolution.path);
    const externals = if (external) |*resolution|
        @as([]const shell.command_plan.ExternalResolution, resolution[0..1])
    else
        &.{};
    const plan = shell.command_plan.classifyExpandedSimpleCommand(.{
        .command = command,
        .lookup = .{ .functions = functions.items, .externals = externals },
        .target = .current_shell,
    });
    const eval_context = shell.EvalContext.init(.{
        .target = plan.target,
        .source = .interactive,
        .interactive = true,
    });
    var hidden_input = shell.EvaluationInput.empty();
    var hidden_frame = shell.ExecutionFrame.init(.{
        .kind = .top_level,
        .eval_target = .current_shell,
        .stdin = .{ .bytes = "" },
        .mutation_policy = .commit_to_parent_shell,
    });
    try hidden_frame.spec.fd_table.bindInput(allocator, 0, .{ .bytes = "" });
    try hidden_frame.spec.fd_table.bindOutput(allocator, 1, .{ .capture = .side_stdout });
    try hidden_frame.spec.fd_table.bindOutput(allocator, 2, .{ .capture = .side_stderr });
    hidden_frame.spec.stdout = .{ .capture = .side_stdout };
    hidden_frame.spec.stderr = .{ .capture = .side_stderr };
    hidden_frame.spec.captures = .{ .channels = &.{ .side_stdout, .side_stderr } };
    defer hidden_frame.spec.fd_table.deinit(allocator);

    var outcome = try shell.eval.evaluatePlanInFrame(
        &evaluator,
        shell_state,
        eval_context,
        plan,
        &hidden_input,
        &hidden_frame,
    );
    defer outcome.deinit();
    try outcome.applyToShellState(shell_state, apply_options);
    return .{
        .allocator = allocator,
        .status = outcome.status,
        .stdout = try allocator.dupe(u8, outcome.stdout.items),
        .stderr = try allocator.dupe(u8, outcome.stderr.items),
    };
}

fn runSemanticShellStateScriptWithoutAliasTiming(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    script: []const u8,
    invocation: shell.InvocationContext,
    source_path: []const u8,
    external_stdio: runtime.ExternalStdio,
    extension_handlers: ExtensionHandlers,
) !SemanticInvocationExecution {
    shell_state.validate();
    invocation.validate();

    var parsed = try parser.parse(
        allocator,
        script,
        .{
            .features = invocation.features.withStrictDiagnostics(),
            .collect_command_substitution_nodes = false,
        },
    );
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) {
        return .{ .output = try parseDiagnosticsWithOptions(allocator, script, parsed.diagnostics, .{
            .source_path = source_path,
        }) };
    }

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();
    if (try semanticPreflightUnsupported(allocator, program, invocation.features)) |message| {
        return semanticUnsupported(allocator, message);
    }

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = true;
    evaluator.external_stdio = external_stdio;
    extension_handlers.apply(&evaluator);
    var parser_resolver = shell.ParserBackedSourceResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const eval_context = invocation.evalContext(.current_shell);

    return runSemanticLoweredProgram(
        allocator,
        script,
        program,
        &evaluator,
        shell_state,
        eval_context,
        &parser_resolver,
        0,
        null,
        0,
        false,
        null,
        extension_handlers,
    );
}

fn runSemanticAliasTimingShellStateScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    script: []const u8,
    invocation: shell.InvocationContext,
    source_path: []const u8,
    external_stdio: runtime.ExternalStdio,
    live_stdio: bool,
    extension_handlers: ExtensionHandlers,
    run_exit_trap: bool,
) !SemanticInvocationExecution {
    shell_state.validate();
    invocation.validate();

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = true;
    evaluator.external_stdio = external_stdio;
    evaluator.commit_exec_redirections = live_stdio and external_stdio == .inherit;
    extension_handlers.apply(&evaluator);
    var parser_resolver = shell.ParserBackedSourceResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const eval_context = invocation.evalContext(.current_shell);

    var output_frame = try shell.eval.RunnerOutputFrame.init(
        allocator,
        runnerOutputMode(evaluator.commit_exec_redirections),
        evaluator.fd_port,
    );
    defer output_frame.deinit();
    var status = shell_state.last_status;
    var start = skipSemanticChunkSeparators(script, 0);
    var stop_for_pending_exit = false;
    while (start < script.len) {
        var end = extendSemanticHereDocChunk(script, start, semanticLineEnd(script, start));
        while (true) {
            const source = std.mem.trim(u8, script[start..end], " \t\r\n;");
            if (source.len == 0) break;
            const aliased = try semanticExpandAliases(allocator, source, invocation.features, shell_state);
            defer allocator.free(aliased);
            var parsed = try parser.parse(allocator, aliased, .{
                .features = invocation.features.withStrictDiagnostics(),
                .collect_command_substitution_nodes = false,
            });
            defer parsed.deinit();
            if (parsed.diagnostics.len == 0) {
                var program = try ir.lowerSimpleCommands(allocator, parsed);
                defer program.deinit();
                if (try semanticPreflightUnsupported(allocator, program, invocation.features)) |message|
                    return semanticUnsupported(allocator, message);
                var alias_snapshot = shell_state.clone(allocator) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ReadonlyVariable => unreachable,
                };
                defer alias_snapshot.deinit();
                parser_resolver.expand_aliases = shell_state.shopts.enabled(.expand_aliases);
                parser_resolver.alias_state = &alias_snapshot;
                const previous_evaluator_alias_state = evaluator.alias_state;
                evaluator.alias_state = &alias_snapshot;
                defer evaluator.alias_state = previous_evaluator_alias_state;
                var execution = try runSemanticLoweredProgram(
                    allocator,
                    aliased,
                    program,
                    &evaluator,
                    shell_state,
                    eval_context,
                    &parser_resolver,
                    semanticSourceLine(script, start),
                    null,
                    0,
                    false,
                    &output_frame,
                    extension_handlers,
                );
                defer execution.deinit(allocator);
                switch (execution) {
                    .unsupported => |message| return semanticUnsupported(allocator, message),
                    .output => |output| {
                        _ = try output_frame.writeOutcome(output.stdout, output.stderr);
                        status = output.status;
                    },
                }
                parser_resolver.alias_state = null;
                parser_resolver.active_frame = null;
                parser_resolver.active_input = null;
                if (shell_state.pending_exit != null) stop_for_pending_exit = true;
                break;
            }
            if (!parsed.incomplete or end >= script.len) {
                return .{ .output = try parseDiagnosticsAfterChunkedOutput(
                    allocator,
                    &output_frame,
                    source,
                    parsed.diagnostics,
                    .{
                        .source_path = source_path,
                        .line_offset = semanticSourceLine(script, start),
                    },
                ) };
            }
            end = extendSemanticHereDocChunk(script, end, semanticLineEnd(script, end));
        }
        if (stop_for_pending_exit) break;
        start = skipSemanticChunkSeparators(script, end);
    }

    if (run_exit_trap) try appendSemanticExitTrap(
        &output_frame,
        &status,
        &evaluator,
        shell_state,
        eval_context,
        parser_resolver.resolver(),
    );
    const runner_output = try output_frame.finish();
    return .{ .output = .{
        .allocator = allocator,
        .status = status,
        .stdout = runner_output.stdout,
        .stderr = runner_output.stderr,
    } };
}

pub fn runInteractiveCommandString(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    script: []const u8,
    invocation: shell.InvocationContext,
    external_stdio: runtime.ExternalStdio,
    live_stdio: bool,
) !SemanticInvocationExecution {
    return runInteractiveCommandStringWithExtensionHandlers(
        allocator,
        io,
        shell_state,
        script,
        invocation,
        external_stdio,
        live_stdio,
        .{},
    );
}

pub fn runInteractiveCommandStringWithExtensionHandlers(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    script: []const u8,
    invocation: shell.InvocationContext,
    external_stdio: runtime.ExternalStdio,
    live_stdio: bool,
    extension_handlers: ExtensionHandlers,
) !SemanticInvocationExecution {
    assertSemanticInteractiveOptions(script, invocation);
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (external_stdio != .inherit and external_stdio != .capture)
        return semanticUnsupported(allocator, "semantic interactive executor requires inherited or captured stdio");
    if (invocation.stdin_script_file != null)
        return semanticUnsupported(allocator, "semantic interactive executor does not consume script stdin files");
    if (shell_state.pending_exit != null)
        return semanticUnsupported(allocator, "semantic interactive executor does not run while an exit is pending");
    if (shell_state.options.verbose or
        shell_state.options.xtrace or
        shell_state.options.errexit)
        return semanticUnsupported(
            allocator,
            "semantic interactive executor does not yet preserve verbose/xtrace/errexit state",
        );

    if (semanticScriptNeedsAliasTiming(script)) {
        return runSemanticAliasTimingShellStateScript(
            allocator,
            io,
            shell_state,
            script,
            invocation,
            "-c",
            external_stdio,
            live_stdio,
            extension_handlers,
            invocation.source == .command_string,
        );
    }

    const aliased = try semanticExpandAliases(allocator, script, invocation.features, shell_state);
    defer allocator.free(aliased);

    var parsed = try parser.parse(allocator, aliased, .{
        .mode = .interactive,
        .features = invocation.features.withStrictDiagnostics(),
        .collect_command_substitution_nodes = false,
    });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0)
        return semanticUnsupported(
            allocator,
            "semantic interactive parser diagnostics are not handled by this path yet",
        );

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();
    if (try semanticPreflightUnsupported(allocator, program, invocation.features)) |message|
        return semanticUnsupported(allocator, message);
    if (semanticInteractiveProgramUnsupported(shell_state.*, program)) |message|
        return semanticUnsupported(allocator, message);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.io = io;
    evaluator.external_stdio = external_stdio;
    evaluator.commit_exec_redirections = live_stdio and external_stdio == .inherit;
    extension_handlers.apply(&evaluator);
    var parser_resolver = shell.ParserBackedSourceResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const eval_context = invocation.evalContext(.current_shell);

    return runSemanticLoweredProgram(
        allocator,
        aliased,
        program,
        &evaluator,
        shell_state,
        eval_context,
        &parser_resolver,
        0,
        null,
        0,
        invocation.source == .command_string,
        null,
        extension_handlers,
    );
}

fn runSemanticLoweredProgram(
    allocator: std.mem.Allocator,
    script: []const u8,
    program: ir.Program,
    evaluator: *shell.eval.Evaluator,
    shell_state: *shell.ShellState,
    eval_context: shell.EvalContext,
    source_resolver: *shell.ParserBackedSourceResolver,
    source_line_offset: usize,
    stdin_script_file: ?std.Io.File,
    stdin_script_source_offset: usize,
    run_exit_trap: bool,
    shared_output_frame: ?*shell.eval.RunnerOutputFrame,
    extension_handlers: ExtensionHandlers,
) !SemanticInvocationExecution {
    eval_context.validate();
    shell_state.validate();
    if (stdin_script_file == null) std.debug.assert(stdin_script_source_offset == 0);

    const previous_source_line_offset = source_resolver.source_line_offset;
    source_resolver.source_line_offset = source_line_offset;
    defer source_resolver.source_line_offset = previous_source_line_offset;

    var local_output_frame: shell.eval.RunnerOutputFrame = undefined;
    const output_frame = if (shared_output_frame) |frame|
        frame
    else blk: {
        local_output_frame = try shell.eval.RunnerOutputFrame.init(
            allocator,
            runnerOutputMode(evaluator.commit_exec_redirections),
            evaluator.fd_port,
        );
        break :blk &local_output_frame;
    };
    defer if (shared_output_frame == null) output_frame.deinit();

    var status: shell.ExitStatus = 0;
    var control_flow: shell.ControlFlow = .normal;
    var abort_bash_line: ?usize = null;
    const source_lines = try SourceLineIndex.init(allocator, script);
    defer source_lines.deinit(allocator);
    var statement_arena = std.heap.ArenaAllocator.init(allocator);
    defer statement_arena.deinit();
    for (program.statements, 0..) |statement, statement_index| {
        std.debug.assert(statement.span.start <= statement.span.end);
        std.debug.assert(statement.span.end <= script.len);
        if (semanticStdinScriptConsumedStatement(stdin_script_file, stdin_script_source_offset, statement.span.start))
            continue;
        if (abort_bash_line) |line| {
            if (source_lines.lineIndex(statement.span.start) == line) continue;
            abort_bash_line = null;
        }

        const should_run = if (statement_index == 0) blk: {
            std.debug.assert(statement.op_before == .sequence);
            break :blk true;
        } else switch (statement.op_before) {
            .sequence => true,
            .and_if => status == 0,
            .or_if => status != 0,
        };
        if (!should_run) continue;
        if (semanticNoexecSuppressesStatement(shell_state.*, eval_context)) break;

        const statement_line_index = source_lines.lineIndex(statement.span.start);
        const statement_line_number = source_line_offset + statement_line_index + 1;
        const statement_allocator = statement_arena.allocator();
        defer _ = statement_arena.reset(.retain_capacity);

        var statement_fragment = try ir.statementSourceFragment(statement_allocator, program, statement_index);
        defer statement_fragment.deinit(statement_allocator);
        const statement_end = statement_fragment.consumed_end;
        const statement_source = statement_fragment.syntax_span.slice(program.source);
        std.debug.assert(statement_source.len != 0);
        var statement_context = eval_context;
        if (statement_index + 1 < program.statements.len) {
            switch (program.statements[statement_index + 1].op_before) {
                .sequence => {},
                .and_if, .or_if => statement_context = statement_context.ignoreErrexit(),
            }
        }
        syncSemanticStdinScriptOffset(stdin_script_file, stdin_script_source_offset, script, statement_end);
        source_resolver.active_frame = output_frame.execution_frame_value;
        var body = if (statement.async_after) body: {
            const statement_script = try statement_fragment.render(
                statement_allocator,
                program.source,
                .{ .trim_syntax = true },
            );
            defer statement_allocator.free(statement_script);
            const previous_statement_source_line_offset = source_resolver.source_line_offset;
            source_resolver.source_line_offset = source_line_offset + statement_line_index;
            defer source_resolver.source_line_offset = previous_statement_source_line_offset;
            const background_statement_context = statement_context.withTarget(.subshell);
            var background_shell_state = shell_state.snapshotForSubshell(statement_allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ReadonlyVariable => unreachable,
            };
            defer background_shell_state.deinit();
            break :body (try source_resolver.lowerSourceScratch(
                statement_allocator,
                statement_script,
                background_statement_context,
                &background_shell_state,
            )) orelse return semanticUnsupported(allocator, "semantic parser lowering returned no body");
        } else try source_resolver.lowerProgramStatementScratchAtLine(
            statement_allocator,
            program,
            statement_index,
            statement_context,
            shell_state,
            statement_line_number,
        );
        defer body.deinit();

        if (semanticBodyUnsupportedMessage(body)) |message| {
            return semanticUnsupported(allocator, message);
        }
        const body_failed = semanticBodyIsStoppingFailure(body, eval_context);
        if (evaluator.external_stdio == .inherit and semanticBodyUsesInheritedExternal(body)) {
            const flush_result = try output_frame.flushPendingToInheritedDescriptors();
            if (flush_result.stdout_failed or flush_result.stderr_failed) return error.Unimplemented;
        }

        evaluator.directory_change_event_observed = false;
        var command_outcome = if (statement.async_after) blk: {
            var background_plan = (try semanticBackgroundPipelinePlan(statement_allocator, body)) orelse
                return semanticUnsupported(
                    allocator,
                    // ziglint-ignore: Z024 user-visible diagnostic; wrapping would inject a newline into stderr
                    "semantic executor does not yet support this background statement shape",
                );
            defer background_plan.deinit(statement_allocator);
            break :blk shell.eval.evaluatePipelinePlan(
                evaluator,
                shell_state,
                statement_context,
                background_plan.plan,
            ) catch |err| switch (err) {
                error.Unimplemented => return semanticUnsupported(
                    allocator,
                    "semantic evaluator reported an unimplemented background command shape",
                ),
                else => |e| return e,
            };
        } else evaluateSemanticComparisonBody(
            evaluator,
            shell_state,
            statement_context,
            body,
            output_frame.execution_frame_value,
        ) catch |err| switch (err) {
            error.Unimplemented => return semanticUnsupported(
                allocator,
                "semantic evaluator reported an unimplemented command shape",
            ),
            else => |e| return e,
        };
        defer command_outcome.deinit();

        command_outcome.validateForContext(eval_context);
        const write_result = try output_frame.writeOutcome(
            command_outcome.stdout.items,
            command_outcome.stderr.items,
        );
        applyOutputWriteResult(&command_outcome, write_result);
        if (evaluator.commit_exec_redirections) {
            const flush_result = try output_frame.flushPendingToInheritedDescriptors();
            if (flush_result.stdout_failed or flush_result.stderr_failed) return error.Unimplemented;
        }
        status = command_outcome.status;
        control_flow = command_outcome.effectiveControlFlow();
        if (bashAssignmentErrorAbortsSourceLine(eval_context.features, statement_source, command_outcome)) {
            abort_bash_line = statement_line_index;
        }
        const old_cwd = try statement_allocator.dupe(u8, shell_state.logical_cwd);
        defer statement_allocator.free(old_cwd);
        try command_outcome.applyToShellState(shell_state, .{ .record_exit_control_flow = true });
        if (!evaluator.directory_change_event_observed) {
            try appendDirectoryChangeEventOutcome(
                allocator,
                evaluator,
                output_frame,
                shell_state,
                eval_context,
                old_cwd,
                extension_handlers,
            );
        }
        try configureRuntimeTrapMutations(evaluator, shell_state.*, command_outcome.state_delta);
        try appendPendingRuntimeTrapOutcome(
            output_frame,
            &status,
            &control_flow,
            evaluator,
            shell_state,
            eval_context,
            source_resolver.resolver(),
        );
        if (control_flow != .normal or body_failed) break;
    }

    control_flow.validate();
    var final_status = control_flow.status(status);
    if (run_exit_trap) try appendSemanticExitTrap(
        output_frame,
        &final_status,
        evaluator,
        shell_state,
        eval_context,
        source_resolver.resolver(),
    );
    const runner_output = try output_frame.finish();
    return .{ .output = .{
        .allocator = allocator,
        .status = final_status,
        .stdout = runner_output.stdout,
        .stderr = runner_output.stderr,
    } };
}

fn appendDirectoryChangeEventOutcome(
    allocator: std.mem.Allocator,
    evaluator: *shell.eval.Evaluator,
    output_frame: *shell.eval.RunnerOutputFrame,
    shell_state: *shell.ShellState,
    eval_context: shell.EvalContext,
    old_cwd: []const u8,
    extension_handlers: ExtensionHandlers,
) !void {
    if (!eval_context.interactive or eval_context.target != .current_shell) return;
    const io = evaluator.io orelse return;
    const new_cwd = shell_state.logical_cwd;
    if (old_cwd.len == 0 or new_cwd.len == 0 or std.mem.eql(u8, old_cwd, new_cwd)) return;

    const calls = try shell.event.orderedHookCalls(allocator, shell_state.event_hooks.items, .directory_change);
    defer shell.event.freeHookCalls(allocator, calls);
    if (calls.len == 0) return;

    const owned_new_cwd = try allocator.dupe(u8, new_cwd);
    defer allocator.free(owned_new_cwd);
    const visible_status = shell_state.last_status;
    const visible_pipeline_statuses = try allocator.dupe(shell.ExitStatus, shell_state.last_pipeline_statuses.items);
    defer allocator.free(visible_pipeline_statuses);
    errdefer shell_state.last_status = visible_status;

    for (calls) |call| {
        try restoreEventVisibleStatus(shell_state, visible_status, visible_pipeline_statuses);
        if (shell_state.getFunction(call.function_name) == null) {
            const message = try std.fmt.allocPrint(
                allocator,
                "event: {s}: function not found\n",
                .{call.function_name},
            );
            defer allocator.free(message);
            const write_result = try output_frame.writeOutcome("", message);
            applyOutputWriteResultToShellState(shell_state, write_result);
            continue;
        }
        const assignments = eventHookContextAssignments(.directory_change, call);
        var result = try runHiddenShellStateCommandWithExtensionHandlersApplyOptionsAndAssignments(
            allocator,
            io,
            shell_state,
            &.{ call.function_name, old_cwd, owned_new_cwd },
            &assignments,
            evaluator.arg_zero,
            evaluator.features,
            .capture,
            extension_handlers,
            .{ .record_exit_control_flow = true },
            1,
        );
        defer result.deinit();
        const write_result = try output_frame.writeOutcome(result.stdout, result.stderr);
        applyOutputWriteResultToShellState(shell_state, write_result);
        try restoreEventVisibleStatus(shell_state, visible_status, visible_pipeline_statuses);
        if (shell_state.pending_exit != null) break;
    }
    try restoreEventVisibleStatus(shell_state, visible_status, visible_pipeline_statuses);
}

fn restoreEventVisibleStatus(
    shell_state: *shell.ShellState,
    visible_status: shell.ExitStatus,
    visible_pipeline_statuses: []const shell.ExitStatus,
) !void {
    shell_state.last_status = visible_status;
    try shell_state.setLastPipelineStatuses(visible_pipeline_statuses);
}

fn applyOutputWriteResultToShellState(
    shell_state: *shell.ShellState,
    write_result: shell.eval.RunnerOutputWriteResult,
) void {
    if (write_result.stdout_failed or write_result.stderr_failed) shell_state.last_status = 1;
}

fn eventHookContextAssignments(
    event_name: shell.EventName,
    call: shell.event.HookCall,
) [2]shell.command_plan.Assignment {
    return .{
        .{ .name = "RUSH_EVENT", .value = event_name.text() },
        .{ .name = "RUSH_EVENT_HOOK", .value = call.name },
    };
}

fn semanticNoexecSuppressesStatement(shell_state: shell.ShellState, eval_context: shell.EvalContext) bool {
    shell_state.validate();
    eval_context.validate();
    return shell_state.options.noexec and !eval_context.interactive;
}

const SourceLineIndex = struct {
    newline_offsets: []usize,

    fn init(allocator: std.mem.Allocator, source: []const u8) !SourceLineIndex {
        var offsets: std.ArrayList(usize) = .empty;
        errdefer offsets.deinit(allocator);
        for (source, 0..) |byte, index| {
            if (byte == '\n') try offsets.append(allocator, index);
        }
        return .{ .newline_offsets = try offsets.toOwnedSlice(allocator) };
    }

    fn deinit(self: SourceLineIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.newline_offsets);
    }

    fn lineIndex(self: SourceLineIndex, offset: usize) usize {
        var low: usize = 0;
        var high: usize = self.newline_offsets.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.newline_offsets[mid] < offset) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }
};

fn semanticSourceLine(source: []const u8, offset: usize) usize {
    std.debug.assert(offset <= source.len);
    var line: usize = 0;
    for (source[0..offset]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn bashAssignmentErrorAbortsSourceLine(
    features: compat.Features,
    statement_script: []const u8,
    command_outcome: shell.CommandOutcome,
) bool {
    command_outcome.validate();
    if (!features.isBash()) return false;
    if (std.mem.indexOfScalar(u8, statement_script, '=') == null) return false;
    if (command_outcome.status != 1 or command_outcome.effectiveControlFlow() != .normal) return false;
    for (command_outcome.diagnostics.items) |diagnostic| {
        if (std.mem.endsWith(u8, diagnostic.message, ": readonly variable")) return true;
        if (std.mem.indexOf(u8, diagnostic.message, "expansion error: arithmetic:") != null) return true;
    }
    return std.mem.endsWith(u8, command_outcome.stderr.items, ": readonly variable\n") or
        std.mem.indexOf(u8, command_outcome.stderr.items, "expansion error: arithmetic:") != null;
}

fn configureRuntimeTrapMutations(
    evaluator: *shell.eval.Evaluator,
    shell_state: shell.ShellState,
    state_delta: shell.StateDelta,
) !void {
    shell_state.validate();
    if (!state_delta.target.allowsShellStateCommit()) return;

    for (state_delta.trap_mutations.items) |mutation| {
        const signal = shell.TrapSignal.fromName(mutation.name) orelse continue;
        if (!signal.isRuntimeSignal()) continue;
        try shell.eval.configureRuntimeTrapSignal(evaluator, shell_state, signal);
    }
}

fn appendPendingRuntimeTrapOutcome(
    output_frame: *shell.eval.RunnerOutputFrame,
    status: *shell.ExitStatus,
    control_flow: *shell.ControlFlow,
    evaluator: *shell.eval.Evaluator,
    shell_state: *shell.ShellState,
    eval_context: shell.EvalContext,
    resolver: shell.TrapActionResolver,
) !void {
    shell_state.validate();
    eval_context.validate();
    control_flow.validate();

    if (try shell.eval.observeRuntimeSignal(evaluator, shell_state, eval_context)) |observed| {
        var observation = observed;
        defer observation.deinit();
        try observation.command_outcome.applyToShellState(shell_state, .{ .record_exit_control_flow = true });
        status.* = observation.command_outcome.status;
        control_flow.* = observation.command_outcome.effectiveControlFlow();
        if (control_flow.* != .normal) return;
    }

    var trap_outcome = (try shell.eval.executePendingTraps(
        evaluator,
        shell_state,
        eval_context,
        resolver,
    )) orelse return;
    defer trap_outcome.deinit();
    _ = try output_frame.writeOutcome(
        trap_outcome.stdout.items,
        trap_outcome.stderr.items,
    );
    status.* = trap_outcome.status;
    control_flow.* = trap_outcome.effectiveControlFlow();
    try trap_outcome.applyToShellState(shell_state, .{ .record_exit_control_flow = true });
}

const SemanticBackgroundPipelinePlan = struct {
    plan: shell.PipelinePlan,
    allocated_stages: []shell.PipelineStagePlan = &.{},

    fn deinit(self: *SemanticBackgroundPipelinePlan, allocator: std.mem.Allocator) void {
        if (self.allocated_stages.len != 0) allocator.free(self.allocated_stages);
        self.* = undefined;
    }
};

fn semanticBackgroundPipelinePlan(
    allocator: std.mem.Allocator,
    body: shell.TrapActionBody,
) !?SemanticBackgroundPipelinePlan {
    body.validate();
    return switch (body) {
        .simple => |plan| try semanticBackgroundSingleStagePlan(allocator, plan),
        .compound => |plan| try semanticBackgroundSingleCompoundStagePlan(allocator, plan),
        .pipeline => |plan| semanticBackgroundPipelineFromPipeline(plan),
        .owned => |owned| switch (owned.body) {
            .simple => |plan| try semanticBackgroundSingleStagePlan(allocator, plan),
            .compound => |plan| try semanticBackgroundSingleCompoundStagePlan(allocator, plan),
            .pipeline => |plan| semanticBackgroundPipelineFromPipeline(plan),
            .failure => null,
        },
        .failure => null,
    };
}

fn semanticBackgroundSingleStagePlan(
    allocator: std.mem.Allocator,
    plan: shell.CommandPlan,
) !SemanticBackgroundPipelinePlan {
    plan.validate();
    const stages = try allocator.alloc(shell.PipelineStagePlan, 1);
    errdefer allocator.free(stages);
    stages[0] = .{ .simple = plan };
    return .{
        .plan = shell.PipelinePlan.init(stages, .{ .background = .background }),
        .allocated_stages = stages,
    };
}

fn semanticBackgroundSingleCompoundStagePlan(
    allocator: std.mem.Allocator,
    plan: shell.CompoundCommandPlan,
) !SemanticBackgroundPipelinePlan {
    plan.validate();
    const stages = try allocator.alloc(shell.PipelineStagePlan, 1);
    errdefer allocator.free(stages);
    stages[0] = .{ .compound = plan };
    return .{
        .plan = shell.PipelinePlan.init(stages, .{ .background = .background }),
        .allocated_stages = stages,
    };
}

fn semanticBackgroundPipelineFromPipeline(plan: shell.PipelinePlan) SemanticBackgroundPipelinePlan {
    plan.validate();
    return .{ .plan = shell.PipelinePlan.init(plan.stages, .{
        .negated = plan.negated,
        .status_rule = plan.status_rule,
        .background = .background,
    }) };
}

fn appendSemanticExitTrap(
    output_frame: *shell.eval.RunnerOutputFrame,
    status: *shell.ExitStatus,
    evaluator: *shell.eval.Evaluator,
    shell_state: *shell.ShellState,
    eval_context: shell.EvalContext,
    resolver: shell.TrapActionResolver,
) !void {
    if (shell_state.getTrapForSignal(.EXIT) == null) return;
    if (evaluator.io != null and evaluator.external_stdio == .inherit) {
        _ = try output_frame.flushPendingToInheritedDescriptors();
    }
    shell_state.last_status = status.*;
    try shell_state.appendPendingTrap(.EXIT);
    var trap_outcome = (try shell.eval.executePendingTraps(
        evaluator,
        shell_state,
        eval_context,
        resolver,
    )) orelse return;
    defer trap_outcome.deinit();
    _ = try output_frame.writeOutcome(
        trap_outcome.stdout.items,
        trap_outcome.stderr.items,
    );
    status.* = trap_outcome.status;
    try trap_outcome.applyToShellState(shell_state, .{});
}

fn semanticScriptNeedsAliasTiming(script: []const u8) bool {
    var index: usize = 0;
    while (index < script.len) {
        if (script[index] == '.' and isSemanticAliasTokenBoundary(script, index, index + 1)) return true;
        while (index < script.len and !isSemanticAliasTokenByte(script[index])) index += 1;
        const start = index;
        while (index < script.len and isSemanticAliasTokenByte(script[index])) index += 1;
        const word = script[start..index];
        if (std.mem.eql(u8, word, "alias") or
            std.mem.eql(u8, word, "unalias") or
            std.mem.eql(u8, word, "eval") or
            std.mem.eql(u8, word, "source"))
        {
            return true;
        }
    }
    return false;
}

fn semanticCommandStringNeedsChunkedExecution(script: []const u8, command_string_line_diagnostics: bool) bool {
    return semanticScriptNeedsAliasTiming(script) or
        (command_string_line_diagnostics and std.mem.indexOfScalar(u8, script, '\n') != null);
}

fn isSemanticAliasTokenBoundary(script: []const u8, start: usize, end: usize) bool {
    std.debug.assert(start < end);
    std.debug.assert(end <= script.len);
    const before = start == 0 or !isSemanticAliasTokenByte(script[start - 1]);
    const after = end == script.len or !isSemanticAliasTokenByte(script[end]);
    return before and after;
}

fn isSemanticAliasTokenByte(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '_';
}

fn skipSemanticChunkSeparators(script: []const u8, start: usize) usize {
    var index = start;
    while (index < script.len and (script[index] == ' ' or
        script[index] == '\t' or
        script[index] == '\r' or
        script[index] == '\n' or
        script[index] == ';')) index += 1;
    return index;
}

fn semanticLineEnd(script: []const u8, start: usize) usize {
    var index = start;
    while (index < script.len) {
        if (script[index] == '\\' and index + 1 < script.len and script[index + 1] == '\n') {
            index += 2;
            continue;
        }
        if (script[index] == '\n') {
            index += 1;
            break;
        }
        index += 1;
    }
    return index;
}

fn extendSemanticHereDocChunk(script: []const u8, start: usize, initial_end: usize) usize {
    var end = initial_end;
    var scan = start;
    while (scan + 1 < end) : (scan += 1) {
        if (script[scan] != '<' or script[scan + 1] != '<') continue;
        var delimiter_start = scan + 2;
        if (delimiter_start < end and script[delimiter_start] == '-') delimiter_start += 1;
        while (delimiter_start < end and
            (script[delimiter_start] == ' ' or
                script[delimiter_start] == '\t')) delimiter_start += 1;
        var delimiter_end = delimiter_start;
        while (delimiter_end < end and !isSemanticHereDocDelimiterTerminator(script[delimiter_end])) delimiter_end += 1;
        const raw_delimiter = std.mem.trim(u8, script[delimiter_start..delimiter_end], "'\"");
        if (raw_delimiter.len == 0) continue;
        end = semanticHereDocBodyEnd(script, end, raw_delimiter);
    }
    return end;
}

fn isSemanticHereDocDelimiterTerminator(byte: u8) bool {
    return byte == ' ' or
        byte == '\t' or
        byte == '\r' or
        byte == '\n' or
        byte == ';' or
        byte == '|' or
        byte == '&' or
        byte == '<' or
        byte == '>';
}

fn semanticHereDocBodyEnd(script: []const u8, body_start: usize, delimiter: []const u8) usize {
    var line_start = body_start;
    while (line_start < script.len) {
        var line_end = line_start;
        while (line_end < script.len and script[line_end] != '\n') line_end += 1;
        const raw_line = script[line_start..line_end];
        const line = if (raw_line.len != 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        if (std.mem.eql(u8, line, delimiter)) return if (line_end < script.len) line_end + 1 else line_end;
        line_start = if (line_end < script.len) line_end + 1 else line_end;
    }
    return script.len;
}

fn semanticExpandAliases(
    allocator: std.mem.Allocator,
    source: []const u8,
    features: compat.Features,
    shell_state: *shell.ShellState,
) ![]const u8 {
    if (!shell_state.shopts.enabled(.expand_aliases)) return allocator.dupe(u8, source);
    return parser.expandAliases(allocator, source, .{
        .features = features.withStrictDiagnostics(),
        .context = shell_state,
        .lookup = lookupSemanticAlias,
        .collect_command_substitution_nodes = false,
    });
}

fn configureCompatibilityShopts(
    shell_state: *shell.ShellState,
    features: compat.Features,
    interactive: bool,
) void {
    if (features.isBash() and !interactive) shell_state.shopts.set(.expand_aliases, false);
}

fn lookupSemanticAlias(opaque_context: *anyopaque, name: []const u8) ?[]const u8 {
    if (!isSemanticAliasName(name)) return null;
    const shell_state: *shell.ShellState = @ptrCast(@alignCast(opaque_context));
    const alias = shell_state.getAlias(name) orelse return null;
    return alias.value;
}

fn isSemanticAliasName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphabetic(byte) or
            std.ascii.isDigit(byte) or
            byte == '!' or
            byte == '%' or
            byte == ',' or
            byte == '-' or
            byte == '@' or
            byte == '_')) return false;
    }
    return true;
}

fn syncSemanticStdinScriptOffset(file: ?std.Io.File, source_offset: usize, script: []const u8, offset: usize) void {
    const stdin_file = file orelse return;
    var adjusted_offset = source_offset + offset;
    if (offset < script.len and script[offset] == '\n') adjusted_offset += 1;
    const seek_offset: std.c.off_t = @intCast(adjusted_offset);
    _ = std.c.lseek(stdin_file.handle, seek_offset, std.c.SEEK.SET);
}

fn semanticStdinScriptConsumedStatement(file: ?std.Io.File, source_offset: usize, statement_start: usize) bool {
    const stdin_file = file orelse return false;
    const current = std.c.lseek(stdin_file.handle, 0, std.c.SEEK.CUR);
    if (current < 0) return false;
    return @as(u64, @intCast(current)) > source_offset + statement_start;
}

fn assertSemanticInteractiveOptions(script: []const u8, invocation: shell.InvocationContext) void {
    invocation.validate();
    std.debug.assert(invocation.interactive);
    std.debug.assert(invocation.arg_zero.len != 0);
    std.debug.assert(script.len == 0 or std.mem.indexOfScalar(u8, script, 0) == null);
}

fn assertSemanticStartupOptions(
    script: []const u8,
    invocation: shell.InvocationContext,
    positionals: []const []const u8,
) void {
    invocation.validate();
    std.debug.assert(!invocation.interactive);
    std.debug.assert(invocation.arg_zero.len != 0);
    std.debug.assert(script.len == 0 or std.mem.indexOfScalar(u8, script, 0) == null);
    for (positionals) |arg| std.debug.assert(std.mem.indexOfScalar(u8, arg, 0) == null);
}

fn semanticUnsupported(allocator: std.mem.Allocator, message: []const u8) !SemanticInvocationExecution {
    std.debug.assert(message.len != 0);
    return .{ .unsupported = try allocator.dupe(u8, message) };
}

fn semanticEnvironmentSupported(environ_map: *const std.process.Environ.Map) bool {
    var iterator = environ_map.iterator();
    while (iterator.next()) |entry| {
        if (!shell.startup.isValidVariableName(entry.key_ptr.*)) return false;
        if (std.mem.indexOfScalar(u8, entry.value_ptr.*, 0) != null) return false;
    }
    return true;
}

fn semanticInteractiveProgramUnsupported(shell_state: shell.ShellState, program: ir.Program) ?[]const u8 {
    shell_state.validate();
    if (shell_state.options.nounset and semanticProgramUsesShellExpansion(program))
        return "semantic interactive executor does not yet preserve nounset expansion diagnostics";

    for (program.commands) |command| {
        if (command.argv.len == 0) continue;
        const root = command.argv[0];
        if (default_builtins.lookup(root.text) != null and !semanticInteractiveBuiltinRootAllowed(root.text))
            return "semantic interactive executor reports unsupported builtins as diagnostics";
        if (shell_state.functions.count() != 0) {
            if (wordMayUseShellExpansion(root.raw))
                return "semantic interactive executor does not yet preserve dynamic function lookup";
        }
    }
    return null;
}

fn semanticInteractiveBuiltinRootAllowed(name: []const u8) bool {
    const definition = default_builtins.lookup(name) orelse return false;
    if (definition.semantic_class == .unsupported) return false;
    if (definition.semantic_class == .control_flow and
        !std.mem.eql(u8, name, "exit") and
        !std.mem.eql(u8, name, "break") and
        !std.mem.eql(u8, name, "continue"))
    {
        return false;
    }
    if (std.mem.eql(u8, name, "local") or std.mem.eql(u8, name, "read")) return false;
    return true;
}

fn semanticProgramUsesShellExpansion(program: ir.Program) bool {
    for (program.commands) |command| {
        for (command.argv) |word| if (wordMayUseShellExpansion(word.raw)) return true;
        for (command.assignments) |word| if (wordMayUseShellExpansion(word.raw)) return true;
        for (command.redirections) |redirection| {
            if (redirection.io_number) |word| if (wordMayUseShellExpansion(word.raw)) return true;
            if (redirection.target) |word| if (wordMayUseShellExpansion(word.raw)) return true;
            if (redirection.here_doc) |body| if (wordMayUseShellExpansion(body)) return true;
        }
    }
    return false;
}

fn wordMayUseShellExpansion(raw: []const u8) bool {
    return std.mem.indexOfScalar(u8, raw, '$') != null or std.mem.indexOfScalar(u8, raw, '`') != null;
}

fn semanticPreflightUnsupported(
    allocator: std.mem.Allocator,
    program: ir.Program,
    features: compat.Features,
) !?[]const u8 {
    for (program.statements, 0..) |statement, index| {
        if (semanticAsyncStatementPreflightUnsupported(program, statement, index)) |message| return message;
    }
    for (program.function_definitions) |definition| {
        if (try semanticFunctionDefinitionPreflightUnsupported(allocator, definition, features)) |message|
            return message;
    }
    if (program.bash_test_commands.len != 0) return "semantic executor does not yet lower bash [[ ]] commands";
    return null;
}

fn semanticFunctionDefinitionPreflightUnsupported(
    allocator: std.mem.Allocator,
    definition: ir.FunctionDefinition,
    features: compat.Features,
) !?[]const u8 {
    var parsed = try parser.parse(allocator, definition.body, .{
        .features = features.withStrictDiagnostics(),
        .collect_command_substitution_nodes = false,
    });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0)
        return "semantic executor does not yet support parser-rejected function bodies";

    var body_program = try ir.lowerSimpleCommands(allocator, parsed);
    defer body_program.deinit();
    return semanticFunctionBodyProgramUnsupported(allocator, body_program, features);
}

fn semanticFunctionBodyProgramUnsupported(
    allocator: std.mem.Allocator,
    program: ir.Program,
    features: compat.Features,
) !?[]const u8 {
    for (program.statements, 0..) |statement, index| {
        if (semanticAsyncStatementPreflightUnsupported(program, statement, index)) |message| return message;
        if (statement.kind == .function_definition and statement.op_before != .sequence)
            return "semantic executor does not yet support dynamically guarded function definitions";
    }
    for (program.function_definitions) |definition| {
        if (try semanticFunctionDefinitionPreflightUnsupported(allocator, definition, features)) |message|
            return message;
    }
    if (program.bash_test_commands.len != 0) return "semantic executor does not yet lower bash [[ ]] commands";
    return null;
}

fn semanticAsyncStatementPreflightUnsupported(program: ir.Program, statement: ir.Statement, index: usize) ?[]const u8 {
    std.debug.assert(index < program.statements.len);
    if (!statement.async_after) return null;
    // ziglint-ignore: Z024 user-visible diagnostic; wrapping would inject a newline into stderr
    const unsupported_background = "semantic executor does not yet support this background statement shape";
    return switch (statement.kind) {
        .pipeline,
        .if_command,
        .loop_command,
        .for_command,
        .case_command,
        .brace_group,
        .subshell,
        => null,
        .function_definition, .bash_test_command => unsupported_background,
    };
}

fn semanticBodyUnsupportedMessage(body: shell.TrapActionBody) ?[]const u8 {
    body.validate();
    return switch (body) {
        .simple => |plan| semanticCommandUnsupportedMessage(plan),
        .compound => |plan| semanticCompoundUnsupportedMessage(plan),
        .pipeline => |plan| semanticPipelineUnsupportedMessage(plan),
        .owned => |owned| switch (owned.body) {
            .simple => |plan| semanticCommandUnsupportedMessage(plan),
            .compound => |plan| semanticCompoundUnsupportedMessage(plan),
            .pipeline => |plan| semanticPipelineUnsupportedMessage(plan),
            .failure => null,
        },
        .failure => null,
    };
}

fn semanticBodyIsStoppingFailure(body: shell.TrapActionBody, eval_context: shell.EvalContext) bool {
    body.validate();
    eval_context.validate();
    return switch (body) {
        .failure => |failure| semanticFailureStopsProgram(failure, eval_context),
        .owned => |owned| switch (owned.body) {
            .failure => |failure| semanticFailureStopsProgram(failure, eval_context),
            .simple, .compound, .pipeline => false,
        },
        .simple, .compound, .pipeline => false,
    };
}

fn semanticFailureStopsProgram(failure: shell.TrapActionFailure, eval_context: shell.EvalContext) bool {
    failure.validate();
    eval_context.validate();
    if (eval_context.interactive and failure.kind == .expansion_error) return false;
    if (eval_context.features.isBash() and
        failure.kind == .parse_error and
        failure.status == 1 and
        std.mem.endsWith(u8, failure.message, ": not a valid identifier"))
    {
        return false;
    }
    return !(eval_context.features.isBash() and
        failure.kind == .expansion_error and
        (failure.bash_arithmetic_expansion or
            failure.bash_arithmetic_assignment_only_expansion or
            failure.bash_parameter_assignment_expansion or
            std.mem.indexOf(u8, failure.message, "expansion error: arithmetic:") != null));
}

fn semanticBodyUsesInheritedExternal(body: shell.TrapActionBody) bool {
    body.validate();
    return switch (body) {
        .simple => |plan| semanticCommandUsesInheritedExternal(plan),
        .pipeline => false,
        .owned => |owned| switch (owned.body) {
            .simple => |plan| semanticCommandUsesInheritedExternal(plan),
            .pipeline => false,
            .compound, .failure => false,
        },
        .compound, .failure => false,
    };
}

fn semanticCommandUsesInheritedExternal(plan: shell.CommandPlan) bool {
    plan.validate();
    return plan.class() == .external;
}

const OutputWriteResult = shell.eval.RunnerOutputWriteResult;

fn runnerOutputMode(commit_exec_redirections: bool) shell.eval.RunnerOutputMode {
    return if (commit_exec_redirections) .live else .capture;
}

fn applyOutputWriteResult(command_outcome: *shell.CommandOutcome, result: OutputWriteResult) void {
    command_outcome.validate();
    if (!result.stdout_failed and !result.stderr_failed) return;
    if (command_outcome.effectiveControlFlow() != .normal) return;
    if (command_outcome.status != 0) return;
    command_outcome.status = 1;
    if (command_outcome.state_delta.last_status != null) command_outcome.state_delta.last_status = 1;
}

fn semanticPipelineUnsupportedMessage(plan: shell.PipelinePlan) ?[]const u8 {
    plan.validate();
    for (plan.stages) |stage| switch (stage) {
        .simple => |simple| if (semanticCommandUnsupportedMessage(simple)) |message|
            return message,
        .compound => |compound| if (semanticCompoundUnsupportedMessage(compound)) |message|
            return message,
    };
    return null;
}

fn semanticCompoundUnsupportedMessage(plan: shell.CompoundCommandPlan) ?[]const u8 {
    plan.validate();
    switch (plan.body) {
        .sequence, .brace_group, .subshell => |list| return semanticCommandListUnsupportedMessage(list),
        .and_or_list => |and_or| for (and_or.commands) |entry| {
            if (semanticCommandUnsupportedMessage(entry.command)) |message| return message;
        },
        .negation => |negation| return semanticCommandListUnsupportedMessage(negation.body),
        .if_clause => |if_plan| {
            for (if_plan.branches) |branch| {
                if (semanticCommandListUnsupportedMessage(branch.condition)) |message|
                    return message;
                if (semanticCommandListUnsupportedMessage(branch.body)) |message| return message;
            }
            return semanticCommandListUnsupportedMessage(if_plan.else_body);
        },
        .while_loop, .until_loop => |loop| {
            if (semanticCommandListUnsupportedMessage(loop.condition)) |message| return message;
            return semanticCommandListUnsupportedMessage(loop.body);
        },
        .for_loop => |for_plan| return semanticCommandListUnsupportedMessage(for_plan.body),
        .case_clause => |case_plan| for (case_plan.arms) |arm| {
            if (semanticCommandListUnsupportedMessage(arm.body)) |message| return message;
        },
    }
    return null;
}

fn semanticCommandListUnsupportedMessage(list: shell.StatementList) ?[]const u8 {
    list.validate();
    for (list.statements) |entry| {
        switch (entry.plan) {
            .simple => |plan| if (semanticCommandUnsupportedMessage(plan)) |message|
                return message,
            .compound => |plan| if (semanticCompoundUnsupportedMessage(plan)) |message|
                return message,
            .pipeline => |plan| if (semanticPipelineUnsupportedMessage(plan)) |message|
                return message,
            .source, .ir_source => {},
        }
    }
    return null;
}

fn semanticCommandUnsupportedMessage(plan: shell.CommandPlan) ?[]const u8 {
    plan.validate();
    return switch (plan.classification) {
        .regular_builtin, .special_builtin => |definition| blk: {
            if (definition.semantic_class == .unsupported)
                break :blk "semantic evaluator does not yet implement this builtin";
            break :blk null;
        },
        .empty, .assignment_only => null,
        .function_definition => |definition| if (definition.source_body == null)
            "semantic evaluator does not yet receive owned production function definitions"
        else
            null,
        .function, .external, .not_found => null,
    };
}

fn evaluateSemanticComparisonBody(
    evaluator: *shell.eval.Evaluator,
    shell_state: *shell.ShellState,
    eval_context: shell.EvalContext,
    body: shell.TrapActionBody,
    frame: *shell.ExecutionFrame,
) shell.eval.EvalError!shell.CommandOutcome {
    body.validate();
    eval_context.validate();
    frame.validate();
    return shell.eval.evaluateTrapActionBodyInFrame(evaluator, shell_state, eval_context, body, frame);
}

pub const CommandResult = struct {
    allocator: std.mem.Allocator,
    status: shell.ExitStatus,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn empty(allocator: std.mem.Allocator, status: shell.ExitStatus) !CommandResult {
    const stdout = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = try allocator.alloc(u8, 0);
    return .{ .allocator = allocator, .status = status, .stdout = stdout, .stderr = stderr };
}

pub fn unsupported(allocator: std.mem.Allocator, message: []const u8) !CommandResult {
    std.debug.assert(message.len != 0);
    const stdout = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = try std.fmt.allocPrint(allocator, "{s}\n", .{message});
    return .{ .allocator = allocator, .status = 2, .stdout = stdout, .stderr = stderr };
}

pub fn parseDiagnostics(
    allocator: std.mem.Allocator,
    script: []const u8,
    diagnostics: []const parser.Diagnostic,
) !CommandResult {
    return parseDiagnosticsWithOptions(allocator, script, diagnostics, .{});
}

const ParseDiagnosticOptions = struct {
    source_path: ?[]const u8 = null,
    line_offset: usize = 0,
    line_number_without_path: bool = false,
};

fn parseDiagnosticsWithOptions(
    allocator: std.mem.Allocator,
    script: []const u8,
    diagnostics: []const parser.Diagnostic,
    options: ParseDiagnosticOptions,
) !CommandResult {
    var stderr_buffer: std.ArrayList(u8) = .empty;
    defer stderr_buffer.deinit(allocator);

    for (diagnostics) |diagnostic| {
        const line = if (options.source_path) |source_path|
            try std.fmt.allocPrint(allocator, "rush: {s}:{d}: {s}: {s}\n", .{
                source_path,
                options.line_offset + diagnosticLineNumber(script, diagnostic.span.start),
                @tagName(diagnostic.kind),
                diagnostic.message,
            })
        else if (options.line_number_without_path)
            try std.fmt.allocPrint(allocator, "rush: {d}: {s}: {s}\n", .{
                options.line_offset + diagnosticLineNumber(script, diagnostic.span.start),
                @tagName(diagnostic.kind),
                diagnostic.message,
            })
        else
            try std.fmt.allocPrint(allocator, "rush: {s}: {s}\n", .{
                @tagName(diagnostic.kind),
                diagnostic.message,
            });
        defer allocator.free(line);
        try stderr_buffer.appendSlice(allocator, line);
        try appendDiagnosticSource(allocator, &stderr_buffer, script, diagnostic.span);
    }

    const stdout = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = try stderr_buffer.toOwnedSlice(allocator);
    return .{ .allocator = allocator, .status = 2, .stdout = stdout, .stderr = stderr };
}

fn parseDiagnosticsAfterChunkedOutput(
    allocator: std.mem.Allocator,
    output_frame: *shell.eval.RunnerOutputFrame,
    script: []const u8,
    diagnostics: []const parser.Diagnostic,
    options: ParseDiagnosticOptions,
) !CommandResult {
    const prior_output = try output_frame.finish();
    defer allocator.free(prior_output.stdout);
    defer allocator.free(prior_output.stderr);

    var diagnostic_output = try parseDiagnosticsWithOptions(allocator, script, diagnostics, options);
    defer diagnostic_output.deinit();

    const stdout = try concatOutput(allocator, prior_output.stdout, diagnostic_output.stdout);
    errdefer allocator.free(stdout);
    const stderr = try concatOutput(allocator, prior_output.stderr, diagnostic_output.stderr);
    return .{ .allocator = allocator, .status = diagnostic_output.status, .stdout = stdout, .stderr = stderr };
}

fn concatOutput(allocator: std.mem.Allocator, first: []const u8, second: []const u8) ![]u8 {
    const joined = try allocator.alloc(u8, first.len + second.len);
    @memcpy(joined[0..first.len], first);
    @memcpy(joined[first.len..], second);
    return joined;
}

fn appendDiagnosticSource(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    source: []const u8,
    span: parser.Span,
) !void {
    const line_start = diagnosticLineStart(source, span.start);
    const line_end = diagnosticLineEnd(source, span.start);
    const line = source[line_start..line_end];
    const caret_start = span.start - line_start;
    const caret_end = @max(caret_start + 1, @min(span.end, line_end) - line_start);

    try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "  ");
    try out.appendNTimes(allocator, ' ', caret_start);
    try out.appendNTimes(allocator, '^', caret_end - caret_start);
    try out.append(allocator, '\n');
}

fn diagnosticLineStart(source: []const u8, offset: usize) usize {
    var index = @min(offset, source.len);
    while (index > 0 and source[index - 1] != '\n') index -= 1;
    return index;
}

fn diagnosticLineNumber(source: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (source[0..@min(offset, source.len)]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn diagnosticLineEnd(source: []const u8, offset: usize) usize {
    var index = @min(offset, source.len);
    while (index < source.len and source[index] != '\n') index += 1;
    return index;
}

extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;

const StdinGuard = struct {
    saved_fd: c_int,

    fn replaceWith(file: std.Io.File) !StdinGuard {
        const saved_fd = dup(std.Io.File.stdin().handle);
        if (saved_fd < 0) return error.SkipZigTest;
        errdefer _ = close(saved_fd);
        if (dup2(file.handle, std.Io.File.stdin().handle) < 0) return error.SkipZigTest;
        return .{ .saved_fd = saved_fd };
    }

    fn restore(self: *StdinGuard) void {
        _ = dup2(self.saved_fd, std.Io.File.stdin().handle);
        _ = close(self.saved_fd);
        self.* = undefined;
    }
};

fn runInvocationForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: cli_invocation.ShellInvocation,
    environ_map: ?*const std.process.Environ.Map,
    external_stdio: runtime.ExternalStdio,
    login_shell: bool,
) !CommandResult {
    _ = login_shell;
    var loaded_script = try loadInvocationScript(allocator, io, invocation, external_stdio);
    defer loaded_script.deinit();
    return runCommandStringWithEnvironment(
        allocator,
        io,
        loaded_script.script,
        loaded_script.options,
        environ_map,
        invocation.positionals,
        invocation.shell_options,
    );
}

fn runInvocationWithPipeStdin(invocation: cli_invocation.ShellInvocation, stdin: []const u8) !CommandResult {
    var adapter = runtime.posix.Adapter.init(std.testing.io);
    const pipe = try adapter.fdPort().pipe(.{});
    const read_file: std.Io.File = .{ .handle = pipe.read, .flags = .{ .nonblocking = false } };
    const write_file: std.Io.File = .{ .handle = pipe.write, .flags = .{ .nonblocking = false } };

    defer read_file.close(std.testing.io);
    var write_open = true;
    defer if (write_open) write_file.close(std.testing.io);

    try writeFileAll(write_file, stdin);
    write_file.close(std.testing.io);
    write_open = false;

    var guard = try StdinGuard.replaceWith(read_file);
    defer guard.restore();
    return runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
}

fn runInvocationWithFileStdin(invocation: cli_invocation.ShellInvocation, path: []const u8) !CommandResult {
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var guard = try StdinGuard.replaceWith(file);
    defer guard.restore();
    return runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
}

fn writeFileAll(file: std.Io.File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "command string operands set the command name and positional parameters" {
    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo $0:$#:$1:$2; echo \"$@\"",
        .{ .io = std.testing.io, .arg_zero = "myname" },
        null,
        &.{ "a", "b c" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("myname:2:a:b c\na b c\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-interactive Rush mode autoloads user functions" {
    const root = "rush-test-noninteractive-function-autoload";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/functions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/rush/functions/hello.rush",
        .data =
        \\printf 'autoload noise\n'
        \\hello() {
        \\  printf 'hello %s\n' "$1"
        \\}
        \\
        ,
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "hello rush",
        .{ .io = std.testing.io, .features = .bash(), .arg_zero = "rush" },
        &env,
        &.{},
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hello rush\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-interactive Rush mode autoloads shipped path helpers" {
    const root = "rush-test-path-functions";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/bin");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/old");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/tools");

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "share");
    try env.put("PATH", "");

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        \\
        \\PATH='rush-test-path-functions/bin:rush-test-path-functions/old'
        \\path_prepend rush-test-path-functions/tools rush-test-path-functions/missing rush-test-path-functions/bin
        \\printf 'pre=%s\n' "$PATH"
        \\path_append rush-test-path-functions/bin rush-test-path-functions/tools
        \\printf 'app=%s\n' "$PATH"
        \\path_remove rush-test-path-functions/tools rush-test-path-functions/missing
        \\printf 'rm=%s\n' "$PATH"
        \\PATH=
        \\path_add rush-test-path-functions/bin rush-test-path-functions/tools
        \\printf 'add=%s\n' "$PATH"
    ,
        .{ .io = std.testing.io, .features = .bash(), .arg_zero = "rush" },
        &env,
        &.{},
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings(
        \\pre=rush-test-path-functions/tools:rush-test-path-functions/bin:rush-test-path-functions/old
        \\app=rush-test-path-functions/old:rush-test-path-functions/bin:rush-test-path-functions/tools
        \\rm=rush-test-path-functions/old:rush-test-path-functions/bin
        \\add=rush-test-path-functions/bin:rush-test-path-functions/tools
        \\
    , result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-interactive unset function suppresses future autoload" {
    const root = "rush-test-unset-function-autoload";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/functions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/rush/functions/hello.rush",
        .data =
        \\hello() {
        \\  printf 'autoloaded\n'
        \\}
        \\
        ,
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);
    try env.put("PATH", "");

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        \\
        \\unset -f hello
        \\if hello; then
        \\  printf 'unexpected\n'
        \\else
        \\  printf 'suppressed:%s\n' "$?"
        \\fi
        \\hello() { printf 'manual\n'; }
        \\hello
    ,
        .{ .io = std.testing.io, .features = .bash(), .arg_zero = "rush" },
        &env,
        &.{},
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("suppressed:127\nmanual\n", result.stdout);
}

test "non-interactive POSIX mode does not autoload user functions" {
    const root = "rush-test-posix-function-autoload";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/functions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/rush/functions/hello.rush",
        .data =
        \\hello() {
        \\  printf 'hello %s\n' "$1"
        \\}
        \\
        ,
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "hello rush",
        .{ .io = std.testing.io, .features = .posix(), .arg_zero = "rush" },
        &env,
        &.{},
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
}

test "command string invocation preserves trailing EOF backslash literal" {
    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo a\\",
        .{ .io = std.testing.io, .arg_zero = "rush" },
        null,
        &.{},
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("a\\\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "script file invocation sets command name and positional parameters" {
    const path = "rush-script-invocation-test.rush";
    try deleteFileIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\#!/usr/bin/env rush
        \\# first-line comments and shebangs are shell comments
        \\shopt -s expand_aliases
        \\alias say='echo'
        \\read value <<EOF
        \\$2
        \\EOF
        \\say "$0:$#:$1:$value"
    });

    const invocation = cli_invocation.parse(&.{ "rush", path, "arg one", "two words" }) orelse
        return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("rush-script-invocation-test.rush:2:arg one:two words\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "script file invocation preserves trailing EOF backslash without final newline" {
    const path = "rush-script-trailing-backslash-test.rush";
    try deleteFileIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "echo a\\" });

    const invocation = cli_invocation.parse(&.{ "rush", path }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("a\\\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "script file incomplete parse diagnostics include path and line" {
    const path = "rush-script-incomplete-diagnostic-test.rush";
    try deleteFileIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\echo before
        \\if true; then
        \\  echo after
    });

    const invocation = cli_invocation.parse(&.{ "rush", path }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "rush: {s}:2: incomplete_input: missing fi to close if command",
        .{path},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "  if true; then\n  ^^^^^^^^^^^^^\n") != null);
}

test "script file unterminated lexer diagnostics do not cascade" {
    const Case = struct {
        path: []const u8,
        data: []const u8,
        message: []const u8,
    };
    const cases = [_]Case{
        .{
            .path = "rush-script-parameter-diagnostic-test.rush",
            .data =
            \\echo before
            \\if true; then
            \\  echo ${foo
            ,
            .message = "unterminated parameter expansion",
        },
        .{
            .path = "rush-script-single-quote-diagnostic-test.rush",
            .data =
            \\echo before
            \\if true; then
            \\  echo 'foo
            ,
            .message = "unterminated single quote",
        },
        .{
            .path = "rush-script-command-substitution-diagnostic-test.rush",
            .data =
            \\echo before
            \\if true; then
            \\  echo $(foo
            ,
            .message = "unterminated command substitution",
        },
        .{
            .path = "rush-script-arithmetic-diagnostic-test.rush",
            .data =
            \\echo before
            \\if true; then
            \\  echo $((1 + 2
            ,
            .message = "unterminated arithmetic expansion",
        },
    };

    for (cases) |case| {
        try deleteFileIfExists(std.testing.io, case.path);
        defer std.Io.Dir.cwd().deleteFile(std.testing.io, case.path) catch {};
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = case.path, .data = case.data });

        const invocation = cli_invocation.parse(&.{ "rush", case.path }) orelse return error.ExpectedInvocation;
        var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
        defer result.deinit();

        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "rush: {s}:3: incomplete_input: {s}",
            .{ case.path, case.message },
        );
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, expected) != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "missing fi to close if command") == null);
    }
}

test "script file parse diagnostics include path and line" {
    const path = "rush-script-parse-diagnostic-test.rush";
    try deleteFileIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\echo before
        \\echo after 2>
    });

    const invocation = cli_invocation.parse(&.{ "rush", path }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "rush: {s}:2: parse_error: missing redirection target",
        .{path},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "  echo after 2>\n") != null);
}

test "multiline command string parse diagnostics include line without path" {
    const invocation = cli_invocation.parse(&.{
        "rush", "-c",
        \\echo before
        \\echo after 2>
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("before\n", result.stdout);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.stderr,
        "rush: 2: parse_error: missing redirection target\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "rush: rush:") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "  echo after 2>\n") != null);
}

test "multiline command string executes complete command before later unterminated quote" {
    const invocation = cli_invocation.parse(&.{
        "rush", "-c",
        \\printf hi
        \\'unterminated
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("hi", result.stdout);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.stderr,
        "rush: 2: incomplete_input: unterminated single quote\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "  'unterminated\n") != null);
}

test "single-line command string parse diagnostics omit redundant line" {
    const invocation = cli_invocation.parse(&.{ "rush", "-c", "echo after 2>" }) orelse
        return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.stderr,
        "rush: parse_error: missing redirection target\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "rush: 1: parse_error") == null);
}

test "multiline command string command-not-found diagnostics include line without path" {
    const Case = struct {
        script: []const u8,
        stdout: []const u8,
        stderr: []const u8,
    };
    const cases = [_]Case{
        .{
            .script =
            \\echo one
            \\echo two
            \\no_such_cmd
            \\echo after
            ,
            .stdout = "one\ntwo\nafter\n",
            .stderr = "3: no_such_cmd: command not found\n",
        },
        .{
            .script =
            \\echo top
            \\if true; then
            \\  echo in
            \\  no_such_if_cmd
            \\fi
            \\echo after
            ,
            .stdout = "top\nin\nafter\n",
            .stderr = "4: no_such_if_cmd: command not found\n",
        },
    };

    for (cases) |case| {
        const invocation = cli_invocation.parse(&.{ "rush", "-c", case.script }) orelse return error.ExpectedInvocation;
        var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
        defer result.deinit();

        try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
        try std.testing.expectEqualStrings(case.stdout, result.stdout);
        try std.testing.expectEqualStrings(case.stderr, result.stderr);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "rush:") == null);
    }
}

test "single-line command string command-not-found diagnostics omit redundant line" {
    const invocation = cli_invocation.parse(&.{ "rush", "-c", "no_such_cmd" }) orelse
        return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("no_such_cmd: command not found\n", result.stderr);
}

test "script file parameter expansion diagnostics in for and case words include path and line" {
    const Case = struct {
        path: []const u8,
        data: []const u8,
        diagnostic: []const u8,
    };
    const cases = [_]Case{
        .{
            .path = "rush-script-for-word-parameter-diagnostic-test.rush",
            .data =
            \\echo before
            \\unset x
            \\for i in ${x:?forbad}; do echo "$i"; done
            \\echo after
            ,
            .diagnostic = "expansion error: x: forbad",
        },
        .{
            .path = "rush-script-case-word-parameter-diagnostic-test.rush",
            .data =
            \\echo before
            \\unset x
            \\case ${x:?casewordbad} in *) echo ok;; esac
            \\echo after
            ,
            .diagnostic = "expansion error: x: casewordbad",
        },
        .{
            .path = "rush-script-case-pattern-parameter-diagnostic-test.rush",
            .data =
            \\echo before
            \\unset x
            \\case ok in ${x:?casepatbad}) echo ok;; esac
            \\echo after
            ,
            .diagnostic = "expansion error: x: casepatbad",
        },
    };

    for (cases) |case| {
        try deleteFileIfExists(std.testing.io, case.path);
        defer std.Io.Dir.cwd().deleteFile(std.testing.io, case.path) catch {};
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = case.path, .data = case.data });

        const invocation = cli_invocation.parse(
            &.{ "rush", "--posix", case.path },
        ) orelse return error.ExpectedInvocation;
        var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
        defer result.deinit();

        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}:3: {s}\n",
            .{ case.path, case.diagnostic },
        );
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings("before\n", result.stdout);
        try std.testing.expectEqualStrings(expected, result.stderr);
        try std.testing.expect(result.status != 0);
    }
}

test "multiline command string expansion diagnostics include line without path" {
    const Case = struct {
        script: []const u8,
        diagnostic: []const u8,
    };
    const cases = [_]Case{
        .{
            .script =
            \\echo before
            \\unset x
            \\printf '%s\n' ${x:?simplebad}
            \\echo after
            ,
            .diagnostic = "3: expansion error: x: simplebad\n",
        },
        .{
            .script =
            \\echo before
            \\unset x
            \\for i in ${x:?forbad}; do echo "$i"; done
            \\echo after
            ,
            .diagnostic = "3: expansion error: x: forbad\n",
        },
        .{
            .script =
            \\echo before
            \\unset x
            \\case ${x:?casewordbad} in *) echo ok;; esac
            \\echo after
            ,
            .diagnostic = "3: expansion error: x: casewordbad\n",
        },
        .{
            .script =
            \\echo before
            \\unset x
            \\case ok in ${x:?casepatbad}) echo ok;; esac
            \\echo after
            ,
            .diagnostic = "3: expansion error: x: casepatbad\n",
        },
    };

    for (cases) |case| {
        const invocation = cli_invocation.parse(&.{ "rush", "--posix", "-c", case.script }) orelse
            return error.ExpectedInvocation;
        var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
        defer result.deinit();

        try std.testing.expectEqualStrings("before\n", result.stdout);
        try std.testing.expectEqualStrings(case.diagnostic, result.stderr);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "rush:") == null);
        try std.testing.expect(result.status != 0);
    }
}

test "script file invocation shell options affect execution" {
    const path = "rush-script-options-test.rush";
    try deleteFileIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\false
        \\echo unreached
    });

    const invocation = cli_invocation.parse(&.{ "rush", "-e", path }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "standard input invocation accepts -s operands and shell options" {
    const invocation = cli_invocation.parse(&.{ "rush", "-e", "-s", "posarg", "two words" }) orelse
        return error.ExpectedInvocation;

    try std.testing.expectEqual(cli_invocation.Kind.standard_input, invocation.kind);
    try std.testing.expectEqualStrings("-", invocation.source);
    try std.testing.expectEqualStrings("rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 2), invocation.positionals.len);
    try std.testing.expectEqualStrings("posarg", invocation.positionals[0]);
    try std.testing.expectEqualStrings("two words", invocation.positionals[1]);
    try std.testing.expect(invocation.shell_options.errexit);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo $0:$#:$1:$2",
        .{ .io = std.testing.io, .arg_zero = invocation.arg_zero },
        null,
        invocation.positionals,
        invocation.shell_options,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("rush:2:posarg:two words\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "command string invocation xtrace option traces the first command" {
    const invocation = cli_invocation.parse(&.{ "rush", "-x", "-c", "echo hi" }) orelse
        return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hi\n", result.stdout);
    try std.testing.expectEqualStrings("+ echo hi\n", result.stderr);
}
test "command string invocation shell options affect execution" {
    const errexit_invocation = cli_invocation.parseCommandString(&.{
        "rush",
        "-e",
        "-c",
        "false; echo unreached",
    }) orelse return error.ExpectedInvocation;
    var errexit = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        errexit_invocation.source,
        .{ .io = std.testing.io, .arg_zero = errexit_invocation.arg_zero },
        null,
        errexit_invocation.positionals,
        errexit_invocation.shell_options,
    );
    defer errexit.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), errexit.status);
    try std.testing.expectEqualStrings("", errexit.stdout);
    try std.testing.expectEqualStrings("", errexit.stderr);

    const clustered_errexit_invocation = cli_invocation.parseCommandString(&.{
        "rush",
        "-ec",
        "false; echo unreached",
    }) orelse return error.ExpectedInvocation;
    var clustered_errexit = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        clustered_errexit_invocation.source,
        .{ .io = std.testing.io, .arg_zero = clustered_errexit_invocation.arg_zero },
        null,
        clustered_errexit_invocation.positionals,
        clustered_errexit_invocation.shell_options,
    );
    defer clustered_errexit.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), clustered_errexit.status);
    try std.testing.expectEqualStrings("", clustered_errexit.stdout);
    try std.testing.expectEqualStrings("", clustered_errexit.stderr);

    const option_after_c_invocation = cli_invocation.parseCommandString(&.{
        "rush",
        "-c",
        "-e",
        "false; echo unreached",
    }) orelse return error.ExpectedInvocation;
    var option_after_c = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        option_after_c_invocation.source,
        .{ .io = std.testing.io, .arg_zero = option_after_c_invocation.arg_zero },
        null,
        option_after_c_invocation.positionals,
        option_after_c_invocation.shell_options,
    );
    defer option_after_c.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), option_after_c.status);
    try std.testing.expectEqualStrings("", option_after_c.stdout);
    try std.testing.expectEqualStrings("", option_after_c.stderr);

    const nounset_invocation = cli_invocation.parseCommandString(&.{
        "rush",
        "-o",
        "nounset",
        "-c",
        "echo $RUSH_INVOCATION_UNSET_FOR_TEST_416; echo unreached",
    }) orelse return error.ExpectedInvocation;
    var nounset = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        nounset_invocation.source,
        .{ .io = std.testing.io, .arg_zero = nounset_invocation.arg_zero },
        null,
        nounset_invocation.positionals,
        nounset_invocation.shell_options,
    );
    defer nounset.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), nounset.status);
    try std.testing.expectEqualStrings("", nounset.stdout);
    try std.testing.expect(std.mem.indexOf(u8, nounset.stderr, "parameter not set") != null);

    const flags_invocation = cli_invocation.parseCommandString(&.{
        "rush",
        "-bem",
        "-o",
        "nounset",
        "-c",
        "printf '<%s>\\n' \"$-\"",
    }) orelse return error.ExpectedInvocation;
    var flags = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        flags_invocation.source,
        .{ .io = std.testing.io, .arg_zero = flags_invocation.arg_zero },
        null,
        flags_invocation.positionals,
        flags_invocation.shell_options,
    );
    defer flags.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), flags.status);
    try std.testing.expectEqualStrings("<bemu>\n", flags.stdout);
    try std.testing.expectEqualStrings("", flags.stderr);

    const noexec_invocation = cli_invocation.parseCommandString(&.{ "rush", "-n", "-c", "echo unreached" }) orelse
        return error.ExpectedInvocation;
    var no_execute = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = noexec_invocation.arg_zero },
        null,
        noexec_invocation.positionals,
        noexec_invocation.shell_options,
    );
    defer no_execute.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), no_execute.status);
    try std.testing.expectEqualStrings("", no_execute.stdout);
    try std.testing.expectEqualStrings("", no_execute.stderr);

    const invalid_noexec_invocation = cli_invocation.parseCommandString(&.{
        "rush",
        "-n",
        "-c",
        "x=for; $x i in 1; do echo $i; done",
    }) orelse return error.ExpectedInvocation;
    var invalid_no_execute = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        invalid_noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = invalid_noexec_invocation.arg_zero },
        null,
        invalid_noexec_invocation.positionals,
        invalid_noexec_invocation.shell_options,
    );
    defer invalid_no_execute.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), invalid_no_execute.status);
    try std.testing.expectEqualStrings("", invalid_no_execute.stdout);
    try std.testing.expect(invalid_no_execute.stderr.len != 0);

    const invalid_elif_noexec_invocation = cli_invocation.parseCommandString(&.{
        "rush",
        "-n",
        "-c",
        "if false; then :; elif true; fi",
    }) orelse return error.ExpectedInvocation;
    var invalid_elif_no_execute = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        invalid_elif_noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = invalid_elif_noexec_invocation.arg_zero },
        null,
        invalid_elif_noexec_invocation.positionals,
        invalid_elif_noexec_invocation.shell_options,
    );
    defer invalid_elif_no_execute.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), invalid_elif_no_execute.status);
    try std.testing.expectEqualStrings("", invalid_elif_no_execute.stdout);
    try std.testing.expect(invalid_elif_no_execute.stderr.len != 0);
}
test "command string set -v does not echo already-read input" {
    const invocation = cli_invocation.parse(&.{ "rush", "-c", "set -v\necho command-string-verbose" }) orelse
        return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("command-string-verbose\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string set -n parses but does not execute later commands" {
    const invocation = cli_invocation.parse(&.{
        "rush",
        "-c",
        "set -n\nprintf should-not-run\nx=$(printf substitution)\nprintf after",
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string read consumes piped real stdin" {
    const invocation = cli_invocation.parse(&.{
        "rush",
        "-c",
        "read x; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"",
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithPipeStdin(invocation, "pipe value\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[pipe value] status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "command string read consumes file real stdin" {
    const path = "rush-command-string-read-stdin.tmp";
    try deleteFileIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "file value\n" });

    const invocation = cli_invocation.parse(&.{
        "rush",
        "-c",
        "read x; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"",
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithFileStdin(invocation, path);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[file value] status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "command string read keeps explicit stdin redirection precedence" {
    const path = "rush-command-string-read-redirection.tmp";
    try deleteFileIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "redirected value\n" });

    const invocation = cli_invocation.parse(&.{
        "rush",
        "-c",
        "read x < \"$1\"; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"",
        "rush",
        path,
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithPipeStdin(invocation, "real stdin value\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[redirected value] status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "standard input script source still leaves read at EOF" {
    const invocation = cli_invocation.parse(&.{"rush"}) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithPipeStdin(
        invocation,
        "read x; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"\n",
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[] status=1\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "standard input file script skips lines consumed by read" {
    const path = "rush-stdin-script-seek-read.tmp";
    try deleteFileIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "read x\nprintf 'x=[%s]\\n' \"$x\"\nprintf 'after\\n'\n",
    });

    const invocation = cli_invocation.parse(&.{"rush"}) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithFileStdin(invocation, path);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("after\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "invalid arithmetic expansion returns a shell diagnostic" {
    const cases = [_][]const u8{
        "echo $((2 ** 3)); echo after",
    };

    for (cases) |script| {
        var result = try runScript(std.testing.allocator, std.testing.io, script);
        defer result.deinit();

        try std.testing.expectEqual(@as(shell.ExitStatus, 1), result.status);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "invalid arithmetic expression") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "after") == null);
    }
}
test "runScriptWithEnvironment imports initial shell variables" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_IMPORTED_ENV", "present");
    try env.put("IFS", ":");
    try env.put("OPTIND", "7");
    try env.put("PWD", "/definitely/not/rush/current/directory");
    try env.put(shell.startup.inherited_ppid_env, "12345");

    var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io,
        \\printf '<%s>\n' "$PPID" "${__RUSH_PPID-unset}"
        \\printf '<%s>\n' "$RUSH_IMPORTED_ENV" "$IFS" "$OPTIND"
        \\case $PWD in /definitely/not/rush/*) echo bad-pwd ;; /*) echo pwd-ok ;; *) echo bad-pwd ;; esac
    , .{ .io = std.testing.io, .allow_external = true }, &env);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("<12345>\n<unset>\n<present>\n< \t\n>\n<1>\npwd-ok\n", result.stdout);
}
test "semantic non-interactive invocation initializes environment arg zero and positionals" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_IMPORTED_ENV", "semantic");
    try env.put("SHLVL", "5");

    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "printf '<%s>\n' \"$0\" \"$#\" \"$1\" \"$RUSH_IMPORTED_ENV\" \"$IFS\" \"$OPTIND\" \"$SHLVL\"",
        shell.InvocationContext.init(.{ .arg_zero = "semantic-rush" }),
        .inherit,
        &env,
        &.{"positional"},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings(
                "<semantic-rush>\n<1>\n<positional>\n<semantic>\n< \t\n>\n<1>\n<6>\n",
                result.stdout,
            );
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic interactive invocation runs cd" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "target", .default_dir);
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "target" });
    defer std.testing.allocator.free(target_path);

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});

    const script = try std.fmt.allocPrint(std.testing.allocator, "cd {s}", .{target_path});
    defer std.testing.allocator.free(script);
    var execution = try runInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        script,
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
            try std.testing.expectEqualStrings(target_path, shell_state.getVariable("PWD").?.value);
        },
    }
}

test "semantic interactive invocation continues after expansion errors" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});

    var execution = try runInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        "echo ${x?alas, poor yorick}; echo hello",
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("hello\n", result.stdout);
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, "alas, poor yorick") != null);
        },
    }
}

test "semantic interactive invocation dispatches job control builtins" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});

    var execution = try runInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        "jobs\nbg\nfg",
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 1), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("bg: job control disabled\nfg: job control disabled\n", result.stderr);
        },
    }
}

test "semantic interactive invocation dispatches alias builtins" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});

    var execution = try runInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        "alias ll='echo listed'\nalias ll\nunalias ll",
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("ll='echo listed'\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
            try std.testing.expect(shell_state.getAlias("ll") == null);
        },
    }
}

test "semantic interactive invocation expands existing aliases" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});
    try shell_state.setAlias("say", "echo alias-ok");

    var execution = try runInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        "say",
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("alias-ok\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic interactive invocation dispatches declaration builtins" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});

    var execution = try runInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        "export FOO=bar",
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
            const variable = shell_state.getVariable("FOO") orelse return error.ExpectedExportedVariable;
            try std.testing.expectEqualStrings("bar", variable.value);
            try std.testing.expect(variable.exported);
        },
    }
}

test "semantic interactive invocation dispatches shell state builtins" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});
    try shell_state.putVariable("GONE", "yes", .{});

    var execution = try runInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        "set -f\nunset GONE\ntrap 'echo bye' EXIT",
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
            try std.testing.expect(shell_state.options.noglob);
            try std.testing.expect(shell_state.getVariable("GONE") == null);
            try std.testing.expect(shell_state.getTrapForSignal(.EXIT) != null);
        },
    }
}

test "semantic interactive invocation runs directory change hooks before following command" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "target", .default_dir);
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "target" });
    defer std.testing.allocator.free(target_path);

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});

    const script = try std.fmt.allocPrint(std.testing.allocator,
        \\on_cd() {{ HOOK_SEEN="$RUSH_EVENT/$RUSH_EVENT_HOOK"; false; }}
        \\event add directory.change env-sync on_cd
        \\cd "{s}" && printf 'hook=%s status=%s event=%s\n' "$HOOK_SEEN" "$?" "$RUSH_EVENT"
    , .{target_path});
    defer std.testing.allocator.free(script);
    var execution = try runInteractiveCommandStringWithExtensionHandlers(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        script,
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
        .{ .lookup = bundledExtensionLookup },
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("hook=directory.change/env-sync status=0 event=\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic interactive invocation does not fire directory hooks retroactively" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "target", .default_dir);
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "target" });
    defer std.testing.allocator.free(target_path);

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});

    const script = try std.fmt.allocPrint(std.testing.allocator,
        \\late_cd() {{ LATE=yes; }}
        \\{{ cd "{s}"; event add directory.change late late_cd; }}
        \\printf 'late=%s\n' "$LATE"
    , .{target_path});
    defer std.testing.allocator.free(script);
    var execution = try runInteractiveCommandStringWithExtensionHandlers(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        script,
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
        .{ .lookup = bundledExtensionLookup },
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("late=\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic interactive invocation suppresses recursive directory hook dispatch" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "first", .default_dir);
    try tmp.dir.createDir(std.testing.io, "second", .default_dir);
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const first_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "first" });
    defer std.testing.allocator.free(first_path);
    const second_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "second" });
    defer std.testing.allocator.free(second_path);

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});

    const script = try std.fmt.allocPrint(std.testing.allocator,
        \\SECOND={s}
        \\on_cd() {{ if test "$COUNT" = ""; then COUNT=1; else COUNT=recursive; fi; cd "$SECOND"; }}
        \\event add directory.change nested on_cd
        \\cd "{s}"
        \\printf 'count=%s pwd=%s\n' "$COUNT" "$PWD"
    , .{ second_path, first_path });
    defer std.testing.allocator.free(script);
    var execution = try runInteractiveCommandStringWithExtensionHandlers(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        script,
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
        .{ .lookup = bundledExtensionLookup },
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            const expected = try std.fmt.allocPrint(
                std.testing.allocator,
                "count=1 pwd={s}\n",
                .{second_path},
            );
            defer std.testing.allocator.free(expected);
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings(expected, result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic interactive invocation honors exit from directory hook" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "target", .default_dir);
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "target" });
    defer std.testing.allocator.free(target_path);

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});

    const script = try std.fmt.allocPrint(std.testing.allocator,
        \\on_cd() {{ exit 7; }}
        \\event add directory.change stop on_cd
        \\cd "{s}"
        \\printf 'after\n'
    , .{target_path});
    defer std.testing.allocator.free(script);
    var execution = try runInteractiveCommandStringWithExtensionHandlers(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        script,
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
        .{ .lookup = bundledExtensionLookup },
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 7), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic interactive invocation dispatches exit" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(std.testing.allocator, std.testing.io, &shell_state, null, &.{}, .{});

    var execution = try runInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        "exit 7",
        shell.InvocationContext.init(.{ .arg_zero = "rush", .source = .interactive, .interactive = true }),
        .capture,
        false,
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 7), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
            try std.testing.expectEqual(@as(?shell.ExitStatus, 7), shell_state.pending_exit);
        },
    }
}

test "semantic non-interactive invocation stops after eval parse errors across chunks" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "eval 'if then echo bad; fi'\nprintf 'bad\\n'",
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, "parse error") != null);
        },
    }
}

test "semantic non-interactive invocation executes foreground simple pipelines" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\printf 'pipe:%s\n' value | /bin/cat
        \\false | true
        \\printf 'status:%s\n' "$?"
        \\! false
        \\printf 'negated:%s\n' "$?"
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("pipe:value\nstatus:0\nnegated:0\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}
test "semantic non-interactive invocation lowers function bodies at call time" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\func() { printf 'call:%s:%s\n' "$1" "$#"; }
        \\func first second
        \\outer() { inner() { printf 'same-list:%s\n' "$1"; }; inner nested; }
        \\outer
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("call:first:2\nsame-list:nested\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation preserves function body source lines" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\printf 'before\n'
        \\outer() {
        \\printf '<outer:%s>\n' "$LINENO"
        \\inner() {
        \\printf '<inner:%s>\n' "$LINENO"
        \\}
        \\inner
        \\}
        \\outer
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush", .features = .strictPosix() }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("before\n<outer:3>\n<inner:5>\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation lowers function for bodies per iteration" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\h() for i in 1 2; do echo f$i; done
        \\h
        \\show() { for x in "$@"; do echo "<$x>"; done; }
        \\show "a b" c ""
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("f1\nf2\n<a b>\n<c>\n<>\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}
test "semantic non-interactive invocation executes function calls in pipelines with subshell isolation" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\pipe_fn() { printf 'pipe:%s\n' "$1"; }
        \\pipe_fn value | /bin/cat
        \\maker() { made() { printf 'bad\n'; }; }
        \\maker | :
        \\made
        \\printf 'missing:%s\n' "$?"
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("pipe:value\nmissing:127\n", result.stdout);
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, "made: command not found") != null);
        },
    }
}
test "semantic non-interactive invocation executes compound pipeline stages" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\{ printf 'brace\n'; } | /bin/cat
        \\( printf 'subshell\n' ) | /bin/cat
        \\if true; then printf 'if\n'; fi | /bin/cat
        \\! { false; }
        \\printf 'negated-compound:%s\n' "$?"
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("brace\nsubshell\nif\nnegated-compound:0\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation executes simple command redirections" {
    const path = "rush-semantic-simple-redirection.tmp";
    try deleteFileIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "echo redirected > " ++ path,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }

    const output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("redirected\n", output);
}
test "semantic non-interactive invocation executes formerly gated production pipeline shapes" {
    const path = "rush-semantic-compound-stage.tmp";
    try deleteFileIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var redirected_compound_stage = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "{ printf 'compound\n'; } > " ++ path ++ " | /bin/cat",
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer redirected_compound_stage.deinit(std.testing.allocator);
    switch (redirected_compound_stage) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }

    const file_output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(file_output);
    try std.testing.expectEqualStrings("compound\n", file_output);

    var dynamic_compound_stage = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "{ printf \"$(printf dynamic)\\n\"; } | /bin/cat",
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer dynamic_compound_stage.deinit(std.testing.allocator);
    switch (dynamic_compound_stage) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("dynamic\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}
test "runScriptWithEnvironment initializes and exports SHLVL" {
    const ShellLevelCase = struct {
        inherited: ?[]const u8,
        expected: []const u8,
    };
    const cases = [_]ShellLevelCase{
        .{ .inherited = null, .expected = "1" },
        .{ .inherited = "5", .expected = "6" },
        .{ .inherited = "not-a-number", .expected = "1" },
    };

    for (cases) |case| {
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        if (case.inherited) |level| try env.put("SHLVL", level);

        var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io,
            \\printf '<%s>\n' "$SHLVL"
            \\env
        , .{ .io = std.testing.io, .allow_external = true }, &env);
        defer result.deinit();

        const expected = try std.fmt.allocPrint(std.testing.allocator, "<{s}>\n", .{case.expected});
        defer std.testing.allocator.free(expected);
        const exported = try std.fmt.allocPrint(std.testing.allocator, "\nSHLVL={s}\n", .{case.expected});
        defer std.testing.allocator.free(exported);
        try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout, expected));
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, exported) != null);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}
test "runScriptWithEnvironment exports PWD and OLDPWD after cd" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "target", .default_dir);
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "target" });
    defer std.testing.allocator.free(target_path);

    const script = try std.fmt.allocPrint(std.testing.allocator,
        \\unset PWD OLDPWD
        \\cd "{s}"
        \\env
    , .{target_path});
    defer std.testing.allocator.free(script);
    var result = try runScriptWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        script,
        .{ .io = std.testing.io, .allow_external = true },
        null,
    );
    defer result.deinit();

    const pwd_line = try std.fmt.allocPrint(std.testing.allocator, "PWD={s}\n", .{target_path});
    defer std.testing.allocator.free(pwd_line);
    const oldpwd_line = try std.fmt.allocPrint(std.testing.allocator, "OLDPWD={s}\n", .{original_cwd});
    defer std.testing.allocator.free(oldpwd_line);

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, pwd_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, oldpwd_line) != null);
}
test "POSIX mode reports misplaced reserved words" {
    var bare = try runScript(std.testing.allocator, std.testing.io, "then echo bad");
    defer bare.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), bare.status);
    try std.testing.expectEqualStrings("", bare.stdout);
    try std.testing.expect(std.mem.indexOf(u8, bare.stderr, "misplaced reserved word") != null);

    var expanded = try runScript(std.testing.allocator, std.testing.io, "x=for; $x i in 1");
    defer expanded.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 127), expanded.status);
    try std.testing.expect(std.mem.indexOf(u8, expanded.stderr, "for: command not found") != null);

    const alias_script =
        \\alias then='echo bad'
        \\then
    ;
    var alias_result = try runScript(std.testing.allocator, std.testing.io, alias_script);
    defer alias_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), alias_result.status);
    try std.testing.expectEqualStrings("", alias_result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, alias_result.stderr, "misplaced reserved word") != null);
    try std.testing.expect(std.mem.indexOf(u8, alias_result.stderr, "bad\n") == null);
}
test "runScript returns parse diagnostics" {
    var result = try runScript(std.testing.allocator, std.testing.io, "echo | ");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "missing command after pipeline operator") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "echo | ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "     ^") != null);
}
test "runScript executes newline-continued pipeline" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\echo before
        \\echo |
        \\echo after
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("before\nafter\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "production shell execution preserves semantic builtin state and sequencing" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\VALUE=new
        \\printf 'semantic %s\n' shell
        \\printf '%s\n' "$VALUE"
        \\false && printf 'bad-and\n'
        \\true || printf 'bad-or\n'
        \\printf 'after\n'
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("semantic shell\nnew\nafter\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "production shell execution handles deterministic builtin pipeline" {
    var result = try runScript(std.testing.allocator, std.testing.io, "printf 'pipe-value\n' | /bin/cat");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("pipe-value\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "production shell execution handles compound pipeline stage" {
    var result = try runScript(std.testing.allocator, std.testing.io, "{ printf 'compound-value\n'; } | /bin/cat");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("compound-value\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "production shell execution handles pipeline function call" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\fn() { printf 'compare:%s\n' "$1"; }
        \\fn value | read VALUE
        \\printf 'status:%s value:%s\n' "$?" "$VALUE"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("status:0 value:\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution keeps negated single commands in the current shell" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\fn() {
        \\    parent=$(exec /usr/bin/env sh -c 'echo $PPID')
        \\    case $parent in ($$) return 1;; (*) return 0;; esac
        \\}
        \\! fn
        \\printf 'status:%s\n' "$?"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("status:0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution keeps nested exec command substitutions scoped" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\outer=$(inner=$(exec /usr/bin/env printf inner); printf 'captured:%s' "$inner")
        \\printf 'outer:%s\n' "$outer"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("outer:captured:inner\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution applies pipeline redirections after pipe setup" {
    const left_path = "rush-pipeline-left-redirection.tmp";
    const right_path = "rush-pipeline-right-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, left_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, right_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, left_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, right_path) catch {};

    var result = try runScript(std.testing.allocator, std.testing.io,
        \\printf 'left\n' >rush-pipeline-left-redirection.tmp | /bin/cat
        \\printf 'left-file='
        \\/bin/cat rush-pipeline-left-redirection.tmp
        \\printf 'right\n' | /bin/cat >rush-pipeline-right-redirection.tmp
        \\printf 'right-file='
        \\/bin/cat rush-pipeline-right-redirection.tmp
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("left-file=left\nright-file=right\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution runs background brace group as subshell" {
    const path = "rush-background-brace-group.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = try runScript(std.testing.allocator, std.testing.io,
        \\x=outer
        \\{ x=inner; printf 'async-body\n' >rush-background-brace-group.tmp; } & wait "$!"
        \\printf '<%s>\n' "$x"
        \\/bin/cat rush-background-brace-group.tmp
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("<outer>\nasync-body\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runScript reports misplaced reserved words before execution" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\echo before
        \\then
        \\echo after
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "misplaced reserved word") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "echo after") == null);
}

test "hidden shell state commands do not read terminal stdin" {
    var adapter = runtime.posix.Adapter.init(std.testing.io);
    const pipe = try adapter.fdPort().pipe(.{});
    const read_file: std.Io.File = .{ .handle = pipe.read, .flags = .{ .nonblocking = false } };
    const write_file: std.Io.File = .{ .handle = pipe.write, .flags = .{ .nonblocking = false } };

    defer read_file.close(std.testing.io);
    var write_open = true;
    defer if (write_open) write_file.close(std.testing.io);

    try writeFileAll(write_file, "terminal-input\n");
    write_file.close(std.testing.io);
    write_open = false;

    var guard = try StdinGuard.replaceWith(read_file);
    defer guard.restore();

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "hidden_read_probe",
        .source_body =
        \\if read value; then
        \\  printf 'read:%s\n' "$value"
        \\else
        \\  printf 'empty\n'
        \\fi
        ,
    });

    var result = try runHiddenShellStateCommandWithExtensionHandlers(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        &.{"hidden_read_probe"},
        "rush",
        .{},
        .capture,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("empty\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "hidden shell state commands keep multi-statement function output captured" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "hidden_output_probe",
        .source_body =
        \\printf 'first\n'
        \\printf 'second\n'
        ,
    });

    var result = try runHiddenShellStateCommandWithExtensionHandlers(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        &.{"hidden_output_probe"},
        "rush",
        .{},
        .capture,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("first\nsecond\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "hidden shell state external pipelines capture output without terminal stdin" {
    var adapter = runtime.posix.Adapter.init(std.testing.io);
    const pipe = try adapter.fdPort().pipe(.{});
    const read_file: std.Io.File = .{ .handle = pipe.read, .flags = .{ .nonblocking = false } };
    const write_file: std.Io.File = .{ .handle = pipe.write, .flags = .{ .nonblocking = false } };

    defer read_file.close(std.testing.io);
    var write_open = true;
    defer if (write_open) write_file.close(std.testing.io);

    try writeFileAll(write_file, "terminal-input\n");
    write_file.close(std.testing.io);
    write_open = false;

    var guard = try StdinGuard.replaceWith(read_file);
    defer guard.restore();

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "hidden_external_pipeline_probe",
        .source_body = "/bin/cat | /usr/bin/wc -c",
    });

    var result = try runHiddenShellStateCommandWithExtensionHandlers(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        &.{"hidden_external_pipeline_probe"},
        "rush",
        .{},
        .capture,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expect(std.mem.eql(u8, result.stdout, "       0\n") or std.mem.eql(u8, result.stdout, "0\n"));
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-interactive aliases affect later complete commands" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo script-alias-ok'
        \\say
        \\alias prefix='say '
        \\alias word='trailing-ok'
        \\prefix word
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("script-alias-ok\nscript-alias-ok trailing-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-interactive aliases see backslash-newline joined command words" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias joined='echo alias-joined'
        \\join\
        \\ed ok
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("alias-joined ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-interactive unalias removes aliases for later complete commands" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias gone='echo before-unalias'
        \\gone
        \\unalias gone
        \\gone 2>/dev/null
        \\printf '<%s>\n' "$?"
        \\alias gone='echo after-realias'
        \\gone
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("before-unalias\n<127>\nafter-realias\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-interactive alias mutations do not affect the same complete command" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias late='echo late-ok'; late 2>/dev/null; printf 'alias-same:%s\n' "$?"
        \\late
        \\alias kept='echo kept-before'
        \\unalias kept; kept
        \\kept 2>/dev/null
        \\printf 'unalias-later:%s\n' "$?"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("alias-same:127\nlate-ok\nkept-before\nunalias-later:127\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "expand_aliases shopt gates non-interactive alias expansion" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\shopt -u expand_aliases
        \\alias hit='echo disabled'
        \\hit 2>/dev/null
        \\printf '<%s>\n' "$?"
        \\shopt -s expand_aliases
        \\alias hit='echo enabled'
        \\hit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("<127>\nenabled\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "chunked alias scripts run EXIT trap once" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\trap 'echo bye' EXIT
        \\alias say='echo body'
        \\say
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("body\nbye\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "alias timing chunks keep multi-line here-doc bodies intact" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo alias-ok'
        \\read value <<EOF
        \\hello
        \\EOF
        \\say
        \\echo "$value"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("alias-ok\nhello\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command substitution survives read closing a large here-doc early" {
    var script_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer script_writer.deinit();

    try script_writer.writer.writeAll("value=$(IFS=' ' read first <<'EOF'\n  first line  \n");
    for (0..8192) |index| {
        try script_writer.writer.print("unused line {d}\n", .{index});
    }
    try script_writer.writer.writeAll(
        \\EOF
        \\printf '<%s>\n' "$first")
        \\printf 'value=%s status=%s\n' "$value" "$?"
        \\
    );

    const script = try script_writer.toOwnedSlice();
    defer std.testing.allocator.free(script);
    var result = try runScript(std.testing.allocator, std.testing.io, script);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("value=<first line> status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command substitution background jobs do not hold capture pipe open" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\fifo="rush-procsubst-fifo-$$"
        \\/bin/rm -f "$fifo"
        \\/usr/bin/mkfifo "$fifo" || exit 1
        \\path=$(printf '%s\n' "$fifo"; exec >&2; (exec >"$fifo"; printf 'fifo-ok\n') &)
        \\IFS= read -r line < "$path"
        \\status=$?
        \\/bin/rm -f "$fifo"
        \\printf 'line=%s status=%s\n' "$line" "$status"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("line=fifo-ok status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases expand at parser-recognized command word positions" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setAlias("say", "echo parser-ok");

    const expanded = try semanticExpandAliases(std.testing.allocator,
        \\FOO=bar say
        \\> out say
        \\if say; then :; fi
    , .{}, &shell_state);
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings(
        \\FOO=bar echo parser-ok
        \\> out echo parser-ok
        \\if echo parser-ok; then :; fi
    , expanded);
}
test "aliases expand inside command substitutions without touching here-doc bodies" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo subst-ok'
        \\alias body='echo bad'
        \\echo "$(say)"
        \\read value <<EOF
        \\body
        \\EOF
        \\echo "$value"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("subst-ok\nbody\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "aliases can introduce reserved-word compound commands" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias start='if '
        \\start true
        \\then echo alias-if-ok
        \\fi
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("alias-if-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "aliases defined by dot affect later complete commands" {
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "rush-alias-dot-source") catch {};
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\printf '%s\n' "alias dot='echo dot-ok'" > rush-alias-dot-source
        \\. ./rush-alias-dot-source
        \\dot
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("dot-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "semantic interactive command string dot aliases affect later lines" {
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "rush-interactive-alias-dot-source") catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = "rush-interactive-alias-dot-source",
        .data = "alias dot='echo interactive-dot-ok'\n",
    });

    const invocation = cli_invocation.parse(&.{
        "rush",
        "--posix",
        "-i",
        "-c",
        ". ./rush-interactive-alias-dot-source\ndot",
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("interactive-dot-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "semantic interactive command string runs exit trap after alias-timed chunks" {
    const invocation = cli_invocation.parse(&.{
        "rush",
        "--posix",
        "-i",
        "-c",
        "trap 'echo EXIT_TRAP' EXIT\nalias body='echo BODY'\nbody",
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("BODY\nEXIT_TRAP\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "semantic interactive command string runs exit trap after normal script" {
    const invocation = cli_invocation.parse(&.{
        "rush",
        "--posix",
        "-i",
        "-c",
        "trap 'echo EXIT_TRAP' EXIT\necho BODY",
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("BODY\nEXIT_TRAP\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "semantic interactive command string preserves output before exiting exit trap" {
    const invocation = cli_invocation.parse(&.{
        "rush",
        "--posix",
        "-i",
        "-c",
        "trap 'echo EXIT_TRAP; exit 7' EXIT\necho BODY",
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("BODY\nEXIT_TRAP\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "semantic interactive command string permits top-level loop controls" {
    const invocation = cli_invocation.parse(&.{
        "rush",
        "--posix",
        "-i",
        "-c",
        "break\ncontinue\necho AFTER",
    }) orelse return error.ExpectedInvocation;
    var result = try runInvocationForTest(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("AFTER\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases defined on a read line affect only later read lines" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias zzsamecmd='echo same-ok'; zzsamecmd; echo same-line:$?
        \\zzsamecmd
        \\eval "alias zzevalcmd='echo eval-ok'"; zzevalcmd; echo eval-line:$?
        \\zzevalcmd
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("same-line:127\nsame-ok\neval-line:127\neval-ok\n", result.stdout);
    try std.testing.expectEqualStrings("zzsamecmd: command not found\nzzevalcmd: command not found\n", result.stderr);
}
test "non-interactive command string invocation does not source ENV" {
    const env_path = "rush-test-noninteractive-env.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "NONINTERACTIVE_ENV=loaded\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ENV", env_path);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '%s\n' \"${NONINTERACTIVE_ENV-unset}\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("unset\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
