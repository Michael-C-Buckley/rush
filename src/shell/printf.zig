//! POSIX printf utility formatting semantics.
//!
//! This module owns shell-level `printf` parsing, operand conversion, format
//! reuse, escapes, and diagnostics. Evaluation code remains responsible for
//! routing the resulting stdout/stderr bytes to the active execution frame.

const std = @import("std");

pub const ExitStatus = u8;

pub fn evaluate(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: *Writer,
    stderr: *Writer,
) !ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "printf"));

    var format_index: usize = 1;
    if (format_index < argv.len and std.mem.eql(u8, argv[format_index], "--")) format_index += 1;
    if (format_index >= argv.len) {
        var status: ExitStatus = 2;
        try printfDiagnostic(Writer, allocator, stderr, &status, "missing format operand");
        return status;
    }

    var status: ExitStatus = 0;
    var stderr_before_stdout = false;
    try appendPrintfOutput(
        Writer,
        allocator,
        stdout,
        stderr,
        &status,
        &stderr_before_stdout,
        argv[format_index],
        argv[format_index + 1 ..],
    );
    return status;
}

const PrintfSpec = struct {
    spec: u8,
    argument: ?usize = null,
    left_adjust: bool = false,
    zero_pad: bool = false,
    sign_plus: bool = false,
    sign_space: bool = false,
    alternate: bool = false,
    width_from_argument: bool = false,
    width: ?usize = null,
    precision_from_argument: bool = false,
    precision: ?usize = null,
};

const PrintfIntegerBase = enum { decimal, octal, lower_hex, upper_hex };

const PrintfArgumentMode = enum { none, numbered, unnumbered };

fn appendPrintfOutput(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    status: *ExitStatus,
    stderr_before_stdout: *bool,
    format: []const u8,
    args: []const []const u8,
) !void {
    const argument_mode = analyzePrintfFormat(format) catch |err| switch (err) {
        error.MixedArguments => {
            try printfDiagnostic(Writer, allocator, stderr, status, "invalid format");
            return;
        },
    };

    var arg_index: usize = 0;
    var numbered_base: usize = 0;
    var first_pass = true;
    while (first_pass or switch (argument_mode) {
        .numbered => numbered_base < args.len,
        .none, .unnumbered => arg_index < args.len,
    }) {
        first_pass = false;
        const before = if (argument_mode == .numbered) numbered_base else arg_index;
        var pass_max_numbered_argument: usize = 0;
        var index: usize = 0;
        while (index < format.len) {
            switch (format[index]) {
                '\\' => {
                    index += 1;
                    if (index >= format.len) {
                        try stdout.append(allocator, '\\');
                    } else {
                        _ = try appendEscapedSequence(Writer, allocator, stdout, format, &index, .format);
                    }
                },
                '%' => {
                    index += 1;
                    if (index >= format.len) {
                        try printfDiagnostic(Writer, allocator, stderr, status, "invalid format");
                        break;
                    }
                    const spec = parsePrintfSpec(format, &index) orelse {
                        try printfDiagnostic(Writer, allocator, stderr, status, "invalid format");
                        continue;
                    };
                    if (spec.spec == '%') {
                        if (spec.width_from_argument or spec.precision_from_argument) {
                            try printfDiagnostic(Writer, allocator, stderr, status, "invalid format");
                            continue;
                        }
                        try stdout.append(allocator, '%');
                        continue;
                    }
                    const resolved_spec = try resolvePrintfDynamicSpec(
                        Writer,
                        allocator,
                        stderr,
                        status,
                        stderr_before_stdout,
                        spec,
                        args,
                        &arg_index,
                    );
                    const arg = if (spec.argument) |argument_number| blk: {
                        pass_max_numbered_argument = @max(pass_max_numbered_argument, argument_number);
                        const offset = std.math.add(usize, numbered_base, argument_number - 1) catch {
                            try printfDiagnostic(Writer, allocator, stderr, status, "missing argument");
                            return;
                        };
                        if (offset >= args.len) {
                            try printfDiagnostic(Writer, allocator, stderr, status, "missing argument");
                            return;
                        }
                        break :blk args[offset];
                    } else if (arg_index < args.len) blk: {
                        const value = args[arg_index];
                        arg_index += 1;
                        break :blk value;
                    } else "";
                    if (!try appendPrintfConversion(
                        Writer,
                        allocator,
                        stdout,
                        stderr,
                        status,
                        stderr_before_stdout,
                        resolved_spec,
                        arg,
                    )) return;
                },
                else => {
                    try stdout.append(allocator, format[index]);
                    index += 1;
                },
            }
        }
        if (argument_mode == .numbered) {
            if (pass_max_numbered_argument == 0) break;
            numbered_base = std.math.add(usize, numbered_base, pass_max_numbered_argument) catch {
                try printfDiagnostic(Writer, allocator, stderr, status, "missing argument");
                return;
            };
            if (numbered_base == before) break;
        } else if (arg_index == before) break;
    }
}

fn analyzePrintfFormat(format: []const u8) error{MixedArguments}!PrintfArgumentMode {
    var result: PrintfArgumentMode = .none;
    var index: usize = 0;
    while (index < format.len) {
        switch (format[index]) {
            '\\' => {
                index += 1;
                if (index < format.len) skipPrintfFormatEscape(format, &index);
            },
            '%' => {
                index += 1;
                if (index >= format.len) return result;
                const spec = parsePrintfSpec(format, &index) orelse return result;
                if (spec.spec == '%') continue;
                if (spec.width_from_argument or spec.precision_from_argument) {
                    if (result == .numbered) return error.MixedArguments;
                    result = .unnumbered;
                }
                if (spec.argument != null) {
                    if (result == .unnumbered) return error.MixedArguments;
                    result = .numbered;
                } else {
                    if (result == .numbered) return error.MixedArguments;
                    result = .unnumbered;
                }
            },
            else => index += 1,
        }
    }
    return result;
}

fn skipPrintfFormatEscape(format: []const u8, index: *usize) void {
    switch (format[index.*]) {
        'a', 'b', 'f', 'n', 'r', 't', 'v', '\\' => index.* += 1,
        'x' => {
            index.* += 1;
            var count: usize = 0;
            while (index.* < format.len and count < 2) : (count += 1) {
                _ = std.fmt.charToDigit(format[index.*], 16) catch break;
                index.* += 1;
            }
        },
        '0'...'7' => {
            var count: usize = 0;
            while (index.* < format.len and
                count < 3 and
                format[index.*] >= '0' and
                format[index.*] <= '7') : (count += 1)
            {
                index.* += 1;
            }
        },
        else => {},
    }
}

fn printfDiagnostic(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stderr: *Writer,
    status: *ExitStatus,
    message: []const u8,
) !void {
    status.* = if (status.* == 2) 2 else 1;
    try stderr.appendSlice(allocator, "printf: ");
    try stderr.appendSlice(allocator, message);
    try stderr.append(allocator, '\n');
}

fn printfNumericDiagnostic(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stderr: *Writer,
    status: *ExitStatus,
    stderr_before_stdout: *bool,
) !void {
    stderr_before_stdout.* = true;
    try printfDiagnostic(Writer, allocator, stderr, status, "numeric argument required");
}

fn resolvePrintfDynamicSpec(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stderr: *Writer,
    status: *ExitStatus,
    stderr_before_stdout: *bool,
    spec: PrintfSpec,
    args: []const []const u8,
    arg_index: *usize,
) !PrintfSpec {
    var result = spec;
    if (result.width_from_argument) {
        const value = try parsePrintfSigned(
            Writer,
            allocator,
            stderr,
            status,
            stderr_before_stdout,
            nextPrintfArgument(args, arg_index),
        );
        applyPrintfDynamicWidth(&result, value);
    }
    if (result.precision_from_argument) {
        const value = try parsePrintfSigned(
            Writer,
            allocator,
            stderr,
            status,
            stderr_before_stdout,
            nextPrintfArgument(args, arg_index),
        );
        result.precision = if (value < 0) null else printfDynamicMagnitude(value);
    }
    result.width_from_argument = false;
    result.precision_from_argument = false;
    return result;
}

fn nextPrintfArgument(args: []const []const u8, arg_index: *usize) []const u8 {
    if (arg_index.* >= args.len) return "";
    const value = args[arg_index.*];
    arg_index.* += 1;
    return value;
}

fn applyPrintfDynamicWidth(spec: *PrintfSpec, value: i64) void {
    if (value < 0) {
        spec.left_adjust = true;
    }
    spec.width = printfDynamicMagnitude(value);
}

fn printfDynamicMagnitude(value: i64) usize {
    const magnitude: u64 = if (value < 0) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
    return std.math.cast(usize, magnitude) orelse std.math.maxInt(usize);
}

fn parsePrintfSpec(format: []const u8, index: *usize) ?PrintfSpec {
    var result: PrintfSpec = .{ .spec = 0 };
    if (index.* < format.len and std.ascii.isDigit(format[index.*])) {
        const start = index.*;
        while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
        if (index.* < format.len and format[index.*] == '$') {
            const argument_number = std.fmt.parseInt(usize, format[start..index.*], 10) catch return null;
            if (argument_number == 0) return null;
            result.argument = argument_number;
            index.* += 1;
        } else {
            index.* = start;
        }
    }
    while (index.* < format.len) {
        switch (format[index.*]) {
            '-' => result.left_adjust = true,
            '0' => result.zero_pad = true,
            '+' => result.sign_plus = true,
            ' ' => result.sign_space = true,
            '#' => result.alternate = true,
            else => break,
        }
        index.* += 1;
    }
    if (index.* < format.len and format[index.*] == '*') {
        result.width_from_argument = true;
        index.* += 1;
    } else if (index.* < format.len and std.ascii.isDigit(format[index.*])) {
        const start = index.*;
        while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
        result.width = std.fmt.parseInt(usize, format[start..index.*], 10) catch null;
    }
    if (index.* < format.len and format[index.*] == '.') {
        index.* += 1;
        const start = index.*;
        if (index.* < format.len and format[index.*] == '*') {
            result.precision_from_argument = true;
            index.* += 1;
        } else {
            while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
            result.precision = if (start == index.*) 0 else std.fmt.parseInt(usize, format[start..index.*], 10) catch 0;
        }
    }
    if (index.* >= format.len) return null;
    result.spec = format[index.*];
    index.* += 1;
    return result;
}

fn appendPrintfConversion(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    status: *ExitStatus,
    stderr_before_stdout: *bool,
    spec: PrintfSpec,
    arg: []const u8,
) !bool {
    if (isPrintfFloatSpec(spec.spec)) {
        try appendPrintfFloatConversion(Writer, allocator, stdout, stderr, status, spec, arg);
        return true;
    }

    switch (spec.spec) {
        'd', 'i' => {
            const rendered = try formatPrintfSignedInteger(
                allocator,
                spec,
                try parsePrintfSigned(Writer, allocator, stderr, status, stderr_before_stdout, arg),
            );
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'u' => {
            const rendered = try formatPrintfUnsignedInteger(
                allocator,
                spec,
                try parsePrintfUnsigned(Writer, allocator, stderr, status, stderr_before_stdout, arg),
                .decimal,
            );
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'o' => {
            const rendered = try formatPrintfUnsignedInteger(
                allocator,
                spec,
                try parsePrintfUnsigned(Writer, allocator, stderr, status, stderr_before_stdout, arg),
                .octal,
            );
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'x' => {
            const rendered = try formatPrintfUnsignedInteger(
                allocator,
                spec,
                try parsePrintfUnsigned(Writer, allocator, stderr, status, stderr_before_stdout, arg),
                .lower_hex,
            );
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'X' => {
            const rendered = try formatPrintfUnsignedInteger(
                allocator,
                spec,
                try parsePrintfUnsigned(Writer, allocator, stderr, status, stderr_before_stdout, arg),
                .upper_hex,
            );
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        else => {},
    }

    if (spec.spec == 'b') {
        var escaped: std.ArrayList(u8) = .empty;
        errdefer escaped.deinit(allocator);
        const keep_going = try appendPrintfEscapedString(std.ArrayList(u8), allocator, &escaped, arg);
        const bytes = try escaped.toOwnedSlice(allocator);
        defer allocator.free(bytes);
        try appendPadded(Writer, allocator, stdout, truncatePrintfBytes(bytes, spec.precision), spec);
        return keep_going;
    }

    const rendered: []u8 = switch (spec.spec) {
        's' => try formatPrintfString(allocator, arg, spec.precision),
        'c' => try allocator.dupe(u8, if (arg.len == 0) &[_]u8{0} else arg[0..1]),
        else => blk: {
            try printfDiagnostic(Writer, allocator, stderr, status, "invalid conversion");
            break :blk try allocator.alloc(u8, 0);
        },
    };
    defer allocator.free(rendered);
    try appendPadded(Writer, allocator, stdout, rendered, spec);
    return true;
}

fn formatPrintfString(allocator: std.mem.Allocator, arg: []const u8, precision: ?usize) ![]u8 {
    return allocator.dupe(u8, truncatePrintfBytes(arg, precision));
}

fn truncatePrintfBytes(text: []const u8, precision: ?usize) []const u8 {
    const limit = if (precision) |value| @min(value, text.len) else text.len;
    return text[0..limit];
}

fn formatPrintfSignedInteger(allocator: std.mem.Allocator, spec: PrintfSpec, value: i64) ![]u8 {
    const negative = value < 0;
    const magnitude: u64 = if (negative) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
    return formatPrintfInteger(allocator, spec, magnitude, negative, .decimal);
}

fn formatPrintfUnsignedInteger(
    allocator: std.mem.Allocator,
    spec: PrintfSpec,
    value: u64,
    base: PrintfIntegerBase,
) ![]u8 {
    var unsigned_spec = spec;
    unsigned_spec.sign_plus = false;
    unsigned_spec.sign_space = false;
    return formatPrintfInteger(allocator, unsigned_spec, value, false, base);
}

fn formatPrintfInteger(
    allocator: std.mem.Allocator,
    spec: PrintfSpec,
    magnitude: u64,
    negative: bool,
    base: PrintfIntegerBase,
) ![]u8 {
    const raw_digits = try formatPrintfIntegerDigits(allocator, magnitude, base);
    defer allocator.free(raw_digits);

    var digits: []const u8 = raw_digits;
    if (spec.precision == 0 and magnitude == 0) digits = "";

    var precision_zeroes: usize = if (spec.precision) |precision|
        if (precision > digits.len) precision - digits.len else 0
    else
        0;
    if (base == .octal and spec.alternate) {
        if (digits.len + precision_zeroes == 0) {
            precision_zeroes = 1;
        } else if ((digits.len == 0 or digits[0] != '0') and precision_zeroes == 0) {
            precision_zeroes = 1;
        }
    }

    var prefix_buffer: [2]u8 = undefined;
    const prefix: []const u8 = switch (base) {
        .decimal => blk: {
            if (negative) {
                prefix_buffer[0] = '-';
                break :blk prefix_buffer[0..1];
            }
            if (spec.sign_plus) {
                prefix_buffer[0] = '+';
                break :blk prefix_buffer[0..1];
            }
            if (spec.sign_space) {
                prefix_buffer[0] = ' ';
                break :blk prefix_buffer[0..1];
            }
            break :blk "";
        },
        .octal => "",
        .lower_hex => if (spec.alternate and magnitude != 0) "0x" else "",
        .upper_hex => if (spec.alternate and magnitude != 0) "0X" else "",
    };

    const unpadded_len = prefix.len + precision_zeroes + digits.len;
    const width = spec.width orelse 0;
    const width_pad = if (width > unpadded_len) width - unpadded_len else 0;
    const use_zero_width_pad = spec.zero_pad and !spec.left_adjust and spec.precision == null;
    const leading_spaces: usize = if (!spec.left_adjust and !use_zero_width_pad) width_pad else 0;
    const width_zeroes: usize = if (use_zero_width_pad) width_pad else 0;
    const trailing_spaces: usize = if (spec.left_adjust) width_pad else 0;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendNTimes(allocator, ' ', leading_spaces);
    try out.appendSlice(allocator, prefix);
    try out.appendNTimes(allocator, '0', width_zeroes + precision_zeroes);
    try out.appendSlice(allocator, digits);
    try out.appendNTimes(allocator, ' ', trailing_spaces);
    return out.toOwnedSlice(allocator);
}

fn formatPrintfIntegerDigits(allocator: std.mem.Allocator, value: u64, base: PrintfIntegerBase) ![]u8 {
    return switch (base) {
        .decimal => std.fmt.allocPrint(allocator, "{d}", .{value}),
        .octal => std.fmt.allocPrint(allocator, "{o}", .{value}),
        .lower_hex => std.fmt.allocPrint(allocator, "{x}", .{value}),
        .upper_hex => std.fmt.allocPrint(allocator, "{X}", .{value}),
    };
}

fn appendPadded(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stdout: *Writer,
    text: []const u8,
    spec: PrintfSpec,
) !void {
    const width = spec.width orelse 0;
    const pad_len = if (width > text.len) width - text.len else 0;
    const pad_byte: u8 = if (spec.zero_pad and !spec.left_adjust) '0' else ' ';
    if (!spec.left_adjust) try stdout.appendNTimes(allocator, pad_byte, pad_len);
    try stdout.appendSlice(allocator, text);
    if (spec.left_adjust) try stdout.appendNTimes(allocator, ' ', pad_len);
}

fn isPrintfFloatSpec(spec: u8) bool {
    return switch (spec) {
        'a', 'A', 'e', 'E', 'f', 'F', 'g', 'G' => true,
        else => false,
    };
}

fn appendPrintfFloatConversion(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    status: *ExitStatus,
    spec: PrintfSpec,
    arg: []const u8,
) !void {
    const value = try parsePrintfFloat(Writer, allocator, stderr, status, arg);
    const rendered = try formatPrintfFloat(allocator, spec, value);
    defer allocator.free(rendered);
    try appendPrintfFloatPadded(Writer, allocator, stdout, rendered, spec);
}

fn formatPrintfFloat(allocator: std.mem.Allocator, spec: PrintfSpec, value: f64) ![]u8 {
    const lower_spec = std.ascii.toLower(spec.spec);
    var rendered: []u8 = switch (lower_spec) {
        'f' => try formatPrintfFloatDecimal(allocator, value, spec.precision orelse 6, spec.alternate),
        'e' => try formatPrintfFloatScientific(allocator, value, spec.precision orelse 6, spec.alternate),
        'g' => try formatPrintfFloatGeneral(allocator, value, spec.precision orelse 6, spec.alternate),
        'a' => try formatPrintfFloatHex(allocator, value, spec.precision, spec.alternate),
        else => unreachable,
    };
    errdefer allocator.free(rendered);
    try applyPrintfFloatSign(allocator, &rendered, spec);
    if (std.ascii.isUpper(spec.spec)) asciiUpper(rendered);
    return rendered;
}

fn formatPrintfFloatDecimal(allocator: std.mem.Allocator, value: f64, precision: usize, alternate: bool) ![]u8 {
    const buffer = try allocator.alloc(u8, @max(std.fmt.float.bufferSize(.decimal, f64), precision + 32));
    defer allocator.free(buffer);
    const decimal = roundPrintfFloat(printfFloatDecimal(value), .decimal, precision);
    const rendered = std.fmt.float.formatDecimal(u64, buffer, decimal, precision) catch |err| switch (err) {
        error.BufferTooSmall => return error.OutOfMemory,
    };
    return floatDuplicateWithAlternateDecimalPoint(allocator, rendered, alternate);
}

fn formatPrintfFloatScientific(allocator: std.mem.Allocator, value: f64, precision: usize, alternate: bool) ![]u8 {
    const rendered = try renderPrintfFloatScientific(allocator, value, precision);
    defer allocator.free(rendered);
    return normalizePrintfScientific(allocator, rendered, alternate);
}

fn renderPrintfFloatScientific(allocator: std.mem.Allocator, value: f64, precision: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, @max(std.fmt.float.bufferSize(.scientific, f64), precision + 32));
    defer allocator.free(buffer);
    const decimal = roundPrintfFloat(printfFloatDecimal(value), .scientific, precision);
    const rendered = std.fmt.float.formatScientific(u64, buffer, decimal, precision) catch |err| switch (err) {
        error.BufferTooSmall => return error.OutOfMemory,
    };
    return allocator.dupe(u8, rendered);
}

fn formatPrintfFloatGeneral(allocator: std.mem.Allocator, value: f64, precision_arg: usize, alternate: bool) ![]u8 {
    const precision = if (precision_arg == 0) 1 else precision_arg;
    const scientific = try renderPrintfFloatScientific(allocator, value, precision - 1);
    defer allocator.free(scientific);
    if (isPrintfFloatSpecial(scientific)) return floatDuplicateWithAlternateDecimalPoint(allocator, scientific, false);

    const exponent = scientificExponent(scientific) orelse 0;
    const use_scientific = exponent < -4 or exponent >= @as(i32, @intCast(precision));
    const rendered = if (use_scientific)
        try normalizePrintfScientific(allocator, scientific, alternate)
    else blk: {
        const decimal_precision: usize = if (exponent >= 0)
            if (precision > @as(usize, @intCast(exponent + 1))) precision - @as(usize, @intCast(exponent + 1)) else 0
        else
            precision + @as(usize, @intCast(-exponent - 1));
        break :blk try formatPrintfFloatDecimal(allocator, value, decimal_precision, alternate);
    };
    errdefer allocator.free(rendered);
    if (!alternate) {
        if (try trimPrintfGeneralZeros(allocator, rendered)) |trimmed| {
            allocator.free(rendered);
            return trimmed;
        }
    }
    return rendered;
}

const PrintfFloatRoundMode = enum { decimal, scientific };

fn printfFloatDecimal(value: f64) std.fmt.float.FloatDecimal(u64) {
    return std.fmt.float.binaryToDecimal(
        u64,
        @as(u64, @bitCast(value)),
        std.math.floatMantissaBits(f64),
        std.math.floatExponentBits(f64),
        false,
        &std.fmt.float.Backend64_TablesFull,
    );
}

fn roundPrintfFloat(
    decimal: std.fmt.float.FloatDecimal(u64),
    mode: PrintfFloatRoundMode,
    precision: usize,
) std.fmt.float.FloatDecimal(u64) {
    if (decimal.exponent == 0x7fffffff) return decimal;

    var round_digit: usize = 0;
    var output = decimal.mantissa;
    var exponent = decimal.exponent;
    const output_length = printfDecimalLength(output);

    switch (mode) {
        .decimal => {
            if (decimal.exponent > 0) {
                round_digit = output_length - 1 + precision + @as(usize, @intCast(decimal.exponent));
            } else {
                const min_exp_required: usize = @intCast(-decimal.exponent);
                if (precision + output_length > min_exp_required) {
                    round_digit = precision + output_length - min_exp_required;
                }
            }
        },
        .scientific => {
            round_digit = 1 + precision;
        },
    }

    if (round_digit < output_length) {
        var sticky = false;
        for (round_digit + 1..output_length) |_| {
            sticky = sticky or output % 10 != 0;
            output /= 10;
            exponent += 1;
        }

        const guard = output % 10;
        output /= 10;
        exponent += 1;
        if (guard > 5 or (guard == 5 and (sticky or output % 2 == 1))) {
            output += 1;

            if (printfIsPowerOf10(output)) {
                output /= 10;
                exponent += 1;
            }
        }
    }

    return .{
        .mantissa = output,
        .exponent = exponent,
        .sign = decimal.sign,
    };
}

fn printfIsPowerOf10(value: u64) bool {
    var n = value;
    while (n != 0) : (n /= 10) {
        if (n % 10 != 0) return false;
    }
    return true;
}

fn printfDecimalLength(value: u64) usize {
    if (value >= 10000000000000000) return 17;
    if (value >= 1000000000000000) return 16;
    if (value >= 100000000000000) return 15;
    if (value >= 10000000000000) return 14;
    if (value >= 1000000000000) return 13;
    if (value >= 100000000000) return 12;
    if (value >= 10000000000) return 11;
    if (value >= 1000000000) return 10;
    if (value >= 100000000) return 9;
    if (value >= 10000000) return 8;
    if (value >= 1000000) return 7;
    if (value >= 100000) return 6;
    if (value >= 10000) return 5;
    if (value >= 1000) return 4;
    if (value >= 100) return 3;
    if (value >= 10) return 2;
    return 1;
}

fn normalizePrintfScientific(allocator: std.mem.Allocator, rendered: []const u8, alternate: bool) ![]u8 {
    if (isPrintfFloatSpecial(rendered)) return allocator.dupe(u8, rendered);
    const e_index = std.mem.indexOfScalar(u8, rendered, 'e') orelse return allocator.dupe(u8, rendered);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, rendered[0..e_index]);
    if (alternate and std.mem.indexOfScalar(u8, rendered[0..e_index], '.') == null) try output.append(allocator, '.');
    try output.append(allocator, 'e');

    var exponent = std.fmt.parseInt(i32, rendered[e_index + 1 ..], 10) catch unreachable;
    if (exponent < 0) {
        try output.append(allocator, '-');
        exponent = -exponent;
    } else {
        try output.append(allocator, '+');
    }
    if (exponent < 10) try output.append(allocator, '0');
    const exponent_text = try std.fmt.allocPrint(allocator, "{d}", .{exponent});
    defer allocator.free(exponent_text);
    try output.appendSlice(allocator, exponent_text);
    return output.toOwnedSlice(allocator);
}

fn floatDuplicateWithAlternateDecimalPoint(allocator: std.mem.Allocator, rendered: []const u8, alternate: bool) ![]u8 {
    if (!alternate or isPrintfFloatSpecial(rendered) or std.mem.indexOfScalar(u8, rendered, '.') != null) {
        return allocator.dupe(u8, rendered);
    }
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, rendered);
    try output.append(allocator, '.');
    return output.toOwnedSlice(allocator);
}

fn scientificExponent(rendered: []const u8) ?i32 {
    const e_index = std.mem.indexOfScalar(u8, rendered, 'e') orelse return null;
    return std.fmt.parseInt(i32, rendered[e_index + 1 ..], 10) catch null;
}

fn trimPrintfGeneralZeros(allocator: std.mem.Allocator, rendered: []const u8) !?[]u8 {
    if (isPrintfFloatSpecial(rendered)) return null;
    const e_index = std.mem.indexOfScalar(u8, rendered, 'e') orelse rendered.len;
    const dot_index = std.mem.indexOfScalar(u8, rendered[0..e_index], '.') orelse return null;
    var end = e_index;
    while (end > dot_index + 1 and rendered[end - 1] == '0') end -= 1;
    if (end > dot_index and rendered[end - 1] == '.') end -= 1;
    if (end == e_index) return null;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, rendered[0..end]);
    try output.appendSlice(allocator, rendered[e_index..]);
    return try output.toOwnedSlice(allocator);
}

fn formatPrintfFloatHex(allocator: std.mem.Allocator, value: f64, precision: ?usize, alternate: bool) ![]u8 {
    if (std.math.isNan(value) or std.math.isInf(value)) {
        var buffer: [8]u8 = undefined;
        const rendered = std.fmt.float.render(&buffer, value, .{}) catch unreachable;
        return allocator.dupe(u8, rendered);
    }

    const negative = std.math.signbit(value);
    const magnitude = @abs(value);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (negative) try output.append(allocator, '-');
    try output.appendSlice(allocator, "0x");

    if (magnitude == 0) {
        try output.append(allocator, '0');
        const digits = precision orelse 0;
        if (alternate or digits != 0) {
            try output.append(allocator, '.');
            try output.appendNTimes(allocator, '0', digits);
        }
        try output.appendSlice(allocator, "p+0");
        return output.toOwnedSlice(allocator);
    }

    const parts = std.math.frexp(magnitude);
    var exponent = parts.exponent - 1;
    var scaled = parts.significand * 2.0;
    var leading: u8 = @intFromFloat(@floor(scaled));
    scaled -= @floatFromInt(leading);

    const requested_digits = precision orelse 13;
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(allocator);
    const generated_digits = if (precision == null) 13 else requested_digits + 1;
    for (0..generated_digits) |_| {
        scaled *= 16.0;
        const digit: u8 = @intFromFloat(@floor(scaled));
        try digits.append(allocator, digit);
        scaled -= @floatFromInt(digit);
    }

    if (precision) |_| {
        if (digits.items.len > requested_digits) {
            const guard_digit = digits.items[requested_digits];
            const sticky = scaled != 0;
            const last_digit_is_odd = if (requested_digits == 0)
                leading % 2 == 1
            else
                digits.items[requested_digits - 1] % 2 == 1;
            const round_up = guard_digit > 8 or (guard_digit == 8 and (sticky or last_digit_is_odd));
            if (round_up) {
                var carry_index = requested_digits;
                while (carry_index > 0) {
                    carry_index -= 1;
                    if (digits.items[carry_index] != 15) {
                        digits.items[carry_index] += 1;
                        break;
                    }
                    digits.items[carry_index] = 0;
                } else {
                    if (leading < 15) {
                        leading += 1;
                    }
                }
            }
        }
        digits.shrinkRetainingCapacity(requested_digits);
    } else {
        while (digits.items.len != 0 and digits.items[digits.items.len - 1] == 0) _ = digits.pop();
    }

    try output.append(allocator, '0' + leading);
    if (alternate or digits.items.len != 0) {
        try output.append(allocator, '.');
        for (digits.items) |digit| try output.append(allocator, lowerHexDigit(digit));
    }
    try output.append(allocator, 'p');
    if (exponent < 0) {
        try output.append(allocator, '-');
        exponent = -exponent;
    } else {
        try output.append(allocator, '+');
    }
    const exponent_text = try std.fmt.allocPrint(allocator, "{d}", .{exponent});
    defer allocator.free(exponent_text);
    try output.appendSlice(allocator, exponent_text);
    return output.toOwnedSlice(allocator);
}

fn applyPrintfFloatSign(allocator: std.mem.Allocator, rendered: *[]u8, spec: PrintfSpec) !void {
    if (rendered.*.len == 0 or rendered.*[0] == '-') return;
    const prefix: u8 = if (spec.sign_plus) '+' else if (spec.sign_space) ' ' else return;
    const next = try allocator.alloc(u8, rendered.*.len + 1);
    next[0] = prefix;
    @memcpy(next[1..], rendered.*);
    allocator.free(rendered.*);
    rendered.* = next;
}

fn appendPrintfFloatPadded(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stdout: *Writer,
    rendered: []const u8,
    spec: PrintfSpec,
) !void {
    const width = spec.width orelse 0;
    const pad_len = if (width > rendered.len) width - rendered.len else 0;
    const use_zero_pad = spec.zero_pad and !spec.left_adjust and !isPrintfFloatSpecial(rendered);
    if (!spec.left_adjust and !use_zero_pad) try stdout.appendNTimes(allocator, ' ', pad_len);
    if (use_zero_pad) {
        const split = printfFloatZeroPadSplit(rendered);
        try stdout.appendSlice(allocator, rendered[0..split]);
        try stdout.appendNTimes(allocator, '0', pad_len);
        try stdout.appendSlice(allocator, rendered[split..]);
    } else {
        try stdout.appendSlice(allocator, rendered);
    }
    if (spec.left_adjust) try stdout.appendNTimes(allocator, ' ', pad_len);
}

fn printfFloatZeroPadSplit(rendered: []const u8) usize {
    var split: usize = if (rendered.len != 0 and
        (rendered[0] == '-' or rendered[0] == '+' or rendered[0] == ' ')) 1 else 0;
    if (rendered.len >= split + 2 and
        rendered[split] == '0' and
        (rendered[split + 1] == 'x' or rendered[split + 1] == 'X'))
    {
        split += 2;
    }
    return split;
}

fn isPrintfFloatSpecial(rendered: []const u8) bool {
    const text = if (rendered.len != 0 and (rendered[0] == '-' or rendered[0] == '+' or rendered[0] == ' '))
        rendered[1..]
    else
        rendered;
    return std.ascii.eqlIgnoreCase(text, "inf") or std.ascii.eqlIgnoreCase(text, "nan");
}

fn asciiUpper(text: []u8) void {
    for (text) |*byte| byte.* = std.ascii.toUpper(byte.*);
}

fn lowerHexDigit(value: u8) u8 {
    std.debug.assert(value < 16);
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

const PrintfIntegerConstant = struct {
    magnitude: u64,
    negative: bool = false,
    complete: bool = true,
    overflow: bool = false,
};

const PrintfMagnitude = struct {
    value: u64,
    overflow: bool = false,
};

const PrintfSignedValue = struct {
    value: i64,
    overflow: bool = false,
};

const PrintfUnsignedValue = struct {
    value: u64,
    overflow: bool = false,
};

fn parsePrintfSigned(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stderr: *Writer,
    status: *ExitStatus,
    stderr_before_stdout: *bool,
    arg: []const u8,
) !i64 {
    const parsed = parsePrintfIntegerConstant(arg) catch |err| switch (err) {
        error.InvalidCharacter => {
            try printfNumericDiagnostic(Writer, allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
        error.Overflow => {
            try printfNumericDiagnostic(Writer, allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
    };
    const converted = printfSignedValue(parsed);
    if (!parsed.complete or converted.overflow) try printfNumericDiagnostic(
        Writer,
        allocator,
        stderr,
        status,
        stderr_before_stdout,
    );
    return converted.value;
}

fn parsePrintfUnsigned(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stderr: *Writer,
    status: *ExitStatus,
    stderr_before_stdout: *bool,
    arg: []const u8,
) !u64 {
    const parsed = parsePrintfIntegerConstant(arg) catch |err| switch (err) {
        error.InvalidCharacter => {
            try printfNumericDiagnostic(Writer, allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
        error.Overflow => {
            try printfNumericDiagnostic(Writer, allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
    };
    const converted = printfUnsignedValue(parsed);
    if (!parsed.complete or converted.overflow) try printfNumericDiagnostic(
        Writer,
        allocator,
        stderr,
        status,
        stderr_before_stdout,
    );
    return converted.value;
}

fn printfSignedValue(parsed: PrintfIntegerConstant) PrintfSignedValue {
    if (!parsed.negative) {
        if (parsed.magnitude > std.math.maxInt(i64)) return .{ .value = std.math.maxInt(i64), .overflow = true };
        return .{ .value = @intCast(parsed.magnitude), .overflow = parsed.overflow };
    }
    const max_plus_one = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    if (parsed.magnitude == max_plus_one) return .{ .value = std.math.minInt(i64), .overflow = parsed.overflow };
    if (parsed.magnitude > max_plus_one) return .{ .value = std.math.minInt(i64), .overflow = true };
    return .{ .value = -@as(i64, @intCast(parsed.magnitude)), .overflow = parsed.overflow };
}

fn printfUnsignedValue(parsed: PrintfIntegerConstant) PrintfUnsignedValue {
    if (!parsed.negative) return .{ .value = parsed.magnitude, .overflow = parsed.overflow };
    if (parsed.overflow) return .{ .value = std.math.maxInt(u64), .overflow = true };
    return .{ .value = (~parsed.magnitude) +% 1 };
}

fn parsePrintfMagnitude(text: []const u8, base: u8) !PrintfMagnitude {
    const value = std.fmt.parseInt(u64, text, base) catch |err| switch (err) {
        error.Overflow => return .{ .value = std.math.maxInt(u64), .overflow = true },
        else => return err,
    };
    return .{ .value = value };
}

fn skipPrintfIntegerWhitespace(arg: []const u8, cursor: *usize) void {
    while (cursor.* < arg.len and std.ascii.isWhitespace(arg[cursor.*])) : (cursor.* += 1) {}
}

fn printfIntegerParseComplete(arg: []const u8, cursor: usize) bool {
    var trailing = cursor;
    skipPrintfIntegerWhitespace(arg, &trailing);
    return trailing == arg.len;
}

fn parsePrintfIntegerConstant(arg: []const u8) !PrintfIntegerConstant {
    if (arg.len == 0) return .{ .magnitude = 0 };
    if (arg[0] == '\'' or arg[0] == '"') return .{
        .magnitude = if (arg.len > 1) arg[1] else 0,
        .complete = arg.len <= 2,
    };

    var cursor: usize = 0;
    skipPrintfIntegerWhitespace(arg, &cursor);
    if (cursor >= arg.len) return error.InvalidCharacter;

    var negative = false;
    if (arg[cursor] == '+' or arg[cursor] == '-') {
        negative = arg[cursor] == '-';
        cursor += 1;
    }
    if (cursor >= arg.len or !std.ascii.isDigit(arg[cursor])) return error.InvalidCharacter;

    const digits_start: usize = cursor;
    var base: u8 = 10;
    if (arg[cursor] == '0') {
        base = 8;
        cursor += 1;
        if (cursor < arg.len and (arg[cursor] == 'x' or arg[cursor] == 'X')) {
            base = 16;
            cursor += 1;
            const hex_start = cursor;
            while (cursor < arg.len and std.ascii.isHex(arg[cursor])) : (cursor += 1) {}
            if (cursor == hex_start) return .{ .magnitude = 0, .negative = negative, .complete = false };
            const magnitude = try parsePrintfMagnitude(arg[hex_start..cursor], base);
            return .{
                .magnitude = magnitude.value,
                .negative = negative,
                .complete = printfIntegerParseComplete(arg, cursor),
                .overflow = magnitude.overflow,
            };
        }
        while (cursor < arg.len and arg[cursor] >= '0' and arg[cursor] <= '7') : (cursor += 1) {}
    } else {
        while (cursor < arg.len and std.ascii.isDigit(arg[cursor])) : (cursor += 1) {}
    }
    const magnitude = try parsePrintfMagnitude(arg[digits_start..cursor], base);
    return .{
        .magnitude = magnitude.value,
        .negative = negative,
        .complete = printfIntegerParseComplete(arg, cursor),
        .overflow = magnitude.overflow,
    };
}

fn parsePrintfFloat(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stderr: *Writer,
    status: *ExitStatus,
    arg: []const u8,
) !f64 {
    const trimmed = trimPrintfFloatWhitespace(arg);
    if (trimmed.len == 0) return 0;
    if (std.fmt.parseFloat(f64, trimmed)) |value| return value else |_| {}
    var end = trimmed.len;
    while (end > 0) : (end -= 1) {
        if (std.fmt.parseFloat(f64, trimmed[0..end])) |value| {
            try printfDiagnostic(Writer, allocator, stderr, status, "numeric argument required");
            return value;
        } else |_| {}
    }
    try printfDiagnostic(Writer, allocator, stderr, status, "numeric argument required");
    return 0;
}

fn trimPrintfFloatWhitespace(arg: []const u8) []const u8 {
    var start: usize = 0;
    while (start < arg.len and std.ascii.isWhitespace(arg[start])) : (start += 1) {}
    var end = arg.len;
    while (end > start and std.ascii.isWhitespace(arg[end - 1])) : (end -= 1) {}
    return arg[start..end];
}

fn appendPrintfEscapedString(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stdout: *Writer,
    text: []const u8,
) !bool {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try stdout.append(allocator, text[index]);
            index += 1;
            continue;
        }
        index += 1;
        if (index >= text.len) {
            try stdout.append(allocator, '\\');
        } else if (!try appendEscapedSequence(Writer, allocator, stdout, text, &index, .percent_b)) {
            return false;
        }
    }
    return true;
}

const PrintfEscapeMode = enum { format, percent_b };

fn appendEscapedSequence(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stdout: *Writer,
    text: []const u8,
    index: *usize,
    mode: PrintfEscapeMode,
) !bool {
    const byte = text[index.*];
    switch (byte) {
        'a' => try stdout.append(allocator, 0x07),
        'b' => try stdout.append(allocator, 0x08),
        'c' => {
            if (mode == .format) {
                try stdout.append(allocator, '\\');
                return true;
            }
            index.* += 1;
            return false;
        },
        'f' => try stdout.append(allocator, 0x0c),
        'n' => try stdout.append(allocator, '\n'),
        'r' => try stdout.append(allocator, '\r'),
        't' => try stdout.append(allocator, '\t'),
        'v' => try stdout.append(allocator, 0x0b),
        '\\' => try stdout.append(allocator, '\\'),
        'x' => {
            if (mode == .format) {
                try stdout.append(allocator, '\\');
                return true;
            }
            try appendHexEscape(Writer, allocator, stdout, text, index);
            return true;
        },
        '0'...'7' => {
            try appendOctalEscape(Writer, allocator, stdout, text, index, mode);
            return true;
        },
        else => {
            try stdout.append(allocator, '\\');
            if (mode == .format) return true;
            try stdout.append(allocator, byte);
        },
    }
    index.* += 1;
    return true;
}

fn appendHexEscape(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stdout: *Writer,
    text: []const u8,
    index: *usize,
) !void {
    var value: u8 = 0;
    var count: usize = 0;
    var cursor = index.* + 1;
    while (cursor < text.len and count < 2) : (count += 1) {
        const digit = std.fmt.charToDigit(text[cursor], 16) catch break;
        value = value * 16 + digit;
        cursor += 1;
    }
    if (count == 0) {
        try stdout.append(allocator, '\\');
        try stdout.append(allocator, 'x');
        index.* += 1;
    } else {
        try stdout.append(allocator, value);
        index.* = cursor;
    }
}

fn appendOctalEscape(
    comptime Writer: type,
    allocator: std.mem.Allocator,
    stdout: *Writer,
    text: []const u8,
    index: *usize,
    mode: PrintfEscapeMode,
) !void {
    var value: u16 = 0;
    var count: usize = 0;
    var cursor = index.*;
    if (mode == .percent_b and cursor < text.len and text[cursor] == '0') cursor += 1;
    while (cursor < text.len and count < 3 and text[cursor] >= '0' and text[cursor] <= '7') : (count += 1) {
        value = value * 8 + (text[cursor] - '0');
        cursor += 1;
    }
    if (count == 0) {
        try stdout.append(allocator, 0);
        index.* += 1;
    } else {
        try stdout.append(allocator, @intCast(value & 0xff));
        index.* = cursor;
    }
}

test "printf evaluates POSIX format reuse and escapes" {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);

    const status = try evaluate(
        std.ArrayList(u8),
        std.testing.allocator,
        &.{ "printf", "[%5s][%-5s][%.3s][%04d]\\n", "a", "b", "abcdef", "7", "c", "d", "xyz", "8" },
        &stdout,
        &stderr,
    );

    try std.testing.expectEqual(@as(ExitStatus, 0), status);
    try std.testing.expectEqualStrings("[    a][b    ][abc][0007]\n[    c][d    ][xyz][0008]\n", stdout.items);
    try std.testing.expectEqualStrings("", stderr.items);
}

test "printf reports numeric conversion diagnostics" {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);

    const status = try evaluate(
        std.ArrayList(u8),
        std.testing.allocator,
        &.{ "printf", "%d:%x\n", "5x ", " 0x1fg " },
        &stdout,
        &stderr,
    );

    try std.testing.expectEqual(@as(ExitStatus, 1), status);
    try std.testing.expectEqualStrings("5:1f\n", stdout.items);
    try std.testing.expectEqualStrings(
        "printf: numeric argument required\nprintf: numeric argument required\n",
        stderr.items,
    );
}

test "printf reports trailing bytes after quoted integer constants" {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);

    const status = try evaluate(
        std.ArrayList(u8),
        std.testing.allocator,
        &.{ "printf", "%d\n", "'3", "\"+3", "'-3" },
        &stdout,
        &stderr,
    );

    try std.testing.expectEqual(@as(ExitStatus, 1), status);
    try std.testing.expectEqualStrings("51\n43\n45\n", stdout.items);
    try std.testing.expectEqualStrings(
        "printf: numeric argument required\nprintf: numeric argument required\n",
        stderr.items,
    );
}

test "printf format operand does not recognize hexadecimal escapes" {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);

    const status = try evaluate(
        std.ArrayList(u8),
        std.testing.allocator,
        &.{ "printf", "A\\x41Z\\n" },
        &stdout,
        &stderr,
    );

    try std.testing.expectEqual(@as(ExitStatus, 0), status);
    try std.testing.expectEqualStrings("A\\x41Z\n", stdout.items);
    try std.testing.expectEqualStrings("", stderr.items);
}

test "printf octal escapes wrap to one byte" {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);

    const status = try evaluate(
        std.ArrayList(u8),
        std.testing.allocator,
        &.{ "printf", "A\\400B:%b", "C\\0777D" },
        &stdout,
        &stderr,
    );

    try std.testing.expectEqual(@as(ExitStatus, 0), status);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0, 'B', ':', 'C', 255, 'D' }, stdout.items);
    try std.testing.expectEqualStrings("", stderr.items);
}

test "printf formats floating point conversions without C snprintf" {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);

    const status = try evaluate(
        std.ArrayList(u8),
        std.testing.allocator,
        &.{
            "printf",
            "<%f><%.2f><%e><%E><%g><%G><%a><%A>\n",
            "1.5",
            "1.5",
            "1000",
            "1000",
            "1000",
            "1000",
            "1.5",
            "1.5",
        },
        &stdout,
        &stderr,
    );

    try std.testing.expectEqual(@as(ExitStatus, 0), status);
    try std.testing.expectEqualStrings(
        "<1.500000><1.50><1.000000e+03><1.000000E+03><1000><1000><0x1.8p+0><0X1.8P+0>\n",
        stdout.items,
    );
    try std.testing.expectEqualStrings("", stderr.items);
}

test "printf floating point formatting applies flags width precision and partial numeric diagnostics" {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);

    const status = try evaluate(
        std.ArrayList(u8),
        std.testing.allocator,
        &.{
            "printf",
            "<%+ f><%+010.2f><% 10.2e><%-10.3g><%#.0f><%#.3g><%.0f><%.1f><%.0g><%.0a><%010.2a><%.1a><%.2f><%.2f>\n",
            "1.5",
            "1.5",
            "1.5",
            "1000",
            "1",
            "1000",
            "2.5",
            "1.25",
            "2.5",
            "1.5",
            "1.5",
            "0x1.08p0",
            " 1.5 ",
            "0x10.1p2x",
        },
        &stdout,
        &stderr,
    );

    try std.testing.expectEqual(@as(ExitStatus, 1), status);
    const expected_stdout = "<+1.500000><+000001.50><  1.50e+00><1e+03     ><1.><1.00e+03>" ++
        "<2><1.2><2><0x2p+0><0x01.80p+0><0x1.0p+0><1.50><64.25>\n";
    try std.testing.expectEqualStrings(
        expected_stdout,
        stdout.items,
    );
    try std.testing.expectEqualStrings("printf: numeric argument required\n", stderr.items);
}
