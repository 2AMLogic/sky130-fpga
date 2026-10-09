// Routability corpus (issue #115): four independent outputs, each a distinct
// full 4-input function of the same four inputs, so the design needs all four
// LUT BELs of the single LOGIC4 tile. No two outputs share a sub-function that
// a 4-LUT mapper could factor out.
//   y = a ^ b ^ c ^ d       w = (a & b) | (c & d)
//   z = (a | b) & (c | d)   v = a ? (b ^ c) : d
module top (input a, input b, input c, input d,
            output y, output w, output z, output v);
    assign y = a ^ b ^ c ^ d;
    assign w = (a & b) | (c & d);
    assign z = (a | b) & (c | d);
    assign v = a ? (b ^ c) : d;
endmodule
