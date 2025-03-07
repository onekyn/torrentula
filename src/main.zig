const std = @import("std");
const torrentula = @import("torrentula");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("Memory Leak");
    }

    // Get the torrent file from the command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <torrent_file>\n\n", .{args[0]});
        std.debug.print("No torrent file provided.\n", .{});
        std.process.exit(1);
    }

    var torrent_data = try torrentula.readTorrentFile(allocator, args[1]);
    defer torrent_data.deinit(allocator);
    torrent_data.debugPrint();
}
