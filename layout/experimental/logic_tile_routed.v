module logic_tile_routed (clk,
    cfg,
    e_in,
    e_out,
    n_in,
    n_out,
    s_in,
    s_out,
    w_in,
    w_out);
 input clk;
 input [157:0] cfg;
 input [3:0] e_in;
 output [3:0] e_out;
 input [3:0] n_in;
 output [3:0] n_out;
 input [3:0] s_in;
 output [3:0] s_out;
 input [3:0] w_in;
 output [3:0] w_out;

 wire \g_slice[0].u_slice/_00_ ;
 wire \g_slice[0].u_slice/_01_ ;
 wire \g_slice[0].u_slice/_02_ ;
 wire \g_slice[0].u_slice/_03_ ;
 wire \g_slice[0].u_slice/_04_ ;
 wire \g_slice[0].u_slice/_05_ ;
 wire \g_slice[0].u_slice/_06_ ;
 wire \g_slice[0].u_slice/_07_ ;
 wire \g_slice[0].u_slice/_08_ ;
 wire \g_slice[0].u_slice/ff_q ;
 wire \g_slice[1].u_slice/_00_ ;
 wire \g_slice[1].u_slice/_01_ ;
 wire \g_slice[1].u_slice/_02_ ;
 wire \g_slice[1].u_slice/_03_ ;
 wire \g_slice[1].u_slice/_04_ ;
 wire \g_slice[1].u_slice/_05_ ;
 wire \g_slice[1].u_slice/_06_ ;
 wire \g_slice[1].u_slice/_07_ ;
 wire \g_slice[1].u_slice/_08_ ;
 wire \g_slice[1].u_slice/ff_q ;
 wire \g_slice[2].u_slice/_00_ ;
 wire \g_slice[2].u_slice/_01_ ;
 wire \g_slice[2].u_slice/_02_ ;
 wire \g_slice[2].u_slice/_03_ ;
 wire \g_slice[2].u_slice/_04_ ;
 wire \g_slice[2].u_slice/_05_ ;
 wire \g_slice[2].u_slice/_06_ ;
 wire \g_slice[2].u_slice/_07_ ;
 wire \g_slice[2].u_slice/_08_ ;
 wire \g_slice[2].u_slice/ff_q ;
 wire \g_slice[3].u_slice/_00_ ;
 wire \g_slice[3].u_slice/_01_ ;
 wire \g_slice[3].u_slice/_02_ ;
 wire \g_slice[3].u_slice/_03_ ;
 wire \g_slice[3].u_slice/_04_ ;
 wire \g_slice[3].u_slice/_05_ ;
 wire \g_slice[3].u_slice/_06_ ;
 wire \g_slice[3].u_slice/_07_ ;
 wire \g_slice[3].u_slice/_08_ ;
 wire \g_slice[3].u_slice/ff_q ;
 wire clknet_1_1__leaf_clk;
 wire \u_sm/_001_ ;
 wire \u_sm/_003_ ;
 wire clknet_0_clk;
 wire \u_sm/_005_ ;
 wire \u_sm/_006_ ;
 wire clknet_1_0__leaf_clk;
 wire \u_sm/_008_ ;
 wire \u_sm/_009_ ;
 wire \u_sm/_010_ ;
 wire \u_sm/_011_ ;
 wire \u_sm/_012_ ;
 wire \u_sm/_013_ ;
 wire \u_sm/_014_ ;
 wire \u_sm/_015_ ;
 wire \u_sm/_016_ ;
 wire \u_sm/_017_ ;
 wire \u_sm/_018_ ;
 wire \u_sm/_019_ ;
 wire \u_sm/_020_ ;
 wire \u_sm/_021_ ;
 wire \u_sm/_022_ ;
 wire \u_sm/_023_ ;
 wire \u_sm/_024_ ;
 wire \u_sm/_025_ ;
 wire \u_sm/_026_ ;
 wire \u_sm/_027_ ;
 wire \u_sm/_028_ ;
 wire \u_sm/_029_ ;
 wire \u_sm/_030_ ;
 wire \u_sm/_031_ ;
 wire \u_sm/_032_ ;
 wire \u_sm/_033_ ;
 wire \u_sm/_034_ ;
 wire \u_sm/_035_ ;
 wire \u_sm/_036_ ;
 wire \u_sm/_037_ ;
 wire \u_sm/_038_ ;
 wire \u_sm/_039_ ;
 wire \u_sm/_040_ ;
 wire \u_sm/_041_ ;
 wire \u_sm/_042_ ;
 wire \u_sm/_043_ ;
 wire \u_sm/_044_ ;
 wire \u_sm/_045_ ;
 wire \u_sm/_046_ ;
 wire \u_sm/_047_ ;
 wire \u_sm/_048_ ;
 wire \u_sm/_049_ ;
 wire \u_sm/_050_ ;
 wire \u_sm/_051_ ;
 wire \u_sm/_052_ ;
 wire \u_sm/_053_ ;
 wire \u_sm/_054_ ;
 wire \u_sm/_055_ ;
 wire \u_sm/_056_ ;
 wire \u_sm/_057_ ;
 wire \u_sm/_058_ ;
 wire \u_sm/_059_ ;
 wire \u_sm/_060_ ;
 wire \u_sm/_061_ ;
 wire \u_sm/_062_ ;
 wire \u_sm/_063_ ;
 wire \u_sm/_064_ ;
 wire \u_sm/_065_ ;
 wire \u_sm/_066_ ;
 wire \u_sm/_067_ ;
 wire [3:0] bel_en;
 wire [3:0] bel_o;
 wire [0:0] bel_sr;
 wire [15:0] lut_in;

 sky130_fd_sc_hd__diode_2 ANTENNA_1 (.DIODE(cfg[1]));
 sky130_fd_sc_hd__diode_2 ANTENNA_2 (.DIODE(cfg[52]));
 sky130_fd_sc_hd__buf_4 clkbuf_0_clk (.A(clk),
    .X(clknet_0_clk));
 sky130_fd_sc_hd__buf_4 clkbuf_1_0__f_clk (.A(clknet_0_clk),
    .X(clknet_1_0__leaf_clk));
 sky130_fd_sc_hd__buf_4 clkbuf_1_1__f_clk (.A(clknet_0_clk),
    .X(clknet_1_1__leaf_clk));
 sky130_fd_sc_hd__mux4_2 \g_slice[0].u_slice/_09_  (.A0(cfg[0]),
    .A1(cfg[1]),
    .A2(cfg[2]),
    .A3(cfg[3]),
    .S0(lut_in[0]),
    .S1(lut_in[1]),
    .X(\g_slice[0].u_slice/_01_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[0].u_slice/_10_  (.A0(cfg[8]),
    .A1(cfg[9]),
    .A2(cfg[10]),
    .A3(cfg[11]),
    .S0(lut_in[0]),
    .S1(lut_in[1]),
    .X(\g_slice[0].u_slice/_02_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[0].u_slice/_11_  (.A0(cfg[4]),
    .A1(cfg[5]),
    .A2(cfg[6]),
    .A3(cfg[7]),
    .S0(lut_in[0]),
    .S1(lut_in[1]),
    .X(\g_slice[0].u_slice/_03_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[0].u_slice/_12_  (.A0(cfg[12]),
    .A1(cfg[13]),
    .A2(cfg[14]),
    .A3(cfg[15]),
    .S0(lut_in[0]),
    .S1(lut_in[1]),
    .X(\g_slice[0].u_slice/_04_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[0].u_slice/_13_  (.A0(\g_slice[0].u_slice/_01_ ),
    .A1(\g_slice[0].u_slice/_02_ ),
    .A2(\g_slice[0].u_slice/_03_ ),
    .A3(\g_slice[0].u_slice/_04_ ),
    .S0(lut_in[3]),
    .S1(lut_in[2]),
    .X(\g_slice[0].u_slice/_05_ ));
 sky130_fd_sc_hd__mux2_2 \g_slice[0].u_slice/_14_  (.A0(\g_slice[0].u_slice/_05_ ),
    .A1(\g_slice[0].u_slice/ff_q ),
    .S(cfg[16]),
    .X(bel_o[0]));
 sky130_fd_sc_hd__inv_1 \g_slice[0].u_slice/_15_  (.A(bel_en[0]),
    .Y(\g_slice[0].u_slice/_06_ ));
 sky130_fd_sc_hd__nor2_1 \g_slice[0].u_slice/_16_  (.A(\g_slice[0].u_slice/ff_q ),
    .B(bel_en[0]),
    .Y(\g_slice[0].u_slice/_07_ ));
 sky130_fd_sc_hd__nor2_1 \g_slice[0].u_slice/_17_  (.A(bel_sr[0]),
    .B(\g_slice[0].u_slice/_07_ ),
    .Y(\g_slice[0].u_slice/_08_ ));
 sky130_fd_sc_hd__o21a_1 \g_slice[0].u_slice/_18_  (.A1(\g_slice[0].u_slice/_06_ ),
    .A2(\g_slice[0].u_slice/_05_ ),
    .B1(\g_slice[0].u_slice/_08_ ),
    .X(\g_slice[0].u_slice/_00_ ));
 sky130_fd_sc_hd__dfxtp_1 \g_slice[0].u_slice/_19_  (.CLK(clknet_1_0__leaf_clk),
    .D(\g_slice[0].u_slice/_00_ ),
    .Q(\g_slice[0].u_slice/ff_q ));
 sky130_fd_sc_hd__mux4_2 \g_slice[1].u_slice/_09_  (.A0(cfg[17]),
    .A1(cfg[18]),
    .A2(cfg[19]),
    .A3(cfg[20]),
    .S0(lut_in[4]),
    .S1(lut_in[5]),
    .X(\g_slice[1].u_slice/_01_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[1].u_slice/_10_  (.A0(cfg[25]),
    .A1(cfg[26]),
    .A2(cfg[27]),
    .A3(cfg[28]),
    .S0(lut_in[4]),
    .S1(lut_in[5]),
    .X(\g_slice[1].u_slice/_02_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[1].u_slice/_11_  (.A0(cfg[21]),
    .A1(cfg[22]),
    .A2(cfg[23]),
    .A3(cfg[24]),
    .S0(lut_in[4]),
    .S1(lut_in[5]),
    .X(\g_slice[1].u_slice/_03_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[1].u_slice/_12_  (.A0(cfg[29]),
    .A1(cfg[30]),
    .A2(cfg[31]),
    .A3(cfg[32]),
    .S0(lut_in[4]),
    .S1(lut_in[5]),
    .X(\g_slice[1].u_slice/_04_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[1].u_slice/_13_  (.A0(\g_slice[1].u_slice/_01_ ),
    .A1(\g_slice[1].u_slice/_02_ ),
    .A2(\g_slice[1].u_slice/_03_ ),
    .A3(\g_slice[1].u_slice/_04_ ),
    .S0(lut_in[7]),
    .S1(lut_in[6]),
    .X(\g_slice[1].u_slice/_05_ ));
 sky130_fd_sc_hd__mux2_2 \g_slice[1].u_slice/_14_  (.A0(\g_slice[1].u_slice/_05_ ),
    .A1(\g_slice[1].u_slice/ff_q ),
    .S(cfg[33]),
    .X(bel_o[1]));
 sky130_fd_sc_hd__inv_1 \g_slice[1].u_slice/_15_  (.A(bel_en[1]),
    .Y(\g_slice[1].u_slice/_06_ ));
 sky130_fd_sc_hd__nor2_1 \g_slice[1].u_slice/_16_  (.A(\g_slice[1].u_slice/ff_q ),
    .B(bel_en[1]),
    .Y(\g_slice[1].u_slice/_07_ ));
 sky130_fd_sc_hd__nor2_1 \g_slice[1].u_slice/_17_  (.A(bel_sr[0]),
    .B(\g_slice[1].u_slice/_07_ ),
    .Y(\g_slice[1].u_slice/_08_ ));
 sky130_fd_sc_hd__o21a_1 \g_slice[1].u_slice/_18_  (.A1(\g_slice[1].u_slice/_06_ ),
    .A2(\g_slice[1].u_slice/_05_ ),
    .B1(\g_slice[1].u_slice/_08_ ),
    .X(\g_slice[1].u_slice/_00_ ));
 sky130_fd_sc_hd__dfxtp_1 \g_slice[1].u_slice/_19_  (.CLK(clknet_1_1__leaf_clk),
    .D(\g_slice[1].u_slice/_00_ ),
    .Q(\g_slice[1].u_slice/ff_q ));
 sky130_fd_sc_hd__mux4_2 \g_slice[2].u_slice/_09_  (.A0(cfg[34]),
    .A1(cfg[35]),
    .A2(cfg[36]),
    .A3(cfg[37]),
    .S0(lut_in[8]),
    .S1(lut_in[9]),
    .X(\g_slice[2].u_slice/_01_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[2].u_slice/_10_  (.A0(cfg[42]),
    .A1(cfg[43]),
    .A2(cfg[44]),
    .A3(cfg[45]),
    .S0(lut_in[8]),
    .S1(lut_in[9]),
    .X(\g_slice[2].u_slice/_02_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[2].u_slice/_11_  (.A0(cfg[38]),
    .A1(cfg[39]),
    .A2(cfg[40]),
    .A3(cfg[41]),
    .S0(lut_in[8]),
    .S1(lut_in[9]),
    .X(\g_slice[2].u_slice/_03_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[2].u_slice/_12_  (.A0(cfg[46]),
    .A1(cfg[47]),
    .A2(cfg[48]),
    .A3(cfg[49]),
    .S0(lut_in[8]),
    .S1(lut_in[9]),
    .X(\g_slice[2].u_slice/_04_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[2].u_slice/_13_  (.A0(\g_slice[2].u_slice/_01_ ),
    .A1(\g_slice[2].u_slice/_02_ ),
    .A2(\g_slice[2].u_slice/_03_ ),
    .A3(\g_slice[2].u_slice/_04_ ),
    .S0(lut_in[11]),
    .S1(lut_in[10]),
    .X(\g_slice[2].u_slice/_05_ ));
 sky130_fd_sc_hd__mux2_2 \g_slice[2].u_slice/_14_  (.A0(\g_slice[2].u_slice/_05_ ),
    .A1(\g_slice[2].u_slice/ff_q ),
    .S(cfg[50]),
    .X(bel_o[2]));
 sky130_fd_sc_hd__inv_1 \g_slice[2].u_slice/_15_  (.A(bel_en[2]),
    .Y(\g_slice[2].u_slice/_06_ ));
 sky130_fd_sc_hd__nor2_1 \g_slice[2].u_slice/_16_  (.A(\g_slice[2].u_slice/ff_q ),
    .B(bel_en[2]),
    .Y(\g_slice[2].u_slice/_07_ ));
 sky130_fd_sc_hd__nor2_1 \g_slice[2].u_slice/_17_  (.A(bel_sr[0]),
    .B(\g_slice[2].u_slice/_07_ ),
    .Y(\g_slice[2].u_slice/_08_ ));
 sky130_fd_sc_hd__o21a_1 \g_slice[2].u_slice/_18_  (.A1(\g_slice[2].u_slice/_06_ ),
    .A2(\g_slice[2].u_slice/_05_ ),
    .B1(\g_slice[2].u_slice/_08_ ),
    .X(\g_slice[2].u_slice/_00_ ));
 sky130_fd_sc_hd__dfxtp_1 \g_slice[2].u_slice/_19_  (.CLK(clknet_1_1__leaf_clk),
    .D(\g_slice[2].u_slice/_00_ ),
    .Q(\g_slice[2].u_slice/ff_q ));
 sky130_fd_sc_hd__mux4_2 \g_slice[3].u_slice/_09_  (.A0(cfg[51]),
    .A1(cfg[52]),
    .A2(cfg[53]),
    .A3(cfg[54]),
    .S0(lut_in[12]),
    .S1(lut_in[13]),
    .X(\g_slice[3].u_slice/_01_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[3].u_slice/_10_  (.A0(cfg[59]),
    .A1(cfg[60]),
    .A2(cfg[61]),
    .A3(cfg[62]),
    .S0(lut_in[12]),
    .S1(lut_in[13]),
    .X(\g_slice[3].u_slice/_02_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[3].u_slice/_11_  (.A0(cfg[55]),
    .A1(cfg[56]),
    .A2(cfg[57]),
    .A3(cfg[58]),
    .S0(lut_in[12]),
    .S1(lut_in[13]),
    .X(\g_slice[3].u_slice/_03_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[3].u_slice/_12_  (.A0(cfg[63]),
    .A1(cfg[64]),
    .A2(cfg[65]),
    .A3(cfg[66]),
    .S0(lut_in[12]),
    .S1(lut_in[13]),
    .X(\g_slice[3].u_slice/_04_ ));
 sky130_fd_sc_hd__mux4_2 \g_slice[3].u_slice/_13_  (.A0(\g_slice[3].u_slice/_01_ ),
    .A1(\g_slice[3].u_slice/_02_ ),
    .A2(\g_slice[3].u_slice/_03_ ),
    .A3(\g_slice[3].u_slice/_04_ ),
    .S0(lut_in[15]),
    .S1(lut_in[14]),
    .X(\g_slice[3].u_slice/_05_ ));
 sky130_fd_sc_hd__mux2_2 \g_slice[3].u_slice/_14_  (.A0(\g_slice[3].u_slice/_05_ ),
    .A1(\g_slice[3].u_slice/ff_q ),
    .S(cfg[67]),
    .X(bel_o[3]));
 sky130_fd_sc_hd__inv_1 \g_slice[3].u_slice/_15_  (.A(bel_en[3]),
    .Y(\g_slice[3].u_slice/_06_ ));
 sky130_fd_sc_hd__nor2_1 \g_slice[3].u_slice/_16_  (.A(\g_slice[3].u_slice/ff_q ),
    .B(bel_en[3]),
    .Y(\g_slice[3].u_slice/_07_ ));
 sky130_fd_sc_hd__nor2_1 \g_slice[3].u_slice/_17_  (.A(bel_sr[0]),
    .B(\g_slice[3].u_slice/_07_ ),
    .Y(\g_slice[3].u_slice/_08_ ));
 sky130_fd_sc_hd__o21a_1 \g_slice[3].u_slice/_18_  (.A1(\g_slice[3].u_slice/_06_ ),
    .A2(\g_slice[3].u_slice/_05_ ),
    .B1(\g_slice[3].u_slice/_08_ ),
    .X(\g_slice[3].u_slice/_00_ ));
 sky130_fd_sc_hd__dfxtp_1 \g_slice[3].u_slice/_19_  (.CLK(clknet_1_0__leaf_clk),
    .D(\g_slice[3].u_slice/_00_ ),
    .Q(\g_slice[3].u_slice/ff_q ));
 sky130_fd_sc_hd__mux4_2 \u_sm/_069_  (.A0(e_in[2]),
    .A1(bel_o[1]),
    .A2(s_in[2]),
    .A3(bel_o[2]),
    .S0(cfg[76]),
    .S1(cfg[74]),
    .X(\u_sm/_001_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_071_  (.A0(w_in[2]),
    .A1(bel_o[3]),
    .S(cfg[76]),
    .Y(\u_sm/_003_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_073_  (.A(bel_o[0]),
    .B(cfg[74]),
    .Y(\u_sm/_005_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_074_  (.A1(cfg[74]),
    .A2(\u_sm/_003_ ),
    .B1(\u_sm/_005_ ),
    .B2(cfg[76]),
    .C1(cfg[75]),
    .Y(\u_sm/_006_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_075_  (.A1(cfg[75]),
    .A2(\u_sm/_001_ ),
    .B1(\u_sm/_006_ ),
    .X(n_out[2]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_077_  (.A0(e_in[3]),
    .A1(s_in[3]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[77]),
    .S1(cfg[79]),
    .X(\u_sm/_008_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_078_  (.A0(w_in[3]),
    .A1(bel_o[3]),
    .S(cfg[79]),
    .Y(\u_sm/_009_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_079_  (.A(bel_o[0]),
    .B(cfg[77]),
    .Y(\u_sm/_010_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_080_  (.A1(cfg[77]),
    .A2(\u_sm/_009_ ),
    .B1(\u_sm/_010_ ),
    .B2(cfg[79]),
    .C1(cfg[78]),
    .Y(\u_sm/_011_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_081_  (.A1(cfg[78]),
    .A2(\u_sm/_008_ ),
    .B1(\u_sm/_011_ ),
    .X(n_out[3]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_082_  (.A0(n_in[0]),
    .A1(s_in[0]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[80]),
    .S1(cfg[82]),
    .X(\u_sm/_012_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_083_  (.A0(w_in[0]),
    .A1(bel_o[3]),
    .S(cfg[82]),
    .Y(\u_sm/_013_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_084_  (.A(bel_o[0]),
    .B(cfg[80]),
    .Y(\u_sm/_014_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_085_  (.A1(cfg[80]),
    .A2(\u_sm/_013_ ),
    .B1(\u_sm/_014_ ),
    .B2(cfg[82]),
    .C1(cfg[81]),
    .Y(\u_sm/_015_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_086_  (.A1(cfg[81]),
    .A2(\u_sm/_012_ ),
    .B1(\u_sm/_015_ ),
    .X(e_out[0]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_087_  (.A0(n_in[1]),
    .A1(s_in[1]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[83]),
    .S1(cfg[85]),
    .X(\u_sm/_016_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_088_  (.A0(w_in[1]),
    .A1(bel_o[3]),
    .S(cfg[85]),
    .Y(\u_sm/_017_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_089_  (.A(bel_o[0]),
    .B(cfg[83]),
    .Y(\u_sm/_018_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_090_  (.A1(cfg[83]),
    .A2(\u_sm/_017_ ),
    .B1(\u_sm/_018_ ),
    .B2(cfg[85]),
    .C1(cfg[84]),
    .Y(\u_sm/_019_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_091_  (.A1(cfg[84]),
    .A2(\u_sm/_016_ ),
    .B1(\u_sm/_019_ ),
    .X(e_out[1]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_092_  (.A0(n_in[2]),
    .A1(bel_o[1]),
    .A2(s_in[2]),
    .A3(bel_o[2]),
    .S0(cfg[88]),
    .S1(cfg[86]),
    .X(\u_sm/_020_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_093_  (.A0(w_in[2]),
    .A1(bel_o[3]),
    .S(cfg[88]),
    .Y(\u_sm/_021_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_094_  (.A(bel_o[0]),
    .B(cfg[86]),
    .Y(\u_sm/_022_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_095_  (.A1(cfg[86]),
    .A2(\u_sm/_021_ ),
    .B1(\u_sm/_022_ ),
    .B2(cfg[88]),
    .C1(cfg[87]),
    .Y(\u_sm/_023_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_096_  (.A1(cfg[87]),
    .A2(\u_sm/_020_ ),
    .B1(\u_sm/_023_ ),
    .X(e_out[2]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_097_  (.A0(n_in[3]),
    .A1(s_in[3]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[89]),
    .S1(cfg[91]),
    .X(\u_sm/_024_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_098_  (.A0(w_in[3]),
    .A1(bel_o[3]),
    .S(cfg[91]),
    .Y(\u_sm/_025_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_099_  (.A(bel_o[0]),
    .B(cfg[89]),
    .Y(\u_sm/_026_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_100_  (.A1(cfg[89]),
    .A2(\u_sm/_025_ ),
    .B1(\u_sm/_026_ ),
    .B2(cfg[91]),
    .C1(cfg[90]),
    .Y(\u_sm/_027_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_101_  (.A1(cfg[90]),
    .A2(\u_sm/_024_ ),
    .B1(\u_sm/_027_ ),
    .X(e_out[3]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_102_  (.A0(n_in[0]),
    .A1(e_in[0]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[92]),
    .S1(cfg[94]),
    .X(\u_sm/_028_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_103_  (.A0(w_in[0]),
    .A1(bel_o[3]),
    .S(cfg[94]),
    .Y(\u_sm/_029_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_104_  (.A(bel_o[0]),
    .B(cfg[92]),
    .Y(\u_sm/_030_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_105_  (.A1(cfg[92]),
    .A2(\u_sm/_029_ ),
    .B1(\u_sm/_030_ ),
    .B2(cfg[94]),
    .C1(cfg[93]),
    .Y(\u_sm/_031_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_106_  (.A1(cfg[93]),
    .A2(\u_sm/_028_ ),
    .B1(\u_sm/_031_ ),
    .X(s_out[0]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_107_  (.A0(n_in[1]),
    .A1(e_in[1]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[95]),
    .S1(cfg[97]),
    .X(\u_sm/_032_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_108_  (.A0(w_in[1]),
    .A1(bel_o[3]),
    .S(cfg[97]),
    .Y(\u_sm/_033_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_109_  (.A(bel_o[0]),
    .B(cfg[95]),
    .Y(\u_sm/_034_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_110_  (.A1(cfg[95]),
    .A2(\u_sm/_033_ ),
    .B1(\u_sm/_034_ ),
    .B2(cfg[97]),
    .C1(cfg[96]),
    .Y(\u_sm/_035_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_111_  (.A1(cfg[96]),
    .A2(\u_sm/_032_ ),
    .B1(\u_sm/_035_ ),
    .X(s_out[1]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_112_  (.A0(n_in[2]),
    .A1(bel_o[1]),
    .A2(e_in[2]),
    .A3(bel_o[2]),
    .S0(cfg[100]),
    .S1(cfg[98]),
    .X(\u_sm/_036_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_113_  (.A0(w_in[2]),
    .A1(bel_o[3]),
    .S(cfg[100]),
    .Y(\u_sm/_037_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_114_  (.A(bel_o[0]),
    .B(cfg[98]),
    .Y(\u_sm/_038_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_115_  (.A1(cfg[98]),
    .A2(\u_sm/_037_ ),
    .B1(\u_sm/_038_ ),
    .B2(cfg[100]),
    .C1(cfg[99]),
    .Y(\u_sm/_039_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_116_  (.A1(cfg[99]),
    .A2(\u_sm/_036_ ),
    .B1(\u_sm/_039_ ),
    .X(s_out[2]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_117_  (.A0(n_in[3]),
    .A1(e_in[3]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[101]),
    .S1(cfg[103]),
    .X(\u_sm/_040_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_118_  (.A0(w_in[3]),
    .A1(bel_o[3]),
    .S(cfg[103]),
    .Y(\u_sm/_041_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_119_  (.A(bel_o[0]),
    .B(cfg[101]),
    .Y(\u_sm/_042_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_120_  (.A1(cfg[101]),
    .A2(\u_sm/_041_ ),
    .B1(\u_sm/_042_ ),
    .B2(cfg[103]),
    .C1(cfg[102]),
    .Y(\u_sm/_043_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_121_  (.A1(cfg[102]),
    .A2(\u_sm/_040_ ),
    .B1(\u_sm/_043_ ),
    .X(s_out[3]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_122_  (.A0(n_in[0]),
    .A1(e_in[0]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[104]),
    .S1(cfg[106]),
    .X(\u_sm/_044_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_123_  (.A0(s_in[0]),
    .A1(bel_o[3]),
    .S(cfg[106]),
    .Y(\u_sm/_045_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_124_  (.A(bel_o[0]),
    .B(cfg[104]),
    .Y(\u_sm/_046_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_125_  (.A1(cfg[104]),
    .A2(\u_sm/_045_ ),
    .B1(\u_sm/_046_ ),
    .B2(cfg[106]),
    .C1(cfg[105]),
    .Y(\u_sm/_047_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_126_  (.A1(cfg[105]),
    .A2(\u_sm/_044_ ),
    .B1(\u_sm/_047_ ),
    .X(w_out[0]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_127_  (.A0(n_in[1]),
    .A1(e_in[1]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[107]),
    .S1(cfg[109]),
    .X(\u_sm/_048_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_128_  (.A0(s_in[1]),
    .A1(bel_o[3]),
    .S(cfg[109]),
    .Y(\u_sm/_049_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_129_  (.A(bel_o[0]),
    .B(cfg[107]),
    .Y(\u_sm/_050_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_130_  (.A1(cfg[107]),
    .A2(\u_sm/_049_ ),
    .B1(\u_sm/_050_ ),
    .B2(cfg[109]),
    .C1(cfg[108]),
    .Y(\u_sm/_051_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_131_  (.A1(cfg[108]),
    .A2(\u_sm/_048_ ),
    .B1(\u_sm/_051_ ),
    .X(w_out[1]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_132_  (.A0(n_in[2]),
    .A1(bel_o[1]),
    .A2(e_in[2]),
    .A3(bel_o[2]),
    .S0(cfg[112]),
    .S1(cfg[110]),
    .X(\u_sm/_052_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_133_  (.A0(s_in[2]),
    .A1(bel_o[3]),
    .S(cfg[112]),
    .Y(\u_sm/_053_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_134_  (.A(bel_o[0]),
    .B(cfg[110]),
    .Y(\u_sm/_054_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_135_  (.A1(cfg[110]),
    .A2(\u_sm/_053_ ),
    .B1(\u_sm/_054_ ),
    .B2(cfg[112]),
    .C1(cfg[111]),
    .Y(\u_sm/_055_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_136_  (.A1(cfg[111]),
    .A2(\u_sm/_052_ ),
    .B1(\u_sm/_055_ ),
    .X(w_out[2]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_137_  (.A0(n_in[3]),
    .A1(e_in[3]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[113]),
    .S1(cfg[115]),
    .X(\u_sm/_056_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_138_  (.A0(s_in[3]),
    .A1(bel_o[3]),
    .S(cfg[115]),
    .Y(\u_sm/_057_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_139_  (.A(bel_o[0]),
    .B(cfg[113]),
    .Y(\u_sm/_058_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_140_  (.A1(cfg[113]),
    .A2(\u_sm/_057_ ),
    .B1(\u_sm/_058_ ),
    .B2(cfg[115]),
    .C1(cfg[114]),
    .Y(\u_sm/_059_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_141_  (.A1(cfg[114]),
    .A2(\u_sm/_056_ ),
    .B1(\u_sm/_059_ ),
    .X(w_out[3]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_142_  (.A0(n_in[0]),
    .A1(e_in[0]),
    .A2(s_in[0]),
    .A3(w_in[0]),
    .S0(cfg[116]),
    .S1(cfg[117]),
    .X(lut_in[0]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_143_  (.A0(n_in[1]),
    .A1(e_in[1]),
    .A2(s_in[1]),
    .A3(w_in[1]),
    .S0(cfg[118]),
    .S1(cfg[119]),
    .X(lut_in[1]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_144_  (.A0(n_in[2]),
    .A1(e_in[2]),
    .A2(s_in[2]),
    .A3(w_in[2]),
    .S0(cfg[120]),
    .S1(cfg[121]),
    .X(lut_in[2]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_145_  (.A0(n_in[3]),
    .A1(e_in[3]),
    .A2(s_in[3]),
    .A3(w_in[3]),
    .S0(cfg[122]),
    .S1(cfg[123]),
    .X(lut_in[3]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_146_  (.A0(n_in[0]),
    .A1(e_in[0]),
    .A2(s_in[0]),
    .A3(w_in[0]),
    .S0(cfg[124]),
    .S1(cfg[125]),
    .X(lut_in[4]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_147_  (.A0(n_in[1]),
    .A1(e_in[1]),
    .A2(s_in[1]),
    .A3(w_in[1]),
    .S0(cfg[126]),
    .S1(cfg[127]),
    .X(lut_in[5]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_148_  (.A0(e_in[1]),
    .A1(w_in[1]),
    .A2(bel_o[1]),
    .A3(bel_o[3]),
    .S0(cfg[72]),
    .S1(cfg[73]),
    .X(\u_sm/_060_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_149_  (.A0(s_in[1]),
    .A1(bel_o[2]),
    .S(cfg[73]),
    .Y(\u_sm/_061_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_150_  (.A(bel_o[0]),
    .B(cfg[72]),
    .Y(\u_sm/_062_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_151_  (.A1(cfg[72]),
    .A2(\u_sm/_061_ ),
    .B1(\u_sm/_062_ ),
    .B2(cfg[73]),
    .C1(cfg[71]),
    .Y(\u_sm/_063_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_152_  (.A1(cfg[71]),
    .A2(\u_sm/_060_ ),
    .B1(\u_sm/_063_ ),
    .X(n_out[1]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_153_  (.A0(n_in[2]),
    .A1(e_in[2]),
    .A2(s_in[2]),
    .A3(w_in[2]),
    .S0(cfg[128]),
    .S1(cfg[129]),
    .X(lut_in[6]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_154_  (.A0(n_in[3]),
    .A1(e_in[3]),
    .A2(s_in[3]),
    .A3(w_in[3]),
    .S0(cfg[130]),
    .S1(cfg[131]),
    .X(lut_in[7]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_155_  (.A0(n_in[0]),
    .A1(e_in[0]),
    .A2(s_in[0]),
    .A3(w_in[0]),
    .S0(cfg[132]),
    .S1(cfg[133]),
    .X(lut_in[8]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_156_  (.A0(n_in[1]),
    .A1(e_in[1]),
    .A2(s_in[1]),
    .A3(w_in[1]),
    .S0(cfg[134]),
    .S1(cfg[135]),
    .X(lut_in[9]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_157_  (.A0(n_in[2]),
    .A1(e_in[2]),
    .A2(s_in[2]),
    .A3(w_in[2]),
    .S0(cfg[136]),
    .S1(cfg[137]),
    .X(lut_in[10]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_158_  (.A0(n_in[3]),
    .A1(e_in[3]),
    .A2(s_in[3]),
    .A3(w_in[3]),
    .S0(cfg[138]),
    .S1(cfg[139]),
    .X(lut_in[11]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_159_  (.A0(n_in[0]),
    .A1(e_in[0]),
    .A2(s_in[0]),
    .A3(w_in[0]),
    .S0(cfg[140]),
    .S1(cfg[141]),
    .X(lut_in[12]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_160_  (.A0(n_in[1]),
    .A1(e_in[1]),
    .A2(s_in[1]),
    .A3(w_in[1]),
    .S0(cfg[142]),
    .S1(cfg[143]),
    .X(lut_in[13]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_161_  (.A0(e_in[0]),
    .A1(s_in[0]),
    .A2(bel_o[1]),
    .A3(bel_o[2]),
    .S0(cfg[68]),
    .S1(cfg[70]),
    .X(\u_sm/_064_ ));
 sky130_fd_sc_hd__mux2i_1 \u_sm/_162_  (.A0(w_in[0]),
    .A1(bel_o[3]),
    .S(cfg[70]),
    .Y(\u_sm/_065_ ));
 sky130_fd_sc_hd__nand2_1 \u_sm/_163_  (.A(bel_o[0]),
    .B(cfg[68]),
    .Y(\u_sm/_066_ ));
 sky130_fd_sc_hd__o221ai_1 \u_sm/_164_  (.A1(cfg[68]),
    .A2(\u_sm/_065_ ),
    .B1(\u_sm/_066_ ),
    .B2(cfg[70]),
    .C1(cfg[69]),
    .Y(\u_sm/_067_ ));
 sky130_fd_sc_hd__o21a_1 \u_sm/_165_  (.A1(cfg[69]),
    .A2(\u_sm/_064_ ),
    .B1(\u_sm/_067_ ),
    .X(n_out[0]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_166_  (.A0(n_in[2]),
    .A1(e_in[2]),
    .A2(s_in[2]),
    .A3(w_in[2]),
    .S0(cfg[144]),
    .S1(cfg[145]),
    .X(lut_in[14]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_167_  (.A0(n_in[3]),
    .A1(e_in[3]),
    .A2(s_in[3]),
    .A3(w_in[3]),
    .S0(cfg[146]),
    .S1(cfg[147]),
    .X(lut_in[15]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_168_  (.A0(n_in[0]),
    .A1(e_in[0]),
    .A2(s_in[0]),
    .A3(w_in[0]),
    .S0(cfg[148]),
    .S1(cfg[149]),
    .X(bel_sr[0]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_169_  (.A0(n_in[0]),
    .A1(e_in[0]),
    .A2(s_in[0]),
    .A3(w_in[0]),
    .S0(cfg[150]),
    .S1(cfg[151]),
    .X(bel_en[0]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_170_  (.A0(n_in[1]),
    .A1(e_in[1]),
    .A2(s_in[1]),
    .A3(w_in[1]),
    .S0(cfg[152]),
    .S1(cfg[153]),
    .X(bel_en[1]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_171_  (.A0(n_in[2]),
    .A1(e_in[2]),
    .A2(s_in[2]),
    .A3(w_in[2]),
    .S0(cfg[154]),
    .S1(cfg[155]),
    .X(bel_en[2]));
 sky130_fd_sc_hd__mux4_2 \u_sm/_172_  (.A0(n_in[3]),
    .A1(e_in[3]),
    .A2(s_in[3]),
    .A3(w_in[3]),
    .S0(cfg[156]),
    .S1(cfg[157]),
    .X(bel_en[3]));
endmodule
