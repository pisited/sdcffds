#pragma once
// Fixture-only interval model. Never linked into the observer or startup DLL.
// Caller identities and lifecycle boundaries are supplied by the owned fixture.
// No driver calls, resource pointers, GPU proof, or game handoff authorization.
#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace beamrt_fixture {
inline constexpr uint32_t listLimit=4,tokenLimit=8,invalidSlot=UINT32_MAX;
struct Limits {
    uint64_t tickets=UINT64_MAX,generations=UINT64_MAX,publications=UINT64_MAX,counters=UINT64_MAX;
};
struct Token {
    uint32_t slot=invalidSlot;
    uint64_t ticket=0,list=0,generation=0,caller=0;
};
struct Receipt {
    uint64_t list=0,generation=0,serial=0,caller=0;
    uint32_t value=0;
};
struct ListStatus {
    uint64_t generation=1,lastCaller=0,threadChanges=0,callbackOverlaps=0,forwardingSpanOverlaps=0,reentries=0;
    uint32_t active=0;
    bool recording=true,uncertain=false;
};
enum class Phase:uint8_t {Entered,Forwarding,NativeReturned,MetadataUpdated};
struct Entry {
    Token token{};
    Phase phase=Phase::Entered;
    uint32_t value=0;
    bool used=false;
};

class IntervalModel final {
    std::mutex mutex;
    std::array<ListStatus,listLimit> lists{};
    std::array<Entry,tokenLimit> entries{};
    Limits limits;
    Receipt latest{};
    uint64_t ticket=0,serial=0;
    bool enabled=true,healthy=true,available=false;

    ListStatus* list(uint64_t id){return id && id<=listLimit?&lists[static_cast<std::size_t>(id-1)]:nullptr;}
    void invalidate(uint64_t id){auto* s=list(id);if(!s){healthy=false;available=false;return;}
        s->uncertain=true;if(latest.list==id)available=false;}
    void fatal(){healthy=false;available=false;}
    bool increment(uint64_t& value){if(value==limits.counters){fatal();return false;}++value;return true;}
    Entry* lookup(const Token& t,uint64_t caller){
        if(t.slot>=tokenLimit || !caller){fatal();return nullptr;}
        auto& e=entries[t.slot];
        if(!e.used || !t.ticket || e.token.ticket!=t.ticket || e.token.list!=t.list
            || e.token.generation!=t.generation || e.token.caller!=t.caller || caller!=t.caller){fatal();return nullptr;}
        auto* s=list(t.list);if(!s || s->generation!=t.generation){fatal();return nullptr;}return &e;
    }
    bool advance(const Token& t,uint64_t caller,Phase before,Phase after){
        auto* e=lookup(t,caller);if(!e)return false;
        if(e->phase!=before){invalidate(t.list);return false;}e->phase=after;
        return enabled && healthy && !list(t.list)->uncertain;
    }
public:
    explicit IntervalModel(Limits bounds={}):limits(bounds){if(!limits.generations)fatal();}
    IntervalModel(const IntervalModel&)=delete;
    IntervalModel& operator=(const IntervalModel&)=delete;

    Token enter(uint64_t id,uint64_t caller){std::lock_guard<std::mutex> guard(mutex);
        auto* s=list(id);if(!s || !caller){fatal();return {};}
        if(!enabled || !healthy)return {};
        if(!s->recording){invalidate(id);return {};}
        if(ticket==limits.tickets){fatal();return {};}
        uint32_t slot=0;for(;slot<tokenLimit && entries[slot].used;++slot){}
        if(slot==tokenLimit){invalidate(id);return {};}
        if(s->active){invalidate(id);if(!increment(s->callbackOverlaps))return {};
            bool reentry=false;for(const auto& e:entries)if(e.used && e.token.list==id && e.token.caller==caller)reentry=true;
            if(reentry && !increment(s->reentries))return {};}
        Token t{slot,++ticket,id,s->generation,caller};entries[slot]={t,Phase::Entered,0,true};++s->active;return t;
    }
    bool forwarding(const Token& t,uint64_t caller){std::lock_guard<std::mutex> guard(mutex);
        auto* e=lookup(t,caller);if(!e)return false;
        if(e->phase!=Phase::Entered){invalidate(t.list);return false;}
        bool overlap=false;for(const auto& other:entries)if(other.used && other.token.ticket!=t.ticket
            && other.token.list==t.list && other.phase==Phase::Forwarding)overlap=true;
        if(overlap){invalidate(t.list);if(!increment(list(t.list)->forwardingSpanOverlaps))return false;}
        e->phase=Phase::Forwarding;return enabled && healthy && !list(t.list)->uncertain;
    }
    bool nativeReturned(const Token& t,uint64_t caller){std::lock_guard<std::mutex> guard(mutex);
        return advance(t,caller,Phase::Forwarding,Phase::NativeReturned);}
    bool metadataUpdated(const Token& t,uint64_t caller,uint32_t value){std::lock_guard<std::mutex> guard(mutex);
        auto* e=lookup(t,caller);if(!e)return false;
        const auto accepted=advance(t,caller,Phase::NativeReturned,Phase::MetadataUpdated);
        if(e->phase==Phase::MetadataUpdated)e->value=value;return accepted;
    }
    bool exit(const Token& t,uint64_t caller){std::lock_guard<std::mutex> guard(mutex);
        auto* e=lookup(t,caller);if(!e)return false;auto* s=list(t.list);
        const bool complete=e->phase==Phase::MetadataUpdated;const auto value=e->value;
        if(!complete)invalidate(t.list);e->used=false;
        if(!s->active){fatal();return false;}--s->active;
        if(!enabled || !healthy || !complete || s->uncertain || s->active)return false;
        if(serial==limits.publications){fatal();return false;}
        if(s->lastCaller && s->lastCaller!=caller && !increment(s->threadChanges))return false;
        s->lastCaller=caller;latest={t.list,t.generation,++serial,caller,value};available=true;return true;
    }
    bool close(uint64_t id){std::lock_guard<std::mutex> guard(mutex);auto* s=list(id);
        if(!s){fatal();return false;}if(!enabled || !healthy)return false;
        if(s->active || !s->recording){invalidate(id);return false;}s->recording=false;return true;}
    bool reset(uint64_t id){std::lock_guard<std::mutex> guard(mutex);auto* s=list(id);
        if(!s){fatal();return false;}if(!enabled || !healthy)return false;
        if(s->active || s->recording){invalidate(id);return false;}
        if(s->generation==limits.generations){invalidate(id);return false;}
        const auto generation=s->generation+1;*s={};s->generation=generation;
        if(latest.list==id)available=false;return true;}
    void disable(){std::lock_guard<std::mutex> guard(mutex);enabled=false;available=false;}
    bool read(Receipt& out){std::lock_guard<std::mutex> guard(mutex);out={};
        if(!enabled || !healthy || !available)return false;auto* s=list(latest.list);
        if(!s || s->uncertain || s->active)return false;out=latest;return true;}
    ListStatus status(uint64_t id){std::lock_guard<std::mutex> guard(mutex);auto* s=list(id);return s?*s:ListStatus{};}
    bool isHealthy(){std::lock_guard<std::mutex> guard(mutex);return healthy;}
};
}
