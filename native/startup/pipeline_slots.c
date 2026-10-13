#define CINTERFACE
#define WIN32_LEAN_AND_MEAN
#pragma warning(push)
#pragma warning(disable:4201)
#include <windows.h>
#include <d3d12.h>
#pragma warning(pop)
#include <stddef.h>
// Addresses of PUBLIC SDK slots, not copied/truncated interface tables or
// guessed engine offsets. Device2 may share a longer table; all other entries
// remain untouched, including newer interfaces beyond this SDK prefix.
void** beamrtPipelineSDKSlot(void* device,void* device2,unsigned method){
    void** table=*(void***)device;
    if(method==0)return table+offsetof(ID3D12DeviceVtbl,CreateRootSignature)/sizeof(void*);
    if(method==1)return table+offsetof(ID3D12DeviceVtbl,CreateGraphicsPipelineState)/sizeof(void*);
    if(method==2 && device2)return (*(void***)device2)+offsetof(ID3D12Device2Vtbl,CreatePipelineState)/sizeof(void*);
    return NULL;
}
