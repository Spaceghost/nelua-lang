/* SPDX-License-Identifier: MIT */
#ifndef LUA_WORKER_KERNEL_H
#define LUA_WORKER_KERNEL_H
#include <stdint.h>
#include <stddef.h>
/* Native and wasm32 use this same ABI. Pointers are borrowed only for the call.
 * IDs and operation sequences must match; buffers are copied before returning.
 * A native host must serialize entry to a kernel instance (not thread-safe).
 * States: absent=0, ready=1, running=2, waiting=3, done=4, failed=5. */
uint32_t lw_abi_version(void), lw_ping(uint32_t), lw_open(void);
int lw_state(uint32_t), lw_attach(uint32_t, void *), lw_tick(uint32_t);
void *lw_vm(uint32_t);
void *lw_lua_alloc(void *, void *, size_t, size_t);
int lw_issue(uint32_t, int, void *, size_t);
uint32_t lw_sequence(uint32_t);
int lw_kind(uint32_t), lw_status(uint32_t), lw_ok(uint32_t);
char *lw_data(uint32_t);
size_t lw_size(uint32_t), lw_bytes(void);
uint32_t lw_active(void);
int lw_result(uint32_t, int, int, void *, size_t);
int lw_complete(uint32_t, uint32_t, int, int, void *, size_t);
int lw_release(uint32_t);
int lw_start(uint32_t, const char *, size_t, const char *, size_t,
             const char *, size_t, const char *, size_t, uint32_t);
int bridge_resume(uint32_t);
void bridge_close(void *);
#endif
