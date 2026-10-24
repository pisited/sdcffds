#pragma once
#include "resource_view_validation.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>

// Internal numeric descriptor storage. Legacy remains the default; compact can
// only be selected by the versioned profiled API/transport. No GI adapter
// capability is implied. Callers independently supply synchronization,
// validated heap extents, lifetime observations and revisions.
namespace beamrt::descriptor_store {
inline constexpr uint32_t legacyLocationLimit=256,compactLocationLimit=1024;
inline constexpr uint32_t arenaBytes=legacyLocationLimit*(sizeof(BeamRTResourceView)+2*sizeof(uint64_t));
struct Limits {uint32_t locations,payloads;};
inline constexpr Limits legacyLimits{legacyLocationLimit,256},compactLimits{compactLocationLimit,256};
enum class Result:uint32_t {Ok,NotFound,Invalid,Capacity,Unhealthy};
enum class Cause:uint32_t {None,Limits,View,Revision,LocationCapacity,PayloadCapacity,ByteCapacity,HeapId,ResourceId};
struct Failure {
    Result result=Result::Ok;Cause cause=Cause::None;
    uint32_t locations=0,payloads=0,usedBytes=0,attemptedLocations=0,attemptedPayloads=0,requiredBytes=0;
};
struct Stats {uint32_t locations,payloads,usedBytes;bool healthy;};

namespace detail {
// Preserve EVERY view byte except the two location-specific fields. In
// particular retain full descriptions, resource lifetime/identity, default-view
// metadata, floating-point bit patterns and padding. Different padding may cost
// sharing, never incorrectly merge two descriptions. No resource-ID-only key.
inline constexpr size_t headBytes=offsetof(BeamRTResourceView,heapId);
inline constexpr size_t middleBegin=offsetof(BeamRTResourceView,resourceId);
inline constexpr size_t middleBytes=offsetof(BeamRTResourceView,revision)-middleBegin;
inline constexpr size_t tailBegin=offsetof(BeamRTResourceView,resource);
inline constexpr size_t tailBytes=sizeof(BeamRTResourceView)-tailBegin;
inline constexpr size_t keyBytes=headBytes+middleBytes+tailBytes;
using Key=std::array<uint8_t,keyBytes>;
struct Payload {Key key{};uint32_t references=0,reserved=0;};
struct Location {uint64_t heap=0,revision=0;uint32_t index=0,payload=0;};
static_assert(std::is_trivially_copyable_v<BeamRTResourceView>);
static_assert(headBytes==16 && middleBegin==24 && middleBytes==16 && tailBegin==48);
static_assert(keyBytes==152 && sizeof(Payload)==160 && sizeof(Location)==24);
static_assert(arenaBytes==47104);
static_assert(arenaBytes==beamrtResourceStorageByteLimit && legacyLocationLimit==256 && compactLocationLimit==1024);
static_assert(legacyLocationLimit*(sizeof(Payload)+sizeof(Location))==arenaBytes,
    "legacy 256 distinct descriptions and locations fit the old 256 full-View byte arena");
inline Key encode(const BeamRTResourceView& view)noexcept{
    Key key{};const auto bytes=reinterpret_cast<const uint8_t*>(&view);
    std::memcpy(key.data(),bytes,headBytes);
    std::memcpy(key.data()+headBytes,bytes+middleBegin,middleBytes);
    std::memcpy(key.data()+headBytes+middleBytes,bytes+tailBegin,tailBytes);return key;
}
inline void decode(const Key& key,const Location& location,BeamRTResourceView& view)noexcept{
    view={};auto bytes=reinterpret_cast<uint8_t*>(&view);
    std::memcpy(bytes,key.data(),headBytes);
    std::memcpy(bytes+middleBegin,key.data()+headBytes,middleBytes);
    std::memcpy(bytes+tailBegin,key.data()+headBytes+middleBytes,tailBytes);
    view.heapId=location.heap;view.revision=location.revision;
}
inline uint64_t resourceId(const Key& key)noexcept{
    uint64_t id=0;std::memcpy(&id,key.data()+headBytes,sizeof(id));return id;
}
} // namespace detail

class Store final {
    Limits limits_;uint32_t locations_=0,payloads_=0;uint64_t lastRevision_=0;
    Failure failure_{};
    // Dense payloads grow from the front, dense locations from the back. Access
    // by memcpy avoids alignment, aliasing and implicit object-lifetime tricks.
    // This is the fixed ARENA budget, plus small explicit Store bookkeeping.
    std::array<uint8_t,arenaBytes> arena_{};
    bool healthy()const noexcept{return failure_.result==Result::Ok;}
    uint32_t used()const noexcept{return static_cast<uint32_t>(payloads_*sizeof(detail::Payload)+locations_*sizeof(detail::Location));}
    Result poison(Result result,Cause cause,uint32_t attemptedLocations=0,uint32_t attemptedPayloads=0,uint32_t requiredBytes=0)noexcept{
        if(healthy())failure_={result,cause,locations_,payloads_,used(),attemptedLocations,attemptedPayloads,requiredBytes};return result;
    }
    detail::Payload payload(uint32_t i)const noexcept{
        detail::Payload value{};std::memcpy(&value,arena_.data()+i*sizeof(value),sizeof(value));return value;
    }
    void payload(uint32_t i,const detail::Payload& value)noexcept{
        std::memcpy(arena_.data()+i*sizeof(value),&value,sizeof(value));
    }
    detail::Location location(uint32_t i)const noexcept{
        detail::Location value{};std::memcpy(&value,arena_.data()+arenaBytes-(i+1)*sizeof(value),sizeof(value));return value;
    }
    void location(uint32_t i,const detail::Location& value)noexcept{
        std::memcpy(arena_.data()+arenaBytes-(i+1)*sizeof(value),&value,sizeof(value));
    }
    uint32_t find(uint64_t heap,uint32_t index)const noexcept{
        for(uint32_t i=0;i<locations_;++i){const auto value=location(i);if(value.heap==heap && value.index==index)return i;}return locations_;
    }
    void eraseAt(uint32_t i)noexcept{
        const auto old=location(i);const auto lastLocation=locations_-1;
        if(i!=lastLocation)location(i,location(lastLocation));
        location(lastLocation,{});--locations_;
        auto oldPayload=payload(old.payload);--oldPayload.references;
        if(oldPayload.references){payload(old.payload,oldPayload);return;}
        const auto lastPayload=payloads_-1;
        if(old.payload!=lastPayload){
            payload(old.payload,payload(lastPayload));
            // No internal slot escapes. Repair every location after compaction;
            // copied-source snapshots held by callers remain full value copies.
            for(uint32_t j=0;j<locations_;++j){auto value=location(j);if(value.payload==lastPayload){value.payload=old.payload;location(j,value);}}
        }
        payload(lastPayload,{});--payloads_;
    }
public:
    explicit Store(Limits limits=legacyLimits)noexcept:limits_(limits){
        if(!limits.locations || limits.locations>compactLocationLimit || !limits.payloads || limits.payloads>256)poison(Result::Invalid,Cause::Limits);
    }
    Store(const Store&)=delete;Store& operator=(const Store&)=delete;
    Stats stats()const noexcept{return {locations_,payloads_,used(),healthy()};}
    Failure failure()const noexcept{return failure_;}
    // Aggregate diagnostics only, available after poisoning without exposing a
    // descriptor or recovering health. No implicit lifetime reaping here.
    uint32_t occupied(uint64_t heap=0)const noexcept{
        if(!heap)return locations_;uint32_t count=0;
        for(uint32_t i=0;i<locations_;++i)if(location(i).heap==heap)++count;return count;
    }
    Result put(uint64_t heap,uint32_t index,const BeamRTResourceView& input)noexcept{
        if(!healthy())return Result::Unhealthy;
        BeamRTResourceView view{};std::memcpy(&view,&input,sizeof(view));view.heapId=heap;
        if(!heap || !beamrtResourceViewValid(view,view.kind))return poison(Result::Invalid,Cause::View);
        if(view.revision<=lastRevision_)return poison(Result::Invalid,Cause::Revision);
        // Snapshot before clearing/repacking. This deliberately has no atomic
        // rollback: any exhaustion poisons reads, as the existing observer does.
        const auto key=detail::encode(view);const auto old=find(heap,index);if(old<locations_)eraseAt(old);
        uint32_t shared=payloads_;
        for(uint32_t i=0;i<payloads_;++i)if(payload(i).key==key){shared=i;break;}
        const bool fresh=shared==payloads_;
        const auto required=used()+static_cast<uint32_t>(sizeof(detail::Location)+(fresh?sizeof(detail::Payload):0));
        const auto attemptedPayloads=payloads_+(fresh?1u:0u);
        if(locations_==limits_.locations)return poison(Result::Capacity,Cause::LocationCapacity,locations_+1,attemptedPayloads,required);
        if(fresh && payloads_==limits_.payloads)return poison(Result::Capacity,Cause::PayloadCapacity,locations_+1,attemptedPayloads,required);
        if(required>arenaBytes)return poison(Result::Capacity,Cause::ByteCapacity,locations_+1,attemptedPayloads,required);
        auto held=fresh?detail::Payload{key,0,0}:payload(shared);++held.references;payload(shared,held);if(fresh)++payloads_;
        location(locations_,{heap,view.revision,index,shared});++locations_;lastRevision_=view.revision;return Result::Ok;
    }
    Result get(uint64_t heap,uint32_t index,BeamRTResourceView& out)const noexcept{
        out={};if(!healthy())return Result::Unhealthy;if(!heap)return Result::Invalid;
        const auto at=find(heap,index);if(at==locations_)return Result::NotFound;
        const auto value=location(at);if(value.payload>=payloads_)return Result::Invalid;
        const auto held=payload(value.payload);if(!held.references || held.reserved)return Result::Invalid;
        detail::decode(held.key,value,out);return Result::Ok;
    }
    Result erase(uint64_t heap,uint32_t index)noexcept{
        if(!healthy())return Result::Unhealthy;if(!heap)return poison(Result::Invalid,Cause::HeapId);
        const auto at=find(heap,index);if(at<locations_)eraseAt(at);return Result::Ok;
    }
    // Retirement is an explicit caller-supplied observation, not a claim that
    // numeric identities retain objects or independently prove destruction.
    Result retireHeap(uint64_t heap)noexcept{
        if(!healthy())return Result::Unhealthy;if(!heap)return poison(Result::Invalid,Cause::HeapId);
        for(uint32_t i=0;i<locations_;)if(location(i).heap==heap)eraseAt(i);else ++i;return Result::Ok;
    }
    Result retireResource(uint64_t resource)noexcept{
        if(!healthy())return Result::Unhealthy;if(!resource)return poison(Result::Invalid,Cause::ResourceId);
        for(uint32_t i=0;i<locations_;)if(detail::resourceId(payload(location(i).payload).key)==resource)eraseAt(i);else ++i;return Result::Ok;
    }
    // The observer may reap its already-observed DEAD lifetime IDs to keep
    // later diagnostic counts current even after failure. These are not general
    // mutation/recovery APIs: no new entry, revision reset or failure replacement.
    // Only the owner holding its metadata lock may supply the death observation.
    Result reapDeadHeap(uint64_t heap)noexcept{
        if(!heap)return Result::Invalid;
        for(uint32_t i=0;i<locations_;)if(location(i).heap==heap)eraseAt(i);else ++i;return Result::Ok;
    }
    Result reapDeadResource(uint64_t resource)noexcept{
        if(!resource)return Result::Invalid;
        for(uint32_t i=0;i<locations_;)if(detail::resourceId(payload(location(i).payload).key)==resource)eraseAt(i);else ++i;return Result::Ok;
    }
};
static_assert(sizeof(Store)<=arenaBytes+64,"bookkeeping must remain small and explicit, not hidden dynamic storage");
} // namespace beamrt::descriptor_store
