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
//
// Input grammar (issue #200). Both files are validated in full BEFORE any check
// runs; any violation is a setup ERROR (no terminal summary), never a mismatch.
// These restrictions belong to this simulation transaction format only (they
// are what flow/configmem_frames.py and sim/bitstream/logic4_configmem.map
// emit), not to any hardware stream format:
//   * line-oriented, '\n'-terminated (the last line may omit it); fields are
//     separated by exactly one space; no blank lines, no leading/trailing
//     spaces, no tabs/CR/control characters; a line is at most LMAX-1 bytes.
//   * map: exactly NB lines "<ConfigBits index> <frame*32+bit>", both plain
//     decimal; a bijection -- every ConfigBits index 0..NB-1 exactly once and
//     every frame position (< NF*FB) at most once; nothing after the last row.
//   * vectors: one or more streams, at least 2 in total; each stream is
//       S <40 hex digits, bits >= NB zero> <name>
//     followed by exactly NF records "F <frame 0..NF-1 decimal> <8 hex digits>"
//     that cover every frame exactly once (any order; the adapter's stream
//     order is replayed as-is). No F before the first S, no other tags, no
//     extra fields, no incomplete stream at an S or at EOF.
`timescale 1ns/1ps
module tb;
    localparam NB = 158, NF = 20, FB = 32;
    localparam LMAX = 256, MAXT = 4, NAMEMAX = 128;
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
    integer fh, a, b, i, f, k, n;
    reg [1023:0] mapf, vecf;
    reg [FB-1:0] d;
    reg [159:0] want;   // 40 hex digits
    reg [8*NAMEMAX-1:0] name;

    // ---- strict line reader / tokenizer (issue #200) ----
    reg [8*LMAX-1:0] lbuf;      // $fgets result, right-justified (last char in low byte)
    integer llen, lineno, ntok, ok, ln_ok;
    integer tst [0:MAXT-1];     // token start offset within the line
    integer tln [0:MAXT-1];     // token length
    reg [8*64-1:0] why;
    reg [159:0] hv;
    integer dv_i;
    reg [NB-1:0] cbseen;
    reg [NF-1:0] fseen;
    integer nfr_in;

    function [7:0] lc(input integer idx);   // idx-th character of the current line
        lc = lbuf[8*(llen-1-idx) +: 8];
    endfunction
    function [7:0] tc(input integer t, input integer j);   // j-th char of token t
        tc = lc(tst[t] + j);
    endfunction

    // Split the current line into single-space-separated, non-empty, printable
    // tokens. ln_ok = 0 (and why set) on any violation.
    task tokenize;
        integer p, e, s;
        reg [7:0] ch;
        begin
            ln_ok = 1; ntok = 0; s = 0; e = llen;
            if (e > 0 && lc(e-1) == 8'h0a) e = e - 1;
            else if (llen >= LMAX - 1) begin ln_ok = 0; why = "line too long"; end
            for (p = 0; ln_ok && p <= e; p = p + 1) begin
                ch = (p < e) ? lc(p) : 8'h20;
                if (ch == 8'h20) begin
                    if (p == s) begin ln_ok = 0; why = "blank line or bad field spacing"; end
                    else if (ntok >= MAXT) begin ln_ok = 0; why = "too many fields"; end
                    else begin tst[ntok] = s; tln[ntok] = p - s; ntok = ntok + 1; end
                    s = p + 1;
                end else if (ch < 8'h21 || ch > 8'h7e) begin
                    ln_ok = 0; why = "non-printable character";
                end
            end
        end
    endtask

    // Token t as a plain decimal (1..6 digits) -> dv_i; ok = 0 if not.
    task tok_dec(input integer t);
        integer j;
        reg [7:0] ch;
        begin
            ok = (tln[t] >= 1 && tln[t] <= 6); dv_i = 0;
            for (j = 0; ok && j < tln[t]; j = j + 1) begin
                ch = tc(t, j);
                if (ch >= "0" && ch <= "9") dv_i = dv_i * 10 + (ch - "0"); else ok = 0;
            end
        end
    endtask

    // Token t as exactly w hex digits -> hv; ok = 0 if not.
    task tok_hex(input integer t, input integer w);
        integer j;
        reg [7:0] ch;
        begin
            ok = (tln[t] == w); hv = 160'b0;
            for (j = 0; ok && j < tln[t]; j = j + 1) begin
                ch = tc(t, j);
                if (ch >= "0" && ch <= "9") hv = (hv << 4) | (ch - "0");
                else if (ch >= "a" && ch <= "f") hv = (hv << 4) | (ch - "a" + 10);
                else if (ch >= "A" && ch <= "F") hv = (hv << 4) | (ch - "A" + 10);
                else ok = 0;
            end
        end
    endtask

    // Read the next line into lbuf; returns llen = 0 at clean EOF.
    task next_line(input integer h, input [8*8-1:0] what, input [1023:0] fname);
        begin
            lbuf = 0;
            llen = $fgets(lbuf, h);
            if (llen == 0 && !$feof(h)) begin
                $display("ERROR: configmem_fabulous_equiv setup: read error in %0s file %0s", what, fname); $finish;
            end
            if (llen > 0) lineno = lineno + 1;
        end
    endtask

    task in_error(input [8*8-1:0] what, input [1023:0] fname, input [8*64-1:0] msg);
        begin
            $display("ERROR: configmem_fabulous_equiv setup: %0s file %0s line %0d: %0s", what, fname, lineno, msg);
            $finish;
        end
    endtask

    // Parse the vector file. replay = 0: validate only (no DUT activity);
    // replay = 1: also write each frame and check each completed stream.
    task vec_pass(input integer replay);
        integer j;
        begin
            fh = $fopen(vecf, "r");
            if (fh == 0) begin
                $display("ERROR: configmem_fabulous_equiv setup: cannot open vector file %0s", vecf); $finish; end
            n = 0; nfr_in = 0; fseen = {NF{1'b0}}; lineno = 0;
            next_line(fh, "vector", vecf);
            while (llen > 0) begin
                tokenize;
                if (!ln_ok) in_error("vector", vecf, why);
                if (tln[0] != 1 || (tc(0, 0) != "S" && tc(0, 0) != "F"))
                    in_error("vector", vecf, "unknown record tag (want S or F)");
                if (ntok != 3) in_error("vector", vecf, "wrong field count (want 3)");
                if (tc(0, 0) == "S") begin
                    if (n > 0 && nfr_in != NF) begin
                        $display("ERROR: configmem_fabulous_equiv setup: vector file %0s line %0d: stream %0s incomplete: %0d of %0d frames before next S", vecf, lineno, name, nfr_in, NF);
                        $finish;
                    end
                    if (replay && n > 0) check_final;
                    tok_hex(1, 40);
                    if (!ok) in_error("vector", vecf, "S: expected value is not 40 hex digits");
                    if (hv[159:NB] != 0) in_error("vector", vecf, "S: expected value has bits set beyond ConfigBits width");
                    if (tln[2] > NAMEMAX) in_error("vector", vecf, "S: stream name too long");
                    want = hv; name = 0;
                    for (j = 0; j < tln[2]; j = j + 1) name = (name << 8) | tc(2, j);
                    n = n + 1; nfr_in = 0; fseen = {NF{1'b0}};
                end else begin
                    if (n == 0) in_error("vector", vecf, "F record before any S record");
                    tok_dec(1);
                    if (!ok) in_error("vector", vecf, "F: frame index is not a decimal number");
                    if (dv_i >= NF) in_error("vector", vecf, "F: frame index out of range");
                    f = dv_i;
                    tok_hex(2, 8);
                    if (!ok) in_error("vector", vecf, "F: frame data is not 8 hex digits");
                    if (fseen[f]) in_error("vector", vecf, "F: duplicate frame in stream");
                    fseen[f] = 1'b1; nfr_in = nfr_in + 1;
                    if (replay) write(f, hv[FB-1:0]);
                end
                next_line(fh, "vector", vecf);
            end
            $fclose(fh);
            if (n > 0 && nfr_in != NF) begin
                $display("ERROR: configmem_fabulous_equiv setup: vector file %0s: last stream %0s incomplete at EOF: %0d of %0d frames", vecf, name, nfr_in, NF);
                $finish;
            end
            // Fewer than 2 streams means a missing/empty/truncated vector file or a
            // broken adapter -- an input problem, never a storage mismatch: setup
            // ERROR and no terminal summary, so it can never count as a kill (#196).
            if (n < 2) begin
                $display("ERROR: configmem_fabulous_equiv setup: only %0d baseline streams in vector file %0s", n, vecf);
                $finish;
            end
            if (replay) check_final;
        end
    endtask

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
        // Map (issue #200): every line must be a well-formed row; the rows must
        // form a bijection onto ConfigBits 0..NB-1 with unique frame positions.
        n = 0; lineno = 0; cbseen = {NB{1'b0}};
        next_line(fh, "map", mapf);
        while (llen > 0) begin
            tokenize;
            if (!ln_ok) in_error("map", mapf, why);
            if (ntok != 2) in_error("map", mapf, "wrong field count (want 2)");
            tok_dec(0); a = dv_i;
            if (!ok) in_error("map", mapf, "ConfigBits index is not a decimal number");
            tok_dec(1); b = dv_i;
            if (!ok) in_error("map", mapf, "frame position is not a decimal number");
            if (a >= NB || b >= NF*FB) begin
                $display("ERROR: configmem_fabulous_equiv setup: bad map entry %0d %0d (map file %0s line %0d: out of range)", a, b, mapf, lineno); $finish; end
            if (cbseen[a]) begin
                $display("ERROR: configmem_fabulous_equiv setup: bad map entry %0d %0d (map file %0s line %0d: duplicate ConfigBits index)", a, b, mapf, lineno); $finish; end
            if (pos2cb[b] >= 0) begin
                $display("ERROR: configmem_fabulous_equiv setup: bad map entry %0d %0d (map file %0s line %0d: duplicate frame position)", a, b, mapf, lineno); $finish; end
            cbseen[a] = 1'b1; pos2cb[b] = a; n = n + 1;
            next_line(fh, "map", mapf);
        end
        $fclose(fh);
        if (n != NB) begin $display("ERROR: configmem_fabulous_equiv setup: map has %0d entries", n); $finish; end
        for (i = 0; i < NB; i = i + 1)   // implied by n == NB with no duplicates; kept explicit
            if (!cbseen[i]) begin
                $display("ERROR: configmem_fabulous_equiv setup: map file %0s has no row for ConfigBits index %0d", mapf, i); $finish; end

        // Vector file (issue #200): validate the whole transaction file before any
        // check runs, so malformed input can never follow (or produce) mismatches.
        vec_pass(0);

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
        // must equal the recorded .cfg vector. The file was fully validated above;
        // the replay pass re-applies the same grammar checks.
        vec_pass(1);
        if (fails == 0) $display("PASS: configmem_fabulous_equiv -- %0d checks, %0d baseline streams, 0 failures; transparent-open: %0d frames, %0d/%0d mapped bits changed under asserted strobe, %0d settled changes, %0d checks, 0 failures", checks, n, tframes, tbits, NB, topen, tchecks);
        else $display("FAIL: configmem_fabulous_equiv -- %0d failures / %0d checks (%0d transparent-open failures / %0d checks)", fails, checks, tfails, tchecks);
        $finish;
    end
endmodule
