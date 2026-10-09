// tb_logic_tile_bitstream.v
//
// EXPERIMENTAL single-LOGIC4 HARNESS test (issue #74): a bitstream produced by
// the pinned FABulous/yosys/nextpnr flow (sim/bitstream/*.bin) is loaded through
// a sim-only model of the FABulous frame interface into the 158-bit `cfg` of
// design/rtl/logic_tile_routed.v, and the mapped design is exercised around it.
//
// Scope / what this is NOT: it targets the G1 harness fabric exactly as
// implemented (same-index switch matrix, CAP_* loopbacks, scratch pad overlay).
// It is not the ratified Wilton-class fabric (ADR-0004/0005 are Proposed), has
// no timing content, and no inter-tile routing. See sim/README.md.
//
// Inputs (plusargs):
//   +bin=<frame stream>   FABulous bit_gen output
//   +map=<file>           "cfg_index frame_position" per line (from ConfigMem.v)
//   +wiring=<file>        pad/loopback/placement manifest derived from the FASM
//   +design=comb|reg      which mapped design's functional spec is the oracle
//   +mutate               also flip each used routing-select bit, and LUT/FF
//                         bits of each used BEL; every flip must be DETECTED
//   +expect_reject        the loader must reject +bin (malformed-input test)
//
// Nothing here uses hand-written LUT/matrix constants: cfg comes only from the
// loaded stream; placement (which BEL) and pad/loopback wiring come from the
// manifest. The oracle (the mapped design's function) is written independently
// below and does not reuse assembler code.
`timescale 1ns/1ps

module tb_logic_tile_bitstream;

    // ---------------------------------------------------------------- DUT
    reg          clk = 1'b0;
    reg  [157:0] cfg = 158'b0;
    reg  [15:0]  tin;           // tin[4*dir + idx], dir: 0=N 1=E 2=S 3=W
    wire [15:0]  tout;

    logic_tile_routed dut (
        .clk(clk), .cfg(cfg),
        .n_in(tin[3:0]),  .e_in(tin[7:4]),  .s_in(tin[11:8]),  .w_in(tin[15:12]),
        .n_out(tout[3:0]), .e_out(tout[7:4]), .s_out(tout[11:8]), .w_out(tout[15:12])
    );

    // ----------------------------------------------------------- bookkeeping
    integer checks = 0;
    integer cur_fail = 0;       // failures in the current run (mutation runs reset it)
    integer fails = 0;          // real failures
    reg     verbose = 1'b0;

    task chk(input cond, input [8*48-1:0] what);
        begin
            checks = checks + 1;
            if (!cond) begin
                cur_fail = cur_fail + 1;
                if (verbose) $display("  mismatch: %0s @%0t", what, $time);
            end
        end
    endtask

    // ------------------------------------------------------------- plusargs
    reg [8*256-1:0] f_bin, f_map, f_wire;
    reg [8*8-1:0]   design_name;
    reg             is_comb, do_mutate, expect_reject;

    // ------------------------------------------------- FABulous stream format
    localparam CFG_N = 158;
    localparam FBITS = 32, NFR = 20, SELW = 5, DESYNC_BIT = 20;
    localparam [159:0] SYNC = 160'h00AAFF01000000010000000000000000FAB0FAB1;

    // ------------------------------------------------- manifest / wiring state
    integer grid_cols, grid_rows, lx, ly;
    // input-track source: 0 = unused (harness constant/random), 1 = pad slot, 2 = loopback from an output track
    integer tin_kind [0:15];
    integer tin_arg  [0:15];
    integer out_track [0:7];      // output slot -> logic output track (-1 = unwired)
    reg [7:0] slot_wired_in;
    reg [7:0] slot_wired_out;
    integer nbel, nsel;
    integer bel_list [0:3];
    integer sel_list [0:127];
    integer n_loops;

    // input pad slots / output pad slots (port names)
    function integer in_slot(input [8*8-1:0] nm);
        begin
            in_slot = (nm == "a") ? 0 : (nm == "b") ? 1 : (nm == "c") ? 2 :
                      (nm == "d") ? 3 : (nm == "en") ? 4 : (nm == "rst") ? 5 : -1;
        end
    endfunction
    function integer out_slot(input [8*8-1:0] nm);
        begin
            out_slot = (nm == "y") ? 0 : (nm == "w") ? 1 : (nm == "q") ? 2 : -1;
        end
    endfunction

    reg [7:0] pad_in;             // harness values driven on the input pads
    reg [15:0] unused;            // harness value on input tracks nothing is routed to

    // input track network: pad / CAP loopback / unused
    integer t;
    always @(pad_in or tout or unused) begin
        for (t = 0; t < 16; t = t + 1)
            case (tin_kind[t])
                1:       tin[t] = pad_in[tin_arg[t]];
                2:       tin[t] = tout[tin_arg[t]];
                default: tin[t] = unused[t];
            endcase
    end

    function pad_out(input integer slot);
        begin pad_out = tout[out_track[slot]]; end
    endfunction

    // ------------------------------------------------------------ the loader
    reg [8*80-1:0] reject_reason;
    reg            load_ok;
    integer cb_pos [0:CFG_N-1];
    reg [31:0] mapped_mask [0:NFR-1];
    reg [31:0] logic_frame [0:NFR-1];
    reg        seen_frame  [0:(8*NFR)-1];
    integer    fd, c0;

    task rd_word(output [31:0] w, output ok);
        integer i, b;
        begin
            w = 0; ok = 1'b1;
            for (i = 0; i < FBITS/8; i = i + 1) begin
                b = $fgetc(fd);
                if (b < 0) ok = 1'b0;
                else w = {w[23:0], b[7:0]};
            end
        end
    endtask

    task reject(input [8*80-1:0] why);
        begin
            if (load_ok) reject_reason = why;
            load_ok = 1'b0;
        end
    endtask

    task load_bitstream;
        reg [31:0] w, fw;
        reg ok;
        integer i, col, frame, nframes, row, order, strobe_pop, done;
        reg [FBITS-NFR-SELW-1:0] reserved;
        reg [NFR-1:0] strobe;
        reg [159:0] hdr;
        integer b;
        begin
            load_ok = 1'b1; reject_reason = "";
            for (i = 0; i < NFR; i = i + 1) logic_frame[i] = 32'b0;
            for (i = 0; i < 8*NFR; i = i + 1) seen_frame[i] = 1'b0;
            fd = $fopen(f_bin, "rb");
            if (fd == 0) begin reject("cannot open bitstream"); disable load_bitstream; end
            // sync header
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
                    reserved = w[FBITS-SELW-1:NFR];
                    strobe = w[NFR-1:0];
                    strobe_pop = 0;
                    for (i = 0; i < NFR; i = i + 1) if (strobe[i]) begin strobe_pop = strobe_pop + 1; frame = i; end
                    if (reserved != 0 || strobe_pop != 1 || col >= grid_cols) begin
                        reject("invalid frame-select word");
                    end else if (seen_frame[col*NFR + frame]) begin
                        reject("duplicate frame");
                    end else begin
                        seen_frame[col*NFR + frame] = 1'b1;
                        nframes = nframes + 1;
                        // interior rows, Y descending: row index grid_rows-2 .. 1
                        for (order = 0; order < grid_rows - 2; order = order + 1) begin
                            rd_word(fw, ok);
                            if (!ok) reject("truncated frame data");
                            else if (col == lx && (grid_rows - 2 - order) == ly) begin
                                logic_frame[frame] = fw;
                            end else if (fw != 0) begin
                                reject("data for a tile without config bits");
                            end
                        end
                    end
                end
            end
            if (load_ok) begin
                if ($fgetc(fd) >= 0) reject("trailing data after desync");
                if (nframes != grid_cols * NFR) reject("incomplete frame set");
            end
            $fclose(fd);
            // frame bits -> cfg through the generated ConfigMem map
            if (load_ok) begin
                for (i = 0; i < NFR; i = i + 1)
                    if ((logic_frame[i] & ~mapped_mask[i]) != 0) reject("set bit at an unmapped frame position");
            end
            if (load_ok)
                for (i = 0; i < CFG_N; i = i + 1)
                    cfg[i] = logic_frame[cb_pos[i] / FBITS][cb_pos[i] % FBITS];
        end
    endtask

    // -------------------------------------------------- manifest / map readers
    task read_map;
        integer i, cb, pos, r;
        begin
            for (i = 0; i < NFR; i = i + 1) mapped_mask[i] = 32'b0;
            for (i = 0; i < CFG_N; i = i + 1) cb_pos[i] = -1;
            fd = $fopen(f_map, "r");
            if (fd == 0) begin $display("FAIL: tb_logic_tile_bitstream: cannot open map"); $finish; end
            r = $fscanf(fd, "%d %d", cb, pos);
            while (r == 2) begin
                cb_pos[cb] = pos;
                mapped_mask[pos / FBITS][pos % FBITS] = 1'b1;
                r = $fscanf(fd, "%d %d", cb, pos);
            end
            $fclose(fd);
            for (i = 0; i < CFG_N; i = i + 1)
                if (cb_pos[i] < 0) begin $display("FAIL: tb_logic_tile_bitstream: map misses cfg bit %0d", i); $finish; end
        end
    endtask

    task read_manifest;
        reg [8*8-1:0] kw, nm;
        integer d, k, a, b, s, r, ok_all, i, end_seen;
        begin
            for (i = 0; i < 16; i = i + 1) begin tin_kind[i] = 0; tin_arg[i] = 0; end
            for (i = 0; i < 8; i = i + 1) out_track[i] = -1;
            slot_wired_in = 0; slot_wired_out = 0; nbel = 0; nsel = 0; n_loops = 0;
            ok_all = 1; end_seen = 0;
            fd = $fopen(f_wire, "r");
            if (fd == 0) begin $display("FAIL: tb_logic_tile_bitstream: cannot open wiring manifest"); $finish; end
            r = $fscanf(fd, "%s", kw);
            while (r == 1 && !end_seen) begin
                if (kw == "GRID") r = $fscanf(fd, "%d %d", grid_cols, grid_rows);
                else if (kw == "TILE") r = $fscanf(fd, "%d %d", lx, ly);
                else if (kw == "IN") begin
                    r = $fscanf(fd, "%s %d %d", nm, d, k);
                    s = in_slot(nm);
                    if (s < 0 || tin_kind[4*d + k] != 0) ok_all = 0;
                    else begin tin_kind[4*d + k] = 1; tin_arg[4*d + k] = s; slot_wired_in[s] = 1'b1; end
                end else if (kw == "OUT") begin
                    r = $fscanf(fd, "%s %d %d", nm, d, k);
                    s = out_slot(nm);
                    if (s < 0) ok_all = 0;
                    else begin out_track[s] = 4*d + k; slot_wired_out[s] = 1'b1; end
                end else if (kw == "LOOP") begin
                    // logic output track (a,b) -> CAP loopback -> logic input track (c,d)
                    r = $fscanf(fd, "%d %d %d %d", a, b, d, k);
                    if (tin_kind[4*d + k] != 0) ok_all = 0;
                    else begin tin_kind[4*d + k] = 2; tin_arg[4*d + k] = 4*a + b; end
                    n_loops = n_loops + 1;
                end else if (kw == "BEL") begin r = $fscanf(fd, "%d", a); bel_list[nbel] = a; nbel = nbel + 1; end
                else if (kw == "SEL") begin r = $fscanf(fd, "%d", a); sel_list[nsel] = a; nsel = nsel + 1; end
                else if (kw == "END") end_seen = 1;
                else ok_all = 0;
                if (!end_seen) r = $fscanf(fd, "%s", kw);
            end
            $fclose(fd);
            if (!ok_all || !end_seen) begin $display("FAIL: tb_logic_tile_bitstream: bad wiring manifest"); $finish; end
        end
    endtask

    // ------------------------------------------------------ harness utilities
    task pulse;
        begin clk = 1'b1; #5; clk = 1'b0; #5; end
    endtask

    // ------------------------------------------- oracle 1: combinational design
    //   y = a ^ b ^ c ^ d        w = a & b & c
    task run_comb;
        integer v;
        reg a, b, c, d;
        begin
            for (v = 0; v < 16; v = v + 1) begin
                {d, c, b, a} = v[3:0];
                pad_in[0] = a; pad_in[1] = b; pad_in[2] = c; pad_in[3] = d;
                #1;
                chk(pad_out(0) === (a ^ b ^ c ^ d), "y = a^b^c^d");
                chk(pad_out(1) === (a & b & c),     "w = a&b&c");
            end
        end
    endtask

    // ------------------------------------------- oracle 2: registered design
    //   @(posedge clk)  q <= rst ? 0 : (en ? a^b^c : q)
    task run_reg;
        integer s, v, i;
        reg a, b, c, en, rst, expect_q, refq;
        begin
            // exhaustive: both starting states x all 32 (rst,en,c,b,a) vectors
            for (s = 0; s < 2; s = s + 1)
                for (v = 0; v < 32; v = v + 1) begin
                    // establish state s through the programmed fabric
                    if (s == 0) begin
                        pad_in[0] = 1; pad_in[1] = 1; pad_in[2] = 1; pad_in[4] = 0; pad_in[5] = 1;
                    end else begin
                        pad_in[0] = 1; pad_in[1] = 0; pad_in[2] = 0; pad_in[4] = 1; pad_in[5] = 0;
                    end
                    #1; pulse;
                    chk(pad_out(2) === s[0], "established state");
                    {rst, en, c, b, a} = v[4:0];
                    pad_in[0] = a; pad_in[1] = b; pad_in[2] = c; pad_in[4] = en; pad_in[5] = rst;
                    #1;
                    chk(pad_out(2) === s[0], "q holds until the clock edge");
                    pulse;
                    expect_q = rst ? 1'b0 : en ? (a ^ b ^ c) : s[0];
                    chk(pad_out(2) === expect_q, "q after edge");
                end
            // directed narrative: capture, hold, reset (en=0), capture, reset (en=1 wins)
            pad_in[5] = 1; pad_in[4] = 0; #1; pulse;
            chk(pad_out(2) === 1'b0, "seq: reset");
            pad_in[5] = 0; pad_in[4] = 1; pad_in[0] = 1; pad_in[1] = 1; pad_in[2] = 1; #1; pulse;
            chk(pad_out(2) === 1'b1, "seq: capture 1 (1^1^1)");
            pad_in[4] = 0; pad_in[0] = 0; pad_in[1] = 0; pad_in[2] = 0; #1; pulse; pulse;
            chk(pad_out(2) === 1'b1, "seq: hold 1 with en=0, data 0");
            pad_in[5] = 1; #1; pulse;
            chk(pad_out(2) === 1'b0, "seq: reset with en=0");
            pad_in[5] = 0; pad_in[4] = 1; pad_in[0] = 1; #1; pulse;
            chk(pad_out(2) === 1'b1, "seq: capture after reset");
            pad_in[4] = 1; pad_in[5] = 1; pad_in[0] = 1; #1; pulse;
            chk(pad_out(2) === 1'b0, "seq: reset beats enable and data");
            // random sequence against an independent reference register
            refq = 1'b0;
            pad_in[5] = 1; pad_in[4] = 0; #1; pulse;
            for (i = 0; i < 300; i = i + 1) begin
                {rst, en, c, b, a} = $random;
                rst = (($random & 7) == 0);
                pad_in[0] = a; pad_in[1] = b; pad_in[2] = c; pad_in[4] = en; pad_in[5] = rst;
                #1;
                chk(pad_out(2) === refq, "random: q before edge");
                pulse;
                if (rst) refq = 1'b0; else if (en) refq = a ^ b ^ c;
                chk(pad_out(2) === refq, "random: q after edge");
            end
        end
    endtask

    task run_design;
        begin
            if (is_comb) run_comb; else run_reg;
        end
    endtask

    // the environment variants a correct programming must be immune to
    task run_all_env(input integer nrand);
        integer i;
        begin
            unused = 16'h0000;     run_design;
            unused = 16'hFFFF;     run_design;
            unused = 16'hAAAA;     run_design;
            unused = 16'h5555;     run_design;
            for (i = 0; i < nrand; i = i + 1) begin unused = $random; run_design; end
        end
    endtask

    // ------------------------------------------------------------------ main
    integer i, m, det, surv, nmut;
    reg [157:0] saved_cfg;
    reg need_ok;

    initial begin
        pad_in = 8'b0; unused = 16'b0;
        tin = 16'b0;
        is_comb = 1'b1; do_mutate = 1'b0; expect_reject = 1'b0;
        if (!$value$plusargs("bin=%s", f_bin) || !$value$plusargs("map=%s", f_map) ||
            !$value$plusargs("wiring=%s", f_wire) || !$value$plusargs("design=%s", design_name)) begin
            $display("FAIL: tb_logic_tile_bitstream: need +bin= +map= +wiring= +design=");
            $finish;
        end
        is_comb = (design_name == "comb");
        do_mutate = $test$plusargs("mutate");
        expect_reject = $test$plusargs("expect_reject");
        verbose = $test$plusargs("verbose");

        read_map;
        read_manifest;
        // the oracle needs these ports to be wired by the mapping
        need_ok = is_comb ? (&slot_wired_in[3:0] && slot_wired_out[0] && slot_wired_out[1])
                          : (&slot_wired_in[2:0] && slot_wired_in[4] && slot_wired_in[5] && slot_wired_out[2]);
        if (!need_ok) begin $display("FAIL: tb_logic_tile_bitstream[%0s]: manifest lacks required ports", design_name); $finish; end

        load_bitstream;
        if (expect_reject) begin
            if (load_ok) $display("FAIL: tb_logic_tile_bitstream[%0s]: malformed stream was ACCEPTED", design_name);
            else $display("PASS: tb_logic_tile_bitstream[%0s] loader rejected the malformed stream (%0s)", design_name, reject_reason);
            $finish;
        end
        if (!load_ok) begin
            $display("FAIL: tb_logic_tile_bitstream[%0s]: loader rejected a stream that must load: %0s", design_name, reject_reason);
            $finish;
        end
        $display("CFG=%040h", {2'b00, cfg});

        // (1) the programmed tile implements the mapped design
        cur_fail = 0;
        run_all_env(4);
        fails = fails + cur_fail;
        chk(1'b1, "end of baseline");
        $display("baseline: %0d checks, %0d failures", checks, cur_fail);

        // (2) deliberate perturbation of the loaded configuration must be detected
        det = 0; surv = 0; nmut = 0;
        if (do_mutate) begin
            saved_cfg = cfg;
            for (m = 0; m < nsel; m = m + 1) begin     // every used routing-select bit
                cfg = saved_cfg ^ (158'b1 << sel_list[m]);
                cur_fail = 0; run_all_env(2); nmut = nmut + 1;
                if (cur_fail > 0) det = det + 1;
                else begin surv = surv + 1; $display("  SURVIVED: flip of routing-select cfg[%0d]", sel_list[m]); end
            end
            for (m = 0; m < nbel; m = m + 1) begin     // LUT bits 0,1 and reg_sel of every used BEL
                for (i = 0; i < 3; i = i + 1) begin
                    cfg = saved_cfg ^ (158'b1 << (17*bel_list[m] + ((i == 2) ? 16 : i)));
                    cur_fail = 0; run_all_env(2); nmut = nmut + 1;
                    if (cur_fail > 0) det = det + 1;
                    else begin surv = surv + 1; $display("  SURVIVED: flip of BEL %0d cfg bit %0d", bel_list[m], (i == 2) ? 16 : i); end
                end
            end
            cfg = saved_cfg;
            fails = fails + surv;
            // restored configuration still passes
            cur_fail = 0; run_all_env(1); fails = fails + cur_fail;
        end

        if (fails == 0)
            $display("PASS: tb_logic_tile_bitstream[%0s] (%0d checks, 0 failures; %0d/%0d perturbations detected)",
                     design_name, checks, det, nmut);
        else
            $display("FAIL: tb_logic_tile_bitstream[%0s] (%0d checks, %0d failures, %0d perturbations survived)",
                     design_name, checks, fails, surv);
        $finish;
    end

endmodule
