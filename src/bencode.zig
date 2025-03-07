const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents the data stored in a bencode file
pub const BencodeData = union(enum) {
    int: i64, // Integers (i42e)
    str: []const u8, // Strings (4:spam)
    list: []BencodeData, // Lists (l...e)
    dict: std.StringHashMap(BencodeData), // Dictionaries (d...e)

    /// Frees all the memory associated with this BencodeData
    pub fn deinit(self: *BencodeData, allocator: Allocator) void {
        switch (self.*) {
            .int => {}, // Nothing to free
            .str => |s| allocator.free(s),
            .list => |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            .dict => |*dict| deinitDict(allocator, dict),
        }
    }

    /// Convert the BencodeData representation to a bencode string
    pub fn encode(self: BencodeData, allocator: Allocator, output: *std.ArrayList(u8)) !void {
        switch (self) {
            .int => |i| try output.writer().print("i{d}e", .{i}),
            .str => |s| {
                try output.writer().print("{d}:", .{s.len});
                try output.appendSlice(s);
            },
            .list => |items| {
                try output.append('l');
                for (items) |item| try item.encode(allocator, output);
                try output.append('e');
            },
            .dict => |dict| {
                try output.append('d');

                // We need to sort the keys for consistent hashing
                var keys = std.ArrayList([]const u8).init(allocator);
                defer keys.deinit();

                var iter = dict.iterator();
                while (iter.next()) |entry| try keys.append(entry.key_ptr.*);
                std.mem.sort([]const u8, keys.items, {}, keyLessThan);

                // Encode each key-value pair
                for (keys.items) |key| {
                    try output.writer().print("{d}:", .{key.len});
                    try output.appendSlice(key);
                    try dict.get(key).?.encode(allocator, output);
                }

                try output.append('e');
            },
        }
    }
};

/// Enumerates all possible parsing errors
pub const ParsingError = error{
    UnexpectedEnd,
    InvalidInteger,
    InvalidString,
    MalformedInput,
    OutOfMemory,
};

/// Parse a bencode string into a BencodeData structure
pub fn parse(allocator: Allocator, source: []const u8) !BencodeData {
    var position: usize = 0;
    const data = try parseExpression(allocator, source, &position);
    if (position != source.len) return ParsingError.MalformedInput;
    return data;
}

/// Reads and parses a bencode file
pub fn parseFile(allocator: Allocator, file_path: []const u8) !BencodeData {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // Get the file size to allocate enough memory for the buffer
    const file_size = try file.getEndPos();

    // Allocate a buffer to hold the file contents
    var file_buffer_arena = std.heap.ArenaAllocator.init(allocator);
    const file_allocator = file_buffer_arena.allocator();
    defer file_buffer_arena.deinit();

    const buffer = try file_allocator.alloc(u8, file_size);

    // Read the entire file into the buffer
    const bytes_read = try file.readAll(buffer);
    if (bytes_read != file_size) return error.IncompleteRead;

    // Parse the bencode data from the buffer
    return try parse(allocator, buffer);
}

/// Parse a bencode expression at the given given position
fn parseExpression(allocator: Allocator, source: []const u8, position: *usize) !BencodeData {
    if (position.* >= source.len) {
        return ParsingError.UnexpectedEnd;
    }

    switch (source[position.*]) {
        'i' => {
            position.* += 1; // Skip 'i'

            // Handle negative numbers
            var negative = false;
            if (position.* < source.len and source[position.*] == '-') {
                negative = true;
                position.* += 1;
            }

            // Parse the number
            const start = position.*;
            while (position.* < source.len and isDigit(source[position.*]))
                position.* += 1;

            if (position.* >= source.len or source[position.*] != 'e') {
                return ParsingError.InvalidInteger;
            }

            // Convert the string to an integer
            const string = source[start..position.*];
            const number = try std.fmt.parseInt(i64, string, 10);

            position.* += 1; // Skip 'e'
            return BencodeData{ .int = if (negative) -number else number };
        },
        '0'...'9' => {
            // Parse the length
            const start = position.*;
            while (position.* < source.len and isDigit(source[position.*]))
                position.* += 1;

            if (position.* >= source.len or source[position.*] != ':') {
                return ParsingError.InvalidString;
            }

            const length = try std.fmt.parseInt(usize, source[start..position.*], 10);
            position.* += 1; // Skip ':'

            if (position.* + length > source.len) {
                return ParsingError.UnexpectedEnd;
            }

            // Copy the string
            const string = try allocator.dupe(u8, source[position.*..(position.* + length)]);
            position.* += length;

            return BencodeData{ .str = string };
        },
        'l' => {
            position.* += 1; // Skip 'l'

            var items = std.ArrayList(BencodeData).init(allocator);
            errdefer items.deinit();

            // Parse list items until we reach the end marker 'e'
            while (position.* < source.len and source[position.*] != 'e') {
                const item = try parseExpression(allocator, source, position);
                try items.append(item);
            }

            if (position.* >= source.len) {
                return ParsingError.UnexpectedEnd;
            }

            position.* += 1; // Skip 'e'

            // Convert the ArrayList to a slice
            const list_items = try items.toOwnedSlice();
            return BencodeData{ .list = list_items };
        },
        'd' => {
            position.* += 1; // Skip 'd'

            var dict = std.StringHashMap(BencodeData).init(allocator);
            errdefer deinitDict(allocator, &dict);

            // Parse dictionary entries until we reach the end marker 'e'
            while (position.* < source.len and source[position.*] != 'e') {
                // Keys must be strings in bencode
                if (!isDigit(source[position.*])) {
                    return ParsingError.MalformedInput;
                }

                // Parse the key and the value
                const key = (try parseExpression(allocator, source, position)).str;
                const value = try parseExpression(allocator, source, position);

                // Store in the dictionary
                try dict.put(try allocator.dupe(u8, key), value);

                // Free the original key as we have duplicated it
                allocator.free(key);
            }

            if (position.* >= source.len) {
                return ParsingError.UnexpectedEnd;
            }

            position.* += 1; // Skip 'e'
            return BencodeData{ .dict = dict };
        },
        else => return ParsingError.MalformedInput,
    }
}

/// Needed for sorting the keys in a bencode dict
fn keyLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Check if a given character is a digit
fn isDigit(char: u8) bool {
    return (char >= '0' and char <= '9');
}

/// Free a dictionary from memory
fn deinitDict(allocator: Allocator, dict: *std.StringHashMap(BencodeData)) void {
    var iter = dict.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.deinit(allocator);
    }
    dict.deinit();
}
