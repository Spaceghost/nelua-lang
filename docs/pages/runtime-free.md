---
layout: docs
title: Runtime-free native code
permalink: /runtime-free/
categories: docs toc
toc: true
order: 7
---

Nelua can compile a native component that an existing C/C++ application or an
operating system calls directly: no Lua VM, garbage collector, Nelua allocator,
initialization routine or panic handler in that component. The host owns the
entrypoint, memory and platform services.
{: .lead}

This is a low-level programming and build pattern, verified in the emitted code
and linked symbols. It is not a blanket `--no-runtime` switch. `nogc` alone does
not establish it.

## The recipe

Keep the component to typed scalar values, pointers, fixed arrays and records.
Export a C ABI with `cexport` and a stable `codename`. Pass storage from the host,
return errors explicitly, and keep executable initialization out of the module's
top level.

```lua
## pragmas.nogc = true
## pragmas.noentrypoint = true
## pragmas.nochecks = true -- Replace automatic checks with explicit validation.

local function nelua_checked_add(a: uint32, b: uint32, out: *[0]uint32): boolean
  <cexport, codename 'nelua_checked_add'>
  if out == nilptr or b > 0xffffffff_u32 - a then return false end
  out[0] = a + b
  return true
end
```

The host must pass a valid writable pointer for one `uint32_t`, or a null pointer.
The function rejects null and arithmetic overflow, leaving the output unchanged
on failure. There is no allocation or initialization to perform before calling
it. A runnable copy, with its C header and tests, lives in
[examples/freestanding](https://github.com/Spaceghost/nelua-lang/tree/master/examples/freestanding).

`nochecks` deliberately disables compiler-inserted runtime checks. It is not a
requirement for every possible runtime-free function, and it is not a general
performance recommendation. These examples use it only with explicit validation
of their failure conditions. Pointer lifetime, capacity, ownership and alignment
remain the caller's contract; null checks cannot prove an arbitrary pointer valid.

## What the pragmas do

| Setting | Effect | What it does not establish |
| --- | --- | --- |
| `pragmas.nogc` | Disables Nelua's garbage collector | An imported allocator or string builder can still allocate through the host heap |
| `pragmas.noentrypoint` | Omits the default generated C `main` | Executable top-level code may still produce a `nelua_main` initialization function |
| `pragmas.nochecks` | Disables automatic runtime checks | It does not remove explicit `assert`, `error`, allocation or other library calls |
| Variable `<noinit>` / `pragmas.noinit` | Suppresses default variable initialization | It does not disable a runtime; every value must be initialized before being read |
| `pragmas.nocstaticassert` | Suppresses generated C static assertions | Static assertions have no executable startup cost; retain ABI checks by default |

There is no `noruntime` pragma. Compiler Lua runs at build time; it is not a Lua
VM embedded in the resulting application.

Avoid nontrivial top-level statements and initialization that must execute
before exports are called. `noentrypoint` does not automatically arrange for a
C host to call such initialization. If your component needs it, expose an
explicit initialization API and document it. Ordinary C static data or zeroed
BSS is distinct from running a Nelua initializer; a freestanding host must honor
its own loader and static-storage requirements.

Keep ABI static assertions when importing C records or target-sized types.
Generate and compile C for the intended target configuration; suppressing a failed
static assertion is not a fix for a real ABI mismatch.

## C-hosted: no Nelua runtime, C libraries allowed

The [C-host example](https://github.com/Spaceghost/nelua-lang/tree/master/examples/c_host)
exports bounded JSON-span and int64-formatting callbacks. C supplies `main`,
borrowed inputs and output buffers. Nelua uses fixed temporary arrays and an
explicit C `memcpy` binding. The host can use its normal C libraries.

From the compiler repository root:

```sh
make
./nelua --release --no-cache examples/c_host/kernel.nelua
python3 examples/c_host/check.py --sanitize
```

Or integrate emitted C into the host's build:

```sh
./nelua --release --print-code examples/c_host/kernel.nelua > kernel.c
cc -std=c11 -O3 -flto -Iexamples/c_host \
   kernel.c examples/c_host/host.c -o host
./host
```

This is **Nelua-runtime-free**, not libc-free: the audit allows `memcpy` and a
compiler stack-protection helper, and the host uses stdio. It verifies
repeatable C emission, exactly the intended exports, explicit bounds, integer
extremes, embedded NUL/control/UTF8 data, and absence of generated allocation,
entrypoint and panic paths. Input UTF8 validity and non-overlap are host
preconditions. Output can be partial on failure.

The `--no-cache` invocation is useful when iterating on C companions with older
compiler pins. Emitting C and compiling the host explicitly also makes that
build boundary visible.

## Freestanding: audit every linked dependency

The checked-add example can go further because it calls no host functions:

```sh
./nelua --release --print-code examples/freestanding/kernel.nelua > kernel.c
cc -std=c11 -Os -ffreestanding -fno-builtin -fno-stack-protector \
   -Iexamples/freestanding -c kernel.c -o kernel.o
nm -u kernel.o
```

The final command must be empty for this recipe on the target being audited.
Inspect the exports as well:

```sh
nm -g --defined-only kernel.o
python3 examples/freestanding/check.py --sanitize
```

The audit requires the one intended export and zero undefined symbols. It runs
boundary cases through a normal C host. On Linux x86-64 it also supplies `_start`,
links with `-static -nostdlib`, verifies no interpreter, dynamic dependencies or
initialization entries,
and executes the same cases. That executable uses Linux for loading and the
exit syscall; it is not an OS kernel. Other platforms run the object/hosted
checks. The audit tools require Python 3 and GNU-compatible `nm`; the Linux
executable check also uses `readelf`.

`-ffreestanding` changes the C compiler's assumptions; `-nostdlib` omits the
usual startup and libraries at link time. Neither proves that generated code
needs no helpers. A C compiler can introduce memory-copy, arithmetic or other
support calls depending on the operations, optimization and target. Audit the
object and final link for each supported toolchain. The bare example disables
stack protection because it supplies no guard runtime; a host that supplies
stack protection can keep it enabled and account for that dependency.

## Evidence from real applications

The pattern was exercised in the
[multicore-server challenge entry](https://github.com/Spaceghost/multicore-server-challenge/tree/bc35c96ef444521151f6f3a78591f39b59f21b6e/submissions/nelua-epoll-spaceghost).
Its Nelua application logic exports callbacks to a native epoll/libpq host.
The generated component omits the Nelua runtime, while the complete server
still uses C allocation, threads and libraries. Its source audit is not a claim
that the whole server is freestanding.

[Drift](https://github.com/Spaceghost/drift) uses the same pattern for a protocol
machine and native controller drivers. Its build additionally checks unresolved
symbols and boots a no-libc reference kernel. The controller host supplies
explicit DMA allocation and device resources; runtime-free does not mean a
driver needs no memory or platform support.

These are usage examples, not compiler optimization switches or benchmark
performance guarantees. Compiler defaults and language semantics are unchanged.
