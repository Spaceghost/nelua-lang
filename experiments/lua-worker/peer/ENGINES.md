# Engine qualification ledger

Inspected September 13, 2026. A candidate enters the headline timing set only after its claimed source profile and host contract pass. Repository README performance numbers are not our results.

| Candidate | Current role | Required qualification |
|---|---|---|
| Stock Lua 5.5.1 native | Implemented peer adapter and KJ HTTP host | Shared source corpus, native sanitizers, real I/O/cancellation, release timings |
| Stock Lua 5.5.1 Wasm | Same explicit-context core/source control | Identical results/transcripts in Node and workerd |
| LuaJIT 2.1 pinned commit c6ffc141 | Implemented interpreter and trusted-JIT lanes | Common source subset; separate hook policy; actual compiled traces; external kill |
| Graal/Truffle Lua | Screened, not built or timed in this slice | Modern reproducible build, coroutine resumption across host calls, library profile, cancellation/fuel and heap accounting |
| Luau | Screened candidate, not built or timed | C API adapter, trusted compiler path, interrupts, and explicit Lua/Luau source differences |
| Deegen / LuaJIT Remake | Research candidate, not built or timed | Reproducible toolchain, embedding/cancellation support, language subset and cold/warm measurements |

## GraalVM is a framework, not automatic Lua support

The official Truffle framework derives optimized code from language implementations and provides interoperability. A usable Lua language implementation still has to implement Lua semantics and our suspension contract.

Two concrete projects were inspected rather than assuming that no Lua implementation exists:

- `zhxzkhz/LuaTruffle`, README at blob `c5583e06bd496ebc879bb1af83437bcf93d51838`, describes a Lua 5.3+ Truffle implementation and polyglot interoperability. Its own remaining-work section lists coroutine support, a complete math/io library and improved string patterns. That prevents treating it as an already qualified worker runtime. Its Fibonacci claims were not copied into our comparisons.
- `00asdf/TruffleLua`, `setup.md` at blob `d1f70e0c7cea1b1ebbcf242a9a9e1d6d9eb2b0d7`, gives a Graal/MX build path and requests GraalVM 25.3.4. This is the project's stated dependency, not a version we built or validated. Its coroutine/host-boundary behavior is unqualified here; an empty code-search response was not treated as proof of absence.

A Graal LLVM or native-function bridge to stock Lua would be another architecture. Calling the interpreter through a polyglot interface is not evidence that Graal optimizes arbitrary guest Lua applications. It must pass the same contract and include its JVM/native-image startup and memory costs.

## Other credible directions

Luau documents its sandboxing/interrupt strategy and its deliberate language differences. It is worth a separate adapter, not relabeling as Lua 5.5. Deegen's paper demonstrates generated interpreters and a baseline JIT with LuaJIT Remake; those results motivate a low-startup-JIT experiment but do not prove embedding or worker completeness for this project.

Primary references:
- https://www.graalvm.org/latest/graalvm-as-a-platform/language-implementation-framework/
- https://github.com/zhxzkhz/LuaTruffle/blob/main/README.md
- https://github.com/00asdf/TruffleLua/blob/master/setup.md
- https://luajit.org/faq.html
- https://luajit.org/extensions.html
- https://luau.org/compatibility/
- https://luau.org/sandbox/
- https://arxiv.org/abs/2411.11469

No Graal, Luau or Deegen runtime has been deployed, selected as a dependency, or assigned a measured speed in this slice.
