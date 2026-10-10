// Registered-BEL placement probe for BEL C (issue #156, EXPERIMENTAL single-tile).
// One registered LUT4 BEL (FF=1) instantiated directly and pinned to X1Y1/C with
// the NEXTPNR_BEL attribute, so the registered composition path (LUT -> flop,
// real EN and SR nets) of exactly this BEL is exercised and cannot silently move
// to another BEL (flow/corpus_run.py checks the placed BEL against corpus.json,
// flow/check_regbel_fixtures.py checks the committed fixtures).
//   q <= rst ? 0 : (en ? ((a & b) ^ (c | d)) : q)
// INIT 16'h7778 is that function with I0=a, I1=b, I2=c, I3=d. Flop semantics
// match design/rtl/lut4_slice.v (reset has priority over enable, reset to 0).
// The BEL clock is the implicit UserCLK (no fabric pin), so there is no clk port.
module top (input a, input b, input c, input d, input en, input rst, output q);
    (* NEXTPNR_BEL = "X1Y1/C" *)
    lut4_ff_bel #(.INIT(16'h7778), .FF(1'b1)) u_c (
        .I0(a), .I1(b), .I2(c), .I3(d), .SR(rst), .EN(en), .O(q));
endmodule
