#define BEAMRT_BINDING_BUILD
#ifdef BEAMRT_BINDING_EMBEDDED
#define BEAMRT_PIPELINE_AUDIT_BUILD
#include "binding_handoff.h"
#endif
#include "gi_bindings.h"
#include "gi_root_layout.h"
#include "pipeline_audit.h"
#include "binding_validation.h"
#ifdef BEAMRT_RESOURCE_EMBEDDED
#include "resource_handoff.h"
namespace {
struct ResourceDrawScope {
    BeamRTResourceDrawToken token{};
    ResourceDrawScope(){BeamRT_ResourcesBeginDraw(&token,sizeof(token));}
    ~ResourceDrawScope(){const auto saved=GetLastError();BeamRT_ResourcesCancelDraw(&token,sizeof(token));SetLastError(saved);}
};
} // namespace: binding-only draw scope
#else
struct BeamRTResourceDrawToken;
#endif
#include <wrl/client.h>
#include <atomic>
#include <array>
#include <memory>
#include <mutex>
#include <unordered_set>
#include <cstring>
#include <cmath>
using Microsoft::WRL::ComPtr;
extern "C" void** beamrtBindingSDKSlot(void*,unsigned);
// Context/Slot/Tag are private to this translation unit, including co-linked
// startup builds. Keep public headers and exported C APIs outside this scope.
namespace {
static constexpr GUID tagGuid={0x4a98231a,0xfdaa,0x4514,{0xac,0xe2,0xc9,0x22,0x2d,0x14,0x41,0xbf}};
struct Slot {void** address=nullptr;void* original=nullptr;unsigned method=0;bool attached=false;HMODULE table=nullptr,code=nullptr;
    ~Slot(){if(code)FreeLibrary(code);if(table)FreeLibrary(table);}};
struct State {
#ifdef BEAMRT_RESOURCE_EMBEDDED
    BeamRTResourceCheckpoint outputCheckpoint{};
#endif
    ComPtr<ID3D12PipelineState> pipeline;ComPtr<ID3D12RootSignature> root;
    BeamRTBindingHeap srv{},sampler{};uint64_t values[64]{};uint8_t kinds[64]{};
    D3D12_VIEWPORT viewports[16]{};D3D12_RECT scissors[16]{};uint64_t rt[8]{},depth=0;
    uint32_t viewportCount=0,scissorCount=0,rtCount=0,thread=0,resetThread=0,firstRecordingThread=0;
    uint64_t id=0,generation=1;bool recording=true,complete=true,threadConflict=false;
};
struct Context;
struct DecoderLease {HMODULE module=nullptr;~DecoderLease(){if(module)FreeLibrary(module);}};
struct __declspec(uuid("F21B13C3-BC7A-4B88-B7CA-E78D301F6DED")) TagInterface:IUnknown {
    virtual State* STDMETHODCALLTYPE state(Context*)=0;
};
struct Context {
    Slot slots[128];std::atomic<unsigned> slotCount{0};
    DecoderLease decoderLease;BeamRTRootDecoder decoder=nullptr;
    ComPtr<ID3D12Device> device;ComPtr<ID3D12Device4> device4;ComPtr<IUnknown> identity;
    ComPtr<ID3D12RootSignature> targetRoot;ComPtr<ID3D12PipelineState> targetPipeline;BeamRTGIRootLayout layout;
    BeamRTBindingStatus status{};BeamRTBindingSnapshot latest{};
    BeamRTBindingThreadDiagnostics diagnostics{};
    std::mutex registryLock;std::unordered_set<IUnknown*> tags;std::atomic<uint32_t> live{0};uint64_t nextId=0;
};
class Tag final:public TagInterface {
    volatile LONG refs=1;Context* owner;State value;
public:
    Tag(Context& c,uint64_t id,ID3D12PipelineState* pipeline,bool recording):owner(&c){
        value.id=id;value.pipeline=pipeline;value.recording=recording;
        std::lock_guard<std::mutex> lock(c.registryLock);c.tags.insert(static_cast<TagInterface*>(this));c.live.fetch_add(1);
    }
    ~Tag(){std::lock_guard<std::mutex> lock(owner->registryLock);owner->tags.erase(static_cast<TagInterface*>(this));owner->live.fetch_sub(1);}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out)override{if(!out)return E_POINTER;*out=nullptr;
        if(iid!=__uuidof(IUnknown) && iid!=__uuidof(TagInterface))return E_NOINTERFACE;*out=static_cast<TagInterface*>(this);AddRef();return S_OK;}
    ULONG STDMETHODCALLTYPE AddRef()override{return static_cast<ULONG>(InterlockedIncrement(&refs));}
    ULONG STDMETHODCALLTYPE Release()override{const auto n=InterlockedDecrement(&refs);if(!n)delete this;return static_cast<ULONG>(n);}
    State* STDMETHODCALLTYPE state(Context* c)override{return owner==c?&value:nullptr;}
};
static PVOID volatile published=nullptr;static SRWLOCK lock=SRWLOCK_INIT;
struct Guard {Guard(){AcquireSRWLockExclusive(&lock);}~Guard(){ReleaseSRWLockExclusive(&lock);}};
struct LastError {DWORD value;~LastError(){SetLastError(value);}};
static Context* context(){return static_cast<Context*>(InterlockedCompareExchangePointer(&published,nullptr,nullptr));}
static void fail(Context& c,uint32_t reason,HRESULT hr){if(!c.status.failureReason){c.status.failureReason=reason;c.status.failureResult=hr;}
    c.status.healthy=0;c.status.snapshotAvailable=0;}
static bool owns(Context& c,IUnknown* object){ComPtr<IUnknown> id;return object && SUCCEEDED(object->QueryInterface(IID_PPV_ARGS(&id))) && id.Get()==c.identity.Get();}
static bool child(Context& c,ID3D12DeviceChild* object){ComPtr<ID3D12Device> d;return object && SUCCEEDED(object->GetDevice(IID_PPV_ARGS(&d))) && owns(c,d.Get());}
static bool identical(IUnknown* a,IUnknown* b){if(a==b)return true;if(!a || !b)return false;ComPtr<IUnknown> x,y;
    return SUCCEEDED(a->QueryInterface(IID_PPV_ARGS(&x))) && SUCCEEDED(b->QueryInterface(IID_PPV_ARGS(&y))) && x.Get()==y.Get();}
static void publishProgress(Context& c){c.status.liveCommands=c.live.load();
#ifdef BEAMRT_BINDING_EMBEDDED
    BeamRT_BindingPublishProgress(c.status);
#endif
}
template<class F>static void observed(Context& c,F f){try{Guard g;if(c.status.enabled && c.status.healthy){f();publishProgress(c);}}
    catch(const std::bad_alloc&){Guard g;fail(c,1,E_OUTOFMEMORY);publishProgress(c);}catch(...){Guard g;fail(c,2,E_FAIL);publishProgress(c);}}
static ComPtr<TagInterface> tag(Context& c,ID3D12GraphicsCommandList* list){ComPtr<TagInterface> result;
    if(!child(c,list))return result;UINT size=0;const auto hr=list->GetPrivateData(tagGuid,&size,nullptr);
    if(hr==DXGI_ERROR_NOT_FOUND){++c.status.untracked;return result;}
    if((FAILED(hr) && hr!=DXGI_ERROR_MORE_DATA) || size!=sizeof(IUnknown*)){fail(c,3,E_INVALIDARG);return result;}
    IUnknown* raw=nullptr;const auto got=list->GetPrivateData(tagGuid,&size,&raw);
    if(FAILED(got) || size!=sizeof(raw) || !raw){fail(c,3,E_INVALIDARG);return result;}
    {std::lock_guard<std::mutex> guard(c.registryLock);if(!c.tags.count(raw)){fail(c,3,E_INVALIDARG);return result;}}
    ComPtr<IUnknown> owned;owned.Attach(raw);if(FAILED(owned.As(&result)) || !result->state(&c)){fail(c,3,E_INVALIDARG);result.Reset();}return result;
}
static void rejectedThread(Context& c,State& s,DWORD tid,unsigned method){
    if(method>=beamrtBindingMethodCount || c.status.threadRejected==UINT64_MAX){fail(c,4,E_FAIL);return;}
    auto& d=c.diagnostics;++c.status.threadRejected;d.threadRejected=c.status.threadRejected;++d.byMethod[method];
    if(c.status.targetReady)++d.afterTarget;else ++d.beforeTarget;
    if(s.threadConflict){++d.repeatedCalls;return;}
    s.threadConflict=true;++d.firstEpochConflicts;
    if(s.resetThread && !s.firstRecordingThread)++d.resetOwnerOnlyConflicts;
    if(d.sampleCount==beamrtBindingThreadSampleLimit){++d.droppedEpochSamples;return;}
    auto& sample=d.samples[d.sampleCount++];sample={s.id,s.generation,method,s.thread,tid,s.resetThread,s.firstRecordingThread,
        c.status.targetReady,identical(s.pipeline.Get(),c.targetPipeline.Get()) && c.status.targetReady?1u:0u,
        s.complete?1u:0u,c.status.snapshotAvailable && c.latest.commandId==s.id?1u:0u,0};
#ifdef BEAMRT_BINDING_EMBEDDED
    BeamRT_BindingPublishThreadSample(sample);
#endif
}
template<class F>static void command(ID3D12GraphicsCommandList* list,unsigned method,F f){auto c=context();observed(*c,[&]{auto t=tag(*c,list);if(!t)return;
    auto& s=*t->state(c);if(!s.recording){++c->status.unsupported;return;}const auto tid=GetCurrentThreadId();
    if(s.thread && s.thread!=tid){rejectedThread(*c,s,tid,method);s.complete=false;
        // Reject this list's epoch, not an accepted receipt from another list.
        // Ownership/one-thread-per-generation rules themselves are unchanged.
        if(c->latest.commandId==s.id)c->status.snapshotAvailable=0;
        return;}s.thread=tid;if(!s.firstRecordingThread)s.firstRecordingThread=tid;f(*c,s);});}
template<class F>static F original(void* object,unsigned method){auto c=context();auto address=beamrtBindingSDKSlot(object,method);
    for(unsigned i=0;i<c->slotCount.load();++i)if(c->slots[i].address==address && c->slots[i].method==method)return reinterpret_cast<F>(c->slots[i].original);
    // A callback only exists on a table published in this immutable registry.
    // Invoking a cached callback on an unrelated/incompatible table is unsupported.
    std::terminate();
}
static void invalidate(Context& c,State& s){s.complete=false;++c.status.unsupported;if(c.latest.commandId==s.id)c.status.snapshotAvailable=0;}
static void draw(ID3D12GraphicsCommandList* list,UINT kind,UINT count,UINT instances,UINT start,UINT base,UINT startInstance,BeamRTResourceDrawToken* interval=nullptr){
#ifndef BEAMRT_RESOURCE_EMBEDDED
    (void)interval;
#endif
    command(list,kind==1?13u:14u,[&](Context& c,State& s){
    if(!c.status.targetReady || !identical(s.pipeline.Get(),c.targetPipeline.Get()))return;
    ++c.status.matchedDraws;c.status.snapshotAvailable=0;BeamRTBindingSnapshot out{};
    const auto& l=c.layout;
    bool valid=s.complete && identical(s.root.Get(),c.targetRoot.Get()) && count && instances && s.viewportCount && s.scissorCount && s.rtCount
        && s.kinds[l.cbv]==1 && s.values[l.cbv] && s.values[l.cbv]%D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT==0
        && s.kinds[l.srv]==2 && s.kinds[l.sampler]==2
        && beamrtBindingTable(s.values[l.srv],s.srv,out.srvCpu) && beamrtBindingTable(s.values[l.sampler],s.sampler,out.samplerCpu);
    if(!valid){++c.status.rejectedDraws;return;}
    if(c.status.serial==UINT64_MAX){fail(c,4,E_FAIL);return;}
    out.bytes=sizeof(out);out.abi=beamrtBindingABI;out.recordedDraw=1;out.drawKind=kind;out.commandId=s.id;out.generation=s.generation;out.serial=++c.status.serial;
    out.cbv=s.values[l.cbv];out.srvTable=s.values[l.srv];out.samplerTable=s.values[l.sampler];out.srvHeap=s.srv;out.samplerHeap=s.sampler;
    out.count=count;out.instances=instances;out.start=start;out.baseBits=base;out.startInstance=startInstance;
    out.viewportCount=s.viewportCount;out.scissorCount=s.scissorCount;out.renderTargetCount=s.rtCount;out.depthTarget=s.depth;
    std::memcpy(out.viewports,s.viewports,sizeof(out.viewports));std::memcpy(out.scissors,s.scissors,sizeof(out.scissors));std::memcpy(out.renderTargets,s.rt,sizeof(out.renderTargets));
    c.latest=out;c.status.snapshotAvailable=1;
#ifdef BEAMRT_BINDING_EMBEDDED
    auto diagnostics=c.diagnostics;diagnostics.bytes=sizeof(diagnostics);diagnostics.abi=beamrtBindingThreadABI;diagnostics.enabled=c.status.enabled;
#ifdef BEAMRT_RESOURCE_EMBEDDED
    BeamRTResourceDrawObservation resources{};
    if(interval)BeamRT_ResourcesFinishDraw(interval,sizeof(*interval),&s.outputCheckpoint,sizeof(s.outputCheckpoint),&out,sizeof(out),BeamRT_ResourceProbeBytes(),&resources,sizeof(resources));
    BeamRT_BindingPublishRecord(c.status,out,s.thread,diagnostics,&resources);
#else
    BeamRT_BindingPublishRecord(c.status,out,s.thread,diagnostics);
#endif
#endif
});}
using Create=HRESULT(STDMETHODCALLTYPE*)(ID3D12Device*,UINT,D3D12_COMMAND_LIST_TYPE,ID3D12CommandAllocator*,ID3D12PipelineState*,REFIID,void**);
using Create1=HRESULT(STDMETHODCALLTYPE*)(ID3D12Device4*,UINT,D3D12_COMMAND_LIST_TYPE,D3D12_COMMAND_LIST_FLAGS,REFIID,void**);
static void created(ID3D12Device*,D3D12_COMMAND_LIST_TYPE,ID3D12PipelineState*,bool,HRESULT,void**);
static HRESULT STDMETHODCALLTYPE create(ID3D12Device* d,UINT node,D3D12_COMMAND_LIST_TYPE type,ID3D12CommandAllocator* allocator,ID3D12PipelineState* p,REFIID iid,void** out){
    const auto hr=original<Create>(d,0)(d,node,type,allocator,p,iid,out);LastError e{GetLastError()};created(d,type,p,true,hr,out);return hr;}
static HRESULT STDMETHODCALLTYPE create1(ID3D12Device4* d,UINT node,D3D12_COMMAND_LIST_TYPE type,D3D12_COMMAND_LIST_FLAGS flags,REFIID iid,void** out){
    const auto hr=original<Create1>(d,1)(d,node,type,flags,iid,out);LastError e{GetLastError()};created(d,type,nullptr,false,hr,out);return hr;}
static HRESULT STDMETHODCALLTYPE close(ID3D12GraphicsCommandList* l){auto hr=original<HRESULT(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*)>(l,2)(l);LastError e{GetLastError()};
    if(SUCCEEDED(hr)){auto c=context();observed(*c,[&]{auto t=tag(*c,l);if(t)t->state(c)->recording=false;});}return hr;}
static HRESULT STDMETHODCALLTYPE reset(ID3D12GraphicsCommandList* l,ID3D12CommandAllocator* a,ID3D12PipelineState* p){
    auto hr=original<HRESULT(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,ID3D12CommandAllocator*,ID3D12PipelineState*)>(l,3)(l,a,p);LastError e{GetLastError()};
    if(SUCCEEDED(hr)){auto c=context();observed(*c,[&]{auto t=tag(*c,l);if(!t)return;auto& s=*t->state(c);
        if(s.generation==UINT64_MAX){fail(*c,4,E_FAIL);return;}const auto id=s.id,generation=s.generation+1;s={};s.id=id;s.generation=generation;s.pipeline=p;s.thread=GetCurrentThreadId();s.resetThread=s.thread;
        if(c->latest.commandId==id)c->status.snapshotAvailable=0;});}return hr;}
static void STDMETHODCALLTYPE clear(ID3D12GraphicsCommandList* l,ID3D12PipelineState* p){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,ID3D12PipelineState*)>(l,4)(l,p);LastError e{GetLastError()};
    command(l,4,[&](Context& c,State& s){const auto id=s.id,g=s.generation;const auto tid=s.thread,resetTid=s.resetThread,firstTid=s.firstRecordingThread;const bool conflict=s.threadConflict;
        s={};s.id=id;s.generation=g;s.thread=tid;s.resetThread=resetTid;s.firstRecordingThread=firstTid;s.threadConflict=conflict;s.pipeline=p;if(c.latest.commandId==id)c.status.snapshotAvailable=0;});}
static void STDMETHODCALLTYPE pipeline(ID3D12GraphicsCommandList* l,ID3D12PipelineState* p){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,ID3D12PipelineState*)>(l,5)(l,p);LastError e{GetLastError()};command(l,5,[&](Context&,State& s){s.pipeline=p;});}
static void STDMETHODCALLTYPE root(ID3D12GraphicsCommandList* l,ID3D12RootSignature* p){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,ID3D12RootSignature*)>(l,6)(l,p);LastError e{GetLastError()};
    command(l,6,[&](Context&,State& s){if(!identical(s.root.Get(),p)){s.root=p;std::memset(s.kinds,0,sizeof(s.kinds));std::memset(s.values,0,sizeof(s.values));}});}
static void STDMETHODCALLTYPE heaps(ID3D12GraphicsCommandList* l,UINT n,ID3D12DescriptorHeap* const* h){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,ID3D12DescriptorHeap* const*)>(l,7)(l,n,h);LastError e{GetLastError()};
    command(l,7,[&](Context& c,State& s){BeamRTBindingHeap srv{},sampler{};bool valid=n<=2 && (!n || h);
        for(UINT i=0;valid && i<n;++i){if(!child(c,h[i])){valid=false;break;}const auto d=h[i]->GetDesc();
            auto* dest=d.Type==D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV?&srv:d.Type==D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER?&sampler:nullptr;
            if(!dest || dest->identity || d.Flags!=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE){valid=false;break;}
            ComPtr<IUnknown> identity;if(FAILED(h[i]->QueryInterface(IID_PPV_ARGS(&identity)))){valid=false;break;}
            *dest={reinterpret_cast<uint64_t>(identity.Get()),h[i]->GetCPUDescriptorHandleForHeapStart().ptr,h[i]->GetGPUDescriptorHandleForHeapStart().ptr,
                d.NumDescriptors,c.device->GetDescriptorHandleIncrementSize(d.Type),static_cast<uint32_t>(d.Type),static_cast<uint32_t>(d.Flags)};}
        if(!valid){invalidate(c,s);return;}
        if(s.srv.identity!=srv.identity || s.sampler.identity!=sampler.identity)for(UINT i=0;i<64;++i)if(s.kinds[i]==2)s.kinds[i]=0;
        s.srv=srv;s.sampler=sampler;});}
static void address(ID3D12GraphicsCommandList* l,unsigned method,UINT slot,UINT64 value,uint8_t kind){command(l,method,[&](Context& c,State& s){if(slot>=64){invalidate(c,s);return;}s.values[slot]=value;s.kinds[slot]=kind;});}
static void STDMETHODCALLTYPE cbv(ID3D12GraphicsCommandList* l,UINT slot,D3D12_GPU_VIRTUAL_ADDRESS v){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,D3D12_GPU_VIRTUAL_ADDRESS)>(l,8)(l,slot,v);LastError e{GetLastError()};address(l,8,slot,v,1);}
static void STDMETHODCALLTYPE descriptor(ID3D12GraphicsCommandList* l,UINT slot,D3D12_GPU_DESCRIPTOR_HANDLE v){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,D3D12_GPU_DESCRIPTOR_HANDLE)>(l,9)(l,slot,v);LastError e{GetLastError()};address(l,9,slot,v.ptr,2);}
static void STDMETHODCALLTYPE viewport(ID3D12GraphicsCommandList* l,UINT n,const D3D12_VIEWPORT* v){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,const D3D12_VIEWPORT*)>(l,10)(l,n,v);LastError e{GetLastError()};
    command(l,10,[&](Context&,State& s){s.viewportCount=0;if(!n || n>16 || !v)return;
        for(UINT i=0;i<n;++i)if(!std::isfinite(v[i].TopLeftX) || !std::isfinite(v[i].TopLeftY) || !std::isfinite(v[i].Width) || !std::isfinite(v[i].Height)
            || !std::isfinite(v[i].MinDepth) || !std::isfinite(v[i].MaxDepth) || v[i].Width<=0 || v[i].Height<=0 || v[i].MinDepth<0 || v[i].MaxDepth>1 || v[i].MinDepth>v[i].MaxDepth)return;
        std::memcpy(s.viewports,v,n*sizeof(*v));s.viewportCount=n;});}
static void STDMETHODCALLTYPE scissor(ID3D12GraphicsCommandList* l,UINT n,const D3D12_RECT* v){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,const D3D12_RECT*)>(l,11)(l,n,v);LastError e{GetLastError()};
    command(l,11,[&](Context&,State& s){s.scissorCount=0;if(!n || n>16 || !v)return;for(UINT i=0;i<n;++i)if(v[i].right<=v[i].left || v[i].bottom<=v[i].top)return;
        std::memcpy(s.scissors,v,n*sizeof(*v));s.scissorCount=n;});}
static void STDMETHODCALLTYPE outputs(ID3D12GraphicsCommandList* l,UINT n,const D3D12_CPU_DESCRIPTOR_HANDLE* rt,BOOL contiguous,const D3D12_CPU_DESCRIPTOR_HANDLE* depth){
#ifdef BEAMRT_RESOURCE_EMBEDDED
    const auto incoming=GetLastError();BeamRTResourceCheckpoint checkpoint{};BeamRT_ResourcesCheckpoint(&checkpoint,sizeof(checkpoint));SetLastError(incoming);
#endif
    original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,const D3D12_CPU_DESCRIPTOR_HANDLE*,BOOL,const D3D12_CPU_DESCRIPTOR_HANDLE*)>(l,12)(l,n,rt,contiguous,depth);LastError e{GetLastError()};
    command(l,12,[&](Context& c,State& s){
#ifdef BEAMRT_RESOURCE_EMBEDDED
        s.outputCheckpoint=checkpoint;
#endif
        s.rtCount=0;s.depth=depth?depth->ptr:0;if(!n || n>8 || !rt)return;
        const auto stride=c.device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        for(UINT i=0;i<n;++i){const auto offset=uint64_t(i)*stride;if(contiguous && offset>UINT64_MAX-rt[0].ptr)return;
            s.rt[i]=contiguous?rt[0].ptr+offset:rt[i].ptr;if(!s.rt[i])return;}s.rtCount=n;});}
static void STDMETHODCALLTYPE drawInstanced(ID3D12GraphicsCommandList* l,UINT n,UINT instances,UINT start,UINT first){
#ifdef BEAMRT_RESOURCE_EMBEDDED
    const auto incoming=GetLastError();ResourceDrawScope scope;SetLastError(incoming);
    original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,UINT,UINT,UINT)>(l,13)(l,n,instances,start,first);LastError e{GetLastError()};draw(l,1,n,instances,start,0,first,&scope.token);
#else
    original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,UINT,UINT,UINT)>(l,13)(l,n,instances,start,first);LastError e{GetLastError()};draw(l,1,n,instances,start,0,first);
#endif
}
static void STDMETHODCALLTYPE drawIndexed(ID3D12GraphicsCommandList* l,UINT n,UINT instances,UINT start,INT base,UINT first){
#ifdef BEAMRT_RESOURCE_EMBEDDED
    const auto incoming=GetLastError();ResourceDrawScope scope;SetLastError(incoming);
    original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,UINT,UINT,INT,UINT)>(l,14)(l,n,instances,start,base,first);LastError e{GetLastError()};draw(l,2,n,instances,start,static_cast<UINT>(base),first,&scope.token);
#else
    original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,UINT,UINT,INT,UINT)>(l,14)(l,n,instances,start,base,first);LastError e{GetLastError()};draw(l,2,n,instances,start,static_cast<UINT>(base),first);
#endif
}
static void unsupported(ID3D12GraphicsCommandList* l,unsigned method){command(l,method,[](Context& c,State& s){invalidate(c,s);});}
static void STDMETHODCALLTYPE bundle(ID3D12GraphicsCommandList* l,ID3D12GraphicsCommandList* b){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,ID3D12GraphicsCommandList*)>(l,15)(l,b);LastError e{GetLastError()};unsupported(l,15);}
static void STDMETHODCALLTYPE indirect(ID3D12GraphicsCommandList* l,ID3D12CommandSignature* s,UINT n,ID3D12Resource* args,UINT64 offset,ID3D12Resource* count,UINT64 countOffset){
    original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,ID3D12CommandSignature*,UINT,ID3D12Resource*,UINT64,ID3D12Resource*,UINT64)>(l,16)(l,s,n,args,offset,count,countOffset);LastError e{GetLastError()};unsupported(l,16);}
static void STDMETHODCALLTYPE beginPass(ID3D12GraphicsCommandList4* l,UINT n,const D3D12_RENDER_PASS_RENDER_TARGET_DESC* rt,const D3D12_RENDER_PASS_DEPTH_STENCIL_DESC* depth,D3D12_RENDER_PASS_FLAGS flags){
    original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList4*,UINT,const D3D12_RENDER_PASS_RENDER_TARGET_DESC*,const D3D12_RENDER_PASS_DEPTH_STENCIL_DESC*,D3D12_RENDER_PASS_FLAGS)>(l,17)(l,n,rt,depth,flags);LastError e{GetLastError()};unsupported(l,17);}
static void STDMETHODCALLTYPE endPass(ID3D12GraphicsCommandList4* l){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList4*)>(l,18)(l);LastError e{GetLastError()};unsupported(l,18);}
static void STDMETHODCALLTYPE constant(ID3D12GraphicsCommandList* l,UINT slot,UINT value,UINT offset){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,UINT,UINT)>(l,19)(l,slot,value,offset);LastError e{GetLastError()};address(l,19,slot,0,3);}
static void STDMETHODCALLTYPE constants(ID3D12GraphicsCommandList* l,UINT slot,UINT n,const void* v,UINT offset){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,UINT,const void*,UINT)>(l,20)(l,slot,n,v,offset);LastError e{GetLastError()};address(l,20,slot,0,3);}
static void STDMETHODCALLTYPE srv(ID3D12GraphicsCommandList* l,UINT slot,D3D12_GPU_VIRTUAL_ADDRESS v){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,D3D12_GPU_VIRTUAL_ADDRESS)>(l,21)(l,slot,v);LastError e{GetLastError()};address(l,21,slot,v,3);}
static void STDMETHODCALLTYPE uav(ID3D12GraphicsCommandList* l,UINT slot,D3D12_GPU_VIRTUAL_ADDRESS v){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList*,UINT,D3D12_GPU_VIRTUAL_ADDRESS)>(l,22)(l,slot,v);LastError e{GetLastError()};address(l,22,slot,v,3);}
static void STDMETHODCALLTYPE pipeline1(ID3D12GraphicsCommandList4* l,ID3D12StateObject* p){original<void(STDMETHODCALLTYPE*)(ID3D12GraphicsCommandList4*,ID3D12StateObject*)>(l,23)(l,p);LastError e{GetLastError()};unsupported(l,23);}
static HRESULT exchange(Slot& s,void* expected,void* value,bool& changed){changed=false;MEMORY_BASIC_INFORMATION m{};
    if(!VirtualQuery(s.address,&m,sizeof(m)) || m.AllocationBase!=s.table || m.State!=MEM_COMMIT || m.Type!=MEM_IMAGE
        || (m.Protect!=PAGE_READONLY && m.Protect!=PAGE_READWRITE && m.Protect!=PAGE_WRITECOPY))return E_ACCESSDENIED;
    DWORD old=0;if(!VirtualProtect(s.address,sizeof(void*),PAGE_READWRITE,&old))return HRESULT_FROM_WIN32(GetLastError());
    changed=InterlockedCompareExchangePointer(s.address,value,expected)==expected;DWORD unused=0;
    if(!VirtualProtect(s.address,sizeof(void*),old,&unused))return HRESULT_FROM_WIN32(GetLastError());return changed?S_OK:HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
}
static void* replacements[]={reinterpret_cast<void*>(create),reinterpret_cast<void*>(create1),reinterpret_cast<void*>(close),reinterpret_cast<void*>(reset),
    reinterpret_cast<void*>(clear),reinterpret_cast<void*>(pipeline),reinterpret_cast<void*>(root),reinterpret_cast<void*>(heaps),reinterpret_cast<void*>(cbv),reinterpret_cast<void*>(descriptor),
    reinterpret_cast<void*>(viewport),reinterpret_cast<void*>(scissor),reinterpret_cast<void*>(outputs),reinterpret_cast<void*>(drawInstanced),reinterpret_cast<void*>(drawIndexed),
    reinterpret_cast<void*>(bundle),reinterpret_cast<void*>(indirect),reinterpret_cast<void*>(beginPass),reinterpret_cast<void*>(endPass),reinterpret_cast<void*>(constant),reinterpret_cast<void*>(constants),
    reinterpret_cast<void*>(srv),reinterpret_cast<void*>(uav),reinterpret_cast<void*>(pipeline1)};
static HRESULT install(Context& c,void* object,unsigned method){auto address=beamrtBindingSDKSlot(object,method);
    for(unsigned i=0;i<c.slotCount.load();++i)if(c.slots[i].address==address)return c.slots[i].method==method?S_OK:E_INVALIDARG;
    const auto count=c.slotCount.load();if(count==128 || !address || reinterpret_cast<ULONG_PTR>(address)%alignof(void*))return E_OUTOFMEMORY;
    auto& s=c.slots[count];s.address=address;s.method=method;s.original=*address;
    if(!s.original || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(address),&s.table)
        || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(s.original),&s.code))return E_ACCESSDENIED;
    c.slotCount.store(count+1);bool changed=false;const auto hr=exchange(s,s.original,replacements[method],changed);s.attached=changed;
    if(changed)++c.status.attachedSlots;return hr;
}
static void created(ID3D12Device* d,D3D12_COMMAND_LIST_TYPE type,ID3D12PipelineState* pipelineState,bool recording,HRESULT hr,void** out){auto c=context();observed(*c,[&]{
    if(!owns(*c,d))return;++c->status.creations;if(FAILED(hr) || !out || !*out)return;
    if(type!=D3D12_COMMAND_LIST_TYPE_DIRECT){++c->status.unsupported;return;}
    ComPtr<ID3D12GraphicsCommandList> list;if(FAILED(static_cast<IUnknown*>(*out)->QueryInterface(IID_PPV_ARGS(&list))) || !child(*c,list.Get())){fail(*c,5,E_INVALIDARG);return;}
    UINT size=0;if(list->GetPrivateData(tagGuid,&size,nullptr)!=DXGI_ERROR_NOT_FOUND){fail(*c,3,E_INVALIDARG);return;}
    if(c->live.load()>=beamrtBindingCommandLimit){++c->status.pressureSkipped;return;}
    if(c->nextId==UINT64_MAX){fail(*c,4,E_FAIL);return;}
    ComPtr<TagInterface> tagged;tagged.Attach(new Tag(*c,++c->nextId,pipelineState,recording));
    const auto stored=list->SetPrivateDataInterface(tagGuid,tagged.Get());if(FAILED(stored)){fail(*c,3,stored);return;}++c->status.tagged;
    for(unsigned method=2;method<24;++method)if(method!=17 && method!=18 && method!=23){const auto result=install(*c,list.Get(),method);if(FAILED(result)){fail(*c,6,result);return;}}
    ComPtr<ID3D12GraphicsCommandList4> list4;if(SUCCEEDED(list.As(&list4)))for(unsigned method:{17u,18u,23u}){const auto result=install(*c,list4.Get(),method);if(FAILED(result)){fail(*c,6,result);return;}}
});}
} // namespace: binding implementation types, not exported ABI
extern "C" HRESULT WINAPI BeamRT_BindingsStart(ID3D12Device* device){if(!device)return E_INVALIDARG;Guard guard;if(context())return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
    std::unique_ptr<Context> pending(new(std::nothrow) Context());if(!pending)return E_OUTOFMEMORY;auto& c=*pending;
    c.device=device;if(FAILED(device->GetDeviceRemovedReason()) || FAILED(c.device.As(&c.identity)))return E_INVALIDARG;c.device.As(&c.device4);
#ifdef BEAMRT_BINDING_EMBEDDED
    // Existing runtime only, outside DLL attach; no new DLL load or static
    // d3d12 import is added to the default-passive bootstrap.
    if(!GetModuleHandleExW(0,L"d3d12.dll",&c.decoderLease.module))return HRESULT_FROM_WIN32(GetLastError());
    c.decoder=reinterpret_cast<BeamRTRootDecoder>(GetProcAddress(c.decoderLease.module,"D3D12CreateVersionedRootSignatureDeserializer"));
    if(!c.decoder)return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
#endif
    c.status.bytes=sizeof(c.status);c.status.abi=beamrtBindingABI;c.status.ownerThread=GetCurrentThreadId();c.status.healthy=1;
    auto resident=pending.release();InterlockedExchangePointer(&published,resident);
    const auto first=install(*resident,device,0);if(FAILED(first)){fail(*resident,6,first);return first;}
    if(resident->device4){const auto second=install(*resident,resident->device4.Get(),1);if(FAILED(second)){fail(*resident,6,second);return second;}}
    resident->status.enabled=1;return S_OK;
}
static HRESULT targetFromAudit(bool controlThread){
    auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    if(controlThread && c->status.ownerThread!=GetCurrentThreadId())return E_ACCESSDENIED;
    uint8_t bytes[65536]{};uint32_t size=0;ID3D12RootSignature* r=nullptr;ID3D12PipelineState* p=nullptr;
    // Do not hold binding metadata lock while calling the separate audit API.
    const auto result=BeamRT_PipelineAuditReadMatch(bytes,sizeof(bytes),&size,&r,&p);ComPtr<ID3D12RootSignature> rootObject;rootObject.Attach(r);ComPtr<ID3D12PipelineState> pso;pso.Attach(p);
    if(FAILED(result))return result;BeamRTGIRootLayout layout;const auto decoded=beamrtDecodeGIRoot(bytes,size,layout,c->decoder);if(FAILED(decoded))return decoded;
    Guard guard;if(!c->status.enabled || !c->status.healthy)return HRESULT_FROM_WIN32(ERROR_NOT_READY);
    if(c->status.targetReady)return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
    if(!child(*c,rootObject.Get()) || !child(*c,pso.Get()))return E_INVALIDARG;c->targetRoot=std::move(rootObject);c->targetPipeline=std::move(pso);c->layout=layout;c->status.targetReady=1;return S_OK;
}
extern "C" HRESULT WINAPI BeamRT_BindingsTargetFromAudit(){return targetFromAudit(true);}
#ifdef BEAMRT_BINDING_EMBEDDED
// Internal only: invoked by a verified first-match callback AFTER the audit
// lock releases, not arbitrary object pointers or a parent remote invocation.
HRESULT BeamRT_BindingsVerifiedAuditMatch(){return targetFromAudit(false);}
#endif
extern "C" HRESULT WINAPI BeamRT_BindingsStatus(BeamRTBindingStatus* out,uint32_t bytes){if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};Guard guard;auto c=context();
    if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);*out=c->status;out->liveCommands=c->live.load();return S_OK;}
extern "C" HRESULT WINAPI BeamRT_BindingsRead(BeamRTBindingSnapshot* out,uint32_t bytes){if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};Guard guard;auto c=context();
    if(!c || !c->status.enabled || !c->status.healthy || !c->status.snapshotAvailable)return HRESULT_FROM_WIN32(ERROR_NOT_READY);*out=c->latest;return S_OK;}
extern "C" HRESULT WINAPI BeamRT_BindingsThreadDiagnostics(BeamRTBindingThreadDiagnostics* out,uint32_t bytes){if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};Guard guard;auto c=context();
    if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);*out=c->diagnostics;out->bytes=sizeof(*out);out->abi=beamrtBindingThreadABI;out->enabled=c->status.enabled;return S_OK;}
extern "C" HRESULT WINAPI BeamRT_BindingsDisable(){Guard guard;auto c=context();if(!c)return HRESULT_FROM_WIN32(ERROR_NOT_READY);if(c->status.ownerThread!=GetCurrentThreadId())return E_ACCESSDENIED;
    c->status.enabled=0;c->status.snapshotAvailable=0;HRESULT first=S_OK;
    for(unsigned i=0;i<c->slotCount.load();++i){auto& s=c->slots[i];if(!s.attached)continue;bool changed=false;const auto hr=exchange(s,replacements[s.method],s.original,changed);
        if(changed){s.attached=false;--c->status.attachedSlots;++c->status.restoredSlots;}if(FAILED(hr)){fail(*c,7,hr);if(SUCCEEDED(first))first=hr;}}
    // Published originals, module leases, target and tag storage stay resident.
    return first;
}
