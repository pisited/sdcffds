#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(halfRadianceTex, 0);
cbuffer perDraw : register(b0)
{
    uniform float2 reflectionHalfSize;
    uniform float2 reflectionQuarterSize;
    uniform float2 reflectionEighthSize;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN) : SV_Target0
{
    int2 outputPixel = int2(floor(IN.hpos.xy));
    int2 halfSize = int2(reflectionHalfSize);
    int2 levelSize = halfSize;
    int2 pixel = outputPixel;
    int block = 1;
    if (pixel.y >= halfSize.y)
    {
        pixel.y -= halfSize.y;
        levelSize = int2(reflectionQuarterSize);
        block = 2;
        if (pixel.y >= levelSize.y)
        {
            pixel.y -= levelSize.y;
            levelSize = int2(reflectionEighthSize);
            block = 4;
        }
    }
    if (any(pixel < 0) || any(pixel >= levelSize)) return 0;
    float2 sourcePixel = (float2(pixel) + 0.5) / levelSize * halfSize;
    int2 centerPixel = clamp(int2(floor(sourcePixel)), 0, halfSize - 1);
    float4 center = halfRadianceTexTex.Load(int3(centerPixel, 0));
    if (block == 1) return center;
    int2 base = int2(floor(sourcePixel - float(block) * 0.5));
    float3 sum = 0;
    float weights = 0;
    [unroll] for (int y = 0; y < 4; ++y)
    [unroll] for (int x = 0; x < 4; ++x)
    {
        if (x < block && y < block)
        {
            int2 p = clamp(base + int2(x, y), 0, halfSize - 1);
            float4 value = halfRadianceTexTex.Load(int3(p, 0));
            float tolerance = max(0.03, center.a * 0.004);
            float weight = 1.0 - smoothstep(tolerance, tolerance * 4.0, abs(value.a - center.a));
            sum += value.rgb * weight;
            weights += weight;
        }
    }
    return float4(weights > 0.0001 ? sum / weights : center.rgb, center.a);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
