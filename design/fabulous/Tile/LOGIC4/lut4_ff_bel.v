// lut4_ff_bel.v -- FABulous BEL for one LUT4 + optional output FF slice.
//
// FABulous-format counterpart of design/rtl/lut4_slice.v (behaviour kept
// identical: LUT index = {I[3],I[2],I[1],I[0]}, synchronous active-high
// reset that takes priority over clock-enable, reset value 0, registered /
// combinational output select).  Unlike FABulous's stock LUT4c BEL there is
// no carry chain (spec/tile-spec.md: "No dedicated carry chain in v1") and
// no configurable reset value.
//
// ConfigBits (NoConfigBits = 17), mapped for nextpnr by the BelMap attribute:
//   [15:0] LUT4 truth table (INIT..INIT_15), == lut_init[15:0] of the slice
//   [16]   reg_sel (FF): 1 = registered output, 0 = combinational output
`default_nettype none

(* FABulous, BelMap,
    INIT=0,
    INIT_1=1,
    INIT_2=2,
    INIT_3=3,
    INIT_4=4,
    INIT_5=5,
    INIT_6=6,
    INIT_7=7,
    INIT_8=8,
    INIT_9=9,
    INIT_10=10,
    INIT_11=11,
    INIT_12=12,
    INIT_13=13,
    INIT_14=14,
    INIT_15=15,
    FF=16
*)
module lut4_ff_bel #(
    parameter integer NoConfigBits = 17
) (
    input wire [3:0] I,   // LUT inputs
    output wire O,        // registered or combinational LUT output
    input wire SR,        // synchronous active-high reset (shared by the tile)
    input wire EN,        // per-slice clock enable
    (* FABulous, EXTERNAL, SHARED_PORT *) input wire UserCLK,
    (* FABulous, GLOBAL *) input wire [NoConfigBits-1:0] ConfigBits
);
    wire [15:0] LUT_values = ConfigBits[15:0];
    wire c_out_mux = ConfigBits[16];

    wire LUT_out = LUT_values[I];
    reg LUT_flop;

    assign O = c_out_mux ? LUT_flop : LUT_out;

    always @(posedge UserCLK) begin
        if (SR) LUT_flop <= 1'b0;
        else if (EN) LUT_flop <= LUT_out;
    end
endmodule
`resetall
