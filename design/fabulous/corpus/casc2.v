// Routability corpus (issue #115): two-stage LUT cascade. The six-input
// function needs at least two 4-LUTs; the first LUT's output feeds the second
// LUT's input, i.e. the net has to leave the tile through an output track and
// come back through a CAP loopback (the fabric has no direct BEL-to-BEL path).
//   y = ((a ^ b ^ c ^ d) & e) ^ f
module top (input a, input b, input c, input d, input e, input f, output y);
    assign y = ((a ^ b ^ c ^ d) & e) ^ f;
endmodule
