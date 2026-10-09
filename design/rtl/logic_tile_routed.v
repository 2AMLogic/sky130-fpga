// logic_tile_routed.v
//
// Composed LOGIC4 tile (RTL only): the 4 lut4_slice BELs from logic_tile.v's
// BEL set plus the generated logic_tile_switch_matrix, behind one flat
// 158-bit configuration port. This is the spec'd tile boundary of
// spec/tile-spec.md (BEL pins + 4 edges x 4 tracks + config port) as RTL.
//
// Scope: RTL composition ONLY. No layout, no DRC/LVS, no timing exist for this
// module. The ratified/signed-off BEL-only module logic_tile (logic_tile.v)
// is deliberately left unchanged; this is a separate, additive module.
//
// Configuration (matches design/README.md "LOGIC4 config-bit layout"):
//   cfg[17*i +: 16]  BEL i LUT4 truth table (i = 0..3 = A..D)
//   cfg[17*i + 16]   BEL i reg_sel
//   cfg[157:68]      switch-matrix selects (matrix cfg[89:0])
//
// Tracks: <dir>_in[t] = <dir>1END<t>, <dir>_out[t] = <dir>1BEG<t>.
// Clock enables and the shared reset are NOT ports: as in the FABulous
// description they are BEL EN/SR pins driven through the matrix from tracks.

`default_nettype none
`timescale 1ns/1ps

module logic_tile_routed (
    input  wire         clk,
    input  wire [157:0] cfg,
    input  wire [3:0]   n_in,
    input  wire [3:0]   e_in,
    input  wire [3:0]   s_in,
    input  wire [3:0]   w_in,
    output wire [3:0]   n_out,
    output wire [3:0]   e_out,
    output wire [3:0]   s_out,
    output wire [3:0]   w_out
);

    wire [15:0] lut_in;   // LA_I0..LA_I3, LB_I0.. : lut_in[4*i + k]
    wire [3:0]  bel_en;
    wire [3:0]  bel_sr;
    wire [3:0]  bel_o;

    logic_tile_switch_matrix u_sm (
        .cfg    (cfg[157:68]),
        .N1END0 (n_in[0]), .N1END1 (n_in[1]), .N1END2 (n_in[2]), .N1END3 (n_in[3]),
        .E1END0 (e_in[0]), .E1END1 (e_in[1]), .E1END2 (e_in[2]), .E1END3 (e_in[3]),
        .S1END0 (s_in[0]), .S1END1 (s_in[1]), .S1END2 (s_in[2]), .S1END3 (s_in[3]),
        .W1END0 (w_in[0]), .W1END1 (w_in[1]), .W1END2 (w_in[2]), .W1END3 (w_in[3]),
        .LA_O   (bel_o[0]), .LB_O (bel_o[1]), .LC_O (bel_o[2]), .LD_O (bel_o[3]),
        .LA_I0 (lut_in[0]),  .LA_I1 (lut_in[1]),  .LA_I2 (lut_in[2]),  .LA_I3 (lut_in[3]),
        .LB_I0 (lut_in[4]),  .LB_I1 (lut_in[5]),  .LB_I2 (lut_in[6]),  .LB_I3 (lut_in[7]),
        .LC_I0 (lut_in[8]),  .LC_I1 (lut_in[9]),  .LC_I2 (lut_in[10]), .LC_I3 (lut_in[11]),
        .LD_I0 (lut_in[12]), .LD_I1 (lut_in[13]), .LD_I2 (lut_in[14]), .LD_I3 (lut_in[15]),
        .LA_EN (bel_en[0]), .LA_SR (bel_sr[0]),
        .LB_EN (bel_en[1]), .LB_SR (bel_sr[1]),
        .LC_EN (bel_en[2]), .LC_SR (bel_sr[2]),
        .LD_EN (bel_en[3]), .LD_SR (bel_sr[3]),
        .N1BEG0 (n_out[0]), .N1BEG1 (n_out[1]), .N1BEG2 (n_out[2]), .N1BEG3 (n_out[3]),
        .E1BEG0 (e_out[0]), .E1BEG1 (e_out[1]), .E1BEG2 (e_out[2]), .E1BEG3 (e_out[3]),
        .S1BEG0 (s_out[0]), .S1BEG1 (s_out[1]), .S1BEG2 (s_out[2]), .S1BEG3 (s_out[3]),
        .W1BEG0 (w_out[0]), .W1BEG1 (w_out[1]), .W1BEG2 (w_out[2]), .W1BEG3 (w_out[3])
    );

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_slice
            lut4_slice u_slice (
                .clk      (clk),
                .rst      (bel_sr[i]),
                .ce       (bel_en[i]),
                .in       (lut_in[4*i +: 4]),
                .lut_init (cfg[17*i +: 16]),
                .reg_sel  (cfg[17*i + 16]),
                .out      (bel_o[i])
            );
        end
    endgenerate

endmodule

`default_nettype wire
