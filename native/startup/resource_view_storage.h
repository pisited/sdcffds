#pragma once
#include "descriptor_location_store.h"
#include <type_traits>
#include <variant>

// Internal profile-dispatched backend. Exactly ONE arena is active; public
// receipt/accounting validation remains in the separately versioned contract.
namespace beamrt::resource_view_storage {
namespace old=beamrt::descriptor_store;
namespace interned=beamrt::descriptor_locations;
using Result=interned::Result;using Cause=interned::Cause;
using Stats=interned::Stats;using Failure=interned::Failure;
inline constexpr auto legacyLocationLimit=old::legacyLocationLimit;
inline Result convert(Result result)noexcept{return result;}
inline Result convert(old::Result result)noexcept{
    switch(result){case old::Result::Ok:return Result::Ok;case old::Result::NotFound:return Result::NotFound;
    case old::Result::Invalid:return Result::Invalid;case old::Result::Capacity:return Result::Capacity;
    case old::Result::Unhealthy:return Result::Unhealthy;}return Result::Invalid;
}
inline Cause convert(old::Cause cause)noexcept{
    switch(cause){case old::Cause::None:return Cause::None;case old::Cause::Limits:return Cause::Limits;
    case old::Cause::View:return Cause::View;case old::Cause::Revision:return Cause::Revision;
    case old::Cause::HeapId:return Cause::HeapId;case old::Cause::ResourceId:return Cause::ResourceId;
    case old::Cause::LocationCapacity:return Cause::LocationCapacity;case old::Cause::PayloadCapacity:return Cause::PayloadCapacity;
    case old::Cause::ByteCapacity:return Cause::ByteCapacity;}return Cause::Limits;
}
class Store final {
    std::variant<std::monostate,old::Store,interned::Store> backend_;
    template<class F>Result apply(F&& action)noexcept{
        return std::visit([&](auto& value)->Result{using T=std::decay_t<decltype(value)>;
            if constexpr(std::is_same_v<T,std::monostate>)return Result::Unhealthy;else return convert(action(value));},backend_);
    }
public:
    explicit Store(uint32_t profile)noexcept{
        if(profile==beamrtResourceStorageLegacy)backend_.emplace<old::Store>(old::legacyLimits);
        else if(profile==beamrtResourceStorageCompact)backend_.emplace<old::Store>(old::compactLimits);
        else if(profile==beamrtResourceStorageInterned)backend_.emplace<interned::Store>(interned::defaultLimits);
    }
    Store(const Store&)=delete;Store& operator=(const Store&)=delete;
    Stats stats()const noexcept{
        return std::visit([](const auto& value)->Stats{using T=std::decay_t<decltype(value)>;
            if constexpr(std::is_same_v<T,std::monostate>)return {0,0,0,0,false};
            else if constexpr(std::is_same_v<T,old::Store>){const auto s=value.stats();return {s.locations,s.payloads,0,s.usedBytes,s.healthy};}
            else return value.stats();},backend_);
    }
    Failure failure()const noexcept{
        return std::visit([](const auto& value)->Failure{using T=std::decay_t<decltype(value)>;
            if constexpr(std::is_same_v<T,std::monostate>)return {Result::Unhealthy,Cause::Limits,0,0,0,0,0,0,0,0};
            else if constexpr(std::is_same_v<T,old::Store>){const auto f=value.failure();return {convert(f.result),convert(f.cause),
                f.locations,f.payloads,0,f.usedBytes,f.attemptedLocations,f.attemptedPayloads,0,f.requiredBytes};}
            else return value.failure();},backend_);
    }
    uint32_t occupied(uint64_t heap=0)const noexcept{
        return std::visit([&](const auto& value)->uint32_t{using T=std::decay_t<decltype(value)>;
            if constexpr(std::is_same_v<T,std::monostate>)return 0;else return value.occupied(heap);},backend_);
    }
    Result put(uint64_t heap,uint32_t index,const BeamRTResourceView& value)noexcept{return apply([&](auto& s){return s.put(heap,index,value);});}
    Result get(uint64_t heap,uint32_t index,BeamRTResourceView& out)const noexcept{
        out={};return std::visit([&](const auto& value)->Result{using T=std::decay_t<decltype(value)>;
            if constexpr(std::is_same_v<T,std::monostate>)return Result::Unhealthy;else return convert(value.get(heap,index,out));},backend_);
    }
    Result erase(uint64_t heap,uint32_t index)noexcept{return apply([&](auto& s){return s.erase(heap,index);});}
    Result reapDeadHeap(uint64_t heap)noexcept{return apply([&](auto& s){return s.reapDeadHeap(heap);});}
    Result reapDeadResource(uint64_t id)noexcept{return apply([&](auto& s){return s.reapDeadResource(id);});}
};
static_assert(sizeof(Store)<=interned::arenaBytes+128,"one arena plus bounded variant/bookkeeping, never both arenas");
} // namespace beamrt::resource_view_storage
