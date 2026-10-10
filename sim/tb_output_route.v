// tb_output_route.v -- boundary output-track source diagnostic (issue #180, EXPERIMENTAL G5)
//
// Proves, through the integrated tile and frame programming, that every source
// the matrix offers a boundary OUTPUT track (4 edges x 4 tracks x 7 sources =
// 112 (output edge, track, source) routes: the four BEL outputs and the three
// same-index incoming tracks of the other edges) reaches that track. Streams
// come from flow/output_route.py (assembler-generated, NOT mapper output) and
// are loaded one after another into ONE live tile, in list order, with no reset
// between them, so every case reprograms the select fields of the previous one.
// The tile boundary is observed directly: stimulus is applied to the 16 incoming
// tracks and all 16 outgoing tracks are read; there are no CAP loopbacks, so no
// combinational feedback path exists.
//
// Inputs (plusargs):
//   +dir=<dir>      directory holding <case>.bin
//   +list=<file>    "<case> <edge N|E|S|W> <track 0-3> <src A-D|N|E|S|W> <16 background tokens>"
//   +wiring=<file>  GRID/TILE, END
//   +map=<file>     "cfg_index frame_position" (repository composition only)
//
// Oracle (independent of the DUT's bit-index derivation): every case routes
// ALL 16 output tracks; the token string gives the source of output track
// 4*edge+track (BEL output A-D, or the incoming track of that index on the named
// edge). BEL X is (NOT, for B and D) the incoming track <E>1END<k> of the tested
// edge E with k = index of X (A=0..D=3). For each of NENV environments of the
// other tracks, the tested edge's four tracks and the three incoming candidates
// of the tested track take ALL 2^7 combinations, so the selected source toggles
// while every unselected candidate takes every value (including all six opposite
// to it) and the four BELs take every combination of values. Expected value of
// each of the 16 outputs = value of its token's source under the applied
// stimulus; all 16 outputs are checked every pattern, so a wrong source on any
// track and an aliased sink both show. cfg / map / ConfigBits / internal mux
// signals are never read for an expectation (the CFG lines are only a storage
// cross-check by the script).
//
// Compile-time DUT choice (same adapter as sim/tb_route_diag.v):
//   default      design/rtl/logic_tile_routed.v through its flat 158-bit cfg port
//   -DGEN_TILE   the FABulous-generated LOGIC4, configured ONLY by legal frame
//                writes on FrameData/FrameStrobe, every frame of every stream.
`timescale 1ns/1ps

module tb_output_route;

    reg          clk = 1'b0;
    reg  [157:0] cfg = 158'b0;
    reg  [15:0]  tin = 16'b0;   // tin[4*dir + idx], dir: 0=N 1=E 2=S 3=W
    wire [15:0]  tout;

`ifdef GEN_TILE
    reg  [31:0] FrameData   = 32'b0;
    reg  [19:0] FrameStrobe = 20'b0;
    wire [31:0] FrameData_O;
    wire [19:0] FrameStrobe_O;
    wire        UserCLKo;
    LOGIC4 dut (
        .N1END(tin[3:0]),   .E1END(tin[7:4]),   .S1END(tin[11:8]),  .W1END(tin[15:12]),
        .N1BEG(tout[3:0]),  .E1BEG(tout[7:4]),  .S1BEG(tout[11:8]), .W1BEG(tout[15:12]),
        .UserCLK(clk), .UserCLKo(UserCLKo),
        .FrameData(FrameData), .FrameData_O(FrameData_O),
        .FrameStrobe(FrameStrobe), .FrameStrobe_O(FrameStrobe_O)
    );
`else
    logic_tile_routed dut (
        .clk(clk), .cfg(cfg),
        .n_in(tin[3:0]),  .e_in(tin[7:4]),  .s_in(tin[11:8]),  .w_in(tin[15:12]),
        .n_out(tout[3:0]), .e_out(tout[7:4]), .s_out(tout[11:8]), .w_out(tout[15:12])
    );
`endif

    localparam CFG_N = 158;
    localparam FBITS = 32, NFR = 20, SELW = 5, DESYNC_BIT = 20;
    localparam [159:0] SYNC = 160'h00AAFF01000000010000000000000000FAB0FAB1;
    localparam NENV = 6;

    reg [8*256-1:0] f_dir, f_list, f_wire, f_map, f_bin;
    integer fd, grid_cols, grid_rows, lx, ly;
    integer cb_pos [0:CFG_N-1];
    reg [31:0] logic_frame [0:NFR-1];
    reg        seen_frame  [0:(8*NFR)-1];
    reg        load_ok;
    reg [8*80-1:0] reject_reason;
    integer n_frame_writes = 0;

    // -------------------------------------------------------------- readers
    task read_map;
        integer i, cb, pos, r;
        begin
            for (i = 0; i < CFG_N; i = i + 1) cb_pos[i] = -1;
            fd = $fopen(f_map, "r");
            if (fd == 0) begin $display("FAIL: tb_output_route: cannot open map"); $finish; end
            r = $fscanf(fd, "%d %d", cb, pos);
            while (r == 2) begin
                cb_pos[cb] = pos;
                r = $fscanf(fd, "%d %d", cb, pos);
            end
            $fclose(fd);
            for (i = 0; i < CFG_N; i = i + 1)
                if (cb_pos[i] < 0) begin $display("FAIL: tb_output_route: map misses cfg bit %0d", i); $finish; end
        end
    endtask

    task read_wiring;
        reg [8*8-1:0] kw;
        integer d1, d2, r, ok_all, end_seen;
        begin
            ok_all = 1; end_seen = 0; grid_cols = 0; grid_rows = 0; lx = -1; ly = -1;
            fd = $fopen(f_wire, "r");
            if (fd == 0) begin $display("FAIL: tb_output_route: cannot open wiring"); $finish; end
            r = $fscanf(fd, "%s", kw);
            while (r == 1 && !end_seen) begin
                if (kw == "GRID") r = $fscanf(fd, "%d %d", grid_cols, grid_rows);
                else if (kw == "TILE") r = $fscanf(fd, "%d %d", lx, ly);
                else if (kw == "END") end_seen = 1;
                else ok_all = 0;
                if (!end_seen) r = $fscanf(fd, "%s", kw);
            end
            $fclose(fd);
            if (!ok_all || !end_seen || grid_cols < 1 || grid_rows < 3) begin
                $display("FAIL: tb_output_route: bad wiring manifest"); $finish;
            end
        end
    endtask

    // ---------------------------------------------------------------- loader
    task rd_word(output [31:0] w, output ok);
        integer i, b;
        begin
            w = 0; ok = 1'b1;
            for (i = 0; i < FBITS/8; i = i + 1) begin
                b = $fgetc(fd);
                if (b < 0) ok = 1'b0; else w = {w[23:0], b[7:0]};
            end
        end
    endtask

    task reject(input [8*80-1:0] why);
        begin if (load_ok) reject_reason = why; load_ok = 1'b0; end
    endtask

    // one legal frame write into the generated tile (no-op for the repository composition)
    task write_frame(input integer fr, input [31:0] data);
        begin
`ifdef GEN_TILE
            FrameData = data; #1;
            FrameStrobe = 20'b0; FrameStrobe[fr] = 1'b1; #1;
            FrameStrobe = 20'b0; #1;
            FrameData = ~data ^ 32'h5a5a_a5a5; #1;
            n_frame_writes = n_frame_writes + 1;
`endif
        end
    endtask

    task load_bitstream;
        reg [31:0] w, fw;
        reg ok;
        integer i, b, col, frame, nframes, order, pop, done;
        reg [159:0] hdr;
        begin
            load_ok = 1'b1; reject_reason = "";
            for (i = 0; i < NFR; i = i + 1) logic_frame[i] = 32'b0;
            for (i = 0; i < 8*NFR; i = i + 1) seen_frame[i] = 1'b0;
            fd = $fopen(f_bin, "rb");
            if (fd == 0) begin reject("cannot open bitstream"); disable load_bitstream; end
            hdr = 0;
            for (i = 0; i < 20; i = i + 1) begin
                b = $fgetc(fd);
                if (b < 0) begin reject("truncated sync header"); i = 99; end
                else hdr = {hdr[151:0], b[7:0]};
            end
            if (load_ok && hdr !== SYNC) reject("bad sync header");
            nframes = 0; done = 0;
            while (load_ok && !done) begin
                rd_word(w, ok);
                if (!ok) reject("truncated: no desync word");
                else if (w[DESYNC_BIT] && w[FBITS-1:FBITS-SELW] == 0 && w[NFR-1:0] == 0) begin
                    if (w !== (32'b1 << DESYNC_BIT)) reject("malformed desync word");
                    done = 1;
                end else begin
                    col = w[FBITS-1:FBITS-SELW];
                    pop = 0;
                    for (i = 0; i < NFR; i = i + 1) if (w[i]) begin pop = pop + 1; frame = i; end
                    if (w[FBITS-SELW-1:NFR] != 0 || pop != 1 || col >= grid_cols) reject("invalid frame-select word");
                    else if (seen_frame[col*NFR + frame]) reject("duplicate frame");
                    else begin
                        seen_frame[col*NFR + frame] = 1'b1;
                        nframes = nframes + 1;
                        for (order = 0; order < grid_rows - 2; order = order + 1) begin
                            rd_word(fw, ok);
                            if (!ok) reject("truncated frame data");
                            else if (col == lx && (grid_rows - 2 - order) == ly) begin
                                logic_frame[frame] = fw;
                                write_frame(frame, fw);   // GEN_TILE: every frame, zero or not
                            end else if (fw != 0) reject("data for a tile without config bits");
                        end
                    end
                end
            end
            if (load_ok) begin
                if ($fgetc(fd) >= 0) reject("trailing data after desync");
                if (nframes != grid_cols * NFR) reject("incomplete frame set");
            end
            $fclose(fd);
`ifndef GEN_TILE
            if (load_ok)
                for (i = 0; i < CFG_N; i = i + 1)
                    cfg[i] = logic_frame[cb_pos[i] / FBITS][cb_pos[i] % FBITS];
`endif
        end
    endtask

    // ------------------------------------------------------------ the checks
    // token code: N0 E1 S2 W3 (incoming track of that edge), A4 B5 C6 D7 (BEL output)
    function integer tokcode(input [7:0] ch);
        begin
            case (ch)
                "N": tokcode = 0;  "E": tokcode = 1;  "S": tokcode = 2;  "W": tokcode = 3;
                "A": tokcode = 4;  "B": tokcode = 5;  "C": tokcode = 6;  "D": tokcode = 7;
                default: tokcode = -1;
            endcase
        end
    endfunction

    function [15:0] env_pat(input integer e);
        begin
            case (e)
                0: env_pat = 16'h0000;  1: env_pat = 16'hFFFF;  2: env_pat = 16'hAAAA;
                3: env_pat = 16'hCCCC;  4: env_pat = 16'hF0F0;  default: env_pat = 16'hFF00;
            endcase
        end
    endfunction

    integer checks = 0, fails = 0, case_fails = 0, ncase = 0, adv_checks = 0, dup_ids = 0;
    integer route_hits [0:127];   // (4*edge+track)*8 + token code -> cases seen
    integer route_chk  [0:127];   // ... -> stimulus patterns checked
    integer route_tog  [0:127];   // ... -> bit0: tested output seen 0, bit1: seen 1
    integer route_adv  [0:127];   // ... -> bit0/bit1: tested output 0/1 while all six other candidates opposite
    reg [8*16-1:0] cid, cbg;
    reg [8*4-1:0]  cedge, csrc;
    integer ctrack, edx, sc, r, e, v, k, cf, first_shown, n, idx, tn, j, nt, ne, tc, bi, opp, o;
    reg [15:0] cand_tin;
    reg expect_o, got, sel_v;
    reg [3:0] bel_v;
    reg [8*16-1:0] seen_ids [0:255];
    integer nseen;
    integer others [0:2];

    function value_of(input integer code, input integer track);   // value of a source token under tin
        begin
            if (code >= 4) value_of = bel_v[code - 4];
            else            value_of = tin[4*code + track];
        end
    endfunction

    initial begin
        if (!$value$plusargs("dir=%s", f_dir) || !$value$plusargs("list=%s", f_list) ||
            !$value$plusargs("wiring=%s", f_wire) || !$value$plusargs("map=%s", f_map)) begin
            $display("FAIL: tb_output_route: need +dir= +list= +wiring= +map=");
            $finish;
        end
        for (n = 0; n < 128; n = n + 1) begin route_hits[n] = 0; route_chk[n] = 0; route_tog[n] = 0; route_adv[n] = 0; end
        nseen = 0;
        read_map;
        read_wiring;
        fd = $fopen(f_list, "r");
        if (fd == 0) begin $display("FAIL: tb_output_route: cannot open case list"); $finish; end
        begin : read_cases
            integer lfd;
            lfd = fd;
            r = $fscanf(lfd, "%s %s %d %s %s", cid, cedge, ctrack, csrc, cbg);
            while (r == 5) begin
                edx = (cedge == "N") ? 0 : (cedge == "E") ? 1 : (cedge == "S") ? 2 : (cedge == "W") ? 3 : -1;
                sc  = tokcode(csrc[7:0]);
                if (edx < 0 || ctrack < 0 || ctrack > 3 || sc < 0 || csrc[15:8] != 0 || sc == edx) begin
                    $display("FAIL: tb_output_route: malformed case line for %0s", cid); $finish;
                end
                for (n = 0; n < 16; n = n + 1)
                    if (tokcode(cbg[8*(15-n) +: 8]) < 0 || tokcode(cbg[8*(15-n) +: 8]) == n/4) begin
                        $display("FAIL: tb_output_route: malformed background token string for %0s", cid); $finish;
                    end
                tn = 4*edx + ctrack;
                if (tokcode(cbg[8*(15-tn) +: 8]) != sc) begin
                    $display("FAIL: tb_output_route: background string disagrees with the tested source for %0s", cid); $finish;
                end
                for (k = 0; k < nseen; k = k + 1) if (seen_ids[k] == cid) dup_ids = dup_ids + 1;
                seen_ids[nseen] = cid; nseen = nseen + 1;
                $sformat(f_bin, "%0s/%0s.bin", f_dir, cid);
                load_bitstream;
                if (!load_ok) begin
                    $display("FAIL: tb_output_route: loader rejected case %0s: %0s", cid, reject_reason); $finish;
                end
`ifdef GEN_TILE
                $display("CFG %0s %040h", cid, {2'b00, dut.ConfigBits});
`else
                $display("CFG %0s %040h", cid, {2'b00, cfg});
`endif
                ncase = ncase + 1;
                idx = 8*tn + sc;
                route_hits[idx] = route_hits[idx] + 1;
                // the three edges other than the tested one, in N,E,S,W order
                j = 0;
                for (k = 0; k < 4; k = k + 1) if (k != edx) begin others[j] = k; j = j + 1; end
                cf = 0; first_shown = 0;
                for (e = 0; e < NENV; e = e + 1) begin
                    for (v = 0; v < 128; v = v + 1) begin
                        tin = env_pat(e);
                        for (k = 0; k < 4; k = k + 1) tin[4*edx + k] = v[k];       // BEL input pins
                        for (j = 0; j < 3; j = j + 1) tin[4*others[j] + ctrack] = v[4 + j];   // incoming candidates
                        #1;
                        // BEL X value = (NOT for B, D) of the tested edge's track X
                        bel_v = {~tin[4*edx + 3], tin[4*edx + 2], ~tin[4*edx + 1], tin[4*edx + 0]};
                        for (n = 0; n < 16; n = n + 1) begin
                            nt = n % 4; ne = n / 4;
                            tc = tokcode(cbg[8*(15-n) +: 8]);
                            expect_o = value_of(tc, nt);
                            got = tout[4*ne + nt];
                            checks = checks + 1;
                            if (got !== expect_o) begin
                                cf = cf + 1;
                                if (!first_shown)
                                    $display("  case %0s: mismatch output %c1BEG%0d (source %c): got %b want %b (stimulus env %0d pattern %0d)",
                                             cid, "NESW" >> (8*(3-ne)), nt, cbg[8*(15-n) +: 8], got, expect_o, e, v);
                                first_shown = 1;
                            end
                        end
                        // coverage bookkeeping for the tested route (value read from the stimulus, not the DUT)
                        sel_v = value_of(sc, ctrack);
                        opp = 1;
                        for (o = 0; o < 8; o = o + 1)
                            if (o != edx && o != sc && !(o < 4 && o == edx) && value_of(o, ctrack) == sel_v) opp = 0;
                        route_chk[idx] = route_chk[idx] + 1;
                        route_tog[idx] = route_tog[idx] | (sel_v ? 2 : 1);
                        if (opp) begin
                            route_adv[idx] = route_adv[idx] | (sel_v ? 2 : 1);
                            adv_checks = adv_checks + 1;
                        end
                    end
                end
                if (cf > 0) begin
                    case_fails = case_fails + 1;
                    $display("  case %0s: %0d mismatches", cid, cf);
                end
                fails = fails + cf;
                r = $fscanf(lfd, "%s %s %d %s %s", cid, cedge, ctrack, csrc, cbg);
            end
            $fclose(lfd);
        end

        // coverage report: one line per (edge, track, source); only a route seen exactly once with
        // the full stimulus set, both selected values and both values against all-opposite
        // candidates is reported as covered
        begin : coverage
            integer ee, tt, ss, ncov;
            ncov = 0;
            for (ee = 0; ee < 4; ee = ee + 1)
                for (tt = 0; tt < 4; tt = tt + 1)
                    for (ss = 0; ss < 8; ss = ss + 1) begin
                        k = 8*(4*ee + tt) + ss;
                        if (ss == ee) begin
                            if (route_hits[k] != 0) begin
                                $display("COVERAGE: ROUTE %c %0d %c: ILLEGAL (a track is not its own source; cases=%0d)",
                                         "NESW" >> (8*(3-ee)), tt, "NESWABCD" >> (8*(7-ss)), route_hits[k]);
                                ncov = ncov + 1000;
                            end
                        end else if (route_hits[k] == 1 && route_chk[k] == 128*NENV && route_tog[k] == 3 && route_adv[k] == 3) begin
                            ncov = ncov + 1;
                            $display("COVERAGE: ROUTE %c %0d %c: selected source toggled against all-opposite unselected candidates, 128 patterns x %0d environments x 16 output tracks",
                                     "NESW" >> (8*(3-ee)), tt, "NESWABCD" >> (8*(7-ss)), NENV);
                        end else
                            $display("COVERAGE: ROUTE %c %0d %c: INCOMPLETE (cases=%0d patterns=%0d toggled=%0d opposite=%0d)",
                                     "NESW" >> (8*(3-ee)), tt, "NESWABCD" >> (8*(7-ss)), route_hits[k], route_chk[k], route_tog[k], route_adv[k]);
                    end
            $display("COVERAGE: %0d/112 routes (4 edges x 4 tracks x 7 sources); %0d cases loaded in sequence into one live tile; %0d adversarial selected-vs-all-unselected-disagree patterns; %0d duplicate case ids",
                     ncov, ncase, adv_checks, dup_ids);
`ifdef GEN_TILE
            $display("GEN_TILE: %0d frame writes through FrameData/FrameStrobe (%0d streams x %0d frames)",
                     n_frame_writes, ncase, NFR);
`endif
            if (ncov != 112 || ncase != 112 || dup_ids != 0) begin
                $display("FAIL: tb_output_route: incomplete output-route coverage: %0d/112 routes, %0d cases, %0d duplicates",
                         ncov, ncase, dup_ids);
                $finish;
            end
        end

        if (fails == 0)
            $display("PASS: tb_output_route[outroute] (%0d checks, 0 failures; %0d/%0d cases)", checks, ncase, ncase);
        else begin
            $display("routes failed: %0d/%0d", case_fails, ncase);
            $display("FAIL: tb_output_route[outroute] (%0d checks, %0d failures, 0 perturbations survived)",
                     checks, fails);
        end
        $finish;
    end

endmodule
