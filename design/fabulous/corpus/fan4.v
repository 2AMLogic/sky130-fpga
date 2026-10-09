// Routability corpus (issue #115): shared-input fanout. Input `a` feeds all
// four LUT BELs (one pad net with four sinks); each output is a distinct
// function of `a` and the other inputs.
//   y = a ^ b    w = a & c    z = a | d    v = a ^ (c & d)
module top (input a, input b, input c, input d,
            output y, output w, output z, output v);
    assign y = a ^ b;
    assign w = a & c;
    assign z = a | d;
    assign v = a ^ (c & d);
endmodule
