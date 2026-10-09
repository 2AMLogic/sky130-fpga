// tb_logic_tile_routed.v
//
// Self-checking testbench for design/rtl/logic_tile_routed.v (4 BELs +
// generated switch matrix, flat 158-bit config). RTL-level only: no timing.
//
// Cases (config bit positions per design/README.md and the generated matrix
// header comments):
//   1. track -> LUT input routing: every (BEL, pin, edge) combination,
//      pass-through LUT, observed on BEL outputs routed to N tracks. Each
//      BEL reads a different edge and every edge carries a distinct value,
//      so BELs are distinguishable from each other.
//   2. registered path: track -> LUT -> FF (EN and SR from tracks) -> track.
//   3. track-driver muxes: all 16 output tracks x all 8 select codes
//      (4 BEL outputs, 3 other-edge tracks, unused code 7 -> 0), under two
//      BEL-output patterns that give every BEL a unique signature.

`default_nettype none
`timescale 1ns/1ps

module tb_logic_tile_routed;

    reg          clk = 0;
    reg  [157:0] cfg = 158'd0;
    reg  [3:0]   tin [0:3];       // 0=N 1=E 2=S 3=W
    wire [3:0]   tout [0:3];
    wire [3:0]   n_out, e_out, s_out, w_out;
    assign tout[0] = n_out;
    assign tout[1] = e_out;
    assign tout[2] = s_out;
    assign tout[3] = w_out;

    integer errors = 0;
    integer checks = 0;

    logic_tile_routed dut (
        .clk(clk), .cfg(cfg),
        .n_in(tin[0]), .e_in(tin[1]), .s_in(tin[2]), .w_in(tin[3]),
        .n_out(n_out), .e_out(e_out), .s_out(s_out), .w_out(w_out)
    );

    always #5 clk = ~clk;

    task check(input [255:0] what, input got, input exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL: %0s got=%b exp=%b (t=%0t)", what, got, exp, $time);
            end
        end
    endtask

    // --- config builders -------------------------------------------------
    task set_lut(input integer n, input [15:0] init, input rs);
        begin
            cfg[17*n +: 16] = init;
            cfg[17*n + 16]  = rs;
        end
    endtask
    // LUT input pin k of BEL n selects edge d (0..3 = N,E,S,W)
    task set_lutin(input integer n, input integer k, input integer d);
        begin cfg[68 + 48 + 2*(4*n+k) +: 2] = d[1:0]; end
    endtask
    // output track (edge d, index t) select code
    task set_trk(input integer d, input integer t, input integer code);
        begin cfg[68 + 3*(4*d+t) +: 3] = code[2:0]; end
    endtask
    task set_en(input integer n, input integer d);
        begin cfg[68 + 82 + 2*n +: 2] = d[1:0]; end
    endtask
    task set_sr(input integer d);
        begin cfg[68 + 80 +: 2] = d[1:0]; end
    endtask

    // expected source for output track (d,t) with code, given BEL outputs
    function exp_trk(input integer d, input integer t, input integer code,
                     input [3:0] bel);
        integer j, dd, found;
        begin
            if (code >= 3 && code < 7) exp_trk = bel[code - 3];
            else if (code == 7) exp_trk = 1'b0;
            else begin
                found = 0; exp_trk = 1'b0;
                for (dd = 0; dd < 4; dd = dd + 1) begin
                    if (dd != d) begin
                        if (found == code) exp_trk = tin[dd][t];
                        found = found + 1;
                    end
                end
            end
        end
    endfunction

    integer n, k, d, t, code, pol, i, v, pb;
    reg [15:0] mask;
    reg [3:0] bel;
    reg [3:0] pat;

    initial begin
        for (i = 0; i < 4; i = i + 1) tin[i] = 4'h0;

        // ---- 1. track -> LUT input routing ------------------------------
        // BEL n's pins all select edge (d+n)%4, so the four BELs read four
        // different edges. Bit k is driven with a one-hot / one-cold pattern
        // across the edges (every edge distinct from every other), and the
        // other bits of each edge carry the complement, so a wrong BEL, edge
        // or pin index flips at least one observed BEL output.
        for (d = 0; d < 4; d = d + 1)
            for (k = 0; k < 4; k = k + 1) begin
                cfg = 158'd0;
                for (i = 0; i < 16; i = i + 1) mask[i] = i[k];
                for (n = 0; n < 4; n = n + 1) begin
                    set_lut(n, mask, 1'b0);
                    for (i = 0; i < 4; i = i + 1) set_lutin(n, i, (d + n) % 4);
                    set_trk(0, n, 3 + n);   // N1BEG<n> <- BEL n output
                end
                for (v = 0; v < 8; v = v + 1) begin
                    // pat[e] = value of bit k on edge e
                    pat = (v < 4) ? (4'b0001 << v) : ~(4'b0001 << (v - 4));
                    for (i = 0; i < 4; i = i + 1) begin
                        tin[i] = pat[i] ? 4'b0000 : 4'b1111;
                        tin[i][k] = pat[i];
                    end
                    #1;
                    // LUT input pin k of BEL n reads <(d+n)%4>1END<k>
                    for (n = 0; n < 4; n = n + 1)
                        check("route track->LUT->N out", n_out[n], pat[(d + n) % 4]);
                end
            end

        // ---- 2. registered path with EN/SR from tracks ------------------
        cfg = 158'd0;
        for (n = 0; n < 4; n = n + 1) begin
            set_lut(n, 16'hAAAA, 1'b1);  // out = in0, registered
            set_lutin(n, 0, 0);          // pin0 <- N1END0
            set_en(n, 1);                // EN_n <- E1END<n>
            set_trk(3, n, 3 + n);            // W1BEG<n> <- BEL n output
        end
        set_sr(2);                       // SR <- S1END0
        tin[0] = 4'b0000; tin[1] = 4'b1111; tin[2] = 4'b0000; tin[3] = 4'b0000;
        #1;
        tin[2][0] = 1'b1;                // reset all
        @(posedge clk); #1;
        for (n = 0; n < 4; n = n + 1) check("reset clears FF", w_out[n], 1'b0);
        tin[2][0] = 1'b0;
        tin[0][0] = 1'b1;                // data 1, all EN
        @(posedge clk); #1;
        for (n = 0; n < 4; n = n + 1) check("capture 1 (EN=1)", w_out[n], 1'b1);
        tin[0][0] = 1'b0;                // data 0, only BEL1 gated off
        tin[1][1] = 1'b0;
        @(posedge clk); #1;
        check("EN=0 holds BEL1", w_out[1], 1'b1);
        for (n = 0; n < 4; n = n + 1)
            if (n != 1) check("EN=1 captures 0", w_out[n], 1'b0);
        tin[2][0] = 1'b1;                // SR with EN still low for BEL1
        @(posedge clk); #1;
        for (n = 0; n < 4; n = n + 1) check("SR priority over EN", w_out[n], 1'b0);
        // SR/EN source selection: move SR to W1END0, EN0 to N1END1
        tin[2][0] = 1'b0;
        set_sr(3); set_en(0, 0);
        tin[0] = 4'b0010; tin[1] = 4'b1110; tin[3] = 4'b0001;
        @(posedge clk); #1;
        for (n = 0; n < 4; n = n + 1) check("SR from W track resets", w_out[n], 1'b0);
        tin[3][0] = 1'b0; tin[0][0] = 1'b1;  // data=1, EN0 from N1END0 -> 1
        tin[0][1] = 1'b0;
        @(posedge clk); #1;
        check("EN0 from N track", w_out[0], 1'b1);
        // combinational select bypasses FF
        set_lut(0, 16'hAAAA, 1'b0);
        tin[0][0] = 1'b0; #1;
        check("reg_sel=0 combinational", w_out[0], 1'b0);

        // ---- 3. track-driver mux: all tracks x all codes ----------------
        // Run under two BEL-output patterns (0101, 0011) so that every BEL
        // has a unique signature across the pair (A=11 B=01 C=10 D=00 for
        // pattern bits [0101,0011]); a BEL-index swap on the outputs or on
        // the truth-table slices is then visible.
        for (pb = 0; pb < 2; pb = pb + 1) begin
            cfg = 158'd0;
            bel = pb ? 4'b0011 : 4'b0101;  // bel[n] = BEL n output (n=0 is A)
            for (n = 0; n < 4; n = n + 1)
                set_lut(n, bel[n] ? 16'hFFFF : 16'h0000, 1'b0);
            for (code = 0; code < 8; code = code + 1)
                for (pol = 0; pol < 2; pol = pol + 1) begin
                    for (d = 0; d < 4; d = d + 1)
                        for (t = 0; t < 4; t = t + 1) set_trk(d, t, code);
                    for (i = 0; i < 4; i = i + 1)
                        tin[i] = pol ? 4'b1001 ^ (4'b0001 << i) : 4'b0110 ^ (4'b0001 << i);
                    #1;
                    for (d = 0; d < 4; d = d + 1)
                        for (t = 0; t < 4; t = t + 1)
                            check("track mux", tout[d][t], exp_trk(d, t, code, bel));
                end
        end

        if (errors == 0)
            $display("PASS: tb_logic_tile_routed (%0d checks, 0 failures)", checks);
        else
            $display("FAIL: tb_logic_tile_routed (%0d checks, %0d failures)", checks, errors);
        $finish;
    end

endmodule

`default_nettype wire
