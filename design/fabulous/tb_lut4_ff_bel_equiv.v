// Randomized equivalence check: FABulous BEL (lut4_ff_bel) vs the ratified
// RTL slice (design/rtl/lut4_slice.v), driven with identical stimulus.
`timescale 1ns/1ps
module tb;
    reg clk = 0, rst = 0, ce = 0, reg_sel = 0;
    reg [3:0] in = 0;
    reg [15:0] lut_init = 0;
    wire o_ref, o_bel;
    integer i, errors = 0;
    lut4_slice ref_i (.clk(clk), .rst(rst), .ce(ce), .in(in), .lut_init(lut_init),
                      .reg_sel(reg_sel), .out(o_ref));
    lut4_ff_bel bel_i (.I(in), .O(o_bel), .SR(rst), .EN(ce), .UserCLK(clk),
                       .ConfigBits({reg_sel, lut_init}));
    always #5 clk = ~clk;
    initial begin
        for (i = 0; i < 20000; i = i + 1) begin
            if (i % 500 == 0) begin lut_init = $random; reg_sel = $random; end
            in = $random; ce = $random; rst = ($random % 8) == 0;
            #3;
            if (o_ref !== o_bel) begin errors = errors + 1; $display("MISMATCH i=%0d", i); end
            #7;
            if (o_ref !== o_bel) begin errors = errors + 1; $display("MISMATCH(post) i=%0d", i); end
        end
        if (errors == 0) $display("PASS: lut4_ff_bel == lut4_slice over 20000 random cycles");
        else $display("FAIL: %0d mismatches", errors);
        $finish;
    end
endmodule
