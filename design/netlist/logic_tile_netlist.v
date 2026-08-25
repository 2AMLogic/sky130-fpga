
module logic_tile(clk, rst, ce, in, lut_init, reg_sel, out);
  input clk;
  wire clk;
  input rst;
  wire rst;
  input [3:0] ce;
  wire [3:0] ce;
  input [15:0] in;
  wire [15:0] in;
  input [63:0] lut_init;
  wire [63:0] lut_init;
  input [3:0] reg_sel;
  wire [3:0] reg_sel;
  output [3:0] out;
  wire [3:0] out;
  lut4_slice \g_slice[0].u_slice  (
    .ce(ce[0]),
    .clk(clk),
    .in(in[3:0]),
    .lut_init(lut_init[15:0]),
    .out(out[0]),
    .reg_sel(reg_sel[0]),
    .rst(rst)
  );
  lut4_slice \g_slice[1].u_slice  (
    .ce(ce[1]),
    .clk(clk),
    .in(in[7:4]),
    .lut_init(lut_init[31:16]),
    .out(out[1]),
    .reg_sel(reg_sel[1]),
    .rst(rst)
  );
  lut4_slice \g_slice[2].u_slice  (
    .ce(ce[2]),
    .clk(clk),
    .in(in[11:8]),
    .lut_init(lut_init[47:32]),
    .out(out[2]),
    .reg_sel(reg_sel[2]),
    .rst(rst)
  );
  lut4_slice \g_slice[3].u_slice  (
    .ce(ce[3]),
    .clk(clk),
    .in(in[15:12]),
    .lut_init(lut_init[63:48]),
    .out(out[3]),
    .reg_sel(reg_sel[3]),
    .rst(rst)
  );
endmodule

module lut4_slice(clk, rst, ce, in, lut_init, reg_sel, out);
  input clk;
  wire clk;
  input rst;
  wire rst;
  input ce;
  wire ce;
  input [3:0] in;
  wire [3:0] in;
  input [15:0] lut_init;
  wire [15:0] lut_init;
  input reg_sel;
  wire reg_sel;
  output out;
  wire out;
  wire [15:0] _00_;
  wire [15:0] _01_;
  wire [15:0] _02_;
  reg ff_q;
  wire lut_out;
  always @(posedge clk)
    if (rst) ff_q <= 1'h0;
    else if (ce) ff_q <= lut_out;
  assign out = reg_sel ? ff_q : lut_out;
  assign _01_[0] = in[1] ? _00_[2] : _00_[0];
  assign _01_[4] = in[1] ? _00_[6] : _00_[4];
  assign _01_[8] = in[1] ? _00_[10] : _00_[8];
  assign _01_[12] = in[1] ? _00_[14] : _00_[12];
  assign _02_[0] = in[2] ? _01_[4] : _01_[0];
  assign _02_[8] = in[2] ? _01_[12] : _01_[8];
  assign _00_[0] = in[0] ? lut_init[1] : lut_init[0];
  assign _00_[2] = in[0] ? lut_init[3] : lut_init[2];
  assign _00_[4] = in[0] ? lut_init[5] : lut_init[4];
  assign _00_[6] = in[0] ? lut_init[7] : lut_init[6];
  assign _00_[8] = in[0] ? lut_init[9] : lut_init[8];
  assign _00_[10] = in[0] ? lut_init[11] : lut_init[10];
  assign _00_[12] = in[0] ? lut_init[13] : lut_init[12];
  assign _00_[14] = in[0] ? lut_init[15] : lut_init[14];
  assign lut_out = in[3] ? _02_[8] : _02_[0];
endmodule
