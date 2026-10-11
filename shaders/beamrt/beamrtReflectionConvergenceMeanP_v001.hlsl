#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(currentTex, 0);
uniform_sampler2D(meanHistoryTex, 1);
uniform_sampler2D(prepassTex, 2);
uniform_sampler2D(depthTex, 3);
cbuffer perDraw : register(b0)
{
    uniform float experimentHistoryValid;
    uniform float reflectionMaxRoughness;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#include "beamrtReflectionConvergencePacking.h.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 geometry = decodeGBuffer(TEX_SAMPLER(depthTex), TEX_SAMPLER(prepassTex), IN.uv2, projParams);
    float roughness = max(tex2D(prepassTex, IN.uv2).b, 0.02);
    bool eligible = geometry.w < 0.9999 && roughness < max(reflectionMaxRoughness, 0.021)
        && dot(geometry.xyz, normalize(-IN.wsEyeRay)) > 0.001;
    if (!eligible) return 0.0;
    int2 p = int2(floor(IN.hpos.xy));
    float4 old = experimentHistoryValid > 0.5 ? meanHistoryTexTex.Load(int3(p, 0)) : 0.0;
    uint3 counts = convergenceCounters(old.a);
    if (counts.x >= 128u) return old; // exact endpoint, no samples129+ during capture
    float4 current = tex2D(currentTex, IN.uv0);
    float3 radiance = max(current.rgb, 0.0);
    counts.x += 1u;
    if (abs(current.a) < 0.5) counts.y += 1u;
    if (current.a > 0.5 && max(radiance.r, max(radiance.g, radiance.b)) <= 0.000001) counts.z += 1u;
    // Misses are zeros of the VISIBLE SSR term, not claims of physically black
    // off-screen surfaces. Unknown counts are retained separately in alpha.
    return float4(lerp(old.rgb, radiance, 1.0 / float(counts.x)), convergencePack(counts));
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
