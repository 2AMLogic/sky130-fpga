// ADR-0005 acceptance design: top-level ports, plus constants.
//   y = a ^ b ^ c ^ d      4-input LUT (INIT 16'h6996)
//   w = (a & b & c) | (d & 1'b0)
// The constant folds away in yosys (w becomes a 3-input AND), the unused 4th
// LUT input is covered by a replicated INIT (flow cells_map.v), so nothing in
// the netlist needs a constant driver. Ports map to the harness pad BELs
// (top_io.pcf, flow/nextpnr_io_overlay.py).
module top (input a, input b, input c, input d, output y, output w);
    assign y = a ^ b ^ c ^ d;
    assign w = (a & b & c) | (d & 1'b0);
endmodule
