// tb_lut_basis.v -- LUT truth-table basis diagnostic (issue #172, EXPERIMENTAL G5)
//
// Proves, through the integrated tile, that every one of the 16 truth-table
// addresses of every one of the four LUT4 BELs (A..D) is selected by exactly
// the matching input vector. Streams come from flow/lut_basis.py (assembler-
// generated, NOT mapper output; see that file for the route set and cases) and
// are loaded one after another into ONE live tile, in list order, with no reset
// in between, so stale configuration from an earlier case is observable.
//
// Inputs (plusargs):
//   +dir=<dir>      directory holding <case>.bin
//   +list=<file>    "<case> <bel A-D|-> <zero|ones|onehot> <addr>" per line
//   +wiring=<file>  GRID/TILE, "IN <lut input> <dir> <idx>", "OUT <bel> <dir> <idx>", END
//   +map=<file>     "cfg_index frame_position" (repository composition only; for
//                   -DGEN_TILE it is read but never used to load the tile)
//
// Oracle (independent of the DUT's bit-index derivation): from the case
// identifier only -- for input vector v = {I3,I2,I1,I0} driven on the four LUT
// input tracks, the output track of BEL b must read
//   onehot X/addr : (b == X) && (v == addr)
//   ones   X      : (b == X)
//   zero          : 0
// for all 16 vectors and under several values on every unrouted input track.
// The cfg / map / ConfigBits are never used to compute an expected value; the
// CFG lines are only a storage cross-check done by the calling script.
//
// Compile-time DUT choice (same adapter as sim/tb_logic_tile_bitstream.v):
//   default      design/rtl/logic_tile_routed.v through its flat 158-bit cfg port
//   -DGEN_TILE   the FABulous-generated LOGIC4, configured ONLY by legal frame
//                writes on FrameData/FrameStrobe, every frame of every stream.
`timescale 1ns/1ps

module tb_lut_basis;

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
    integer in_track [0:3];
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
            if (fd == 0) begin $display("FAIL: tb_lut_basis: cannot open map"); $finish; end
            r = $fscanf(fd, "%d %d", cb, pos);
            while (r == 2) begin
                cb_pos[cb] = pos;
                r = $fscanf(fd, "%d %d", cb, pos);
            end
            $fclose(fd);
            for (i = 0; i < CFG_N; i = i + 1)
                if (cb_pos[i] < 0) begin $display("FAIL: tb_lut_basis: map misses cfg bit %0d", i); $finish; end
        end
    endtask

    task read_wiring;
        reg [8*8-1:0] kw, nm;
        integer a, d, k, r, ok_all, end_seen, i, b;
        begin
            for (i = 0; i < 4; i = i + 1) begin in_track[i] = -1; out_track[i] = -1; end
            ok_all = 1; end_seen = 0; grid_cols = 0; grid_rows = 0; lx = -1; ly = -1;
            fd = $fopen(f_wire, "r");
            if (fd == 0) begin $display("FAIL: tb_lut_basis: cannot open wiring"); $finish; end
            r = $fscanf(fd, "%s", kw);
            while (r == 1 && !end_seen) begin
                if (kw == "GRID") r = $fscanf(fd, "%d %d", grid_cols, grid_rows);
                else if (kw == "TILE") r = $fscanf(fd, "%d %d", lx, ly);
                else if (kw == "IN") begin
                    r = $fscanf(fd, "%d %d %d", a, d, k);
                    if (a < 0 || a > 3 || in_track[a] != -1) ok_all = 0; else in_track[a] = 4*d + k;
                end else if (kw == "OUT") begin
                    r = $fscanf(fd, "%s %d %d", nm, d, k);
                    b = (nm == "A") ? 0 : (nm == "B") ? 1 : (nm == "C") ? 2 : (nm == "D") ? 3 : -1;
                    if (b < 0 || out_track[b] != -1) ok_all = 0; else out_track[b] = 4*d + k;
                end else if (kw == "END") end_seen = 1;
                else ok_all = 0;
                if (!end_seen) r = $fscanf(fd, "%s", kw);
            end
            $fclose(fd);
            for (i = 0; i < 4; i = i + 1) if (in_track[i] < 0 || out_track[i] < 0) ok_all = 0;
            if (!ok_all || !end_seen || grid_cols < 1 || grid_rows < 3) begin
                $display("FAIL: tb_lut_basis: bad wiring manifest"); $finish;
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
    integer checks = 0, fails = 0, case_fails = 0, ncase = 0, n_onehot = 0, n_ones = 0, n_zero = 0;
    integer vec_cov [0:63];      // (bel, addr) -> input vectors checked on that one-hot case
    integer cov_hits [0:63];     // (bel, addr) -> number of one-hot cases seen
    reg [8*16-1:0] cid;
    reg [8*4-1:0]  cbel, ckind_s;
    reg [8*8-1:0]  ckind;
    integer caddr, belx, r, e, v, b, cf, first_shown;
    reg [15:0] unused;
    reg expect_o, got;

    initial begin
        if (!$value$plusargs("dir=%s", f_dir) || !$value$plusargs("list=%s", f_list) ||
            !$value$plusargs("wiring=%s", f_wire) || !$value$plusargs("map=%s", f_map)) begin
            $display("FAIL: tb_lut_basis: need +dir= +list= +wiring= +map=");
            $finish;
        end
        for (b = 0; b < 64; b = b + 1) begin vec_cov[b] = 0; cov_hits[b] = 0; end
        read_map;
        read_wiring;
        fd = $fopen(f_list, "r");
        if (fd == 0) begin $display("FAIL: tb_lut_basis: cannot open case list"); $finish; end
        // the case list is read up front (the loader reuses fd)
        begin : read_cases
            integer lfd;
            lfd = fd;
            r = $fscanf(lfd, "%s %s %s %d", cid, cbel, ckind, caddr);
            while (r == 4) begin
                belx = (cbel == "A") ? 0 : (cbel == "B") ? 1 : (cbel == "C") ? 2 : (cbel == "D") ? 3 : -1;
                if (!((ckind == "zero" && caddr == 0) || (ckind == "ones" && belx >= 0 && caddr == 0) ||
                      (ckind == "onehot" && belx >= 0 && caddr >= 0 && caddr < 16))) begin
                    $display("FAIL: tb_lut_basis: malformed case line for %0s", cid); $finish;
                end
                $sformat(f_bin, "%0s/%0s.bin", f_dir, cid);
                load_bitstream;
                if (!load_ok) begin
                    $display("FAIL: tb_lut_basis: loader rejected case %0s: %0s", cid, reject_reason); $finish;
                end
`ifdef GEN_TILE
                $display("CFG %0s %040h", cid, {2'b00, dut.ConfigBits});
`else
                $display("CFG %0s %040h", cid, {2'b00, cfg});
`endif
                ncase = ncase + 1;
                if (ckind == "onehot") n_onehot = n_onehot + 1;
                else if (ckind == "ones") n_ones = n_ones + 1;
                else n_zero = n_zero + 1;
                cf = 0; first_shown = 0;
                for (e = 0; e < NENV; e = e + 1) begin
                    unused = (e == 0) ? 16'h0000 : (e == 1) ? 16'hFFFF : (e == 2) ? 16'hAAAA :
                             (e == 3) ? 16'h5555 : $random;
                    for (v = 0; v < 16; v = v + 1) begin
                        tin = unused;
                        tin[in_track[0]] = v[0]; tin[in_track[1]] = v[1];
                        tin[in_track[2]] = v[2]; tin[in_track[3]] = v[3];
                        #1;
                        for (b = 0; b < 4; b = b + 1) begin
                            expect_o = (b == belx) && ((ckind == "ones") || (ckind == "onehot" && v == caddr));
                            got = tout[out_track[b]];
                            checks = checks + 1;
                            if (got !== expect_o) begin
                                cf = cf + 1;
                                if (!first_shown)
                                    $display("  case %0s: mismatch BEL %c vector %0d (unrouted=%04h): got %b want %b",
                                             cid, "A" + b, v, unused, got, expect_o);
                                first_shown = 1;
                            end
                        end
                        if (ckind == "onehot") vec_cov[16*belx + caddr] = vec_cov[16*belx + caddr] + 1;
                    end
                end
                if (ckind == "onehot") cov_hits[16*belx + caddr] = cov_hits[16*belx + caddr] + 1;
                if (cf > 0) begin
                    case_fails = case_fails + 1;
                    $display("  case %0s: %0d mismatches", cid, cf);
                end
                fails = fails + cf;
                r = $fscanf(lfd, "%s %s %s %d", cid, cbel, ckind, caddr);
            end
            $fclose(lfd);
        end

        // coverage report: every (BEL, address) one-hot case, all 16 vectors in every environment
        begin : coverage
            integer bb, aa, full, nfull;
            nfull = 0;
            for (bb = 0; bb < 4; bb = bb + 1) begin
                full = 0;
                for (aa = 0; aa < 16; aa = aa + 1)
                    if (cov_hits[16*bb + aa] == 1 && vec_cov[16*bb + aa] == 16*NENV) full = full + 1;
                $display("COVERAGE: BEL %c: %0d/16 addresses, each one-hot case checked on all 16 input vectors x %0d unrouted-track values x 4 BEL outputs",
                         "A" + bb, full, NENV);
                nfull = nfull + full;
            end
            $display("COVERAGE: %0d BELs x 16 addresses = %0d/64 one-hot cases; %0d all-ones, %0d all-zero cases; %0d cases loaded in sequence into one live tile",
                     4, nfull, n_ones, n_zero, ncase);
`ifdef GEN_TILE
            $display("GEN_TILE: %0d frame writes through FrameData/FrameStrobe (%0d streams x %0d frames)",
                     n_frame_writes, ncase, NFR);
`endif
            if (nfull != 64 || n_onehot != 64 || n_ones != 4 || n_zero < 4) begin
                $display("FAIL: tb_lut_basis: incomplete basis coverage (%0d/64 one-hot, %0d ones, %0d zero)",
                         nfull, n_ones, n_zero);
                $finish;
            end
        end

        if (fails == 0)
            $display("PASS: tb_lut_basis[basis] (%0d checks, 0 failures; %0d/%0d cases)", checks, ncase, ncase);
        else begin
            // terminal summary in the shared verdict format (flow/gate_sim_verdict.sh);
            // this bench has no perturbation phase, so "0 perturbations survived"
            $display("basis cases failed: %0d/%0d", case_fails, ncase);
            $display("FAIL: tb_lut_basis[basis] (%0d checks, %0d failures, 0 perturbations survived)",
                     checks, fails);
        end
        $finish;
    end

endmodule
