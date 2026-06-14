//! Terminal-independent line editor core.

const Self = @This();

const std = @import("std");
const edit_buffer = @import("buffer.zig");
const completion = @import("completion.zig");
const key_mod = @import("key.zig");
const path = @import("path.zig");
const render = @import("render.zig");
const vaxis = @import("vaxis");

const max_vi_macro_depth = 16;

pub const UnderlineStyle = render.UnderlineStyle;
pub const UiStyle = render.UiStyle;
pub const UiTheme = render.UiTheme;
pub const CursorShape = render.CursorShape;
pub const Prompt = render.Prompt;
pub const CompletionFlash = render.CompletionFlash;
pub const Frame = render.Frame;
pub const FrameRenderer = render.FrameRenderer;
pub const FrameRenderOptions = render.FrameRenderOptions;
pub const RenderOptions = render.RenderOptions;
pub const DiagnosticSeverity = render.DiagnosticSeverity;
pub const DiagnosticSpan = render.DiagnosticSpan;
pub const DiagnosticRender = render.DiagnosticRender;
pub const semanticPromptEnd = render.semantic_prompt_end;
pub const parseUiStyle = render.parseUiStyle;
pub const visibleWidth = render.visibleWidth;

const appendUiStyleStart = render.appendUiStyleStart;
const appendUiStyleEnd = render.appendUiStyleEnd;
const completionFlashForCursor = render.completionFlashForCursor;
const renderableInlineText = render.renderableInlineText;
const serializeFullFrame = render.serializeFullFrame;

pub const KeyEvent = key_mod.Event;
pub const Key = key_mod.Key;
pub const Modifiers = key_mod.Modifiers;
pub const keyEventFromVaxis = key_mod.eventFromVaxis;
const keyFromVaxis = key_mod.keyFromVaxis;

const BufferSnapshot = edit_buffer.Snapshot;
pub const EditBuffer = edit_buffer.EditBuffer;
pub const Editor = edit_buffer.Editor;
const previousGraphemeStart = edit_buffer.previousGraphemeStart;
const nextGraphemeEnd = edit_buffer.nextGraphemeEnd;
const previousWordStart = edit_buffer.previousWordStart;
const nextWordEnd = edit_buffer.nextWordEnd;

pub const EditingMode = enum {
    emacs,
    vi,
};

pub const PathExpansionCommand = path.Command;
pub const PathExpansionReplacementStyle = path.ReplacementStyle;
pub const PathExpansionRequest = path.Request;
pub const PathExpansionMatches = path.Matches;
pub const pathExpansionListOutput = path.listOutput;
const currentViBigwordRange = path.currentViBigwordRange;
const pathExpansionReplacementStyle = path.replacementStyle;
const pathExpansionCompletionReplacement = path.completionReplacement;
const pathExpansionAllReplacement = path.allReplacement;

pub const ViState = enum {
    insert,
    command,
    replace,
};

const ViOperator = enum {
    change,
    delete,
    yank,
};

const ViFindDirection = enum {
    forward,
    backward,
};

const ViHistoryDirection = enum {
    backward,
    forward,
};

const ViFindPlacement = enum {
    on_character,
    before_character,
    after_character,
};

const ViFindCommand = struct {
    direction: ViFindDirection,
    placement: ViFindPlacement,
    char: u21,
};

const ViPending = union(enum) {
    none,
    operator: struct {
        operator: ViOperator,
        count: usize,
    },
    replace,
    find: struct {
        direction: ViFindDirection,
        placement: ViFindPlacement,
    },
    history_search: ViHistoryDirection,
    alias,
};

const ViMotionResult = struct {
    cursor: usize,
    inclusive: bool = false,
};

const ViMotionRange = struct {
    start: usize,
    end: usize,
    cursor_after_delete: usize,
};

const ViWordKind = enum {
    word,
    bigword,
};

const ViInsertPlacement = enum {
    at_cursor,
    after_cursor,
    line_start,
    line_end,
};

const ViInsertRepeatCapture = union(enum) {
    insert: struct {
        placement: ViInsertPlacement,
        text_count: usize,
    },
    replace_session,
    change_to_end,
    clear_line_change,
    operator_change: struct {
        motion_command: u21,
        count: usize,
    },
};

const ViInputRepeatMode = enum {
    insert,
    replace,
};

const ViInputRepeatOp = union(enum) {
    text: []u8,
    key: Key,

    fn deinit(self: ViInputRepeatOp, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |text| allocator.free(text),
            .key => {},
        }
    }

    fn changesBuffer(self: ViInputRepeatOp) bool {
        return switch (self) {
            .text => |text| text.len != 0,
            .key => |key| switch (key) {
                .backspace,
                .delete_previous_word,
                .delete_to_start,
                => true,
                else => false,
            },
        };
    }
};

const ViInputRepeat = struct {
    ops: []ViInputRepeatOp,

    fn deinit(self: ViInputRepeat, allocator: std.mem.Allocator) void {
        for (self.ops) |op| op.deinit(allocator);
        allocator.free(self.ops);
    }

    fn changesBuffer(self: ViInputRepeat) bool {
        for (self.ops) |op| {
            if (op.changesBuffer()) return true;
        }
        return false;
    }
};

const ViRepeat = union(enum) {
    insert: struct {
        placement: ViInsertPlacement,
        input: ViInputRepeat,
        text_count: usize,
    },
    replace: struct {
        text: []u8,
        count: usize,
    },
    replace_session: ViInputRepeat,
    delete_forward: usize,
    delete_backward: usize,
    delete_to_end,
    change_to_end: ViInputRepeat,
    clear_line_delete,
    clear_line_change: ViInputRepeat,
    operator_delete: struct {
        motion_command: u21,
        count: usize,
    },
    operator_change: struct {
        motion_command: u21,
        count: usize,
        input: ViInputRepeat,
    },
    put_after: usize,
    put_before: usize,
    toggle_case: usize,

    fn deinit(self: ViRepeat, allocator: std.mem.Allocator) void {
        switch (self) {
            .insert => |repeat| repeat.input.deinit(allocator),
            .replace => |repeat| allocator.free(repeat.text),
            .replace_session => |input| input.deinit(allocator),
            .change_to_end => |input| input.deinit(allocator),
            .clear_line_change => |input| input.deinit(allocator),
            .operator_change => |repeat| repeat.input.deinit(allocator),
            .delete_forward,
            .delete_backward,
            .delete_to_end,
            .clear_line_delete,
            .operator_delete,
            .put_after,
            .put_before,
            .toggle_case,
            => {},
        }
    }
};

pub const HistoryView = struct {
    entries: []const []const u8 = &.{},
    now: i64 = 0,
    context: ?*anyopaque = null,
    previous: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, ?i64) anyerror!?HistoryEntry = null,
    next: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, i64) anyerror!?HistoryEntry = null,
    by_number: ?*const fn (*anyopaque, std.mem.Allocator, usize) anyerror!?HistoryEntry = null,
    search: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, ?i64) anyerror!?HistoryEntry = null,
    search_next: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, ?i64) anyerror!?HistoryEntry = null,
    suggest: ?*const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?HistoryEntry = null,

    pub const HistoryEntry = struct {
        id: i64,
        text: []const u8,
        when: i64 = 0,

        pub fn deinit(self: HistoryEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
        }
    };
};

pub const ViAliasView = struct {
    context: ?*anyopaque = null,
    lookup: ?*const fn (*anyopaque, std.mem.Allocator, u21) anyerror!?[]const u8 = null,
};

pub const ExternalEditorRequest = struct {
    text: []const u8,
    number: ?usize = null,

    pub fn deinit(self: ExternalEditorRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const CompletionMenu = struct {
    candidates: []completion.Candidate = &.{},
    selected: usize = no_selection,
    window_start: usize = 0,

    const no_selection = std.math.maxInt(usize);

    pub fn deinit(self: *CompletionMenu, allocator: std.mem.Allocator) void {
        if (self.candidates.len != 0) completion.freeCandidates(allocator, self.candidates);
        self.* = .{};
    }

    pub fn replace(self: *CompletionMenu, allocator: std.mem.Allocator, candidates: []const completion.Candidate) !void {
        self.deinit(allocator);
        self.candidates = try completion.cloneCandidates(allocator, candidates);
        self.selected = no_selection;
        self.window_start = 0;
    }

    pub fn clear(self: *CompletionMenu, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }

    pub fn isOpen(self: CompletionMenu) bool {
        return self.candidates.len != 0;
    }

    pub fn selectPrevious(self: *CompletionMenu) void {
        if (self.candidates.len == 0) return;
        self.selected = if (self.selected == no_selection or self.selected == 0) 0 else self.selected - 1;
    }

    pub fn selectNext(self: *CompletionMenu) void {
        if (self.candidates.len == 0) return;
        self.selected = if (self.selected == no_selection) 0 else @min(self.selected + 1, self.candidates.len - 1);
    }

    pub fn selectedCandidate(self: CompletionMenu) ?completion.Candidate {
        if (self.candidates.len == 0 or self.selected == no_selection) return null;
        return self.candidates[self.selected];
    }

    pub fn visibleWindowStart(self: *CompletionMenu, max_rows: usize) usize {
        if (self.candidates.len == 0) return 0;
        if (self.selected == no_selection) {
            self.window_start = 0;
            return 0;
        }
        const visible_rows = @max(max_rows, 1);
        if (self.candidates.len <= visible_rows) {
            self.window_start = 0;
            return 0;
        }
        const last_start = self.candidates.len - visible_rows;
        self.window_start = @min(self.window_start, last_start);
        if (self.selected < self.window_start) {
            self.window_start = self.selected;
        } else if (self.selected >= self.window_start + visible_rows) {
            self.window_start = self.selected + 1 - visible_rows;
        }
        return self.window_start;
    }
};

const PendingRemovableSuffix = struct {
    start: usize,
    end: usize,
    text: []u8,

    fn deinit(self: PendingRemovableSuffix, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const LineSession = struct {
    allocator: std.mem.Allocator,
    prompt: Prompt,
    prompt_dirty: bool = false,
    editing_mode: EditingMode = .emacs,
    vi_state: ViState = .insert,
    vi_pending: ViPending = .none,
    vi_count: ?usize = null,
    vi_last_find: ?ViFindCommand = null,
    vi_undo: ?BufferSnapshot = null,
    vi_line_undo: ?BufferSnapshot = null,
    vi_last_repeat: ?ViRepeat = null,
    vi_insert_repeat: ?ViInsertRepeatCapture = null,
    vi_insert_repeat_ops: std.ArrayList(ViInputRepeatOp) = .empty,
    vi_replaying_repeat: bool = false,
    vi_macro_depth: usize = 0,
    vi_aliases: ViAliasView = .{},
    editor: Editor,
    history: HistoryView = .{},
    history_index: ?i64 = null,
    saved_edit: std.ArrayList(u8) = .empty,
    history_search_query: std.ArrayList(u8) = .empty,
    history_search_original: std.ArrayList(u8) = .empty,
    history_search_match: ?HistoryView.HistoryEntry = null,
    history_search_matches: std.ArrayList(HistoryView.HistoryEntry) = .empty,
    history_search_selected: usize = 0,
    vi_history_search_query: std.ArrayList(u8) = .empty,
    vi_last_history_search_pattern: std.ArrayList(u8) = .empty,
    vi_last_history_search_direction: ?ViHistoryDirection = null,
    kill_ring: std.ArrayList(u8) = .empty,
    completion_menu: CompletionMenu = .{},
    state: State = .editing,
    submitted_line: ?[]const u8 = null,
    external_editor_request: ?ExternalEditorRequest = null,
    path_expansion_request: ?PathExpansionRequest = null,
    paste_depth: usize = 0,
    clear_screen_requested: bool = false,
    completion_flash: ?CompletionFlash = null,
    pending_removable_suffix: ?PendingRemovableSuffix = null,

    pub const State = enum {
        editing,
        history_search,
        external_editor,
        submitted,
        canceled,
        eof,
    };

    pub fn init(allocator: std.mem.Allocator, prompt: []const u8) !LineSession {
        return initWithOptions(allocator, .{ .bytes = prompt }, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, prompt: Prompt, history: HistoryView) !LineSession {
        return initWithEditingMode(allocator, prompt, history, .emacs);
    }

    pub fn initWithEditingMode(allocator: std.mem.Allocator, prompt: Prompt, history: HistoryView, editing_mode: EditingMode) !LineSession {
        return .{
            .allocator = allocator,
            .prompt = .{
                .bytes = try allocator.dupe(u8, prompt.bytes),
                .visible_width = prompt.visible_width,
            },
            .editing_mode = editing_mode,
            .editor = .init(allocator),
            .history = history,
        };
    }

    pub fn deinit(self: *LineSession) void {
        if (self.submitted_line) |line| self.allocator.free(line);
        if (self.external_editor_request) |request| request.deinit(self.allocator);
        self.clearPathExpansionRequest();
        self.clearPendingRemovableSuffix();
        if (self.history_search_match) |entry| entry.deinit(self.allocator);
        self.clearHistorySearchMatches();
        self.history_search_matches.deinit(self.allocator);
        self.history_search_original.deinit(self.allocator);
        self.history_search_query.deinit(self.allocator);
        self.vi_last_history_search_pattern.deinit(self.allocator);
        self.vi_history_search_query.deinit(self.allocator);
        self.completion_menu.deinit(self.allocator);
        self.kill_ring.deinit(self.allocator);
        self.saved_edit.deinit(self.allocator);
        self.clearViLastRepeat();
        self.clearViInsertRepeatCapture();
        self.vi_insert_repeat_ops.deinit(self.allocator);
        self.clearViUndo();
        self.clearViLineUndo();
        self.editor.deinit();
        self.allocator.free(self.prompt.bytes);
        self.* = undefined;
    }

    pub fn handleKey(self: *LineSession, event: KeyEvent) !void {
        if (self.state != .editing and self.state != .history_search) return;
        if (self.paste_depth != 0) {
            if (event.key == .text or event.key == .enter) {
                const text = if (event.key == .enter) "\n" else event.text;
                try self.editor.handleKey(.{ .key = .text, .text = text });
                self.completion_menu.clear(self.allocator);
                self.clearPendingRemovableSuffix();
            }
            return;
        }
        if (self.state == .history_search) return self.handleHistorySearchKey(event);
        if (try self.consumePendingRemovableSuffix(event)) return;
        if (self.editing_mode == .vi) return self.handleViKey(event);
        switch (event.key) {
            .enter => {
                if (self.completion_menu.selectedCandidate()) |candidate| {
                    try self.applyCompletionCandidate(candidate);
                    return;
                }
                self.completion_menu.clear(self.allocator);
                std.debug.assert(self.submitted_line == null);
                self.submitted_line = try self.allocator.dupe(u8, self.editor.buffer.text());
                self.state = .submitted;
            },
            .escape => {
                self.completion_menu.clear(self.allocator);
            },
            .ctrl_c => {
                try self.clearInput();
            },
            .ctrl_d => {
                self.completion_menu.clear(self.allocator);
                if (self.editor.buffer.text().len == 0) {
                    self.state = .eof;
                } else {
                    self.editor.buffer.deleteNext();
                }
            },
            .ctrl_r => try self.beginHistorySearch(),
            .clear_screen => {
                self.completion_menu.clear(self.allocator);
                self.clear_screen_requested = true;
            },
            .backspace => {
                self.editor.buffer.deletePrevious();
                self.completion_menu.clear(self.allocator);
            },
            .delete => {
                self.editor.buffer.deleteNext();
                self.completion_menu.clear(self.allocator);
            },
            .delete_to_start => {
                try self.killRange(0, self.editor.buffer.cursor_byte, 0);
                self.completion_menu.clear(self.allocator);
            },
            .delete_to_end => {
                try self.killRange(self.editor.buffer.cursor_byte, self.editor.buffer.text().len, self.editor.buffer.cursor_byte);
                self.completion_menu.clear(self.allocator);
            },
            .delete_previous_word => {
                const start = previousWordStart(self.editor.buffer.text(), self.editor.buffer.cursor_byte);
                try self.killRange(start, self.editor.buffer.cursor_byte, start);
                self.completion_menu.clear(self.allocator);
            },
            .delete_next_word => {
                const end = nextWordEnd(self.editor.buffer.text(), self.editor.buffer.cursor_byte);
                try self.killRange(self.editor.buffer.cursor_byte, end, self.editor.buffer.cursor_byte);
                self.completion_menu.clear(self.allocator);
            },
            .yank => {
                if (self.kill_ring.items.len != 0) {
                    try self.editor.buffer.insertText(self.kill_ring.items);
                    self.completion_menu.clear(self.allocator);
                }
            },
            .left, .home, .word_left, .word_right => {
                try self.editor.handleKey(event);
                self.completion_menu.clear(self.allocator);
            },
            .right, .end => {
                if (self.editor.buffer.cursor_byte == self.editor.buffer.text().len and try self.acceptAutosuggestion()) {
                    self.completion_menu.clear(self.allocator);
                    return;
                }
                try self.editor.handleKey(event);
                self.completion_menu.clear(self.allocator);
            },
            .up => if (self.completion_menu.isOpen()) self.completion_menu.selectPrevious() else try self.historyPrevious(),
            .down => if (self.completion_menu.isOpen()) self.completion_menu.selectNext() else try self.historyNext(),
            .tab => if (self.completion_menu.isOpen()) {
                if (event.modifiers.shift) self.completion_menu.selectPrevious() else self.completion_menu.selectNext();
            },
            else => {
                try self.editor.handleKey(event);
                if (!self.completion_menu.isOpen()) self.completion_menu.clear(self.allocator);
            },
        }
    }

    fn handleViKey(self: *LineSession, event: KeyEvent) !void {
        switch (self.vi_state) {
            .insert => return self.handleViInsertKey(event),
            .replace => return self.handleViReplaceKey(event),
            .command => return self.handleViCommandKey(event),
        }
    }

    fn handleViInsertKey(self: *LineSession, event: KeyEvent) !void {
        switch (event.key) {
            .escape => {
                try self.finishViInsertRepeat();
                self.enterViCommandMode();
            },
            .ctrl_c => {
                self.clearViInsertRepeatCapture();
                try self.clearInput();
            },
            .enter => {
                self.clearViInsertRepeatCapture();
                try self.submitInput();
            },
            .backspace => {
                self.editor.buffer.deletePrevious();
                try self.appendViInputRepeatKey(.backspace);
                self.completion_menu.clear(self.allocator);
            },
            .delete_previous_word => {
                const start = previousViWordStart(self.editor.buffer.text(), self.editor.buffer.cursor_byte, .word);
                try self.killRange(start, self.editor.buffer.cursor_byte, start);
                try self.appendViInputRepeatKey(.delete_previous_word);
            },
            .delete_to_start => {
                try self.killRange(0, self.editor.buffer.cursor_byte, 0);
                try self.appendViInputRepeatKey(.delete_to_start);
            },
            .ctrl_d => {
                self.completion_menu.clear(self.allocator);
                if (self.editor.buffer.text().len == 0) {
                    self.state = .eof;
                } else {
                    self.editor.buffer.deleteNext();
                }
            },
            .clear_screen => {
                self.completion_menu.clear(self.allocator);
                self.clear_screen_requested = true;
            },
            .left, .right, .home, .end, .word_left, .word_right => {
                try self.editor.handleKey(event);
                try self.appendViInputRepeatKey(event.key);
                self.completion_menu.clear(self.allocator);
            },
            .text => {
                if (event.text.len == 0) return;
                try self.editor.buffer.insertText(event.text);
                try self.appendViInputRepeatText(event.text);
                self.completion_menu.clear(self.allocator);
            },
            else => {},
        }
    }

    fn handleViReplaceKey(self: *LineSession, event: KeyEvent) !void {
        switch (event.key) {
            .escape => {
                try self.finishViInsertRepeat();
                self.enterViCommandMode();
            },
            .ctrl_c => {
                self.clearViInsertRepeatCapture();
                try self.clearInput();
            },
            .enter => {
                self.clearViInsertRepeatCapture();
                try self.submitInput();
            },
            .backspace => {
                self.editor.buffer.deletePrevious();
                try self.appendViInputRepeatKey(.backspace);
                self.completion_menu.clear(self.allocator);
            },
            .text => {
                if (event.text.len == 0) return;
                try self.viReplaceInputText(event.text);
                try self.appendViInputRepeatText(event.text);
                self.completion_menu.clear(self.allocator);
            },
            else => try self.handleViInsertKey(event),
        }
    }

    fn handleViCommandKey(self: *LineSession, event: KeyEvent) !void {
        switch (self.vi_pending) {
            .history_search => |direction| return self.handleViHistorySearchKey(direction, event),
            .alias => return self.handleViAliasKey(event),
            else => {},
        }

        switch (event.key) {
            .enter => return self.submitInput(),
            .ctrl_c => return self.clearInput(),
            .clear_screen => {
                self.clear_screen_requested = true;
                return;
            },
            .escape => {
                self.resetViCommandPrefix();
                return;
            },
            .left => return self.applyViMotionCommand('h'),
            .right => return self.applyViMotionCommand('l'),
            .up => return self.viHistoryPrevious(self.takeViCountOrDefault(1)),
            .down => return self.viHistoryNext(self.takeViCountOrDefault(1)),
            .home => return self.applyViMotionCommand('0'),
            .end => return self.applyViMotionCommand('$'),
            .backspace => return self.applyViMotionCommand('h'),
            .ctrl_d => return,
            .text => {},
            else => return,
        }

        if (event.text.len == 0) return;
        const command = firstCodepoint(event.text) orelse return;

        switch (self.vi_pending) {
            .none => {},
            .replace => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viReplaceCharacters(event.text, count) and !self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .replace = .{ .text = try self.allocator.dupe(u8, event.text), .count = count } });
                }
                self.vi_pending = .none;
                return;
            },
            .operator => |pending| {
                if (command >= '1' and command <= '9') {
                    self.vi_count = (self.vi_count orelse 0) * 10 + (command - '0');
                    return;
                }
                if (command == '0' and self.vi_count != null) {
                    self.vi_count = (self.vi_count orelse 0) * 10;
                    return;
                }
                const motion_count = self.takeViCountOrDefault(1);
                try self.applyViOperator(pending.operator, command, multiplyViCounts(pending.count, motion_count));
                self.vi_pending = .none;
                return;
            },
            .find => |find| {
                try self.applyViFind(.{ .direction = find.direction, .placement = find.placement, .char = command }, self.takeViCountOrDefault(1));
                self.vi_pending = .none;
                return;
            },
            .alias => unreachable,
            .history_search => unreachable,
        }

        if (command >= '1' and command <= '9') {
            self.vi_count = (self.vi_count orelse 0) * 10 + (command - '0');
            return;
        }

        switch (command) {
            '0', '^', '$', '|', 'h', 'l', ' ', 'w', 'W', 'e', 'E', 'b', 'B' => try self.applyViMotionCommand(command),
            'f' => self.vi_pending = .{ .find = .{ .direction = .forward, .placement = .on_character } },
            'F' => self.vi_pending = .{ .find = .{ .direction = .backward, .placement = .on_character } },
            't' => self.vi_pending = .{ .find = .{ .direction = .forward, .placement = .before_character } },
            'T' => self.vi_pending = .{ .find = .{ .direction = .backward, .placement = .after_character } },
            ';' => if (self.vi_last_find) |find| try self.applyViFind(find, self.takeViCountOrDefault(1)),
            ',' => if (self.vi_last_find) |find| try self.applyViFind(reverseViFind(find), self.takeViCountOrDefault(1)),
            'i' => {
                const count = self.takeViCountOrDefault(1);
                try self.saveViUndo();
                try self.beginViInsertRepeat(.{ .insert = .{ .placement = .at_cursor, .text_count = count } });
                self.enterViInsertModeAtCursor();
            },
            'I' => {
                const count = self.takeViCountOrDefault(1);
                self.editor.buffer.cursor_byte = firstNonBlank(self.editor.buffer.text());
                try self.saveViUndo();
                try self.beginViInsertRepeat(.{ .insert = .{ .placement = .line_start, .text_count = count } });
                self.enterViInsertModeAtCursor();
            },
            'a' => {
                const count = self.takeViCountOrDefault(1);
                if (self.editor.buffer.text().len != 0) self.editor.buffer.moveRight();
                try self.saveViUndo();
                try self.beginViInsertRepeat(.{ .insert = .{ .placement = .after_cursor, .text_count = count } });
                self.enterViInsertModeAtCursor();
            },
            'A' => {
                const count = self.takeViCountOrDefault(1);
                self.editor.buffer.moveEnd();
                try self.saveViUndo();
                try self.beginViInsertRepeat(.{ .insert = .{ .placement = .line_end, .text_count = count } });
                self.enterViInsertModeAtCursor();
            },
            'R' => {
                try self.saveViUndo();
                try self.beginViInsertRepeat(.replace_session);
                try self.captureViLineUndo();
                self.vi_state = .replace;
                self.resetViCommandPrefix();
            },
            'r' => self.vi_pending = .replace,
            'x' => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viDeleteForward(count) and !self.vi_replaying_repeat) try self.setViLastRepeat(.{ .delete_forward = count });
            },
            'X' => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viDeleteBackward(count) and !self.vi_replaying_repeat) try self.setViLastRepeat(.{ .delete_backward = count });
            },
            'D' => if (try self.viDeleteRange(self.editor.buffer.cursor_byte, self.editor.buffer.text().len, self.editor.buffer.cursor_byte) and !self.vi_replaying_repeat) try self.setViLastRepeat(.delete_to_end),
            'C' => {
                _ = try self.viDeleteRange(self.editor.buffer.cursor_byte, self.editor.buffer.text().len, self.editor.buffer.cursor_byte);
                try self.beginViInsertRepeat(.change_to_end);
                self.enterViInsertModeAtCursor();
            },
            'S' => {
                _ = try self.viClearLine(false);
                try self.beginViInsertRepeat(.clear_line_change);
                self.enterViInsertModeAtCursor();
            },
            '_' => try self.viInsertPreviousBigword(self.takeViCount()),
            'd' => self.vi_pending = .{ .operator = .{ .operator = .delete, .count = self.takeViCountOrDefault(1) } },
            'c' => self.vi_pending = .{ .operator = .{ .operator = .change, .count = self.takeViCountOrDefault(1) } },
            'y' => self.vi_pending = .{ .operator = .{ .operator = .yank, .count = self.takeViCountOrDefault(1) } },
            'Y' => try self.viYankRange(self.editor.buffer.cursor_byte, self.editor.buffer.text().len),
            'p' => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viPutAfter(count) and !self.vi_replaying_repeat) try self.setViLastRepeat(.{ .put_after = count });
            },
            'P' => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viPutBefore(count) and !self.vi_replaying_repeat) try self.setViLastRepeat(.{ .put_before = count });
            },
            'u' => try self.restoreViUndo(),
            'U' => try self.restoreViLineUndo(),
            '~' => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viToggleCase(count) and !self.vi_replaying_repeat) try self.setViLastRepeat(.{ .toggle_case = count });
            },
            'k', '-' => try self.viHistoryPrevious(self.takeViCountOrDefault(1)),
            'j', '+' => try self.viHistoryNext(self.takeViCountOrDefault(1)),
            'G' => try self.viHistoryOldestOrNumber(self.vi_count),
            '/' => self.beginViHistorySearch(.backward),
            '?' => self.beginViHistorySearch(.forward),
            'n' => try self.repeatViHistorySearch(false),
            'N' => try self.repeatViHistorySearch(true),
            '@' => self.vi_pending = .alias,
            'v' => try self.requestExternalEditor(self.takeViCount()),
            '=' => try self.requestPathExpansion(.list),
            '\\' => try self.requestPathExpansion(.complete),
            '*' => try self.requestPathExpansion(.expand_all),
            '.' => try self.repeatViLastChange(),
            '#' => try self.viCommentAndSubmit(),
            else => self.resetViCommandPrefix(),
        }
    }

    fn submitInput(self: *LineSession) !void {
        self.completion_menu.clear(self.allocator);
        std.debug.assert(self.submitted_line == null);
        self.submitted_line = try self.allocator.dupe(u8, self.editor.buffer.text());
        self.state = .submitted;
    }

    fn requestExternalEditor(self: *LineSession, maybe_number: ?usize) !void {
        const text = if (maybe_number) |number| blk: {
            const entry = try self.historyEntryByNumber(number) orelse {
                self.resetViCommandPrefix();
                return;
            };
            defer entry.deinit(self.allocator);
            break :blk try self.allocator.dupe(u8, entry.text);
        } else try self.allocator.dupe(u8, self.editor.buffer.text());
        errdefer self.allocator.free(text);

        if (self.external_editor_request) |request| request.deinit(self.allocator);
        self.external_editor_request = .{ .text = text, .number = maybe_number };
        self.state = .external_editor;
        self.resetViCommandPrefix();
        self.completion_menu.clear(self.allocator);
    }

    fn requestPathExpansion(self: *LineSession, command: PathExpansionCommand) !void {
        const range = currentViBigwordRange(self.editor.buffer.text(), self.editor.buffer.cursor_byte) orelse {
            self.resetViCommandPrefix();
            return;
        };
        const word = try self.allocator.dupe(u8, self.editor.buffer.text()[range.start..range.end]);
        errdefer self.allocator.free(word);
        self.clearPathExpansionRequest();
        self.path_expansion_request = .{
            .command = command,
            .word = word,
            .replace_start = range.start,
            .replace_end = range.end,
            .replacement_style = pathExpansionReplacementStyle(word),
        };
        self.resetViCommandPrefix();
        self.completion_menu.clear(self.allocator);
    }

    pub fn takePathExpansionRequest(self: *LineSession) ?PathExpansionRequest {
        const request = self.path_expansion_request orelse return null;
        self.path_expansion_request = null;
        return request;
    }

    fn clearPathExpansionRequest(self: *LineSession) void {
        if (self.path_expansion_request) |request| request.deinit(self.allocator);
        self.path_expansion_request = null;
    }

    pub fn applyPathExpansion(self: *LineSession, request: PathExpansionRequest, matches: PathExpansionMatches) !bool {
        if (request.command == .list or matches.items.len == 0) return false;
        const replacement = switch (request.command) {
            .list => unreachable,
            .complete => try pathExpansionCompletionReplacement(self.allocator, request.word, matches.items, request.replacement_style),
            .expand_all => try pathExpansionAllReplacement(self.allocator, matches.items, request.replacement_style),
        };
        defer self.allocator.free(replacement);
        if (std.mem.eql(u8, request.word, replacement)) return false;

        try self.saveViUndo();
        try self.editor.buffer.replaceRange(request.replace_start, request.replace_end, replacement);
        self.completion_menu.clear(self.allocator);
        return true;
    }

    fn historyEntryByNumber(self: *LineSession, number: usize) !?HistoryView.HistoryEntry {
        if (number == 0) return null;
        if (self.history.context != null and self.history.by_number != null) {
            return self.history.by_number.?(self.history.context.?, self.allocator, number);
        }
        const index = number - 1;
        if (index >= self.history.entries.len) return null;
        return .{ .id = @intCast(index), .text = try self.allocator.dupe(u8, self.history.entries[index]) };
    }

    pub fn takeExternalEditorRequest(self: *LineSession) ?ExternalEditorRequest {
        const request = self.external_editor_request orelse return null;
        self.external_editor_request = null;
        return request;
    }

    pub fn acceptExternalEditorResult(self: *LineSession, text: []const u8) !void {
        self.completion_menu.clear(self.allocator);
        try self.editor.buffer.replace(text);
        std.debug.assert(self.submitted_line == null);
        self.submitted_line = try self.allocator.dupe(u8, self.editor.buffer.text());
        self.state = .submitted;
    }

    pub fn resumeEditingAfterExternalEditor(self: *LineSession) void {
        if (self.state == .external_editor) self.state = .editing;
    }

    fn enterViCommandMode(self: *LineSession) void {
        self.vi_state = .command;
        self.resetViCommandPrefix();
        if (self.editor.buffer.cursor_byte == self.editor.buffer.text().len) {
            self.editor.buffer.moveLeft();
        }
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn enterViInsertModeAtCursor(self: *LineSession) void {
        self.vi_state = .insert;
        self.resetViCommandPrefix();
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn resetViCommandPrefix(self: *LineSession) void {
        self.vi_count = null;
        self.vi_pending = .none;
    }

    fn takeViCountOrDefault(self: *LineSession, default: usize) usize {
        const count = self.vi_count orelse default;
        self.vi_count = null;
        return @max(count, 1);
    }

    fn takeViCount(self: *LineSession) ?usize {
        const count = self.vi_count;
        self.vi_count = null;
        return if (count) |value| @max(value, 1) else null;
    }

    fn beginViInsertRepeat(self: *LineSession, capture: ViInsertRepeatCapture) !void {
        if (self.vi_replaying_repeat) return;
        self.clearViInsertRepeatCapture();
        self.vi_insert_repeat = capture;
        self.clearViInputRepeatOps();
    }

    fn appendViInputRepeatText(self: *LineSession, text: []const u8) !void {
        if (self.vi_insert_repeat == null or self.vi_replaying_repeat) return;
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try self.vi_insert_repeat_ops.append(self.allocator, .{ .text = copy });
    }

    fn appendViInputRepeatKey(self: *LineSession, key: Key) !void {
        if (self.vi_insert_repeat == null or self.vi_replaying_repeat) return;
        try self.vi_insert_repeat_ops.append(self.allocator, .{ .key = key });
    }

    fn finishViInsertRepeat(self: *LineSession) !void {
        const capture = self.vi_insert_repeat orelse return;
        self.vi_insert_repeat = null;
        var input = try self.takeViInputRepeat();
        var stored = false;
        defer if (!stored) input.deinit(self.allocator);

        switch (capture) {
            .insert => |insert| {
                if (!input.changesBuffer()) return;
                var remaining = insert.text_count -| 1;
                while (remaining != 0) : (remaining -= 1) try self.applyViInputRepeat(input, .insert);
                if (!self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .insert = .{ .placement = insert.placement, .input = input, .text_count = insert.text_count } });
                    stored = true;
                }
            },
            .replace_session => {
                if (!input.changesBuffer()) return;
                if (!self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .replace_session = input });
                    stored = true;
                }
            },
            .change_to_end => {
                if (!self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .change_to_end = input });
                    stored = true;
                }
            },
            .clear_line_change => {
                if (!self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .clear_line_change = input });
                    stored = true;
                }
            },
            .operator_change => |change| {
                if (!self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .operator_change = .{ .motion_command = change.motion_command, .count = change.count, .input = input } });
                    stored = true;
                }
            },
        }
    }

    fn clearViInsertRepeatCapture(self: *LineSession) void {
        self.vi_insert_repeat = null;
        self.clearViInputRepeatOps();
    }

    fn clearViInputRepeatOps(self: *LineSession) void {
        for (self.vi_insert_repeat_ops.items) |op| op.deinit(self.allocator);
        self.vi_insert_repeat_ops.clearRetainingCapacity();
    }

    fn takeViInputRepeat(self: *LineSession) !ViInputRepeat {
        return .{ .ops = try self.vi_insert_repeat_ops.toOwnedSlice(self.allocator) };
    }

    fn clearViLastRepeat(self: *LineSession) void {
        if (self.vi_last_repeat) |repeat| repeat.deinit(self.allocator);
        self.vi_last_repeat = null;
    }

    fn setViLastRepeat(self: *LineSession, repeat: ViRepeat) !void {
        self.clearViLastRepeat();
        self.vi_last_repeat = repeat;
    }

    fn repeatViLastChange(self: *LineSession) !void {
        const repeat = self.vi_last_repeat orelse {
            self.resetViCommandPrefix();
            return;
        };
        const count = self.takeViCountOrDefault(1);
        self.vi_replaying_repeat = true;
        defer self.vi_replaying_repeat = false;
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) try self.applyViRepeat(repeat);
        self.resetViCommandPrefix();
    }

    fn applyViRepeat(self: *LineSession, repeat: ViRepeat) !void {
        switch (repeat) {
            .insert => |insert| {
                try self.saveViUndo();
                self.applyViInsertPlacement(insert.placement);
                var remaining = insert.text_count;
                while (remaining != 0) : (remaining -= 1) try self.applyViInputRepeat(insert.input, .insert);
                self.finishViInputRepeat(insert.input);
            },
            .replace => |replace| _ = try self.viReplaceCharacters(replace.text, replace.count),
            .replace_session => |input| {
                try self.saveViUndo();
                try self.applyViInputRepeat(input, .replace);
                self.finishViInputRepeat(input);
            },
            .delete_forward => |count| _ = try self.viDeleteForward(count),
            .delete_backward => |count| _ = try self.viDeleteBackward(count),
            .delete_to_end => _ = try self.viDeleteRange(self.editor.buffer.cursor_byte, self.editor.buffer.text().len, self.editor.buffer.cursor_byte),
            .change_to_end => |input| {
                _ = try self.viDeleteRange(self.editor.buffer.cursor_byte, self.editor.buffer.text().len, self.editor.buffer.cursor_byte);
                try self.applyViInputRepeat(input, .insert);
                self.finishViInputRepeat(input);
            },
            .clear_line_delete => _ = try self.viClearLine(false),
            .clear_line_change => |input| {
                _ = try self.viClearLine(false);
                try self.applyViInputRepeat(input, .insert);
                self.finishViInputRepeat(input);
            },
            .operator_delete => |operator| try self.applyViOperator(.delete, operator.motion_command, operator.count),
            .operator_change => |operator| {
                const motion = viMotion(self.editor.buffer.text(), self.editor.buffer.cursor_byte, operator.motion_command, operator.count) orelse return;
                const range = viOperatorMotionRange(self.editor.buffer.text(), self.editor.buffer.cursor_byte, .change, operator.motion_command, operator.count, motion);
                if (!try self.viDeleteRange(range.start, range.end, range.cursor_after_delete)) return;
                try self.applyViInputRepeat(operator.input, .insert);
                self.finishViInputRepeat(operator.input);
            },
            .put_after => |count| _ = try self.viPutAfter(count),
            .put_before => |count| _ = try self.viPutBefore(count),
            .toggle_case => |count| _ = try self.viToggleCase(count),
        }
    }

    fn applyViInsertPlacement(self: *LineSession, placement: ViInsertPlacement) void {
        switch (placement) {
            .at_cursor => {},
            .after_cursor => if (self.editor.buffer.text().len != 0) self.editor.buffer.moveRight(),
            .line_start => self.editor.buffer.cursor_byte = firstNonBlank(self.editor.buffer.text()),
            .line_end => self.editor.buffer.moveEnd(),
        }
    }

    fn applyViInputRepeat(self: *LineSession, input: ViInputRepeat, mode: ViInputRepeatMode) !void {
        for (input.ops) |op| {
            switch (op) {
                .text => |text| switch (mode) {
                    .insert => try self.editor.buffer.insertText(text),
                    .replace => try self.viReplaceInputText(text),
                },
                .key => |key| try self.applyViInputRepeatKey(key),
            }
        }
        self.completion_menu.clear(self.allocator);
    }

    fn applyViInputRepeatKey(self: *LineSession, key: Key) !void {
        switch (key) {
            .backspace => self.editor.buffer.deletePrevious(),
            .delete_previous_word => {
                const start = previousViWordStart(self.editor.buffer.text(), self.editor.buffer.cursor_byte, .word);
                try self.killRange(start, self.editor.buffer.cursor_byte, start);
            },
            .delete_to_start => try self.killRange(0, self.editor.buffer.cursor_byte, 0),
            .left, .right, .home, .end, .word_left, .word_right => try self.editor.handleKey(.{ .key = key }),
            else => {},
        }
    }

    fn finishViInputRepeat(self: *LineSession, input: ViInputRepeat) void {
        if (input.changesBuffer()) self.editor.buffer.moveLeft();
        self.completion_menu.clear(self.allocator);
    }

    fn applyViMotionCommand(self: *LineSession, command: u21) !void {
        const count = self.takeViCountOrDefault(1);
        const motion = viMotion(self.editor.buffer.text(), self.editor.buffer.cursor_byte, command, count) orelse return;
        self.editor.buffer.cursor_byte = motion.cursor;
    }

    fn applyViOperator(self: *LineSession, operator: ViOperator, motion_command: u21, count: usize) !void {
        if ((operator == .delete and motion_command == 'd') or (operator == .change and motion_command == 'c') or (operator == .yank and motion_command == 'y')) {
            switch (operator) {
                .delete => if (try self.viClearLine(false) and !self.vi_replaying_repeat) try self.setViLastRepeat(.clear_line_delete),
                .change => {
                    _ = try self.viClearLine(false);
                    try self.beginViInsertRepeat(.clear_line_change);
                    self.enterViInsertModeAtCursor();
                },
                .yank => try self.viYankRange(0, self.editor.buffer.text().len),
            }
            return;
        }
        const motion = viMotion(self.editor.buffer.text(), self.editor.buffer.cursor_byte, motion_command, count) orelse return;
        const range = viOperatorMotionRange(self.editor.buffer.text(), self.editor.buffer.cursor_byte, operator, motion_command, count, motion);
        switch (operator) {
            .delete => if (try self.viDeleteRange(range.start, range.end, range.cursor_after_delete) and !self.vi_replaying_repeat) try self.setViLastRepeat(.{ .operator_delete = .{ .motion_command = motion_command, .count = count } }),
            .change => {
                if (!try self.viDeleteRange(range.start, range.end, range.cursor_after_delete)) return;
                try self.beginViInsertRepeat(.{ .operator_change = .{ .motion_command = motion_command, .count = count } });
                self.enterViInsertModeAtCursor();
            },
            .yank => try self.viYankRange(range.start, range.end),
        }
    }

    fn applyViFind(self: *LineSession, find: ViFindCommand, count: usize) !void {
        const cursor = viFind(self.editor.buffer.text(), self.editor.buffer.cursor_byte, find, count) orelse return;
        self.editor.buffer.cursor_byte = cursor;
        self.vi_last_find = find;
    }

    fn handleViAliasKey(self: *LineSession, event: KeyEvent) !void {
        self.vi_pending = .none;
        if (event.key != .text or event.text.len == 0) return;
        const letter = firstCodepoint(event.text) orelse return;
        try self.applyViAlias(letter);
    }

    fn applyViAlias(self: *LineSession, letter: u21) !void {
        if (!isPortableAlphabetic(letter)) return;
        const context = self.vi_aliases.context orelse return;
        const lookup = self.vi_aliases.lookup orelse return;
        const value = try lookup(context, self.allocator, letter) orelse return;
        defer self.allocator.free(value);
        try self.feedViMacro(value);
    }

    fn feedViMacro(self: *LineSession, bytes: []const u8) !void {
        if (self.vi_macro_depth >= max_vi_macro_depth) return;
        self.vi_macro_depth += 1;
        defer self.vi_macro_depth -= 1;

        var index: usize = 0;
        while (index < bytes.len and self.state == .editing) {
            const event = viMacroKeyEvent(bytes, &index) orelse return;
            try self.handleKey(event);
        }
    }

    fn viReplaceInputText(self: *LineSession, text: []const u8) !void {
        var cursor: usize = 0;
        while (cursor < text.len) {
            const next = nextGraphemeEnd(text, cursor);
            if (next == cursor) return error.InvalidUtf8;
            try self.editor.buffer.replaceGrapheme(text[cursor..next]);
            cursor = next;
        }
        self.completion_menu.clear(self.allocator);
    }

    fn viReplaceCharacters(self: *LineSession, replacement: []const u8, count: usize) !bool {
        if (self.editor.buffer.text().len == 0) return false;
        try self.saveViUndo();
        var remaining = count;
        while (remaining != 0 and self.editor.buffer.cursor_byte < self.editor.buffer.text().len) : (remaining -= 1) {
            try self.editor.buffer.replaceGrapheme(replacement);
        }
        self.editor.buffer.moveLeft();
        self.completion_menu.clear(self.allocator);
        return remaining != count;
    }

    fn viDeleteForward(self: *LineSession, count: usize) !bool {
        if (self.editor.buffer.text().len == 0) return false;
        var end = self.editor.buffer.cursor_byte;
        var remaining = count;
        while (remaining != 0 and end < self.editor.buffer.text().len) : (remaining -= 1) end = nextGraphemeEnd(self.editor.buffer.text(), end);
        return self.viDeleteRange(self.editor.buffer.cursor_byte, end, self.editor.buffer.cursor_byte);
    }

    fn viDeleteBackward(self: *LineSession, count: usize) !bool {
        if (self.editor.buffer.text().len <= 1 or self.editor.buffer.cursor_byte == 0) return false;
        var start = self.editor.buffer.cursor_byte;
        var remaining = count;
        while (remaining != 0 and start != 0) : (remaining -= 1) start = previousGraphemeStart(self.editor.buffer.text(), start);
        return self.viDeleteRange(start, self.editor.buffer.cursor_byte, start);
    }

    fn viDeleteRange(self: *LineSession, start: usize, end: usize, cursor_after_delete: usize) !bool {
        if (start >= end) return false;
        try self.saveViUndo();
        self.kill_ring.clearRetainingCapacity();
        try self.kill_ring.appendSlice(self.allocator, self.editor.buffer.text()[start..end]);
        try self.editor.buffer.replaceRange(start, end, "");
        self.editor.buffer.cursor_byte = @min(cursor_after_delete, self.editor.buffer.text().len);
        if (self.vi_state == .command and self.editor.buffer.cursor_byte == self.editor.buffer.text().len) self.editor.buffer.moveLeft();
        self.completion_menu.clear(self.allocator);
        return true;
    }

    fn viYankRange(self: *LineSession, start: usize, end: usize) !void {
        if (start >= end) return;
        self.kill_ring.clearRetainingCapacity();
        try self.kill_ring.appendSlice(self.allocator, self.editor.buffer.text()[start..end]);
    }

    fn viClearLine(self: *LineSession, insert_after: bool) !bool {
        const changed = self.editor.buffer.text().len != 0;
        try self.saveViUndo();
        self.kill_ring.clearRetainingCapacity();
        try self.kill_ring.appendSlice(self.allocator, self.editor.buffer.text());
        try self.editor.buffer.replace("");
        if (insert_after) self.enterViInsertModeAtCursor();
        self.completion_menu.clear(self.allocator);
        return changed;
    }

    fn viPutAfter(self: *LineSession, count: usize) !bool {
        if (self.kill_ring.items.len == 0) return false;
        try self.saveViUndo();
        if (self.editor.buffer.text().len != 0) self.editor.buffer.moveRight();
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) try self.editor.buffer.insertText(self.kill_ring.items);
        self.editor.buffer.moveLeft();
        self.completion_menu.clear(self.allocator);
        return true;
    }

    fn viPutBefore(self: *LineSession, count: usize) !bool {
        if (self.kill_ring.items.len == 0) return false;
        try self.saveViUndo();
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) try self.editor.buffer.insertText(self.kill_ring.items);
        self.editor.buffer.moveLeft();
        self.completion_menu.clear(self.allocator);
        return true;
    }

    fn viToggleCase(self: *LineSession, count: usize) !bool {
        if (self.editor.buffer.text().len == 0) return false;
        try self.saveViUndo();
        const start_cursor = self.editor.buffer.cursor_byte;
        var remaining = count;
        while (remaining != 0 and self.editor.buffer.cursor_byte < self.editor.buffer.text().len) : (remaining -= 1) {
            const cursor = self.editor.buffer.cursor_byte;
            const byte = self.editor.buffer.text()[cursor];
            if (std.ascii.isAlphabetic(byte)) {
                self.editor.buffer.bytes.items[cursor] = if (std.ascii.isLower(byte)) std.ascii.toUpper(byte) else std.ascii.toLower(byte);
            }
            if (self.editor.buffer.cursor_byte == self.editor.buffer.text().len - 1) break;
            self.editor.buffer.moveRight();
        }
        self.completion_menu.clear(self.allocator);
        return self.editor.buffer.cursor_byte != start_cursor or count != 0;
    }

    fn viHistoryPrevious(self: *LineSession, count: usize) !void {
        if (self.history_index == null) {
            self.saved_edit.clearRetainingCapacity();
            try self.saved_edit.appendSlice(self.allocator, self.editor.buffer.text());
        }
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            if (try self.queryPreviousHistory("")) |entry| {
                defer entry.deinit(self.allocator);
                self.history_index = entry.id;
                try self.editor.buffer.replace(entry.text);
            } else if (self.history.entries.len != 0) {
                const start: usize = if (self.history_index) |index| @intCast(index) else self.history.entries.len;
                if (start == 0) break;
                const index = start - 1;
                self.history_index = @intCast(index);
                try self.editor.buffer.replace(self.history.entries[index]);
            }
        }
        self.editor.buffer.moveHome();
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn viHistoryNext(self: *LineSession, count: usize) !void {
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            const index = self.history_index orelse break;
            if (try self.queryNextHistory("", index)) |entry| {
                defer entry.deinit(self.allocator);
                self.history_index = entry.id;
                try self.editor.buffer.replace(entry.text);
            } else if (self.history.context != null) {
                self.history_index = null;
                try self.editor.buffer.replace(self.saved_edit.items);
                self.saved_edit.clearRetainingCapacity();
                break;
            } else {
                const next_index = @as(usize, @intCast(index)) + 1;
                if (next_index >= self.history.entries.len) {
                    self.history_index = null;
                    try self.editor.buffer.replace(self.saved_edit.items);
                    self.saved_edit.clearRetainingCapacity();
                    break;
                }
                self.history_index = @intCast(next_index);
                try self.editor.buffer.replace(self.history.entries[next_index]);
            }
        }
        self.editor.buffer.moveHome();
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn viHistoryOldestOrNumber(self: *LineSession, maybe_number: ?usize) !void {
        const index = if (maybe_number) |number| if (number == 0) return else number - 1 else 0;
        self.vi_count = null;
        if (index >= self.history.entries.len) return;
        if (self.history_index == null) {
            self.saved_edit.clearRetainingCapacity();
            try self.saved_edit.appendSlice(self.allocator, self.editor.buffer.text());
        }
        self.history_index = @intCast(index);
        try self.editor.buffer.replace(self.history.entries[index]);
        self.editor.buffer.moveHome();
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn beginViHistorySearch(self: *LineSession, direction: ViHistoryDirection) void {
        self.vi_history_search_query.clearRetainingCapacity();
        self.vi_pending = .{ .history_search = direction };
        self.completion_menu.clear(self.allocator);
    }

    fn handleViHistorySearchKey(self: *LineSession, direction: ViHistoryDirection, event: KeyEvent) !void {
        switch (event.key) {
            .enter => {
                const count = self.takeViCountOrDefault(1);
                const typed_pattern = self.vi_history_search_query.items;
                if (typed_pattern.len == 0 and self.vi_last_history_search_pattern.items.len == 0) {
                    self.vi_history_search_query.clearRetainingCapacity();
                    self.vi_pending = .none;
                    return;
                }
                const pattern = if (typed_pattern.len == 0) self.vi_last_history_search_pattern.items else blk: {
                    self.vi_last_history_search_pattern.clearRetainingCapacity();
                    try self.vi_last_history_search_pattern.appendSlice(self.allocator, typed_pattern);
                    self.vi_last_history_search_direction = direction;
                    break :blk self.vi_last_history_search_pattern.items;
                };
                self.vi_history_search_query.clearRetainingCapacity();
                self.vi_pending = .none;
                try self.applyViHistoryPatternSearch(direction, pattern, count);
            },
            .escape => {
                self.vi_history_search_query.clearRetainingCapacity();
                self.resetViCommandPrefix();
            },
            .ctrl_c => {
                self.vi_history_search_query.clearRetainingCapacity();
                self.resetViCommandPrefix();
                try self.clearInput();
            },
            .backspace => {
                if (self.vi_history_search_query.items.len != 0) {
                    const start = previousCodepointStart(self.vi_history_search_query.items, self.vi_history_search_query.items.len);
                    self.vi_history_search_query.items.len = start;
                }
            },
            .text => {
                if (event.text.len != 0) try self.vi_history_search_query.appendSlice(self.allocator, event.text);
            },
            else => {},
        }
    }

    fn repeatViHistorySearch(self: *LineSession, reverse: bool) !void {
        const last_direction = self.vi_last_history_search_direction orelse {
            self.resetViCommandPrefix();
            return;
        };
        if (self.vi_last_history_search_pattern.items.len == 0) {
            self.resetViCommandPrefix();
            return;
        }
        const direction = if (reverse) reverseViHistoryDirection(last_direction) else last_direction;
        try self.applyViHistoryPatternSearch(direction, self.vi_last_history_search_pattern.items, self.takeViCountOrDefault(1));
    }

    fn applyViHistoryPatternSearch(self: *LineSession, direction: ViHistoryDirection, pattern: []const u8, count: usize) !void {
        if (pattern.len == 0) return;
        if (self.history_index == null) {
            self.saved_edit.clearRetainingCapacity();
            try self.saved_edit.appendSlice(self.allocator, self.editor.buffer.text());
        }

        var cursor = self.history_index;
        var selected: ?HistoryView.HistoryEntry = null;
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            const entry = try self.findViHistoryPatternMatch(direction, pattern, cursor) orelse break;
            if (selected) |old| old.deinit(self.allocator);
            cursor = entry.id;
            selected = entry;
        }
        const entry = selected orelse return;
        defer entry.deinit(self.allocator);
        self.history_index = entry.id;
        try self.editor.buffer.replace(entry.text);
        self.editor.buffer.moveHome();
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn findViHistoryPatternMatch(self: *LineSession, direction: ViHistoryDirection, pattern: []const u8, cursor: ?i64) !?HistoryView.HistoryEntry {
        if (self.history.context != null) {
            switch (direction) {
                .backward => if (self.history.previous != null) return self.queryViHistoryPatternMatch(direction, pattern, cursor),
                .forward => if (self.history.next != null) return self.queryViHistoryPatternMatch(direction, pattern, cursor),
            }
        }
        return self.findStaticViHistoryPatternMatch(direction, pattern, cursor);
    }

    fn queryViHistoryPatternMatch(self: *LineSession, direction: ViHistoryDirection, pattern: []const u8, start_cursor: ?i64) !?HistoryView.HistoryEntry {
        var cursor = start_cursor;
        while (true) {
            const entry = switch (direction) {
                .backward => try self.queryPreviousHistoryBefore("", cursor),
                .forward => if (cursor) |after| try self.queryNextHistory("", after) else null,
            } orelse return null;
            cursor = entry.id;
            if (viHistoryPatternMatches(pattern, entry.text)) return entry;
            entry.deinit(self.allocator);
        }
    }

    fn findStaticViHistoryPatternMatch(self: LineSession, direction: ViHistoryDirection, pattern: []const u8, cursor: ?i64) !?HistoryView.HistoryEntry {
        const index = switch (direction) {
            .backward => self.findPreviousHistoryPatternMatch(staticHistoryStart(self.history.entries.len, cursor), pattern),
            .forward => if (cursor) |after| self.findNextHistoryPatternMatch(@as(usize, @intCast(after)) + 1, pattern) else null,
        } orelse return null;
        return .{ .id = @intCast(index), .text = try self.allocator.dupe(u8, self.history.entries[index]) };
    }

    fn findPreviousHistoryPatternMatch(self: LineSession, start: usize, pattern: []const u8) ?usize {
        var index = start;
        while (index > 0) {
            index -= 1;
            if (self.historyEntryPatternMatches(index, pattern)) return index;
        }
        return null;
    }

    fn findNextHistoryPatternMatch(self: LineSession, start: usize, pattern: []const u8) ?usize {
        var index = start;
        while (index < self.history.entries.len) : (index += 1) {
            if (self.historyEntryPatternMatches(index, pattern)) return index;
        }
        return null;
    }

    fn historyEntryPatternMatches(self: LineSession, index: usize, pattern: []const u8) bool {
        if (!viHistoryPatternMatches(pattern, self.history.entries[index])) return false;
        const entry = self.history.entries[index];
        for (self.history.entries[index + 1 ..]) |newer| {
            if (!std.mem.eql(u8, newer, entry)) continue;
            if (viHistoryPatternMatches(pattern, newer)) return false;
        }
        return true;
    }

    fn viInsertPreviousBigword(self: *LineSession, maybe_count: ?usize) !void {
        const entry = try self.previousViHistoryEntry() orelse return;
        defer entry.deinit(self.allocator);
        const bigword = viHistoryBigword(entry.text, maybe_count) orelse return;

        try self.saveViUndo();
        if (self.editor.buffer.text().len != 0) {
            if (self.editor.buffer.cursor_byte < self.editor.buffer.text().len) self.editor.buffer.moveRight();
            try self.editor.buffer.insertText(" ");
        }
        try self.editor.buffer.insertText(bigword);
        self.vi_state = .insert;
        self.resetViCommandPrefix();
        self.completion_menu.clear(self.allocator);
    }

    fn previousViHistoryEntry(self: *LineSession) !?HistoryView.HistoryEntry {
        if (self.history.context != null and self.history.previous != null) return self.queryPreviousHistoryBefore("", self.history_index);
        const index = self.findPreviousHistoryMatch(staticHistoryStart(self.history.entries.len, self.history_index), "") orelse return null;
        return .{ .id = @intCast(index), .text = try self.allocator.dupe(u8, self.history.entries[index]) };
    }

    fn viCommentAndSubmit(self: *LineSession) !void {
        try self.saveViUndo();
        try self.editor.buffer.replaceRange(0, 0, "#");
        try self.submitInput();
    }

    fn saveViUndo(self: *LineSession) !void {
        const snapshot = try self.snapshotBuffer();
        if (self.vi_undo) |old| old.deinit(self.allocator);
        self.vi_undo = snapshot;
    }

    fn captureViLineUndo(self: *LineSession) !void {
        if (self.vi_line_undo != null) return;
        self.vi_line_undo = try self.snapshotBuffer();
    }

    fn snapshotBuffer(self: LineSession) !BufferSnapshot {
        return .{ .text = try self.allocator.dupe(u8, self.editor.buffer.text()), .cursor_byte = self.editor.buffer.cursor_byte };
    }

    fn restoreViUndo(self: *LineSession) !void {
        const snapshot = self.vi_undo orelse return;
        try self.editor.buffer.replace(snapshot.text);
        self.editor.buffer.cursor_byte = @min(snapshot.cursor_byte, self.editor.buffer.text().len);
        self.vi_undo = null;
        snapshot.deinit(self.allocator);
        self.completion_menu.clear(self.allocator);
    }

    fn restoreViLineUndo(self: *LineSession) !void {
        const snapshot = self.vi_line_undo orelse return;
        try self.editor.buffer.replace(snapshot.text);
        self.editor.buffer.cursor_byte = @min(snapshot.cursor_byte, self.editor.buffer.text().len);
        self.vi_line_undo = null;
        snapshot.deinit(self.allocator);
        self.completion_menu.clear(self.allocator);
    }

    fn clearViUndo(self: *LineSession) void {
        if (self.vi_undo) |snapshot| snapshot.deinit(self.allocator);
        self.vi_undo = null;
    }

    fn clearViLineUndo(self: *LineSession) void {
        if (self.vi_line_undo) |snapshot| snapshot.deinit(self.allocator);
        self.vi_line_undo = null;
    }

    pub fn cancel(self: *LineSession) !void {
        if (self.state != .editing and self.state != .history_search) return;
        self.completion_menu.clear(self.allocator);
        try self.editor.buffer.replace("");
        self.state = .canceled;
    }

    fn clearInput(self: *LineSession) !void {
        if (self.state != .editing) return;
        self.completion_menu.clear(self.allocator);
        if (self.editor.buffer.text().len == 0) return;
        try self.editor.buffer.replace("");
    }

    pub fn takeClearScreenRequest(self: *LineSession) bool {
        const requested = self.clear_screen_requested;
        self.clear_screen_requested = false;
        return requested;
    }

    pub fn invalidatePrompt(self: *LineSession) void {
        self.prompt_dirty = true;
    }

    pub fn takePromptInvalidation(self: *LineSession) bool {
        const dirty = self.prompt_dirty;
        self.prompt_dirty = false;
        return dirty;
    }

    pub fn replacePrompt(self: *LineSession, prompt: Prompt) !void {
        const bytes = try self.allocator.dupe(u8, prompt.bytes);
        self.allocator.free(self.prompt.bytes);
        self.prompt = .{
            .bytes = bytes,
            .visible_width = prompt.visible_width,
        };
        self.prompt_dirty = false;
    }

    pub fn applyCompletion(self: *LineSession, application: completion.Application) !void {
        switch (application) {
            .edit => |edit| {
                try self.editor.buffer.applyCompletionEdit(edit);
                try self.setPendingRemovableSuffix(edit);
                self.completion_menu.clear(self.allocator);
                self.completion_flash = null;
            },
            .ambiguous => |candidates| {
                try self.completion_menu.replace(self.allocator, candidates);
                self.completion_flash = null;
            },
            .none => {
                self.completion_menu.clear(self.allocator);
                self.completion_flash = completionFlashForCursor(self.editor.buffer.text(), self.editor.buffer.cursor_byte);
            },
        }
    }

    pub fn hasCompletionMenu(self: LineSession) bool {
        return self.completion_menu.isOpen();
    }

    pub fn hasCompletionFlash(self: LineSession) bool {
        return self.completion_flash != null;
    }

    pub fn beginPaste(self: *LineSession) void {
        self.paste_depth += 1;
    }

    pub fn endPaste(self: *LineSession) void {
        if (self.paste_depth != 0) self.paste_depth -= 1;
    }

    pub fn handlePaste(self: *LineSession, text: []const u8) !void {
        if (self.state != .editing and self.state != .history_search) return;
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(self.allocator);
        const pasted = try normalizePastedText(self.allocator, &normalized, text);
        try self.editor.buffer.insertText(pasted);
        self.completion_menu.clear(self.allocator);
        if (self.state == .history_search) {
            if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshHistorySearch(null);
        }
    }

    pub fn renderFrame(self: *LineSession, allocator: std.mem.Allocator, options: RenderOptions) !Frame {
        var render_options = options;
        var suggestion_suffix: ?[]const u8 = null;
        defer if (suggestion_suffix) |suffix| allocator.free(suffix);
        render_options.prompt = self.prompt;
        render_options.cursor_shape = self.cursorShape();
        render_options.completion_menu = self.completion_menu.candidates;
        render_options.completion_selection = self.completion_menu.selected;
        render_options.completion_window_start = self.completion_menu.visibleWindowStart(render_options.menuCandidateRows());
        render_options.completion_flash = self.completion_flash;
        self.completion_flash = null;
        if (self.state == .history_search) {
            var history_candidates: std.ArrayList(completion.Candidate) = .empty;
            defer history_candidates.deinit(allocator);
            var styled_labels: std.ArrayList([]const u8) = .empty;
            var history_label_width: usize = 0;
            defer {
                for (styled_labels.items) |label| allocator.free(label);
                styled_labels.deinit(allocator);
            }
            if (self.history_search_matches.items.len != 0) {
                for (self.history_search_matches.items) |entry| {
                    const label = try styledHistorySearchLabel(allocator, entry.text, self.history_search_query.items, render_options.theme);
                    try styled_labels.append(allocator, label);
                    history_label_width = @max(history_label_width, visibleWidth(label, render_options.width_method));
                    const description = try historySearchDescription(allocator, self.history.now, entry.when);
                    history_candidates.append(allocator, .{
                        .value = entry.text,
                        .display = label,
                        .description = description,
                        .kind = .plain,
                        .replace_start = 0,
                        .replace_end = self.editor.buffer.text().len,
                    }) catch |err| {
                        if (description) |owned| allocator.free(owned);
                        return err;
                    };
                    if (description) |owned| {
                        styled_labels.append(allocator, owned) catch |err| {
                            allocator.free(owned);
                            return err;
                        };
                    }
                }
            } else {
                history_label_width = visibleWidth("No history matches", render_options.width_method);
                try history_candidates.append(allocator, .{
                    .value = self.history_search_query.items,
                    .display = "No history matches",
                    .kind = .plain,
                    .replace_start = 0,
                    .replace_end = self.editor.buffer.text().len,
                });
            }
            render_options.completion_menu = history_candidates.items;
            render_options.completion_selection = self.history_search_selected;
            render_options.completion_window_start = 0;
            render_options.completion_label_width = @min(history_label_width, @as(usize, @intCast(render_options.width)) -| 3);
            return frameFromLine(allocator, self.editor, render_options);
        } else if (self.state == .editing) {
            // Ghost suggestions are editing aids; an accepted line must show
            // only the text that actually runs.
            if (try self.currentAutosuggestion(allocator)) |suggestion| {
                defer suggestion.deinit(allocator);
                const text = self.editor.buffer.text();
                if (std.mem.startsWith(u8, suggestion.text, text) and renderableInlineText(suggestion.text)) {
                    suggestion_suffix = try allocator.dupe(u8, suggestion.text[text.len..]);
                    render_options.suggestion = suggestion_suffix.?;
                }
            }
        }
        return frameFromLine(allocator, self.editor, render_options);
    }

    fn cursorShape(self: LineSession) CursorShape {
        if (self.state != .editing) return .default;
        if (self.editing_mode != .vi) return .default;
        return switch (self.vi_state) {
            .insert => .beam,
            .replace => .underline,
            .command => .block,
        };
    }

    pub fn render(self: *LineSession, allocator: std.mem.Allocator, options: RenderOptions) ![]const u8 {
        var frame = try self.renderFrame(allocator, options);
        defer frame.deinit(allocator);
        return serializeFullFrame(allocator, frame, options.synchronized_output);
    }

    pub fn takeSubmittedLine(self: *LineSession) ?[]const u8 {
        const line = self.submitted_line orelse return null;
        self.submitted_line = null;
        return line;
    }

    fn historyPrevious(self: *LineSession) !void {
        const prefix = try self.historyPrefix();
        if (try self.queryPreviousHistory(prefix)) |entry| {
            defer entry.deinit(self.allocator);
            self.history_index = entry.id;
            try self.editor.buffer.replace(entry.text);
            self.completion_menu.clear(self.allocator);
            return;
        }
        if (self.history.entries.len == 0) return;
        const start: usize = if (self.history_index) |index| @intCast(index) else self.history.entries.len;
        const index = self.findPreviousHistoryMatch(start, prefix) orelse return;
        self.history_index = @intCast(index);
        try self.editor.buffer.replace(self.history.entries[index]);
        self.completion_menu.clear(self.allocator);
    }

    fn historyNext(self: *LineSession) !void {
        const index = self.history_index orelse return;
        const prefix = self.saved_edit.items;
        if (try self.queryNextHistory(prefix, index)) |entry| {
            defer entry.deinit(self.allocator);
            self.history_index = entry.id;
            try self.editor.buffer.replace(entry.text);
            self.completion_menu.clear(self.allocator);
            return;
        }
        if (self.history.context != null) {
            self.history_index = null;
            try self.editor.buffer.replace(self.saved_edit.items);
            self.saved_edit.clearRetainingCapacity();
            self.completion_menu.clear(self.allocator);
            return;
        }
        const next_index = self.findNextHistoryMatch(@as(usize, @intCast(index)) + 1, prefix) orelse {
            self.history_index = null;
            try self.editor.buffer.replace(self.saved_edit.items);
            self.saved_edit.clearRetainingCapacity();
            self.completion_menu.clear(self.allocator);
            return;
        };
        self.history_index = @intCast(next_index);
        try self.editor.buffer.replace(self.history.entries[next_index]);
        self.completion_menu.clear(self.allocator);
    }

    fn queryPreviousHistory(self: *LineSession, prefix: []const u8) !?HistoryView.HistoryEntry {
        return self.queryPreviousHistoryBefore(prefix, self.history_index);
    }

    fn queryPreviousHistoryBefore(self: *LineSession, prefix: []const u8, before: ?i64) !?HistoryView.HistoryEntry {
        const context = self.history.context orelse return null;
        const previous = self.history.previous orelse return null;
        return previous(context, self.allocator, prefix, before);
    }

    fn queryNextHistory(self: *LineSession, prefix: []const u8, after: i64) !?HistoryView.HistoryEntry {
        const context = self.history.context orelse return null;
        const next = self.history.next orelse return null;
        return next(context, self.allocator, prefix, after);
    }

    fn beginHistorySearch(self: *LineSession) !void {
        const search = self.history.search orelse return;
        _ = search;
        self.history_search_query.clearRetainingCapacity();
        self.history_search_original.clearRetainingCapacity();
        try self.history_search_original.appendSlice(self.allocator, self.editor.buffer.text());
        try self.history_search_query.appendSlice(self.allocator, self.editor.buffer.text());
        self.clearHistorySearchMatch();
        self.state = .history_search;
        try self.refreshHistorySearch(null);
        self.completion_menu.clear(self.allocator);
    }

    fn handleHistorySearchKey(self: *LineSession, event: KeyEvent) !void {
        switch (event.key) {
            .enter => {
                if (self.selectedHistorySearchMatch()) |entry| try self.editor.buffer.replace(entry.text);
                self.finishHistorySearch();
            },
            .tab => if (event.modifiers.shift) self.selectPreviousHistorySearchMatch() else self.selectNextHistorySearchMatch(),
            .escape, .ctrl_c => {
                try self.editor.buffer.replace(self.history_search_original.items);
                self.finishHistorySearch();
            },
            .ctrl_r, .down => self.selectNextHistorySearchMatch(),
            .up => self.selectPreviousHistorySearchMatch(),
            .backspace => {
                self.editor.buffer.deletePrevious();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshHistorySearch(null);
            },
            .delete => {
                self.editor.buffer.deleteNext();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshHistorySearch(null);
            },
            .text => {
                if (event.text.len == 0) return;
                try self.editor.handleKey(event);
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshHistorySearch(null);
            },
            .left, .right, .home, .end, .word_left, .word_right => try self.editor.handleKey(event),
            .delete_to_start => {
                self.editor.buffer.deleteToStart();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshHistorySearch(null);
            },
            .delete_to_end => {
                self.editor.buffer.deleteToEnd();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshHistorySearch(null);
            },
            .delete_previous_word => {
                self.editor.buffer.deletePreviousWord();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshHistorySearch(null);
            },
            .delete_next_word => {
                self.editor.buffer.deleteNextWord();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshHistorySearch(null);
            },
            else => {},
        }
    }

    fn syncHistorySearchQueryFromBuffer(self: *LineSession) !bool {
        if (std.mem.eql(u8, self.history_search_query.items, self.editor.buffer.text())) return false;
        self.history_search_query.clearRetainingCapacity();
        try self.history_search_query.appendSlice(self.allocator, self.editor.buffer.text());
        return true;
    }

    fn refreshHistorySearch(self: *LineSession, before: ?i64) !void {
        self.clearHistorySearchMatch();
        self.clearHistorySearchMatches();
        self.history_search_selected = 0;
        const context = self.history.context orelse return;
        const search = self.history.search orelse return;
        var cursor = before;
        while (self.history_search_matches.items.len < 20) {
            const entry = try search(context, self.allocator, self.history_search_query.items, cursor) orelse break;
            cursor = entry.id;
            try self.history_search_matches.append(self.allocator, entry);
        }
        if (self.history_search_matches.items.len == 0 and before != null) {
            cursor = null;
            while (self.history_search_matches.items.len < 20) {
                const entry = try search(context, self.allocator, self.history_search_query.items, cursor) orelse break;
                cursor = entry.id;
                try self.history_search_matches.append(self.allocator, entry);
            }
        }
        if (self.history_search_matches.items.len != 0) self.history_search_match = try cloneHistoryEntry(self.allocator, self.history_search_matches.items[0]);
    }

    fn refreshHistorySearchNext(self: *LineSession, after: ?i64) !void {
        self.clearHistorySearchMatch();
        self.clearHistorySearchMatches();
        self.history_search_selected = 0;
        const context = self.history.context orelse return;
        const search_next = self.history.search_next orelse return try self.refreshHistorySearch(null);
        var cursor = after;
        while (self.history_search_matches.items.len < 20) {
            const entry = try search_next(context, self.allocator, self.history_search_query.items, cursor) orelse break;
            cursor = entry.id;
            try self.history_search_matches.append(self.allocator, entry);
        }
        if (self.history_search_matches.items.len == 0 and after != null) {
            cursor = null;
            while (self.history_search_matches.items.len < 20) {
                const entry = try search_next(context, self.allocator, self.history_search_query.items, cursor) orelse break;
                cursor = entry.id;
                try self.history_search_matches.append(self.allocator, entry);
            }
        }
        if (self.history_search_matches.items.len != 0) self.history_search_match = try cloneHistoryEntry(self.allocator, self.history_search_matches.items[0]);
    }

    fn selectedHistorySearchMatch(self: LineSession) ?HistoryView.HistoryEntry {
        if (self.history_search_matches.items.len == 0) return null;
        return self.history_search_matches.items[@min(self.history_search_selected, self.history_search_matches.items.len - 1)];
    }

    fn selectNextHistorySearchMatch(self: *LineSession) void {
        if (self.history_search_matches.items.len == 0) return;
        self.history_search_selected = @min(self.history_search_selected + 1, self.history_search_matches.items.len - 1);
        self.replaceHistorySearchMatchFromSelection() catch {};
    }

    fn selectPreviousHistorySearchMatch(self: *LineSession) void {
        if (self.history_search_matches.items.len == 0) return;
        self.history_search_selected = if (self.history_search_selected == 0) 0 else self.history_search_selected - 1;
        self.replaceHistorySearchMatchFromSelection() catch {};
    }

    fn replaceHistorySearchMatchFromSelection(self: *LineSession) !void {
        self.clearHistorySearchMatch();
        if (self.selectedHistorySearchMatch()) |entry| self.history_search_match = try cloneHistoryEntry(self.allocator, entry);
    }

    fn clearHistorySearchMatches(self: *LineSession) void {
        for (self.history_search_matches.items) |entry| entry.deinit(self.allocator);
        self.history_search_matches.clearRetainingCapacity();
    }

    fn finishHistorySearch(self: *LineSession) void {
        self.clearHistorySearchMatch();
        self.clearHistorySearchMatches();
        self.history_search_query.clearRetainingCapacity();
        self.history_search_original.clearRetainingCapacity();
        self.state = .editing;
    }

    fn clearHistorySearchMatch(self: *LineSession) void {
        if (self.history_search_match) |entry| entry.deinit(self.allocator);
        self.history_search_match = null;
    }

    fn currentAutosuggestion(self: *LineSession, allocator: std.mem.Allocator) !?HistoryView.HistoryEntry {
        if (self.completion_menu.isOpen()) return null;
        if (self.editor.buffer.cursor_byte != self.editor.buffer.text().len) return null;
        if (self.editor.buffer.text().len == 0) return null;
        const context = self.history.context orelse return null;
        const suggest = self.history.suggest orelse return null;
        return suggest(context, allocator, self.editor.buffer.text());
    }

    fn acceptAutosuggestion(self: *LineSession) !bool {
        if (try self.currentAutosuggestion(self.allocator)) |suggestion| {
            defer suggestion.deinit(self.allocator);
            if (!renderableInlineText(suggestion.text)) return false;
            try self.editor.buffer.replace(suggestion.text);
            self.completion_menu.clear(self.allocator);
            return true;
        }
        return false;
    }

    fn historyPrefix(self: *LineSession) ![]const u8 {
        if (self.history_index == null) {
            self.saved_edit.clearRetainingCapacity();
            try self.saved_edit.appendSlice(self.allocator, self.editor.buffer.text());
        }
        return self.saved_edit.items;
    }

    fn findPreviousHistoryMatch(self: LineSession, start: usize, prefix: []const u8) ?usize {
        var index = start;
        while (index > 0) {
            index -= 1;
            if (self.historyEntryMatches(index, prefix)) return index;
        }
        return null;
    }

    fn findNextHistoryMatch(self: LineSession, start: usize, prefix: []const u8) ?usize {
        var index = start;
        while (index < self.history.entries.len) : (index += 1) {
            if (self.historyEntryMatches(index, prefix)) return index;
        }
        return null;
    }

    fn historyEntryMatches(self: LineSession, index: usize, prefix: []const u8) bool {
        const entry = self.history.entries[index];
        if (prefix.len != 0 and !std.mem.startsWith(u8, entry, prefix)) return false;
        return self.isNewestMatchingCommand(index, prefix);
    }

    fn isNewestMatchingCommand(self: LineSession, index: usize, prefix: []const u8) bool {
        const entry = self.history.entries[index];
        for (self.history.entries[index + 1 ..]) |newer| {
            if (prefix.len != 0 and !std.mem.startsWith(u8, newer, prefix)) continue;
            if (std.mem.eql(u8, newer, entry)) return false;
        }
        return true;
    }

    fn applyCompletionCandidate(self: *LineSession, candidate: completion.Candidate) !void {
        const replacement = try completion.candidateEditReplacement(self.allocator, candidate);
        defer self.allocator.free(replacement);
        const suffix = try completion.candidateEditSuffix(self.allocator, candidate);
        defer if (suffix) |owned_suffix| self.allocator.free(owned_suffix);
        const edit: completion.Edit = .{
            .replace_start = candidate.replace_start,
            .replace_end = candidate.replace_end,
            .replacement = replacement,
            .suffix = suffix,
            .removable_suffix = candidate.removable_suffix,
            .append_space = candidate.append_space,
        };
        try self.editor.buffer.applyCompletionEdit(.{
            .replace_start = candidate.replace_start,
            .replace_end = candidate.replace_end,
            .replacement = replacement,
            .suffix = suffix,
            .removable_suffix = candidate.removable_suffix,
            .append_space = candidate.append_space,
        });
        try self.setPendingRemovableSuffix(edit);
        self.completion_menu.clear(self.allocator);
    }

    fn setPendingRemovableSuffix(self: *LineSession, edit: completion.Edit) !void {
        self.clearPendingRemovableSuffix();
        if (!edit.removable_suffix) return;
        const suffix = edit.suffix orelse return;
        if (suffix.len == 0 or edit.replacement.len < suffix.len) return;
        const suffix_end = edit.replace_start + edit.replacement.len;
        const suffix_start = suffix_end - suffix.len;
        if (suffix_end > self.editor.buffer.text().len) return;
        if (!std.mem.eql(u8, self.editor.buffer.text()[suffix_start..suffix_end], suffix)) return;
        self.pending_removable_suffix = .{
            .start = suffix_start,
            .end = suffix_end,
            .text = try self.allocator.dupe(u8, suffix),
        };
    }

    fn clearPendingRemovableSuffix(self: *LineSession) void {
        if (self.pending_removable_suffix) |pending| pending.deinit(self.allocator);
        self.pending_removable_suffix = null;
    }

    fn consumePendingRemovableSuffix(self: *LineSession, event: KeyEvent) !bool {
        const pending = self.pending_removable_suffix orelse return false;
        if (pending.end > self.editor.buffer.text().len or self.editor.buffer.cursor_byte != pending.end or !std.mem.eql(u8, self.editor.buffer.text()[pending.start..pending.end], pending.text)) {
            self.clearPendingRemovableSuffix();
            return false;
        }
        if (event.key == .text and event.text.len != 0) {
            if (std.mem.eql(u8, event.text, pending.text)) {
                self.clearPendingRemovableSuffix();
                self.completion_menu.clear(self.allocator);
                return true;
            }
            if (isRemovableSuffixTerminator(event)) {
                try self.removePendingRemovableSuffix();
                return false;
            }
            self.clearPendingRemovableSuffix();
            return false;
        }
        if (isRemovableSuffixTerminator(event)) {
            try self.removePendingRemovableSuffix();
            return false;
        }
        self.clearPendingRemovableSuffix();
        return false;
    }

    fn removePendingRemovableSuffix(self: *LineSession) !void {
        const pending = self.pending_removable_suffix orelse return;
        const start = pending.start;
        const end = pending.end;
        self.clearPendingRemovableSuffix();
        try self.editor.buffer.replaceRange(start, end, "");
    }

    fn killRange(self: *LineSession, start: usize, end: usize, cursor_byte: usize) !void {
        if (start == end) return;
        self.kill_ring.clearRetainingCapacity();
        try self.kill_ring.appendSlice(self.allocator, self.editor.buffer.text()[start..end]);
        try self.editor.buffer.replaceRange(start, end, "");
        self.editor.buffer.cursor_byte = cursor_byte;
        self.completion_menu.clear(self.allocator);
        self.clearPendingRemovableSuffix();
    }
};

fn isRemovableSuffixTerminator(event: KeyEvent) bool {
    return switch (event.key) {
        .enter => true,
        .text => std.mem.eql(u8, event.text, " ") or std.mem.eql(u8, event.text, "\n"),
        else => false,
    };
}

fn reverseViHistoryDirection(direction: ViHistoryDirection) ViHistoryDirection {
    return switch (direction) {
        .backward => .forward,
        .forward => .backward,
    };
}

fn isPortableAlphabetic(codepoint: u21) bool {
    return (codepoint >= 'A' and codepoint <= 'Z') or (codepoint >= 'a' and codepoint <= 'z');
}

fn viMacroKeyEvent(bytes: []const u8, index: *usize) ?KeyEvent {
    if (index.* >= bytes.len) return null;
    const start = index.*;
    const byte = bytes[start];
    index.* += 1;
    return switch (byte) {
        '\x1b' => .{ .key = .escape },
        '\r', '\n' => .{ .key = .enter },
        '\x08', '\x7f' => .{ .key = .backspace },
        else => blk: {
            if (byte >= 0x80) index.* = @min(nextCodepointEnd(bytes, start), bytes.len);
            break :blk .{ .key = .text, .text = bytes[start..index.*] };
        },
    };
}

fn staticHistoryStart(entry_count: usize, cursor: ?i64) usize {
    const index = cursor orelse return entry_count;
    if (index < 0) return 0;
    return @min(@as(usize, @intCast(index)), entry_count);
}

fn viHistoryBigword(line: []const u8, maybe_count: ?usize) ?[]const u8 {
    var last: ?[]const u8 = null;
    var ordinal: usize = 0;
    var index: usize = 0;
    while (index < line.len) {
        while (index < line.len and isAsciiWhitespace(line[index])) index += 1;
        if (index >= line.len) break;
        const start = index;
        while (index < line.len and !isAsciiWhitespace(line[index])) index += 1;
        ordinal += 1;
        const bigword = line[start..index];
        if (maybe_count) |count| {
            if (ordinal == count) return bigword;
        } else {
            last = bigword;
        }
    }
    return last;
}

fn viHistoryPatternMatches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern[0] == '^') return viHistoryPatternMatchesAt(pattern[1..], text, 0, 0);

    var text_index: usize = 0;
    while (true) {
        if (viHistoryPatternMatchesAt(pattern, text, 0, text_index)) return true;
        if (text_index >= text.len) break;
        text_index = nextCodepointEnd(text, text_index);
    }
    return false;
}

fn viHistoryPatternMatchesAt(pattern: []const u8, text: []const u8, pattern_index: usize, text_index: usize) bool {
    if (pattern_index == pattern.len) return true;

    switch (pattern[pattern_index]) {
        '\\' => {
            const literal_index = pattern_index + 1;
            if (literal_index >= pattern.len) return text_index < text.len and text[text_index] == '\\' and viHistoryPatternMatchesAt(pattern, text, literal_index, text_index + 1);
            return text_index < text.len and text[text_index] == pattern[literal_index] and viHistoryPatternMatchesAt(pattern, text, literal_index + 1, text_index + 1);
        },
        '*' => {
            var next_text = text_index;
            while (true) {
                if (viHistoryPatternMatchesAt(pattern, text, pattern_index + 1, next_text)) return true;
                if (next_text >= text.len) break;
                next_text = nextCodepointEnd(text, next_text);
            }
            return false;
        },
        '?' => return text_index < text.len and viHistoryPatternMatchesAt(pattern, text, pattern_index + 1, nextCodepointEnd(text, text_index)),
        '[' => {
            if (matchViHistoryPatternBracket(pattern, pattern_index, text, text_index)) |matched| {
                return matched.ok and viHistoryPatternMatchesAt(pattern, text, matched.next_pattern, nextCodepointEnd(text, text_index));
            }
            return text_index < text.len and text[text_index] == '[' and viHistoryPatternMatchesAt(pattern, text, pattern_index + 1, text_index + 1);
        },
        else => |byte| return text_index < text.len and text[text_index] == byte and viHistoryPatternMatchesAt(pattern, text, pattern_index + 1, text_index + 1),
    }
}

const ViHistoryPatternBracketMatch = struct { ok: bool, next_pattern: usize };

fn matchViHistoryPatternBracket(pattern: []const u8, pattern_index: usize, text: []const u8, text_index: usize) ?ViHistoryPatternBracketMatch {
    if (text_index >= text.len) return .{ .ok = false, .next_pattern = pattern_index + 1 };
    var index = pattern_index + 1;
    if (index >= pattern.len) return null;
    const negated = pattern[index] == '!' or pattern[index] == '^';
    if (negated) index += 1;

    var matched = false;
    var saw_end = false;
    var first_expression = true;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == ']' and !first_expression) {
            saw_end = true;
            break;
        }
        first_expression = false;

        if (matchViHistoryPatternBracketCharacterClass(pattern, index, text[text_index])) |class| {
            if (class.ok) matched = true;
            index = class.end_index;
            continue;
        }

        if (index + 2 < pattern.len and pattern[index + 1] == '-' and pattern[index + 2] != ']') {
            const start = pattern[index];
            const end = pattern[index + 2];
            if (start <= text[text_index] and text[text_index] <= end) matched = true;
            index += 2;
            continue;
        }

        if (pattern[index] == '\\' and index + 1 < pattern.len) index += 1;
        if (pattern[index] == text[text_index]) matched = true;
    }
    if (!saw_end) return null;
    return .{ .ok = if (negated) !matched else matched, .next_pattern = index + 1 };
}

const ViHistoryPatternBracketClassMatch = struct { ok: bool, end_index: usize };

fn matchViHistoryPatternBracketCharacterClass(pattern: []const u8, index: usize, text: u8) ?ViHistoryPatternBracketClassMatch {
    if (index + 3 >= pattern.len or pattern[index] != '[' or pattern[index + 1] != ':') return null;
    const name_start = index + 2;
    var name_end = name_start;
    while (name_end + 1 < pattern.len) : (name_end += 1) {
        if (pattern[name_end] == ':' and pattern[name_end + 1] == ']') {
            const ok = bracketCharacterClassMatches(pattern[name_start..name_end], text) orelse return null;
            return .{ .ok = ok, .end_index = name_end + 1 };
        }
    }
    return null;
}

fn bracketCharacterClassMatches(class_name: []const u8, text: u8) ?bool {
    if (std.mem.eql(u8, class_name, "alnum")) return std.ascii.isAlphanumeric(text);
    if (std.mem.eql(u8, class_name, "alpha")) return std.ascii.isAlphabetic(text);
    if (std.mem.eql(u8, class_name, "blank")) return text == ' ' or text == '\t';
    if (std.mem.eql(u8, class_name, "cntrl")) return std.ascii.isControl(text);
    if (std.mem.eql(u8, class_name, "digit")) return std.ascii.isDigit(text);
    if (std.mem.eql(u8, class_name, "graph")) return std.ascii.isGraphical(text);
    if (std.mem.eql(u8, class_name, "lower")) return std.ascii.isLower(text);
    if (std.mem.eql(u8, class_name, "print")) return std.ascii.isPrint(text);
    if (std.mem.eql(u8, class_name, "punct")) return std.ascii.isPunctuation(text);
    if (std.mem.eql(u8, class_name, "space")) return std.ascii.isWhitespace(text);
    if (std.mem.eql(u8, class_name, "upper")) return std.ascii.isUpper(text);
    if (std.mem.eql(u8, class_name, "xdigit")) return std.ascii.isHex(text);
    return null;
}

fn cloneHistoryEntry(allocator: std.mem.Allocator, entry: HistoryView.HistoryEntry) !HistoryView.HistoryEntry {
    return .{ .id = entry.id, .text = try allocator.dupe(u8, entry.text), .when = entry.when };
}

fn normalizePastedText(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\r') == null) return text;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\r') {
            try buffer.append(allocator, '\n');
            if (index + 1 < text.len and text[index + 1] == '\n') index += 1;
        } else {
            try buffer.append(allocator, text[index]);
        }
    }
    return buffer.items;
}

fn historySearchDescription(allocator: std.mem.Allocator, now: i64, when: i64) !?[]const u8 {
    if (now <= 0 or when <= 0) return null;
    var age_buffer: [16]u8 = undefined;
    const age = relativeAge(&age_buffer, now, when);
    return try allocator.dupe(u8, age);
}

pub fn relativeAge(buffer: *[16]u8, now: i64, when: i64) []const u8 {
    const elapsed = @max(now - when, 0);
    const value = if (elapsed < 60)
        elapsed
    else if (elapsed < 60 * 60)
        @divTrunc(elapsed, 60)
    else if (elapsed < 24 * 60 * 60)
        @divTrunc(elapsed, 60 * 60)
    else
        @divTrunc(elapsed, 24 * 60 * 60);
    const suffix: u8 = if (elapsed < 60) 's' else if (elapsed < 60 * 60) 'm' else if (elapsed < 24 * 60 * 60) 'h' else 'd';
    return std.fmt.bufPrint(buffer, "{d}{c}", .{ value, suffix }) catch unreachable;
}

fn styledHistorySearchLabel(allocator: std.mem.Allocator, text: []const u8, query: []const u8, theme: UiTheme) ![]const u8 {
    const positions = (try completion.fuzzyMatchPositions(allocator, text, query)) orelse return try allocator.dupe(u8, text);
    defer allocator.free(positions);
    if (positions.len == 0) return try allocator.dupe(u8, text);

    var label: std.ArrayList(u8) = .empty;
    errdefer label.deinit(allocator);
    var position_index: usize = 0;
    for (text, 0..) |byte, index| {
        if (position_index < positions.len and positions[position_index] == index) {
            try appendUiStyleStart(allocator, &label, theme.history_match);
            try label.append(allocator, byte);
            try appendUiStyleEnd(allocator, &label, theme.history_match);
            position_index += 1;
        } else {
            try label.append(allocator, byte);
        }
    }
    return label.toOwnedSlice(allocator);
}

pub fn renderLine(allocator: std.mem.Allocator, editor: Editor, options: RenderOptions) ![]const u8 {
    return render.renderLine(allocator, .{
        .text = editor.buffer.text(),
        .cursor_byte = editor.buffer.cursor_byte,
    }, options);
}

pub fn frameFromLine(allocator: std.mem.Allocator, editor: Editor, options: RenderOptions) !Frame {
    return render.frameFromInput(allocator, .{
        .text = editor.buffer.text(),
        .cursor_byte = editor.buffer.cursor_byte,
    }, options);
}

fn viMotion(bytes: []const u8, cursor_byte: usize, command: u21, count: usize) ?ViMotionResult {
    if (bytes.len == 0) return .{ .cursor = 0 };
    return switch (command) {
        '0' => .{ .cursor = 0 },
        '^' => .{ .cursor = firstNonBlank(bytes) },
        '$' => if (count == 1) .{ .cursor = lastGraphemeStart(bytes), .inclusive = true } else null,
        'h' => .{ .cursor = previousViCharacter(bytes, cursor_byte, count) },
        'l', ' ' => .{ .cursor = nextViCharacter(bytes, cursor_byte, count) },
        '|' => .{ .cursor = nthViCharacter(bytes, count) },
        'w' => .{ .cursor = nextViWordStartCount(bytes, cursor_byte, count, .word) },
        'W' => .{ .cursor = nextViWordStartCount(bytes, cursor_byte, count, .bigword) },
        'e' => .{ .cursor = nextViWordEndCount(bytes, cursor_byte, count, .word), .inclusive = true },
        'E' => .{ .cursor = nextViWordEndCount(bytes, cursor_byte, count, .bigword), .inclusive = true },
        'b' => .{ .cursor = previousViWordStartCount(bytes, cursor_byte, count, .word) },
        'B' => .{ .cursor = previousViWordStartCount(bytes, cursor_byte, count, .bigword) },
        else => null,
    };
}

fn viMotionRange(bytes: []const u8, cursor_byte: usize, motion: ViMotionResult) ViMotionRange {
    if (motion.cursor < cursor_byte) return .{ .start = motion.cursor, .end = cursor_byte, .cursor_after_delete = motion.cursor };
    const end = if (motion.inclusive) nextGraphemeEnd(bytes, motion.cursor) else motion.cursor;
    return .{ .start = cursor_byte, .end = end, .cursor_after_delete = cursor_byte };
}

fn viOperatorMotionRange(bytes: []const u8, cursor_byte: usize, operator: ViOperator, motion_command: u21, count: usize, motion: ViMotionResult) ViMotionRange {
    if (operator == .change and (motion_command == 'w' or motion_command == 'W')) {
        return viChangeWordMotionRange(bytes, cursor_byte, motion_command, count, motion);
    }
    if ((motion_command == 'w' or motion_command == 'W') and motion.cursor == lastGraphemeStart(bytes) and motion.cursor >= cursor_byte) {
        return .{ .start = cursor_byte, .end = bytes.len, .cursor_after_delete = cursor_byte };
    }
    return viMotionRange(bytes, cursor_byte, motion);
}

fn viChangeWordMotionRange(bytes: []const u8, cursor_byte: usize, motion_command: u21, count: usize, motion: ViMotionResult) ViMotionRange {
    if (bytes.len == 0 or motion.cursor <= cursor_byte) return viMotionRange(bytes, cursor_byte, motion);
    if (count == 1 and cursor_byte < bytes.len and isAsciiWhitespace(bytes[cursor_byte])) {
        return .{ .start = cursor_byte, .end = nextCodepointEnd(bytes, cursor_byte), .cursor_after_delete = cursor_byte };
    }
    if (motion.cursor == lastGraphemeStart(bytes)) {
        return .{ .start = cursor_byte, .end = bytes.len, .cursor_after_delete = cursor_byte };
    }

    var end = motion.cursor;
    while (end > cursor_byte) {
        const previous = previousCodepointStart(bytes, end);
        if (!isAsciiWhitespace(bytes[previous])) break;
        end = previous;
    }
    if (end == cursor_byte and (motion_command == 'w' or motion_command == 'W')) end = motion.cursor;
    return .{ .start = cursor_byte, .end = end, .cursor_after_delete = cursor_byte };
}

fn multiplyViCounts(a: usize, b: usize) usize {
    if (a != 0 and b > std.math.maxInt(usize) / a) return std.math.maxInt(usize);
    return a * b;
}

fn previousViCharacter(bytes: []const u8, cursor_byte: usize, count: usize) usize {
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0 and cursor != 0) : (remaining -= 1) cursor = previousGraphemeStart(bytes, cursor);
    return cursor;
}

fn nextViCharacter(bytes: []const u8, cursor_byte: usize, count: usize) usize {
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0 and cursor < lastGraphemeStart(bytes)) : (remaining -= 1) cursor = nextGraphemeEnd(bytes, cursor);
    return @min(cursor, lastGraphemeStart(bytes));
}

fn nthViCharacter(bytes: []const u8, count: usize) usize {
    var cursor: usize = 0;
    var remaining = count - 1;
    while (remaining != 0 and cursor < lastGraphemeStart(bytes)) : (remaining -= 1) cursor = nextGraphemeEnd(bytes, cursor);
    return cursor;
}

fn lastGraphemeStart(bytes: []const u8) usize {
    return previousGraphemeStart(bytes, bytes.len);
}

fn firstNonBlank(bytes: []const u8) usize {
    var cursor: usize = 0;
    while (cursor < bytes.len) : (cursor = nextCodepointEnd(bytes, cursor)) {
        if (!isAsciiWhitespace(bytes[cursor])) return cursor;
    }
    return 0;
}

fn nextViWordStartCount(bytes: []const u8, cursor_byte: usize, count: usize, kind: ViWordKind) usize {
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) cursor = nextViWordStart(bytes, cursor, kind);
    return cursor;
}

fn nextViWordStart(bytes: []const u8, cursor_byte: usize, kind: ViWordKind) usize {
    if (cursor_byte >= lastGraphemeStart(bytes)) return lastGraphemeStart(bytes);
    var cursor = nextCodepointEnd(bytes, cursor_byte);
    if (kind == .bigword) {
        while (cursor < bytes.len and !isAsciiWhitespace(bytes[cursor])) cursor = nextCodepointEnd(bytes, cursor);
    } else if (cursor_byte < bytes.len and !isAsciiWhitespace(bytes[cursor_byte])) {
        const class = viWordClass(bytes[cursor_byte]);
        while (cursor < bytes.len and !isAsciiWhitespace(bytes[cursor]) and viWordClass(bytes[cursor]) == class) cursor = nextCodepointEnd(bytes, cursor);
    }
    while (cursor < bytes.len and isAsciiWhitespace(bytes[cursor])) cursor = nextCodepointEnd(bytes, cursor);
    return if (cursor >= bytes.len) lastGraphemeStart(bytes) else cursor;
}

fn nextViWordEndCount(bytes: []const u8, cursor_byte: usize, count: usize, kind: ViWordKind) usize {
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) cursor = nextViWordEnd(bytes, cursor, kind);
    return cursor;
}

fn nextViWordEnd(bytes: []const u8, cursor_byte: usize, kind: ViWordKind) usize {
    if (cursor_byte >= lastGraphemeStart(bytes)) return lastGraphemeStart(bytes);
    var cursor = cursor_byte;
    if (cursor < bytes.len and !isAsciiWhitespace(bytes[cursor]) and viAtWordEnd(bytes, cursor, kind)) {
        cursor = nextViWordStart(bytes, cursor, kind);
    } else if (cursor < bytes.len and isAsciiWhitespace(bytes[cursor])) {
        while (cursor < bytes.len and isAsciiWhitespace(bytes[cursor])) cursor = nextCodepointEnd(bytes, cursor);
    }
    if (cursor >= bytes.len) return lastGraphemeStart(bytes);
    if (kind == .bigword) {
        while (nextCodepointEnd(bytes, cursor) < bytes.len and !isAsciiWhitespace(bytes[nextCodepointEnd(bytes, cursor)])) cursor = nextCodepointEnd(bytes, cursor);
    } else {
        const class = viWordClass(bytes[cursor]);
        while (nextCodepointEnd(bytes, cursor) < bytes.len and !isAsciiWhitespace(bytes[nextCodepointEnd(bytes, cursor)]) and viWordClass(bytes[nextCodepointEnd(bytes, cursor)]) == class) cursor = nextCodepointEnd(bytes, cursor);
    }
    return cursor;
}

fn viAtWordEnd(bytes: []const u8, cursor_byte: usize, kind: ViWordKind) bool {
    const next = nextCodepointEnd(bytes, cursor_byte);
    if (next >= bytes.len) return true;
    if (isAsciiWhitespace(bytes[next])) return true;
    if (kind == .bigword) return false;
    return viWordClass(bytes[cursor_byte]) != viWordClass(bytes[next]);
}

fn previousViWordStartCount(bytes: []const u8, cursor_byte: usize, count: usize, kind: ViWordKind) usize {
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) cursor = previousViWordStart(bytes, cursor, kind);
    return cursor;
}

fn previousViWordStart(bytes: []const u8, cursor_byte: usize, kind: ViWordKind) usize {
    if (cursor_byte == 0) return 0;
    var cursor = previousCodepointStart(bytes, cursor_byte);
    while (cursor != 0 and isAsciiWhitespace(bytes[cursor])) cursor = previousCodepointStart(bytes, cursor);
    if (kind == .bigword) {
        while (cursor != 0) {
            const previous = previousCodepointStart(bytes, cursor);
            if (isAsciiWhitespace(bytes[previous])) break;
            cursor = previous;
        }
    } else {
        const class = viWordClass(bytes[cursor]);
        while (cursor != 0) {
            const previous = previousCodepointStart(bytes, cursor);
            if (isAsciiWhitespace(bytes[previous]) or viWordClass(bytes[previous]) != class) break;
            cursor = previous;
        }
    }
    return cursor;
}

fn viWordClass(byte: u8) enum { word, punct } {
    return if (std.ascii.isAlphanumeric(byte) or byte == '_') .word else .punct;
}

fn viFind(bytes: []const u8, cursor_byte: usize, find: ViFindCommand, count: usize) ?usize {
    if (bytes.len == 0) return null;
    var cursor = cursor_byte;
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) {
        cursor = switch (find.direction) {
            .forward => findCodepointForward(bytes, cursor, find.char) orelse return null,
            .backward => findCodepointBackward(bytes, cursor, find.char) orelse return null,
        };
    }
    return switch (find.placement) {
        .on_character => cursor,
        .before_character => if (cursor == 0) cursor else previousGraphemeStart(bytes, cursor),
        .after_character => @min(nextGraphemeEnd(bytes, cursor), lastGraphemeStart(bytes)),
    };
}

fn findCodepointForward(bytes: []const u8, cursor_byte: usize, needle: u21) ?usize {
    var cursor = nextCodepointEnd(bytes, cursor_byte);
    while (cursor < bytes.len) : (cursor = nextCodepointEnd(bytes, cursor)) {
        if (codepointAt(bytes, cursor) == needle) return cursor;
    }
    return null;
}

fn findCodepointBackward(bytes: []const u8, cursor_byte: usize, needle: u21) ?usize {
    if (cursor_byte == 0) return null;
    var cursor = previousCodepointStart(bytes, cursor_byte);
    while (true) {
        if (codepointAt(bytes, cursor) == needle) return cursor;
        if (cursor == 0) return null;
        cursor = previousCodepointStart(bytes, cursor);
    }
}

fn reverseViFind(find: ViFindCommand) ViFindCommand {
    return .{
        .direction = switch (find.direction) {
            .forward => .backward,
            .backward => .forward,
        },
        .placement = switch (find.placement) {
            .on_character => .on_character,
            .before_character => .after_character,
            .after_character => .before_character,
        },
        .char = find.char,
    };
}

fn firstCodepoint(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    return codepointAt(bytes, 0);
}

fn codepointAt(bytes: []const u8, cursor_byte: usize) ?u21 {
    if (cursor_byte >= bytes.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[cursor_byte]) catch return null;
    if (cursor_byte + len > bytes.len) return null;
    return std.unicode.utf8Decode(bytes[cursor_byte .. cursor_byte + len]) catch null;
}

fn previousCodepointStart(bytes: []const u8, cursor_byte: usize) usize {
    var i = cursor_byte - 1;
    while (i != 0 and (bytes[i] & 0xc0) == 0x80) i -= 1;
    return i;
}

fn nextCodepointEnd(bytes: []const u8, cursor_byte: usize) usize {
    if (cursor_byte >= bytes.len) return bytes.len;
    const len = std.unicode.utf8ByteSequenceLength(bytes[cursor_byte]) catch return bytes.len;
    return cursor_byte + len;
}

fn isAsciiWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

test "line session yanks last killed text" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git checkout main" });
    try session.handleKey(.{ .key = .word_left });
    try session.handleKey(.{ .key = .delete_to_end });
    try std.testing.expectEqualStrings("git checkout ", session.editor.buffer.text());
    try session.handleKey(.{ .key = .yank });
    try std.testing.expectEqualStrings("git checkout main", session.editor.buffer.text());
}

test "line session yanks killed previous and next words" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git checkout main" });
    try session.handleKey(.{ .key = .word_left });
    try session.handleKey(.{ .key = .delete_previous_word });
    try std.testing.expectEqualStrings("git main", session.editor.buffer.text());
    try session.handleKey(.{ .key = .yank });
    try std.testing.expectEqualStrings("git checkout main", session.editor.buffer.text());
    try session.handleKey(.{ .key = .home });
    try session.handleKey(.{ .key = .delete_next_word });
    try std.testing.expectEqualStrings(" checkout main", session.editor.buffer.text());
    try session.handleKey(.{ .key = .yank });
    try std.testing.expectEqualStrings("git checkout main", session.editor.buffer.text());
}

test "line session emacs control keys edit command line" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = keyFromVaxis('f', .{ .ctrl = true }) });
    try session.handleKey(.{ .key = .text, .text = "abcd ef" });
    try session.handleKey(.{ .key = keyFromVaxis('a', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 0), session.editor.buffer.cursor_byte);
    try session.handleKey(.{ .key = keyFromVaxis('f', .{ .ctrl = true }) });
    try session.handleKey(.{ .key = keyFromVaxis('f', .{ .ctrl = true }) });
    try session.handleKey(.{ .key = keyFromVaxis('t', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("bacd ef", session.editor.buffer.text());
    try session.handleKey(.{ .key = keyFromVaxis('k', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("ba", session.editor.buffer.text());
    try session.handleKey(.{ .key = keyFromVaxis('y', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("bacd ef", session.editor.buffer.text());
    try session.handleKey(.{ .key = keyFromVaxis('e', .{ .ctrl = true }) });
    try session.handleKey(.{ .key = keyFromVaxis('b', .{ .ctrl = true }) });
    try session.handleKey(.{ .key = keyFromVaxis('w', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("bacd f", session.editor.buffer.text());
    try session.handleKey(.{ .key = keyFromVaxis('u', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("f", session.editor.buffer.text());
}

test "line session records clear screen requests" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .clear_screen });
    try std.testing.expect(session.takeClearScreenRequest());
    try std.testing.expect(!session.takeClearScreenRequest());
}

test "editor handles readline movement and deletion keys" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    try editor.handleKey(.{ .key = .text, .text = "git checkout main" });
    try editor.handleKey(.{ .key = .word_left });
    try std.testing.expectEqual(@as(usize, "git checkout ".len), editor.buffer.cursor_byte);
    try editor.handleKey(.{ .key = .delete_to_end });
    try std.testing.expectEqualStrings("git checkout ", editor.buffer.text());
    try editor.handleKey(.{ .key = .delete_previous_word });
    try std.testing.expectEqualStrings("git ", editor.buffer.text());
    try std.testing.expectEqual(@as(usize, "git ".len), editor.buffer.cursor_byte);
}

test "line session applies completion edit" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();
    try session.editor.buffer.replace("git st");

    const application: completion.Application = .{ .edit = .{
        .replace_start = 4,
        .replace_end = 6,
        .replacement = "status",
        .append_space = true,
    } };
    try session.applyCompletion(application);

    try std.testing.expectEqualStrings("git status ", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, "git status ".len), session.editor.buffer.cursor_byte);
}

test "line session leaves ambiguous and empty completions unchanged" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();
    try session.editor.buffer.replace("git ");

    try session.applyCompletion(.{ .ambiguous = &.{} });
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try session.applyCompletion(.none);
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
}

test "line session flashes current word when completion has no candidates" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git zzz");

    try session.applyCompletion(.none);
    const flashed = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(flashed);
    try std.testing.expect(std.mem.indexOf(u8, flashed, "git \x1b[38;5;0m\x1b[48;5;7mzzz\x1b[49m\x1b[39m") != null);

    const normal = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(normal);
    try std.testing.expect(std.mem.indexOf(u8, normal, "\x1b[38;5;0m\x1b[48;5;7mzzz") == null);
}

test "line session renders ambiguous completion menu" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git che");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .description = "switch branches", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
        .{ .value = "cherry-pick", .display = "cherry", .description = "apply commits", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "checkout") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cherry") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "switch branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "apply commits") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1m\x1b[38;5;6m❯") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2mswitch branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "git che") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2A") != null);
}

test "completion menu styles candidates by kind" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "--help", .description = "show help", .kind = .option, .replace_start = 0, .replace_end = 0 },
        .{ .value = "$HOME", .description = "home directory", .kind = .variable, .replace_start = 0, .replace_end = 0 },
        .{ .value = "src/", .description = "source directory", .kind = .directory, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;6m--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;5m$HOME") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;4msrc/") != null);
}

test "ui style parser supports colors and attributes" {
    const style = parseUiStyle("fg=bright-blue,bg=#112233,ul=dashed,ul_color=red,bold,dim,italic,reverse,strike") orelse return error.MissingStyle;
    try std.testing.expectEqual(vaxis.Color{ .index = 12 }, style.fg.?);
    try std.testing.expectEqual(vaxis.Color.rgbFromUint(0x112233), style.bg.?);
    try std.testing.expectEqual(UnderlineStyle.dashed, style.ul);
    try std.testing.expectEqual(vaxis.Color{ .index = 1 }, style.ul_color.?);
    try std.testing.expect(style.bold);
    try std.testing.expect(style.dim);
    try std.testing.expect(style.italic);
    try std.testing.expect(style.reverse);
    try std.testing.expect(style.strike);
    try std.testing.expect(parseUiStyle("fg=nope") == null);
}

test "completion menu renders paired option spellings" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{.{
        .value = "--interactive",
        .description = "add modified contents interactively",
        .kind = .option,
        .option = .{ .long = "interactive", .short = "i" },
        .replace_start = 0,
        .replace_end = 0,
    }};
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--interactive,-i") != null);
}

test "completion menu does not render trailing scrollbar border" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 3 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "┃") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "│") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 1-1 of 3") != null);
}

test "completion menu selection accepts selected candidate" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git che");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .enter });

    try std.testing.expectEqualStrings("git cherry-pick ", session.editor.buffer.text());
    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.candidates.len);
}

test "completion menu acceptance uses insertion text while rendering display text" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("cat two\\ w");
    var candidates = [_]completion.Candidate{
        .{ .value = "two words", .display = "two words", .insert = "two\\ words", .kind = .file, .replace_start = 4, .replace_end = "cat two\\ w".len },
        .{ .value = "two ways", .display = "two ways", .insert = "two\\ ways", .kind = .file, .replace_start = 4, .replace_end = "cat two\\ w".len },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "two words") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "two\\ words") == null);

    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .enter });

    try std.testing.expectEqualStrings("cat two\\ words ", session.editor.buffer.text());
    try std.testing.expectEqual(LineSession.State.editing, session.state);
}

test "accepting completion clears previously rendered menu rows" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git che");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const menu_frame = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_frame);
    try std.testing.expect(std.mem.indexOf(u8, menu_frame, "checkout") != null);

    try session.handleKey(.{ .key = .tab });
    try session.handleKey(.{ .key = .enter });
    const accepted_frame = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(accepted_frame);
    try std.testing.expect(std.mem.indexOf(u8, accepted_frame, "git checkout ") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_frame, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_frame, "\x1b[2A") == null);
}

test "completion menu selection clamps with arrow keys" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
}

test "completion menu moves selection with tab and shift tab" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "switch", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
    };

    try session.applyCompletion(.{ .ambiguous = &candidates });
    try std.testing.expect(session.hasCompletionMenu());
    try std.testing.expect(session.completion_menu.selectedCandidate() == null);

    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .tab, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 2), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 2), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('p', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('p', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);

    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("git status ", session.editor.buffer.text());
}

test "completion menu remains open across text edits and modifier-only events" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git s");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 5 },
        .{ .value = "switch", .kind = .subcommand, .replace_start = 4, .replace_end = 5 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .text, .text = "t" });
    try std.testing.expectEqualStrings("git st", session.editor.buffer.text());
    try std.testing.expect(session.hasCompletionMenu());
    try session.handleKey(.{ .key = .text, .text = "" });
    try std.testing.expectEqualStrings("git st", session.editor.buffer.text());
    try std.testing.expect(session.hasCompletionMenu());

    try session.handleKey(.{ .key = .escape });
    try std.testing.expect(!session.hasCompletionMenu());
}

test "completion menu closes on deletion edits" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git st");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .backspace });
    try std.testing.expectEqualStrings("git s", session.editor.buffer.text());
    try std.testing.expect(!session.hasCompletionMenu());

    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .delete_previous_word });
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try std.testing.expect(!session.hasCompletionMenu());
}

test "completion menu closes on cursor movement" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git st");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .left });
    try std.testing.expectEqual(@as(usize, "git s".len), session.editor.buffer.cursor_byte);
    try std.testing.expect(!session.hasCompletionMenu());

    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .home });
    try std.testing.expectEqual(@as(usize, 0), session.editor.buffer.cursor_byte);
    try std.testing.expect(!session.hasCompletionMenu());
}

test "completion edit clears rendered menu" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git st");
    var candidates = [_]completion.Candidate{.{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 6 }};
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.candidates.len);

    try session.applyCompletion(.{ .edit = .{ .replace_start = 4, .replace_end = 6, .replacement = "status", .append_space = true } });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.candidates.len);
    try std.testing.expectEqualStrings("git status ", session.editor.buffer.text());
}

test "removable completion suffix keeps remove and types through" {
    var keep = try LineSession.init(std.testing.allocator, "$ ");
    defer keep.deinit();
    try keep.editor.buffer.replace("tool bl");
    try keep.applyCompletion(.{ .edit = .{ .replace_start = "tool ".len, .replace_end = "tool bl".len, .replacement = "blue,", .suffix = ",", .removable_suffix = true } });
    try std.testing.expectEqualStrings("tool blue,", keep.editor.buffer.text());
    try keep.handleKey(.{ .key = .text, .text = "," });
    try std.testing.expectEqualStrings("tool blue,", keep.editor.buffer.text());

    var remove = try LineSession.init(std.testing.allocator, "$ ");
    defer remove.deinit();
    try remove.editor.buffer.replace("tool bl");
    try remove.applyCompletion(.{ .edit = .{ .replace_start = "tool ".len, .replace_end = "tool bl".len, .replacement = "blue,", .suffix = ",", .removable_suffix = true } });
    try remove.handleKey(.{ .key = .text, .text = " " });
    try std.testing.expectEqualStrings("tool blue ", remove.editor.buffer.text());

    var accept = try LineSession.init(std.testing.allocator, "$ ");
    defer accept.deinit();
    try accept.editor.buffer.replace("tool bl");
    try accept.applyCompletion(.{ .edit = .{ .replace_start = "tool ".len, .replace_end = "tool bl".len, .replacement = "blue,", .suffix = ",", .removable_suffix = true } });
    try accept.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("tool blue", accept.submitted_line.?);

    var typed = try LineSession.init(std.testing.allocator, "$ ");
    defer typed.deinit();
    try typed.editor.buffer.replace("tool bl");
    try typed.applyCompletion(.{ .edit = .{ .replace_start = "tool ".len, .replace_end = "tool bl".len, .replacement = "blue,", .suffix = ",", .removable_suffix = true } });
    try typed.handleKey(.{ .key = .text, .text = "x" });
    try std.testing.expectEqualStrings("tool blue,x", typed.editor.buffer.text());
}

test "completion menu respects render height" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ");
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 3 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "two") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 1-1 of 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2A") != null);
}

test "completion menu caps visible candidates at sixteen rows" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "item00", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item01", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item02", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item03", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item04", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item05", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item06", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item07", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item08", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item09", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item10", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item11", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item12", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item13", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item14", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item15", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item16", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item17", .kind = .plain, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 40 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "item15") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "item16") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 1-16 of 18") != null);
}

test "completion menu visible window follows selection" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ");
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 3 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1m\x1b[38;5;6m  three") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 3-3 of 3") != null);
}

test "completion menu only pins selection to bottom while scrolling down" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "four", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });

    const scrolled_down = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 4 });
    defer std.testing.allocator.free(scrolled_down);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "\x1b[1m\x1b[38;5;6m  three") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "showing 2-3 of 4") != null);

    try session.handleKey(.{ .key = .up });
    const moved_up = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 4 });
    defer std.testing.allocator.free(moved_up);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "\x1b[1m\x1b[38;5;6m  two") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "showing 2-3 of 4") != null);
}

test "completion menu truncates long columns to terminal width" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{.{
        .value = "extraordinarily-long-subcommand-name",
        .description = "this description is intentionally too long for the menu",
        .kind = .subcommand,
        .replace_start = 0,
        .replace_end = 0,
    }};
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .width = 32 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "extraordinarily-long-subcomm…") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "intentionally") == null);
}

test "line session submits an owned copy on enter" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "echo hi" });
    try session.handleKey(.{ .key = .enter });

    try std.testing.expectEqual(LineSession.State.submitted, session.state);
    const line = session.takeSubmittedLine().?;
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("echo hi", line);
}

test "line session keeps input and clears menu on escape" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "d" });

    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expect(!session.hasCompletionMenu());
    try std.testing.expectEqualStrings("abcd", session.editor.buffer.text());
}

test "line session clears input and menu on ctrl-c" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .ctrl_c });

    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expect(!session.hasCompletionMenu());
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
    try std.testing.expect(session.takeSubmittedLine() == null);

    try session.handleKey(.{ .key = .ctrl_c });
    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
}

test "line session treats ctrl-d as eof only on empty buffer" {
    var empty = try LineSession.init(std.testing.allocator, "$ ");
    defer empty.deinit();
    try empty.handleKey(.{ .key = .ctrl_d });
    try std.testing.expectEqual(LineSession.State.eof, empty.state);

    var non_empty = try LineSession.init(std.testing.allocator, "$ ");
    defer non_empty.deinit();
    try non_empty.handleKey(.{ .key = .text, .text = "ab" });
    non_empty.editor.buffer.moveLeft();
    try non_empty.handleKey(.{ .key = .ctrl_d });
    try std.testing.expectEqual(LineSession.State.editing, non_empty.state);
    try std.testing.expectEqualStrings("a", non_empty.editor.buffer.text());
}

test "vi line session switches modes and edits in command mode" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqual(ViState.command, session.vi_state);
    try std.testing.expectEqual(@as(usize, 2), session.editor.buffer.cursor_byte);

    try session.handleKey(.{ .key = .text, .text = "h" });
    try session.handleKey(.{ .key = .text, .text = "x" });
    try std.testing.expectEqualStrings("ac", session.editor.buffer.text());
    try session.handleKey(.{ .key = .text, .text = "u" });
    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "i" });
    try std.testing.expectEqual(ViState.insert, session.vi_state);
    try session.handleKey(.{ .key = .text, .text = "B" });
    try std.testing.expectEqualStrings("aBbc", session.editor.buffer.text());
}

test "vi line session deletes to end and puts killed text" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git status" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "b" });
    try session.handleKey(.{ .key = .text, .text = "D" });
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try session.handleKey(.{ .key = .text, .text = "p" });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
}

test "vi line session repeats insert replace and delete changes with dot" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "ab" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "I" });
    try session.handleKey(.{ .key = .text, .text = "x" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("xxab", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "l" });
    try session.handleKey(.{ .key = .text, .text = "r" });
    try session.handleKey(.{ .key = .text, .text = "Y" });
    try session.handleKey(.{ .key = .text, .text = "l" });
    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("xYYb", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "2" });
    try session.handleKey(.{ .key = .text, .text = "x" });
    try std.testing.expectEqualStrings("Yb", session.editor.buffer.text());
    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
}

test "vi line session repeats counted insert text" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "ab" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "3" });
    try session.handleKey(.{ .key = .text, .text = "i" });
    try session.handleKey(.{ .key = .text, .text = "x" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("xxxab", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("xxxxxxab", session.editor.buffer.text());
}

test "vi line session repeats insert editing controls" {
    var counted = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer counted.deinit();

    try counted.handleKey(.{ .key = .text, .text = "ab" });
    try counted.handleKey(.{ .key = .escape });
    try counted.handleKey(.{ .key = .text, .text = "0" });
    try counted.handleKey(.{ .key = .text, .text = "2" });
    try counted.handleKey(.{ .key = .text, .text = "i" });
    try counted.handleKey(.{ .key = .text, .text = "xy" });
    try counted.handleKey(.{ .key = .backspace });
    try counted.handleKey(.{ .key = .text, .text = "z" });
    try counted.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("xzxzab", counted.editor.buffer.text());

    try counted.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("xzxzxzxzab", counted.editor.buffer.text());

    var edited = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer edited.deinit();

    try edited.handleKey(.{ .key = .text, .text = "end" });
    try edited.handleKey(.{ .key = .escape });
    try edited.handleKey(.{ .key = .text, .text = "0" });
    try edited.handleKey(.{ .key = .text, .text = "i" });
    try edited.handleKey(.{ .key = .text, .text = "one two" });
    try edited.handleKey(.{ .key = .delete_previous_word });
    try edited.handleKey(.{ .key = .text, .text = "three " });
    try edited.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("one three end", edited.editor.buffer.text());

    try edited.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("one three one three end", edited.editor.buffer.text());

    var moved = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer moved.deinit();

    try moved.handleKey(.{ .key = .text, .text = "ab" });
    try moved.handleKey(.{ .key = .escape });
    try moved.handleKey(.{ .key = .text, .text = "0" });
    try moved.handleKey(.{ .key = .text, .text = "i" });
    try moved.handleKey(.{ .key = .text, .text = "xy" });
    try moved.handleKey(.{ .key = .left });
    try moved.handleKey(.{ .key = .text, .text = "Z" });
    try moved.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("xZyab", moved.editor.buffer.text());

    try moved.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("xZxZyyab", moved.editor.buffer.text());
}

test "vi line session repeats replace mode sessions" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "abcdef" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "R" });
    try session.handleKey(.{ .key = .text, .text = "XY" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("XYcdef", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("XYXYef", session.editor.buffer.text());
}

test "vi line session multiplies operator and motion counts" {
    var before_operator = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer before_operator.deinit();
    try before_operator.handleKey(.{ .key = .text, .text = "one two three" });
    try before_operator.handleKey(.{ .key = .escape });
    try before_operator.handleKey(.{ .key = .text, .text = "0" });
    try before_operator.handleKey(.{ .key = .text, .text = "2" });
    try before_operator.handleKey(.{ .key = .text, .text = "c" });
    try before_operator.handleKey(.{ .key = .text, .text = "w" });
    try before_operator.handleKey(.{ .key = .text, .text = "X" });
    try before_operator.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("X three", before_operator.editor.buffer.text());

    var after_operator = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer after_operator.deinit();
    try after_operator.handleKey(.{ .key = .text, .text = "one two three" });
    try after_operator.handleKey(.{ .key = .escape });
    try after_operator.handleKey(.{ .key = .text, .text = "0" });
    try after_operator.handleKey(.{ .key = .text, .text = "c" });
    try after_operator.handleKey(.{ .key = .text, .text = "2" });
    try after_operator.handleKey(.{ .key = .text, .text = "w" });
    try after_operator.handleKey(.{ .key = .text, .text = "X" });
    try after_operator.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("X three", after_operator.editor.buffer.text());

    var multiplied = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer multiplied.deinit();
    try multiplied.handleKey(.{ .key = .text, .text = "one two three four" });
    try multiplied.handleKey(.{ .key = .escape });
    try multiplied.handleKey(.{ .key = .text, .text = "0" });
    try multiplied.handleKey(.{ .key = .text, .text = "2" });
    try multiplied.handleKey(.{ .key = .text, .text = "d" });
    try multiplied.handleKey(.{ .key = .text, .text = "2" });
    try multiplied.handleKey(.{ .key = .text, .text = "w" });
    try std.testing.expectEqualStrings("", multiplied.editor.buffer.text());
}

test "vi line session repeats operator changes and preserves change-word blanks" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "one two three" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "c" });
    try session.handleKey(.{ .key = .text, .text = "w" });
    try session.handleKey(.{ .key = .text, .text = "X" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("X two three", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "w" });
    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("X X three", session.editor.buffer.text());

    var blank = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer blank.deinit();
    try blank.handleKey(.{ .key = .text, .text = "one  two" });
    try blank.handleKey(.{ .key = .escape });
    try blank.handleKey(.{ .key = .text, .text = "0" });
    try blank.handleKey(.{ .key = .text, .text = "l" });
    try blank.handleKey(.{ .key = .text, .text = "l" });
    try blank.handleKey(.{ .key = .text, .text = "l" });
    try blank.handleKey(.{ .key = .text, .text = "c" });
    try blank.handleKey(.{ .key = .text, .text = "w" });
    try blank.handleKey(.{ .key = .text, .text = "X" });
    try blank.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("oneX two", blank.editor.buffer.text());
}

test "vi line session leaves out-of-range operator motions unchanged" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "d" });
    try session.handleKey(.{ .key = .text, .text = "l" });
    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 2), session.editor.buffer.cursor_byte);

    try session.handleKey(.{ .key = .text, .text = "2" });
    try session.handleKey(.{ .key = .text, .text = "$" });
    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 2), session.editor.buffer.cursor_byte);
}

test "vi line session inserts previous history bigwords with underscore" {
    const entries = [_][]const u8{ "echo first", "git commit --amend" };
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries }, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "run" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "_" });
    try std.testing.expectEqual(ViState.insert, session.vi_state);
    try std.testing.expectEqualStrings("run --amend", session.editor.buffer.text());

    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "2" });
    try session.handleKey(.{ .key = .text, .text = "_" });
    try std.testing.expectEqualStrings("r commitun --amend", session.editor.buffer.text());
}

test "vi line session searches history with POSIX patterns and n N" {
    const entries = [_][]const u8{ "echo one", "git status", "echo two", "git commit --amend" };
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries }, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "/" });
    try session.handleKey(.{ .key = .text, .text = "git *" });
    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("git commit --amend", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 0), session.editor.buffer.cursor_byte);

    try session.handleKey(.{ .key = .text, .text = "n" });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "N" });
    try std.testing.expectEqualStrings("git commit --amend", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "/" });
    try session.handleKey(.{ .key = .text, .text = "^echo" });
    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("echo two", session.editor.buffer.text());
}

test "vi line session question mark searches history forward" {
    const entries = [_][]const u8{ "echo one", "git status", "echo two", "git commit --amend" };
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries }, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "G" });
    try std.testing.expectEqualStrings("echo one", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "?" });
    try session.handleKey(.{ .key = .text, .text = "git*" });
    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "n" });
    try std.testing.expectEqualStrings("git commit --amend", session.editor.buffer.text());
}

const TestViAliasSet = struct {
    entries: []const Entry,

    const Entry = struct {
        letter: u21,
        value: []const u8,
    };
};

fn testLookupViAlias(context: *anyopaque, allocator: std.mem.Allocator, letter: u21) !?[]const u8 {
    const aliases: *const TestViAliasSet = @ptrCast(@alignCast(context));
    for (aliases.entries) |entry| {
        if (entry.letter == letter) {
            const copy = try allocator.dupe(u8, entry.value);
            return copy;
        }
    }
    return null;
}

test "vi line session expands command aliases as editing input" {
    const alias_entries = [_]TestViAliasSet.Entry{
        .{ .letter = 'a', .value = "Igit \x1b" },
        .{ .letter = 'd', .value = "0dw" },
    };
    const aliases: TestViAliasSet = .{ .entries = &alias_entries };
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();
    session.vi_aliases = .{ .context = @constCast(&aliases), .lookup = testLookupViAlias };

    try session.handleKey(.{ .key = .text, .text = "status" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "@" });
    try session.handleKey(.{ .key = .text, .text = "a" });
    try std.testing.expectEqual(ViState.command, session.vi_state);
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "@" });
    try session.handleKey(.{ .key = .text, .text = "d" });
    try std.testing.expectEqualStrings("status", session.editor.buffer.text());
}

test "vi line session ignores disabled command aliases" {
    const aliases: TestViAliasSet = .{ .entries = &.{} };
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();
    session.vi_aliases = .{ .context = @constCast(&aliases), .lookup = testLookupViAlias };

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "@" });
    try session.handleKey(.{ .key = .text, .text = "z" });

    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());
    try std.testing.expectEqual(ViState.command, session.vi_state);
}

test "vi line session requests external editor for current and numbered history commands" {
    const entries = [_][]const u8{ "echo one", "echo two" };
    var current = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries }, .vi);
    defer current.deinit();
    try current.handleKey(.{ .key = .text, .text = "echo draft" });
    try current.handleKey(.{ .key = .escape });
    try current.handleKey(.{ .key = .text, .text = "v" });
    try std.testing.expectEqual(LineSession.State.external_editor, current.state);
    const current_request = current.takeExternalEditorRequest() orelse return error.MissingExternalEditorRequest;
    defer current_request.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo draft", current_request.text);
    current.resumeEditingAfterExternalEditor();

    var numbered = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries }, .vi);
    defer numbered.deinit();
    try numbered.handleKey(.{ .key = .escape });
    try numbered.handleKey(.{ .key = .text, .text = "2" });
    try numbered.handleKey(.{ .key = .text, .text = "v" });
    try std.testing.expectEqual(LineSession.State.external_editor, numbered.state);
    const numbered_request = numbered.takeExternalEditorRequest() orelse return error.MissingExternalEditorRequest;
    defer numbered_request.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo two", numbered_request.text);
    try std.testing.expectEqual(@as(?usize, 2), numbered_request.number);
}

test "vi line session requests pathname expansion for current bigword" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "cat rush-path" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "=" });

    const request = session.takePathExpansionRequest() orelse return error.MissingPathExpansionRequest;
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(PathExpansionCommand.list, request.command);
    try std.testing.expectEqualStrings("rush-path", request.word);
    try std.testing.expectEqual(@as(usize, "cat ".len), request.replace_start);
    try std.testing.expectEqual(@as(usize, "cat rush-path".len), request.replace_end);
}

test "vi line session pathname request keeps quoted shell words together" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "cat 'rush path" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "=" });

    const request = session.takePathExpansionRequest() orelse return error.MissingPathExpansionRequest;
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(PathExpansionCommand.list, request.command);
    try std.testing.expectEqualStrings("'rush path", request.word);
    try std.testing.expectEqual(@as(usize, "cat ".len), request.replace_start);
    try std.testing.expectEqual(@as(usize, "cat 'rush path".len), request.replace_end);
    try std.testing.expectEqual(PathExpansionReplacementStyle.single_quoted, request.replacement_style);
}

test "vi pathname completion applies common prefixes and complete matches" {
    var common = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer common.deinit();
    try common.editor.buffer.replace("cat rush-vi-al");
    try std.testing.expect(try common.applyPathExpansion(.{
        .command = .complete,
        .word = "rush-vi-al",
        .replace_start = "cat ".len,
        .replace_end = "cat rush-vi-al".len,
    }, .{ .items = &.{ "rush-vi-alpha", "rush-vi-alpine" } }));
    try std.testing.expectEqualStrings("cat rush-vi-alp", common.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, "cat rush-vi-alp".len), common.editor.buffer.cursor_byte);

    var file = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer file.deinit();
    try file.editor.buffer.replace("cat rush-vi-alpha");
    try std.testing.expect(try file.applyPathExpansion(.{
        .command = .complete,
        .word = "rush-vi-alpha",
        .replace_start = "cat ".len,
        .replace_end = "cat rush-vi-alpha".len,
    }, .{ .items = &.{"rush-vi-alpha"} }));
    try std.testing.expectEqualStrings("cat rush-vi-alpha ", file.editor.buffer.text());

    var dir = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer dir.deinit();
    try dir.editor.buffer.replace("cd rush-vi-dir");
    try std.testing.expect(try dir.applyPathExpansion(.{
        .command = .complete,
        .word = "rush-vi-dir",
        .replace_start = "cd ".len,
        .replace_end = "cd rush-vi-dir".len,
    }, .{ .items = &.{"rush-vi-dir/"} }));
    try std.testing.expectEqualStrings("cd rush-vi-dir/", dir.editor.buffer.text());
}

test "vi pathname completion requotes replacements for quoted shell words" {
    var file = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer file.deinit();
    try file.editor.buffer.replace("cat 'rush vi file");
    try std.testing.expect(try file.applyPathExpansion(.{
        .command = .complete,
        .word = "'rush vi file",
        .replace_start = "cat ".len,
        .replace_end = "cat 'rush vi file".len,
        .replacement_style = .single_quoted,
    }, .{ .items = &.{"rush vi file"} }));
    try std.testing.expectEqualStrings("cat 'rush vi file' ", file.editor.buffer.text());

    var double = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer double.deinit();
    try double.editor.buffer.replace("cat \"rush vi file");
    try std.testing.expect(try double.applyPathExpansion(.{
        .command = .complete,
        .word = "\"rush vi file",
        .replace_start = "cat ".len,
        .replace_end = "cat \"rush vi file".len,
        .replacement_style = .double_quoted,
    }, .{ .items = &.{"rush vi file"} }));
    try std.testing.expectEqualStrings("cat \"rush vi file\" ", double.editor.buffer.text());

    var escaped = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer escaped.deinit();
    try escaped.editor.buffer.replace("cat rush\\ vi");
    try std.testing.expect(try escaped.applyPathExpansion(.{
        .command = .complete,
        .word = "rush\\ vi",
        .replace_start = "cat ".len,
        .replace_end = "cat rush\\ vi".len,
        .replacement_style = .backslash_escaped,
    }, .{ .items = &.{"rush vi file"} }));
    try std.testing.expectEqualStrings("cat rush\\ vi\\ file ", escaped.editor.buffer.text());

    var all = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer all.deinit();
    try all.editor.buffer.replace("printf rush\\ vi*");
    try std.testing.expect(try all.applyPathExpansion(.{
        .command = .expand_all,
        .word = "rush\\ vi*",
        .replace_start = "printf ".len,
        .replace_end = "printf rush\\ vi*".len,
        .replacement_style = .backslash_escaped,
    }, .{ .items = &.{ "rush vi a", "rush vi b" } }));
    try std.testing.expectEqualStrings("printf rush\\ vi\\ a rush\\ vi\\ b", all.editor.buffer.text());

    var dir = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer dir.deinit();
    try dir.editor.buffer.replace("cd \"rush vi dir");
    try std.testing.expect(try dir.applyPathExpansion(.{
        .command = .complete,
        .word = "\"rush vi dir",
        .replace_start = "cd ".len,
        .replace_end = "cd \"rush vi dir".len,
        .replacement_style = .double_quoted,
    }, .{ .items = &.{"rush vi dir/"} }));
    try std.testing.expectEqualStrings("cd \"rush vi dir/\"", dir.editor.buffer.text());
}

test "vi pathname star expands all matches and listing formats matches" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();
    try session.editor.buffer.replace("printf rush-vi-* ");
    try std.testing.expect(try session.applyPathExpansion(.{
        .command = .expand_all,
        .word = "rush-vi-*",
        .replace_start = "printf ".len,
        .replace_end = "printf rush-vi-*".len,
    }, .{ .items = &.{ "rush-vi-a", "rush-vi-b/", "rush-vi-c" } }));
    try std.testing.expectEqualStrings("printf rush-vi-a rush-vi-b/ rush-vi-c ", session.editor.buffer.text());

    const output = try pathExpansionListOutput(std.testing.allocator, .{ .items = &.{ "rush-vi-a", "rush-vi-b/", "rush-vi-c" } });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("rush-vi-a rush-vi-b/ rush-vi-c\n", output);
}

test "vi line session renders beam block and underline cursors" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    const insert = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(insert);
    try std.testing.expect(std.mem.startsWith(u8, insert, "\x1b[6 q"));

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.handleKey(.{ .key = .escape });
    const command = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(command);
    try std.testing.expect(std.mem.startsWith(u8, command, "\x1b[2 q"));

    try session.handleKey(.{ .key = .text, .text = "R" });
    const replace = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(replace);
    try std.testing.expect(std.mem.startsWith(u8, replace, "\x1b[4 q"));
}

test "line session renders with its prompt" {
    var session = try LineSession.init(std.testing.allocator, "rush> ");
    defer session.deinit();
    try session.handleKey(.{ .key = .text, .text = "x" });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2Krush> x\r\x1b[7C", rendered);
}

test "render line styles diagnostic spans without moving cursor" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.buffer.replace("git comit");

    const spans = [_]DiagnosticSpan{.{ .start = 4, .end = 9, .severity = .err }};
    const rendered = try renderLine(std.testing.allocator, editor, .{
        .prompt = .{ .bytes = "$ " },
        .diagnostic_spans = &spans,
        .synchronized_output = false,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2K$ git \x1b[4:3m\x1b[58;5;1mcomit\x1b[24;59m\r\x1b[11C", rendered);
}

test "render line wraps styled diagnostic spans" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.buffer.replace("git commit --amend");

    const spans = [_]DiagnosticSpan{.{ .start = 11, .end = 18, .severity = .warning }};
    const rendered = try renderLine(std.testing.allocator, editor, .{
        .prompt = .{ .bytes = "$ " },
        .diagnostic_spans = &spans,
        .width = 12,
        .synchronized_output = false,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[4:3m\x1b[58;5;1m--amend\x1b[24;59m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "\r\x1b[8C"));
}

test "relative age formats compact units" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("30s", relativeAge(&buffer, 100, 70));
    try std.testing.expectEqualStrings("12m", relativeAge(&buffer, 12 * 60 + 5, 5));
    try std.testing.expectEqualStrings("1h", relativeAge(&buffer, 60 * 60 + 10, 10));
    try std.testing.expectEqualStrings("3d", relativeAge(&buffer, 3 * 24 * 60 * 60 + 9, 9));
    try std.testing.expectEqualStrings("0s", relativeAge(&buffer, 10, 20));
}

test "line session navigates full history from empty buffer" {
    const entries = [_][]const u8{ "echo one", "echo two" };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries });
    defer session.deinit();

    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("echo two", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("echo one", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("echo two", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
}

test "line session searches history by draft prefix" {
    const entries = [_][]const u8{ "echo one", "git status", "echo two", "git diff" };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git diff", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("git diff", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());
}

const TestHistorySearch = struct {
    entries: []const []const u8,
    whens: []const i64 = &.{},

    fn when(self: TestHistorySearch, index: usize) i64 {
        return if (index < self.whens.len) self.whens[index] else 0;
    }
};

fn testSearchHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, query: []const u8, before: ?i64) !?HistoryView.HistoryEntry {
    const history: *TestHistorySearch = @ptrCast(@alignCast(context));
    var index = if (before) |id| @as(usize, @intCast(id)) else history.entries.len;
    while (index > 0) {
        index -= 1;
        const entry = history.entries[index];
        if (completion.fuzzyMatchRank(entry, query) != null) {
            return .{ .id = @intCast(index), .text = try allocator.dupe(u8, entry), .when = history.when(index) };
        }
    }
    return null;
}

fn testSearchNextHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, query: []const u8, after: ?i64) !?HistoryView.HistoryEntry {
    const history: *TestHistorySearch = @ptrCast(@alignCast(context));
    var index = if (after) |id| @as(usize, @intCast(id)) + 1 else 0;
    while (index < history.entries.len) : (index += 1) {
        const entry = history.entries[index];
        if (completion.fuzzyMatchRank(entry, query) != null) {
            return .{ .id = @intCast(index), .text = try allocator.dupe(u8, entry), .when = history.when(index) };
        }
    }
    return null;
}

test "history search seeds query from current buffer and renders menu-style match" {
    const entries = [_][]const u8{ "echo one", "git status", "git diff" };
    const whens = [_]i64{ 10, 60, 90 };
    var history: TestHistorySearch = .{ .entries = &entries, .whens = &whens };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .now = 120, .context = &history, .search = testSearchHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });

    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git", session.history_search_query.items);
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1m\x1b[38;5;6m  ") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "diff") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;3mg\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "30s") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "history") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "history `") == null);
}

test "history search renders clean no-match menu state" {
    const entries = [_][]const u8{ "echo one", "git status" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "missing" });
    try session.handleKey(.{ .key = .ctrl_r });

    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("missing", session.history_search_query.items);
    try std.testing.expectEqualStrings("missing", session.editor.buffer.text());

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "No history matches") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2mmissing") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "history `") == null);
}

test "history search cancel restores original and enter accepts match" {
    const entries = [_][]const u8{ "echo one", "git status", "git diff" };
    var history: TestHistorySearch = .{ .entries = &entries };

    var cancel = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry });
    defer cancel.deinit();
    try cancel.handleKey(.{ .key = .text, .text = "git" });
    try cancel.handleKey(.{ .key = .ctrl_r });
    try cancel.handleKey(.{ .key = .escape });
    try std.testing.expectEqual(LineSession.State.editing, cancel.state);
    try std.testing.expectEqualStrings("git", cancel.editor.buffer.text());

    var accept = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry });
    defer accept.deinit();
    try accept.handleKey(.{ .key = .text, .text = "git" });
    try accept.handleKey(.{ .key = .ctrl_r });
    try accept.handleKey(.{ .key = .enter });
    try std.testing.expectEqual(LineSession.State.editing, accept.state);
    try std.testing.expectEqualStrings("git diff", accept.editor.buffer.text());
}

test "history search edits query while staying open" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try session.handleKey(.{ .key = .text, .text = " s" });

    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git s", session.history_search_query.items);
    try std.testing.expectEqualStrings("git s", session.editor.buffer.text());
    try std.testing.expect(session.history_search_match != null);
    try std.testing.expectEqualStrings("git show", session.history_search_match.?.text);

    try session.handleKey(.{ .key = .text, .text = "t" });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git st", session.history_search_query.items);
    try std.testing.expectEqualStrings("git status", session.history_search_match.?.text);
}

test "history search deletion edits query while staying open" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git st" });
    try session.handleKey(.{ .key = .ctrl_r });
    try session.handleKey(.{ .key = .backspace });

    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git s", session.history_search_query.items);
    try std.testing.expectEqualStrings("git s", session.editor.buffer.text());
    try std.testing.expectEqualStrings("git show", session.history_search_match.?.text);

    session.editor.buffer.moveLeft();
    try session.handleKey(.{ .key = .delete });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git ", session.history_search_query.items);
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
}

test "history search transitions from no match to match as query changes" {
    const entries = [_][]const u8{ "git status", "git diff" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "missing" });
    try session.handleKey(.{ .key = .ctrl_r });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expect(session.history_search_match == null);

    try session.handleKey(.{ .key = .delete_to_start });
    try session.handleKey(.{ .key = .text, .text = "git d" });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git d", session.history_search_query.items);
    try std.testing.expect(session.history_search_match != null);
    try std.testing.expectEqualStrings("git diff", session.history_search_match.?.text);
}

test "history search uses fuzzy query matching" {
    const entries = [_][]const u8{ "git status", "git checkout", "git diff" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry, .search_next = testSearchNextHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "gco" });
    try session.handleKey(.{ .key = .ctrl_r });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("gco", session.history_search_query.items);
    try std.testing.expect(session.history_search_match != null);
    try std.testing.expectEqualStrings("git checkout", session.history_search_match.?.text);
    try std.testing.expectEqual(@as(usize, 1), session.history_search_matches.items.len);

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;3mg\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;3mc\x1b[39m") != null);

    try session.handleKey(.{ .key = .delete_to_start });
    try session.handleKey(.{ .key = .text, .text = "zz" });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expect(session.history_search_match == null);
    try std.testing.expectEqual(@as(usize, 0), session.history_search_matches.items.len);
}

test "history search first tab advances the already-open menu" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry, .search_next = testSearchNextHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try std.testing.expectEqualStrings("git show", session.history_search_match.?.text);
    try std.testing.expectEqual(@as(usize, 3), session.history_search_matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.history_search_selected);

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "show") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "diff") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;3mg\x1b[39m") != null);

    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());
    try std.testing.expectEqualStrings("git diff", session.history_search_match.?.text);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);
    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);

    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("git status", session.history_search_match.?.text);
    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqualStrings("git status", session.history_search_match.?.text);

    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
}

test "history search menu caps visible candidates at sixteen rows" {
    const entries = [_][]const u8{
        "cmd00", "cmd01", "cmd02", "cmd03", "cmd04", "cmd05",
        "cmd06", "cmd07", "cmd08", "cmd09", "cmd10", "cmd11",
        "cmd12", "cmd13", "cmd14", "cmd15", "cmd16", "cmd17",
    };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .ctrl_r });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 40 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cmd17") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cmd02") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cmd01") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 1-16 of 18") != null);
}

test "history search ignores modifier-only text events" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry, .search_next = testSearchNextHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = .text, .text = "", .modifiers = .{ .shift = true } });

    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());
}

test "history search refreshes only when query changes" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry, .search_next = testSearchNextHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = .delete });

    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);
    try std.testing.expectEqualStrings("git", session.history_search_query.items);
}

test "history search shift tab clamps at first match" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry, .search_next = testSearchNextHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try std.testing.expectEqualStrings("git show", session.history_search_match.?.text);

    try session.handleKey(.{ .key = .tab, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git show", session.history_search_match.?.text);

    try session.handleKey(.{ .key = keyFromVaxis('p', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("git show", session.history_search_match.?.text);

    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqualStrings("git diff", session.history_search_match.?.text);
}

test "history search ctrl n and ctrl p clamp like completion" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history, .search = testSearchHistoryEntry, .search_next = testSearchNextHistoryEntry });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try std.testing.expectEqualStrings("git show", session.history_search_match.?.text);

    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git diff", session.history_search_match.?.text);

    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("git status", session.history_search_match.?.text);

    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("git status", session.history_search_match.?.text);

    try session.handleKey(.{ .key = keyFromVaxis('p', .{ .ctrl = true }) });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git diff", session.history_search_match.?.text);
}

test "line session hides older duplicate history commands" {
    const entries = [_][]const u8{ "git status", "echo hi", "git status", "git diff" };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git diff", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
}

test "line session inserts enter literally during paste" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    session.beginPaste();
    try session.handleKey(.{ .key = .text, .text = "echo" });
    try session.handleKey(.{ .key = .enter });
    try session.handleKey(.{ .key = .text, .text = "hi" });
    session.endPaste();

    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("echo\nhi", session.editor.buffer.text());
}

test "line session inserts and renders pasted newlines" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    try session.handlePaste("echo one\r\necho two");

    try std.testing.expectEqualStrings("echo one\necho two", session.editor.buffer.text());
    var frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), frame.input_line_count);
    try std.testing.expectEqualStrings("$ echo one", frame.lines[0]);
    try std.testing.expectEqualStrings("echo two", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 8), frame.cursor_col);
}

test "prompt invalidation preserves edit state and redraws through session" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git status" });
    try session.handleKey(.{ .key = .word_left });
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 10 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 10 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    session.invalidatePrompt();
    try std.testing.expect(session.takePromptInvalidation());
    try session.replacePrompt(.{ .bytes = "\x1b[34mrush> \x1b[0m", .visible_width = 6 });

    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 4), session.editor.buffer.cursor_byte);
    try std.testing.expectEqual(@as(usize, 2), session.completion_menu.candidates.len);

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .semantic_prompt_marks = true });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[34mrush> \x1b[0m" ++ semanticPromptEnd ++ "git status") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "stash") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "\r\x1b[10C"));
}

test "render line redraws prompt and buffer inside synchronized output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abc" });
    editor.buffer.moveLeft();

    const rendered = try renderLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " } });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\x1b[?2026h\r\x1b[2K$ abc\r\x1b[4C\x1b[?2026l", rendered);
}

test "render line can omit synchronized output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "界" });

    const rendered = try renderLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "> " }, .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2K> 界\r\x1b[4C", rendered);
}

test "render line ignores ansi prompt bytes for cursor placement" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "x" });

    const rendered = try renderLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "\x1b[34mrush> \x1b[0m" }, .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2K\x1b[34mrush> \x1b[0mx\r\x1b[7C", rendered);
}

test "frame wraps long input at terminal width" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abcdef" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " }, .width = 5 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("$ abc", frame.lines[0]);
    try std.testing.expectEqualStrings("def", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 3), frame.cursor_col);
}

test "frame wrapping keeps cursor on trailing empty row at exact width" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abc" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " }, .width = 5 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("$ abc", frame.lines[0]);
    try std.testing.expectEqualStrings("", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), frame.cursor_col);
}

test "frame wrapping preserves prompt escape sequences" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abcd" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "\x1b[34m$ \x1b[0m", .visible_width = 2 }, .width = 4 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("\x1b[34m$ \x1b[0mab", frame.lines[0]);
    try std.testing.expectEqualStrings("cd", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor_col);
}

test "frame wrapping computes cursor with wide graphemes" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "ab界" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " }, .width = 5 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("$ ab", frame.lines[0]);
    try std.testing.expectEqualStrings("界", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor_col);
}

test "frame renderer diffs changed input line" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var first_editor = Editor.init(std.testing.allocator);
    defer first_editor.deinit();
    try first_editor.handleKey(.{ .key = .text, .text = "a" });
    var first = try frameFromLine(std.testing.allocator, first_editor, .{ .prompt = .{ .bytes = "$ " }, .synchronized_output = false });
    defer first.deinit(std.testing.allocator);
    const first_output = try renderer.render(std.testing.allocator, first, .{ .synchronized_output = false });
    defer std.testing.allocator.free(first_output);
    try std.testing.expect(std.mem.indexOf(u8, first_output, "\x1b[J") == null);

    var second_editor = Editor.init(std.testing.allocator);
    defer second_editor.deinit();
    try second_editor.handleKey(.{ .key = .text, .text = "ab" });
    var second = try frameFromLine(std.testing.allocator, second_editor, .{ .prompt = .{ .bytes = "$ " }, .synchronized_output = false });
    defer second.deinit(std.testing.allocator);
    const second_output = try renderer.render(std.testing.allocator, second, .{ .synchronized_output = false });
    defer std.testing.allocator.free(second_output);

    try std.testing.expect(std.mem.indexOf(u8, second_output, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\x1b[2K$ ab") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\r\x1b[0C") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\r\x1b[4C") != null);
}

test "frame renderer clears current frame before interrupt output" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    var frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer frame.deinit(std.testing.allocator);
    const rendered = try renderer.render(std.testing.allocator, frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    const prefix = try renderer.interruptOutputPrefix(std.testing.allocator);
    defer std.testing.allocator.free(prefix);
    try std.testing.expectEqual(frame.lines.len, std.mem.count(u8, prefix, "\x1b[2K"));
    try std.testing.expect(std.mem.endsWith(u8, prefix, "\r"));
}

test "frame renderer redraws when frame adds lines" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    var input_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer input_frame.deinit(std.testing.allocator);
    const input_output = try renderer.render(std.testing.allocator, input_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(input_output);

    try session.applyCompletion(.{ .ambiguous = &candidates });
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try std.testing.expect(std.mem.indexOf(u8, menu_output, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, menu_output, "\r\n\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu_output, "checkout") != null);
}

test "frame renderer diffs when frame removes lines" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try session.handleKey(.{ .key = .tab });
    try session.handleKey(.{ .key = .enter });
    var accepted_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer accepted_frame.deinit(std.testing.allocator);
    const accepted_output = try renderer.render(std.testing.allocator, accepted_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(accepted_output);

    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "\x1b[2K$ checkout ") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "\x1b[1B\r\x1b[2K") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, accepted_output, "\x1b[1B\r\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "cherry-pick") == null);
}

test "frame renderer clears menu rows when escape closes completion menu" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ch");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try session.handleKey(.{ .key = .escape });
    try std.testing.expect(!session.hasCompletionMenu());
    var closed_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer closed_frame.deinit(std.testing.allocator);
    const clear_output = try renderer.render(std.testing.allocator, closed_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(clear_output);

    try std.testing.expect(std.mem.indexOf(u8, clear_output, "\x1b[J") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, clear_output, "\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, clear_output, "\x1b[2K$ git ch") == null);
    try std.testing.expect(std.mem.indexOf(u8, clear_output, "checkout") == null);
    try std.testing.expect(std.mem.indexOf(u8, clear_output, "cherry-pick") == null);
}

test "line session cancel discards rendered input and menu state" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ch");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try session.cancel();
    try std.testing.expect(!session.hasCompletionMenu());
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
    try std.testing.expectEqual(LineSession.State.canceled, session.state);
}

test "submitted handoff moves to bottom of wrapped input without clearing it" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.buffer.replace("abcdef");
    editor.buffer.moveHome();

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " }, .width = 5, .synchronized_output = false });
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), frame.input_line_count);
    const rendered = try renderer.render(std.testing.allocator, frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    const handoff = try renderer.submittedHandoff(std.testing.allocator);
    defer std.testing.allocator.free(handoff);

    try std.testing.expectEqualStrings("\x1b[1B\r", handoff);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "\x1b[2K") == null);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "\x1b[J") == null);
}

test "submitted handoff clears completion rows but preserves wrapped input rows" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git checkout");
    session.editor.buffer.moveHome();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 12 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 12 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    var frame = try session.renderFrame(std.testing.allocator, .{ .width = 8, .synchronized_output = false });
    defer frame.deinit(std.testing.allocator);
    try std.testing.expect(frame.input_line_count > 1);
    try std.testing.expect(frame.lines.len > frame.input_line_count);
    const rendered = try renderer.render(std.testing.allocator, frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    const handoff = try renderer.submittedHandoff(std.testing.allocator);
    defer std.testing.allocator.free(handoff);

    try std.testing.expect(std.mem.indexOf(u8, handoff, "\x1b[J") == null);
    try std.testing.expectEqual(frame.lines.len - frame.input_line_count, std.mem.count(u8, handoff, "\x1b[2K"));
    try std.testing.expect(std.mem.endsWith(u8, handoff, "\r"));
}
