#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(sceneTex, 0);
uniform_sampler2D(meanTex, 1);
uniform_sampler2D(momentsTex, 2);
cbuffer perDraw : register(b0)
{
    uniform float experimentDisplay;
    uniform float reflectionStrength;
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
    float4 mean = tex2D(meanTex, IN.uv1);
    uint3 counts = convergenceCounters(mean.a);
    if (experimentDisplay < 0.5)
    {
        float4 base = tex2D(sceneTex, IN.uv0);
        return float4(hdrEncode(max(hdrDecode(base.rgb) + mean.rgb * reflectionStrength, 0.0)), base.a);
    }
    if (counts.x == 0u) return float4(0.15, 0.15, 0.15, 1.0);
    float4 moments = tex2D(momentsTex, IN.uv2);
    if (experimentDisplay < 1.5) return float4(hdrEncode(max(mean.rgb, 0.0)), 1.0);
    if (experimentDisplay < 2.5)
    {
        float stddev = sqrt(max(moments.y - moments.x * moments.x, 0.0));
        float relative = stddev / max(moments.x, 0.000001);
        float shown = relative / (1.0 + relative);
        return float4(shown, shown, shown, 1.0);
    }
    if (experimentDisplay < 3.5)
        return float4(float(counts.y) / float(counts.x), saturate(moments.z), saturate(moments.w), 1.0);
    if (experimentDisplay < 4.5)
    {
        float rate = float(counts.z) / float(counts.x);
        return float4(rate, rate, rate, 1.0);
    }
    return counts.x == 128u ? float4(0, 1, 0, 1) : float4(float(counts.x) / 128.0, 0, 0, 1);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
