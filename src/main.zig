const std = @import("std");
const Io = std.Io;

// NOTE: The brief's `main() !void` and `File.stdout().writer(&buf)` do not match this
// Zig version. 0.17.0-dev.704+b8cb78023 threads an `Io` instance through `std.process.Init`
// rather than a bare no-argument `main`, and `File.writer` now takes that `Io` explicitly.
// Reconciled against `/home/moe/zig/lib/init/src/main.zig`, the current `zig init` template.
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [256]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout_writer = &stdout_file_writer.interface;

    try stdout_writer.writeAll("gauge 0.1.0\n");
    try stdout_writer.flush();
}
