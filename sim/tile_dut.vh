// tile_dut.vh -- shared DUT hookup for the five bitstream benches: the corpus
// bench (tb_logic_tile_bitstream) and the four generated-tile diagnostic
// benches (tb_lut_basis, tb_route_diag, tb_ctrl_route, tb_output_route). They
// previously each carried this adapter inline, byte-identical (the corpus bench
// alone omitting the tin initializer, which its initial block assigns before
// first use anyway); this include is the single copy, so a boundary change to
// LOGIC4 or logic_tile_routed is one edit, not five (issue #384).
//
// Included INSIDE the bench module, exactly where the DUT block used to sit,
// before any use of clk / cfg / tin / tout / dut. Declares and instantiates:
//   default      design/rtl/logic_tile_routed.v through its flat 158-bit cfg
//   -DGEN_TILE   the FABulous-generated LOGIC4 (scratch output of
//                flow/fabulous.sh), configured only through its real
//                FrameData/FrameStrobe boundary ports (driven by the loader's
//                write_frame, sim/bitstream_load.vh / the corpus bench)
//
// sim/tb_boundary_fwd.v deliberately does NOT use this include: it is
// -DGEN_TILE-only, carries no cfg, and refuses compilation without -DGEN_TILE.
// Every compile line already passes -I <sim dir>; no build change.

    reg          clk = 1'b0;
    reg  [157:0] cfg = 158'b0;
    reg  [15:0]  tin = 16'b0;   // tin[4*dir + idx], dir: 0=N 1=E 2=S 3=W
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
