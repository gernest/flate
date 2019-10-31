const std = @import("std");

const table_bits: usize = 14; // Bits used in the table.
const table_size: usize = 1 << table_bits; // Size of the table.
const table_mask: usize = table_size - 1; // Mask for table indices. Redundant, but can eliminate bounds checks.
const table_shift: usize = 32 - table_bits; // Right-shift to get the tableBits most significant bits of a uint32.

const input_margin = 16 - 1;
const min_non_literal_block_size = 1 + 1 + input_margin;
const max_store_block_size: usize = 65535;
pub const Fast = struct {
    table: [table_size]TableEntry,
    prev: []u8 = blk: {
        var a: [max_store_block_size]u8 = undefined;
        break :blk a[0..];
    },
    cur: usize = max_store_block_size,

    fn init() Fast {
        var f: Fast = undefined;
        f.prev = blk: {
            var a: [max_store_block_size]u8 = undefined;
            break :blk a[0..];
        };
        f.cur = max_store_block_size;
        return f;
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
};
