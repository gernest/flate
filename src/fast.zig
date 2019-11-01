const std = @import("std");

const table_bits: usize = 14; // Bits used in the table.
const table_size: usize = 1 << table_bits; // Size of the table.
const table_mask: usize = table_size - 1; // Mask for table indices. Redundant, but can eliminate bounds checks.
const table_shift: usize = 32 - table_bits; // Right-shift to get the tableBits most significant bits of a uint32.

const input_margin = 16 - 1;
const min_non_literal_block_size = 1 + 1 + input_margin;
const max_store_block_size: usize = 65535;
const max_match_offset: usize = 1 << 15;
const max_match_length: usize = 258;

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
        var i: usize = 0;
        while (i < self.prev.len) : (i += 1) {
            self.prev[i] = 0;
        }
        self.prev_len = 0;
        self.cur += max_match_offset;
        if (self.cur > (1 << 30)) {
            self.resetAll();
        }
    }

    fn resetAll(self: *Fast) void {
        self.cur = max_store_block_size;
        var i: usize = 0;
        while (i < self.prev.len) : (i += 1) {
            self.prev[i] = 0;
        }
        self.prev_len = 0;
        i = 0;
        while (i < self.table.len) : (i += 1) {
            self.table[i] = TableEntry{};
        }
    }
};
