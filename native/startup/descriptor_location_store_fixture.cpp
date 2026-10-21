#define NOMINMAX
#include "descriptor_location_store.h"
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

// CPU-only exact-location representation experiment. All inputs are synthetic.
// A live-shaped surrogate is NOT a replay of the game's unrecorded full table.
// No observer, production ABI/cap change, resource lease, graphics or game proof.
namespace {
namespace ls=beamrt::descriptor_locations;
using View=BeamRTResourceView;
using Image=std::array<uint8_t,sizeof(View)>;
using Address=std::pair<uint64_t,uint32_t>;
using Reference=std::map<Address,Image>;
void need(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
Image bytes(const View& v){Image out{};std::memcpy(out.data(),&v,sizeof(v));return out;}
View value(const Image& image){View out{};std::memcpy(&out,image.data(),sizeof(out));return out;}
View makeView(uint64_t resource,uint64_t revision=1){
    View v{};std::memset(&v,0,sizeof(v));v.bytes=sizeof(v);v.abi=1;v.kind=1;v.heapId=77;
    v.resourceId=resource;v.canonicalIdentity=0x100000+resource*0x1000;v.revision=revision;
    v.resource.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;v.resource.Width=v.resource.Height=16;
    v.resource.DepthOrArraySize=1;v.resource.MipLevels=4;v.resource.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
    v.resource.SampleDesc.Count=1;v.resource.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    v.srv.Format=v.resource.Format;v.srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;
    v.srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;v.srv.Texture2D.MipLevels=4;
    need(beamrtResourceViewValid(v,1),"invalid synthetic source view");return v;
}
Image normalized(const View& v,uint64_t heap){auto out=bytes(v);std::memcpy(out.data()+offsetof(View,heapId),&heap,sizeof(heap));return out;}
Image payloadKey(const Image& image){
    // Independent full-value oracle. No production key slices or slot indexes.
    auto key=image;std::memset(key.data()+offsetof(View,heapId),0,sizeof(uint64_t));
    std::memset(key.data()+offsetof(View,revision),0,sizeof(uint64_t));return key;
}
void expect(ls::Store& s,uint64_t heap,uint32_t index,const Image& expected){
    View out{};std::memset(&out,0xa5,sizeof(out));need(s.get(heap,index,out)==ls::Result::Ok,"lookup failed");
    need(bytes(out)==expected,"full 168-byte value changed (identity, padding, heap or revision)");
    need(beamrtResourceViewValid(out,out.kind),"decoded view failed existing validator");
}
void expect(ls::Store& s,uint64_t heap,uint32_t index,const View& v){expect(s,heap,index,normalized(v,heap));}
void cleared(ls::Store& s,uint64_t heap,uint32_t index,ls::Result result){
    View out{};std::memset(&out,0xa5,sizeof(out));need(s.get(heap,index,out)==result,"wrong missing/invalid/unhealthy lookup result");
    need(beamrtResourceZero(out),"refused lookup exposed stale output");
}
void stats(ls::Store& s,uint32_t locations,uint32_t payloads,uint32_t heaps,uint32_t used){
    const auto actual=s.stats();need(actual.healthy && actual.locations==locations && actual.payloads==payloads && actual.heaps==heaps && actual.usedBytes==used,
        "location/payload/heap/byte accounting differed from independent reference");
}
void checkReference(ls::Store& s,const Reference& reference){
    std::set<Image> payloads;std::set<uint64_t> heaps;
    for(const auto& item:reference){payloads.insert(payloadKey(item.second));heaps.insert(item.first.first);expect(s,item.first.first,item.first.second,item.second);}
    const auto l=static_cast<uint32_t>(reference.size()),p=static_cast<uint32_t>(payloads.size()),h=static_cast<uint32_t>(heaps.size());
    stats(s,l,p,h,512+14*l+160*p);need(s.occupied()==l,"aggregate occupied count differed");
    for(const auto heap:heaps){uint32_t count=0;for(const auto& item:reference)if(item.first.first==heap)++count;need(s.occupied(heap)==count,"per-heap logical count differed");}
}
void poisoned(ls::Store& s,ls::Result result,ls::Cause cause){
    const auto original=s.failure();const auto before=s.stats();need(!before.healthy && original.result==result && original.cause==cause,"wrong poison result/cause");
    need(original.locations==before.locations && original.payloads==before.payloads && original.heaps==before.heaps && original.usedBytes==before.usedBytes,
        "failure did not describe post-clear storage");
    cleared(s,1,0,ls::Result::Unhealthy);cleared(s,0,0,ls::Result::Unhealthy);
    need(s.put(1,0,makeView(999,UINT64_MAX))==ls::Result::Unhealthy && s.erase(1,0)==ls::Result::Unhealthy
        && s.retireHeap(1)==ls::Result::Unhealthy && s.retireResource(1)==ls::Result::Unhealthy,"strict mutation succeeded after poison");
    const auto after=s.failure();const auto now=s.stats();need(!std::memcmp(&original,&after,sizeof(after)),"first failure changed after poison");
    need(now.locations==before.locations && now.payloads==before.payloads && now.heaps==before.heaps && now.usedBytes==before.usedBytes,"strict poisoned mutation changed occupancy");
}
uint32_t scatter(uint32_t index){return index*2654435761u^0xfedcba98u;}
void legacyDistinct(){
    auto owner=std::make_unique<ls::Store>();auto& s=*owner;Reference reference;stats(s,0,0,0,512);
    for(uint32_t i=0;i<256;++i){const auto view=makeView(i+1,uint64_t(i)+1);
        need(s.put(1,scatter(i),view)==ls::Result::Ok,"legacy 256 distinct descriptions no longer fit");reference[{1,scatter(i)}]=normalized(view,1);}
    stats(s,256,256,1,45056);checkReference(s,reference);expect(s,1,scatter(255),reference.at({1,scatter(255)}));
    need(s.put(1,scatter(256),makeView(257,257))==ls::Result::Capacity,"257th distinct payload bypassed exact payload bound");
    const auto f=s.failure();need(f.attemptedLocations==257 && f.attemptedPayloads==257 && f.attemptedHeaps==1 && f.requiredBytes==45230,"payload exhaustion lost exact demand");
    poisoned(s,ls::Result::Capacity,ls::Cause::PayloadCapacity);
    std::cout<<"PASS legacy 256 distinct full views fit 45056 bytes; payload slot 255 roundtrips\n";
}
void liveShapedSurrogate(){
    auto owner=std::make_unique<ls::Store>();auto& s=*owner;Reference reference;uint64_t revision=uint64_t(1)<<55;
    for(uint32_t i=0;i<2000;++i){const uint64_t heap=i<34?1u:i<49?2u:3u;revision+=3+i%17;
        const auto view=makeView(1+i%47,revision);need(s.put(heap,scatter(i),view)==ls::Result::Ok,"scattered surrogate exhausted unexpectedly");
        reference[{heap,scatter(i)}]=normalized(view,heap);
        if(i==1023){stats(s,1024,47,3,22368);need(s.occupied(1)==34 && s.occupied(2)==15 && s.occupied(3)==975,"surrogate heap partition changed");checkReference(s,reference);}
    }
    stats(s,2000,47,3,36032);checkReference(s,reference);
    std::cout<<"PASS SYNTHETIC surrogate only, NOT live replay: L1024/P47 heaps34/15/975; 2000 arbitrary scattered locations fit\n";
}
void fullWidthAndHeapReuse(){
    {
        auto aliases=std::make_unique<ls::Store>();const uint64_t low=1,high=(uint64_t(1)<<32)|1;
        const auto a=makeView(11,(uint64_t(1)<<60)+3),b=makeView(22,(uint64_t(1)<<60)+17);
        need(aliases->put(low,7,a)==ls::Result::Ok && aliases->put(high,7,b)==ls::Result::Ok,"full64 heap alias baseline failed");
        View first{},second{};
        need(aliases->get(low,7,first)==ls::Result::Ok && aliases->get(high,7,second)==ls::Result::Ok
            && bytes(first)==normalized(a,low) && bytes(second)==normalized(b,high),"full64 heap identity alias changed copied values");
    }
    auto owner=std::make_unique<ls::Store>();auto& s=*owner;Reference reference;uint64_t revision=(uint64_t(1)<<61)+7;
    for(uint32_t i=0;i<32;++i){const uint64_t heap=(uint64_t(i+1)<<32)|5;revision+=11+i;
        const auto view=makeView(1,revision);need(s.put(heap,UINT_MAX-i,view)==ls::Result::Ok,"full 64-bit heap directory slot failed");reference[{heap,UINT_MAX-i}]=normalized(view,heap);}
    stats(s,32,1,32,1120);checkReference(s,reference);
    const auto retiredHeap=(uint64_t(16)<<32)|5;const auto retained=reference.at({retiredHeap,UINT_MAX-15});
    need(s.erase(retiredHeap,UINT_MAX-15)==ls::Result::Ok,"last heap reference did not erase");reference.erase({retiredHeap,UINT_MAX-15});
    const uint64_t replacement=UINT64_MAX;const auto fresh=makeView(1,++revision);
    need(s.put(replacement,UINT_MAX,fresh)==ls::Result::Ok,"freed heap slot could not be reused");reference[{replacement,UINT_MAX}]=normalized(fresh,replacement);
    cleared(s,retiredHeap,UINT_MAX-15,ls::Result::NotFound);checkReference(s,reference);
    need(value(retained).heapId==retiredHeap,"held value snapshot changed during heap-slot ABA reuse");
    need(s.retireHeap(replacement)==ls::Result::Ok,"replacement heap retirement failed");reference.erase({replacement,UINT_MAX});checkReference(s,reference);
    const auto newer=makeView(1,++revision);need(s.put(retiredHeap,0,newer)==ls::Result::Ok,"numeric old heap ID could not be independently supplied after retirement");expect(s,retiredHeap,0,newer);
    need(s.put(UINT64_MAX-1,1,makeView(1,++revision))==ls::Result::Capacity,"33rd full-width heap bypassed physical directory bound");
    const auto f=s.failure();need(f.attemptedLocations==33 && f.attemptedHeaps==33 && f.attemptedPayloads==1 && f.requiredBytes==1134,"physical heap failure lost exact demand");
    poisoned(s,ls::Result::Capacity,ls::Cause::HeapCapacity);
    std::cout<<"PASS full64 heap/revision IDs, all32 heap slots and last-reference slot reuse without ABA aliases\n";
}
void movedPayloadRepair(){
    auto owner=std::make_unique<ls::Store>();auto& s=*owner;Reference reference;uint64_t revision=0;
    for(uint32_t i=0;i<256;++i){const auto view=makeView(i+1,++revision);need(s.put(1,scatter(i),view)==ls::Result::Ok,"payload slot fill failed");reference[{1,scatter(i)}]=normalized(view,1);}
    for(uint64_t heap=2;heap<=32;++heap){const auto view=makeView(256,++revision);need(s.put(heap,UINT_MAX,view)==ls::Result::Ok,"last payload fanout failed");reference[{heap,UINT_MAX}]=normalized(view,heap);}
    need(s.erase(1,scatter(1))==ls::Result::Ok,"middle payload erase failed");reference.erase({1,scatter(1)});
    View repaired{};need(s.get(32,UINT_MAX,repaired)==ls::Result::Ok && bytes(repaired)==reference.at({32,UINT_MAX}),"moved payload reference not repaired");
    checkReference(s,reference);
    need(s.retireResource(1)==ls::Result::Ok,"resource retirement failed");reference.erase({1,scatter(0)});checkReference(s,reference);
    need(s.retireResource(256)==ls::Result::Ok,"shared moved payload retirement failed");
    for(auto it=reference.begin();it!=reference.end();)if(value(it->second).resourceId==256)it=reference.erase(it);else ++it;
    checkReference(s,reference);need(s.stats().heaps==1,"empty heap references survived moved payload retirement");
    std::cout<<"PASS dense payload compaction repairs every location and heap refcount\n";
}
void exactPayloadBytes(){
    auto owner=std::make_unique<ls::Store>();auto& s=*owner;std::vector<Image> images;const auto base=makeView(1);images.push_back(bytes(base));
    auto changed=value(bytes(base));changed.srv.Texture2D.ResourceMinLODClamp=0.25f;images.push_back(bytes(changed));
    changed=value(bytes(base));changed.defaultView=1;images.push_back(bytes(changed));
    changed=value(bytes(base));changed.srv.Texture2D.MostDetailedMip=1;changed.srv.Texture2D.MipLevels=3;images.push_back(bytes(changed));
    changed=value(bytes(base));changed.resource.Width=32;images.push_back(bytes(changed));
    changed=value(bytes(base));changed.canonicalIdentity+=16;images.push_back(bytes(changed));
    changed=value(bytes(base));changed.resourceId=2;images.push_back(bytes(changed));
    changed=value(bytes(base));const uint32_t negativeZero=0x80000000u;std::memcpy(&changed.srv.Texture2D.ResourceMinLODClamp,&negativeZero,sizeof(negativeZero));images.push_back(bytes(changed));
    auto padding=bytes(base);padding[offsetof(View,resource)+sizeof(D3D12_RESOURCE_DIMENSION)]=0xa5;images.push_back(padding);
    changed=value(bytes(base));changed.kind=2;changed.srv={};changed.rtv.Format=changed.resource.Format;changed.rtv.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2D;images.push_back(bytes(changed));
    Reference reference;uint64_t revision=0;for(uint32_t i=0;i<images.size();++i){auto view=value(images[i]);view.revision=++revision;
        need(beamrtResourceViewValid(view,view.kind) && s.put(1,i,view)==ls::Result::Ok,"exact-byte variant failed");reference[{1,i}]=normalized(view,1);}
    auto duplicate=makeView(1,++revision);need(s.put(2,0,duplicate)==ls::Result::Ok,"identical exact-payload sharing failed");reference[{2,0}]=normalized(duplicate,2);
    checkReference(s,reference);stats(s,11,10,2,2266);
    std::cout<<"PASS exact payload identity includes full descriptions, signed zero, raw padding and resource lifetime\n";
}
void copySnapshotsAndUnknowns(){
    auto owner=std::make_unique<ls::Store>(ls::Limits{5,8,8});auto& s=*owner;Reference reference;uint64_t revision=0;
    const auto put=[&](uint64_t heap,uint32_t index,uint64_t resource){const auto v=makeView(resource,++revision);need(s.put(heap,index,v)==ls::Result::Ok,"copy fixture put failed");reference[{heap,index}]=normalized(v,heap);};
    put(1,0,11);put(1,1,22);put(2,50,33);put(2,80,44);put(3,0,55);checkReference(s,reference);
    const std::array<Address,3> sources{{{1,0},{99,3},{1,1}}},destinations{{{2,80},{3,0},{2,50}}};
    std::array<Image,3> snapshots{};std::array<bool,3> known{};
    for(unsigned i=0;i<sources.size();++i){const auto at=reference.find(sources[i]);if(at!=reference.end()){known[i]=true;snapshots[i]=at->second;expect(s,sources[i].first,sources[i].second,snapshots[i]);}}
    for(const auto& destination:destinations){need(s.erase(destination.first,destination.second)==ls::Result::Ok,"whole-batch destination clear failed");reference.erase(destination);}
    for(unsigned i=0;i<destinations.size();++i){++revision;if(!known[i])continue;auto v=value(snapshots[i]);v.revision=revision;
        const auto& destination=destinations[i];need(s.put(destination.first,destination.second,v)==ls::Result::Ok,"post-clear copied snapshot did not fit");reference[destination]=normalized(v,destination.first);}
    checkReference(s,reference);cleared(s,3,0,ls::Result::NotFound);
    const auto retained=reference.at({2,80});put(1,0,66);need(reference.at({2,80})==retained,"reference copy independence failed");expect(s,2,80,retained);
    put(2,50,77);expect(s,1,1,reference.at({1,1}));need(s.retireHeap(1)==ls::Result::Ok,"source heap retirement failed");
    for(auto it=reference.begin();it!=reference.end();)if(it->first.first==1)it=reference.erase(it);else ++it;
    checkReference(s,reference);expect(s,2,80,retained);
    std::cout<<"PASS caller-model source snapshots, clear-all-before-write, unknown holes, revision gaps and copy independence\n";
}
void capacityPriorityAndOverwrite(){
    for(uint32_t which=0;which<3;++which){const ls::Limits limits=which==0?ls::Limits{1,1,1}:which==1?ls::Limits{8,1,1}:ls::Limits{8,1,8};
        auto owner=std::make_unique<ls::Store>(limits);auto& s=*owner;need(s.put(1,0,makeView(1,1))==ls::Result::Ok,"capacity priority baseline failed");
        need(s.put(which==2?1u:2u,1,makeView(2,2))==ls::Result::Capacity,"capacity priority control did not fail");
        const auto f=s.failure();need(f.attemptedLocations==2 && f.attemptedPayloads==2 && f.attemptedHeaps==(which==2?1u:2u) && f.requiredBytes==860,"exact priority demand changed");
        poisoned(s,ls::Result::Capacity,which==0?ls::Cause::LocationCapacity:which==1?ls::Cause::HeapCapacity:ls::Cause::PayloadCapacity);}
    {auto owner=std::make_unique<ls::Store>(ls::Limits{4,1,2});auto& s=*owner;
        need(s.put(1,0,makeView(1,1))==ls::Result::Ok && s.put(1,0,makeView(2,2))==ls::Result::Ok,"sole overwritten payload/heap was not reclaimed first");stats(s,1,1,1,686);
        need(s.put(1,1,makeView(2,3))==ls::Result::Ok && s.put(1,0,makeView(3,4))==ls::Result::Capacity,"post-clear payload failure not reached");
        const auto f=s.failure();need(f.locations==1 && f.payloads==1 && f.heaps==1 && f.usedBytes==686 && f.requiredBytes==860,"overwrite failure sampled pre-clear occupancy");
        poisoned(s,ls::Result::Capacity,ls::Cause::PayloadCapacity);}
    std::cout<<"PASS Location -> Heap -> Payload priority, precise demand and post-overwrite-clear accounting\n";
}
void exactByteBoundary(){
    auto owner=std::make_unique<ls::Store>();auto& s=*owner;uint64_t revision=0;
    for(uint32_t i=0;i<3248;++i)need(s.put(1,scatter(i),makeView(1+i%7,++revision))==ls::Result::Ok,"exact-byte boundary fill failed");
    stats(s,3248,7,1,47104);
    need(s.put(1,scatter(3248),makeView(1,++revision))==ls::Result::Capacity,"one shared location exceeded arena without refusal");
    const auto f=s.failure();need(f.attemptedLocations==3249 && f.attemptedPayloads==7 && f.attemptedHeaps==1 && f.requiredBytes==47118,"byte failure lost actual required bytes");
    poisoned(s,ls::Result::Capacity,ls::Cause::ByteCapacity);
    std::cout<<"PASS exact47104 byte arena including512 directory; next shared location requires47118\n";
}
void diagnosticReaping(){
    auto owner=std::make_unique<ls::Store>(ls::Limits{4,8,8});auto& s=*owner;
    need(s.put(1,0,makeView(11,1))==ls::Result::Ok && s.put(1,1,makeView(22,2))==ls::Result::Ok
        && s.put(2,0,makeView(11,3))==ls::Result::Ok && s.put(3,0,makeView(33,4))==ls::Result::Ok,"diagnostic baseline failed");
    need(s.put(4,0,makeView(44,5))==ls::Result::Capacity,"diagnostic capacity failure not reached");poisoned(s,ls::Result::Capacity,ls::Cause::LocationCapacity);const auto original=s.failure();
    const auto unchanged=[&](uint32_t l,uint32_t p,uint32_t h,uint32_t used){const auto now=s.stats();const auto failure=s.failure();
        need(!now.healthy && now.locations==l && now.payloads==p && now.heaps==h && now.usedBytes==used && s.occupied()==l,"poisoned diagnostic counts incorrect");
        need(!std::memcmp(&original,&failure,sizeof(failure)),"diagnostic reap replaced immutable failure");cleared(s,1,0,ls::Result::Unhealthy);};
    need(s.reapDeadHeap(0)==ls::Result::Invalid && s.reapDeadResource(0)==ls::Result::Invalid,"invalid diagnostic IDs accepted");unchanged(4,3,3,1048);
    need(s.reapDeadHeap(1)==ls::Result::Ok,"poisoned dead heap reap failed");unchanged(2,2,2,860);
    need(s.reapDeadResource(11)==ls::Result::Ok,"poisoned dead resource reap failed");unchanged(1,1,1,686);
    need(s.reapDeadHeap(99)==ls::Result::Ok && s.reapDeadResource(99)==ls::Result::Ok,"unrelated diagnostic reap failed");unchanged(1,1,1,686);
    need(s.reapDeadResource(33)==ls::Result::Ok && s.reapDeadHeap(3)==ls::Result::Ok,"last diagnostic reference could not reap");unchanged(0,0,0,512);
    need(s.put(1,0,makeView(55,6))==ls::Result::Unhealthy,"diagnostic empty store recovered health");
    std::cout<<"PASS poisoned dead-ID reaping shrinks counts to fixed512 directory without recovery or failure replacement\n";
}
void invalidInputsAndRevisions(){
    {auto owner=std::make_unique<ls::Store>();auto& s=*owner;cleared(s,0,0,ls::Result::Invalid);cleared(s,1,0,ls::Result::NotFound);stats(s,0,0,0,512);
        auto v=makeView(1,UINT64_MAX);v.heapId=0;need(s.put(UINT64_MAX,UINT_MAX,v)==ls::Result::Ok,"full-width boundary view refused");expect(s,UINT64_MAX,UINT_MAX,v);}
    const std::array<ls::Limits,6> invalidLimits{{{0,1,1},{4097,1,1},{1,0,1},{1,257,1},{1,1,0},{1,1,33}}};
    for(const auto limits:invalidLimits){auto owner=std::make_unique<ls::Store>(limits);poisoned(*owner,ls::Result::Invalid,ls::Cause::Limits);}
    for(uint32_t which=0;which<8;++which){auto owner=std::make_unique<ls::Store>();auto& s=*owner;auto v=makeView(1);uint64_t heap=1;
        switch(which){case 0:v.bytes=0;break;case 1:v.abi=2;break;case 2:v.kind=3;break;case 3:v.resourceId=0;break;
            case 4:v.revision=0;break;case 5:v.srv.Texture2D.ResourceMinLODClamp=std::numeric_limits<float>::quiet_NaN();break;case 6:v.canonicalIdentity=0;break;case 7:heap=0;break;}
        need(s.put(heap,0,v)==ls::Result::Invalid,"malformed view accepted");poisoned(s,ls::Result::Invalid,ls::Cause::View);}
    for(uint32_t which=0;which<3;++which){auto owner=std::make_unique<ls::Store>();auto& s=*owner;
        const auto result=which==0?s.erase(0,0):which==1?s.retireHeap(0):s.retireResource(0);need(result==ls::Result::Invalid,"zero strict identity accepted");
        poisoned(s,ls::Result::Invalid,which<2?ls::Cause::HeapId:ls::Cause::ResourceId);}
    for(uint32_t which=0;which<5;++which){auto owner=std::make_unique<ls::Store>();auto& s=*owner;need(s.put(1,0,makeView(1,100))==ls::Result::Ok,"revision baseline failed");
        if(which==1)need(s.erase(1,0)==ls::Result::Ok,"revision erase failed");if(which==2)need(s.retireHeap(1)==ls::Result::Ok,"revision heap retire failed");
        if(which==3)need(s.retireResource(1)==ls::Result::Ok,"revision resource retire failed");if(which==4)need(s.reapDeadHeap(1)==ls::Result::Ok,"revision diagnostic reap failed");
        need(s.put(2,UINT_MAX,makeView(2,which?99:100))==ls::Result::Invalid,"global revision watermark reset or equal/descending revision accepted");poisoned(s,ls::Result::Invalid,ls::Cause::Revision);}
    std::cout<<"PASS cleared failures, malformed values/limits/IDs and globally increasing full64 revisions across retirement\n";
}
uint32_t randomWord(uint32_t& seed){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
void randomizedReference(){
    auto owner=std::make_unique<ls::Store>(ls::Limits{128,64,16});auto& s=*owner;Reference reference;uint32_t seed=0x8375ca11;uint64_t revision=(uint64_t(1)<<56)+19;
    for(uint32_t iteration=0;iteration<5000;++iteration){const auto word=randomWord(seed);const uint64_t heap=(uint64_t(1+(word>>8)%12)<<32)|5;
        const uint32_t index=scatter((word>>16)%8),operation=word%100;
        if(operation<70){revision+=1+(word>>24)%19;auto v=makeView(1+(word>>20)%12,revision);if(v.resourceId%3==0)v.defaultView=1;
            need(s.put(heap,index,v)==ls::Result::Ok,"bounded randomized put failed");reference[{heap,index}]=normalized(v,heap);
        }else if(operation<89){need(s.erase(heap,index)==ls::Result::Ok,"randomized erase failed");reference.erase({heap,index});
        }else if(operation<95){need(s.retireHeap(heap)==ls::Result::Ok,"randomized heap retire failed");for(auto it=reference.begin();it!=reference.end();)if(it->first.first==heap)it=reference.erase(it);else ++it;
        }else{const uint64_t resource=1+(word>>20)%12;need(s.retireResource(resource)==ls::Result::Ok,"randomized resource retire failed");for(auto it=reference.begin();it!=reference.end();)if(value(it->second).resourceId==resource)it=reference.erase(it);else ++it;}
        checkReference(s,reference);
        for(uint32_t h=1;h<=12;++h)for(uint32_t i=0;i<8;++i){const uint64_t candidate=(uint64_t(h)<<32)|5;if(reference.find({candidate,scatter(i)})==reference.end())cleared(s,candidate,scatter(i),ls::Result::NotFound);}
    }
    for(uint32_t h=1;h<=12;++h)need(s.retireHeap((uint64_t(h)<<32)|5)==ls::Result::Ok,"post-randomized cleanup failed");reference.clear();checkReference(s,reference);
    for(uint32_t i=0;i<128;++i){revision+=3;const auto v=makeView(1,revision);need(s.put(1,scatter(i),v)==ls::Result::Ok,"post-randomized planned bounded fill failed");reference[{1,scatter(i)}]=normalized(v,1);}
    checkReference(s,reference);need(s.put(1,scatter(128),makeView(1,++revision))==ls::Result::Capacity,"post-randomized logical exhaustion did not fail");
    poisoned(s,ls::Result::Capacity,ls::Cause::LocationCapacity);
    std::cout<<"PASS5000 deterministic operations against independent full168-byte map including heap-slot churn and planned exhaustion\n";
}
} // namespace
int main(){try{
    static_assert(ls::arenaBytes==47104 && ls::directoryBytes==512 && ls::locationBytes==14 && ls::payloadBytes==160);
    static_assert(ls::logicalLocationLimit==4096 && ls::heapLimit==32);
    std::cout<<"Compiled Store bytes="<<sizeof(ls::Store)<<" including arena and explicit bookkeeping\n";
    legacyDistinct();liveShapedSurrogate();fullWidthAndHeapReuse();movedPayloadRepair();exactPayloadBytes();copySnapshotsAndUnknowns();
    capacityPriorityAndOverwrite();exactByteBoundary();diagnosticReaping();invalidInputsAndRevisions();randomizedReference();
    std::cout<<"PASS descriptor location store:11 CPU-only groups; synthetic only, no production ABI/caps, observer, GPU or game proof\n";return 0;
}catch(const std::exception& e){std::cerr<<"Descriptor location fixture failed: "<<e.what()<<'\n';return 1;}}
