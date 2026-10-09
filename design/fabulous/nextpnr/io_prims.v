// Harness pad primitive (ADR-0005). Name/ports as the nextpnr fabulous uarch
// expects an IO BEL; the BEL itself exists only in the harness model made by
// flow/nextpnr_io_overlay.py, not in the FABulous tile description.
(* blackbox *)
module IO_1_bidirectional_frame_config_pass (
    input I, input T, output O, output Q, inout PAD
);
endmodule
