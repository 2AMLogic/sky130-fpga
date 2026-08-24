// tb_lut4_slice.v
//
// Self-checking testbench for design/rtl/lut4_slice.v -- the tile's
// BEL-level LUT4 + optional output FF, per spec/tile-spec.md.
//
// Coverage (per the T1 "design sources" acceptance bar -- see issue #5):
//   1. LUT4 truth-table programmability: several representative configs
//      (all-0, all-1, and two mixed patterns) swept across all 16 input
//      combinations, in combinational mode.
//   2. Registered mode: output follows the FF (lags the LUT's
//      combinational value by one clock edge), including a reset check.
//   3. Clock-enable gating: with ce=0, the FF must hold its value across
//      clock edges even as the combinational LUT input changes.
//   4. Synchronous reset while ce is active: reset must win.
//   5. Combinational passthrough must not latch: with reg_sel=0, `out`
//      tracks `in` immediately and stays stable across clock edges,
//      regardless of ce.
//
// Pass/fail is asserted in-simulation (no waveform eyeballing): every
// check increments `checks`, mismatches increment `errors` and are
// printed with a `FAIL` prefix, and the run concludes with a single
// PASS/FAIL summary line. See sim/README.md for how this is run.

`default_nettype none
`timescale 1ns/1ps

module tb_lut4_slice;

    reg         clk = 0;
    reg         rst = 0;
    reg         ce = 0;
    reg  [3:0]  in = 4'b0;
    reg  [15:0] lut_init = 16'h0000;
    reg         reg_sel = 0;
    wire        out;

    integer errors = 0;
    integer checks = 0;

    lut4_slice dut (
        .clk      (clk),
        .rst      (rst),
        .ce       (ce),
        .in       (in),
        .lut_init (lut_init),
        .reg_sel  (reg_sel),
        .out      (out)
    );

    always #5 clk = ~clk;

    task check(input expected, input string label);
        begin
            checks = checks + 1;
            if (out !== expected) begin
                errors = errors + 1;
                $display("FAIL[%0d] %s: expected=%b got=%b (t=%0t)",
                          checks, label, expected, out, $time);
            end
        end
    endtask

    integer i;
    reg [15:0] test_inits[0:3];

    initial begin
        test_inits[0] = 16'h0000; // always 0
        test_inits[1] = 16'hFFFF; // always 1
        test_inits[2] = 16'hAAAA; // out = in[0] (odd-indexed bits set)
        test_inits[3] = 16'h6996; // 4-input XOR truth table

        // -----------------------------------------------------------
        // 1. LUT4 truth-table programmability, combinational mode.
        // -----------------------------------------------------------
        reg_sel = 0;
        ce = 0;
        rst = 0;

        for (i = 0; i < 4; i = i + 1) begin : sweep_configs
            integer j;
            lut_init = test_inits[i];
            for (j = 0; j < 16; j = j + 1) begin
                in = j[3:0];
                #1;
                check(lut_init[in], "lut4 truth table (combinational)");
            end
        end

        // -----------------------------------------------------------
        // 2. Registered mode: output lags the LUT value by one clock
        //    edge while ce=1; reset clears the FF.
        // -----------------------------------------------------------
        lut_init = 16'hAAAA; // out = in[0]
        reg_sel = 1;
        ce = 1;
        rst = 1;
        in = 4'b0000;
        @(posedge clk); #1;
        check(1'b0, "reset clears FF");
        rst = 0;

        in = 4'b0001; // lut_out = 1
        #1;
        check(1'b0, "registered output has not yet captured new value");
        @(posedge clk); #1;
        check(1'b1, "registered output captures LUT value after clock edge");

        // -----------------------------------------------------------
        // 3. Clock-enable gating: ce=0 holds the FF value across clock
        //    edges even though the combinational LUT input changes.
        // -----------------------------------------------------------
        ce = 0;
        in = 4'b0000; // lut_out = 0 now, but FF must hold its prior value (1)
        @(posedge clk); #1;
        check(1'b1, "ce=0 holds FF value across clock edge");
        @(posedge clk); #1;
        check(1'b1, "ce=0 continues to hold FF value");

        // -----------------------------------------------------------
        // 4. Reset while ce is active: synchronous reset must win.
        // -----------------------------------------------------------
        ce = 1;
        in = 4'b0001; // lut_out = 1
        @(posedge clk); #1;
        check(1'b1, "ce=1 re-captures LUT value");
        rst = 1;
        @(posedge clk); #1;
        check(1'b0, "sync reset clears FF even with ce=1 and lut_out=1");
        rst = 0;

        // -----------------------------------------------------------
        // 5. Combinational passthrough must not latch: `out` tracks
        //    `in` immediately and stays stable across clock edges,
        //    ignoring ce entirely.
        // -----------------------------------------------------------
        reg_sel = 0;
        ce = 0;
        lut_init = 16'hAAAA; // out = in[0]
        for (i = 0; i < 4; i = i + 1) begin
            in = i[3:0];
            #1;
            check(lut_init[in], "combinational passthrough ignores clock/ce");
            @(posedge clk); #1;
            check(lut_init[in], "combinational passthrough stable across clock edge");
        end

        if (errors == 0)
            $display("PASS: tb_lut4_slice -- %0d checks, 0 failures", checks);
        else
            $display("FAIL: tb_lut4_slice -- %0d checks, %0d failures", checks, errors);

        $finish;
    end

endmodule

`default_nettype wire
