#pragma once
#include "descriptor_view_store.h"
#include <array>
#include <cstdint>
#include <cstring>

// Exact bounded representation used only by the explicit interned profile2.
// Legacy/compact keep their old Store. Counts/byte accounting differ from ABI6
// and must never be silently substituted behind its existing validators.
namespace beamrt::descriptor_locations {
namespace raw=beamrt::descriptor_store::detail;
inline constexpr uint32_t arenaBytes=47104,directoryBytes=512,locationBytes=14,payloadBytes=160;
inline constexpr uint32_t logicalLocationLimit=4096,heapLimit=32;
struct Limits {uint32_t locations,payloads,heaps;};
inline constexpr Limits defaultLimits{logicalLocationLimit,256,heapLimit};
enum class Result:uint32_t {Ok,NotFound,Invalid,Capacity,Unhealthy};
enum class Cause:uint32_t {None,Limits,View,Revision,HeapId,ResourceId,LocationCapacity,HeapCapacity,PayloadCapacity,ByteCapacity};
struct Failure {
    Result result=Result::Ok;Cause cause=Cause::None;
    uint32_t locations=0,payloads=0,heaps=0,usedBytes=0;
    uint32_t attemptedLocations=0,attemptedPayloads=0,attemptedHeaps=0,requiredBytes=0;
};
struct Stats {uint32_t locations,payloads,heaps,usedBytes;bool healthy;};
namespace detail {
// Full lifetime IDs live in the fixed directory, never truncated to a slot.
// A slot is released only after its LAST logical location has disappeared.
struct Heap {uint64_t id=0;uint32_t references=0,reserved=0;};
// This aligned local value is NOT the serialized representation. Serialize each
// field with memcpy: heapSlot8 / payloadSlot8 / index32 / revision64 =14 bytes.
struct Location {uint8_t heap=0,payload=0;uint32_t index=0;uint64_t revision=0;};
static_assert(sizeof(Heap)==16 && directoryBytes==heapLimit*sizeof(Heap));
static_assert(sizeof(raw::Payload)==payloadBytes && raw::keyBytes==152);
static_assert(locationBytes==2*sizeof(uint8_t)+sizeof(uint32_t)+sizeof(uint64_t));
}

class Store final {
    Limits limits_;uint32_t locations_=0,payloads_=0,heaps_=0;uint64_t lastRevision_=0;
    Failure failure_{};
    // The heap directory is INSIDE this budget. Payloads grow forward after
    // it; densely serialized locations grow backward. No hidden heap table.
    std::array<uint8_t,arenaBytes> arena_{};
    bool healthy()const noexcept{return failure_.result==Result::Ok;}
    uint32_t used()const noexcept{return directoryBytes+payloads_*payloadBytes+locations_*locationBytes;}
    Result poison(Result result,Cause cause,uint32_t attemptedLocations=0,uint32_t attemptedPayloads=0,
        uint32_t attemptedHeaps=0,uint32_t requiredBytes=0)noexcept{
        if(healthy())failure_={result,cause,locations_,payloads_,heaps_,used(),attemptedLocations,attemptedPayloads,attemptedHeaps,requiredBytes};
        return result;
    }
    detail::Heap heap(uint32_t i)const noexcept{
        detail::Heap out{};std::memcpy(&out,arena_.data()+i*sizeof(out),sizeof(out));return out;
    }
    void heap(uint32_t i,const detail::Heap& value)noexcept{
        std::memcpy(arena_.data()+i*sizeof(value),&value,sizeof(value));
    }
    uint32_t heapSlot(uint64_t id)const noexcept{
        // Always bounded by the physical directory, including diagnostics on
        // an instance poisoned at construction for invalid configured limits.
        for(uint32_t i=0;i<heapLimit;++i)if(heap(i).id==id)return i;return heapLimit;
    }
    raw::Payload payload(uint32_t i)const noexcept{
        raw::Payload out{};std::memcpy(&out,arena_.data()+directoryBytes+i*payloadBytes,sizeof(out));return out;
    }
    void payload(uint32_t i,const raw::Payload& value)noexcept{
        std::memcpy(arena_.data()+directoryBytes+i*payloadBytes,&value,sizeof(value));
    }
    detail::Location location(uint32_t i)const noexcept{
        detail::Location out{};const auto bytes=arena_.data()+arenaBytes-(i+1)*locationBytes;
        std::memcpy(&out.heap,bytes,1);std::memcpy(&out.payload,bytes+1,1);
        std::memcpy(&out.index,bytes+2,4);std::memcpy(&out.revision,bytes+6,8);return out;
    }
    void location(uint32_t i,const detail::Location& value)noexcept{
        auto bytes=arena_.data()+arenaBytes-(i+1)*locationBytes;
        std::memcpy(bytes,&value.heap,1);std::memcpy(bytes+1,&value.payload,1);
        std::memcpy(bytes+2,&value.index,4);std::memcpy(bytes+6,&value.revision,8);
    }
    uint32_t find(uint64_t id,uint32_t index)const noexcept{
        const auto at=heapSlot(id);if(at==heapLimit)return locations_;
        for(uint32_t i=0;i<locations_;++i){const auto value=location(i);if(value.heap==at && value.index==index)return i;}return locations_;
    }
    void eraseAt(uint32_t i)noexcept{
        const auto old=location(i);const auto lastLocation=locations_-1;
        if(i!=lastLocation)location(i,location(lastLocation));location(lastLocation,{});--locations_;
        auto held=payload(old.payload);--held.references;
        if(held.references)payload(old.payload,held);
        else{
            const auto lastPayload=payloads_-1;
            if(old.payload!=lastPayload){
                payload(old.payload,payload(lastPayload));
                // No internal payload index escapes. Repair ALL locations that
                // reference the moved final payload, not just the first copy.
                for(uint32_t j=0;j<locations_;++j){auto value=location(j);if(value.payload==lastPayload){
                    value.payload=old.payload;location(j,value);}}
            }
            payload(lastPayload,{});--payloads_;
        }
        auto h=heap(old.heap);--h.references;
        if(h.references)heap(old.heap,h);else{heap(old.heap,{});--heaps_;}
    }
public:
    explicit Store(Limits limits=defaultLimits)noexcept:limits_(limits){
        if(!limits.locations || limits.locations>logicalLocationLimit || !limits.payloads || limits.payloads>256
            || !limits.heaps || limits.heaps>heapLimit)poison(Result::Invalid,Cause::Limits);
    }
    Store(const Store&)=delete;Store& operator=(const Store&)=delete;
    Stats stats()const noexcept{return {locations_,payloads_,heaps_,used(),healthy()};}
    Failure failure()const noexcept{return failure_;}
    uint32_t occupied(uint64_t id=0)const noexcept{
        if(!id)return locations_;const auto at=heapSlot(id);return at<heapLimit?heap(at).references:0;
    }
    Result put(uint64_t id,uint32_t index,const BeamRTResourceView& input)noexcept{
        if(!healthy())return Result::Unhealthy;
        BeamRTResourceView view{};std::memcpy(&view,&input,sizeof(view));view.heapId=id;
        if(!id || !beamrtResourceViewValid(view,view.kind))return poison(Result::Invalid,Cause::View);
        if(view.revision<=lastRevision_)return poison(Result::Invalid,Cause::Revision);
        // Capture all full view bytes BEFORE clearing. As in the existing
        // primitive, a failed insert is not an atomic rollback of an overwrite.
        const auto key=raw::encode(view);const auto old=find(id,index);if(old<locations_)eraseAt(old);
        auto h=heapSlot(id);const bool freshHeap=h==heapLimit;
        uint32_t shared=payloads_;for(uint32_t i=0;i<payloads_;++i)if(payload(i).key==key){shared=i;break;}
        const bool freshPayload=shared==payloads_;
        const uint32_t attemptedLocations=locations_+1,attemptedPayloads=payloads_+(freshPayload?1u:0u),attemptedHeaps=heaps_+(freshHeap?1u:0u);
        const auto required=directoryBytes+attemptedPayloads*payloadBytes+attemptedLocations*locationBytes;
        // Explicit CPU-only work/directory/payload/byte bounds. No eviction,
        // fallback allocation, ID truncation or fabricated known-null location.
        if(attemptedLocations>limits_.locations)return poison(Result::Capacity,Cause::LocationCapacity,attemptedLocations,attemptedPayloads,attemptedHeaps,required);
        if(attemptedHeaps>limits_.heaps)return poison(Result::Capacity,Cause::HeapCapacity,attemptedLocations,attemptedPayloads,attemptedHeaps,required);
        if(attemptedPayloads>limits_.payloads)return poison(Result::Capacity,Cause::PayloadCapacity,attemptedLocations,attemptedPayloads,attemptedHeaps,required);
        if(required>arenaBytes)return poison(Result::Capacity,Cause::ByteCapacity,attemptedLocations,attemptedPayloads,attemptedHeaps,required);
        if(freshHeap){for(h=0;h<limits_.heaps;++h)if(!heap(h).id)break;
            if(h>=limits_.heaps)return poison(Result::Invalid,Cause::HeapId);
            heap(h,{id,0,0});++heaps_;
        }
        auto held=freshPayload?raw::Payload{key,0,0}:payload(shared);++held.references;payload(shared,held);if(freshPayload)++payloads_;
        auto directory=heap(h);++directory.references;heap(h,directory);
        // Counts 32 and 256 are NOT serialized as sentinel slots: successful
        // lookup/allocation above yields actual indexes 0..31 and 0..255.
        location(locations_,{static_cast<uint8_t>(h),static_cast<uint8_t>(shared),index,view.revision});
        ++locations_;lastRevision_=view.revision;return Result::Ok;
    }
    Result get(uint64_t id,uint32_t index,BeamRTResourceView& out)const noexcept{
        out={};if(!healthy())return Result::Unhealthy;if(!id)return Result::Invalid;
        const auto at=find(id,index);if(at==locations_)return Result::NotFound;
        const auto value=location(at);if(value.heap>=heapLimit || value.payload>=payloads_)return Result::Invalid;
        const auto h=heap(value.heap);const auto held=payload(value.payload);
        if(h.id!=id || !h.references || h.reserved || !held.references || held.reserved)return Result::Invalid;
        raw::decode(held.key,{h.id,value.revision,value.index,value.payload},out);return Result::Ok;
    }
    Result erase(uint64_t id,uint32_t index)noexcept{
        if(!healthy())return Result::Unhealthy;if(!id)return poison(Result::Invalid,Cause::HeapId);
        const auto at=find(id,index);if(at<locations_)eraseAt(at);return Result::Ok;
    }
    // Lifetime observations remain the caller's responsibility. Full numeric
    // IDs and refcounts do not retain native heaps/resources or certify death.
    Result retireHeap(uint64_t id)noexcept{
        if(!healthy())return Result::Unhealthy;if(!id)return poison(Result::Invalid,Cause::HeapId);
        return reapDeadHeap(id);
    }
    Result retireResource(uint64_t id)noexcept{
        if(!healthy())return Result::Unhealthy;if(!id)return poison(Result::Invalid,Cause::ResourceId);
        return reapDeadResource(id);
    }
    Result reapDeadHeap(uint64_t id)noexcept{
        if(!id)return Result::Invalid;const auto at=heapSlot(id);if(at==heapLimit)return Result::Ok;
        for(uint32_t i=0;i<locations_;)if(location(i).heap==at)eraseAt(i);else ++i;return Result::Ok;
    }
    Result reapDeadResource(uint64_t id)noexcept{
        if(!id)return Result::Invalid;
        for(uint32_t i=0;i<locations_;)if(raw::resourceId(payload(location(i).payload).key)==id)eraseAt(i);else ++i;return Result::Ok;
    }
};
static_assert(sizeof(Store)<=arenaBytes+80,"explicit small bookkeeping outside the fixed arena, no hidden allocation");
} // namespace beamrt::descriptor_locations
