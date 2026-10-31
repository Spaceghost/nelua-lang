#!/usr/bin/env python3
"""Audit a runtime-free object and exercise hosted and no-CRT entrypoints."""
import argparse
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    cc = shlex.split(os.environ.get('CC', 'cc'))
    command = [str(ROOT / 'nelua'), '--release', '--print-code', str(HERE / 'kernel.nelua')]
    code = subprocess.check_output(command, cwd=ROOT)
    assert code == subprocess.check_output(command, cwd=ROOT), 'nondeterministic C'
    text = code.decode()
    assert not re.search(r'\b(?:main|nelua_main|malloc|calloc|realloc|free|abort|exit)\s*\(', text)
    assert not re.search(r'\b(?:lua_|GC_|nelua_(?:gc|panic|assert|error|abort))', text)
    with tempfile.TemporaryDirectory(prefix='nelua-freestanding-') as folder:
        folder = Path(folder)
        source, obj = folder / 'kernel.c', folder / 'kernel.o'
        source.write_bytes(code)
        flags = ['-std=c11', '-Os', '-Wall', '-Wextra', '-Werror',
                 '-ffreestanding', '-fno-builtin', '-fno-stack-protector', '-I' + str(HERE)]
        subprocess.run(cc + flags + ['-c', str(source), '-o', str(obj)], check=True)
        imports = subprocess.check_output(['nm', '-u', str(obj)], text=True)
        assert not imports.strip(), imports
        symbols = subprocess.check_output(['nm', '-g', '--defined-only', str(obj)], text=True)
        exports = {line.split()[-1].lstrip('_') for line in symbols.splitlines() if line.split()}
        assert exports == {'nelua_checked_add'}, exports
        hosted = folder / 'host'
        test_flags = flags + (['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if args.sanitize else [])
        subprocess.run(cc + test_flags + [str(source), str(HERE / 'host.c'), '-o', str(hosted)], check=True)
        subprocess.run([str(hosted)], env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'}, check=True)
        print('deterministic C, zero imports, exact export, checked bounds: pass')
        if platform.system() == 'Linux' and platform.machine() in ('x86_64', 'AMD64'):
            bare = folder / 'no-crt'
            subprocess.run(cc + flags + ['-fno-pie', '-static', '-nostdlib', '-Wl,-e,_start',
                           str(source), str(HERE / 'start_linux_x86_64.c'), '-o', str(bare)], check=True)
            assert not subprocess.check_output(['nm', '-u', str(bare)], text=True).strip()
            segments = subprocess.check_output(['readelf', '-l', str(bare)], text=True)
            assert 'INTERP' not in segments, segments
            dynamic = subprocess.check_output(['readelf', '-d', str(bare)], text=True)
            assert '(NEEDED)' not in dynamic and '(INIT)' not in dynamic and '(INIT_ARRAY)' not in dynamic, dynamic
            subprocess.run([str(bare)], check=True)
            print('Linux x86-64: no-CRT executable, no dynamic dependencies, execution: pass')
        else:
            print('no-CRT execution is Linux x86-64 only; object and hosted checks passed')


if __name__ == '__main__':
    main()
