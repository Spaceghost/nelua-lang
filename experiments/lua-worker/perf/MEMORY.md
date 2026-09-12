# Heap diagnostic and protocol failure evidence

The normal, inspector-free benchmark shows rising process RSS in both plain JavaScript and all Lua profiles, despite zero live Lua allocation and invocation counters. No small-memory or stable-plateau claim follows from the Lua counters.

The first separate diagnostic in run **34722306961** failed while waiting ten seconds for a `HeapProfiler.collectGarbage` reply. The same run's contender contracts, all three shipped-profile byte comparisons, and complete performance measurements passed. Its failure was in the additional inspector probe, not the optimized runtime.

The failed artifact is `lua-shootout-34722306961`, ID `10306174110`, ZIP SHA256 `54aa5bddd4ec03a854fb6e053163302fa8d969399f41092eebba53c5683dba56`. Its `reports/memory-diagnostic.log` and `reports/shootout/memory-diagnostic.json` retain the exact timeout.

An upstream report, https://github.com/cloudflare/workerd/issues/6824, describes standalone workerd accumulating collectible JSG/cppgc objects under sustained load and GC acknowledgements arriving much later than the collection's observable effect. That report is relevant corroborating evidence, not a proof that our workload has the identical root cause. Our tested workerd version is newer than the version in that report.

The revised probe does not interpret an absent acknowledgement as either success or failure of collection. It records each explicitly sent collection request and any eventual reply separately, then independently samples process RSS and V8 heap counters one and two seconds later. Labels say `after-gc-request`, not unconditionally `post-GC`. Unsupported inspector methods, malformed statistics, incorrect response/operation counts, and nonzero Lua/invocation accounting still fail the probe. Its `MEASURED` status means observations were obtained, not that a memory optimization or production memory bound was proven.

The diagnostic runs separately against JavaScript, the frozen Lua baseline, the balanced profile and the CPU profile. Each process receives 100,000 checked hello invocations. Inspector mode and explicit collection requests are never used in the headline performance tests or the normal worker configuration.

Read the resulting `reports/shootout/memory-diagnostic.json` to distinguish:
- growth without forced collection;
- observed changes after a collection request;
- whether the control protocol actually acknowledged the request;
- live JS heap, any supplied embedder/backing-storage counters, Lua allocations and whole-process RSS.

A reproducible reduction after collection would support the interpretation of delayed reclamation rather than an unreclaimable Lua leak. It would not establish a leak-free runtime, guaranteed container memory safety, or acceptable long-term standalone workerd memory behavior. Production outer memory limits and supervision remain separate requirements.
