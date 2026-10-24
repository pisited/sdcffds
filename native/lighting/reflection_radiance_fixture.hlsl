// OFFLINE only: synthetic camera plus a direct test of production RGB helpers.
#include "shaders/beamrt/beamrtReflectionRadianceSafety.h.hlsl"
Texture2D<float4> fixtureInput : register(t0);
cbuffer perDraw : register(b0) { float3 weighting; };
struct V { float4 hpos:SV_Position;float2 uv0:TEXCOORD0;float2 uv1:TEXCOORD1;
    float2 uv2:TEXCOORD2;float2 uv3:TEXCOORD3;float3 eye:TEXCOORD4; };
V mainV(uint index:SV_VertexID)
{
    V v;v.uv0=float2((index<<1)&2,index&2);v.uv1=v.uv2=v.uv3=v.uv0;
    v.eye=float3((v.uv0.x-.5)*10,(.5-v.uv0.y)*10,10);
    v.hpos=float4(v.uv0*float2(2,-2)+float2(-1,1),0,1);return v;
}
float4 mainP(V input):SV_Target0
{
    float4 sample=fixtureInput.Load(int3(uint2(input.hpos.xy),0));
    float3 source=beamrtReflectionFiniteSource(sample.rgb);
    return float4(beamrtReflectionSafeRadiance(max(source,0.0)*weighting),sample.a);
}
