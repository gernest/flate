const std = @import("std");

const table_bits: usize = 14; // Bits used in the table.
const table_size: usize = 1 << table_bits; // Size of the table.
const table_mask: usize = table_size - 1; // Mask for table indices. Redundant, but can eliminate bounds checks.
const table_shift: usize = 32 - table_bits; // Right-shift to get the tableBits most significant bits of a uint32.

const input_margin = 16 - 1;
const min_non_literal_block_size = 1 + 1 + input_margin;
pub const Fast = stuct{};
