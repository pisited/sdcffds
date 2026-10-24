// OFFLINE production helper with explicit synthetic buffers, no game loading.
#define BEAMRT_MATERIAL_FRESNEL 1
#define BEAMRT_REFLECTION_GGX 1
#define BEAMRT_REFLECTION_DIAGNOSTICS 1
#define BEAMRT_REFLECTION_LOCAL_RESOLVE 1
#include "shaders/beamrt/beamrtReflectionCompose.h.hlsl"
#include "shaders/beamrt/beamrtReflectionLocalResolve.h.hlsl"
struct V { float4 hpos:SV_Position;float2 uv0:TEXCOORD0;float2 uv1:TEXCOORD1;
    float2 uv2:TEXCOORD2;float2 uv3:TEXCOORD3;float3 eye:TEXCOORD4; };
V mainV(uint index:SV_VertexID)
{
    V v;v.uv0=float2((index<<1)&2,index&2);v.uv1=v.uv2=v.uv3=v.uv0;
    v.eye=float3((v.uv0.x-.5)*10,(.5-v.uv0.y)*10,-10);
    v.hpos=float4(v.uv0*float2(2,-2)+float2(-1,1),0,1);return v;
}
float4 mainP(PFXVertToPix input):SV_Target0
{
    return beamrtReflectionLocalResolve(input, tex2D(temporalReflectionTex, input.uv1));
}
