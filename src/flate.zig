const std = @import("std");

const math = std.math;
const assert = std.debug.assert;
const warn = std.debug.warn;
const Allocator = std.mem.Allocator;
const io = std.io;

pub const max_num_lit = 286;
pub const max_bits_limit = 16;
const max_i32 = math.maxInt(i32);

pub const Huffman = struct {
    codes: [max_num_lit]Code,
    codes_len: usize,
    freq_cache: [max_num_lit]LitaralNode,
    bit_count: [17]i32,

    /// sorted by literal
    lns: LiteralList,

    ///sorted by freq
    lfs: LiteralList,

    pub const Code = struct {
        code: u16,
        len: u16,
    };

    pub const LitaralNode = struct {
        literal: u16,
        freq: i32,

        pub fn max() LitaralNode {
            return LitaralNode{
                .literal = math.maxInt(u16),
                .freq = math.maxInt(i32),
            };
        }

        pub const SortBy = enum {
            Literal,
            Freq,
        };

        fn sort(ls: []LitaralNode, by: SortBy) void {
            switch (by) {
                .Literal => {
                    std.sort.sort(LitaralNode, ls, sortByLiteralFn);
                },
                .Freq => {
                    std.sort.sort(LitaralNode, ls, sortByFreqFn);
                },
            }
        }

        fn sortByLiteralFn(lhs: LitaralNode, rhs: LitaralNode) bool {
            return lhs.literal < rhs.literal;
        }

        fn sortByFreqFn(lhs: LitaralNode, rhs: LitaralNode) bool {
            if (lhs.freq == rhs.freq) {
                return lhs.literal < rhs.literal;
            }
            return lhs.freq < rhs.freq;
        }
    };

    pub const LiteralList = std.ArrayList(LitaralNode);

    const LevelInfo = struct {
        level: i32,
        last_freq: i32,
        next_char_freq: i32,
        next_pair_freq: i32,
        needed: i32,
    };

    pub fn init(size: usize) Huffman {
        assert(size <= max_num_lit);
        var h: Huffman = undefined;
        h.codes_len = size;
        return h;
    }

    pub fn initAlloc(allocator: *Allocator, size: usize) Huffman {
        var h = init(size);
        h.lhs = LiteralList.init(a);
        h.rhs = LiteralList.init(a);
        return h;
    }

    pub fn generateFixedLiteralEncoding() Huffman {
        var h = init(max_num_lit);
        var codes = h.codes[0..h.codes_len];
        var ch: u16 = 0;
        while (ch < max_num_lit) : (ch += 1) {
            var bits: u16 = 0;
            var size: u16 = 0;
            if (ch < 144) {
                // size 8, 000110000  .. 10111111
                bits = ch + 48;
                size = 8;
            } else if (ch < 256) {
                // size 9, 110010000 .. 111111111
                bits = ch + 400 - 144;
                size = 9;
            } else if (ch < 280) {
                // size 7, 0000000 .. 0010111
                bits = ch - 256;
                size = 7;
            } else {
                // size 8, 11000000 .. 11000111
                bits = ch + 192 - 280;
                size = 8;
            }
            codes[@intCast(usize, ch)] = Code{
                .code = reverseBits(bits, size),
                .len = size,
            };
        }
        return h;
    }

    pub fn generateFixedOffsetEncoding() Huffman {
        var h = init(30);
        var codes = h.codes[0..h.codes_len];
        var i: usize = 0;
        while (i < h.codes_len) : (i += 1) {
            codes[i] = Code{
                .code = reverseBits(@intCast(u16, i), 5),
                .len = 5,
            };
        }
        return h;
    }

    pub fn bitLength(self: *Huffman, freq: []i32) isize {
        var total: isize = 0;
        for (freq) |f, i| {
            if (f != 0) {
                total += @intCast(isize, f) + @intCast(isize, h.codes[i].len);
            }
        }
        return total;
    }

    pub fn bitCounts(
        self: *Huffman,
        list: LitaralNode,
        max_bits_arg: i32,
    ) []i32 {
        var amx_bits = max_bits_arg;
        assert(max_bits <= max_bits_limit);
        const n = @intCast(i32, list.len);
        var last_node = n + 1;
        if (max_bits > n - 1) {
            max_bits = n - 1;
        }

        var levels: [max_bits_limit]LevelInfo = undefined;
        var leaf_counts: [max_bits_limit][max_bits_limit]i32 = undefined;

        var level: i32 = 0;
        while (level <= max_bits) : (level += 1) {
            levels[@intCast(usize, level)] = LevelInfo{
                .level = level,
                .last_freq = list[1].freq,
                .next_char_freq = list[2].freq,
                .next_pair_freq = list[0].freq + list[1].freq,
            };
            leaf_counts[level][level] = 2;
            if (level == 1) {
                levels[@intCast(usize, level)].next_pair_freq = max_i32;
            }
        }
        levels[max_bits].needed = 2 * n - 4;
        level = max_bits;
        while (true) {
            var l = &levels[@intCast(usize, level)];
            if (l.next_pair_freq == max_i32 and l.next_char_freq == max_i32) {
                l.needed = 0;
                levels[@intCast(usize, level + 1)].next_pair_freq = max_i32;
                level += 1;
                continue;
            }
            const prev_freq = l.last_freq;
            if (l.next_char_freq < l.next_pair_freq) {
                const nx = leaf_counts[level][level] + 1;
                l.last_freq = l.next_char_freq;
                leaf_counts[level][level] = nx;
                l.next_char_freq = if (nx == last_node) LitaralNode.max().freq else list[nx].freq;
            } else {
                l.last_freq = l.next_pair_freq;
                mem.copy(i32, leaf_counts[level][0..level], leaf_counts[level - 1][0..level]);
                levels[l.level - 1].needed = 2;
                l.needed -= 1;
                if (l.needed == 0) {
                    if (l.level == max_bits) {
                        break;
                    }
                    levels[l.level + 1].next_pair_freq = prev_freq + l.last_freq;
                    level += 1;
                } else {
                    while (level - 1 >= 0 and levels[level - 1].needed > 0) : (level -= 1) {}
                }
            }
        }
        if (leaf_counts[max_bits][max_bits] != n) {
            @panic("leaf_counts[max_bits][max_bits] != n");
        }
        var bit_count = self.bit_count[0 .. max_bits + 1];
        var bits = 1;
        const counts = leaf_counts[max_bits];
        level = max_bits;
        while (level > 0) : (level -= 1) {
            bit_count[bits] = counts[level] - counts[level - 1];
            bits += 1;
        }
        return bit_count;
    }

    /// Look at the leaves and assign them a bit count and an encoding as specified
    /// in RFC 1951 3.2.2
    pub fn assignEncodingAndSize(
        self: *Huffman,
        bit_count: []const i32,
        list: []LitaralNode,
    ) !void {
        var ls = list;
        var code: u16 = 0;
        for (bit_count) |bits, n| {
            code = math.shl(u16, code, 1);
            if (n == 0 or bits == 0) {
                continue;
            }
            // The literals list[len(list)-bits] .. list[len(list)-bits]
            // are encoded using "bits" bits, and get the values
            // code, code + 1, ....  The code values are
            // assigned in literal order (not frequency order).
            var chunk = ls[ls.len - @intCast(usize, bits) ..];
            LitaralNode.sort(chunk, .Literal);
            try self.lhs.append(chunk);
            for (chunk) |node| {
                self.codes[@intCast(usize, node.literal)] = Code{
                    .code = reverseBits(code, @intCast(u16, n)),
                    .len = @intCast(u16, n),
                };
            }
            ls = ls[0 .. ls.len - @intCast(usize, bits)];
        }
    }

    pub fn generate(
        self: *Huffman,
        freq: []const i32,
        max_bits: i32,
    ) !void {
        var list = self.freq_cache[0 .. freq.len + 1];
        var count: usize = 0;
        for (freq) |f, i| {
            if (f != 0) {
                list[count] = LitaralNode{
                    .literal = @intCast(u16, i),
                    .freq = f,
                };
                count += 1;
            } else {
                ls[count] = LitaralNode{
                    .literal = 0,
                    .freq = 0,
                };
                self.codes[i].len = 0;
            }
        }
        ls[freq.len] = LitaralNode{
            .literal = 0,
            .freq = 0,
        };
        ls = ls[0..count];
        if (count <= 2) {
            for (ls) |node, i| {
                // Handle the small cases here, because they are awkward for the general case code. With
                // two or fewer literals, everything has bit length 1.
                var x = &self.codes[@intCast(usize, node.literal)];
                x.code = @intCast(u16, i);
                x.len = 1;
            }
            return;
        }
        LitaralNode.sort(ls, .Freq);
        try self.lfs.append(ls);
        const bit_counts = try self.bitCounts(ls, max_bits);
        try self.assignEncodingAndSize(bit_count, ls);
    }
};

fn reverseBits(number: u16, bit_length: u16) u16 {
    return @bitReverse(u16, math.shl(u16, number, 16 - bit_length));
}

test "huffman" {
    var h = Huffman.generateFixedOffsetEncoding();
    warn("\n");
    for (h.codes[0..h.codes_len]) |code| {
        warn("{}, {}\n", code.code, code.len);
    }
}

const offset_code_count = 30;

// The special code used to mark the end of a block.
const end_block_marker = 256;

// The first length code.
const length_codes_start = 257;

// The number of codegen codes.
const codegen_code_count = 19;
const bad_code = 255;

// buffer_flush_size indicates the buffer size
// after which bytes are flushed to the writer.
// Should preferably be a multiple of 6, since
// we accumulate 6 bytes between writes to the buffer.
const buffer_flush_size = 240;

// buffer_size is the actual output byte buffer size.
// It must have additional headroom for a flush
// which can contain up to 8 bytes.
const buffer_size = buffer_flush_size + 8;

//zig fmt: off
const length_extra_bits = [_]u8{
     0, 0, 0, //257
     0, 0, 0, 0, 0, 1, 1, 1, 1, 2,// 260
     2, 2, 2, 3, 3, 3, 3, 4, 4, 4, //270
     4, 5, 5, 5, 5, 0, //280
};
//zig fmt: on
const length_base = [_]u32{
    0,  1,  2,  3,   4,   5,   6,   7,   8,   10,
    12, 14, 16, 20,  24,  28,  32,  40,  48,  56,
    64, 80, 96, 112, 128, 160, 192, 224, 255,
};
const offset_extra_bits = [_]u8{
    0, 0, 0,  0,  1,  1,  2,  2,  3,  3,
    4, 4, 5,  5,  6,  6,  7,  7,  8,  8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};
const offset_base = []u32{
    0x000000, 0x000001, 0x000002, 0x000003, 0x000004,
    0x000006, 0x000008, 0x00000c, 0x000010, 0x000018,
    0x000020, 0x000030, 0x000040, 0x000060, 0x000080,
    0x0000c0, 0x000100, 0x000180, 0x000200, 0x000300,
    0x000400, 0x000600, 0x000800, 0x000c00, 0x001000,
    0x001800, 0x002000, 0x003000, 0x004000, 0x006000,
};
const codegen_order = [_]u32{
    16, 17, 18, 0,  8,  7,  9,
    6,  10, 5,  11, 4,  12, 3,
    13, 2,  14, 1,  15,
};

const code_gen_size = max_num_lit + offset_code_count + 1;

pub fn Writer(comptime Error: type) type {
    return struct {
        const Self = @This();
        pub const Stream = io.OutStream(Error);

        stream: Stream,
        out_stream: *Stream,
        bits: u64,
        nbits: u8,
        bytes: [buffer_size]u8 = []u8{0} ** buffer_size,
        code_gen_freq: [codegen_code_count]u32 = []u32{0} ** codegen_code_count,
        nbytes: usize,
        literal_freq: [max_num_lit]i32 = []i32{0} ** max_num_lit,
        offset_freq: []i32 = []i32 ** offset_code_count,
        code_gen: [code_gen_size]u8 = []u8{0} ** code_gen_size,
        literal_encoding: Huffman = Huffman.init(max_num_lit),
        offset_encoding: Huffman = Huffman.init(codegen_code_count),
        code_gen_encoding: Huffman = Huffman.init(offset_code_count),

        fn writeFn(out_stream: *Stream, bytes: []const u8) !void {
            const self = @fieldParentPtr(Self, "stream", out_stream);
            return self.write(bytes);
        }

        fn write(self: *Self, bytes: []const u8) !void {
            try self.out_stream.write(bytes);
        }

        fn flush(sel: *Self) !void {
            var n = self.nbytes;
            while (self.nbits != 0) {
                self.bytes[n] = @intCast(usize, self.bits);
                self.bits >>= 8;
                if (self.bits > 8) {
                    self.nbits -= 8;
                } else {
                    self.nbits = 0;
                }
                n += 1;
            }
            self.bits = 0;
            try self.write(self.bytes[0..n]);
            self.nbytes = 0;
        }
    };
}
