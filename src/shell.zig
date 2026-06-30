//! Public facade for the rewritten shell core.

pub const ast = @import("shell/ast.zig");
pub const host = @import("shell/host.zig");
pub const result = @import("shell/result.zig");
pub const source = @import("shell/source.zig");
pub const state = @import("shell/state.zig");
pub const token = @import("shell/token.zig");

pub const Shell = @import("shell/Shell.zig").Shell;

pub const ExitStatus = result.ExitStatus;
pub const EvalResult = result.EvalResult;
pub const ShellState = state.State;
pub const SourceSpan = source.Span;
pub const Token = token.Token;
