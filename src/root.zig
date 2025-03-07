const bencode = @import("bencode.zig");
const torrent = @import("torrent.zig");

pub const ParsingError = bencode.ParsingError;
pub const readTorrentFile = torrent.readTorrentFile;
