//! `gauge setup-waybar`: wires the `custom/gauge` module into a stock waybar
//! config and stylesheet automatically, so the README can offer a true
//! one-line setup path. Two layers: pure text transforms (`editConfig`,
//! `editCss`) that a caller can unit test without touching a filesystem, and
//! `run`, the impure driver that reads the real files, backs them up, calls
//! the transforms, and writes the result. Safety over cleverness throughout:
//! `editConfig` refuses rather than guesses when the config's shape is
//! unfamiliar, and `run` never writes a file it has not first backed up.

const std = @import("std");
const state = @import("state.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Cap on how much of a waybar config or stylesheet we will ever read. Both
/// files are a few kilobytes in a real setup; anything past this is not a
/// file `editConfig`/`editCss` should try to parse.
const read_limit: Io.Limit = .limited(1024 * 1024);

pub const config_file_name = "config.jsonc";
pub const style_file_name = "style.css";

/// Outcome of editing config.jsonc's text.
pub const ConfigOutcome = union(enum) {
    /// `"custom/gauge"` was already present; `text` was not touched.
    already_done,
    /// The module is wired in; carries the full new text.
    edited: []const u8,
};

/// Reasons `editConfig` refuses to touch a config: its `modules-right` array
/// is missing or does not match the flat, single-level shape the insertion
/// logic knows how to edit safely.
pub const ConfigError = error{
    NoModulesRight,
    NoCloseBracket,
    NestedBracket,
    /// A `//` or `/*` comment sits between the array's `]` and the comma (or
    /// where a comma would go). Rewriting around a comment safely needs a
    /// real jsonc parser; refusing is simpler and safer than guessing.
    CommentAdjacentComma,
};

/// The module definition inserted right after the `modules-right` array,
/// verbatim per the brief's contract, matching the README's manual snippet.
/// `format` prefixes the rendered text with U+2731 HEAVY ASTERISK, a
/// Claude-evoking spark, ahead of waybar's own `{}` substitution; it styles
/// how the module renders, not the JSON `gauge waybar` emits on stdout.
const module_block =
    "  \"custom/gauge\": {\n" ++
    "    \"exec\": \"gauge waybar\",\n" ++
    "    \"return-type\": \"json\",\n" ++
    "    \"interval\": 30,\n" ++
    "    \"tooltip\": true,\n" ++
    "    \"format\": \"\u{2731} {}\"\n" ++
    "  },";

/// Pure text transform: wires `"custom/gauge"` into `text`'s `modules-right`
/// array as the first entry, then inserts `module_block` right after the
/// array, or reports the edit is already done.
///
/// Locates the array via `findModulesRightOpen`, then the next `]`. Module
/// name arrays contain no nested brackets in a stock config (they are flat
/// lists of strings), so a `[` found before that `]` means the shape is not
/// what this function knows how to edit, and it refuses via `ConfigError`
/// rather than guess. This is the safety boundary the brief calls out: `run`
/// calls this once and never retries with a looser rule on refusal.
pub fn editConfig(
    arena: Allocator,
    text: []const u8,
) (ConfigError || Allocator.Error)!ConfigOutcome {
    if (alreadyHasCustomGauge(text)) return .already_done;

    const open = findModulesRightOpen(text) orelse return error.NoModulesRight;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, ']') orelse
        return error.NoCloseBracket;
    if (std.mem.indexOfScalarPos(u8, text, open + 1, '[')) |nested| {
        if (nested < close) return error.NestedBracket;
    }

    const inner_is_empty = std.mem.trim(u8, text[open + 1 .. close], " \t\r\n").len == 0;
    const entry = if (inner_is_empty) "\"custom/gauge\"" else "\"custom/gauge\", ";
    // NOTE: when `modules-right` has no following key (it is the object's
    // last field, uncommon but possible in a hand-trimmed config), the
    // "append a comma if missing" step below plus `module_block`'s own
    // trailing comma leaves a trailing comma before the object's closing
    // `}`. Strict JSON forbids that; waybar's jsonc parser tolerates it in
    // practice, and the brief's insertion algorithm is followed verbatim
    // here rather than special-cased, since second-guessing it would mean
    // silently deviating from a documented, deliberate contract.
    const with_entry = try std.mem.concat(arena, u8, &.{
        text[0 .. open + 1],
        entry,
        text[open + 1 ..],
    });

    // `close` was an index into `text`; inserting `entry` right after `open`
    // shifts everything from `open + 1` onward by `entry.len` in `with_entry`.
    const close_shifted = close + entry.len;
    std.debug.assert(close_shifted < with_entry.len);
    std.debug.assert(with_entry[close_shifted] == ']');

    const after_bracket = close_shifted + 1;
    const ws_end = skipWhitespace(with_entry, after_bracket);
    // A `//` or `/*` comment between the array's `]` and its comma (or where
    // a comma would go) means this function cannot tell, from text alone,
    // whether a comma already follows without also parsing the comment.
    // Guessing wrong emits either a missing or a doubled comma, both of
    // which fail waybar's jsoncpp parser silently from gauge's point of
    // view, so this refuses rather than rewrite around a comment.
    if (ws_end + 1 < with_entry.len and with_entry[ws_end] == '/' and
        (with_entry[ws_end + 1] == '/' or with_entry[ws_end + 1] == '*'))
    {
        return error.CommentAdjacentComma;
    }
    const has_comma = ws_end < with_entry.len and with_entry[ws_end] == ',';
    const insert_at = if (has_comma) ws_end + 1 else after_bracket;
    // A comma already follows the array (the common case: modules-right is
    // rarely the object's last key) inserts right after it. Otherwise one is
    // added here, ahead of the newline and the block, per the brief.
    const prefix = if (has_comma) "\n" else ",\n";

    const final = try std.mem.concat(arena, u8, &.{
        with_entry[0..insert_at],
        prefix,
        module_block,
        with_entry[insert_at..],
    });
    return .{ .edited = final };
}

/// Advances `start` over ASCII whitespace in `text`, bounded by `text.len`.
fn skipWhitespace(text: []const u8, start: usize) usize {
    std.debug.assert(start <= text.len);
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    return i;
}

/// Finds the `[` that opens the real `modules-right` array's value, or
/// `null` if none qualifies.
///
/// A raw substring search for `"modules-right"` is hijacked by an earlier
/// comment or string value that happens to contain that text (a `[` inside
/// or before such a false match would then be mistaken for the array's own
/// bracket). This instead walks every occurrence of the key text in order
/// and accepts the first one followed, modulo whitespace, by `:` and then
/// `[`, the shape only a real `"modules-right": [...]` key has. The loop is
/// bounded: `search_from` strictly increases toward `text.len` every
/// iteration, so it terminates within `text.len` steps even on pathological
/// input.
fn findModulesRightOpen(text: []const u8) ?usize {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, "\"modules-right\"")) |key_idx| {
        const after_key = key_idx + "\"modules-right\"".len;
        const colon_at = skipWhitespace(text, after_key);
        if (colon_at < text.len and text[colon_at] == ':') {
            const bracket_at = skipWhitespace(text, colon_at + 1);
            if (bracket_at < text.len and text[bracket_at] == '[') return bracket_at;
        }
        search_from = key_idx + 1;
    }
    return null;
}

/// Reports whether `text` already has a real `"custom/gauge"` entry: a
/// module definition key (`"custom/gauge":`) or an array entry (preceded by
/// `[` or `,` and followed by `,` or `]`, modulo whitespace on either side).
///
/// A raw substring search treats `"custom/gauge"` inside a comment (`// see
/// "custom/gauge" below`) as proof the setup is already done, which then
/// skips the real edit forever. This walks every occurrence in order and
/// only accepts one that has the shape of a real key or array entry, same
/// bounded-loop approach as `findModulesRightOpen`.
fn alreadyHasCustomGauge(text: []const u8) bool {
    const key = "\"custom/gauge\"";
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, key)) |idx| {
        const after = idx + key.len;
        const ws_end = skipWhitespace(text, after);
        const is_key = ws_end < text.len and text[ws_end] == ':';
        const followed_like_entry = ws_end < text.len and
            (text[ws_end] == ',' or text[ws_end] == ']');
        var before = idx;
        while (before > 0 and std.ascii.isWhitespace(text[before - 1])) : (before -= 1) {}
        const preceded_like_entry = before > 0 and
            (text[before - 1] == '[' or text[before - 1] == ',');
        if (is_key or (followed_like_entry and preceded_like_entry)) return true;
        search_from = idx + 1;
    }
    return false;
}

/// Outcome of editing style.css's text.
pub const CssOutcome = union(enum) {
    /// `#custom-gauge` was already present; `text` was not touched.
    already_done,
    /// The CSS block is appended; carries the full new text.
    edited: []const u8,
};

/// The CSS block appended to style.css, verbatim per the brief's contract:
/// padding, the `warn`/`critical` colors, and the `stale` opacity.
const css_block =
    "#custom-gauge { padding: 0 8px; }\n" ++
    "#custom-gauge.warn { color: #e5c07b; }\n" ++
    "#custom-gauge.critical { color: #e06c75; }\n" ++
    "#custom-gauge.stale { opacity: 0.6; }\n";

/// Pure text transform: appends `css_block` to `text`, preceded by a blank
/// line, or reports the edit is already done. Empty `text` (a missing or
/// empty style.css, waybar tolerates either) gets just the block with no
/// leading blank line. Never refuses: unlike `editConfig` there is no
/// structure to misparse, an append is always safe.
pub fn editCss(arena: Allocator, text: []const u8) Allocator.Error!CssOutcome {
    if (std.mem.indexOf(u8, text, "#custom-gauge") != null) return .already_done;
    if (text.len == 0) return .{ .edited = css_block };
    const sep = if (std.mem.endsWith(u8, text, "\n")) "\n" else "\n\n";
    const final = try std.mem.concat(arena, u8, &.{ text, sep, css_block });
    return .{ .edited = final };
}

/// Resolves the waybar config directory: `GAUGE_WAYBAR_DIR` if set to a
/// non-empty value, else `$HOME/.config/waybar`. Mirrors
/// `state.stateDirPath`'s treatment of an empty-but-set variable as unset
/// rather than an explicit empty path.
pub fn waybarDirPath(arena: Allocator) ![]u8 {
    if (try state.envVarOwned(arena, "GAUGE_WAYBAR_DIR")) |explicit| {
        if (explicit.len > 0) return explicit;
    }
    const home = try state.envVarOwned(arena, "HOME") orelse return error.HomeNotSet;
    if (home.len == 0) return error.HomeNotSet;
    return std.fs.path.join(arena, &.{ home, ".config", "waybar" });
}

/// Result of `run`. `main.zig` prints `ok` to stdout and exits 0, or
/// `refused` to stderr and exits 2; the message already carries everything
/// the user needs, so the dispatcher does no further formatting.
pub const Result = union(enum) {
    ok: []const u8,
    refused: []const u8,
};

/// The manual fallback, printed on every refusal: the same snippets the
/// README documents under "Manual setup", so a refusal never leaves the user
/// without a path forward.
const manual_instructions =
    \\Add "custom/gauge" to a modules array (e.g. "modules-right") in
    \\config.jsonc, and merge this object in beside it:
    \\
    \\  "custom/gauge": {
    \\    "exec": "gauge waybar",
    \\    "return-type": "json",
    \\    "interval": 30,
    \\    "tooltip": true,
    \\    "format": "✱ {}"
    \\  }
    \\
    \\Then add this block to style.css:
    \\
    \\  #custom-gauge { padding: 0 8px; }
    \\  #custom-gauge.warn { color: #e5c07b; }
    \\  #custom-gauge.critical { color: #e06c75; }
    \\  #custom-gauge.stale { opacity: 0.6; }
    \\
    \\Reload waybar after wiring both in (pkill waybar; waybar &, or your
    \\compositor's restart mechanism).
    \\
;

/// Backs up `text` (the file's current contents) to `<name>.bak.<now>` next
/// to `path`, then atomically replaces `path` with `new_text`: a temp file is
/// written first and renamed into place, so a reader or a crash mid-write
/// never sees a partial file. The backup is written before either, so a
/// failure at any later step still leaves the original content recoverable.
///
/// NOTE: this writes `text` from memory rather than calling
/// `Io.Dir.copyFile`, since the caller already holds `text` from the read
/// that fed `editConfig`/`editCss`; `copyFile` would re-open and re-read a
/// file already in hand.
///
/// LIMITATION: if `path` is itself a symlink, `rename` replaces the symlink
/// with a regular file rather than writing through it to the link's target;
/// out of scope here, and not addressed.
fn backupAndWrite(
    io: Io,
    arena: Allocator,
    dir_path: []const u8,
    name: []const u8,
    now: i64,
    text: []const u8,
    new_text: []const u8,
) !void {
    std.debug.assert(now >= 0);
    const backup_name = try std.fmt.allocPrint(arena, "{s}.bak.{d}", .{ name, now });
    const backup_path = try std.fs.path.join(arena, &.{ dir_path, backup_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = backup_path, .data = text });

    const path = try std.fs.path.join(arena, &.{ dir_path, name });
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = new_text });
    try Io.Dir.cwd().rename(tmp_path, .cwd(), path, io);
}

/// Writes `new_text` to `dir_path/name` atomically, with no preceding
/// backup: used only when the file did not previously exist, so there is
/// nothing to back up.
///
/// LIMITATION: same symlink caveat as `backupAndWrite`, see its doc comment.
fn writeNew(
    io: Io,
    arena: Allocator,
    dir_path: []const u8,
    name: []const u8,
    new_text: []const u8,
) !void {
    const path = try std.fs.path.join(arena, &.{ dir_path, name });
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = new_text });
    try Io.Dir.cwd().rename(tmp_path, .cwd(), path, io);
}

/// Reads `dir_path/config.jsonc` and `dir_path/style.css`, wires the gauge
/// module into both via `editConfig`/`editCss`, and reports what it did.
/// `now` (Unix epoch seconds) seeds backup filenames' timestamp suffix.
///
/// A missing config.jsonc (`error.FileNotFound`) is a refusal: waybar is not
/// set up at `dir_path`, or `dir_path` is wrong, and there is nothing safe
/// to edit. Any other config.jsonc read error (permission denied, a
/// dangling symlink, a file past `read_limit`) is also a refusal, since only
/// `FileNotFound` means "nothing is here to overwrite"; every other error
/// means a real file exists and could not be read, and treating that as
/// "missing" would silently discard it on write. A missing style.css is not
/// a refusal, `editCss` handles it directly by treating it as empty; other
/// style.css read errors refuse for the same reason as config.jsonc. A
/// config that fails `editConfig` (unfamiliar shape) is also a refusal, and
/// nothing is written, not even to style.css: a half-applied setup is worse
/// than none.
///
/// LIMITATION: two concurrent `run` calls against the same `dir_path` are
/// not locked against each other; out of scope here, and not addressed.
pub fn run(io: Io, arena: Allocator, dir_path: []const u8, now: i64) !Result {
    std.debug.assert(dir_path.len > 0);
    std.debug.assert(now >= 0);

    const config_path = try std.fs.path.join(arena, &.{ dir_path, config_file_name });
    const config_read = Io.Dir.cwd().readFileAlloc(io, config_path, arena, read_limit);
    const config_text = config_read catch |err| switch (err) {
        error.FileNotFound => return .{ .refused = try std.fmt.allocPrint(
            arena,
            "gauge: no config.jsonc found at {s}\n\n{s}",
            .{ config_path, manual_instructions },
        ) },
        else => return .{ .refused = try std.fmt.allocPrint(
            arena,
            "gauge: could not read {s} ({s}), refusing to edit it\n\n{s}",
            .{ config_path, @errorName(err), manual_instructions },
        ) },
    };

    const config_outcome = editConfig(arena, config_text) catch |err| {
        return .{ .refused = try std.fmt.allocPrint(
            arena,
            "gauge: {s} does not look like a stock waybar config ({s}), refusing to edit it\n\n{s}",
            .{ config_path, @errorName(err), manual_instructions },
        ) };
    };

    const style_path = try std.fs.path.join(arena, &.{ dir_path, style_file_name });
    const style_read = Io.Dir.cwd().readFileAlloc(io, style_path, arena, read_limit);
    const style_text: ?[]const u8 = style_read catch |err| switch (err) {
        error.FileNotFound => null,
        else => return .{ .refused = try std.fmt.allocPrint(
            arena,
            "gauge: could not read {s} ({s}), refusing to edit it\n\n{s}",
            .{ style_path, @errorName(err), manual_instructions },
        ) },
    };
    const css_outcome = try editCss(arena, style_text orelse "");

    // Up to two lines per file (backed up, then edited) plus the closing
    // reload reminder.
    var lines: [5][]const u8 = undefined;
    var n: usize = 0;

    switch (config_outcome) {
        .already_done => {
            lines[n] = "config.jsonc already has the custom/gauge module";
            n += 1;
        },
        .edited => |new_text| {
            try backupAndWrite(io, arena, dir_path, config_file_name, now, config_text, new_text);
            lines[n] = try std.fmt.allocPrint(
                arena,
                "backed up {s}.bak.{d}",
                .{ config_path, now },
            );
            n += 1;
            lines[n] = "added the custom/gauge module to config.jsonc";
            n += 1;
        },
    }

    switch (css_outcome) {
        .already_done => {
            lines[n] = "style.css already has the custom/gauge styles";
            n += 1;
        },
        .edited => |new_text| {
            if (style_text) |original| {
                try backupAndWrite(io, arena, dir_path, style_file_name, now, original, new_text);
                lines[n] = try std.fmt.allocPrint(
                    arena,
                    "backed up {s}.bak.{d}",
                    .{ style_path, now },
                );
                n += 1;
                lines[n] = "appended the gauge styles to style.css";
                n += 1;
            } else {
                try writeNew(io, arena, dir_path, style_file_name, new_text);
                lines[n] = "created style.css with the gauge styles";
                n += 1;
            }
        },
    }

    lines[n] = "reload waybar to pick this up: pkill waybar; waybar &, or your " ++
        "compositor's restart mechanism";
    n += 1;

    std.debug.assert(n <= lines.len);
    const joined = try std.mem.join(arena, "\n", lines[0..n]);
    return .{ .ok = try std.fmt.allocPrint(arena, "{s}\n", .{joined}) };
}

test "editConfig inserts module first in a multi-line modules-right with other custom modules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fixture =
        \\{
        \\  "layer": "top",
        \\  "modules-left": ["hyprland/workspaces"],
        \\  "modules-right": [
        \\    "custom/updates",
        \\    "network",
        \\    "pulseaudio",
        \\    "battery",
        \\    "clock"
        \\  ],
        \\  "custom/updates": {
        \\    "exec": "some-script.sh",
        \\    "interval": 3600
        \\  },
        \\  "clock": {
        \\    "format": "{:%H:%M}"
        \\  }
        \\}
    ;
    const outcome = try editConfig(arena_state.allocator(), fixture);
    const edited = switch (outcome) {
        .edited => |t| t,
        .already_done => return error.TestUnexpectedResult,
    };

    // The array's first entry is now custom/gauge, formatting around it
    // otherwise untouched (inserted right after "[", the brief's contract).
    try testing.expect(
        std.mem.indexOf(u8, edited, "[\"custom/gauge\", \n    \"custom/updates\"") != null,
    );
    // Exactly one module object was inserted.
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, edited, pos, "\"custom/gauge\": {")) |found| {
        count += 1;
        pos = found + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(std.mem.indexOf(u8, edited, "\"exec\": \"gauge waybar\"") != null);
    // The module renders with a Claude-evoking spark prefix ahead of
    // waybar's own `{}` substitution.
    try testing.expect(std.mem.indexOf(u8, edited, "\"format\": \"\u{2731} {}\"") != null);
}

test "editConfig handles a minimal single-line modules-right" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try editConfig(arena_state.allocator(), "{\"modules-right\": [\"clock\"]}");
    const edited = switch (outcome) {
        .edited => |t| t,
        .already_done => return error.TestUnexpectedResult,
    };
    try testing.expect(
        std.mem.indexOf(u8, edited, "\"modules-right\": [\"custom/gauge\", \"clock\"]") != null,
    );
    try testing.expect(std.mem.indexOf(u8, edited, "\"custom/gauge\": {") != null);
}

test "editConfig handles an empty modules-right array" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try editConfig(arena_state.allocator(), "{\"modules-right\": []}");
    const edited = switch (outcome) {
        .edited => |t| t,
        .already_done => return error.TestUnexpectedResult,
    };
    try testing.expect(
        std.mem.indexOf(u8, edited, "\"modules-right\": [\"custom/gauge\"]") != null,
    );
}

test "editConfig reports already done and leaves text untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fixture = "{\"modules-right\": [\"custom/gauge\", \"clock\"], \"custom/gauge\": {}}";
    const outcome = try editConfig(arena_state.allocator(), fixture);
    try testing.expectEqual(ConfigOutcome.already_done, outcome);
}

test "editConfig refuses when modules-right is absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(
        error.NoModulesRight,
        editConfig(arena_state.allocator(), "{\"modules-left\": [\"clock\"]}"),
    );
}

test "editConfig refuses on a nested bracket before the array closes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(
        error.NestedBracket,
        editConfig(arena_state.allocator(), "{\"modules-right\": [\"a\", [\"b\"]]}"),
    );
}

test "editConfig refuses rather than rewrite around a comment before the comma" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fixture =
        \\{
        \\  "modules-right": ["clock"] /* comment */,
        \\  "clock": {}
        \\}
    ;
    try testing.expectError(
        error.CommentAdjacentComma,
        editConfig(arena_state.allocator(), fixture),
    );
}

test "editConfig locates the real modules-right past an earlier comment mentioning it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fixture =
        \\{
        \\  // tweak "modules-right" later
        \\  "modules-left": ["hyprland/workspaces"],
        \\  "modules-right": ["clock"]
        \\}
    ;
    const outcome = try editConfig(arena_state.allocator(), fixture);
    const edited = switch (outcome) {
        .edited => |t| t,
        .already_done => return error.TestUnexpectedResult,
    };

    // The comment's own array-free "modules-right" mention did not hijack
    // the insertion point: modules-left is untouched, and gauge landed
    // first in the real modules-right.
    try testing.expect(
        std.mem.indexOf(u8, edited, "\"modules-left\": [\"hyprland/workspaces\"]") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, edited, "\"modules-right\": [\"custom/gauge\", \"clock\"]") != null,
    );
}

test "editConfig does not treat a comment mentioning custom/gauge as already done" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fixture =
        \\{
        \\  // wire up "custom/gauge" later
        \\  "modules-right": ["clock"]
        \\}
    ;
    const outcome = try editConfig(arena_state.allocator(), fixture);
    const edited = switch (outcome) {
        .edited => |t| t,
        .already_done => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, edited, "\"custom/gauge\": {") != null);
}

test "editCss appends the block to empty text with no leading blank line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try editCss(arena_state.allocator(), "");
    const edited = switch (outcome) {
        .edited => |t| t,
        .already_done => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.startsWith(u8, edited, "#custom-gauge { padding: 0 8px; }"));
}

test "editCss appends the block to existing text preceded by a blank line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try editCss(arena_state.allocator(), "#workspaces { margin: 0; }\n");
    const edited = switch (outcome) {
        .edited => |t| t,
        .already_done => return error.TestUnexpectedResult,
    };
    try testing.expect(
        std.mem.indexOf(u8, edited, "#workspaces { margin: 0; }\n\n#custom-gauge") != null,
    );
}

test "editCss reports already done and leaves text untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try editCss(arena_state.allocator(), "#custom-gauge { padding: 0; }\n");
    try testing.expectEqual(CssOutcome.already_done, outcome);
}

// NOTE: mirrors the `setenv`/`unsetenv` reconciliation from `state.zig`'s
// `stateDirPath` tests. `std.c` does not wrap these, so they are declared
// locally, and doing so is safe because the libc `environ` global they
// mutate is exactly what `envVarOwned` (reused from `state.zig`) reads.
test "waybarDirPath honors GAUGE_WAYBAR_DIR when set" {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    std.debug.assert(c.setenv("GAUGE_WAYBAR_DIR", "/tmp/gauge-test-waybar-dir", 1) == 0);
    defer std.debug.assert(c.unsetenv("GAUGE_WAYBAR_DIR") == 0);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const path = try waybarDirPath(arena_state.allocator());
    try testing.expectEqualStrings("/tmp/gauge-test-waybar-dir", path);
}

test "waybarDirPath treats empty GAUGE_WAYBAR_DIR as unset and falls back to HOME" {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    std.debug.assert(c.setenv("GAUGE_WAYBAR_DIR", "", 1) == 0);
    defer std.debug.assert(c.unsetenv("GAUGE_WAYBAR_DIR") == 0);
    std.debug.assert(c.setenv("HOME", "/tmp/gauge-test-home", 1) == 0);
    defer std.debug.assert(c.unsetenv("HOME") == 0);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const path = try waybarDirPath(arena_state.allocator());
    try testing.expectEqualStrings("/tmp/gauge-test-home/.config/waybar", path);
}

test "run refuses when config.jsonc is missing, writes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const result = try run(testing.io, arena, dir_path, 1_700_000_000);
    const refused = switch (result) {
        .refused => |m| m,
        .ok => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, refused, "no config.jsonc found") != null);

    var iterated = tmp.dir.iterate();
    try testing.expect((try iterated.next(testing.io)) == null);
}

test "run refuses on a config.jsonc read error that is not FileNotFound, writes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A config.jsonc past `read_limit` deterministically triggers
    // `error.StreamTooLong` rather than `error.FileNotFound`, exercising the
    // "real file exists but could not be read" path without needing
    // permission bits, which are not reliably testable in-process.
    const oversized = try arena.alloc(u8, 1024 * 1024 + 16);
    @memset(oversized, 'x');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = config_file_name, .data = oversized });

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const result = try run(testing.io, arena, dir_path, 1_700_000_000);
    const refused = switch (result) {
        .refused => |m| m,
        .ok => return error.TestUnexpectedResult,
    };
    // The message must name the real failure, not claim the file is
    // missing: it exists and gauge refused to read it.
    try testing.expect(std.mem.indexOf(u8, refused, "no config.jsonc found") == null);
    try testing.expect(std.mem.indexOf(u8, refused, "could not read") != null);
    try testing.expect(std.mem.indexOf(u8, refused, "StreamTooLong") != null);

    const big_limit: Io.Limit = .limited(2 * 1024 * 1024);
    const config_after = try tmp.dir.readFileAlloc(testing.io, config_file_name, arena, big_limit);
    try testing.expectEqualStrings(oversized, config_after);

    // Nothing but the oversized config.jsonc itself exists: no backup, no
    // style.css, nothing else was written.
    var found_extra = false;
    var iterated = tmp.dir.iterate();
    while (try iterated.next(testing.io)) |entry| {
        if (!std.mem.eql(u8, entry.name, config_file_name)) found_extra = true;
    }
    try testing.expect(!found_extra);
}

test "run refuses on a style.css read error that is not FileNotFound, writes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const config_data = "{\"modules-right\": [\"clock\"]}";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = config_file_name, .data = config_data });
    // See the config.jsonc test above: an oversized file deterministically
    // triggers `error.StreamTooLong`, standing in for any non-FileNotFound
    // read error (permission denied, a dangling symlink) that the old
    // `catch null` treated as "missing" and silently overwrote.
    const oversized = try arena.alloc(u8, 1024 * 1024 + 16);
    @memset(oversized, 'y');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = style_file_name, .data = oversized });

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const result = try run(testing.io, arena, dir_path, 1_700_000_000);
    const refused = switch (result) {
        .refused => |m| m,
        .ok => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, refused, "could not read") != null);
    try testing.expect(std.mem.indexOf(u8, refused, style_file_name) != null);
    try testing.expect(std.mem.indexOf(u8, refused, "StreamTooLong") != null);

    // Neither file was touched: config.jsonc was never written past its
    // read (no backup, no edit), and style.css was never overwritten with a
    // fresh stylesheet.
    const config_after = try tmp.dir.readFileAlloc(testing.io, config_file_name, arena, read_limit);
    try testing.expectEqualStrings(config_data, config_after);
    const big_limit: Io.Limit = .limited(2 * 1024 * 1024);
    const style_after = try tmp.dir.readFileAlloc(testing.io, style_file_name, arena, big_limit);
    try testing.expectEqualStrings(oversized, style_after);

    var found_extra = false;
    var iterated = tmp.dir.iterate();
    while (try iterated.next(testing.io)) |entry| {
        const is_config = std.mem.eql(u8, entry.name, config_file_name);
        const is_style = std.mem.eql(u8, entry.name, style_file_name);
        if (!is_config and !is_style) {
            found_extra = true;
        }
    }
    try testing.expect(!found_extra);
}

test "run refuses on a malformed config and writes nothing, not even to style.css" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = config_file_name,
        .data = "{\"modules-left\": [\"clock\"]}",
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = style_file_name, .data = "" });

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const result = try run(testing.io, arena, dir_path, 1_700_000_000);
    const refused = switch (result) {
        .refused => |m| m,
        .ok => return error.TestUnexpectedResult,
    };
    try testing.expect(
        std.mem.indexOf(u8, refused, "does not look like a stock waybar config") != null,
    );

    const style_after = try tmp.dir.readFileAlloc(testing.io, style_file_name, arena, read_limit);
    try testing.expectEqualStrings("", style_after);
}

test "run inserts the module and backs up both files, second run is a no-op" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = config_file_name,
        .data = "{\"modules-right\": [\"clock\"]}",
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = style_file_name, .data = "#workspaces {}\n" });

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const first = try run(testing.io, arena, dir_path, 1_700_000_000);
    const first_ok = switch (first) {
        .ok => |m| m,
        .refused => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, first_ok, "added the custom/gauge module") != null);
    try testing.expect(std.mem.indexOf(u8, first_ok, "appended the gauge styles") != null);

    const config_after = try tmp.dir.readFileAlloc(testing.io, config_file_name, arena, read_limit);
    try testing.expect(std.mem.indexOf(u8, config_after, "\"custom/gauge\"") != null);
    const style_after = try tmp.dir.readFileAlloc(testing.io, style_file_name, arena, read_limit);
    try testing.expect(std.mem.indexOf(u8, style_after, "#custom-gauge") != null);

    const config_backup = try tmp.dir.readFileAlloc(
        testing.io,
        try std.fmt.allocPrint(arena, "{s}.bak.1700000000", .{config_file_name}),
        arena,
        read_limit,
    );
    try testing.expectEqualStrings("{\"modules-right\": [\"clock\"]}", config_backup);

    const second = try run(testing.io, arena, dir_path, 1_700_000_100);
    const second_ok = switch (second) {
        .ok => |m| m,
        .refused => return error.TestUnexpectedResult,
    };
    try testing.expect(
        std.mem.indexOf(u8, second_ok, "already has the custom/gauge module") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, second_ok, "already has the custom/gauge styles") != null,
    );

    // No new backup was written on the idempotent second run.
    var found_second_backup = false;
    var iterated = tmp.dir.iterate();
    while (try iterated.next(testing.io)) |entry| {
        if (std.mem.indexOf(u8, entry.name, "bak.1700000100") != null) found_second_backup = true;
    }
    try testing.expect(!found_second_backup);
}
