// OFFLINE only. Production helper, owned textures and an explicit test hit.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(prepassDepthTex, 1);
uniform_sampler2D(backBufferTex, 2);
cbuffer perDraw : register(b0)
{
    float2 acceptedUv;
    float acceptedEyeDepth;
    float reconstructEnabled;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#include "shaders/beamrt/beamrtReflectionSourceReconstruction.h.hlsl"
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
    float coverage = 1.0;
    float2 viewUv = (acceptedUv - rtParams0.xy) / rtParams0.zw;
    float2 sourceUv = viewportCoordToRenderTarget(viewUv, rtParams2);
    float3 radiance = reconstructEnabled > 0.5
        ? beamrtReflectionReconstructedSource(acceptedUv, acceptedEyeDepth, coverage)
        : hdrDecode(tex2Dlod(backBufferTex, float4(sourceUv, 0, 0)).rgb);
    return float4(radiance, coverage);
}
