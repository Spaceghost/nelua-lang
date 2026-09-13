// SPDX-License-Identifier: MIT
// Native HTTP service below JSG: no V8 values, JS callbacks or Wasm instance.
#include "api.h"
#include <kj/async-io.h>
#include <kj/compat/http.h>
#include <kj/debug.h>
#include <kj/timer.h>
#include <sys/resource.h>
#include <sys/random.h>
#include <fstream>
#include <iostream>
#include <string>
#include <cstring>
#include <unistd.h>
namespace {
constexpr size_t BODY_LIMIT=65536;
struct Reply { unsigned status; kj::Array<kj::byte> body; bool transportOk=true; };
kj::Array<kj::byte> copyBytes(const char *p,size_t n) {
  auto b=kj::heapArray<kj::byte>(n);if(n)memcpy(b.begin(),p,n);return b;
}
std::string encodeKey(const std::string& key) {
  static const char hex[]="0123456789ABCDEF";std::string s="/";
  for(unsigned char c:key) {
    if((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c=='~')s.push_back(c);
    else{s.push_back('%');s.push_back(hex[c>>4]);s.push_back(hex[c&15]);}
  }
  return s;
}
class Peer final: public kj::HttpService {
public:
  Peer(np_app *app,kj::Timer& timer,const kj::HttpHeaderTable& table,kj::HttpClient& config,kj::HttpClient& upstream)
    :app(app),timer(timer),table(table),config(config),upstream(upstream){}
  ~Peer(){KJ_ASSERT(admitted==0);KJ_ASSERT(np_delete(app)==0);}
  kj::Promise<void> request(kj::HttpMethod method,kj::StringPtr url,const kj::HttpHeaders&,
                           kj::AsyncInputStream& input,Response& output) override {
    // Local diagnostic endpoint. Listener is restricted to loopback/Unix sockets.
    if(url=="/_peer/stats") {
      auto s=kj::str("{\"active\":",np_active(app),",\"admitted\":",admitted,",\"luaBytes\":",np_bytes(app),
        ",\"hostOperationsTotal\":",operations,",\"traces\":",np_traces(app),",\"requests\":",completed,"}");
      return send(output,Reply{200,copyBytes(s.cStr(),s.size())},false);
    }
    if(admitted>=8)return send(output,Reply{503,copyBytes("capacity",8)},false);
    auto call=kj::heap<Call>(*this,method,kj::str(url));auto& c=*call;
    auto task=input.readAllBytes(BODY_LIMIT).then([this,&c](kj::Array<kj::byte> body)->kj::Promise<Reply>{
      auto method=kj::str(c.method);
      auto canonical=c.url.startsWith("/")?kj::str("http://worker.invalid",c.url):kj::str(c.url);
      c.id=np_start(app,method.cStr(),method.size(),canonical.cStr(),canonical.size(),
                    reinterpret_cast<const char*>(body.begin()),body.size());
      KJ_REQUIRE(c.id!=0,"native invocation admission failed");return drive(c);
    });
    // Dropping the pending promise cancels native I/O before Call destruction.
    auto bounded=timer.timeoutAfter(2500*kj::MILLISECONDS,kj::mv(task))
      .catch_([](kj::Exception&& e)->Reply {
        std::string s(e.getDescription().cStr());
        unsigned status=(s.find("timed out")!=std::string::npos || s.find("timeout")!=std::string::npos)?504:
          (s.find("limit")!=std::string::npos || s.find("too large")!=std::string::npos)?413:502;
        return {status,copyBytes("native worker failed",20)};
      });
    return bounded.then([this,&c,&output](Reply reply)->kj::Promise<void>{
      if(c.id){KJ_REQUIRE(np_close(app,c.id)==0,"request cleanup failed");c.id=0;}
      ++completed;return send(output,kj::mv(reply),c.method==kj::HttpMethod::HEAD);
    }).attach(kj::mv(call));
  }
private:
  struct Call {
    Peer& owner;kj::HttpMethod method;kj::String url;uint32_t id=0;
    kj::String operationUrl;kj::HttpHeaders operationHeaders;
    Call(Peer& owner,kj::HttpMethod method,kj::String url):owner(owner),method(method),url(kj::mv(url)),operationHeaders(owner.table){++owner.admitted;}
    ~Call(){if(id)KJ_ASSERT(np_close(owner.app,id)==0);--owner.admitted;}
  };
  np_app *app;kj::Timer& timer;const kj::HttpHeaderTable& table;
  kj::HttpClient& config;kj::HttpClient& upstream;
  uint32_t admitted=0;uint64_t operations=0,completed=0;
  kj::Promise<Reply> drive(Call& c) {
    int state=np_state(app,c.id);
    if(state==4)return Reply{(unsigned)np_status(app,c.id),copyBytes(np_data(app,c.id),np_size(app,c.id))};
    if(state==5) {
      std::cerr.write(np_data(app,c.id),np_size(app,c.id))<<'\n';
      return Reply{500,copyBytes("Lua worker failed",17)};
    }
    KJ_REQUIRE(state==3,"invalid native operation state");
    auto seq=np_sequence(app,c.id);int kind=np_kind(app,c.id);
    std::string argument(np_data(app,c.id),np_size(app,c.id));++operations;
    if(kind==3) {
      std::cerr<<"lua log: "<<argument<<'\n';
      KJ_REQUIRE(np_complete(app,c.id,seq,1,200,"",0)>=3,"log completion rejected");return drive(c);
    }
    auto path=kind==1?encodeKey(argument):argument;
    c.operationUrl=kj::str(path);c.operationHeaders.clear();c.operationHeaders.set(kj::HttpHeaderId::HOST,"bound.invalid");
    // Fixed-address clients, no ambient DNS, redirect following or generic bridge.
    auto req=(kind==1?config:upstream).request(kj::HttpMethod::GET,c.operationUrl,c.operationHeaders,(uint64_t)0);
    req.body=nullptr;
    auto result=req.response.then([](kj::HttpClient::Response response)->kj::Promise<Reply>{
      unsigned status=response.statusCode;auto body=kj::mv(response.body);
      return body->readAllBytes(BODY_LIMIT).then([status](kj::Array<kj::byte> bytes)->Reply{return {status,kj::mv(bytes)};}).attach(kj::mv(body));
    }).catch_([](kj::Exception&&)->Reply{return {502,copyBytes("host operation failed (HOST_ERROR)",33),false};});
    return result.then([this,&c,seq,kind](Reply result)->kj::Promise<Reply>{
      int ok=result.transportOk && (kind!=1 || result.status==200 || result.status==404);
      const char *data=reinterpret_cast<const char*>(result.body.begin());size_t size=result.body.size();
      if(!ok){data="host operation failed (HOST_ERROR)";size=strlen(data);}
      KJ_REQUIRE(np_complete(app,c.id,seq,ok,result.status,data,size)>=3,"stale native completion");return drive(c);
    });
  }
  kj::Promise<void> send(Response& output,Reply reply,bool head) {
    kj::HttpHeaders headers(table);headers.set(kj::HttpHeaderId::CONTENT_TYPE,"text/plain; charset=utf-8");
    bool noBody=head || reply.status==204 || reply.status==205 || reply.status==304;
    auto body=kj::mv(reply.body);auto stream=output.send(reply.status,"Worker",headers,(uint64_t)(noBody?0:body.size()));
    if(noBody)return kj::READY_NOW;
    auto write=stream->write(body.begin(),body.size());return write.attach(kj::mv(body),kj::mv(stream));
  }
};
}
int main(int argc,char **argv) {
  try {
    if(argc!=5 && argc!=6){std::cerr<<"usage: peer-host SOURCE LISTEN CONFIG_ADDRESS UPSTREAM_ADDRESS [trusted-jit]\n";return 2;}
    std::string listen=argv[2];
    if(listen.rfind("127.0.0.1:",0)!=0 && listen.rfind("unix:/",0)!=0){std::cerr<<"listener must be loopback or a filesystem Unix socket\n";return 2;}
    bool jit=argc==6 && std::string(argv[5])=="trusted-jit";if(argc==6 && !jit)return 2;
    rlimit core{0,0};KJ_REQUIRE(setrlimit(RLIMIT_CORE,&core)==0,"core limit");
    rlimit fds{128,128};KJ_REQUIRE(setrlimit(RLIMIT_NOFILE,&fds)==0,"fd limit");
    rlimit cpu{300,301};KJ_REQUIRE(setrlimit(RLIMIT_CPU,&cpu)==0,"CPU limit");
#ifndef __SANITIZE_ADDRESS__
    rlimit memory{512ULL*1024*1024,512ULL*1024*1024};KJ_REQUIRE(setrlimit(RLIMIT_AS,&memory)==0,"address-space limit");
#endif
    // External wall-clock supervisor remains mandatory for hostile/unreviewed code.
    std::ifstream file(argv[1],std::ios::binary);KJ_REQUIRE(file.good(),"source unavailable");
    char input[BODY_LIMIT+1];file.read(input,sizeof(input));std::string source(input,file.gcount());KJ_REQUIRE(source.size()<=BODY_LIMIT,"source limit");
    np_app *app=np_new(2097152,jit);KJ_REQUIRE(app!=nullptr,"application allocation failed");
    uint32_t seed;KJ_REQUIRE(getrandom(&seed,sizeof(seed),0)==sizeof(seed),"entropy unavailable");
    if(np_load(app,source.data(),source.size(),seed)){std::cerr<<np_error(app)<<'\n';np_delete(app);return 1;}
    auto io=kj::setupAsyncIo();auto& timer=io.provider->getTimer();auto& network=io.provider->getNetwork();kj::HttpHeaderTable table;
    auto cfgAddress=network.parseAddress(argv[3]).wait(io.waitScope);auto upAddress=network.parseAddress(argv[4]).wait(io.waitScope);
    auto cfg=kj::newHttpClient(timer,table,*cfgAddress);auto up=kj::newHttpClient(timer,table,*upAddress);
    Peer service(app,timer,table,*cfg,*up);
    auto address=network.parseAddress(argv[2]).wait(io.waitScope);auto listener=address->listen();kj::HttpServer server(timer,table,service);
    std::cout<<"READY "<<np_version()<<" jit="<<jit<<std::endl;
    server.listenHttp(*listener).wait(io.waitScope);return 0;
  } catch(const kj::Exception& e){std::cerr<<e.getDescription().cStr()<<'\n';return 1;}
}
