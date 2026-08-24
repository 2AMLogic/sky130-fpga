// logic_tile.v
//
// LUT4-class logic tile: 4x lut4_slice BELs sharing one clock domain and
// one reset -- each slice has an independent clock-enable and independent
// bitstream configuration (LUT truth table + registered/combinational
// output select), per spec/tile-spec.md:
//
//   "All 4 FFs in a tile share one clock domain and one reset, each with
//   an independent clock-enable -- this is a minimal-but-real per-LUT
//   register file rather than a single shared register, while avoiding a
//   multi-clock-domain tile for the first physical design pass."
//
// Bus packing (flat vectors, since plain Verilog-2001 ports don't support
// unpacked arrays): slice `i` (0..3) owns:
//   - in[4*i +: 4]        -- that slice's 4 LUT inputs
//   - lut_init[16*i +: 16] -- that slice's 16-bit LUT4 truth table
//   - ce[i], reg_sel[i], out[i]
//
// Scope note: this is BEL-level RTL only -- 4x LUT4 + 4x output FF, per
// spec/tile-spec.md's "LUT count per tile" and "FF arrangement" sections.
// It does NOT implement the tile's switch matrix / inter-tile routing or
// the FABulous-style tile/fabric description format (that schema is
// unconfirmed pending spec/framework-gaps.md item G1, and is a separate,
// larger follow-on). See design/README.md.

`default_nettype none
`timescale 1ns/1ps

module logic_tile (
    input  wire        clk,        // shared tile clock
    input  wire        rst,        // shared tile reset (synchronous, active-high)
    input  wire [3:0]  ce,         // per-slice clock enable
    input  wire [15:0] in,         // 4 slices x 4 LUT inputs each
    input  wire [63:0] lut_init,   // 4 slices x 16-bit LUT4 truth table each
    input  wire [3:0]  reg_sel,    // per-slice registered/combinational select
    output wire [3:0]  out         // per-slice output
);

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_slice
            lut4_slice u_slice (
                .clk      (clk),
                .rst      (rst),
                .ce       (ce[i]),
                .in       (in[4*i +: 4]),
                .lut_init (lut_init[16*i +: 16]),
                .reg_sel  (reg_sel[i]),
                .out      (out[i])
            );
        end
    endgenerate

endmodule

`default_nettype wire
