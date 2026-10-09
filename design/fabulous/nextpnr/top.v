// G1 nextpnr acceptance design (issue #87): one 4-input function, the 4-input
// parity (LUT4 INIT = 16'h6996), as a single LOGIC4 BEL, plus one consumer BEL
// so a net is actually routed through the generated switch matrix.
//
// Instantiated structurally, with no top-level ports and no constants: the
// generated fabric has no IO BEL (nextpnr rejects a port driven by a LUT: "must
// be PAD") and no constant driver (a tied-off pin makes $PACKER_GND
// unroutable). Both are findings, see design/README.md and
// the expected-FAIL probe in design/fabulous/nextpnr.log. Unconnected LUT inputs are left floating.
module top;
    (* keep *) wire n1;
    (* keep *) wire n2;
    (* keep *) lut4_ff_bel #(.INIT(16'h6996), .FF(1'b0)) u0 (.O(n1));
    (* keep *) lut4_ff_bel #(.INIT(16'h6996), .FF(1'b0)) u1 (.I0(n1), .O(n2));
endmodule
