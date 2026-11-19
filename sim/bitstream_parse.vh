// bitstream_parse.vh -- the common FABulous frame-stream wire-format reader,
// shared by the diagnostic loader (sim/bitstream_load.vh, issue #268) and the
// corpus bench (sim/tb_logic_tile_bitstream.v, issue #338). Both previously
// carried this parser inline, identical in every check; this include is the
// single copy, so a wire-format change is one edit.
//
// The include declares the format constants (CFG_N, FBITS, NFR, SELW,
// DESYNC_BIT, SYNC), the parser state (f_bin, fd, grid_cols, grid_rows, lx,
// ly, cb_pos, logic_frame, seen_frame, load_ok, reject_reason) and defines
// rd_word, reject and parse_bitstream. parse_bitstream reports the eleven
// wire-format errors both copies reported, through $fclose:
//   cannot open bitstream, truncated sync header, bad sync header,
//   truncated: no desync word, malformed desync word, invalid frame-select
//   word, duplicate frame, truncated frame data, data for a tile without
//   config bits, trailing data after desync, incomplete frame set
// and leaves the decoded frames of the logic tile in logic_frame.
//
// The including module must (Icarus resolves a task call to a task declared
// later in the module, but not a variable reference, so order matters):
//   - before the include, declare every net/reg its own manifest reader and
//     frame writer touch (cfg, FrameData/FrameStrobe, ...);
//   - fill grid_cols, grid_rows, lx, ly from its wiring manifest before
//     calling parse_bitstream;
//   - define write_frame(input integer fr, input [31:0] data) anywhere in the
//     module: parse_bitstream calls it for the logic tile's frames, zero or
//     not, in stream order (a repository-composition no-op). Because
//     write_frame's body may use this include's NFR, the usual order is this
//     include first, then the frame writer;
//   - after parse_bitstream returns, run its own post-read checks on success
//     (load_ok): the corpus bench rejects set bits outside its configuration
//     map and rebuilds cfg in both DUT modes; the diagnostic loader rebuilds
//     cfg for the repository composition only.

    localparam CFG_N = 158;
    localparam FBITS = 32, NFR = 20, SELW = 5, DESYNC_BIT = 20;
    localparam [159:0] SYNC = 160'h00AAFF01000000010000000000000000FAB0FAB1;

    reg [8*256-1:0] f_bin;
    integer fd, grid_cols, grid_rows, lx, ly;
    integer cb_pos [0:CFG_N-1];
    reg [31:0] logic_frame [0:NFR-1];
    reg        seen_frame  [0:(8*NFR)-1];
    reg        load_ok;
    reg [8*80-1:0] reject_reason;

    // -------------------------------------------------------------- readers
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

    // --------------------------------------------------------------- parser
    task parse_bitstream;
        reg [31:0] w, fw;
        reg ok;
        integer i, b, col, frame, nframes, order, pop, done;
        reg [159:0] hdr;
        begin
            load_ok = 1'b1; reject_reason = "";
            for (i = 0; i < NFR; i = i + 1) logic_frame[i] = 32'b0;
            for (i = 0; i < 8*NFR; i = i + 1) seen_frame[i] = 1'b0;
            fd = $fopen(f_bin, "rb");
            if (fd == 0) begin reject("cannot open bitstream"); disable parse_bitstream; end
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
                        // interior rows, Y descending: row index grid_rows-2 .. 1
                        for (order = 0; order < grid_rows - 2; order = order + 1) begin
                            rd_word(fw, ok);
                            if (!ok) reject("truncated frame data");
                            else if (col == lx && (grid_rows - 2 - order) == ly) begin
                                logic_frame[frame] = fw;
                                write_frame(frame, fw);   // includer-provided: every frame, zero or not
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
        end
    endtask
