/* SPDX-License-Identifier: MIT */
#include "lifecycle.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
static const char *source = "local h=require'worker.http';local count=0;return{fetch=function(r,e)count=count+1;local mine=count;local s=e.CONFIG:get('greeting');return h.text(s..':'..mine)end}";
static uint32_t request(uint32_t app) {
  uint32_t id=lw_open();assert(id);
  assert(wa_start(id,app,"GET",3,"https://test.invalid",19,"",0)==3);
  return id;
}
int main(void) {
  uint32_t app=wa_open();assert(app);
  assert(wa_load(app,source,strlen(source),123)==0);
  assert(wa_load_count()==1);
  uint32_t a=request(app),b=request(app);
  assert(wa_pending()==2);assert(wa_release(app)==-1);
  assert(lw_complete(b,lw_sequence(b),1,200,"B",1)==4);
  assert(lw_size(b)==3&&!memcmp(lw_data(b),"B:2",3));assert(lw_release(b)==0);
  assert(lw_complete(a,lw_sequence(a),1,200,"A",1)==4);
  assert(lw_size(a)==3&&!memcmp(lw_data(a),"A:1",3));assert(lw_release(a)==0);
  for(int i=0;i<1000;++i){a=request(app);uint32_t seq=lw_sequence(a);assert(lw_release(a)==0);assert(lw_complete(a,seq,1,200,"late",4)==-1);}
  assert(wa_pending()==0);assert(lw_active()==0&&lw_bytes()==0);
  assert(wa_collect(app)==0);assert(wa_bytes()<100000);assert(wa_bytes()>0);
  assert(wa_release(app)==0);assert(wa_bytes()==0&&wa_app_count()==0);
  uint32_t gone=lw_open();assert(wa_start(gone,app,"GET",3,"x",1,"",0)==5);assert(lw_release(gone)==0);
  puts("native resident lifecycle: PASS (load once, overlap, shared globals, exact ownership, stale IDs, cancellation, collection, eviction)");
  return 0;
}
