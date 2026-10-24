#pragma once
#include "resource_tracker.h"
#include <climits>
#include <cmath>
#include <cstring>

template<class T>inline bool beamrtResourceZero(const T& value){const T zero{};return std::memcmp(&value,&zero,sizeof(value))==0;}
inline bool beamrtResourceViewValid(const BeamRTResourceView& v,uint32_t kind){
    const auto& d=v.resource;
    if(v.bytes!=sizeof(v) || v.abi!=1 || v.kind!=kind || v.defaultView>1 || !v.heapId || !v.resourceId || !v.canonicalIdentity || !v.revision
        || d.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D || !d.Width || !d.Height || d.DepthOrArraySize!=1 || !d.MipLevels || d.SampleDesc.Count!=1
        || (d.Format!=DXGI_FORMAT_R32G32B32A32_FLOAT && d.Format!=DXGI_FORMAT_R32_FLOAT && d.Format!=DXGI_FORMAT_R8G8B8A8_UNORM))return false;
    if(kind==1)return v.srv.Format==d.Format && v.srv.ViewDimension==D3D12_SRV_DIMENSION_TEXTURE2D
        && v.srv.Shader4ComponentMapping==D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING && !v.srv.Texture2D.PlaneSlice
        && v.srv.Texture2D.MostDetailedMip<d.MipLevels && v.srv.Texture2D.MipLevels && (v.srv.Texture2D.MipLevels==UINT_MAX
            || v.srv.Texture2D.MipLevels<=d.MipLevels-v.srv.Texture2D.MostDetailedMip)
        && std::isfinite(v.srv.Texture2D.ResourceMinLODClamp) && v.srv.Texture2D.ResourceMinLODClamp>=0 && beamrtResourceZero(v.rtv);
    return kind==2 && (d.Flags&D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET) && v.rtv.Format==d.Format
        && v.rtv.ViewDimension==D3D12_RTV_DIMENSION_TEXTURE2D && !v.rtv.Texture2D.PlaneSlice
        && v.rtv.Texture2D.MipSlice<d.MipLevels && beamrtResourceZero(v.srv);
}
