// lut4_slice.v
//
// LUT4 + optional output flip-flop "slice" -- the basic logic element (BEL)
// of the tile, per spec/tile-spec.md:
//
//   - "LUT count per tile": 4x LUT4 -- this module implements ONE such
//     LUT4; the tile instantiates four of these (see logic_tile.v).
//   - "FF arrangement": 1 FF per LUT, output-only. The FF's output is
//     bitstream-selectable (via `reg_sel`) between registered and
//     combinational LUT output -- the standard "LUT + optional output
//     register" slice shape. No input-side or mid-chain FFs.
//   - Reset style is explicitly left as an RTL-level decision by the spec
//     ("must not add a second clock-tree topology to the tile"). This
//     implementation uses a single synchronous, active-high reset, shared
//     by every slice in the tile (see logic_tile.v), which keeps the tile
//     to one clock-tree topology.
//
// Scope note: this is BEL-level RTL only. It does not implement the
// tile's switch matrix / routing or the FABulous-style tile/fabric
// description format -- that is tracked separately as
// spec/framework-gaps.md item G1 and is out of scope for this file (see
// design/README.md).

`default_nettype none
`timescale 1ns/1ps

module lut4_slice (
    input  wire        clk,       // shared tile clock
    input  wire        rst,       // shared tile reset (synchronous, active-high)
    input  wire        ce,        // per-slice clock enable for the output FF
    input  wire [3:0]  in,        // 4 LUT inputs
    input  wire [15:0] lut_init,  // bitstream-configured LUT4 truth table
    input  wire        reg_sel,   // 1 = registered (FF) output, 0 = combinational
    output wire        out        // slice output: registered or combinational
);

    // Combinational LUT4: a 16-bit truth table indexed by the 4-bit input
    // vector -- the standard LUT4 implementation (init word bit `in`
    // selects the output for input pattern `in`).
    wire lut_out = lut_init[in];

    // Single output flip-flop, synchronous active-high reset, per-slice
    // clock-enable. Combinational passthrough (reg_sel == 0) below bypasses
    // this FF entirely, so it never latches regardless of clock activity.
    reg ff_q;
    always @(posedge clk) begin
        if (rst)
            ff_q <= 1'b0;
        else if (ce)
            ff_q <= lut_out;
    end

    assign out = reg_sel ? ff_q : lut_out;

endmodule

`default_nettype wire
