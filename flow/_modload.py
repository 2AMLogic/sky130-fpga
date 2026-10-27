"""flow/_modload.py

Shared `load_module(name, path)` helper for the `flow/` scripts and their unit
tests: load a Python source file by path as a module, without needing its
directory on `sys.path`. Previously hand-copied as a private `_load` into
fourteen files. Callers that run under `python3 -I` (which drops the script
directory from `sys.path`) put `flow/` on `sys.path` before importing this.

Not a public API beyond `flow/` -- hence the leading underscore in the filename.
"""

import importlib.util


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
