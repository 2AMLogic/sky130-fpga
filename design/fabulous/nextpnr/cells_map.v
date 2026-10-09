// Map abc's $lut cells onto the LOGIC4 BEL (combinational: FF=0).
//
// ADR-0005 constant handling: no constant driver exists in the fabric, so no
// pin is tied. A LUT narrower than 4 inputs has its truth table replicated
// across the unused upper inputs (INIT[i] = LUT[i mod 2^WIDTH]) and those
// pins are left unconnected, so whatever the config-selected switch-matrix
// mux feeds them cannot change the output. SR/EN are also left unconnected
// (FF=0, so they are don't-care).
module \$lut #(parameter WIDTH = 4, parameter LUT = 16'h0) (
    input [WIDTH-1:0] A, output Y
);
    function [15:0] rep(input [15:0] t);
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1) rep[i] = t[i % (1 << WIDTH)];
        end
    endfunction
    wire [3:0] I;
    assign I[WIDTH-1:0] = A;
    lut4_ff_bel #(.INIT(rep(LUT)), .FF(1'b0)) _lut (
        .I0(I[0]), .I1(I[1]), .I2(I[2]), .I3(I[3]), .O(Y));
endmodule
