#pragma once
// Generic OFFLINE pixel-pass fixture, shared by sunlight and history tests.
#include "gpu_fixture_host.h"
#include <array>
#include <utility>
using Pixel=std::array<float,4>;
struct FixtureShader {
    std::vector<uint8_t> bytes,constants;
    ComPtr<ID3D11ShaderReflection> reflection;
    ID3D11ShaderReflectionConstantBuffer* fields=nullptr;
    explicit FixtureShader(const std::filesystem::path& path):bytes(file(path.c_str())){
        hr(D3DReflect(bytes.data(),bytes.size(),IID_PPV_ARGS(&reflection)),"fixture shader reflection");
        fields=reflection->GetConstantBufferByName("perDraw");D3D11_SHADER_BUFFER_DESC desc{};
        hr(fields->GetDesc(&desc),"fixture perDraw");constants.resize((desc.Size+255)&~size_t(255));
    }
    void put(const char* name,const void* data,size_t size){
        D3D11_SHADER_VARIABLE_DESC desc{};hr(fields->GetVariableByName(name)->GetDesc(&desc),name);
        require(size==desc.Size && uint64_t(desc.StartOffset)+size<=constants.size(),"fixture constant extent mismatch");
        std::memcpy(constants.data()+desc.StartOffset,data,size);
    }
    void scalar(const char* name,float value){put(name,&value,sizeof(value));}
    template<size_t N> void vector(const char* name,const std::array<float,N>& value){put(name,value.data(),N*sizeof(float));}
};
inline ComPtr<ID3D12Resource> drawFixture(Host& host,const std::vector<uint8_t>& vs,const FixtureShader& ps,UINT width,UINT height,
    const std::vector<std::pair<UINT,ID3D12Resource*>>& inputs,DXGI_FORMAT format=DXGI_FORMAT_R32G32B32A32_FLOAT){
    require(format==DXGI_FORMAT_R32G32B32A32_FLOAT || format==DXGI_FORMAT_R16G16B16A16_FLOAT,"unsupported fixture output format");
    auto device=host.device.Get();D3D12_DESCRIPTOR_RANGE range{};range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV;range.NumDescriptors=15;
    D3D12_ROOT_PARAMETER params[2]{};params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;
    params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[1].DescriptorTable={1,&range};
    D3D12_STATIC_SAMPLER_DESC samplers[15]{};
    for(UINT i=0;i<15;++i){auto& s=samplers[i];s.ShaderRegister=i;s.Filter=D3D12_FILTER_MIN_MAG_MIP_POINT;
        s.AddressU=s.AddressV=s.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;s.MaxLOD=D3D12_FLOAT32_MAX;
        s.ComparisonFunc=D3D12_COMPARISON_FUNC_ALWAYS;s.ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;}
    D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=2;desc.pParameters=params;desc.NumStaticSamplers=15;desc.pStaticSamplers=samplers;
    ComPtr<ID3DBlob> encoded,errors;hr(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&encoded,&errors));
    ComPtr<ID3D12RootSignature> root;hr(device->CreateRootSignature(0,encoded->GetBufferPointer(),encoded->GetBufferSize(),IID_PPV_ARGS(&root)));
    D3D12_GRAPHICS_PIPELINE_STATE_DESC p{};p.pRootSignature=root.Get();p.VS={vs.data(),vs.size()};p.PS={ps.bytes.data(),ps.bytes.size()};
    p.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;p.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;p.RasterizerState.DepthClipEnable=TRUE;
    p.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;p.SampleMask=UINT_MAX;
    p.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;p.NumRenderTargets=1;p.RTVFormats[0]=format;p.SampleDesc.Count=1;
    ComPtr<ID3D12PipelineState> pipeline;hr(device->CreateGraphicsPipelineState(&p,IID_PPV_ARGS(&pipeline)),"fixture shader pipeline");
    D3D12_RESOURCE_DESC targetDesc{};targetDesc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;targetDesc.Width=width;targetDesc.Height=height;
    targetDesc.DepthOrArraySize=targetDesc.MipLevels=1;targetDesc.SampleDesc.Count=1;targetDesc.Format=format;targetDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    auto target=make(device,targetDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
    auto cb=make(device,buffer(ps.constants.size()),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);fill(cb.Get(),ps.constants.data(),ps.constants.size());
    D3D12_DESCRIPTOR_HEAP_DESC heap{};heap.NumDescriptors=1;heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    ComPtr<ID3D12DescriptorHeap> rtv;hr(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&rtv)));device->CreateRenderTargetView(target.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
    heap.NumDescriptors=15;heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    ComPtr<ID3D12DescriptorHeap> srvs;hr(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&srvs)));
    const auto stride=device->GetDescriptorHandleIncrementSize(heap.Type);
    D3D12_SHADER_RESOURCE_VIEW_DESC srv{};srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;srv.Texture2D.MipLevels=1;
    srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;srv.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
    for(UINT i=0;i<15;++i){auto cpu=srvs->GetCPUDescriptorHandleForHeapStart();cpu.ptr+=i*stride;device->CreateShaderResourceView(nullptr,&srv,cpu);}
    for(const auto& entry:inputs){require(entry.first<15,"fixture SRV slot overflow");auto cpu=srvs->GetCPUDescriptorHandleForHeapStart();cpu.ptr+=entry.first*stride;
        srv.Format=entry.second->GetDesc().Format;device->CreateShaderResourceView(entry.second,&srv,cpu);}
    host.begin();host.list->SetPipelineState(pipeline.Get());host.list->SetGraphicsRootSignature(root.Get());ID3D12DescriptorHeap* heaps[]={srvs.Get()};host.list->SetDescriptorHeaps(1,heaps);
    host.list->SetGraphicsRootConstantBufferView(0,cb->GetGPUVirtualAddress());host.list->SetGraphicsRootDescriptorTable(1,srvs->GetGPUDescriptorHandleForHeapStart());
    const D3D12_VIEWPORT viewport{0,0,float(width),float(height),0,1};const D3D12_RECT scissor{0,0,LONG(width),LONG(height)};
    host.list->RSSetViewports(1,&viewport);host.list->RSSetScissorRects(1,&scissor);auto cpu=rtv->GetCPUDescriptorHandleForHeapStart();
    host.list->OMSetRenderTargets(1,&cpu,FALSE,nullptr);host.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);host.list->DrawInstanced(3,1,0,0);
    transition(host.list.Get(),target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);host.execute();host.wait();return target;
}
inline float fixtureHalf(uint16_t bits){
    const unsigned exponent=(bits>>10)&31u,fraction=bits&1023u;const float sign=(bits&32768u)?-1.f:1.f;
    if(exponent==31u)return fraction?std::numeric_limits<float>::quiet_NaN():sign*std::numeric_limits<float>::infinity();
    return sign*std::ldexp(float(fraction)+(exponent?1024.f:0.f),exponent?int(exponent)-25:-24);
}
inline std::vector<Pixel> readPixels(Host& host,ID3D12Resource* target){
    auto desc=target->GetDesc();const bool half=desc.Format==DXGI_FORMAT_R16G16B16A16_FLOAT;
    require(half || desc.Format==DXGI_FORMAT_R32G32B32A32_FLOAT,"unsupported fixture readback format");
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows;UINT64 rowBytes,total;
    host.device->GetCopyableFootprints(&desc,0,1,0,&footprint,&rows,&rowBytes,&total);
    auto result=make(host.device.Get(),buffer(total),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    host.begin();transition(host.list.Get(),target,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=target;src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    dst.pResource=result.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;host.list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
    transition(host.list.Get(),target,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);host.execute();host.wait();
    std::vector<Pixel> values(size_t(desc.Width)*desc.Height);void* mapped=nullptr;D3D12_RANGE span{0,static_cast<SIZE_T>(total)};hr(result->Map(0,&span,&mapped));
    for(UINT y=0;y<desc.Height;++y){const auto row=static_cast<const uint8_t*>(mapped)+footprint.Offset+size_t(y)*footprint.Footprint.RowPitch;
        if(!half)std::memcpy(values.data()+size_t(y)*desc.Width,row,static_cast<size_t>(rowBytes));
        else for(size_t x=0;x<desc.Width;++x)for(unsigned c=0;c<4;++c){uint16_t bits;std::memcpy(&bits,row+(x*4+c)*2,2);values[size_t(y)*desc.Width+x][c]=fixtureHalf(bits);}}
    D3D12_RANGE none{0,0};result->Unmap(0,&none);return values;
}
