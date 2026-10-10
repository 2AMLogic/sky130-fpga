// tb_ctrl_route.v -- control-jump directional route diagnostic (issue #181, EXPERIMENTAL G5)
//
// Proves, through the integrated tile and frame programming, that every
// directional source the matrix offers a control-jump mux reaches its
// destination register(s): the four per-BEL enables (J_EN_BEG0..3, 4 edges each
// = 16 routes, each checked on its destination BEL and aliasing-checked on the
// other three) and the shared reset (J_SR_BEG0, 4 edges, each checked on all
// four BELs) = 20 routes. Streams come from flow/ctrl_route.py (assembler-
// generated, NOT mapper output) and are loaded one after another into ONE live
// tile, in list order, with no reset between them, so every case reprograms the
// control select fields of the previous one.
//
// Inputs (plusargs):
//   +dir=<dir>      directory holding <case>.bin
//   +list=<file>    "<case> <EN|SR> <bel A-D|-> <tested edge> <reset edge> <4 enable edges>"
//   +wiring=<file>  GRID/TILE, "OUT <bel> <dir> <idx>", END (the BEL output tracks)
//   +map=<file>     "cfg_index frame_position" (repository composition only)
//
// Every BEL is a registered constant-one function (INIT all ones, FF = 1), so the
// FF next state is: SR ? 0 : (EN ? 1 : hold). The oracle is that reference model
// fed by the stimulus the bench applies on the boundary tracks, nothing else:
// cfg / map / ConfigBits / internal control nets are never read for an
// expectation (the CFG lines are only a storage cross-check by the script). The
// model starts unknown per case; the first phase makes every BEL's state known
// (reset for EN cases, capture for SR cases), and an unknown model state is not
// compared. Control values live on the 16 boundary tracks:
//   idx k = 1..3  enable-k candidates (the four edges' tracks of index k): the
//                 selected edge carries en[k]; the three unselected edges carry
//                 the complement of en[k] while enable k is under test (they
//                 disagree), else en[k] (the route is idle, not under test).
//   idx 0         enable-0 AND reset candidates: enable-0 edge carries en[0],
//                 reset edge carries sr, every other edge carries the complement
//                 of the value of the sink under test (enable 0 or reset), else
//                 en[0]. (A single track cannot disagree with two unrelated
//                 controls; the enable-0/reset selected tracks stay pinned.)
// Each phase: apply stimulus, check the outputs did not move before the clock
// edge, clock once, check the new state.
//   EN case, tested BEL X (all other enables idle low):
//     reset/enable-low clears, capture, hold with unselected enable tracks high,
//     reset clears, hold 0, capture, reset-over-enable, hold 0
//   SR case, tested reset edge (per-BEL enable vectors, one edge per BEL):
//     capture, reset with enables low, recapture, reset over all enables, hold
//     with reset inactive and enables low, mixed-enable captures, mixed-enable
//     reset priority
//
// Compile-time DUT choice (same adapter as sim/tb_route_diag.v):
//   default      design/rtl/logic_tile_routed.v through its flat 158-bit cfg port
//   -DGEN_TILE   the FABulous-generated LOGIC4, configured ONLY by legal frame
//                writes on FrameData/FrameStrobe, every frame of every stream.
`timescale 1ns/1ps

module tb_ctrl_route;

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
    integer out_track [0:3];
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
            if (fd == 0) begin $display("FAIL: tb_ctrl_route: cannot open map"); $finish; end
            r = $fscanf(fd, "%d %d", cb, pos);
            while (r == 2) begin
                cb_pos[cb] = pos;
                r = $fscanf(fd, "%d %d", cb, pos);
            end
            $fclose(fd);
            for (i = 0; i < CFG_N; i = i + 1)
                if (cb_pos[i] < 0) begin $display("FAIL: tb_ctrl_route: map misses cfg bit %0d", i); $finish; end
        end
    endtask

    task read_wiring;
        reg [8*8-1:0] kw, nm;
        integer a, d, k, r, ok_all, end_seen, i, b;
        begin
            for (i = 0; i < 4; i = i + 1) out_track[i] = -1;
            ok_all = 1; end_seen = 0; grid_cols = 0; grid_rows = 0; lx = -1; ly = -1;
            fd = $fopen(f_wire, "r");
            if (fd == 0) begin $display("FAIL: tb_ctrl_route: cannot open wiring"); $finish; end
            r = $fscanf(fd, "%s", kw);
            while (r == 1 && !end_seen) begin
                if (kw == "GRID") r = $fscanf(fd, "%d %d", grid_cols, grid_rows);
                else if (kw == "TILE") r = $fscanf(fd, "%d %d", lx, ly);
                else if (kw == "OUT") begin
                    r = $fscanf(fd, "%s %d %d", nm, d, k);
                    b = (nm == "A") ? 0 : (nm == "B") ? 1 : (nm == "C") ? 2 : (nm == "D") ? 3 : -1;
                    if (b < 0 || out_track[b] != -1) ok_all = 0; else out_track[b] = 4*d + k;
                end else if (kw == "END") end_seen = 1;
                else ok_all = 0;
                if (!end_seen) r = $fscanf(fd, "%s", kw);
            end
            $fclose(fd);
            for (i = 0; i < 4; i = i + 1) if (out_track[i] < 0) ok_all = 0;
            if (!ok_all || !end_seen || grid_cols < 1 || grid_rows < 3) begin
                $display("FAIL: tb_ctrl_route: bad wiring manifest"); $finish;
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
    integer checks = 0, fails = 0, case_fails = 0, ncase = 0, adv_checks = 0, dup_ids = 0, phases_total = 0;
    integer route_hits [0:19];   // EN: 4*bel + edge (0..15), SR: 16 + edge -> cases seen
    integer route_chk  [0:19];   // ... -> phases run
    integer route_tog  [0:19];   // ... -> tested control seen at 0 (bit0) and at 1 (bit1)
    reg [8*16-1:0] cid;
    reg [8*4-1:0]  cbel, cedge, credge, cen_s, ckind;
    integer belx, edx, redx, r, b, cf, first_shown, k, idx, d, nphase, p, nbad;
    integer een [0:3];
    integer is_en, tested_trk_idx, sel_val, n_dis, dd2;
    reg [3:0] qv, qk, en_v, tq;
    reg       sr_v, pre_ok;
    reg [8*16-1:0] seen_ids [0:63];
    integer nseen;

    // stimulus on the 16 boundary tracks (see the header for the rules)
    task apply(input [3:0] en, input sr);
        integer kk, dd;
        reg v;
        begin
            tin = 16'b0;
            for (kk = 1; kk < 4; kk = kk + 1)
                for (dd = 0; dd < 4; dd = dd + 1)
                    tin[4*dd + kk] = (is_en && belx == kk && dd != een[kk]) ? ~en[kk] : en[kk];
            for (dd = 0; dd < 4; dd = dd + 1) begin
                if (dd == een[0])      v = en[0];
                else if (dd == redx)   v = sr;
                else if (!is_en)       v = ~sr;
                else if (belx == 0)    v = ~en[0];
                else                   v = en[0];
                tin[4*dd] = v;
            end
        end
    endtask

    // one phase: apply the stimulus, check no early change, clock once, check the new state
    task phase(input [3:0] en, input sr);
        integer bb, nb;
        begin
            apply(en, sr);
            // disagreement bookkeeping for the control under test
            sel_val = is_en ? en[belx] : sr;
            tested_trk_idx = is_en ? belx : 0;
            n_dis = 0;
            for (dd2 = 0; dd2 < 4; dd2 = dd2 + 1)
                if (dd2 != edx && tin[4*dd2 + tested_trk_idx] !== sel_val[0]) n_dis = n_dis + 1;
            if (n_dis == 3) adv_checks = adv_checks + 1;
            route_tog[idx] = route_tog[idx] | (sel_val ? 2 : 1);
            route_chk[idx] = route_chk[idx] + 1;
            #1;
            nb = 0;
            for (bb = 0; bb < 4; bb = bb + 1) if (qk[bb]) begin
                checks = checks + 1;
                if (tout[out_track[bb]] !== qv[bb]) begin
                    nb = nb + 1;
                    if (!first_shown) $display("  case %0s: early change BEL %c phase %0d: got %b want %b (en=%b sr=%b)",
                                               cid, "A" + bb, p, tout[out_track[bb]], qv[bb], en, sr);
                    first_shown = 1;
                end
            end
            clk = 1'b1; #1;
            for (bb = 0; bb < 4; bb = bb + 1) begin
                if (sr) begin qv[bb] = 1'b0; qk[bb] = 1'b1; end
                else if (en[bb]) begin qv[bb] = 1'b1; qk[bb] = 1'b1; end
            end
            for (bb = 0; bb < 4; bb = bb + 1) if (qk[bb]) begin
                checks = checks + 1;
                if (tout[out_track[bb]] !== qv[bb]) begin
                    nb = nb + 1;
                    if (!first_shown) $display("  case %0s: BEL %c phase %0d: got %b want %b (en=%b sr=%b)",
                                               cid, "A" + bb, p, tout[out_track[bb]], qv[bb], en, sr);
                    first_shown = 1;
                end
            end
            clk = 1'b0; #1;
            cf = cf + nb;
        end
    endtask

    initial begin
        if (!$value$plusargs("dir=%s", f_dir) || !$value$plusargs("list=%s", f_list) ||
            !$value$plusargs("wiring=%s", f_wire) || !$value$plusargs("map=%s", f_map)) begin
            $display("FAIL: tb_ctrl_route: need +dir= +list= +wiring= +map=");
            $finish;
        end
        for (b = 0; b < 20; b = b + 1) begin route_hits[b] = 0; route_chk[b] = 0; route_tog[b] = 0; end
        nseen = 0;
        read_map;
        read_wiring;
        fd = $fopen(f_list, "r");
        if (fd == 0) begin $display("FAIL: tb_ctrl_route: cannot open case list"); $finish; end
        // the case list is read up front (the loader reuses fd)
        begin : read_cases
            integer lfd;
            lfd = fd;
            r = $fscanf(lfd, "%s %s %s %s %s %s", cid, ckind, cbel, cedge, credge, cen_s);
            while (r == 6) begin
                is_en = (ckind == "EN") ? 1 : (ckind == "SR") ? 0 : -1;
                belx = (cbel == "A") ? 0 : (cbel == "B") ? 1 : (cbel == "C") ? 2 : (cbel == "D") ? 3 : -1;
                edx  = (cedge  == "N") ? 0 : (cedge  == "E") ? 1 : (cedge  == "S") ? 2 : (cedge  == "W") ? 3 : -1;
                redx = (credge == "N") ? 0 : (credge == "E") ? 1 : (credge == "S") ? 2 : (credge == "W") ? 3 : -1;
                for (k = 0; k < 4; k = k + 1) begin
                    d = cen_s[8*(3-k) +: 8];
                    een[k] = (d == "N") ? 0 : (d == "E") ? 1 : (d == "S") ? 2 : (d == "W") ? 3 : -1;
                end
                if (is_en < 0 || edx < 0 || redx < 0 || een[0] < 0 || een[1] < 0 || een[2] < 0 || een[3] < 0 ||
                    (is_en == 1 && (belx < 0 || een[belx] != edx)) ||
                    (is_en == 0 && (cbel != "-" || redx != edx)) || een[0] == redx) begin
                    $display("FAIL: tb_ctrl_route: malformed case line for %0s", cid); $finish;
                end
                if (is_en == 0) belx = 0;   // unused by the reset cases' stimulus rules
                for (k = 0; k < nseen; k = k + 1) if (seen_ids[k] == cid) dup_ids = dup_ids + 1;
                seen_ids[nseen] = cid; nseen = nseen + 1;
                $sformat(f_bin, "%0s/%0s.bin", f_dir, cid);
                load_bitstream;
                if (!load_ok) begin
                    $display("FAIL: tb_ctrl_route: loader rejected case %0s: %0s", cid, reject_reason); $finish;
                end
`ifdef GEN_TILE
                $display("CFG %0s %040h", cid, {2'b00, dut.ConfigBits});
`else
                $display("CFG %0s %040h", cid, {2'b00, cfg});
`endif
                ncase = ncase + 1;
                idx = (is_en == 1) ? 4*belx + edx : 16 + edx;
                route_hits[idx] = route_hits[idx] + 1;
                cf = 0; first_shown = 0; qv = 4'b0; qk = 4'b0;
                if (is_en == 1) begin
                    // (enable of BEL X, reset) per phase; all other enables idle low
                    for (p = 0; p < 8; p = p + 1) begin
                        case (p)
                            0: begin en_v = 4'b0; sr_v = 1'b1; end   // reset, enable low: all BELs known 0
                            1: begin en_v = 4'b0; en_v[belx] = 1'b1; sr_v = 1'b0; end   // capture on BEL X only
                            2: begin en_v = 4'b0; sr_v = 1'b0; end   // hold 1 (unselected enable tracks high)
                            3: begin en_v = 4'b0; sr_v = 1'b1; end   // synchronous clear, enable low
                            4: begin en_v = 4'b0; sr_v = 1'b0; end   // hold 0 (unselected tracks high)
                            5: begin en_v = 4'b0; en_v[belx] = 1'b1; sr_v = 1'b0; end
                            6: begin en_v = 4'b0; en_v[belx] = 1'b1; sr_v = 1'b1; end   // reset over enable
                            default: begin en_v = 4'b0; sr_v = 1'b0; end                // hold 0
                        endcase
                        phase(en_v, sr_v);
                    end
                end else begin
                    for (p = 0; p < 11; p = p + 1) begin
                        case (p)
                            0: begin en_v = 4'hF; sr_v = 1'b0; end   // capture all
                            1: begin en_v = 4'h0; sr_v = 1'b1; end   // reset, enables low
                            2: begin en_v = 4'hF; sr_v = 1'b0; end
                            3: begin en_v = 4'hF; sr_v = 1'b1; end   // reset over every enable
                            4: begin en_v = 4'hF; sr_v = 1'b0; end
                            5: begin en_v = 4'h0; sr_v = 1'b0; end   // reset inactive: hold 1 on all BELs
                            6: begin en_v = 4'h0; sr_v = 1'b1; end
                            7: begin en_v = 4'h5; sr_v = 1'b0; end   // per-BEL enables
                            8: begin en_v = 4'hA; sr_v = 1'b1; end   // reset over mixed enables
                            9: begin en_v = 4'hA; sr_v = 1'b0; end
                            default: begin en_v = 4'h5; sr_v = 1'b1; end
                        endcase
                        phase(en_v, sr_v);
                    end
                end
                phases_total = phases_total + p;
                if (cf > 0) begin
                    case_fails = case_fails + 1;
                    $display("  case %0s: %0d mismatches", cid, cf);
                end
                fails = fails + cf;
                r = $fscanf(lfd, "%s %s %s %s %s %s", cid, ckind, cbel, cedge, credge, cen_s);
            end
            $fclose(lfd);
        end

        // coverage report: one line per control route; only a route seen exactly once with
        // its full phase set and the tested control at both 0 and 1 is reported as covered
        begin : coverage
            integer bb, ee, ncov, want;
            ncov = 0;
            for (k = 0; k < 20; k = k + 1) begin
                bb = k / 4; ee = k % 4;
                want = (k < 16) ? 8 : 11;
                if (route_hits[k] == 1 && route_chk[k] == want && route_tog[k] == 3) begin
                    ncov = ncov + 1;
                    if (k < 16)
                        $display("COVERAGE: ROUTE EN %c %c: enable toggled on the selected track against disagreeing unselected tracks; checked on BEL %c and the 3 other BELs",
                                 "A" + bb, ((ee == 0) ? "N" : (ee == 1) ? "E" : (ee == 2) ? "S" : "W"), "A" + bb);
                    else
                        $display("COVERAGE: ROUTE SR - %c: reset toggled on the selected track against disagreeing unselected tracks; checked on all 4 BELs",
                                 ((ee == 0) ? "N" : (ee == 1) ? "E" : (ee == 2) ? "S" : "W"));
                end else
                    $display("COVERAGE: ROUTE %0s %c %c: INCOMPLETE (cases=%0d phases=%0d toggled=%0d)",
                             (k < 16) ? "EN" : "SR", (k < 16) ? "A" + bb : "-",
                             ((ee == 0) ? "N" : (ee == 1) ? "E" : (ee == 2) ? "S" : "W"),
                             route_hits[k], route_chk[k], route_tog[k]);
            end
            $display("COVERAGE: %0d/20 routes (16 enable = 4 BELs x 4 edges, 4 shared-reset edges); %0d cases loaded in sequence into one live tile; %0d phases; %0d full-disagreement phases (all unselected candidates opposite the selected control); %0d duplicate case ids",
                     ncov, ncase, phases_total, adv_checks, dup_ids);
`ifdef GEN_TILE
            $display("GEN_TILE: %0d frame writes through FrameData/FrameStrobe (%0d streams x %0d frames)",
                     n_frame_writes, ncase, NFR);
`endif
            if (ncov != 20 || ncase != 20 || dup_ids != 0) begin
                $display("FAIL: tb_ctrl_route: incomplete control-route coverage: %0d/20 routes, %0d cases, %0d duplicates",
                         ncov, ncase, dup_ids);
                $finish;
            end
        end

        if (fails == 0)
            $display("PASS: tb_ctrl_route[ctrl] (%0d checks, 0 failures; %0d/%0d cases)", checks, ncase, ncase);
        else begin
            $display("control routes failed: %0d/%0d", case_fails, ncase);
            $display("FAIL: tb_ctrl_route[ctrl] (%0d checks, %0d failures, 0 perturbations survived)",
                     checks, fails);
        end
        $finish;
    end

endmodule
