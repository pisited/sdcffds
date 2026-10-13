#pragma once
#include "startup_contract.h"
#include <d3d12.h>
struct BeamRTPipelineAuditConfig {
    uint32_t bytes,abi;
    const void* vertex;uint64_t vertexBytes;
    const void* pixel;uint64_t pixelBytes;
    uint32_t reserved[2];
};
inline constexpr uint32_t beamrtPipelineAuditInfoABI=2;
inline constexpr uint32_t beamrtPipelineLayoutCacheLimit=32;
inline constexpr uint64_t beamrtPipelineMetadataBudget=2*1024*1024;
// Reserved for this audit's object-owned COM evidence, never an engine tag.
inline constexpr GUID beamrtPipelineRootEvidenceGuid={0x2c0b703e,0x4b94,0x451d,{0x8c,0x76,0x8b,0xc7,0xf0,0x22,0x1a,0x33}};
enum class BeamRTPipelineFailure : uint32_t {
    none,counterOverflow,invalidRootBytes,rootInterface,rootOwner,
    rootEvidenceConflict,rootEvidenceWrite,pipelineShape,pipelineInterface,
    pipelineOwner,allocation,metadataException,slotInstall,slotRestore,deviceRemoved
};
inline const wchar_t* beamrtPipelineFailureName(uint32_t reason){
    switch(static_cast<BeamRTPipelineFailure>(reason)){
    case BeamRTPipelineFailure::none:return L"none";
    case BeamRTPipelineFailure::counterOverflow:return L"counter-overflow";
    case BeamRTPipelineFailure::invalidRootBytes:return L"invalid-root-bytes";
    case BeamRTPipelineFailure::rootInterface:return L"root-interface";
    case BeamRTPipelineFailure::rootOwner:return L"root-owner";
    case BeamRTPipelineFailure::rootEvidenceConflict:return L"root-evidence-conflict";
    case BeamRTPipelineFailure::rootEvidenceWrite:return L"root-evidence-write";
    case BeamRTPipelineFailure::pipelineShape:return L"pipeline-shape";
    case BeamRTPipelineFailure::pipelineInterface:return L"pipeline-interface";
    case BeamRTPipelineFailure::pipelineOwner:return L"pipeline-owner";
    case BeamRTPipelineFailure::allocation:return L"allocation";
    case BeamRTPipelineFailure::metadataException:return L"metadata-exception";
    case BeamRTPipelineFailure::slotInstall:return L"slot-install";
    case BeamRTPipelineFailure::slotRestore:return L"slot-restore";
    case BeamRTPipelineFailure::deviceRemoved:return L"device-removed";
    default:return L"unknown";
    }
}
struct BeamRTPipelineAuditInfo {
    uint32_t bytes,abi,enabled,healthy,ownerThread,attachedSlots,restoredSlots,reserved;
    uint64_t rootsObserved,graphicsObserved,shaderMatches,unknownRootMatches,unsupportedStreams;
    uint32_t cachedLayouts,rootBytes,renderTargetCount,sampleCount;
    DXGI_FORMAT renderTargetFormats[8];
    uint32_t creationMatchAvailable,drawBindingsVerified,cameraVerified,gpuOrderingVerified,lightingConsumed;
    uint32_t failureReason;HRESULT failureResult;
    uint32_t liveLayouts,liveRootTags;
    uint64_t rootsTagged,budgetSkipped,cacheEvictions,metadataBytes,peakMetadataBytes;
};
static_assert(sizeof(BeamRTPipelineAuditInfo)==200,"pipeline info ABI v2 layout");
#ifdef BEAMRT_PIPELINE_AUDIT_BUILD
#define BEAMRT_PIPELINE_API __declspec(dllexport)
#else
#define BEAMRT_PIPELINE_API __declspec(dllimport)
#endif
extern "C" {
// Explicit valid-device call outside DLL attach. Only public SDK vtable DATA
// slots change; no function instructions or caller-quiescence assertion.
// One process-lifetime session. Start failure may leave resident forwarding
// slots/context; Query reports that state. Never unload after attempting Start.
BEAMRT_PIPELINE_API HRESULT WINAPI BeamRT_PipelineAuditStart(ID3D12Device*,const BeamRTPipelineAuditConfig*);
BEAMRT_PIPELINE_API HRESULT WINAPI BeamRT_PipelineAuditQuery(BeamRTPipelineAuditInfo*,uint32_t bytes);
// Returns the first exact VS+PS creation match and copied observed root bytes.
// Root/PSO outputs transfer COM references. NOT a draw or resource-binding proof.
// All outputs cleared on failure. Only the matching root/PSO remain retained
// until exit; other roots own their metadata and are NOT kept alive by the audit.
BEAMRT_PIPELINE_API HRESULT WINAPI BeamRT_PipelineAuditReadMatch(void* rootBytes,uint32_t capacity,uint32_t* actual,
    ID3D12RootSignature**,ID3D12PipelineState**);
// Owner-thread atomic slot restoration. No heap/context/module/COM retirement,
// no restart or hot-unload. Prefetched old callbacks stay valid after disable.
BEAMRT_PIPELINE_API HRESULT WINAPI BeamRT_PipelineAuditDisable();
}
