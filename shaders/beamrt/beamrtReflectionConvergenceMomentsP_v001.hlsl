#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(currentTex, 0);
uniform_sampler2D(meanHistoryTex, 1);
uniform_sampler2D(momentHistoryTex, 2);
uniform_sampler2D(currentMeanTex, 3);
cbuffer perDraw : register(b0) { uniform float experimentHistoryValid; POSTFX_UNIFORMS };
#include "shaders/common/postFx/postFx.hlsl"
#include "beamrtReflectionConvergencePacking.h.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN) : SV_Target0
{
    int2 p = int2(floor(IN.hpos.xy));
    uint n = convergenceCounters(currentMeanTexTex.Load(int3(p, 0)).a).x;
    if (n == 0u) return 0.0;
    float4 old = experimentHistoryValid > 0.5 ? momentHistoryTexTex.Load(int3(p, 0)) : 0.0;
    uint oldN = experimentHistoryValid > 0.5 ? convergenceCounters(meanHistoryTexTex.Load(int3(p, 0)).a).x : 0u;
    if (oldN >= 128u) return old;
    float4 current = tex2D(currentTex, IN.uv0);
    float L = dot(max(current.rgb, 0.0), float3(0.2126, 0.7152, 0.0722));
    // M1/M2 are moments of the complete weighted linear-HDR contribution.
    // Z is accepted-geometry rate; W known below-macro-surface zero rate.
    return lerp(old, float4(L, L * L, current.a > 0.5 ? 1.0 : 0.0,
        current.a < -0.5 ? 1.0 : 0.0), 1.0 / float(n));
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
