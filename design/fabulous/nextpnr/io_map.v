// -extra-map for synth_fabulous: map the iopadmap pad cells onto the harness
// pad BEL. T/Q are left unconnected on purpose: tying T would create a
// $PACKER_VCC/GND sink the fabric cannot drive (ADR-0005).
module \$__FABULOUS_IBUF (input PAD, output OUT);
    IO_1_bidirectional_frame_config_pass _io (.PAD(PAD), .O(OUT));
endmodule
module \$__FABULOUS_OBUF (output PAD, input IN);
    IO_1_bidirectional_frame_config_pass _io (.PAD(PAD), .I(IN));
endmodule
