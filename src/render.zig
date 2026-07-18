//! Renderers: turn `state.State` into the three output shapes the CLI serves,
//! human text, waybar JSON, and raw JSON passthrough, plus the shared relative
//! time formatter they all lean on. No decision logic lives here beyond
//! picking a display class: see `policy.zig` for staleness and utilization
//! thresholds.

const std = @import("std");
const policy = @import("policy.zig");
const state = @import("state.zig");
const testing = std.testing;

/// Formats a duration in seconds as a short human-relative string: `now` at
/// or below zero, minutes under an hour (`47m`), hours with zero-padded
/// minutes under a day (`1h 08m`), and days with hours beyond that (`2d
/// 3h`). Shared by `human` and `waybar` for both time-until-reset and
/// time-since-fetch.
fn relative(arena: std.mem.Allocator, delta_seconds: i64) ![]u8 {
    if (delta_seconds <= 0) return arena.dupe(u8, "now");
    const minutes_total = @divTrunc(delta_seconds, 60);
    const days = @divTrunc(minutes_total, 60 * 24);
    const hours = @divTrunc(@mod(minutes_total, 60 * 24), 60);
    const minutes = @mod(minutes_total, 60);
    // NOTE: `{d:0>2}` on a signed integer prints a spurious `+` in place of
    // the zero fill in this Zig version (0.17.0-dev.704+b8cb78023): zero
    // padding a signed value reserves the leading column for a sign and
    // fills it with '+' rather than '0' when the value is non-negative.
    // `minutes` is always in `[0, 59]` here (an `@mod` result), so cast to
    // `u64` to sidestep the signed-format quirk instead of hand-padding.
    std.debug.assert(minutes >= 0);
    const minutes_unsigned: u64 = @intCast(minutes);
    if (days > 0) return std.fmt.allocPrint(arena, "{d}d {d}h", .{ days, hours });
    if (hours > 0) return std.fmt.allocPrint(arena, "{d}h {d:0>2}m", .{ hours, minutes_unsigned });
    return std.fmt.allocPrint(arena, "{d}m", .{minutes});
}

/// Converts a utilization ratio in `[0, 1]` to a whole percentage for display.
fn pct(utilization: f64) i64 {
    std.debug.assert(utilization >= 0.0);
    return @intFromFloat(@round(utilization * 100.0));
}

/// Renders `s` as a single-line waybar JSON payload: `text` for the bar
/// itself, `tooltip` for the hover detail, `class` for CSS styling (the
/// utilization band, or `stale` when the cache has gone stale per
/// `policy.isStale`, which overrides the band), and `percentage` for
/// waybar's built-in progress indicator. When `s.fetched_at` is zero (no
/// cached state has ever been written), the tooltip's age line reads "no data
/// yet" instead of a relative duration: an epoch-0 `fetched_at` would
/// otherwise format as something like "20647d 3h ago", which is technically
/// correct and practically nonsense.
pub fn waybar(arena: std.mem.Allocator, s: state.State, now: i64, ttl: i64) ![]u8 {
    const worst = @max(s.five_hour.utilization, s.seven_day.utilization);
    const stale = policy.isStale(now, s.fetched_at, ttl, s.last_status);
    // NOTE: the CSS classes waybar styles against are `policy.Class`'s tag
    // names verbatim, so renaming a tag is a user-visible contract change;
    // the class-band test below pins all three spellings.
    const class = if (stale) "stale" else @tagName(policy.classify(worst));
    const text = try std.fmt.allocPrint(arena, "5h {d}% \u{b7} wk {d}%", .{
        pct(s.five_hour.utilization), pct(s.seven_day.utilization),
    });
    const age = if (s.fetched_at == 0)
        try arena.dupe(u8, "no data yet")
    else
        try std.fmt.allocPrint(arena, "as of {s} ago", .{try relative(arena, now - s.fetched_at)});
    const tooltip = try std.fmt.allocPrint(
        arena,
        "5h: {d}% resets in {s}\nweek: {d}% resets in {s}\nstatus: {s}, {s}",
        .{
            pct(s.five_hour.utilization), try relative(arena, s.five_hour.resets_at - now),
            pct(s.seven_day.utilization), try relative(arena, s.seven_day.resets_at - now),
            @tagName(s.last_status),      age,
        },
    );
    const Payload = struct {
        text: []const u8,
        tooltip: []const u8,
        class: []const u8,
        percentage: i64,
    };
    const payload = Payload{
        .text = text,
        .tooltip = tooltip,
        .class = class,
        .percentage = pct(worst),
    };
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(payload, .{})});
}

/// Renders `s` as multi-line human-readable text for terminal output: both
/// windows' utilization and reset times, and the cache's data age with a
/// `(stale)` suffix when `policy.isStale` says the cache is no longer fresh.
pub fn human(arena: std.mem.Allocator, s: state.State, now: i64, ttl: i64) ![]u8 {
    const stale = policy.isStale(now, s.fetched_at, ttl, s.last_status);
    const format =
        "5h window:   {d}%  resets in {s}\n" ++
        "week window: {d}%  resets in {s}\n" ++
        "data age:    {s}{s}  status: {s}\n";
    return std.fmt.allocPrint(
        arena,
        format,
        .{
            pct(s.five_hour.utilization),
            try relative(arena, s.five_hour.resets_at - now),
            pct(s.seven_day.utilization),
            try relative(arena, s.seven_day.resets_at - now),
            try relative(arena, now - s.fetched_at),
            if (stale) " (stale)" else "",
            @tagName(s.last_status),
        },
    );
}

/// Renders `s` as indented JSON, passed straight through to `state.serialize`.
/// This is the raw machine-readable output mode: no policy applied, no
/// derived fields, exactly what is on disk.
pub fn raw(arena: std.mem.Allocator, s: state.State) ![]u8 {
    return state.serialize(arena, s);
}

test "relative formats minutes hours days" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("47m", try relative(arena, 47 * 60));
    try testing.expectEqualStrings("1h 08m", try relative(arena, 68 * 60));
    try testing.expectEqualStrings("2d 3h", try relative(arena, (51 * 60 + 4) * 60));
    try testing.expectEqualStrings("now", try relative(arena, 0));
}

fn testState() state.State {
    return .{
        .fetched_at = 1000,
        .five_hour = .{ .utilization = 0.45, .resets_at = 1000 + 47 * 60 },
        .seven_day = .{ .utilization = 0.62, .resets_at = 1000 + 2 * 86400 },
        .last_status = .ok,
    };
}

test "waybar json has text class percentage tooltip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const line = try waybar(arena, testState(), 1060, 180);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    try testing.expectEqualStrings("5h 45% \u{b7} wk 62%", parsed.object.get("text").?.string);
    try testing.expectEqualStrings("ok", parsed.object.get("class").?.string);
    try testing.expectEqual(@as(i64, 62), parsed.object.get("percentage").?.integer);
    try testing.expect(parsed.object.get("tooltip").?.string.len > 0);
}

test "waybar class tracks the classification band" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bands = [_]struct { utilization: f64, class: []const u8 }{
        .{ .utilization = 0.45, .class = "ok" },
        .{ .utilization = 0.72, .class = "warn" },
        .{ .utilization = 0.94, .class = "critical" },
    };
    for (bands) |band| {
        var s = testState();
        s.five_hour.utilization = band.utilization;
        const line = try waybar(arena, s, 1060, 180);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        try testing.expectEqualStrings(band.class, parsed.object.get("class").?.string);
    }
}

test "waybar marks stale with suffix class" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = testState();
    s.last_status = .rate_limited;
    const line = try waybar(arena, s, 1060, 180);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    try testing.expectEqualStrings("stale", parsed.object.get("class").?.string);
}

test "waybar tooltip reads no data yet for a zero fetched_at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = testState();
    s.fetched_at = 0;
    const line = try waybar(arena, s, 1060, 180);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    const tooltip = parsed.object.get("tooltip").?.string;
    try testing.expect(std.mem.indexOf(u8, tooltip, "no data yet") != null);
    try testing.expect(std.mem.indexOf(u8, tooltip, "ago") == null);
}
