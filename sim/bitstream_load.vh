// bitstream_load.vh -- shared frame-programming bitstream loader for the four
// generated-tile diagnostic benches (tb_lut_basis, tb_route_diag,
// tb_output_route, tb_ctrl_route). They previously each carried this loader
// inline, byte-identical modulo bench name (issue #268); this include is the
// single copy.
//
// The including bench must, before the `include line:
//   `define TB_NAME "<bench name>"   -- verbatim prefix of the FAIL strings
//     (a macro, not %m: inside a task %m expands to the task's scope)
// and must already have declared, as its DUT hookup does:
//   reg [157:0] cfg;                               (repository composition)
//   reg [31:0] FrameData; reg [19:0] FrameStrobe;  (under -DGEN_TILE only)
//
// The include declares the loader state (f_bin/f_map, fd, frame arrays, load
// bookkeeping) and defines read_map, rd_word, reject, write_frame and
// load_bitstream. What genuinely differs per bench stays in the bench:
// read_wiring, the oracles and the case logic. Both sim/run.sh and
// flow/generated_tile_replay.sh already pass -I <sim dir>; no build change.

    localparam CFG_N = 158;
    localparam FBITS = 32, NFR = 20, SELW = 5, DESYNC_BIT = 20;
    localparam [159:0] SYNC = 160'h00AAFF01000000010000000000000000FAB0FAB1;

    reg [8*256-1:0] f_bin, f_map;
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
            if (fd == 0) begin $display("FAIL: %0s: cannot open map", `TB_NAME); $finish; end
            r = $fscanf(fd, "%d %d", cb, pos);
            while (r == 2) begin
                cb_pos[cb] = pos;
                r = $fscanf(fd, "%d %d", cb, pos);
            end
            $fclose(fd);
            for (i = 0; i < CFG_N; i = i + 1)
                if (cb_pos[i] < 0) begin $display("FAIL: %0s: map misses cfg bit %0d", `TB_NAME, i); $finish; end
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
