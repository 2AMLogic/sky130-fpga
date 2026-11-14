<!-- record-meta
{
  "record_id": "20261114-sdf-port-interconnect-564db73",
  "experiment": "sdf-port-interconnect",
  "git_revision": "564db73529522d7ae511394bcd2e2fe4f90a5077",
  "framework_gap": "G4",
  "harness": "sim/sdf_port_interconnect/run.sh",
  "provenance": {
    "iverilog_version": "13.0 (stable) (v13_0)",
    "pdk": {
      "name": "sky130A",
      "version": "open_pdks c6d73a35f524070e85faff4a6a9eef49553ebc2b"
    },
    "inputs": [
      {
        "path": "sim/sdf_port_interconnect/port_interconnect_dut.v",
        "role": "the fixture netlist under test",
        "content_hash": "sha256:c9aafa360f8dbfd69b653b31293749874bca289bc7a9f69ab138681b831568c3"
      },
      {
        "path": "sim/sdf_port_interconnect/tb_port_interconnect_noop.v",
        "role": "no-stimulus testbench, AC 5 pair half 1",
        "content_hash": "sha256:1e02d7efbfb4d5309c50a29caa77e98f9a7ef4e8c4b002f465572a30a8a31f5a"
      },
      {
        "path": "sim/sdf_port_interconnect/tb_port_interconnect_drive.v",
        "role": "driving testbench and delay probe, AC 5 pair half 2",
        "content_hash": "sha256:b0d268af8c91c69238531af8b2c4efb9a927aaf8f793f04e9cb0a5b25eff983b"
      },
      {
        "path": "sim/sdf_port_interconnect/run.sh",
        "role": "the harness; asserts every verdict below",
        "content_hash": "sha256:06c0653058545daa01ed7d31757509cdebd9d453d9e10cccabc04b07416fa789"
      },
      {
        "path": "sim/sdf_port_interconnect/classify_sdf_log.py",
        "role": "per-entry verdict parser",
        "content_hash": "sha256:01c94d818b43c0b178077b359fa99861a3fe75da94590dcb0b68105c36913ba5"
      },
      {
        "path": "sim/sdf_port_interconnect/predict_fanout_rejections.py",
        "role": "applies the model to a real SDF (Result 7)",
        "content_hash": "sha256:c580b7cf3e341d24f43633f8ee791e07752e0fbf200e2103bb78385bd556e22a"
      },
      {
        "path": "sim/sdf_port_interconnect/fanout4_bitsel_first.sdf",
        "role": "case SDF",
        "content_hash": "sha256:490f3b681414a39d8d5731f7242e1ac087932cdf05ae8296fdc5a66e37d7000b"
      },
      {
        "path": "sim/sdf_port_interconnect/fanout4_bitsel_last.sdf",
        "role": "case SDF",
        "content_hash": "sha256:a16f691c832f69074eb46b3ae5554199c71217afa5e308d67b7545ffce087df9"
      },
      {
        "path": "sim/sdf_port_interconnect/fanout4_bitsel_all.sdf",
        "role": "case SDF",
        "content_hash": "sha256:b0f89892e27afa86352e92ac6c98b9122daff8df369c1cea0abb4f6284e859bb"
      },
      {
        "path": "sim/sdf_port_interconnect/fanout2_bitsel_first.sdf",
        "role": "case SDF",
        "content_hash": "sha256:84ecb5d8f951490cfa0939474d5f65d0df9e6fff286f73586a9283c48c1c1499"
      },
      {
        "path": "sim/sdf_port_interconnect/fanout2_bitsel_all.sdf",
        "role": "case SDF",
        "content_hash": "sha256:376869df249a46cb3481fb2bcc45cf3b78f3b2a7880be8690e5d26abeb319a8c"
      },
      {
        "path": "sim/sdf_port_interconnect/fanout1_bitsel.sdf",
        "role": "case SDF, the discriminator",
        "content_hash": "sha256:bcd06a381c8f6ab035b916b44808d1eacca0768858f599811e4cf52b1a7e0594"
      },
      {
        "path": "sim/sdf_port_interconnect/fanout1_bitsel_mux4_1.sdf",
        "role": "case SDF",
        "content_hash": "sha256:19b644e315a9728292e32335d50c95ba0236778979076cccd574c784733900df"
      },
      {
        "path": "sim/sdf_port_interconnect/fanout2_bitsel_nospecify.sdf",
        "role": "case SDF, specify-free destination control",
        "content_hash": "sha256:86481075e5e613fe6a049f14550bab003a920612810eaedf7690d0bebdaccd1b"
      },
      {
        "path": "sim/sdf_port_interconnect/fanout4_scalar_all.sdf",
        "role": "case SDF, scalar-port control",
        "content_hash": "sha256:b54abc2786403ffcb452406b2ca6086c1efc11117338d6c84a3cdd833cf361c1"
      },
      {
        "path": "sim/sdf_port_interconnect/fanout4_instpin_all.sdf",
        "role": "case SDF, instance-pin positive control",
        "content_hash": "sha256:d1e94093f53428b66cf61f4d03b5e0de3fa7771b207910ebf14c5741e41940f6"
      },
      {
        "path": "sim/sdf_port_interconnect/buffered_port_all.sdf",
        "role": "case SDF, the buffer remedy",
        "content_hash": "sha256:52a7bb77a6b8e785c6eeb512a0df854d7cf6aa9fe6138e84cfceda54e24ddd5d"
      },
      {
        "path": "sim/sdf_port_interconnect/iopath_with_interconnect.sdf",
        "role": "case SDF, IOPATH alongside INTERCONNECT",
        "content_hash": "sha256:989a29874c11627106310ecfa8e2ab8bff447908c93ef5d2fd692ef458ede9ec"
      },
      {
        "path": "sim/sdf_port_interconnect/committed_shape_miniature.sdf",
        "role": "case SDF, miniature of the committed SDF's affected population",
        "content_hash": "sha256:7a457ad8fcc2c3aa4d931a310137f3583f143c941cfb7ab46a561c34a3c98406"
      },
      {
        "path": "flow/sdf_annotate_shim.py",
        "role": "used UNMODIFIED to generate the second elaboration root",
        "content_hash": "sha256:1d6112433626e5073e67e505917c4b31f585071a0742458321516bbf008858b2"
      },
      {
        "path": "measurements/timing-characterization/logic_tile_route.sdf",
        "role": "the committed SDF the model is applied to in Result 7; read only, not regenerated",
        "content_hash": "sha256:6416961eb45815b1c8c83dc7dc439e235ab95a9a20c2404a7674ad64a0c8ac16"
      }
    ]
  }
}
-->

# Record 20261114-sdf-port-interconnect-564db73

- **Record ID**: 20261114-sdf-port-interconnect-564db73
- **Claim**: the cause of record `20261017-sdf-sanitize-d811bcd` Result 3's
  **28 of 179** rejected `INTERCONNECT` entries is isolated. It is the
  **fanout of the source net**, not the source's spelling: Icarus Verilog
  13.0's `$sdf_annotate` creates at most **one** interconnect modpath per
  *bit-selected top-level port* net, annotating the destination of the
  last-declared instance on that net and rejecting the other N-1.
- **Non-claim**: this does **not** cite T1 item 7 (#213), does not change
  `flow/sdf-resim.sh`, does not regenerate the SDF or any layout, and makes
  **no timing claim** about the tile. `environment.sdf.annotated: true` is
  still not truthful on the committed SDF -- see Result 8.
- **Relationship to other records**: **append-only, supersedes nothing.** It
  explains `20261017-sdf-sanitize-d811bcd`'s open question rather than
  replacing its measurements, and leaves that record untouched. It does not
  touch `20261008-233733-23e6b5e` (the active `sdf-resim` record, which
  pins `flow/sdf-resim.sh`; that script is unchanged here).
- **Toolchain** (2026-11-14, host tools untouched): Icarus Verilog
  `13.0 (stable) (v13_0)` and runtime `13.0 (stable) (v13_0)` from
  `~/.local/bin`; sky130A cell models at the pinned
  `open_pdks c6d73a35f524070e85faff4a6a9eef49553ebc2b`. No OpenROAD, no
  `klt`, no `yosys`, no place-and-route.
- **Harness**: `./sim/sdf_port_interconnect/run.sh` -- see
  [`sim/sdf_port_interconnect/README.md`](../../../sim/sdf_port_interconnect/README.md).

## Method

A hand-written gate-level fixture, annotated through exactly the path
`flow/sdf-resim.sh` leg 2 uses: `-g2012 -gspecify -ginterconnect -T typ`,
two elaboration roots (`-s <testbench> -s klt_sdf_annotate`), the shim
generated by `flow/sdf_annotate_shim.py` **unmodified**, and an absolute
SDF path. Instance names are plain and unescaped on purpose -- escaped
dividers are a separate, closed question (klayout-tools#2897) and the record
being explained states the rejections are "not a name problem".

Thirteen committed case SDFs each annotate one experiment on a net whose
source shape, fanout and destination kind are known by construction. Every
case is run twice, once under a testbench that drives nothing and finishes
at t=1, once under one that drives every input across 80 ns.

**Verdicts are not taken from `vvp`'s exit code**, which is 0 even when
every annotation was skipped. They are parsed from the transcript and
attributed to entries by SDF line number
(`sim/sdf_port_interconnect/classify_sdf_log.py`), and then corroborated
independently: each case delay is rescaled from 0.100 ns to 3.000 ns and the
driving testbench's per-edge timestamps are diffed against an un-annotated
baseline. "Applied" therefore means *an observed timing shift*, and
"rejected" means *a waveform bit-identical to the un-annotated run* -- not
merely a quiet or noisy transcript.

## Result 1: the verdict table

All verdicts below are identical under both testbenches, and the
"delay observed" column is the independent waveform corroboration.

| Case | source shape | fanout | entries | rejected | delay observed |
|---|---|---|---|---|---|
| `fanout4_bitsel_first` | bit-selected port `in[0]` -> `u_a0.S0` | 4 | 1 | **1** | no |
| `fanout4_bitsel_last` | bit-selected port `in[0]` -> `u_a3.S0` | 4 | 1 | 0 | yes |
| `fanout4_bitsel_all` | bit-selected port `in[0]`, all 4 | 4 | 4 | **3** | yes |
| `fanout2_bitsel_first` | bit-selected port `in[1]` -> `u_b0.S0` | 2 | 1 | **1** | no |
| `fanout2_bitsel_all` | bit-selected port `in[1]`, both | 2 | 2 | **1** | yes |
| `fanout1_bitsel` | bit-selected port `in[2]` -> `u_c0.S0` | **1** | 1 | 0 | yes |
| `fanout1_bitsel_mux4_1` | bit-selected port `in[4]` -> `u_m0.S1` (`mux4_1`) | **1** | 1 | 0 | yes |
| `fanout2_bitsel_nospecify` | bit-selected port `in[3]` -> `u_n0.A`, **no `specify`** | 2 | 1 | **1** | no |
| `fanout4_scalar_all` | **scalar** port `clk`, all 4 | 4 | 4 | 0 | yes |
| `fanout4_instpin_all` | instance pin `u_a3.X`, all 4 | 4 | 4 | 0 | yes |
| `buffered_port_all` | instance pin `u_buf.X`, both | 2 | 2 | 0 | yes |
| `iopath_with_interconnect` | `IOPATH` + fanout-1 `INTERCONNECT` | 1 | 2 | 0 | yes |
| `committed_shape_miniature` | 4x`in[0]` + 2x`in[1]` + 4x`clk` + 4x`u_a3.X` + 1x`in[2]` | mixed | 15 | **4** | yes |

The two rows that settle it are `fanout4_bitsel_first` versus
`fanout1_bitsel`: **same source spelling, same specify-bearing destination
pin, same cell, same flags -- only the net's fanout differs, and only the
fanout-4 one is rejected.**

## Result 2: the exact simulator messages

Verbatim from `sim/build/sdf_port_interconnect/fanout4_bitsel_all__tb_port_interconnect_drive.out`
(absolute SDF paths shortened to repo-relative; nothing else altered):

```
VPI error: Could not insert intermodpath!
VPI error: Could not insert intermodpath!
VPI error: Could not insert intermodpath!
SDF ERROR: sim/sdf_port_interconnect/fanout4_bitsel_all.sdf:9: Chosen value not defined.
SDF ERROR: sim/sdf_port_interconnect/fanout4_bitsel_all.sdf:11: Chosen value not defined.
SDF ERROR: sim/sdf_port_interconnect/fanout4_bitsel_all.sdf:18: Could not find intermodpath!
SDF ERROR: sim/sdf_port_interconnect/fanout4_bitsel_all.sdf:19: Could not find intermodpath!
SDF ERROR: sim/sdf_port_interconnect/fanout4_bitsel_all.sdf:20: Could not find intermodpath!
```

Lines 18/19/20 are the `u_a0`/`u_a1`/`u_a2` entries; line 21 (`u_a3`) draws
no message and is the one that applies. The `VPI error` lines carry no line
number and are the VPI-side half of the same three failures -- the parser
checks their count against the line-attributed rejections and reports a
disagreement rather than hiding it.

The two `Chosen value not defined.` messages at lines 9 and 11 are the
`(VOLTAGE 1.800::1.800)` and `(TEMPERATURE 25.000::25.000)` **header**
triples, which have no typ value for `-T typ` to choose. They appear on
every run including the all-applied ones, are not per-entry verdicts, and
are reported as notes. The committed `logic_tile_route.sdf` carries the same
`min::max` header form, so this is the same benign noise the real flow
produces -- and a concrete reason the verdict cannot be "did the transcript
mention SDF ERROR".

For comparison, `fanout4_scalar_all` (four entries on a **scalar** port net
at fanout 4) produces **only** those two header lines and no intermodpath
failure at all.

## Result 3: the surviving entry is netlist-ordered, not SDF-ordered

Reversing the four `in[0]` entries' order in the SDF file leaves the same
entry applied (`u_a3.S0`) and the same three rejected. Varying the
*netlist* declaration order instead moves the survivor: with the four
instances declared `u_f4d, u_f4a, u_f4b, u_f4c`, the single annotatable
destination becomes `u_f4c` -- the last declared. So the annotatable
destination is the one belonging to the **last-declared instance on the
net**, and SDF entry order is not the variable.

This is asserted on every run by `run.sh` leg C, which rebuilds the
reversed SDF from the committed one and compares survivors.

## Result 4: the destination's `specify`/`IOPATH` block is irrelevant

`fanout2_bitsel_nospecify` routes `in[3]` to two instances of
`nospec_sink`, a stand-in module with **no `specify` block of any kind**,
and the first-declared destination is rejected exactly as the standard-cell
case is. Annotating the *last*-declared `u_n1.A` instead applies cleanly.

A destination pin declaring its own `specify`/`IOPATH` is therefore **not**
a precondition for the failure. (It is also not a shield: the
specify-bearing `mux4_2` and `mux4_1` cases behave identically.)

## Result 5: AC 5 question 1 -- no testbench sensitivity

Every one of the 13 cases produces a **byte-identical** per-entry verdict
set under the no-stimulus testbench (no input ever driven, `$finish` at
t=1) and under the driving testbench (every input toggled, 80 ns of
simulated time). `run.sh` leg F asserts this.

So on a plain Verilog testbench the behaviour is **deterministic and
independent of whether the DUT is driven or how far time advances**. That
does not reproduce the testbench sensitivity klayout-tools#1619 finding 9
reports from cocotb, and it does not support that finding's reading of the
cause as "a genuine Icarus-internal race between `$sdf_annotate`'s own
intermodpath insertion and VPI callback scheduling once the simulator
advances past time 0". A race would not pick the last-declared instance
every time, in both SDF orders, under both testbenches, across repeated
runs.

## Result 6: AC 5 question 2 -- the buffer remedy works

`buffered_port_all` routes `in[5]` through a `sky130_fd_sc_hd__buf_1` and
annotates `u_buf.X -> u_e0.S0` and `u_buf.X -> u_e1.S0` -- the same fanout-2
topology as `fanout2_bitsel_all`, differing only in that the source is now
a **cell output pin** instead of a port bit. **Both entries apply**, and
both delays are observed in the waveform (the `t=60000` edge moves to
`t=63000` under the rescaled delay, and a 3 ns shift appears at t=0 on the
buffer's own output).

So inserting a buffer so the source is a cell pin **is** an effective
remedy, and it is one klayout-tools#1619 did not record. The other half of
issue #250's suggested remedy -- a DUT wrapper -- is already satisfied
structurally: the fixture's DUT is a nested child named `dut`, mirroring
`sim/tb_logic_tile.v`, which is what `flow/sdf_annotate_shim.py`'s
docstring argues and what klayout-tools#1056's nesting fix provides
synthetically. Adding a wrapper changes nothing here.

**This is not proposed as a flow change.** Buffering would mean inserting
cells into the characterized netlist, which is a place-and-route change,
out of scope for this issue and barred by #162's pin on
`flow/sdf-resim.sh`. It is recorded as the measured answer to the question
issue #250 asked.

## Result 7: the model predicts the committed SDF's 28 exactly

`sim/sdf_port_interconnect/predict_fanout_rejections.py` applies the model
to `measurements/timing-characterization/logic_tile_route.sdf` with no
simulator involved. That file's 179 `INTERCONNECT` entries break down as
116 bit-selected bare port, 5 scalar bare port (`clk` x1, `rst` x4) and 58
instance-pin sourced; of the bit-selected ones, only **12 nets** have fanout
above 1:

| net group | nets | fanout | entries | predicted rejections |
|---|---|---|---|---|
| `in[0]`, `in[1]`, `in[4]`, `in[5]`, `in[8]`, `in[9]`, `in[12]`, `in[13]` | 8 | 4 | 32 | 8 x 3 = **24** |
| `ce[0..3]` | 4 | 2 | 8 | 4 x 1 = **4** |
| all other bit-selected nets (`lut_init[*]` x64, `reg_sel[*]` x4, 8 one-way `in[*]`) | 76 | 1 | 76 | 0 |
| `clk`, `rst` (scalar) | 2 | 1, 4 | 5 | 0 |
| instance-pin sourced | 55 | 1-4 | 58 | 0 |
| **total** | | | **179** | **28** |

**28**, and the predicted sink-pin distribution is `S0` x12, `S1` x12,
`A` x4 -- the record being explained reports, verbatim, "a cell input pin
(`S0` x12, `S1` x12, `A` x4) as its sink". The four `in[N]` S0 nets
contribute 12, the four S1 nets 12, and each two-way `ce[N]` net
contributes its `A` entry, `B` being the last-declared destination. The
match is exact on count **and** on sink distribution, and `run.sh` leg G
asserts both on every run.

**The "28" is therefore the right figure for the citable path**, not a
figure from the record's non-matching regenerated geometry. Issue #250's
curated body states the affected population is 116 and that the Builder
"must not hard-code 28"; that is the count of *all* bit-selected-port
entries, which is not the affected population. Only entries on
bit-selected-port nets with fanout above 1 are affected, and only
fanout-1 of them per net.

## Result 8: consequence for `environment.sdf.annotated` and T1 item 7

Two facts, both measured here, point in opposite directions and both belong
in the record:

1. **Every one of the 28 affected entries carries `(0.000:0.000:0.000)`.**
   So do all 179 `INTERCONNECT` entries in that SDF -- the design's wire
   delays round to zero at its 1 ns timescale. All 215 `IOPATH` entries
   carry real non-zero cell delays (0.140-0.453 ns). `INTERCONNECT` and
   `IOPATH` annotate independently, which `iopath_with_interconnect`
   confirms directly. **Dropping the 28 therefore removes no delay from the
   simulation**: numerically, the annotated run would be identical with or
   without them.
2. **That does not make `environment.sdf.annotated: true` truthful.** An
   annotated run is still not reachable: `flow/sdf-resim.sh` leg 2 aborts
   earlier, at `NULL handle passed to vpi_scan` on this design's
   `generate`-flattened escaped identifiers, and leg 1 does not even reach
   leg 2 because the regenerated DEF does not match the committed one
   (#162). The 28 rejections were one open question behind item 7; they are
   now answered and shown to be numerically inert, but they were never the
   only gate.

**Item 7 stays uncited, and nothing in `signoff/block-manifest.json` is
changed by this record.** What changes is that a future annotated run no
longer has to treat the 28 as an unexplained correctness risk: it can state
the count, the mechanism, and that the dropped values are all zero.

## Result 9: divergence from klayout-tools#1619 shape (b)

The installed `klayout-tools` (0.9.2.dev1022+g2a9c52b27ce7) documents this
failure in `functional_verification.py` finding 9 and above
`_split_sdf_bus_port_interconnects` in `functional_verification_sdf.py`,
as issue #1619 shape (b), "not order-dependent, and not fixable from here",
left unfixed by design. The order-independence reproduces. Three other
parts of that description **do not**:

| klayout-tools#1619 shape (b) says | measured here |
|---|---|
| "entirely alone with no sibling at all, already fails" | **False.** A bit-selected-port entry alone on a **fanout-1** net applies cleanly (`fanout1_bitsel`). Fanout above 1 is the precondition. |
| "fails whenever its destination pin declares its own `specify`/`IOPATH` block" | **Not the trigger.** A destination with no `specify` at all fails identically at fanout 2 (`fanout2_bitsel_nospecify`, Result 4). |
| "a genuine Icarus-internal race ... once the simulator advances past time 0", and testbench-sensitive | **Not supported.** Deterministic: identical verdicts under a bench that never drives the DUT and one that runs 80 ns, in both SDF orders, across repeated runs; the survivor is always the last-declared instance (Results 3, 5). |

Plus one finding #1619 does not record at all: the **buffer remedy works**
(Result 6).

Per the friction protocol in `CLAUDE.md` and issue #250's acceptance
criteria, #1619 being closed would make a duplicate inappropriate -- but
this is a measured divergence, not a duplicate, so a new generic issue was
filed describing the gap in tool terms with no design detail:
[klayout-tools#5705](https://github.com/2AMLogic/klayout-tools/issues/5705).

Two neighbouring upstream issues were read before filing, and neither
covers this. [#1619](https://github.com/2AMLogic/klayout-tools/issues/1619)
(closed 2026-09-15) marks the mechanism "unconfirmed" and its body's
contrast -- "a same-arity multi-fanout net with **no** top-level-port
endpoint at all resolves 100% of its entries" -- is consistent with the
fanout reading; it is the module's own shape (b) *comment* that overstates
the precondition.
[#2984](https://github.com/2AMLogic/klayout-tools/issues/2984) (closed
2026-10-16) adds a counted zero-delay drop for exactly this entry shape, so
a future `klt`-driven annotated run would report these entries rather than
fail on them -- but it lists the cause as "Suspected Cause (unverified)",
notes without explaining that "two sibling entries on the same bus bit did
*not* fail", and bounds its drop to zero-delay entries. The one-modpath-per-
bit-select cap measured here explains that partial behaviour and is what
#5705 contributes.

## Reproducing

```bash
./sim/sdf_port_interconnect/run.sh
```

Exits 0 only if every verdict, every rejected-entry count, the
waveform corroboration, the SDF-order independence, the no-op/driving
equivalence and the committed-SDF prediction all match the tables above, so
this record is pinned by an assertion and not only by prose. Output is
idempotent: two consecutive runs produce identical transcripts.

Needs Icarus Verilog 13.0+ (`-ginterconnect`; the script fails loud with a
named error on 12.x rather than running silently zero-delay) and the pinned
sky130A revision (it refuses to substitute another). Scratch output goes to
`sim/build/sdf_port_interconnect/` (gitignored).
