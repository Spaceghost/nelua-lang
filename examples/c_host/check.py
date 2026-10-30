#!/usr/bin/env python3
"""Emit, compile, audit and run the C-host example with standard host tools."""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    compiler = shlex.split(os.environ.get("CC", "cc"))
    command = [str(ROOT / "nelua"), "--release", "--print-code", str(HERE / "kernel.nelua")]
    code = subprocess.check_output(command, cwd=ROOT)
    # Same inputs must generate identical output; no timestamp or cache state.
    assert code == subprocess.check_output(command, cwd=ROOT)
    text = code.decode()
    assert not re.search(r"\b(?:main|nelua_main)\s*\(", text)
    assert not re.search(r"\b(?:malloc|calloc|realloc|free|abort|exit)\s*\(", text)
    assert not re.search(r"\b(?:lua_|GC_|nelua_(?:gc|panic|assert|error|abort))", text)
    with tempfile.TemporaryDirectory(prefix="nelua-c-host-") as folder:
        folder = Path(folder)
        source, obj, binary = folder / "kernel.c", folder / "kernel.o", folder / "host"
        source.write_bytes(code)
        flags = ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I" + str(HERE)]
        subprocess.run(compiler + flags + ["-c", str(source), "-o", str(obj)], check=True)
        imports = subprocess.check_output(["nm", "-u", str(obj)], text=True)
        imported = {line.split()[-1].lstrip("_") for line in imports.splitlines() if line.split()}
        assert imported <= {"memcpy", "stack_chk_fail"}, imports
        exports = subprocess.check_output(["nm", "-g", "--defined-only", str(obj)], text=True)
        exported = {line.split()[-1].lstrip("_") for line in exports.splitlines() if line.split()}
        assert exported == {"host_json_string", "host_decimal_i64"}, exports
        if args.sanitize:
            flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        subprocess.run(compiler + flags + [str(source), str(HERE / "host.c"), "-o", str(binary)], check=True)
        # LeakSanitizer requires /proc capabilities absent in some build sandboxes.
        env = {**os.environ, "ASAN_OPTIONS": "detect_leaks=0"}
        subprocess.run([str(binary)], env=env, check=True)
    print("C ABI, deterministic emission, host-owned bounds, runtime audit: pass")


if __name__ == "__main__":
    main()
