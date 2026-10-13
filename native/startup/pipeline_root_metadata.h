#pragma once
#include "pipeline_audit.h"
#include <wrl/client.h>
#include <atomic>
#include <memory>
#include <vector>
#include <cstring>
#include <mutex>
#include <unordered_set>

// CPU evidence only. No root/device reference, GPU allocation or completion
// inference. Published audit storage is process-lifetime; tag destructors can
// run on any native thread and must never acquire the audit metadata lock.
struct RootBudget {
    std::atomic<uint64_t> bytes{0},peak{0};
    std::atomic<uint32_t> layouts{0},tags{0};
    std::mutex registryLock;std::unordered_set<IUnknown*> known;
    bool reserve(uint64_t count){
        auto prior=bytes.load();
        do {if(count>beamrtPipelineMetadataBudget-prior)return false;}
        while(!bytes.compare_exchange_weak(prior,prior+count));
        auto high=peak.load();while(high<prior+count && !peak.compare_exchange_weak(high,prior+count)){}
        return true;
    }
};
struct RootCharge {
    RootBudget& budget;uint64_t bytes;
    RootCharge(RootBudget& b,uint64_t n):budget(b),bytes(n){}
    ~RootCharge(){budget.bytes.fetch_sub(bytes);}
    RootCharge(const RootCharge&)=delete;RootCharge& operator=(const RootCharge&)=delete;
};
struct RootRecord {
    RootCharge charge;std::unique_ptr<uint8_t[]> data;uint32_t count;
    RootRecord(RootBudget& budget,const void* bytes,uint32_t size,uint64_t cost)
        :charge(budget,cost),data(new uint8_t[size]),count(size){
        std::memcpy(data.get(),bytes,size);budget.layouts.fetch_add(1);
    }
    ~RootRecord(){charge.budget.layouts.fetch_sub(1);}
};
struct __declspec(uuid("7483D719-600B-4E47-908C-5B7C1BC3A27F")) RootEvidenceInterface : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE read(const void* session,const uint8_t** bytes,uint32_t* count)=0;
};
class RootEvidence final : public RootEvidenceInterface {
    volatile LONG refs=1;RootCharge charge;const void* session;
    std::shared_ptr<RootRecord> record;
public:
    RootEvidence(RootBudget& b,const void* owner,std::shared_ptr<RootRecord> value)
        :charge(b,0),session(owner),record(std::move(value)){
        std::lock_guard<std::mutex> lock(b.registryLock);b.known.insert(static_cast<RootEvidenceInterface*>(this));b.tags.fetch_add(1);
    }
    void acceptCharge(uint64_t size){charge.bytes=size;}
    ~RootEvidence(){auto& b=charge.budget;std::lock_guard<std::mutex> lock(b.registryLock);
        b.known.erase(static_cast<RootEvidenceInterface*>(this));b.tags.fetch_sub(1);}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out) override {
        if(!out)return E_POINTER;*out=nullptr;
        if(iid!=__uuidof(IUnknown) && iid!=__uuidof(RootEvidenceInterface))return E_NOINTERFACE;
        *out=static_cast<RootEvidenceInterface*>(this);AddRef();return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override {return static_cast<ULONG>(InterlockedIncrement(&refs));}
    ULONG STDMETHODCALLTYPE Release() override {
        const auto left=InterlockedDecrement(&refs);if(!left)delete this;return static_cast<ULONG>(left);
    }
    HRESULT STDMETHODCALLTYPE read(const void* owner,const uint8_t** bytes,uint32_t* count) override {
        if(!bytes || !count)return E_POINTER;*bytes=nullptr;*count=0;
        if(owner!=session)return E_ACCESSDENIED;
        *bytes=record->data.get();*count=record->count;return S_OK;
    }
};
// GetPrivateData AddRefs an interface previously stored with
// SetPrivateDataInterface. Attach exactly that returned reference, not another.
// A wrong-size/raw/foreign tag is conflict evidence, never a guessed layout.
inline HRESULT rootEvidence(RootBudget& budget,ID3D12RootSignature* root,Microsoft::WRL::ComPtr<RootEvidenceInterface>& evidence){
    evidence.Reset();if(!root)return E_INVALIDARG;
    UINT size=0;auto result=root->GetPrivateData(beamrtPipelineRootEvidenceGuid,&size,nullptr);
    if(result==DXGI_ERROR_NOT_FOUND)return S_FALSE;
    if(FAILED(result) && result!=DXGI_ERROR_MORE_DATA)return result;if(size!=sizeof(IUnknown*))return E_INVALIDARG;
    IUnknown* pointer=nullptr;result=root->GetPrivateData(beamrtPipelineRootEvidenceGuid,&size,&pointer);
    if(FAILED(result))return result;if(size!=sizeof(pointer) || !pointer)return E_INVALIDARG;
    {std::lock_guard<std::mutex> lock(budget.registryLock);
        // Never invoke a raw/foreign pointer. A conflicting unknown interface
        // cannot safely be Released either; invalidate once and stop observing.
        if(!budget.known.count(pointer))return E_INVALIDARG;}
    Microsoft::WRL::ComPtr<IUnknown> object;object.Attach(pointer);
    return object.As(&evidence);
}
struct RootMetadata {
    RootBudget budget;
    std::vector<std::weak_ptr<RootRecord>> cache;
    void prune(){for(auto it=cache.begin();it!=cache.end();)if(it->expired())it=cache.erase(it);else ++it;}
    // S_FALSE means bounded pressure; the new root stays unclassified.
    HRESULT attach(ID3D12RootSignature* root,const void* owner,const void* bytes,uint32_t count,uint64_t& evictions){
        Microsoft::WRL::ComPtr<RootEvidenceInterface> existing;auto result=rootEvidence(budget,root,existing);
        if(FAILED(result))return result;
        if(existing){const uint8_t* data=nullptr;uint32_t size=0;result=existing->read(owner,&data,&size);
            return SUCCEEDED(result) && size==count && std::memcmp(data,bytes,count)==0?S_OK:E_INVALIDARG;}
        std::shared_ptr<RootRecord> record;
        for(auto it=cache.begin();it!=cache.end();){auto live=it->lock();
            if(!live){it=cache.erase(it);continue;}
            if(live->count==count && std::memcmp(live->data.get(),bytes,count)==0)record=std::move(live);
            ++it;
        }
        if(!record){
            // Includes record/control-block allowance and tag storage. This is
            // accounted CPU storage, not a claim about allocator/GPU overhead.
            const uint64_t cost=sizeof(RootRecord)+64ull+count;
            if(!budget.reserve(cost))return S_FALSE;
            // Charge exists before any throwing allocation; reserve rolls back
            // exactly once if record construction/control-block allocation fails.
            RootCharge pending(budget,cost);
            auto raw=new RootRecord(budget,bytes,count,0);
            record.reset(raw);raw->charge.bytes=cost;pending.bytes=0;
            if(cache.size()==beamrtPipelineLayoutCacheLimit){cache.erase(cache.begin());++evictions;}
            cache.emplace_back(record);
        }
        const uint64_t tagCost=sizeof(RootEvidence)+64ull; // Registry-entry allowance.
        if(!budget.reserve(tagCost))return S_FALSE;
        RootCharge pending(budget,tagCost);
        auto raw=new RootEvidence(budget,owner,record);raw->acceptCharge(tagCost);pending.bytes=0;
        Microsoft::WRL::ComPtr<RootEvidenceInterface> tag;tag.Attach(raw);
        return root->SetPrivateDataInterface(beamrtPipelineRootEvidenceGuid,tag.Get());
    }
};
