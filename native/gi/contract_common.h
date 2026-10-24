#pragma once
#include "../capture/beamrt_capture.h"
#include <windows.h>
#include <wrl/client.h>
#include <stdexcept>
namespace beamrt_fixture {
using Microsoft::WRL::ComPtr;
inline void demand(bool ok,const char* reason){if(!ok)throw std::runtime_error(reason);}
inline bool sameObject(IUnknown* a,IUnknown* b) {
    if(!a || !b)return false;ComPtr<IUnknown> x,y;
    if(FAILED(a->QueryInterface(IID_PPV_ARGS(&x))) || FAILED(b->QueryInterface(IID_PPV_ARGS(&y))))return false;
    return x.Get()==y.Get();
}
inline void owned(ID3D12Device* device,ID3D12DeviceChild* object) {
    demand(device && object,"missing native resource/queue/fence");ComPtr<ID3D12Device> actual;
    demand(SUCCEEDED(object->GetDevice(IID_PPV_ARGS(&actual))) && sameObject(device,actual.Get()),
           "foreign-device resource/queue/fence");
}
}
