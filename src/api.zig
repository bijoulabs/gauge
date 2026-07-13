//! Usage API client: fetches and parses Anthropic's OAuth usage-limit endpoint
//! into a `Snapshot`. Parsing is defensive: a renamed or reshaped field
//! degrades to `error.UnrecognizedShape` (stale cached data survives) rather
//! than a crash, since this module talks to a server gauge does not control.

const std = @import("std");
const policy = @import("policy.zig");
const testing = std.testing;

/// The Anthropic OAuth usage endpoint. Fetched once per refresh cycle by
/// `fetchUsage`; see `policy.decide` for the cache/refresh gate that guards
/// how often that happens.
pub const usage_url = "https://api.anthropic.com/api/oauth/usage";

/// Default `User-Agent` sent with the usage request, overridable via
/// `GAUGE_USER_AGENT` in `main`. Mirrors the live `claude` CLI's own user
/// agent since the endpoint is undocumented and may key behavior off it.
pub const default_user_agent = "claude-code/2.1.207";

/// Cap on how much of the usage response we will ever buffer. The real
/// response is a few kilobytes of JSON; anything past this is not a shape
/// `parseResponse` will recognize, so `fetchUsage` treats it as a parse
/// error instead of growing an unbounded buffer.
const response_limit = 64 * 1024;

/// One window's last known utilization ratio (0.0 to 1.0) and reset time
/// (Unix epoch seconds), for both the 5-hour and 7-day rate-limit windows
/// the usage endpoint reports.
pub const Snapshot = struct {
    five_hour_utilization: f64,
    five_hour_resets_at: i64,
    seven_day_utilization: f64,
    seven_day_resets_at: i64,
};

/// Outcome of a `fetchUsage` call, mirroring `policy.Status` so callers can
/// match on the same enum the rest of the program uses to decide caching and
/// backoff behavior.
pub const FetchOutcome = union(policy.Status) {
    ok: Snapshot,
    rate_limited: void,
    auth_error: void,
    network_error: void,
    parse_error: void,
};

// NOTE: the fixture captured at src/fixtures/usage-response.json (2026-07-12)
// uses "five_hour" and "seven_day" as the top-level window keys and
// "resets_at" for the reset field, not the "session_usage_5h",
// "weekly_usage", and "reset_time" names community docs guessed. The
// fixture's real names lead each candidate list below; the guessed names
// stay as fallbacks in case a different account tier or a future server
// change reshapes the response.
const five_hour_keys = [_][]const u8{ "five_hour", "session_usage_5h", "5h" };
const seven_day_keys = [_][]const u8{ "seven_day", "weekly_usage", "7d" };
const utilization_keys = [_][]const u8{ "utilization", "used_pct" };
const reset_keys = [_][]const u8{ "resets_at", "reset_time", "reset_at" };

/// Returns the value of the first key in `keys` present on `object`, or
/// `null` if `object` is not a JSON object or none of `keys` are present.
/// Centralizes the "try several candidate names in order" pattern that
/// `parseResponse` needs at both the window level and the field level.
fn firstField(object: std.json.Value, keys: []const []const u8) ?std.json.Value {
    if (object != .object) return null;
    for (keys) |key| {
        if (object.object.get(key)) |value| return value;
    }
    return null;
}

/// Reads a utilization value from `window` and normalizes it to a 0.0-1.0
/// ratio. The live endpoint reports utilization as a 0-100 percentage (the
/// fixture's `"utilization": 41.0` means 41%), but a float already in
/// 0.0-1.0 passes through unchanged so a future API version that switches to
/// a plain ratio does not silently get divided twice.
fn readUtilization(window: std.json.Value) ?f64 {
    const value = firstField(window, &utilization_keys) orelse return null;
    return switch (value) {
        .float => |f| if (f > 1.0) f / 100.0 else f,
        .integer => |i| @as(f64, @floatFromInt(i)) / 100.0,
        else => null,
    };
}

/// Reads a reset time from `window` as Unix epoch seconds. The value may
/// arrive as a bare epoch integer or as an ISO 8601 string (the fixture uses
/// the latter). `now` is accepted for interface symmetry with the rest of
/// `parseResponse` but is not otherwise consulted here.
fn readResetEpoch(window: std.json.Value, now: i64) ?i64 {
    _ = now;
    const value = firstField(window, &reset_keys) orelse return null;
    return switch (value) {
        .integer => |i| i,
        .string => |s| iso8601ToEpoch(s) catch null,
        else => null,
    };
}

/// Parses a raw usage-endpoint response body into a `Snapshot`. Probes
/// `five_hour_keys`, `seven_day_keys`, `utilization_keys`, and `reset_keys`
/// in order rather than binding to fixed field names, so a server-side
/// rename degrades to `error.UnrecognizedShape` instead of a crash:
/// `fetchUsage` turns that into `.parse_error` and keeps serving whatever
/// stale cached snapshot it already has.
pub fn parseResponse(arena: std.mem.Allocator, bytes: []const u8, now: i64) !Snapshot {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch
        return error.UnrecognizedShape;
    const five = firstField(root, &five_hour_keys) orelse return error.UnrecognizedShape;
    const seven = firstField(root, &seven_day_keys) orelse return error.UnrecognizedShape;
    return .{
        .five_hour_utilization = readUtilization(five) orelse return error.UnrecognizedShape,
        .five_hour_resets_at = readResetEpoch(five, now) orelse return error.UnrecognizedShape,
        .seven_day_utilization = readUtilization(seven) orelse return error.UnrecognizedShape,
        .seven_day_resets_at = readResetEpoch(seven, now) orelse return error.UnrecognizedShape,
    };
}

/// Parses `text` as an unsigned decimal integer. A helper for the
/// fixed-width fields `iso8601ToEpoch` slices out; any non-digit character
/// anywhere in `text` is malformed input, not a programmer error, so this
/// returns an error rather than asserting.
fn parseDigits(text: []const u8) !u32 {
    var result: u32 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidTimestamp;
        result = result * 10 + (c - '0');
    }
    return result;
}

/// Number of days from the Unix epoch (1970-01-01) to the given calendar
/// date. Bounded by construction: `year` comes from a 4-digit field (at
/// most 9999) and `month` is checked to be 1-12 before this is called, so
/// both loops below have a small, obvious iteration cap regardless of input.
fn daysSinceEpoch(year: std.time.epoch.Year, month: u4, day: u5) i64 {
    std.debug.assert(year >= std.time.epoch.epoch_year);
    std.debug.assert(month >= 1 and month <= 12);
    var days: i64 = 0;
    var y: std.time.epoch.Year = std.time.epoch.epoch_year;
    while (y < year) : (y += 1) {
        days += std.time.epoch.getDaysInYear(y);
    }
    var m: u4 = 1;
    while (m < month) : (m += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    }
    days += day - 1;
    std.debug.assert(days >= 0);
    return days;
}

/// Parses an ISO 8601 timestamp of the form
/// `YYYY-MM-DDTHH:MM:SS(.fraction)?(Z|+HH:MM|-HH:MM)` into Unix epoch
/// seconds. Fractional seconds are accepted (the live endpoint emits
/// microsecond precision, see the fixture) but truncated, since `Snapshot`
/// only tracks whole-second precision. Single pass, no recursion: every
/// field is a fixed-width slice checked in order, and anything that does
/// not match this shape returns `error.InvalidTimestamp` rather than
/// guessing at a partial parse.
fn iso8601ToEpoch(text: []const u8) !i64 {
    if (text.len < 20) return error.InvalidTimestamp;
    const year = try parseDigits(text[0..4]);
    if (text[4] != '-') return error.InvalidTimestamp;
    const month = try parseDigits(text[5..7]);
    if (text[7] != '-') return error.InvalidTimestamp;
    const day = try parseDigits(text[8..10]);
    if (text[10] != 'T') return error.InvalidTimestamp;
    const hour = try parseDigits(text[11..13]);
    if (text[13] != ':') return error.InvalidTimestamp;
    const minute = try parseDigits(text[14..16]);
    if (text[16] != ':') return error.InvalidTimestamp;
    const second = try parseDigits(text[17..19]);

    if (year < std.time.epoch.epoch_year) return error.InvalidTimestamp;
    if (month < 1 or month > 12) return error.InvalidTimestamp;
    const days_in_month = std.time.epoch.getDaysInMonth(
        @intCast(year),
        @enumFromInt(@as(u4, @intCast(month))),
    );
    if (day < 1 or day > days_in_month) return error.InvalidTimestamp;
    if (hour > 23) return error.InvalidTimestamp;
    if (minute > 59) return error.InvalidTimestamp;
    if (second > 59) return error.InvalidTimestamp;

    var index: usize = 19;
    if (index < text.len and text[index] == '.') {
        index += 1;
        const fraction_start = index;
        // Bounded: nine digits covers nanosecond precision, past which this
        // cannot be a real fractional-second field.
        const fraction_digits_max = 9;
        while (index < text.len and index - fraction_start < fraction_digits_max and
            std.ascii.isDigit(text[index])) : (index += 1)
        {}
        if (index == fraction_start) return error.InvalidTimestamp;
    }

    if (index >= text.len) return error.InvalidTimestamp;
    var offset_seconds: i64 = 0;
    if (text[index] == 'Z') {
        index += 1;
    } else if (text[index] == '+' or text[index] == '-') {
        const sign: i64 = if (text[index] == '-') -1 else 1;
        index += 1;
        if (index + 5 > text.len) return error.InvalidTimestamp;
        const offset_hour = try parseDigits(text[index .. index + 2]);
        if (text[index + 2] != ':') return error.InvalidTimestamp;
        const offset_minute = try parseDigits(text[index + 3 .. index + 5]);
        index += 5;
        if (offset_hour > 23 or offset_minute > 59) return error.InvalidTimestamp;
        offset_seconds = sign * (@as(i64, @intCast(offset_hour)) * std.time.s_per_hour +
            @as(i64, @intCast(offset_minute)) * std.time.s_per_min);
    } else {
        return error.InvalidTimestamp;
    }
    if (index != text.len) return error.InvalidTimestamp;

    const days = daysSinceEpoch(@intCast(year), @intCast(month), @intCast(day));
    const day_seconds = @as(i64, @intCast(hour)) * std.time.s_per_hour +
        @as(i64, @intCast(minute)) * std.time.s_per_min +
        @as(i64, @intCast(second));
    return days * std.time.epoch.secs_per_day + day_seconds - offset_seconds;
}

/// Fetches the live usage snapshot over the network and classifies the
/// result into `FetchOutcome`. Thin by design: all the interesting logic
/// (defensive field probing, ISO 8601 parsing) lives in `parseResponse` and
/// its helpers, which carry the unit tests. This function only wires HTTP
/// outcomes to `policy.Status` variants and touches the live network, so it
/// is deliberately excluded from `zig build test`.
pub fn fetchUsage(
    io: std.Io,
    arena: std.mem.Allocator,
    token: []const u8,
    user_agent: []const u8,
    now: i64,
) FetchOutcome {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{token}) catch return .network_error;

    // Fixed buffer, not `Writer.Allocating`: the cap is enforced during the
    // read itself (`drain` returns `error.WriteFailed` once `buffer` fills)
    // rather than checked after an unbounded buffer has already grown.
    var buffer: [response_limit]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const result = client.fetch(.{
        .location = .{ .url = usage_url },
        .method = .GET,
        .headers = .{
            .authorization = .{ .override = bearer },
            .user_agent = .{ .override = user_agent },
        },
        .response_writer = &writer,
    }) catch |err| switch (err) {
        // The body overran `buffer`: past `response_limit` is not a shape
        // `parseResponse` will recognize anyway, so this is a parse error,
        // not a network failure.
        error.WriteFailed => return .parse_error,
        else => return .network_error,
    };

    switch (result.status) {
        .ok => {},
        .unauthorized, .forbidden => return .auth_error,
        .too_many_requests => return .rate_limited,
        else => return .network_error,
    }
    const snapshot = parseResponse(arena, writer.buffered(), now) catch return .parse_error;
    return .{ .ok = snapshot };
}

const fixture = @embedFile("fixtures/usage-response.json");

test "parses the captured live response" {
    const arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    var arena_holder = arena_state;
    defer arena_holder.deinit();
    const snap = try parseResponse(arena_holder.allocator(), fixture, 1783275851);
    // Exact values from the fixture: five_hour.utilization = 3.0 (a 0-100
    // percentage) normalizes to 0.03, seven_day.utilization = 41.0 to 0.41.
    try testing.expectApproxEqAbs(@as(f64, 0.03), snap.five_hour_utilization, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.41), snap.seven_day_utilization, 1e-9);
    try testing.expectEqual(@as(i64, 1783926000), snap.five_hour_resets_at);
    try testing.expectEqual(@as(i64, 1784131200), snap.seven_day_resets_at);
}

test "empty object is parse error" {
    const arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    var arena_holder = arena_state;
    defer arena_holder.deinit();
    try testing.expectError(error.UnrecognizedShape, parseResponse(arena_holder.allocator(), "{}", 0));
}

test "parseResponse accepts community-alternate key names" {
    const arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    var arena_holder = arena_state;
    defer arena_holder.deinit();
    const body =
        \\{"session_usage_5h":{"used_pct":0.5,"reset_time":1000},"weekly_usage":{"used_pct":0.25,"reset_at":2000}}
    ;
    const snap = try parseResponse(arena_holder.allocator(), body, 0);
    try testing.expectEqual(@as(f64, 0.5), snap.five_hour_utilization);
    try testing.expectEqual(@as(i64, 1000), snap.five_hour_resets_at);
    try testing.expectEqual(@as(f64, 0.25), snap.seven_day_utilization);
    try testing.expectEqual(@as(i64, 2000), snap.seven_day_resets_at);
}

test "parseResponse rejects malformed json" {
    const arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    var arena_holder = arena_state;
    defer arena_holder.deinit();
    try testing.expectError(
        error.UnrecognizedShape,
        parseResponse(arena_holder.allocator(), "not json", 0),
    );
}

test "parseResponse rejects a missing window" {
    const arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    var arena_holder = arena_state;
    defer arena_holder.deinit();
    try testing.expectError(
        error.UnrecognizedShape,
        parseResponse(arena_holder.allocator(), "{\"five_hour\":{\"utilization\":1.0,\"resets_at\":1}}", 0),
    );
}

test "parseResponse rejects wrong-typed fields" {
    const arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    var arena_holder = arena_state;
    defer arena_holder.deinit();
    // `five_hour.utilization` is a string, which `readUtilization`'s type
    // switch does not accept (only `.float` and `.integer` are), so this
    // fails before `seven_day`'s int-typed `utilization` is even read.
    const body =
        \\{"five_hour":{"utilization":"high","resets_at":123},"seven_day":{"utilization":1,"resets_at":123}}
    ;
    try testing.expectError(
        error.UnrecognizedShape,
        parseResponse(arena_holder.allocator(), body, 0),
    );
}

test "iso8601ToEpoch parses the unix epoch" {
    try testing.expectEqual(@as(i64, 0), try iso8601ToEpoch("1970-01-01T00:00:00Z"));
}

test "iso8601ToEpoch parses a plain Z timestamp" {
    try testing.expectEqual(@as(i64, 1783894500), try iso8601ToEpoch("2026-07-12T22:15:00Z"));
}

test "iso8601ToEpoch parses fractional seconds with a zero UTC offset" {
    try testing.expectEqual(
        @as(i64, 1783926000),
        try iso8601ToEpoch("2026-07-13T07:00:00.402134+00:00"),
    );
}

test "iso8601ToEpoch parses a leap day" {
    // Expected value from `date -u -d '2024-02-29T12:00:00Z' +%s`, 2024
    // being a leap year (divisible by 4, not by 100).
    try testing.expectEqual(@as(i64, 1709208000), try iso8601ToEpoch("2024-02-29T12:00:00Z"));
}

test "iso8601ToEpoch applies a nonzero offset" {
    // 20:15-02:00 on 07-12 is 22:15Z on 07-12: UTC = local minus offset, so a
    // negative offset moves the UTC instant later.
    try testing.expectEqual(
        @as(i64, 1783894500),
        try iso8601ToEpoch("2026-07-12T20:15:00-02:00"),
    );
}

test "iso8601ToEpoch rejects malformed input" {
    try testing.expectError(error.InvalidTimestamp, iso8601ToEpoch(""));
    try testing.expectError(error.InvalidTimestamp, iso8601ToEpoch("not a timestamp"));
    try testing.expectError(error.InvalidTimestamp, iso8601ToEpoch("2026-13-01T00:00:00Z"));
    try testing.expectError(error.InvalidTimestamp, iso8601ToEpoch("2026-02-30T00:00:00Z"));
    try testing.expectError(error.InvalidTimestamp, iso8601ToEpoch("2026-07-12T25:00:00Z"));
    try testing.expectError(error.InvalidTimestamp, iso8601ToEpoch("2026-07-12T22:15:00"));
    try testing.expectError(error.InvalidTimestamp, iso8601ToEpoch("2026-07-12T22:15:00+0200"));
    try testing.expectError(error.InvalidTimestamp, iso8601ToEpoch("2026-07-12T22:15:00Zgarbage"));
}
