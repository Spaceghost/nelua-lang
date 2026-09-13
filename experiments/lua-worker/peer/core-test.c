/* SPDX-License-Identifier: MIT */
#include "api.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static np_app *make(const char *src) {
  np_app *a=np_new(2097152,0);assert(a);
  int r=np_load(a,src,strlen(src),12345);if(r)fprintf(stderr,"load: %s\n",np_error(a));assert(r==0);return a;
}
static uint32_t start(np_app *a){uint32_t id=np_start(a,"GET",3,"/get",4,"",0);assert(id);return id;}
static void body(np_app *a,uint32_t id,const char *expect){assert(np_state(a,id)==4);assert(np_size(a,id)==strlen(expect));assert(!memcmp(np_data(a,id),expect,strlen(expect)));assert(np_close(a,id)==0);}
int main(void) {
  const char *src="local h=require'worker.http';local n=0;return{fetch=function(r,e,c)n=n+1;return h.text(e.CONFIG:get('greeting')..':'..n)end}";
  np_app *a=make(src),*b=make(src);uint32_t x=start(a),y=start(a),z=start(b);
  assert(np_state(a,x)==3 && np_state(a,y)==3 && np_state(b,z)==3);
  assert(np_delete(a)==-1);assert(np_complete(a,x,99,1,200,"bad",3)==-1);
  assert(np_complete(b,z,1,1,200,"other",5)==4);body(b,z,"other:1");
  assert(np_complete(a,y,1,1,200,"second",6)==4);body(a,y,"second:2");
  assert(np_complete(a,x,1,1,200,"first",5)==4);body(a,x,"first:2");
  x=start(a);assert(np_close(a,x)==0);y=start(a);assert(x!=y);assert(np_complete(a,x,1,1,200,"late",4)==-1);assert(np_close(a,y)==0);
  assert(np_active(a)==0 && np_active(b)==0);assert(np_delete(a)==0);assert(np_delete(b)==0);
  a=make("return{fetch=function()local function broken()error('trace-needle')end;broken()end}");x=start(a);assert(np_state(a,x)==5);fwrite(np_data(a,x),1,np_size(a,x),stdout);puts("");np_close(a,x);assert(np_delete(a)==0);
  a=make("return{fetch=function()while true do end end}");x=start(a);assert(np_state(a,x)==5);np_close(a,x);assert(np_delete(a)==0);
  a=make("return{fetch=function()return{status=200,body=string.rep('x',4000000)}end}");x=start(a);assert(np_state(a,x)==5);np_close(a,x);assert(np_delete(a)==0);
  a=np_new(2097152,0);assert(np_load(a,"\033Lua",4,123)<0);assert(np_delete(a)==0);
  a=np_new(2097152,0);const char *loop="while true do end";assert(np_load(a,loop,strlen(loop),123)<0);assert(np_delete(a)==0);
  printf("PASS %s: multi-context, overlap, stale IDs, cancellation, traceback, instruction and memory bounds, text-only\n",np_version());
}
