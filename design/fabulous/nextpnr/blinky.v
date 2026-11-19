// Issue #324 blinky acceptance design (experimental single-LOGIC4 harness):
//   q <= rst ? 0 : (en ? ~q : q)       synchronous, reset over enable
// With en held high after reset, the flop toggles on every rising edge, so the
// output pad q completes one full blink period per two input clocks. Same
// registered BEL mapping as top_reg.v (flow/nextpnr.sh / flow/blinky.sh):
// yosys maps the flop onto a LOGIC4 BEL with FF=1 (ff_map.v, pass-through
// INIT, EN/SR as real routed nets) and the inverter onto a combinational
// LOGIC4 BEL, so the feedback net (Q -> ~ -> D) crosses the switch matrix and
// must route together with the output pad. `clk` is the BEL's implicit
// UserCLK (no fabric pin): a runtime *harness* input, stripped from the
// nextpnr JSON by flow/blinky.sh (see sim/README.md).
module top (input clk, input en, input rst, output q);
    reg r;
    always @(posedge clk)
        if (rst) r <= 1'b0;
        else if (en) r <= ~r;
    assign q = r;
endmodule
