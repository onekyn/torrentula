const std = @import("std");
const Allocator = std.mem.Allocator;
const bencode = @import("bencode.zig");

/// Represents the data stored in a torrent file
pub const TorrentData = struct {
    announce: []const u8, // The URL to which we need to announce our existence as peers
    file_name: []const u8, // The name of the file we are torrenting
    file_length: i64, // The final size of the file we are torrenting
    info_hash: [20]u8, // The SHA1 hash of the "info" dictionary
    piece_length: i64, // The length of each piece
    piece_hashes: [][20]u8, // The SHA1 hashes of all the pieces

    /// Construct a TorrentData from a BencodeData
    fn fromBencodeData(allocator: Allocator, bencode_data: bencode.BencodeData) !TorrentData {
        const info = bencode_data.dict.get("info").?;
        const announce = bencode_data.dict.get("announce").?.str;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const arena_allocator = arena.allocator();
        defer arena.deinit();

        // Re-encode the info dictionary so that we can hash it
        var info_encoded = std.ArrayList(u8).init(arena_allocator);
        try info.encode(arena_allocator, &info_encoded);

        // Compute SHA1 hash
        var info_hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(info_encoded.items, &info_hash, .{});

        // Extract piece hashes
        const pieces = info.dict.get("pieces").?.str;
        const number_of_pieces = pieces.len / 20;
        var piece_hashes = try allocator.alloc([20]u8, number_of_pieces);
        for (0..number_of_pieces) |i| {
            @memcpy(&piece_hashes[i], pieces[i * 20 .. (i + 1) * 20]);
        }

        return TorrentData{
            .announce = try allocator.dupe(u8, announce),
            .file_name = try allocator.dupe(u8, info.dict.get("name").?.str),
            .file_length = info.dict.get("length").?.int,
            .info_hash = info_hash,
            .piece_length = info.dict.get("piece length").?.int,
            .piece_hashes = piece_hashes,
        };
    }

    /// Frees all the memory allocated with this TorrentData
    pub fn deinit(self: *TorrentData, allocator: Allocator) void {
        allocator.free(self.announce);
        allocator.free(self.file_name);
        allocator.free(self.piece_hashes);
    }

    /// Prints a human-readable representation of the data
    pub fn debugPrint(self: TorrentData) void {
        std.debug.print("Announce: {s}\n", .{self.announce});
        std.debug.print("File: {s} ({d} bytes)\n", .{ self.file_name, self.file_length });

        std.debug.print("Hash: ", .{});
        for (self.info_hash) |byte| std.debug.print("{x:0>2}", .{byte});
        std.debug.print("\n", .{});

        std.debug.print("Pieces: {d} ({d} bytes each)\n", .{ self.piece_hashes.len, self.piece_length });
    }
};

/// Read a torrent file from the file system
pub fn readTorrentFile(allocator: Allocator, file_path: []const u8) !TorrentData {
    var bencode_data = try bencode.parseFile(allocator, file_path);
    defer bencode_data.deinit(allocator);
    return TorrentData.fromBencodeData(allocator, bencode_data);
}
