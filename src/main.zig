//! CLI entry point: parses arguments, decides whether to serve cached usage data or
//! refresh from upstream, and renders the result. `policy.decide` makes the
//! refresh/serve call; a lock file at `state.lock` keeps concurrent invocations from
//! racing the upstream fetch. Exit codes: 0 whenever any state renders (waybar mode
//! always renders something, even an all-zero "stale" placeholder, so the bar never
//! breaks), 2 for usage errors, offline-with-no-data, or a render failure.

const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const creds = @import("creds.zig");
const api = @import("api.zig");
const render = @import("render.zig");
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
}

/// Output mode, selected by the (optional) first positional argument.
const Mode = enum { human, waybar, json };

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
/// set to a non-empty value, else `api.default_user_agent`. Mirrors
/// `state.stateDirPath`'s treatment of an empty-but-set variable as unset, since an
/// empty env var is operational input, not an explicit override.
fn userAgent(arena: std.mem.Allocator) ![]const u8 {
    if (try state.envVarOwned(arena, "GAUGE_USER_AGENT")) |explicit| {
        if (explicit.len > 0) return explicit;
    }
    return api.default_user_agent;
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
    switch (api.fetchUsage(io, arena, token, user_agent, now)) {
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
        .rate_limited => _ = markFailure(&next, .rate_limited, now),
        .auth_error => _ = markFailure(&next, .auth_error, now),
        .network_error => _ = markFailure(&next, .network_error, now),
        .parse_error => _ = markFailure(&next, .parse_error, now),
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
    \\Usage: gauge [waybar|json] [--force] [--offline] [--max-age <secs>]
    \\             [--version] [--help]
    \\
    \\Subcommands:
    \\  (default)   Human readable text for a terminal.
    \\  waybar      Single line JSON for waybar's custom module.
    \\  json        Raw cached state as JSON.
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
        printErr(io, "usage: gauge [waybar|json] [--force] [--offline] [--max-age <secs>]\n");
        return 2;
    };
    if (args.help) {
        printOut(io, help_text);
        return 0;
    }
    if (args.version) {
        printOut(io, "gauge 0.1.0\n");
        return 0;
    }

    // NOTE: the brief's `std.time.timestamp()` does not exist in this Zig version;
    // `std.time` is now only the epoch/unit-conversion constants (see
    // `/home/moe/zig/lib/std/time.zig`). Wall-clock reads go through `Io`'s clock
    // API instead: `Io.Clock.real` is documented as Unix epoch seconds (leap
    // seconds ignored), matching what `state.State.fetched_at` and every
    // `policy`/`render` timestamp parameter already assume.
    const now: i64 = Io.Clock.real.now(io).toSeconds();
    const dir_path = state.stateDirPath(arena) catch return 2;
    var current = state.load(io, arena, dir_path) orelse state.State{};

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
    } catch return 2;
    printOut(io, output);
    if (args.mode != .json) printOut(io, "\n");
    return 0;
}

// NOTE: the brief sketches `pub fn main() u8`. This toolchain's entry point is
// `pub fn main(init: std.process.Init) !void` (see Task 1's stub and its own NOTE):
// 0.17.0-dev.704+b8cb78023 threads an `Io` and a permanent per-process arena through
// `Init` rather than exposing a bare no-argument `main`. Reconciled by keeping the
// brief's `u8`-returning logic verbatim in `run` above and using this thin wrapper
// to translate a nonzero code into the real exit code via `std.process.exit`, which
// is `noreturn`, so `main` never needs to produce a `u8` itself. A zero code needs
// no translation: falling off the end of `!void` already exits 0.
//
// `init.io` is used directly instead of constructing a `std.Io.Threaded` as the
// brief sketches: `Init` already carries an appropriate `Io` for the target
// (see `process.zig`'s doc comment on the field), which is the simplest working
// path and matches the current `zig init` template. Likewise `init.arena` (a
// permanent, process-lifetime arena that Zig cleans up automatically on exit) is
// used in place of a locally constructed `ArenaAllocator`, since one is already
// provided and manual `deinit` would run into the same "no unwind before
// `std.process.exit`" question `main` itself sidesteps.
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
