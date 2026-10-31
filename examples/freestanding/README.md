# A Nelua function without a runtime or libc

The host supplies an output pointer; the Nelua function returns failure for
null storage or unsigned overflow. It owns no memory, runs no initialization,
and imports no linked functions in the audited reference build.

```sh
./nelua --release --no-cache examples/freestanding/kernel.nelua
python3 examples/freestanding/check.py --sanitize
```

The first command uses an ordinary C `main`. The audit separately checks the
emitted object, runs the same boundary cases under a hosted C entrypoint, and
on Linux x86-64 links/runs `_start` without libc or the C runtime startup.
The no-CRT executable uses Linux only for loading and the exit syscall; it is
not an operating-system kernel. Other platforms run the object/hosted checks.
Python 3 and GNU-compatible `nm` are needed; Linux execution also uses `readelf`.

To emit and compile the component yourself:

```sh
./nelua --release --print-code examples/freestanding/kernel.nelua > kernel.c
cc -std=c11 -Os -ffreestanding -fno-builtin -fno-stack-protector \
   -Iexamples/freestanding -c kernel.c -o kernel.o
nm -u kernel.o
```

The final command must be empty for this recipe on your target. Compiler helper
calls depend on operations and target architecture, so verify each build.

See the [runtime-free guide](../../docs/pages/runtime-free.md) for the pragma
semantics, memory/initialization rules and the distinction from C-hosted code
that is allowed to call libc.
