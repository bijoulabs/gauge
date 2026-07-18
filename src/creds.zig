//! Credentials reader: locates and parses the Claude OAuth credentials file
//! (the one the `claude` CLI itself writes) to extract the access token gauge
//! needs to call the rate-limit endpoint. No refresh, no write path: gauge is
//! a read-only consumer of credentials another process owns.

const std = @import("std");
const state = @import("state.zig");
const testing = std.testing;

/// Cap on how much of a credentials file we will ever read. The real file is a
/// few hundred bytes of JSON; anything past this is corruption or a hostile
/// file planted at the path, not data we should try to hold in memory.
const creds_read_limit: std.Io.Limit = .limited(1024 * 1024);

/// Mirrors only the fields gauge reads from the live credentials file: a
/// top-level `claudeAiOauth` object holding `accessToken`. `refreshToken`,
/// `expiresAt`, `scopes`, `subscriptionType`, `rateLimitTier`, and the sibling
/// `mcpOAuth` tree are present in the real file but irrelevant here, so
/// `ignore_unknown_fields` lets `std.json` skip them rather than mapping every
/// field gauge does not use.
///
/// NOTE: `claudeAiOauth` deliberately breaks this repo's snake_case field
/// naming: it must match the JSON key verbatim for `std.json`'s struct
/// mapping to find it.
const CredsFile = struct {
    claudeAiOauth: ?struct { accessToken: ?[]const u8 = null } = null,
};

/// Parses `bytes` as a credentials file and returns the OAuth access token,
/// allocated from `arena`. Any shape that is not valid JSON, lacks
/// `claudeAiOauth`, lacks `accessToken`, or carries an empty token collapses
/// to `error.MalformedCredentials`: callers only need one signal for "this
/// file is not a usable credentials file," not a menu of JSON error variants.
pub fn extractAccessToken(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(CredsFile, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedCredentials;
    const oauth = parsed.claudeAiOauth orelse return error.MalformedCredentials;
    const token = oauth.accessToken orelse return error.MalformedCredentials;
    if (token.len == 0) return error.MalformedCredentials;
    return token;
}

/// Resolves the path to the credentials file: `GAUGE_CREDENTIALS` if set to a
/// non-empty value, else `$HOME/.claude/.credentials.json`. Empty variables
/// are unset and a missing `HOME` is `error.HomeNotSet`, per
/// `state.envVarNonEmpty` and `state.homePath`.
pub fn credentialsPath(arena: std.mem.Allocator) ![]u8 {
    if (try state.envVarNonEmpty(arena, "GAUGE_CREDENTIALS")) |explicit| return explicit;
    const home = try state.homePath(arena);
    return std.fs.path.join(arena, &.{ home, ".claude", ".credentials.json" });
}

/// Reads the credentials file at `path` and returns its OAuth access token,
/// allocated from `arena`. Collapses every read failure (missing file, denied
/// permissions, a directory instead of a file) into `error.NoCredentials`:
/// like `state.load`'s treatment of a missing state file, the caller only
/// needs one signal for "there is nothing usable here," not a menu of
/// `Io.Dir.ReadFileError` variants. A file that exists but does not parse
/// still surfaces as `error.MalformedCredentials` via `extractAccessToken`,
/// since that is a different, more actionable failure: the file is present
/// but the wrong shape.
pub fn readAccessToken(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, creds_read_limit) catch
        return error.NoCredentials;
    return extractAccessToken(arena, bytes);
}

test "extracts access token and ignores everything else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const token = try extractAccessToken(arena_state.allocator(),
        \\{"claudeAiOauth":{"accessToken":"tok-123","expiresAt":9,"scopes":["a"]},"mcpOAuth":{}}
    );
    try testing.expectEqualStrings("tok-123", token);
}

test "missing claudeAiOauth is MalformedCredentials" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(
        error.MalformedCredentials,
        extractAccessToken(arena_state.allocator(), "{}"),
    );
}

// NOTE: mirrors the `setenv`/`unsetenv` reconciliation from `state.zig`'s
// `stateDirPath` tests: `std.c` does not wrap these, so they are declared
// locally, and doing so is safe because the libc `environ` global they mutate
// is exactly what `envVarOwned` (reused from `state.zig`) reads.
test "credentialsPath honors GAUGE_CREDENTIALS when set" {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    std.debug.assert(c.setenv("GAUGE_CREDENTIALS", "/tmp/gauge-test-creds.json", 1) == 0);
    defer std.debug.assert(c.unsetenv("GAUGE_CREDENTIALS") == 0);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const path = try credentialsPath(arena_state.allocator());
    try testing.expectEqualStrings("/tmp/gauge-test-creds.json", path);
}

// NOTE: an empty-but-set `GAUGE_CREDENTIALS=` is operational input, not a
// programmer error, so it must fall through to the `HOME`-derived default
// rather than flow into `readAccessToken` as a zero-length path.
test "credentialsPath treats empty GAUGE_CREDENTIALS as unset" {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    std.debug.assert(c.setenv("GAUGE_CREDENTIALS", "", 1) == 0);
    defer std.debug.assert(c.unsetenv("GAUGE_CREDENTIALS") == 0);
    std.debug.assert(c.setenv("HOME", "/tmp/gauge-test-home", 1) == 0);
    defer std.debug.assert(c.unsetenv("HOME") == 0);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const path = try credentialsPath(arena_state.allocator());
    try testing.expectEqualStrings("/tmp/gauge-test-home/.claude/.credentials.json", path);
}

test "credentialsPath errors when neither GAUGE_CREDENTIALS nor HOME is set" {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    std.debug.assert(c.unsetenv("GAUGE_CREDENTIALS") == 0);
    std.debug.assert(c.setenv("HOME", "", 1) == 0);
    defer std.debug.assert(c.unsetenv("HOME") == 0);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.HomeNotSet, credentialsPath(arena_state.allocator()));
}

test "readAccessToken returns the token from a real file on disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "creds.json",
        .data =
        \\{"claudeAiOauth":{"accessToken":"tok-456"}}
        ,
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const path = try std.fs.path.join(arena, &.{ path_buf[0..dir_len], "creds.json" });

    const token = try readAccessToken(testing.io, arena, path);
    try testing.expectEqualStrings("tok-456", token);
}

test "readAccessToken returns NoCredentials when the file is missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const path = try std.fs.path.join(arena, &.{ path_buf[0..dir_len], "missing.json" });

    try testing.expectError(error.NoCredentials, readAccessToken(testing.io, arena, path));
}

test "readAccessToken returns MalformedCredentials for a corrupt file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "creds.json", .data = "not json" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const path = try std.fs.path.join(arena, &.{ path_buf[0..dir_len], "creds.json" });

    try testing.expectError(error.MalformedCredentials, readAccessToken(testing.io, arena, path));
}
