#pragma once
#include <d3d12.h>
#include <wrl/client.h>
#include <filesystem>
#include <fstream>
#include <vector>
#include <stdexcept>
#include <string>
#include <cstring>
using Microsoft::WRL::ComPtr;
static void need(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
static void hr(HRESULT h){if(FAILED(h))throw std::runtime_error("binding fixture HRESULT="+std::to_string(h));}
static std::vector<uint8_t> file(const wchar_t* name){std::ifstream s(std::filesystem::path(name),std::ios::binary|std::ios::ate);
    need(bool(s) && s.tellg()>0 && s.tellg()<=16*1024*1024,"fixture input missing/oversized");std::vector<uint8_t> b(static_cast<size_t>(s.tellg()));
    s.seekg(0);s.read(reinterpret_cast<char*>(b.data()),b.size());need(bool(s),"fixture input truncated");return b;}
static D3D12_RESOURCE_DESC buffer(UINT64 n){D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=n;d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;return d;}
static ComPtr<ID3D12Resource> resource(ID3D12Device* device,D3D12_RESOURCE_DESC d,D3D12_HEAP_TYPE type,D3D12_RESOURCE_STATES state){D3D12_HEAP_PROPERTIES h{};h.Type=type;
    ComPtr<ID3D12Resource> r;hr(device->CreateCommittedResource(&h,D3D12_HEAP_FLAG_NONE,&d,state,nullptr,IID_PPV_ARGS(&r)));return r;}
static void transition(ID3D12GraphicsCommandList* l,ID3D12Resource* r,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after){D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition={r,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};l->ResourceBarrier(1,&b);}
struct Renderer {
    ComPtr<ID3D12Device> device;ComPtr<ID3D12CommandQueue> queue;ComPtr<ID3D12CommandAllocator> allocator;ComPtr<ID3D12GraphicsCommandList> list;ComPtr<ID3D12Fence> fence;
    uint64_t sequence=0;std::vector<ComPtr<ID3D12Resource>> uploads;
    Renderer(ID3D12Device* d):device(d){D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;
        hr(d->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)));hr(d->CreateCommandAllocator(q.Type,IID_PPV_ARGS(&allocator)));
        hr(d->CreateCommandList(0,q.Type,allocator.Get(),nullptr,IID_PPV_ARGS(&list)));hr(list->Close());hr(d->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));}
    void begin(){hr(allocator->Reset());hr(list->Reset(allocator.Get(),nullptr));}
    void submit(){hr(list->Close());ID3D12CommandList* lists[]={list.Get()};queue->ExecuteCommandLists(1,lists);hr(queue->Signal(fence.Get(),++sequence));
        HANDLE done=CreateEventW(nullptr,FALSE,FALSE,nullptr);need(done!=nullptr,"fixture fence event");const auto set=fence->SetEventOnCompletion(sequence,done);
        const auto wait=SUCCEEDED(set)?WaitForSingleObject(done,10000):WAIT_FAILED;CloseHandle(done);hr(set);need(wait==WAIT_OBJECT_0,"fixture GPU timeout");hr(device->GetDeviceRemovedReason());uploads.clear();}
    ComPtr<ID3D12Resource> texture(float value){D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=d.Height=1;d.DepthOrArraySize=1;d.MipLevels=1;d.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;d.SampleDesc.Count=1;
        auto r=resource(device.Get(),d,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);D3D12_PLACED_SUBRESOURCE_FOOTPRINT f{};UINT rows;UINT64 row,total;device->GetCopyableFootprints(&d,0,1,0,&f,&rows,&row,&total);
        auto u=resource(device.Get(),buffer(total),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);void* p;D3D12_RANGE none{0,0};hr(u->Map(0,&none,&p));const float color[]={value,value,value,value};std::memcpy(static_cast<uint8_t*>(p)+f.Offset,color,sizeof(color));u->Unmap(0,nullptr);
        D3D12_TEXTURE_COPY_LOCATION dst{},src{};dst.pResource=r.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;src.pResource=u.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;src.PlacedFootprint=f;list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);transition(list.Get(),r.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);uploads.push_back(u);return r;}
};
