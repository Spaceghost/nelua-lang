/* SPDX-License-Identifier: MIT */
#ifndef LUA_PEER_API_H
#define LUA_PEER_API_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* The native and Wasm targets compile this same API and context kernel.
 * Each app owns its kernel and Lua state. Calls to one app must be serialized.
 * Handles are (app identity, request ID, operation sequence), not bare IDs.
 * Byte pointers are borrowed for the synchronous call only.
 * States: absent=0, running=2, waiting=3, done=4, failed=5.
 * jit=1 is a TRUSTED-CODE benchmark profile, not instruction-metered execution.
 */
typedef struct np_app np_app;
np_app *np_new(size_t lua_limit, int jit);
int np_load(np_app *, const char *, size_t, uint32_t seed);
uint32_t np_start(np_app *, const char *, size_t, const char *, size_t, const char *, size_t);
int np_complete(np_app *, uint32_t, uint32_t, int, int, const char *, size_t);
int np_close(np_app *, uint32_t);
int np_delete(np_app *);
int np_state(np_app *, uint32_t), np_kind(np_app *, uint32_t), np_status(np_app *, uint32_t);
uint32_t np_sequence(np_app *, uint32_t), np_active(np_app *), np_traces(np_app *);
const char *np_data(np_app *, uint32_t), *np_error(np_app *), *np_version(void);
size_t np_size(np_app *, uint32_t), np_bytes(np_app *);
int np_collect(np_app *);
/* Private Nelua ABI. Every mutable operation takes an explicit kernel pointer. */
void *nk_new(size_t), *nk_vm(void *), *nk_alloc(void *, void *, size_t, size_t), *nk_data(void *, uint32_t);
void nk_setvm(void *, void *);
int nk_delete(void *), nk_index(void *, uint32_t), nk_tick(void *, uint32_t), nk_state(void *, uint32_t), nk_kind(void *, uint32_t), nk_status(void *, uint32_t);
uint32_t nk_open(void *), nk_active(void *), nk_sequence(void *, uint32_t);
size_t nk_size(void *, uint32_t), nk_bytes(void *);
int nk_issue(void *,uint32_t,int,void *,size_t);
int nk_resolve(void *,uint32_t,uint32_t,int,int,void *,size_t);
int nk_result(void *,uint32_t,int,int,void *,size_t), nk_close(void *,uint32_t);
#ifdef __cplusplus
}
#endif
#endif
