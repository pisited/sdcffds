// OFFLINE full-screen triangle. Matches BeamNG PostFX semantic layout, with
// fixture-owned eye rays and no engine vertex buffers/camera assumptions.
struct V { float4 hpos:SV_Position;float2 uv0:TEXCOORD0;float2 uv1:TEXCOORD1;
    float2 uv2:TEXCOORD2;float2 uv3:TEXCOORD3;float3 eye:TEXCOORD4; };
V mainV(uint index:SV_VertexID) {
    V v;v.uv0=float2((index<<1)&2,index&2);v.uv1=v.uv2=v.uv3=v.uv0;
    v.eye=float3(v.uv0*float2(40,20),10);
    v.hpos=float4(v.uv0*float2(2,-2)+float2(-1,1),0,1);return v;
}
#ifndef SHADER_STAGE_VS
Texture2D<float4> receiverWorldTex:register(t0);
Texture2D<float4> prePassDepthBufferTex:register(t1);
#define uniform_sampler2D(name,slot) Texture2D<float4> name##Tex : register(t##slot)
cbuffer perDraw:register(b0) {
    float3 receiverOffset;float nativeVisibility;
    float cloudVisibility;float2 pixelOffset;
};
#include "shaders/beamrt/beamrtMeshSunHook.h.hlsl"
float4 mainP(V v):SV_Target0 {
    float3 world=receiverWorldTex.Load(int3(v.hpos.xy,0)).xyz+receiverOffset;
    float4 position=v.hpos;position.xy+=pixelOffset;
    float visibility=beamrtResolveSunVisibility(nativeVisibility,cloudVisibility,position,world);
    // The real hook changes the direct-light visibility expression. Keep a
    // separate ambient term to detect accidental finished-image darkening.
    return float4(float3(.2,.3,.4)+float3(1,2,3)*visibility,visibility);
}
#endif
