#pragma once
// Owned OFFLINE GPU resources only. No capture hooks, DLL loading or game data.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <d3dcompiler.h>
#include <d3d11shader.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;
inline void require(bool ok,const char* why) { if(!ok) throw std::runtime_error(why); }
inline void hr(HRESULT value,const char* operation="D3D12 fixture operation") {
    if(FAILED(value)) throw std::runtime_error(std::string(operation)+" failed HRESULT="+std::to_string(value));
}
inline void read(std::ifstream& stream,void* output,size_t bytes) { stream.read(static_cast<char*>(output),static_cast<std::streamsize>(bytes));require(bool(stream),"truncated fixture"); }
inline std::vector<uint8_t> file(const wchar_t* path) {
    std::ifstream stream(std::filesystem::path(path),std::ios::binary|std::ios::ate);require(bool(stream),"file missing");
    auto size=stream.tellg();require(size>0 && size<=16*1024*1024,"file size invalid");
    std::vector<uint8_t> data(static_cast<size_t>(size));stream.seekg(0);read(stream,data.data(),data.size());return data;
}
inline void transition(ID3D12GraphicsCommandList* list,ID3D12Resource* resource,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition={resource,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};list->ResourceBarrier(1,&b);
}
inline ComPtr<ID3D12Resource> make(ID3D12Device* device,D3D12_RESOURCE_DESC desc,D3D12_HEAP_TYPE type,D3D12_RESOURCE_STATES state) {
    D3D12_HEAP_PROPERTIES props{};props.Type=type;ComPtr<ID3D12Resource> result;
    hr(device->CreateCommittedResource(&props,D3D12_HEAP_FLAG_NONE,&desc,state,nullptr,IID_PPV_ARGS(&result)));return result;
}
inline D3D12_RESOURCE_DESC buffer(UINT64 bytes) {
    D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=bytes;d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;return d;
}
inline void fill(ID3D12Resource* resource,const void* data,size_t bytes) {
    void* mapped=nullptr;D3D12_RANGE noRead{0,0};hr(resource->Map(0,&noRead,&mapped));std::memcpy(mapped,data,bytes);resource->Unmap(0,nullptr);
}
struct Host {
    ComPtr<ID3D12Device> device;ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;ComPtr<ID3D12GraphicsCommandList> list;
    ComPtr<ID3D12Fence> fence;UINT64 sequence=0;
    std::vector<ComPtr<ID3D12Resource>> staging;
    explicit Host(ID3D12Device* native):device(native) {
        D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;hr(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)));
        hr(device->CreateCommandAllocator(q.Type,IID_PPV_ARGS(&allocator)));hr(device->CreateCommandList(0,q.Type,allocator.Get(),nullptr,IID_PPV_ARGS(&list)));
        hr(list->Close());hr(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));
    }
    void begin() { hr(allocator->Reset());hr(list->Reset(allocator.Get(),nullptr)); }
    void execute() { hr(list->Close());ID3D12CommandList* lists[]={list.Get()};queue->ExecuteCommandLists(1,lists); }
    void wait() {
        hr(queue->Signal(fence.Get(),++sequence));HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);require(event!=nullptr,"event creation failed");
        hr(fence->SetEventOnCompletion(sequence,event));const DWORD result=WaitForSingleObject(event,10000);CloseHandle(event);
        require(result==WAIT_OBJECT_0,"GPU test timeout; stop test process, not frame retirement proof");hr(device->GetDeviceRemovedReason());staging.clear();
    }
    ComPtr<ID3D12Resource> texture(UINT width,UINT height,DXGI_FORMAT format,const void* pixels,UINT pixelBytes) {
        D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=width;d.Height=height;d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Format=format;
        auto result=make(device.Get(),d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows;UINT64 rowBytes,total;
        device->GetCopyableFootprints(&d,0,1,0,&footprint,&rows,&rowBytes,&total);
        require(rowBytes==uint64_t(width)*pixelBytes,"fixture pixel format mismatch");
        auto upload=make(device.Get(),buffer(total),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
        void* mapped;D3D12_RANGE noRead{0,0};hr(upload->Map(0,&noRead,&mapped));
        for(UINT y=0;y<rows;++y) std::memcpy(static_cast<uint8_t*>(mapped)+footprint.Offset+uint64_t(y)*footprint.Footprint.RowPitch,static_cast<const uint8_t*>(pixels)+uint64_t(y)*rowBytes,static_cast<size_t>(rowBytes));
        upload->Unmap(0,nullptr);D3D12_TEXTURE_COPY_LOCATION dst{},src{};dst.pResource=result.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        src.pResource=upload.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;src.PlacedFootprint=footprint;
        list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);transition(list.Get(),result.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        staging.push_back(upload);return result;
    }
};
