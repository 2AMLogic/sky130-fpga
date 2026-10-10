#!/usr/bin/env python3
"""Unit tests for flow/configmem_frames.py (issue #169). stdlib only; reads the
committed fixtures in sim/bitstream/. Run from flow/fabulous.sh before the
ConfigMem equivalence step.

    python3 flow/test_configmem_frames.py
"""
import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIX = REPO / "sim" / "bitstream"
sys.path.insert(0, str(REPO / "flow"))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


M = _load("configmem_frames", REPO / "flow" / "configmem_frames.py")
C = _load("bitstream_corrupt", REPO / "sim" / "bitstream_corrupt.py")
SNAP = M.f2b.load_snapshot(FIX / "fabric_spec.json")
GOOD = (FIX / "top_io.bin").read_bytes()
STREAMS = sorted(list(FIX.glob("*.bin")) + list((FIX / "corpus").glob("*.bin")))


def rejects(tc, data, frag=None):
    with tc.assertRaises(M.FrameStreamError) as cm:
        M.frames(bytes(data), SNAP)
    if frag:
        tc.assertIn(frag, str(cm.exception))


class Valid(unittest.TestCase):
    def test_all_committed_streams_accepted(self):
        self.assertTrue(STREAMS)
        for p in STREAMS:
            self.assertTrue(M.frames(p.read_bytes(), SNAP), p)

    def test_frame_count_is_one_write_per_column_frame_for_logic_column(self):
        self.assertEqual(len(M.frames(GOOD, SNAP)), SNAP["arch"]["max_frames_per_col"])

    def test_payload_slicing_independent_of_map(self):
        # data bits the configuration map does not use are still passed through
        for name in ("unmapped_bit_set", "unused_frame_bit_set"):
            data = C.variants(GOOD)[name]
            self.assertNotEqual(M.frames(data, SNAP), M.frames(GOOD, SNAP), name)


class Malformed(unittest.TestCase):
    def test_empty_and_header_only(self):
        rejects(self, b"")
        rejects(self, GOOD[:C.HDR], "truncated")

    def test_bad_header(self):
        bad = bytearray(GOOD); bad[0] ^= 0xFF
        rejects(self, bad, "sync header")

    def test_every_truncation_length_is_rejected(self):
        for n in range(len(GOOD)):
            rejects(self, GOOD[:n])

    def test_trailing_bytes(self):
        rejects(self, GOOD + b"\x00", "trailing")
        rejects(self, GOOD + b"\xff" * 9, "trailing")

    def test_corrupt_variants(self):
        # variants() entries that are structural faults (the rest are map-dependent)
        for name in ("truncated_mid_frame", "truncated_no_desync", "truncated_header",
                     "empty", "bad_sync", "duplicate_frame", "two_strobes", "bad_column",
                     "cap_column_data", "trailing_byte", "missing_frame"):
            with self.subTest(name):
                rejects(self, C.variants(GOOD)[name])

    def test_reserved_bit_set(self):
        # Reserved field of the frame-select word: bits nfr..(fbits - sel_w - 1),
        # i.e. 20..26 for nfr = 20. Words are big-endian, so byte off+1 holds
        # bits 16..23 and byte off holds bits 24..31. Only the reserved bit is
        # set: strobe stays one-hot and the column stays in range.
        a = SNAP["arch"]
        nfr = a["max_frames_per_col"]
        self.assertEqual(nfr, 20)              # bit positions below assume this
        off = C.frame_off(1, 3)
        for byte, mask, bit in ((1, 0x10, 20), (0, 0x01, 24)):
            with self.subTest(bit=bit):
                d = bytearray(GOOD)
                self.assertFalse(d[off + byte] & mask)
                d[off + byte] |= mask
                word = int.from_bytes(d[off:off + 4], "big")
                self.assertEqual(word ^ int.from_bytes(GOOD[off:off + 4], "big"), 1 << bit)
                rejects(self, d, "frame-select")

    def test_duplicate_frame_in_otherwise_complete_stream(self):
        # complete stream plus one repeated frame: without the duplicate check the
        # later write would silently overwrite the earlier one and be accepted
        dup = GOOD[C.frame_off(1, 3):C.frame_off(1, 4)]
        d = GOOD[:C.frame_off(1, 4)] + dup + GOOD[C.frame_off(1, 4):]
        rejects(self, d, "duplicate")

    def test_zero_and_wrong_desync(self):
        z = bytearray(GOOD); z[-4:] = b"\0\0\0\0"
        rejects(self, z, "desync")
        w = bytearray(GOOD); w[-4:] = (1 << (SNAP["arch"]["desync_bit"] + 1)).to_bytes(4, "big")
        rejects(self, w, "desync")
        e = bytearray(GOOD); e[-1] |= 1   # strobe bit set on the final word -> frame-select, truncated
        rejects(self, e)

    def test_early_desync_is_incomplete(self):
        desync = GOOD[-4:]
        rejects(self, GOOD[:C.frame_off(1, 5)] + desync, "incomplete")

    def test_short_payload(self):
        rejects(self, GOOD[:C.frame_off(0, 0) + 4 + 2], "truncated")


class Cli(unittest.TestCase):
    def run_cli(self, d):
        return subprocess.run([sys.executable, str(REPO / "flow" / "configmem_frames.py"), str(d)],
                              capture_output=True, text=True)

    def test_cli_valid_has_output(self):
        r = self.run_cli(FIX)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.startswith("S "))

    def test_cli_bad_fixture_exits_nonzero_with_no_stdout(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            shutil.copy(FIX / "fabric_spec.json", t)
            (t / "corpus").mkdir()
            shutil.copy(FIX / "top_io.cfg", t / "a_good.cfg")
            (t / "a_good.bin").write_bytes(GOOD)
            shutil.copy(FIX / "top_io.cfg", t / "z_bad.cfg")
            (t / "z_bad.bin").write_bytes(GOOD + b"\0")
            r = self.run_cli(t)
            self.assertEqual(r.returncode, 1)
            self.assertEqual(r.stdout, "")
            self.assertIn("error: z_bad.bin:", r.stderr)


if __name__ == "__main__":
    unittest.main()
