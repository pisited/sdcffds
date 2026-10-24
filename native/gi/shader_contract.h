#pragma once
// Bounded OFFLINE shader/layout and upload-buffer contract. No engine camera
// interpretation, GPU readback, address dereference or game resource discovery.
#include "contract_common.h"
#include <d3dcompiler.h>
#include <d3d11shader.h>
#include <map>
#include <vector>
#include <cstring>
#include <string>

namespace beamrt_fixture {
enum class PassRole { Producer,Consumer };
struct ReflectedField { uint32_t offset=0,bytes=0; };
class ShaderContract {
    PassRole role_;
    std::vector<uint8_t> shader_,root_;
    uint32_t cbv_=0,table_=0,constantBytes_=0;
    std::map<std::string,ReflectedField> fields_;
public:
    ShaderContract(const std::vector<uint8_t>& shader,const void* root,size_t rootBytes,PassRole role):role_(role),shader_(shader) {
        demand((role==PassRole::Producer || role==PassRole::Consumer) && !shader.empty()
            && shader.size()<=16*1024*1024 && root && rootBytes>0 && rootBytes<=256*1024,"missing/unsupported shader manifest");
        root_.assign(static_cast<const uint8_t*>(root),static_cast<const uint8_t*>(root)+rootBytes);
        ComPtr<ID3D11ShaderReflection> reflection;
        demand(SUCCEEDED(D3DReflect(shader_.data(),shader_.size(),IID_PPV_ARGS(&reflection))),"shader reflection unavailable");
        D3D11_SHADER_DESC sd{};demand(SUCCEEDED(reflection->GetDesc(&sd)),"shader reflection description unavailable");
        demand(D3D11_SHVER_GET_TYPE(sd.Version)==D3D11_SHVER_PIXEL_SHADER
            && D3D11_SHVER_GET_MAJOR(sd.Version)==5 && D3D11_SHVER_GET_MINOR(sd.Version)==0,
            "only the owned SM5.0 pixel fixtures are supported");
        const bool producer=role==PassRole::Producer;
        cbv_=producer?1u:0u;table_=producer?0u:1u;
        const char* cbName=producer?"HandoffFixture":"Test";
        demand(sd.BoundResources==(producer?3u:2u) && sd.ConstantBuffers==1,"unexpected shader resource layout");
        auto binding=[&](const char* name,D3D_SHADER_INPUT_TYPE type,UINT reg){
            D3D11_SHADER_INPUT_BIND_DESC d{};
            demand(SUCCEEDED(reflection->GetResourceBindingDescByName(name,&d)) && d.Type==type
                && d.BindPoint==reg && d.BindCount==1,"shader binding name/register/type mismatch");
            if(type==D3D_SIT_TEXTURE)demand(d.Dimension==D3D_SRV_DIMENSION_TEXTURE2D && d.ReturnType==D3D_RETURN_TYPE_FLOAT,
                                          "unsupported reflected texture type");
        };
        binding(cbName,D3D_SIT_CBUFFER,0);
        if(producer){binding("receiverOriginTex",D3D_SIT_TEXTURE,0);binding("meshDataTex",D3D_SIT_TEXTURE,1);}
        else binding("nativeGIVisibilityTexTex",D3D_SIT_TEXTURE,5);
        auto cb=reflection->GetConstantBufferByName(cbName);D3D11_SHADER_BUFFER_DESC bd{};
        demand(SUCCEEDED(cb->GetDesc(&bd)) && bd.Type==D3D_CT_CBUFFER && bd.Size>0
            && bd.Size<=65536 && bd.Variables==(producer?1u:5u),"unsupported reflected constant buffer");
        constantBytes_=bd.Size;
        auto member=[&](const char* name,D3D_SHADER_VARIABLE_TYPE type,UINT columns,UINT bytes){
            auto v=cb->GetVariableByName(name);D3D11_SHADER_VARIABLE_DESC vd{};D3D11_SHADER_TYPE_DESC td{};
            demand(SUCCEEDED(v->GetDesc(&vd)) && SUCCEEDED(v->GetType()->GetDesc(&td))
                && vd.Size==bytes && vd.StartOffset<=bd.Size && bytes<=bd.Size-vd.StartOffset
                && td.Type==type && td.Rows==1 && td.Columns==columns && td.Elements==0 && td.Members==0
                && td.Class==(columns==1?D3D_SVC_SCALAR:D3D_SVC_VECTOR),"constant field name/type/extent mismatch");
            fields_.emplace(name,ReflectedField{vd.StartOffset,vd.Size});
        };
        if(producer)member("fixtureControl",D3D_SVT_FLOAT,4,16);
        else {
            member("nativeGIVisibilityKey",D3D_SVT_FLOAT,4,16);
            member("nativeGIVisibilitySize",D3D_SVT_FLOAT,2,8);
            member("nativeGIVisibilityEnabled",D3D_SVT_FLOAT,1,4);
            member("surfelIndex",D3D_SVT_INT,1,4);
            member("rtParams0",D3D_SVT_FLOAT,4,16);
        }
        ComPtr<ID3D12RootSignatureDeserializer> decoded;
        demand(SUCCEEDED(D3D12CreateRootSignatureDeserializer(root_.data(),root_.size(),IID_PPV_ARGS(&decoded))),
               "serialized root layout unavailable");
        const auto d=decoded->GetRootSignatureDesc();
        demand(d->NumParameters==2 && d->NumStaticSamplers==0 && d->Flags==D3D12_ROOT_SIGNATURE_FLAG_NONE,
               "unsupported root signature shape");
        const auto& c=d->pParameters[cbv_];const auto& t=d->pParameters[table_];
        demand(c.ParameterType==D3D12_ROOT_PARAMETER_TYPE_CBV && c.Descriptor.ShaderRegister==0
            && c.Descriptor.RegisterSpace==0 && c.ShaderVisibility==D3D12_SHADER_VISIBILITY_ALL,
            "root CBV does not match reflected b0");
        demand(t.ParameterType==D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE && t.DescriptorTable.NumDescriptorRanges==1
            && t.ShaderVisibility==D3D12_SHADER_VISIBILITY_ALL,"unexpected root SRV table");
        const auto& range=t.DescriptorTable.pDescriptorRanges[0];
        demand(range.RangeType==D3D12_DESCRIPTOR_RANGE_TYPE_SRV && range.RegisterSpace==0
            && range.BaseShaderRegister==(producer?0u:5u) && range.NumDescriptors==(producer?2u:1u)
            && range.OffsetInDescriptorsFromTableStart==0,"root table does not match shader SRVs");
    }
    PassRole role() const {return role_;}
    uint32_t cbvParameter() const {return cbv_;}
    uint32_t tableParameter() const {return table_;}
    uint32_t constantBytes() const {return constantBytes_;}
    uint64_t cbvSpan() const {return (uint64_t(constantBytes_)+255)&~uint64_t(255);}
    const std::vector<uint8_t>& shader() const {return shader_;}
    const std::vector<uint8_t>& root() const {return root_;}
    ReflectedField field(const std::string& name) const {
        auto found=fields_.find(name);demand(found!=fields_.end(),"unrecognized constant field");return found->second;
    }
    std::vector<uint8_t> constants() const {return std::vector<uint8_t>(constantBytes_);}
    void put(std::vector<uint8_t>& bytes,const std::string& name,const void* value,size_t count) const {
        const auto f=field(name);demand(value && count==f.bytes && f.offset<=bytes.size()
            && count<=bytes.size()-f.offset,"constant upload extent mismatch");
        std::memcpy(bytes.data()+f.offset,value,count);
    }
};
struct KnownConstantBuffer {
    ComPtr<ID3D12Resource> resource;
    std::vector<uint8_t> uploadMirror; // exact bytes supplied by fixture fill()
    float key[4]{};
    uint32_t contentsCurrent=0,unchangedThroughConsumer=0;
};
struct ResolvedConstants {
    ComPtr<ID3D12Resource> resource;
    uint64_t offset=0,span=0;
    std::vector<uint8_t> contents;
};
inline bool resolveConstants(ID3D12Device* device,const BeamRTCaptureInfo& info,const ShaderContract& layout,
    const std::vector<KnownConstantBuffer>& registry,const float* expectedKey,ResolvedConstants& out,std::string& reason) {
    out={};reason.clear();
    try {
        demand(expectedKey && info.rootValueCount==0 && info.rootUavCount==0 && info.rootCbvCount==1,
               "unresolved root constant/CBV/UAV semantics");
        const auto& c=info.rootCbvs[0];
        demand(c.parameter==layout.cbvParameter() && c.reserved==0 && c.address>0
            && c.address%D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT==0,"missing/misaligned root CBV address");
        demand(!registry.empty() && registry.size()<=16,"missing/overflowed owned buffer registry");
        ResolvedConstants candidate;UINT matches=0;
        for(const auto& entry:registry){
            owned(device,entry.resource.Get());const auto d=entry.resource->GetDesc();
            demand(d.Dimension==D3D12_RESOURCE_DIMENSION_BUFFER && d.Layout==D3D12_TEXTURE_LAYOUT_ROW_MAJOR
                && d.Height==1 && d.DepthOrArraySize==1 && d.MipLevels==1 && d.SampleDesc.Count==1
                && d.SampleDesc.Quality==0 && d.Flags==D3D12_RESOURCE_FLAG_NONE,"unsupported constant buffer resource");
            const UINT64 base=entry.resource->GetGPUVirtualAddress();
            if(!base || c.address<base || c.address-base>=d.Width)continue;
            const UINT64 offset=c.address-base;
            demand(layout.cbvSpan()<=d.Width-offset,"CBV range exceeds actual buffer allocation");
            D3D12_HEAP_PROPERTIES heap{};D3D12_HEAP_FLAGS flags{};
            demand(SUCCEEDED(entry.resource->GetHeapProperties(&heap,&flags)) && heap.Type==D3D12_HEAP_TYPE_UPLOAD,
                   "constant contents unavailable for this heap");
            demand(entry.contentsCurrent==1 && entry.unchangedThroughConsumer==1,"unproven constant upload lifetime");
            for(int i=0;i<4;++i)demand(entry.key[i]==expectedKey[i],"stale constant upload generation");
            demand(offset<=entry.uploadMirror.size() && layout.constantBytes()<=entry.uploadMirror.size()-offset,
                   "missing constant upload contents");
            ++matches;candidate.resource=entry.resource;candidate.offset=offset;candidate.span=layout.cbvSpan();
            candidate.contents.assign(entry.uploadMirror.begin()+static_cast<size_t>(offset),
                                      entry.uploadMirror.begin()+static_cast<size_t>(offset)+layout.constantBytes());
        }
        demand(matches==1,"CBV ownership missing or ambiguous");out=std::move(candidate);return true;
    } catch(const std::exception& error){reason=error.what();return false;}
}
} // namespace beamrt_fixture
