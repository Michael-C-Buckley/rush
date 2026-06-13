//! Facade for the redesigned semantic shell core.
//!
//! This module makes the new execution boundary visible without replacing the
//! existing executor. The core owns shell semantics, plans, state deltas, and
//! commit/discard decisions; imperative host effects stay behind `runtime.zig`.

pub const assignment = @import("shell/assignment.zig");
pub const builtin = @import("shell/builtin.zig");
pub const command_plan = @import("shell/command_plan.zig");
pub const consequence = @import("shell/consequence.zig");
pub const context = @import("shell/context.zig");
pub const delta = @import("shell/delta.zig");
pub const eval = @import("shell/eval.zig");
pub const outcome = @import("shell/outcome.zig");
pub const pipeline_plan = @import("shell/pipeline_plan.zig");
pub const redirection_plan = @import("shell/redirection_plan.zig");
pub const state = @import("shell/state.zig");

pub const Builtin = builtin.Builtin;
pub const BuiltinKind = builtin.BuiltinKind;
pub const BuiltinSemanticClass = builtin.BuiltinSemanticClass;
pub const AndOrCommand = command_plan.AndOrCommand;
pub const AndOrOperator = command_plan.AndOrOperator;
pub const AndOrPlan = command_plan.AndOrPlan;
pub const CommandOutcome = outcome.CommandOutcome;
pub const CaseArm = command_plan.CaseArm;
pub const CasePlan = command_plan.CasePlan;
pub const CommandList = command_plan.CommandList;
pub const CommandPlan = command_plan.CommandPlan;
pub const CommandSubstitutionBody = eval.CommandSubstitutionBody;
pub const CommandSubstitutionExpansionContext = eval.CommandSubstitutionExpansionContext;
pub const CommandSubstitutionResolver = eval.CommandSubstitutionResolver;
pub const CommandSubstitutionResult = eval.CommandSubstitutionResult;
pub const CompoundBody = command_plan.CompoundBody;
pub const CompoundCommandPlan = command_plan.CompoundCommandPlan;
pub const ControlFlow = outcome.ControlFlow;
pub const ConsequenceDecision = consequence.Decision;
pub const Diagnostic = outcome.Diagnostic;
pub const EvalContext = context.EvalContext;
pub const ExecutionTarget = context.ExecutionTarget;
pub const ExitStatus = outcome.ExitStatus;
pub const ForPlan = command_plan.ForPlan;
pub const ForWords = command_plan.ForWords;
pub const InputSource = context.InputSource;
pub const IfBranch = command_plan.IfBranch;
pub const IfPlan = command_plan.IfPlan;
pub const LoopPlan = command_plan.LoopPlan;
pub const NegationPlan = command_plan.NegationPlan;
pub const PipelineBackgroundMode = pipeline_plan.PipelineBackgroundMode;
pub const PipelineExecutionStrategy = pipeline_plan.PipelineExecutionStrategy;
pub const PipelineOptions = pipeline_plan.PipelineOptions;
pub const PipelinePlan = pipeline_plan.PipelinePlan;
pub const PipelineStagePlan = pipeline_plan.PipelineStagePlan;
pub const PipelineStatusRule = pipeline_plan.PipelineStatusRule;
pub const RedirectionPlan = redirection_plan.RedirectionPlan;
pub const ReturnRequest = outcome.ReturnRequest;
pub const ReturnScope = outcome.ReturnScope;
pub const ShellErrorConsequence = consequence.ErrorConsequence;
pub const ShellErrorKind = consequence.ShellErrorKind;
pub const ShellState = state.ShellState;
pub const ShellOption = state.ShellOption;
pub const ShellOptions = state.ShellOptions;
pub const StateDelta = delta.StateDelta;
pub const Alias = state.Alias;
pub const Trap = state.Trap;
pub const Variable = state.Variable;
pub const VariableAttributes = state.VariableAttributes;

pub const Assignment = command_plan.Assignment;
pub const AssignmentEffect = command_plan.AssignmentEffect;
pub const AssignmentEffects = assignment.AssignmentEffects;
pub const AssignmentResult = assignment.AssignmentResult;
pub const CommandClass = command_plan.CommandClass;
pub const CommandLookupSnapshot = command_plan.LookupSnapshot;
pub const ExpandedSimpleCommand = command_plan.ExpandedSimpleCommand;
pub const ExternalResolution = command_plan.ExternalResolution;
pub const FunctionDefinition = command_plan.FunctionDefinition;
pub const PlanRequest = command_plan.PlanRequest;
pub const TemporaryEnvironment = assignment.TemporaryEnvironment;
pub const TemporaryVariable = assignment.TemporaryVariable;
