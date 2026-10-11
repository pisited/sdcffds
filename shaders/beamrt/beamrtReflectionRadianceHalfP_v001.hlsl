#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(sceneTex, 0);
uniform_sampler2D(depthTex, 1);
cbuffer perDraw : register(b0)
{
    uniform float2 reflectionHalfSize;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float sourceDepth(float2 uv)
{
    float d = ndcToRealDepth(tex2Dlod(depthTex, float4(uv, 0, 0)).r, projParams.zw);
    return clamp(d, 0.0001, 65000.0);
}
float4 mainP(PFXVertToPix IN) : SV_Target0
{
    uint w, h;
    sceneTexTex.GetDimensions(w, h);
    float2 viewportUV = (floor(IN.hpos.xy) + 0.5) / reflectionHalfSize;
    float2 sourceUV = viewportCoordToRenderTarget(viewportUV, rtParams0);
    float centerDepth = sourceDepth(viewportCoordToRenderTarget(viewportUV, rtParams1));
    int2 size = max(int2(w, h), int2(1, 1));
    int2 low = clamp(int2(ceil(min(rtParams0.xy, rtParams0.xy + rtParams0.zw) * size)), 0, size - 1);
    int2 high = clamp(int2(ceil(max(rtParams0.xy, rtParams0.xy + rtParams0.zw) * size)) - 1, low, size - 1);
    int2 base = int2(floor(sourceUV * size - 0.5));
    float3 sum = 0;
    float weights = 0;
    [unroll] for (int y = 0; y < 2; ++y)
    [unroll] for (int x = 0; x < 2; ++x)
    {
        int2 p = clamp(base + int2(x, y), low, high);
        float2 uv = (float2(p) + 0.5) / size;
        float2 viewUV = (uv - rtParams0.xy) / rtParams0.zw;
        float depth = sourceDepth(viewportCoordToRenderTarget(viewUV, rtParams1));
        float tolerance = max(0.03, centerDepth * 0.004);
        float weight = 1.0 - smoothstep(tolerance, tolerance * 4.0, abs(depth - centerDepth));
        // Decode EACH source texel before averaging, not the encoded average.
        sum += max(hdrDecode(sceneTexTex.Load(int3(p, 0)).rgb), 0.0) * weight;
        weights += weight;
    }
    float3 fallback = max(hdrDecode(tex2Dlod(sceneTex, float4(sourceUV, 0, 0)).rgb), 0.0);
    // Representative depth is never averaged with radiance.
    return float4(clamp(weights > 0.0001 ? sum / weights : fallback, 0.0, 65000.0), centerDepth);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
