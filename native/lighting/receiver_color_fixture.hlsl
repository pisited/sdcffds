// Offline test of the exact helper included by the production receiver shader.
#include "shaders/beamrt/beamrtReceiverColor.h.hlsl"
Texture2D<float4> sceneInput : register(t0);
Texture2D<float4> lightInput : register(t1);
cbuffer perDraw : register(b0) { float tint; };
struct V { float4 hpos:SV_Position; };
V mainV(uint index:SV_VertexID)
{
    V v;float2 uv=float2((index<<1)&2,index&2);
    v.hpos=float4(uv*float2(2,-2)+float2(-1,1),0,1);return v;
}
float4 mainP(V input):SV_Target0
{
    int3 pos=int3(uint2(input.hpos.xy),0);
    float3 color=beamrtDelitReceiverChroma(sceneInput.Load(pos).rgb,lightInput.Load(pos).rgb);
    return float4(lerp(float3(1,1,1),color,tint),1);
}
