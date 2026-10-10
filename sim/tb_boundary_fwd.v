// tb_boundary_fwd.v -- generated-tile boundary forwarding diagnostic (issue #188, EXPERIMENTAL G5)
//
// Checks the three pass-through outputs of the FABulous-GENERATED LOGIC4 tile
// against their generated forwarding contract, read from the pinned generated
// Tile/LOGIC4/LOGIC4.v (which is the only place it is defined):
//     UserCLKo      = UserCLK          (clk_buf, 1 bit)
//     FrameData_O   = FrameData        (my_buf per bit, 32 bits)
//     FrameStrobe_O = FrameStrobe      (my_buf per bit, 20 bits)
// i.e. each output is a pure LOGICAL copy of the same-index input; nothing is
// registered, inverted, re-ordered or gated by configuration. Delays of the
// generator's placeholder buffers/matrix are NOT modelled or claimed: every
// check is made after a fixed 1 ns settle, a simulation convention only.
//
// Oracle: the expected value is the value this bench itself just drove on the
// matching input, compared with the four-state operator !== so X and Z on any
// forwarded output fail. ConfigBits, cfg, maps and the tile's internal signals
// are never read: forwarding is checked independently of local configuration.
//
// Stimulus phases (clock and frame ports are exercised together):
//   1. initial state and clock: both levels, 16 full periods (repeated edges),
//      each level checked after every edge, plus a short pulse train;
//   2. walking-one and walking-zero over all 32 FrameData bits (strobes idle);
//   3. walking-one and walking-zero over all 20 FrameStrobe bits (data changing);
//      walking-zero strobes are a forwarding-only pattern, not frame writes;
//   4. idle strobes (all 0) with changing data (all-0, all-1, alternating, LFSR);
//   5. normal legal frame writes: for each of the 20 frames, data presented,
//      one-hot strobe, strobe released, data changed, the clock toggling between.
// Coverage is accumulated per port bit from the checks themselves: a bit counts
// only once the output was checked equal to the input at both levels.
//
// Compile with -DGEN_TILE only (the repository composition has no pass-through
// ports). Verdict lines follow flow/gate_sim_verdict.sh.
`timescale 1ns/1ps

module tb_boundary_fwd;

`ifndef GEN_TILE
    initial begin
        $display("FAIL: tb_boundary_fwd: needs -DGEN_TILE (the generated LOGIC4 tile)");
        $finish;
    end
`else
    reg          clk = 1'b0;
    reg  [31:0]  FrameData   = 32'b0;
    reg  [19:0]  FrameStrobe = 20'b0;
    wire [31:0]  FrameData_O;
    wire [19:0]  FrameStrobe_O;
    wire         UserCLKo;
    reg  [15:0]  tin = 16'b0;
    wire [15:0]  tout;

    LOGIC4 dut (
        .N1END(tin[3:0]),   .E1END(tin[7:4]),   .S1END(tin[11:8]),  .W1END(tin[15:12]),
        .N1BEG(tout[3:0]),  .E1BEG(tout[7:4]),  .S1BEG(tout[11:8]), .W1BEG(tout[15:12]),
        .UserCLK(clk), .UserCLKo(UserCLKo),
        .FrameData(FrameData), .FrameData_O(FrameData_O),
        .FrameStrobe(FrameStrobe), .FrameStrobe_O(FrameStrobe_O)
    );

    integer checks = 0, failures = 0, i, j, fr;
    integer clk_rise = 0, clk_fall = 0, nd, ns;
    reg [31:0] d_seen0 = 32'b0, d_seen1 = 32'b0;
    reg [19:0] s_seen0 = 20'b0, s_seen1 = 20'b0;
    reg [31:0] lfsr = 32'hace1_1234;

    task automatic step_lfsr;
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    endtask

    // settle, then compare every forwarded output with the driven input (four-state)
    task automatic check(input [255:0] what);
        integer b;
        begin
            #1;
            checks = checks + 3;
            if (UserCLKo !== clk) begin
                failures = failures + 1;
                if (failures <= 20) $display("  mismatch %0s t=%0t: UserCLKo=%b expected %b", what, $time, UserCLKo, clk);
            end
            if (FrameData_O !== FrameData) begin
                failures = failures + 1;
                if (failures <= 20) $display("  mismatch %0s t=%0t: FrameData_O=%b expected %b", what, $time, FrameData_O, FrameData);
            end
            if (FrameStrobe_O !== FrameStrobe) begin
                failures = failures + 1;
                if (failures <= 20) $display("  mismatch %0s t=%0t: FrameStrobe_O=%b expected %b", what, $time, FrameStrobe_O, FrameStrobe);
            end
            for (b = 0; b < 32; b = b + 1) begin
                if (FrameData_O[b] === 1'b0 && FrameData[b] === 1'b0) d_seen0[b] = 1'b1;
                if (FrameData_O[b] === 1'b1 && FrameData[b] === 1'b1) d_seen1[b] = 1'b1;
            end
            for (b = 0; b < 20; b = b + 1) begin
                if (FrameStrobe_O[b] === 1'b0 && FrameStrobe[b] === 1'b0) s_seen0[b] = 1'b1;
                if (FrameStrobe_O[b] === 1'b1 && FrameStrobe[b] === 1'b1) s_seen1[b] = 1'b1;
            end
        end
    endtask

    // clock edge, checked after the edge; counted only when UserCLKo followed it
    task automatic set_clk(input v, input [255:0] what);
        begin
            clk = v;
            check(what);
            if (UserCLKo === v) begin
                if (v) clk_rise = clk_rise + 1; else clk_fall = clk_fall + 1;
            end
        end
    endtask

    task automatic drive(input [31:0] d, input [19:0] s, input [255:0] what);
        begin
            FrameData = d; FrameStrobe = s;
            check(what);
        end
    endtask

    initial begin
        // phase 1: initial state, clock levels and repeated edges
        check("initial");
        for (i = 0; i < 16; i = i + 1) begin
            set_clk(1'b1, "clk rise");
            set_clk(1'b0, "clk fall");
        end
        // short pulse train with the frame ports changing between edges
        for (i = 0; i < 8; i = i + 1) begin
            step_lfsr; FrameData = lfsr; FrameStrobe = 20'b0;
            set_clk(1'b1, "clk+data rise");
            set_clk(1'b0, "clk+data fall");
        end
        set_clk(1'b1, "clk hold high");
        drive(32'hffff_ffff, 20'b0, "clk high, data all-ones");
        set_clk(1'b0, "clk low");

        // phase 2: walking one / walking zero over all 32 data bits (strobes idle)
        for (i = 0; i < 32; i = i + 1) begin
            drive(32'b1 << i, 20'b0, "data walking-one");
            drive(~(32'b1 << i), 20'b0, "data walking-zero");
            set_clk(i[0], "clk during data walk");
        end

        // phase 3: walking one / walking zero over all 20 strobe bits, data changing
        for (i = 0; i < 20; i = i + 1) begin
            step_lfsr;
            drive(lfsr, 20'b1 << i, "strobe walking-one");
            drive(~lfsr, ~(20'b1 << i), "strobe walking-zero");
            set_clk(i[0], "clk during strobe walk");
        end
        drive(32'b0, 20'b0, "release strobes");

        // phase 4: idle strobes with changing data
        drive(32'h0000_0000, 20'b0, "idle strobe, data all-zero");
        drive(32'hffff_ffff, 20'b0, "idle strobe, data all-ones");
        drive(32'h5555_5555, 20'b0, "idle strobe, data 0101");
        drive(32'haaaa_aaaa, 20'b0, "idle strobe, data 1010");
        for (i = 0; i < 32; i = i + 1) begin
            step_lfsr;
            drive(lfsr, 20'b0, "idle strobe, data lfsr");
            set_clk(i[0], "clk during idle strobe");
        end

        // phase 5: normal legal frame writes, clock toggling between steps
        for (j = 0; j < 2; j = j + 1) begin
            for (fr = 0; fr < 20; fr = fr + 1) begin
                step_lfsr;
                FrameData = (j == 0) ? lfsr : ~lfsr; check("write data");
                FrameStrobe = 20'b0; FrameStrobe[fr] = 1'b1; check("write strobe");
                set_clk(1'b1, "write clk rise");
                FrameStrobe = 20'b0; check("write release");
                FrameData = ~FrameData ^ 32'h5a5a_a5a5; check("write data change");
                set_clk(1'b0, "write clk fall");
            end
        end
        drive(32'b0, 20'b0, "final idle");

        nd = 0; ns = 0;
        for (i = 0; i < 32; i = i + 1) if (d_seen0[i] && d_seen1[i]) nd = nd + 1;
        for (i = 0; i < 20; i = i + 1) if (s_seen0[i] && s_seen1[i]) ns = ns + 1;
        $display("COVERAGE: UserCLKo %0d rising and %0d falling edges followed", clk_rise, clk_fall);
        $display("COVERAGE: FrameData_O %0d/32 bits forwarded at both levels", nd);
        $display("COVERAGE: FrameStrobe_O %0d/20 bits forwarded at both levels", ns);
        if (clk_rise < 16 || clk_fall < 16 || nd != 32 || ns != 20) begin
            // coverage is only meaningful for a forwarding that works; a gap
            // caused by a failing port is reported as the functional FAIL below
            if (failures == 0) begin
                $display("FAIL: tb_boundary_fwd: incomplete forwarding coverage");
                $finish;
            end
        end
        if (failures == 0)
            $display("PASS: tb_boundary_fwd[fwd] (%0d checks, 0 failures; UserCLKo + FrameData_O[31:0] + FrameStrobe_O[19:0])", checks);
        else
            $display("FAIL: tb_boundary_fwd[fwd] (%0d checks, %0d failures, 0 perturbations survived)", checks, failures);
        $finish;
    end
`endif
endmodule
