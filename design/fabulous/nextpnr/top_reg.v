// Issue #74 registered acceptance design (experimental single-LOGIC4 harness):
//   q <= rst ? 0 : (en ? a ^ b ^ c : q)       synchronous, reset over enable
// i.e. exactly the BEL's flop semantics (design/rtl/lut4_slice.v: reset
// independent of / priority over clock-enable, reset value 0). yosys maps the
// data function to a combinational LOGIC4 BEL (FF=0) and the flop to a second
// LOGIC4 BEL (FF=1, INIT = pass I0; ff_map.v), so EN and SR are real routed
// nets (pads -> tracks -> jump wires), not simulator constants. `clk` is the
// BEL's implicit UserCLK (no fabric pin): it is a runtime *harness* input,
// stripped from the nextpnr JSON by flow/nextpnr.sh (see sim/README.md).
module top (input clk, input a, input b, input c, input en, input rst,
            output q);
    reg r;
    always @(posedge clk)
        if (rst) r <= 1'b0;
        else if (en) r <= a ^ b ^ c;
    assign q = r;
endmodule
