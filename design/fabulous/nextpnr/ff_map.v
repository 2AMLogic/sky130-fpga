// -extra-map for synth_fabulous (issue #74): map the yosys synchronous-reset,
// clock-enable flop ($_SDFFE_PP0P_: reset has priority over enable, reset
// value 0 -- the same semantics as lut4_ff_bel / lut4_slice) onto a LOGIC4 BEL
// with the output register selected (FF=1) and a pass-through LUT (INIT[i] =
// i[0], so O = flop(I0)). C is dropped: the BEL clock is the implicit
// UserCLK. SR and EN are real BEL pins and get routed like any other net.
module \$_SDFFE_PP0P_ (input D, input C, input R, input E, output Q);
    lut4_ff_bel #(.INIT(16'hAAAA), .FF(1'b1)) _ff (
        .I0(D), .SR(R), .EN(E), .O(Q));
endmodule
