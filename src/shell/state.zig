//! Mutable shell state for direct evaluation.

const std = @import("std");

const ast = @import("ast.zig");
const host = @import("../host.zig");
const memory = @import("memory.zig");
const result = @import("result.zig");
const source = @import("source.zig");

pub const Mode = enum {
    posix,
    bash,
};

pub const Options = struct {
    mode: Mode = .bash,
    allexport: bool = false,
    errexit: bool = false,
    hashall: bool = false,
    nounset: bool = false,
    noglob: bool = false,
    noclobber: bool = false,
    noexec: bool = false,
    pipefail: bool = false,
    notify: bool = false,
    verbose: bool = false,
    expand_aliases: bool = false,
    xtrace: bool = false,
    monitor: bool = false,
    interactive: bool = false,
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    exported: bool = false,
    readonly: bool = false,

    pub fn validate(self: Variable) void {
        std.debug.assert(self.name.len != 0);
    }
};

pub const VariableAttributes = struct {
    name: []const u8,
    exported: bool = false,
    readonly: bool = false,

    pub fn validate(self: VariableAttributes) void {
        std.debug.assert(self.name.len != 0);
        std.debug.assert(self.exported or self.readonly);
    }
};

const SavedLocalBinding = struct {
    name: []const u8,
    variable: ?Variable = null,
    attributes: ?VariableAttributes = null,

    fn deinit(self: SavedLocalBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.variable) |variable| {
            allocator.free(variable.name);
            allocator.free(variable.value);
        }
        if (self.attributes) |attributes| allocator.free(attributes.name);
    }
};

const LocalFrame = struct {
    saved: std.StringHashMapUnmanaged(SavedLocalBinding) = .empty,
    assignment_prefixes: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *LocalFrame, allocator: std.mem.Allocator) void {
        var saved_iterator = self.saved.iterator();
        while (saved_iterator.next()) |entry| entry.value_ptr.deinit(allocator);
        self.saved.deinit(allocator);

        var prefix_iterator = self.assignment_prefixes.iterator();
        while (prefix_iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        self.assignment_prefixes.deinit(allocator);
        self.* = undefined;
    }
};

pub const Function = struct {
    name: []const u8,
    source_text: []const u8,
    definition: ast.FunctionDefinition,

    pub fn validate(self: Function) void {
        std.debug.assert(self.name.len != 0);
        std.debug.assert(self.source_text.len != 0);
        self.definition.validate();
        std.debug.assert(std.mem.eql(u8, self.name, self.definition.name));
    }
};

pub const Alias = struct {
    name: []const u8,
    value: []const u8,

    pub fn validate(self: Alias) void {
        std.debug.assert(self.name.len != 0);
    }
};

pub const CommandHash = struct {
    name: []const u8,
    path: []const u8,

    pub fn validate(self: CommandHash) void {
        std.debug.assert(self.name.len != 0);
        std.debug.assert(self.path.len != 0);
    }
};

pub const JobStatus = enum {
    running,
    stopped,
};

pub const BackgroundJob = struct {
    id: usize,
    pid: host.Pid,
    process_group: host.Pid,
    job_control: bool,
    pids: std.ArrayListUnmanaged(host.Pid) = .empty,
    status: JobStatus = .running,
    command: []const u8,

    pub fn validate(self: BackgroundJob) void {
        std.debug.assert(self.id != 0);
        std.debug.assert(self.pid != 0);
        std.debug.assert(self.process_group != 0);
        std.debug.assert(self.pids.items.len != 0);
        std.debug.assert(self.command.len != 0);
    }

    fn deinit(self: *BackgroundJob, allocator: std.mem.Allocator) void {
        self.pids.deinit(allocator);
        allocator.free(self.command);
        self.* = undefined;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    definition_arena: memory.Arena,
    options: Options = .{},
    variables: std.StringHashMapUnmanaged(Variable) = .empty,
    variable_attributes: std.StringHashMapUnmanaged(VariableAttributes) = .empty,
    local_frames: std.ArrayListUnmanaged(LocalFrame) = .empty,
    functions: std.StringHashMapUnmanaged(Function) = .empty,
    suppressed_autoload_functions: std.StringHashMapUnmanaged(void) = .empty,
    aliases: std.StringHashMapUnmanaged(Alias) = .empty,
    command_hashes: std.StringHashMapUnmanaged(CommandHash) = .empty,
    signal_traps: std.StringHashMapUnmanaged([]const u8) = .empty,
    pending_traps: std.ArrayListUnmanaged([]const u8) = .empty,
    background_pids: std.ArrayListUnmanaged(host.Pid) = .empty,
    background_jobs: std.ArrayListUnmanaged(BackgroundJob) = .empty,
    last_status: result.ExitStatus = 0,
    last_status_errexit_ignored: bool = false,
    last_background_pid: ?host.Pid = null,
    getopts_char_index: usize = 1,
    errexit_ignore_depth: usize = 0,
    loop_depth: usize = 0,
    diagnostic_line_offset: usize = 0,
    root_source_kind: ?source.SourceKind = null,
    exit_trap: ?[]const u8 = null,
    exit_trap_listing: ?[]const u8 = null,
    running_exit_trap: bool = false,
    running_signal_trap: bool = false,
    shell_pid: ?host.Pid = null,
    parent_pid: ?host.Pid = null,
    arg_zero: []const u8 = "rush",
    positionals: []const []const u8 = &.{},
    owned_positionals: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, options: Options) State {
        return .{
            .allocator = allocator,
            .definition_arena = memory.Arena.init(allocator),
            .options = options,
        };
    }

    pub fn deinit(self: *State) void {
        var iterator = self.variables.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.value);
        }
        self.variables.deinit(self.allocator);
        var attributes_iterator = self.variable_attributes.iterator();
        while (attributes_iterator.next()) |entry| self.allocator.free(entry.value_ptr.name);
        self.variable_attributes.deinit(self.allocator);
        for (self.local_frames.items) |*frame| frame.deinit(self.allocator);
        self.local_frames.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        var suppressed_iterator = self.suppressed_autoload_functions.iterator();
        while (suppressed_iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.suppressed_autoload_functions.deinit(self.allocator);
        var alias_iterator = self.aliases.iterator();
        while (alias_iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.value);
        }
        self.aliases.deinit(self.allocator);
        var command_hash_iterator = self.command_hashes.iterator();
        while (command_hash_iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.path);
        }
        self.command_hashes.deinit(self.allocator);
        var signal_trap_iterator = self.signal_traps.iterator();
        while (signal_trap_iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.signal_traps.deinit(self.allocator);
        self.pending_traps.deinit(self.allocator);
        self.background_pids.deinit(self.allocator);
        for (self.background_jobs.items) |*job| job.deinit(self.allocator);
        self.background_jobs.deinit(self.allocator);
        self.freeOwnedPositionals();
        self.clearExitTrap();
        self.definition_arena.deinit();
        self.* = undefined;
    }

    pub fn definitionAllocator(self: *State) std.mem.Allocator {
        return self.definition_arena.allocator();
    }

    pub fn getVariable(self: State, name: []const u8) ?Variable {
        std.debug.assert(name.len != 0);
        return self.variables.get(name);
    }

    pub fn getVariableAttributes(self: State, name: []const u8) ?VariableAttributes {
        std.debug.assert(name.len != 0);
        return self.variable_attributes.get(name);
    }

    pub fn putVariable(self: *State, variable: Variable) !void {
        variable.validate();
        const attributes = self.getVariableAttributes(variable.name);
        if (attributes) |attribute| {
            if (attribute.readonly) return error.ReadonlyVariable;
        }
        const owned_value = try self.allocator.dupe(u8, variable.value);
        errdefer self.allocator.free(owned_value);

        if (self.variables.getPtr(variable.name)) |existing| {
            if (existing.readonly and !std.mem.eql(u8, existing.value, variable.value)) return error.ReadonlyVariable;
            self.allocator.free(existing.value);
            existing.value = owned_value;
            existing.exported = variable.exported or (attributes != null and attributes.?.exported);
            existing.readonly = variable.readonly or (attributes != null and attributes.?.readonly);
            self.removeVariableAttributes(variable.name);
            return;
        }

        const owned_name = try self.allocator.dupe(u8, variable.name);
        errdefer self.allocator.free(owned_name);

        try self.variables.put(self.allocator, owned_name, .{
            .name = owned_name,
            .value = owned_value,
            .exported = variable.exported or (attributes != null and attributes.?.exported),
            .readonly = variable.readonly or (attributes != null and attributes.?.readonly),
        });
        self.removeVariableAttributes(variable.name);
    }

    pub fn removeVariable(self: *State, name: []const u8) void {
        std.debug.assert(name.len != 0);
        if (self.variables.fetchRemove(name)) |entry| {
            self.allocator.free(entry.value.name);
            self.allocator.free(entry.value.value);
        }
        self.removeVariableAttributes(name);
    }

    pub fn putVariableAttributes(self: *State, attributes: VariableAttributes) !void {
        attributes.validate();
        if (self.variables.getPtr(attributes.name)) |variable| {
            variable.exported = variable.exported or attributes.exported;
            variable.readonly = variable.readonly or attributes.readonly;
            return;
        }
        if (self.variable_attributes.getPtr(attributes.name)) |existing| {
            existing.exported = existing.exported or attributes.exported;
            existing.readonly = existing.readonly or attributes.readonly;
            return;
        }
        const owned_name = try self.allocator.dupe(u8, attributes.name);
        errdefer self.allocator.free(owned_name);
        try self.variable_attributes.put(self.allocator, owned_name, .{
            .name = owned_name,
            .exported = attributes.exported,
            .readonly = attributes.readonly,
        });
    }

    pub fn removeVariableAttributes(self: *State, name: []const u8) void {
        if (self.variable_attributes.fetchRemove(name)) |entry| self.allocator.free(entry.value.name);
    }

    pub fn pushLocalFrame(self: *State, assignment_prefixes: []const []const u8) !void {
        var frame: LocalFrame = .{};
        errdefer frame.deinit(self.allocator);

        for (assignment_prefixes) |name| {
            if (frame.assignment_prefixes.contains(name)) continue;
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            try frame.assignment_prefixes.put(self.allocator, owned_name, {});
        }

        try self.local_frames.append(self.allocator, frame);
    }

    pub fn popLocalFrame(self: *State) void {
        std.debug.assert(self.local_frames.items.len != 0);
        var frame = self.local_frames.pop().?;
        defer frame.deinit(self.allocator);

        var entries: std.ArrayList(SavedLocalBinding) = .empty;
        defer entries.deinit(self.allocator);

        var iterator = frame.saved.iterator();
        while (iterator.next()) |entry| entries.append(self.allocator, entry.value_ptr.*) catch unreachable;

        var index = entries.items.len;
        while (index != 0) {
            index -= 1;
            const binding = entries.items[index];
            self.removeVariable(binding.name);
            self.removeVariableAttributes(binding.name);
            if (binding.variable) |variable| {
                self.putVariable(variable) catch unreachable;
            } else if (binding.attributes) |attributes| {
                self.putVariableAttributes(attributes) catch unreachable;
            }
        }
    }

    pub fn hasLocalFrame(self: State) bool {
        return self.local_frames.items.len != 0;
    }

    pub fn declareLocal(self: *State, name: []const u8, value: ?[]const u8) !void {
        std.debug.assert(name.len != 0);
        if (self.getVariable(name)) |variable| if (variable.readonly) return error.ReadonlyVariable;
        if (self.getVariableAttributes(name)) |attributes| if (attributes.readonly) return error.ReadonlyVariable;
        const frame = self.currentLocalFrame();
        try self.saveLocalBinding(frame, name);

        if (value) |local_value| {
            try self.putVariable(.{ .name = name, .value = local_value });
        } else if (!frame.assignment_prefixes.contains(name)) {
            self.removeVariable(name);
        }
    }

    fn currentLocalFrame(self: *State) *LocalFrame {
        std.debug.assert(self.local_frames.items.len != 0);
        return &self.local_frames.items[self.local_frames.items.len - 1];
    }

    fn saveLocalBinding(self: *State, frame: *LocalFrame, name: []const u8) !void {
        if (frame.saved.contains(name)) return;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const variable = if (self.getVariable(name)) |existing| variable: {
            const owned_variable_name = try self.allocator.dupe(u8, existing.name);
            errdefer self.allocator.free(owned_variable_name);
            const owned_value = try self.allocator.dupe(u8, existing.value);
            errdefer self.allocator.free(owned_value);
            break :variable Variable{
                .name = owned_variable_name,
                .value = owned_value,
                .exported = existing.exported,
                .readonly = existing.readonly,
            };
        } else null;
        errdefer if (variable) |saved_variable| {
            self.allocator.free(saved_variable.name);
            self.allocator.free(saved_variable.value);
        };

        const attributes = if (self.getVariableAttributes(name)) |existing| attributes: {
            const owned_attributes_name = try self.allocator.dupe(u8, existing.name);
            errdefer self.allocator.free(owned_attributes_name);
            break :attributes VariableAttributes{
                .name = owned_attributes_name,
                .exported = existing.exported,
                .readonly = existing.readonly,
            };
        } else null;
        errdefer if (attributes) |saved_attributes| self.allocator.free(saved_attributes.name);

        try frame.saved.put(self.allocator, owned_name, .{
            .name = owned_name,
            .variable = variable,
            .attributes = attributes,
        });
    }

    pub fn setPositionals(self: *State, positionals: []const []const u8) !void {
        const owned = try self.allocator.alloc([]const u8, positionals.len);
        errdefer self.allocator.free(owned);

        var copied: usize = 0;
        errdefer for (owned[0..copied]) |item| self.allocator.free(item);

        for (positionals, 0..) |positional, index| {
            owned[index] = try self.allocator.dupe(u8, positional);
            copied += 1;
        }

        self.freeOwnedPositionals();
        self.owned_positionals = owned;
        self.positionals = owned;
    }

    fn freeOwnedPositionals(self: *State) void {
        for (self.owned_positionals) |positional| self.allocator.free(positional);
        self.allocator.free(self.owned_positionals);
        self.owned_positionals = &.{};
    }

    pub fn getFunction(self: State, name: []const u8) ?Function {
        std.debug.assert(name.len != 0);
        return self.functions.get(name);
    }

    /// Installs a function definition whose name, source text, and AST storage
    /// have already been allocated from `definitionAllocator()`.
    pub fn putPersistentFunction(self: *State, function: Function) !void {
        function.validate();
        try self.functions.put(self.allocator, function.name, function);
        self.unsuppressFunctionAutoload(function.name);
    }

    pub fn removeFunction(self: *State, name: []const u8) void {
        std.debug.assert(name.len != 0);
        _ = self.functions.remove(name);
    }

    pub fn suppressFunctionAutoload(self: *State, name: []const u8) !void {
        std.debug.assert(name.len != 0);
        if (self.suppressed_autoload_functions.contains(name)) return;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.suppressed_autoload_functions.put(self.allocator, owned_name, {});
    }

    pub fn isFunctionAutoloadSuppressed(self: State, name: []const u8) bool {
        std.debug.assert(name.len != 0);
        return self.suppressed_autoload_functions.contains(name);
    }

    fn unsuppressFunctionAutoload(self: *State, name: []const u8) void {
        if (self.suppressed_autoload_functions.fetchRemove(name)) |entry| self.allocator.free(entry.key);
    }

    pub fn getAlias(self: State, name: []const u8) ?Alias {
        std.debug.assert(name.len != 0);
        return self.aliases.get(name);
    }

    pub fn putAlias(self: *State, alias: Alias) !void {
        alias.validate();
        const owned_value = try self.allocator.dupe(u8, alias.value);
        errdefer self.allocator.free(owned_value);

        if (self.aliases.getPtr(alias.name)) |existing| {
            self.allocator.free(existing.value);
            existing.value = owned_value;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, alias.name);
        errdefer self.allocator.free(owned_name);

        try self.aliases.put(self.allocator, owned_name, .{
            .name = owned_name,
            .value = owned_value,
        });
    }

    pub fn removeAlias(self: *State, name: []const u8) bool {
        std.debug.assert(name.len != 0);
        if (self.aliases.fetchRemove(name)) |entry| {
            self.allocator.free(entry.value.name);
            self.allocator.free(entry.value.value);
            return true;
        }
        return false;
    }

    pub fn clearAliases(self: *State) void {
        var iterator = self.aliases.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.value);
        }
        self.aliases.clearRetainingCapacity();
    }

    pub fn putCommandHash(self: *State, command_hash: CommandHash) !void {
        command_hash.validate();
        const owned_path = try self.allocator.dupe(u8, command_hash.path);
        errdefer self.allocator.free(owned_path);

        if (self.command_hashes.getPtr(command_hash.name)) |existing| {
            self.allocator.free(existing.path);
            existing.path = owned_path;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, command_hash.name);
        errdefer self.allocator.free(owned_name);

        try self.command_hashes.put(self.allocator, owned_name, .{
            .name = owned_name,
            .path = owned_path,
        });
    }

    pub fn clearCommandHashes(self: *State) void {
        var iterator = self.command_hashes.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.path);
        }
        self.command_hashes.clearRetainingCapacity();
    }

    pub fn setExitTrap(self: *State, action: []const u8) !void {
        const owned = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(owned);
        const listed = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(listed);
        self.clearExitTrap();
        self.exit_trap = owned;
        self.exit_trap_listing = listed;
    }

    pub fn clearExitTrap(self: *State) void {
        if (self.exit_trap) |action| self.allocator.free(action);
        self.exit_trap = null;
        if (self.exit_trap_listing) |action| self.allocator.free(action);
        self.exit_trap_listing = null;
    }

    pub fn forgetActiveExitTrap(self: *State) void {
        self.exit_trap = null;
    }

    pub fn getSignalTrap(self: State, name: []const u8) ?[]const u8 {
        return self.signal_traps.get(name);
    }

    pub fn setSignalTrap(self: *State, name: []const u8, action: []const u8) !void {
        const owned_action = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(owned_action);
        if (self.signal_traps.getPtr(name)) |existing| {
            self.allocator.free(existing.*);
            existing.* = owned_action;
            return;
        }
        try self.signal_traps.put(self.allocator, name, owned_action);
    }

    pub fn clearSignalTrap(self: *State, name: []const u8) void {
        if (self.signal_traps.fetchRemove(name)) |entry| self.allocator.free(entry.value);
    }

    pub fn clearSignalTraps(self: *State) void {
        var iterator = self.signal_traps.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.signal_traps.clearRetainingCapacity();
        self.pending_traps.clearRetainingCapacity();
    }

    pub fn queueTrap(self: *State, name: []const u8) !void {
        try self.pending_traps.append(self.allocator, name);
    }

    pub fn popPendingTrap(self: *State) ?[]const u8 {
        if (self.pending_traps.items.len == 0) return null;
        const name = self.pending_traps.items[0];
        // ziglint-ignore: Z011 Z024 deprecated API left unchanged to avoid semantic drift in lint-only pass; preserve existing readable expression shape; lint-only cleanup
        std.mem.copyForwards([]const u8, self.pending_traps.items[0 .. self.pending_traps.items.len - 1], self.pending_traps.items[1..]);
        self.pending_traps.items.len -= 1;
        return name;
    }

    pub fn addBackgroundPid(self: *State, pid: host.Pid) !void {
        try self.background_pids.append(self.allocator, pid);
    }

    pub fn addBackgroundJob(self: *State, pid: host.Pid, command: []const u8, job_control: bool) !void {
        try self.addBackgroundJobPids(&.{pid}, pid, command, job_control);
    }

    pub fn addBackgroundJobPids(
        self: *State,
        pids: []const host.Pid,
        process_group: host.Pid,
        command: []const u8,
        job_control: bool,
    ) !void {
        std.debug.assert(pids.len != 0);
        std.debug.assert(process_group != 0);
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);
        // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift in lint-only pass
        var owned_pids: std.ArrayListUnmanaged(host.Pid) = .empty;
        errdefer owned_pids.deinit(self.allocator);
        try owned_pids.appendSlice(self.allocator, pids);
        const job: BackgroundJob = .{
            .id = self.nextAvailableJobId(),
            .pid = pids[pids.len - 1],
            .process_group = process_group,
            .job_control = job_control,
            .pids = owned_pids,
            .status = .running,
            .command = owned_command,
        };
        job.validate();
        try self.background_jobs.append(self.allocator, job);
    }

    fn nextAvailableJobId(self: State) usize {
        var id: usize = 1;
        while (true) : (id += 1) {
            for (self.background_jobs.items) |job| {
                if (job.id == id) break;
            } else return id;
        }
    }

    pub fn removeBackgroundPid(self: *State, pid: host.Pid) bool {
        var removed = false;
        for (self.background_pids.items, 0..) |known, index| {
            if (known != pid) continue;
            _ = self.background_pids.orderedRemove(index);
            removed = true;
            break;
        }
        return self.removePidFromBackgroundJobs(pid) or removed;
    }

    fn removePidFromBackgroundJobs(self: *State, pid: host.Pid) bool {
        for (self.background_jobs.items, 0..) |*job, job_index| {
            for (job.pids.items, 0..) |job_pid, pid_index| {
                if (job_pid != pid) continue;
                _ = job.pids.orderedRemove(pid_index);
                if (job.pids.items.len == 0) {
                    var removed_job = self.background_jobs.orderedRemove(job_index);
                    removed_job.deinit(self.allocator);
                } else if (job.pid == pid) {
                    job.pid = job.pids.items[job.pids.items.len - 1];
                }
                return true;
            }
        }
        return false;
    }

    pub fn backgroundJobPid(self: State, job_id: usize) ?host.Pid {
        for (self.background_jobs.items) |job| if (job.id == job_id) return job.pid;
        return null;
    }

    pub fn backgroundJob(self: State, job_id: usize) ?BackgroundJob {
        for (self.background_jobs.items) |job| if (job.id == job_id) return job;
        return null;
    }

    pub fn resolveJobSpec(self: State, spec: []const u8) ?BackgroundJob {
        if (spec.len < 2 or spec[0] != '%') return null;
        const selector = spec[1..];
        if (std.mem.eql(u8, selector, "%") or std.mem.eql(u8, selector, "+")) return self.currentBackgroundJob();
        if (std.mem.eql(u8, selector, "-")) return self.previousBackgroundJob();
        if (std.fmt.parseInt(usize, selector, 10)) |job_id| {
            return self.backgroundJob(job_id);
        } else |_| {}
        if (selector[0] == '?') {
            if (selector.len == 1) return null;
            return self.findBackgroundJobContaining(selector[1..]);
        }
        return self.findBackgroundJobStartingWith(selector);
    }

    pub fn currentBackgroundJob(self: State) ?BackgroundJob {
        if (self.background_jobs.items.len == 0) return null;
        if (self.recentBackgroundJobWithStatus(.stopped, null)) |job| return job;
        return self.background_jobs.items[self.background_jobs.items.len - 1];
    }

    pub fn previousBackgroundJob(self: State) ?BackgroundJob {
        const current = self.currentBackgroundJob() orelse return null;
        if (self.recentBackgroundJobWithStatus(.stopped, current.id)) |job| return job;
        var index = self.background_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.background_jobs.items[index];
            if (job.id != current.id) return job;
        }
        return null;
    }

    pub fn backgroundJobMarker(self: State, job_id: usize) u8 {
        if (self.currentBackgroundJob()) |job| {
            if (job.id == job_id) return '+';
        }
        if (self.previousBackgroundJob()) |job| {
            if (job.id == job_id) return '-';
        }
        return ' ';
    }

    fn recentBackgroundJobWithStatus(self: State, status: JobStatus, excluded_id: ?usize) ?BackgroundJob {
        var index = self.background_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.background_jobs.items[index];
            if (excluded_id != null and job.id == excluded_id.?) continue;
            if (job.status == status) return job;
        }
        return null;
    }

    fn findBackgroundJobStartingWith(self: State, prefix: []const u8) ?BackgroundJob {
        if (prefix.len == 0) return null;
        var index = self.background_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.background_jobs.items[index];
            if (std.mem.startsWith(u8, job.command, prefix)) return job;
        }
        return null;
    }

    fn findBackgroundJobContaining(self: State, needle: []const u8) ?BackgroundJob {
        std.debug.assert(needle.len != 0);
        var index = self.background_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.background_jobs.items[index];
            if (std.mem.indexOf(u8, job.command, needle) != null) return job;
        }
        return null;
    }

    pub fn setBackgroundJobStatusByPid(self: *State, pid: host.Pid, status: JobStatus) bool {
        for (self.background_jobs.items) |*job| {
            for (job.pids.items) |job_pid| {
                if (job_pid != pid) continue;
                job.status = status;
                return true;
            }
        }
        return false;
    }

    pub fn setBackgroundJobStatus(self: *State, job_id: usize, status: JobStatus) bool {
        for (self.background_jobs.items) |*job| {
            if (job.id != job_id) continue;
            job.status = status;
            return true;
        }
        return false;
    }

    pub fn forgetBackgroundJob(self: *State, pid: host.Pid) void {
        for (self.background_jobs.items, 0..) |*job, index| {
            if (job.pid != pid) continue;
            var removed_job = self.background_jobs.orderedRemove(index);
            removed_job.deinit(self.allocator);
            return;
        }
    }

    pub fn clearBackgroundPids(self: *State) void {
        self.background_pids.clearRetainingCapacity();
        for (self.background_jobs.items) |*job| job.deinit(self.allocator);
        self.background_jobs.clearRetainingCapacity();
    }
};

test "State replaces variable values without losing the binding" {
    var shell_state = State.init(std.testing.allocator, .{});
    defer shell_state.deinit();

    try shell_state.putVariable(.{ .name = "x", .value = "old" });
    try shell_state.putVariable(.{ .name = "x", .value = "new", .exported = true });

    const variable = shell_state.getVariable("x") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("x", variable.name);
    try std.testing.expectEqualStrings("new", variable.value);
    try std.testing.expect(variable.exported);
}
