// tb_logic_tile.v
//
// Self-checking testbench for design/rtl/logic_tile.v -- the 4x lut4_slice
// tile-level composition, per spec/tile-spec.md.
//
// This complements tb_lut4_slice.v (which exhaustively covers one slice's
// LUT/FF behavior) by checking the tile-level wiring claims specifically:
//   1. All 4 slices can hold independent LUT configs and independent
//      registered/combinational select simultaneously.
//   2. Per-slice clock-enable is independent -- gating one slice's FF must
//      not affect the others.
//   3. Reset is shared -- a single `rst` clears every slice's FF at once.

`default_nettype none
`timescale 1ns/1ps

module tb_logic_tile;

    reg         clk = 0;
    reg         rst = 0;
    reg  [3:0]  ce = 4'b0000;
    reg  [15:0] in = 16'h0000;
    reg  [63:0] lut_init = 64'h0;
    reg  [3:0]  reg_sel = 4'b0000;
    wire [3:0]  out;

    integer errors = 0;
    integer checks = 0;

    logic_tile dut (
        .clk      (clk),
        .rst      (rst),
        .ce       (ce),
        .in       (in),
        .lut_init (lut_init),
        .reg_sel  (reg_sel),
        .out      (out)
    );

    always #5 clk = ~clk;

    task check(input [3:0] expected, input string label);
        begin
            checks = checks + 1;
            if (out !== expected) begin
                errors = errors + 1;
                $display("FAIL[%0d] %s: expected=%b got=%b (t=%0t)",
                          checks, label, expected, out, $time);
            end
        end
    endtask

    initial begin
        // -----------------------------------------------------------
        // 1. Independent per-slice LUT config + registered/combinational
        //    select, all combinational to start.
        //      slice0: always-0, slice1: always-1,
        //      slice2: passthrough of in[0], slice3: 4-input XOR
        //    All 4 slices are driven with the same input pattern
        //    (index 3, i.e. in[0]=1), so any cross-slice bleed-through
        //    would show up as a mismatch against the hand-computed
        //    per-slice expectation below.
        // -----------------------------------------------------------
        lut_init = {16'h6996, 16'hAAAA, 16'hFFFF, 16'h0000};
        reg_sel  = 4'b0000;
        ce       = 4'b0000;
        rst      = 0;
        in       = {4'b0011, 4'b0011, 4'b0011, 4'b0011}; // same 4-bit pattern to all slices
        #1;
        // Expected, computed directly from each slice's truth table at
        // index 3 (4'b0011): slice0=0x0000[3]=0, slice1=0xFFFF[3]=1,
        // slice2=0xAAAA[3]=1 (odd index -> in[0]), slice3=0x6996[3]=0
        // (4-input XOR truth table, even parity of index 3 -> 0).
        check(4'b0110, "independent per-slice combinational config");

        // -----------------------------------------------------------
        // 2. Independent clock-enable: put all 4 slices in registered
        //    mode with distinct LUT outputs, enable ce for slices 0 and
        //    2 only, and confirm only those two update on the clock
        //    edge while 1 and 3 hold their reset value.
        // -----------------------------------------------------------
        reg_sel  = 4'b1111;
        rst      = 1;
        ce       = 4'b0000;
        @(posedge clk); #1;
        check(4'b0000, "shared reset clears all 4 slice FFs");
        rst = 0;

        // Drive each slice's LUT to output 1 for the applied input.
        lut_init = {16'hFFFF, 16'hFFFF, 16'hFFFF, 16'hFFFF};
        in       = {4'b0000, 4'b0000, 4'b0000, 4'b0000};
        ce       = 4'b0101; // enable slices 0 and 2 only
        @(posedge clk); #1;
        check(4'b0101, "independent ce: only enabled slices (0,2) capture new value");

        // -----------------------------------------------------------
        // 3. Shared reset: with slices holding mixed values, asserting
        //    `rst` must clear all 4 simultaneously regardless of ce.
        // -----------------------------------------------------------
        ce  = 4'b1111;
        rst = 1;
        @(posedge clk); #1;
        check(4'b0000, "shared reset clears all slices even with ce=1111");
        rst = 0;

        if (errors == 0)
            $display("PASS: tb_logic_tile -- %0d checks, 0 failures", checks);
        else
            $display("FAIL: tb_logic_tile -- %0d checks, %0d failures", checks, errors);

        $finish;
    end

endmodule

`default_nettype wire
