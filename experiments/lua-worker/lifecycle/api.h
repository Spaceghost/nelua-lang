/* SPDX-License-Identifier: MIT */
#ifndef LUA_WORKER_LIFECYCLE_H
#define LUA_WORKER_LIFECYCLE_H
#include "kernel.h"
uint32_t wa_open(void), wa_pending(void), wa_app_count(void);
void *wa_ptr(uint32_t);
int wa_attach(uint32_t, void *), wa_ready(uint32_t), wa_pin(uint32_t), wa_unpin(uint32_t), wa_tick(uint32_t);
void *wa_alloc(void *, void *, size_t, size_t);
size_t wa_bytes(void), wa_error_size(void);
char *wa_error_data(void);
int wa_error(void *, size_t), wa_release(uint32_t);
int wa_load(uint32_t, const char *, size_t, uint32_t);
int wa_start(uint32_t, uint32_t, const char *, size_t, const char *, size_t, const char *, size_t);
int wa_collect(uint32_t);
uint32_t wa_load_count(void);
void warm_destroy(void *);
#endif
