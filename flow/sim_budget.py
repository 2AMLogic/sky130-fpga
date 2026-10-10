"""Per-simulation wall-clock budget for the Python simulation drivers (issue #157).

Mirrors the shell helpers in flow/gate_sim_verdict.sh, which hold the single
default (GS_SIM_TIMEOUT_DEFAULT); this module reads that value instead of
restating it. Override with SIM_TIMEOUT_SECONDS (positive integer seconds).
A run that exceeds the budget is an infrastructure failure: callers must never
count it as a test verdict, a caught mutation or a functional rejection.
"""
import os
import pathlib
import re

_HELPER = pathlib.Path(__file__).resolve().parent / "gate_sim_verdict.sh"
_VALID = re.compile(r"[1-9][0-9]{0,5}")


def default_budget():
    m = re.search(r"^GS_SIM_TIMEOUT_DEFAULT=([0-9]+)$", _HELPER.read_text(), re.M)
    if not m:
        raise SystemExit(f"error: GS_SIM_TIMEOUT_DEFAULT not found in {_HELPER}")
    return int(m.group(1))


def budget():
    """Return the budget in seconds; SystemExit on an invalid override."""
    v = os.environ.get("SIM_TIMEOUT_SECONDS")
    if v is None:
        return default_budget()
    if not _VALID.fullmatch(v):
        raise SystemExit(f"error: invalid SIM_TIMEOUT_SECONDS={v!r} "
                         "(must be a positive integer number of seconds, 1..999999)")
    return int(v)
