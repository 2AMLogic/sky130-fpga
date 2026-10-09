// tb_logic_tile_gapfill.v
//
// Coverage-gap fill found by the RTL mutation check (issue #124,
// sim/mutation.py). The pre-existing testbenches left three single-point
// wiring mutants alive; this bench kills them without editing those benches
// (whose check counts are quoted in append-only gate-level evidence files):
//
//   A. logic_tile.v: tb_logic_tile drove the SAME 4-bit input to all four
//      slices and used only reg_sel = 0000/1111, so rotating the per-slice
//      `in` slicing or swapping reg_sel[i] <-> reg_sel[3-i] was invisible.
//      Here every slice gets an independent random truth table and input
//      nibble, and every reg_sel pattern (0..15) is exercised, including
//      comb/registered hold behaviour after the inputs change.
//   B. logic_tile_routed.v: EN selects with the top bit set (S/W sources),
//      notably BEL3's cfg[89], were never exercised by the composed-tile
//      benches. Here every BEL's EN is routed from each of the four edges
//      and must capture only when the SELECTED track is high.

`default_nettype none
`timescale 1ns/1ps

module tb_logic_tile_gapfill;

    integer errors = 0;
    integer checks = 0;
    integer seed = 32'h124;

    // ---------------- A. logic_tile ----------------
    reg          clk = 0;
    reg          rst = 0;
    reg  [3:0]   ce = 4'b1111;
    reg  [15:0]  in = 16'h0;
    reg  [63:0]  lut_init = 64'h0;
    reg  [3:0]   reg_sel = 4'h0;
    wire [3:0]   out;

    logic_tile u_tile (.clk(clk), .rst(rst), .ce(ce), .in(in),
                       .lut_init(lut_init), .reg_sel(reg_sel), .out(out));

    // ---------------- B. logic_tile_routed ----------------
    reg  [157:0] cfg = 158'd0;
    reg  [3:0]   tin [0:3];       // 0=N 1=E 2=S 3=W
    wire [3:0]   n_out, e_out, s_out, w_out;

    logic_tile_routed u_rt (
        .clk(clk), .cfg(cfg),
        .n_in(tin[0]), .e_in(tin[1]), .s_in(tin[2]), .w_in(tin[3]),
        .n_out(n_out), .e_out(e_out), .s_out(s_out), .w_out(w_out));

    always #5 clk = ~clk;

    task check(input [255:0] what, input [3:0] got, input [3:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL: %0s got=%b exp=%b (t=%0t)", what, got, exp, $time);
            end
        end
    endtask

    function [3:0] lut_vec(input [63:0] init, input [15:0] inp);
        integer s;
        begin
            for (s = 0; s < 4; s = s + 1) lut_vec[s] = init[16*s + inp[4*s +: 4]];
        end
    endfunction

    integer rs, rep, n, d, dsr, k, e;
    reg [3:0] q, old_q, comb;
    reg [15:0] mask;

    task en_step(input [255:0] what, input dat, input sel_en, input noise, input exp,
                 input integer nn, input integer dd, input integer kk, input integer dsrr);
        integer ee;
        begin
            tin[0][kk] = dat;
            for (ee = 0; ee < 4; ee = ee + 1)
                if (!(ee == dsrr && nn == 0))   // keep the SR track low
                    tin[ee][nn] = (ee == dd) ? sel_en : noise;
            @(posedge clk); #1;
            check(what, {3'b000, w_out[nn]}, {3'b000, exp});
        end
    endtask

    initial begin
        for (e = 0; e < 4; e = e + 1) tin[e] = 4'h0;

        // ---- A. per-slice independence + every reg_sel pattern ----------
        for (rs = 0; rs < 16; rs = rs + 1)
            for (rep = 0; rep < 4; rep = rep + 1) begin
                reg_sel = rs[3:0];
                rst = 1; ce = 4'b1111; @(posedge clk); #1; rst = 0;
                lut_init = {$random(seed), $random(seed)};
                in = $random(seed);
                #1;
                comb = lut_vec(lut_init, in);
                check("reg_sel=0 slices combinational, others at reset 0", out, comb & ~reg_sel);
                @(posedge clk); #1;
                check("registered slices captured LUT", out, comb);
                old_q = comb;
                in = $random(seed);
                #1;
                comb = lut_vec(lut_init, in);
                q = (comb & ~reg_sel) | (old_q & reg_sel);
                check("comb follow input, registered hold", out, q);
            end

        // ---- B. EN source select, every BEL x every edge ----------------
        for (n = 0; n < 4; n = n + 1)
            for (d = 0; d < 4; d = d + 1) begin
                k   = (n + 1) % 4;               // data track index (never == n)
                dsr = (d == 3) ? 2 : 3;          // SR edge: never N, never d
                for (e = 0; e < 4; e = e + 1) tin[e] = 4'h0;
                cfg = 158'd0;
                for (e = 0; e < 16; e = e + 1) mask[e] = e[k];
                cfg[17*n +: 16] = mask;          // LUT = pin k passthrough
                cfg[17*n + 16]  = 1'b1;          // registered
                cfg[68 + 82 + 2*n +: 2] = d[1:0];      // EN_n <- edge d, track n
                cfg[68 + 80 +: 2]       = dsr[1:0];    // SR  <- edge dsr, track 0 (held low)
                cfg[68 + 3*(4*3 + n) +: 3] = 3 + n;    // W1BEG<n> <- BEL n
                en_step("EN selected high, data 0 captured", 1'b0, 1'b1, 1'b0, 1'b0, n, d, k, dsr);
                en_step("EN selected low (others high) holds 0", 1'b1, 1'b0, 1'b1, 1'b0, n, d, k, dsr);
                en_step("EN selected high captures 1",   1'b1, 1'b1, 1'b0, 1'b1, n, d, k, dsr);
                en_step("EN selected low (others high) holds 1", 1'b0, 1'b0, 1'b1, 1'b1, n, d, k, dsr);
            end

        if (errors == 0)
            $display("PASS: tb_logic_tile_gapfill -- %0d checks, 0 failures", checks);
        else
            $display("FAIL: tb_logic_tile_gapfill -- %0d checks, %0d failures", checks, errors);
        $finish;
    end

endmodule

`default_nettype wire
