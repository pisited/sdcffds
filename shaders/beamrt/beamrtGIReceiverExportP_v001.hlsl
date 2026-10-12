// Native-host-only receiver export before GI, at identical GI viewport/resolution.
// Reuses the beauty path's depth/camera/geometric origin, without reinterpreting
// BeamNG depth in native compute. Host must duplicate the exact original draw
// inputs, then restore the original pass; no Lua registration or auto activation.
#define BEAMRT_GI_PIXEL_ENTRY beamrtUnusedBeautyMain
#include "beamrtGITraceP_v084.hlsl"
#undef BEAMRT_GI_PIXEL_ENTRY
#ifdef SHADER_STAGE_VS
// The included GI vertex entry is unchanged.
#else
#undef main
#ifdef BEAMRT_RECEIVER_ENGINE_ENTRY
float4 main(PFXVertToPix IN) : SV_Target0
#else
float4 beamrtReceiverMain(PFXVertToPix IN) : SV_Target0
#endif
{
    float4 decoded=decodeGBuffer(TEX_SAMPLER(prepassDepthTex),TEX_SAMPLER(prepassTex),IN.uv0,projParams);
    if(!(decoded.w>=0) || decoded.w>=0.9999) return 0.0;
    float uvDx=ddx(IN.uv0.x),uvDy=ddy(IN.uv0.y);
    if(abs(uvDx)<1e-10 || abs(uvDy)<1e-10) return 0.0;
    float3 position=eyePosWorld+IN.wsEyeRay*decoded.w;
    float3 geometricNormal;
    float3 origin=beamrtGIReceiverOrigin(IN,decoded,position,ddx(IN.wsEyeRay)/uvDx,ddy(IN.wsEyeRay)/uvDy,geometricNormal);
    return all(isfinite(origin)) ? float4(origin,1.0) : 0.0;
}
#endif
