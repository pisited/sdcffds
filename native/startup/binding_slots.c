#define CINTERFACE
#define WIN32_LEAN_AND_MEAN
#pragma warning(push)
#pragma warning(disable:4201)
#include <windows.h>
#include <d3d12.h>
#pragma warning(pop)
#include <stddef.h>
void** beamrtBindingSDKSlot(void* object,unsigned method){
    void** table=*(void***)object;
#define SLOT(type,name) return table+offsetof(type,name)/sizeof(void*)
    switch(method){
    case 0:SLOT(ID3D12DeviceVtbl,CreateCommandList);
    case 1:SLOT(ID3D12Device4Vtbl,CreateCommandList1);
    case 2:SLOT(ID3D12GraphicsCommandListVtbl,Close);
    case 3:SLOT(ID3D12GraphicsCommandListVtbl,Reset);
    case 4:SLOT(ID3D12GraphicsCommandListVtbl,ClearState);
    case 5:SLOT(ID3D12GraphicsCommandListVtbl,SetPipelineState);
    case 6:SLOT(ID3D12GraphicsCommandListVtbl,SetGraphicsRootSignature);
    case 7:SLOT(ID3D12GraphicsCommandListVtbl,SetDescriptorHeaps);
    case 8:SLOT(ID3D12GraphicsCommandListVtbl,SetGraphicsRootConstantBufferView);
    case 9:SLOT(ID3D12GraphicsCommandListVtbl,SetGraphicsRootDescriptorTable);
    case 10:SLOT(ID3D12GraphicsCommandListVtbl,RSSetViewports);
    case 11:SLOT(ID3D12GraphicsCommandListVtbl,RSSetScissorRects);
    case 12:SLOT(ID3D12GraphicsCommandListVtbl,OMSetRenderTargets);
    case 13:SLOT(ID3D12GraphicsCommandListVtbl,DrawInstanced);
    case 14:SLOT(ID3D12GraphicsCommandListVtbl,DrawIndexedInstanced);
    case 15:SLOT(ID3D12GraphicsCommandListVtbl,ExecuteBundle);
    case 16:SLOT(ID3D12GraphicsCommandListVtbl,ExecuteIndirect);
    case 17:SLOT(ID3D12GraphicsCommandList4Vtbl,BeginRenderPass);
    case 18:SLOT(ID3D12GraphicsCommandList4Vtbl,EndRenderPass);
    case 19:SLOT(ID3D12GraphicsCommandListVtbl,SetGraphicsRoot32BitConstant);
    case 20:SLOT(ID3D12GraphicsCommandListVtbl,SetGraphicsRoot32BitConstants);
    case 21:SLOT(ID3D12GraphicsCommandListVtbl,SetGraphicsRootShaderResourceView);
    case 22:SLOT(ID3D12GraphicsCommandListVtbl,SetGraphicsRootUnorderedAccessView);
    case 23:SLOT(ID3D12GraphicsCommandList4Vtbl,SetPipelineState1);
    default:return NULL;
    }
#undef SLOT
}
