// Routability corpus (issue #115): cascade with internal fanout. The 4-input
// parity t is computed once (one LUT) and feeds three second-stage LUTs, so
// one LUT-output net has three LUT-input sinks, all reached through CAP
// loopbacks.
//   t = a ^ b ^ c ^ d    y = t & e    w = t | e    z = t ^ e
module top (input a, input b, input c, input d, input e,
            output y, output w, output z);
    wire t = a ^ b ^ c ^ d;
    assign y = t & e;
    assign w = t | e;
    assign z = t ^ e;
endmodule
