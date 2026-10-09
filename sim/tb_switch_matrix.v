// tb_switch_matrix.v
//
// Self-checking testbench for the generated LOGIC4 switch matrix
// (design/rtl/logic_tile_switch_matrix.v).  Convention: prints
// "PASS: tb_switch_matrix -- ..." or "FAIL: ..." (see sim/run.sh).
//
// Checks:
//  1. Table-driven (sim/switch_matrix_tb_gen.vh, generated from the same
//     FABulous list): for every LUT-input and track-driver mux and every
//     select value, the sink follows the listed source in both polarities
//     (selected source toggles while all others are held at the opposite
//     value, so a wrong/merged source is caught), and an out-of-range
//     select drives 0.
//  2. Hand-written spot checks of the documented topology (independent of
//     the table): LUT-input same-index tracks, track-driver populations,
//     and the J_EN/J_SR jump paths into the BEL EN/SR pins.
// No timing is checked or claimed.

`default_nettype none
`timescale 1ns/1ps

module tb_switch_matrix;

    reg [89:0] cfg;
    reg [19:0] srcr;
    `include "switch_matrix_tb_gen.vh"
    assign src = srcr;

    integer checks = 0;
    integer errors = 0;

    task check1(input actual, input expected, input [255:0] what);
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                errors = errors + 1;
                $display("  MISMATCH %0s: got %b expected %b (cfg=%h src=%h)",
                         what, actual, expected, cfg, srcr);
            end
        end
    endtask

    // Source index map (matches generated port order, = FABulous input-port
    // order): 0..15 = 4*dir+idx with dir N,E,S,W; 16..19 = LA_O..LD_O.
    // Sink map (= FABulous output-port order): 0..15 = N/E/S/W1BEG0..3
    // (4*dir+idx); 16+6*bel+{0..3} = L?_I0..3, +4 = L?_SR, +5 = L?_EN.
    // cfg layout: BEG k at cfg[3k+:3]; L{bel}_I{p} at cfg[48+2*(4*bel+p)+:2];
    // J_SR_BEG0 at cfg[80+:2]; J_EN_BEGi at cfg[82+2i+:2].
    integer r, s, k, n, bitv, d, i;
    reg [89:0] mask;

    task drive_one(input integer sink, input integer srcidx, input integer sel_off,
                   input integer sel_w, input integer sel, input [255:0] what);
        begin
            cfg = 0;
            cfg = cfg | (sel << sel_off);
            srcr = {20{1'b1}}; srcr[srcidx] = 1'b0; #1;
            check1(snk[sink], 1'b0, what);
            srcr = {20{1'b0}}; srcr[srcidx] = 1'b1; #1;
            check1(snk[sink], 1'b1, what);
        end
    endtask

    initial begin
        load_table;

        // 1. table-driven
        for (r = 0; r < NROW; r = r + 1) begin
            for (s = 0; s < tbl_n[r]; s = s + 1)
                drive_one(tbl_snk[r], tbl_src[r*MAXFAN + s], tbl_off[r], tbl_w[r], s, "table");
            if ((1 << tbl_w[r]) > tbl_n[r]) begin
                cfg = 0; cfg = cfg | (tbl_n[r] << tbl_off[r]);
                srcr = {20{1'b1}}; #1;
                check1(snk[tbl_snk[r]], 1'b0, "out-of-range select");
            end
        end

        // 2. spot checks
        // LA_I2 (sink 18, cfg[53:52]): N,E,S,W of track 2 -> src 4*d+2
        // LD_I3 (sink 37, cfg[79:78]): N,E,S,W of track 3 -> src 4*d+3
        for (d = 0; d < 4; d = d + 1) begin
            drive_one(18, 4*d + 2, 52, 2, d, "LA_I2 track2");
            drive_one(37, 4*d + 3, 78, 2, d, "LD_I3 track3");
        end
        // N1BEG0 (sink 0, cfg[2:0]): sel0..2 = E,S,W track0, sel3..6 = LA_O..LD_O
        for (d = 0; d < 4; d = d + 1)
            drive_one(0, 16 + d, 0, 3, 3 + d, "N1BEG0 BEL out");
        drive_one(0, 4,  0, 3, 0, "N1BEG0 <- E1END0");
        drive_one(0, 8,  0, 3, 1, "N1BEG0 <- S1END0");
        drive_one(0, 12, 0, 3, 2, "N1BEG0 <- W1END0");
        // W1BEG0 (sink 12, cfg[38:36]): sel0..2 = N,E,S track0
        drive_one(12, 0, 36, 3, 0, "W1BEG0 <- N1END0");
        drive_one(12, 4, 36, 3, 1, "W1BEG0 <- E1END0");
        drive_one(12, 8, 36, 3, 2, "W1BEG0 <- S1END0");

        // J_EN_BEGi at cfg[82+2i +: 2] -> L?_EN (sink 21+6i); J_SR_BEG0 at cfg[80 +: 2].
        for (i = 0; i < 4; i = i + 1)
            for (d = 0; d < 4; d = d + 1) begin
                drive_one(21 + 6*i, 4*d + i, 82 + 2*i, 2, d, "J_EN -> L?_EN");
            end
        for (d = 0; d < 4; d = d + 1) begin
            cfg = 0; cfg = cfg | (d << 80);
            srcr = {20{1'b1}}; srcr[4*d] = 1'b0; #1;
            for (i = 0; i < 4; i = i + 1) check1(snk[20 + 6*i], 1'b0, "J_SR -> L?_SR (0)");
            srcr = {20{1'b0}}; srcr[4*d] = 1'b1; #1;
            for (i = 0; i < 4; i = i + 1) check1(snk[20 + 6*i], 1'b1, "J_SR -> L?_SR (1)");
        end

        // structural count sanity
        checks = checks + 1;
        if (CFGW !== 90 || NROW !== 32) begin
            errors = errors + 1;
            $display("  unexpected matrix size CFGW=%0d NROW=%0d", CFGW, NROW);
        end

        if (errors == 0)
            $display("PASS: tb_switch_matrix -- %0d checks, 0 failures", checks);
        else
            $display("FAIL: tb_switch_matrix -- %0d checks, %0d failures", checks, errors);
        $finish;
    end

endmodule

`default_nettype wire
