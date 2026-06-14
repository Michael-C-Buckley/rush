//! Script runner public types and result formatting helpers.

const std = @import("std");

const cli_invocation = @import("invocation.zig");
const runtime = @import("runtime.zig");
const shell = @import("shell.zig");
const compat = shell.compat;
const parser = shell.parser;
const ir = shell.ir;

pub const Options = struct {
    io: ?std.Io = null,
    allow_external: bool = true,
    features: compat.Features = .{},
    external_stdio: runtime.ExternalStdio = .capture,
    interactive: bool = false,
    arg_zero: []const u8 = "rush",
    source_path: ?[]const u8 = null,
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

pub fn loadInvocationScript(allocator: std.mem.Allocator, io: std.Io, invocation: cli_invocation.ShellInvocation, external_stdio: runtime.ExternalStdio) !LoadedInvocationScript {
    var options: Options = .{
        .io = io,
        .allow_external = true,
        .features = invocation.features,
        .external_stdio = external_stdio,
        .arg_zero = invocation.arg_zero,
    };
    switch (invocation.kind) {
        .command_string => return .{
            .allocator = allocator,
            .script = invocation.source,
            .options = options,
            .owns_script = false,
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

pub fn runScriptWithOptions(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: Options) !CommandResult {
    return runScriptWithEnvironment(allocator, io, script, options, null);
}

pub fn runScriptWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: Options, environ_map: ?*const std.process.Environ.Map) !CommandResult {
    return runCommandStringWithEnvironment(allocator, io, script, options, environ_map, &.{}, .{});
}

pub fn runCommandStringWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: Options, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, shell_options: shell.ShellOptions) !CommandResult {
    const invocation = invocationContext(options);
    if (invocation.interactive or !options.allow_external) {
        return unsupported(allocator, "non-interactive command strings must run through the semantic executor");
    }
    var execution = try runSemanticCommandString(allocator, io, script, invocation, options.external_stdio, environ_map, positionals, shell_options);
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

pub fn runSemanticCommandString(allocator: std.mem.Allocator, io: std.Io, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, shell_options: shell.ShellOptions) !SemanticInvocationExecution {
    assertSemanticStartupOptions(script, invocation, positionals);

    if (shell_options.noexec or shell_options.verbose or shell_options.xtrace) return semanticUnsupported(allocator, "semantic executor does not yet implement non-interactive noexec/verbose/xtrace startup modes");
    if (environ_map) |map| if (!semanticEnvironmentSupported(map)) return semanticUnsupported(allocator, "semantic ShellState cannot yet preserve non-shell environment names");

    if (semanticScriptNeedsAliasTiming(script)) {
        return runSemanticAliasTimingCommandString(allocator, io, script, invocation, external_stdio, environ_map, positionals, shell_options);
    }

    var parsed = try parser.parse(allocator, script, .{ .features = invocation.features.withStrictDiagnostics() });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) {
        return .{ .output = try parseDiagnostics(allocator, script, parsed.diagnostics) };
    }

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();
    if (try semanticPreflightUnsupported(allocator, program, invocation.features, false)) |message| return semanticUnsupported(allocator, message);

    var shell_state = shell.ShellState.init(allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(allocator, io, &shell_state, environ_map, positionals, shell_options);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = true;
    evaluator.external_stdio = external_stdio;
    var parser_resolver = shell.ParserTrapActionResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const resolver = parser_resolver.resolver();
    const eval_context = invocation.evalContext(.current_shell);

    return runSemanticLoweredProgram(allocator, script, program, &evaluator, &shell_state, eval_context, resolver, invocation.stdin_script_file, invocation.stdin_script_source_offset, true);
}

fn runSemanticAliasTimingCommandString(allocator: std.mem.Allocator, io: std.Io, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, shell_options: shell.ShellOptions) !SemanticInvocationExecution {
    var shell_state = shell.ShellState.init(allocator);
    defer shell_state.deinit();
    try shell.startup.initializeInvocationState(allocator, io, &shell_state, environ_map, positionals, shell_options);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = true;
    evaluator.external_stdio = external_stdio;
    var parser_resolver = shell.ParserTrapActionResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const resolver = parser_resolver.resolver();
    const eval_context = invocation.evalContext(.current_shell);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    var status: shell.ExitStatus = 0;
    var start = skipSemanticChunkSeparators(script, 0);
    while (start < script.len) {
        var end = extendSemanticHereDocChunk(script, start, semanticLineEnd(script, start));
        while (true) {
            const source = std.mem.trim(u8, script[start..end], " \t\r\n;");
            if (source.len == 0) break;
            const aliased = try semanticExpandAliases(allocator, source, invocation.features, &shell_state);
            defer allocator.free(aliased);
            var parsed = try parser.parse(allocator, aliased, .{ .features = invocation.features.withStrictDiagnostics() });
            defer parsed.deinit();
            if (parsed.diagnostics.len == 0) {
                var program = try ir.lowerSimpleCommands(allocator, parsed);
                defer program.deinit();
                var alias_snapshot = shell_state.clone(allocator) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ReadonlyVariable => unreachable,
                };
                defer alias_snapshot.deinit();
                parser_resolver.alias_state = &alias_snapshot;
                var execution = try runSemanticLoweredProgram(allocator, aliased, program, &evaluator, &shell_state, eval_context, resolver, invocation.stdin_script_file, invocation.stdin_script_source_offset, false);
                defer execution.deinit(allocator);
                switch (execution) {
                    .unsupported => |message| return semanticUnsupported(allocator, message),
                    .output => |output| {
                        try stdout.appendSlice(allocator, output.stdout);
                        try stderr.appendSlice(allocator, output.stderr);
                        status = output.status;
                    },
                }
                parser_resolver.alias_state = null;
                break;
            }
            if (!parsed.incomplete or end >= script.len) return .{ .output = try parseDiagnostics(allocator, source, parsed.diagnostics) };
            end = extendSemanticHereDocChunk(script, start, semanticLineEnd(script, end));
        }
        start = skipSemanticChunkSeparators(script, end);
    }

    try appendSemanticExitTrap(allocator, &stdout, &stderr, &status, &evaluator, &shell_state, eval_context, resolver);
    return .{ .output = .{ .allocator = allocator, .status = status, .stdout = try stdout.toOwnedSlice(allocator), .stderr = try stderr.toOwnedSlice(allocator) } };
}

pub fn runShellStateScript(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, script: []const u8, source_path: []const u8, arg_zero: []const u8, features: compat.Features, external_stdio: runtime.ExternalStdio) !CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    std.debug.assert(arg_zero.len != 0);
    std.debug.assert(source_path.len != 0);
    if (script.len == 0) return empty(allocator, shell_state.last_status);

    const invocation = shell.InvocationContext.init(.{ .features = features, .arg_zero = arg_zero, .source = .script_file, .interactive = true });
    var semantic_execution = if (semanticScriptNeedsAliasTiming(script))
        try runSemanticAliasTimingShellStateScript(allocator, io, shell_state, script, invocation, external_stdio)
    else
        try runSemanticShellStateScriptWithoutAliasTiming(allocator, io, shell_state, script, invocation, external_stdio);
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

fn runSemanticShellStateScriptWithoutAliasTiming(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio) !SemanticInvocationExecution {
    shell_state.validate();
    invocation.validate();

    var parsed = try parser.parse(allocator, script, .{ .features = invocation.features.withStrictDiagnostics() });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) return .{ .output = try parseDiagnostics(allocator, script, parsed.diagnostics) };

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();
    if (try semanticPreflightUnsupported(allocator, program, invocation.features, false)) |message| return semanticUnsupported(allocator, message);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = true;
    evaluator.external_stdio = external_stdio;
    var parser_resolver = shell.ParserTrapActionResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const resolver = parser_resolver.resolver();
    const eval_context = invocation.evalContext(.current_shell);

    return runSemanticLoweredProgram(allocator, script, program, &evaluator, shell_state, eval_context, resolver, null, 0, false);
}

fn runSemanticAliasTimingShellStateScript(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio) !SemanticInvocationExecution {
    shell_state.validate();
    invocation.validate();

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = true;
    evaluator.external_stdio = external_stdio;
    var parser_resolver = shell.ParserTrapActionResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const resolver = parser_resolver.resolver();
    const eval_context = invocation.evalContext(.current_shell);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    var status = shell_state.last_status;
    var start = skipSemanticChunkSeparators(script, 0);
    while (start < script.len) {
        var end = extendSemanticHereDocChunk(script, start, semanticLineEnd(script, start));
        while (true) {
            const source = std.mem.trim(u8, script[start..end], " \t\r\n;");
            if (source.len == 0) break;
            const aliased = try semanticExpandAliases(allocator, source, invocation.features, shell_state);
            defer allocator.free(aliased);
            var parsed = try parser.parse(allocator, aliased, .{ .features = invocation.features.withStrictDiagnostics() });
            defer parsed.deinit();
            if (parsed.diagnostics.len == 0) {
                var program = try ir.lowerSimpleCommands(allocator, parsed);
                defer program.deinit();
                if (try semanticPreflightUnsupported(allocator, program, invocation.features, false)) |message| return semanticUnsupported(allocator, message);
                var alias_snapshot = shell_state.clone(allocator) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ReadonlyVariable => unreachable,
                };
                defer alias_snapshot.deinit();
                parser_resolver.alias_state = &alias_snapshot;
                var execution = try runSemanticLoweredProgram(allocator, aliased, program, &evaluator, shell_state, eval_context, resolver, null, 0, false);
                defer execution.deinit(allocator);
                switch (execution) {
                    .unsupported => |message| return semanticUnsupported(allocator, message),
                    .output => |output| {
                        try stdout.appendSlice(allocator, output.stdout);
                        try stderr.appendSlice(allocator, output.stderr);
                        status = output.status;
                    },
                }
                parser_resolver.alias_state = null;
                break;
            }
            if (!parsed.incomplete or end >= script.len) return .{ .output = try parseDiagnostics(allocator, source, parsed.diagnostics) };
            end = extendSemanticHereDocChunk(script, start, semanticLineEnd(script, end));
        }
        start = skipSemanticChunkSeparators(script, end);
    }

    const out = try stdout.toOwnedSlice(allocator);
    errdefer allocator.free(out);
    const err = try stderr.toOwnedSlice(allocator);
    return .{ .output = .{ .allocator = allocator, .status = status, .stdout = out, .stderr = err } };
}

pub fn runInteractiveCommandString(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio) !SemanticInvocationExecution {
    assertSemanticInteractiveOptions(script, invocation);
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (external_stdio != .inherit and external_stdio != .capture) return semanticUnsupported(allocator, "semantic interactive executor requires inherited or captured stdio");
    if (invocation.stdin_script_file != null) return semanticUnsupported(allocator, "semantic interactive executor does not consume script stdin files");
    if (shell_state.pending_exit != null) return semanticUnsupported(allocator, "semantic interactive executor does not run while an exit is pending");
    if (shell_state.options.verbose or shell_state.options.xtrace or shell_state.options.errexit) return semanticUnsupported(allocator, "semantic interactive executor does not yet preserve verbose/xtrace/errexit state");

    var parsed = try parser.parse(allocator, script, .{ .mode = .interactive, .features = invocation.features.withStrictDiagnostics() });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) return semanticUnsupported(allocator, "semantic interactive parser diagnostics are not handled by this path yet");

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();
    if (try semanticPreflightUnsupported(allocator, program, invocation.features, true)) |message| return semanticUnsupported(allocator, message);
    if (semanticInteractiveProgramUnsupported(shell_state.*, program)) |message| return semanticUnsupported(allocator, message);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.external_stdio = external_stdio;
    var parser_resolver = shell.ParserTrapActionResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const resolver = parser_resolver.resolver();
    const eval_context = invocation.evalContext(.current_shell);

    return runSemanticLoweredProgram(allocator, script, program, &evaluator, shell_state, eval_context, resolver, null, 0, false);
}

fn runSemanticLoweredProgram(allocator: std.mem.Allocator, script: []const u8, program: ir.Program, evaluator: *shell.eval.Evaluator, shell_state: *shell.ShellState, eval_context: shell.EvalContext, resolver: shell.TrapActionResolver, stdin_script_file: ?std.Io.File, stdin_script_source_offset: usize, run_exit_trap: bool) !SemanticInvocationExecution {
    eval_context.validate();
    shell_state.validate();
    if (stdin_script_file == null) std.debug.assert(stdin_script_source_offset == 0);

    var accumulated_stdout: std.ArrayList(u8) = .empty;
    errdefer accumulated_stdout.deinit(allocator);
    var accumulated_stderr: std.ArrayList(u8) = .empty;
    errdefer accumulated_stderr.deinit(allocator);
    var release_accumulated = false;
    defer if (!release_accumulated) {
        accumulated_stdout.deinit(allocator);
        accumulated_stderr.deinit(allocator);
    };

    var status: shell.ExitStatus = 0;
    var control_flow: shell.ControlFlow = .normal;
    for (program.statements, 0..) |statement, statement_index| {
        std.debug.assert(statement.span.start <= statement.span.end);
        std.debug.assert(statement.span.end <= script.len);
        if (semanticStdinScriptConsumedStatement(stdin_script_file, stdin_script_source_offset, statement.span.start)) continue;

        const should_run = if (statement_index == 0) blk: {
            std.debug.assert(statement.op_before == .sequence);
            break :blk true;
        } else switch (statement.op_before) {
            .sequence => true,
            .and_if => status == 0,
            .or_if => status != 0,
        };
        if (!should_run) continue;

        const statement_end = semanticStatementSourceEnd(program, statement_index, script.len);
        const statement_script = std.mem.trim(u8, script[statement.span.start..statement_end], " \t\r\n;");
        std.debug.assert(statement_script.len != 0);
        syncSemanticStdinScriptOffset(stdin_script_file, stdin_script_source_offset, script, statement_end);
        var body = (try resolver.resolve(allocator, statement_script, .TERM, eval_context, shell_state)) orelse return semanticUnsupported(allocator, "semantic parser lowering returned no body");
        defer body.deinit();

        if (semanticBodyUnsupportedMessage(body, eval_context.interactive)) |message| return semanticUnsupported(allocator, message);
        const body_failed = semanticBodyIsFailure(body);

        var command_outcome = if (statement.async_after) blk: {
            var background_plan = (try semanticBackgroundPipelinePlan(allocator, body)) orelse return semanticUnsupported(allocator, "semantic executor production preflight keeps unsupported background statements outside the switched slice");
            defer background_plan.deinit(allocator);
            break :blk shell.eval.evaluatePipelinePlan(evaluator, shell_state, eval_context, background_plan.plan) catch |err| switch (err) {
                error.Unimplemented => return semanticUnsupported(allocator, "semantic evaluator reported an unimplemented background command shape"),
                else => |e| return e,
            };
        } else evaluateSemanticComparisonBody(evaluator, shell_state, eval_context, body) catch |err| switch (err) {
            error.Unimplemented => return semanticUnsupported(allocator, "semantic evaluator reported an unimplemented command shape"),
            else => |e| return e,
        };
        defer command_outcome.deinit();

        command_outcome.validateForContext(eval_context);
        try accumulated_stdout.appendSlice(allocator, command_outcome.stdout.items);
        try accumulated_stderr.appendSlice(allocator, command_outcome.stderr.items);
        status = command_outcome.status;
        control_flow = command_outcome.control_flow;
        switch (control_flow) {
            .exit, .fatal => |exit_status| shell_state.setPendingExit(exit_status),
            .normal, .break_loop, .continue_loop, .return_from_scope => {},
        }

        const outcome_target = command_outcome.state_delta.target;
        if (outcome_target.allowsShellStateCommit() and shell_state.acceptsExecutionTarget(outcome_target)) {
            try command_outcome.commitDelta(shell_state, outcome_target);
        } else {
            std.debug.assert(outcome_target.isIsolatedFromParent());
            command_outcome.discardDelta(outcome_target);
            shell_state.last_status = status;
        }
        shell_state.validate();
        if (control_flow != .normal or body_failed) break;
    }

    control_flow.validate();
    var final_status = control_flow.status(status);
    if (run_exit_trap) try appendSemanticExitTrap(allocator, &accumulated_stdout, &accumulated_stderr, &final_status, evaluator, shell_state, eval_context, resolver);
    const stdout = try accumulated_stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try accumulated_stderr.toOwnedSlice(allocator);
    release_accumulated = true;
    return .{ .output = .{
        .allocator = allocator,
        .status = final_status,
        .stdout = stdout,
        .stderr = stderr,
    } };
}

const SemanticBackgroundPipelinePlan = struct {
    plan: shell.PipelinePlan,
    allocated_stages: []shell.PipelineStagePlan = &.{},

    fn deinit(self: *SemanticBackgroundPipelinePlan, allocator: std.mem.Allocator) void {
        if (self.allocated_stages.len != 0) allocator.free(self.allocated_stages);
        self.* = undefined;
    }
};

fn semanticBackgroundPipelinePlan(allocator: std.mem.Allocator, body: shell.TrapActionBody) !?SemanticBackgroundPipelinePlan {
    body.validate();
    return switch (body) {
        .simple => |plan| try semanticBackgroundSingleStagePlan(allocator, plan),
        .pipeline => |plan| semanticBackgroundPipelineFromPipeline(plan),
        .owned => |owned| switch (owned.body) {
            .simple => |plan| try semanticBackgroundSingleStagePlan(allocator, plan),
            .pipeline => |plan| semanticBackgroundPipelineFromPipeline(plan),
            .compound, .failure => null,
        },
        .compound, .failure => null,
    };
}

fn semanticBackgroundSingleStagePlan(allocator: std.mem.Allocator, plan: shell.CommandPlan) !SemanticBackgroundPipelinePlan {
    plan.validate();
    const stages = try allocator.alloc(shell.PipelineStagePlan, 1);
    errdefer allocator.free(stages);
    stages[0] = .{ .simple = plan };
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

fn appendSemanticExitTrap(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8), status: *shell.ExitStatus, evaluator: *shell.eval.Evaluator, shell_state: *shell.ShellState, eval_context: shell.EvalContext, resolver: shell.TrapActionResolver) !void {
    if (shell_state.getTrapForSignal(.EXIT) == null) return;
    shell_state.last_status = status.*;
    try shell_state.appendPendingTrap(.EXIT);
    var trap_outcome = (try shell.eval.executePendingTraps(evaluator, shell_state, eval_context, resolver)) orelse return;
    defer trap_outcome.deinit();
    try stdout.appendSlice(allocator, trap_outcome.stdout.items);
    try stderr.appendSlice(allocator, trap_outcome.stderr.items);
    status.* = trap_outcome.status;
    try trap_outcome.commitDelta(shell_state, trap_outcome.state_delta.target);
}

fn semanticScriptNeedsAliasTiming(script: []const u8) bool {
    var index: usize = 0;
    while (index < script.len) {
        while (index < script.len and !isSemanticAliasTokenByte(script[index])) index += 1;
        const start = index;
        while (index < script.len and isSemanticAliasTokenByte(script[index])) index += 1;
        const word = script[start..index];
        if (std.mem.eql(u8, word, "alias") or std.mem.eql(u8, word, "unalias") or std.mem.eql(u8, word, "eval") or std.mem.eql(u8, word, ".")) return true;
    }
    return false;
}

fn isSemanticAliasTokenByte(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '_';
}

fn skipSemanticChunkSeparators(script: []const u8, start: usize) usize {
    var index = start;
    while (index < script.len and (script[index] == ' ' or script[index] == '\t' or script[index] == '\r' or script[index] == '\n' or script[index] == ';')) index += 1;
    return index;
}

fn semanticLineEnd(script: []const u8, start: usize) usize {
    var index = start;
    while (index < script.len and script[index] != '\n') index += 1;
    if (index < script.len) index += 1;
    return index;
}

fn extendSemanticHereDocChunk(script: []const u8, start: usize, initial_end: usize) usize {
    var end = initial_end;
    var scan = start;
    while (scan + 1 < end) : (scan += 1) {
        if (script[scan] != '<' or script[scan + 1] != '<') continue;
        var delimiter_start = scan + 2;
        if (delimiter_start < end and script[delimiter_start] == '-') delimiter_start += 1;
        while (delimiter_start < end and (script[delimiter_start] == ' ' or script[delimiter_start] == '\t')) delimiter_start += 1;
        var delimiter_end = delimiter_start;
        while (delimiter_end < end and !isSemanticHereDocDelimiterTerminator(script[delimiter_end])) delimiter_end += 1;
        const raw_delimiter = std.mem.trim(u8, script[delimiter_start..delimiter_end], "'\"");
        if (raw_delimiter.len == 0) continue;
        end = semanticHereDocBodyEnd(script, end, raw_delimiter);
    }
    return end;
}

fn isSemanticHereDocDelimiterTerminator(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == ';' or byte == '|' or byte == '&' or byte == '<' or byte == '>';
}

fn semanticHereDocBodyEnd(script: []const u8, body_start: usize, delimiter: []const u8) usize {
    var line_start = body_start;
    while (line_start < script.len) {
        var line_end = line_start;
        while (line_end < script.len and script[line_end] != '\n') line_end += 1;
        const raw_line = script[line_start..line_end];
        const line = if (raw_line.len != 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        if (std.mem.eql(u8, line, delimiter)) return if (line_end < script.len) line_end + 1 else line_end;
        line_start = if (line_end < script.len) line_end + 1 else line_end;
    }
    return script.len;
}

fn semanticExpandAliases(allocator: std.mem.Allocator, source: []const u8, features: compat.Features, shell_state: *shell.ShellState) ![]const u8 {
    return parser.expandAliases(allocator, source, .{
        .features = features.withStrictDiagnostics(),
        .context = shell_state,
        .lookup = lookupSemanticAlias,
    });
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
        if (!(std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '!' or byte == '%' or byte == ',' or byte == '-' or byte == '@' or byte == '_')) return false;
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

fn semanticStatementSourceEnd(program: ir.Program, statement_index: usize, script_len: usize) usize {
    std.debug.assert(statement_index < program.statements.len);
    const statement = program.statements[statement_index];
    if (!semanticStatementHasHereDoc(program, statement)) return statement.span.end;
    if (statement_index + 1 < program.statements.len) return program.statements[statement_index + 1].span.start;
    return script_len;
}

fn semanticStatementHasHereDoc(program: ir.Program, statement: ir.Statement) bool {
    switch (statement.kind) {
        .pipeline => {
            const pipeline = program.pipelines[statement.index];
            for (pipeline.command_indexes) |command_index| {
                if (semanticCommandHasHereDoc(program.commands[command_index])) return true;
            }
            return false;
        },
        .if_command => return semanticRedirectionsHaveHereDoc(program.if_commands[statement.index].redirections),
        .loop_command => return semanticRedirectionsHaveHereDoc(program.loop_commands[statement.index].redirections),
        .for_command => return semanticRedirectionsHaveHereDoc(program.for_commands[statement.index].redirections),
        .case_command => return semanticRedirectionsHaveHereDoc(program.case_commands[statement.index].redirections),
        .function_definition => return semanticRedirectionsHaveHereDoc(program.function_definitions[statement.index].redirections),
        .brace_group => return semanticRedirectionsHaveHereDoc(program.brace_groups[statement.index].redirections),
        .subshell => return semanticRedirectionsHaveHereDoc(program.subshells[statement.index].redirections),
        .bash_test_command => return false,
    }
}

fn semanticCommandHasHereDoc(command: ir.SimpleCommand) bool {
    return semanticRedirectionsHaveHereDoc(command.redirections);
}

fn semanticRedirectionsHaveHereDoc(redirections: []const ir.Redirection) bool {
    for (redirections) |redirection| if (redirection.here_doc != null) return true;
    return false;
}

fn assertSemanticInteractiveOptions(script: []const u8, invocation: shell.InvocationContext) void {
    invocation.validate();
    std.debug.assert(invocation.interactive);
    std.debug.assert(invocation.arg_zero.len != 0);
    std.debug.assert(script.len == 0 or std.mem.indexOfScalar(u8, script, 0) == null);
}

fn assertSemanticStartupOptions(script: []const u8, invocation: shell.InvocationContext, positionals: []const []const u8) void {
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
    if (program.function_definitions.len != 0) return "semantic interactive executor does not yet preserve function definitions";
    if (shell_state.aliases.count() != 0) return "semantic interactive executor does not yet preserve alias-aware parsing";
    if (shell_state.options.nounset and semanticProgramUsesShellExpansion(program)) return "semantic interactive executor does not yet preserve nounset expansion diagnostics";

    for (program.commands) |command| {
        if (command.argv.len == 0) continue;
        const root = command.argv[0];
        if (shell.builtin.lookup(root.text) != null and !semanticInteractiveBuiltinRootAllowed(root.text)) return "semantic interactive executor reports unsupported builtins as diagnostics";
        if (shell_state.functions.count() != 0) {
            if (wordMayUseShellExpansion(root.raw)) return "semantic interactive executor does not yet preserve dynamic function lookup";
            if (shell_state.functions.contains(root.text)) return "semantic interactive executor does not yet preserve shell function calls";
        }
    }
    return null;
}

fn semanticInteractiveBuiltinRootAllowed(name: []const u8) bool {
    const definition = shell.builtin.lookup(name) orelse return false;
    if (definition.semantic_class == .unsupported) return false;
    if (definition.semantic_class == .job_control or definition.semantic_class == .control_flow) return false;
    if (std.mem.eql(u8, name, "alias") or std.mem.eql(u8, name, "unalias")) return false;
    if (std.mem.eql(u8, name, "local") or std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "unset")) return false;
    if (std.mem.eql(u8, name, "trap")) return false;
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

fn semanticPreflightUnsupported(allocator: std.mem.Allocator, program: ir.Program, features: compat.Features, legacy_fallback_gates: bool) !?[]const u8 {
    if (legacy_fallback_gates and (program.if_commands.len != 0 or program.loop_commands.len != 0 or program.for_commands.len != 0 or program.case_commands.len != 0 or program.brace_groups.len != 0 or program.subshells.len != 0)) {
        return "semantic executor production preflight keeps compound commands unsupported outside the switched slice";
    }
    for (program.statements, 0..) |statement, index| {
        if (semanticAsyncStatementPreflightUnsupported(program, statement, index)) |message| return message;
    }
    if (legacy_fallback_gates) {
        for (program.commands) |command| {
            if (commandUsesUnsupportedSemanticBuiltin(command, false)) return "semantic executor preflight found an unsupported builtin";
            if (commandUsesUnsupportedProductionExpansion(command)) return "semantic executor production preflight found an expansion shape outside the switched slice";
            if (command.argv.len == 0 and command.redirections.len != 0) return "semantic executor does not yet support redirection-only commands";
        }
    }
    for (program.function_definitions) |definition| {
        if (try semanticFunctionDefinitionPreflightUnsupported(allocator, definition, features)) |message| return message;
    }
    if (program.bash_test_commands.len != 0) return "semantic executor does not yet lower bash [[ ]] commands";
    return null;
}

fn semanticFunctionDefinitionPreflightUnsupported(allocator: std.mem.Allocator, definition: ir.FunctionDefinition, features: compat.Features) !?[]const u8 {
    var parsed = try parser.parse(allocator, definition.body, .{ .features = features.withStrictDiagnostics() });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) return "semantic executor production preflight keeps parser-rejected function bodies on the old executor";

    var body_program = try ir.lowerSimpleCommands(allocator, parsed);
    defer body_program.deinit();
    return semanticFunctionBodyProgramUnsupported(allocator, body_program, features);
}

fn semanticFunctionBodyProgramUnsupported(allocator: std.mem.Allocator, program: ir.Program, features: compat.Features) !?[]const u8 {
    for (program.statements, 0..) |statement, index| {
        if (semanticAsyncStatementPreflightUnsupported(program, statement, index)) |message| return message;
        if (statement.kind == .function_definition and statement.op_before != .sequence) return "semantic executor production preflight keeps dynamically guarded function definitions on the old executor";
    }
    for (program.function_definitions) |definition| {
        if (try semanticFunctionDefinitionPreflightUnsupported(allocator, definition, features)) |message| return message;
    }
    if (program.bash_test_commands.len != 0) return "semantic executor does not yet lower bash [[ ]] commands";
    return null;
}

fn semanticProgramHasCompoundRedirections(program: ir.Program) bool {
    for (program.if_commands) |command| if (command.redirections.len != 0) return true;
    for (program.loop_commands) |command| if (command.redirections.len != 0) return true;
    for (program.for_commands) |command| if (command.redirections.len != 0) return true;
    for (program.case_commands) |command| if (command.redirections.len != 0) return true;
    for (program.brace_groups) |group| if (group.redirections.len != 0) return true;
    for (program.subshells) |subshell| if (subshell.redirections.len != 0) return true;
    return false;
}

fn semanticProgramHasLoopDependentExpansion(program: ir.Program) bool {
    for (program.for_commands) |command| {
        if (!command.use_positionals) {
            for (command.words) |word| if (wordUsesUnsupportedForWordExpansion(word.raw)) return true;
        }
    }
    for (program.loop_commands) |command| {
        if (std.mem.indexOfScalar(u8, command.condition, '$') != null) return true;
        if (std.mem.indexOfScalar(u8, command.body, '$') != null) return true;
    }
    return false;
}

fn wordUsesUnsupportedForWordExpansion(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "$(") != null or
        std.mem.indexOfScalar(u8, raw, '`') != null or
        std.mem.indexOf(u8, raw, "${") != null or
        std.mem.indexOf(u8, raw, "$((") != null;
}

fn semanticAsyncStatementPreflightUnsupported(program: ir.Program, statement: ir.Statement, index: usize) ?[]const u8 {
    std.debug.assert(index < program.statements.len);
    if (!statement.async_after) return null;
    if (statement.kind != .pipeline) return "semantic executor production preflight keeps non-pipeline background statements unsupported outside the switched slice";
    return null;
}

fn semanticPipelinePreflightUnsupported(program: ir.Program, pipeline: ir.Pipeline) ?[]const u8 {
    std.debug.assert(program.commands.len != 0 or pipeline.command_indexes.len == 0);
    if (pipeline.stage_spans.len == 0) {
        return "semantic executor production preflight keeps empty pipelines unsupported outside the switched slice";
    }
    if (pipeline.command_indexes.len > pipeline.stage_spans.len) return "semantic executor production preflight keeps malformed pipelines unsupported outside the switched slice";
    for (pipeline.stage_spans) |stage_span| {
        if (wordUsesUnsupportedProductionExpansion(stage_span.slice(program.source))) return "semantic executor production preflight found an expansion shape outside the switched slice";
    }
    for (pipeline.command_indexes) |command_index| std.debug.assert(command_index < program.commands.len);
    return null;
}

fn commandUsesUnsupportedSemanticBuiltin(command: ir.SimpleCommand, allow_interactive_declarations: bool) bool {
    if (command.argv.len == 0) return false;
    const name = command.argv[0].text;
    const definition = shell.builtin.lookup(name) orelse return false;
    return switch (definition.semantic_class) {
        .unsupported, .predicate, .shell_state, .job_control, .control_flow => true,
        .declaration => !allow_interactive_declarations,
        .no_op, .status_constant, .output => false,
    };
}

fn commandUsesUnsupportedProductionExpansion(command: ir.SimpleCommand) bool {
    for (command.argv) |word| {
        if (wordUsesUnsupportedProductionExpansion(word.raw)) return true;
    }
    for (command.assignments) |word| {
        if (wordUsesUnsupportedProductionExpansion(word.raw)) return true;
    }
    return false;
}

fn wordUsesUnsupportedProductionExpansion(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "$(") != null or
        std.mem.indexOfScalar(u8, raw, '`') != null or
        std.mem.indexOf(u8, raw, "${") != null or
        std.mem.indexOf(u8, raw, "$((") != null or
        std.mem.indexOf(u8, raw, "$@") != null or
        std.mem.indexOf(u8, raw, "$*") != null;
}

fn semanticBodyUnsupportedMessage(body: shell.TrapActionBody, legacy_fallback_gates: bool) ?[]const u8 {
    body.validate();
    return switch (body) {
        .simple => |plan| semanticCommandUnsupportedMessage(plan, legacy_fallback_gates),
        .compound => |plan| semanticCompoundUnsupportedMessage(plan, legacy_fallback_gates),
        .pipeline => |plan| semanticPipelineUnsupportedMessage(plan, legacy_fallback_gates),
        .owned => |owned| switch (owned.body) {
            .simple => |plan| semanticCommandUnsupportedMessage(plan, legacy_fallback_gates),
            .compound => |plan| semanticCompoundUnsupportedMessage(plan, legacy_fallback_gates),
            .pipeline => |plan| semanticPipelineUnsupportedMessage(plan, legacy_fallback_gates),
            .failure => null,
        },
        .failure => null,
    };
}

fn semanticBodyIsFailure(body: shell.TrapActionBody) bool {
    body.validate();
    return switch (body) {
        .failure => true,
        .owned => |owned| owned.body == .failure,
        .simple, .compound, .pipeline => false,
    };
}

fn semanticPipelineUnsupportedMessage(plan: shell.PipelinePlan, legacy_fallback_gates: bool) ?[]const u8 {
    plan.validate();
    for (plan.stages) |stage| switch (stage) {
        .simple => |simple| if (semanticCommandUnsupportedMessage(simple, legacy_fallback_gates)) |message| return message,
        .compound => |compound| if (semanticCompoundUnsupportedMessage(compound, legacy_fallback_gates)) |message| return message,
    };
    return null;
}

fn semanticCompoundUnsupportedMessage(plan: shell.CompoundCommandPlan, legacy_fallback_gates: bool) ?[]const u8 {
    plan.validate();
    if (legacy_fallback_gates and (plan.redirections.steps.len != 0 or plan.redirections.rollback_steps.len != 0)) return "semantic executor production preflight keeps compound redirections unsupported outside the switched slice";
    switch (plan.body) {
        .sequence, .brace_group, .subshell => |list| return semanticCommandListUnsupportedMessage(list, legacy_fallback_gates),
        .and_or_list => |and_or| for (and_or.commands) |entry| {
            if (semanticCommandUnsupportedMessage(entry.command, legacy_fallback_gates)) |message| return message;
        },
        .negation => |negation| return semanticCommandListUnsupportedMessage(negation.body, legacy_fallback_gates),
        .if_clause => |if_plan| {
            for (if_plan.branches) |branch| {
                if (semanticCommandListUnsupportedMessage(branch.condition, legacy_fallback_gates)) |message| return message;
                if (semanticCommandListUnsupportedMessage(branch.body, legacy_fallback_gates)) |message| return message;
            }
            return semanticCommandListUnsupportedMessage(if_plan.else_body, legacy_fallback_gates);
        },
        .while_loop, .until_loop => |loop| {
            if (semanticCommandListUnsupportedMessage(loop.condition, legacy_fallback_gates)) |message| return message;
            return semanticCommandListUnsupportedMessage(loop.body, legacy_fallback_gates);
        },
        .for_loop => |for_plan| return semanticCommandListUnsupportedMessage(for_plan.body, legacy_fallback_gates),
        .case_clause => |case_plan| for (case_plan.arms) |arm| {
            if (semanticCommandListUnsupportedMessage(arm.body, legacy_fallback_gates)) |message| return message;
        },
    }
    return null;
}

fn semanticCommandListUnsupportedMessage(list: shell.StatementList, legacy_fallback_gates: bool) ?[]const u8 {
    list.validate();
    for (list.commands) |command| {
        if (semanticCommandUnsupportedMessage(command, legacy_fallback_gates)) |message| return message;
    }
    for (list.statements) |entry| {
        switch (entry.plan) {
            .simple => |plan| if (semanticCommandUnsupportedMessage(plan, legacy_fallback_gates)) |message| return message,
            .compound => |plan| if (semanticCompoundUnsupportedMessage(plan, legacy_fallback_gates)) |message| return message,
            .pipeline => |plan| if (semanticPipelineUnsupportedMessage(plan, legacy_fallback_gates)) |message| return message,
        }
    }
    return null;
}

fn semanticCommandUnsupportedMessage(plan: shell.CommandPlan, legacy_fallback_gates: bool) ?[]const u8 {
    plan.validate();
    return switch (plan.classification) {
        .regular_builtin, .special_builtin => |definition| blk: {
            if (definition.semantic_class == .unsupported) break :blk "semantic evaluator does not yet implement this builtin";
            if (legacy_fallback_gates and std.mem.eql(u8, definition.name, "read")) break :blk "semantic evaluator does not yet connect read to non-interactive stdin";
            if (legacy_fallback_gates and (std.mem.eql(u8, definition.name, "alias") or std.mem.eql(u8, definition.name, "unalias"))) break :blk "semantic evaluator does not yet integrate alias expansion with production parsing";
            break :blk null;
        },
        .empty, .assignment_only => null,
        .function_definition => |definition| if (definition.source_body == null) "semantic evaluator does not yet receive owned production function definitions" else null,
        .function, .external, .not_found => null,
    };
}

fn evaluateSemanticComparisonBody(evaluator: *shell.eval.Evaluator, shell_state: *shell.ShellState, eval_context: shell.EvalContext, body: shell.TrapActionBody) shell.eval.EvalError!shell.CommandOutcome {
    body.validate();
    eval_context.validate();
    return switch (body) {
        .simple => |plan| shell.eval.evaluatePlan(evaluator, shell_state, eval_context.withTarget(plan.target), plan),
        .compound => |plan| shell.eval.evaluateCompoundPlan(evaluator, shell_state, eval_context.withTarget(plan.target), plan),
        .pipeline => |plan| shell.eval.evaluatePipelinePlan(evaluator, shell_state, eval_context, plan),
        .owned => |owned| switch (owned.body) {
            .simple => |plan| shell.eval.evaluatePlan(evaluator, shell_state, eval_context.withTarget(plan.target), plan),
            .compound => |plan| shell.eval.evaluateCompoundPlan(evaluator, shell_state, eval_context.withTarget(plan.target), plan),
            .pipeline => |plan| shell.eval.evaluatePipelinePlan(evaluator, shell_state, eval_context, plan),
            .failure => |failure| shell.eval.trapActionFailureOutcome(evaluator.allocator, eval_context, failure),
        },
        .failure => |failure| shell.eval.trapActionFailureOutcome(evaluator.allocator, eval_context, failure),
    };
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

pub fn parseDiagnostics(allocator: std.mem.Allocator, script: []const u8, diagnostics: []const parser.Diagnostic) !CommandResult {
    var stderr_buffer: std.ArrayList(u8) = .empty;
    defer stderr_buffer.deinit(allocator);

    for (diagnostics) |diagnostic| {
        const line = try std.fmt.allocPrint(allocator, "rush: {s}: {s}\n", .{
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

fn appendDiagnosticSource(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8, span: parser.Span) !void {
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

fn diagnosticLineEnd(source: []const u8, offset: usize) usize {
    var index = @min(offset, source.len);
    while (index < source.len and source[index] != '\n') index += 1;
    return index;
}
