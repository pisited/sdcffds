// Offline execution of the owned traversal core, not an engine/native pass.
#include "shaders/common/hlsl.h"
Texture2D<float4> depths : register(t0);
cbuffer perDraw : register(b0) { float3 origin; float3 direction; float budget; };
float2 beamrtSssrSelect(bool2 c, float2 a, float2 b)
{ return float2(c.x ? a.x : b.x, c.y ? a.y : b.y); }
float3 beamrtSssrSelect(bool3 c, float3 a, float3 b)
{ return float3(c.x ? a.x : b.x, c.y ? a.y : b.y, c.z ? a.z : b.z); }
float FFX_SSSR_LoadDepth(int2 p, int mip)
{ return depths.Load(int3(clamp(p, 0, int2(31, 15)), 0)).r; }
float3 FFX_SSSR_LoadWorldSpaceNormal(int2 p) { return float3(0, 0, -1); }
float3 FFX_SSSR_ScreenSpaceToViewSpace(float3 p) { return p; }
#include "shaders/beamrt/nativeSsr/ffx_sssr_fork.h.hlsl"
struct V { float4 position : SV_Position; };
V mainV(uint index : SV_VertexID)
{
    V output;
    float2 uv = float2((index << 1) & 2, index & 2);
    output.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return output;
}
float4 mainP(V input) : SV_Target0
{
    bool valid = false, sky = false;
    float travel = 0.0;
    float3 hit = FFX_SSSR_HierarchicalRaymarch(origin, direction, float2(-1, -1),
        false, float2(32, 16), 0, 0, (uint)budget, valid, sky, travel);
    return float4(hit, valid ? 1.0 : 0.0);
}
