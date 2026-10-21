#pragma once
#include "startup_contract.h"
#include "gi_bindings.h"
#include "binding_validation.h"
#include <cmath>
inline constexpr GUID beamrtBindingGuid={0x1d86baa8,0x5734,0x4233,{0x97,0x4e,0x34,0x77,0x31,0xc9,0x2a,0xed}};
inline constexpr uint64_t beamrtBindingMagic=0x42525442494e4447ull;
// Reply layout v2 adds bounded thread evidence. Old payloads fail closed;
// the public status/snapshot APIs and 1144-byte recording artifact stay v1.
inline constexpr uint32_t beamrtBindingHandoffABI=2;
struct BeamRTBindingPayload {
    uint32_t bytes,abi;uint64_t magic;uint32_t processId,initialThread;
    uint64_t outputMapping,startEvent,recordEvent;uint32_t reserved[2];
};
static_assert(sizeof(BeamRTBindingPayload)==56,"binding payload ABI v1 layout");
inline bool beamrtBindingPayloadValid(const BeamRTBindingPayload* p,DWORD size,DWORD pid,DWORD thread){
    return p && size==sizeof(*p) && p->bytes==sizeof(*p) && p->abi==beamrtBindingHandoffABI && p->magic==beamrtBindingMagic
        && pid && p->processId==pid && thread && p->initialThread==thread && !p->reserved[0] && !p->reserved[1]
        && p->outputMapping && p->outputMapping!=UINT64_MAX && p->startEvent && p->startEvent!=UINT64_MAX && p->recordEvent && p->recordEvent!=UINT64_MAX
        && p->outputMapping!=p->startEvent && p->outputMapping!=p->recordEvent && p->startEvent!=p->recordEvent;
}
struct BeamRTBindingStartReceipt {uint32_t bytes,abi,processId,initialThread,callerThread;HRESULT result;BeamRTBindingStatus status;};
struct BeamRTBindingRecordReceipt {uint32_t bytes,abi,processId,recordThread;BeamRTBindingStatus status;BeamRTBindingSnapshot snapshot;};
struct BeamRTBindingProgress {
    volatile LONG enabled,healthy,targetReady,failureReason,failureResult,liveCommands,targetResult,targetThread;
    volatile LONG64 creations,tagged,pressureSkipped,untracked,matchedDraws,rejectedDraws,unsupported,threadRejected,serial,targetAttempts;
};
struct BeamRTBindingThreadReceipt {
    uint32_t bytes,abi,processId,recordThread;uint64_t snapshotSerial;BeamRTBindingThreadDiagnostics diagnostics;
};
struct BeamRTBindingThreadPrefix {
    uint32_t bytes,abi,processId;volatile LONG count;
    BeamRTBindingThreadSample samples[beamrtBindingThreadSampleLimit];
};
static_assert(sizeof(BeamRTBindingRecordReceipt)==1144,"unchanged recording artifact v1");
static_assert(sizeof(BeamRTBindingThreadReceipt)==1184,"coherent first-record thread evidence");
static_assert(sizeof(BeamRTBindingThreadPrefix)==912,"immutable first-conflict prefix");
struct BeamRTBindingReply {BeamRTBindingStartReceipt start;BeamRTBindingRecordReceipt record;BeamRTBindingProgress progress;
    BeamRTBindingThreadReceipt threads;BeamRTBindingThreadPrefix threadSamples;};
// Strict transport shape checks, NOT verification of pointed-to descriptors,
// camera values, resource states, GPU completion or a fresh frame.
inline bool beamrtBindingSnapshotValid(const BeamRTBindingSnapshot& s){
    if(s.bytes!=sizeof(s) || s.abi!=1 || s.recordedDraw!=1 || (s.drawKind!=1 && s.drawKind!=2) || !s.commandId || !s.generation || !s.serial
        || !s.cbv || s.cbv%256 || !s.count || !s.instances || !s.viewportCount || s.viewportCount>16 || !s.scissorCount || s.scissorCount>16
        || !s.renderTargetCount || s.renderTargetCount>8 || s.descriptorProvenanceVerified || s.cbvContentsVerified || s.cameraVerified || s.gpuOrderingVerified || s.lightingConsumed)return false;
    const auto& a=s.srvHeap;const auto& b=s.samplerHeap;
    if(!a.identity || !b.identity || a.type!=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV || b.type!=D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER
        || a.flags!=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE || b.flags!=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE)return false;
    uint64_t srv[6]{},sampler[6]{};if(!beamrtBindingTable(s.srvTable,a,srv) || !beamrtBindingTable(s.samplerTable,b,sampler))return false;
    for(unsigned i=0;i<6;++i)if(srv[i]!=s.srvCpu[i] || sampler[i]!=s.samplerCpu[i])return false;
    for(unsigned i=0;i<s.viewportCount;++i){const auto& v=s.viewports[i];if(!std::isfinite(v.TopLeftX) || !std::isfinite(v.TopLeftY)
        || !std::isfinite(v.Width) || !std::isfinite(v.Height) || v.Width<=0 || v.Height<=0 || !std::isfinite(v.MinDepth) || !std::isfinite(v.MaxDepth)
        || v.MinDepth<0 || v.MaxDepth>1 || v.MinDepth>v.MaxDepth)return false;}
    for(unsigned i=0;i<s.scissorCount;++i)if(s.scissors[i].right<=s.scissors[i].left || s.scissors[i].bottom<=s.scissors[i].top)return false;
    for(unsigned i=0;i<s.renderTargetCount;++i)if(!s.renderTargets[i])return false;return true;
}
HRESULT BeamRT_BindingStartFromPayload(ID3D12Device*);
void BeamRT_BindingBridgeAuditMatch();
HRESULT BeamRT_BindingsVerifiedAuditMatch();
struct BeamRTResourceDrawObservation;
void BeamRT_BindingPublishRecord(const BeamRTBindingStatus&,const BeamRTBindingSnapshot&,DWORD,const BeamRTBindingThreadDiagnostics&,const BeamRTResourceDrawObservation* =nullptr);
void BeamRT_BindingPublishThreadSample(const BeamRTBindingThreadSample&);
void BeamRT_BindingPublishProgress(const BeamRTBindingStatus&);
