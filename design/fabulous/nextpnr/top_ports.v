// Expected-FAIL probe (flow/nextpnr.sh): the same 4-input parity function with
// ordinary top-level ports. The generated LOGIC4 fabric has no IO BEL, so
// nextpnr cannot pack the ports; the failure is recorded in nextpnr.log as
// the evidence behind design/README.md's "no IO BEL" finding.
module top (input a, input b, input c, input d, output y);
    assign y = a ^ b ^ c ^ d;
endmodule
