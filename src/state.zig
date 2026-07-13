//! State file: the on-disk cache of the last known rate-limit windows. Owns
//! JSON parsing/serialization, the atomic save path, and the state directory
//! resolution rules. No decision logic lives here: see `policy.zig` for that.

const std = @import("std");
const policy = @import("policy.zig");
const testing = std.testing;

/// A single rate-limit window's last known utilization and reset time.
pub const Window = struct {
    utilization: f64 = 0,
    resets_at: i64 = 0,
};

/// Cached gauge state, persisted as JSON at `stateDirPath()/state.json`.
pub const State = struct {
    fetched_at: i64 = 0,
    five_hour: Window = .{},
    seven_day: Window = .{},
    last_status: policy.Status = .ok,
    backoff_until: i64 = 0,
    backoff_level: u8 = 0,
};

const state_file_name = "state.json";
const state_tmp_file_name = "state.json.tmp";

/// Cap on how much of a state file we will ever read. A state file is a few
/// dozen bytes of JSON; anything past this is corruption or a hostile file,
/// not data we should try to hold in memory.
const state_read_limit: std.Io.Limit = .limited(64 * 1024);

/// Parses `bytes` into a `State`. Tolerates unknown fields, so a state file
/// written by a newer version of this program still loads under an older
/// one, but rejects malformed JSON outright: `error.SyntaxError` and friends
/// propagate rather than silently producing a zeroed `State`. `load` is the
/// layer that turns "corrupt" into "absent."
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !State {
    return std.json.parseFromSliceLeaky(State, arena, bytes, .{
        .ignore_unknown_fields = true,
    });
}

/// Serializes `state` to indented JSON. The result is allocated from `arena`
/// and lives as long as `arena` does.
pub fn serialize(arena: std.mem.Allocator, state: State) ![]u8 {
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(state, .{ .whitespace = .indent_2 })});
}

/// Loads state from `dir_path/state.json`. Returns `null` for any failure
/// along the way: missing directory, missing file, unreadable file, or
/// corrupt JSON. A cache miss is never fatal to a caller, it is always
/// treated as a cold start, so `load` collapses every failure mode into one
/// signal instead of forcing every caller to match on file-not-found versus
/// parse errors.
pub fn load(io: std.Io, arena: std.mem.Allocator, dir_path: []const u8) ?State {
    std.debug.assert(dir_path.len > 0);
    const path = std.fs.path.join(arena, &.{ dir_path, state_file_name }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        state_read_limit,
    ) catch return null;
    return parse(arena, bytes) catch null;
}

/// Saves `state` to `dir_path/state.json`, creating `dir_path` (and any
/// missing parents) as needed. Writes to a temp file first and renames it
/// into place, so a reader calling `load` concurrently either sees the old
/// file or the new one in full, never a partial write.
pub fn save(io: std.Io, arena: std.mem.Allocator, dir_path: []const u8, state: State) !void {
    std.debug.assert(dir_path.len > 0);
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    const bytes = try serialize(arena, state);
    const tmp_path = try std.fs.path.join(arena, &.{ dir_path, state_tmp_file_name });
    const final_path = try std.fs.path.join(arena, &.{ dir_path, state_file_name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = bytes });
    try std.Io.Dir.cwd().rename(tmp_path, .cwd(), final_path, io);
}

/// Resolves the directory the state file lives in: `GAUGE_STATE_DIR` if set,
/// else `$XDG_STATE_HOME/gauge`, else `$HOME/.local/state/gauge`. Does not
/// create the directory; `save` does that.
///
/// An empty value for any of the three variables is treated as unset rather
/// than as an explicit empty path: an empty env var is operational input
/// (e.g. `GAUGE_STATE_DIR=` in a launched shell), not a programmer error, so
/// it falls through to the next source instead of producing a zero-length
/// `dir_path` that would later trip the assert in `load`/`save`.
pub fn stateDirPath(arena: std.mem.Allocator) ![]u8 {
    if (try envVarOwned(arena, "GAUGE_STATE_DIR")) |explicit| {
        if (explicit.len > 0) return explicit;
    }
    if (try envVarOwned(arena, "XDG_STATE_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(arena, &.{ xdg, "gauge" });
    }
    const home = try envVarOwned(arena, "HOME") orelse return error.HomeNotSet;
    if (home.len == 0) return error.HomeNotSet;
    return std.fs.path.join(arena, &.{ home, ".local", "state", "gauge" });
}

// NOTE: `std.process` in this Zig version (0.17.0-dev.704) has no free-standing
// "read one environment variable" function comparable to the old
// `getEnvVarOwned`. Environment access now flows through `std.process.Init`,
// threaded in from `main`'s parameter, via `Environ`/`Environ.Map`. That does
// not fit `stateDirPath`'s committed signature, `fn (arena) ![]u8`, which later
// tasks call with no environment handle to pass in. Reconciled by reading
// libc's `environ` global directly, which requires linking libc (added in
// `build.zig`). This mirrors what `std.process.Init`'s own startup path does
// internally on WASI/Emscripten (see `std.process.Environ.createMap`), just
// without the intermediate `Init` plumbing this module's interface has no
// room for.
///
/// Reads a single environment variable by walking libc's `environ` global,
/// returning a copy owned by `arena`. `null` means the variable is entirely
/// unset; an explicitly empty value comes back as a zero-length slice, not
/// `null`, so callers that want to treat empty as unset (see `stateDirPath`)
/// do that themselves rather than losing the distinction here. `pub` so
/// `creds.zig` can reuse it for `GAUGE_CREDENTIALS`/`HOME` instead of
/// duplicating the `environ` walk.
pub fn envVarOwned(arena: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!?[]u8 {
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const entry_slice = std.mem.span(entry);
        const eq_index = std.mem.indexOfScalar(u8, entry_slice, '=') orelse continue;
        if (!std.mem.eql(u8, entry_slice[0..eq_index], key)) continue;
        return try arena.dupe(u8, entry_slice[eq_index + 1 ..]);
    }
    return null;
}

test "state json round trip preserves all fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original = State{
        .fetched_at = 1783275851,
        .five_hour = .{ .utilization = 0.45, .resets_at = 1783290900 },
        .seven_day = .{ .utilization = 0.62, .resets_at = 1783382400 },
        .last_status = .rate_limited,
        .backoff_until = 1783276151,
        .backoff_level = 2,
    };
    const bytes = try serialize(arena, original);
    const parsed = try parse(arena, bytes);
    try testing.expectEqual(original, parsed);
}

test "parse rejects garbage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.SyntaxError, parse(arena_state.allocator(), "not json"));
}

test "parse tolerates unknown fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parse(arena_state.allocator(),
        \\{"fetched_at": 5, "future_field": true}
    );
    try testing.expectEqual(@as(i64, 5), parsed.fetched_at);
}

// NOTE: exercises the `envVarOwned` reconciliation from a fresh angle since the
// round trip tests below never touch `stateDirPath`. `setenv`/`unsetenv` are not
// wrapped in `std.c`, so they are declared locally; this is safe because the
// libc `environ` global these mutate is exactly what `envVarOwned` reads.
test "stateDirPath honors GAUGE_STATE_DIR when set" {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    std.debug.assert(c.setenv("GAUGE_STATE_DIR", "/tmp/gauge-test-state-dir", 1) == 0);
    defer std.debug.assert(c.unsetenv("GAUGE_STATE_DIR") == 0);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const path = try stateDirPath(arena_state.allocator());
    try testing.expectEqualStrings("/tmp/gauge-test-state-dir", path);
}

// NOTE: an empty-but-set `GAUGE_STATE_DIR=` is operational input (e.g. a
// launched shell with the variable exported empty), not a programmer error,
// so it must fall through to the next source rather than flow into `load`/
// `save`'s `dir_path.len > 0` assert as an empty path.
test "stateDirPath treats empty GAUGE_STATE_DIR as unset" {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    std.debug.assert(c.setenv("GAUGE_STATE_DIR", "", 1) == 0);
    defer std.debug.assert(c.unsetenv("GAUGE_STATE_DIR") == 0);
    std.debug.assert(c.setenv("XDG_STATE_HOME", "/tmp/gauge-test-xdg-state-home", 1) == 0);
    defer std.debug.assert(c.unsetenv("XDG_STATE_HOME") == 0);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const path = try stateDirPath(arena_state.allocator());
    try testing.expectEqualStrings("/tmp/gauge-test-xdg-state-home/gauge", path);
}

test "save then load round trips through disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const original = State{
        .fetched_at = 42,
        .five_hour = .{ .utilization = 0.1, .resets_at = 100 },
        .seven_day = .{ .utilization = 0.2, .resets_at = 200 },
        .last_status = .ok,
        .backoff_until = 0,
        .backoff_level = 0,
    };
    try save(testing.io, arena, dir_path, original);
    const loaded = load(testing.io, arena, dir_path) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(original, loaded);
}

test "load returns null when the state file is missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    try testing.expect(load(testing.io, arena, dir_path) == null);
}

test "load returns null when the state file is corrupt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    try tmp.dir.writeFile(testing.io, .{ .sub_path = state_file_name, .data = "not json" });
    try testing.expect(load(testing.io, arena, dir_path) == null);
}
