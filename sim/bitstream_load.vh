// bitstream_load.vh -- shared frame-programming bitstream loader for the four
// generated-tile diagnostic benches (tb_lut_basis, tb_route_diag,
// tb_output_route, tb_ctrl_route). They previously each carried this loader
// inline, byte-identical modulo bench name (issue #268); this include is the
// single copy. The wire-format parser it used to carry is shared further with
// the corpus bench (issue #338) and lives in sim/bitstream_parse.vh, included
// below; what remains here is diagnostic-specific: the map reader, the frame
// writer, and the load_bitstream wrapper that reconstructs cfg for the
// repository composition.
//
// The including bench must, before the `include line:
//   `define TB_NAME "<bench name>"   -- verbatim prefix of the FAIL strings
//     (a macro, not %m: inside a task %m expands to the task's scope)
// and must already have declared, as its DUT hookup does:
//   reg [157:0] cfg;                               (repository composition)
//   reg [31:0] FrameData; reg [19:0] FrameStrobe;  (under -DGEN_TILE only)
//
// This include declares f_map and n_frame_writes and defines read_map,
// write_frame and load_bitstream; f_bin, the format constants, the parser
// state and parse_bitstream come from bitstream_parse.vh. What genuinely
// differs per bench stays in the bench: read_wiring, the oracles and the case
// logic. Both sim/run.sh and flow/generated_tile_replay.sh already pass
// -I <sim dir>; no build change.

    reg [8*256-1:0] f_map;
    integer n_frame_writes = 0;

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

`include "bitstream_parse.vh"

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

    // parse_bitstream owns the wire-format checks; on success the repository
    // composition gets cfg from the ConfigMem map (the generated tile is
    // already configured, through write_frame).
    task load_bitstream;
        integer i;
        begin
            parse_bitstream;
`ifndef GEN_TILE
            if (load_ok)
                for (i = 0; i < CFG_N; i = i + 1)
                    cfg[i] = logic_frame[cb_pos[i] / FBITS][cb_pos[i] % FBITS];
`endif
        end
    endtask
