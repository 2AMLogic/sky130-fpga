// Map abc's $lut cells onto the LOGIC4 BEL (combinational: FF=0).
module \$lut #(parameter WIDTH = 4, parameter LUT = 16'h0) (
    input [WIDTH-1:0] A, output Y
);
    wire [3:0] I = A;
    lut4_ff_bel #(.INIT(LUT), .FF(1'b0)) _lut (
        .I0(I[0]), .I1(I[1]), .I2(I[2]), .I3(I[3]),
        .SR(1'b0), .EN(1'b0), .O(Y));
endmodule
