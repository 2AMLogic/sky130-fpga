// Differential check (issue #136): FABulous-generated LOGIC4_ConfigMem.v
// (frame-storage latches, scratch only) vs the recorded configuration map
// sim/bitstream/logic4_configmem.map ("<ConfigBits index> <frame*32+bit>").
//
// SCOPE: frame STORAGE only -- FrameData/FrameStrobe -> ConfigBits.  This does
// not verify any hardware serial receiver / stream controller (none exists).
// The generated config_latch (Fabric/models_pack.v) is the unmodified model.
//
// Issue #195: a transparent-open phase holds one-hot FrameStrobe high while FrameData
// changes, so edge-triggered storage cannot pass.
//
// Output contract (flow/gate_sim_verdict.sh gs_classify_configmem, issue #196):
// setup/input problems print "ERROR: configmem_fabulous_equiv setup: ..." and finish
// with NO terminal summary; per-check mismatches print "FAIL <what>: ..." (no colon
// directly after FAIL); exactly one terminal summary ends a completed run:
// "PASS: configmem_fabulous_equiv -- N checks, S baseline streams, 0 failures; transparent-open: ..."
// or "FAIL: configmem_fabulous_equiv -- M failures / N checks (T transparent-open failures / C checks)".
//
// Plusargs: +map=<file> +vec=<baseline vector file from flow/configmem_frames.py>
`timescale 1ns/1ps
module tb;
    localparam NB = 158, NF = 20, FB = 32;
    reg  [FB-1:0] FrameData;
    reg  [NF-1:0] FrameStrobe;
    wire [NB-1:0] CB, CBN;
    LOGIC4_ConfigMem dut (.FrameData(FrameData), .FrameStrobe(FrameStrobe),
                          .ConfigBits(CB), .ConfigBits_N(CBN));

    integer pos2cb [0:NF*FB-1];
    reg [NB-1:0] exp;
    integer checks = 0, fails = 0;
    // transparent-open phase (issue #195): failures counted separately so the runner
    // can require edge-storage mutants to be caught by this phase specifically
    integer tphase = 0, tfails = 0, tchecks = 0, tframes = 0, tbits = 0, topen = 0;
    reg [NB-1:0] tprev;      // previous settled value, to detect a real change
    reg [NB-1:0] tmoved;     // bit changed value while its strobe stayed asserted
    integer fh, r, a, b, i, f, k, n;
    reg [1023:0] mapf, vecf;
    reg [FB-1:0] d, dv;
    reg [159:0] want;   // 40 hex digits
    reg [8*40-1:0] name;
    reg [7:0] tag;

    task check(input [127:0] what);
        begin
            checks = checks + 1;
            if (tphase) tchecks = tchecks + 1;
            if (CB !== exp || CBN !== ~exp) begin
                fails = fails + 1;
                if (tphase) tfails = tfails + 1;
                if (fails < 10)
                    $display("FAIL %0s: ConfigBits %h expected %h (N ok=%b)", what, CB, exp, (CBN === ~exp));
            end
        end
    endtask

    // Legal frame write: data on FrameData, one-hot strobe, release strobe,
    // then scramble FrameData (storage must hold) before the caller checks.
    task write(input integer fr, input [FB-1:0] data);
        integer q;
        begin
            FrameData = data; #1;
            FrameStrobe = {NF{1'b0}}; FrameStrobe[fr] = 1'b1; #1;
            FrameStrobe = {NF{1'b0}}; #1;
            for (q = 0; q < FB; q = q + 1)
                if (pos2cb[fr*FB+q] >= 0) exp[pos2cb[fr*FB+q]] = data[q];
            FrameData = ~data ^ 32'h5a5a_a5a5; #1;
        end
    endtask

    // Transparent-open step: with the strobe of frame fr already high, drive new
    // FrameData, let it settle, and require ConfigBits/ConfigBits_N to follow it at
    // once (level-sensitive latch) while every other frame keeps its state.
    task topen_step(input integer fr, input [FB-1:0] data, input [127:0] what);
        integer q;
        begin
            FrameData = data; #1;
            for (q = 0; q < FB; q = q + 1)
                if (pos2cb[fr*FB+q] >= 0) exp[pos2cb[fr*FB+q]] = data[q];
            topen = topen + 1;
            check(what);
            for (q = 0; q < FB; q = q + 1)
                if (pos2cb[fr*FB+q] >= 0 && CB[pos2cb[fr*FB+q]] !== tprev[pos2cb[fr*FB+q]]
                    && CB[pos2cb[fr*FB+q]] === data[q]) tmoved[pos2cb[fr*FB+q]] = 1'b1;
            tprev = exp;
        end
    endtask

    // Per populated frame: strobe held high across many FrameData changes, then
    // release and prove retention while FrameData keeps changing.
    task transparent_frame(input integer fr);
        integer j;
        begin
            write(fr, 32'h0); check("topen-prep");
            FrameData = 32'h0f0f_3c3c; #1;
            FrameStrobe = {NF{1'b0}}; FrameStrobe[fr] = 1'b1; #1;   // strobe rises, data already present
            for (j = 0; j < FB; j = j + 1)
                if (pos2cb[fr*FB+j] >= 0) exp[pos2cb[fr*FB+j]] = FrameData[j];
            check("topen-rise");
            tprev = exp;
            topen_step(fr, 32'hffff_ffff, "topen-ones");
            topen_step(fr, 32'h0000_0000, "topen-zeros");
            topen_step(fr, 32'haaaa_aaaa, "topen-a");
            topen_step(fr, 32'h5555_5555, "topen-5");
            topen_step(fr, 32'hffff_ffff, "topen-ones2");
            for (j = 0; j < FB; j = j + 1) begin      // walking one, strobe still high
                topen_step(fr, 32'h1 << j, "topen-walk1");
                topen_step(fr, ~(32'h1 << j), "topen-walk0");
            end
            for (j = 0; j < 8; j = j + 1) topen_step(fr, $random, "topen-rand");
            FrameStrobe = {NF{1'b0}}; #1;              // release: last value is held
            check("topen-release");
            for (j = 0; j < 6; j = j + 1) begin
                FrameData = (j == 0) ? ~FrameData : $random; #1; check("topen-retain");
            end
        end
    endtask

    // Compare final ConfigBits against the recorded baseline vector.
    task check_final;
        begin
            checks = checks + 1;
            if (CB !== want[NB-1:0]) begin
                fails = fails + 1;
                $display("FAIL baseline %0s: ConfigBits %h recorded %h", name, CB, want[NB-1:0]);
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("map=%s", mapf) || !$value$plusargs("vec=%s", vecf)) begin
            $display("ERROR: configmem_fabulous_equiv setup: need +map= and +vec="); $finish;
        end
        for (i = 0; i < NF*FB; i = i + 1) pos2cb[i] = -1;
        fh = $fopen(mapf, "r");
        if (fh == 0) begin
            $display("ERROR: configmem_fabulous_equiv setup: cannot open map file %0s", mapf); $finish; end
        n = 0;
        while ($fscanf(fh, "%d %d\n", a, b) == 2) begin
            if (a < 0 || a >= NB || b < 0 || b >= NF*FB || pos2cb[b] >= 0) begin
                $display("ERROR: configmem_fabulous_equiv setup: bad map entry %0d %0d", a, b); $finish; end
            pos2cb[b] = a; n = n + 1;
        end
        $fclose(fh);
        if (n != NB) begin $display("ERROR: configmem_fabulous_equiv setup: map has %0d entries", n); $finish; end

        FrameData = 0; FrameStrobe = 0; exp = {NB{1'b0}};
        // Initial fill: zero every frame so all storage is defined.
        for (f = 0; f < NF; f = f + 1) write(f, 32'h0);
        check("init");

        // Walking one on every frame bit (mapped and unmapped), each preceded by
        // an all-ones write so a stale bit would show; other frames retained.
        for (f = 0; f < NF; f = f + 1)
            for (k = 0; k < FB; k = k + 1) begin
                write(f, 32'hffff_ffff); check("ones");
                write(f, 32'h1 << k);    check("walk1");
            end
        // Walking zero.
        for (f = 0; f < NF; f = f + 1)
            for (k = 0; k < FB; k = k + 1) begin
                write(f, 32'hffff_ffff); write(f, ~(32'h1 << k)); check("walk0");
            end
        // Alternating patterns with retention across frames: load all frames with
        // pattern P, then rewrite single frames with ~P and require the rest hold.
        for (k = 0; k < 4; k = k + 1) begin
            d = (k == 0) ? 32'haaaa_aaaa : (k == 1) ? 32'h5555_5555 :
                (k == 2) ? 32'hf0f0_f0f0 : 32'h0ff0_0ff0;
            for (f = 0; f < NF; f = f + 1) write(f, d);
            check("pattern-all");
            for (f = 0; f < NF; f = f + 1) begin
                write(f, ~d); check("pattern-inv"); write(f, d); check("pattern-restore");
            end
        end
        // Repeated writes clearing previously set bits.
        for (f = 0; f < NF; f = f + 1) begin
            write(f, 32'hffff_ffff); check("set");
            write(f, 32'h0000_0000); check("clear");
            write(f, 32'h8000_0001); write(f, 32'h0000_0001); check("clear-msb");
            write(f, 32'h0000_0000); check("clear2");
        end
        // Unused frame positions (frames 5..19, frame4 bits 30-31): ones written
        // there must not disturb mapped state.
        write(0, 32'hffff_ffff); write(1, 32'h1234_5678); write(4, 32'h3fff_ffff);
        check("unused-setup");
        for (f = 5; f < NF; f = f + 1) begin write(f, 32'hffff_ffff); check("unused-ones"); end
        write(4, 32'hffff_ffff); check("unused-frame4-hi");
        for (f = 5; f < NF; f = f + 1) begin write(f, 32'h0); check("unused-zero"); end
        // Data changes with no strobe leave storage alone.
        for (i = 0; i < 64; i = i + 1) begin FrameData = $random; #1; check("nostrobe"); end
        // Transparent-open phase (issue #195): level-sensitive behavior while strobe stays high.
        tphase = 1; tmoved = {NB{1'b0}};
        for (f = 0; f < NF; f = f + 1) begin
            k = 0;
            for (i = 0; i < FB; i = i + 1) if (pos2cb[f*FB+i] >= 0) k = k + 1;
            if (k > 0) begin tframes = tframes + 1; transparent_frame(f); end
        end
        tphase = 0;
        tbits = 0;
        for (i = 0; i < NB; i = i + 1) if (tmoved[i]) tbits = tbits + 1;
        if (tbits != NB || tframes < 1) begin
            fails = fails + 1; tfails = tfails + 1;
            $display("FAIL transparent-open-coverage: %0d/%0d mapped bits, %0d frames", tbits, NB, tframes);
        end
        // Randomized frame-write sequences against the map model.
        for (i = 0; i < 5000; i = i + 1) begin write($unsigned($random) % NF, $random); check("random"); end

        // Baseline streams: replay frame payloads in stream order; final ConfigBits
        // must equal the recorded .cfg vector.
        fh = $fopen(vecf, "r");
        if (fh == 0) begin
            $display("ERROR: configmem_fabulous_equiv setup: cannot open vector file %0s", vecf); $finish; end
        n = 0;
        while (!$feof(fh)) begin
            r = $fscanf(fh, " %c", tag);
            if (r == 1 && tag == "S") begin
                if (n > 0) check_final;
                r = $fscanf(fh, " %h %s\n", want, name);
                n = n + 1;
            end else if (r == 1 && tag == "F") begin
                r = $fscanf(fh, " %d %h\n", f, dv);
                write(f, dv);
            end
        end
        if (n > 0) check_final;
        $fclose(fh);
        // Fewer than 2 streams means a missing/empty/truncated vector file or a
        // broken adapter -- an input problem, never a storage mismatch: setup
        // ERROR and no terminal summary, so it can never count as a kill (#196).
        if (n < 2) begin
            $display("ERROR: configmem_fabulous_equiv setup: only %0d baseline streams in vector file %0s", n, vecf);
            $finish;
        end
        if (fails == 0) $display("PASS: configmem_fabulous_equiv -- %0d checks, %0d baseline streams, 0 failures; transparent-open: %0d frames, %0d/%0d mapped bits changed under asserted strobe, %0d settled changes, %0d checks, 0 failures", checks, n, tframes, tbits, NB, topen, tchecks);
        else $display("FAIL: configmem_fabulous_equiv -- %0d failures / %0d checks (%0d transparent-open failures / %0d checks)", fails, checks, tfails, tchecks);
        $finish;
    end
endmodule
