#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(sceneTex,0);
uniform_sampler2D(nativeSnapshotTex,1);
cbuffer perDraw:register(b0){float nativeShadowEpoch;float2 sceneColorJitterUV;POSTFX_UNIFORMS};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
// Failures are NOT shadow visibility. Numbered white bars identify the guard,
// with the scene faintly retained so a broken transport does not hide location.
float4 nativeRelayFailure(float4 beauty,float2 uv,uint stage)
{
    float3 color=stage<=3?float3(.08,.15,.9):
        stage==4?float3(1,.35,.02):stage==5?float3(0,.7,.8):float3(.6,0,.6);
    float3 outColor=lerp(beauty.rgb,color,.85);
    uint bar=(uint)floor(saturate(uv.x)*20);
    if(uv.y>.04&&uv.y<.10&&bar<stage&&frac(uv.x*20)<.65)outColor=1;
    return float4(outColor,beauty.a);
}
float4 mainP(PFXVertToPix IN):SV_Target0
{
    float4 beauty=tex2D(sceneTex,IN.uv0);
    if(nativeShadowEpoch<32)return beauty; // neutral during cleanup failure
    uint w,h;nativeSnapshotTexTex.GetDimensions(w,h);
    if(w<=1||h<=1)return nativeRelayFailure(beauty,IN.uv0,8);
    // Snapshot is render-resolution; display can be upscaled. Point sampling
    // keeps the packet intact; engine rtParams handles its viewport mapping.
    float4 payload=tex2D(nativeSnapshotTex,IN.uv1-sceneColorJitterUV*rtParams1.zw);
    if(!all(isfinite(payload))||payload.w!=.625)return nativeRelayFailure(beauty,IN.uv0,9);
    if(payload.y!=nativeShadowEpoch)return nativeRelayFailure(beauty,IN.uv0,10);
    if(payload.z>=1&&payload.z<=7&&payload.z==floor(payload.z))
        return nativeRelayFailure(beauty,IN.uv0,(uint)payload.z);
    if(payload.z==13)return nativeRelayFailure(beauty,IN.uv0,13);
    if(payload.z==0)return float4(.07,.07,.07,beauty.a);
    if(payload.z!=12)return nativeRelayFailure(beauty,IN.uv0,11);
    float packed=payload.x;
    uint bits=f32tof16(packed),epoch=bits>>5,code=bits&31;
    // No matching current-frame native draw = unknown, NOT a lit receiver.
    if(epoch!=(uint)nativeShadowEpoch)return float4(.07,.07,.07,beauty.a);
    if(code>=16)return nativeRelayFailure(beauty,IN.uv0,7);
    float visibility=(float)code/15;
    return float4(lerp(float3(1,.03,.02),float3(.03,1,.08),visibility),beauty.a);
}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
