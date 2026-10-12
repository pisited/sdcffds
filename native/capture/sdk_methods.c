// Method slots derive ONLY from the public Windows SDK COM ABI, not guessed
// engine offsets or scans. Never call with an arbitrary address.
#define CINTERFACE
#define WIN32_LEAN_AND_MEAN
#pragma warning(push)
#pragma warning(disable:4201) // Public SDK anonymous unions in C; not our code.
#include <windows.h>
#include <d3d12.h>
#pragma warning(pop)
#include <stddef.h>
#include "sdk_methods.h"
#define DEVICE_SLOT(name) (*(void***)device)[offsetof(ID3D12DeviceVtbl,name)/sizeof(void*)]
#define LIST_SLOT(name) (*(void***)list)[offsetof(ID3D12GraphicsCommandListVtbl,name)/sizeof(void*)]
void* beamrtSDKMethod(void* device,void* list,void* queue,unsigned method) {
    switch(method) {
    case CreateHeap:return DEVICE_SLOT(CreateDescriptorHeap);
    case CreateSRV:return DEVICE_SLOT(CreateShaderResourceView);
    case CreateCBV:return DEVICE_SLOT(CreateConstantBufferView);
    case CreateUAV:return DEVICE_SLOT(CreateUnorderedAccessView);
    case CopySimple:return DEVICE_SLOT(CopyDescriptorsSimple);
    case CopyRanges:return DEVICE_SLOT(CopyDescriptors);
    case CreateRoot:return DEVICE_SLOT(CreateRootSignature);
    case CreateGraphics:return DEVICE_SLOT(CreateGraphicsPipelineState);
    case CreateCompute:return DEVICE_SLOT(CreateComputePipelineState);
    case CreateList:return DEVICE_SLOT(CreateCommandList);
    case ResetList:return LIST_SLOT(Reset);
    case ClearList:return LIST_SLOT(ClearState);
    case SetHeaps:return LIST_SLOT(SetDescriptorHeaps);
    case SetPipeline:return LIST_SLOT(SetPipelineState);
    case SetGraphicsRoot:return LIST_SLOT(SetGraphicsRootSignature);
    case SetComputeRoot:return LIST_SLOT(SetComputeRootSignature);
    case SetGraphicsTable:return LIST_SLOT(SetGraphicsRootDescriptorTable);
    case SetComputeTable:return LIST_SLOT(SetComputeRootDescriptorTable);
    case Draw:return LIST_SLOT(DrawInstanced);
    case DrawIndexed:return LIST_SLOT(DrawIndexedInstanced);
    case Dispatch:return LIST_SLOT(Dispatch);
    case Bundle:return LIST_SLOT(ExecuteBundle);
    case Indirect:return LIST_SLOT(ExecuteIndirect);
    case ExecuteLists:return (*(void***)queue)[offsetof(ID3D12CommandQueueVtbl,ExecuteCommandLists)/sizeof(void*)];
    default:return NULL;
    }
}
