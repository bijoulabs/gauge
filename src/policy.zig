//! Policy core: pure decision logic for cache freshness, backoff escalation, and
//! utilization classification. No I/O, no allocation, no side effects: every
//! function here is a deterministic function of its arguments.

const std = @import("std");
const testing = std.testing;

/// Default cache time-to-live, in seconds, used when a caller has no override.
pub const ttl_seconds_default: i64 = 180;

/// Backoff ladder, in minutes: escalates on repeated failure and caps at the last
/// entry. Index selection lives in `nextBackoffUntil`.
const backoff_minutes = [_]i64{ 5, 10, 20, 30 };

/// Outcome of the most recent fetch attempt against the upstream source.
pub const Status = enum { ok, rate_limited, auth_error, network_error, parse_error };

/// Whether to serve the cached value as-is or refresh it from upstream.
pub const Decision = enum { serve_cached, refresh };

/// Utilization band for gauge display and alerting.
pub const Class = enum { ok, warn, critical };

/// Decides whether to serve the cached value or refresh from upstream.
///
/// Branch order is deliberate and load-bearing: offline first (no network attempt
/// is possible), then force (a human explicitly retrying deserves a real attempt,
/// so force beats backoff), then backoff (protects upstream from automatic
/// hammering), then plain ttl staleness.
pub fn decide(
    now: i64,
    fetched_at: i64,
    backoff_until: i64,
    ttl_seconds: i64,
    force: bool,
    offline: bool,
) Decision {
    std.debug.assert(ttl_seconds > 0);
    std.debug.assert(fetched_at <= now or fetched_at == 0);
    if (offline) return .serve_cached;
    if (force) return .refresh;
    if (backoff_until > now) return .serve_cached;
    if (now - fetched_at < ttl_seconds) return .serve_cached;
    return .refresh;
}

/// Computes the next backoff deadline from `now`, escalating with `backoff_level`
/// along a fixed ladder (5, 10, 20, 30 minutes) and capping at the ladder's end so
/// repeated failures never grow the delay unboundedly.
pub fn nextBackoffUntil(now: i64, backoff_level: u8) i64 {
    const index = @min(@as(usize, backoff_level), backoff_minutes.len - 1);
    const result = now + backoff_minutes[index] * std.time.s_per_min;
    std.debug.assert(result > now);
    return result;
}

/// Classifies a maximum utilization ratio into a display band: warn at 0.70,
/// critical at 0.90.
pub fn classify(utilization_max: f64) Class {
    std.debug.assert(utilization_max >= 0.0);
    if (utilization_max >= 0.90) return .critical;
    if (utilization_max >= 0.70) return .warn;
    return .ok;
}

/// Reports whether cached data should be considered stale: any non-ok status is
/// immediately stale, and even an ok status goes stale past 3x the ttl (a wider
/// margin than `decide`'s plain ttl, since staleness here is a display signal, not
/// a refresh trigger).
pub fn isStale(now: i64, fetched_at: i64, ttl_seconds: i64, last_status: Status) bool {
    std.debug.assert(ttl_seconds > 0);
    std.debug.assert(fetched_at <= now or fetched_at == 0);
    if (last_status != .ok) return true;
    return now - fetched_at > 3 * ttl_seconds;
}

test "decide serves cache when fresh" {
    try testing.expectEqual(Decision.serve_cached, decide(1000, 900, 0, 180, false, false));
}
test "decide refreshes when stale" {
    try testing.expectEqual(Decision.refresh, decide(1181, 1000, 0, 180, false, false));
}
test "decide honors backoff over staleness" {
    try testing.expectEqual(Decision.serve_cached, decide(2000, 0, 2100, 180, false, false));
}
test "decide force overrides freshness but not offline" {
    try testing.expectEqual(Decision.refresh, decide(1000, 999, 0, 180, true, false));
    try testing.expectEqual(Decision.serve_cached, decide(1000, 0, 0, 180, true, true));
}
test "decide force beats backoff" {
    try testing.expectEqual(Decision.refresh, decide(2000, 0, 2100, 180, true, false));
}
test "backoff ladder escalates and caps" {
    try testing.expectEqual(@as(i64, 1000 + 5 * 60), nextBackoffUntil(1000, 0));
    try testing.expectEqual(@as(i64, 1000 + 10 * 60), nextBackoffUntil(1000, 1));
    try testing.expectEqual(@as(i64, 1000 + 30 * 60), nextBackoffUntil(1000, 3));
    try testing.expectEqual(@as(i64, 1000 + 30 * 60), nextBackoffUntil(1000, 200));
}
test "classify thresholds at boundaries" {
    try testing.expectEqual(Class.ok, classify(0.699));
    try testing.expectEqual(Class.warn, classify(0.70));
    try testing.expectEqual(Class.critical, classify(0.90));
}
test "isStale on error status and on age" {
    try testing.expect(isStale(1000, 999, 180, .network_error));
    try testing.expect(!isStale(1000, 999, 180, .ok));
    try testing.expect(isStale(1541, 1000, 180, .ok));
}
