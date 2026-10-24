#pragma once
#include <d3d12.h>
#include <wrl/client.h>
#include <cstdint>
struct BeamRTGIRootLayout {uint32_t cbv=UINT32_MAX,srv=UINT32_MAX,sampler=UINT32_MAX;};
using BeamRTRootDecoder=HRESULT(WINAPI*)(LPCVOID,SIZE_T,REFIID,void**);
// Scope: the actual three-parameter v1.0 root captured in the successful live
// creation audit. No register guessing, root-constant substitution or layout
// expansion. This decoder creates CPU metadata only, never a D3D12 device.
inline HRESULT beamrtDecodeGIRoot(const void* bytes,size_t count,BeamRTGIRootLayout& out,BeamRTRootDecoder function=nullptr){
    out={};if(!bytes || !count || count>65536)return E_INVALIDARG;
    Microsoft::WRL::ComPtr<ID3D12VersionedRootSignatureDeserializer> decoder;
#ifdef BEAMRT_BINDING_EMBEDDED
    if(!function)return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
#else
    if(!function)function=D3D12CreateVersionedRootSignatureDeserializer;
#endif
    auto result=function(bytes,count,IID_PPV_ARGS(&decoder));
    if(FAILED(result))return result;const auto versioned=decoder->GetUnconvertedRootSignatureDesc();
    if(!versioned || versioned->Version!=D3D_ROOT_SIGNATURE_VERSION_1_0)return E_NOTIMPL;
    const auto& root=versioned->Desc_1_0;
    if(root.NumParameters!=3 || root.NumStaticSamplers || root.Flags!=D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT)return E_NOTIMPL;
    BeamRTGIRootLayout layout;
    for(UINT i=0;i<3;++i){const auto& p=root.pParameters[i];
        if(p.ShaderVisibility!=D3D12_SHADER_VISIBILITY_ALL)return E_NOTIMPL;
        if(p.ParameterType==D3D12_ROOT_PARAMETER_TYPE_CBV){
            if(layout.cbv!=UINT32_MAX || p.Descriptor.ShaderRegister || p.Descriptor.RegisterSpace)return E_NOTIMPL;layout.cbv=i;
        }else if(p.ParameterType==D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE){
            if(p.DescriptorTable.NumDescriptorRanges!=1)return E_NOTIMPL;const auto& r=p.DescriptorTable.pDescriptorRanges[0];
            if(r.NumDescriptors!=6 || r.BaseShaderRegister || r.RegisterSpace || r.OffsetInDescriptorsFromTableStart)return E_NOTIMPL;
            if(r.RangeType==D3D12_DESCRIPTOR_RANGE_TYPE_SRV && layout.srv==UINT32_MAX)layout.srv=i;
            else if(r.RangeType==D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER && layout.sampler==UINT32_MAX)layout.sampler=i;
            else return E_NOTIMPL;
        }else return E_NOTIMPL;
    }
    if(layout.cbv==UINT32_MAX || layout.srv==UINT32_MAX || layout.sampler==UINT32_MAX)return E_NOTIMPL;
    out=layout;return S_OK;
}
