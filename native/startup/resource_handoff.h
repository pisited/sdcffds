#pragma once
#include "binding_handoff.h"
#include "resource_record.h"
#include "resource_copy_validation.h"
#include "resource_view_validation.h"
#include <cstring>
inline constexpr GUID beamrtResourceGuid={0x4cc8f4bf,0x9365,0x4f0e,{0x98,0xc9,0xb6,0x3d,0x1f,0x9d,0x4b,0xae}};
inline constexpr uint64_t beamrtResourceMagic=0x4252545245534f42ull;
inline constexpr uint32_t beamrtResourceHandoffABI=7;
struct BeamRTResourcePayload {
    uint32_t bytes,abi;uint64_t magic;uint32_t processId,initialThread;
    uint64_t outputMapping,startEvent;uint32_t cbvProbeBytes,mode;
    uint32_t profile,reserved;
};
static_assert(sizeof(BeamRTResourcePayload)==56,"separate default-off resource payload ABI v7");
inline bool beamrtResourcePayloadValid(const BeamRTResourcePayload* p,DWORD bytes,DWORD pid,DWORD thread){
    return p && bytes==sizeof(*p) && p->bytes==sizeof(*p) && p->abi==beamrtResourceHandoffABI && p->magic==beamrtResourceMagic
        && pid && p->processId==pid && thread && p->initialThread==thread && p->mode<=beamrtResourceDescriptorTextures && p->cbvProbeBytes<=65536
        && (p->mode!=beamrtResourceDescriptorTextures || !p->cbvProbeBytes)
        && beamrtResourceStorageProfileValid(p->profile) && !p->reserved
        && (p->profile==beamrtResourceStorageLegacy || p->mode==beamrtResourceDescriptorTextures)
        && p->outputMapping && p->outputMapping!=UINT64_MAX && p->startEvent && p->startEvent!=UINT64_MAX && p->outputMapping!=p->startEvent;
}
struct BeamRTResourceStartReceipt {uint32_t bytes,abi,processId,initialThread,callerThread;HRESULT result;uint32_t mode,reserved,profile,reserved2;
    BeamRTResourceStatus status;BeamRTResourceFailure firstFailure;BeamRTResourceStorageSnapshot storage;BeamRTResourceStorageFailure storageFailure;};
struct BeamRTResourceRecordReceipt {uint32_t bytes,abi,processId,recordThread;uint64_t snapshotSerial;uint32_t mode,reserved,profile,reserved2;
    BeamRTResourceDrawObservation observation;BeamRTResourceCopyFailure copyFailure;};
struct BeamRTResourceReply {BeamRTResourceStartReceipt start;BeamRTResourceRecordReceipt record;};
static_assert(sizeof(BeamRTResourceStartReceipt)==392,"resource start receipt ABI v7");
static_assert(sizeof(BeamRTResourceRecordReceipt)==32768,"resource record receipt ABI v7");
static_assert(sizeof(BeamRTResourceReply)==33160,"resource reply ABI v7");
inline bool beamrtResourceStartReceiptValid(const BeamRTResourceStartReceipt& r,DWORD pid,DWORD thread,uint32_t expectedMode=beamrtResourceAllAllocations,uint32_t expectedProfile=beamrtResourceStorageLegacy){
    const auto& s=r.status;
    return pid && thread && r.bytes==sizeof(r) && r.abi==beamrtResourceHandoffABI && r.processId==pid
        && r.initialThread==thread && r.callerThread==thread && expectedMode<=beamrtResourceDescriptorTextures
        && r.mode==expectedMode && !r.reserved && !r.reserved2 && r.profile==expectedProfile && beamrtResourceStorageProfileValid(expectedProfile)
        && (expectedProfile==beamrtResourceStorageLegacy || expectedMode==beamrtResourceDescriptorTextures)
        && s.bytes==sizeof(s) && s.abi==beamrtResourceStatusABI(expectedProfile)
        && s.enabled<=1 && s.healthy<=1 && s.ownerThread==thread && s.attachedSlots<=10 && s.restoredSlots<=10
        && !s.reserved && !s.reserved2 && s.liveHeaps<=beamrtResourceHeapLimit && s.liveResources<=beamrtResourceObjectLimit
        && s.views<=beamrtResourceLocationLimit(expectedProfile) && s.serial!=UINT64_MAX && beamrtResourceFailureValid(r.firstFailure,s,expectedProfile)
        && beamrtResourceStorageEvidenceValid(r.storage,r.storageFailure,r.firstFailure,s,expectedProfile);
}
inline bool beamrtResourceObservationValid(const BeamRTResourceDrawObservation& o,const BeamRTBindingSnapshot& s,DWORD thread,uint32_t expectedProfile=beamrtResourceStorageLegacy){
    if(!beamrtBindingSnapshotValid(s) || o.bytes!=sizeof(o) || o.abi!=beamrtResourceDrawABI || o.attempted!=1 || o.intervalAccepted>1 || o.recordThread!=thread || !thread
        || o.srvCount!=6 || o.rtvCount!=s.renderTargetCount || o.cbvProbeBytes>65536 || o.commandId!=s.commandId || o.generation!=s.generation
        || o.snapshotSerial!=s.serial || o.callbacksBegin>o.callbacksEnd || !beamrtResourceStorageProfileValid(expectedProfile)
        || o.status.bytes!=sizeof(o.status) || o.status.abi!=beamrtResourceStatusABI(expectedProfile)
        || o.status.enabled>1 || o.status.healthy>1 || !o.status.ownerThread || o.status.attachedSlots>10 || o.status.restoredSlots>10
        || o.status.liveHeaps>beamrtResourceHeapLimit || o.status.liveResources>beamrtResourceObjectLimit || o.status.views>beamrtResourceLocationLimit(expectedProfile)
        || o.status.reserved || o.status.reserved2 || o.status.serial==UINT64_MAX || o.status.callbacks!=o.callbacksEnd
        || o.descriptorProvenanceVerified || o.cbvContentsVerified || o.cameraVerified || o.gpuOrderingVerified || o.lightingConsumed
        || o.reserved || o.outputCheckpointValid>1 || (!o.outputCheckpointValid && (o.outputCallbacks || o.outputThread))
        || !beamrtResourceFailureValid(o.firstFailure,o.status,expectedProfile)
        || !beamrtResourceStorageEvidenceValid(o.storage,o.storageFailure,o.firstFailure,o.status,expectedProfile))return false;
    if(o.intervalAccepted){if(o.result!=S_OK || !o.ticket || !o.status.enabled || !o.status.healthy || o.callbacksBegin!=o.callbacksEnd
        || !o.outputCheckpointValid || o.outputThread!=thread || o.outputCallbacks!=o.callbacksBegin)return false;}
    else if(!FAILED(o.result))return false;
    for(unsigned i=0;i<6;++i){
        if(o.srvResults[i]==S_OK){if(!o.intervalAccepted || !beamrtResourceViewValid(o.srvs[i],1) || o.srvs[i].revision>o.status.serial)return false;}
        else if((SUCCEEDED(o.srvResults[i]) && o.srvResults[i]!=S_FALSE) || !beamrtResourceZero(o.srvs[i]))return false;
    }
    for(unsigned i=0;i<8;++i){
        if(i>=o.rtvCount){if(o.rtvResults[i]!=S_FALSE || !beamrtResourceZero(o.rtvs[i]))return false;}
        else if(o.rtvResults[i]==S_OK){if(!o.intervalAccepted || !beamrtResourceViewValid(o.rtvs[i],2) || o.rtvs[i].revision>o.status.serial)return false;}
        else if((SUCCEEDED(o.rtvResults[i]) && o.rtvResults[i]!=S_FALSE) || !beamrtResourceZero(o.rtvs[i]))return false;
    }
    if(o.cbvResult==S_OK){const auto& c=o.cbv;
        if(!o.intervalAccepted || !o.cbvProbeBytes || c.bytes!=sizeof(c) || c.abi!=1 || c.candidateOnly!=1 || c.reserved
            || !c.resourceId || !c.canonicalIdentity || c.address!=s.cbv || c.address%256 || c.resource.Dimension!=D3D12_RESOURCE_DIMENSION_BUFFER
            || c.offset>=c.resource.Width || c.offset>c.address || c.availableBytes!=c.resource.Width-c.offset || o.cbvProbeBytes>c.availableBytes)return false;
    }else if((SUCCEEDED(o.cbvResult) && o.cbvResult!=S_FALSE) || !beamrtResourceZero(o.cbv))return false;
    if(!o.cbvProbeBytes && o.cbvResult!=S_FALSE)return false;return true;
}
HRESULT BeamRT_ResourceStartFromPayload(ID3D12Device*);
uint32_t BeamRT_ResourceProbeBytes();
void BeamRT_ResourcePublishForBinding(const BeamRTBindingSnapshot&,DWORD,const BeamRTResourceDrawObservation*);
extern "C" BEAMRT_RESOURCE_API HRESULT WINAPI BeamRT_ResourceRecordRead(BeamRTResourceRecordReceipt*,uint32_t);
