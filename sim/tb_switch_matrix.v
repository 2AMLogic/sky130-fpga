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

    // Source index map (matches generated port order): 0..15 = 4*idx+dir with
    // dir N,E,S,W; 16..19 = LA_O..LD_O.  Sink map: 0..15 = L{A..D}_I{0..3};
    // 16+2k = L?_EN, 17+2k = L?_SR; 24..39 = N/E/S/W1BEG0..3.
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
        // LA_I2 (sink 2, cfg[5:4]): N,E,S,W of track 2 -> src 8..11
        for (d = 0; d < 4; d = d + 1) begin
            drive_one(2,  8 + d, 4,  2, d, "LA_I2 track2");
            drive_one(15, 12 + d, 30, 2, d, "LD_I3 track3");
        end
        // N1BEG0 (sink 24): sel0..3 = LA_O..LD_O, sel4..6 = E,S,W track0
        // (offset of the track-driver fields is read from the table row)
        for (r = 0; r < NROW; r = r + 1)
            if (tbl_snk[r] == 24) begin
                for (d = 0; d < 4; d = d + 1)
                    drive_one(24, 16 + d, tbl_off[r], 3, d, "N1BEG0 BEL out");
                drive_one(24, 1,  tbl_off[r], 3, 4, "N1BEG0 <- E1END0");
                drive_one(24, 2,  tbl_off[r], 3, 5, "N1BEG0 <- S1END0");
                drive_one(24, 3,  tbl_off[r], 3, 6, "N1BEG0 <- W1END0");
            end
            else if (tbl_snk[r] == 36) begin   // W1BEG0
                drive_one(36, 0, tbl_off[r], 3, 4, "W1BEG0 <- N1END0");
                drive_one(36, 1, tbl_off[r], 3, 5, "W1BEG0 <- E1END0");
                drive_one(36, 2, tbl_off[r], 3, 6, "W1BEG0 <- S1END0");
            end

        // J_EN_BEGi at cfg[80+2i +: 2]; J_SR_BEG0 at cfg[88 +: 2].
        for (i = 0; i < 4; i = i + 1)
            for (d = 0; d < 4; d = d + 1) begin
                drive_one(16 + 2*i, 4*i + d, 80 + 2*i, 2, d, "J_EN -> L?_EN");
            end
        for (d = 0; d < 4; d = d + 1) begin
            cfg = 0; cfg = cfg | (d << 88);
            srcr = {20{1'b1}}; srcr[d] = 1'b0; #1;
            for (i = 0; i < 4; i = i + 1) check1(snk[17 + 2*i], 1'b0, "J_SR -> L?_SR (0)");
            srcr = {20{1'b0}}; srcr[d] = 1'b1; #1;
            for (i = 0; i < 4; i = i + 1) check1(snk[17 + 2*i], 1'b1, "J_SR -> L?_SR (1)");
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
