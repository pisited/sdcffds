#define BEAMRT_CAPTURE_BUILD
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "beamrt_capture.h"
#include "sdk_methods.h"
#include <windows.h>
#include <detours.h>
#include <wrl/client.h>
#include <atomic>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;
static thread_local std::string lastError;
static thread_local unsigned nested=0;
static std::atomic<uint32_t> activeCalls{0};
struct Call { Call(){++activeCalls;++nested;}~Call(){--nested;--activeCalls;} };
static void require(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
static void check(HRESULT hr,const char* why){if(FAILED(hr))throw std::runtime_error(std::string(why)+" HRESULT="+std::to_string(hr));}
struct Heap {
    ComPtr<ID3D12DescriptorHeap> resource;
    SIZE_T cpu=0;UINT64 gpu=0;UINT count=0,stride=0;
    bool shaderVisible=false;
};
struct View { ComPtr<ID3D12Resource> resource;D3D12_SHADER_RESOURCE_VIEW_DESC description{}; };
struct Table { ComPtr<ID3D12DescriptorHeap> heap;UINT64 gpu=0; };
struct Command {
    ComPtr<ID3D12GraphicsCommandList> resource;
    ComPtr<ID3D12PipelineState> pipeline;
    ComPtr<ID3D12RootSignature> graphicsRoot,computeRoot;
    ComPtr<ID3D12DescriptorHeap> heap,samplerHeap;
    std::map<UINT,UINT64> graphicsTables,computeTables;
    Table candidate;UINT64 generation=1;bool targeted=false,poisoned=false;
};
struct BeamRTCaptureSnapshot {
    BeamRTCaptureInfo info{};
    ComPtr<ID3D12Resource> references[8];
    ComPtr<ID3D12CommandQueue> queueReference;
};
struct QueueCapture {
    ComPtr<ID3D12CommandQueue> resource;
    std::shared_ptr<BeamRTCaptureSnapshot> latest;
};
struct BeamRTCapture {
    std::mutex mutex;ComPtr<ID3D12Device> device;DWORD thread=0;
    BeamRTCaptureConfig config{};std::vector<uint8_t> shader,root;
    std::map<ID3D12DescriptorHeap*,Heap> heaps;
    std::map<SIZE_T,View> views;
    std::map<ID3D12RootSignature*,ComPtr<ID3D12RootSignature>> roots;
    std::map<ID3D12PipelineState*,ComPtr<ID3D12PipelineState>> pipelines;
    std::map<ID3D12GraphicsCommandList*,Command> commands;
    std::map<ID3D12CommandQueue*,QueueCapture> queues;
    std::shared_ptr<BeamRTCaptureSnapshot> latest;
    uint64_t calls=0,matched=0,submissions=0,captured=0;
    bool healthy=true;std::string reason="no submitted matching pass";
    bool owns(ID3D12DeviceChild* object) {
        if(!object)return false;ComPtr<ID3D12Device> owner;
        if(FAILED(object->GetDevice(IID_PPV_ARGS(&owner))))return false;
        ComPtr<IUnknown> a,b;check(device.As(&a),"device identity");check(owner.As(&b),"owner identity");return a.Get()==b.Get();
    }
    bool owns(ID3D12Device* object) {
        if(!object)return false;ComPtr<IUnknown> a,b;
        check(device.As(&a),"device identity");check(object->QueryInterface(IID_PPV_ARGS(&b)),"caller identity");return a.Get()==b.Get();
    }
    void poison(const char* why){healthy=false;latest.reset();queues.clear();reason=why;}
    Command* list(ID3D12GraphicsCommandList* object) {
        auto found=commands.find(object);return found==commands.end()?nullptr:&found->second;
    }
    Heap* cpuHeap(SIZE_T handle) {
        for(auto& pair:heaps){auto& h=pair.second;
            if(handle>=h.cpu && (handle-h.cpu)%h.stride==0 && (handle-h.cpu)/h.stride<h.count)return &h;}
        return nullptr;
    }
    SIZE_T cpuHandle(const Table& t,UINT offset) {
        auto found=heaps.find(t.heap.Get());if(found==heaps.end())return 0;const auto& h=found->second;
        if(!h.gpu || t.gpu<h.gpu || (t.gpu-h.gpu)%h.stride)return 0;
        UINT64 index=(t.gpu-h.gpu)/h.stride+offset;if(index>=h.count)return 0;
        return h.cpu+static_cast<SIZE_T>(index*h.stride);
    }
    void write(ID3D12Resource* resource,const D3D12_SHADER_RESOURCE_VIEW_DESC* d,D3D12_CPU_DESCRIPTOR_HANDLE handle) {
        if(!cpuHeap(handle.ptr))return;views.erase(handle.ptr);
        if(!resource || !d || !owns(resource))return;
        const auto desc=resource->GetDesc();bool valid=false;
        if(d->ViewDimension==D3D12_SRV_DIMENSION_TEXTURE2D)
            valid=desc.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE2D && desc.DepthOrArraySize==1
                && desc.SampleDesc.Count==1 && d->Texture2D.MostDetailedMip==0 && d->Texture2D.MipLevels==1
                && d->Texture2D.PlaneSlice==0 && d->Texture2D.ResourceMinLODClamp==0;
        else if(d->ViewDimension==D3D12_SRV_DIMENSION_BUFFER) {
            const auto& b=d->Buffer;
            valid=desc.Dimension==D3D12_RESOURCE_DIMENSION_BUFFER && d->Format==DXGI_FORMAT_UNKNOWN
                && b.Flags==D3D12_BUFFER_SRV_FLAG_NONE && b.StructureByteStride>=4 && b.StructureByteStride<=2048
                && b.NumElements>0 && b.FirstElement<=desc.Width/b.StructureByteStride
                && b.NumElements<=desc.Width/b.StructureByteStride-b.FirstElement;
        }
        if(!valid)return;
        require(views.size()<512,"descriptor capture budget exceeded");
        View view;view.resource=resource;view.description=*d;views[handle.ptr]=view;
    }
    void copyHandles(const std::vector<D3D12_CPU_DESCRIPTOR_HANDLE>& from,
                     const std::vector<D3D12_CPU_DESCRIPTOR_HANDLE>& to) {
        require(from.size()==to.size() && from.size()<=512,"descriptor copy size mismatch/budget exceeded");
        // Track creation/copy provenance, NEVER read descriptor-heap memory.
        // The SDK forbids shader-visible copy sources. Such a source, or any
        // unknown source, clears destination provenance rather than certifying
        // a stale resource. All original calls are still forwarded unchanged.
        std::vector<View> values(from.size());
        for(size_t i=0;i<from.size();++i){
            const auto heap=cpuHeap(from[i].ptr);
            if(!heap || heap->shaderVisible)continue;
            auto found=views.find(from[i].ptr);
            if(found!=views.end())values[i]=found->second;
        }
        for(size_t i=0;i<to.size();++i){
            if(!cpuHeap(to[i].ptr))continue;
            views.erase(to[i].ptr);
            if(values[i].resource){
                require(views.size()<512,"descriptor capture budget exceeded");
                views[to[i].ptr]=values[i];
            }
        }
    }
    void copy(UINT count,D3D12_CPU_DESCRIPTOR_HANDLE dst,D3D12_CPU_DESCRIPTOR_HANDLE src,D3D12_DESCRIPTOR_HEAP_TYPE type) {
        if(type!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV)return;
        require(count<=512,"descriptor copy budget exceeded");
        const UINT stride=device->GetDescriptorHandleIncrementSize(type);
        std::vector<D3D12_CPU_DESCRIPTOR_HANDLE> from,to;
        from.reserve(count);to.reserve(count);
        for(UINT i=0;i<count;++i){
            from.push_back({src.ptr+SIZE_T(i)*stride});
            to.push_back({dst.ptr+SIZE_T(i)*stride});
        }
        copyHandles(from,to);
    }
    void target(ID3D12GraphicsCommandList* object,uint32_t kind) {
        auto state=list(object);if(!state || !pipelines.count(state->pipeline.Get()) || config.kind!=kind)return;
        ++matched;state->targeted=true;state->candidate={};
        auto& signature=kind==1?state->graphicsRoot:state->computeRoot;
        auto& tables=kind==1?state->graphicsTables:state->computeTables;
        if(!roots.count(signature.Get()) || !state->heap || state->poisoned){reason="missing or unsupported target bindings";return;}
        auto found=tables.find(config.tableParameter);
        if(found==tables.end()){reason="target table was not observed";return;}
        state->candidate.heap=state->heap;state->candidate.gpu=found->second;
    }
    void submit(ID3D12CommandQueue* queue,UINT count,ID3D12CommandList* const* lists) {
        ++submissions;
        for(UINT i=0;i<count;++i) {
            ComPtr<ID3D12GraphicsCommandList> graphics;
            if(FAILED(lists[i]->QueryInterface(IID_PPV_ARGS(&graphics))))continue;
            auto state=list(graphics.Get());if(!state || !state->targeted)continue;
            auto foundQueue=queues.find(queue);
            if(foundQueue==queues.end()){
                require(queues.size()<32,"queue capture budget exceeded");
                QueueCapture entry;entry.resource=queue;
                foundQueue=queues.emplace(queue,std::move(entry)).first;
            }
            latest.reset();
            foundQueue->second.latest.reset();
            if(state->poisoned || !state->candidate.heap){reason="unsupported or incomplete submitted target";continue;}
            auto snapshot=std::make_shared<BeamRTCaptureSnapshot>();
            snapshot->queueReference=queue;snapshot->info.queue=queue;
            snapshot->info.submission=submissions;snapshot->info.recordingGeneration=state->generation;
            snapshot->info.count=config.inputCount;snapshot->info.kind=config.kind;
            bool valid=true;
            for(UINT n=0;n<config.inputCount;++n) {
                auto found=views.find(cpuHandle(state->candidate,config.offsets[n]));
                if(found==views.end() || found->second.description.Format!=config.formats[n]
                    || found->second.description.ViewDimension!=config.dimensions[n]){valid=false;break;}
                snapshot->references[n]=found->second.resource;
                snapshot->info.resources[n]=found->second.resource.Get();snapshot->info.views[n]=found->second.description;
            }
            if(valid){latest=snapshot;foundQueue->second.latest=snapshot;++captured;reason="live bindings captured; GPU ordering/camera/lighting NOT verified";}
            else reason="unknown descriptor provenance or view mismatch";
        }
    }
};
static std::atomic<BeamRTCapture*> current{nullptr};
template<class F>static void observe(F&& fn) noexcept {
    auto host=current.load();if(!host || nested!=1)return;
    try { std::lock_guard<std::mutex> lock(host->mutex);++host->calls;
        // Mark callback failures while still holding the metadata lock. Another
        // thread must not publish partially updated state before invalidation.
        try {
            if(host->config.threadMode==BEAMRT_CAPTURE_SINGLE_THREAD && GetCurrentThreadId()!=host->thread){host->poison("single-thread capture received another API-calling thread");return;}
            if(host->healthy)fn(*host);
        } catch(const std::exception& e){host->poison(e.what());}
          catch(...){host->poison("capture callback failed");}
    } catch(const std::exception& e) {
        try{std::lock_guard<std::mutex> lock(host->mutex);host->poison(e.what());}catch(...){}
    } catch(...) {
        try{std::lock_guard<std::mutex> lock(host->mutex);host->poison("capture callback failed");}catch(...){}
    }
}
template<class T>static ComPtr<T> outputInterface(void** output) {
    ComPtr<T> value;if(output && *output)static_cast<IUnknown*>(*output)->QueryInterface(IID_PPV_ARGS(&value));return value;
}
static bool bytesMatch(const D3D12_SHADER_BYTECODE& code,const std::vector<uint8_t>& bytes){
    return code.pShaderBytecode && code.BytecodeLength==bytes.size()
        && std::memcmp(code.pShaderBytecode,bytes.data(),bytes.size())==0;
}
static HRESULT (STDMETHODCALLTYPE *oCreateHeap)(ID3D12Device* self,const D3D12_DESCRIPTOR_HEAP_DESC* desc,REFIID iid,void** out)=nullptr;
static HRESULT STDMETHODCALLTYPE hCreateHeap(ID3D12Device* self,const D3D12_DESCRIPTOR_HEAP_DESC* desc,REFIID iid,void** out) { Call call;auto result=oCreateHeap(self,desc,iid,out);if(SUCCEEDED(result))observe([&](BeamRTCapture& h){if(!h.owns(self) || !desc || desc->Type!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV)return;auto object=outputInterface<ID3D12DescriptorHeap>(out);if(!object)return;require(h.heaps.size()<64,"heap capture budget exceeded");Heap heap;heap.resource=object;heap.cpu=object->GetCPUDescriptorHandleForHeapStart().ptr;heap.shaderVisible=(desc->Flags&D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE)!=0;heap.gpu=heap.shaderVisible?object->GetGPUDescriptorHandleForHeapStart().ptr:0;heap.count=desc->NumDescriptors;heap.stride=self->GetDescriptorHandleIncrementSize(desc->Type);h.heaps[object.Get()]=heap;});return result;}
static void (STDMETHODCALLTYPE *oCreateSRV)(ID3D12Device* self,ID3D12Resource* resource,const D3D12_SHADER_RESOURCE_VIEW_DESC* desc,D3D12_CPU_DESCRIPTOR_HANDLE handle)=nullptr;
static void STDMETHODCALLTYPE hCreateSRV(ID3D12Device* self,ID3D12Resource* resource,const D3D12_SHADER_RESOURCE_VIEW_DESC* desc,D3D12_CPU_DESCRIPTOR_HANDLE handle) { Call call;oCreateSRV(self,resource,desc,handle);observe([&](BeamRTCapture& h){if(h.owns(self))h.write(resource,desc,handle);});}
static void (STDMETHODCALLTYPE *oCreateCBV)(ID3D12Device* self,const D3D12_CONSTANT_BUFFER_VIEW_DESC* desc,D3D12_CPU_DESCRIPTOR_HANDLE handle)=nullptr;
static void STDMETHODCALLTYPE hCreateCBV(ID3D12Device* self,const D3D12_CONSTANT_BUFFER_VIEW_DESC* desc,D3D12_CPU_DESCRIPTOR_HANDLE handle) { Call call;oCreateCBV(self,desc,handle);observe([&](BeamRTCapture& h){if(h.owns(self))h.views.erase(handle.ptr);});}
static void (STDMETHODCALLTYPE *oCreateUAV)(ID3D12Device* self,ID3D12Resource* resource,ID3D12Resource* counter,const D3D12_UNORDERED_ACCESS_VIEW_DESC* desc,D3D12_CPU_DESCRIPTOR_HANDLE handle)=nullptr;
static void STDMETHODCALLTYPE hCreateUAV(ID3D12Device* self,ID3D12Resource* resource,ID3D12Resource* counter,const D3D12_UNORDERED_ACCESS_VIEW_DESC* desc,D3D12_CPU_DESCRIPTOR_HANDLE handle) { Call call;oCreateUAV(self,resource,counter,desc,handle);observe([&](BeamRTCapture& h){if(h.owns(self))h.views.erase(handle.ptr);});}
static void (STDMETHODCALLTYPE *oCopySimple)(ID3D12Device* self,UINT count,D3D12_CPU_DESCRIPTOR_HANDLE dst,D3D12_CPU_DESCRIPTOR_HANDLE src,D3D12_DESCRIPTOR_HEAP_TYPE type)=nullptr;
static void STDMETHODCALLTYPE hCopySimple(ID3D12Device* self,UINT count,D3D12_CPU_DESCRIPTOR_HANDLE dst,D3D12_CPU_DESCRIPTOR_HANDLE src,D3D12_DESCRIPTOR_HEAP_TYPE type) { Call call;oCopySimple(self,count,dst,src,type);observe([&](BeamRTCapture& h){if(h.owns(self))h.copy(count,dst,src,type);});}
static void (STDMETHODCALLTYPE *oCopyRanges)(ID3D12Device* self,UINT dstCount,const D3D12_CPU_DESCRIPTOR_HANDLE* dst,const UINT* dstSizes,UINT srcCount,const D3D12_CPU_DESCRIPTOR_HANDLE* src,const UINT* srcSizes,D3D12_DESCRIPTOR_HEAP_TYPE type)=nullptr;
static void STDMETHODCALLTYPE hCopyRanges(ID3D12Device* self,UINT dstCount,const D3D12_CPU_DESCRIPTOR_HANDLE* dst,const UINT* dstSizes,UINT srcCount,const D3D12_CPU_DESCRIPTOR_HANDLE* src,const UINT* srcSizes,D3D12_DESCRIPTOR_HEAP_TYPE type) {
    Call call;oCopyRanges(self,dstCount,dst,dstSizes,srcCount,src,srcSizes,type);
    observe([&](BeamRTCapture& h){
        if(!h.owns(self) || type!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV)return;
        require(dstCount<=64 && srcCount<=64,"copy range budget exceeded");
        std::vector<D3D12_CPU_DESCRIPTOR_HANDLE> from,to;
        const UINT stride=self->GetDescriptorHandleIncrementSize(type);
        for(UINT i=0;i<srcCount;++i){
            UINT n=srcSizes?srcSizes[i]:1;
            require(n<=512 && from.size()+n<=512,"copy size budget exceeded");
            for(UINT j=0;j<n;++j)from.push_back({src[i].ptr+SIZE_T(j)*stride});
        }
        for(UINT i=0;i<dstCount;++i){
            UINT n=dstSizes?dstSizes[i]:1;
            require(n<=512 && to.size()+n<=512,"copy size budget exceeded");
            for(UINT j=0;j<n;++j)to.push_back({dst[i].ptr+SIZE_T(j)*stride});
        }
        h.copyHandles(from,to);
    });
}
static HRESULT (STDMETHODCALLTYPE *oCreateRoot)(ID3D12Device* self,UINT node,const void* bytes,SIZE_T count,REFIID iid,void** out)=nullptr;
static HRESULT STDMETHODCALLTYPE hCreateRoot(ID3D12Device* self,UINT node,const void* bytes,SIZE_T count,REFIID iid,void** out) { Call call;auto result=oCreateRoot(self,node,bytes,count,iid,out);if(SUCCEEDED(result))observe([&](BeamRTCapture& h){if(!h.owns(self) || !bytes || count!=h.root.size() || std::memcmp(bytes,h.root.data(),count))return;auto object=outputInterface<ID3D12RootSignature>(out);if(object){require(h.roots.size()<32,"root capture budget exceeded");h.roots[object.Get()]=object;}});return result;}
static HRESULT (STDMETHODCALLTYPE *oCreateGraphics)(ID3D12Device* self,const D3D12_GRAPHICS_PIPELINE_STATE_DESC* desc,REFIID iid,void** out)=nullptr;
static HRESULT STDMETHODCALLTYPE hCreateGraphics(ID3D12Device* self,const D3D12_GRAPHICS_PIPELINE_STATE_DESC* desc,REFIID iid,void** out) { Call call;auto result=oCreateGraphics(self,desc,iid,out);if(SUCCEEDED(result))observe([&](BeamRTCapture& h){if(!h.owns(self) || !desc || h.config.kind!=1 || !h.roots.count(desc->pRootSignature) || !bytesMatch(desc->PS,h.shader))return;auto object=outputInterface<ID3D12PipelineState>(out);if(object){require(h.pipelines.size()<64,"pipeline capture budget exceeded");h.pipelines[object.Get()]=object;}});return result;}
static HRESULT (STDMETHODCALLTYPE *oCreateCompute)(ID3D12Device* self,const D3D12_COMPUTE_PIPELINE_STATE_DESC* desc,REFIID iid,void** out)=nullptr;
static HRESULT STDMETHODCALLTYPE hCreateCompute(ID3D12Device* self,const D3D12_COMPUTE_PIPELINE_STATE_DESC* desc,REFIID iid,void** out) { Call call;auto result=oCreateCompute(self,desc,iid,out);if(SUCCEEDED(result))observe([&](BeamRTCapture& h){if(!h.owns(self) || !desc || h.config.kind!=2 || !h.roots.count(desc->pRootSignature) || !bytesMatch(desc->CS,h.shader))return;auto object=outputInterface<ID3D12PipelineState>(out);if(object){require(h.pipelines.size()<64,"pipeline capture budget exceeded");h.pipelines[object.Get()]=object;}});return result;}
static HRESULT (STDMETHODCALLTYPE *oCreateList)(ID3D12Device* self,UINT node,D3D12_COMMAND_LIST_TYPE type,ID3D12CommandAllocator* allocator,ID3D12PipelineState* pipeline,REFIID iid,void** out)=nullptr;
static HRESULT STDMETHODCALLTYPE hCreateList(ID3D12Device* self,UINT node,D3D12_COMMAND_LIST_TYPE type,ID3D12CommandAllocator* allocator,ID3D12PipelineState* pipeline,REFIID iid,void** out) { Call call;auto result=oCreateList(self,node,type,allocator,pipeline,iid,out);if(SUCCEEDED(result))observe([&](BeamRTCapture& h){if(!h.owns(self) || (type!=D3D12_COMMAND_LIST_TYPE_DIRECT && type!=D3D12_COMMAND_LIST_TYPE_COMPUTE))return;auto object=outputInterface<ID3D12GraphicsCommandList>(out);if(object){require(h.commands.size()<64,"command-list capture budget exceeded");Command state;state.resource=object;state.pipeline=pipeline;h.commands[object.Get()]=state;}});return result;}
static HRESULT (STDMETHODCALLTYPE *oResetList)(ID3D12GraphicsCommandList* self,ID3D12CommandAllocator* allocator,ID3D12PipelineState* pipeline)=nullptr;
static HRESULT STDMETHODCALLTYPE hResetList(ID3D12GraphicsCommandList* self,ID3D12CommandAllocator* allocator,ID3D12PipelineState* pipeline) { Call call;auto result=oResetList(self,allocator,pipeline);if(SUCCEEDED(result))observe([&](BeamRTCapture& h){auto old=h.list(self);if(!old)return;const auto generation=old->generation+1;Command state;state.resource=self;state.pipeline=pipeline;state.generation=generation;*old=state;});return result;}
static void (STDMETHODCALLTYPE *oClearList)(ID3D12GraphicsCommandList* self,ID3D12PipelineState* pipeline)=nullptr;
static void STDMETHODCALLTYPE hClearList(ID3D12GraphicsCommandList* self,ID3D12PipelineState* pipeline) { Call call;oClearList(self,pipeline);observe([&](BeamRTCapture& h){auto old=h.list(self);if(!old)return;const auto generation=old->generation+1;Command state;state.resource=self;state.pipeline=pipeline;state.generation=generation;*old=state;});}
static void (STDMETHODCALLTYPE *oSetHeaps)(ID3D12GraphicsCommandList* self,UINT count,ID3D12DescriptorHeap* const* heaps)=nullptr;
static void STDMETHODCALLTYPE hSetHeaps(ID3D12GraphicsCommandList* self,UINT count,ID3D12DescriptorHeap* const* heaps) {
    Call call;oSetHeaps(self,count,heaps);observe([&](BeamRTCapture& h){
        auto state=h.list(self);if(!state)return;
        if(count>2){state->poisoned=true;return;}
        ComPtr<ID3D12DescriptorHeap> chosen,sampler;
        for(UINT i=0;i<count;++i){const auto type=heaps[i]->GetDesc().Type;
            if(type==D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV)chosen=heaps[i];
            else if(type==D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER)sampler=heaps[i];}
        if(chosen.Get()!=state->heap.Get() || sampler.Get()!=state->samplerHeap.Get()){
            state->graphicsTables.clear();state->computeTables.clear();
        }
        state->heap=chosen;state->samplerHeap=sampler;
    });
}
static void (STDMETHODCALLTYPE *oSetPipeline)(ID3D12GraphicsCommandList* self,ID3D12PipelineState* pipeline)=nullptr;
static void STDMETHODCALLTYPE hSetPipeline(ID3D12GraphicsCommandList* self,ID3D12PipelineState* pipeline) { Call call;oSetPipeline(self,pipeline);observe([&](BeamRTCapture& h){auto state=h.list(self);if(state)state->pipeline=pipeline;});}
static void (STDMETHODCALLTYPE *oSetGraphicsRoot)(ID3D12GraphicsCommandList* self,ID3D12RootSignature* root)=nullptr;
static void STDMETHODCALLTYPE hSetGraphicsRoot(ID3D12GraphicsCommandList* self,ID3D12RootSignature* root) { Call call;oSetGraphicsRoot(self,root);observe([&](BeamRTCapture& h){auto state=h.list(self);if(!state)return;if(state->graphicsRoot.Get()!=root)state->graphicsTables.clear();state->graphicsRoot=root;});}
static void (STDMETHODCALLTYPE *oSetComputeRoot)(ID3D12GraphicsCommandList* self,ID3D12RootSignature* root)=nullptr;
static void STDMETHODCALLTYPE hSetComputeRoot(ID3D12GraphicsCommandList* self,ID3D12RootSignature* root) { Call call;oSetComputeRoot(self,root);observe([&](BeamRTCapture& h){auto state=h.list(self);if(!state)return;if(state->computeRoot.Get()!=root)state->computeTables.clear();state->computeRoot=root;});}
static void (STDMETHODCALLTYPE *oSetGraphicsTable)(ID3D12GraphicsCommandList* self,UINT parameter,D3D12_GPU_DESCRIPTOR_HANDLE handle)=nullptr;
static void STDMETHODCALLTYPE hSetGraphicsTable(ID3D12GraphicsCommandList* self,UINT parameter,D3D12_GPU_DESCRIPTOR_HANDLE handle) { Call call;oSetGraphicsTable(self,parameter,handle);observe([&](BeamRTCapture& h){auto state=h.list(self);if(state && parameter<64)state->graphicsTables[parameter]=handle.ptr;});}
static void (STDMETHODCALLTYPE *oSetComputeTable)(ID3D12GraphicsCommandList* self,UINT parameter,D3D12_GPU_DESCRIPTOR_HANDLE handle)=nullptr;
static void STDMETHODCALLTYPE hSetComputeTable(ID3D12GraphicsCommandList* self,UINT parameter,D3D12_GPU_DESCRIPTOR_HANDLE handle) { Call call;oSetComputeTable(self,parameter,handle);observe([&](BeamRTCapture& h){auto state=h.list(self);if(state && parameter<64)state->computeTables[parameter]=handle.ptr;});}
static void (STDMETHODCALLTYPE *oDraw)(ID3D12GraphicsCommandList* self,UINT vertices,UINT instances,UINT vertexStart,UINT instanceStart)=nullptr;
static void STDMETHODCALLTYPE hDraw(ID3D12GraphicsCommandList* self,UINT vertices,UINT instances,UINT vertexStart,UINT instanceStart) { Call call;oDraw(self,vertices,instances,vertexStart,instanceStart);observe([&](BeamRTCapture& h){h.target(self,1);});}
static void (STDMETHODCALLTYPE *oDrawIndexed)(ID3D12GraphicsCommandList* self,UINT indices,UINT instances,UINT indexStart,INT vertexBase,UINT instanceStart)=nullptr;
static void STDMETHODCALLTYPE hDrawIndexed(ID3D12GraphicsCommandList* self,UINT indices,UINT instances,UINT indexStart,INT vertexBase,UINT instanceStart) { Call call;oDrawIndexed(self,indices,instances,indexStart,vertexBase,instanceStart);observe([&](BeamRTCapture& h){h.target(self,1);});}
static void (STDMETHODCALLTYPE *oDispatch)(ID3D12GraphicsCommandList* self,UINT x,UINT y,UINT z)=nullptr;
static void STDMETHODCALLTYPE hDispatch(ID3D12GraphicsCommandList* self,UINT x,UINT y,UINT z) { Call call;oDispatch(self,x,y,z);observe([&](BeamRTCapture& h){h.target(self,2);});}
static void (STDMETHODCALLTYPE *oBundle)(ID3D12GraphicsCommandList* self,ID3D12GraphicsCommandList* bundle)=nullptr;
static void STDMETHODCALLTYPE hBundle(ID3D12GraphicsCommandList* self,ID3D12GraphicsCommandList* bundle) { Call call;oBundle(self,bundle);observe([&](BeamRTCapture& h){auto state=h.list(self);if(state)state->poisoned=true;});}
static void (STDMETHODCALLTYPE *oIndirect)(ID3D12GraphicsCommandList* self,ID3D12CommandSignature* signature,UINT count,ID3D12Resource* args,UINT64 argsOffset,ID3D12Resource* counter,UINT64 countOffset)=nullptr;
static void STDMETHODCALLTYPE hIndirect(ID3D12GraphicsCommandList* self,ID3D12CommandSignature* signature,UINT count,ID3D12Resource* args,UINT64 argsOffset,ID3D12Resource* counter,UINT64 countOffset) { Call call;oIndirect(self,signature,count,args,argsOffset,counter,countOffset);observe([&](BeamRTCapture& h){auto state=h.list(self);if(state)state->poisoned=true;});}
static void (STDMETHODCALLTYPE *oExecuteLists)(ID3D12CommandQueue* self,UINT count,ID3D12CommandList* const* lists)=nullptr;
static void STDMETHODCALLTYPE hExecuteLists(ID3D12CommandQueue* self,UINT count,ID3D12CommandList* const* lists) { Call call;observe([&](BeamRTCapture& h){if(h.owns(self))h.submit(self,count,lists);});oExecuteLists(self,count,lists);}
struct Hook { PVOID* original;PVOID replacement; };
static Hook hooks[]={
    {reinterpret_cast<PVOID*>(&oCreateHeap),reinterpret_cast<PVOID>(hCreateHeap)},
    {reinterpret_cast<PVOID*>(&oCreateSRV),reinterpret_cast<PVOID>(hCreateSRV)},
    {reinterpret_cast<PVOID*>(&oCreateCBV),reinterpret_cast<PVOID>(hCreateCBV)},
    {reinterpret_cast<PVOID*>(&oCreateUAV),reinterpret_cast<PVOID>(hCreateUAV)},
    {reinterpret_cast<PVOID*>(&oCopySimple),reinterpret_cast<PVOID>(hCopySimple)},
    {reinterpret_cast<PVOID*>(&oCopyRanges),reinterpret_cast<PVOID>(hCopyRanges)},
    {reinterpret_cast<PVOID*>(&oCreateRoot),reinterpret_cast<PVOID>(hCreateRoot)},
    {reinterpret_cast<PVOID*>(&oCreateGraphics),reinterpret_cast<PVOID>(hCreateGraphics)},
    {reinterpret_cast<PVOID*>(&oCreateCompute),reinterpret_cast<PVOID>(hCreateCompute)},
    {reinterpret_cast<PVOID*>(&oCreateList),reinterpret_cast<PVOID>(hCreateList)},
    {reinterpret_cast<PVOID*>(&oResetList),reinterpret_cast<PVOID>(hResetList)},
    {reinterpret_cast<PVOID*>(&oClearList),reinterpret_cast<PVOID>(hClearList)},
    {reinterpret_cast<PVOID*>(&oSetHeaps),reinterpret_cast<PVOID>(hSetHeaps)},
    {reinterpret_cast<PVOID*>(&oSetPipeline),reinterpret_cast<PVOID>(hSetPipeline)},
    {reinterpret_cast<PVOID*>(&oSetGraphicsRoot),reinterpret_cast<PVOID>(hSetGraphicsRoot)},
    {reinterpret_cast<PVOID*>(&oSetComputeRoot),reinterpret_cast<PVOID>(hSetComputeRoot)},
    {reinterpret_cast<PVOID*>(&oSetGraphicsTable),reinterpret_cast<PVOID>(hSetGraphicsTable)},
    {reinterpret_cast<PVOID*>(&oSetComputeTable),reinterpret_cast<PVOID>(hSetComputeTable)},
    {reinterpret_cast<PVOID*>(&oDraw),reinterpret_cast<PVOID>(hDraw)},
    {reinterpret_cast<PVOID*>(&oDrawIndexed),reinterpret_cast<PVOID>(hDrawIndexed)},
    {reinterpret_cast<PVOID*>(&oDispatch),reinterpret_cast<PVOID>(hDispatch)},
    {reinterpret_cast<PVOID*>(&oBundle),reinterpret_cast<PVOID>(hBundle)},
    {reinterpret_cast<PVOID*>(&oIndirect),reinterpret_cast<PVOID>(hIndirect)},
    {reinterpret_cast<PVOID*>(&oExecuteLists),reinterpret_cast<PVOID>(hExecuteLists)}
};
static_assert(sizeof(hooks)/sizeof(hooks[0])==MethodCount,"SDK hook table");
static void transaction(bool attach) {
    LONG status=DetourTransactionBegin();require(status==NO_ERROR,"DetourTransactionBegin failed");
    status=DetourUpdateThread(GetCurrentThread());
    if(status==NO_ERROR)for(auto& hook:hooks){status=attach?DetourAttach(hook.original,hook.replacement):DetourDetach(hook.original,hook.replacement);if(status!=NO_ERROR)break;}
    if(status!=NO_ERROR){DetourTransactionAbort();throw std::runtime_error("Detours transaction preparation failed "+std::to_string(status));}
    status=DetourTransactionCommit();require(status==NO_ERROR,"Detours transaction commit failed");
}
static void validateRoot(const BeamRTCaptureConfig& c) {
    ComPtr<ID3D12RootSignatureDeserializer> root;
    check(D3D12CreateRootSignatureDeserializer(c.rootSignature,static_cast<SIZE_T>(c.rootSignatureBytes),IID_PPV_ARGS(&root)),"root contract decode");
    const auto desc=root->GetRootSignatureDesc();
    require(c.tableParameter<desc->NumParameters,"table parameter out of range");
    const auto& p=desc->pParameters[c.tableParameter];
    require(p.ParameterType==D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,"SRV descriptor table required");
    UINT end=0;std::set<UINT> valid;
    for(UINT r=0;r<p.DescriptorTable.NumDescriptorRanges;++r){
        const auto& range=p.DescriptorTable.pDescriptorRanges[r];
        require(range.NumDescriptors<=4096,"unbounded root table unsupported");
        UINT first=range.OffsetInDescriptorsFromTableStart==D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND?end:range.OffsetInDescriptorsFromTableStart;
        require(first<=4096 && range.NumDescriptors<=4096-first,"root table budget exceeded");
        if(range.RangeType==D3D12_DESCRIPTOR_RANGE_TYPE_SRV)for(UINT i=0;i<range.NumDescriptors;++i)valid.insert(first+i);
        end=first+range.NumDescriptors;
    }
    std::set<UINT> distinct;
    for(UINT i=0;i<c.inputCount;++i){require(valid.count(c.offsets[i])!=0 && distinct.insert(c.offsets[i]).second,"SRV offset invalid/duplicate");
        require(c.dimensions[i]==D3D12_SRV_DIMENSION_TEXTURE2D || (c.dimensions[i]==D3D12_SRV_DIMENSION_BUFFER && c.formats[i]==DXGI_FORMAT_UNKNOWN),"unsupported input contract");}
}
extern "C" uint32_t BeamRT_CaptureAbiVersion(){return 2;}
extern "C" const char* BeamRT_CaptureLastError(){return lastError.c_str();}
extern "C" int BeamRT_CaptureStart(ID3D12Device* device,const BeamRTCaptureConfig* cfg,uint32_t quiet,BeamRTCapture** out){
    try{
        lastError.clear();require(device && cfg && out && !*out && quiet==1,"valid caller device/config and explicit API quiescence required");
        require(!current.load() && activeCalls==0,"another capture session or callback is active");
        require(cfg->reserved==0 && (cfg->kind==1 || cfg->kind==2) && cfg->inputCount>0 && cfg->inputCount<=8,"unsupported capture ABI fields");
        require(cfg->reserved2==0 && cfg->threadMode<=BEAMRT_CAPTURE_MULTITHREAD,"unsupported capture thread mode/ABI fields");
        require(cfg->shader && cfg->shaderBytes>0 && cfg->shaderBytes<=16*1024*1024 && cfg->rootSignature && cfg->rootSignatureBytes>0 && cfg->rootSignatureBytes<=256*1024,"exact shader/root bytecode required");
        validateRoot(*cfg);check(device->GetDeviceRemovedReason(),"caller device");
        auto h=std::make_unique<BeamRTCapture>();h->device=device;h->thread=GetCurrentThreadId();h->config=*cfg;
        h->shader.assign(static_cast<const uint8_t*>(cfg->shader),static_cast<const uint8_t*>(cfg->shader)+cfg->shaderBytes);
        h->root.assign(static_cast<const uint8_t*>(cfg->rootSignature),static_cast<const uint8_t*>(cfg->rootSignature)+cfg->rootSignatureBytes);
        // Discover PUBLIC COM method implementations from empty SDK objects.
        // No new device, GPU submission, proxy DLL, engine scan or DllMain work.
        ComPtr<ID3D12CommandAllocator> allocator;ComPtr<ID3D12GraphicsCommandList> list;ComPtr<ID3D12CommandQueue> queue;
        check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)),"method-discovery allocator");
        check(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&list)),"method-discovery list");check(list->Close(),"discovery list close");
        D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;check(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)),"method-discovery queue");
        std::set<PVOID> distinct;
        for(unsigned i=0;i<MethodCount;++i){PVOID address=beamrtSDKMethod(device,list.Get(),queue.Get(),i);require(address && distinct.insert(address).second,"aliased/missing SDK method implementation unsupported");*hooks[i].original=address;}
        current=h.get();try{transaction(true);}catch(...){current=nullptr;throw;}
        *out=h.release();return 0;
    }catch(const std::exception& e){lastError=e.what();return -1;}
}
extern "C" int BeamRT_CaptureGetStatus(BeamRTCapture* h,BeamRTCaptureStatus* out){
    Call call;
    try{lastError.clear();require(h && h==current.load() && out,"active host/status required");std::lock_guard<std::mutex> lock(h->mutex);
        *out={h->calls,h->matched,h->captured,1,h->healthy?1u:0u,h->latest?1u:0u,0,h->config.threadMode,static_cast<uint32_t>(h->queues.size())};return 0;
    }catch(const std::exception& e){lastError=e.what();return -1;}
}
extern "C" int BeamRT_CaptureGetSnapshot(BeamRTCapture* h,BeamRTCaptureSnapshot** out){
    Call call;
    try{lastError.clear();require(h && h==current.load() && out && !*out,"active host/null snapshot output required");std::lock_guard<std::mutex> lock(h->mutex);
        require(h->healthy && bool(h->latest),h->reason.c_str());*out=new BeamRTCaptureSnapshot(*h->latest);return 0;
    }catch(const std::exception& e){lastError=e.what();return -1;}
}
extern "C" int BeamRT_CaptureGetSnapshotForQueue(BeamRTCapture* h,ID3D12CommandQueue* queue,BeamRTCaptureSnapshot** out){
    Call call;
    try{
        lastError.clear();require(h && h==current.load() && queue && out && !*out,"active host/queue/null snapshot output required");
        std::lock_guard<std::mutex> lock(h->mutex);
        require(h->healthy,"capture unhealthy; queue snapshot unavailable");
        require(h->owns(queue),"foreign-device queue rejected");
        auto found=h->queues.find(queue);
        require(found!=h->queues.end() && bool(found->second.latest),"no valid matching submission on the requested queue");
        *out=new BeamRTCaptureSnapshot(*found->second.latest);return 0;
    }catch(const std::exception& e){lastError=e.what();return -1;}
}
extern "C" int BeamRT_CaptureReadSnapshot(BeamRTCaptureSnapshot* snapshot,BeamRTCaptureInfo* out){
    try{lastError.clear();require(snapshot && out,"snapshot/info required");*out=snapshot->info;return 0;}catch(const std::exception& e){lastError=e.what();return -1;}
}
extern "C" void BeamRT_CaptureReleaseSnapshot(BeamRTCaptureSnapshot** snapshot){if(snapshot){delete *snapshot;*snapshot=nullptr;}}
extern "C" int BeamRT_CaptureStop(BeamRTCapture** out,uint32_t quiet){
    try{lastError.clear();require(out && quiet==1,"explicit API quiescence required");if(!*out)return 0;auto h=*out;
        require(h==current.load() && GetCurrentThreadId()==h->thread && activeCalls==0,"detach requires original caller and quiescent API threads");
        transaction(false);current=nullptr;delete h;*out=nullptr;return 0;
    }catch(const std::exception& e){lastError=e.what();return -1;}
}
