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
//   +design=comb|reg|quad4|casc2|fan4|casc_fan|regcasc|regbel
//                         which mapped design's functional spec is the oracle
//                         (comb/reg: issue #74; the rest: issue #115 corpus,
//                         design/fabulous/corpus/*.v)
//   +mutate               also flip each used routing-select bit, and LUT/FF
//                         bits of each used BEL; every flip must be DETECTED
//   +expect_reject        the loader must reject +bin (malformed-input test)
//
// Nothing here uses hand-written LUT/matrix constants: cfg comes only from the
// loaded stream; placement (which BEL) and pad/loopback wiring come from the
// manifest. The oracle (the mapped design's function) is written independently
// below and does not reuse assembler code.
//
// Compile-time DUT choice (issue #140):
//   default        the repository composition design/rtl/logic_tile_routed.v,
//                  configured through its flat 158-bit `cfg` port (cfg[i] =
//                  frame bit of logic4_configmem.map line i).
//   -DGEN_TILE     the FABulous-GENERATED tile module LOGIC4 (scratch output of
//                  flow/fabulous.sh: LOGIC4.v + its generated LOGIC4_ConfigMem,
//                  LOGIC4_switch_matrix and lut4_ff_bel instances, models_pack.v).
//                  It is configured ONLY through its real FrameData/FrameStrobe
//                  boundary ports: each frame of the stream addressed to the
//                  logic tile is written, in stream order, as a legal frame write
//                  (data, one-hot strobe, strobe release). The map is NOT used to
//                  load it; the CFG= line is read back from the generated tile's
//                  internal ConfigBits. Perturbations (+mutate) are re-written as
//                  frames (the map only locates the flipped bit). Same oracles,
//                  same CAP loopback / pad semantics; flow/generated_tile_replay.sh.
`timescale 1ns/1ps

module tb_logic_tile_bitstream;

    // ---------------------------------------------------------------- DUT
    reg          clk = 1'b0;
    reg  [157:0] cfg = 158'b0;
    reg  [15:0]  tin;           // tin[4*dir + idx], dir: 0=N 1=E 2=S 3=W
    wire [15:0]  tout;

`ifdef GEN_TILE
    // Adapter onto the generated LOGIC4 boundary (port names as emitted by the
    // pinned generator: <dir>1END = input track, <dir>1BEG = output track, the
    // same names logic_tile_routed.v documents for <dir>_in / <dir>_out).
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
                      (nm == "d") ? 3 : (nm == "en") ? 4 : (nm == "rst") ? 5 :
                      (nm == "e") ? 6 : (nm == "f") ? 7 : -1;
        end
    endfunction
    function integer out_slot(input [8*8-1:0] nm);
        begin
            out_slot = (nm == "y") ? 0 : (nm == "w") ? 1 : (nm == "q") ? 2 :
                       (nm == "v") ? 3 : (nm == "z") ? 4 : -1;
        end
    endfunction

    reg [7:0] pad_in;             // harness values driven on the input pads
    reg [15:0] unused;            // harness value on input tracks nothing is routed to

    // input track network: pad / CAP loopback / unused
    integer t;
    // The CAP loopback carries a 100 ps transport delay (issue #115): a perturbed
    // configuration can close a combinational cycle through the loopbacks, which
    // with zero delay never advances simulation time (the run would hang). With
    // the delay a cycle oscillates in simulated time and the checks see it.
    // `flush` forces the loopbacks to 0 (see flush_loops).
    reg flush = 1'b0;
    always @(pad_in or tout or unused or flush) begin
        for (t = 0; t < 16; t = t + 1)
            case (tin_kind[t])
                1:       tin[t] = pad_in[tin_arg[t]];
                2:       tin[t] <= #0.1 (flush ? 1'b0 : tout[tin_arg[t]]);
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

    // ------------------------------------- GEN_TILE: real frame-port writes
    // One legal frame write into the generated tile: data, one-hot strobe,
    // strobe release, then FrameData scrambled (storage must hold). No-op for
    // the repository composition (its cfg port is driven directly).
    reg [31:0] held_frame [0:NFR-1];   // what the generated tile currently stores
    integer    n_frame_writes = 0;
    task write_frame(input integer fr, input [31:0] data);
        begin
`ifdef GEN_TILE
            FrameData = data; #1;
            FrameStrobe = 20'b0; FrameStrobe[fr] = 1'b1; #1;
            FrameStrobe = 20'b0; #1;
            FrameData = ~data ^ 32'h5a5a_a5a5; #1;
            held_frame[fr] = data;
            n_frame_writes = n_frame_writes + 1;
`endif
        end
    endtask

    // Bring the DUT to the configuration in `cfg` after a perturbation/restore.
    // GEN_TILE: rewrite (as frames) every frame whose content changed; the map
    // only locates bits, unmapped positions keep the loaded stream's (zero) bits.
    task apply_cfg;
`ifdef GEN_TILE
        integer f, k;
        reg [31:0] w;
`endif
        begin
`ifdef GEN_TILE
            for (f = 0; f < NFR; f = f + 1) begin
                w = logic_frame[f] & ~mapped_mask[f];
                for (k = 0; k < CFG_N; k = k + 1)
                    if (cb_pos[k] / FBITS == f) w[cb_pos[k] % FBITS] = cfg[k];
                if (w !== held_frame[f]) write_frame(f, w);
            end
`endif
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
                                write_frame(frame, fw);   // GEN_TILE: real frame port
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
    // Between perturbations: restore the loaded configuration and break any X (or stale
    // value) a perturbed configuration left circulating. An unconnected LUT pin defaults
    // to a switch-matrix track that can be the loopback of the BEL's own output, a
    // don't-care cycle (replicated INIT) that nonetheless holds an X forever in
    // simulation once an X (e.g. an unclocked flop selected by a reg_sel flip) enters it.
    reg [157:0] clean_cfg;
    task flush_loops;
        begin
            cfg = clean_cfg;
            apply_cfg;
            flush = 1'b1; #1; flush = 1'b0; #1;
        end
    endtask

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

    // ------------------------------- oracles 3-6: routability corpus (issue #115)
    // Written from the corpus sources design/fabulous/corpus/*.v, exhaustive over
    // every input vector. pad slots: a b c d en rst e f = 0..7; outputs y w q v z = 0..4
    task run_corpus_comb;
        integer v;
        reg a, b, c, d, e, f, t;
        begin
            for (v = 0; v < 64; v = v + 1) begin
                {f, e, d, c, b, a} = v[5:0];
                pad_in[0] = a; pad_in[1] = b; pad_in[2] = c; pad_in[3] = d; pad_in[6] = e; pad_in[7] = f;
                #1;
                t = a ^ b ^ c ^ d;
                case (design_name)
                    "quad4": begin
                        chk(pad_out(0) === (a ^ b ^ c ^ d),       "y = a^b^c^d");
                        chk(pad_out(1) === ((a & b) | (c & d)),   "w = ab|cd");
                        chk(pad_out(4) === ((a | b) & (c | d)),   "z = (a|b)&(c|d)");
                        chk(pad_out(3) === (a ? (b ^ c) : d),     "v = a ? b^c : d");
                    end
                    "fan4": begin
                        chk(pad_out(0) === (a ^ b),               "y = a^b");
                        chk(pad_out(1) === (a & c),               "w = a&c");
                        chk(pad_out(4) === (a | d),               "z = a|d");
                        chk(pad_out(3) === (a ^ (c & d)),         "v = a^(c&d)");
                    end
                    "casc2": chk(pad_out(0) === ((t & e) ^ f),    "y = ((a^b^c^d)&e)^f");
                    "casc_fan": begin
                        chk(pad_out(0) === (t & e),               "y = t&e");
                        chk(pad_out(1) === (t | e),               "w = t|e");
                        chk(pad_out(4) === (t ^ e),               "z = t^e");
                    end
                    default: chk(1'b0, "unknown corpus design");
                endcase
            end
        end
    endtask

    //   @(posedge clk)  q <= rst ? 0 : (en ? ((a^b^c^d)&e) : q)
    task run_regcasc;
        integer s, v, i;
        reg a, b, c, d, e, en, rst, expect_q, refq;
        begin
            for (s = 0; s < 2; s = s + 1)
                for (v = 0; v < 128; v = v + 1) begin
                    // establish state s through the programmed fabric
                    pad_in[3] = 0; pad_in[6] = 1;
                    if (s == 0) begin
                        pad_in[0] = 1; pad_in[1] = 0; pad_in[2] = 0; pad_in[4] = 0; pad_in[5] = 1;
                    end else begin
                        pad_in[0] = 1; pad_in[1] = 0; pad_in[2] = 0; pad_in[4] = 1; pad_in[5] = 0;
                    end
                    #1; pulse;
                    chk(pad_out(2) === s[0], "established state");
                    {rst, en, e, d, c, b, a} = v[6:0];
                    pad_in[0] = a; pad_in[1] = b; pad_in[2] = c; pad_in[3] = d; pad_in[6] = e;
                    pad_in[4] = en; pad_in[5] = rst;
                    #1;
                    chk(pad_out(2) === s[0], "q holds until the clock edge");
                    pulse;
                    expect_q = rst ? 1'b0 : en ? ((a ^ b ^ c ^ d) & e) : s[0];
                    chk(pad_out(2) === expect_q, "q after edge");
                end
            refq = 1'b0;
            pad_in[5] = 1; pad_in[4] = 0; #1; pulse;
            for (i = 0; i < 300; i = i + 1) begin
                {rst, en, e, d, c, b, a} = $random;
                rst = (($random & 7) == 0);
                pad_in[0] = a; pad_in[1] = b; pad_in[2] = c; pad_in[3] = d; pad_in[6] = e;
                pad_in[4] = en; pad_in[5] = rst;
                #1;
                chk(pad_out(2) === refq, "random: q before edge");
                pulse;
                if (rst) refq = 1'b0; else if (en) refq = (a ^ b ^ c ^ d) & e;
                chk(pad_out(2) === refq, "random: q after edge");
            end
        end
    endtask


    // issue #156: one registered LUT4 BEL (any of A..D) with real EN/SR nets:
    //   @(posedge clk)  q <= rst ? 0 : (en ? ((a & b) ^ (c | d)) : q)
    // Written from design/fabulous/corpus/regbel_*.v. Exhaustive over both
    // starting states x all (rst,en,d,c,b,a) vectors, plus the four directed
    // control behaviours (capture, hold, reset with en=0, reset beats en=1) and a
    // random sequence against a reference register.
    task run_regbel;
        integer s, v, i;
        reg a, b, c, d, en, rst, expect_q, refq;
        begin
            for (s = 0; s < 2; s = s + 1)
                for (v = 0; v < 64; v = v + 1) begin
                    if (s == 0) begin
                        pad_in[0] = 1; pad_in[1] = 1; pad_in[2] = 0; pad_in[3] = 0; pad_in[4] = 0; pad_in[5] = 1;
                    end else begin
                        pad_in[0] = 1; pad_in[1] = 1; pad_in[2] = 0; pad_in[3] = 0; pad_in[4] = 1; pad_in[5] = 0;
                    end
                    #1; pulse;
                    chk(pad_out(2) === s[0], "established state");
                    {rst, en, d, c, b, a} = v[5:0];
                    pad_in[0] = a; pad_in[1] = b; pad_in[2] = c; pad_in[3] = d;
                    pad_in[4] = en; pad_in[5] = rst;
                    #1;
                    chk(pad_out(2) === s[0], "q holds until the clock edge");
                    pulse;
                    expect_q = rst ? 1'b0 : en ? ((a & b) ^ (c | d)) : s[0];
                    chk(pad_out(2) === expect_q, "q after edge");
                end
            // directed: reset, capture 1, hold 1 (en=0, data 0), reset with en=0,
            // capture after reset, reset beats enable and data
            pad_in[5] = 1; pad_in[4] = 0; #1; pulse;
            chk(pad_out(2) === 1'b0, "seq: reset");
            pad_in[5] = 0; pad_in[4] = 1; pad_in[0] = 1; pad_in[1] = 1; pad_in[2] = 0; pad_in[3] = 0; #1; pulse;
            chk(pad_out(2) === 1'b1, "seq: capture 1");
            pad_in[4] = 0; pad_in[0] = 0; pad_in[1] = 0; #1; pulse; pulse;
            chk(pad_out(2) === 1'b1, "seq: hold 1 with en=0, data 0");
            pad_in[5] = 1; #1; pulse;
            chk(pad_out(2) === 1'b0, "seq: reset with en=0");
            pad_in[5] = 0; pad_in[4] = 1; pad_in[2] = 1; #1; pulse;
            chk(pad_out(2) === 1'b1, "seq: capture after reset");
            pad_in[4] = 1; pad_in[5] = 1; pad_in[0] = 1; pad_in[1] = 1; pad_in[2] = 0; pad_in[3] = 0; #1; pulse;
            chk(pad_out(2) === 1'b0, "seq: reset beats enable and data");
            refq = 1'b0;
            pad_in[5] = 1; pad_in[4] = 0; #1; pulse;
            for (i = 0; i < 300; i = i + 1) begin
                {rst, en, d, c, b, a} = $random;
                rst = (($random & 7) == 0);
                pad_in[0] = a; pad_in[1] = b; pad_in[2] = c; pad_in[3] = d;
                pad_in[4] = en; pad_in[5] = rst;
                #1;
                chk(pad_out(2) === refq, "random: q before edge");
                pulse;
                if (rst) refq = 1'b0; else if (en) refq = (a & b) ^ (c | d);
                chk(pad_out(2) === refq, "random: q after edge");
            end
        end
    endtask

    task run_design;
        begin
            if (is_comb) run_comb;
            else if (design_name == "reg") run_reg;
            else if (design_name == "regcasc") run_regcasc;
            else if (design_name == "regbel") run_regbel;
            else run_corpus_comb;
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
    integer i, m, det, surv, nmut, nper;
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
        case (design_name)
            "comb":     need_ok = &slot_wired_in[3:0] && slot_wired_out[0] && slot_wired_out[1];
            "reg":      need_ok = &slot_wired_in[2:0] && slot_wired_in[4] && slot_wired_in[5] && slot_wired_out[2];
            "quad4",
            "fan4":     need_ok = &slot_wired_in[3:0] && slot_wired_out[0] && slot_wired_out[1] &&
                                  slot_wired_out[3] && slot_wired_out[4];
            "casc2":    need_ok = &slot_wired_in[3:0] && slot_wired_in[6] && slot_wired_in[7] && slot_wired_out[0];
            "casc_fan": need_ok = &slot_wired_in[3:0] && slot_wired_in[6] && slot_wired_out[0] &&
                                  slot_wired_out[1] && slot_wired_out[4];
            "regcasc":  need_ok = &slot_wired_in[3:0] && slot_wired_in[4] && slot_wired_in[5] &&
                                  slot_wired_in[6] && slot_wired_out[2];
            "regbel":   need_ok = &slot_wired_in[5:0] && slot_wired_out[2];
            default:    need_ok = 1'b0;
        endcase
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
`ifdef GEN_TILE
        // read back from the generated tile's own ConfigMem output (not the map)
        $display("CFG=%040h", {2'b00, dut.ConfigBits});
        $display("GEN_TILE: %0d frame writes through FrameData/FrameStrobe; %0d CAP loopbacks, %0d BELs used",
                 n_frame_writes, n_loops, nbel);
        // Configuring a live tile frame by frame lets the still-X ConfigBits of the
        // first writes push an X into a CAP loopback. A don't-care cycle (an unused
        // LUT pin defaulting to the loopback of a track the LUT itself drives, see
        // flush_loops) then holds that simulation-only X forever. The repository
        // composition never sees it because its cfg port is valid from time 0.
        // Break it exactly as flush_loops does between perturbations: force the
        // loopbacks to 0 once, after configuration and before any check.
        flush = 1'b1; #1; flush = 1'b0; #1;
`else
        $display("CFG=%040h", {2'b00, cfg});
`endif

        // (1) the programmed tile implements the mapped design
        cur_fail = 0;
        run_all_env(4);
        fails = fails + cur_fail;
        chk(1'b1, "end of baseline");
        $display("baseline: %0d checks, %0d failures", checks, cur_fail);

        // (2) deliberate perturbation of the loaded configuration must be detected
        det = 0; surv = 0; nmut = 0;
        if (do_mutate) begin
            saved_cfg = cfg; clean_cfg = cfg;
            for (m = 0; m < nsel; m = m + 1) begin     // every used routing-select bit
                flush_loops;
                cfg = saved_cfg ^ (158'b1 << sel_list[m]);
                apply_cfg;
                cur_fail = 0; run_all_env(2); nmut = nmut + 1;
                if (cur_fail > 0) det = det + 1;
                else begin surv = surv + 1; $display("  SURVIVED: flip of routing-select cfg[%0d]", sel_list[m]); end
            end
            for (m = 0; m < nbel; m = m + 1) begin
                // comb/reg (#74): LUT bits 0,1 and reg_sel of every used BEL.
                // corpus designs (#115): the whole LUT table inverted, and reg_sel. A single
                // LUT entry can be legitimately unobservable (e.g. an entry only read while
                // EN=0 on a flop BEL) and which entry that is depends on the placement.
                nper = (is_comb || design_name == "reg") ? 3 : 2;
                for (i = 0; i < nper; i = i + 1) begin
                    flush_loops;
                    if (nper == 3)
                        cfg = saved_cfg ^ (158'b1 << (17*bel_list[m] + ((i == 2) ? 16 : i)));
                    else
                        cfg = saved_cfg ^ ((i == 0) ? (158'hFFFF << (17*bel_list[m]))
                                                    : (158'b1 << (17*bel_list[m] + 16)));
                    apply_cfg;
                    cur_fail = 0; run_all_env(2); nmut = nmut + 1;
                    if (cur_fail > 0) det = det + 1;
                    else begin surv = surv + 1; $display("  SURVIVED: flip of BEL %0d cfg bit %0d", bel_list[m], (i == 2) ? 16 : i); end
                end
            end
            flush_loops;
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
