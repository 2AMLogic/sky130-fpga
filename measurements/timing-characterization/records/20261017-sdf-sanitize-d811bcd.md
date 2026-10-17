<!-- record-meta
{
  "record_id": "20261017-sdf-sanitize-d811bcd",
  "experiment": "sdf-sanitize",
  "git_revision": "d811bcd0da39799d1a89e07cc6cf5273a70ccc40",
  "framework_gap": "G4",
  "harness": "flow/sdf_sanitize_names.py",
  "provenance": {
    "klt_version": "0.7.1.dev1743+g7ee09483b748",
    "openroad_version": "26Q3-1510-g6cb3f2b704",
    "iverilog_version": "13.0 (stable) (v13_0)",
    "pdk": {
      "name": "sky130A",
      "version": "open_pdks c6d73a35f524070e85faff4a6a9eef49553ebc2b"
    },
    "inputs": [
      {"path": "layout/logic_tile.def", "role": "committed characterized geometry; this run's regenerated DEF did NOT match it (see Result 1)", "content_hash": "sha256:2979e7fb3e292e20e31c85e642687b4cacdc7ff9f7d72c7bc2b526bb793badaf"},
      {"path": "sim/tb_logic_tile.v", "role": "existing functional testbench, run gate-level UNMODIFIED", "content_hash": "sha256:3f90296942e63a59f55db70dd657025d90d91f9452577a07fbddef35a15c3603"},
      {"path": "flow/sdf-resim.sh", "role": "run unmodified; stops at the DEF gate", "content_hash": "sha256:65c8fb606aebdcdbc36b1be56fce73b51b833fffde631318c99e86a8b05f6c86"},
      {"path": "flow/sdf_annotate_shim.py", "role": "used unmodified for the exploratory annotated run", "content_hash": "sha256:1d6112433626e5073e67e505917c4b31f585071a0742458321516bbf008858b2"},
      {"path": "flow/sdf_sanitize_names.py", "role": "paired netlist + SDF rename under test", "content_hash": "sha256:a445e5ebf647f9df48d8fbd0e19c2ef40f69b4582f8bbd03f7a09e95a069ae42"}
    ]
  }
}
-->

# Record 20261017-sdf-sanitize-d811bcd

- **Record ID**: 20261017-sdf-sanitize-d811bcd
- **Claim**: T1 checklist item 7 (issue #213) -- the escaped-identifier
  workaround for the `$sdf_annotate` abort was tried. **Item 7 stays
  uncited**: the characterized geometry could not be regenerated on this
  toolchain, and the annotated run that was possible is partial and on
  non-characterized geometry.
- **Relationship to other records**: does not supersede
  `20261008-233733-23e6b5e` (the active `sdf-resim` record, which pins
  `flow/sdf-resim.sh`; that script is unchanged here). Append-only.
- **Toolchain** (2026-10-17, host tools untouched; `PDK_ROOT=~/.volare` so the recorded PDK is used, the default pick is a newer open_pdks): klt `0.7.1.dev1743`,
  OpenROAD `26Q3-1510`, Icarus `13.0` from `~/.cache/icarus-13.0/bin`
  (selected with `ICARUS13_BIN_DIR`, see Note).

## Result 1: `flow/sdf-resim.sh` leg 1 -- FAILS at the DEF reproducibility gate

Synthesis and place-and-route complete and reach `route`, but the
regenerated DEF differs from the committed `layout/logic_tile.def`
(205 vs 212 `COMPONENTS`, different filler cells; 3066 diff lines). The
gate was **not** relaxed. Regenerated DEF hash
`sha256:149bb47959f157e351b800a0bc547ddb54a1c5d846a7cf32e8cefb5e7771c3b6`.
This is the toolchain drift already tracked in #162. Consequence: the SDF
this run produced does not describe the geometry PR #22 characterized, so
nothing below can be cited for item 7.

**Note**: with `/usr/bin/yosys` present, the script prepends `/usr/bin` to
`PATH`, which puts the distro Icarus 12.0 ahead of the 13.0 build in
`~/.local/bin`, and `resolve_icarus13()` then fails ("no Icarus Verilog
13.0+ build found"). Setting `ICARUS13_BIN_DIR` works around it. Not fixed
here (pinned script, #162).

## Result 2: the rename is a pure rename (checked, not asserted)

`flow/sdf_sanitize_names.py` applied to this run's routed netlist
(`sha256:82af1c38...6946`) and SDF (`sha256:62da4707...8d7f (non-canonicalized, carries a DATE line)`):

- netlist: 84 distinct names renamed; SDF: 44 distinct names renamed;
- `check` reports `PASS: pure rename`: map injective and collision-free
  against existing plain identifiers, inverse map reproduces both
  originals byte-for-byte, every SDF instance exists in the sanitized
  netlist, and no escaped `.`/`[`/`]`/`/` identifier remains in either file;
- unit tests: `python3 -I flow/test_sdf_sanitize_names.py` (7 tests,
  including the `\g_slice[0].u_slice/_NN_` forms and both collision cases).

## Result 3: annotated run on the sanitized pair (exploratory, uncitable)

`tb_logic_tile` gate-level + `$sdf_annotate` on the sanitized pair, `-T typ`:

- `vvp` **no longer aborts** (exit 0, no `NULL handle passed to vpi_scan`);
  `PASS: tb_logic_tile -- 4 checks, 0 failures`.
- The annotation is **partial**. 28 `INTERCONNECT` entries are rejected
  (`Could not find intermodpath!` / `Could not insert intermodpath!`): every
  one has a top-level input port (`in[N]`, `ce[N]`) as its source and a
  cell input pin (`S0` x12, `S1` x12, `A` x4) as its sink. The other
  151 of 179 entries raised no error. Two header lines (`VOLTAGE`,
  `PROCESS`: `1.800::1.800`, no typ value) report `Chosen value not
  defined`; 4 `TIMINGCHECK not supported` warnings.
- Because 28 entries are unapplied, the PASS is **not** evidence of a
  fully SDF-annotated run, and `environment.sdf.annotated: true` would not
  be a truthful statement. The cause of the 28 rejections was not
  isolated; it is not a name problem (the names resolve after the rename).

## Conclusion

The workaround removes the `vvp` abort of klayout-tools#2897 on this
design's escaped identifiers. It does not by itself yield a citable item 7:
(1) the characterized geometry is not reproducible on the current toolchain
(#162), and (2) a further Icarus/SDF limitation leaves port-sourced
interconnects unannotated. `signoff/block-manifest.json` is unchanged and
item 7 remains uncited. No Fmax or timing-closure claim is made.
