// CPU-only synthetic callbacks. No Windows/D3D12 APIs or native DLL loading.
#include "thread_handoff_fixture_model.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <exception>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
using namespace beamrt_fixture;

static void need(bool value,const char* message){if(!value)throw std::runtime_error(message);}
class Gate {
    std::mutex mutex;std::condition_variable condition;bool signalled=false;
public:
    void open(){std::lock_guard<std::mutex> guard(mutex);signalled=true;condition.notify_all();}
    void wait(){std::unique_lock<std::mutex> guard(mutex);
        need(condition.wait_for(guard,std::chrono::seconds(5),[&]{return signalled;}),"fixture coordination timeout");}
};
class Worker {
    std::exception_ptr error;std::thread thread;
public:
    explicit Worker(std::function<void()> body):thread([this,body]{try{body();}catch(...){error=std::current_exception();}}){}
    ~Worker(){if(thread.joinable())thread.join();}
    void join(){thread.join();if(error)std::rethrow_exception(error);}
};
static void absent(IntervalModel& model){Receipt out{9,9,9,9,9};need(!model.read(out),"uncertain observation accepted");
    need(!out.list && !out.generation && !out.serial && !out.caller && !out.value,"refused output not cleared");}
static Token entered(IntervalModel& model,uint64_t list,uint64_t caller){auto t=model.enter(list,caller);
    need(t.ticket && t.slot<tokenLimit,"fixture entry refused unexpectedly");return t;}
static bool drain(IntervalModel& model,const Token& t,uint64_t caller,uint32_t value){
    // A refused observation never suppresses this fixture's stand-in forward.
    (void)model.forwarding(t,caller);(void)model.nativeReturned(t,caller);
    (void)model.metadataUpdated(t,caller,value);return model.exit(t,caller);}
static Receipt completed(IntervalModel& model,uint64_t list,uint64_t caller,uint32_t value){
    const auto t=entered(model,list,caller);need(model.forwarding(t,caller),"clean forward refused");
    need(model.nativeReturned(t,caller),"clean native return refused");need(model.metadataUpdated(t,caller,value),"clean metadata refused");
    absent(model);need(model.exit(t,caller),"complete fixture callback refused");Receipt out{};need(model.read(out),"complete fixture receipt unavailable");return out;}

static void sameThread(){IntervalModel model;const auto a=completed(model,1,1,41),b=completed(model,1,1,42);
    need(b.serial==a.serial+1 && b.value==42 && !model.status(1).threadChanges && !model.status(1).callbackOverlaps,"same-thread ordering lost");}
static void sequentialHandoff(){IntervalModel model;(void)completed(model,1,1,41);
    Worker worker([&]{const auto b=completed(model,1,2,42);need(b.caller==2 && b.value==42,"worker receipt mismatch");});worker.join();
    const auto c=completed(model,1,1,43);const auto s=model.status(1);
    need(c.value==43 && c.serial==3 && s.threadChanges==2 && !s.callbackOverlaps && !s.forwardingSpanOverlaps,
        "sequential A-B-A handoff misclassified");}
static void overlappingForwarding(){IntervalModel model;Gate inside,release;std::atomic<unsigned> forwards{0};
    Worker worker([&]{const auto a=entered(model,1,1);need(model.forwarding(a,1),"first forward refused");++forwards;inside.open();release.wait();
        (void)model.nativeReturned(a,1);(void)model.metadataUpdated(a,1,41);need(!model.exit(a,1),"overlap first receipt accepted");});
    inside.wait();const auto b=entered(model,1,2);(void)model.forwarding(b,2);++forwards;
    (void)model.nativeReturned(b,2);(void)model.metadataUpdated(b,2,42);need(!model.exit(b,2),"overlap second receipt accepted");
    absent(model);release.open();worker.join();const auto s=model.status(1);
    need(forwards==2 && !s.active && s.uncertain && s.callbackOverlaps==1 && s.forwardingSpanOverlaps==1,"overlap evidence/forwarding lost");absent(model);}
static void postNativeGap(){IntervalModel model;const auto a=entered(model,1,1);
    need(model.forwarding(a,1) && model.nativeReturned(a,1),"first stand-in return failed");
    Worker worker([&]{const auto b=entered(model,1,2);need(!drain(model,b,2,42),"metadata-gap overlap accepted");});worker.join();
    (void)model.metadataUpdated(a,1,41);need(!model.exit(a,1),"metadata-gap source accepted");const auto s=model.status(1);
    need(s.callbackOverlaps==1 && !s.forwardingSpanOverlaps && s.uncertain && !s.active,"callback gap confused with forwarding-span overlap");absent(model);}
static void independentLists(){IntervalModel model;Gate inside,release;
    Worker worker([&]{const auto a=entered(model,1,1);need(model.forwarding(a,1),"list A forward refused");inside.open();release.wait();
        need(model.nativeReturned(a,1) && model.metadataUpdated(a,1,41) && model.exit(a,1),"independent list A refused");});
    inside.wait();const auto b=entered(model,2,2);need(model.forwarding(b,2),"parallel different-list forward refused");
    need(model.status(1).active==1 && model.status(2).active==1,"fixture did not overlap different lists");
    need(model.nativeReturned(b,2) && model.metadataUpdated(b,2,42) && model.exit(b,2),"independent list B refused");
    Receipt out{};need(model.read(out) && out.list==2 && out.value==42,"active unrelated list blocked receipt");
    release.open();worker.join();need(!model.status(1).callbackOverlaps && !model.status(2).callbackOverlaps,"global traffic mistaken for list overlap");}
static void reentry(){IntervalModel model;const auto a=entered(model,1,1);need(model.forwarding(a,1),"first forward refused");
    const auto b=entered(model,1,1);need(!drain(model,b,1,42),"reentrant receipt accepted");
    (void)model.nativeReturned(a,1);(void)model.metadataUpdated(a,1,41);need(!model.exit(a,1),"reentrant source accepted");
    need(model.status(1).reentries==1 && !model.status(1).active,"reentry not distinguished/drained");absent(model);}
static void lifecycleCrossing(){for(bool reset:{false,true}){IntervalModel model;const auto t=entered(model,1,1);
    need(model.forwarding(t,1),"first forward refused");need(!(reset?model.reset(1):model.close(1)),"active lifecycle boundary accepted");
    need(model.status(1).generation==1 && model.status(1).recording,"refused lifecycle changed epoch");
    (void)model.nativeReturned(t,1);(void)model.metadataUpdated(t,1,41);need(!model.exit(t,1),"crossing lifecycle receipt accepted");absent(model);
    need(model.close(1) && model.reset(1),"quiescent fixture lifecycle did not recover");
    const auto out=completed(model,1,2,42);need(out.generation==2,"new epoch generation lost");}}
static void staleGeneration(){IntervalModel model;const auto old=entered(model,1,1);need(drain(model,old,1,41),"clean drain failed");
    need(model.close(1) && model.reset(1),"fixture reset failed");const auto current=entered(model,1,2);
    need(!model.exit(old,1),"stale generation token accepted");need(!model.isHealthy(),"stale token did not fail closed");
    need(!drain(model,current,2,42) && !model.status(1).active,"stale-token session published or failed to drain");absent(model);}
static void tokenErrors(){for(unsigned mode=0;mode<4;++mode){IntervalModel model;const auto t=entered(model,1,1);auto bad=t;
    if(mode==0)bad.ticket++;if(mode==1)bad.generation++;if(mode==2)bad.list=2;if(mode==3)bad.slot=invalidSlot;
    need(!model.exit(bad,1),"forged token accepted");need(!model.isHealthy(),"unknown token did not fail globally closed");
    need(!drain(model,t,1,41) && !model.status(1).active,"valid cleanup after bad token failed");absent(model);}}
static void duplicateExit(){IntervalModel model;const auto t=entered(model,1,1);need(drain(model,t,1,41),"clean drain failed");
    need(!model.exit(t,1),"duplicate exit accepted");absent(model);}
static void wrongCaller(){IntervalModel model;const auto t=entered(model,1,1);
    need(!model.forwarding(t,2),"foreign caller used another callback token");need(!model.isHealthy(),"foreign token use not fail closed");
    need(!drain(model,t,1,41) && !model.status(1).active,"foreign-token cleanup failed");absent(model);}
static void missingPhases(){for(unsigned mode=0;mode<4;++mode){IntervalModel model;const auto t=entered(model,1,1);
    if(mode!=0)(void)model.forwarding(t,1);if(mode>=2)(void)model.nativeReturned(t,1);
    if(mode==3){need(model.metadataUpdated(t,1,41),"clean metadata refused");absent(model);
        need(!model.close(1) && !model.reset(1),"missing exit allowed lifecycle boundary");}
    need(!model.exit(t,1),"missing phase/lost exit accepted");need(!model.status(1).active,"invalid callback failed to drain");absent(model);}
    IntervalModel model;need(!model.nativeReturned({},1) && !model.isHealthy(),"missing entry accepted");absent(model);}
static void reorderedPhases(){IntervalModel model;const auto t=entered(model,1,1);
    need(!model.metadataUpdated(t,1,41),"metadata before forwarding accepted");need(!drain(model,t,1,41),"phase error later authorized");absent(model);}
static void offAndLate(){IntervalModel model;const auto t=entered(model,1,1);need(model.forwarding(t,1),"first forward refused");model.disable();
    need(!model.nativeReturned(t,1) && !model.metadataUpdated(t,1,41) && !model.exit(t,1),"OFF published active callback");
    need(!model.status(1).active && !model.enter(1,2).ticket,"OFF admitted late callback");absent(model);}
static void boundsAndCapacity(){IntervalModel model;std::array<Token,tokenLimit> tokens{};
    for(auto& t:tokens)t=entered(model,1,1);need(!model.enter(1,1).ticket,"token pressure exceeded fixed capacity");
    for(const auto& t:tokens)need(!drain(model,t,1,41),"pressure/overlap receipt accepted");
    need(!model.status(1).active && model.isHealthy(),"known-list capacity error failed to drain/isolate");absent(model);
    for(uint64_t id:{0ull,uint64_t(listLimit)+1}){IntervalModel bad;need(!bad.enter(id,1).ticket && !bad.isHealthy(),"unknown list accepted");absent(bad);}
    IntervalModel bad;need(!bad.enter(1,0).ticket && !bad.isHealthy(),"zero caller accepted");absent(bad);}
static void counterCeilings(){for(unsigned mode=0;mode<4;++mode){Limits limits;
    if(mode==0)limits.tickets=1;if(mode==1)limits.generations=1;if(mode==2)limits.publications=1;if(mode==3)limits.counters=1;
    IntervalModel model(limits);(void)completed(model,1,1,41);
    if(mode==0)need(!model.enter(1,1).ticket && !model.isHealthy(),"ticket ceiling wrapped");
    if(mode==1){need(model.close(1) && !model.reset(1) && model.status(1).generation==1,"generation ceiling wrapped");}
    if(mode==2){const auto t=entered(model,1,1);need(!drain(model,t,1,42) && !model.isHealthy(),"publication ceiling wrapped");}
    if(mode==3){(void)completed(model,1,2,42);const auto t=entered(model,1,1);need(!drain(model,t,1,43) && !model.isHealthy(),"thread-change ceiling wrapped");}
    absent(model);}}
static void receiptIsolation(){IntervalModel model;const auto source=completed(model,1,1,41);
    const auto a=entered(model,2,1),b=entered(model,2,2);need(!drain(model,b,2,42) && !drain(model,a,1,43),"unrelated overlap accepted");
    Receipt retained{};need(model.read(retained) && retained.list==source.list && retained.serial==source.serial && retained.value==source.value,
        "unrelated uncertainty erased source receipt");
    const auto c=entered(model,1,1),d=entered(model,1,2);need(!drain(model,d,2,44) && !drain(model,c,1,45),"source overlap accepted");absent(model);}

int main(int argc,char**){if(argc!=1){std::cerr<<"No arguments accepted; this fixture cannot select an external process or DLL.\n";return 2;}
    const std::pair<const char*,void(*)()> cases[]={
        {"same-thread",sameThread},{"sequential-A-B-A",sequentialHandoff},{"overlapping-forwarding",overlappingForwarding},
        {"post-native-metadata-gap",postNativeGap},{"different-lists-concurrent",independentLists},{"same-thread-reentry",reentry},
        {"Close-Reset-crossing",lifecycleCrossing},{"stale-generation",staleGeneration},{"forged-token",tokenErrors},
        {"duplicate-exit",duplicateExit},{"wrong-caller",wrongCaller},{"missing-entry-phase-exit",missingPhases},
        {"reordered-phases",reorderedPhases},{"OFF-and-late",offAndLate},{"bounds-and-capacity",boundsAndCapacity},
        {"counter-ceilings",counterCeilings},{"receipt-source-isolation",receiptIsolation}};
    static_assert(sizeof(cases)/sizeof(cases[0])==17,"update scenario inventory and contracts together");
    unsigned passed=0;for(const auto& c:cases){try{c.second();++passed;std::cout<<"PASS: "<<c.first<<'\n';}
        catch(const std::exception& e){std::cerr<<"FAIL: "<<c.first<<": "<<e.what()<<'\n';return 1;}}
    std::cout<<"PASS: "<<passed<<"/17 CPU-only callback interval cases; no GPU/driver calls, game launch, DLL loading or observer-policy change.\n";return 0;
}
