// tb_port_interconnect_drive.v
//
// The DRIVING half of issue #250 AC 5's testbench-sensitivity pair. Same
// nesting and the same second-root `$sdf_annotate` mechanism as
// tb_port_interconnect_noop.v -- see that file's header for why both are
// load-bearing. The ONLY difference is that this half drives every DUT
// input and advances simulation time well past time 0, which is the
// condition klayout-tools#1619 finding 9 reports as the trigger.
//
// It also doubles as the delay PROBE. Every change of `out` is printed with
// `$time` on an `EDGE` line, and run.sh reruns this bench with a rescaled
// copy of each case SDF and diffs the `EDGE` lines against an un-annotated
// baseline -- so an "applied" verdict rests on an observed timing shift and
// not merely on the absence of an `SDF ERROR` line. The 1ps precision is
// far finer than the rescaled delay.
//
// Each input toggles on its own, at its own time, so exactly one group in
// the DUT moves per stimulus step:
//   t=10  in[0] -> GROUP A (and, through u_a3.X, GROUP P)
//   t=20  in[1] -> GROUP B
//   t=30  in[2] -> GROUP C
//   t=40  in[3] -> GROUP N
//   t=50  in[4] -> GROUP M
//   t=60  in[5] -> GROUP E (through u_buf)
//   t=70  clk   -> GROUP S

`default_nettype none
`timescale 1ns/1ps

module tb_port_interconnect_drive;

    reg  [5:0]  in  = 6'b000000;
    reg         clk = 1'b0;
    wire [19:0] out;

    port_interconnect_dut dut (
        .in  (in),
        .clk (clk),
        .out (out)
    );

    always @(out)
        $display("EDGE t=%0t out=%b", $time, out);

    initial begin
        $display("TB: tb_port_interconnect_drive -- driving stimulus");
        #10 in[0] = 1'b1;
        #10 in[1] = 1'b1;
        #10 in[2] = 1'b1;
        #10 in[3] = 1'b1;
        #10 in[4] = 1'b1;
        #10 in[5] = 1'b1;
        #10 clk   = 1'b1;
        #10;
        $display("TB: final in=%b clk=%b out=%b", in, clk, out);
        $display("DONE: tb_port_interconnect_drive");
        $finish;
    end

endmodule

`default_nettype wire
