# A C host with runtime-free Nelua callbacks

The C host supplies `main`, borrowed input spans, and output storage. Nelua
exports a JSON byte-span encoder and an int64 formatter. Neither callback owns
heap memory, initializes a VM/GC, or depends on a panic/exit path. Explicit
capacity checks return failure even when release checks are disabled. Output
can be partial on failure; reset the buffer length before retrying. Input must
not overlap the output buffer, and the host guarantees valid UTF8 input.

Run the complete example through Nelua's existing C-file support:

```sh
./nelua --release examples/c_host/kernel.nelua
```

Or emit C for an existing application's build system:

```sh
./nelua --release --print-code examples/c_host/kernel.nelua > kernel.c
cc -std=c11 -O3 -flto -Iexamples/c_host kernel.c examples/c_host/host.c -o host
./host
python3 examples/c_host/check.py --sanitize
```

The standalone audit uses Python 3 and GNU-compatible `nm`; `CC=clang` selects
another C compiler. The portable compiler regression suite also runs the host.
The audit checks deterministic source, exactly two public symbols, only memory
copying/stack protection imports, integer boundaries, JSON controls/UTF8/NUL,
short buffers, and missing entrypoint/allocator/panic code.

`nogc` alone does not prohibit allocation: importing string builders or an
allocator may still add host heap work. Keep leaf interfaces to borrowed spans,
scalar values, and fixed stack buffers; inspect the emitted code and linked
symbols. The macros, typedefs, and ABI static assertions in generated C add no
executable startup. Preserve the assertions when crossing a foreign ABI.

Use application-specific C compiler flags for LTO, native CPU tuning, PGO, or
vectorization experiments, and retain a correctness-tested baseline. Nelua's
`--maximum-performance` can enable fast-math on some compilers; it is not an
automatic improvement for code needing strict floating-point behavior. The
example uses `--release` plus explicit `-O3 -flto` instead. No compiler defaults,
language semantics, or security settings are changed by this example.
