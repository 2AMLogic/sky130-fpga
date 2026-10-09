// Expected-FAIL probe (flow/nextpnr.sh): top.v with one LUT input tied off to
// a constant (u0.I1 = 1'b0). The generated LOGIC4 fabric has no constant
// driver, so nextpnr packs the tie into $PACKER_GND but cannot route it
// ("Failed to find a route ... net $PACKER_GND"). The failure is recorded in
// nextpnr.log as the evidence behind design/README.md's "no constant driver"
// finding.
module top;
    (* keep *) wire n1;
    (* keep *) wire n2;
    (* keep *) lut4_ff_bel #(.INIT(16'h6996), .FF(1'b0)) u0 (.I1(1'b0), .O(n1));
    (* keep *) lut4_ff_bel #(.INIT(16'h6996), .FF(1'b0)) u1 (.I0(n1), .O(n2));
endmodule
