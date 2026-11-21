// Replay nextpnr's six-LUT chain on the generated 2x2 eFPGA. The bench
// supplies values only at LUT inputs left unconnected by cross_tile.v.
`timescale 1ns/1ps
module tb_fabric_bitstream;
    localparam CFG_N = 158;
    reg clk = 0, reset_n = 0, write_strobe = 0;
    reg [31:0] word = 0;
    always #1 clk = ~clk;
    eFPGA_top dut (.CLK(clk), .resetn(reset_n), .SelfWriteData(word),
                   .SelfWriteStrobe(write_strobe), .Rx(1'b1), .s_clk(1'b0), .s_data(1'b0));

    // Placement of u0..u5 in the pinned route. n3 is the X2Y1 -> X1Y1
    // crossing. All five routed I0 inputs and every output are driven by RTL.
`define U0 dut.eFPGA_inst.Tile_X2Y1_LOGIC4.Inst_LC_lut4_ff_bel
`define U1 dut.eFPGA_inst.Tile_X2Y1_LOGIC4.Inst_LA_lut4_ff_bel
`define U2 dut.eFPGA_inst.Tile_X2Y1_LOGIC4.Inst_LD_lut4_ff_bel
`define U3 dut.eFPGA_inst.Tile_X1Y1_LOGIC4.Inst_LB_lut4_ff_bel
`define U4 dut.eFPGA_inst.Tile_X1Y1_LOGIC4.Inst_LA_lut4_ff_bel
`define U5 dut.eFPGA_inst.Tile_X1Y1_LOGIC4.Inst_LD_lut4_ff_bel
    wire [5:0] chain = {`U5.O, `U4.O, `U3.O, `U2.O, `U1.O, `U0.O};
    wire [4*CFG_N-1:0] latched = {dut.eFPGA_inst.Tile_X2Y2_LOGIC4.ConfigBits,
                                   dut.eFPGA_inst.Tile_X1Y2_LOGIC4.ConfigBits,
                                   dut.eFPGA_inst.Tile_X2Y1_LOGIC4.ConfigBits,
                                   dut.eFPGA_inst.Tile_X1Y1_LOGIC4.ConfigBits};
    reg [4*CFG_N-1:0] expected_cfg;
    reg [3:0] stimulus;
    integer fd, bytes_read, vector, stage, failures = 0;
    string bin_path, cfg_path;

    initial begin
        if (!$value$plusargs("bin=%s", bin_path) || !$value$plusargs("cfg=%s", cfg_path))
            $fatal(1, "missing +bin or +cfg");
        fd = $fopen(bin_path, "rb");
        if (!fd) $fatal(1, "cannot open bitstream");
        repeat (3) @(negedge clk);
        reset_n = 1;
        // $fread fills packed words MSB first. The pinned ConfigFSM handles
        // sync, row ordering, select and desync; space writes for its long strobe.
        bytes_read = $fread(word, fd);
        while (bytes_read == 4) begin
            write_strobe = 1;
            @(negedge clk);
            write_strobe = 0;
            repeat (3) @(negedge clk);
            bytes_read = $fread(word, fd);
        end
        if (bytes_read != 0) $fatal(1, "partial bitstream word");
        $fclose(fd);
        fd = $fopen(cfg_path, "r");
        if (!fd || $fscanf(fd, "%h", expected_cfg) != 1) $fatal(1, "cannot read cfg");
        $fclose(fd);
        if ($isunknown(latched) || latched !== expected_cfg)
            $fatal(1, "generated ConfigMem readback differs from decoded stream");

        force `U0.I = stimulus;
        force `U1.I[3:1] = 0;
        force `U2.I[3:1] = 0;
        force `U3.I[3:1] = 0;
        force `U4.I[3:1] = 0;
        force `U5.I[3:1] = 0;
        for (vector = 0; vector < 16; vector = vector + 1) begin
            stimulus = vector;
            #5;  // allow the chain of generated #80 ps muxes to settle
            if ($isunknown(chain)) $fatal(1, "unknown LUT output for vector %d", vector);
            for (stage = 0; stage < 6; stage = stage + 1)
                if (chain[stage] != ^stimulus) failures = failures + 1;
        end
        if (failures == 0) $display("PASS: tb_fabric_bitstream (96 checks, 0 failures)");
        else $display("FAIL: tb_fabric_bitstream (96 checks, %0d failures)", failures);
        $finish;
    end
`undef U0
`undef U1
`undef U2
`undef U3
`undef U4
`undef U5
endmodule
