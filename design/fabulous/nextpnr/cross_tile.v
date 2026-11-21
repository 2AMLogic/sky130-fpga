// The downstream 2AMLogic/sg13g2-fpga #80 parity chain. Six kept LUTs exceed
// one tile's four BELs, so at least one of the five nets must cross a boundary.
// The generated model has no pads. The bench drives the unconnected LUT pins.
module top;
    (* keep *) wire n1;
    (* keep *) wire n2;
    (* keep *) wire n3;
    (* keep *) wire n4;
    (* keep *) wire n5;
    (* keep *) wire n6;
    (* keep *) lut4_ff_bel #(.INIT(16'h6996), .FF(1'b0)) u0 (.O(n1));
    (* keep *) lut4_ff_bel #(.INIT(16'h6996), .FF(1'b0)) u1 (.I0(n1), .O(n2));
    (* keep *) lut4_ff_bel #(.INIT(16'h6996), .FF(1'b0)) u2 (.I0(n2), .O(n3));
    (* keep *) lut4_ff_bel #(.INIT(16'h6996), .FF(1'b0)) u3 (.I0(n3), .O(n4));
    (* keep *) lut4_ff_bel #(.INIT(16'h6996), .FF(1'b0)) u4 (.I0(n4), .O(n5));
    (* keep *) lut4_ff_bel #(.INIT(16'h6996), .FF(1'b0)) u5 (.I0(n5), .O(n6));
endmodule
