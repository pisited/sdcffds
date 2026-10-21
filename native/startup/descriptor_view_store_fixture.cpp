#define NOMINMAX
#include "descriptor_view_store.h"
#include "resource_storage_validation.h"
#include "resource_copy_validation.h"
#include <array>
#include <climits>
#include <cstring>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <utility>
#include <vector>

// CPU-only storage experiment. Synthetic, validator-valid numeric metadata is
// not a resource lease, lifetime detector, descriptor observation or GPU proof.
namespace {
namespace ds=beamrt::descriptor_store;
using View=BeamRTResourceView;
using Image=std::array<uint8_t,sizeof(View)>;
using Address=std::pair<uint64_t,uint32_t>;
using Reference=std::map<Address,Image>;

void need(bool condition,const char* message){if(!condition)throw std::runtime_error(message);}
Image bytes(const View& view){Image out{};std::memcpy(out.data(),&view,sizeof(view));return out;}
View value(const Image& image){View out{};std::memcpy(&out,image.data(),sizeof(out));return out;}
View makeView(uint64_t resourceId,uint64_t revision=1){
    View out{};std::memset(&out,0,sizeof(out));
    out.bytes=sizeof(out);out.abi=1;out.kind=1;out.heapId=77;
    out.resourceId=resourceId;out.canonicalIdentity=0x100000+resourceId*0x1000;out.revision=revision;
    out.resource.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    out.resource.Width=16;out.resource.Height=16;out.resource.DepthOrArraySize=1;out.resource.MipLevels=4;
    out.resource.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;out.resource.SampleDesc.Count=1;
    out.resource.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    out.srv.Format=out.resource.Format;out.srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;
    out.srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;out.srv.Texture2D.MipLevels=4;
    need(beamrtResourceViewValid(out,1),"fixture produced an invalid synthetic SRV");return out;
}
Image atLocation(const View& view,uint64_t heap){
    auto normalized=bytes(view);std::memcpy(normalized.data()+offsetof(View,heapId),&heap,sizeof(heap));return normalized;
}
void expect(ds::Store& store,uint64_t heap,uint32_t index,const Image& expected){
    View out{};std::memset(&out,0xa5,sizeof(out));
    need(store.get(heap,index,out)==ds::Result::Ok,"full-value lookup failed");
    need(bytes(out)==expected,"full 168-byte view roundtrip changed metadata or location revision");
    need(beamrtResourceViewValid(out,out.kind),"decoded full view was not validator-valid");
}
void expect(ds::Store& store,uint64_t heap,uint32_t index,const View& expected){expect(store,heap,index,atLocation(expected,heap));}
void cleared(ds::Store& store,uint64_t heap,uint32_t index,ds::Result result){
    View out{};std::memset(&out,0xa5,sizeof(out));
    need(store.get(heap,index,out)==result,"lookup did not return its expected fail-closed result");
    need(beamrtResourceZero(out),"failed lookup did not clear its entire output");
}
void stats(ds::Store& store,uint32_t locations,uint32_t payloads,uint32_t usedBytes){
    const auto s=store.stats();need(s.healthy && s.locations==locations && s.payloads==payloads && s.usedBytes==usedBytes,
        "healthy location/payload/byte accounting differed from reference");
}
void poisoned(ds::Store& store,ds::Result result,ds::Cause cause){
    const auto failure=store.failure();const auto before=store.stats();
    need(!before.healthy && failure.result==result && failure.cause==cause,"first failure result/cause differed");
    need(failure.locations==before.locations && failure.payloads==before.payloads && failure.usedBytes==before.usedBytes,
        "first failure must describe post-clear storage, not promise rollback");
    cleared(store,1,0,ds::Result::Unhealthy);cleared(store,0,0,ds::Result::Unhealthy);
    const auto next=makeView(99999,std::numeric_limits<uint64_t>::max());
    need(store.put(1,0,next)==ds::Result::Unhealthy && store.erase(1,0)==ds::Result::Unhealthy
        && store.retireHeap(1)==ds::Result::Unhealthy && store.retireResource(1)==ds::Result::Unhealthy,
        "poisoned store accepted a later mutation");
    const auto after=store.failure();const auto afterStats=store.stats();
    need(!std::memcmp(&failure,&after,sizeof(failure)),"later reads, clears or retirements changed the immutable first failure");
    need(afterStats.locations==before.locations && afterStats.payloads==before.payloads && afterStats.usedBytes==before.usedBytes,
        "a later mutation changed poisoned storage");
}

void legacyDistinct(){
    auto owner=std::make_unique<ds::Store>();auto& store=*owner;std::vector<Image> expected;
    for(uint32_t i=0;i<256;++i){const auto view=makeView(i+1,i+1);
        need(store.put(1,i,view)==ds::Result::Ok,"legacy 256 distinct views did not fit");expected.push_back(atLocation(view,1));}
    stats(store,256,256,47104);
    for(uint32_t i=0;i<256;++i)expect(store,1,i,expected[i]);
    std::cout<<"PASS legacy 256 distinct full descriptions preserve all bytes in 47104 bytes\n";
}

void compactFanout(){
    auto owner=std::make_unique<ds::Store>(ds::compactLimits);auto& store=*owner;std::vector<Image> expected;
    for(uint32_t i=0;i<1024;++i){auto view=makeView(1,i+1);
        // Deliberately pass the source heap: only destination heap and revision
        // belong to a location, and neither changes another copied location.
        view.heapId=999;const uint64_t heap=1+i/128;
        need(store.put(heap,i%128,view)==ds::Result::Ok,"compact identical fanout did not fit");expected.push_back(atLocation(view,heap));}
    stats(store,1024,1,24736);
    need(store.stats().usedBytes<=ds::arenaBytes,"sharing exceeded the unchanged byte budget");
    for(uint32_t i=0;i<1024;++i)expect(store,1+i/128,i%128,expected[i]);
    auto overflow=makeView(1,1025);need(store.put(9,0,overflow)==ds::Result::Capacity,"1025th location was not bounded");
    const auto f=store.failure();need(f.attemptedLocations==1025 && f.attemptedPayloads==1 && f.requiredBytes==24760,
        "location failure lost attempted occupancy");poisoned(store,ds::Result::Capacity,ds::Cause::LocationCapacity);
    std::cout<<"PASS compact 1024-location identical fanout and bounded location failure\n";
}

void redundancyCapacityControl(){
    {
        auto owner=std::make_unique<ds::Store>(ds::compactLimits);auto& store=*owner;
        for(uint32_t i=0;i<256;++i)need(store.put(1,i,makeView(i+1,i+1))==ds::Result::Ok,"distinct control fill failed");
        stats(store,256,256,47104);
        auto copied=makeView(1,257);
        need(store.put(2,0,copied)==ds::Result::Capacity,"257th copy after 256 distinct payloads must still exhaust bytes");
        const auto f=store.failure();need(f.attemptedLocations==257 && f.attemptedPayloads==256 && f.requiredBytes==47128,
            "distinct control did not retain exact byte demand");poisoned(store,ds::Result::Capacity,ds::Cause::ByteCapacity);
    }
    {
        auto owner=std::make_unique<ds::Store>(ds::compactLimits);auto& store=*owner;
        for(uint32_t i=0;i<256;++i)need(store.put(1,i,makeView(i<255?i+1:1,i+1))==ds::Result::Ok,"redundant control fill failed");
        stats(store,256,255,46944);
        const auto copied=makeView(1,257);need(store.put(2,0,copied)==ds::Result::Ok,"257th location with 255 payloads should fit");
        stats(store,257,255,46968);expect(store,2,0,copied);
    }
    std::cout<<"PASS 257th location requires actual redundancy, not a universal capacity increase\n";
}

void exactPayloadBytes(){
    auto owner=std::make_unique<ds::Store>(ds::Limits{64,64});auto& store=*owner;const auto base=makeView(1);std::vector<Image> variants;
    const auto add=[&](const View& view){need(beamrtResourceViewValid(view,view.kind),"exact-byte test variant was invalid");variants.push_back(bytes(view));};
    add(base);
    auto changed=value(bytes(base));changed.srv.Texture2D.ResourceMinLODClamp=0.25f;add(changed);
    changed=value(bytes(base));changed.srv.Texture2D.MostDetailedMip=1;changed.srv.Texture2D.MipLevels=3;add(changed);
    changed=value(bytes(base));changed.srv.Texture2D.MipLevels=2;add(changed);
    changed=value(bytes(base));changed.defaultView=1;add(changed);
    changed=value(bytes(base));changed.kind=2;changed.srv={};changed.rtv.Format=changed.resource.Format;
    changed.rtv.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2D;add(changed);
    changed.rtv.Texture2D.MipSlice=1;add(changed);
    changed=value(bytes(base));changed.resource.Width=32;add(changed);
    changed=value(bytes(base));changed.resource.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET|D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;add(changed);
    static_assert(offsetof(D3D12_RESOURCE_DESC,Alignment)>sizeof(D3D12_RESOURCE_DIMENSION),"fixture requires the documented resource-desc padding");
    changed=value(bytes(base));auto raw=bytes(changed);
    raw[offsetof(View,resource)+sizeof(D3D12_RESOURCE_DIMENSION)]=0x6d;std::memcpy(&changed,raw.data(),sizeof(changed));add(changed);
    changed=value(bytes(base));const uint32_t negativeZero=0x80000000u;
    std::memcpy(&changed.srv.Texture2D.ResourceMinLODClamp,&negativeZero,sizeof(negativeZero));add(changed);
    changed=value(bytes(base));changed.canonicalIdentity+=16;add(changed);
    changed=value(bytes(base));changed.resourceId=2;add(changed);
    changed=value(variants[5]);changed.defaultView=1;add(changed);
    changed=value(bytes(base));changed.srv.Texture2D.MipLevels=UINT_MAX;add(changed);
    need(variants.size()==15,"exact-byte variant inventory drifted");
    for(uint32_t i=0;i<static_cast<uint32_t>(variants.size());++i){auto view=value(variants[i]);view.revision=i+1;
        variants[i]=atLocation(view,2);need(store.put(2,i,view)==ds::Result::Ok,"full-description variant did not fit");}
    for(uint32_t i=0;i<15;++i)expect(store,2,i,variants[i]);
    stats(store,15,15,2760);
    // Full raw-byte equality, not float equality, is deliberate: signed-zero
    // and resource-desc padding differences must each retain their own payload.
    auto copied=value(variants[9]);copied.revision=16;copied.heapId=1000;
    need(store.put(3,0,copied)==ds::Result::Ok,"exact padding copy failed");stats(store,16,15,2784);
    expect(store,3,0,copied);expect(store,2,9,variants[9]);
    std::cout<<"PASS all 152 shared bytes: mip/clamp/default/type, signed zero and padding retained exactly\n";
}

void snapshotRetirement(){
    auto owner=std::make_unique<ds::Store>(ds::Limits{64,64});auto& store=*owner;auto a=makeView(1,1);
    need(store.put(1,0,a)==ds::Result::Ok,"snapshot source admission failed");View held{};
    need(store.get(1,0,held)==ds::Result::Ok,"snapshot source get failed");const auto oldImage=bytes(held);
    held.revision=2;need(store.put(2,0,held)==ds::Result::Ok,"copied snapshot admission failed");
    const auto copyImage=atLocation(held,2);stats(store,2,1,208);
    auto b=makeView(2,3);need(store.put(1,0,b)==ds::Result::Ok,"source overwrite failed");expect(store,2,0,copyImage);
    auto c=makeView(3,4);need(store.put(2,0,c)==ds::Result::Ok,"destination overwrite failed");expect(store,1,0,b);
    need(oldImage==atLocation(a,1),"caller-owned copied-source snapshot changed after overwrite");
    auto restored=value(oldImage);restored.revision=5;need(store.put(3,0,restored)==ds::Result::Ok,"detached full snapshot could not be copied again");
    c.revision=6;need(store.put(4,0,c)==ds::Result::Ok,"second shared C reference failed");stats(store,4,3,576);
    // Removing non-last payload B moves a later payload and must repair every
    // referencing location, including both C copies when that payload moves.
    need(store.erase(1,0)==ds::Result::Ok,"non-last payload erase failed");expect(store,2,0,makeView(3,4));expect(store,4,0,c);expect(store,3,0,restored);
    need(store.erase(3,0)==ds::Result::Ok,"second compacting erase failed");expect(store,2,0,makeView(3,4));expect(store,4,0,c);stats(store,2,1,208);
    need(store.erase(999,999)==ds::Result::Ok && store.retireHeap(999)==ds::Result::Ok && store.retireResource(999)==ds::Result::Ok,
        "absent clear/retire operations were not idempotent");
    auto newLife=makeView(30,7);newLife.canonicalIdentity=c.canonicalIdentity;
    need(store.put(5,0,newLife)==ds::Result::Ok,"same-address new numeric lifetime failed");
    need(store.retireResource(3)==ds::Result::Ok,"cross-heap explicit resource retirement failed");
    cleared(store,2,0,ds::Result::NotFound);cleared(store,4,0,ds::Result::NotFound);expect(store,5,0,newLife);stats(store,1,1,184);
    need(store.retireHeap(5)==ds::Result::Ok,"explicit heap retirement failed");stats(store,0,0,0);
    a.revision=8;need(store.put(5,0,a)==ds::Result::Ok,"caller-issued heap/index reuse failed");expect(store,5,0,a);
    need(store.retireResource(30)==ds::Result::Ok,"old resource retirement after ID reuse failed");expect(store,5,0,a);
    need(store.retireResource(1)==ds::Result::Ok,"last reference reclamation failed");stats(store,0,0,0);
    std::cout<<"PASS independent copy snapshots, compaction, explicit retirement and numeric ID reuse\n";
}

void boundedFailures(){
    {
        auto owner=std::make_unique<ds::Store>(ds::Limits{2,2});auto& store=*owner;
        need(store.put(1,0,makeView(1,1))==ds::Result::Ok && store.put(1,1,makeView(1,2))==ds::Result::Ok,"tiny location fill failed");
        need(store.put(1,2,makeView(1,3))==ds::Result::Capacity,"tiny location exhaustion not rejected");
        need(store.failure().attemptedLocations==3 && store.failure().attemptedPayloads==1,"tiny location attempted counts differed");
        poisoned(store,ds::Result::Capacity,ds::Cause::LocationCapacity);
    }
    {
        auto owner=std::make_unique<ds::Store>(ds::Limits{4,1});auto& store=*owner;need(store.put(1,0,makeView(1,1))==ds::Result::Ok,"tiny payload fill failed");
        need(store.put(1,1,makeView(2,2))==ds::Result::Capacity,"tiny unique payload exhaustion not rejected");
        need(store.failure().attemptedPayloads==2,"tiny payload attempted count differed");poisoned(store,ds::Result::Capacity,ds::Cause::PayloadCapacity);
    }
    {
        auto owner=std::make_unique<ds::Store>(ds::Limits{1,1});auto& store=*owner;
        need(store.put(1,0,makeView(1,1))==ds::Result::Ok && store.put(1,0,makeView(2,2))==ds::Result::Ok,
            "sole-reference overwrite did not reclaim before capacity checking");
        auto replacement=makeView(2,3);need(store.put(1,0,replacement)==ds::Result::Ok,"same payload overwrite at exact capacity failed");
        stats(store,1,1,184);expect(store,1,0,replacement);
    }
    {
        auto owner=std::make_unique<ds::Store>(ds::compactLimits);auto& store=*owner;uint64_t revision=0;
        for(uint32_t i=0;i<1024;++i)need(store.put(1,i,makeView(1,++revision))==ds::Result::Ok,"byte pressure fanout fill failed");
        bool failed=false;
        for(uint32_t i=0;i<256;++i){const auto result=store.put(1,i,makeView(100+i,++revision));
            if(result==ds::Result::Capacity){failed=true;break;}need(result==ds::Result::Ok,"byte pressure changed to an unexpected failure");}
        need(failed,"unique replacement pressure did not exhaust the fixed byte arena");
        const auto f=store.failure();need(f.locations==1023 && f.payloads==140 && f.usedBytes==46952
            && f.attemptedLocations==1024 && f.attemptedPayloads==141 && f.requiredBytes==47136,
            "byte pressure did not expose exact post-clear, pre-insert demand");
        poisoned(store,ds::Result::Capacity,ds::Cause::ByteCapacity);
    }
    std::cout<<"PASS independent location/payload/byte capacities and immutable post-clear first failure\n";
}

void diagnosticReaping(){
    auto owner=std::make_unique<ds::Store>(ds::Limits{4,4});auto& store=*owner;
    const auto healthyFailure=store.failure();
    need(store.reapDeadHeap(0)==ds::Result::Invalid && store.reapDeadResource(0)==ds::Result::Invalid,
        "zero diagnostic reap identity was accepted");
    const auto stillHealthy=store.failure();
    need(!std::memcmp(&healthyFailure,&stillHealthy,sizeof(healthyFailure)),"invalid diagnostic reaping poisoned a healthy store");
    stats(store,0,0,0);
    need(store.put(1,0,makeView(11,1))==ds::Result::Ok && store.put(1,1,makeView(22,2))==ds::Result::Ok
        && store.put(2,0,makeView(11,3))==ds::Result::Ok && store.put(3,0,makeView(33,4))==ds::Result::Ok,
        "diagnostic reaping capacity baseline did not fit");
    stats(store,4,3,576);
    need(store.occupied()==4 && store.occupied(1)==2 && store.occupied(2)==1 && store.occupied(3)==1 && !store.occupied(99),
        "occupied diagnostics did not count per-heap locations independently of payload sharing");
    need(store.put(4,0,makeView(44,5))==ds::Result::Capacity,"diagnostic reaping baseline did not poison at capacity");
    poisoned(store,ds::Result::Capacity,ds::Cause::LocationCapacity);
    const auto firstFailure=store.failure();
    const auto unchanged=[&](uint32_t locations,uint32_t payloads,uint32_t usedBytes){
        const auto now=store.stats();const auto failure=store.failure();
        need(!now.healthy && now.locations==locations && now.payloads==payloads && now.usedBytes==usedBytes
            && store.occupied()==locations,"diagnostic reaping did not update poisoned occupancy");
        need(!std::memcmp(&failure,&firstFailure,sizeof(failure)),"diagnostic reaping replaced immutable capacity failure");
        cleared(store,1,0,ds::Result::Unhealthy);cleared(store,2,0,ds::Result::Unhealthy);cleared(store,3,0,ds::Result::Unhealthy);
        need(store.put(4,0,makeView(44,6))==ds::Result::Unhealthy && store.erase(1,0)==ds::Result::Unhealthy
            && store.retireHeap(1)==ds::Result::Unhealthy && store.retireResource(11)==ds::Result::Unhealthy,
            "diagnostic reaping resumed strict poisoned reads or writes");
    };
    unchanged(4,3,576);
    need(store.reapDeadHeap(0)==ds::Result::Invalid && store.reapDeadResource(0)==ds::Result::Invalid,
        "zero diagnostic reap identity changed after poison");unchanged(4,3,576);
    need(store.reapDeadHeap(1)==ds::Result::Ok,"dead heap diagnostic reaping refused after poison");
    need(!store.occupied(1) && store.occupied(2)==1 && store.occupied(3)==1,"dead heap reaping removed unrelated locations");unchanged(2,2,368);
    need(store.reapDeadHeap(1)==ds::Result::Ok && store.reapDeadHeap(99)==ds::Result::Ok
        && store.reapDeadResource(22)==ds::Result::Ok && store.reapDeadResource(99)==ds::Result::Ok,
        "repeated and unrelated dead identities were not safe");unchanged(2,2,368);
    need(store.reapDeadResource(11)==ds::Result::Ok,"dead resource diagnostic reaping refused after poison");
    need(!store.occupied(2) && store.occupied(3)==1,"resource reaping removed unrelated payloads");unchanged(1,1,184);
    need(store.reapDeadResource(11)==ds::Result::Ok && store.reapDeadHeap(2)==ds::Result::Ok,
        "repeated resource/heap retirement after poison was not idempotent");unchanged(1,1,184);
    need(store.reapDeadResource(33)==ds::Result::Ok && store.reapDeadHeap(3)==ds::Result::Ok,
        "last poisoned reference could not be diagnostically reaped");unchanged(0,0,0);
    need(firstFailure.locations==4 && firstFailure.payloads==3 && firstFailure.usedBytes==576,
        "first failure stopped describing original capacity occupancy");
    std::cout<<"PASS poisoned diagnostic reaping updates counts but never revives metadata or changes first failure\n";
}

void invalidQueriesAndMutations(){
    {
        auto owner=std::make_unique<ds::Store>();auto& store=*owner;
        cleared(store,0,0,ds::Result::Invalid);cleared(store,1,0,ds::Result::NotFound);stats(store,0,0,0);
        auto boundary=makeView(1);boundary.heapId=0;
        need(store.put(std::numeric_limits<uint64_t>::max(),UINT_MAX,boundary)==ds::Result::Ok,
            "valid numeric destination should override the copied source heap");
        expect(store,std::numeric_limits<uint64_t>::max(),UINT_MAX,boundary);
    }
    for(uint32_t which=0;which<14;++which){
        auto owner=std::make_unique<ds::Store>();auto& store=*owner;auto malformed=makeView(1);uint64_t heap=1;
        switch(which){
        case 0:malformed.bytes=0;break;case 1:malformed.abi=2;break;case 2:malformed.kind=3;break;
        case 3:malformed.defaultView=2;break;case 4:malformed.resourceId=0;break;case 5:malformed.canonicalIdentity=0;break;
        case 6:malformed.revision=0;break;case 7:malformed.srv.Texture2D.ResourceMinLODClamp=-1;break;
        case 8:malformed.srv.Texture2D.ResourceMinLODClamp=std::numeric_limits<float>::quiet_NaN();break;
        case 9:malformed.srv.Texture2D.ResourceMinLODClamp=std::numeric_limits<float>::infinity();break;
        case 10:malformed.srv.Format=DXGI_FORMAT_R32_FLOAT;break;case 11:malformed.rtv.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2D;break;
        case 12:malformed.resource.SampleDesc.Count=2;break;case 13:heap=0;break;
        }
        need(store.put(heap,0,malformed)==ds::Result::Invalid,"invalid view mutation did not fail closed");poisoned(store,ds::Result::Invalid,ds::Cause::View);
    }
    const std::array<ds::Limits,4> invalidLimits{{{0,1},{1025,1},{1,0},{1,257}}};
    for(const auto limits:invalidLimits){auto owner=std::make_unique<ds::Store>(limits);poisoned(*owner,ds::Result::Invalid,ds::Cause::Limits);}
    for(uint32_t which=0;which<3;++which){auto owner=std::make_unique<ds::Store>();auto& store=*owner;
        const auto result=which==0?store.erase(0,0):(which==1?store.retireHeap(0):store.retireResource(0));
        need(result==ds::Result::Invalid,"invalid retirement identity was accepted");
        poisoned(store,ds::Result::Invalid,which<2?ds::Cause::HeapId:ds::Cause::ResourceId);
    }
    for(uint32_t which=0;which<4;++which){auto owner=std::make_unique<ds::Store>();auto& store=*owner;
        need(store.put(1,0,makeView(1,10))==ds::Result::Ok,"revision baseline failed");
        if(which==1)need(store.erase(1,0)==ds::Result::Ok,"revision erase failed");
        if(which==2)need(store.retireHeap(1)==ds::Result::Ok,"revision heap retirement failed");
        if(which==3)need(store.retireResource(1)==ds::Result::Ok,"revision resource retirement failed");
        need(store.put(2,0,makeView(2,which==0?10:9))==ds::Result::Invalid,"globally non-increasing revision was accepted after clear/retirement");
        poisoned(store,ds::Result::Invalid,ds::Cause::Revision);
    }
    std::cout<<"PASS cleared query failures, invalid mutations, limits and globally monotonic revisions\n";
}

Image payloadKey(const Image& image){
    // Independent oracle: preserve all 168 bytes and zero ONLY the two location
    // fields. Do not reuse detail::encode, its key slicing or payload indexes.
    auto key=image;std::memset(key.data()+offsetof(View,heapId),0,sizeof(uint64_t));
    std::memset(key.data()+offsetof(View,revision),0,sizeof(uint64_t));return key;
}
void checkReference(ds::Store& store,const Reference& reference){
    std::set<Image> distinct;for(const auto& item:reference)distinct.insert(payloadKey(item.second));
    const auto locations=static_cast<uint32_t>(reference.size()),payloads=static_cast<uint32_t>(distinct.size());
    stats(store,locations,payloads,locations*24+payloads*160);
    for(uint64_t heap=1;heap<=4;++heap)for(uint32_t index=0;index<8;++index){const auto at=reference.find({heap,index});
        if(at==reference.end())cleared(store,heap,index,ds::Result::NotFound);else expect(store,heap,index,at->second);}
}
uint32_t randomWord(uint32_t& seed){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
void randomizedReference(){
    auto owner=std::make_unique<ds::Store>(ds::Limits{64,32});auto& store=*owner;Reference reference;uint32_t seed=0x6e624731;uint64_t revision=0;
    for(uint32_t iteration=0;iteration<5000;++iteration){
        const auto word=randomWord(seed);const uint64_t heap=1+(word>>8)%4;const uint32_t index=(word>>16)%8,operation=word%100;
        if(operation<70){auto view=makeView(1+(word>>20)%12,++revision);
            if(view.resourceId%3==0)view.srv.Texture2D.ResourceMinLODClamp=0.25f;
            if(view.resourceId%5==0)view.defaultView=1;
            need(store.put(heap,index,view)==ds::Result::Ok,"randomized valid put failed within limits");reference[{heap,index}]=atLocation(view,heap);
        }else if(operation<90){need(store.erase(heap,index)==ds::Result::Ok,"randomized erase failed");reference.erase({heap,index});
        }else if(operation<96){need(store.retireHeap(heap)==ds::Result::Ok,"randomized heap retirement failed");
            for(auto it=reference.begin();it!=reference.end();)if(it->first.first==heap)it=reference.erase(it);else ++it;
        }else{const uint64_t resource=1+(word>>20)%12;need(store.retireResource(resource)==ds::Result::Ok,"randomized resource retirement failed");
            for(auto it=reference.begin();it!=reference.end();)if(value(it->second).resourceId==resource)it=reference.erase(it);else ++it;
        }
        checkReference(store,reference);
    }
    for(uint64_t heap=1;heap<=4;++heap)need(store.retireHeap(heap)==ds::Result::Ok,"randomized final clear failed");
    reference.clear();checkReference(store,reference);
    for(uint32_t i=0;i<64;++i){auto view=makeView(1,++revision);need(store.put(1,i,view)==ds::Result::Ok,"post-randomized bounded fill failed");
        reference[{1,i}]=atLocation(view,1);expect(store,1,i,reference.at({1,i}));}
    stats(store,64,1,1696);
    need(store.put(1,64,makeView(1,++revision))==ds::Result::Capacity,"post-randomized planned exhaustion did not fail closed");
    poisoned(store,ds::Result::Capacity,ds::Cause::LocationCapacity);
    std::cout<<"PASS 5000 deterministic operations against independent full-value reference and planned exhaustion\n";
}

void profiledEvidence(){
    constexpr auto compact=beamrtResourceStorageCompact;
    const auto snapshot=[](uint32_t locations,uint32_t payloads){return BeamRTResourceStorageSnapshot{
        sizeof(BeamRTResourceStorageSnapshot),2,beamrtResourceStorageCompact,1024,256,47104,locations,payloads,locations*24+payloads*160,{},0,24,0,0};};
    BeamRTResourceStatus status{};status.bytes=sizeof(status);status.abi=2;status.healthy=1;
    BeamRTResourceFailure failure{};failure.bytes=sizeof(failure);failure.abi=2;
    BeamRTResourceStorageFailure evidence{};evidence.bytes=sizeof(evidence);evidence.abi=2;
    auto current=snapshot(0,0);
    need(beamrtResourceStorageEvidenceValid(current,evidence,failure,status,compact),"empty compact evidence rejected");
    need(!beamrtResourceFailureValid(failure,status),"old default validator accepted empty compact population");
    auto legacyStatus=status;legacyStatus.abi=1;auto legacyFailure=failure;legacyFailure.abi=1;
    auto legacyStorage=current;legacyStorage.profile=0;legacyStorage.locationLimit=256;
    need(beamrtResourceStorageEvidenceValid(legacyStorage,evidence,legacyFailure,legacyStatus,0),"legacy empty evidence changed");
    need(!beamrtResourceStorageEvidenceValid(current,evidence,legacyFailure,legacyStatus,compact),"legacy status mixed into compact evidence");
    for(uint32_t which=0;which<12;++which){auto invalid=current;
        switch(which){case 0:invalid.bytes=0;break;case 1:invalid.abi=1;break;case 2:invalid.profile=0;break;
        case 3:invalid.locationLimit=256;break;case 4:invalid.payloadLimit=257;break;case 5:invalid.byteLimit=47105;break;
        case 6:invalid.locations=1;break;case 7:invalid.payloads=1;break;case 8:invalid.usedBytes=1;break;
        case 9:invalid.reserved[0]=1;break;case 10:invalid.reserved[1]=1;break;case 11:invalid.reserved[2]=1;break;}
        need(!beamrtResourceStorageEvidenceValid(invalid,evidence,failure,status,compact),"malformed current storage evidence accepted");
    }
    for(uint32_t which=0;which<3;++which){
        const auto locations=which?256u:1024u,payloads=which?256u:1u;
        current=snapshot(locations,payloads);status.healthy=0;status.views=locations;status.callbacks=1;status.pressure=1;status.serial=locations;
        failure={};failure.bytes=sizeof(failure);failure.abi=2;failure.kind=which==0?BeamRTResourceFailureViewCapacity:
            which==1?BeamRTResourceFailureViewPayloadCapacity:BeamRTResourceFailureViewByteCapacity;
        failure.method=BeamRTResourceMethodCreateSRV;failure.callerThread=1;failure.activeCallbacks=1;
        failure.capacityLimit=which==0?1024u:which==1?256u:47104u;
        failure.attemptedCount=which==0?1025u:which==1?257u:47128u;
        failure.callbackOrdinal=1;failure.observedCallbacks=1;failure.pressure=1;failure.serial=locations;failure.views=locations;
        evidence={sizeof(evidence),2,1,which+1,current,locations+1,payloads+(which==1?1u:0u),
            current.usedBytes+24+(which==1?160u:0u),0,0,0};
        need(beamrtResourceStorageEvidenceValid(current,evidence,failure,status,compact),"precise compact capacity evidence rejected");
        const auto original=evidence;
        // The valid immutable sample must not allow fabricated post-failure
        // growth, even when current byte math and public bounds are consistent.
        const auto grown=which==0?snapshot(2,2):snapshot(257,1);
        auto grownStatus=status;grownStatus.views=grown.locations;
        need(!beamrtResourceStorageEvidenceValid(grown,evidence,failure,grownStatus,compact),"post-failure occupancy growth accepted");
        for(uint32_t mutation=0;mutation<13;++mutation){auto invalid=evidence;
            switch(mutation){case 0:invalid.bytes=0;break;case 1:invalid.abi=1;break;case 2:invalid.present=0;break;
            case 3:invalid.cause=0;break;case 4:invalid.atFailure.profile=0;break;case 5:++invalid.atFailure.locations;break;
            case 6:++invalid.atFailure.payloads;break;case 7:++invalid.atFailure.usedBytes;break;case 8:++invalid.attemptedLocations;break;
            case 9:invalid.attemptedPayloads+=2;break;case 10:++invalid.requiredBytes;break;case 11:invalid.reserved=1;break;
            case 12:invalid.atFailure.reserved[0]=1;break;}
            need(!beamrtResourceStorageEvidenceValid(current,invalid,failure,status,compact),"malformed original capacity evidence accepted");
        }
        // A later current snapshot can shrink to zero, but not rewrite the
        // recorded original failure. This is not health recovery or rollback.
        current=snapshot(0,0);status.views=0;
        need(beamrtResourceStorageEvidenceValid(current,evidence,failure,status,compact)
            && !std::memcmp(&original,&evidence,sizeof(evidence)),"post-failure reaping invalidated the immutable original sample");
    }
    // Lower-priority causes must not conceal a limit that Store checks first.
    current=snapshot(256,256);status.views=256;failure.kind=BeamRTResourceFailureViewByteCapacity;
    failure.views=256;failure.capacityLimit=47104;failure.attemptedCount=47288;
    evidence={sizeof(evidence),2,1,beamrtResourceStorageFailureBytes,current,257,257,47288,0,0,0};
    need(beamrtResourceFailureValid(failure,status,compact)
        && !beamrtResourceStorageEvidenceValid(current,evidence,failure,status,compact),"byte cause hid earlier payload exhaustion");
    current=snapshot(1024,140);status.views=1024;status.serial=1024;failure.views=1024;failure.serial=1024;failure.attemptedCount=47160;
    evidence={sizeof(evidence),2,1,beamrtResourceStorageFailureBytes,current,1025,141,47160,0,0,0};
    need(beamrtResourceFailureValid(failure,status,compact)
        && !beamrtResourceStorageEvidenceValid(current,evidence,failure,status,compact),"byte cause hid earlier location exhaustion");
    std::cout<<"PASS public profile discriminator, exact capacity units, malformed evidence, precedence and post-reap joins\n";
}

void internedEvidence(){
    constexpr auto profile=beamrtResourceStorageInterned;
    const auto snapshot=[](uint32_t locations,uint32_t payloads,uint32_t heaps){return BeamRTResourceStorageSnapshot{
        sizeof(BeamRTResourceStorageSnapshot),2,beamrtResourceStorageInterned,4096,256,47104,
        locations,payloads,512+locations*14+payloads*160,{},512,14,heaps,32};};
    BeamRTResourceStatus status{};status.bytes=sizeof(status);status.abi=3;status.healthy=1;
    BeamRTResourceFailure failure{};failure.bytes=sizeof(failure);failure.abi=3;
    BeamRTResourceStorageFailure evidence{};evidence.bytes=sizeof(evidence);evidence.abi=2;
    auto current=snapshot(0,0,0);
    need(beamrtResourceStorageEvidenceValid(current,evidence,failure,status,profile),"interned empty directory accounting rejected");
    need(!beamrtResourceStorageEvidenceValid(current,evidence,failure,status,beamrtResourceStorageCompact)
        && !beamrtResourceFailureValid(failure,status),"interned population accepted as an old profile");
    for(uint32_t which=0;which<12;++which){auto invalid=current;
        switch(which){case 0:invalid.directoryBytes=0;break;case 1:invalid.locationBytes=24;break;case 2:invalid.heapLimit=31;break;
        case 3:invalid.heaps=1;break;case 4:invalid.usedBytes=0;break;case 5:invalid.abi=1;break;case 6:invalid.locationLimit=1024;break;
        case 7:invalid.profile=beamrtResourceStorageCompact;break;case 8:invalid.reserved[0]=1;break;
        case 9:invalid.reserved[1]=1;break;case 10:invalid.reserved[2]=1;break;case 11:invalid.locations=1;break;}
        need(!beamrtResourceStorageEvidenceValid(invalid,evidence,failure,status,profile),"malformed interned empty accounting accepted");
    }
    auto dirtyEmpty=evidence;dirtyEmpty.attemptedHeaps=1;
    need(!beamrtResourceStorageEvidenceValid(current,dirtyEmpty,failure,status,profile),"noncanonical interned empty accepted");
    for(uint32_t which=0;which<3;++which){
        const uint32_t locations=which==0?256u:which==1?3248u:32u,payloads=which==0?256u:which==1?7u:1u;
        const uint32_t heaps=which==2?32u:2u;
        current=snapshot(locations,payloads,heaps);status.healthy=0;status.views=locations;status.callbacks=1;status.pressure=1;status.serial=4000;
        failure={};failure.bytes=sizeof(failure);failure.abi=3;failure.kind=which==0?BeamRTResourceFailureViewPayloadCapacity:
            which==1?BeamRTResourceFailureViewByteCapacity:BeamRTResourceFailureViewHeapCapacity;
        failure.method=BeamRTResourceMethodCreateSRV;failure.callerThread=1;failure.activeCallbacks=1;
        failure.capacityLimit=which==0?256u:which==1?47104u:32u;
        failure.attemptedCount=which==0?257u:which==1?47118u:33u;
        failure.callbackOrdinal=1;failure.observedCallbacks=1;failure.pressure=1;failure.serial=4000;failure.views=locations;
        evidence={sizeof(evidence),2,1,which==0?beamrtResourceStorageFailurePayloads:which==1?beamrtResourceStorageFailureBytes:beamrtResourceStorageFailureHeaps,
            current,locations+1,payloads+(which==0?1u:0u),current.usedBytes+14+(which==0?160u:0u),0,heaps+(which==2?1u:0u),0};
        need(beamrtResourceStorageEvidenceValid(current,evidence,failure,status,profile),"exact interned capacity evidence rejected");
        const auto original=evidence;
        for(uint32_t mutation=0;mutation<11;++mutation){auto invalid=evidence;
            switch(mutation){case 0:invalid.abi=1;break;case 1:invalid.atFailure.directoryBytes=0;break;
            case 2:invalid.atFailure.locationBytes=24;break;case 3:invalid.atFailure.heapLimit=31;break;
            case 4:invalid.atFailure.heaps=33;break;case 5:invalid.attemptedHeaps+=2;break;
            case 6:invalid.requiredBytes+=512;break;case 7:invalid.reserved2=1;break;case 8:invalid.reserved=1;break;
            case 9:invalid.attemptedHeaps=0;break;case 10:invalid.attemptedPayloads+=2;break;}
            need(!beamrtResourceStorageEvidenceValid(current,invalid,failure,status,profile),"malformed interned capacity evidence accepted");
        }
        if(which<2){auto grown=snapshot(10,1,3);auto grownStatus=status;grownStatus.views=10;
            need(beamrtResourceStorageSnapshotValid(grown,profile)
                && !beamrtResourceStorageEvidenceValid(grown,evidence,failure,grownStatus,profile),"post-failure occupied heap growth accepted");}
        current=snapshot(0,0,0);status.views=0;
        need(beamrtResourceStorageEvidenceValid(current,evidence,failure,status,profile)
            && !std::memcmp(&original,&evidence,sizeof(evidence)),"interned reaping lost fixed directory or original failure");
    }
    // Synthetic public contracts only: the observer's outer 32-heap guard can
    // precede directory exhaustion, and byte accounting precedes logical4096.
    current=snapshot(256,256,32);status.views=256;failure.views=256;failure.kind=BeamRTResourceFailureViewPayloadCapacity;
    failure.capacityLimit=256;failure.attemptedCount=257;
    evidence={sizeof(evidence),2,1,beamrtResourceStorageFailurePayloads,current,257,257,45230,0,33,0};
    need(beamrtResourceFailureValid(failure,status,profile)
        && !beamrtResourceStorageEvidenceValid(current,evidence,failure,status,profile),"payload cause hid earlier heap exhaustion");
    current=snapshot(402,256,32);status.views=402;failure.views=402;failure.kind=BeamRTResourceFailureViewByteCapacity;
    failure.capacityLimit=47104;failure.attemptedCount=47274;
    evidence={sizeof(evidence),2,1,beamrtResourceStorageFailureBytes,current,403,257,47274,0,33,0};
    need(beamrtResourceFailureValid(failure,status,profile)
        && !beamrtResourceStorageEvidenceValid(current,evidence,failure,status,profile),"byte cause hid earlier heap/payload exhaustion");
    evidence.attemptedHeaps=32;
    need(!beamrtResourceStorageEvidenceValid(current,evidence,failure,status,profile),"byte cause hid earlier payload exhaustion");
    need(!beamrtResourceStorageSnapshotValid(snapshot(4096,1,1),profile),"logical4096 fabricated a byte-valid native population");
    std::cout<<"PASS interned public metrics, canonical empties, heap demand, capacity precedence and directory-preserving reaping\n";
}
void internedCopyEvidence(){
    constexpr auto profile=beamrtResourceStorageInterned;constexpr uint32_t mode=beamrtResourceDescriptorTextures;
    BeamRTResourceStatus status{};status.bytes=sizeof(status);status.abi=3;status.enabled=1;status.ownerThread=1;
    status.attachedSlots=10;status.callbacks=1;status.pressure=1;status.serial=100;status.liveHeaps=2;status.liveResources=7;status.views=3248;
    BeamRTResourceFailure failure{};failure.bytes=sizeof(failure);failure.abi=3;failure.kind=BeamRTResourceFailureViewByteCapacity;
    failure.method=BeamRTResourceMethodCopyRanges;failure.callerThread=1;failure.activeCallbacks=1;failure.capacityLimit=47104;
    failure.attemptedCount=47118;failure.callbackOrdinal=1;failure.observedCallbacks=1;failure.pressure=1;failure.serial=100;
    failure.liveHeaps=2;failure.liveResources=7;failure.views=3248;
    auto owner=std::make_unique<BeamRTResourceCopyFailure>();auto& copy=*owner;
    copy.bytes=sizeof(copy);copy.abi=beamrtResourceCopyFailureABI;copy.present=1;copy.mode=mode;copy.method=failure.method;
    copy.descriptorType=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;copy.callerThread=1;copy.laneCount=1;
    copy.destinationRanges=copy.sourceRanges=1;copy.destinationSizesExplicit=copy.sourceSizesExplicit=1;
    copy.entryViews=copy.afterClearViews=3248;copy.heapCount=3;copy.descriptorStride=32;copy.firstFailure=failure;copy.profile=profile;
    // The third summarized heap is empty. Heap liveness is not occupancy, and
    // the failed destination slot is empty even when another slot in it exists.
    copy.heaps[0]={11,0x10000,4096,32,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,0,3247,3247,3247,1,{}};
    copy.heaps[1]={22,0x40000,4096,32,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,0,1,1,1,1,{}};
    copy.heaps[2]={33,0x70000,4096,32,D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,0,0,0,0,0,{}};
    copy.destinations[0]={0x40000,1,0};copy.sources[0]={0x10000,1,0};
    auto& lane=copy.lanes[0];lane.sourceCpu=0x10000;lane.destinationCpu=0x40000;
    lane.sourceHeapId=11;lane.destinationHeapId=22;lane.sourceHeapKnown=lane.destinationHeapKnown=1;
    lane.source=makeView(7,99);lane.source.heapId=11;
    const BeamRTResourceStorageSnapshot snapshot{sizeof(snapshot),2,profile,4096,256,47104,3248,7,47104,{},512,14,2,32};
    copy.storageFailure={sizeof(copy.storageFailure),2,1,beamrtResourceStorageFailureBytes,snapshot,3249,7,47118,0,2,0};
    const auto valid=[&](const BeamRTResourceCopyFailure& candidate){return beamrtResourceCopyFailureValid(candidate,failure,status,mode,profile);};
    need(beamrtResourceStorageFailureValid(copy.storageFailure,failure,status,profile) && valid(copy),
        "interned occupied-destination copy baseline rejected");
    need(!beamrtResourceCopyFailureValid(copy,failure,status,mode,beamrtResourceStorageCompact),"compact copy validator accepted interned profile");
    auto mutated=std::make_unique<BeamRTResourceCopyFailure>();
    for(uint32_t which=0;which<3;++which){*mutated=copy;
        if(which==0)mutated->storageFailure.atFailure.heaps=1;
        if(which==1)mutated->storageFailure.atFailure.heaps=mutated->storageFailure.attemptedHeaps=3;
        if(which==2)mutated->storageFailure.attemptedHeaps=3;
        // These are deliberately valid standalone storage samples: H does not
        // alter fixed-directory byte math. Only the copy-topology join rejects.
        need(beamrtResourceStorageFailureValid(mutated->storageFailure,failure,status,profile)
            && !valid(*mutated),which<2?"copy accepted false original occupied H with valid byte math":
            "copy accepted H+1 demand for an already occupied destination");
    }
    // Both a retired occupied heap and an alive empty heap remain legal
    // diagnostic samples. Neither aliveAtEntry nor heapCount implies H.
    for(uint32_t which=0;which<3;++which){*mutated=copy;
        if(which==0)mutated->heaps[0].aliveAtEntry=0;
        if(which==1)mutated->heaps[2].aliveAtEntry=1;
        if(which==2){mutated->heaps[0].aliveAtEntry=0;mutated->heaps[1].aliveAtEntry=0;mutated->heaps[2].aliveAtEntry=1;}
        need(valid(*mutated),"copy inferred occupied H from aliveAtEntry instead of failureViews");
    }
    // Move the destination's other association into the source heap. The
    // failed destination now needs a new directory slot, not extra byte charge.
    copy.heaps[0].entryViews=copy.heaps[0].afterClearViews=copy.heaps[0].failureViews=3248;
    copy.heaps[1].entryViews=copy.heaps[1].afterClearViews=copy.heaps[1].failureViews=0;
    copy.storageFailure.atFailure.heaps=1;copy.storageFailure.attemptedHeaps=2;
    need(beamrtResourceStorageFailureValid(copy.storageFailure,failure,status,profile) && valid(copy),
        "interned empty-destination H+1 copy baseline rejected");
    *mutated=copy;mutated->storageFailure.attemptedHeaps=1;
    need(beamrtResourceStorageFailureValid(mutated->storageFailure,failure,status,profile) && !valid(*mutated),
        "copy accepted unchanged H demand for an empty destination");
    copy.heaps[1].aliveAtEntry=0;copy.heaps[2].aliveAtEntry=1;
    need(valid(copy),"retired empty destination or alive empty summary changed directory demand");
    std::cout<<"PASS interned copy occupied-H / attempted-H topology joins, four byte-valid malformed receipts and liveness-independent occupancy\n";
}
} // namespace

int main(){
    try{
        static_assert(sizeof(View)==168 && ds::arenaBytes==47104,"unchanged metadata and arena sizes");
        static_assert(sizeof(ds::Store)<=ds::arenaBytes+64,"no hidden unbounded storage");
        legacyDistinct();compactFanout();redundancyCapacityControl();exactPayloadBytes();snapshotRetirement();
        boundedFailures();diagnosticReaping();invalidQueriesAndMutations();randomizedReference();profiledEvidence();internedEvidence();internedCopyEvidence();
        std::cout<<"PASS descriptor view store: 12 CPU-only groups; no observer, game or GPU proof\n";return 0;
    }catch(const std::exception& error){std::cerr<<"FAIL descriptor view store: "<<error.what()<<'\n';return 1;}
}
