//! CLI entry point: parses arguments, decides whether to serve cached usage data or
//! refresh from upstream, and renders the result. `policy.decide` makes the
//! refresh/serve call; a lock file at `state.lock` keeps concurrent invocations from
//! racing the upstream fetch. Exit codes: 0 whenever any state renders (waybar mode
//! always renders something, even an all-zero "stale" placeholder, so the bar never
//! breaks), 2 for usage errors, offline-with-no-data, or a render failure.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const creds = @import("creds.zig");
const api = @import("api.zig");
const render = @import("render.zig");
const waybar_setup = @import("waybar_setup.zig");
const testing = std.testing;

// Test reachability: `zig test` never calls `main`, so `run` and everything it
// calls (state, creds, api, render) are otherwise dead code from the test
// binary's perspective and their `test` blocks get silently dropped. A
// top-level `comptime` block is analyzed unconditionally (unlike a plain
// `const x = @import(...)`, which is lazy and only forces analysis when
// something already-reachable uses it), so it is what actually pulls every
// module's tests into `zig build test`. This is a restoration, not new code:
// the Task 1 stub carried the same block for the same reason.
comptime {
    _ = @import("policy.zig");
    _ = @import("state.zig");
    _ = @import("creds.zig");
    _ = @import("api.zig");
    _ = @import("render.zig");
    _ = @import("waybar_setup.zig");
}

/// Output mode, selected by the (optional) first positional argument.
/// `setup_waybar` is a one-shot side-effecting action rather than a render
/// mode, but it shares the same dispatch slot since it is selected the same
/// way: the first positional argument.
const Mode = enum { human, waybar, json, setup_waybar };

/// Parsed command line: defaults match the brief's contract (`human` mode, TTL from
/// `policy.ttl_seconds_default`, every flag off).
const Args = struct {
    mode: Mode = .human,
    force: bool = false,
    offline: bool = false,
    max_age: i64 = policy.ttl_seconds_default,
    version: bool = false,
    help: bool = false,
};

/// Parses `argv` (program name already stripped) into `Args`. Any unrecognized
/// token, or `--max-age` missing its value or given a non-positive one, is
/// `error.BadUsage`: a single signal so `run` only needs one usage-error branch.
fn parseArgs(argv: []const []const u8) error{BadUsage}!Args {
    var args = Args{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "waybar")) {
            args.mode = .waybar;
        } else if (std.mem.eql(u8, arg, "json")) {
            args.mode = .json;
        } else if (std.mem.eql(u8, arg, "setup-waybar")) {
            args.mode = .setup_waybar;
        } else if (std.mem.eql(u8, arg, "--force")) {
            args.force = true;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            args.offline = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            args.version = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            args.help = true;
        } else if (std.mem.eql(u8, arg, "--max-age")) {
            i += 1;
            if (i >= argv.len) return error.BadUsage;
            args.max_age = std.fmt.parseInt(i64, argv[i], 10) catch return error.BadUsage;
            if (args.max_age <= 0) return error.BadUsage;
        } else {
            return error.BadUsage;
        }
    }
    return args;
}

/// Extracts the program's argument vector, excluding argv[0] (the program name), as
/// a plain `[]const []const u8` matching `parseArgs`'s signature. `Args.toSlice`
/// returns `[]const [:0]const u8`; a slice of sentinel-terminated elements does not
/// coerce as a whole to a slice of plain ones (only single values do), so each
/// element is copied across individually.
fn argvSlice(init: std.process.Init, arena: std.mem.Allocator) ![]const []const u8 {
    const raw = try init.minimal.args.toSlice(arena);
    // Every process argv includes the program name at index 0; a violation here is
    // a platform/runtime bug, not operational input, hence an assertion.
    std.debug.assert(raw.len >= 1);
    const argv = try arena.alloc([]const u8, raw.len - 1);
    for (raw[1..], 0..) |arg, i| argv[i] = arg;
    return argv;
}

/// Resolves the `User-Agent` header for the upstream request: `GAUGE_USER_AGENT` if
/// set to a non-empty value, else `api.default_user_agent`. Empty variables are
/// unset, per `state.envVarNonEmpty`.
fn userAgent(arena: std.mem.Allocator) ![]const u8 {
    return try state.envVarNonEmpty(arena, "GAUGE_USER_AGENT") orelse api.default_user_agent;
}

/// Attempts one refresh from upstream and returns the resulting state: `previous`
/// with fresh windows and a cleared backoff on success, or `previous` with an
/// escalated backoff via `markFailure` on any failure. Never returns an error:
/// every failure path here (missing credentials, malformed credentials, a network
/// or API failure) is an operational outcome the caller renders around, not a bug.
fn refresh(io: Io, arena: std.mem.Allocator, previous: state.State, now: i64) state.State {
    var next = previous;
    const creds_path = creds.credentialsPath(arena) catch
        return markFailure(&next, .auth_error, now);
    const token = creds.readAccessToken(io, arena, creds_path) catch
        return markFailure(&next, .auth_error, now);
    const user_agent = userAgent(arena) catch api.default_user_agent;
    const outcome = api.fetchUsage(io, arena, token, user_agent);
    switch (outcome) {
        .ok => |snapshot| {
            next.fetched_at = now;
            next.five_hour = .{
                .utilization = snapshot.five_hour_utilization,
                .resets_at = snapshot.five_hour_resets_at,
            };
            next.seven_day = .{
                .utilization = snapshot.seven_day_utilization,
                .resets_at = snapshot.seven_day_resets_at,
            };
            next.last_status = .ok;
            next.backoff_until = 0;
            next.backoff_level = 0;
        },
        // All four failure payloads are void and `FetchOutcome` is tagged by
        // `policy.Status` itself, so the active tag is the status to record.
        .rate_limited, .auth_error, .network_error, .parse_error => {
            _ = markFailure(&next, @as(policy.Status, outcome), now);
        },
    }
    return next;
}

/// Records a failed fetch attempt on `next`: sets `last_status`, schedules the next
/// backoff deadline from the current `backoff_level`, then escalates the level.
/// `+|=` saturates at `u8`'s max instead of wrapping, so a very long losing streak
/// still lands on the ladder's last (30 minute) rung in `nextBackoffUntil` rather
/// than wrapping back to the first.
fn markFailure(next: *state.State, status: policy.Status, now: i64) state.State {
    next.last_status = status;
    next.backoff_until = policy.nextBackoffUntil(now, next.backoff_level);
    next.backoff_level +|= 1;
    return next.*;
}

/// Clamps `s`'s time fields to sane bounds relative to `now`, applied to every
/// loaded state before it reaches `policy.decide` or `policy.isStale`.
///
/// NOTE: both `policy.decide` and `policy.isStale` assert `fetched_at <= now`,
/// which normally holds since `fetched_at` is only ever set from a past `now`.
/// A backwards clock step between invocations (an NTP correction, a VM resume, a
/// manual clock change) breaks that: a state file written under the old, later
/// clock reading loads with a `fetched_at` now in the future, and the assert
/// panics on every subsequent run until the clock catches back up, a crash loop
/// from a single bad state file. Clamping `fetched_at` to `now` here, at the load
/// boundary, restores the invariant before it reaches policy. `backoff_until`
/// gets the same treatment, capped at `now` plus the backoff ladder's longest
/// rung (30 minutes, see `policy.nextBackoffUntil`'s ladder): without this, a
/// state file written after a large forward clock jump could carry a
/// `backoff_until` far in the future, and a later backwards step would freeze
/// refreshes for as long as that stale deadline says, well past anything the
/// ladder itself would ever schedule.
///
/// Both windows' `utilization` are clamped to `[0.0, 10.0]` (ratio space, the
/// same 1000-percent ceiling `api.readUtilization` enforces on freshly parsed
/// values) for the same reason: this function is the load boundary, and a
/// state file need not have come through that parser to reach it. State
/// files written by a pre-fix `gauge` build, hand-edited for testing, or
/// produced by some other writer entirely can carry an out-of-range value
/// (negative, or a huge percent-as-ratio typo) that `readUtilization` would
/// have rejected. Left unclamped, a negative value trips `render.pct`'s
/// `utilization >= 0.0` assert and an oversized one overflows `pct`'s
/// `@intFromFloat`, either way panicking the `ReleaseSafe` binary on every
/// run until the file is manually fixed.
fn sanitizeState(s: state.State, now: i64) state.State {
    var sanitized = s;
    sanitized.fetched_at = @min(sanitized.fetched_at, now);
    sanitized.backoff_until = @min(sanitized.backoff_until, now + 30 * std.time.s_per_min);
    sanitized.five_hour.utilization = std.math.clamp(sanitized.five_hour.utilization, 0.0, 10.0);
    sanitized.seven_day.utilization = std.math.clamp(sanitized.seven_day.utilization, 0.0, 10.0);
    return sanitized;
}

/// Attempts to acquire the exclusive refresh lock at `dir_path/state.lock`,
/// returning `null` if the directory cannot be created, the lock file cannot be
/// opened, or another process already holds the lock. A `null` return is not
/// exceptional: it means another invocation is refreshing right now, and the
/// caller falls back to serving whatever state it already has.
fn acquireLock(io: Io, arena: std.mem.Allocator, dir_path: []const u8) ?Io.File {
    Io.Dir.cwd().createDirPath(io, dir_path) catch return null;
    const lock_path = std.fs.path.join(arena, &.{ dir_path, "state.lock" }) catch return null;
    const file = Io.Dir.cwd().createFile(io, lock_path, .{}) catch return null;
    const got_lock = file.tryLock(io, .exclusive) catch false;
    if (!got_lock) {
        file.close(io);
        return null;
    }
    return file;
}

/// Releases a lock acquired by `acquireLock`: unlocks, then closes the file.
fn releaseLock(io: Io, file: Io.File) void {
    file.unlock(io);
    file.close(io);
}

/// Runs the `setup-waybar` subcommand: resolves the waybar config directory,
/// hands off to `waybar_setup.run` for the actual read/edit/write work, and
/// prints its result. A directory that cannot be resolved (no `HOME` and no
/// `GAUGE_WAYBAR_DIR`) or an unexpected allocator failure inside
/// `waybar_setup.run` both collapse to exit 2, matching every other usage
/// error in this file.
fn runSetupWaybar(io: Io, arena: std.mem.Allocator, now: i64) u8 {
    const dir_path = waybar_setup.waybarDirPath(arena) catch {
        printErr(io, "gauge: could not resolve a waybar config directory (is $HOME set?)\n");
        return 2;
    };
    const result = waybar_setup.run(io, arena, dir_path, now) catch {
        printErr(io, "gauge: setup-waybar failed unexpectedly\n");
        return 2;
    };
    switch (result) {
        .ok => |message| {
            printOut(io, message);
            return 0;
        },
        .refused => |message| {
            printErr(io, message);
            return 2;
        },
    }
}

/// Writes `text` to stdout through a small buffered writer. Errors are silently
/// dropped: a write failure on stdout mid-render (a closed pipe, most likely) is not
/// something this program can meaningfully recover from or report further.
fn printOut(io: Io, text: []const u8) void {
    var buf: [1024]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), io, &buf);
    writer.interface.writeAll(text) catch return;
    writer.interface.flush() catch return;
}

/// Writes `text` to stderr through a small buffered writer. See `printOut` for why
/// write failures are dropped rather than propagated.
fn printErr(io: Io, text: []const u8) void {
    var buf: [1024]u8 = undefined;
    var writer: Io.File.Writer = .init(.stderr(), io, &buf);
    writer.interface.writeAll(text) catch return;
    writer.interface.flush() catch return;
}

const help_text =
    \\gauge: Claude usage gauge for terminal and waybar.
    \\
    \\Usage: gauge [waybar|json|setup-waybar] [--force] [--offline]
    \\             [--max-age <secs>] [--version] [--help]
    \\
    \\Subcommands:
    \\  (default)     Human readable text for a terminal.
    \\  waybar        Single line JSON for waybar's custom module.
    \\  json          Raw cached state as JSON.
    \\  setup-waybar  Wire the custom/gauge module into your waybar config
    \\                and stylesheet automatically. Backs up both files
    \\                first and refuses, printing manual steps, if your
    \\                config does not look like it expects. Ignores
    \\                --force, --offline, and --max-age.
    \\
    \\Flags:
    \\  --force            Refresh from upstream even if cached or backing off.
    \\  --offline          Never contact upstream, serve only what is cached.
    \\  --max-age <secs>   Cache time to live in seconds, default 180.
    \\  --version          Print the version and exit.
    \\  --help             Print this help and exit.
    \\
    \\Environment:
    \\  GAUGE_STATE_DIR    State directory. Default $XDG_STATE_HOME/gauge or
    \\                     $HOME/.local/state/gauge.
    \\  GAUGE_CREDENTIALS  Credentials file path. Default
    \\                     $HOME/.claude/.credentials.json.
    \\  GAUGE_USER_AGENT   User-Agent sent with the usage request.
    \\  GAUGE_WAYBAR_DIR   Waybar config directory used by setup-waybar.
    \\                     Default $HOME/.config/waybar.
    \\
;

/// Runs the CLI end to end and returns a process exit code. Kept `!void`-free and
/// side-effect-explicit (a plain `u8` return) so `main` stays a thin wrapper that
/// only has to decide whether to exit with a nonzero code.
fn run(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = argvSlice(init, arena) catch return 2;
    const args = parseArgs(argv) catch {
        printErr(
            io,
            "usage: gauge [waybar|json|setup-waybar] [--force] [--offline] [--max-age <secs>]\n",
        );
        return 2;
    };
    if (args.help) {
        printOut(io, help_text);
        return 0;
    }
    if (args.version) {
        printOut(io, "gauge " ++ build_options.version ++ "\n");
        return 0;
    }

    // NOTE: the brief's `std.time.timestamp()` does not exist in this Zig version;
    // `std.time` is now only the epoch/unit-conversion constants (see
    // std/time.zig in the Zig source tree). Wall-clock reads go through `Io`'s
    // clock API instead: `Io.Clock.real` is documented as Unix epoch seconds (leap
    // seconds ignored), matching what `state.State.fetched_at` and every
    // `policy`/`render` timestamp parameter already assume.
    const now: i64 = Io.Clock.real.now(io).toSeconds();

    // setup-waybar is a one-shot side-effecting action, not a render: it never
    // touches the usage cache, upstream, or `--force`/`--offline`/`--max-age`,
    // so it dispatches here rather than falling through to the state/policy
    // pipeline below.
    if (args.mode == .setup_waybar) return runSetupWaybar(io, arena, now);

    const dir_path = state.stateDirPath(arena) catch return 2;
    var current = sanitizeState(state.load(io, arena, dir_path) orelse state.State{}, now);

    const decision = policy.decide(
        now,
        current.fetched_at,
        current.backoff_until,
        args.max_age,
        args.force,
        args.offline,
    );
    if (decision == .refresh) {
        if (acquireLock(io, arena, dir_path)) |lock_file| {
            defer releaseLock(io, lock_file);
            current = refresh(io, arena, current, now);
            // A failed save must never break rendering: the freshly fetched `current`
            // still renders below from memory even if it never made it to disk, and
            // the next invocation just refreshes again once the cache looks stale.
            state.save(io, arena, dir_path, current) catch {};
        }
        // Else: another invocation is refreshing right now. Serve what we have.
    }

    // `current.fetched_at == 0` here means no cached state ever existed and no
    // refresh (attempted above, or ruled out by `.offline`/backoff) produced one
    // either: there is nothing to show. Waybar mode still renders below anyway,
    // an all-zero snapshot classifies as stale via `policy.isStale`, so the bar
    // gets valid JSON instead of breaking.
    if (current.fetched_at == 0) {
        printErr(io, "gauge: no usage data yet and none could be fetched\n");
        if (args.mode != .waybar) return 2;
    }

    const output = switch (args.mode) {
        .human => render.human(arena, current, now, args.max_age),
        .waybar => render.waybar(arena, current, now, args.max_age),
        .json => render.raw(arena, current),
        // `run` already returned above for `.setup_waybar`, before `dir_path`
        // and the state/policy pipeline this switch renders from even exist.
        .setup_waybar => unreachable,
    } catch return 2;
    printOut(io, output);
    // Only waybar's output needs an appended newline: `render.human` already ends
    // with one, and `render.raw`'s JSON is deliberately left unterminated so a
    // caller piping it elsewhere gets exactly the bytes on disk.
    if (args.mode == .waybar) printOut(io, "\n");
    return 0;
}

// NOTE: the brief sketches `pub fn main() u8`. This toolchain's entry point is
// `pub fn main(init: std.process.Init) !void` (see Task 1's stub and its own NOTE):
// 0.17.0-dev.704+b8cb78023 threads an `Io` and a permanent per-process arena through
// `Init` rather than exposing a bare no-argument `main`. Reconciled by keeping the
// brief's `u8`-returning logic verbatim in `run` above and using this thin wrapper
// to translate a nonzero code into the real exit code via `std.process.exit`, which
// is `noreturn`, so `main` never needs to produce a `u8` itself.
//
// `init.io` is used directly instead of constructing a `std.Io.Threaded` as the
// brief sketches: `Init` already carries an appropriate `Io` for the target
// (see `process.zig`'s doc comment on the field), which is the simplest working
// path and matches the current `zig init` template. Likewise `init.arena` (a
// permanent, process-lifetime arena that Zig cleans up automatically on exit) is
// used in place of a locally constructed `ArenaAllocator`, since one is already
// provided and manual `deinit` would run into the same "no unwind before
// `std.process.exit`" question `main` itself sidesteps.
///
/// Entry point: runs the CLI via `run` and translates a nonzero result into the
/// real process exit code. A zero result needs no translation, falling off the
/// end of `!void` already exits 0.
pub fn main(init: std.process.Init) !void {
    const code = run(init);
    if (code != 0) std.process.exit(code);
}

test "parseArgs subcommands and flags" {
    const args = try parseArgs(&.{ "waybar", "--force", "--max-age", "60" });
    try testing.expectEqual(Mode.waybar, args.mode);
    try testing.expect(args.force);
    try testing.expectEqual(@as(i64, 60), args.max_age);
}

test "parseArgs rejects unknown and missing value" {
    try testing.expectError(error.BadUsage, parseArgs(&.{"frobnicate"}));
    try testing.expectError(error.BadUsage, parseArgs(&.{"--max-age"}));
    try testing.expectError(error.BadUsage, parseArgs(&.{ "--max-age", "0" }));
}

test "parseArgs recognizes setup-waybar and still parses (ignored) flags after it" {
    const args = try parseArgs(&.{ "setup-waybar", "--force", "--offline" });
    try testing.expectEqual(Mode.setup_waybar, args.mode);
    try testing.expect(args.force);
    try testing.expect(args.offline);
}

test "sanitizeState clamps a future fetched_at to now" {
    const s = state.State{ .fetched_at = 5000 };
    const sanitized = sanitizeState(s, 1000);
    try testing.expectEqual(@as(i64, 1000), sanitized.fetched_at);
}

test "sanitizeState clamps an oversized backoff_until to the ladder cap" {
    const s = state.State{ .backoff_until = 1000 + 999 * std.time.s_per_min };
    const sanitized = sanitizeState(s, 1000);
    try testing.expectEqual(@as(i64, 1000 + 30 * std.time.s_per_min), sanitized.backoff_until);
}

test "sanitizeState leaves in-range fields untouched" {
    const s = state.State{ .fetched_at = 900, .backoff_until = 950 };
    const sanitized = sanitizeState(s, 1000);
    try testing.expectEqual(@as(i64, 900), sanitized.fetched_at);
    try testing.expectEqual(@as(i64, 950), sanitized.backoff_until);
}

test "sanitizeState clamps out-of-range utilization into [0.0, 10.0]" {
    const s = state.State{
        .five_hour = .{ .utilization = -0.5 },
        .seven_day = .{ .utilization = 5000 },
    };
    const sanitized = sanitizeState(s, 1000);
    try testing.expectEqual(@as(f64, 0.0), sanitized.five_hour.utilization);
    try testing.expectEqual(@as(f64, 10.0), sanitized.seven_day.utilization);
}
