// Public SDK data slots only; never guessed engine offsets.
#define CINTERFACE
#define WIN32_LEAN_AND_MEAN
#pragma warning(push)
#pragma warning(disable:4201)
#include <windows.h>
#include <d3d12.h>
#pragma warning(pop)
#include <stddef.h>
void** beamrtResourceSDKSlot(void* object,unsigned method){
    void** table=*(void***)object;
#define SLOT(name) return table+offsetof(ID3D12DeviceVtbl,name)/sizeof(void*)
    switch(method){
    case 0:SLOT(CreateDescriptorHeap);
    case 1:SLOT(CreateShaderResourceView);
    case 2:SLOT(CreateRenderTargetView);
    case 3:SLOT(CreateConstantBufferView);
    case 4:SLOT(CreateUnorderedAccessView);
    case 5:SLOT(CopyDescriptorsSimple);
    case 6:SLOT(CopyDescriptors);
    case 7:SLOT(CreateCommittedResource);
    case 8:SLOT(CreatePlacedResource);
    case 9:SLOT(CreateReservedResource);
    default:return NULL;
    }
#undef SLOT
}
