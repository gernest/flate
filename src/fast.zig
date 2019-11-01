const std = @import("std");

const table_bits: usize = 14; // Bits used in the table.
const table_size: usize = 1 << table_bits; // Size of the table.
const table_mask: usize = table_size - 1; // Mask for table indices. Redundant, but can eliminate bounds checks.
const table_shift: usize = 32 - table_bits; // Right-shift to get the tableBits most significant bits of a uint32.

const input_margin = 16 - 1;
const min_non_literal_block_size = 1 + 1 + input_margin;
const max_store_block_size: usize = 65535;

// The LZ77 step produces a sequence of literal tokens and <length, offset>
// pair tokens. The offset is also known as distance. The underlying wire
// format limits the range of lengths and offsets. For example, there are
// 256 legitimate lengths: those in the range [3, 258]. This package's
// compressor uses a higher minimum match length, enabling optimizations
// such as finding matches via 32-bit loads and compares.
const base_match_length: usize = 3; // The smallest match length per the RFC section 3.2.5
const max_match_offset: usize = 1 << 15;
const max_match_length: usize = 258; // The largest match length
const base_match_offset: usize = 1; // The smallest match offset
const min_match_Length: usize = 4; // The smallest match length that the compressor actually emits

const literal_type: u32 = 0 << 30;
const imput_margin = 16 - 1;
const min_non_literal_block_size = 1 + 1 + input_margin;
const match_type: u32 = 1 << 30;
const length_shift = 32;
pub const Fast = struct {
    table: [table_size]TableEntry = [_]TableEntry{TableEntry{}} ** table_size,
    prev: []u8 = blk: {
        var a: [max_store_block_size]u8 = undefined;
        break :blk a[0..];
    },
    prev_len: usize = 0,
    cur: usize = max_store_block_size,

    fn init() Fast {
        return Fast{};
    }

    const TableEntry = struct {
        val: u32 = 0,
        offset: usize = 0,
    };

    fn load32(b: []const u8) u32 {
        return @intCast(u32, b[0]) | @intCast(u32, b[1] << 8) |
            @intCast(u32, b[2]) << 16 | @intCast(u32, b[3]) << 24;
    }

    fn load64(b: []const u8) u64 {
        return @intCast(u64, b[0]) | @intCast(u64, b[1] << 8) |
            @intCast(u64, b[2]) << 16 | @intCast(u64, b[3]) << 24 |
            @intCast(u64, b[4]) << 32 | @intCast(u64, b[5]) << 40 |
            @intCast(u64, b[6]) << 48 | @intCast(u64, b[7]) << 56;
    }

    fn hash(u: u32) u32 {
        return (u * 0x1e35a7bd) >> @intCast(u32, table_shift);
    }

    fn literalToken(lit: u32) u32 {
        return literal_type + lit;
    }

    fn matchToken(xlength: u32, xoffset: u32) u32 {
        return match_type + xlength << length_shift + xoffset;
    }

    fn emitLiteral(dst: *std.ArrayList(u32), src: []const u8) !void {
        for (src) |lit| {
            try dst.append(literalToken(@intCast(u32, lit)));
        }
    }

    pub fn encode(
        self: *Fast,
        dst: *std.ArrayList(u32),
        src: []const u8,
    ) !void {
        if (self.cur > (1 << 30)) {
            self.resetAll();
        }
        if (src.len < min_non_literal_block_size) {
            self.cur += max_store_block_size;
            self.zeroPrev();
            return emitLiteral(dst, src);
        }
        const s_limit = s.len - input_margin;
        var next_emit: usize = 0;
        var s: usize = 0;
        var cv = load32(src);
        var next_hash = hash(cv);
        while (true) {
            // Copied from the C++ snappy implementation:
            //
            // Heuristic match skipping: If 32 bytes are scanned with no matches
            // found, start looking only at every other byte. If 32 more bytes are
            // scanned (or skipped), look at every third byte, etc.. When a match
            // is found, immediately go back to looking at every byte. This is a
            // small loss (~5% performance, ~0.1% density) for compressible data
            // due to more bookkeeping, but for non-compressible data (such as
            // JPEG) it's a huge win since the compressor quickly "realizes" the
            // data is incompressible and doesn't bother looking for matches
            // everywhere.
            //
            // The "skip" variable keeps track of how many bytes there are since
            // the last match; dividing it by 32 (ie. right-shifting by five) gives
            // the number of bytes to move ahead for each iteration.
            var skip: usize = 32;
            var next_s = s;
            var candidate = TableEntry{};
            while (true) {
                s = next_s;
                const bytes_between_hash_lookup = skip >> 5;
                next_s = s + bytes_between_hash_lookup;
                skip += bytes_between_hash_lookup;
                if (next_s > s_limit) {
                    if (next_emit < src.len) {
                        try emitLiteral(dst, src[next_emit..]);
                    }
                    self.cur += src.len;
                    self.prev_len = src.len;
                    std.mem.copy(u8, self.prev, src);
                    return;
                }
                const x = @intCast(usize, next_hash) & table_mask;
                candidate = self.table[x];
                var now = load32(src);
                self.table[x] = TableEntry{
                    .offset = s + self.cur,
                    .val = cv,
                };
                next_hash = hash(now);
                const offset = s - (candidate.offset - self.cur);
                if (offset > max_match_offset or cv != candidate.val) {
                    cv = now;
                    continue;
                }
                break;
            }
            // A 4-byte match has been found. We'll later see if more than 4 bytes
            // match. But, prior to the match, src[nextEmit:s] are unmatched. Emit
            // them as literal bytes.
            try emitLiteral(dst, src[next_emit..s]);

            // Call emitCopy, and then see if another emitCopy could be our next
            // move. Repeat until we find no match for the input immediately after
            // what was consumed by the last emitCopy call.
            //
            // If we exit this loop normally then we need to call emitLiteral next,
            // though we don't yet know how big the literal will be. We handle that
            // by proceeding to the next iteration of the main loop. We also can
            // exit this loop via goto if we get close to exhausting the input.
            while (true) {
                // Invariant: we have a 4-byte match at s, and no need to emit any
                // literal bytes prior to s.

                // Extend the 4-byte match as long as possible.
                s += 4;
                const t = @intCast(isize, candidate.offset) - @intCast(isize, e.cur) + 4;
                const l = self.matchLen(s, t, src);
                try dst.append(matchToken(
                    @intCast(u32, l + 4 + base_match_length),
                    @intCast(u32, @intCast(isize, s) - t - @intCast(isize, base_match_offset)),
                ));
                s += l;
                next_emit = s;
                if (s >= s_limit) {
                    if (next_emit < src.len) {
                        try emitLiteral(dst, src[next_emit..]);
                    }
                    self.cur += src.len;
                    self.prev_len = src.len;
                    std.mem.copy(u8, self.prev, src);
                    return;
                }
                // We could immediately start working at s now, but to improve
                // compression we first update the hash table at s-1 and at s. If
                // another emitCopy is not our next move, also calculate nextHash
                // at s+1. At least on GOARCH=amd64, these three hash calculations
                // are faster as one load64 call (with some shifts) instead of
                // three load32 calls.
            }
        }
    }

    fn matchLen(self: *Fast, s: usize, t: isize, src: []const u8) usize {
        var s1 = s + max_match_length - 4;
        if (s1 > src.len) {
            s1 = src.len;
        }
        if (t >= 0) {
            const tt = @intCast(usize, t);
            var b = src[tt..];
            const a = src[s..s1];
            b = b[0..a.len];
            var i: usize = 0;
            while (i < a.len) : (i += 1) {
                if (a[i] != b[i]) {
                    return i;
                }
            }
            return a.len;
        }
        const tp = @intCast(isize, self.prev_len) + t;
        if (tp < 0) {
            return 0;
        }
        var a = src[s..s1];
        var b = self.prev[@intCast(usize, tp)..];
        if (b.len > a.len) {
            b = b[0..a.len];
        }
        a = a[0..b.len];
        var i: usize = 0;
        while (i < b.len) : (i += 1) {
            if (a[i] != b[i]) {
                return i;
            }
        }
        const n = b.len;
        if (s + n == s1) {
            return n;
        }

        a = src[s + n .. s1];
        b = src[0..a.len];
        i = 0;
        while (i < a.len) : (i += 1) {
            if (a[i] != b[i]) {
                return i + n;
            }
        }
        return a.len + n;
    }

    fn reset(self: *Fast) void {
        self.zeroPrev();
        self.cur += max_match_offset;
        if (self.cur > (1 << 30)) {
            self.resetAll();
        }
    }

    fn zeroPrev(self: *Fast) void {
        var i: usize = 0;
        while (i < self.prev.len) : (i += 1) {
            self.prev[i] = 0;
        }
        self.prev_len = 0;
    }

    fn resetAll(self: *Fast) void {
        self.cur = max_store_block_size;
        self.zeroPrev();
        var i: usize = 0;
        while (i < self.table.len) : (i += 1) {
            self.table[i] = TableEntry{};
        }
    }
};
