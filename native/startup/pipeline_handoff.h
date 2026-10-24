#pragma once
#include "pipeline_audit.h"
inline constexpr GUID beamrtPipelineGuid={0x8b66cf5d,0x6995,0x48cb,{0x9e,0xae,0x84,0x53,0x3d,0x73,0x58,0x89}};
inline constexpr uint64_t beamrtPipelineMagic=0x425254504950454cull;
inline constexpr uint32_t beamrtPipelineHandoffABI=2;
struct BeamRTPipelinePayload {
    uint32_t bytes,abi;uint64_t magic;uint32_t processId,initialThread;
    uint64_t inputMapping,outputMapping,startEvent,matchEvent;
    uint32_t vertexBytes,pixelBytes,reserved[2];
};
static_assert(sizeof(BeamRTPipelinePayload)==72,"pipeline payload layout");
struct BeamRTPipelineInput {uint32_t bytes,abi,vertexBytes,pixelBytes;};
struct BeamRTPipelineStartReceipt {
    uint32_t bytes,abi,processId,initialThread,callerThread;
    HRESULT result;BeamRTPipelineAuditInfo info;
};
struct BeamRTPipelineMatchReceipt {
    uint32_t bytes,abi,processId,rootBytes;BeamRTPipelineAuditInfo info;
    uint8_t root[65536];
};
// Independent immutable regions: start receipt and first exact creation match.
// Signals certify CPU publication only, never GPU execution/completion.
// Individually atomic x64 diagnostic counters only; NOT a coherent frame,
// certified snapshot or eligibility gate. Used to explain a no-match timeout.
struct BeamRTPipelineProgress {
    volatile LONG64 roots,graphics,streams,shaderMatches,unknownRoots;
    volatile LONG healthy,enabled,failureReason,failureResult,cachedLayouts,liveLayouts,liveRootTags;
    volatile LONG64 rootsTagged,budgetSkipped,cacheEvictions,metadataBytes,peakMetadataBytes;
};
struct BeamRTPipelineReply {BeamRTPipelineStartReceipt start;BeamRTPipelineMatchReceipt match;BeamRTPipelineProgress progress;};
inline bool beamrtPipelinePayloadValid(const BeamRTPipelinePayload* p,DWORD bytes,DWORD pid) {
    return p && bytes==sizeof(*p) && p->bytes==sizeof(*p) && p->abi==beamrtPipelineHandoffABI && p->magic==beamrtPipelineMagic
        && pid && p->processId==pid && p->initialThread && p->vertexBytes && p->pixelBytes
        && p->vertexBytes<=16*1024*1024 && p->pixelBytes<=16*1024*1024 && !p->reserved[0] && !p->reserved[1]
        && p->inputMapping && p->inputMapping!=UINT64_MAX && p->outputMapping && p->outputMapping!=UINT64_MAX
        && p->startEvent && p->startEvent!=UINT64_MAX && p->matchEvent && p->matchEvent!=UINT64_MAX;
}
// Called at the first valid imported device output, outside DLL attach. A
// missing separate payload is a no-op. Initial-thread/main-image policy only;
// these checks do not certify loader-lock freedom or all-caller quiescence.
HRESULT BeamRT_PipelineStartFromPayload(ID3D12Device*,const void* importCaller);
// Internal, under the audit metadata lock; immutable first-match publication.
void BeamRT_PipelinePublishMatch(const BeamRTPipelineAuditInfo&,const void*,uint32_t);
void BeamRT_PipelinePublishProgress(const BeamRTPipelineAuditInfo&);
