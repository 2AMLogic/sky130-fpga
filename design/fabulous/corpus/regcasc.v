// Routability corpus (issue #115): registered path through a LUT cascade with
// real EN/SR nets. Same flop semantics as design/fabulous/nextpnr/top_reg.v
// (synchronous reset over clock enable, reset value 0); the data function
// needs two LUTs, so this needs three BELs (two LUTs + the FF BEL) and CAP
// loopbacks between the LUTs and the flop. `clk` is the BEL's implicit
// UserCLK (stripped before nextpnr, as flow/nextpnr.sh does for top_reg.v).
//   q <= rst ? 0 : (en ? ((a ^ b ^ c ^ d) & e) : q)
module top (input clk, input a, input b, input c, input d, input e,
            input en, input rst, output q);
    reg r;
    always @(posedge clk)
        if (rst) r <= 1'b0;
        else if (en) r <= (a ^ b ^ c ^ d) & e;
    assign q = r;
endmodule
