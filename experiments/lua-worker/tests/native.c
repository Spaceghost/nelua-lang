/* SPDX-License-Identifier: MIT */
#include "kernel.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static uint32_t start(const char *source) {
  uint32_t id = lw_open(); assert(id);
  int status = lw_start(id, source, strlen(source), "GET", 3, "https://test.invalid/native", 27, "", 0, 12345);
  assert(status == 3 || status == 4 || status == 5);
  return id;
}
static void close_id(uint32_t id) { assert(lw_release(id) == 0); }
static int complete(uint32_t id, const char *value) {
  return lw_complete(id, lw_sequence(id), 1, 200, (void *)value, strlen(value));
}
int main(void) {
  const char *app = "local h=require'worker.http'; return {fetch=function(r,e,c) return h.text(e.CONFIG:get('greeting')) end}";
  uint32_t a = start(app), b = start(app);
  assert(a != b && lw_state(a) == 3 && lw_state(b) == 3);
  assert(lw_complete(a, lw_sequence(a)+1, 1, 200, "wrong", 5) == -1);
  assert(complete(b, "second") == 4);
  assert(complete(a, "first") == 4);
  assert(lw_size(a) == 5 && !memcmp(lw_data(a), "first", 5));
  assert(lw_size(b) == 6 && !memcmp(lw_data(b), "second", 6));
  close_id(a); close_id(b);
  a = start(app); uint32_t seq = lw_sequence(a); close_id(a);
  b = start(app); assert(a != b);
  assert(lw_complete(a, seq, 1, 200, "late", 4) == -1);
  assert(lw_state(b) == 3); close_id(b);
  a = start("return {fetch=function() local function broken() error('needle') end; broken() end}");
  assert(lw_state(a) == 5);
  assert(lw_size(a) > 0); fwrite(lw_data(a), 1, lw_size(a), stdout); puts(""); close_id(a);
  a = start("return {fetch=function() while true do end end}");
  assert(lw_state(a) == 5); close_id(a);
  a = start("return {fetch=function() return {status=200,body=string.rep('x',4000000)} end}");
  assert(lw_state(a) == 5); close_id(a);
  a = start("\033Lua binary chunks are not allowed");
  assert(lw_state(a) == 5); close_id(a);
  assert(lw_active() == 0 && lw_bytes() == 0);
  puts("native contract: PASS (ownership, out-of-order, stale IDs, traceback, budget, allocation, text-only, cleanup)");
}
