#!/usr/bin/env python3
"""ctypes test driver for the public native API, not a Python HTTP backend."""
import ctypes as C
from pathlib import Path
class Native:
    def __init__(self,path):
        self.lib=C.CDLL(str(Path(path).resolve()),mode=C.RTLD_LOCAL)
        p=C.c_void_p;u=C.c_uint32;s=C.c_size_t;i=C.c_int;t=C.c_char_p
        signatures={'np_new':([s,i],p),'np_load':([p,t,s,u],i),'np_start':([p,t,s,t,s,t,s],u),
          'np_complete':([p,u,u,i,i,t,s],i),'np_close':([p,u],i),'np_delete':([p],i),
          'np_state':([p,u],i),'np_kind':([p,u],i),'np_status':([p,u],i),'np_sequence':([p,u],u),
          'np_active':([p],u),'np_traces':([p],u),'np_data':([p,u],p),'np_error':([p],t),'np_version':([],t),
          'np_size':([p,u],s),'np_bytes':([p],s),'np_collect':([p],i)}
        for name,(args,result) in signatures.items():
            f=getattr(self.lib,name);f.argtypes=args;f.restype=result
    def app(self,source,jit=0):return App(self.lib,source,jit)
class App:
    def __init__(self,lib,source,jit):
        self.e=lib;self.ptr=lib.np_new(2097152,jit)
        if not self.ptr:raise RuntimeError('app allocation')
        if isinstance(source,str):source=source.encode()
        if lib.np_load(self.ptr,source,len(source),12345):
            message=lib.np_error(self.ptr).decode(errors='replace');lib.np_delete(self.ptr);self.ptr=None;raise RuntimeError(message)
    def start(self,method='GET',url='http://worker.invalid/hello',body=b''):
        vals=[x.encode() if isinstance(x,str) else x for x in (method,url,body)]
        return self.e.np_start(self.ptr,*[v for b in vals for v in (b,len(b))])
    def info(self,id):
        e=self.e;p=self.ptr;n=e.np_size(p,id)
        return dict(state=e.np_state(p,id),kind=e.np_kind(p,id),seq=e.np_sequence(p,id),status=e.np_status(p,id),body=C.string_at(e.np_data(p,id),n))
    def complete(self,id,seq,ok,status,body):
        if isinstance(body,str):body=body.encode()
        return self.e.np_complete(self.ptr,id,seq,ok,status,body,len(body))
    def close(self,id):return self.e.np_close(self.ptr,id)
    def delete(self):
        if self.ptr:
            if self.e.np_delete(self.ptr):raise RuntimeError('live app on deletion')
            self.ptr=None
