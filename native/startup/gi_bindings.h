#pragma once
#include <d3d12.h>
#include <cstdint>
#include "binding_thread_diagnostics.h"
inline constexpr uint32_t beamrtBindingABI=1,beamrtBindingCommandLimit=64;
struct BeamRTBindingHeap {
    uint64_t identity,cpu,gpu;uint32_t count,stride,type,flags;
};
struct BeamRTBindingSnapshot {
    uint32_t bytes,abi,recordedDraw,drawKind;
    uint64_t commandId,generation,serial,cbv,srvTable,samplerTable;
    BeamRTBindingHeap srvHeap,samplerHeap;
    uint64_t srvCpu[6],samplerCpu[6];
    uint32_t count,instances,start,baseBits,startInstance;
    uint32_t viewportCount,scissorCount,renderTargetCount;
    D3D12_VIEWPORT viewports[16];D3D12_RECT scissors[16];
    uint64_t renderTargets[8],depthTarget;
    uint32_t descriptorProvenanceVerified,cbvContentsVerified,cameraVerified,gpuOrderingVerified,lightingConsumed;
};
struct BeamRTBindingStatus {
    uint32_t bytes,abi,enabled,healthy,targetReady,snapshotAvailable,ownerThread,attachedSlots;
    uint32_t failureReason;HRESULT failureResult;
    uint64_t creations,tagged,pressureSkipped,untracked,matchedDraws,rejectedDraws,unsupported,threadRejected,serial;
    uint32_t liveCommands,restoredSlots;
};
static_assert(sizeof(BeamRTBindingSnapshot)==1008,"recording snapshot ABI v1 layout");
static_assert(sizeof(BeamRTBindingStatus)==120,"recording status ABI v1 layout");
#ifdef BEAMRT_BINDING_BUILD
#define BEAMRT_BINDING_API __declspec(dllexport)
#else
#define BEAMRT_BINDING_API __declspec(dllimport)
#endif
extern "C" {
// Standalone, explicitly invoked outside DLL attach. SDK vtable DATA swaps only.
// Process-lifetime session; no restart/hot unload, even after partial install.
BEAMRT_BINDING_API HRESULT WINAPI BeamRT_BindingsStart(ID3D12Device*);
// Obtain actual objects/bytes exclusively from the existing creation audit's
// ReadMatch, then SDK-decode the exact supported layout. No guessed target API.
BEAMRT_BINDING_API HRESULT WINAPI BeamRT_BindingsTargetFromAudit();
BEAMRT_BINDING_API HRESULT WINAPI BeamRT_BindingsStatus(BeamRTBindingStatus*,uint32_t);
// Copies the last accepted recording observation, NOT a fresh frame/resource
// lease or GPU-completion receipt. Outputs are cleared on unavailable/error.
BEAMRT_BINDING_API HRESULT WINAPI BeamRT_BindingsRead(BeamRTBindingSnapshot*,uint32_t);
// Bounded CPU rejection ledger. Not call-overlap, frame or GPU evidence.
// Available after OFF for diagnostics; no resource pointers/leases are added.
BEAMRT_BINDING_API HRESULT WINAPI BeamRT_BindingsThreadDiagnostics(BeamRTBindingThreadDiagnostics*,uint32_t);
BEAMRT_BINDING_API HRESULT WINAPI BeamRT_BindingsDisable();
}
